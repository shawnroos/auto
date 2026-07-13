#!/usr/bin/env python3
"""auto U1 (v0.3.0): the ONE iteration-decision module.

Every site that reads a gate step's `decision` field — the pulse's iteration
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
commit `81de3e0` — `set_winner_step_id`): `record_verdict` normalizes findings
to `{severity, note}` only. A `decision` field on findings would be silently
stripped on the canonical write path. `dispatch_context` is preserved by
`transition()` and the verdict-write path with no normalize step. v0.3.0
mirrors the precedent exactly via `set_verdict_decision`.

Loaded via `_bootstrap.load_lib_module("iteration")`.
"""

from __future__ import annotations

import math

# Kill-switch parity with pulse.advance_iteration_loop (G1 / rel-r2-1).
# `_bootstrap` is on sys.path before this module loads: every caller of
# `load_lib_module("iteration")` (pulse.py at module top, ledger.py via
# `_lazy_load`) prepends lib/ to sys.path first. Importing the symbol here is
# the same shape pulse.py uses at line 60. The fence has to hold on the READ
# side (compute_pending_state) too — without it, a kill-switched mid-iteration
# run still computes iteration_pending=True from the gate's stale "iterate"
# verdict, which blocks the predicate's `met` branch via the AND-NOT clause
# and leaves /auto-resume abort as the only escape. F5 unfenced the write
# side (pulse.py:624); G1 mirrors it on the read side so the standard
# predicate-met flow takes over when the operator flips the switch.
from _bootstrap import is_iteration_disabled  # noqa: E402

# The three legal values a gate step's verdict.decision may carry. The engine
# reads `decision_effective` from `evaluate_decision()` and routes on it; raw
# step-side reads MUST go through `read_decision()` so the AST lint can hold.
DECISIONS = ("advance", "iterate", "exit")

# ── Deliberate bound-check duplication (do NOT naively merge) ────────────────
# The iterate-bound comparison (attempts vs max_attempts, active_wall vs
# max_wall) is written twice in this module: `evaluate_decision` (engine
# decision path) and `compute_pending_state` (the recompute path called from
# `_atomic_write` on EVERY write). They are kept separate on purpose because
# both policies are load-bearing and genuinely differ:
#   • Coercion — evaluate_decision uses raw int()/float() that RAISE on a
#     corrupt bound (→ an operator-visible ITERATION_CHECK_FAILED F2 stop);
#     compute_pending_state uses _try_int/_try_float that DEGRADE to False so
#     the recompute never raises and never locks the ledger. A shared
#     never-raise helper would silently convert F2's diagnostic stop into
#     continuation on a torn bound.
#   • Cap applicability — evaluate_decision treats max_attempts == 0 as "no
#     cap" (the `max_attempts > 0` guard); compute_pending_state treats a
#     PRESENT max_attempts (incl. explicit 0) as a real cap. Preserved, not
#     reconciled.
# Merging the comparison would require collapsing these — so the duplication is
# a documented trade, not an open "close the dimension" TODO.


# ── dispatch_context: the typed key set + thin accessors (U12) ───────────────
# `dispatch_context` is the additive per-step bag `transition()` preserves
# verbatim (no normalize step). Historically every consumer read it via
# `(u.get("dispatch_context") or {}).get("<literal>")` — a shape that SWALLOWS a
# typo: `.get("enumarated_steps")` returns None just like a real miss. Declaring
# the key set ONCE + reading through `read_dc` turns a misspelled key into a loud
# KeyError at the accessor instead of a silent None. `read_decision` (the
# centralized decision reader the AST lint pins here) now delegates to `read_dc`,
# so the "decision" literal still lives only in this module.
DISPATCH_CONTEXT_KEYS = frozenset({
    "decision",
    "decision_payload",
    "winner_step_id",
    "judge_verdicts",
    "enumerated_steps",
    "bound_override",
    "requirements_doc",
    "plan_path",
    "cluster_findings",
    "bias",
    "plan_items",
})


def read_dc(step: dict, key: str, default=None):
    """Typed read of a single `dispatch_context` key off a step.

    Raises ``KeyError`` if `key` is not a declared `dispatch_context` key — a
    MISSPELLED key name fails loud at the accessor instead of silently returning
    None the way `(dc or {}).get("<typo>")` would. A declared-but-ABSENT key
    returns `default` (None), matching the prior `.get()` semantics for a real
    miss. Thin by design: no coercion, no isinstance guards — a caller that needs
    to distinguish a non-dict `dispatch_context` keeps its own guard.
    """
    if key not in DISPATCH_CONTEXT_KEYS:
        raise KeyError(
            f"read_dc: {key!r} is not a declared dispatch_context key; "
            f"known keys: {sorted(DISPATCH_CONTEXT_KEYS)!r}"
        )
    return (step.get("dispatch_context") or {}).get(key, default)


