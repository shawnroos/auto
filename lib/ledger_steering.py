#!/usr/bin/env python3
"""auto ledger steering: the AGENT-FACING write verbs (R3/R5/R20/R21).

The steering layer of the ledger surface. Where ``ledger_mutators`` holds the
engine's own scalar mutators, this module holds the verbs a DRIVING AGENT calls to
reshape a live run: retire an obsolete step, add newly-discovered work, re-wire a
dependency, and join the ownership set that the PreToolUse hooks gate on.

Extracted from ``ledger_mutators`` when that file crossed the 1000-LOC budget. The
split is conceptual, not merely mechanical: these four verbs are the surface the
agent-native runtime exposes as tools, and they share one contract —

    read freely; write only through a verb that revalidates its precondition
    INSIDE the flock and can REJECT.

Every verb here wraps precondition + mutate + predicate-recompute in a single
``ledger_core._with_locked_ledger`` call (I-1 / KTD-2). The model never holds the
lock and never does a read-then-write across two invocations, so a slow agent
deciding against a stale snapshot has its write rejected rather than merged.
``tests/unit/steering-verbs.test.sh`` asserts that structurally, per verb, via AST.

Sits ABOVE ledger_mutators in the acyclic DAG
(core ← mutators ← steering ← facade): imports ledger_core for the lock primitive
and errors, and ledger_mutators for the two graph helpers ``add_step`` /
``reshape_deps`` reuse (``_sanitize_enumerated_depends_on``,
``_find_depends_on_back_edge``) rather than hand-rolling a second sanitizer or
cycle detector. Imports NOTHING from producers or the facade.
"""

from __future__ import annotations

import os
import sys

# Same bootstrap-loader rationale as ledger_mutators: the ledger surface is loaded
# from many sites by file path (spec_from_file_location does NOT add lib/ to
# sys.path), so a plain `import ledger_core` is not guaranteed to resolve.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import AGENT_SESSIONS_KEY, load_lib_module  # noqa: E402

ledger_core = load_lib_module("ledger_core")
ledger_mutators = load_lib_module("ledger_mutators")

# The two graph helpers add_step / reshape_deps reuse. Bound at import so the
# moved function bodies read exactly as they did in ledger_mutators.
_sanitize_enumerated_depends_on = ledger_mutators._sanitize_enumerated_depends_on
_find_depends_on_back_edge = ledger_mutators._find_depends_on_back_edge




# States from which force_skip may retire a step. This is a force_skip-ONLY
# transition set, deliberately WIDER than ALLOWED_TRANSITIONS (which governs the
# reason-free `transition()` path). It is NOT added to ALLOWED_TRANSITIONS
# because doing so would let `transition()` reach `terminal-skip` with no reason
# — exactly what the mandatory-reason guard below exists to prevent. Precisely
# the asymmetry `_VERDICT_WRITABLE_STATES` uses for findings.
#
#   * pending          — retire work that was never dispatched (the obsolete-step
#                        case; before U2 an agent had to contrive a stall).
#   * verdict-returned — retire work whose verdict is superseded.
#   * stalled          — the pre-existing human `auto-resume.py skip` source,
#                        which reaches terminal-skip via plain `transition()`.
_FORCE_SKIP_SOURCE_STATES = frozenset({"pending", "verdict-returned", "stalled"})


