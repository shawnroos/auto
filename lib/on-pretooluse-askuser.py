#!/usr/bin/env python3
"""auto U4: decision logic behind .claude/hooks/on-pretooluse-askuser.sh.

The advisor-routing gate (KTD-4/5). On an AskUserQuestion tool call, DENY and
redirect the driving agent to the advisor ONLY when a LIVE self-driven /auto run
owns this very session — otherwise emit nothing (allow).

OWNERSHIP PREDICATE (KTD-5 — the load-bearing fact for the whole gate):
    a question belongs to a live auto run iff, for SOME ledger under
    <repo>/.claude/auto/*.json:
      * current phase != "done"                         (run not finished)
      * loop.driver == "self"                           (a live tick chain, not
                                                          a seam/manual pause)
      * loop.last_beat_at fresher than
        ledger.DRIVER_SELF_STALE_SECONDS (3900s)        (not a dead chain)
      * ledger.driving_session_id == stdin session_id   (THIS session drives it)

    The session_id equality (not mere presence) is what cleanly rejects a
    concurrent STANDALONE /ce-plan in the same worktree: it has a different
    session_id, so no ledger matches and the gate allows. `driving_session_id`
    is recorded at arm time by U5; we read it DEFENSIVELY — absent => no match
    => allow (the gate never fires on the pre-U5 tree).

    This is NOT on-stop.py's `_is_blocking`: that ALSO requires met==False
    (exit-state), which is irrelevant to ownership. We keep a dedicated
    predicate so the gate is not coupled to whether the run is done-eligible.

LOCK-FREE READ: the atomic-rename invariant gives a consistent snapshot; we
copy on-stop.py's `_load_ledger_safe` model (plain open + json.load, no flock).

FAIL-OPEN (KTD-4 asymmetry): the question gate degrades to allow on ANY
uncertainty — a malformed ledger, an absent driving_session_id, an internal
error. Worst case the operator is asked directly (no harm). When the PreToolUse
deny contract itself is unavailable (test hatch CLAUDE_AUTO_TEST_DENY_UNSUPPORTED,
fenced via test_hatch_enabled), it still allows the question through but surfaces
a loud systemMessage — never a pause. The DESTRUCTIVE backstop
(on-pretooluse-action.py) is the one that fails CLOSED.

rel-001: ALWAYS exit 0; never let a bad ledger break the tool flow.
"""

from __future__ import annotations

import datetime
import glob
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger, load_lib_module, test_hatch_enabled  # noqa: E402

# Read the phase via the ONE phase-decision module so the AST lint can forbid a
# raw phase literal anywhere else in lib/ (KTD-3).
phase_grammar = load_lib_module("phase-grammar")

# Ledger key recorded by U5 at arm time (read defensively — see module docstring).
_DRIVING_SESSION_KEY = "driving_session_id"


def _read_session_id(raw: str):
    """Parse the PreToolUse stdin and return its `session_id` (or None)."""
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    sid = data.get("session_id")
    return sid if isinstance(sid, str) and sid else None


def _load_ledger_safe(path):
    """Read a ledger JSON; return None on any read/parse failure (rel-001)."""
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except Exception:
        return None


def _owns_session(led, *, ledger, session_id, skip_staleness, stale_threshold, now):
    """True iff this ledger is a LIVE self-driven run owned by ``session_id``.

    The dedicated ownership predicate (NOT on-stop's `_is_blocking`): no
    met-state coupling. See the module docstring for the four conjuncts.
    """
    if not isinstance(led, dict):
        return False
    if phase_grammar.current_phase(led) == "done":
        return False
    loop = led.get("loop") or {}
    if loop.get("driver") != "self":
        return False
    # Dead-chain guard (mirrors on-stop.py): a self-driven run whose beat is
    # older than the stale threshold is a dead chain, not a live owner.
    if not skip_staleness:
        last_beat = ledger._parse_iso(loop.get("last_beat_at"))
        if last_beat is None:
            return False
        if (now - last_beat).total_seconds() > stale_threshold:
            return False
    # KTD-5 — session_id EQUALITY (read driving_session_id defensively).
    driving = led.get(_DRIVING_SESSION_KEY)
    return bool(driving) and driving == session_id


def _live_run_owns_session(repo_root: str, session_id, now=None) -> bool:
    """Scan <repo>/.claude/auto/*.json for a live self-driven run owning ``session_id``.

    Per-worktree glob only — fan-out sub-runs have their OWN session_id and are
    out of this hook's scope by design (KTD-5 two-seam split: they carry the
    prompt-embedded instruction instead). No batch-sidecar walk.
    """
    if not session_id:
        return False
    ledger = load_ledger()
    skip_staleness = test_hatch_enabled("CLAUDE_AUTO_TEST_NO_STALENESS_CHECK")
    stale_threshold = ledger.DRIVER_SELF_STALE_SECONDS
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        led = _load_ledger_safe(path)
        if led is None:
            continue
        if _owns_session(
            led, ledger=ledger, session_id=session_id,
            skip_staleness=skip_staleness, stale_threshold=stale_threshold, now=now,
        ):
            return True
    return False


# The redirect prose the denied agent reads (KTD-4 classification rule). Contains
# the word "decision" only inside prose — never as a bare ast.Constant string
# matched by the iteration-ast-lint (which exact-matches Constant value ==
# "decision"); this multi-word reason is not that literal.
_REDIRECT_REASON = (
    "auto: this is a live self-driven /auto run — do NOT stop to ask the "
    "operator. Consult the `advisor` tool with the question's context, then "
    "classify it yourself using that prose advice: (a) a MECHANICAL "
    "clarification (which file, formatting, an unambiguous default) -> resolve "
    "autonomously and proceed; (b) a substantive DESIGN/ARCHITECTURE fork (which "
    "architecture, is this scope right, a premise/positioning call) -> escalate "
    "to the operator via `auto-resume.py pause <run> \"<the fork>\"`. When unsure "
    "between the two, treat it as a fork and escalate (the default for "
    "substantive choices is escalate, not auto-resolve)."
)


def decide(repo_root: str, stdin_raw: str) -> dict | None:
    """Return the deny decision dict to print, or None to allow silently.

    Fires the deny ONLY when a live self-driven run owns this session.
    """
    session_id = _read_session_id(stdin_raw)
    if not _live_run_owns_session(repo_root, session_id):
        return None  # not our run (or no session) => allow normal AskUserQuestion.
    if test_hatch_enabled("CLAUDE_AUTO_TEST_DENY_UNSUPPORTED"):
        # FAIL OPEN (the question gate's asymmetry vs the action backstop —
        # KTD-4 / plan VERIFY (a)): with no deny contract, ALLOW the question
        # through (worst case the operator is asked directly) but surface a loud
        # systemMessage. A bare systemMessage with NO permissionDecision is "no
        # decision => normal flow". Crucially NO pause — unlike the action hook,
        # which fails closed by pausing.
        return {
            "systemMessage": (
                "auto advisor gate: the PreToolUse deny contract is unavailable "
                "— allowing this AskUserQuestion through to the operator (fail "
                "open). " + _REDIRECT_REASON
            )
        }
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": _REDIRECT_REASON,
        }
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
        decision = None  # any failure => allow (fail-open; rel-001).
    if decision is not None:
        json.dump(decision, sys.stdout)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
