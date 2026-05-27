#!/usr/bin/env python3
"""auto U1 (v0.3.0): the ONE iteration-decision module.

Every site that reads a gate unit's `decision` field — the tick's iteration
check, `recompute_predicate`'s iteration_pending computation, `/auto-status`'s
reporting — routes through THIS module. The AST lint
(`tests/unit/iteration-ast-lint.test.sh`) forbids the string literal "decision"
as an `ast.Constant` anywhere in `lib/*.py` EXCEPT this file and `lib/ledger.py`
(the writer in `set_verdict_decision`). A new consumer physically cannot
re-introduce a divergent literal access without tripping the lint.

WHY centralize (memory `feedback_plan_documents_transition_code_doesnt_wire_it`):
the dominant v0.2.0 build-bug class was "a rule the prose describes that the
code enforces in some sites but not its siblings." The iteration `decision`
field is exactly that kind of rule once recipes can declare an `iteration`
block. One helper = one place the decision lives.

WHY the field lives on `dispatch_context` (memory v0.2.0 round-2 P0 fix at
commit `81de3e0` — `set_winner_unit_id`): `record_verdict` normalizes findings
to `{severity, note}` only. A `decision` field on findings would be silently
stripped on the canonical write path. `dispatch_context` is preserved by
`transition()` and the verdict-write path with no normalize step. v0.3.0
mirrors the precedent exactly via `set_verdict_decision`.

Loaded via `_bootstrap.load_lib_module("iteration")`.
"""

from __future__ import annotations

import math

# Kill-switch parity with tick.advance_iteration_loop (G1 / rel-r2-1).
# `_bootstrap` is on sys.path before this module loads: every caller of
# `load_lib_module("iteration")` (tick.py at module top, ledger.py via
# `_lazy_load`) prepends lib/ to sys.path first. Importing the symbol here is
# the same shape tick.py uses at line 60. The fence has to hold on the READ
# side (compute_pending_state) too — without it, a kill-switched mid-iteration
# run still computes iteration_pending=True from the gate's stale "iterate"
# verdict, which blocks the predicate's `met` branch via the AND-NOT clause
# and leaves /auto-resume abort as the only escape. F5 unfenced the write
# side (tick.py:624); G1 mirrors it on the read side so the standard
# predicate-met flow takes over when the operator flips the switch.
from _bootstrap import is_iteration_disabled  # noqa: E402

# The three legal values a gate unit's verdict.decision may carry. The engine
# reads `decision_effective` from `evaluate_decision()` and routes on it; raw
# unit-side reads MUST go through `read_decision()` so the AST lint can hold.
DECISIONS = ("advance", "iterate", "exit")


def read_decision(unit: dict):
    """Return the gate unit's verdict.decision, or None if not set.

    Reads from `unit.dispatch_context.decision` — the v0.3.0 channel established
    by `lib/ledger.py::set_verdict_decision`. NEVER from `findings[]` (which
    `record_verdict` normalizes to `{severity, note}`). This is the ONE function
    every caller routes through; the AST lint enforces it.
    """
    return (unit.get("dispatch_context") or {}).get("decision")


def _find_gate_unit(ledger: dict, gate_unit_id: str) -> dict:
    """Find the gate unit in the ledger; raise on not-found.

    Mirrors `lib/ledger.py::_find_unit` shape — a missing gate_unit_id is a
    recipe bug (validator should have caught it) and must surface loudly, not
    return None which would let the iteration check silently no-op.
    """
    for u in ledger.get("units", []):
        if u.get("id") == gate_unit_id:
            return u
    raise KeyError(
        f"iteration.evaluate_decision: gate_unit_id {gate_unit_id!r} not in "
        f"ledger.units; known ids: "
        f"{sorted(u.get('id') for u in ledger.get('units', []))!r}"
    )