def force_skip(repo_root, run_id, step_id, reason):
    """Agent-driven force-skip: <state> -> terminal-skip, with a mandatory reason.

    The steering verb behind R3/R20, and the ONLY producer of the
    `pending -> terminal-skip` / `verdict-returned -> terminal-skip` edges. An
    agent that judges a step obsolete no longer has to contrive a dispatch
    timeout to retire it.

    ``reason`` is REQUIRED and must be non-blank (R20) — a skip is auditable,
    never silent. It is stored on the step as ``skip_reason`` and rendered by
    /auto-status. A blank/absent reason raises LedgerError and writes nothing.
    Because the edges live in ``_FORCE_SKIP_SOURCE_STATES`` rather than
    ALLOWED_TRANSITIONS, the reason cannot be bypassed by calling `transition()`.

    I-1 (KTD-2): the precondition check, the mutation, and the predicate
    recompute all happen inside ONE ``_with_locked_ledger`` call, so a slow agent
    deciding against a stale snapshot has its write REJECTED rather than merged.
    This function performs no ledger read or write outside that closure; the
    steering-verbs test asserts that structurally.

    Does NOT bury findings: a skipped step keeps its ``findings``, and
    ``_count_severities_by_step`` counts them regardless of state, so a blocker on
    a force-skipped step still holds ``met`` false (AE5). A never-dispatched step
    carries no findings, so skipping it CAN clear the predicate — deliberate;
    the done-floor is "no open gating findings" (R16), not "all work performed."
    """
    if reason is None or not str(reason).strip():
        raise ledger_core.LedgerError(
            f"force_skip requires a non-blank reason for step {step_id!r} (R20)"
        )
    clean_reason = str(reason).strip()

    def mutate(ledger):
        step = ledger_core._find_step(ledger, step_id)
        current = step.get("state")
        if current not in _FORCE_SKIP_SOURCE_STATES:
            raise ledger_core.InvalidTransition(
                f"{current!r} -> 'terminal-skip' not permitted for step {step_id!r}"
            )
        step["state"] = "terminal-skip"
        step["skip_reason"] = clean_reason
        return step["state"]

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def add_step(repo_root, run_id, step_id, depends_on=None, phase=None):
    """Agent-driven step insertion: append a NEW pending step under flock (R3).

    The steering verb behind R3 (an agent that discovers the plan needs one more
    step of work adds it directly, instead of re-running the plan phase). The new
    step is built through ``ledger_core._normalize_step`` — it enters the ledger
    with the SAME shape as an init-time or enumerate-time step (state defaults to
    ``pending``, the full findings/depends_on/attempt/skip_reason/… key set
    present), so no downstream reader has to special-case an agent-added step. We
    do NOT hand-assemble the step dict; the one step-builder is the SSOT for shape.

    I-1 (KTD-2): the duplicate-id check, the depends_on sanitize, the normalize
    and the append all run inside ONE ``_with_locked_ledger`` call, and the
    predicate is recomputed in that same atomic snapshot. A slow agent adding a
    step against a stale view has its write REVALIDATED and REJECTED rather than
    merged; this function performs no ledger read or write outside that closure
    (the steering-verbs lock-discipline test asserts this structurally).

    Two invariants, both enforced INSIDE the lock because either violation would
    otherwise wedge the run:
      * DUPLICATE id → rejected. Two steps sharing an id make ``_find_step``
        ambiguous (it returns the first match) and every id-keyed write becomes
        nondeterministic — that is corruption, not a recoverable stall, so we
        raise and write nothing.
      * a ``depends_on`` edge to an UNKNOWN step → rejected. Unlike
        ``set_enumerated_steps`` (which DROPS bad edges because it validates a
        whole BATCH of model output, where a raise would materialize zero work
        steps — itself a stall), ``add_step`` is a single DELIBERATE add: a bad
        edge is a caller mistake we surface loudly, not silently repair. A
        dangling edge would leave the step permanently un-``_is_ready``
        (``dep is None -> False``) — the exact silent-livelock class the
        enumerate sanitizer exists to catch — so we REUSE that sanitizer
        (``_sanitize_enumerated_depends_on``) rather than duplicate its logic and
        turn any dropped edge into a hard reject. A self-edge is reported by the
        sanitizer as ``self`` and likewise rejected (a step depending on itself
        is never ready).

    New steps are always ``pending`` — the ONLY legal birth state (every other
    state is reached along the §3 grammar). ``depends_on`` defaults to empty;
    ``phase`` defaults to ``_normalize_step``'s run-phase-derived default
    (``"work"`` outside a plan phase).
    """
    deps = list(depends_on or [])

    def mutate(ledger):
        steps = ledger.setdefault("steps", [])
        existing_ids = {u.get("id") for u in steps}
        # DUPLICATE id: reject before any write — a colliding id is corruption
        # (ambiguous _find_step), not a stall we can repair by dropping.
        if step_id in existing_ids:
            raise ledger_core.LedgerError(
                f"cannot add step {step_id!r}: id already exists"
            )
        # Reuse the enumerate-path sanitizer as the ONE depends_on validator, but
        # in REJECT mode: a single deliberate add surfaces a bad edge loudly
        # rather than silently dropping it (the batch path's divergent choice).
        sanitized, dropped = _sanitize_enumerated_depends_on(
            [{"id": step_id, "depends_on": deps}], existing_ids
        )
        if dropped:
            _u, dep, reason = dropped[0]
            raise ledger_core.LedgerError(
                f"cannot add step {step_id!r}: depends_on edge to {dep!r} is "
                f"{reason} (must name an existing step, and not itself)"
            )
        clean_deps = sanitized[0].get("depends_on", [])
        # Normalize through the ONE step-builder so an agent-added step is shape-
        # identical to an init/enumerate step (do NOT hand-build the dict).
        loop_phase = ledger.get("loop_phase", "plan")
        raw = {"id": step_id, "state": "pending", "depends_on": clean_deps}
        if phase is not None:
            raw["phase"] = phase
        steps.append(ledger_core._normalize_step(raw, loop_phase=loop_phase))
        return step_id

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def reshape_deps(repo_root, run_id, step_id, depends_on):
    """Agent-driven dependency rewrite: REPLACE a step's ``depends_on`` under flock
    (R3).

    The steering verb behind R3 (an agent that learns step X must actually wait
    on step Y rewires the graph directly). ``depends_on`` fully REPLACES the
    step's prior edge list — a merge would make the new complete set the agent
    states unexpressible.

    I-1 (KTD-2): the step lookup, the unknown-dep + cycle checks and the write
    all run inside ONE ``_with_locked_ledger`` call, predicate recomputed in the
    same snapshot. A reshape decided against a stale graph is REVALIDATED and
    REJECTED, never merged; no ledger read/write happens outside the closure
    (asserted by the steering-verbs lock-discipline test).

    Two rejections, both guarding readiness liveness:
      * an edge to an UNKNOWN step → rejected. A dangling dep leaves the step
        permanently un-``_is_ready`` (``dep is None -> False``); same class
        ``set_enumerated_steps`` sanitizes away, but a deliberate single reshape
        surfaces it loudly. On rejection the ledger is untouched.
      * a change that would introduce a CYCLE → rejected. A cycle makes every
        step on it mutually-unsatisfiable → never ready, never dispatched → a
        silent full-run livelock. The check runs the SHARED detector
        (``_find_depends_on_back_edge``) over the WHOLE step graph with THIS
        step's edges swapped to the proposed set — because a reshape can close a
        cycle THROUGH OTHER steps (e.g. A->B already exists; reshaping B->A
        closes it), the batch-internal-only view ``set_enumerated_steps`` uses is
        insufficient here, so we widen the graph but reuse the detector verbatim
        (no second hand-rolled cycle finder). A self-edge is the degenerate
        1-cycle and is caught by the same detector.
    """
    proposed = list(depends_on or [])

    def mutate(ledger):
        step = ledger_core._find_step(ledger, step_id)  # raises UnknownStep
        steps = ledger.get("steps", [])
        all_ids = {u.get("id") for u in steps}
        # UNKNOWN-dep guard: every proposed edge must name a real step, else the
        # reshaped step can never become ready.
        for d in proposed:
            if not isinstance(d, str) or d not in all_ids:
                raise ledger_core.LedgerError(
                    f"cannot reshape {step_id!r}: depends_on edge to {d!r} names "
                    f"no existing step"
                )
        # CYCLE guard: build the full dependency graph with this step's edges
        # REPLACED by the proposed set, then run the SHARED back-edge detector.
        # Every step id is a node key, and edges are restricted to known ids, so
        # the detector never indexes a non-node (its `v not in adj` leaf guard is
        # a no-op here). Reused verbatim — no divergent second cycle detector.
        adj = {}
        for u in steps:
            uid = u.get("id")
            edges = proposed if uid == step_id else (u.get("depends_on") or [])
            adj[uid] = [d for d in edges if d in all_ids]
        back = _find_depends_on_back_edge(adj)
        if back is not None:
            raise ledger_core.LedgerError(
                f"cannot reshape {step_id!r}: the change introduces a dependency "
                f"cycle (back edge {back[0]!r} -> {back[1]!r})"
            )
        step["depends_on"] = proposed
        return proposed

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


