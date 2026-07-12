#!/usr/bin/env python3
"""auto B4: the pulse's advance + stall-detection logic (split out of lib/pulse.py).

These are the functions that perform the ONE smallest-useful advance the pulse
owns each beat — the plan-loop step, the work-loop fix/re-enqueue, the
iteration check, and the stall-detect-and-halt that backs the parallel-fan-out
promise — plus the seam transition that routes a finished plan-loop to seam
(manual) or work (auto).

They were extracted VERBATIM from lib/pulse.py (B4); no logic changed. The
dependency graph is one-way:

    pulse.py        → pulse_advance, pulse_guidance
    pulse_advance   → ledger, iteration, producers, phase_grammar, pulse_guidance
    pulse_guidance  → ledger, phase_grammar (leaf)

No cycle: nothing here imports pulse.py. `PulseError` is defined HERE (raised by
``advance_plan_loop``) and re-exported by pulse.py so the single class identity
is shared — ``resolve_backend`` in pulse.py and ``_cli``'s catch both reference
the same class.
"""

from __future__ import annotations

import os
import sys
import time

# Mirror pulse.py's bootstrap dance — the plugin is not pip-installed and lib/ is
# not guaranteed on sys.path. We do NOT re-import pulse.py to share its bootstrap
# (that would create a cycle); each lib/ module does its own _bootstrap load.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    is_iteration_disabled,
    load_ledger,
    load_lib_module,
    test_hatch_enabled,
)

ledger = load_ledger()
phase_grammar = load_lib_module("phase-grammar")
iteration = load_lib_module("iteration")
import unit_emitters as producers  # noqa: E402
pulse_guidance = load_lib_module("pulse_guidance")
# v0.6.0 U9: the pure upstream-cluster classifier. A stdlib-only leaf (it imports
# no lib siblings) — this adds the single DAG edge pulse_advance → upstream_cluster.
# advance_work_loop consults it BEFORE applying a fix, so a flaw inherited from an
# upstream spine phase escalates to the operator instead of ratcheting fix passes
# against a gap it cannot close (KTD-6 — detect-and-escalate; rebound is v0.7.0).
upstream_cluster = load_lib_module("upstream-cluster")


# ──────────────────────────────────────────────────────────────────────────
# Errors. Defined here (raised by advance_plan_loop) and re-exported by pulse.py.


class PulseError(Exception):
    """Base class for pulse errors."""


# The backend's plan-step ops the engine may execute (the engine never PICKS
# the step — the backend does; this is the set the engine will dispatch).
_PLAN_STEP_OPS = ("plan", "deepen", "review_plan")


# ──────────────────────────────────────────────────────────────────────────
# Stall detection + transitive halt (the parallel-fan-out promise).


def _seconds_since(iso_value, now) -> float:
    parsed = ledger.parse_iso(iso_value)
    if parsed is None:
        return -1.0
    return (now - parsed).total_seconds()


def _transitive_dependents(units, root_ids):
    """All units (transitively) depending on any id in `root_ids`, plus the roots."""
    halted = set(root_ids)
    changed = True
    while changed:
        changed = False
        for u in units:
            uid = u.get("id")
            if uid in halted:
                continue
            deps = u.get("depends_on") or []
            if any(d in halted for d in deps):
                halted.add(uid)
                changed = True
    return halted


def detect_and_halt_stalled(repo_root, run_id, ledger_dict, now):
    """Mark dispatched-past-threshold units `stalled`; return the halted-id set.

    A unit is stalled if it is `dispatched` and has been so for longer than its
    `stall_threshold_seconds` with no verdict. We mark it via ledger.transition
    (so the write goes through the I-1 chokepoint) with last_error preserved as
    null (a plain timeout; a backend raise sets last_error elsewhere). The
    stalled unit AND its transitive dependents are halted for this pulse;
    independent siblings still advance.
    """
    newly_stalled = []
    for u in ledger_dict.get("units", []):
        if u.get("state") != "dispatched":
            continue
        threshold = int(
            u.get("stall_threshold_seconds")
            or ledger.DEFAULT_STALL_THRESHOLD_SECONDS
        )
        age = _seconds_since(u.get("dispatched_at"), now)
        if age >= 0 and age > threshold:
            newly_stalled.append(u.get("id"))

    confirmed_stalled = []
    for uid in newly_stalled:
        # Plain timeout stall: last_error stays null (vs a backend-raise stall,
        # which records {call, message, at}). See record_stall_error.
        #
        # reap_pending (U3): the live agent may still be up (this is the alive-
        # but-wedged case), so a model-side kill (TaskStop + SIGTERM) is OWED. We
        # record that debt on the SAME atomic write as the stall flip; the driver
        # clears it via clear_reap_pending right after issuing the kill. An
        # uncleared marker on a later pulse is an assertable "kill requested but
        # unconfirmed" (units_awaiting_reap) — the only Python-visible handle on a
        # kill that is otherwise entirely model-side.
        try:
            ledger.transition(repo_root, run_id, uid, "stalled", reap_pending=True)
        except ledger.InvalidTransition:
            # Lost race — newly exposed by U1's dispatch-time heartbeat, which
            # runs this detector WHILE background agents are live. The unit left
            # `dispatched` between the snapshot read (ledger_dict) above and this
            # locked transition: a concurrent record_verdict (a healthy sibling
            # landing its verdict) or a death-path reap_unit already resolved it.
            # Swallow so the pulse doesn't crash and wedge the run — the exact hang
            # this watchdog exists to prevent — and drop the unit from the stalled
            # set; the fresh re-read below reflects the true post-transition state.
            # Mirrors reap_unit's guard: both writers to the dispatched→stalled
            # edge must tolerate this race.
            continue
        confirmed_stalled.append(uid)

    # Compute the full halted set (newly + already-stalled) and their dependents.
    fresh = ledger.read_ledger(repo_root, run_id)
    stalled_ids = [
        u.get("id") for u in fresh.get("units", []) if u.get("state") == "stalled"
    ]
    halted = _transitive_dependents(fresh.get("units", []), stalled_ids)
    return fresh, sorted(halted), confirmed_stalled


