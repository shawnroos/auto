#!/usr/bin/env python3
"""auto CONTENT data object — loader + validator (U1, addressable-step-contents).

A *content* is the pure `invokes` payload of a step, promoted to a first-class
named object:

    {"name", "version", "description", "invokes": {"adapter_op", "prompt_template"?}}

It carries NO verification gate (R2) — a content is payload, never payload+gate.
The container concerns `phase` and `depends_on` are NOT a content's business
either (those live on the flow that hosts it); this validator rejects all three
keys so the content/container boundary stays clean.

RESOLUTION (a deliberate SUBSET of `recipes.py`'s registry — Phase 1 ships no
tri-tier catalog / `list_available`, which is R3/Phase 2). Two tiers, first-wins:

    1. workspace:  <repo>/.claude/auto/contents/<name>.json   (override)
    2. built-in:   <auto_root>/contents/<name>.json           (shipped seed)

A workspace file of the same name OVERRIDES the built-in (first-wins, workspace
first — mirrors `recipes.resolve`). An unknown name raises `ContentError` with a
clear, operator-facing message that lists what was searched — never a traceback.

DAG DISCIPLINE (KTD-2): this module reuses `recipe_validate`'s primitives
(`_check_prompt_template` for path-bounding, `_validate_recipe_name` for the
filename-safe name check) and imports `VALID_ADAPTER_OPS` from the pure-stdlib
leaf `adapter_ops`. It MUST NOT import `orchestrator.py` — that module pulls in
the ledger and the whole dispatch surface; the validator stays a light leaf.
`recipe_validate` and `adapter_ops` are themselves DAG roots (no sibling
imports), so this stays a shallow, cycle-free layer.

VALIDATION IS HAND-ROLLED (no `jsonschema` — same install-anywhere constraint as
`recipe_validate`; the plugin ships pure stdlib + bash to arbitrary repos). The
written contract is `docs/contracts/content-format.md` (marked PROVISIONAL until
a Phase-2 `content_ref` consumer validates the container/content boundary); there
is deliberately no `contents/schema.json` — code is the enforcement.
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
# validation DAG root; `adapter_ops` is the pure-stdlib op-set leaf. Neither
# imports a heavy sibling, so this module stays light.
_recipe_validate = load_lib_module("recipe_validate")
_adapter_ops = load_lib_module("adapter_ops")

_check_prompt_template = _recipe_validate._check_prompt_template
_validate_recipe_name = _recipe_validate._validate_recipe_name
RecipeError = _recipe_validate.RecipeError
VALID_ADAPTER_OPS = _adapter_ops.VALID_ADAPTER_OPS

# The built-in seed directory: <auto_root>/contents (auto_root is lib/'s parent),
# computed the same way recipe_validate._BUILTIN_DIR resolves <auto_root>/recipes.
_BUILTIN_DIR = os.path.join(os.path.dirname(_LIB_DIR), "contents")

# A content is a closed object: exactly these top-level keys are known. `invokes`
# is a closed sub-object of {adapter_op, prompt_template}. `verification`,
# `phase`, and `depends_on` are NOT merely "unknown" — they are named explicitly
# in the reject list so the error message is precise about WHY (R2 / the
# content-vs-container boundary), rather than a generic "unknown field".
_KNOWN_TOPLEVEL = frozenset({"name", "version", "description", "invokes"})
_FORBIDDEN_TOPLEVEL = frozenset({"verification", "phase", "depends_on"})
_KNOWN_INVOKES_KEYS = frozenset({"adapter_op", "prompt_template"})


class ContentError(Exception):
    """A content failed to load (resolution). Message is operator-facing."""


def _tier_dirs(repo_root: str):
    """The content directories in resolution order: (tier_name, dir). Workspace
    first (override), built-in last (shipped seed). A deliberate two-tier SUBSET
    of `recipes._tier_dirs` — no global tier, no catalog (R3/Phase 2)."""
    return [
        ("workspace", os.path.join(repo_root, ".claude", "auto", "contents")),
        ("built-in", _BUILTIN_DIR),
    ]


def load_content(name: str, repo: str) -> dict:
    """Resolve content ``name`` across the two tiers (workspace override first,
    built-in second), first-wins. Returns the parsed content dict.

    Raises ``ContentError`` — never a bare traceback — when the name is unsafe,
    when a resolved file fails to parse, or when nothing resolves at any tier
    (the message lists exactly what was searched).

    Note: this only RESOLVES + parses; call ``validate_content`` on the result to
    check its shape (mirrors `recipes.resolve` vs `recipes.validate`).
    """
    # The name is interpolated into a file path — reuse the recipe name guard so
    # "../../etc/passwd" can't traverse out of the contents dir (fail closed
    # before touching the filesystem).
    try:
        _validate_recipe_name(name, source="content name")
    except RecipeError as e:
        raise ContentError(str(e)) from None

    for _tier, d in _tier_dirs(repo):
        path = os.path.join(d, f"{name}.json")
        # Open directly rather than isfile-then-open: one syscall instead of two,
        # and no TOCTOU window. A missing file at this tier falls through to the
        # next; a present-but-unreadable/unparseable file is a hard error.
        try:
            with open(path) as f:
                return json.load(f)
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as e:
            raise ContentError(
                f"content {name!r} at {path} failed to load: {e}"
            ) from None

    searched = ", ".join(os.path.join(d, f"{name}.json") for _, d in _tier_dirs(repo))
    raise ContentError(f"content {name!r} not found; searched: {searched}")


def validate_content(obj) -> tuple:
    """Validate a content dict. Returns ``(ok: bool, errors: list[str])`` — it
    COLLECTS problems rather than raising, so a caller (loader or authoring UI)
    can surface them all at once.

    Enforced:
      - object shape; only {name, version, description, invokes} top-level keys
      - a `verification` / `phase` / `depends_on` key is a HARD error, named
        explicitly (R2 + the content-vs-container boundary)
      - name is a non-empty, filename-safe string (reuses the recipe name guard)
      - version / description are non-empty strings
      - invokes is an object of {adapter_op, prompt_template?}
      - adapter_op is required and ∈ VALID_ADAPTER_OPS (the shared leaf)
      - prompt_template, when present, is path-bounded via `_check_prompt_template`
        (relative, no `..`, no leading `/`) — the SAME check recipes use
    """
    errors: list = []

    if not isinstance(obj, dict):
        return False, ["content must be a JSON object"]

    # Forbidden keys FIRST so their precise message wins over the generic
    # unknown-field message (a `verification`-bearing content is the R2 headline).
    for k in _FORBIDDEN_TOPLEVEL:
        if k in obj:
            errors.append(
                f"content must not carry a {k!r} field — a content is pure "
                f"payload with no gate ({k} is a container/flow concern, not a "
                f"content concern)"
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
            _validate_recipe_name(name, source="content.name")
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
            op = inv.get("adapter_op")
            if not isinstance(op, str) or not op:
                errors.append("invokes.adapter_op must be a non-empty string")
            elif op not in VALID_ADAPTER_OPS:
                errors.append(
                    f"invokes.adapter_op {op!r} not in the closed set "
                    f"{sorted(VALID_ADAPTER_OPS)}"
                )
            if "prompt_template" in inv:
                try:
                    _check_prompt_template(inv["prompt_template"], "invokes")
                except RecipeError as e:
                    errors.append(str(e))

    return (len(errors) == 0), errors


def load_and_validate_content(name: str, repo: str) -> dict:
    """Resolve content ``name`` and validate its shape in one call — the loader
    convenience the ``auto-content`` skill (and the CLI below) use so a malformed
    content fails closed BEFORE it is launched.

    Raises ``ContentError`` — never a bare traceback — on an unresolved/unparseable
    name (from ``load_content``) OR on an invalid shape (the collected
    ``validate_content`` errors, joined). Returns the validated content dict.
    """
    obj = load_content(name, repo)
    ok, errors = validate_content(obj)
    if not ok:
        raise ContentError(f"content {name!r} is invalid: " + "; ".join(errors))
    return obj


# ── op-dispatch CLI (exercised by tests/unit/content-cli.test.sh) ─────────────
def _cli(argv) -> int:
    if not argv:
        sys.stderr.write("usage: contents.py <op> ...\n")
        return 2
    op = argv[0]
    if op == "load-validate":
        # argv[1] = content name, argv[2] = repo. Prints OK on a valid resolved
        # content, or the operator-facing ContentError message otherwise.
        if len(argv) != 3:
            sys.stderr.write("usage: contents.py load-validate <name> <repo>\n")
            return 2
        try:
            load_and_validate_content(argv[1], argv[2])
        except ContentError as e:
            print("INVALID: " + str(e))
            return 0
        print("OK")
        return 0
    sys.stderr.write(f"contents.py: unknown op {op!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
