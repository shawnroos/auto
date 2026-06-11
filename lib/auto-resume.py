#!/usr/bin/env python3
"""auto U7: /auto-resume subcommand logic behind resume.sh.

Parses the resume argument string into a subcommand and applies the ledger
transition via ledger.py (so the per-run RMW flock is inherited — no new flock).

Subcommands:
    [<run>]            default continue: re-record the driving session (so the
                       advisor gates own the re-armed run — fix-round-6 P1),
                       flip a paused seam -> work, then emit a re-arm INTENT
                       (the model fires /auto-tick).
    continue <run>     explicit continue (same as default with a run-id).
    pause <run> [why]  blocked on a human/external action (auth, approval,
                       missing creds): flip driver -> "manual" so the Stop hook
                       stops blocking and the driver stops yielding, record the
                       reason, and stay resumable. Resume with `continue` once
                       the human acts. NOT a cancellation (use abort for that).
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
from _bootstrap import load_ledger, load_lib_module, resolve_repo  # noqa: E402 — after _LIB_DIR is on sys.path.

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")
# v0.2.0 fix-pass A.2: the manual seam→work resume routes through tick.py's
# centralized advance helper so it fires the recipe's emitter the same way the
# auto-flip does. tick.py uses a hyphenless name so plain import works.
import tick  # noqa: E402 — after _LIB_DIR is on sys.path via _bootstrap.

# fix-round-6 P1: the resume re-arm path RE-records driving_session_id (the
# advisor-gate ownership key) so a run resumed from a DIFFERENT interactive
# session hands ownership to the new session instead of keeping the stale
# arm-time id. ONE source of truth, shared with auto.py's arm-time recorder.
driver_session = load_lib_module("driver_session")


# Repo root resolution is shared with auto.py and auto-status.py; lives in
# _bootstrap.resolve_repo (P2-8 — was three identical copies).
_resolve_repo = resolve_repo


def _resumable_runs(ledger, repo_root: str):
    """Run-ids that are resumable (seam-paused OR blocked-paused OR is_orphaned)."""
    import glob

    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    runs = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict) or phase_grammar.current_phase(led) == "done":
            continue
        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
        seam_paused = phase_grammar.current_phase(led) == "seam" and led.get("seam_paused")
        # Blocked-paused: a manual-driver run that is NOT at a seam and NOT done
        # (set by `pause`). Without this, a run paused on a human blocker would
        # be invisible to bare `/auto-resume` and need an explicit run-id.
        loop = led.get("loop") or {}
        blocked_paused = loop.get("driver") == "manual" and not seam_paused
        try:
            orphaned = ledger.is_orphaned(led)
        except Exception:
            orphaned = False
        if seam_paused or blocked_paused or orphaned:
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


def _rearm_owns_session(ledger, repo_root: str, run_id: str) -> int:
    """Re-record THIS interactive session as the run's driving session, or refuse.

    fix-round-6 P1. A re-armed run becomes self-driven again, so the advisor-gate
    PreToolUse hooks must be able to own it — they match on
    ``driving_session_id == stdin.session_id``. Resume is the common cross-session
    case (after a seam pause, a crash, or the next day from a fresh window), so
    the stale arm-time id would never match the NEW driving session and BOTH gates
    (question redirect AND the destructive-action backstop) would fall through to
    ALLOW: a live self-driven run executing ``rm -rf`` / force-push with the
    deterministic backstop dark. Re-recording closes that hole.

    Returns 0 on success. Refuses (returns 1, leaves the run paused, prints a loud
    warning) when the driving session cannot be determined — a child/unset env. We
    must NOT pass None to ``set_driving_session_id`` (None CLEARS the field, which
    fails BOTH gates OPEN), and we must NOT re-arm a self-driven run whose backstop
    is dark. Resume runs INSIDE the live interactive session, so this is normally
    a real id; None here means an unsupported environment, not a routine case.
    """
    sid = driver_session.driving_session_id()
    if not sid:
        sys.stderr.write(
            f"resume: refusing to re-arm run {run_id!r} — cannot determine the "
            "driving session id (CLAUDE_CODE_SESSION_ID unset, or a spawned "
            "child). Re-arming now would leave the advisor-gate destructive "
            "backstop dark (no owning session => gates fail open). The run stays "
            "paused. Re-run `/auto-resume continue` from the interactive driver "
            "session.\n"
        )
        return 1
    ledger.set_driving_session_id(repo_root, run_id, sid)
    return 0


def _cmd_continue(ledger, repo_root: str, run_id: str) -> int:
    """Flip a paused seam -> work (if applicable), then arm a tick."""
    try:
        led = ledger.read_ledger(repo_root, run_id)
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    phase = phase_grammar.current_phase(led)
    if phase == "done":
        sys.stdout.write(f"resume: run {run_id!r} is already done; nothing to resume.\n")
        return 0
    # Re-record the driving session BEFORE either re-arm branch (both make the
    # run self-driven). On refusal, leave the run paused and DO NOT re-arm — a
    # dark backstop is worse than a not-resumed run (fix-round-6 P1).
    rc = _rearm_owns_session(ledger, repo_root, run_id)
    if rc != 0:
        return rc
    if phase == "seam":
        # seam -> work: route through tick.advance_to_phase so the recipe's
        # emitter fires the same way it does on the auto-flip path (P0 #1
        # fix-pass A.2 — without this the manual resume would silently skip
        # emission and the work-loop would start with empty units). Legacy
        # ledgers (no recipe) fall through to set_loop inside the helper,
        # preserving v0.1.x behavior. seam_paused=False is written by both
        # paths inside the helper.
        tick.advance_to_phase(repo_root, run_id, led, to_phase="work")
        return _emit_rearm(run_id, "seam -> work; arm a fresh tick chain")
    # Orphaned, or resuming a blocked-pause: re-arm cleanly off the durable
    # ledger. driver -> "self" reactivates the Stop hook; clear blocked_on (the
    # human acted, so the pause reason no longer applies).
    ledger.set_loop(repo_root, run_id, driver="self", blocked_on=None)
    return _emit_rearm(run_id, "resume run; arm a fresh tick chain")


def _cmd_pause(ledger, repo_root: str, run_id: str, reason: str) -> int:
    """Pause a run blocked on a human/external action.

    Flips driver -> "manual" (the Stop hook's SEAM/MANUAL carve-out then
    declines to block this run — on-stop.py) and records the reason, WITHOUT
    marking the loop done. The run stays resumable: once the human does the
    blocked-on thing, `/auto-resume continue <run>` reactivates it.

    This is the clean exit when the driver hits a wall it cannot cross in-loop
    (auth login, external approval, missing creds). The alternative — silently
    yielding turn after turn — produces no progress and lets any other open gate
    (e.g. an operator-set native `/goal`) re-invite the model into a spam loop.
    """
    try:
        led = ledger.read_ledger(repo_root, run_id)
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    if phase_grammar.current_phase(led) == "done":
        sys.stdout.write(f"resume: run {run_id!r} is already done; nothing to pause.\n")
        return 0
    reason = (reason or "").strip()
    ledger.set_loop(
        repo_root, run_id, driver="manual", blocked_on=(reason or None)
    )
    why = f" — {reason}" if reason else ""
    sys.stdout.write(
        f"resume: run {run_id!r} paused (driver=manual){why}.\n"
        f"Resume with `/auto-resume continue {run_id}` once unblocked.\n"
        "NOTE: if you set a native `/goal` for this session, run `/goal clear` "
        "too — auto neither arms nor can clear it.\n"
    )
    return 0


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


def _active_runs(ledger, repo_root: str):
    """Run-ids that are NOT done (candidates for `pause`).

    `pause` targets a LIVE run, not a resumable one, so it disambiguates over a
    different set than continue/abort (which use `_resumable_runs`).
    """
    import glob

    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    runs = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict) or phase_grammar.current_phase(led) == "done":
            continue
        runs.append(led.get("run_id") or os.path.splitext(os.path.basename(path))[0])
    return runs


def _resolve_run_or_disambiguate(ledger, repo_root: str, run_id, *, candidates=None, label="resumable"):
    """Return a run-id, or print a disambiguation prompt and return None.

    `candidates` is the run-list to draw from when no run-id is given; defaults
    to the resumable set. `pause` passes the active set instead.
    """
    if run_id:
        return run_id
    runs = _resumable_runs(ledger, repo_root) if candidates is None else candidates
    if len(runs) == 1:
        return runs[0]
    if not runs:
        sys.stdout.write(f"resume: no {label} run found.\n")
        return None
    sys.stdout.write(
        f"resume: multiple {label} runs — specify one:\n"
        + "".join(f"  /auto-resume {r}\n" for r in runs)
    )
    return None


def run(argv) -> int:
    ledger = load_ledger()
    repo_root = _resolve_repo()

    SUBCOMMANDS = ("continue", "pause", "abort", "retry", "skip")
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

    if sub == "pause":
        run_id = _resolve_run_or_disambiguate(
            ledger, repo_root, run_arg,
            candidates=_active_runs(ledger, repo_root), label="active",
        )
        if run_id is None:
            return 0
        # Everything after <run> is the free-text reason.
        reason = " ".join(rest[1:]) if len(rest) >= 2 else ""
        return _cmd_pause(ledger, repo_root, run_id, reason)

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
