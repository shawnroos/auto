#!/usr/bin/env python3
"""auto: the ONE ledger-module loader.

Every consumer module (tick.py, orchestrator.py, on-stop.py, on-session-start.py,
goal-status.py, auto-resume.py, auto.py, auto-status.py) loads the canonical ledger
module by FILE PATH rather than `import ledger` — the plugin is not pip-installed
and lib/ is not guaranteed on sys.path. That importlib bootstrap used to be
copy-pasted into all eight modules; it lives here ONCE so a change to the load
strategy (or the Python pin contract) has a single edit site.

Usage from a sibling module in lib/::

    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _bootstrap import load_ledger
    ledger = load_ledger()

We do NOT load _bootstrap itself via importlib — that would just move the
duplication. The two-line sys.path prepend + plain import is the dedup.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))


def load_lib_module(name: str):
    """Load and return a sibling lib/ module by its filename stem, by file path.

    The ONE load strategy for every lib/ module (the plugin is not pip-installed
    and lib/ is not guaranteed on sys.path). ``name`` is the filename stem WITHOUT
    the ``.py`` extension and MAY contain hyphens (e.g. ``"phase-grammar"`` for
    ``lib/phase-grammar.py``) — hyphens are valid in a file path but not in a
    Python module identifier, so the registered spec name sanitizes them to
    underscores (``phase_grammar``). Callers bind the returned module once.

    Added in v0.2.0 (U5) to load the hyphenated ``phase-grammar.py`` (and reusable
    for ``topology-render.py``). Generalizes the former ``load_ledger`` idiom that
    was previously the only loader here.

    Caches the loaded module in ``sys.modules`` under ``spec_name`` so repeat
    calls return the SAME instance — important for classes (e.g.
    ``recipes.RecipeError``): without caching, two callers that both
    ``load_lib_module("recipes")`` would each get a fresh ``RecipeError`` class
    and ``except recipes.RecipeError`` in one wouldn't catch a raise from the
    other. The cache mirrors ordinary Python import semantics; the file-path
    load strategy is unchanged.
    """
    path = os.path.join(_LIB_DIR, f"{name}.py")
    spec_name = name.replace("-", "_")
    cached = sys.modules.get(spec_name)
    if cached is not None:
        # Only re-use if it came from our path (defensive — an unrelated module
        # of the same name shouldn't be returned).
        cached_file = getattr(cached, "__file__", None)
        if cached_file and os.path.abspath(cached_file) == os.path.abspath(path):
            return cached
    spec = importlib.util.spec_from_file_location(spec_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec_name] = module  # register BEFORE exec so cyclic refs resolve.
    try:
        spec.loader.exec_module(module)
    except BaseException:
        # Roll back the registration on a load failure so the next attempt
        # doesn't see a half-initialized module.
        sys.modules.pop(spec_name, None)
        raise
    return module


def resolve_repo() -> str:
    """Repo root: $CLAUDE_AUTO_REPO, else walk up from cwd for .claude/auto.

    Used by every CLI module that needs to find the repo's ``.claude/auto``
    directory (``auto.py``, ``auto-resume.py``, ``auto-status.py``). Consolidated
    here from three identical copies (P2-8) so the lookup rule lives in ONE
    place. ``$CLAUDE_AUTO_REPO`` is the explicit override; otherwise we walk up
    from cwd looking for ``.claude/auto``; the fallback is cwd (a fresh run that
    has not yet created the directory — ``init_ledger`` creates it).
    """
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    dir_ = os.getcwd()
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "auto")):
            return dir_
        dir_ = os.path.dirname(dir_)
    return os.getcwd()


def resolve_host_repo_root(*, cwd=None):
    """Absolute path of the MAIN repo (the host of any worktrees), or None.

    v0.4.0 KTD-3 (round-3 finding R3-001 — empirically verified): from inside a
    git worktree, ``git rev-parse --show-toplevel`` returns the *worktree's*
    own root, NOT the main repo. For multi-plan fanout we need the host repo
    so spawned worktrees nest under the main checkout's ``worktrees/`` —
    independent of which worktree the parent session is itself running in.

    The mechanism uses ``git rev-parse --git-common-dir``: from a main repo
    this returns ``.git`` (the actual git dir); from a worktree it returns
    the main repo's ``.git`` (NOT the worktree's ``.git/worktrees/<name>/``
    private dir). The parent of the resolved common-dir is the host repo
    root in both cases.

    Returns the absolute host repo path. Returns ``None`` when git is not
    available or cwd is not inside a git tree — callers must handle the
    None case (typically by erroring out: fanout requires a git repo).

    Pass ``cwd`` to run git from a specific directory (review round 1 fix:
    on-stop.py needs to query the host repo from a process whose cwd may
    be elsewhere).
    """
    return _resolve_host_repo_root(cwd=cwd)


def _resolve_host_repo_root(*, cwd=None):
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=False,
            cwd=cwd,
        )
    except (OSError, FileNotFoundError):
        return None
    if result.returncode != 0:
        return None
    common_dir = result.stdout.strip()
    if not common_dir:
        return None
    # git emits a relative path when cwd is inside the main repo (".git") and
    # an absolute path from inside a worktree. Resolve to absolute either way,
    # then return the parent (the main repo root). When cwd is provided,
    # `os.path.abspath` resolves the relative path against the PROCESS cwd
    # rather than the cwd we passed to git — so for relative outputs we must
    # join explicitly against cwd before resolving.
    if not os.path.isabs(common_dir) and cwd is not None:
        common_dir = os.path.join(cwd, common_dir)
    abs_common = os.path.abspath(common_dir)
    return os.path.dirname(abs_common)


def resolve_shared_dir(*, cwd=None):
    """Absolute path to ``<host-repo-root>/.claude/auto/``, or None.

    v0.4.0 KTD-3: shared state — batch sidecars, cross-worktree run discovery,
    the v0.4 default-flip back-compat marker — lives at the HOST repo's
    ``.claude/auto/`` (NOT the cwd worktree's). This helper wraps
    ``resolve_host_repo_root()`` + the ``.claude/auto/`` join so every shared-
    state consumer reads the same path.

    Returns ``None`` when ``resolve_host_repo_root()`` returns None (no git).
    Callers that need a directory MUST handle None — typically by degrading
    to per-worktree state (the legacy ``resolve_repo`` shape) or erroring out
    for features that genuinely require shared state (fanout).

    Distinct from ``resolve_repo()``: that returns the per-worktree ledger
    home (env-pinned via ``CLAUDE_AUTO_REPO`` for sub-runs); this returns the
    main repo's shared state directory. Both are needed: the per-worktree
    helper for "what does THIS worktree own", this helper for "what does the
    parent know across worktrees".
    """
    host = resolve_host_repo_root(cwd=cwd)
    if host is None:
        return None
    return os.path.join(host, ".claude", "auto")


def load_ledger():
    """Load and return the canonical ledger module (lib/ledger.py).

    Thin wrapper over ``load_lib_module("ledger")`` — kept as a named entry point
    because eight consumers already call it; the load strategy lives in one place.
    """
    return load_lib_module("ledger")


def test_hatch_enabled(hatch_var: str) -> bool:
    """Return True iff BOTH the test-harness sentinel AND ``hatch_var`` are set.

    Task #31 (extended to the class per feedback_fix_the_class_not_the_cited_instance):
    every CLAUDE_AUTO_TEST_* deliberate-fail hatch in the codebase routes through
    this one helper. A production user who exports a specific hatch by accident
    will NOT also have ``CLAUDE_AUTO_TEST_HARNESS=1`` exported, so the hatch
    stays inert. tests/run.sh exports the sentinel once at the top of every test
    invocation, so the existing hatches (NO_TICK_LOCK, NO_REENQUEUE,
    NO_STALENESS_CHECK, FORCE_THREETIER_GATING, NO_RECOMPUTE, NO_LOCK,
    NO_ATTEMPT_CHECK, NO_STALLED_RECOVERY) and any future hatches inherit the
    fence for free. Deterministic, grep-checkable mechanism — composes with
    feedback_deterministic_over_probabilistic_v1.
    """
    return (
        os.environ.get("CLAUDE_AUTO_TEST_HARNESS") == "1"
        and os.environ.get(hatch_var) == "1"
    )


def is_iteration_disabled() -> bool:
    """Return True iff the operator has set ``CLAUDE_AUTO_DISABLE_ITERATION=1``.

    The iteration kill-switch — a REAL operator escape hatch, not a test-only
    hatch. When set, ``tick.advance_iteration_loop`` short-circuits and the
    standard predicate-met flow takes over (the run exits as if no iteration
    block existed on the ledger). Useful for emergency rollback of an
    outcomes-gated recipe without redeploying.

    Originally (v0.3.0 U4) this routed through ``test_hatch_enabled`` and
    therefore ALSO required ``CLAUDE_AUTO_TEST_HARNESS=1`` — making it inert
    in production. v0.3.0 F5 unfences it: the var is now a runtime-tunable
    operator knob (CRIT-2 + rel-3). Composes with
    feedback_deterministic_over_probabilistic_v1: env-var presence is a
    deterministic, grep-checkable mechanism.
    """
    return os.environ.get("CLAUDE_AUTO_DISABLE_ITERATION") == "1"
