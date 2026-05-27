#!/usr/bin/env python3
"""auto ledger mutators: grammar-checked, flock-serialized write paths.

The mutation layer of the ledger surface (see lib/ledger.py for the facade and
docs/contracts/ledger-schema.md for the authoritative spec). Every function here
routes through ``ledger_core._with_locked_ledger`` (the one RMW primitive), which
recomputes the predicate in the SAME atomic snapshot as the write (I-1). Each is a
single-purpose mutator: ``transition``, ``record_verdict``, ``set_loop``,
``set_gaps_open``, ``set_enumerated_units``, ``set_winner_unit_id``,
``set_verdict_decision``, ``set_bound_override``, ``set_exit_reason``,
``accumulate_active_time``, ``increment_iteration_attempts``.

Sits ABOVE ledger_core in the acyclic DAG (core ← mutators ← emitters ← facade):
imports ledger_core for constants, errors, the lock primitive, and the pure
helpers; imports NOTHING from emitters or the facade.
"""

from __future__ import annotations

import os
import sys

# Import ledger_core via the standard bootstrap loader (mirrors emitters.py).
# The ledger surface is loaded from many sites by file path (the test harness
# uses spec_from_file_location, which does NOT add lib/ to sys.path), so a plain
# `import ledger_core` is not guaranteed to resolve. Prepending lib/ + routing
# through _bootstrap.load_lib_module is the one robust load strategy the codebase
# already uses for sibling modules.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

ledger_core = load_lib_module("ledger_core")


def transition(repo_root, run_id, unit_id, new_state, **fields):
    """Grammar-checked unit state change under flock.

    Rejects any transition not in ALLOWED_TRANSITIONS (raises InvalidTransition;
    the ledger is NOT written). Optional ``fields`` update unit attributes in the
    same write (e.g. dispatched_at, last_error). Predicate recomputed + atomic.

    NOTE: ``record_verdict`` is the dedicated path for dispatched -> verdict-returned
    (it owns findings semantics). ``transition`` can also perform it but does NOT
    touch findings; callers writing findings should use ``record_verdict``.
    """
    if new_state not in ledger_core.UNIT_STATES:
        raise ledger_core.InvalidTransition(f"unknown target state {new_state!r}")

    def mutate(ledger):
        unit = ledger_core._find_unit(ledger, unit_id)
        current = unit.get("state")
        if new_state not in ledger_core.ALLOWED_TRANSITIONS.get(current, set()):
            raise ledger_core.InvalidTransition(
                f"{current!r} -> {new_state!r} not permitted for unit {unit_id!r}"
            )
        unit["state"] = new_state
        # stalled -> pending (retry) clears last_error per the contract.
        if current == "stalled" and new_state == "pending":
            unit["last_error"] = None
        # Capture the dispatch-generation counter BEFORE the fields loop (which may
        # itself carry an explicit attempt=) so the mechanical bump below reconciles
        # against the PRE-transition value, not a value the loop just wrote.
        prev_attempt = int(unit.get("attempt", 0) or 0)
        for key, value in fields.items():
            if key == "findings":
                raise ledger_core.LedgerError(
                    "use record_verdict() to write findings, not transition()"
                )
            unit[key] = value
        # Bug #6 (attempt-identity), made MECHANICAL (P2): the dispatch generation
        # counter MUST advance on every pending -> dispatched edge, in the SAME
        # atomic snapshot as the state change. We bump it HERE — at the transition
        # itself — rather than relying on the caller (dispatch_batch) to pass the
        # right ``attempt=`` value by convention. That convention was a latent
        # stale-verdict-clobber hole: any future re-dispatch path that forgot to
        # bump would let a superseded attempt's verdict overwrite the live one. By
        # enforcing the increment at the only edge that creates a new dispatch
        # generation, no caller can re-open Bug #6. We reconcile against an explicit
        # attempt= the caller may have passed: the counter becomes max(prev+1,
        # passed) so the dispatch_batch path (which passes prev+1) stays exactly
        # consistent, a caller that passes nothing still advances by one, and a
        # stale/lower explicit value can never lower the counter. Crucially we use
        # the PRE-loop ``prev_attempt`` — the fields loop above may have written the
        # passed value into ``unit["attempt"]`` already, so reading it back would
        # double-count.
        if current == "pending" and new_state == "dispatched":
            passed = fields.get("attempt")
            unit["attempt"] = max(
                prev_attempt + 1,
                int(passed) if passed is not None else 0,
            )
        return unit["state"]

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


