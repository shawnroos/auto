#!/usr/bin/env python3
"""auto B4: pulse guidance + report builders (split out of lib/pulse.py).

These are the READ-ONLY helpers the pulse uses to build the operator-guidance
block that rides every rearm intent, the gaps_open livelock warning, and the
exit/most-recently-dispatched reports. They read the run-record snapshot they are
handed (or re-read via the canonical run-record module) but never mutate it, so
they form the LEAF of the pulse module graph:

    pulse.py        → pulse_advance, pulse_guidance
    pulse_advance   → pulse_guidance
    pulse_guidance  → run_record (read-only) + phase_grammar (report shape)

No cycle: nothing here imports pulse.py or pulse_advance.
"""

from __future__ import annotations

import json
import os
import sys

# Mirror pulse.py's bootstrap dance — the plugin is not pip-installed and lib/ is
# not guaranteed on sys.path. We do NOT re-import pulse.py to share its bootstrap
# (that would create a cycle); each lib/ module does its own _bootstrap load.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_run_record, load_lib_module  # noqa: E402

run_record = load_run_record()
phase_grammar = load_lib_module("phase-grammar")
# U12: typed dispatch_context accessors (iteration is a `_bootstrap`-only leaf —
# no import cycle, and import-topology only forbids the pulse/pulse_advance edges).
iteration = load_lib_module("iteration")


def _operator_guidance_for(phase, advance_result, led):
    """Build the prepare/execute reminder block that rides every rearm intent.

    v0.2.0 fix-pass H (memory feedback_auto_prepare_execute_operator_traps):
    field bug where an agent pulsed 5 times expecting steps to populate. Root
    cause was invisible contract: the pulse prepares invocations; the model
    EXECUTES them; if the model doesn't, the run-record doesn't progress. The
    rearm intent now carries this reminder explicitly. Phase-aware so plan-
    loop and work-loop get the right framing.

    v0.3.0 R9 (KTD §D operator-diagnostics):
      * If the gate step just had `bound_override` written on this pulse →
        prepend a notice naming which bound tripped + the best-so-far state
        from the gate's last decision_payload (OQ2). Operators see WHY the
        loop exited and WHAT we tried before bound.
      * Else if iteration is active AND `iteration_attempts == max_attempts`
        → prepend a "last attempt before bound" warning. Operators know the
        NEXT iterate decision will trip the bound (the engine overrides
        when `attempts_made >= max_attempts` per lib/iteration.py:136).
    """
    iteration_prefix = _iteration_guidance_prefix(led)

    # v0.4.3 producer handshake: the plan is complete but the work-loop has no
    # steps yet. The rearm must tell the model to EXECUTE the enumerate prepare
    # op (read the plan → produce work steps → set_enumerated_steps), else the
    # run sits in the plan phase forever. Named explicitly so the generic
    # plan-step message ("Just-prepared step: None") doesn't mislead.
    if isinstance(advance_result, dict) and (
        advance_result.get("advanced") == "plan-enumerate-pending"
    ):
        envelope = advance_result.get("enumerate_envelope") or {}
        plan_path = envelope.get("plan_path")
        whence = f" from {plan_path}" if plan_path else ""
        body = (
            "plan complete — ENUMERATE its work steps. Read the reviewed plan"
            f"{whence}, produce the work-step list, then PERSIST it via Bash: "
            "`bash \"$CLAUDE_PLUGIN_ROOT/lib/run_record.sh\" set-enumerated-steps "
            "<run> <plan-step-id> '[{\"id\":\"...\",\"invokes\":{...}}]'`. The "
            "NEXT pulse transitions to the work-loop. Re-pulsing WITHOUT "
            "persisting leaves the run in the plan phase with no steps to "
            "dispatch."
        )
        return iteration_prefix + body if iteration_prefix else body

    if phase == "plan":
        step = None
        if isinstance(advance_result, dict):
            step = advance_result.get("step")
        invocation = _PLAN_STEP_INVOCATION.get(step, "(see backend contract)")
        body = (
            "prepare/execute contract: I PREPARED a plan-loop invocation; "
            "YOU must run it. I do NOT dispatch the work — my role is to "
            "advance the state machine AFTER you feed structured results back "
            "(after /ce-doc-review, persist gaps via `bash "
            "\"$CLAUDE_PLUGIN_ROOT/lib/run_record.sh\" set-gaps-open <run> <N>`). "
            "Re-pulsing without running "
            f"the invocation is a NO-OP — steps will stay []. Just-prepared "
            f"step: {step!r}; expected invocation: {invocation}. "
            "If this plan is ALREADY reviewed and you're re-deriving finished "
            "work, run `/auto-resume advance <run>` to declare it satisfied and "
            "skip straight to the work-loop (v0.4.3)."
        )
        return iteration_prefix + body if iteration_prefix else body
    if phase == "brainstorm":
        # v0.6.0 U7/U8 (P0 fix-round-3): the spine's brainstorm phase is a
        # SINGLE-step, model-driven step (like plan, NOT a work-loop fan-out).
        # The CE backend has no `brainstorm` op, so nothing dispatches it for
        # the model — the driver MUST run /ce-brainstorm itself, then record the
        # two conditions advance_brainstorm_loop/_brainstorm_step_ready gate on:
        # (i) the requirements-doc path on the brainstorm step's
        # dispatch_context.requirements_doc, AND (ii) self-write that step
        # `verdict-returned`. Without BOTH, the forward brainstorm→plan producer
        # never fires and every pulse re-arms identically (the livelock the U7
        # success criterion forbids; feedback_plan_documents_transition_code_
        # doesnt_wire_it). Mirrors the single-step plan-phase guidance, not the
        # work-loop fan-out reminder.
        body = (
            "prepare/execute contract: I PREPARED the brainstorm step; YOU "
            "must run it. Invoke /ce-brainstorm to explore the conversation "
            "context and produce a requirements doc. THEN, on the `brainstorm` "
            "step, record BOTH (i) dispatch_context.requirements_doc = <the doc "
            "path> AND (ii) state `verdict-returned`, via the existing mutators "
            "in THIS order (the step starts `pending`, from which record_verdict "
            "would raise): run_record.transition(repo, run, 'brainstorm', "
            "'dispatched', dispatch_context={'requirements_doc': <path>}) then "
            "run_record.record_verdict(repo, run, 'brainstorm', []). Both conditions "
            "are required before the spine advances brainstorm→plan. Re-pulsing "
            "without running /ce-brainstorm and recording the doc is a NO-OP — "
            "the brainstorm phase stays put until both conditions hold."
        )
        return iteration_prefix + body if iteration_prefix else body
    if phase == "work":
        # In the work-loop, the trap is different: the driver dispatches background
        # Agents via the dispatcher and then YIELDS for harness re-invocation
        # (fix-pass G). Don't ScheduleWakeup-poll waiting for verdicts.
        body = (
            "prepare/execute contract: in the work-loop YOU drive the "
            "dispatcher fan-out (dispatcher.ready_steps + dispatch_batch); "
            "after dispatching, YIELD silently — the harness re-invokes you "
            "when a verdict lands (fix-pass G). Re-pulsing without running "
            "dispatch is a no-op."
        )
        return iteration_prefix + body if iteration_prefix else body
    body = (
        "prepare/execute contract: I prepare; YOU execute. Re-pulsing without "
        "running the prepared invocation does not advance the run_record."
    )
    return iteration_prefix + body if iteration_prefix else body


