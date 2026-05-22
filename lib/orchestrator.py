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
background-agent launch is an INJECTED callable ``launch_fn(unit_id, attempt)``;
U5's driver passes the real wrapper around an ``Agent`` ``run_in_background``
dispatch whose prompt instructs the agent to call ``ledger.record_verdict`` on
completion — passing ``attempt`` so the verdict carries the dispatch generation it
was launched for (Bug #6 attempt-identity). For tests (and a documented default)
``launch_fn`` defaults to a no-op recorder.

The launch fires ONLY AFTER the pending->dispatched transition succeeds — never
launch-then-fail-to-mark, which would orphan a verdict with nothing to link it to.

THE LAUNCH GUARD (Bug #8)
─────────────────────────
``launch_fn`` is real I/O (a background-agent spawn) and CAN raise. The launch is
wrapped in a PER-UNIT try/except: a launch failure marks that unit ``stalled`` with
``last_error = {call:"launch", ...}`` (reusing the ``dispatched -> stalled`` edge —
no new grammar) and records ``"launch-failed:<class>:<msg>"`` in the per-unit
results, then CONTINUES the wave. Without the guard a single launch raise would
leave the unit committed as ``dispatched`` with no agent running (a phantom unit
recoverable only via the stall timeout) AND propagate out of the loop, abandoning
every remaining unit in the wave. The burnt attempt is naturally recorded in the
unit's ``attempt`` counter (incremented at dispatch); the operator can
``/dispatch-resume retry`` the stalled unit.

ATTEMPT-IDENTITY (Bug #6)
─────────────────────────
Each ``pending -> dispatched`` transition INCREMENTS the unit's ``attempt`` counter
(in the SAME atomic snapshot as the state change, via the transition's ``**fields``
— never a separate write, which would reopen a race). The launched agent carries
this attempt; ``ledger.record_verdict`` rejects a verdict whose attempt is older
than the unit's current attempt (a stale verdict from a superseded retry).
"""

from __future__ import annotations

import inspect
import os
import sys

# ──────────────────────────────────────────────────────────────────────────
# Load the canonical ledger module via the ONE shared loader (lib/_bootstrap),
# then bind the public names we use explicitly so the import surface of this
# module is legible. We still EXTRACT individual names (rather than touching
# `ledger.<x>` everywhere) so the deliberate reader/writer split below stays
# visible — that split is the load-bearing discipline, not the binding name.

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger  # noqa: E402 — after _LIB_DIR is on sys.path.

ledger = load_ledger()

# The ledger names this module is permitted to use. NOTE the deliberate split:
# the READER path (ready_units / converge) uses only read_ledger; the WRITER
# path (dispatch_batch) additionally uses transition + InvalidTransition. There
# is no path through converge that reaches a write function.
read_ledger = ledger.read_ledger
_transition = ledger.transition
_unit_is_terminal = ledger.unit_is_terminal
InvalidTransition = ledger.InvalidTransition
LedgerError = ledger.LedgerError

# Re-export _now_iso so dispatch_batch can stamp dispatched_at consistently with
# every other ledger timestamp (same format ledger.py emits).
_now_iso = ledger._now_iso

GATING_SEVERITIES = ledger.GATING_SEVERITIES


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


def _default_launch_fn(unit_id: str, attempt: int = 0) -> None:
    """Default agent-launch: a no-op recorder.

    The real launch is injected by U5's driver — a wrapper around an ``Agent``
    ``run_in_background`` dispatch whose prompt instructs the spawned agent to
    call ``ledger.record_verdict(... attempt=attempt)`` on completion (the durable
    self-write, tagged with the dispatch generation — Bug #6). For U10 (and tests)
    this default does nothing observable; the dispatch_batch return value is what
    tests assert against.

    Signature note (RAISED as a contract change): ``launch_fn`` now takes
    ``(unit_id, attempt)`` so the agent can carry its attempt into the verdict.
    ``_invoke_launch`` below calls back-compat-safely via ``inspect.signature`` so
    a legacy single-arg ``launch_fn(unit_id)`` still works.
    """
    return None


def _invoke_launch(launch_fn, unit_id: str, attempt: int) -> None:
    """Call ``launch_fn`` tolerating BOTH the new ``(unit_id, attempt)`` signature
    and a legacy single-arg ``(unit_id)`` one (back-compat for any U5 wiring
    written against the old contract). Defensive, not load-bearing — the canonical
    signature is two-arg.
    """
    try:
        params = inspect.signature(launch_fn).parameters
        # A *args launcher, or one accepting >=2 positional params, gets attempt.
        accepts_attempt = (
            any(
                p.kind == inspect.Parameter.VAR_POSITIONAL for p in params.values()
            )
            or len(
                [
                    p
                    for p in params.values()
                    if p.kind
                    in (
                        inspect.Parameter.POSITIONAL_ONLY,
                        inspect.Parameter.POSITIONAL_OR_KEYWORD,
                    )
                ]
            )
            >= 2
        )
    except (TypeError, ValueError):
        accepts_attempt = True  # builtins / C funcs: assume the new signature.
    if accepts_attempt:
        launch_fn(unit_id, attempt)
    else:
        launch_fn(unit_id)


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
      * For each selected unit: ``transition(... "dispatched", dispatched_at=now,
        attempt=current+1)`` FIRST (which inherits I-1 atomicity + flock from
        ledger.py, and bumps the Bug #6 attempt counter in the SAME atomic
        snapshot), THEN call ``launch_fn(unit_id, attempt)``. Transition-before-
        launch ordering is deliberate: a launch with no recorded dispatch would
        orphan the eventual verdict.
      * Bug #8 — the ``launch_fn`` call is wrapped in a PER-UNIT try/except. A
        launch raise marks the unit ``stalled`` (``dispatched -> stalled`` with
        ``last_error = {call:"launch", ...}``), records ``"launch-failed:..."`` in
        the results, and CONTINUES the wave — it does NOT leave a phantom
        ``dispatched`` unit with no agent, and does NOT abandon the rest of the
        batch by propagating the raise.

    Per-unit results are returned as a list of ``(unit_id, status)`` tuples where
    status is ``"dispatched"``, ``"rejected:<reason>"``, or
    ``"launch-failed:<class>:<msg>"`` — so callers/tests can assert the precise
    outcome of a mixed batch (some pending, some already in flight, some whose
    launch raised). The rejection is per-unit, NOT fail-fast: a stray
    already-dispatched unit in the list does not block the genuinely-pending ones,
    and one unit's launch failure does not abandon the rest of the wave.

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

        # Transition FIRST (records dispatched_at + bumps the attempt counter
        # atomically under flock + I-1), then launch. If the transition raises
        # (e.g. a concurrent dispatch beat us to it), record the rejection and DO
        # NOT launch. The attempt increment is part of the SAME atomic snapshot as
        # the state change (Bug #6) — never a separate write, which would reopen a
        # race between the bump and the dispatch.
        next_attempt = int(unit.get("attempt", 0) or 0) + 1
        try:
            _transition(
                repo_root,
                run_id,
                uid,
                "dispatched",
                dispatched_at=_now_iso(),
                attempt=next_attempt,
            )
        except InvalidTransition as exc:
            results.append((uid, f"rejected:invalid-transition({exc})"))
            continue

        # Bug #8: guard the real I/O per-unit. A launch raise must NOT leave the
        # unit a phantom `dispatched` with no agent, NOR abandon the rest of the
        # wave. Mark the unit stalled (dispatched -> stalled, reusing the existing
        # grammar edge) with a launch-failure last_error, record the failure, and
        # CONTINUE. The operator can /dispatch-resume retry it; the burnt attempt
        # is already recorded in the attempt counter.
        try:
            _invoke_launch(launch_fn, uid, next_attempt)
        except Exception as exc:  # noqa: BLE001 — any launch raise is recorded.
            err = {
                "call": "launch",
                "message": f"{type(exc).__name__}: {exc}",
                "at": _now_iso(),
            }
            try:
                _transition(repo_root, run_id, uid, "stalled", last_error=err)
            except (InvalidTransition, LedgerError):
                # Best-effort: even if the rollback transition fails, do not
                # propagate — record the launch failure and keep the wave going.
                pass
            results.append(
                (uid, f"launch-failed:{type(exc).__name__}:{exc}")
            )
            continue

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
