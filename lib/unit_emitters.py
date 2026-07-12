#!/usr/bin/env python3
"""auto U5b (v0.2.0): the phase-transition producer registry (G1).

Recipes declare WHAT topology to run; producers are HOW work units come into being
at a phase boundary. v0.1.x produced work units off-ledger (the seam paused for
manual creation); v0.2.0 makes emission a first-class, in-engine step so A2/A4
actually spawn their units.

THE PRODUCER (the F4 gap that almost shipped): producers do NOT invent plan output
— they read it from `unit["dispatch_context"]["enumerated_units"]`, which the
engine persists when a plan unit reaches `plan-done` by calling the backend's
`enumerate_plan_units` op (U6 wires the persist; the backend op is the v0.2.0
contract re-lock). So the data flow is: plan-loop runs → backend enumerates the
plan's work units → engine stashes them on the plan unit → producer reads + shapes
them into ledger units at the phase boundary.

PRODUCERS ARE PURE (F3): each is `(ledger, to_phase) -> list[new_unit_dict]`. They
READ the ledger dict and RETURN new partial unit dicts. They MUST NOT call ledger
mutators — `ledger.transition_and_emit` calls them INSIDE its locked write, and a
re-entrant mutator would deadlock on the flock. The primitive appends + normalizes
what they return.

V1 ships exactly 3 producers (A3's `review_findings_to_plan_input` deferred with A3,
KTD-14). The NAME registry below is what `recipes.V1_PRODUCER_NAMES` mirrors; a
test asserts the two sets match so a recipe can't name a producer that isn't here.
"""

from __future__ import annotations

import os
import sys

# Import recipes via the standard bootstrap so producer errors share the
# RecipeError hierarchy: a judge that names no winner is a recipe-shape
# violation (the recipe declared an A2 topology but the judge did not produce
# the verdict the topology requires). Using the same exception class as the
# validator lets callers `except recipes.RecipeError` once and catch the
# whole "recipe-contract violation" class regardless of which side raised.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

recipes = load_lib_module("recipes")
RecipeError = recipes.RecipeError
# U12: typed `dispatch_context` accessors (iteration is a `_bootstrap`-only leaf,
# so this adds no import cycle) — reads route through named accessors so a
# misspelled key trips a KeyError at the accessor, not a swallowed None. Aliased
# `_iteration` because `iterate_template` binds a LOCAL `iteration` (the ledger's
# iteration block) that would otherwise shadow the module.
_iteration = load_lib_module("iteration")


def _enumerated_units(unit: dict) -> list:
    """The work units a plan unit produced, stashed by the engine at plan-done.

    Read from `dispatch_context.enumerated_units` (the backend's
    `enumerate_plan_units` output, persisted in U6's advance path). Empty list if
    the plan produced nothing (the caller/predicate handles the vacuous case).
    """
    return list(_iteration.read_enumerated_units(unit) or [])


def _plan_units(ledger: dict) -> list:
    return [u for u in ledger.get("units", []) if u.get("phase") == "plan"]


def _brainstorm_units(ledger: dict) -> list:
    return [u for u in ledger.get("units", []) if u.get("phase") == "brainstorm"]


def plan_output_to_work_units(ledger: dict, to_phase: str) -> list:
    """A1: the single plan unit's enumerated output → one work unit per item.

    The classic plan→work emission. With one plan unit (A1), reads its
    enumerated_units and emits each as a `to_phase` unit with no dependencies.
    """
    plan_units = _plan_units(ledger)
    if not plan_units:
        return []
    # A1 has exactly one plan unit; if a recipe somehow has more here, take the
    # first (A2's multi-plan path uses judge_winner_to_work_units instead).
    items = _enumerated_units(plan_units[0])
    return [
        {"id": item["id"], "phase": to_phase,
         "depends_on": item.get("depends_on") or [],
         "invokes": item.get("invokes", {}),
         "dispatch_context": item.get("dispatch_context", {})}
        for item in items
    ]


