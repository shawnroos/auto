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
    invocation, so the eight existing hatches (NO_TICK_LOCK, NO_REENQUEUE,
    NO_STALENESS_CHECK, FORCE_THREETIER_GATING, NO_RECOMPUTE, NO_LOCK,
    NO_ATTEMPT_CHECK, NO_STALLED_RECOVERY) and any future hatches inherit the
    fence for free. Deterministic, grep-checkable mechanism — composes with
    feedback_deterministic_over_probabilistic_v1.
    """
    return (
        os.environ.get("CLAUDE_AUTO_TEST_HARNESS") == "1"
        and os.environ.get(hatch_var) == "1"
    )
