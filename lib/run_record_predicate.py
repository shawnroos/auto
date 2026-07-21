#!/usr/bin/env python3
"""auto run-record predicate evaluator: the PURE exit-predicate logic (I-2 / §4).

Extracted from run_record_core (U16) so the core file stays under the size budget
and the predicate evaluator has a home of its own. This module holds the pure,
side-effect-free predicate surface: ``recompute_predicate`` and its B7 helpers
(``_count_severities_by_step``, ``_read_cached_gaps_open``,
``_compute_terminality``, ``_evaluate_met``, ``_compute_iteration_pending``),
plus ``gating_severities``, ``step_is_terminal``, and ``is_orphaned``.

Topology (the load-bearing acyclic discipline): this module imports ONLY
``run_record_core`` (for the constants ``GATING_SEVERITIES`` / ``GRACE_SECONDS``, the
test-hatch fence ``_test_hatch_enabled``, the time helper ``parse_iso``, and the
lazy-load idiom ``_lazy_load`` used to reach ``iteration`` / ``phase-grammar``
cycle-safely). ``run_record_core`` does NOT import this module at top level — its
``_atomic_write`` chokepoint reaches ``recompute_predicate`` via
``_lazy_load("run_record_predicate")`` INSIDE the function body, so the
core → predicate edge is deferred and no import cycle forms (same cycle-safe
shape core already uses for ``iteration`` / ``phase-grammar``). The facade
``lib/run_record.py`` re-exports this module's public predicate names so
``run_record.<name>`` keeps resolving unchanged.

The predicate is pure per I-2 (contract §4/§5): it reads the run-record dict and
returns a fresh ``exit_predicate_result`` — it NEVER mutates the run-record. The
one serialization chokepoint (``run_record_core._atomic_write``) assigns the
returned dict immediately before every write, so predicate freshness is
structural. See docs/contracts/run-record-schema.md for the authoritative spec — if
they disagree, the contract wins and this file is the bug.
"""

from __future__ import annotations

import datetime
import os
import sys

# Load run_record_core via the standard bootstrap loader (mirrors run_record_mutators /
# run_record_producers). The run-record surface is loaded from many sites by file path
# (the test harness uses spec_from_file_location, which does NOT add lib/ to
# sys.path), so a plain `import run_record_core` is not guaranteed to resolve.
# Prepending lib/ + routing through _bootstrap.load_lib_module is the one robust
# load strategy the codebase already uses for sibling modules.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")


# ──────────────────────────────────────────────────────────────────────────
# Pure predicate logic (I-2 / §4).


def gating_severities(scale: str = "three-tier") -> tuple:
    """The SINGLE source of truth for which severities GATE the loop, scale-aware.

    This is the one place that maps ``backend_scale`` -> the gating-severity tuple.
    EVERY consumer that asks "does this finding block terminality / done /
    dependency-satisfaction?" MUST route through here rather than hardcoding
    ``GATING_SEVERITIES`` or a ``("blocker", "major")`` literal — that hardcoding
    was the Bug #3 livelock class (a ``blocker-only`` run with a major finding
    would gate forever at six different call sites). Centralizing the decision
    means a new caller cannot reintroduce the bug at a seventh site: there is
    nothing to copy.

      * ``"three-tier"`` (CE; the default for any missing / unknown value) — both
        ``blocker`` and ``major`` gate.
      * ``"blocker-only"`` (native) — only ``blocker`` gates; majors are advisory
        (surfaced at exit, never blocking). Unknown -> three-tier is the safe
        default (gates more, never under-blocks).

    The corresponding ``run_record`` field is ``backend_scale``; read it once per call
    site (e.g. ``run_record.get("backend_scale", "three-tier")``) and pass it in.

    Test-only deliberate-fail hatch ``CLAUDE_AUTO_TEST_FORCE_THREETIER_GATING``:
    when set to ``"1"`` this helper IGNORES ``scale`` and always returns the
    hardcoded three-tier ``GATING_SEVERITIES``. That simulates a regression where a
    call site bypasses the scale-aware decision (the Bug #3 class). The class-1
    blocker-only test runs the same scenario with this hatch set and asserts the
    run LIVELOCKS — proving the helper, not a hardcoded copy, is what unblocks the
    run. Because EVERY gating consumer routes through this one function, the single
    hatch reverts ALL sites at once, so the test proves the CLASS is closed (no
    site bypasses scale), not merely one instance.
    """
    if run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_FORCE_THREETIER_GATING"):
        return run_record_core.GATING_SEVERITIES
    return ("blocker",) if scale == "blocker-only" else run_record_core.GATING_SEVERITIES


