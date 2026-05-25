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
    """
    path = os.path.join(_LIB_DIR, f"{name}.py")
    spec_name = name.replace("-", "_")
    spec = importlib.util.spec_from_file_location(spec_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_ledger():
    """Load and return the canonical ledger module (lib/ledger.py).

    Thin wrapper over ``load_lib_module("ledger")`` — kept as a named entry point
    because eight consumers already call it; the load strategy lives in one place.
    """
    return load_lib_module("ledger")
