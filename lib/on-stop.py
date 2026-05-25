#!/usr/bin/env python3
"""auto U7: decision logic behind .claude/hooks/on-stop.sh.

The engine's OWN deliberate-stop guard (U9 spike: native `/goal` has no external
predicate seam — auto ships this). Reads every ledger under
<repo>/.claude/auto/ LOCK-FREE (atomic-rename => consistent snapshot) and
decides whether to BLOCK the stop.

BLOCK MECHANISM (U9 §4 + ralph-loop/hooks/stop-hook.sh:179-188):
    emit `{"decision":"block","reason":...}` on stdout, exit 0. NOT exit-2 — the
    codebase convention is decision-JSON + exit-0.

ACTIVE-RUN POLICY:
    BLOCK if ANY run has loop_phase != "done" AND exit_predicate_result.met ==
    false AND loop.driver == "self". `met` already encodes the all_units_terminal
    gate (schema §5 I-2), so a lurking stalled/pending unit (findings counters
    zero) keeps the stop blocked.

    The `driver == "self"` conjunct is the SEAM/MANUAL carve-out: the engine
    blocks premature stop only during ACTIVE work — a live tick chain (driver ==
    "self") that expects to keep going. When the engine writes `driver:
    "manual"` it is SIGNALING a valid stop-point awaiting human input (a
    seam pause emits action:"stop" + driver:"manual" deliberately; predicate-met
    and abort also set manual but are already filtered by phase == "done").
    Blocking a manual-driver run would self-conflict with the engine's own
    seam-stop signal. (Brief/plan stated the simpler "phase != done AND !met"
    rule, which conflicts with the seam; this carve-out resolves it — raised as a
    gap for the orchestrator.)

LOOP-SAFETY:
    Claude Code re-fires Stop after a block with stop_hook_active == true. We
    ALLOW the stop in that case (no decision JSON), surfacing a warning — the
    deterministic gate fires once per stop attempt, never an inescapable loop.

FRESHNESS: we read exit_predicate_result.met directly (the I-1-fresh field —
schema §5). No cached/derived `done` copy exists; a re-review reopening the
predicate (verdict-returned → pending) is reflected on that very write, so the
hook can never read a stale met:true and allow a premature stop.

STALE-CHAIN CARVE-OUT (Bug #9):
    The `driver == "self"` block above assumes a LIVE tick chain. But a tick can
    be killed AFTER it writes the beat and BEFORE it re-arms its successor. That
    leaves a ledger with driver=="self", met==false, and a fresh-ISH last_beat_at
    — a DEAD chain that, without a freshness check, would block EVERY session's
    stop in the repo until last_beat_at finally ages past GRACE (≈70 min, when
    is_orphaned surfaces it for resume). So we add a freshness gate: a
    driver=="self" run whose last_beat_at is older than DRIVER_SELF_STALE_SECONDS
    is treated as a DEAD chain → it does NOT block stop (it will be surfaced for
    resume by the SessionStart hook instead).

    THREE THRESHOLDS, reconciled (smallest → largest, no overlap of purpose):
      * DEFAULT_STALL_THRESHOLD_SECONDS = 600  — per-UNIT dispatch timeout (tick).
      * DRIVER_SELF_STALE_SECONDS       = 3900 — per-RUN dead-chain gate (THIS
            hook). Above the 3600s ScheduleWakeup max-tick-delay + slack, so a
            healthy slow-paced chain (last beat ≤3600s ago) is NEVER misread as
            dead and prematurely un-blocked (a false un-block could let a real
            loop stop early). Below GRACE so a dead chain stops blocking BEFORE
            is_orphaned would surface it — the two purposes (anti-false-double-
            drive vs anti-stale-block) do not fight: by the time we DECLINE to
            block (3900s), the resume path has not yet (4200s) claimed it, so
            there is a clean ~300s hand-off window and no double-claim.
      * GRACE_SECONDS                   = 4200 — orphan/resume window (I-3).
"""

from __future__ import annotations

import glob
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger, load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")


def _read_stop_hook_active(raw: str) -> bool:
    if not raw:
        return False
    try:
        data = json.loads(raw)
    except Exception:
        return False
    return bool(isinstance(data, dict) and data.get("stop_hook_active"))