def evaluate_decision(ledger: dict, gate_unit_id: str, now_monotonic=None) -> dict:
    """Compute the iteration decision the engine should honor THIS tick.

    Reads the gate unit's `dispatch_context.decision` (via `read_decision`) AND
    the ledger's `iteration.bound` block, then composes them: `iterate` under
    bound stays `iterate`; `iterate` over bound forces to `exit` and surfaces
    `bound_breached: True` + `bound_type` so the engine's caller can record
    `bound_override` on the gate unit (per KTD §D).

    Returns a dict with five fields (always all present):
        decision_effective: "advance" | "iterate" | "exit" | None
        original_decision:  the raw read (or None)
        bound_breached:     True iff engine overrode iterate→exit
        bound_type:         "max_attempts" | "max_wall_seconds" | None
        attempts_made:      ledger["iteration_attempts"] (top-level int field)

    `now_monotonic` is reserved for future use (a wall-time-from-now bound
    check that doesn't depend on the ledger's `active_wall_seconds` accumulator
    — useful for emergency stop in long-running ticks). v0.3.0 reads the
    accumulator off the ledger and ignores `now_monotonic`.

    The bound check fires on the ATTEMPTS COUNTER PRE-INCREMENT — if
    iteration_attempts is already at max_attempts when the gate writes
    iterate, that next iterate would be the (max_attempts+1)-th attempt;
    engine overrides to exit. The caller (tick's advance_iteration_loop)
    increments iteration_attempts ONLY when honoring an iterate (not when
    overriding to exit), so the counter tracks honored iterations.
    """
    gate = _find_gate_unit(ledger, gate_unit_id)
    original = read_decision(gate)

    attempts_made = int(ledger.get("iteration_attempts", 0))
    active_wall_seconds = float(ledger.get("active_wall_seconds", 0))

    # No decision yet (gate hasn't verdicted, or its decision was cleared by
    # the most recent reset_for_iteration) — caller treats this as "no
    # iteration in flight."
    if original is None:
        return {
            "decision_effective": None,
            "original_decision": None,
            "bound_breached": False,
            "bound_type": None,
            "attempts_made": attempts_made,
        }

    if original not in DECISIONS:
        raise ValueError(
            f"iteration.evaluate_decision: gate unit {gate_unit_id!r} "
            f"dispatch_context.decision is {original!r}; must be one of "
            f"{DECISIONS!r}"
        )

    # advance and exit are honored as-is; only iterate is bound-checkable.
    if original != "iterate":
        return {
            "decision_effective": original,
            "original_decision": original,
            "bound_breached": False,
            "bound_type": None,
            "attempts_made": attempts_made,
        }

    # iterate: read the recipe's bound and check.
    iteration = ledger.get("iteration") or {}
    bound = iteration.get("bound") or {}
    max_attempts = int(bound.get("max_attempts", 0)) if bound.get("max_attempts") is not None else 0
    max_wall = bound.get("max_wall_seconds")
    max_wall = float(max_wall) if max_wall is not None else math.inf

    if max_attempts > 0 and attempts_made >= max_attempts:
        return {
            "decision_effective": "exit",
            "original_decision": "iterate",
            "bound_breached": True,
            "bound_type": "max_attempts",
            "attempts_made": attempts_made,
        }

    if active_wall_seconds >= max_wall:
        return {
            "decision_effective": "exit",
            "original_decision": "iterate",
            "bound_breached": True,
            "bound_type": "max_wall_seconds",
            "attempts_made": attempts_made,
        }

    # iterate honored — under bound.
    return {
        "decision_effective": "iterate",
        "original_decision": "iterate",
        "bound_breached": False,
        "bound_type": None,
        "attempts_made": attempts_made,
    }


_COERCE_FAILED = object()  # sentinel: a coercion that couldn't parse its input.


def _try_int(value):
    """Return int(value), or ``_COERCE_FAILED`` on bad type/value.

    Used by ``compute_pending_state`` — a coercion failure on any numeric
    bound field is treated as "ledger numeric state is corrupt; cannot make
    a safe iteration decision; collapse to not-pending so writes still go
    through." Per the "close a dimension, not a sibling" rule (rel-2): the
    predicate-recompute chokepoint must degrade gracefully on bad inputs.
    """
    try:
        return int(value)
    except (TypeError, ValueError):
        return _COERCE_FAILED


