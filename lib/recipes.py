#!/usr/bin/env python3
"""auto recipe REGISTRY facade + the A1 built-in constant (U3/U7; U17 split).

A *recipe* is a named, file-backed JSON declaration of a workflow topology — the
initial-ledger shape `/auto` builds a run from. This module is the three-tier
REGISTRY (workspace → global → built-in, first-wins) and the public surface every
consumer reaches through the ``recipes.`` namespace.

U17 (v0.9.0) split the former ~981-LOC recipes.py BY CONCERN: the ~700-LOC
validation family moved to lib/recipe_validate.py (the DAG root — pure stdlib,
imports no sibling), and THIS file is the thin registry facade. It re-exports the
validation surface (``validate`` / ``validate_and_lint`` / ``RecipeError`` /
``V1_PRODUCER_NAMES`` / the ``_validate_*`` helpers ``resolve``/``unit_for`` need)
so existing callers that do ``recipes.validate(...)``, ``except recipes.RecipeError``,
``recipes.V1_PRODUCER_NAMES`` etc. keep resolving unchanged — exactly the pattern
the ledger facade uses for ledger_core/mutators/producers. ``RecipeError`` lives in
recipe_validate (the root) and is re-exported here, so it is importable from BOTH
modules with no import cycle (facade → recipe_validate, one direction).

This module holds:
  U3 — the three-tier registry (``resolve``, ``list_available``,
       ``load_and_validate``, ``unit_for``, ``workspace_recipe_path``, ``_tier_dirs``).
  U7 — ``A1_BUILTIN`` constant (the canonical runtime fallback).
Validation (``validate`` / ``validate_and_lint`` / format rules) → recipe_validate.
"""

from __future__ import annotations

import json
import os
import sys

# Load the validation module via the standard bootstrap loader. The recipes
# surface is loaded from many sites by file path (the test harness uses
# spec_from_file_location, which does NOT add lib/ to sys.path), so a plain
# `from recipe_validate import ...` is not guaranteed to resolve. Prepending
# lib/ + routing through _bootstrap.load_lib_module is the one robust load
# strategy the codebase already uses for sibling modules (see lib/ledger.py).
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

recipe_validate = load_lib_module("recipe_validate")

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from recipe_validate (the validation DAG root). Every name is listed
# explicitly (greppable) so the re-export surface is auditable and a consumer's
# `recipes.<name>` keeps resolving after the U17 split. RecipeError is shared —
# both modules expose it, no cycle (this facade imports it; the root defines it).

RecipeError = recipe_validate.RecipeError  # shared exception (both modules expose it)
validate = recipe_validate.validate
validate_and_lint = recipe_validate.validate_and_lint

# Public constant consumers read as recipes.V1_PRODUCER_NAMES (e.g. the U5b
# symmetry test that cross-checks it against unit_emitters.REGISTRY).
V1_PRODUCER_NAMES = recipe_validate.V1_PRODUCER_NAMES

# Format constants + the private validation helpers the registry below reaches:
# resolve() calls _validate_recipe_name + _bad; unit_for() calls
# _check_prompt_template; _tier_dirs() reads _BUILTIN_DIR. Re-exported so both
# the facade internals AND any consumer that referenced them via recipes.<name>
# before the split keep resolving.
_bad = recipe_validate._bad
_validate_recipe_name = recipe_validate._validate_recipe_name
# The reserved-alias-name gate lives in recipe_validate (the DAG root that both
# validate() and validate_and_lint() funnel through). It holds a copy of the
# _ALIASES map below; a recipe authored under one of those legible names is
# rejected at validate time (fail fast) instead of being silently shadowed by
# resolve()'s alias→stem rewrite. Re-exported so the drift-guard test can assert
# `_ALIASES == _RESERVED_ALIAS_STEMS` (the two copies never diverge).
_RESERVED_ALIAS_STEMS = recipe_validate._RESERVED_ALIAS_STEMS
_check_prompt_template = recipe_validate._check_prompt_template
_lint_verification_placement = recipe_validate._lint_verification_placement
_builtin_names = recipe_validate._builtin_names
_BUILTIN_DIR = recipe_validate._BUILTIN_DIR
_DEFAULT_PHASE_ORDER = recipe_validate._DEFAULT_PHASE_ORDER
_WORK_ONLY_PHASE_ORDER = recipe_validate._WORK_ONLY_PHASE_ORDER


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
        {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {"adapter_op": "next_plan_step"}}  # format-v1 key; flips in U6
    ],
}


