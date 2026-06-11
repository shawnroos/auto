#!/usr/bin/env python3
"""auto v0.6.0 — the driving-session identity helper (KTD-5).

ONE source of truth for "what is the interactive driver's session_id?", shared
by every code path that records ``driving_session_id`` on a ledger:

  * lib/auto.py        — records it at arm time (init_ledger).
  * lib/auto-resume.py — RE-records it on the resume/re-arm path so a run
                         resumed from a DIFFERENT interactive session (after a
                         seam pause, a crash, or the next day from a fresh
                         Claude Code window) hands ownership to the NEW session
                         instead of keeping the stale arm-time id (fix-round-6
                         P1).

Why this matters (the load-bearing fact for BOTH advisor-gate hooks): the
PreToolUse hooks (lib/on-pretooluse-askuser.py + lib/on-pretooluse-action.py)
match a question/destructive-action to a live auto run by comparing the hook's
stdin ``session_id`` against the recorded ``driving_session_id`` — session-id
EQUALITY, not ledger-state alone. If a re-armed run keeps a STALE arm-time id,
the new driving session never matches and BOTH gates fall through to ALLOW —
including the destructive-action backstop, which would then let a live
self-driven run execute ``rm -rf`` / force-push unintercepted. Re-recording the
session at re-arm time closes that hole.

Read from ``CLAUDE_CODE_SESSION_ID``. Both the arm path and the resume path run
INSIDE the live interactive session (there is no spawn — the model fires
ScheduleWakeup / runs the slash command), so this env var IS the driving
session at both call sites. Belt-and-suspenders on the spawn-free path: if
``CLAUDE_CODE_CHILD_SESSION`` is truthy we are (somehow) in a spawned child, so
the env id is NOT the interactive driver — return None rather than record a
wrong id. An empty/unset id is also None.

CRITICAL for the resume path: a None return must NEVER be passed to
``ledger.set_driving_session_id`` — that setter treats None as "clear the
field", and a cleared field makes BOTH gates fail OPEN (no owner => allow). The
caller must refuse to re-arm (leave the run paused, surface a loud warning)
rather than re-arm a self-driven run with a dark backstop. See
lib/auto-resume.py::_cmd_continue.
"""

from __future__ import annotations

import os


def driving_session_id() -> str | None:
    """The interactive driver's session_id, or None if it cannot be trusted.

    Returns ``CLAUDE_CODE_SESSION_ID`` unless ``CLAUDE_CODE_CHILD_SESSION`` is
    truthy (a spawned child — not the interactive driver) or the id is
    empty/unset, in which cases it returns None. Callers MUST guard on None (see
    the module docstring): record only a real string; never clear or re-arm on
    None.
    """
    if os.environ.get("CLAUDE_CODE_CHILD_SESSION"):
        return None
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    return sid or None
