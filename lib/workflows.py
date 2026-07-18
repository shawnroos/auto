#!/usr/bin/env python3
"""auto workflow REGISTRY facade + the A1 built-in constant (U3/U7; U17 split).

A *workflow* is a named, file-backed JSON declaration of a LOOP topology — an
ordered graph of steps (CONCEPTS.md) — the
initial-run-record shape `/auto` builds a run from. This module is the three-tier
REGISTRY (workspace → global → built-in, first-wins) and the public surface every
consumer reaches through the ``workflows.`` namespace.

U17 (v0.9.0) split the former ~981-LOC workflows.py BY CONCERN: the ~700-LOC
validation family moved to lib/workflow_validate.py (the DAG root — pure stdlib,
imports no sibling), and THIS file is the thin registry facade. It re-exports the
validation surface (``validate`` / ``validate_and_lint`` / ``WorkflowError`` /
``V1_PRODUCER_NAMES`` / the ``_validate_*`` helpers ``resolve``/``step_for`` need)
so existing callers that do ``workflows.validate(...)``, ``except workflows.WorkflowError``,
``workflows.V1_PRODUCER_NAMES`` etc. keep resolving unchanged — exactly the pattern
the run-record facade uses for run_record_core/mutators/producers. ``WorkflowError`` lives in
workflow_validate (the root) and is re-exported here, so it is importable from BOTH
modules with no import cycle (facade → workflow_validate, one direction).

This module holds:
  U3 — the three-tier registry (``resolve``, ``list_available``,
       ``load_and_validate``, ``step_for``, ``workspace_workflow_path``, ``_tier_dirs``).
  U7 — ``A1_BUILTIN`` constant (the canonical runtime fallback).
Validation (``validate`` / ``validate_and_lint`` / format rules) → workflow_validate.
"""

from __future__ import annotations

import json
import os
import sys

# Load the validation module via the standard bootstrap loader. The workflows
# surface is loaded from many sites by file path (the test harness uses
# spec_from_file_location, which does NOT add lib/ to sys.path), so a plain
# `from workflow_validate import ...` is not guaranteed to resolve. Prepending
# lib/ + routing through _bootstrap.load_lib_module is the one robust load
# strategy the codebase already uses for sibling modules (see lib/run_record.py).
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

workflow_validate = load_lib_module("workflow_validate")
# U6 (KTD-1): the format-v1 → v2 read shim. DAG root, pure stdlib, imports no
# sibling — so this edge closes no cycle.
format_compat = load_lib_module("format_compat")

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from workflow_validate (the validation DAG root). Every name is listed
# explicitly (greppable) so the re-export surface is auditable and a consumer's
# `workflows.<name>` keeps resolving after the U17 split. WorkflowError is shared —
# both modules expose it, no cycle (this facade imports it; the root defines it).

WorkflowError = workflow_validate.WorkflowError  # shared exception (both modules expose it)
validate = workflow_validate.validate
validate_and_lint = workflow_validate.validate_and_lint

# Public constant consumers read as workflows.V1_PRODUCER_NAMES (e.g. the U5b
# symmetry test that cross-checks it against step_producers.REGISTRY).
V1_PRODUCER_NAMES = workflow_validate.V1_PRODUCER_NAMES

# Format constants + the private validation helpers the registry below reaches:
# resolve() calls _validate_workflow_name + _bad; step_for() calls
# _check_prompt_template; _tier_dirs() reads _BUILTIN_DIR. Re-exported so both
# the facade internals AND any consumer that referenced them via workflows.<name>
# before the split keep resolving.
_bad = workflow_validate._bad
_validate_workflow_name = workflow_validate._validate_workflow_name
# The reserved-alias-name gate lives in workflow_validate (the DAG root that both
# validate() and validate_and_lint() funnel through). It holds a copy of the
# _ALIASES map below; a workflow authored under one of those legible names is
# rejected at validate time (fail fast) instead of being silently shadowed by
# resolve()'s alias→stem rewrite. Re-exported so the drift-guard test can assert
# `_ALIASES == _RESERVED_ALIAS_STEMS` (the two copies never diverge).
_RESERVED_ALIAS_STEMS = workflow_validate._RESERVED_ALIAS_STEMS
_check_prompt_template = workflow_validate._check_prompt_template
_lint_verification_placement = workflow_validate._lint_verification_placement
_builtin_names = workflow_validate._builtin_names
_BUILTIN_DIR = workflow_validate._BUILTIN_DIR
_DEFAULT_PHASE_ORDER = workflow_validate._DEFAULT_PHASE_ORDER
_WORK_ONLY_PHASE_ORDER = workflow_validate._WORK_ONLY_PHASE_ORDER


