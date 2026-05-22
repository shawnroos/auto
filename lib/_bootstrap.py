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


def load_ledger():
    """Load and return the canonical ledger module (lib/ledger.py) by file path.

    No package install required — resolves ledger.py as a sibling of this file.
    Each call creates a fresh module object; callers bind it once at import time.
    """
    path = os.path.join(_LIB_DIR, "ledger.py")
    spec = importlib.util.spec_from_file_location("ledger", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