def _iteration_guidance_prefix(led):
    """Build the iteration-aware operator-guidance prefix (R9 / KTD §D).

    Returns an empty string when no iteration is declared, or when neither
    R9 condition fires. Otherwise returns a one-sentence prefix that names
    either the bound-override (operator sees WHY the loop exited) or the
    last-attempt warning (operator sees that the NEXT iterate trips bound).

    The bound-override read goes through `dispatch_context.bound_override` —
    the field key (`"bound_override"`) is NOT the literal `"decision"` so
    the AST lint allows it. The bound type is read from the same dict.

    The "best-so-far" payload (OQ2) is the gate's `decision_payload` — the
    payload that rode the LAST advance/iterate decision. On a bound-exit
    pulse, that payload was the iterate that the engine overrode to exit.
    """
    iter_block = led.get("iteration") or {}
    gate_id = iter_block.get("gate_step")
    if not gate_id:
        return ""
    gate = next(
        (u for u in led.get("steps", []) if u.get("id") == gate_id), None
    )
    if gate is None:
        return ""
    # Branch 1 (higher priority): bound_override was written. Surface bound
    # type + best-so-far so the operator sees what we tried before bound.
    override = iteration.read_bound_override(gate)
    if override:
        btype = override.get("bound") or "unknown"
        payload = iteration.read_decision_payload(gate)
        payload_repr = (
            json.dumps(payload, sort_keys=True) if payload is not None else "null"
        )
        return (
            f"iteration bound tripped: {btype}. "
            f"Best-so-far (last gate payload): {payload_repr}. "
            "The engine overrode the gate's iterate to exit; the run is done. "
        )

    # Branch 2: under bound, but the next iterate decision the engine sees
    # will trip the bound. Surface a warning so the operator knows.
    #
    # v0.3.0 F2 (ADV-3 off-by-one): the warning fires when the NEXT iterate
    # decision will be overridden to exit by `iteration.evaluate_decision`.
    # That override fires when `attempts_made >= max_attempts` (lib/iteration
    # .py:136). `iteration_attempts` increments per HONORED iterate (in
    # atomic_iterate_step, pre-check). So the next iterate trips bound EXACTLY
    # when `attempts == max_attempts` — i.e., max_attempts iterates have been
    # honored and the (max+1)-th would trip. The prior code compared `attempts
    # == max - 1`, which fires ONE pulse early (with max=3, that warns at
    # attempts=2 even though attempts=2 still has TWO more iterates to honor
    # before bound trip: the iterate at attempts=2 becomes attempts=3, and the
    # iterate read at attempts=3 is the one that trips).
    bound = iter_block.get("bound") or {}
    max_attempts = bound.get("max_attempts")
    attempts = int(led.get("iteration_attempts", 0))
    if max_attempts is not None and attempts == int(max_attempts):
        return (
            f"iteration: last attempt before bound (attempts={attempts}, "
            f"max_attempts={max_attempts}). The next iterate decision will "
            "trip the bound and force exit. "
        )

    return ""


