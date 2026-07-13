#!/usr/bin/env python3
"""auto U10: agent-managed batch fan-out for the work-loop.

The orchestration layer is *agent-driven* and deliberately separate from the
mechanical pulse (U4). The DRIVING AGENT (U5) owns the policy — it reads which
steps are ready, decides a batch cap for this wave (resizing in flight under
machine pressure), dispatches, then reconciles landed verdicts. The engine here
only exposes ready-and-independent steps and reconciles durable state; it never
hardcodes a concurrency constant (R12) and never decides how to parallelize.

Three operations (against the run-record schema contract,
docs/contracts/run-record-schema.md — read THAT, not lib/run_record.py, for the spec):

  * ``ready_steps(repo, run)``  -> the step ids dispatchable RIGHT NOW.
  * ``dispatch_batch(repo, run, step_ids, cap, *, launch_fn=None)``
        -> marks each chosen step pending->dispatched (records dispatched_at),
           launches its background agent; REJECTS any step not in `pending`
           (idempotency guard — pending->dispatched is the only entry).
  * ``converge(repo, run)``  -> a RECONCILE/READ step over durable run-record state.
           It is NOT the verdict-writer.

THE LOAD-BEARING CORRECTNESS PROPERTY (verdict survives session death)
─────────────────────────────────────────────────────────────────────
Each dispatched background agent SELF-WRITES its own verdict into the run-record
atomically, via ``run_record.record_verdict`` (the I-1 write chokepoint). The
verdict is durable the moment the agent finishes — independent of whether the
driving session is still alive. So ``converge`` never loses a verdict to a
session death: a resumed session reads completed verdicts straight off the
run-record and does NOT re-dispatch them. The dispatcher's in-flight batch state
(which cap it chose, which handles it holds) is DISPOSABLE; only the durable
per-step run-record state matters across a resume.

``converge`` is therefore a READER by construction: this module's converge code
path imports ONLY ``read_run_record`` from the run-record — never ``transition`` /
``record_verdict`` / ``set_loop``. A future reviewer cannot add a write to
converge without adding a new write-import, which would be immediately visible.
This mirrors run_record.py's "single chokepoint" discipline for I-1.

THE AGENT-LAUNCH BOUNDARY (documented interface for U5 to wire)
────────────────────────────────────────────────────────────────
For U10 we implement the orchestration + run-record interactions. The actual
background-agent launch is an INJECTED callable ``launch_fn(step_id, attempt)``;
U5's driver passes the real wrapper around an ``Agent`` ``run_in_background``
dispatch whose prompt instructs the agent to call ``run_record.record_verdict`` on
completion — passing ``attempt`` so the verdict carries the dispatch generation it
was launched for (Bug #6 attempt-identity). For tests (and a documented default)
``launch_fn`` defaults to a no-op recorder.

The launch fires ONLY AFTER the pending->dispatched transition succeeds — never
launch-then-fail-to-mark, which would orphan a verdict with nothing to link it to.

THE LAUNCH GUARD (Bug #8)
─────────────────────────
``launch_fn`` is real I/O (a background-agent spawn) and CAN raise. The launch is
wrapped in a PER-STEP try/except: a launch failure marks that step ``stalled`` with
``last_error = {call:"launch", ...}`` (reusing the ``dispatched -> stalled`` edge —
no new grammar) and records ``"launch-failed:<class>:<msg>"`` in the per-step
results, then CONTINUES the wave. Without the guard a single launch raise would
leave the step committed as ``dispatched`` with no agent running (a phantom step
recoverable only via the stall timeout) AND propagate out of the loop, abandoning
every remaining step in the wave. The burnt attempt is naturally recorded in the
step's ``attempt`` counter (incremented at dispatch); the operator can
``/auto-resume retry`` the stalled step.

ATTEMPT-IDENTITY (Bug #6)
─────────────────────────
Each ``pending -> dispatched`` transition INCREMENTS the step's ``attempt`` counter
(in the SAME atomic snapshot as the state change, via the transition's ``**fields``
— never a separate write, which would reopen a race). The launched agent carries
this attempt; ``run_record.record_verdict`` rejects a verdict whose attempt is older
than the step's current attempt (a stale verdict from a superseded retry).
"""

from __future__ import annotations

