#!/usr/bin/env python3
"""auto U7: /auto-resume subcommand logic behind resume.sh.

Parses the resume argument string into a subcommand and applies the ledger
transition via ledger.py (so the per-run RMW flock is inherited — no new flock).

Subcommands:
    [<run>]            default continue: flip a paused seam -> work, then emit a
                       re-arm INTENT (the model fires /auto-tick).
    continue <run>     explicit continue (same as default with a run-id).
    abort <run>        loop_phase -> "done" (cancellation marker).
    retry <run> <unit> stalled unit -> pending (clears last_error via ledger.py).
    skip <run> <unit>  stalled unit -> terminal-skip (terminal for I-2).

Ambiguity: if no run-id is given and >1 run is resumable, list them and ask the
operator to disambiguate (exit 0 — surfacing, not an error).

DOUBLE-DRIVE: state transitions route through ledger.py (RMW flock); the
arm-a-tick path emits intent only — the tick's own non-blocking process-held
_tick_lock is the double-drive guard. No new flock here (would deadlock the
tick). No file sentinel.

rel-001-ish: a clean usage/disambiguation message exits 0; only a genuine bad
transition exits non-zero (so the operator sees the error).
"""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger  # noqa: E402 — after _LIB_DIR is on sys.path.


def _resolve_repo() -> str:
    """Repo root: $CLAUDE_AUTO_REPO, else walk up from cwd for .claude/auto."""
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    dir_ = os.getcwd()
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "auto")):
            return dir_
        dir_ = os.path.dirname(dir_)
    return os.getcwd()


def _resumable_runs(ledger, repo_root: str):
    """Run-ids that are resumable (seam-paused OR is_orphaned)."""
    import glob

    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    runs = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict) or led.get("loop_phase") == "done":
            continue
        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
        seam_paused = led.get("loop_phase") == "seam" and led.get("seam_paused")
        try:
            orphaned = ledger.is_orphaned(led)
        except Exception:
            orphaned = False
        if seam_paused or orphaned:
            runs.append(run_id)
    return runs


def _emit_rearm(run_id: str, note: str) -> int:
    """Emit the re-arm INTENT — the model fires the actual /auto-tick."""
    json.dump(
        {
            "action": "arm-tick",
            "run": run_id,
            "prompt": f"/auto-tick {run_id}",
            "note": note,
        },
        sys.stdout,
    )
    sys.stdout.write("\n")
    return 0


def _cmd_continue(ledger, repo_root: str, run_id: str) -> int:
    """Flip a paused seam -> work (if applicable), then arm a tick."""
    try:
        led = ledger.read_ledger(repo_root, run_id)
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    phase = led.get("loop_phase")
    if phase == "done":
        sys.stdout.write(f"resume: run {run_id!r} is already done; nothing to resume.\n")
        return 0
    if phase == "seam":
        # seam -> work: clear seam_paused, hand the driver back to self.
        ledger.set_loop(
            repo_root, run_id, loop_phase="work", seam_paused=False, driver="self"
        )
        return _emit_rearm(run_id, "seam -> work; arm a fresh tick chain")
    # Orphaned (or otherwise active): re-arm cleanly off the durable ledger.
    ledger.set_loop(repo_root, run_id, driver="self")
    return _emit_rearm(run_id, "resume orphaned run; arm a fresh tick chain")


def _cmd_abort(ledger, repo_root: str, run_id: str) -> int:
    try:
        ledger.set_loop(repo_root, run_id, loop_phase="done", driver="manual")
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    sys.stdout.write(f"resume: run {run_id!r} aborted (loop_phase=done).\n")
    return 0


def _cmd_retry(ledger, repo_root: str, run_id: str, unit_id: str) -> int:
    # stalled -> pending; ledger.transition clears last_error on this edge.
    try:
        ledger.transition(repo_root, run_id, unit_id, "pending")
    except (ledger.LedgerError,) as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    sys.stdout.write(
        f"resume: unit {unit_id!r} of run {run_id!r} retried "
        f"(stalled -> pending; last_error cleared).\n"
    )
    return 0


def _cmd_skip(ledger, repo_root: str, run_id: str, unit_id: str) -> int:
    try:
        ledger.transition(repo_root, run_id, unit_id, "terminal-skip")
    except (ledger.LedgerError,) as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    sys.stdout.write(
        f"resume: unit {unit_id!r} of run {run_id!r} skipped (-> terminal-skip).\n"
    )
    return 0


def _resolve_run_or_disambiguate(ledger, repo_root: str, run_id):
    """Return a run-id, or print a disambiguation prompt and return None."""
    if run_id:
        return run_id
    runs = _resumable_runs(ledger, repo_root)
    if len(runs) == 1:
        return runs[0]
    if not runs:
        sys.stdout.write("resume: no resumable run found.\n")
        return None
    sys.stdout.write(
        "resume: multiple resumable runs — specify one:\n"
        + "".join(f"  /auto-resume {r}\n" for r in runs)
    )
    return None


def run(argv) -> int:
    ledger = load_ledger()
    repo_root = _resolve_repo()

    SUBCOMMANDS = ("continue", "abort", "retry", "skip")
    sub = None
    rest = list(argv)
    if rest and rest[0] in SUBCOMMANDS:
        sub = rest.pop(0)

    run_arg = rest[0] if len(rest) >= 1 else None
    unit_arg = rest[1] if len(rest) >= 2 else None

    if sub in (None, "continue"):
        run_id = _resolve_run_or_disambiguate(ledger, repo_root, run_arg)
        if run_id is None:
            return 0
        return _cmd_continue(ledger, repo_root, run_id)

    if sub == "abort":
        run_id = _resolve_run_or_disambiguate(ledger, repo_root, run_arg)
        if run_id is None:
            return 0
        return _cmd_abort(ledger, repo_root, run_id)

    if sub in ("retry", "skip"):
        if not run_arg or not unit_arg:
            sys.stderr.write(f"resume: {sub} requires <run> <unit>\n")
            return 2
        if sub == "retry":
            return _cmd_retry(ledger, repo_root, run_arg, unit_arg)
        return _cmd_skip(ledger, repo_root, run_arg, unit_arg)

    sys.stderr.write(f"resume: unknown subcommand {sub!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
