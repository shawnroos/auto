#!/usr/bin/env python3
"""claude-dispatch U10: agent-managed batch fan-out for the work-loop.

The orchestration layer is *agent-driven* and deliberately separate from the
mechanical tick (U4). The DRIVING AGENT (U5) owns the policy — it reads which
units are ready, decides a batch cap for this wave (resizing in flight under
machine pressure), dispatches, then reconciles landed verdicts. The engine here
only exposes ready-and-independent units and reconciles durable state; it never
hardcodes a concurrency constant (R12) and never decides how to parallelize.

Three operations (against the ledger schema contract,
docs/contracts/ledger-schema.md — read THAT, not lib/ledger.py, for the spec):

  * ``ready_units(repo, run)``  -> the unit ids dispatchable RIGHT NOW.
  * ``dispatch_batch(repo, run, unit_ids, cap, *, launch_fn=None)``
        -> marks each chosen unit pending->dispatched (records dispatched_at),
           launches its background agent; REJECTS any unit not in `pending`
           (idempotency guard — pending->dispatched is the only entry).
  * ``converge(repo, run)``  -> a RECONCILE/READ step over durable ledger state.
           It is NOT the verdict-writer.

THE LOAD-BEARING CORRECTNESS PROPERTY (verdict survives session death)
─────────────────────────────────────────────────────────────────────
Each dispatched background agent SELF-WRITES its own verdict into the ledger
atomically, via ``ledger.record_verdict`` (the I-1 write chokepoint). The
verdict is durable the moment the agent finishes — independent of whether the
driving session is still alive. So ``converge`` never loses a verdict to a
session death: a resumed session reads completed verdicts straight off the
ledger and does NOT re-dispatch them. The orchestrator's in-flight batch state
(which cap it chose, which handles it holds) is DISPOSABLE; only the durable
per-unit ledger state matters across a resume.

``converge`` is therefore a READER by construction: this module's converge code
path imports ONLY ``read_ledger`` from the ledger — never ``transition`` /
``record_verdict`` / ``set_loop``. A future reviewer cannot add a write to
converge without adding a new write-import, which would be immediately visible.
This mirrors ledger.py's "single chokepoint" discipline for I-1.

THE AGENT-LAUNCH BOUNDARY (documented interface for U5 to wire)
────────────────────────────────────────────────────────────────
For U10 we implement the orchestration + ledger interactions. The actual
background-agent launch is an INJECTED callable ``launch_fn(unit_id)``; U5's
driver passes the real wrapper around an ``Agent`` ``run_in_background`` dispatch
whose prompt instructs the agent to call ``ledger.record_verdict`` on completion.
For tests (and a documented default) ``launch_fn`` defaults to a no-op recorder.
The launch fires ONLY AFTER the pending->dispatched transition succeeds — never
launch-then-fail-to-mark, which would orphan a verdict with nothing to link it to.
"""

from __future__ import annotations

import importlib.util
import os
import sys

# ──────────────────────────────────────────────────────────────────────────
# Load the canonical ledger module by file path (matches the test harness
# pattern; avoids depending on lib/ being on sys.path). We bind the public
# names we use explicitly so the import surface of this module is legible.

_LEDGER_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ledger.py")
_spec = importlib.util.spec_from_file_location("claude_dispatch_ledger", _LEDGER_PY)
_ledger = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ledger)

# The ledger names this module is permitted to use. NOTE the deliberate split:
# the READER path (ready_units / converge) uses only read_ledger; the WRITER
# path (dispatch_batch) additionally uses transition + InvalidTransition. There
# is no path through converge that reaches a write function.
read_ledger = _ledger.read_ledger
_transition = _ledger.transition
_unit_is_terminal = _ledger.unit_is_terminal
InvalidTransition = _ledger.InvalidTransition
LedgerError = _ledger.LedgerError

# Re-export _now_iso so dispatch_batch can stamp dispatched_at consistently with
# every other ledger timestamp (same format ledger.py emits).
_now_iso = _ledger._now_iso

GATING_SEVERITIES = _ledger.GATING_SEVERITIES


# ──────────────────────────────────────────────────────────────────────────
# Errors.


class OrchestratorError(Exception):
    """Base class for orchestrator errors."""


# ──────────────────────────────────────────────────────────────────────────
# Pure dependency / readiness logic (operates on an in-memory ledger dict).


def _units_by_id(ledger: dict) -> dict:
    return {u["id"]: u for u in ledger.get("units", [])}