import os
import sys

# ──────────────────────────────────────────────────────────────────────────
# Load the canonical run-record module via the ONE shared loader (lib/_bootstrap),
# then bind the public names we use explicitly so the import surface of this
# module is legible. We still EXTRACT individual names (rather than touching
# `run_record.<x>` everywhere) so the deliberate reader/writer split below stays
# visible — that split is the load-bearing discipline, not the binding name.

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_run_record, load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

run_record = load_run_record()

# The run-record names this module is permitted to use. NOTE the deliberate split:
# the READER path (ready_steps / converge) uses only read_run_record; the WRITER
# path (dispatch_batch) additionally uses transition + InvalidTransition. There
# is no path through converge that reaches a write function.
read_run_record = run_record.read_run_record
_transition = run_record.transition
_step_is_terminal = run_record.step_is_terminal
_gating_severities = run_record.gating_severities
InvalidTransition = run_record.InvalidTransition
RunRecordError = run_record.RunRecordError

# Re-export now_iso so dispatch_batch can stamp dispatched_at consistently with
# every other run-record timestamp (same format run_record.py emits).
_now_iso = run_record.now_iso

# NOTE: we deliberately do NOT re-export GATING_SEVERITIES here. The gating
# decision is scale-aware and lives in ONE place — run_record.gating_severities(scale)
# (Bug #3). Re-exporting the raw constant would let a future caller shortcut around
# the helper and reintroduce the hardcoded-major-gating livelock; there is nothing
# to copy if the constant is not in reach.


# ──────────────────────────────────────────────────────────────────────────
# Errors.


class DispatcherError(Exception):
    """Base class for dispatcher errors."""


# ──────────────────────────────────────────────────────────────────────────
# Pure dependency / readiness logic (operates on an in-memory run-record dict).


def _steps_by_id(run_record: dict) -> dict:
    return {u["id"]: u for u in run_record.get("steps", [])}


def _dependency_satisfied(dep_step: dict, scale: str = "three-tier") -> bool:
    """A SINGLE dependency is *satisfied* per the contract's precise definition.

    Satisfied iff the dependency is ``fixed``, ``terminal-skip``, OR
    ``verdict-returned AND it contributes no open GATING finding``. A merely
    ``verdict-returned`` step that STILL has an open gating finding is NOT
    satisfied — its dependents wait, because that step is about to transition
    ``verdict-returned -> pending`` for re-dispatch and its output will change.

    SCALE-AWARE (Bug #3): which severities count as gating is decided by the
    SINGLE helper ``run_record.gating_severities(scale)`` — never a hardcoded
    ``("blocker","major")``. Under ``"blocker-only"`` a dependency carrying only a
    major finding IS satisfied (its dependents may dispatch), exactly as
    ``step_is_terminal`` treats it as terminal — the two agree because they share
    the helper. Hardcoding majors here would livelock a blocker-only run: a major
    finding on a predecessor would block its dependents forever even though that
    finding never gates the loop's done-ness.

    Note ``fixed`` is treated as satisfied unconditionally here (per the
    explicit list in the U10 approach). The closure livelock is guarded at the
    predicate level (a ``fixed`` step with a stale gating finding keeps
    ``all_steps_terminal == false``), so a downstream step dispatched against a
    ``fixed`` predecessor is correct — the predecessor will be re-reviewed.
    """
    gating = _gating_severities(scale)
    state = dep_step.get("state")
    if state in ("fixed", "terminal-skip"):
        return True
    if state == "verdict-returned":
        for finding in dep_step.get("findings") or []:
            if finding.get("severity") in gating:
                return False
        return True
    return False


def _ancestor_ids(step_id: str, by_id: dict) -> set:
    """Transitive closure of a step's ancestors (all dependencies, recursively).

    "No ancestor is stalled" in the ready definition is TRANSITIVE: if
    U_c -> U_b -> U_a and U_a is stalled, U_c is NOT ready even though its direct
    dependency U_b is merely pending. We compute the full ancestor set so the
    stall-propagation gate matches the engine's predicate-time stall propagation.
    Cycle-safe via a visited set (a malformed cyclic graph terminates).
    """
    ancestors: set = set()
    stack = list((by_id.get(step_id) or {}).get("depends_on") or [])
    while stack:
        dep_id = stack.pop()
        if dep_id in ancestors:
            continue
        ancestors.add(dep_id)
        dep = by_id.get(dep_id)
        if dep:
            stack.extend(dep.get("depends_on") or [])
    return ancestors


