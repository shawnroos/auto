#!/usr/bin/env python3
"""auto U7: resurrection / handoff surfacing behind on-session-start.sh.

Scans every run-record under <repo>/.claude/auto/ and prints a one-line resume
hint for each resumable run. SURFACES ONLY — never auto-runs (auto-resume is U8).

Classification (schema §5 I-3), in order:
  * loop_phase == "done"                          -> skip (no line).
  * loop_phase == "handoff" AND handoff_paused == true  -> handoff-specific hint
    (checked BEFORE the time-based orphan branch — handoff is the INTENTIONAL
    orphan).
  * else is_orphaned(run-record) (driver == "manual" OR last_beat_at older than
    GRACE_SECONDS)                                -> generic resume hint.

GRACE_SECONDS and the is_orphaned predicate are IMPORTED from run_record.py, never
hardcoded (schema §6 — consumers read the module constants to avoid drift).

rel-001: any failure (missing dir, malformed run-record) prints nothing and exits 0.
A single bad run-record never aborts the scan of its siblings.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    iter_worktree_run_records,
    load_run_record,
    load_lib_module,
)

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")


def surfacing_lines(repo_root: str):
    """Return the list of resume-hint lines for the repo's run_records."""
    run_record = load_run_record()
    lines = []
    for run_id, led in iter_worktree_run_records(repo_root):
        phase = phase_grammar.current_phase(led)
        if phase == "done":
            continue

        # Handoff pause is the INTENTIONAL orphan — check it BEFORE the time-based
        # orphan branch (schema §5 I-3).
        if phase == "handoff" and led.get("handoff_paused"):
            lines.append(
                f"loop {run_id} paused at handoff (plan complete; awaiting "
                f"work-loop confirmation) — /auto-resume continue {run_id} | "
                f"abort {run_id}"
            )
            continue

        # Time/driver-based orphan (the pulse chain died with a prior session).
        try:
            orphaned = run_record.is_orphaned(led)
        except Exception:
            orphaned = False
        if orphaned:
            lines.append(
                f"loop {run_id} can be resumed: /auto-resume {run_id}"
            )
    return lines


def _cli(argv) -> int:
    repo_root = argv[0] if argv else os.getcwd()
    try:
        lines = surfacing_lines(repo_root)
    except Exception:
        lines = []  # rel-001: never break session start.
    for line in lines:
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