def reap_unit(repo_root, run_id, unit_id, attempt):
    """Attempt-gated idempotent reap: flip a `dispatched` unit to `stalled` (U2).

    The death path's counterpart to detect_and_halt_stalled's timeout path. On a
    native death signal (crash / auth-churn / completion with no verdict) the
    driver reconciles the dead unit HERE instead of waiting out the stall
    threshold. The flip goes through ledger.transition (the I-1 chokepoint),
    mirroring detect_and_halt_stalled.

    It transitions ONLY when the unit exists, is currently `dispatched`, AND its
    current `attempt` equals the passed ``attempt``. Otherwise it is a NO-OP that
    returns False and never raises:

      * already `stalled` (or any non-dispatched state) — a second reap of a unit
        the timeout watchdog already stalled is a no-op (dispatched -> stalled is
        the only legal edge; stalled -> stalled is not). This makes the two
        detection paths converge on exactly one stall per attempt (R3 / AE3).
      * ``attempt`` older than the unit's current attempt — a late death event
        from a driver-killed, already-superseded attempt-1 agent must NOT stall a
        fresh, healthy attempt-2 retry. This is the load-bearing gate that
        record_verdict's ``StaleVerdict`` does NOT cover: StaleVerdict gates the
        verdict write, not the reap, so reap carries its own attempt check.

    Returns True iff it actually reaped (transitioned), else False. Swallows
    ``InvalidTransition`` defensively (a lost race — the unit left `dispatched`
    between the read and the locked transition — is treated as a no-op).
    """
    fresh = ledger.read_ledger(repo_root, run_id)
    unit = None
    for u in fresh.get("units", []):
        if u.get("id") == unit_id:
            unit = u
            break
    if unit is None:
        return False
    if unit.get("state") != "dispatched":
        return False
    if int(unit.get("attempt", 0) or 0) != int(attempt):
        return False
    try:
        # reap_pending (U3): mirror detect_and_halt_stalled — the death path also
        # owes a model-side kill (TaskStop + SIGTERM) of whatever process is still
        # up, recorded on the same atomic flip so a forgotten kill stays visible.
        ledger.transition(repo_root, run_id, unit_id, "stalled", reap_pending=True)
    except ledger.InvalidTransition:
        return False
    return True


def clear_reap_pending(repo_root, run_id, unit_id):
    """Clear a unit's ``reap_pending`` marker — the driver calls this right after
    it has issued the model-side kill (TaskStop + SIGTERM) for a stalled unit (U3).

    The ``dispatched -> stalled`` flip (in BOTH detect_and_halt_stalled and
    reap_unit) sets ``reap_pending=True`` to record that a live-agent kill is
    OWED. The kill itself is model-side — no reaping primitive exists in lib/
    (KTD2) — so Python cannot observe that it happened; instead the driver calls
    HERE once it has. An UNCLEARED marker on a later pulse is therefore an
    assertable "kill requested but unconfirmed" state (units_awaiting_reap), which
    keeps a forgotten kill (and its zombie agent) from being invisible to tests.

    ``stalled -> stalled`` is not a legal grammar edge, so this is a same-state
    FIELD update and does NOT go through ``transition`` (which would raise
    InvalidTransition). It routes the write through the SAME atomic chokepoint —
    ``ledger._with_locked_ledger`` -> ``_atomic_write`` (which recomputes the
    predicate under flock) — so clearing the marker is never a bypass of the I-1
    write path. Returns True iff the unit was found and its marker cleared.
    """
    def mutate(led):
        for u in led.get("units", []):
            if u.get("id") == unit_id:
                u["reap_pending"] = False
                return True
        return False

    return ledger._with_locked_ledger(repo_root, run_id, mutate)


def units_awaiting_reap(ledger_dict):
    """Pure: the ids of ``stalled`` units whose ``reap_pending`` marker is truthy.

    The assertable "kill requested but unconfirmed" set. The stalled transition
    sets the marker; the driver clears it via clear_reap_pending right after
    issuing the kill — so anything still here on a later pulse is a kill the driver
    owes but has not confirmed (a possible zombie agent). Python owns this set
    even though the kill is model-side, giving the test suite a handle on a
    forgotten reap.
    """
    return [
        u.get("id")
        for u in ledger_dict.get("units", [])
        if u.get("state") == "stalled" and u.get("reap_pending")
    ]


# ──────────────────────────────────────────────────────────────────────────
# Error recording (atomic, via ledger.py).


