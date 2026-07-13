#!/usr/bin/env python3
"""auto U7: /auto-resume subcommand logic behind resume.sh.

Parses the resume argument string into a subcommand and applies the ledger
transition via ledger.py (so the per-run RMW flock is inherited — no new flock).

Subcommands:
    [<run>]            default continue: re-record the driving session (so the
                       advisor gates own the re-armed run — fix-round-6 P1),
                       flip a paused handoff -> work, then emit a re-arm INTENT
                       (the model fires /auto:auto-pulse).
    continue <run>     explicit continue (same as default with a run-id).
    pause <run> [why]  blocked on a human/external action (auth, approval,
                       missing creds): flip driver -> "manual" so the Stop hook
                       stops blocking and the driver stops yielding, record the
                       reason, and stay resumable. Resume with `continue` once
                       the human acts. NOT a cancellation (use abort for that).
    advance <run>      declare the CURRENT phase already satisfied and move on
                       (v0.4.3 KTD-15). The "the plan is done — stop re-planning
                       it" tool: in the plan phase it marks the plan satisfied
                       (plan_step=review_plan, gaps_open=0) so the next pulse goes
                       straight to enumerate -> work; at a handoff it behaves like
                       continue; in the work phase it is a no-op (work advances by
                       unit verdicts, not by fiat).
    abort <run>        loop_phase -> "done" (cancellation marker).
    retry <run> <unit> stalled unit -> pending (clears last_error via ledger.py).
    skip <run> <unit>  stalled unit -> terminal-skip (terminal for I-2).

Ambiguity: if no run-id is given and >1 run is resumable, list them and ask the
operator to disambiguate (exit 0 — surfacing, not an error).

DOUBLE-DRIVE: state transitions route through ledger.py (RMW flock); the
arm-a-pulse path emits intent only — the pulse's own non-blocking process-held
_pulse_lock is the double-drive guard. No new flock here (would deadlock the
pulse). No file sentinel.

rel-001-ish: a clean usage/disambiguation message exits 0; only a genuine bad
transition exits non-zero (so the operator sees the error).
"""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    DRIVING_SESSION_KEY,
    build_arm_intent,
    build_pulse_prompt,
    iter_active_runs,
    iter_worktree_ledgers,
    load_ledger,
    load_lib_module,
    resolve_repo,
)

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")
# v0.2.0 fix-pass A.2: the manual handoff→work resume routes through pulse.py's
# centralized advance helper so it fires the recipe's producer the same way the
# auto-flip does. pulse.py uses a hyphenless name so plain import works.
import pulse  # noqa: E402 — after _LIB_DIR is on sys.path via _bootstrap.

# fix-round-6 P1: the resume re-arm path RE-records driving_session_id (the
# advisor-gate ownership key) so a run resumed from a DIFFERENT interactive
# session hands ownership to the new session instead of keeping the stale
# arm-time id. ONE source of truth, shared with auto.py's arm-time recorder.
driver_session = load_lib_module("driver_session")


# Repo root resolution is shared with auto.py and auto-status.py; lives in
# _bootstrap.resolve_repo (P2-8 — was three identical copies).
_resolve_repo = resolve_repo


def _resumable_runs(ledger, repo_root: str):
    """Run-ids that are resumable (handoff-paused OR blocked-paused OR is_orphaned)."""
    runs = []
    for run_id, led in iter_worktree_ledgers(repo_root):
        if phase_grammar.current_phase(led) == "done":
            continue
        handoff_paused = phase_grammar.current_phase(led) == "handoff" and led.get("handoff_paused")
        # Blocked-paused: a manual-driver run that is NOT at a handoff and NOT done
        # (set by `pause`). Without this, a run paused on a human blocker would
        # be invisible to bare `/auto-resume` and need an explicit run-id.
        loop = led.get("loop") or {}
        blocked_paused = loop.get("driver") == "manual" and not handoff_paused
        try:
            orphaned = ledger.is_orphaned(led)
        except Exception:
            orphaned = False
        if handoff_paused or blocked_paused or orphaned:
            runs.append(run_id)
    return runs


def _emit_rearm(run_id: str, note: str) -> int:
    """Emit the re-arm INTENT — the model fires the actual /auto:auto-pulse."""
    json.dump(
        build_arm_intent(run_id, build_pulse_prompt(run_id), note),
        sys.stdout,
    )
    sys.stdout.write("\n")
    return 0