def step_is_terminal(step: dict, scale: str = "three-tier") -> bool:
    """terminal(u) per §4.1 of the contract.

    A step is terminal iff it is ``terminal-skip``, OR it is ``verdict-returned``
    / ``fixed`` AND carries no open *gating* finding. A ``fixed`` step with a stale
    gating finding is NOT terminal (the findings-closure livelock guard).

    SCALE-AWARE (Bug #3): which severities gate is decided by the SINGLE helper
    ``gating_severities(scale)`` (the one source of truth). Under ``"three-tier"``
    (CE / default) both ``blocker`` and ``major`` gate; under ``"blocker-only"``
    (native) only ``blocker`` gates — majors are advisory (surfaced at exit, never
    blocking terminality), matching the work-loop ``met`` predicate so the two
    cannot disagree about done-ness.
    """
    gating = gating_severities(scale)
    state = step.get("state")
    if state == "terminal-skip":
        return True
    if state in ("verdict-returned", "fixed"):
        for finding in step.get("findings") or []:
            if finding.get("severity") in gating:
                return False
        return True
    return False


def _count_severities_by_step(run_record: dict) -> tuple:
    """B7 helper: total (blockers, majors, minors) finding counts across all steps.

    Extracted VERBATIM from ``recompute_predicate``'s leading count loop — pure,
    no mutation, byte-equivalent tallies.
    """
    blockers = majors = minors = 0
    for step in run_record.get("steps", []):
        for finding in step.get("findings") or []:
            sev = finding.get("severity")
            if sev == "blocker":
                blockers += 1
            elif sev == "major":
                majors += 1
            elif sev == "minor":
                minors += 1
    return blockers, majors, minors


def _read_cached_gaps_open(run_record: dict):
    """B7 helper: read the backend-supplied ``gaps_open`` from the prior predicate.

    gaps_open is backend-supplied; preserve any existing value (the engine
    never invents it). It is genuinely NULLABLE (Bug #5): `null`/unknown means
    "no real review has reported its gap count yet" and is DISTINCT from `0`
    ("a review ran and found zero gaps"). Only `set_gaps_open` (driven by a real
    review_plan return) ever writes a non-null value. We do NOT coerce to 0 here
    — that coercion was the bug: a freshly-PREPARED-but-unfilled review envelope
    left gaps_open at the default and plan-met fired after one un-reviewed pass.

    Extracted VERBATIM; returns ``None`` (unknown) or an ``int``.
    """
    prev = run_record.get("exit_predicate_result") or {}
    gaps_open = prev.get("gaps_open")
    if gaps_open is not None:
        gaps_open = int(gaps_open)
    return gaps_open