def record_stall_error(repo_root, run_id, unit_id, call, message, now_iso):
    """On a backend raise mid-advance: mark the unit `stalled` AND record
    last_error = {call, message, at}, in one grammar-checked atomic write.

    The unit must be `dispatched` for the dispatched → stalled edge to be legal.
    If it is not dispatched (e.g. a plan-step raise with no unit in flight), we
    cannot use the dispatched→stalled edge, so we record the error on the run by
    flipping the loop to manual and surfacing — the caller decides. We return a
    flag indicating whether a unit-level stall was recorded.
    """
    fresh = ledger.read_ledger(repo_root, run_id)
    unit = None
    for u in fresh.get("units", []):
        if u.get("id") == unit_id:
            unit = u
            break
    err = {"call": call, "message": message, "at": now_iso}
    if unit is not None and unit.get("state") == "dispatched":
        ledger.transition(
            repo_root, run_id, unit_id, "stalled", last_error=err
        )
        return True
    return False


# ──────────────────────────────────────────────────────────────────────────
# The advance.


def _ready_fix_unit(ledger_dict, halted_ids):
    """Pick ONE unit whose latest verdict is converged and needs a fix applied.

    A fix-due unit is `verdict-returned` with an open GATING finding and is NOT
    in the halted set. The pulse applies the fix as a state transition only
    (verdict-returned → fixed); it does NOT touch findings (R8 — closure only via
    a fresh verdict). Returns the unit id or None.

    SCALE-AWARE (Bug #3): which severities are fix-due is decided by the SINGLE
    helper ``ledger.gating_severities(scale)``, read off this ledger's
    ``adapter_scale``. Hardcoding ``GATING_SEVERITIES`` here would livelock a
    blocker-only run: the pulse would forever try to fix a major-only unit that
    re-reviews to the same advisory major, fix→re-enqueue→re-review forever, while
    the predicate already reports met. The fix-class and the terminality class
    MUST share the gating decision so they agree on which units still need work.
    """
    gating = ledger.gating_severities(ledger_dict.get("adapter_scale", "three-tier"))  # format-v1 key; flips in U6
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "verdict-returned":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in gating:
                return u.get("id")
    return None


def _ready_reenqueue_unit(ledger_dict, halted_ids):
    """Pick ONE `fixed` unit whose STALE verdict still shows a GATING finding.

    After a fix is applied (verdict-returned → fixed) the findings remain stale
    (R8 — only a fresh verdict clears them), so the unit is NOT yet terminal.
    The pulse re-enqueues it (fixed → pending) so the dispatcher re-dispatches
    it for a fresh review. Skips halted units. Returns the unit id or None.

    SCALE-AWARE (Bug #3): same single-helper gating decision as ``_ready_fix_unit``
    and ``unit_is_terminal`` — a blocker-only run never re-enqueues a major-only
    fixed unit (majors are advisory), so it cannot churn fix→re-enqueue forever.
    """
    gating = ledger.gating_severities(ledger_dict.get("adapter_scale", "three-tier"))  # format-v1 key; flips in U6
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "fixed":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in gating:
                return u.get("id")
    return None


def _collect_upstream_findings(ledger_dict):
    """Gather role-tagged finding records from verdict-returned units'
    ``dispatch_context`` (the `decision`/`winner_unit_id` channel — findings[]
    is normalized to {severity, note}, so role/phase tags survive only here).

    A unit's ``dispatch_context.cluster_findings`` (when present) is a list of
    ``{"role": str, "phase": str, ...}`` records the review-op producer wrote
    (the producer is OUT OF SCOPE for U9 — until it exists this list is empty
    and detection never fires). Degrade-safe: any non-dict unit, missing/
    non-list cluster_findings, etc. contributes nothing rather than raising.
    """
    collected = []
    for u in ledger_dict.get("units", []) or []:
        if not isinstance(u, dict) or u.get("state") != "verdict-returned":
            continue
        dc = u.get("dispatch_context")
        if not isinstance(dc, dict):
            continue
        records = dc.get("cluster_findings")
        if isinstance(records, list):
            collected.extend(records)
    return collected


def detect_upstream_cluster(ledger_dict):
    """Read-only: classify whether this run's review findings cluster on a single
    UPSTREAM spine phase (KTD-6, role-diversity-weighted). Returns the classifier
    result dict (always five keys). Degrade-safe: ANY failure collapses to a
    not-detected result so a torn verdict can never raise out of the work-loop
    (where _dispatch_phase_advance would mis-record it as a unit stall).

    NEVER reads the loop_phase literal — current phase + order come from
    phase_grammar (the one sanctioned accessor), then are passed to the pure
    classifier as args.
    """
    try:
        current = phase_grammar.current_phase(ledger_dict)
        order = phase_grammar.phase_order(ledger_dict)
        findings = _collect_upstream_findings(ledger_dict)
        return upstream_cluster.classify(findings, current, order)
    except Exception:  # noqa: BLE001 — detection must never break a write path.
        return {
            "detected": False, "target_phase": None, "distinct_roles": [],
            "finding_count": 0, "reason": "classifier degraded (malformed input)",
        }