def _is_ready(step: dict, by_id: dict, scale: str = "three-tier") -> bool:
    """A step is READY (dispatchable now) iff:

      * state == "pending", AND
      * every DIRECT dependency is *satisfied* (see _dependency_satisfied), AND
      * NO transitive ancestor is in state "stalled".

    A dependency id that is absent from the run-record is treated as unsatisfied
    (we never dispatch against an unknown predecessor). ``scale`` is threaded into
    the satisfaction check so blocker-only runs treat a major-only predecessor as
    satisfied (Bug #3 — same gating decision as terminality / met).
    """
    if step.get("state") != "pending":
        return False

    # Direct-dependency satisfaction.
    for dep_id in step.get("depends_on") or []:
        dep = by_id.get(dep_id)
        if dep is None or not _dependency_satisfied(dep, scale):
            return False

    # Transitive stalled-ancestor gate.
    for anc_id in _ancestor_ids(step["id"], by_id):
        anc = by_id.get(anc_id)
        if anc is not None and anc.get("state") == "stalled":
            return False

    return True


def ready_steps(repo_root: str, run_id: str):
    """Return the list of step ids dispatchable RIGHT NOW (a READER op).

    Reads the run-record off disk (durable truth) and applies the readiness
    predicate. Ordering is the run-record's step declaration order (deterministic),
    so ``dispatch_batch``'s ``cap`` truncation is reproducible.
    """
    run_record = read_run_record(repo_root, run_id)
    by_id = _steps_by_id(run_record)
    scale = run_record.get("backend_scale", "three-tier")
    return [u["id"] for u in run_record.get("steps", []) if _is_ready(u, by_id, scale)]


# ──────────────────────────────────────────────────────────────────────────
# Supervision / escalation predicate (U3 / KTD4 / R8).


def should_escalate(step: dict, max_attempts: int = 2) -> bool:
    """True iff a stalled step has exhausted its retry budget — the driver must
    pause-escalate to the operator instead of retrying again (R8).

    Pure over a single in-memory step dict. It reads the EXISTING ``attempt``
    counter (bumped mechanically on each ``pending -> dispatched`` dispatch, Bug
    #6) — deliberately NO new counter (KTD4). The driver's stalled-node policy
    (SKILL.md §4): reap the live agent, clear the reap marker, then if this is
    False (``attempt < max_attempts``) ``auto-resume.py retry`` the step; if True
    (``attempt >= max_attempts``) ``auto-resume.py pause`` to hand a wedged step
    to the operator rather than looping forever. ``max_attempts`` defaults to 2,
    the settled N=2 escalation budget. A missing/zero attempt reads as 0 (never
    escalates), matching the attempt counter's additive default.
    """
    return int(step.get("attempt", 0) or 0) >= int(max_attempts)


def pick_next_plan_step_to_advance(run_record: dict):
    """Round-robin selector for serialized N>1 plan-loop advance (U6 / KTD-4).

    With multiple plan-phase steps (A2's competing plans), exactly ONE advances
    per pulse so the backend's ``next_plan_step(run-record)`` sees a single logical
    advance-stream and the contract stays unchanged. This picks which one: the
    eligible plan step with the OLDEST ``last_advanced_at`` (``null`` sorts oldest
    → a never-advanced step goes first), ties broken by ``steps[]`` declaration
    order. State lives in the run-record (``last_advanced_at`` per step), so resume
    continues the rotation correctly across pulses.

    Eligible = phase ``plan`` AND state ``dispatched`` (NOT ``stalled`` — a
    stalled plan step is excluded from the rotation; adversarial F3). Returns the
    step id, or ``None`` when no plan step is eligible (single-plan A1 never calls
    this — it uses the scalar fast path). A READER: no mutation.
    """
    candidates = [
        u for u in run_record.get("steps", [])
        if u.get("phase") == "plan" and u.get("state") == "dispatched"
    ]
    if not candidates:
        return None
    # Stable sort by (has_timestamp, timestamp): None sorts before any string, so
    # never-advanced steps (last_advanced_at=None) come first; declaration order
    # is preserved among equals because sorted() is stable.
    def keyfn(u):
        ts = u.get("last_advanced_at")
        return (ts is not None, ts or "")
    return sorted(candidates, key=keyfn)[0]["id"]


