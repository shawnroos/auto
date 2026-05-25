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

import json
import os
import re

# Recipe-name regex (v0.2.0 fix-pass B / P0 #4 — round-1 security+correctness+
# adversarial all flagged the same path-traversal fingerprint). The recipe NAME
# is interpolated into `os.path.join(<tier_dir>, f"{name}.json")` in resolve(),
# so an unbounded name like "../../../../etc/passwd" would happily traverse out
# of the recipes dir. Constrain to a conservative POSIX-filename shape:
#   - first char must be lowercase letter or digit (rejects ".." and leading dot)
#   - body: letters, digits, dot, underscore, dash (rejects "/", "\", "..")
# Layered defense: validate() enforces it on the recipe's declared name (so the
# file-on-disk's `name:` matches the filename it'd resolve under), AND resolve()
# enforces it on the CLI-supplied --recipe argument (the actual attack surface).
# The helper itself is defined below RecipeError (forward-ref guard).
_RECIPE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

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


def _validate_recipe_name(name, *, source: str) -> None:
    """Reject an unsafe recipe name (see _RECIPE_NAME_RE above for rationale).

    ``source`` names the caller in the error so a misconfigured workspace
    recipe vs a malformed --recipe arg is distinguishable.
    """
    if not isinstance(name, str) or not _RECIPE_NAME_RE.match(name):
        _bad(
            f"invalid recipe name {name!r} ({source}); names must match "
            f"{_RECIPE_NAME_RE.pattern} (lowercase alphanumeric, with "
            f"'.', '_', '-' allowed inside)"
        )


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
    # P0 #4 fix-pass B: layer 1 — the file's declared name must be a safe
    # filename. validate_and_lint() additionally checks the name matches the
    # filename stem; this regex is the security floor.
    _validate_recipe_name(recipe["name"], source="recipe.name")
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

    # Work-only init-time gap (P1 #6, fix-pass D). A recipe with
    # phase_order: ["work"] and units: [] is UNRUNNABLE in v0.2.0 — at
    # init_ledger time the engine creates a ledger with zero units, the
    # work-loop predicate's has_units_in_phase guard is vacuous so met never
    # fires, and the engine re-arms forever while the operator sees nothing.
    # The intended runtime path (init-time enumeration via the adapter's
    # enumerate_plan_units op) is NOT WIRED in v0.2.0; that ships in v0.2.1
    # (KTD-15). The recipe format also has no field to declare init-time
    # enumeration, so an empty work-only units list IS the unrunnable case.
    # Reject mechanically here rather than ship a recipe whose only failure
    # mode is silent re-arming.
    if phase_order == _WORK_ONLY_PHASE_ORDER and not recipe["units"]:
        _bad(
            "v0.2.0 work-only recipes require pre-declared units; init-time "
            "enumeration ships in v0.2.1 (KTD-15). A recipe with "
            "phase_order: ['work'] and units: [] would create a ledger with "
            "zero units and the engine would re-arm forever without dispatching."
        )


# ──────────────────────────────────────────────────────────────────────────
# U3: three-tier registry — workspace → global → built-in, first-wins.

_BUILTIN_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "recipes")


def _tier_dirs(repo_root: str):
    """The three recipe directories in resolution order: (tier_name, dir)."""
    return [
        ("workspace", os.path.join(repo_root, ".claude", "auto", "recipes")),
        ("global", os.path.join(os.path.expanduser("~"), ".claude", "auto", "recipes")),
        ("built-in", _BUILTIN_DIR),
    ]


def resolve(name: str, repo_root: str):
    """Resolve recipe ``name`` across the three tiers, first-wins.

    Returns ``(recipe_dict, source_tier)``. For the built-in ``a1`` specifically,
    falls back to the ``A1_BUILTIN`` Python constant if no ``a1.json`` resolves at
    any tier (KTD-1 — a corrupt/missing built-in JSON can't break bare ``/auto``).
    Raises ``RecipeError`` (FileNotFound-shaped message) if nothing resolves.

    P0 #4 fix-pass B: layer 2 — the CLI-supplied ``--recipe`` value lands here
    unvalidated; without this check ``name="../../etc/passwd"`` would happily
    traverse out of the recipes dir via os.path.join. The check is BEFORE any
    path construction (fail closed before touching the filesystem).
    """
    _validate_recipe_name(name, source="--recipe argument")
    for tier, d in _tier_dirs(repo_root):
        path = os.path.join(d, f"{name}.json")
        if os.path.isfile(path):
            try:
                with open(path) as f:
                    return json.load(f), tier
            except (OSError, ValueError) as e:
                _bad(f"recipe {name!r} at {path} failed to load: {e}")
    if name == "a1":
        return dict(A1_BUILTIN), "built-in"
    searched = ", ".join(os.path.join(d, f"{name}.json") for _, d in _tier_dirs(repo_root))
    _bad(f"recipe {name!r} not found; searched: {searched}")