def brainstorm_output_to_plan_unit(ledger: dict, to_phase: str) -> list:
    """Spine (v0.6.0 / U8): the brainstorm unit's output → ONE plan unit.

    The brainstorm-rooted spine (``recipes/pipeline.json``,
    ``phase_order ["brainstorm","plan","seam","work"]``) fires this producer on
    arrival at ``plan`` from ``brainstorm`` (KTD-2). ce-brainstorm produces a
    requirements document; the model records that doc's path on the brainstorm
    unit's ``dispatch_context.requirements_doc`` when the brainstorm completes.
    This producer reads that path and materializes the single structural plan
    unit the plan-loop then drives — exactly the shape ``a1`` declares at init
    (``invokes.adapter_op == "next_plan_step"``), so the downstream plan→work
    machinery is unchanged for both plan-entry (a1) and brainstorm-entry (spine).

    PURE (mirrors ``plan_output_to_work_units``): reads the ledger dict, returns
    a one-element list of a partial 5-key unit dict; no ledger mutation. The
    requirements-doc path flows onto the plan unit's ``dispatch_context`` so the
    plan backend op has the brainstorm output as input.

    Raises ``RecipeError`` (the recipe-shape error class, matching the A2/A4
    producer failure surface) when no brainstorm unit carries an output — a
    silent empty emit would leave the plan phase with no unit and the run would
    re-arm against a vacuous plan phase forever.
    """
    brainstorm_units = _brainstorm_units(ledger)
    if not brainstorm_units:
        raise RecipeError(
            "brainstorm_output_to_plan_unit: no 'brainstorm' unit in ledger — "
            "the spine recipe must declare a brainstorm unit whose output seeds "
            "the plan phase"
        )
    # The spine has exactly one brainstorm unit; read its recorded output.
    requirements_doc = _iteration.read_requirements_doc(brainstorm_units[0])
    if not requirements_doc:
        raise RecipeError(
            "brainstorm_output_to_plan_unit: brainstorm unit "
            "dispatch_context.requirements_doc is missing — the brainstorm step "
            "must record the requirements-doc path before the plan phase can be "
            "seeded (a silent empty emit would leave plan with no unit)"
        )
    return [
        {
            "id": "plan",
            "phase": to_phase,
            "depends_on": [],
            "invokes": {"adapter_op": "next_plan_step"},  # format-v1 key; flips in U6
            "dispatch_context": {"requirements_doc": requirements_doc},
        }
    ]


def judge_winner_to_work_units(ledger: dict, to_phase: str) -> list:
    """A2: emit the WINNING plan's enumerated output as work units.

    The judge unit names the winner via ``dispatch_context.winner_unit_id``
    (fix-pass I — v0.2.0 round-2 P0 fix). The previous design read it from
    ``findings[].winner_unit_id``, but the canonical write path
    ``ledger.record_verdict`` normalizes findings to ``{severity, note}``
    only, hard-stripping every other key — so a real judge agent calling
    record_verdict would have its winner_id silently dropped before the
    producer ever ran. Production A2 was unrunnable end-to-end.

    dispatch_context is the right home: it's already where the engine
    persists ``enumerated_units`` (the parallel routing channel), it survives
    ``transition()`` and the verdict-write path with no normalize step, and
    findings stay narrow ``{severity, note}`` (matching the schema doc).

    The winner_id is written by ``ledger.set_winner_unit_id(judge_unit_id,
    winner)`` — a tiny mutator that the judge agent (or its launcher) calls
    alongside ``record_verdict``. Raises if no winner is named (malformed
    judge verdict is a hard error, not silent empty emission).

    v0.3.0 generalization (KTD §D / U3): the gate unit id is read from
    ``ledger.iteration.gate_unit`` (defaulting to literal ``"judge"`` so
    v0.2.0 a2 ledgers without an iteration block keep working). This lets a
    recipe rename the gate unit without forking the producer.
    """
    gate_unit_id = (ledger.get("iteration") or {}).get("gate_unit", "judge")
    judge = next(
        (u for u in ledger.get("units", []) if u.get("id") == gate_unit_id), None
    )
    if judge is None:
        raise RecipeError(
            f"judge_winner_to_work_units: no {gate_unit_id!r} unit in ledger"
        )
    winner_id = _iteration.read_winner_unit_id(judge)
    if not winner_id:
        raise RecipeError(
            "judge_winner_to_work_units: judge dispatch_context.winner_unit_id "
            "is missing — the judge must call ledger.set_winner_unit_id(...) "
            "alongside record_verdict to declare the winning plan unit"
        )
    winner = next(
        (u for u in ledger.get("units", []) if u.get("id") == winner_id), None
    )
    if winner is None:
        raise RecipeError(
            f"judge_winner_to_work_units: winner {winner_id!r} not in ledger"
        )
    items = _enumerated_units(winner)
    return [
        {"id": item["id"], "phase": to_phase,
         "depends_on": item.get("depends_on") or [],
         "invokes": item.get("invokes", {}),
         "dispatch_context": item.get("dispatch_context", {})}
        for item in items
    ]


