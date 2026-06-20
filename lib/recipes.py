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
from typing import NoReturn

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
        # v0.3.0 (U3): iterate_template materializes new units from a recipe-
        # declared emit_templates entry when the gate unit verdicts "iterate".
        # Added atomically with the REGISTRY entry in lib/emitters.py so the
        # symmetry test stays green; U5 reserved this name but deferred the add.
        "iterate_template",
        # v0.6.0 (U8): brainstorm_output_to_plan_unit fires on arrival at `plan`
        # from `brainstorm` in the spine recipe (recipes/pipeline.json), reading
        # the brainstorm unit's requirements-doc output and emitting the single
        # plan unit. Added atomically with the emitters.REGISTRY entry so the
        # symmetry test (set(REGISTRY) == V1_EMITTER_NAMES) stays green.
        "brainstorm_output_to_plan_unit",
    }
)

# The default (v0.1.x) phase grammar and the work-only grammar. v0.6.0 (U6)
# dropped the literal allow-list (`_V1_ALLOWED_PHASE_ORDERS`) — phase_order is
# now validated structurally (every element a non-empty string, members cross-
# checked downstream), so arbitrary spines like
# ["brainstorm","plan","seam","work"] validate. These two constants survive:
# `_DEFAULT_PHASE_ORDER` is the recipe-blind default, `_WORK_ONLY_PHASE_ORDER`
# still anchors the work-only empty-units guard below.
_DEFAULT_PHASE_ORDER = ["plan", "seam", "work"]
_WORK_ONLY_PHASE_ORDER = ["work"]

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
        # v0.3.0 (U5): outcomes-gated iteration. Both fields are ADDITIVE — a
        # v0.2.x recipe that declares neither still validates (R7). The
        # validator block below cross-checks shape, gate_unit references, the
        # bound block, and the iteration↔emit_templates pairing rule.
        "iteration",
        "emit_templates",
        # v0.3.0 fix-pass F4: ADV-2 + maint-4 (depends_on carve-out is too
        # loose). Recipes that use a non-iterate emitter to produce concrete
        # unit ids consumed by a structural unit's depends_on must DECLARE
        # those ids here. The validator then accepts depends_on members that
        # are EITHER in units[], OR in expected_emit_outputs, OR plausibly
        # produced by iterate_template's id math (`{id_prefix}{N}` shape).
        # Prior carve-out accepted any depends_on string starting with an
        # emit_template id_prefix — `"build-typo"` would pass against
        # id_prefix `"build-"` even though no emitter would ever produce it.
        "expected_emit_outputs",
    }
)
_KNOWN_UNIT_KEYS = frozenset({"id", "phase", "depends_on", "invokes"})
# v0.3.0 (U5): the field set an emit_templates ENTRY may carry. Same depth as
# `_KNOWN_UNIT_KEYS` for `units[]` — mechanical reject of unknown inner keys so
# a typo in a template ("invoke" vs "invokes") doesn't silently no-op at emit.
_KNOWN_EMIT_TEMPLATE_KEYS = frozenset({"phase", "invokes", "id_prefix"})
_KNOWN_ITERATION_KEYS = frozenset({"gate_unit", "emit_template", "bound"})
_KNOWN_ITERATION_BOUND_KEYS = frozenset({"max_attempts", "max_wall_seconds"})


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


def _bad(msg: str) -> NoReturn:
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


def _validate_toplevel(recipe: dict) -> None:
    """Top-level shape: object, no unknown fields, required name/version/units,
    a safe filename name, units-is-list. Order-preserving extract — the
    first-violation message must not change."""
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


def _validate_phase_order(recipe: dict) -> list:
    """phase_order (default if absent; non-empty list of non-empty strings) +
    terminal_phase membership. Returns the resolved phase_order."""
    # phase_order: default if absent. v0.6.0 (U6) replaced the literal allow-list
    # gate with a STRUCTURAL rule (every element a non-empty string); the
    # phase-membership invariants are enforced downstream, unlocking arbitrary
    # spines like ["brainstorm","plan","seam","work"] (KTD-2/3).
    phase_order = recipe.get("phase_order", _DEFAULT_PHASE_ORDER)
    if not isinstance(phase_order, list) or not phase_order:
        _bad(f"phase_order must be a non-empty list: {phase_order!r}")
    for ph in phase_order:
        if not isinstance(ph, str) or not ph:
            _bad(f"phase_order entries must be non-empty strings; got {ph!r}")

    # terminal_phase: default "work"; must be a member of phase_order.
    terminal_phase = recipe.get("terminal_phase", "work")
    if terminal_phase not in phase_order:
        _bad(f"terminal_phase {terminal_phase!r} not in phase_order {phase_order!r}")
    return phase_order