def _dependency_satisfied(dep_unit: dict) -> bool:
    """A SINGLE dependency is *satisfied* per the contract's precise definition.

    Satisfied iff the dependency is ``fixed``, ``terminal-skip``, OR
    ``verdict-returned AND it contributes no open blockers/majors``. A merely
    ``verdict-returned`` unit that STILL has an open blocker/major is NOT
    satisfied — its dependents wait, because that unit is about to transition
    ``verdict-returned -> pending`` for re-dispatch and its output will change.

    Note ``fixed`` is treated as satisfied unconditionally here (per the
    explicit list in the U10 approach: "fixed, terminal-skip, OR
    verdict-returned AND no open blockers/majors"). The closure livelock is
    guarded at the predicate level (a ``fixed`` unit with a stale blocker keeps
    ``all_units_terminal == false``), so a downstream unit dispatched against a
    ``fixed`` predecessor is correct — the predecessor will be re-reviewed.
    """
    state = dep_unit.get("state")
    if state in ("fixed", "terminal-skip"):
        return True
    if state == "verdict-returned":
        for finding in dep_unit.get("findings") or []:
            if finding.get("severity") in GATING_SEVERITIES:
                return False
        return True
    return False


def _ancestor_ids(unit_id: str, by_id: dict) -> set:
    """Transitive closure of a unit's ancestors (all dependencies, recursively).

    "No ancestor is stalled" in the ready definition is TRANSITIVE: if
    U_c -> U_b -> U_a and U_a is stalled, U_c is NOT ready even though its direct
    dependency U_b is merely pending. We compute the full ancestor set so the
    stall-propagation gate matches the engine's predicate-time stall propagation.
    Cycle-safe via a visited set (a malformed cyclic graph terminates).
    """
    ancestors: set = set()
    stack = list((by_id.get(unit_id) or {}).get("depends_on") or [])
    while stack:
        dep_id = stack.pop()
        if dep_id in ancestors:
            continue
        ancestors.add(dep_id)
        dep = by_id.get(dep_id)
        if dep:
            stack.extend(dep.get("depends_on") or [])
    return ancestors


def _is_ready(unit: dict, by_id: dict) -> bool:
    """A unit is READY (dispatchable now) iff:

      * state == "pending", AND
      * every DIRECT dependency is *satisfied* (see _dependency_satisfied), AND
      * NO transitive ancestor is in state "stalled".

    A dependency id that is absent from the ledger is treated as unsatisfied
    (we never dispatch against an unknown predecessor).
    """
    if unit.get("state") != "pending":
        return False

    # Direct-dependency satisfaction.
    for dep_id in unit.get("depends_on") or []:
        dep = by_id.get(dep_id)
        if dep is None or not _dependency_satisfied(dep):
            return False

    # Transitive stalled-ancestor gate.
    for anc_id in _ancestor_ids(unit["id"], by_id):
        anc = by_id.get(anc_id)
        if anc is not None and anc.get("state") == "stalled":
            return False

    return True


def ready_units(repo_root: str, run_id: str):
    """Return the list of unit ids dispatchable RIGHT NOW (a READER op).

    Reads the ledger off disk (durable truth) and applies the readiness
    predicate. Ordering is the ledger's unit declaration order (deterministic),
    so ``dispatch_batch``'s ``cap`` truncation is reproducible.
    """
    ledger = read_ledger(repo_root, run_id)
    by_id = _units_by_id(ledger)
    return [u["id"] for u in ledger.get("units", []) if _is_ready(u, by_id)]


# ──────────────────────────────────────────────────────────────────────────
# Dispatch — the WRITER op. pending -> dispatched + launch the background agent.


def _default_launch_fn(unit_id: str) -> None:
    """Default agent-launch: a no-op recorder.

    The real launch is injected by U5's driver — a wrapper around an ``Agent``
    ``run_in_background`` dispatch whose prompt instructs the spawned agent to
    call ``ledger.record_verdict`` on completion (the durable self-write). For
    U10 (and tests) this default does nothing observable; the dispatch_batch
    return value is what tests assert against.
    """
    return None