# A1 (Classic CE Stack) as a Python constant — the canonical runtime fallback
# (KTD-1). `workflows/a1.json` is the user-facing override target + conformance
# fixture, but bare `/auto` resolves A1 from THIS constant when no a1.json
# resolves at any tier — so a corrupted/missing built-in JSON can't break the
# default workflow. A U7 test asserts this constant equals the resolved a1.json
# topology (no drift) and that it passes validate().
A1_BUILTIN = {
    "name": "a1",
    "version": "1",
    "description": "Classic CE Stack — plan, build, review, fix to P3-only exit. The v0.1.x default workflow.",
    "default_backend": "ce",
    "phase_order": ["plan", "handoff", "work"],
    "terminal_phase": "work",
    "phase_transitions": [
        {"from": "plan", "to": "work", "producer": "plan_output_to_work_steps"}
    ],
    "steps": [
        {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {"backend_op": "next_plan_step"}}
    ],
}


# ──────────────────────────────────────────────────────────────────────────
# U6 (R9): legible names that ALIAS the a1/a2/a4/w shorthand. A PURE alias layer
# — each legible name resolves to the SAME workflow as its stem. `resolve()`
# rewrites a legible name to its stem BEFORE the file lookup, so a legible name
# lands on the stem's workflow at whichever tier it resolves AND inherits the
# stem's fallback (e.g. `plan-build-review` → `a1`, which still falls back to
# A1_BUILTIN when no a1.json resolves). The stem files and A1_BUILTIN are NEVER
# renamed (KTD-6). Each name is confirmed against the workflow's `description`:
#   a1 "Classic CE Stack — plan, build, review"  → plan-build-review
#   a2 "Parallel Theories + Judge"               → parallel-theories
#   a4 "Adversarial Pair + Comparator"           → adversarial-pair
#   w  "Work-only"                               → work-only
# RESERVED NAMES: the four legible keys below are rewritten to their stem BEFORE
# any tier file lookup, so a user workflow literally named e.g. `work-only.json`
# would be shadowed (it resolves to `w`). These names are reserved aliases — do
# not author a custom workflow under one of them.
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
    site is what lets ``launch-gate.SKIP_ELIGIBLE_WORKFLOWS`` hold STEMS ONLY (no
    dead alias entries): aliases are folded to stems here, upstream of the check.
    """
    return _ALIASES.get(name, name)


# ──────────────────────────────────────────────────────────────────────────
# U3: three-tier registry — workspace → global → built-in, first-wins.

# U8 (KTD-7): the LEGACY workspace/global dir name. Before the concept-vocabulary
# rename the tier dirs were `.claude/auto/recipes/`; users have real workflow files
# sitting there RIGHT NOW. Renaming the dir without a fallback would silently make
# every one of them unresolvable ("workflow 'x' not found") — a rename is not a
# licence to drop the user's files on the floor. So the old dirs stay as READ-ONLY
# legacy tiers appended after their new-name counterparts. This literal MUST spell
# the old name — it is the one place in the tree that legitimately does, and it is
# whitelisted in tests/unit/vocabulary-audit.test.sh for exactly that reason.
_LEGACY_TIER_DIRNAME = "recipes"


def _tier_dirs(repo_root: str):
    """The workflow directories in resolution order: (tier_name, dir).

    U8 (KTD-7) — five tiers, not three. Each user-writable tier is probed at its
    NEW dir first, then at the LEGACY (pre-rename) dir:

        workspace → workspace-legacy → global → global-legacy → built-in

    FIRST-WINS IS PRESERVED, and the ordering is deliberate: the new dir shadows
    the legacy dir at the SAME tier (the new home wins, so a user who has migrated
    one file is not fighting their own stale copy), and any workspace file —
    new-dir or legacy-dir — still shadows every global one (tier precedence
    outranks dir-vintage, which is what "workspace overrides global" has always
    meant).

    The legacy tiers are READ-ONLY: nothing in the codebase ever writes to them.
    ``workspace_workflow_path`` (the sole write path) targets the NEW dir only, so
    a run-scoped variant is written to — and torn down from — `workflows/`, never
    the legacy dir. Legacy tiers report the same tier NAME as their modern sibling
    (`workspace` / `global`): the tier badge is a PRECEDENCE fact the picker and
    the description-spoofing guard consume, not a statement about which directory
    the bytes came from.
    """
    home = os.path.expanduser("~")
    return [
        ("workspace", os.path.join(repo_root, ".claude", "auto", "workflows")),
        ("workspace", os.path.join(repo_root, ".claude", "auto", _LEGACY_TIER_DIRNAME)),
        ("global", os.path.join(home, ".claude", "auto", "workflows")),
        ("global", os.path.join(home, ".claude", "auto", _LEGACY_TIER_DIRNAME)),
        ("built-in", _BUILTIN_DIR),
    ]


def workspace_workflow_path(repo_root: str, name: str) -> str:
    """The workspace-tier file path for workflow ``name`` (the run-scoped variant
    home). Single source of truth for where the launch chooser writes a
    ``<builtin>-<run-slug>`` workflow and where ``auto.py --teardown-workflow-after-init``
    deletes exactly that file post-init. Targets ONLY the workspace tier, so it can
    never name a built-in or global workflow — deleting it can't shadow-break a
    canonical workflow."""
    return os.path.join(repo_root, ".claude", "auto", "workflows", f"{name}.json")


def resolve(name: str, repo_root: str):
    """Resolve workflow ``name`` across the three tiers, first-wins.

    Returns ``(workflow_dict, source_tier)``. For the built-in ``a1`` specifically,
    falls back to the ``A1_BUILTIN`` Python constant if no ``a1.json`` resolves at
    any tier (KTD-1 — a corrupt/missing built-in JSON can't break bare ``/auto``).
    Raises ``WorkflowError`` (FileNotFound-shaped message) if nothing resolves.

    P0 #4 fix-pass B: layer 2 — the CLI-supplied ``--workflow`` value lands here
    unvalidated; without this check ``name="../../etc/passwd"`` would happily
    traverse out of the workflows dir via os.path.join. The check is BEFORE any
    path construction (fail closed before touching the filesystem).
    """
    _validate_workflow_name(name, source="--workflow argument")
    # U6 (R9): rewrite a legible alias to its shorthand stem BEFORE any path
    # construction or the `name == "a1"` constant fallback — so a legible name
    # resolves to the stem's workflow at every tier AND inherits the stem's
    # A1_BUILTIN fallback. Validation runs on the ORIGINAL name first (defense);
    # a non-alias name passes through unchanged.
    name = canonical_name(name)
    for tier, d in _tier_dirs(repo_root):
        path = os.path.join(d, f"{name}.json")
        if os.path.isfile(path):
            try:
                with open(path) as f:
                    # U6 (KTD-1): upgrade a format-v1 workflow file to v2 IN MEMORY,
                    # right after json.load and BEFORE validate() — the validator now
                    # expects v2 keys. auto never writes a user's workflow file back,
                    # so acceptance of v1-keyed files is INDEFINITE: the file upgrades
                    # on every resolve, forever. Pure + idempotent, so a v2 file is a
                    # no-op pass-through.
                    return format_compat.upgrade_workflow(json.load(f)), tier
            except (OSError, ValueError) as e:
                _bad(f"workflow {name!r} at {path} failed to load: {e}")
    if name == "a1":
        return dict(A1_BUILTIN), "built-in"
    searched = ", ".join(os.path.join(d, f"{name}.json") for _, d in _tier_dirs(repo_root))
    _bad(f"workflow {name!r} not found; searched: {searched}")


def list_available(repo_root: str):
    """All resolvable workflows as ``[(name, source_tier), ...]``, deduped by name
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
                continue  # the workflow-shape doc (see module docstring), not a workflow
            nm = fn[:-5]
            if nm in seen:
                continue  # first tier wins
            seen[nm] = tier
            order.append((nm, tier))
    return order


def load_and_validate(name: str, repo_root: str):
    """``resolve`` + ``validate``. Returns ``(workflow_dict, source_tier)`` or
    raises ``WorkflowError``. The engine's entry point at run start."""
    workflow, tier = resolve(name, repo_root)
    validate(workflow)
    return workflow, tier


def step_for(workflow_step: dict, workflow: dict) -> dict:
    """Project a WORKFLOW step dict onto a RUN_RECORD step dict (the shape
    ``run_record.init_run_record`` expects). Merges workflow-side ``invokes`` metadata
    (``prompt_template`` etc.) into ``dispatch_context`` — RE-VALIDATING the
    path bound (the second enforcement point; the first is ``validate``). The
    ``backend_op`` stays in ``dispatch_context`` so the backend reads it via the
    step at dispatch.
    """
    inv = dict(workflow_step.get("invokes") or {})
    if "prompt_template" in inv:
        _check_prompt_template(inv["prompt_template"], f"step {workflow_step.get('id')!r}")
    return {
        "id": workflow_step["id"],
        "phase": workflow_step.get("phase", "work"),
        "depends_on": list(workflow_step.get("depends_on") or []),
        "dispatch_context": inv,
    }


# ──────────────────────────────────────────────────────────────────────────
# CLI — the opt-in `migrate` verb (U6 / KTD-1).
#
# Read-compat for v1-keyed workflow files is INDEFINITE (resolve() upgrades them
# in memory on every read), so migrating a file is never REQUIRED. This verb
# exists for users who want their own files modernized on disk — e.g. so the JSON
# they edit by hand matches the current contract.


def migrate(path: str) -> bool:
    """Rewrite a format-v1 workflow file at ``path`` to v2, in place, atomically.

    Returns True if the file changed, False if it was already v2 (a no-op —
    running this twice is idempotent, because ``upgrade_workflow`` is).

    Atomic = mkstemp + os.replace in the target dir, so a crash mid-write leaves
    the original intact rather than a half-written workflow.
    """
    import tempfile

    with open(path) as f:
        before = json.load(f)
    after = format_compat.upgrade_workflow(before)
    if after == before:
        return False

    target_dir = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(prefix=".workflow.", suffix=".json", dir=target_dir)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(after, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def _cli(argv):
    if len(argv) < 2 or argv[0] != "migrate":
        sys.stderr.write("usage: workflows.py migrate <path-to-workflow.json>\n")
        return 2
    path = argv[1]
    try:
        changed = migrate(path)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"auto: migrate failed for {path!r}: {e}\n")
        return 1
    sys.stdout.write(
        f"migrated {path} to format v2\n" if changed
        else f"{path} is already format v2 (no change)\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
