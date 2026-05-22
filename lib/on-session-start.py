#!/usr/bin/env python3
"""auto U7: resurrection / seam surfacing behind on-session-start.sh.

Scans every ledger under <repo>/.claude/auto/ and prints a one-line resume
hint for each resumable run. SURFACES ONLY — never auto-runs (auto-resume is U8).

Classification (schema §5 I-3), in order:
  * loop_phase == "done"                          -> skip (no line).
  * loop_phase == "seam" AND seam_paused == true  -> seam-specific hint
    (checked BEFORE the time-based orphan branch — seam is the INTENTIONAL
    orphan).
  * else is_orphaned(ledger) (driver == "manual" OR last_beat_at older than
    GRACE_SECONDS)                                -> generic resume hint.

GRACE_SECONDS and the is_orphaned predicate are IMPORTED from ledger.py, never
hardcoded (schema §6 — consumers read the module constants to avoid drift).

rel-001: any failure (missing dir, malformed ledger) prints nothing and exits 0.
A single bad ledger never aborts the scan of its siblings.
"""

from __future__ import annotations

import glob
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger  # noqa: E402 — after _LIB_DIR is on sys.path.


def surfacing_lines(repo_root: str):
    """Return the list of resume-hint lines for the repo's ledgers."""
    ledger = load_ledger()
    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    lines = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue  # malformed ledger -> skip, keep scanning siblings.
        if not isinstance(led, dict):
            continue

        phase = led.get("loop_phase")
        if phase == "done":
            continue

        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]

        # Seam pause is the INTENTIONAL orphan — check it BEFORE the time-based
        # orphan branch (schema §5 I-3).
        if phase == "seam" and led.get("seam_paused"):
            lines.append(
                f"loop {run_id} paused at seam (plan complete; awaiting "
                f"work-loop confirmation) — /auto-resume continue {run_id} | "
                f"abort {run_id}"
            )
            continue

        # Time/driver-based orphan (the tick chain died with a prior session).
        try:
            orphaned = ledger.is_orphaned(led)
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
