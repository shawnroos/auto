#!/usr/bin/env python3
"""auto U2/U3/U7 (v0.2.0): recipe format, validator, and three-tier registry.

A *recipe* is a named, file-backed JSON declaration of a workflow topology — the
initial-ledger shape `/auto` builds a run from. This module is the SINGLE place
recipes are validated and resolved; both the engine loader (at run start) and the
authoring skill (at write time) call `validate()` / `validate_and_lint()` here, so
a recipe the skill writes is exactly what the engine will accept (one validator,
two callers — KTD-2).

VALIDATION IS HAND-ROLLED (no `jsonschema` dependency). The plugin ships pure
stdlib + bash to arbitrary repos via a marketplace; adding a pip dependency would
break install-anywhere. `recipes/schema.json` documents the shape; `validate()`
enforces the specific load-bearing rules mechanically below.

This file is built across three units:
  U2 — `validate()` + the format rules (this is the impl half).
  U3 — `resolve()`, `list_available()`, `load_and_validate()`, `unit_for()`,
       `validate_and_lint()` (the three-tier registry).
  U7 — `A1_BUILTIN` constant.
"""

from __future__ import annotations

import os

# The emitter NAMES the V1 engine ships (KTD-5). A recipe's phase_transitions may
# only reference these — the validator rejects any other name so a recipe can't
# point at a v0.3.0 emitter that doesn't exist yet. Kept here (not imported from
# emitters.py) so validation has no runtime dependency on the emitter module; the
# two are cross-checked by a U5b test that asserts this set equals the registry.
V1_EMITTER_NAMES = frozenset(
    {
        "plan_output_to_work_units",
        "judge_winner_to_work_units",
        "plan_output_to_paired_builders",
    }
)

# The default (v0.1.x) phase grammar, and the ONE non-default phase_order V1
# accepts: work-only (KTD-15). A3's multi-phase grammar is rejected until v0.2.1.
_DEFAULT_PHASE_ORDER = ["plan", "seam", "work"]
_WORK_ONLY_PHASE_ORDER = ["work"]
_V1_ALLOWED_PHASE_ORDERS = (_DEFAULT_PHASE_ORDER, _WORK_ONLY_PHASE_ORDER)

# Only this top-level key is reserved-but-ignored (R3). Every other unknown
# top-level key is rejected.
_RESERVED_TOPLEVEL = frozenset({"python_hook"})
_KNOWN_TOPLEVEL = frozenset(
    {
        "name",
        "version",
        "description",
        "default_adapter",
        "phase_order",
        "terminal_phase",
        "phase_transitions",
        "units",
    }
)
_KNOWN_UNIT_KEYS = frozenset({"id", "phase", "depends_on", "invokes"})


# A1 (Classic CE Stack) as a Python constant — the canonical runtime fallback
# (KTD-1). `recipes/a1.json` is the user-facing override target + conformance
# fixture, but bare `/auto` resolves A1 from THIS constant when no a1.json
# resolves at any tier — so a corrupted/missing built-in JSON can't break the
# default workflow. A U7 test asserts this constant equals the resolved a1.json
# topology (no drift) and that it passes validate().
A1_BUILTIN = {
    "name": "a1",
    "version": "1",
    "description": "Classic CE Stack — plan, build, review, fix to P3-only exit. The v0.1.x default workflow.",
    "default_adapter": "ce",
    "phase_order": ["plan", "seam", "work"],
    "terminal_phase": "work",
    "phase_transitions": [
        {"from": "plan", "to": "work", "emitter": "plan_output_to_work_units"}
    ],
    "units": [
        {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {"adapter_op": "next_plan_step"}}
    ],
}


class RecipeError(Exception):
    """A recipe failed validation. Message is operator-facing."""


def _bad(msg: str):
    raise RecipeError(msg)


def _check_prompt_template(value, where: str):
    """Path-bounding for `prompt_template` (security-lens Finding 1).

    Workspace recipes ship in committed code; an unbounded path would let a
    malicious recipe set `prompt_template: "../../../etc/passwd"` and the adapter
    would forward that file's contents into LLM context. Reject `..` segments,
    absolute paths, and empty strings. Enforced HERE (not only in the schema doc)
    so it is the load-bearing check, and re-checked in `unit_for` before the value
    reaches `dispatch_context`.
    """
    if not isinstance(value, str) or not value:
        _bad(f"{where}: prompt_template must be a non-empty string")
    if value.startswith("/"):
        _bad(f"{where}: prompt_template must be relative, got absolute {value!r}")
    parts = value.replace("\\", "/").split("/")
    if ".." in parts:
        _bad(f"{where}: prompt_template must not contain '..' (path traversal): {value!r}")


