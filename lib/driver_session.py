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

Read from ``CLAUDE_CODE_SESSION_ID`` — the session identity, guaranteed by the
harness to equal the ``session_id`` the PreToolUse hooks receive on stdin. An
empty/unset id returns None. (v0.6.4 removed a bogus ``CLAUDE_CODE_CHILD_SESSION``
guard — the canonical explanation lives on ``driving_session_id`` below; don't
re-tell it here.)

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
    """The interactive driver's session_id (``CLAUDE_CODE_SESSION_ID``), or None
    if it is unset/empty.

    v0.6.4 — the CLAUDE_CODE_CHILD_SESSION guard was REMOVED (it was a bug). The
    prior version returned None whenever ``CLAUDE_CODE_CHILD_SESSION`` was truthy,
    on the assumption that meant "a spawned sub-agent, not the interactive driver."
    That misread the harness: Claude Code sets ``CLAUDE_CODE_CHILD_SESSION=1`` in
    EVERY subprocess it spawns via the Bash tool (it marks Claude-spawned
    subprocesses — e.g. so a nested ``claude`` TUI is excluded from --resume).
    auto's CLIs (auto.sh / auto-resume.sh) ALWAYS run inside the Bash tool, so the
    var was ALWAYS set at arm AND resume time → the guard fired unconditionally and
    this returned None on every call. Consequences: the advisor-gate destructive
    backstop was dark on EVERY run (arm recorded a null driving_session_id, which
    the PreToolUse hooks can never match), and ``/auto-resume continue`` / ``advance``
    refused to re-arm (None → refuse). Neither worked in production since v0.6.0.

    The harness contract (env-vars docs): ``CLAUDE_CODE_SESSION_ID`` identifies the
    session and EQUALS the ``session_id`` the PreToolUse hooks receive on stdin;
    ``CLAUDE_CODE_CHILD_SESSION`` is NOT a driver-vs-sub-agent signal. So we trust
    the session id directly. A non-driver sub-agent (Agent tool) that arms its OWN
    run records its OWN session_id, which its OWN hook calls match — correct, no leak.

    Callers MUST still guard on None (record only a real string; never clear or
    re-arm on None). None now means the id is genuinely absent — a truly headless /
    env-less context — which is exactly what the arm warning + resume refusal cover.
    """
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    return sid or None