def _validate_units(recipe: dict, phase_order: list) -> set:
    """Per-unit shape: known keys, non-empty unique id, phase ∈ phase_order,
    depends_on/invokes shape, prompt_template path-bounded. Returns the set of
    unit ids — the depends_on integrity pass needs ALL ids known first."""
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
    return unit_ids


def _gather_emit_prefixes(emit_templates) -> set:
    """The id_prefix set declared by emit_templates. Computed ONCE and threaded
    to BOTH the depends_on integrity pass and the iteration gate_unit check —
    these were two byte-identical gathers (recipe-format §6 calls them
    symmetric), so a single shared set is behavior-preserving."""
    prefixes = set()
    if isinstance(emit_templates, dict):
        for tmpl in emit_templates.values():
            if isinstance(tmpl, dict) and isinstance(tmpl.get("id_prefix"), str):
                prefixes.add(tmpl["id_prefix"])
    return prefixes


def _validate_expected_emit_outputs(recipe: dict) -> set:
    """F4: validate expected_emit_outputs shape (list of non-empty strings).
    Returns the set used by the depends_on carve-out."""
    expected_emit_outputs = recipe.get("expected_emit_outputs")
    if expected_emit_outputs is not None:
        if not isinstance(expected_emit_outputs, list):
            _bad("expected_emit_outputs must be a list of strings")
        for eeo in expected_emit_outputs:
            if not isinstance(eeo, str) or not eeo:
                _bad(
                    f"expected_emit_outputs entries must be non-empty strings; "
                    f"got {eeo!r}"
                )
    return set(expected_emit_outputs or [])


def _validate_depends_on(recipe: dict, unit_ids: set, emit_prefixes: set,
                         expected_emit_outputs_set: set) -> None:
    """depends_on integrity — a second pass once all ids are known. Each dep is
    a known unit id, an iterate-shaped emit id (`{id_prefix}{positive_int}`), or
    a declared expected_emit_output.

    v0.3.0 (U6): emit_template id_prefixes are forward-reference targets. A
    structurally-declared unit (e.g., A4's `compare` after U6) may name a
    builder id like `build-clarity` in its `depends_on` even though no `units[]`
    entry has that exact id yet — the matching builder is materialized at run
    time by an emitter. Two emit-shapes are legitimate: (a) iterate_template
    materializes `{id_prefix}{N}`; (b) a non-iterate emitter produces
    explicitly-named ids declared via top-level `expected_emit_outputs` (F4:
    ADV-2 + maint-4 — grounds acceptance in the author's stated producer-output
    contract, not a literal-prefix coincidence)."""

    def _matches_iterate_shape(dep_id: str) -> bool:
        """Is ``dep_id`` plausibly an `iterate_template` output?

        iterate_template emits ids of the form ``{id_prefix}{N}`` where N is a
        positive int (see ``lib/emitters.py``: ``f"{id_prefix}{base + i + 1}"``,
        with base >= 0 and i >= 0). For depends_on validation we accept any
        prefix-match whose remainder parses as a positive int — string
        ``"build-1"`` matches, ``"build-typo"`` does not.

        G1 / ADV-R2-3: use ``isdecimal()`` not ``isdigit()`` —
        ``'²'.isdigit()`` is True but ``int('²')`` raises ValueError, so an
        author-crafted depends_on like ``"build-²"`` would crash the
        validator instead of being rejected as not-iterate-shaped.
        ``isdecimal()`` matches exactly the base-10 digits ``int()`` accepts.
        """
        for p in emit_prefixes:
            if not dep_id.startswith(p) or dep_id == p:
                continue
            suffix = dep_id[len(p):]
            if suffix.isdecimal() and int(suffix) >= 1:
                return True
        return False

    for u in recipe["units"]:
        for d in u.get("depends_on", []):
            if d in unit_ids:
                continue
            # F4 carve-out (tightened): depends_on may forward-reference EITHER
            # (a) an iterate-shaped id (`{id_prefix}{positive_int}`) OR
            # (b) a member of expected_emit_outputs declared by the recipe.
            if _matches_iterate_shape(d):
                continue
            if d in expected_emit_outputs_set:
                continue
            _bad(f"unit {u['id']!r}: depends_on references unknown unit {d!r}")


