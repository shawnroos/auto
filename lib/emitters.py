#!/usr/bin/env python3
"""auto U5b (v0.2.0): the phase-transition emitter registry (G1).

Recipes declare WHAT topology to run; emitters are HOW work units come into being
at a phase boundary. v0.1.x produced work units off-ledger (the seam paused for
manual creation); v0.2.0 makes emission a first-class, in-engine step so A2/A4
actually spawn their units.

THE PRODUCER (the F4 gap that almost shipped): emitters do NOT invent plan output
— they read it from `unit["dispatch_context"]["enumerated_units"]`, which the
engine persists when a plan unit reaches `plan-done` by calling the adapter's
`enumerate_plan_units` op (U6 wires the persist; the adapter op is the v0.2.0
contract re-lock). So the data flow is: plan-loop runs → adapter enumerates the
plan's work units → engine stashes them on the plan unit → emitter reads + shapes
them into ledger units at the phase boundary.

EMITTERS ARE PURE (F3): each is `(ledger, to_phase) -> list[new_unit_dict]`. They
READ the ledger dict and RETURN new partial unit dicts. They MUST NOT call ledger
mutators — `ledger.transition_and_emit` calls them INSIDE its locked write, and a
re-entrant mutator would deadlock on the flock. The primitive appends + normalizes
what they return.

V1 ships exactly 3 emitters (A3's `review_findings_to_plan_input` deferred with A3,
KTD-14). The NAME registry below is what `recipes.V1_EMITTER_NAMES` mirrors; a
test asserts the two sets match so a recipe can't name an emitter that isn't here.
"""

from __future__ import annotations

import os
import sys

# Import recipes via the standard bootstrap so emitter errors share the
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


def _enumerated_units(unit: dict) -> list:
    """The work units a plan unit produced, stashed by the engine at plan-done.

    Read from `dispatch_context.enumerated_units` (the adapter's
    `enumerate_plan_units` output, persisted in U6's advance path). Empty list if
    the plan produced nothing (the caller/predicate handles the vacuous case).
    """
    return list((unit.get("dispatch_context") or {}).get("enumerated_units") or [])


def _plan_units(ledger: dict) -> list:
    return [u for u in ledger.get("units", []) if u.get("phase") == "plan"]


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
        {"id": item["id"], "phase": to_phase, "depends_on": [],
         "invokes": item.get("invokes", {}),
         "dispatch_context": item.get("dispatch_context", {})}
        for item in items
    ]


def judge_winner_to_work_units(ledger: dict, to_phase: str) -> list:
    """A2: emit the WINNING plan's enumerated output as work units.

    The judge unit's findings name the winner via `winner_unit_id`. We read that
    winning plan unit's stashed `enumerated_units` (Gap A resolution — no per-unit
    adapter op param needed; the winner's output was persisted at its plan-done).
    Raises if the judge named no winner (a malformed judge verdict is a hard
    error, not a silent empty emission).
    """
    judge = next(
        (u for u in ledger.get("units", []) if u.get("id") == "judge"), None
    )
    if judge is None:
        raise RecipeError("judge_winner_to_work_units: no 'judge' unit in ledger")
    winner_id = None
    for f in judge.get("findings", []):
        if isinstance(f, dict) and f.get("winner_unit_id"):
            winner_id = f["winner_unit_id"]
            break
    if not winner_id:
        raise RecipeError(
            "judge_winner_to_work_units: judge findings name no winner_unit_id"
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
        {"id": item["id"], "phase": to_phase, "depends_on": [],
         "invokes": item.get("invokes", {}),
         "dispatch_context": item.get("dispatch_context", {})}
        for item in items
    ]


def plan_output_to_paired_builders(ledger: dict, to_phase: str) -> list:
    """A4: emit two bias-differentiated builders + a comparator gating on both.

    The plan's enumerated output is built TWICE — once clarity-biased, once
    perf-biased — then a comparator (depends_on both) picks/merges. The two
    builders carry their bias in `dispatch_context.bias`; the comparator reviews.
    """
    plan_units = _plan_units(ledger)
    if not plan_units:
        return []
    items = _enumerated_units(plan_units[0])
    if not items:
        return []
    out = []
    builder_ids = []
    for bias in ("clarity", "perf"):
        bid = f"build-{bias}"
        builder_ids.append(bid)
        out.append({
            "id": bid, "phase": to_phase, "depends_on": [],
            "invokes": {"adapter_op": "do_unit"},
            "dispatch_context": {"bias": bias, "plan_items": items},
        })
    out.append({
        "id": "compare", "phase": to_phase, "depends_on": builder_ids,
        "invokes": {"adapter_op": "review", "prompt_template": "compare.md"},
        "dispatch_context": {},
    })
    return out


# NAME → emitter function. `recipes.V1_EMITTER_NAMES` mirrors these keys; a U5b
# test asserts the two sets are equal so a recipe can never name an emitter that
# isn't registered here (and the registry can't drift from the validator).
REGISTRY = {
    "plan_output_to_work_units": plan_output_to_work_units,
    "judge_winner_to_work_units": judge_winner_to_work_units,
    "plan_output_to_paired_builders": plan_output_to_paired_builders,
}


def resolve(name: str):
    """Return the emitter function for ``name``, or raise KeyError.

    The seam-handler resolves the recipe's declared emitter name through here,
    then hands the function to ``ledger.transition_and_emit``.
    """
    if name not in REGISTRY:
        raise KeyError(f"unknown emitter {name!r}; registered: {sorted(REGISTRY)}")
    return REGISTRY[name]