def read_decision(step: dict):
    """Return the gate step's verdict.decision, or None if not set.

    Reads from `step.dispatch_context.decision` — the v0.3.0 channel established
    by `lib/ledger.py::set_verdict_decision`. NEVER from `findings[]` (which
    `record_verdict` normalizes to `{severity, note}`). This is the ONE function
    every caller routes through; the AST lint enforces it.
    """
    return read_dc(step, "decision")


# Named thin accessors for the read-heavy keys — one call per consumer read site
# so a typo becomes an AttributeError on the module, not a swallowed None. Keys
# with no live read site (`bias`, `plan_items` — producer-WRITTEN only) stay in
# `DISPATCH_CONTEXT_KEYS` and are reachable via `read_dc` without a named alias.
def read_enumerated_steps(step: dict):
    """The plan step's enumerated work-step list (producer-persist), or None."""
    return read_dc(step, "enumerated_steps")


def read_winner_step_id(step: dict):
    """The judge gate's chosen winner step id, or None."""
    return read_dc(step, "winner_step_id")


def read_judge_verdicts(step: dict):
    """The gate's persisted judge verdicts map, or None."""
    return read_dc(step, "judge_verdicts")


def read_bound_override(step: dict):
    """The gate's bound-override record ({bound, original_decision, ...}), or None."""
    return read_dc(step, "bound_override")


def read_requirements_doc(step: dict):
    """The brainstorm/plan step's requirements-doc path, or None."""
    return read_dc(step, "requirements_doc")


def read_plan_path(step: dict):
    """The plan step's durable plan_path, or None."""
    return read_dc(step, "plan_path")


def read_decision_payload(step: dict):
    """The gate's per-iteration decision payload dict, or None."""
    return read_dc(step, "decision_payload")


def _find_gate_step(ledger: dict, gate_step_id: str) -> dict:
    """Find the gate step in the ledger; raise on not-found.

    Mirrors `lib/ledger.py::_find_step` shape — a missing gate_step_id is a
    recipe bug (validator should have caught it) and must surface loudly, not
    return None which would let the iteration check silently no-op.
    """
    for u in ledger.get("steps", []):
        if u.get("id") == gate_step_id:
            return u
    raise KeyError(
        f"iteration.evaluate_decision: gate_step_id {gate_step_id!r} not in "
        f"ledger.steps; known ids: "
        f"{sorted(u.get('id') for u in ledger.get('steps', []))!r}"
    )


def resolve_gate_verification(ledger: dict, gate_step_id: str, *, repo_root=None, judge_verdicts=None) -> dict:
    """v0.7.0 (U4): run a gate step's typed ``verification`` criteria and fold
    them into an advance/iterate SIGNAL via ``verification.aggregate`` (KTD-6).

    Pure of ledger WRITES (so it is unit-testable without a live run): it runs
    the gate's ``programmatic`` criteria in-process
    (``verification.evaluate_programmatic``), folds in any already-supplied judge
    verdicts (``advisor_judge`` / ``model_judge`` / ``human`` — passed in, or
    previously persisted on ``dispatch_context.judge_verdicts`` by the driver in
    U5), and returns ``{"signal", "pending_judges", "programmatic_results"}``.

    The CALLER (pulse/driver) commits a non-None ``signal`` as the gate's decision
    via ``ledger_mutators.set_verdict_decision`` — keeping the decision write
    centralized (``tests/unit/iteration-ast-lint.test.sh``). When
    ``pending_judges`` is non-empty the signal is None: the gate cannot decide
    until the driver supplies those verdicts.

    A gate step with no ``verification`` block returns ``signal=None`` and no
    pending judges — legacy gates (a1/a2/a4) are unaffected (the field is
    additive and they never carry it).
    """
    gate = _find_gate_step(ledger, gate_step_id)
    crits = gate.get("verification") or []
    if not crits:
        return {"signal": None, "pending_judges": [], "programmatic_results": {}}
    from _bootstrap import load_lib_module  # lazy: avoid import-order coupling

    verification = load_lib_module("verification")
    programmatic_results = {}
    for c in crits:
        if c.get("type") == "programmatic":
            res = verification.evaluate_programmatic(c, cwd=repo_root)
            programmatic_results[res["criterion_id"]] = res["status"]
    jv = dict(judge_verdicts or {})
    existing = read_judge_verdicts(gate) or {}
    for k, val in existing.items():
        jv.setdefault(k, val)
    agg = verification.aggregate(crits, programmatic_results, jv)
    return {
        "signal": agg["signal"],
        "pending_judges": agg["pending_judges"],
        "programmatic_results": programmatic_results,
    }


