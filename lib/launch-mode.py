#!/usr/bin/env python3
"""auto launch-chooser: the deterministic interactive-vs-headless seam (R11/KTD-5).

skills/auto-launch §0 must decide **silent-apply** (a self-driven / headless run)
vs **show-the-chooser** (an interactive human-typed `/auto`) — the load-bearing
guard that keeps a self-driven run out of the `AskUserQuestion` path *by
construction* (AE6), not by relying on the PreToolUse advisor-gate denial. Prior
to this module that decision lived entirely in skill prose; this folds it into
ONE shell-callable check that prints exactly `headless` / `interactive`, so the
guard has an executable seam a test can pin (agent-native hardening).

`headless` (→ silent-apply) IFF either:
  - `CLAUDE_CODE_SESSION_ID` is unset/empty — a truly headless / env-less context
    with no interactive operator present; or
  - this session already owns a LIVE self-driven run in the repo: some ledger has
    `loop.driver == "self"`, is not in the terminal `done` phase, and its
    `driving_session_id` equals this session id (an autonomous run reached the
    launch path).
Otherwise `interactive`: a human-typed `/auto` with no live self-driven run of
its own (the common case — at a fresh launch there is no ledger yet) → the
chooser may show.

**Uncertainty degrades to `headless`, never crashes.** Absence of a session id,
an unresolvable repo, a core module that won't load — all resolve to `headless`
(and the CLI never prints empty stdout). This is the same conservative direction
as the SKILL §0 "anything but `interactive` → headless" fallback, and it is
deliberate: the advisor-gate PreToolUse hook that would otherwise catch a
wrongly-`interactive` self-driven run is itself FAIL-OPEN on the SAME infra this
module reads (`lib/on-pretooluse-askuser.py`: phase-grammar, the `.claude/auto`
scan, `driving_session_id`). So `interactive`-on-uncertainty risks wedging a
headless run on an unanswerable question, whereas `headless` proceeds with the R9
one-line notice — degraded, not stuck. Individual malformed ledgers are skipped
(via `iter_worktree_ledgers` / `load_ledger_safe`), never fatal.
"""

import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)
from _bootstrap import (  # noqa: E402
    iter_worktree_ledgers,
    load_lib_module,
    resolve_repo,
)

# Canonical readers — never re-implement these (they carry guards that have
# drifted before, e.g. the v0.6.4 CHILD_SESSION removal): the session id comes
# from `driver_session` (the ONE `CLAUDE_CODE_SESSION_ID` reader) and the ledger
# scan from `iter_worktree_ledgers` (the shared per-worktree glob + safe-load).
driver_session = load_lib_module("driver_session")

HEADLESS = "headless"
INTERACTIVE = "interactive"


def _owns_live_self_run(repo_root, session_id, phase_grammar):
    """True iff `session_id` owns a LIVE self-driven run under `repo_root`.

    A live self-run is a ledger with `loop.driver == "self"`, `driving_session_id
    == session_id`, and a current phase that is not the terminal `done`. A
    non-dict `loop` field (a corrupt ledger) is treated as not-an-owner and
    skipped, never a crash.
    """
    for _run_id, led in iter_worktree_ledgers(repo_root):
        loop = led.get("loop")
        if not isinstance(loop, dict) or loop.get("driver") != "self":
            continue  # manual / unset driver, or a non-dict loop field.
        if led.get("driving_session_id") != session_id:
            continue  # owned by another session (or no recorded owner).
        if phase_grammar.current_phase(led) == "done":
            continue  # a finished run does not make this launch headless.
        return True
    return False


def launch_mode(repo_root, session_id):
    """Decide `headless` vs `interactive`. Degrades to `headless` on any infra
    failure (see the module docstring for why that is the safe direction)."""
    if not session_id:
        return HEADLESS  # no operator present => silent-apply by construction.
    try:
        phase_grammar = load_lib_module("phase-grammar")
        owns = _owns_live_self_run(repo_root, session_id, phase_grammar)
    except Exception:
        return HEADLESS  # infra failure => proceed-with-notice, never wedge.
    return HEADLESS if owns else INTERACTIVE


def _cli(argv):
    """Print `headless` / `interactive` for the current session + repo. No args.

    The no-session-id short-circuit runs BEFORE `resolve_repo`, so a truly
    headless run can never crash on repo resolution. Any uncaught failure still
    degrades to a clean `headless` token — never empty stdout (the SKILL reads a
    non-`interactive` output as headless, so an empty/garbled line must not leak).
    """
    try:
        session_id = driver_session.driving_session_id()
        if not session_id:
            sys.stdout.write(HEADLESS + "\n")
            return 0
        repo_root = resolve_repo()
        sys.stdout.write(launch_mode(repo_root, session_id) + "\n")
    except Exception:
        sys.stdout.write(HEADLESS + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