def plan_output_to_paired_builders(ledger: dict, to_phase: str) -> list:
    """A4: emit two bias-differentiated builders. v0.3.0 U6: `compare` is now
    declared structurally in `units[]` (with `depends_on: [build-clarity, build-perf]`
    forward-referencing the bias-builder emit_template's id_prefix), so this
    producer only emits the two builders — the comparator is already on the
    ledger from init.

    The plan's enumerated output is built TWICE — once clarity-biased, once
    perf-biased. The two builders carry their bias in `dispatch_context.bias`;
    the structurally-declared `compare` reviews. Removing `compare` from this
    producer's output is U6's "compare structural" contract — closes round-2 P0 #7
    (the validator special case + the dual-source compare definition).
    """
    plan_units = _plan_units(ledger)
    if not plan_units:
        return []
    items = _enumerated_units(plan_units[0])
    if not items:
        return []
    out = []
    for bias in ("clarity", "perf"):
        bid = f"build-{bias}"
        out.append({
            "id": bid, "phase": to_phase, "depends_on": [],
            "invokes": {"adapter_op": "do_unit"},  # format-v1 key; flips in U6
            "dispatch_context": {"bias": bias, "plan_items": items},
        })
    return out


def iterate_template(ledger: dict, to_phase: str) -> list:
    """v0.3.0 / KTD §D: re-emit units from a recipe-declared emit_template.

    Materializes ``emit_count`` new units off the recipe's named template at
    iteration time. Drives the outcomes-gated loop: the gate unit verdicts
    ``iterate`` with a payload, the engine calls this producer through
    ``emit_within_phase``, new sibling units land inside the gate's current
    phase, and the gate unit resets to pending with extended ``depends_on``.

    The id contract is monotonic — the Nth unit emitted across the WHOLE run
    gets id ``id_prefix + (counter+N)`` where ``counter`` is the pre-emit
    ``ledger["iteration_emit_count"]``. The producer NEVER recounts existing
    units (round-3 P0-R3-2): after a partial-emit crash the counter may
    exceed the surviving unit count, and recount-based id assignment would
    re-use ids that previously existed and got lost. The counter only ever
    advances; ``_apply_emit`` (lib/ledger.py) bumps it under the flock once
    PER emitted unit, after this function returns.

    Reads (pure, no ledger mutation):
      - ``ledger.iteration.gate_unit`` → gate unit id (required; the U5
        validator enforces this on the recipe, but defense-in-depth: a
        freshly-mutated ledger missing this field is a recipe-shape error).
      - ``ledger.iteration.emit_template`` → template name.
      - ``ledger.emit_templates[<name>]`` → ``{phase, invokes, id_prefix}``.
      - Gate unit's ``dispatch_context.decision_payload.emit_count`` → N
        (default 1). Must be int (booleans rejected — ``isinstance(True, int)``
        is True in Python, and a True payload masquerading as 1 is a
        misshapen payload, not a valid emit_count). 1 ≤ emit_count ≤ 10
        (round-3 P1-R3-4: upper bound prevents a misbehaving gate agent from
        DOS-emitting 1000 units in one tick).
      - ``ledger.iteration_emit_count`` (default 0 on v0.2.x-shape ledgers)
        → the monotonic id base.

    Emits N partial unit dicts. Each carries ``phase`` + ``invokes`` from
    the template, an explicit id (so ``_apply_emit``'s setdefault doesn't
    override), an empty ``depends_on`` (the gate unit's depends_on is
    extended by ``reset_for_iteration``, not the new units'), and an empty
    ``dispatch_context`` (the gate's payload is per-iteration; the new
    units are blanks for the next round of plan-work).

    Raises ``RecipeError`` on any contract violation (no iteration block,
    template name not found, emit_count out of range or wrong type, gate
    unit missing from the ledger).
    """
    iteration = ledger.get("iteration")
    if not iteration:
        raise RecipeError(
            "iterate_template: ledger has no 'iteration' block — recipe must "
            "declare iteration.{gate_unit, emit_template} to use this producer"
        )

    gate_unit_id = iteration.get("gate_unit")
    if not gate_unit_id:
        raise RecipeError(
            "iterate_template: iteration.gate_unit is missing — the recipe "
            "must name the gate unit (U5 validator should have rejected this)"
        )

    template_name = iteration.get("emit_template")
    if not template_name:
        raise RecipeError(
            "iterate_template: iteration.emit_template is missing — the recipe "
            "must name the emit_templates entry to re-emit from"
        )

    emit_templates = ledger.get("emit_templates") or {}
    template = emit_templates.get(template_name)
    if template is None:
        raise RecipeError(
            f"iterate_template: emit_templates[{template_name!r}] not in "
            f"ledger; available: {sorted(emit_templates)!r}"
        )

    id_prefix = template.get("id_prefix")
    if not id_prefix:
        raise RecipeError(
            f"iterate_template: emit_templates[{template_name!r}].id_prefix "
            "is missing (U5 validator should have rejected this)"
        )

    # Find the gate unit to read its decision_payload.emit_count.
    gate = next(
        (u for u in ledger.get("units", []) if u.get("id") == gate_unit_id), None
    )
    if gate is None:
        raise RecipeError(
            f"iterate_template: gate unit {gate_unit_id!r} not in ledger.units"
        )

    decision_payload = _iteration.read_decision_payload(gate) or {}
    emit_count = decision_payload.get("emit_count", 1)

    # Validate emit_count. Reject bool first — `isinstance(True, int)` is True
    # in Python, and a True payload silently treated as 1 is a misshapen
    # payload, not a valid emit_count.
    if isinstance(emit_count, bool) or not isinstance(emit_count, int):
        raise RecipeError(
            f"iterate_template: emit_count must be int in [1, 10]; "
            f"got {emit_count!r} (type {type(emit_count).__name__})"
        )
    if emit_count < 1 or emit_count > 10:
        raise RecipeError(
            f"iterate_template: emit_count must be int in [1, 10]; got {emit_count}"
        )

    # Read the monotonic counter — the pre-emit base. _apply_emit (ledger.py)
    # bumps this PER appended unit, AFTER we return. So id math here is pure
    # arithmetic on the pre-emit value; this producer NEVER writes the counter.
    base = int(ledger.get("iteration_emit_count", 0))

    template_phase = template.get("phase", to_phase)
    template_invokes = template.get("invokes") or {}

    return [
        {
            "id": f"{id_prefix}{base + i + 1}",
            "phase": template_phase,
            "depends_on": [],
            "invokes": dict(template_invokes),
            "dispatch_context": {},
        }
        for i in range(emit_count)
    ]