def _compute_terminality(run_record: dict) -> dict:
    """B7 helper: compute the phase-scoped + global terminality facts.

    Returns a dict with keys ``current_phase``, ``terminal_phase``, ``scale``,
    ``all_steps_terminal_global`` (bool), ``current_phase_steps`` (list). Extracted
    VERBATIM from ``recompute_predicate``'s terminality block — pure, no mutation.

    The current-phase read routes through ``phase_grammar.current_phase`` (the one
    phase-decision module) rather than a raw ``run_record["loop_phase"]`` subscript —
    byte-identical return (``run_record.get("loop_phase") or "plan"``), and it keeps
    the raw ``loop_phase`` literal out of this module (the AST-lint's single-source
    rule; same convention ``is_orphaned`` follows). Lazy-loaded to preserve the
    load-order discipline the run-record surface needs.

    v0.2.0 fix-pass A.1 (correctness P0 #3 / api-contract AC-2): the work-loop
    exit predicate's terminal check is scoped to the steps in the CURRENT phase,
    not the global step set. Pre-v0.2.0 (steps=[] in the plan phase, the handoff
    synthesized work steps), the global all() was equivalent. v0.2.0 declares
    plan steps explicitly in the workflow (a1's "plan", a2's "plan-1/2/3"); those
    plan steps stay `pending` after plan-done is reached (the plan-loop's
    advance is recorded in plan_step, not via a step state transition). A global
    all_steps_terminal would block work-met forever. Scoping by phase makes each
    phase have its own terminality. terminal_phase from the workflow gates which
    phase's steps count for run-exit (AC-2 — the doc promised this but the code
    didn't honor it). Global all_steps_terminal is retained for the
    exit_predicate_result reporting field (downstream consumers may want it).
    """
    phase_grammar = run_record_core._lazy_load("phase-grammar")
    scale = run_record.get("backend_scale", "three-tier")
    current_phase = phase_grammar.current_phase(run_record)
    terminal_phase = run_record.get("terminal_phase") or "work"
    all_steps_terminal_global = all(
        step_is_terminal(u, scale) for u in run_record.get("steps", [])
    )
    current_phase_steps = [
        u for u in run_record.get("steps", []) if u.get("phase") == current_phase
    ]
    # U4 (finding #4): the eval-phase-scoped terminality — the ONE terminality
    # fact that gates `met` in the work/handoff/done branch. Computed HERE (was
    # inline in _evaluate_met) so both the met decision AND the reported
    # `all_steps_terminal` draw from the same value and can never contradict
    # (met:true beside all_steps_terminal:false was the field-notes #4 bug — the
    # report used the GLOBAL value, which includes the deliberately-pending plan
    # step). "done" is treated as terminal-equivalent: it remaps to terminal_phase
    # steps, mirroring _evaluate_met's post-terminal handling.
    eval_phase = terminal_phase if current_phase == "done" else current_phase
    eval_phase_steps = (
        current_phase_steps
        if current_phase != "done"
        else [u for u in run_record.get("steps", []) if u.get("phase") == terminal_phase]
    )
    all_terminal_in_eval_phase = all(
        step_is_terminal(u, scale) for u in eval_phase_steps
    )
    return {
        "current_phase": current_phase,
        "terminal_phase": terminal_phase,
        "scale": scale,
        "all_steps_terminal_global": all_steps_terminal_global,
        "current_phase_steps": current_phase_steps,
        "eval_phase": eval_phase,
        "eval_phase_steps": eval_phase_steps,
        "all_terminal_in_eval_phase": all_terminal_in_eval_phase,
    }