# ──────────────────────────────────────────────────────────────────────────
# Dispatch — the WRITER op. pending -> dispatched + launch the background agent.

# The closed set of backend ops a step may declare via ``invokes.backend_op``
# (workflow-compiled steps carry it on ``dispatch_context`` — ``workflows.step_for``
# merges ``invokes`` into ``dispatch_context``, and ``_normalize_step`` drops the
# raw ``invokes`` key but preserves ``dispatch_context`` verbatim). Every shipped
# workflow's op is one of these four (``tests/unit/workflows.test.sh`` asserts the
# subset). ``dispatch_batch`` rejects any OTHER value at dispatch instead of
# launching an agent against a misspelled/unknown op — the guard closes the gap
# where an unknown op previously flowed straight to ``launch_fn``.
#
# v0.14.0 (U1): the frozenset was lifted into the pure-stdlib leaf
# ``lib/backend_ops.py`` so ``lib/presets.py::validate_preset`` can check a
# preset's op against the SAME set without importing this heavy dispatch module
# (KTD-2 DAG boundary). We re-bind it here under the same name, so this module's
# dispatch guard (``op not in VALID_BACKEND_OPS`` below) is unchanged.
VALID_BACKEND_OPS = load_lib_module("backend_ops").VALID_BACKEND_OPS


def _step_backend_op(step: dict):
    """Resolve a step's declared ``backend_op``, or None if it declares none.

    Reads ``dispatch_context.backend_op`` FIRST (the durable home on a
    workflow-compiled run-record step — ``_normalize_step`` preserves dispatch_context
    but drops the raw ``invokes`` bag), falling back to ``invokes.backend_op``
    for any pre-normalize/raw step shape. Returns None when neither is present;
    a None op is NOT rejected (steps may legitimately carry no op).
    """
    dc = step.get("dispatch_context") or {}
    inv = step.get("invokes") or {}
    return dc.get("backend_op") or inv.get("backend_op")


def _default_launch_fn(step_id: str, attempt: int = 0) -> None:
    """Default agent-launch: a no-op recorder.

    The real launch is injected by U5's driver — a wrapper around an ``Agent``
    ``run_in_background`` dispatch whose prompt instructs the spawned agent to
    call ``run_record.record_verdict(... attempt=attempt)`` on completion (the durable
    self-write, tagged with the dispatch generation — Bug #6). For U10 (and tests)
    this default does nothing observable; the dispatch_batch return value is what
    tests assert against.

    Signature note (contract): ``launch_fn`` takes ``(step_id, attempt)`` so the
    agent can carry its attempt generation into the verdict (Bug #6). This is the
    ONE signature — ``dispatch_batch`` calls ``launch_fn(uid, next_attempt)``
    directly. (A prior ``_invoke_launch`` inspect.signature shim tolerated a
    legacy single-arg launcher; it was deleted because the single-arg branch
    silently dropped the attempt tag, weakening attempt-identity.)
    """
    return None