def _validate_phase_transitions(recipe: dict, phase_order: list) -> None:
    """phase_transitions: optional; each entry {from, to, emitter}; emitter must
    be a registered V1 emitter name (Gap B disambiguation — A1 vs A4 at the
    shared (plan, work) boundary each name their own emitter)."""
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


def _validate_emit_templates(recipe: dict, phase_order: list) -> None:
    """v0.3.0 (U5): emit_templates shape validation (OPTIONAL field — a v0.2.x
    recipe omits it and validates unchanged, R7 backward compat). Runs BEFORE
    iteration validation to preserve first-violation order."""
    emit_templates = recipe.get("emit_templates")
    if emit_templates is not None:
        if not isinstance(emit_templates, dict):
            _bad("emit_templates must be a JSON object")
        for tmpl_name, tmpl in emit_templates.items():
            if not isinstance(tmpl, dict):
                _bad(f"emit_templates[{tmpl_name!r}] must be a JSON object")
            for tk in tmpl:
                if tk not in _KNOWN_EMIT_TEMPLATE_KEYS:
                    _bad(
                        f"emit_templates[{tmpl_name!r}]: unknown field {tk!r}; "
                        f"known: {sorted(_KNOWN_EMIT_TEMPLATE_KEYS)}"
                    )
            for req_k in ("phase", "invokes", "id_prefix"):
                if req_k not in tmpl:
                    _bad(f"emit_templates[{tmpl_name!r}]: missing required field {req_k!r}")
            tphase = tmpl["phase"]
            if tphase not in phase_order:
                _bad(
                    f"emit_templates[{tmpl_name!r}]: phase {tphase!r} not in "
                    f"phase_order {phase_order!r}"
                )
            tinv = tmpl["invokes"]
            # Mirror existing `units[].invokes` validation depth: invokes must be
            # a dict; prompt_template path-bounded if present. We don't constrain
            # inner keys (no whitelist) — `_KNOWN_UNIT_KEYS` doesn't constrain
            # `invokes`'s inner keys either. The adapter contract bounds those.
            if not isinstance(tinv, dict):
                _bad(f"emit_templates[{tmpl_name!r}]: invokes must be an object")
            if "prompt_template" in tinv:
                _check_prompt_template(tinv["prompt_template"], f"emit_templates[{tmpl_name!r}]")
            tprefix = tmpl["id_prefix"]
            if not isinstance(tprefix, str) or not tprefix:
                _bad(f"emit_templates[{tmpl_name!r}]: id_prefix must be a non-empty string")


