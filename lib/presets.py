#!/usr/bin/env python3
"""auto PRESET data object — loader + validator (U1, addressable-step-contents).

A *preset* is the pure `invokes` payload of a step, promoted to a first-class
named object:

    {"name", "version", "description", "invokes": {"backend_op", "prompt_template"?}}

It carries NO verification gate (R2) — a preset is payload, never payload+gate.
The container concerns `phase` and `depends_on` are NOT a preset's business
either (those live on the flow that hosts it); this validator rejects all three
keys so the preset/container boundary stays clean.

RESOLUTION (a deliberate SUBSET of `recipes.py`'s registry — Phase 1 ships no
tri-tier catalog / `list_available`, which is R3/Phase 2). Two tiers, first-wins:

    1. workspace:  <repo>/.claude/auto/presets/<name>.json   (override)
    2. built-in:   <auto_root>/presets/<name>.json           (shipped seed)

A workspace file of the same name OVERRIDES the built-in (first-wins, workspace
first — mirrors `recipes.resolve`). An unknown name raises `PresetError` with a
clear, operator-facing message that lists what was searched — never a traceback.

DAG DISCIPLINE (KTD-2): this module reuses `recipe_validate`'s primitives
(`_check_prompt_template` for path-bounding, `_validate_recipe_name` for the
filename-safe name check) and imports `VALID_BACKEND_OPS` from the pure-stdlib
leaf `backend_ops`. It MUST NOT import `dispatcher.py` — that module pulls in
the ledger and the whole dispatch surface; the validator stays a light leaf.
`recipe_validate` and `backend_ops` are themselves DAG roots (no sibling
imports), so this stays a shallow, cycle-free layer.

VALIDATION IS HAND-ROLLED (no `jsonschema` — same install-anywhere constraint as
`recipe_validate`; the plugin ships pure stdlib + bash to arbitrary repos). The
written contract is `docs/contracts/preset-format.md` (marked PROVISIONAL until
a Phase-2 `preset_ref` consumer validates the container/preset boundary); there
is deliberately no `presets/schema.json` — code is the enforcement.
"""

from __future__ import annotations

import json
import os
import sys

# Standard bootstrap: prepend lib/ and route sibling loads through _bootstrap,
# exactly as recipes.py does (the harness loads this file by path via
# spec_from_file_location, which does NOT add lib/ to sys.path).
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

# Reused validation primitives (KTD-2). `recipe_validate` is the pure-stdlib
# validation DAG root; `backend_ops` is the pure-stdlib op-set leaf. Neither
# imports a heavy sibling, so this module stays light.
_recipe_validate = load_lib_module("recipe_validate")
_backend_ops = load_lib_module("backend_ops")
# U6 (KTD-1): the format-v1 → v2 read shim. DAG root, pure stdlib, imports no
# sibling — so this edge closes no cycle.
_format_compat = load_lib_module("format_compat")

_check_prompt_template = _recipe_validate._check_prompt_template
_validate_recipe_name = _recipe_validate._validate_recipe_name
RecipeError = _recipe_validate.RecipeError
VALID_BACKEND_OPS = _backend_ops.VALID_BACKEND_OPS

# The built-in seed directory: <auto_root>/presets (auto_root is lib/'s parent),
# computed the same way recipe_validate._BUILTIN_DIR resolves <auto_root>/recipes.
_BUILTIN_DIR = os.path.join(os.path.dirname(_LIB_DIR), "presets")

# A preset is a closed object: exactly these top-level keys are known. `invokes`
# is a closed sub-object of {backend_op, prompt_template}. `verification`,
# `phase`, and `depends_on` are NOT merely "unknown" — they are named explicitly
# in the reject list so the error message is precise about WHY (R2 / the
# preset-vs-container boundary), rather than a generic "unknown field".
_KNOWN_TOPLEVEL = frozenset({"name", "version", "description", "invokes"})
_FORBIDDEN_TOPLEVEL = frozenset({"verification", "phase", "depends_on"})
_KNOWN_INVOKES_KEYS = frozenset({"backend_op", "prompt_template"})


class PresetError(Exception):
    """A preset failed to load (resolution). Message is operator-facing."""


def _tier_dirs(repo_root: str):
    """The preset directories in resolution order: (tier_name, dir). Workspace
    first (override), built-in last (shipped seed). A deliberate two-tier SUBSET
    of `recipes._tier_dirs` — no global tier, no catalog (R3/Phase 2)."""
    return [
        ("workspace", os.path.join(repo_root, ".claude", "auto", "presets")),
        ("built-in", _BUILTIN_DIR),
    ]