def dispatch_batch(repo_root, run_id, step_ids, cap, *, launch_fn=None):
    """Mark up to ``cap`` of ``step_ids`` pending->dispatched and launch each.

    Behavior (per the U10 contract):

      * ``cap`` is supplied by the AGENT PER CALL — it is NOT a constant. 16 when
        idle, 3 when grinding, 1 to serialize a probe, 0 to dispatch nothing.
        ``cap`` is a per-wave decision; resizing happens BETWEEN calls.
      * Selection: take ``step_ids`` in the order given, keep only those whose
        current state is ``pending`` (the idempotency guard — any non-pending
        step, e.g. already ``dispatched``, is REJECTED and skipped, never
        double-launched), and truncate the eligible set to ``cap``.
      * For each selected step: ``transition(... "dispatched", dispatched_at=now,
        attempt=current+1)`` FIRST (which inherits I-1 atomicity + flock from
        run_record.py, and bumps the Bug #6 attempt counter in the SAME atomic
        snapshot), THEN call ``launch_fn(step_id, attempt)``. Transition-before-
        launch ordering is deliberate: a launch with no recorded dispatch would
        orphan the eventual verdict.
      * Bug #8 — the ``launch_fn`` call is wrapped in a PER-STEP try/except. A
        launch raise marks the step ``stalled`` (``dispatched -> stalled`` with
        ``last_error = {call:"launch", ...}``), records ``"launch-failed:..."`` in
        the results, and CONTINUES the wave — it does NOT leave a phantom
        ``dispatched`` step with no agent, and does NOT abandon the rest of the
        batch by propagating the raise.

    Per-step results are returned as a list of ``(step_id, status)`` tuples where
    status is ``"dispatched"``, ``"rejected:<reason>"``, or
    ``"launch-failed:<class>:<msg>"`` — so callers/tests can assert the precise
    outcome of a mixed batch (some pending, some already in flight, some whose
    launch raised). The rejection is per-step, NOT fail-fast: a stray
    already-dispatched step in the list does not block the genuinely-pending ones,
    and one step's launch failure does not abandon the rest of the wave.

    Idempotency note: an already-``dispatched`` step fails the
    ``pending -> dispatched`` grammar edge in run_record.py (``transition`` raises
    ``InvalidTransition``), so even a race that slips past the pre-filter cannot
    produce a second ``dispatched_at`` — the transition is the authoritative
    guard, the pre-filter is just to avoid a pointless write attempt.
    """
    if cap is None or int(cap) < 0:
        raise DispatcherError(f"cap must be a non-negative int, got {cap!r}")
    cap = int(cap)
    if launch_fn is None:
        launch_fn = _default_launch_fn

    run_record = read_run_record(repo_root, run_id)
    by_id = _steps_by_id(run_record)

    results = []
    dispatched_count = 0
    for uid in step_ids:
        step = by_id.get(uid)
        if step is None:
            results.append((uid, "rejected:unknown-step"))
            continue
        if step.get("state") != "pending":
            # Idempotency guard: already dispatched / verdict-returned / etc.
            results.append((uid, f"rejected:not-pending({step.get('state')})"))
            continue
        op = _step_backend_op(step)
        if op is not None and op not in VALID_BACKEND_OPS:
            # A declared-but-unknown backend_op (typo in a workflow, or a hand-
            # crafted step) must NOT flow to launch — reject it per-step,
            # mirroring the not-pending path. Checked BEFORE the cap so a bad op
            # surfaces eagerly rather than being deferred as "over-cap".
            results.append((uid, "rejected:bad-backend-op"))
            continue
        if dispatched_count >= cap:
            # Eligible but over the agent-chosen cap for THIS wave; left pending
            # for a later wave's dispatch_batch call.
            results.append((uid, "rejected:over-cap"))
            continue

        # Transition FIRST (records dispatched_at; the attempt counter is bumped
        # MECHANICALLY by transition() itself on the pending->dispatched edge — P2
        # — so we no longer rely on this call site passing the right attempt by
        # convention), then launch. If the transition raises (e.g. a concurrent
        # dispatch beat us to it), record the rejection and DO NOT launch. The
        # attempt increment is part of the SAME atomic snapshot as the state change
        # (Bug #6) — never a separate write, which would reopen a race between the
        # bump and the dispatch. We still compute next_attempt to pass to launch_fn
        # (the agent carries it into its verdict); transition() reconciles it via
        # max(current+1, passed) so the launched attempt and the stored counter
        # agree even though the bump is now enforced engine-side.
        next_attempt = int(step.get("attempt", 0) or 0) + 1
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

        # Bug #8: guard the real I/O per-step. A launch raise must NOT leave the
        # step a phantom `dispatched` with no agent, NOR abandon the rest of the
        # wave. Mark the step stalled (dispatched -> stalled, reusing the existing
        # grammar edge) with a launch-failure last_error, record the failure, and
        # CONTINUE. The operator can /auto-resume retry it; the burnt attempt
        # is already recorded in the attempt counter.
        try:
            launch_fn(uid, next_attempt)
        except Exception as exc:  # noqa: BLE001 — any launch raise is recorded.
            err = {
                "call": "launch",
                "message": f"{type(exc).__name__}: {exc}",
                "at": _now_iso(),
            }
            try:
                _transition(repo_root, run_id, uid, "stalled", last_error=err)
            except Exception:  # noqa: BLE001 — P3: broadened from (InvalidTransition,
                # RunRecordError). The rescue transition does real I/O (flock + atomic
                # write); a raw OSError from the rescue's own flock (e.g. the lock
                # file vanished, a disk error) is NOT an InvalidTransition/RunRecordError
                # and would otherwise propagate, re-abandoning the entire wave —
                # precisely the failure Bug #8's guard exists to prevent. The rescue
                # is best-effort: even if it cannot mark the step stalled, we record
                # the launch failure and keep the wave going.
                pass
            results.append(
                (uid, f"launch-failed:{type(exc).__name__}:{exc}")
            )
            continue

        dispatched_count += 1
        results.append((uid, "dispatched"))

    return results