def _escalate_upstream_cluster(repo_root, run_id, result):
    """Escalate a detected upstream cluster to the operator via the EXISTING
    pause seam — driver=manual + a blocked_on message naming the upstream phase
    and the converging findings. This is the SAME mechanism auto-resume.py's
    `pause` uses (ledger.set_loop direct, mirroring advance_iteration_loop's
    bound-exit), so on-stop.py's manual carve-out lets the session stop and
    _resumable_runs surfaces the run for `/auto-resume continue`.

    Crucially this does NOT move loop_phase backward and writes NO new persisted
    field (driver + blocked_on already exist) — autonomous rebound is v0.7.0
    (KTD-6). The returned dict carries ``seam_pause: True`` so pulse.py's
    _try_seam_pause short-circuits BEFORE the standard driver="self" re-stamp +
    rearm (which would otherwise immediately undo this pause).
    """
    message = upstream_cluster.escalation_message(result) or "upstream-cluster detected"
    ledger.set_loop(repo_root, run_id, driver="manual", blocked_on=message)
    return {
        "advanced": "upstream-cluster-escalation",
        "seam_pause": True,
        "upstream_cluster": {
            "target_phase": result.get("target_phase"),
            "distinct_roles": result.get("distinct_roles"),
            "finding_count": result.get("finding_count"),
        },
        "blocked_on": message,
    }


def advance_work_loop(repo_root, run_id, ledger_dict, halted_ids):
    """Work-loop advance: apply ONE fix, OR re-enqueue ONE fixed-stale unit.

    Returns a dict describing what advanced (for the pulse result). The pulse
    NEVER dispatches and NEVER writes verdicts here. The TWO smallest-useful
    work-loop advances the pulse owns (state grammar §3 / closure loop R8):

      1. verdict-returned + gating finding  → fixed   (apply ONE fix)
      2. fixed + STALE gating finding       → pending (re-enqueue for re-review)

    Fix-due takes PRIORITY over re-enqueue-due so a single pulse on a fresh
    verdict-returned+blocker unit applies the fix (one step), and the NEXT pulse
    re-enqueues that fixed-with-stale-blocker unit. This MIRRORS the plan_step
    advance: one persisted advance per fresh-process pulse. Without step 2 the
    loop livelocks at `fixed` (the stale blocker keeps all_units_terminal false
    forever) — the closure loop is unreachable.

    The fixed→pending re-enqueue honors the test-only
    ``CLAUDE_AUTO_TEST_NO_REENQUEUE`` hatch (a deliberate-fail control: with
    it set the work-loop closure test goes RED — livelocks at `fixed`). The
    hatch is FENCED via ``test_hatch_enabled`` (task #31): only honored
    when ``CLAUDE_AUTO_TEST_HARNESS=1`` is ALSO set, so a stray production
    export of NO_REENQUEUE alone has no effect.

    v0.6.0 U9 — UPSTREAM-CLUSTER GATE (early, mirrors advance_iteration_loop's
    gate-then-route shape but routes to PAUSE, not a mutator): BEFORE picking a
    fix, check whether the converged review findings cluster on an upstream
    spine phase (role-diversity-weighted). If so, escalate to the operator via
    the pause seam and return — do NOT ratchet a fix pass against a flaw the
    current phase cannot close (KTD-6). The check is read-only + degrade-safe;
    on a recipe-blind / non-spine run upstream_phases is empty so it never fires.
    """
    cluster = detect_upstream_cluster(ledger_dict)
    if cluster.get("detected"):
        return _escalate_upstream_cluster(repo_root, run_id, cluster)
    fix_uid = _ready_fix_unit(ledger_dict, halted_ids)
    if fix_uid is not None:
        ledger.transition(repo_root, run_id, fix_uid, "fixed")
        return {"advanced": "fix-applied", "unit": fix_uid}
    if not test_hatch_enabled("CLAUDE_AUTO_TEST_NO_REENQUEUE"):
        reenq_uid = _ready_reenqueue_unit(ledger_dict, halted_ids)
        if reenq_uid is not None:
            ledger.transition(repo_root, run_id, reenq_uid, "pending")
            return {"advanced": "re-enqueued", "unit": reenq_uid}
    return {"advanced": "none", "reason": "no-fix-due"}


def _persist_enumerated_units(repo_root, run_id, enumerated):
    """Persist the plan's enumerated work units onto the plan unit (U6 producer).

    Targets the plan-phase unit being advanced. For A1 (single plan unit) and the
    per-pulse serialized A2 advance, that is the lone plan unit currently at
    plan-done; we resolve it from the fresh ledger (the unit whose phase is
    'plan'). If there are multiple plan units (A2), the active one is the one the
    round-robin advanced this pulse — for the V1 testable slice we target the first
    plan-phase unit lacking enumerated_units, which the serialized one-per-pulse
    advance makes unambiguous. Idempotent-safe: re-persist overwrites.
    """
    led = ledger.read_ledger(repo_root, run_id)
    plan_units = [u for u in led.get("units", []) if u.get("phase") == "plan"]
    if not plan_units:
        return
    target = next(
        (u for u in plan_units
         if not iteration.read_enumerated_units(u)),
        plan_units[0],
    )
    ledger.set_enumerated_units(repo_root, run_id, target["id"], enumerated)