def load_preset(name: str, repo: str) -> dict:
    """Resolve preset ``name`` across the two tiers (workspace override first,
    built-in second), first-wins. Returns the parsed preset dict.

    Raises ``PresetError`` — never a bare traceback — when the name is unsafe,
    when a resolved file fails to parse, or when nothing resolves at any tier
    (the message lists exactly what was searched).

    Note: this only RESOLVES + parses; call ``validate_preset`` on the result to
    check its shape (mirrors `recipes.resolve` vs `recipes.validate`).
    """
    # The name is interpolated into a file path — reuse the recipe name guard so
    # "../../etc/passwd" can't traverse out of the presets dir (fail closed
    # before touching the filesystem).
    try:
        _validate_recipe_name(name, source="preset name")
    except RecipeError as e:
        raise PresetError(str(e)) from None

    for _tier, d in _tier_dirs(repo):
        path = os.path.join(d, f"{name}.json")
        # Open directly rather than isfile-then-open: one syscall instead of two,
        # and no TOCTOU window. A missing file at this tier falls through to the
        # next; a present-but-unreadable/unparseable file is a hard error.
        try:
            with open(path) as f:
                # U6 (KTD-1): upgrade a format-v1 preset to v2 IN MEMORY, right
                # after json.load and BEFORE validate_preset — whose known-key set
                # is now `backend_op` only, so a user's pre-rename preset (carrying
                # the legacy op key + op value; see format_compat) would otherwise
                # HARD-FAIL and abort `/auto --preset <name>`. Presets are
                # user-authorable and auto never writes them back, so read-compat is
                # INDEFINITE, exactly as for workflow files. Pure + idempotent: a v2
                # preset passes through unchanged.
                return _format_compat.upgrade_preset(json.load(f))
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as e:
            raise PresetError(
                f"preset {name!r} at {path} failed to load: {e}"
            ) from None

    searched = ", ".join(os.path.join(d, f"{name}.json") for _, d in _tier_dirs(repo))
    raise PresetError(f"preset {name!r} not found; searched: {searched}")


def validate_preset(obj) -> tuple:
    """Validate a preset dict. Returns ``(ok: bool, errors: list[str])`` — it
    COLLECTS problems rather than raising, so a caller (loader or authoring UI)
    can surface them all at once.

    Enforced:
      - object shape; only {name, version, description, invokes} top-level keys
      - a `verification` / `phase` / `depends_on` key is a HARD error, named
        explicitly (R2 + the preset-vs-container boundary)
      - name is a non-empty, filename-safe string (reuses the recipe name guard)
      - version / description are non-empty strings
      - invokes is an object of {backend_op, prompt_template?}
      - backend_op is required and ∈ VALID_BACKEND_OPS (the shared leaf)
      - prompt_template, when present, is path-bounded via `_check_prompt_template`
        (relative, no `..`, no leading `/`) — the SAME check recipes use
    """
    errors: list = []

    if not isinstance(obj, dict):
        return False, ["preset must be a JSON object"]

    # Forbidden keys FIRST so their precise message wins over the generic
    # unknown-field message (a `verification`-bearing preset is the R2 headline).
    for k in _FORBIDDEN_TOPLEVEL:
        if k in obj:
            errors.append(
                f"preset must not carry a {k!r} field — a preset is pure "
                f"payload with no gate ({k} is a container/flow concern, not a "
                f"preset concern)"
            )

    for k in obj:
        if k not in _KNOWN_TOPLEVEL and k not in _FORBIDDEN_TOPLEVEL:
            errors.append(f"unknown top-level field: {k!r}")

    # name: required, non-empty, filename-safe.
    name = obj.get("name")
    if not isinstance(name, str) or not name:
        errors.append("name must be a non-empty string")
    else:
        try:
            _validate_recipe_name(name, source="preset.name")
        except RecipeError as e:
            errors.append(str(e))

    for req in ("version", "description"):
        v = obj.get(req)
        if not isinstance(v, str) or not v:
            errors.append(f"{req} must be a non-empty string")

    if "invokes" not in obj:
        errors.append("missing required field: 'invokes'")
    else:
        inv = obj["invokes"]
        if not isinstance(inv, dict):
            errors.append("invokes must be an object")
        else:
            for ik in inv:
                if ik not in _KNOWN_INVOKES_KEYS:
                    errors.append(
                        f"invokes: unknown field {ik!r}; known: "
                        f"{sorted(_KNOWN_INVOKES_KEYS)}"
                    )
            op = inv.get("backend_op")
            if not isinstance(op, str) or not op:
                errors.append("invokes.backend_op must be a non-empty string")
            elif op not in VALID_BACKEND_OPS:
                errors.append(
                    f"invokes.backend_op {op!r} not in the closed set "
                    f"{sorted(VALID_BACKEND_OPS)}"
                )
            if "prompt_template" in inv:
                try:
                    _check_prompt_template(inv["prompt_template"], "invokes")
                except RecipeError as e:
                    errors.append(str(e))

    return (len(errors) == 0), errors


def load_and_validate_preset(name: str, repo: str) -> dict:
    """Resolve preset ``name`` and validate its shape in one call — the loader
    convenience the ``auto-preset`` skill (and the CLI below) use so a malformed
    preset fails closed BEFORE it is launched.

    Raises ``PresetError`` — never a bare traceback — on an unresolved/unparseable
    name (from ``load_preset``) OR on an invalid shape (the collected
    ``validate_preset`` errors, joined). Returns the validated preset dict.
    """
    obj = load_preset(name, repo)
    ok, errors = validate_preset(obj)
    if not ok:
        raise PresetError(f"preset {name!r} is invalid: " + "; ".join(errors))
    return obj


# ── op-dispatch CLI (exercised by tests/unit/preset-cli.test.sh) ─────────────
def _cli(argv) -> int:
    if not argv:
        sys.stderr.write("usage: presets.py <op> ...\n")
        return 2
    op = argv[0]
    if op == "load-validate":
        # argv[1] = preset name, argv[2] = repo. Prints OK on a valid resolved
        # preset, or the operator-facing PresetError message otherwise.
        if len(argv) != 3:
            sys.stderr.write("usage: presets.py load-validate <name> <repo>\n")
            return 2
        try:
            load_and_validate_preset(argv[1], argv[2])
        except PresetError as e:
            print("INVALID: " + str(e))
            return 0
        print("OK")
        return 0
    sys.stderr.write(f"presets.py: unknown op {op!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