def no_emit(ledger_dict, to_phase):
    """v0.3.0 F2: no-op producer for the iterate path on a recipe that omits
    ``iteration.emit_template``. Returns an empty list so ``_apply_emit``'s
    ``producer(ledger, to_phase) or []`` line treats it as "no new units" —
    ``iteration_emit_count`` stays unchanged (the counter bumps per emitted
    unit) and ``appended`` is []. The default ``caller_depends_on=None`` path
    in ``atomic_iterate_step`` then computes ``gate.depends_on + [] =
    gate.depends_on``, preserving the existing dependency graph; the gate is
    reset (verdict-returned → pending, decision cleared) and
    ``iteration_attempts`` increments, so the existing siblings re-engage on
    the next tick.

    Lives here (B10, v0.3.1) — it's a producer and belongs next to the others.
    NOT in ``REGISTRY``: it's selected by ``tick_advance.advance_iteration_loop``
    as the internal fallback when the recipe declares no ``emit_template``;
    promoting it to a recipe-namable producer would duplicate the "omit
    emit_template" recipe shape with no added authoring expressiveness.
    """
    return []


# NAME → producer function. `recipes.V1_PRODUCER_NAMES` mirrors these keys; a U5b
# test asserts the two sets are equal so a recipe can never name a producer that
# isn't registered here (and the registry can't drift from the validator).
REGISTRY = {
    "plan_output_to_work_units": plan_output_to_work_units,
    "judge_winner_to_work_units": judge_winner_to_work_units,
    "plan_output_to_paired_builders": plan_output_to_paired_builders,
    "iterate_template": iterate_template,
    # v0.6.0 (U8): brainstorm→plan spine producer. Added atomically with the
    # recipes.V1_PRODUCER_NAMES entry so the symmetry test stays green.
    "brainstorm_output_to_plan_unit": brainstorm_output_to_plan_unit,
}


def resolve(name: str):
    """Return the producer function for ``name``, or raise KeyError.

    The seam-handler resolves the recipe's declared producer name through here,
    then hands the function to ``ledger.transition_and_emit``.
    """
    if name not in REGISTRY:
        raise KeyError(f"unknown producer {name!r}; registered: {sorted(REGISTRY)}")
    return REGISTRY[name]