def advance_plan_loop(repo_root, run_id, ledger_dict, backend):
    """Plan-loop advance: ask the backend for the next step and call that ONE
    step. The BACKEND owns plan-step sequencing — the engine never picks it.

    Returns a bare ``result_dict`` (U18 / KTD-5: the advance-return contract is
    normalized so every phase-advance returns a bare dict). A raise from the
    backend op (or a bad plan step) propagates to the caller's try/except in
    ``_dispatch_phase_advance``, which records it as a stall — this function does
    NOT catch and never signals the raising op back through its return value.

    CRITICAL (anti-livelock — schema §3.1): after the backend op returns
    SUCCESSFULLY, we PERSIST the executed step to the ledger via
    ``set_loop(plan_step=step)``. ``next_plan_step`` is pure over the ledger and
    each pulse is a fresh process reading ALL state from disk; without this write
    the next pulse reads ``plan_step == null``, the backend returns ``"plan"``,
    and the plan-loop re-plans forever. The persist is AFTER ``op(...)`` (and
    thus only on success): a step that raised is recorded as a stall by the
    caller's try/except, never as a completed step.

    PLAN→exit (schema §3.1 / backend-contract §4.1, §5): when ``next_plan_step``
    returns ``"done"`` the plan sequence is complete (gaps closed). The plan-loop
    must NOT re-arm on ``plan``; the caller (``_maybe_seam``) routes the met plan
    predicate to seam (manual) or work (auto). We surface ``{"advanced":
    "plan-done"}`` so the caller knows the sequence finished this pulse.

    GAPS persist (gap-write, backend-contract §2.2): when the executed step is
    ``review_plan``, its return is the gap-set; the engine reads ONLY its length
    and persists ``gaps_open = len(gap_set)`` via ``ledger.set_gaps_open`` (the
    I-1 atomic write path). The gap-set arrives either as a bare list (a direct
    return) OR inside the live PREPARE envelope (a dict) under the canonical
    ``gap_set`` key (§2.2), which the model fills out-of-band before the engine
    reads. We extract from whichever shape carries the array; a bare envelope
    that has no ``gap_set`` yet leaves ``gaps_open`` untouched (no default-0
    short-circuit). This is what makes plan-met depend on a REAL review having
    reported its gaps, not the default — closing the deepen-refinement loop.
    """
    step = backend.next_plan_step(ledger_dict)
    if step == "done":
        # PLAN-DONE: the plan sequence finished — enumerate this plan's work units
        # via the v0.2.0 backend op and PERSIST them onto the plan unit's
        # dispatch_context.enumerated_units, so the phase-transition producer (U5b)
        # can read them when it emits work units (resolves F4 — the producer).
        # enumerate_plan_units is prepare-only: it may return a bare list (a
        # synchronous/test backend) OR a PREPARE envelope the model fills with the
        # units under the canonical "units" key. We persist whichever concrete list
        # is available; a freshly-prepared envelope with no "units" key leaves the
        # field untouched (same no-premature-default discipline as gaps_open).
        enum_op = getattr(backend, "enumerate_plan_units", None)
        enum_envelope = None
        if callable(enum_op):
            enum_result = enum_op(ledger_dict)
            enumerated = None
            if isinstance(enum_result, list):
                enumerated = enum_result
            elif isinstance(enum_result, dict):
                if isinstance(enum_result.get("units"), list):
                    enumerated = enum_result["units"]
                else:
                    # A PREPARE envelope (the live backend): the model fills the
                    # units out-of-band via set_enumerated_units. Carry it so the
                    # caller can surface it as the rearm intent (producer
                    # handshake — see _maybe_seam). NOT a synchronous result.
                    enum_envelope = enum_result
            if enumerated is not None:
                _persist_enumerated_units(repo_root, run_id, enumerated)
        return {"advanced": "plan-done", "enumerate_envelope": enum_envelope}
    if step not in _PLAN_STEP_OPS:
        raise PulseError(f"backend returned unknown plan step: {step!r}")
    op = getattr(backend, step, None)
    if op is None or not callable(op):
        raise PulseError(f"backend missing op {step!r}")
    # The backend step is the work-bearing call; the caller wraps this in the
    # try/except so a raise becomes a recorded last_error, not a crash.
    result = op(ledger_dict)
    # review_plan returns the gap-set; the engine reads ONLY its length and
    # persists it (backend-contract §2.2). The gap-set arrives in one of two
    # shapes (Bug #5 — gaps_open was never written from the LIVE backends, which
    # return a dict envelope, so plan-met fired after a SINGLE review pass and the
    # deepen-refinement loop was unreachable):
    #   * a bare array — direct return (e.g. a test/synchronous backend); OR
    #   * the live PREPARE envelope (a dict) with the model-filled ``gap_set``
    #     array under the canonical ``gap_set`` key (contract §2.2). The bare
    #     envelope ships WITHOUT ``gap_set``; the model fills it before the engine
    #     reads, so a freshly-prepared envelope with no key leaves gaps_open
    #     untouched (never a default 0 that would short-circuit plan-met).
    gap_set = None
    if isinstance(result, list):
        gap_set = result
    elif isinstance(result, dict) and isinstance(result.get("gap_set"), list):
        gap_set = result["gap_set"]
    if step == "review_plan" and gap_set is not None:
        ledger.set_gaps_open(repo_root, run_id, len(gap_set))
    # Op succeeded — persist the step so the NEXT fresh-process pulse advances
    # from it instead of re-reading null and re-planning (the livelock).
    ledger.set_loop(repo_root, run_id, plan_step=step)
    return {"advanced": "plan-step", "step": step}


# ──────────────────────────────────────────────────────────────────────────
# Iteration loop (v0.3.0 U4).


# v0.3.1 B10: `no_emit` moved to lib/unit_emitters.py (collocated with the other
# emit functions per kieran-r2-2 — producers belong in the producers module).
# The call site below now references `producers.no_emit`.


