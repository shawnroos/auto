#!/usr/bin/env python3
"""auto U5 (v0.2.0): the ONE phase-grammar decision point.

Every site that used to branch on the `loop_phase` string literal — the pulse's
phase switch, the seam/phase-advance handler, `recompute_predicate`'s phase-aware
branch, `_ready_fix_unit`'s phase-awareness, and auto-status's reporting — reads
through THIS module instead of comparing `ledger["loop_phase"]` to a literal.

WHY centralize (memory `feedback_plan_documents_transition_code_doesnt_wire_it`):
the dominant v0.1.x build-bug class was "a rule the prose describes that the code
enforces in some sites but not its siblings." Phase ordering is exactly that kind
of rule once recipes can declare non-default `phase_order`. One helper = one place
the decision lives; the AST lint (tests/unit/phase-grammar-ast-lint.test.sh)
forbids the string literal "loop_phase" anywhere ELSE in lib/, so a new consumer
physically cannot re-introduce a divergent literal comparison.

RECIPE-BLIND DEFAULTS: a v0.1.x ledger has no `phase_order`/`terminal_phase`.
Every accessor here falls back to the legacy grammar (`["plan","seam","work"]`,
terminal `"work"`) so a recipe-blind ledger routes phases EXACTLY as v0.1.1 did.

Loaded via `_bootstrap.load_lib_module("phase-grammar")` (the file name is
hyphenated per repo convention; the registered module name is `phase_grammar`).
"""

from __future__ import annotations

_DEFAULT_PHASE_ORDER = ["plan", "seam", "work"]
_DEFAULT_TERMINAL_PHASE = "work"

# The canonical ledger key. Exported so status-output dicts that mirror the
# ledger field name can reference it instead of a bare "loop_phase" literal —
# this keeps the AST lint (KTD-3) green at output-key sites while still routing
# every phase DECISION through the accessors below. (A reporting key is not a
# phase decision; this constant is the sanctioned way to name the field.)
LOOP_PHASE_KEY = "loop_phase"


def current_phase(ledger: dict) -> str:
    """The run's current phase. Reads `loop_phase` — NEVER `phase_order[0]`.

    Load-bearing for resume: a paused run carries its CURRENT phase in
    `loop_phase`; `phase_order[0]` is the START phase and would be wrong for a
    mid-run resume. Defaults to "plan" for a malformed/absent value (a
    recipe-blind v0.1.x ledger always has `loop_phase`, so the default is only a
    last-resort guard).
    """
    return ledger.get("loop_phase") or "plan"


def phase_order(ledger: dict) -> list:
    """The run's ordered phase sequence; the legacy grammar if recipe-blind."""
    po = ledger.get("phase_order")
    return list(po) if po else list(_DEFAULT_PHASE_ORDER)


def terminal_phase(ledger: dict) -> str:
    """The phase whose completion ends the run; "work" if recipe-blind."""
    return ledger.get("terminal_phase") or _DEFAULT_TERMINAL_PHASE


def is_terminal_phase(ledger: dict, phase: str | None = None) -> bool:
    """True iff `phase` (default: the current phase) is the run's terminal phase.

    The run-exit predicate (`exit_predicate_result.met`) may be true ONLY when the
    current phase is the terminal phase — so a non-default-phase run cannot
    silent-exit before reaching its terminal phase.
    """
    if phase is None:
        phase = current_phase(ledger)
    return phase == terminal_phase(ledger)


def next_phase_after_met(ledger: dict, current: str | None = None) -> str | None:
    """The phase AFTER `current` in `phase_order`, or None if `current` is last.

    Drives phase advancement: when the current phase's work is done and `current`
    is not the terminal phase, the engine advances to this next phase. Returns
    None at the terminal phase (nothing follows). If `current` isn't in the
    order (defensive), returns None.
    """
    if current is None:
        current = current_phase(ledger)
    order = phase_order(ledger)
    try:
        idx = order.index(current)
    except ValueError:
        return None
    return order[idx + 1] if idx + 1 < len(order) else None


def producer_name_for_arrival(ledger: dict, to_phase: str) -> str | None:
    """The producer NAME that fires when the run ARRIVES at ``to_phase``, per the
    ledger's persisted ``phase_transitions``. Returns None when no transition
    declares a producer for this arrival.

    Per recipe-format §4, producer firing is keyed on the ``to`` phase (not the
    ``from``): a transition ``{from: plan, to: work}`` fires the producer when
    the run reaches work, even if it routes through seam. The seam-handler
    looks up the producer for its DESTINATION phase via this helper.

    Returns None in two distinct shapes:
      * legacy ledger (recipe is None or phase_transitions is empty/absent) —
        callers should fall back to a raw ``set_loop`` for backward-compat
        with v0.1.x ledgers resumed under v0.2.0.
      * v0.2.0 ledger with a recipe but no matching ``to_phase`` transition —
        the recipe declares no producer for this arrival; the caller decides
        whether that's a misconfigured recipe (raise) or a legitimate
        pass-through (proceed without emission).

    The caller distinguishes these via ``ledger.get("recipe") is None``.
    """
    transitions = ledger.get("phase_transitions") or []
    for pt in transitions:
        if isinstance(pt, dict) and pt.get("to") == to_phase:
            return pt.get("emitter")
    return None
