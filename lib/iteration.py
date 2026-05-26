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