def _validate_iteration(recipe: dict, phase_order: list, unit_ids: set,
                        emit_prefixes: set) -> None:
    """v0.3.0 (U5): iteration block validation (OPTIONAL field). Cross-refs
    emit_templates (the pairing rule) + emit_prefixes (the gate_unit carve-out —
    the shared id_prefix set also used by depends_on integrity)."""
    iteration = recipe.get("iteration")
    if iteration is not None:
        emit_templates = recipe.get("emit_templates")
        if not isinstance(iteration, dict):
            _bad("iteration must be a JSON object")
        for ik in iteration:
            if ik not in _KNOWN_ITERATION_KEYS:
                _bad(
                    f"iteration: unknown field {ik!r}; known: "
                    f"{sorted(_KNOWN_ITERATION_KEYS)}"
                )
        # gate_unit is required and must reference a unit_id OR an
        # emit_templates entry's id_prefix. The latter is a defensive carve-out
        # per round-3 P2 #21 — A4's `compare` lands in `units[]` explicitly per
        # U6, so the carve-out is forward-looking insurance for future recipes.
        if "gate_unit" not in iteration:
            _bad("iteration: missing required field 'gate_unit'")
        gate = iteration["gate_unit"]
        if not isinstance(gate, str) or not gate:
            _bad("iteration.gate_unit must be a non-empty string")
        if gate not in unit_ids and gate not in emit_prefixes:
            _bad(
                f"iteration.gate_unit {gate!r} not in units[] (ids: "
                f"{sorted(unit_ids)!r}) and not declared as an emit_templates "
                f"id_prefix (prefixes: {sorted(emit_prefixes)!r})"
            )

        # bound is required (max_attempts inside is required; max_wall_seconds
        # optional). Bounds are engine-enforced (deterministic over
        # probabilistic) — they live in the recipe so the engine can't be
        # fooled into running forever by a misbehaving gate agent.
        if "bound" not in iteration:
            _bad("iteration: missing required field 'bound'")
        bound = iteration["bound"]
        if not isinstance(bound, dict):
            _bad("iteration.bound must be a JSON object")
        for bk in bound:
            if bk not in _KNOWN_ITERATION_BOUND_KEYS:
                _bad(
                    f"iteration.bound: unknown field {bk!r}; known: "
                    f"{sorted(_KNOWN_ITERATION_BOUND_KEYS)}"
                )
        if "max_attempts" not in bound:
            _bad("iteration.bound: missing required field 'max_attempts'")
        ma = bound["max_attempts"]
        # Reject bool first — `bool` is a subclass of `int` in Python, so a
        # plain `isinstance(ma, int)` would accept True/False here.
        if isinstance(ma, bool) or not isinstance(ma, int) or ma <= 0:
            _bad(
                f"iteration.bound.max_attempts must be a positive int; got "
                f"{ma!r}"
            )
        if "max_wall_seconds" in bound:
            mw = bound["max_wall_seconds"]
            if isinstance(mw, bool) or not isinstance(mw, int) or mw <= 0:
                _bad(
                    f"iteration.bound.max_wall_seconds must be a positive int; "
                    f"got {mw!r}"
                )

        # emit_template is OPTIONAL per round-3 P2 #21's relaxation — supports
        # "re-engage the gate without spawning new siblings" (e.g., A4's
        # comparator re-comparing the same builders after a clarifying signal).
        # PAIRING RULE: if iteration.emit_template IS set, emit_templates MUST
        # be defined AND contain that key. If emit_template is absent,
        # emit_templates may be absent too.
        if "emit_template" in iteration:
            etn = iteration["emit_template"]
            if not isinstance(etn, str) or not etn:
                _bad("iteration.emit_template must be a non-empty string")
            if emit_templates is None:
                _bad(
                    f"iteration.emit_template = {etn!r} requires an "
                    f"'emit_templates' top-level field; none declared"
                )
            if etn not in emit_templates:
                _bad(
                    f"iteration.emit_template {etn!r} not in emit_templates "
                    f"keys: {sorted(emit_templates)!r}"
                )


def _validate_work_only_gap(recipe: dict, phase_order: list) -> None:
    """Work-only init-time gap (P1 #6, fix-pass D). A recipe with
    phase_order: ["work"] and units: [] is UNRUNNABLE in v0.2.0 — at
    init_ledger time the engine creates a ledger with zero units, the
    work-loop predicate's has_units_in_phase guard is vacuous so met never
    fires, and the engine re-arms forever while the operator sees nothing.
    The intended runtime path (init-time enumeration via the adapter's
    enumerate_plan_units op) is NOT WIRED in v0.2.0; that ships in v0.2.1
    (KTD-15). Reject mechanically here rather than ship a recipe whose only
    failure mode is silent re-arming."""
    if phase_order == _WORK_ONLY_PHASE_ORDER and not recipe["units"]:
        _bad(
            "v0.2.0 work-only recipes require pre-declared units; init-time "
            "enumeration ships in v0.2.1 (KTD-15). A recipe with "
            "phase_order: ['work'] and units: [] would create a ledger with "
            "zero units and the engine would re-arm forever without dispatching."
        )