def _gaps_open_guard(phase, led):
    """Warn the operator when they are in the deepen↔review livelock state.

    This is Trap 2 from feedback_auto_prepare_execute_operator_traps: the
    plan-loop cycles `plan → deepen → review_plan → deepen → review_plan → …`
    forever unless the operator runs a real review and feeds back
    ``set_gaps_open(N)``. Without that, gaps_open stays null, plan-met never
    fires, and steps never materialize.

    The livelock signature is: ``plan_step ∈ {"deepen", "review_plan"}`` AND
    ``gaps_open is None``. We do NOT key only on review_plan because the pulse
    PERSISTS plan_step AFTER the step runs (anti-livelock §3.1 fix), so by the
    time this guard reads the run-record the just-completed review_plan has been
    succeeded by a deepen → plan_step="deepen", gaps_open still null. Both
    states are diagnostically equivalent: the operator hasn't fed back gaps yet.
    """
    if phase != "plan":
        return None
    plan_step = led.get("plan_step") or ""
    if plan_step not in ("deepen", "review_plan"):
        return None
    pred = led.get("exit_predicate_result") or {}
    if pred.get("gaps_open") is not None:
        return None
    return (
        "gaps_open is NULL — plan-met cannot fire until a real review_plan "
        "step has run and you call run_record.set_gaps_open(<N>) with the gap "
        "count from /ce-doc-review's output. Without this the plan-loop will "
        "deepen↔review_plan forever and steps will never materialize. "
        "Feeding back gaps_open=0 closes the loop and starts the work-loop."
    )


# Map a plan_step name to the invocation an operator should run. Authoritative
# source for the operator-guidance string; if a new plan-step ships, add it here.
_PLAN_STEP_INVOCATION = {
    "plan": "/ce-plan <issue>",
    "deepen": "/ce-plan deepen",
    "review_plan": "/ce-doc-review",
}


def _build_report(led):
    """Exit report — emit the minors list for a work-loop (R6)."""
    pred = led.get("exit_predicate_result") or {}
    minors = []
    for u in led.get("steps", []):
        for f in u.get("findings") or []:
            if f.get("severity") == "minor":
                minors.append({"step": u.get("id"), "note": f.get("note", "")})
    return {
        phase_grammar.LOOP_PHASE_KEY: phase_grammar.current_phase(led),
        "blockers": pred.get("blockers", 0),
        "majors": pred.get("majors", 0),
        "minors": pred.get("minors", 0),
        "minor_findings": minors,
        "all_steps_terminal": pred.get("all_steps_terminal", False),
    }


def _most_recently_dispatched(led):
    best_id = None
    best_at = None
    for u in led.get("steps", []):
        if u.get("state") != "dispatched":
            continue
        at = run_record.parse_iso(u.get("dispatched_at"))
        if at is None:
            continue
        if best_at is None or at > best_at:
            best_at = at
            best_id = u.get("id")
    return best_id