def evaluate_decision(ledger: dict, gate_step_id: str, now_monotonic=None) -> dict:
    """Compute the iteration decision the engine should honor THIS pulse.

    Reads the gate step's `dispatch_context.decision` (via `read_decision`) AND
    the ledger's `iteration.bound` block, then composes them: `iterate` under
    bound stays `iterate`; `iterate` over bound forces to `exit` and surfaces
    `bound_breached: True` + `bound_type` so the engine's caller can record
    `bound_override` on the gate step (per KTD §D).

    Returns a dict with five fields (always all present):
        decision_effective: "advance" | "iterate" | "exit" | None
        original_decision:  the raw read (or None)
        bound_breached:     True iff engine overrode iterate→exit
        bound_type:         "max_attempts" | "max_wall_seconds" | None
        attempts_made:      ledger["iteration_attempts"] (top-level int field)

    `now_monotonic` is reserved for future use (a wall-time-from-now bound
    check that doesn't depend on the ledger's `active_wall_seconds` accumulator
    — useful for emergency stop in long-running pulses). v0.3.0 reads the
    accumulator off the ledger and ignores `now_monotonic`.

    The bound check fires on the ATTEMPTS COUNTER PRE-INCREMENT — if
    iteration_attempts is already at max_attempts when the gate writes
    iterate, that next iterate would be the (max_attempts+1)-th attempt;
    engine overrides to exit. The caller (pulse's advance_iteration_loop)
    increments iteration_attempts ONLY when honoring an iterate (not when
    overriding to exit), so the counter tracks honored iterations.
    """
    gate = _find_gate_step(ledger, gate_step_id)
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
            f"iteration.evaluate_decision: gate step {gate_step_id!r} "
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
    pulse.advance_iteration_loop) reads the SAME rule through this module.
    Mirrors ``evaluate_decision``'s bound math without surfacing the
    ``decision_effective``/``bound_type`` envelope ``recompute_predicate``
    doesn't need.

    True iff:
        - The run declares an ``iteration`` block.
        - The block names a ``gate_step`` that exists in ``steps[]``.
        - The gate step's ``dispatch_context.decision == "iterate"``.
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
    iteration.py is THE iteration-decision module; the bound check
    ``ledger._compute_iteration_pending`` used to open-code was lifted here so
    the recompute path and the engine path live in one module. The comparison
    is still deliberately written twice (here + ``evaluate_decision``) — see the
    module-level "Deliberate bound-check duplication" note for why not to merge.

    Kill-switch parity (G1 / rel-r2-1): when ``CLAUDE_AUTO_DISABLE_ITERATION=1``
    is set, return False unconditionally — symmetric with the write-side
    short-circuit at ``pulse.advance_iteration_loop`` (lib/pulse.py:624).
    Without this, a kill-switched mid-iteration run can't exit via the
    standard predicate-met path: the gate's stale ``decision="iterate"``
    still composes ``iteration_pending=True`` into the predicate, blocking
    ``met`` via the AND-NOT clause. The operator's only escape would be
    ``/auto-resume abort``. With the parity, flipping the switch lets the
    run exit normally.
    """
    if is_iteration_disabled():
        return False

    # v0.3.0 G2 / ADV-R2-1: shape-corruption shield. ``iteration`` may be any
    # JSON-deserializable value if the ledger is torn (e.g. a non-dict scalar
    # from a partial write or a corrupted recovery); the subsequent
    # ``.get(...)`` calls would raise AttributeError, which would propagate
    # through ``_atomic_write -> recompute_predicate`` and block the very
    # ledger writes F2 needs to mark the loop done. Fence here before the
    # "no iteration declared" check (None stays the legitimate signal).
    iter_block_raw = ledger.get("iteration")
    if iter_block_raw is not None and not isinstance(iter_block_raw, dict):
        return False

    iteration_block = iter_block_raw
    if not iteration_block:
        return False
    gate_step_id = iteration_block.get("gate_step")
    if not gate_step_id:
        return False
    gate_step = None
    for u in ledger.get("steps", []):
        if u.get("id") == gate_step_id:
            gate_step = u
            break
    if gate_step is None:
        return False
    if read_decision(gate_step) != "iterate":
        return False

    bound = iteration_block.get("bound") or {}
    # v0.3.0 H / corr-r3-1: shape guard on iteration.bound — symmetric with
    # G2's top-level iteration guard (line 259-260) and G7's render-side
    # bound guard (auto-status.py:165-168). Without this, a torn ledger
    # writing iteration.bound="corrupted" survives `or {}` (truthy non-dict
    # string) and the subsequent `bound.get(...)` raises AttributeError —
    # which propagates through _atomic_write→recompute_predicate and blocks
    # the very ledger writes F2 needs to mark the loop done.
    if not isinstance(bound, dict):
        return False

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