# ──────────────────────────────────────────────────────────────────────────
# Converge — the RECONCILE/READ step. This path uses ONLY read_run_record.
# It NEVER writes the run-record (the durability property: agents self-write
# verdicts; converge merely reads what is already durable on disk).


def converge(repo_root, run_id):
    """Reconcile durable run-record state into a cheap summary for the driver.

    A RECONCILE/READ step over durable per-step state — NOT the verdict-writer.
    Each dispatched background agent has already self-written its own verdict via
    ``run_record.record_verdict`` (atomic, I-1) the moment it finished. converge just
    READS the run-record fresh off disk and classifies steps, so a resumed session
    (one whose driving process died after agents completed) sees completed
    verdicts straight from disk and does NOT re-dispatch them.

    Returns a summary dict::

        {
          "in_flight":  [ids still "dispatched" (no verdict yet)],
          "completed":  [ids whose agent self-wrote a verdict: state in
                         {"verdict-returned","fixed"}],
          "stalled":    [ids in "stalled"],
          "terminal":   [ids where step_is_terminal(u) is True],
          "all_steps_terminal": bool (read from the cached predicate — NOT
                         re-derived; honors feedback_loop_monitor_terminal_state_field),
          "met": bool (the cached exit predicate; read, never recomputed here),
        }

    The fresh-read property is the load-bearing one: between two converge calls,
    state written by ANOTHER process (an agent self-writing a verdict) is picked
    up — converge holds no in-memory batch state across calls.
    """
    run_record = read_run_record(repo_root, run_id)
    # Read the run's scale ONCE; the per-step terminality classification below
    # must use the SAME scale-aware gating decision as the cached predicate (Bug
    # #3 — a scale-blind _step_is_terminal(step) here would mark a blocker-only
    # run's major-only step non-terminal, contradicting the met=True the predicate
    # reports and confusing the driver about done-ness).
    scale = run_record.get("backend_scale", "three-tier")

    in_flight = []
    completed = []
    stalled = []
    terminal = []
    for step in run_record.get("steps", []):
        state = step.get("state")
        if state == "dispatched":
            in_flight.append(step["id"])
        elif state in ("verdict-returned", "fixed"):
            completed.append(step["id"])
        elif state == "stalled":
            stalled.append(step["id"])
        if _step_is_terminal(step, scale):
            terminal.append(step["id"])

    pred = run_record.get("exit_predicate_result") or {}
    return {
        "in_flight": in_flight,
        "completed": completed,
        "stalled": stalled,
        "terminal": terminal,
        "all_steps_terminal": bool(pred.get("all_steps_terminal", False)),
        "met": bool(pred.get("met", False)),
    }


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/dispatcher.sh routes through this). Positional argv only;
# never string-interpolated into a shell ($ARGUMENTS-safe — the $-logic lives
# in the .sh shim, never in a command .md body).


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: dispatcher.py <subcommand> ...\n")
        return 2
    cmd = argv[0]
    try:
        if cmd == "ready":
            repo, run = argv[1], argv[2]
            for uid in ready_steps(repo, run):
                print(uid)
            return 0
        if cmd == "dispatch":
            # dispatch <repo> <run> <cap> <step_id...>
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
        sys.stderr.write(f"dispatcher.py: unknown subcommand {cmd!r}\n")
        return 2
    except (DispatcherError, RunRecordError) as e:
        sys.stderr.write(f"dispatcher.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"dispatcher.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