# States from which record_verdict may write a verdict. This is a record_verdict
# -ONLY transition set, deliberately WIDER than ALLOWED_TRANSITIONS (which governs
# the findings-free `transition()` path). It is NOT added to ALLOWED_TRANSITIONS
# because doing so would let `transition()` move state without findings — exactly
# what the "use record_verdict() to write findings" guard blocks.
#
#   * dispatched        — the normal first verdict self-write (§3 grammar edge).
#   * verdict-returned   — a re-verdict (the re-review path; latest-only findings).
#   * stalled            — Bug #7 RECOVERY: a healthy-but-slow review that was
#                          marked `stalled` past stall_threshold_seconds finishes
#                          and self-writes a GENUINE verdict. That is real work;
#                          throwing it away (InvalidTransition, silently) loses a
#                          completed verdict AND leaves last_error null so it looks
#                          identical to a true timeout. We RECOVER it instead. The
#                          attempt-identity check (Bug #6) still rejects a recovery
#                          from a SUPERSEDED attempt (an operator retried, a fresh
#                          agent already verdicted), so a stale late verdict from a
#                          retried-past attempt is NOT recovered.
_VERDICT_WRITABLE_STATES = frozenset({"dispatched", "verdict-returned", "stalled"})


def record_verdict(repo_root, run_id, unit_id, findings, attempt=None):
    """{dispatched, verdict-returned, stalled} -> verdict-returned: OVERWRITE
    findings + set verdict_at.

    This is the background-agent verdict-self-write path (U10). It is the ONLY
    writer of ``findings[]`` (§4.2). ``findings`` fully REPLACES the prior array.
    Predicate recomputed in the same atomic snapshot (I-1).

    ``attempt`` (Bug #6 — attempt-identity): the dispatch generation the verdict is
    written FOR. The orchestrator increments a unit's ``attempt`` on each
    pending->dispatched dispatch; a background agent launched for attempt N carries
    N here. A verdict whose ``attempt`` is OLDER than the unit's current ``attempt``
    is REJECTED (``StaleVerdict``) — it is a stale verdict from a SUPERSEDED attempt
    (e.g. a slow agent A stalled, the operator retried, agent B was dispatched as a
    fresh attempt and verdicted; A then finishes and tries to clobber B's verdict
    with stale findings). ``attempt=None`` skips the check (back-compat: callers /
    tests that do not track attempts behave exactly as before). Equal-attempt is
    ACCEPTED (the legitimate re-review / recovery path).

    Bug #7 (late-verdict recovery): a genuine verdict arriving from a unit currently
    in ``stalled`` is RECOVERED to verdict-returned (it is real work — see
    ``_VERDICT_WRITABLE_STATES``), UNLESS Bug #6's attempt check rejects it as
    stale. The two interact: recovery is only for the CURRENT attempt; a late
    verdict from a superseded attempt is still rejected, never recovered.
    """
    norm = []
    for f in findings or []:
        sev = f.get("severity")
        if sev not in ledger_core.SEVERITIES:
            raise ledger_core.LedgerError(f"invalid finding severity: {sev!r}")
        norm.append({"severity": sev, "note": f.get("note", "")})

    skip_attempt = ledger_core._test_hatch_enabled("CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK")
    skip_recovery = ledger_core._test_hatch_enabled("CLAUDE_AUTO_TEST_NO_STALLED_RECOVERY")

    def mutate(ledger):
        unit = ledger_core._find_unit(ledger, unit_id)
        current = unit.get("state")

        # Bug #6: reject a verdict from a superseded attempt BEFORE any write. This
        # is checked first so a stale late verdict is never recovered (it interacts
        # with Bug #7's recovery: only a current-attempt late verdict recovers).
        if not skip_attempt and attempt is not None:
            cur_attempt = int(unit.get("attempt", 0) or 0)
            if int(attempt) < cur_attempt:
                raise ledger_core.StaleVerdict(
                    f"verdict for unit {unit_id!r} carries attempt {attempt} "
                    f"but current attempt is {cur_attempt} — superseded; rejected"
                )

        # Bug #7: a stalled unit's GENUINE late verdict is recoverable. The
        # deliberate-fail hatch forces the old (pre-fix) check that ONLY permitted
        # dispatched/verdict-returned, so a late verdict from a stalled unit is
        # lost to InvalidTransition.
        writable = (
            {"dispatched", "verdict-returned"}
            if skip_recovery
            else _VERDICT_WRITABLE_STATES
        )
        if current not in writable:
            raise ledger_core.InvalidTransition(
                f"{current!r} -> 'verdict-returned' not permitted for unit {unit_id!r}"
            )

        unit["state"] = "verdict-returned"
        unit["findings"] = norm
        unit["verdict_at"] = ledger_core._now_iso()
        # A recovered late verdict is real work — clear any stale last_error so the
        # unit no longer looks like an unresolved timeout/raise.
        unit["last_error"] = None
        return norm

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_loop(
    repo_root,
    run_id,
    *,
    loop_phase=None,
    seam_paused=None,
    driver=None,
    beat=False,
    plan_step=ledger_core._UNSET,
):
    """Update loop-level phase / liveness / plan-step fields (U4's tick uses this).

    ``beat=True`` stamps ``loop.last_beat_at`` to now. Predicate recomputed +
    atomic (a phase change can flip ``met`` via the plan-loop gaps clause).

    ``plan_step`` uses an UNSET sentinel default (NOT ``None``) because ``null``
    is itself a valid stored plan_step (the initial "no step yet"). Omit it to
    leave the field unchanged; pass ``plan_step=None`` to clear it, or a step
    name (``"plan"`` / ``"deepen"`` / ``"review_plan"``) to record it. The tick
    calls this with the step it just ran so the NEXT (fresh-process) tick is not
    amnesiac — the anti-livelock persist (schema §3.1). In the plan phase
    ``plan_step`` feeds the predicate (plan-met requires ``plan_step ==
    "review_plan"``), so persisting it can flip ``met`` — the recompute on this
    write reflects that.
    """
    if loop_phase is not None and loop_phase not in ledger_core.LOOP_PHASES:
        raise ledger_core.LedgerError(f"invalid loop_phase: {loop_phase!r}")
    if driver is not None and driver not in ("self", "manual"):
        raise ledger_core.LedgerError(f"invalid driver: {driver!r}")
    if (
        plan_step is not ledger_core._UNSET
        and plan_step is not None
        and plan_step not in ledger_core.PLAN_STEPS
    ):
        raise ledger_core.LedgerError(f"invalid plan_step: {plan_step!r}")

    def mutate(ledger):
        if loop_phase is not None:
            ledger["loop_phase"] = loop_phase
        if seam_paused is not None:
            ledger["seam_paused"] = bool(seam_paused)
        if plan_step is not ledger_core._UNSET:
            ledger["plan_step"] = plan_step
        loop = ledger.setdefault("loop", {})
        if driver is not None:
            loop["driver"] = driver
        if beat:
            loop["last_beat_at"] = ledger_core._now_iso()
        return ledger["loop_phase"]

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_gaps_open(repo_root, run_id, gaps_open: int):
    """Persist the plan-loop open-gap count from ``review_plan``'s return (U4's
    tick uses this). The engine reads ONLY the gap-set length and writes it here
    (adapter-contract §2.2 / §5).

    The value is written into ``exit_predicate_result.gaps_open`` BEFORE the
    atomic-write recompute reads it back, so the freshly-recomputed predicate
    reflects the new gap count in the SAME snapshot (I-1). ``recompute_predicate``
    preserves the prior cached ``gaps_open`` precisely so this mutator can seed
    it; this is the ONLY writer of a non-null value. Until it runs, gaps_open is
    null (Bug #5 — null means "no real review reported gaps yet" and is distinct
    from 0; plan-met requires a non-null zero, so a freshly-prepared-but-unfilled
    review can never satisfy it).
    """
    n = int(gaps_open)
    if n < 0:
        raise ledger_core.LedgerError(f"gaps_open must be >= 0, got {n}")

    def mutate(ledger):
        epr = ledger.setdefault("exit_predicate_result", {})
        epr["gaps_open"] = n
        return n

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_enumerated_units(repo_root, run_id, unit_id, enumerated):
    """Persist a plan unit's ``enumerate_plan_units`` output onto its
    ``dispatch_context.enumerated_units`` (v0.2.0 U6, the producer-persist).

    Called at plan-done with the adapter's enumerated work-unit list. The
    phase-transition emitter (U5b) reads it from here when emitting work units —
    so this is the on-ledger bridge between "the plan finished" and "here are its
    work units," resolving F4 (v0.1.x had no in-code producer). ``enumerated`` is
    a list of partial unit dicts (each at least an ``id``). Raises if the named
    unit doesn't exist. Atomic (predicate recompute is a no-op here — the plan
    unit's own state is unchanged — but the write stays on the I-1 path).
    """
    if not isinstance(enumerated, list):
        raise ledger_core.LedgerError("enumerated units must be a list")

    def mutate(ledger):
        unit = ledger_core._find_unit(ledger, unit_id)
        dc = unit.setdefault("dispatch_context", {})
        dc["enumerated_units"] = list(enumerated)
        return len(enumerated)

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_winner_unit_id(repo_root, run_id, judge_unit_id, winner_id):
    """Persist an A2 judge's winner pick onto its ``dispatch_context.winner_unit_id``
    (v0.2.0 round-2 P0 fix — fix-pass I).

    A2's ``judge_winner_to_work_units`` emitter needs to know which plan unit won.
    The original design read it from ``findings[].winner_unit_id``, but
    ``record_verdict`` normalizes findings to ``{severity, note}`` only —
    stripping the winner before the emitter ever runs. Production A2 was
    unrunnable end-to-end. dispatch_context is the right home: same channel as
    ``enumerated_units``, preserved by ``transition()`` and the verdict-write
    path, and findings stay narrow.

    The judge agent (or its launcher) calls THIS mutator alongside
    ``record_verdict`` to declare the winner. ``winner_id`` must be a non-empty
    string AND must reference an existing unit id in the ledger (defensive — a
    typo'd winner would surface as a hard error here rather than a confusing
    emitter raise later). Raises if the judge unit doesn't exist or the winner
    is invalid. Atomic (predicate recompute is a no-op here — the judge's own
    state is unchanged — but the write stays on the I-1 path).
    """
    if not isinstance(winner_id, str) or not winner_id:
        raise ledger_core.LedgerError(
            f"winner_id must be a non-empty string, got {winner_id!r}"
        )

    def mutate(ledger):
        judge = ledger_core._find_unit(ledger, judge_unit_id)
        # The eligible-winner set is "every unit except the judge itself"
        # (round-3 P3 promotion — fix-pass J). The previous check accepted
        # the judge naming itself as winner, which would pass the guard, the
        # emitter would call _enumerated_units(judge) which returns [] (judges
        # don't carry enumerated_units), and the run would silently emit no
        # work units — exactly the failure mode the design was trying to
        # prevent ("malformed judge verdict is a hard error, not silent empty
        # emission"). Excluding judge_unit_id from existing_ids tightens the
        # contract to "winner must be SOME OTHER unit" and surfaces the
        # malformed case as the LedgerError it deserves.
        existing_ids = {
            u.get("id") for u in ledger.get("units", [])
        } - {judge_unit_id}
        if winner_id not in existing_ids:
            raise ledger_core.LedgerError(
                f"winner_id {winner_id!r} does not name an eligible unit "
                f"(must differ from judge {judge_unit_id!r}); "
                f"known: {sorted(i for i in existing_ids if i)!r}"
            )
        dc = judge.setdefault("dispatch_context", {})
        dc["winner_unit_id"] = winner_id
        return winner_id

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