def _try_float(value):
    """Float-typed sibling of ``_try_int`` — same graceful-degrade contract."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return _COERCE_FAILED


def compute_pending_state(ledger: dict) -> bool:
    """Return True iff the run has a live iteration in flight (KTD §B).

    THE central iteration-bound logic — every caller (the
    ``recompute_predicate`` -> ``_atomic_write`` chokepoint AND the engine's
    tick.advance_iteration_loop) reads the SAME rule through this module.
    Mirrors ``evaluate_decision``'s bound math without surfacing the
    ``decision_effective``/``bound_type`` envelope ``recompute_predicate``
    doesn't need.

    True iff:
        - The run declares an ``iteration`` block.
        - The block names a ``gate_unit`` that exists in ``units[]``.
        - The gate unit's ``dispatch_context.decision == "iterate"``.
        - Neither bound is breached (``iteration_attempts < max_attempts``
          AND ``active_wall_seconds < max_wall_seconds``).

    Brittleness contract (rel-2): if any of ``iteration_attempts``,
    ``active_wall_seconds``, ``max_attempts``, ``max_wall_seconds`` fails
    to coerce to a number, the function returns ``False`` (the ledger's
    numeric state is corrupt and the safest decision is "not pending" —
    treats the in-flight iteration as advisorially-exited so the ledger
    can continue accepting writes). A single corrupt numeric field MUST
    NOT lock out every subsequent ledger mutation, including writes
    needed to recover — this function is called from ``_atomic_write`` on
    EVERY write.

    Why this lives here and not in ``ledger.py``: the AST lint says
    iteration.py is THE iteration-decision module; the bound-check
    duplicated between ``evaluate_decision`` (lines 130-152 in this file)
    and ``ledger._compute_iteration_pending`` was the NEXT dimension of
    the recurring "rule the prose describes that the code enforces in
    some sites but not its siblings" class — close a dimension, not a
    sibling. Centralizing it here closes the dimension.

    Kill-switch parity (G1 / rel-r2-1): when ``CLAUDE_AUTO_DISABLE_ITERATION=1``
    is set, return False unconditionally — symmetric with the write-side
    short-circuit at ``tick.advance_iteration_loop`` (lib/tick.py:624).
    Without this, a kill-switched mid-iteration run can't exit via the
    standard predicate-met path: the gate's stale ``decision="iterate"``
    still composes ``iteration_pending=True`` into the predicate, blocking
    ``met`` via the AND-NOT clause. The operator's only escape would be
    ``/auto-resume abort``. With the parity, flipping the switch lets the
    run exit normally.
    """
    if is_iteration_disabled():
        return False

    iteration_block = ledger.get("iteration")
    if not iteration_block:
        return False
    gate_unit_id = iteration_block.get("gate_unit")
    if not gate_unit_id:
        return False
    gate_unit = None
    for u in ledger.get("units", []):
        if u.get("id") == gate_unit_id:
            gate_unit = u
            break
    if gate_unit is None:
        return False
    if read_decision(gate_unit) != "iterate":
        return False

    bound = iteration_block.get("bound") or {}

    # max_attempts bound: coerce defensively. ANY coercion failure on either
    # the bound limit OR the counter degrades to "not pending" (rel-2).
    max_attempts_raw = bound.get("max_attempts")
    if max_attempts_raw is not None:
        max_attempts = _try_int(max_attempts_raw)
        if max_attempts is _COERCE_FAILED:
            return False
        attempts = _try_int(ledger.get("iteration_attempts", 0))
        if attempts is _COERCE_FAILED:
            return False
        if attempts >= max_attempts:
            return False

    # max_wall_seconds bound: same graceful-degrade contract.
    max_wall_raw = bound.get("max_wall_seconds")
    if max_wall_raw is not None:
        max_wall = _try_float(max_wall_raw)
        if max_wall is _COERCE_FAILED:
            return False
        active = _try_float(ledger.get("active_wall_seconds", 0))
        if active is _COERCE_FAILED:
            return False
        if active >= max_wall:
            return False

    return True