def _blocking_runs(repo_root: str, now=None):
    """Return [(run_id, predicate_dict)] for every ACTIVE run that is NOT met.

    Lock-free: each ledger file is read as a whole via the atomic-rename
    invariant. A malformed/partial file is skipped silently (rel-001 — never let
    a bad ledger break the stop machinery).
    """
    ledger = load_ledger()
    # Bug #9: the dead-self-chain freshness gate. A driver=="self" run whose last
    # beat is older than this is treated as a dead chain (it does NOT block stop).
    # The hatch forces the OLD behaviour (no freshness check) so the deliberate-
    # fail test can prove a stale chain WOULD block without the gate.
    skip_staleness = (
        os.environ.get("CLAUDE_AUTO_TEST_NO_STALENESS_CHECK") == "1"
    )
    stale_threshold = ledger.DRIVER_SELF_STALE_SECONDS
    import datetime

    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)

    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    blocking = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict):
            continue
        if phase_grammar.current_phase(led) == "done":
            continue
        loop = led.get("loop") or {}
        # SEAM/MANUAL carve-out: a manual-driver run is the engine signaling a
        # valid stop-point awaiting human input (seam pause). Only a live tick
        # chain (driver == "self") expects to keep going, so only it gates stop.
        if loop.get("driver") == "manual":
            continue
        # Bug #9 STALE-CHAIN carve-out: a driver=="self" run whose last_beat_at is
        # older than DRIVER_SELF_STALE_SECONDS is a DEAD chain (tick killed after
        # the beat, before the re-arm). It must NOT block stop — it will be
        # surfaced for resume by the SessionStart hook. A healthy slow chain (last
        # beat within the threshold) STILL blocks. A missing/unparseable
        # last_beat_at on a self-driver run is treated as stale (no proof of
        # liveness → do not hold the stop hostage on a chain that never beat).
        if not skip_staleness and loop.get("driver") == "self":
            last_beat = ledger._parse_iso(loop.get("last_beat_at"))
            if last_beat is None:
                continue
            if (now - last_beat).total_seconds() > stale_threshold:
                continue
        predicate = led.get("exit_predicate_result") or {}
        # Read the I-1-fresh `met` directly (never re-derived).
        if not predicate.get("met"):
            run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
            blocking.append((run_id, predicate))
    return blocking


def _reason_for(blocking) -> str:
    chunks = []
    for run_id, predicate in blocking:
        blockers = int(predicate.get("blockers", 0) or 0)
        majors = int(predicate.get("majors", 0) or 0)
        all_terminal = bool(predicate.get("all_units_terminal"))
        parts = []
        if blockers:
            parts.append(f"{blockers} blocker{'s' if blockers != 1 else ''}")
        if majors:
            parts.append(f"{majors} major{'s' if majors != 1 else ''}")
        if not all_terminal:
            parts.append("units not yet terminal")
        detail = " / ".join(parts) if parts else "loop not complete"
        chunks.append(f"{run_id} ({detail})")
    # The block holds the session open; the reason message routes the driver's
    # next move. v0.2.0 (fix-pass G): make the harness re-invocation model
    # explicit so the driver does NOT read "continue the loop" as "act now."
    # The two viable paths from a blocked stop:
    #   1. Background `Agent` work is in flight → YIELD; the harness re-invokes
    #      on completion (the natural signal — do not ScheduleWakeup-poll).
    #   2. The loop is genuinely stalled outside its natural channel (rate-
    #      limited, waiting on external event) → ScheduleWakeup with a LONG
    #      delay calibrated to the wake event.
    # The driver knows which case it is in (it knows what it just dispatched);
    # the hook doesn't and shouldn't guess. Naming both cases explicitly lets
    # the driver route correctly.
    return (
        "auto: loop exit condition not met — "
        + "; ".join(chunks)
        + ". If you have background work in flight (Agent.run_in_background), "
        + "YIELD silently — the harness re-invokes you when a verdict lands. "
        + "Do NOT ScheduleWakeup-poll waiting for it. ScheduleWakeup is only "
        + "for genuine waits outside the agentic loop (rate-limit reset, "
        + "external deploy ETA) — long delays (1200s+), calibrated to the wake "
        + "event. `/auto-resume abort <run>` to stop early."
    )


def decide(repo_root: str, stdin_raw: str) -> dict | None:
    """Return the decision dict to print, or None to allow stop silently.

    Loop-safety: a re-fired Stop (stop_hook_active) always allows the stop.
    """
    if _read_stop_hook_active(stdin_raw):
        # Re-fired after a prior block — allow the stop to avoid an inescapable
        # loop. Surface a one-line note (no `decision` => stop proceeds).
        return {
            "systemMessage": (
                "auto: Stop re-fired (stop_hook_active) — allowing "
                "stop. Loop state is durable on disk; /auto-resume continues it."
            )
        }

    blocking = _blocking_runs(repo_root)
    if not blocking:
        return None  # nothing active+unmet => allow stop silently.

    return {
        "decision": "block",
        "reason": _reason_for(blocking),
        "systemMessage": (
            f"auto held the stop: {len(blocking)} run(s) have unmet loop exit "
            "conditions. If you have background work in flight, the harness "
            "will re-invoke you when a verdict lands — do not poll."
        ),
    }


def _cli(argv) -> int:
    repo_root = argv[0] if argv else os.getcwd()
    stdin_raw = ""
    if not sys.stdin.isatty():
        try:
            stdin_raw = sys.stdin.read()
        except Exception:
            stdin_raw = ""
    try:
        decision = decide(repo_root, stdin_raw)
    except Exception:
        decision = None  # any failure => allow stop (rel-001).
    if decision is not None:
        json.dump(decision, sys.stdout)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