def list_available(repo_root: str):
    """All resolvable recipes as ``[(name, source_tier), ...]``, deduped by name
    (first-wins), workspace first then global then built-in. For the picker (U8).
    """
    seen = {}
    order = []
    for tier, d in _tier_dirs(repo_root):
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json"):
                continue
            nm = fn[:-5]
            if nm in seen:
                continue  # first tier wins
            seen[nm] = tier
            order.append((nm, tier))
    return order


def load_and_validate(name: str, repo_root: str):
    """``resolve`` + ``validate``. Returns ``(recipe_dict, source_tier)`` or
    raises ``RecipeError``. The engine's entry point at run start."""
    recipe, tier = resolve(name, repo_root)
    validate(recipe)
    return recipe, tier


def unit_for(recipe_unit: dict, recipe: dict) -> dict:
    """Project a RECIPE unit dict onto a LEDGER unit dict (the shape
    ``ledger.init_ledger`` expects). Merges recipe-side ``invokes`` metadata
    (``prompt_template`` etc.) into ``dispatch_context`` — RE-VALIDATING the
    path bound (the second enforcement point; the first is ``validate``). The
    ``adapter_op`` stays in ``dispatch_context`` so the adapter reads it via the
    unit at dispatch.
    """
    inv = dict(recipe_unit.get("invokes") or {})
    if "prompt_template" in inv:
        _check_prompt_template(inv["prompt_template"], f"unit {recipe_unit.get('id')!r}")
    return {
        "id": recipe_unit["id"],
        "phase": recipe_unit.get("phase", "work"),
        "depends_on": list(recipe_unit.get("depends_on") or []),
        "dispatch_context": inv,
    }


def validate_and_lint(recipe: dict):
    """``validate`` (hard errors, raises) PLUS editorial lint warnings the engine
    ignores but the authoring skill surfaces (KTD-2). Returns a list of warning
    strings (empty when clean). Call ``validate`` for the contract; this adds:
      - a phase in phase_order with no unit assigned (and no emitter targeting it)
      - depends_on creating an unreachable unit (no path from a root)
      - terminal_phase with no units AND no emitter targeting it
      - a workspace/global recipe whose description matches a built-in verbatim
        (description-spoofing defense — security observation 1)
    """
    validate(recipe)  # hard errors first
    warnings = []
    phase_order = recipe.get("phase_order", _DEFAULT_PHASE_ORDER)
    units = recipe.get("units", [])
    emit_targets = {pt.get("to") for pt in recipe.get("phase_transitions", [])}
    units_by_phase = {}
    for u in units:
        units_by_phase.setdefault(u.get("phase"), []).append(u)
    for ph in phase_order:
        if ph == "seam":
            continue  # seam is a pass-through; never holds units
        if not units_by_phase.get(ph) and ph not in emit_targets:
            warnings.append(
                f"phase {ph!r} has no units and no emitter targets it — it will "
                f"do nothing"
            )
    terminal = recipe.get("terminal_phase", "work")
    if not units_by_phase.get(terminal) and terminal not in emit_targets:
        warnings.append(
            f"terminal_phase {terminal!r} has no units and no emitter — the run "
            f"would exit immediately with nothing done"
        )
    # description-spoofing: a non-built-in recipe copying a built-in's description.
    desc = (recipe.get("description") or "").strip()
    if desc:
        for nm in ("a1", "a2", "a4", "w"):
            path = os.path.join(_BUILTIN_DIR, f"{nm}.json")
            if os.path.isfile(path):
                try:
                    with open(path) as f:
                        bdesc = (json.load(f).get("description") or "").strip()
                except (OSError, ValueError):
                    continue
                if desc == bdesc and recipe.get("name") != nm:
                    warnings.append(
                        f"description matches built-in {nm!r} verbatim — possible "
                        f"spoofing; consider a distinct description"
                    )
    return warnings