def validate(recipe: dict) -> None:
    """Validate a recipe dict against the V1 format. Raises RecipeError on any
    violation; returns None on success. The hard contract — both the engine and
    the authoring skill call this; skill output that passes here is engine-OK.
    """
    if not isinstance(recipe, dict):
        _bad("recipe must be a JSON object")

    # Unknown top-level fields: reject everything except the explicitly reserved
    # python_hook (which parses but the V1 engine ignores).
    for k in recipe:
        if k not in _KNOWN_TOPLEVEL and k not in _RESERVED_TOPLEVEL:
            _bad(f"unknown top-level field: {k!r}")

    # Required fields.
    for req in ("name", "version", "units"):
        if req not in recipe:
            _bad(f"missing required field: {req!r}")
    if not isinstance(recipe["name"], str) or not recipe["name"]:
        _bad("name must be a non-empty string")
    if not isinstance(recipe["units"], list):
        _bad("units must be a list")

    # phase_order: default if absent; V1 accepts ONLY the default or work-only.
    phase_order = recipe.get("phase_order", _DEFAULT_PHASE_ORDER)
    if not isinstance(phase_order, list) or not phase_order:
        _bad(f"phase_order must be a non-empty list: {phase_order!r}")
    if phase_order not in _V1_ALLOWED_PHASE_ORDERS:
        _bad(
            "non-default phase_order not yet supported (v0.2.1): "
            f"{phase_order!r} — V1 accepts only {_DEFAULT_PHASE_ORDER} or "
            f"{_WORK_ONLY_PHASE_ORDER}"
        )

    # terminal_phase: default "work"; must be a member of phase_order.
    terminal_phase = recipe.get("terminal_phase", "work")
    if terminal_phase not in phase_order:
        _bad(f"terminal_phase {terminal_phase!r} not in phase_order {phase_order!r}")

    # Units: each must have id + phase ∈ phase_order; depends_on references
    # existing unit ids; invokes well-formed; prompt_template path-bounded.
    unit_ids = set()
    for u in recipe["units"]:
        if not isinstance(u, dict):
            _bad("each unit must be a JSON object")
        for uk in u:
            if uk not in _KNOWN_UNIT_KEYS:
                _bad(f"unknown unit field: {uk!r}")
        if "id" not in u or not isinstance(u["id"], str) or not u["id"]:
            _bad("unit missing non-empty 'id'")
        if u["id"] in unit_ids:
            _bad(f"duplicate unit id: {u['id']!r}")
        unit_ids.add(u["id"])
        uphase = u.get("phase")
        if uphase is None or uphase not in phase_order:
            _bad(f"unit {u['id']!r}: phase {uphase!r} not in phase_order {phase_order!r}")
        dep = u.get("depends_on", [])
        if not isinstance(dep, list):
            _bad(f"unit {u['id']!r}: depends_on must be a list")
        inv = u.get("invokes", {})
        if not isinstance(inv, dict):
            _bad(f"unit {u['id']!r}: invokes must be an object")
        if "prompt_template" in inv:
            _check_prompt_template(inv["prompt_template"], f"unit {u['id']!r}")

    # depends_on integrity — a second pass once all ids are known.
    for u in recipe["units"]:
        for d in u.get("depends_on", []):
            if d not in unit_ids:
                _bad(f"unit {u['id']!r}: depends_on references unknown unit {d!r}")

    # phase_transitions: optional; each entry {from, to, emitter}; emitter must be
    # a registered V1 emitter name (Gap B disambiguation — A1 vs A4 at the shared
    # (plan, work) boundary each name their own emitter).
    pts = recipe.get("phase_transitions", [])
    if not isinstance(pts, list):
        _bad("phase_transitions must be a list")
    for pt in pts:
        if not isinstance(pt, dict):
            _bad("each phase_transitions entry must be an object")
        for fld in ("from", "to", "emitter"):
            if fld not in pt:
                _bad(f"phase_transitions entry missing {fld!r}")
        if pt["from"] not in phase_order or pt["to"] not in phase_order:
            _bad(
                f"phase_transitions from/to must be members of phase_order: {pt!r}"
            )
        if pt["emitter"] not in V1_EMITTER_NAMES:
            _bad(
                f"unknown emitter {pt['emitter']!r} — V1 recipes may only name "
                f"one of {sorted(V1_EMITTER_NAMES)}"
            )
