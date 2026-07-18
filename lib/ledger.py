#!/usr/bin/env python3
"""DEPRECATED re-export shim (concept-vocabulary rename U9): ledger → run_record.

**This is NOT a bare CLI-exec stub, and it must never become one.** Several call
sites load this file BY PATH and then reach for a SYMBOL on the resulting module
object:

    spec = importlib.util.spec_from_file_location("ledger", ".../lib/ledger.py")
    L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
    L.ledger_path(repo, run)   # ← a symbol, not a subprocess

``lib/cmux-socket.sh`` did exactly that (both its ``spec_from_file_location``
sites), and every such block is wrapped in ``except: sys.exit(0)`` — so a stub
that only execs a CLI under ``__main__`` would define NO ``ledger_path``, the
AttributeError would be swallowed, and the runaway-spawn sentinel / double-drive
guard would silently FAIL OPEN. (U9 also repoints cmux-socket at
``run_record.py`` — that repoint is the suspenders; this module-importable shim
is the belt, for any out-of-tree caller with the memorized path.)

So: importing this file by path re-exports the WHOLE public surface of
``run_record.py`` under the OLD names — ``ledger_path``, ``read_ledger``,
``init_ledger``, the ``LedgerError`` family, and the CLI — plus the new names,
so both spellings resolve off one module object. The classes are the SAME class
objects (rebound, not redefined), so ``except ledger.LedgerError`` still catches
a raise from anywhere in the run_record family.

Kept one minor version for agents/scripts with the memorized ``lib/ledger.py``
path; removed next minor. Whitelisted in tests/unit/vocabulary-audit.test.sh.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

_rr = load_lib_module("run_record")

# ── New-vocabulary surface: re-export everything public run_record.py exposes,
# so a by-path loader of this shim sees the same module surface as the real one.
for _name in dir(_rr):
    if _name.startswith("__"):
        continue
    globals()[_name] = getattr(_rr, _name)

# ── OLD-vocabulary aliases (the whole point of this shim). Explicit and
# greppable — every name a pre-rename by-path caller could reach for. The error
# classes are REBOUND (same objects), never redefined: `except ledger.LedgerError`
# must catch a raise from run_record_core.
LedgerError = _rr.RunRecordError
LedgerNotFound = _rr.RunRecordNotFound
LedgerExists = _rr.RunRecordExists

ledger_path = _rr.run_record_path
read_ledger = _rr.read_run_record
init_ledger = _rr.init_run_record
_with_locked_ledger = _rr._with_locked_run_record

# lock_path / now_iso / parse_iso / transition / record_verdict / set_loop /
# the steering + producer verbs / apply_pause / describe never carried the term,
# so the `dir(_rr)` re-export above already binds them under their real names.


def _deprecation_notice() -> None:
    # stderr ONLY — a legacy `python3 lib/ledger.py read <repo> <run> | jq`
    # pipeline must keep a byte-clean stdout.
    sys.stderr.write(
        "lib/ledger.py is deprecated; use lib/run_record.py (ledger→run-record rename)\n"
    )


if __name__ == "__main__":
    _deprecation_notice()
    sys.exit(_rr._cli(sys.argv[1:]))