# ──────────────────────────────────────────────────────────────────────────
# v0.3.0 (U2): iteration mutators.
#
# These write paths support outcomes-gated emission (KTD §A-D + U2 plan
# section). All share the same atomicity contract as the v0.2.0 mutators:
# each routes through ``ledger_core._with_locked_ledger``, which recomputes the
# predicate (now including ``iteration_pending``) in the SAME atomic snapshot as
# the write (I-1).
#
# Why the surface is wider than round-1 priced: the round-2 doc-review pinned
# three architectural locks (KTD §A control-flow placement, §B predicate
# composition, §C gate-unit re-engagement) that require dedicated mutators
# rather than letting the tick stitch raw writes — see plan U2 §Approach.
#
# The composite/emit paths (emit_within_phase, atomic_iterate_step, etc.) live in
# ledger_emitters.py; this module holds the scalar-field iteration mutators.


def set_verdict_decision(
    repo_root, run_id, gate_unit_id, decision: str, payload=None
):
    """Persist the gate unit's verdict.decision onto its dispatch_context
    (KTD §D / U2). Mirrors the ``set_winner_unit_id`` precedent (v0.2.0 round-2
    P0 fix — fix-pass I): the decision lives on ``dispatch_context.decision``,
    NOT on ``findings[]``, because ``record_verdict`` normalizes findings to
    ``{severity, note}`` only and would strip the decision before any reader
    sees it.

    ``decision`` MUST be a member of ``iteration.DECISIONS`` —
    ``("advance", "iterate", "exit")``. The validation is the contract the
    engine relies on; a garbage decision is the dominant build-bug class this
    centralization closes (the "plan documents a behavior the code never
    wires" class).
    Optional ``payload`` (dict) is persisted alongside on
    ``dispatch_context.decision_payload`` — used by ``iterate_template`` to
    read e.g. ``emit_count`` (U3).

    Raises ``LedgerError`` if the gate unit is missing OR the decision is not
    in the enum.
    """
    # Lazy load (same load-order discipline as recompute_predicate).
    iteration = ledger_core._lazy_load("iteration")

    if decision not in iteration.DECISIONS:
        raise ledger_core.LedgerError(
            f"decision must be one of {iteration.DECISIONS!r}; got {decision!r}"
        )
    if payload is not None and not isinstance(payload, dict):
        raise ledger_core.LedgerError(
            f"decision_payload must be a dict or None; got {type(payload).__name__}"
        )

    def mutate(ledger):
        gate = ledger_core._find_unit(ledger, gate_unit_id)
        dc = gate.setdefault("dispatch_context", {})
        dc["decision"] = decision
        if payload is not None:
            dc["decision_payload"] = dict(payload)
        return decision

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_bound_override(
    repo_root, run_id, gate_unit_id, bound_type: str, original_decision: str
):
    """Record that the engine overrode an ``iterate`` decision to ``exit``
    because the iteration bound was breached (KTD §D / U2).

    Writes ``dispatch_context.bound_override = {bound: <bound_type>,
    original_decision: <original>, at: <iso>}`` on the gate unit. Mirrors the
    ``winner_unit_id`` precedent — operator-diagnostic data lives on
    ``dispatch_context``, not on findings or a top-level field. The operator
    on ``/auto-status`` reads from here (R9 surface).

    ``bound_type`` must be ``"max_attempts"`` or ``"max_wall_seconds"``;
    ``original_decision`` must be a member of ``iteration.DECISIONS``. The
    ``at`` timestamp is load-bearing for operator provenance (the deliberate-
    fail #5 test asserts overrides without a timestamp are caught).
    """
    if bound_type not in ("max_attempts", "max_wall_seconds"):
        raise ledger_core.LedgerError(
            f"bound_type must be 'max_attempts' or 'max_wall_seconds'; "
            f"got {bound_type!r}"
        )

    iteration = ledger_core._lazy_load("iteration")

    if original_decision not in iteration.DECISIONS:
        raise ledger_core.LedgerError(
            f"original_decision must be one of {iteration.DECISIONS!r}; "
            f"got {original_decision!r}"
        )

    def mutate(ledger):
        gate = ledger_core._find_unit(ledger, gate_unit_id)
        dc = gate.setdefault("dispatch_context", {})
        dc["bound_override"] = {
            "bound": bound_type,
            "original_decision": original_decision,
            "at": ledger_core._now_iso(),
        }
        return bound_type

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def set_exit_reason(repo_root, run_id, kind: str, error: dict):
    """Record a non-clean exit on the ledger (v0.3.0 G2 / AN-W1).

    Writes ``ledger["exit_reason"] = {"kind": kind, "error": error, "at": iso}``
    via the standard locked-RMW path. Called by F2's try/except in
    ``lib/tick.py`` BEFORE force-marking the loop done, so ``/auto-status`` of
    a crashed run can distinguish a wedge-marked-done from a clean exit. ``kind``
    is a short tag (e.g. ``"iteration-check-failed"``, ``"recipe-bug"``);
    ``error`` is a dict carrying at minimum ``{"type": ..., "message": ...}``
    so the operator surface can render the original exception type.

    Mirrors ``set_bound_override``'s shape — operator-diagnostic data lives on
    the ledger via a single timestamped envelope, NOT on findings.

    v0.3.1 B11: ``kind`` MUST be a member of ``ledger_core.ExitReason``.
    Validating at the write boundary closes the convention-only gap H left
    (the named-constants tuple was advisory; this is mechanism). Accepts the
    enum member directly (e.g. ``ExitReason.RECIPE_BUG``) or its string
    value (e.g. ``"recipe-bug"``) — StrEnum membership matches both.
    """
    try:
        kind_enum = ledger_core.ExitReason(kind)  # raises ValueError on bad input
    except ValueError as e:
        raise ledger_core.LedgerError(
            f"set_exit_reason: kind {kind!r} is not a member of ExitReason; "
            f"valid kinds: {[m.value for m in ledger_core.ExitReason]!r}"
        ) from e

    # Persist as the raw string value so the on-disk JSON shape stays
    # backwards-compatible with v0.3.0 (where kind was a plain string).
    # Use `.value` explicitly: `str(member)` on the pre-3.11 `(str, Enum)`
    # mixin returns the repr ("ExitReason.RECIPE_BUG"), not the value.
    kind_value = kind_enum.value

    def mutate(ledger):
        ledger["exit_reason"] = {
            "kind": kind_value,
            "error": error,
            "at": ledger_core._now_iso(),
        }
        return kind_value

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def accumulate_active_time(repo_root, run_id, delta_seconds: float):
    """Add ``delta_seconds`` to ``active_wall_seconds`` and stamp
    ``last_active_at`` (R5 / KTD §D).

    The FIRST sum-of-deltas accumulator on the ledger — every prior time field
    is overwrite-on-write. The contract is ADD, not OVERWRITE: each call adds
    its delta to the existing total, so two ticks of 5.0 + 7.5 sum to 12.5.
    The deliberate-fail #1 test asserts this is real addition, not the trap
    where a future refactor accidentally writes ``= round(delta, 3)``.

    Rounded to 3 decimal places to cap on-disk precision (a tick that runs for
    0.0000001 s is not interesting; the bound check tolerates millisecond
    granularity). Negative deltas are clamped to 0 — wall time only flows
    forward; a clock anomaly should not subtract from the bound budget.

    ``last_active_at`` is the ISO timestamp of THIS call, diagnostic only.
    The bound math reads ``active_wall_seconds``.

    Called from U4's ``finally``-clause around ``_tick_body`` (per round-2
    doc-review P1) so the crashed-tick delta still lands.
    """
    delta = float(delta_seconds)
    if delta < 0:
        delta = 0.0
    delta = round(delta, 3)

    def mutate(ledger):
        cur = float(ledger.get("active_wall_seconds", 0))
        ledger["active_wall_seconds"] = round(cur + delta, 3)
        ledger["last_active_at"] = ledger_core._now_iso()
        return ledger["active_wall_seconds"]

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def increment_iteration_attempts(repo_root, run_id, gate_unit_id):
    """Atomic ``iteration_attempts += 1``. KTD §D / U2.

    Called by U4's ``advance_iteration_loop`` when honoring an iterate decision
    (NOT when the bound-override path forces exit — overrides do not count as
    honored attempts). The pre-increment value drives the bound check in
    ``iteration.evaluate_decision`` so the Nth attempt is checked BEFORE its
    decision is honored: if a tick reads iteration_attempts==max, the override
    fires; the counter only crosses max via this call when the prior tick
    honored the (max-1)-th iterate.

    Composite path (``atomic_iterate_step``) inlines this increment instead of
    calling here — the F3 deadlock guard. The standalone mutator exists for
    completeness (tests, future paths) and for the deliberate-fail #6 control.

    ``gate_unit_id`` is required (and validated) so the increment can NEVER be
    silently called against a missing/typo'd gate — defensive. The value is
    the new count; the return is the new count for caller convenience.
    """
    def mutate(ledger):
        # Validate the gate unit exists; raises UnknownUnit on typo.
        ledger_core._find_unit(ledger, gate_unit_id)
        cur = int(ledger.get("iteration_attempts", 0))
        ledger["iteration_attempts"] = cur + 1
        return ledger["iteration_attempts"]

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)