def dispatch_batch(repo_root, run_id, unit_ids, cap, *, launch_fn=None):
    """Mark up to ``cap`` of ``unit_ids`` pending->dispatched and launch each.

    Behavior (per the U10 contract):

      * ``cap`` is supplied by the AGENT PER CALL — it is NOT a constant. 16 when
        idle, 3 when grinding, 1 to serialize a probe, 0 to dispatch nothing.
        ``cap`` is a per-wave decision; resizing happens BETWEEN calls.
      * Selection: take ``unit_ids`` in the order given, keep only those whose
        current state is ``pending`` (the idempotency guard — any non-pending
        unit, e.g. already ``dispatched``, is REJECTED and skipped, never
        double-launched), and truncate the eligible set to ``cap``.
      * For each selected unit: ``transition(... "dispatched", dispatched_at=now)``
        FIRST (which inherits I-1 atomicity + flock from ledger.py), THEN call
        ``launch_fn(unit_id)``. Transition-before-launch ordering is deliberate:
        a launch with no recorded dispatch would orphan the eventual verdict.

    Per-unit results are returned as a list of ``(unit_id, status)`` tuples where
    status is ``"dispatched"`` or ``"rejected:<reason>"`` — so callers/tests can
    assert the precise outcome of a mixed batch (some pending, some already in
    flight). The rejection is per-unit, NOT fail-fast: a stray already-dispatched
    unit in the list does not block the genuinely-pending ones.

    Idempotency note: an already-``dispatched`` unit fails the
    ``pending -> dispatched`` grammar edge in ledger.py (``transition`` raises
    ``InvalidTransition``), so even a race that slips past the pre-filter cannot
    produce a second ``dispatched_at`` — the transition is the authoritative
    guard, the pre-filter is just to avoid a pointless write attempt.
    """
    if cap is None or int(cap) < 0:
        raise OrchestratorError(f"cap must be a non-negative int, got {cap!r}")
    cap = int(cap)
    if launch_fn is None:
        launch_fn = _default_launch_fn

    ledger = read_ledger(repo_root, run_id)
    by_id = _units_by_id(ledger)

    results = []
    dispatched_count = 0
    for uid in unit_ids:
        unit = by_id.get(uid)
        if unit is None:
            results.append((uid, "rejected:unknown-unit"))
            continue
        if unit.get("state") != "pending":
            # Idempotency guard: already dispatched / verdict-returned / etc.
            results.append((uid, f"rejected:not-pending({unit.get('state')})"))
            continue
        if dispatched_count >= cap:
            # Eligible but over the agent-chosen cap for THIS wave; left pending
            # for a later wave's dispatch_batch call.
            results.append((uid, "rejected:over-cap"))
            continue

        # Transition FIRST (records dispatched_at atomically under flock + I-1),
        # then launch. If the transition raises (e.g. a concurrent dispatch beat
        # us to it), record the rejection and DO NOT launch.
        try:
            _transition(
                repo_root, run_id, uid, "dispatched", dispatched_at=_now_iso()
            )
        except InvalidTransition as exc:
            results.append((uid, f"rejected:invalid-transition({exc})"))
            continue

        launch_fn(uid)
        dispatched_count += 1
        results.append((uid, "dispatched"))

    return results


# ──────────────────────────────────────────────────────────────────────────
# Converge — the RECONCILE/READ step. This path uses ONLY read_ledger.
# It NEVER writes the ledger (the durability property: agents self-write
# verdicts; converge merely reads what is already durable on disk).


def converge(repo_root, run_id):
    """Reconcile durable ledger state into a cheap summary for the driver.

    A RECONCILE/READ step over durable per-unit state — NOT the verdict-writer.
    Each dispatched background agent has already self-written its own verdict via
    ``ledger.record_verdict`` (atomic, I-1) the moment it finished. converge just
    READS the ledger fresh off disk and classifies units, so a resumed session
    (one whose driving process died after agents completed) sees completed
    verdicts straight from disk and does NOT re-dispatch them.

    Returns a summary dict::

        {
          "in_flight":  [ids still "dispatched" (no verdict yet)],
          "completed":  [ids whose agent self-wrote a verdict: state in
                         {"verdict-returned","fixed"}],
          "stalled":    [ids in "stalled"],
          "terminal":   [ids where unit_is_terminal(u) is True],
          "all_units_terminal": bool (read from the cached predicate — NOT
                         re-derived; honors feedback_loop_monitor_terminal_state_field),
          "met": bool (the cached exit predicate; read, never recomputed here),
        }

    The fresh-read property is the load-bearing one: between two converge calls,
    state written by ANOTHER process (an agent self-writing a verdict) is picked
    up — converge holds no in-memory batch state across calls.
    """
    ledger = read_ledger(repo_root, run_id)

    in_flight = []
    completed = []
    stalled = []
    terminal = []
    for unit in ledger.get("units", []):
        state = unit.get("state")
        if state == "dispatched":
            in_flight.append(unit["id"])
        elif state in ("verdict-returned", "fixed"):
            completed.append(unit["id"])
        elif state == "stalled":
            stalled.append(unit["id"])
        if _unit_is_terminal(unit):
            terminal.append(unit["id"])

    pred = ledger.get("exit_predicate_result") or {}
    return {
        "in_flight": in_flight,
        "completed": completed,
        "stalled": stalled,
        "terminal": terminal,
        "all_units_terminal": bool(pred.get("all_units_terminal", False)),
        "met": bool(pred.get("met", False)),
    }


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/orchestrator.sh routes through this). Positional argv only;
# never string-interpolated into a shell ($ARGUMENTS-safe — the $-logic lives
# in the .sh shim, never in a command .md body).


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: orchestrator.py <subcommand> ...\n")
        return 2
    cmd = argv[0]
    try:
        if cmd == "ready":
            repo, run = argv[1], argv[2]
            for uid in ready_units(repo, run):
                print(uid)
            return 0
        if cmd == "dispatch":
            # dispatch <repo> <run> <cap> <unit_id...>
            repo, run, cap = argv[1], argv[2], argv[3]
            uids = argv[4:]
            for uid, status in dispatch_batch(repo, run, uids, int(cap)):
                print(f"{uid}\t{status}")
            return 0
        if cmd == "converge":
            repo, run = argv[1], argv[2]
            import json

            json.dump(converge(repo, run), sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        sys.stderr.write(f"orchestrator.py: unknown subcommand {cmd!r}\n")
        return 2
    except (OrchestratorError, LedgerError) as e:
        sys.stderr.write(f"orchestrator.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"orchestrator.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