def _evaluate_met(run_record: dict, counts: tuple, gaps_open, term: dict) -> bool:
    """B7 helper: the phase-aware ``met`` decision, PRE-iteration_pending.

    Extracted VERBATIM from ``recompute_predicate``'s plan/work branch. Returns
    the boolean ``met`` BEFORE the KTD §B iteration_pending AND-NOT suppression
    (the caller composes that). Pure; no mutation.

    ``counts`` is the (blockers, majors, minors) tuple; ``gaps_open`` the nullable
    cached gap count; ``term`` the dict ``_compute_terminality`` returns.

      * ``loop_phase == "plan"`` — plan-loop exit is ``gaps_open == 0 AND
        plan_step == "review_plan"`` (backend-contract §5 + schema §3.1). There
        are no work steps yet, so ``all_steps_terminal`` is NOT a requirement in
        the plan phase. The ``plan_step == "review_plan"`` conjunct mirrors the
        backend coherence guard one-to-one: a DEFAULT ``gaps_open == 0`` BEFORE
        any review has run (at ``plan`` / ``deepen`` / ``null``) must NOT
        short-circuit the loop to met (schema §3.1) — only a completed
        ``review_plan`` whose gap-set is empty closes the plan loop.
      * otherwise (``"work"`` / ``"handoff"`` / ``"done"``) — the work-loop exit,
        SCALE-AWARE on ``backend_scale`` (§2.2 ``met`` row):
          - ``"three-tier"`` (CE; the default for any missing/unknown value):
            ``blockers == 0 AND majors == 0 AND all_steps_terminal AND steps``.
          - ``"blocker-only"`` (native): majors are advisory (surfaced at exit,
            not gating), so ``blockers == 0 AND all_steps_terminal AND steps``.
        The ``steps`` (non-empty) conjunct closes the vacuous-exit hole: a work
        phase with ZERO dispatched steps must NOT declare done (``all([]) ==
        True`` would otherwise short-circuit it before any fan-out). A *plan*
        phase with no steps is fine — it never reaches this branch.
    """
    blockers, majors, minors = counts
    scale = term["scale"]
    current_phase = term["current_phase"]
    terminal_phase = term["terminal_phase"]
    current_phase_steps = term["current_phase_steps"]

    if current_phase == "plan":
        # Plan-loop exit: a REAL review reported zero gaps AND a review_plan
        # actually ran (§3.1). Bug #5: gaps_open must be NON-NULL — a null/unknown
        # gap count means no review has filled it yet, so plan-met cannot fire. The
        # live CE/native backends return a PREPARE envelope WITHOUT a gap_set (the
        # model fills gaps out-of-band), so set_gaps_open is not called and
        # gaps_open stays null; without the `is not None` guard a default 0 would
        # short-circuit plan-met after a SINGLE un-reviewed pass and the deepen-
        # refinement loop would be unreachable. The plan_step conjunct is kept
        # belt-and-braces; the load-bearing new conjunct is `gaps_open is not None`.
        met = (
            gaps_open is not None
            and gaps_open == 0
            and run_record.get("plan_step") == "review_plan"
        )
    else:
        # Work-loop exit, SCALE-AWARE (Bug #3 — backend_scale was stored but never
        # read). The native backend declares backend_scale="blocker-only": its
        # majors are advisory (surfaced at exit) and do NOT gate the loop, so a
        # native run with majors>0 / blockers==0 must still be able to exit.
        # CE (or any missing/unknown value) defaults to the three-tier gate where
        # majors DO gate. Unknown → three-tier is the safe default (gates more,
        # never under-blocks). I-2: all_steps_terminal stays required either way.
        # `scale` is read once above and also drives step_is_terminal so the
        # terminality check and the met predicate agree on whether majors gate.
        # Whether majors gate is decided by the SINGLE helper (the one source of
        # truth) — never a hardcoded scale comparison here.
        no_majors = "major" not in gating_severities(scale) or majors == 0
        # Bug #4 — vacuous work-phase exit. all([]) is vacuously True, so a
        # phase flip with ZERO steps dispatched would declare met before the
        # dispatcher fans out work. The phase-scoped check
        # (all_terminal_in_eval_phase + has_steps_in_phase) addresses both this AND
        # the v0.2.0 fix-pass A.1 (plan steps in declared workflows shouldn't gate
        # the work-loop's terminal check).
        # AC-2 fix: `met` requires loop_phase == terminal_phase (the run doesn't
        # exit until the terminal phase is reached AND its own steps are terminal).
        # Post-terminal: "done" is the exit sentinel set BY a met-triggered pulse
        # (the LAST member of LOOP_PHASES, never a member of any workflow's
        # phase_order). At "done", phase-scoped steps would be empty (no step
        # declares phase=done), so we'd vacuously flip met→false on the recompute
        # that fires when set_loop writes "done". Treat "done" as
        # terminal-equivalent for predicate purposes: the run already exited at
        # terminal_phase; "done" preserves that state. Any FUTURE post-terminal
        # sentinel (aborted/error/…) added to LOOP_PHASES would need the same
        # treatment here; today "done" is the only post-terminal value.
        # For v0.2.0's workflows terminal_phase is always "work"; v0.2.1's A3 will
        # have non-work terminal phases and this gate becomes load-bearing.
        # eval-phase terminality is computed ONCE in _compute_terminality (U4) so
        # `met` here and the reported `all_steps_terminal` cannot diverge.
        eval_phase = term["eval_phase"]
        eval_phase_steps = term["eval_phase_steps"]
        all_terminal_in_eval_phase = term["all_terminal_in_eval_phase"]
        has_steps_in_phase = bool(eval_phase_steps)
        met = (
            eval_phase == terminal_phase
            and blockers == 0
            and no_majors
            and all_terminal_in_eval_phase
            and has_steps_in_phase
        )
    return bool(met)