def _rearm_owns_session(ledger, repo_root: str, run_id: str, led: dict) -> int:
    """Re-record THIS interactive session as the run's driving session, or refuse.

    fix-round-6 P1. A re-armed run becomes self-driven again, so the advisor-gate
    PreToolUse hooks must be able to own it — they match on
    ``driving_session_id == stdin.session_id``. Resume is the common cross-session
    case (after a handoff pause, a crash, or the next day from a fresh window), so
    the stale arm-time id would never match the NEW driving session and BOTH gates
    (question redirect AND the destructive-action backstop) would fall through to
    ALLOW: a live self-driven run executing ``rm -rf`` / force-push with the
    deterministic backstop dark. Re-recording closes that hole.

    Returns 0 on success. Refuses (returns 1, leaves the run paused, prints a loud
    warning) in two cases:

    1. CLAUDE_CODE_SESSION_ID is unset/empty (a truly headless context; v0.6.4
       dropped the CHILD_SESSION guard, so a child env no longer refuses). We must
       NOT pass None to ``set_driving_session_id`` (None CLEARS the field, failing
       BOTH gates OPEN), and must NOT re-arm a self-driven run whose backstop is dark.

    2. OWNERSHIP-STEAL guard (review #5): the run is currently LIVE and self-driven
       by a DIFFERENT session (driver=="self", not handoff-paused, beat fresh enough
       that ``is_orphaned`` is False). Re-recording would silently hand the backstop
       to THIS session while the ORIGINAL driver keeps running — going its backstop
       dark mid-run. Legitimate cross-session handoff (a paused / orphaned / stale
       run) is NOT live and passes; a same-session re-record is idempotent and passes;
       a run with no recorded owner passes (nothing to steal).
    """
    sid = driver_session.driving_session_id()
    if not sid:
        sys.stderr.write(
            f"resume: refusing to re-arm run {run_id!r} — CLAUDE_CODE_SESSION_ID "
            "is unset (a truly headless/env-less context). Re-arming now would "
            "leave the advisor-gate destructive backstop dark (no owning session "
            "=> gates fail open). The run stays paused. Re-run `/auto-resume "
            "continue` from an interactive Claude Code session (where the id is "
            "present).\n"
        )
        return 1
    existing = led.get(DRIVING_SESSION_KEY)
    loop = led.get("loop") or {}
    run_is_live = (
        loop.get("driver") == "self"
        and not led.get("handoff_paused")
        and not ledger.is_orphaned(led)
    )
    if existing and existing != sid and run_is_live:
        sys.stderr.write(
            f"resume: refusing to re-arm run {run_id!r} — it is LIVE and owned by "
            "another session (driver=self, recent heartbeat). Re-arming from this "
            "session would steal ownership and leave the ORIGINAL driver's "
            "destructive-action backstop dark mid-run. If the other session is "
            "actually dead, wait for the orphan grace window (then it becomes "
            "resumable), or `/auto-resume abort` it.\n"
        )
        return 1
    try:
        ledger.set_driving_session_id(repo_root, run_id, sid)
    except ledger.LedgerError as exc:
        # A torn/locked ledger on the write: surface a structured message and
        # leave the run paused (safe) rather than a raw traceback (REL-001).
        sys.stderr.write(
            f"resume: could not record the driving session for run {run_id!r} "
            f"({exc}); the run stays paused. Retry `/auto-resume continue`.\n"
        )
        return 1
    return 0


def _cmd_continue(ledger, repo_root: str, run_id: str) -> int:
    """Flip a paused handoff -> work (if applicable), then arm a pulse."""
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
    rc = _rearm_owns_session(ledger, repo_root, run_id, led)
    if rc != 0:
        return rc
    if phase == "handoff":
        # handoff -> work: route through pulse.advance_to_phase so the recipe's
        # producer fires the same way it does on the auto-flip path (P0 #1
        # fix-pass A.2 — without this the manual resume would silently skip
        # emission and the work-loop would start with empty units). Legacy
        # ledgers (no recipe) fall through to set_loop inside the helper,
        # preserving v0.1.x behavior. handoff_paused=False is written by both
        # paths inside the helper.
        pulse.advance_to_phase(repo_root, run_id, led, to_phase="work")
        return _emit_rearm(run_id, "handoff -> work; arm a fresh pulse chain")
    # Orphaned, or resuming a blocked-pause: re-arm cleanly off the durable
    # ledger. driver -> "self" reactivates the Stop hook; clear blocked_on (the
    # human acted, so the pause reason no longer applies). Clear backstop_latched
    # too (P3-b): a clean resume "forgives" any backstop pause, so a LATER
    # operator pause on this run again allows the operator's own cleanup. If the
    # agent immediately re-issues the same destructive command, the backstop just
    # re-fires (driver=self -> gated) and re-latches — safe.
    ledger.set_loop(
        repo_root, run_id, driver="self", blocked_on=None, backstop_latched=False
    )
    return _emit_rearm(run_id, "resume run; arm a fresh pulse chain")