def advance_iteration_loop(repo_root, run_id, led):
    """v0.3.0 U4 / KTD §A+§C+§D: the engine-side iteration check.

    Fires in `_pulse_body` BEFORE the predicate-met short-circuit at lines
    564-576. Reads the gate unit's effective decision via
    `iteration.evaluate_decision` and routes:

      * No iteration block / no gate_unit / kill-switch enabled → return None.
        Standard flow continues; the predicate-met short-circuit evaluates
        normally.
      * No decision yet (gate hasn't verdicted, or its decision was cleared by
        the most recent reset_for_iteration) → return None. Same path.
      * "advance" → return {"action": "advance"}. The caller falls through; the
        existing predicate-met short-circuit (now suppressed only by
        iteration_pending=True) advances to the terminal "done" state via the
        normal flow.
      * "iterate" under bound → call `ledger.atomic_iterate_step` (one locked
        body: increment + emit + reset). Return {"action": "iterate"}. The
        caller emits a rearm intent so the next pulse dispatches the new units.
      * "exit" OR "iterate over bound" → write `bound_override` on the gate
        unit's dispatch_context, then flip the loop to "done" / driver="manual"
        DIRECTLY via set_loop (NOT through advance_to_phase, which would re-
        invoke `judge_winner_to_work_units` and raise on missing winner_unit_id
        — KTD §D / round-2 P0 fix). Return {"action": "stop", "reason":
        "bound-exit", "report": ...}.

    Two safety gates fire BEFORE the decision read (no ledger writes on either
    early-return path — keeps a1/W pulses side-effect-clean):
      1. a1/W early-return: `led.get("iteration")` missing OR `gate_unit` is
         None → return None. No call to `evaluate_decision`.
      2. Kill-switch: `_bootstrap.is_iteration_disabled()` True
         (CLAUDE_AUTO_DISABLE_ITERATION=1) → return None. A REAL operator
         knob, not a test-only hatch: set the env var at runtime to skip the
         iteration check without redeploying — useful for emergency rollback
         of an outcomes-gated recipe. v0.3.0 F5 unfenced this (CRIT-2 + rel-3);
         it used to require the CLAUDE_AUTO_TEST_HARNESS=1 sentinel as well.

    The `new_depends_on` argument to `atomic_iterate_step` is passed as `None`:
    the ledger mutator computes the union of `gate.depends_on + appended` ids
    INSIDE the locked body (lib/ledger.py:1605-1607). Pre-computing here would
    race with the in-locked-body `_apply_emit` counter bump.
    """
    # Gate 1: no iteration declared (a1, W, legacy ledgers). Side-effect-free.
    iter_block = led.get("iteration") or {}
    gate_unit_id = iter_block.get("gate_unit")
    if not gate_unit_id:
        return None
    # Gate 2: kill-switch. Operators can set CLAUDE_AUTO_DISABLE_ITERATION=1
    # to skip the iteration check at runtime — useful for emergency rollback
    # of an outcomes-gated recipe without redeploying. Unfenced in v0.3.0 F5;
    # see _bootstrap.is_iteration_disabled.
    if is_iteration_disabled():
        return None

    eval_result = iteration.evaluate_decision(
        led, gate_unit_id, now_monotonic=time.monotonic()
    )
    effective = eval_result.get("decision_effective")

    if effective is None:
        # Gate hasn't verdicted (or decision was cleared by the most recent
        # reset_for_iteration). Standard flow continues; short-circuit evaluates.
        return None

    if effective == "advance":
        # Caller falls through to standard flow; the predicate-met short-
        # circuit then fires (iteration_pending is now False — the gate said
        # advance, not iterate — so the AND-NOT clause doesn't suppress).
        return {"action": "advance"}

    if effective == "iterate":
        # Under-bound iterate. Drive ONE atomic step (increment + emit +
        # reset) through the composite mutator. new_depends_on=None tells
        # atomic_iterate_step to compute the union of gate.depends_on +
        # appended ids inside its own locked body.
        #
        # v0.3.0 F2 (correctness-emit-template): the recipe validator at
        # lib/recipes.py:380-393 makes `iteration.emit_template` OPTIONAL
        # ("re-engage the gate without spawning new siblings" — e.g. A4's
        # comparator re-comparing the same builders after a clarifying
        # signal). When the recipe omits emit_template, the iterate path
        # must still advance the loop (increment iteration_attempts + reset
        # the gate) WITHOUT emitting new units; the existing units re-
        # engage. We honor that by passing a no-op producer to
        # atomic_iterate_step: `_apply_emit` calls `producer(ledger,
        # to_phase) or []`, so returning `[]` cleanly skips emission AND
        # leaves iteration_emit_count unchanged (the counter bumps PER
        # emitted unit). The deps default (`caller_depends_on=None` →
        # `gate.depends_on + [] = gate.depends_on`) preserves the existing
        # dependency graph. Going through atomic_iterate_step (one locked
        # body) preserves the all-or-nothing contract — splitting into two
        # writes (increment then reset) would open a window where a pulse
        # could read attempts++ but a still-verdict-returned gate.
        if (led.get("iteration") or {}).get("emit_template"):
            producer = producers.iterate_template
        else:
            producer = producers.no_emit
        ledger.atomic_iterate_step(
            repo_root,
            run_id,
            gate_unit_id,
            producer=producer,
            new_depends_on=None,
        )
        return {"action": "iterate"}

    # effective in ("exit", "iterate"-over-bound). Both shapes: write the
    # bound_override (carries bound_type + original_decision + at) and force
    # the loop to "done" / driver="manual" via set_loop DIRECTLY.
    # advance_to_phase would re-invoke `judge_winner_to_work_units` which
    # raises on missing winner_unit_id (the gate said iterate, not advance, so
    # no winner is set). Skipping advance_to_phase preserves the audit trail
    # in the gate's dispatch_context.bound_override.
    bound_type = eval_result.get("bound_type")
    original = eval_result.get("original_decision") or "iterate"
    if eval_result.get("bound_breached"):
        ledger.set_bound_override(
            repo_root, run_id, gate_unit_id,
            bound_type=bound_type, original_decision=original,
        )
    ledger.set_loop(
        repo_root, run_id, loop_phase="done", driver="manual", beat=True,
    )
    final_led = ledger.read_ledger(repo_root, run_id)
    report = _build_bound_exit_report(final_led, gate_unit_id)
    return {
        "action": "stop",
        "reason": "bound-exit",
        "run": run_id,
        "report": report,
    }


