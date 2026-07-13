#!/usr/bin/env python3
"""auto U7: deterministic loop-status, the data behind goal-status.sh.

Consumer: the engine's OWN Stop hook (.claude/hooks/on-stop.sh). NOT native
`/goal` (U9 spike: `/goal` is a closed model-judged loop with no external
predicate handoff — see docs/research/native-goal-mechanism-spike.md).

FRESHNESS GUARANTEE (C2 / I-1):
    No cached copy exists; we read the I-1-fresh field directly off the ledger.
    `exit_predicate_result` is recomputed inside ledger.py's single atomic-write
    chokepoint on every write (schema §5 I-1). Here we ONLY read it back — we do
    NOT maintain a separate `done` that could drift. `done` IS
    `exit_predicate_result.met` from the same atomic snapshot. There is no
    staleness window where status says done while the ledger says not (the
    re-review verdict-returned → pending reopen is reflected immediately because
    the predicate is recomputed on that very write).

Reads the ledger LOCK-FREE: the atomic-rename invariant (mkstemp + os.rename)
means a reader always sees a whole, consistent file — never a torn one. This
keeps the Stop hook trivially under any hook timeout (no flock contention with a
slow writer).

Output: one JSON object on stdout —
    {"active": bool, "done": bool, "reason": str, "iterations": int}

A missing or malformed ledger yields active:false (allow stop) and exit 0
(rel-001 — never break the harness).
"""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger, load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")


def _build_reason(predicate: dict, all_terminal: bool) -> str:
    blockers = int(predicate.get("blockers", 0) or 0)
    majors = int(predicate.get("majors", 0) or 0)
    parts = []
    if blockers:
        parts.append(f"{blockers} blocker{'s' if blockers != 1 else ''}")
    if majors:
        parts.append(f"{majors} major{'s' if majors != 1 else ''}")
    if not all_terminal:
        # The I-2 work-loop gate: counters may be zero while a stalled / pending
        # unit lurks. Name it so the operator knows the loop is not actually
        # clean even with no findings.
        parts.append("units not yet terminal")
    if not parts:
        return "loop exit condition not met"
    return "loop exit condition not met: " + " / ".join(parts) + " remain"


def status(repo_root: str, run_id: str) -> dict:
    """Compute the deterministic status dict for ONE run.

    Reads the ledger directly (lock-free). `done` is the I-1-fresh
    `exit_predicate_result.met` — never a separate cached value.
    """
    ledger = load_ledger()
    try:
        led = ledger.read_ledger(repo_root, run_id)
    except Exception:
        # Missing / unreadable ledger => not active => allow stop.
        return {"active": False, "done": False, "reason": "no active run", "iterations": 0}

    phase = phase_grammar.current_phase(led)
    predicate = led.get("exit_predicate_result") or {}
    # `done` IS the I-1-fresh predicate field — read directly, never re-derived.
    done = bool(predicate.get("met"))
    all_terminal = bool(predicate.get("all_steps_terminal"))
    active = phase != "done"

    if not active:
        reason = "loop is done"
    elif done:
        reason = "loop exit condition met"
    else:
        reason = _build_reason(predicate, all_terminal)

    return {
        "active": active,
        "done": done,
        "reason": reason,
        # The ledger carries no iteration counter; informational placeholder
        # only — never gates (the predicate is the sole authority).
        "iterations": 0,
    }


def _cli(argv) -> int:
    if len(argv) < 2:
        # Underspecified call: emit a safe "allow stop" status, exit 0.
        json.dump(
            {"active": False, "done": False, "reason": "no run specified", "iterations": 0},
            sys.stdout,
        )
        sys.stdout.write("\n")
        return 0
    repo, run = argv[0], argv[1]
    try:
        result = status(repo, run)
    except Exception:
        result = {"active": False, "done": False, "reason": "status error", "iterations": 0}
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