# ──────────────────────────────────────────────────────────────────────────
# U6 (R9): legible names that ALIAS the a1/a2/a4/w shorthand. A PURE alias layer
# — each legible name resolves to the SAME recipe as its stem. `resolve()`
# rewrites a legible name to its stem BEFORE the file lookup, so a legible name
# lands on the stem's recipe at whichever tier it resolves AND inherits the
# stem's fallback (e.g. `plan-build-review` → `a1`, which still falls back to
# A1_BUILTIN when no a1.json resolves). The stem files and A1_BUILTIN are NEVER
# renamed (KTD-6). Each name is confirmed against the recipe's `description`:
#   a1 "Classic CE Stack — plan, build, review"  → plan-build-review
#   a2 "Parallel Theories + Judge"               → parallel-theories
#   a4 "Adversarial Pair + Comparator"           → adversarial-pair
#   w  "Work-only"                               → work-only
# RESERVED NAMES: the four legible keys below are rewritten to their stem BEFORE
# any tier file lookup, so a user recipe literally named e.g. `work-only.json`
# would be shadowed (it resolves to `w`). These names are reserved aliases — do
# not author a custom recipe under one of them.
_ALIASES = {
    "plan-build-review": "a1",
    "parallel-theories": "a2",
    "adversarial-pair": "a4",
    "work-only": "w",
}


def canonical_name(name):
    """Rewrite a legible alias to its shorthand stem; identity for a non-alias.

    The SINGLE public accessor for the alias→stem rewrite (SSOT: ``_ALIASES``).
    ``resolve()`` routes through it, and ``recommender.py --check-agrees``
    canonicalizes the agent's recommended value through it BEFORE the stem-
    equality / skip-eligibility comparison — so an alias-form recommendation
    (`plan-build-review`) resolves to its stem (`a1`) and can reach the skip tier
    exactly where the bare stem would. Keeping this one function the only rewrite
    site is what lets ``launch-gate.SKIP_ELIGIBLE_RECIPES`` hold STEMS ONLY (no
    dead alias entries): aliases are folded to stems here, upstream of the check.
    """
    return _ALIASES.get(name, name)


# ──────────────────────────────────────────────────────────────────────────
# U3: three-tier registry — workspace → global → built-in, first-wins.


def _tier_dirs(repo_root: str):
    """The three recipe directories in resolution order: (tier_name, dir)."""
    return [
        ("workspace", os.path.join(repo_root, ".claude", "auto", "recipes")),
        ("global", os.path.join(os.path.expanduser("~"), ".claude", "auto", "recipes")),
        ("built-in", _BUILTIN_DIR),
    ]


def workspace_recipe_path(repo_root: str, name: str) -> str:
    """The workspace-tier file path for recipe ``name`` (the run-scoped variant
    home). Single source of truth for where the launch chooser writes a
    ``<builtin>-<run-slug>`` recipe and where ``auto.py --teardown-recipe-after-init``
    deletes exactly that file post-init. Targets ONLY the workspace tier, so it can
    never name a built-in or global recipe — deleting it can't shadow-break a
    canonical recipe."""
    return os.path.join(repo_root, ".claude", "auto", "recipes", f"{name}.json")


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
    # U6 (R9): rewrite a legible alias to its shorthand stem BEFORE any path
    # construction or the `name == "a1"` constant fallback — so a legible name
    # resolves to the stem's recipe at every tier AND inherits the stem's
    # A1_BUILTIN fallback. Validation runs on the ORIGINAL name first (defense);
    # a non-alias name passes through unchanged.
    name = canonical_name(name)
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
            if fn == "schema.json":
                continue  # the recipe-shape doc (see module docstring), not a recipe
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
    ``adapter_op`` stays in ``dispatch_context`` so the backend reads it via the
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