def _build_bound_exit_report(led, gate_unit_id):
    """Build the bound-exit report from the gate unit's dispatch_context.

    Mirrors `_build_report`'s shape but adds the bound_override block + best-
    so-far state per OQ2. The best-so-far is the gate's last
    decision_payload (the payload that accompanied either the last iterate or
    the last advance) — surfaced for operator diagnostics so the
    operator-guidance branch in R9 can name what we tried before bound trip.
    """
    base = pulse_guidance._build_report(led)
    gate = next(
        (u for u in led.get("units", []) if u.get("id") == gate_unit_id), None
    )
    base["bound_override"] = iteration.read_bound_override(gate or {})
    base["best_so_far"] = iteration.read_decision_payload(gate or {})
    return base


# ──────────────────────────────────────────────────────────────────────────
# Seam handling.


def _plan_has_enumerated_units(led) -> bool:
    """True iff some plan-phase unit has had enumerated_units SET — the producer
    handshake gate. We test KEY PRESENCE, not truthiness: an explicit empty list
    means the model RAN the enumerate prepare op and legitimately found zero work
    units (a valid terminal — the producer returns [] and any structural units
    remain), so we must transition. A MISSING key means the model hasn't run
    enumerate yet, so we surface the prepare and wait. The plan→work producers read
    enumerated_units off the plan unit."""
    for u in led.get("units", []):
        if u.get("phase") == "plan" and "enumerated_units" in (
            u.get("dispatch_context") or {}
        ):
            return True
    return False


def _is_auto(auto_flag) -> bool:
    """Auto mode: the explicit --auto flag. The pulse honors only the flag the
    driver passes; there is no ledger-driven auto marker (the schema has no slot
    for one, and the driver owns the policy). Kept as a named predicate so the
    seam-routing call site reads intentionally."""
    return bool(auto_flag)


def advance_to_phase(repo_root, run_id, led, *, to_phase):
    """Advance loop_phase to ``to_phase``, emitting that phase's units if the
    recipe declares a producer for arrival there.

    v0.2.0 fix-pass A.2 — the single chokepoint for phase advancement. Resolves
    the recipe's {to: to_phase} producer via phase_grammar.producer_name_for_arrival
    and calls ledger.transition_and_emit (atomic advance+emit+recompute). When
    no producer is declared we still need to fall back to a raw set_loop:

    * Legacy ledger (recipe is None, e.g. a v0.1.x run resumed under v0.2.0) —
      no recipe means no phase_transitions; use set_loop to preserve byte-
      identical R13 behavior.
    * v0.2.0 ledger with no matching transition — the recipe declares no
      producer for arrival at to_phase; this is a RECIPE BUG (the validator
      should have rejected it earlier, but defense in depth: raise here so a
      misconfigured workspace recipe can't silently no-op).

    `feedback_plan_documents_transition_code_doesnt_wire_it`: this helper IS
    the wire — every phase advance that crosses a transition boundary goes
    through here.
    """
    producer_name = phase_grammar.producer_name_for_arrival(led, to_phase)
    legacy_ledger = led.get("recipe") is None
    if producer_name is None:
        if not legacy_ledger:
            raise ledger.LedgerError(
                f"recipe {led.get('recipe',{}).get('name')!r} declares no producer "
                f"for arrival at {to_phase!r}; either add a phase_transitions entry "
                f"or fix the recipe"
            )
        # legacy: no recipe declared, behave like v0.1.x — raw advance.
        # transition_and_emit's v0.2.0 path writes seam_paused=(to_phase=="seam");
        # we mirror that here so manual seam→work via auto-resume clears the
        # pause flag on legacy ledgers too. The auto-flip path (called with
        # to_phase="work") clears it; future helpers that arrive at "seam"
        # would set it. Either way, both writes happen in one set_loop.
        ledger.set_loop(
            repo_root,
            run_id,
            loop_phase=to_phase,
            seam_paused=(to_phase == "seam"),
            driver="self",
            beat=True,
        )
        return
    producer_fn = producers.resolve(producer_name)
    ledger.transition_and_emit(repo_root, run_id, to_phase, producer_fn)