_MAX_AGENT_SESSIONS = 256


def register_session(repo_root, run_id, session_id):
    """Join ``session_id`` to the run's OWNERSHIP SET (U8 / R21 / KTD-7).

    A dispatched phase sub-agent calls this on start. Both PreToolUse hooks then
    gate it by membership of ``{driving_session_id} ∪ agent_session_ids`` instead
    of scalar equality against the boss's session — which is why the fail-closed
    destructive backstop now fires inside the sub-agent tree, where the ``fix``
    phase writes code and runs Bash.

    Membership is opt-IN by registration, never by co-location: an unrelated
    Claude session running in the same worktree is in neither key and is never
    gated (the "standalone ce-skill is not captured" dimension is preserved).

    Idempotent — re-registering an already-present id is a no-op, so a sub-agent
    that retries its own start does not grow the set. Bounded at
    ``_MAX_AGENT_SESSIONS`` so a pathological re-dispatch loop cannot grow the
    ledger without limit; the oldest entry is evicted first.

    EVICTION IS A FIFO HEURISTIC, NOT A LIVENESS GUARANTEE (adversarial/security
    review, v0.13.0). The oldest-registered id is the one MOST LIKELY already
    complete, so FIFO is a reasonable proxy for "drop the dead one" — but it is a
    proxy. A sub-agent registers ONCE at start (not per command), so a still-live
    early agent that is evicted after ``_MAX_AGENT_SESSIONS`` later distinct
    registrations falls out of the set and the destructive backstop goes dark for
    it, reverting to the prompt-carried constraints (§4.6) as the only guard. The
    cap is set well above a realistic run's session count (fan-out cap 16 per
    wave, idempotent retries don't grow the set), so eviction should never fire in
    a normal run; if it does, that run is anomalous. This is defense-in-depth
    against a MISBEHAVING agent, not a sandbox against a MALICIOUS one — an agent
    with Bash can edit the ledger JSON directly regardless.

    I-1: read + membership check + append happen inside ONE
    ``_with_locked_ledger`` call. Two sub-agents registering concurrently
    serialize; neither loses the other's id.

    CALLER-TRUST: the CLI verb accepts an arbitrary ``session_id`` arg, so it is
    the CALLER's responsibility to pass its OWN id — the §4.8 dispatch contract
    has each sub-agent register ``$CLAUDE_CODE_SESSION_ID`` (its own env id), so a
    sub-agent only ever adds ITSELF. A process that passes a third party's id
    could gate that bystander (a DoS, not a destructive-command bypass); the
    env-derived contract is the mitigation.

    Does NOT touch ``driving_session_id`` — the boss remains the primary owner,
    and only the boss's session is exempt from the action gate's operator-pause
    carve-out (see on-pretooluse-action.py::_owns_session).
    """
    if not session_id or not isinstance(session_id, str):
        raise ledger_core.LedgerError(
            f"register_session requires a non-empty session_id string: {session_id!r}"
        )

    def mutate(ledger):
        existing = ledger.get(AGENT_SESSIONS_KEY)
        if not isinstance(existing, list):
            existing = []
        if session_id not in existing:
            existing.append(session_id)
            if len(existing) > _MAX_AGENT_SESSIONS:
                existing = existing[-_MAX_AGENT_SESSIONS:]
        ledger[AGENT_SESSIONS_KEY] = existing
        return list(existing)

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)