def recompute_predicate(run_record: dict) -> dict:
    """Compute ``exit_predicate_result`` purely from the run-record's current state.

    Counts findings across all steps, computes ``all_steps_terminal``, and sets
    ``met`` PHASE-AWARELY (I-2, contract §5). See the B7 helpers
    (``_count_severities_by_step``, ``_read_cached_gaps_open``,
    ``_compute_terminality``, ``_evaluate_met``, ``_compute_iteration_pending``)
    for the decomposed pure steps — this function is their composition.

    v0.3.0 (U2 / KTD §B): the returned dict gains an ``iteration_pending: bool``
    field, and the new met rule is ``met = (existing met conditions) AND NOT
    iteration_pending``. ``iteration_pending`` is True iff the run declares an
    ``iteration`` block AND the gate step's verdict.decision is ``"iterate"``
    AND the bound is unbreached (``iteration_attempts < max_attempts`` AND
    ``active_wall_seconds < max_wall_seconds``). Without the AND-NOT clause, a
    workflow that emits new plan-N steps while ``loop_phase == "work"`` would see
    work-met fire spuriously (the work-loop branch above scopes terminality to
    current-phase steps; pending plan-N steps are phase=plan, invisible) — see
    KTD §A. The gate-decision read routes through ``iteration.read_decision`` to
    keep the run-record surface off the AST-lint's allowlist for that semantic — the
    lint permits the literal in the writer site but the convention is to consume
    via the centralized reader (mirrors how ``is_orphaned`` reads ``loop_phase``
    via ``phase_grammar.current_phase`` rather than raw subscript).

    Returns the new dict (does NOT mutate ``run_record``; the caller assigns it).
    """
    blockers, majors, minors = _count_severities_by_step(run_record)
    gaps_open = _read_cached_gaps_open(run_record)
    term = _compute_terminality(run_record)
    met = _evaluate_met(run_record, (blockers, majors, minors), gaps_open, term)

    # v0.3.0 KTD §B — iteration_pending composition. Compute BEFORE finalizing
    # `met` so the AND-NOT clause can suppress a work-loop met that would
    # otherwise short-circuit the iteration loop (see KTD §A: the pulse's
    # predicate-met short-circuit yields when iteration_pending is True).
    iteration_pending = _compute_iteration_pending(run_record)
    met = bool(met) and not iteration_pending

    return {
        "met": bool(met),
        "blockers": blockers,
        "majors": majors,
        "minors": minors,
        "gaps_open": gaps_open,
        # U4 (finding #4): report the EVAL-phase-scoped terminality — the same
        # value that gates `met` — so the exit report is never self-contradictory
        # (met:true beside all_steps_terminal:false). The GLOBAL value (which
        # includes the deliberately-pending plan step) is retained under an
        # explicit key for any consumer that genuinely wants cross-phase
        # terminality; all current consumers use this field only for reason/display
        # text, so phase-scoping makes those messages accurate.
        "all_steps_terminal": bool(term["all_terminal_in_eval_phase"]),
        "all_steps_terminal_global": bool(term["all_steps_terminal_global"]),
        "iteration_pending": iteration_pending,
    }


def _compute_iteration_pending(run_record: dict) -> bool:
    """Compute KTD §B's iteration_pending bool for ``recompute_predicate``.

    Thin delegating wrapper over ``iteration.compute_pending_state`` — the
    bound-check logic itself lives in ``lib/iteration.py`` (the ONE
    iteration-decision module per the AST lint). This file keeps the wrapper
    purely so ``recompute_predicate`` has a single in-file callable and the
    lazy-load idiom stays localized.

    Previously this function open-coded the bound check; that copy was lifted
    into ``iteration.compute_pending_state`` so this file holds only the thin
    wrapper. The comparison is still deliberately duplicated INSIDE iteration.py
    (``evaluate_decision`` + ``compute_pending_state``) because their coercion +
    cap policies diverge and both are load-bearing — see that module's
    "Deliberate bound-check duplication" note; not an open TODO.

    Brittleness contract (rel-2): ``compute_pending_state`` swallows
    coercion errors on the numeric bound fields and returns ``False`` on
    bad input — a corrupted ``iteration_attempts`` MUST NOT raise from
    ``_atomic_write`` and lock every subsequent run-record write, including the
    one needed to recover.
    """
    iteration = run_record_core._lazy_load("iteration")
    return iteration.compute_pending_state(run_record)


def is_orphaned(run_record: dict, now=None) -> bool:
    """I-3 orphan predicate (§5), excluding handoff-paused surfacing (U7's concern).

    Resumable iff current phase != "done" AND (driver == "manual" OR last_beat_at
    older than GRACE_SECONDS).

    P2-10: routes the current-phase read through ``phase_grammar.current_phase``
    for consistency with the rest of the codebase (the AST lint allows the raw
    literal in the run-record surface, but the convention is to read the field through
    the one phase-decision module). Lazy import to avoid module-load ordering
    surprises (the run-record surface is loaded from many sites, sometimes before
    sys.path is set up for sibling modules).
    """
    # Lazy load: phase-grammar.py is a sibling lib module; loading it at
    # module import time would create a load-order dependency, so we defer.
    phase_grammar = run_record_core._lazy_load("phase-grammar")

    if phase_grammar.current_phase(run_record) == "done":
        return False
    loop = run_record.get("loop") or {}
    if loop.get("driver") == "manual":
        return True
    last_beat = run_record_core.parse_iso(loop.get("last_beat_at"))
    if last_beat is None:
        # No beat ever recorded on a non-done run => treat as resumable.
        return True
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    age = (now - last_beat).total_seconds()
    return age > run_record_core.GRACE_SECONDS