def _cmd_pause(ledger, repo_root: str, run_id: str, reason: str) -> int:
    """Pause a run blocked on a human/external action.

    Flips driver -> "manual" (the Stop hook's HANDOFF/MANUAL carve-out then
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
    # Shared pause core (U9). Operator path uses the default backstop_latched=
    # False: the operator now owns the session and runs their own cleanup, so
    # the fail-closed gate must not re-fire on it (the backstop path latches).
    ledger.apply_pause(repo_root, run_id, reason or None)
    why = f" — {reason}" if reason else ""
    sys.stdout.write(
        f"resume: run {run_id!r} paused (driver=manual){why}.\n"
        f"Resume with `/auto-resume continue {run_id}` once unblocked.\n"
        "NOTE: if you set a native `/goal` for this session, run `/goal clear` "
        "too — auto neither arms nor can clear it.\n"
    )
    return 0


def _cmd_advance(ledger, repo_root: str, run_id: str) -> int:
    """Declare the current phase satisfied and route to the next phase.

    v0.4.3 KTD-15 — the general "the plan is done, move on" tool. auto's gap was
    that it had no concept of phase-satisfaction: armed at the plan phase it would
    re-run /ce-plan even when a reviewed plan already existed, because nothing let
    the driving agent SAY "this phase is satisfied" (project_auto_v042_stuck_root_causes
    ③). This verb is that affordance, phase-aware:

      * plan  — mark the plan satisfied: plan_step="review_plan" + gaps_open=0,
        the exact pre-satisfied state W inits with. The next pulse's next_plan_step
        returns "done" → enumerate_plan_units → plan→work, no re-derivation. We
        arm a pulse so the model enumerates the (already-in-context) plan's units.
      * handoff  — identical to `continue` (handoff→work); delegate so there's one
        code path for the handoff advance.
      * work  — no-op: the work-loop advances by unit verdicts, not by fiat;
        forcing it would skip unfinished units. Point the operator at the real
        levers (let units land, or `abort`).
      * done  — already terminal.
    """
    try:
        led = ledger.read_ledger(repo_root, run_id)
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"resume: {exc}\n")
        return 1
    phase = phase_grammar.current_phase(led)
    if phase == "done":
        sys.stdout.write(f"resume: run {run_id!r} is already done; nothing to advance.\n")
        return 0
    if phase == "handoff":
        # The handoff advance IS continue (handoff→work). One code path.
        return _cmd_continue(ledger, repo_root, run_id)
    if phase == "work":
        sys.stdout.write(
            f"resume: run {run_id!r} is in the work phase — nothing to force-"
            "advance. The work-loop exits when its units reach terminal verdicts "
            "(only P3 remaining). Let the units land, or `/auto-resume abort "
            f"{run_id}` to stop.\n"
        )
        return 0
    # phase == "plan": advance re-arms a now-self-driven run, so re-record the
    # driving session FIRST (same guard as continue) — else the advisor-gate
    # destructive backstop would be dark on the re-armed run. Refuse (leave the
    # run untouched) if the session can't be determined (fix-round-6 P1 parity).
    rc = _rearm_owns_session(ledger, repo_root, run_id, led)
    if rc != 0:
        return rc
    # Mark the plan satisfied. Two atomic writes (set_loop has no gaps_open kwarg);
    # plan-met = gaps_open==0 AND plan_step=="review_plan", and gaps_open must be
    # NON-NULL, so set BOTH or plan-met won't fire.
    ledger.set_loop(repo_root, run_id, plan_step="review_plan", driver="self")
    ledger.set_gaps_open(repo_root, run_id, 0)
    return _emit_rearm(
        run_id,
        "plan declared satisfied (advance); arm a pulse to enumerate work units",
    )


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

    SUBCOMMANDS = ("continue", "pause", "advance", "abort", "retry", "skip")
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
            candidates=[run_id for run_id, _ in iter_active_runs(repo_root)], label="active",
        )
        if run_id is None:
            return 0
        # Everything after <run> is the free-text reason.
        reason = " ".join(rest[1:]) if len(rest) >= 2 else ""
        return _cmd_pause(ledger, repo_root, run_id, reason)

    if sub == "advance":
        # advance targets a LIVE run (like pause), not a resumable one — you
        # advance a run that is mid-phase, not one parked at a handoff.
        run_id = _resolve_run_or_disambiguate(
            ledger, repo_root, run_arg,
            candidates=[run_id for run_id, _ in iter_active_runs(repo_root)], label="active",
        )
        if run_id is None:
            return 0
        return _cmd_advance(ledger, repo_root, run_id)

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