def validate(recipe: dict) -> None:
    """Validate a recipe dict against the V1 format. Raises RecipeError on any
    violation; returns None on success. The hard contract — both the engine and
    the authoring skill call this; skill output that passes here is engine-OK.

    An ordered orchestrator over per-concern validators (extracted from the
    former 315-line monolith). ORDER IS LOAD-BEARING: the first violation a
    malformed recipe hits must stay the same, so these run in the original
    sequence. Shared state (phase_order, unit_ids, the single emit_prefixes set)
    is computed once and threaded explicitly.
    """
    _validate_toplevel(recipe)
    phase_order = _validate_phase_order(recipe)
    unit_ids = _validate_units(recipe, phase_order)
    # One id_prefix gather, shared by depends_on integrity AND the iteration
    # gate_unit check (formerly computed twice, ~140 lines apart).
    emit_prefixes = _gather_emit_prefixes(recipe.get("emit_templates") or {})
    expected_emit_outputs_set = _validate_expected_emit_outputs(recipe)
    _validate_depends_on(recipe, unit_ids, emit_prefixes, expected_emit_outputs_set)
    _validate_phase_transitions(recipe, phase_order)
    _validate_emit_templates(recipe, phase_order)
    _validate_iteration(recipe, phase_order, unit_ids, emit_prefixes)
    _validate_work_only_gap(recipe, phase_order)


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


def validate_and_lint(recipe: dict, *, filename: str | None = None):
    """``validate`` (hard errors, raises) PLUS editorial lint warnings the engine
    ignores but the authoring skill surfaces (KTD-2). Returns a list of warning
    strings (empty when clean). Call ``validate`` for the contract; this adds:
      - a phase in phase_order with no unit assigned (and no emitter targeting it)
      - depends_on creating an unreachable unit (no path from a root)
      - terminal_phase with no units AND no emitter targeting it
      - a workspace/global recipe whose description matches a built-in verbatim
        (description-spoofing defense — security observation 1)
      - (P2-15) when ``filename`` is supplied: the recipe's declared ``name``
        does not match the file stem. The engine resolves recipes by filename,
        so a name/stem mismatch means a user who runs ``--recipe <stem>`` would
        load this file while a recipe author who reads the ``name:`` field
        expects a different identifier — a UX trap, surfaced here as a warning.

    ``filename`` is optional: the path or basename to compare against (file
    extension stripped if present). When omitted (the engine's load path), the
    name-stem check is skipped — only the skill needs it, since the skill is
    the one choosing the write path.
    """
    validate(recipe)  # hard errors first
    warnings = []
    # P2-15: name-stem mismatch warning (skill-only path; engine load doesn't
    # supply filename).
    if filename:
        stem = os.path.splitext(os.path.basename(filename))[0]
        declared = recipe.get("name")
        if stem and declared and stem != declared:
            warnings.append(
                f"recipe name {declared!r} does not match filename stem "
                f"{stem!r} — the engine resolves recipes by filename, so "
                f"--recipe {stem!r} would load this file but its declared "
                f"name is {declared!r}; rename one to match the other"
            )
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
    # v0.3.0 (U5) editorial: iteration.bound editorial sanity checks. Neither is
    # a hard error — operator-defined bounds; surface as advisory only. The
    # validator above already rejects 0/negative max_attempts; this warns on
    # values that pass the hard check but look suspicious.
    if isinstance(recipe.get("iteration"), dict):
        bound = recipe["iteration"].get("bound")
        if isinstance(bound, dict):
            ma = bound.get("max_attempts")
            if isinstance(ma, int) and not isinstance(ma, bool) and ma > 10:
                warnings.append(
                    f"iteration.bound.max_attempts = {ma} — are you sure? "
                    f"iterations are expensive (each spawns a new wave of "
                    f"units + re-engages the gate); >10 is typically a sign "
                    f"the gate's verdict-criterion is too strict"
                )
            mw = bound.get("max_wall_seconds")
            if isinstance(mw, int) and not isinstance(mw, bool) and mw < 60:
                warnings.append(
                    f"iteration.bound.max_wall_seconds = {mw} — seems short; "
                    f"a single wave can take longer than this, in which case "
                    f"the bound will fire before any iteration completes"
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
