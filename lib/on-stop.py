#!/usr/bin/env python3
"""claude-dispatch U7: decision logic behind .claude/hooks/on-stop.sh.

The engine's OWN deliberate-stop guard (U9 spike: native `/goal` has no external
predicate seam — claude-dispatch ships this). Reads every ledger under
<repo>/.claude/dispatch/ LOCK-FREE (atomic-rename => consistent snapshot) and
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
"""

from __future__ import annotations

import glob
import importlib.util
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_ledger():
    path = os.path.join(_LIB_DIR, "ledger.py")
    spec = importlib.util.spec_from_file_location("ledger", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _read_stop_hook_active(raw: str) -> bool:
    if not raw:
        return False
    try:
        data = json.loads(raw)
    except Exception:
        return False
    return bool(isinstance(data, dict) and data.get("stop_hook_active"))


def _blocking_runs(repo_root: str):
    """Return [(run_id, predicate_dict)] for every ACTIVE run that is NOT met.

    Lock-free: each ledger file is read as a whole via the atomic-rename
    invariant. A malformed/partial file is skipped silently (rel-001 — never let
    a bad ledger break the stop machinery).
    """
    ledger = _load_ledger()
    dispatch_dir = os.path.join(repo_root, ".claude", "dispatch")
    blocking = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict):
            continue
        if led.get("loop_phase") == "done":
            continue
        # SEAM/MANUAL carve-out: a manual-driver run is the engine signaling a
        # valid stop-point awaiting human input (seam pause). Only a live tick
        # chain (driver == "self") expects to keep going, so only it gates stop.
        if (led.get("loop") or {}).get("driver") == "manual":
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
    return (
        "claude-dispatch: loop exit condition not met — "
        + "; ".join(chunks)
        + ". Continue the loop (or /dispatch-resume abort to stop early)."
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
                "claude-dispatch: Stop re-fired (stop_hook_active) — allowing "
                "stop. Loop state is durable on disk; /dispatch-resume continues it."
            )
        }

    blocking = _blocking_runs(repo_root)
    if not blocking:
        return None  # nothing active+unmet => allow stop silently.

    return {
        "decision": "block",
        "reason": _reason_for(blocking),
        "systemMessage": (
            "claude-dispatch held the stop: "
            f"{len(blocking)} run(s) have unmet loop exit conditions."
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