def _brainstorm_unit_ready(led) -> bool:
    """True iff the spine's brainstorm unit is complete AND has recorded its
    requirements-doc output — the precondition for firing the U8
    ``brainstorm_output_to_plan_unit`` producer.

    Gating on BOTH conditions is load-bearing: if we advanced to plan before the
    doc path is recorded, the U8 producer raises ``RecipeError``, which
    ``_dispatch_phase_advance``'s try/except would mis-record as a unit stall
    (feedback_plan_documents_transition_code_doesnt_wire_it — the producer must
    only fire when its input is present). Until both hold the brainstorm pulse
    re-arms (the unit is still being worked by the model).
    """
    for u in led.get("units", []) or []:
        if not isinstance(u, dict) or u.get("id") != "brainstorm":
            continue
        if u.get("state") != "verdict-returned":
            return False
        return bool(iteration.read_requirements_doc(u))
    return False


def advance_brainstorm_loop(repo_root, run_id, led):
    """Brainstorm-phase advance for the spine recipe (v0.6.0 / U7 — the forward
    brainstorm→plan trigger that mirrors ``_maybe_seam``'s plan→work auto-flip).

    The brainstorm phase has NO predicate-met exit (KTD-3 / U7 technical design:
    ``eval_phase == terminal_phase`` is False at brainstorm, so ``met`` stays
    False) — it leaves ONLY via producer-driven forward advance. Without this
    branch a brainstorm-phase pulse falls into ``_dispatch_phase_advance``'s
    ``else`` ({"advanced":"none"}) and re-arms forever (the livelock the U7
    success criterion forbids; feedback_plan_documents_transition_code_doesnt_wire_it
    — the U8 producer existed but nothing CALLED it on a brainstorm pulse).

    When the brainstorm unit is complete + has its requirements-doc, advance to
    ``plan`` through ``advance_to_phase`` (the single phase-advance chokepoint),
    which resolves the recipe's {to: plan} transition and fires the registered
    ``brainstorm_output_to_plan_unit`` producer atomically. Otherwise return
    ``{"advanced":"none"}`` so the pulse re-arms while the model still works the
    brainstorm step. Pairs with the plan→work producer exactly as plan→work pairs
    with seam.
    """
    if not _brainstorm_unit_ready(led):
        return {"advanced": "none", "reason": "brainstorm-pending"}
    advance_to_phase(repo_root, run_id, led, to_phase="plan")
    return {"advanced": "brainstorm-done", "seam": "auto-advance-to-plan"}


def _maybe_seam(repo_root, run_id, led, *, auto, advance_result):
    """If the plan-loop is complete, transition out of plan (gap #5).

    The plan sequence is complete when EITHER the cached predicate is met
    (plan-phase: gaps_open == 0) OR the backend signalled the sequence finished
    this pulse (``next_plan_step`` returned "done" → advance "plan-done"). The two
    MUST agree (backend-contract §4.1 coherence guard); we trigger on either so a
    `next_plan_step=="done"` always transitions loop_phase, never re-arming on
    `plan`.

    Manual (not auto): write loop_phase="seam", seam_paused=true,
    loop.driver="manual"; do NOT re-arm (signal seam_pause to the caller).
    Auto: flip plan → work directly via the recipe's producer (v0.2.0; P0 #1
    fix-pass A.2 — the load-bearing rewire). Reads the recipe's
    phase_transitions for the {to: work} producer, resolves it, and calls
    ledger.transition_and_emit atomically (advance + emit + recompute in ONE
    locked snapshot — the G3/F2 invariant). Legacy ledgers (no recipe) fall
    back to the raw set_loop path so v0.1.x runs resumed under v0.2.0 keep
    working. A v0.2.0 ledger missing the {to: work} declaration is a recipe
    bug; we raise rather than silently no-op (per
    feedback_plan_documents_transition_code_doesnt_wire_it — silent fallback
    on configured recipes IS the build-bug class).
    """
    pred = led.get("exit_predicate_result") or {}
    plan_done = (
        isinstance(advance_result, dict)
        and advance_result.get("advanced") == "plan-done"
    )
    if not pred.get("met") and not plan_done:
        return advance_result  # gaps still open; keep pulsing the plan loop.
    # PRODUCER HANDSHAKE (v0.4.3): the plan is complete, but the work-loop needs
    # units to dispatch. enumerate_plan_units is a PREPARE op the MODEL executes
    # (backend-contract §2.2) — it returns an envelope, then calls
    # set_enumerated_units out-of-band. If the plan unit has no enumerated_units
    # yet, the model hasn't run it; transitioning now would flip to a work phase
    # with ZERO units (vacuous-exit guard keeps it un-met → the run wedges with
    # nothing to dispatch). So surface the enumerate prepare and do NOT transition
    # — the next pulse, once units are stashed, passes this guard and flips to
    # work. This closes the latent producer gap for a1 too (every other plan op is
    # surfaced+executed across a pulse boundary; enumerate must be as well). Tests
    # / synchronous backends that pre-persist enumerated_units pass straight
    # through. The plan-presatisfied (W) path lands here on its very first pulse.
    if not _plan_has_enumerated_units(led):
        out = dict(advance_result or {})
        out["advanced"] = "plan-enumerate-pending"
        out["seam"] = "enumerate-pending"
        return out
    if _is_auto(auto):
        advance_to_phase(repo_root, run_id, led, to_phase="work")
        out = dict(advance_result or {})
        out["seam"] = "auto-flip-to-work"
        return out
    ledger.set_loop(
        repo_root,
        run_id,
        loop_phase="seam",
        seam_paused=True,
        driver="manual",
        beat=True,
    )
    out = dict(advance_result or {})
    out["seam_pause"] = True
    out["seam"] = "paused"
    return out
