#!/usr/bin/env python3
"""auto U4: decision logic behind .claude/hooks/on-pretooluse-action.sh.

The deterministic destructive-action backstop (KTD-4/5). On a Bash tool call,
under the SAME live-run + session_id ownership gate as the question hook, match
the `command` against the CLAUDE.md-anchored irreversible/destructive set and
ESCALATE via the pause seam. Write tool calls reach this hook (the plugin
matches both) but only their `command` field is classified — which Write never
sets — so Write is effectively a no-op here (round-4 P2: Write `content` is NOT
scanned; see ``_command_text``).

FAILS CLOSED (KTD-4 — the opposite asymmetry from the question gate):
    on a CONFIRMED destructive command for a CONFIRMED live run, this hook PAUSES
    the run (set_loop driver="manual" + blocked_on) UNCONDITIONALLY — even when
    the PreToolUse `deny` contract is unavailable. It never degrades to
    silent-allow on a destructive match. The halt is observable on the LEDGER
    (driver=manual / blocked_on), not the process exit code (which stays 0).

    Scope of fail-closed is PRECISE: a confirmed-destructive command on a
    confirmed-live owned run. A malformed ledger, an unidentifiable run, a
    non-owned session, or a BENIGN command all fall through to allow (matching
    the question hook's malformed->allow scenario). We do NOT blanket-deny on any
    exception — that would brick the tool flow on an unrelated read.

DENY-CONTRACT MODES:
    * normal (deny supported): emit the deny JSON (blocks the single call) AND
      pause the run (halts the loop). Belt-and-suspenders.
    * deny-unsupported (test hatch CLAUDE_AUTO_TEST_DENY_UNSUPPORTED, fenced via
      test_hatch_enabled): still pause the run, but emit a `systemMessage`
      instead of the deny payload — never an empty/allow output on a destructive
      match. This is the fail-closed path the integration test exercises.

BYPASS RESIDUALS (KTD-4 — documented out-of-scope, NOT covered by this
classifier): the general flag-reorder/long-form class (`rm -vrf`,
`rm --recursive --force` — we catch the literal `rm -rf` and `rm -fr` only),
refspec force-push (`git push origin +<ref>`), compound commands (`a; rm -rf b`),
and eval/obfuscation. ALSO out-of-scope (fix-round-5 P2): GitHub MCP write tools
(`delete_file`, `merge_pull_request`, `push_files`, `create_or_update_file`) — they
do NOT flow through the Bash `command` channel this classifier reads (their
tool_input carries no `command`), and the hook is wired to Bash/Write tool names
only, so an MCP tool name never reaches it. Gating MCP-write tools is a tool-name
interception change beyond v0.6.0's detect-and-escalate scope; fan-out units carry
the prompt-embedded two-seam instruction instead. The classifier is a
deterministic minimum-set backstop, not a comprehensive sandbox.

rel-001: ALWAYS exit 0 at the process level.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger, load_lib_module, test_hatch_enabled  # noqa: E402

phase_grammar = load_lib_module("phase-grammar")

_DRIVING_SESSION_KEY = "driving_session_id"

# ──────────────────────────────────────────────────────────────────────────
# Destructive pattern set (KTD-4 — anchored to the project's CLAUDE.md
# destructive list). Each entry is (human_label, compiled_regex). The regex is
# matched against the Bash `command` string ONLY (round-4 P2: NOT Write content
# — see ``_command_text``); the label is surfaced in the deny reason / pause
# record (never the raw regex source — that would be opaque to the agent reading
# permissionDecisionReason). The set is the documented minimum; residual bypasses
# (see module docstring) are out of scope.
_DESTRUCTIVE_PATTERNS = [
    # Force-push in ANY flag position (fix-round-5 P1). `push` always precedes
    # its force flag in real git, so match by ORDER (`push` ... force flag), not
    # by adjacency — the prior `push\s+--force` anchoring missed the canonical
    # flag-last spelling `git push origin main --force` / `-f` /
    # `--force-with-lease`, which is at least as common as flag-first and is NOT a
    # documented residual (KTD-4 residuals are shell-syntax bypasses only).
    # `--force\b` matches inside `--force-with-lease` (word boundary between `e`
    # and `-`), so the lease form needs no separate pattern. The `\s-f\b` (leading
    # whitespace) keeps benign branch names like `git push origin my-feature` /
    # `git push origin wolf` from matching the short flag.
    ("git push --force / -f / --force-with-lease",
     re.compile(r"\bpush\b.*(?:--force\b|\s-f\b)")),
    ("git reset --hard", re.compile(r"reset\s+--hard\b")),
    # Whole-tree discard family — the trailing ` .` pathspec discards the entire
    # working tree regardless of the intervening flags/tree-ish, so match it in
    # any spelling (`checkout .`, `checkout -- .`, `checkout HEAD -- .`,
    # `restore -- .`, `restore --source=HEAD~1 .`). The `\s\.` requires the `.`
    # to be its own whitespace-delimited pathspec, so a scoped pathspec
    # (`checkout -- file.py`, `restore --staged x`) and benign forms
    # (`checkout -b`, `checkout main`) correctly do NOT fire.
    ("git checkout . (discard working tree)", re.compile(r"checkout\b[^\n]*\s\.(?:\s|$)")),
    ("git restore . (discard working tree)", re.compile(r"restore\b[^\n]*\s\.(?:\s|$)")),
    ("git clean -f / -fdx", re.compile(r"clean\s+-[a-z]*f")),
    ("git branch -D (force-delete)", re.compile(r"branch\s+-D\b")),
    ("rm -rf", re.compile(r"\brm\s+-rf\b")),
    ("rm -fr", re.compile(r"\brm\s+-fr\b")),  # the one flag-reorder residual we DO catch
    # Known external-publish / irreversible-GitHub endpoints (KTD-4). Minimal,
    # explicit set — extend deliberately, not speculatively. `npm publish` /
    # `gh release create` are the concrete irreversible publishes in this
    # project's orbit. The destructive `gh` subcommands below (fix-round-5 P2)
    # run through the already-gated Bash channel — the global CLAUDE.md instructs
    # preferring `gh` for GitHub ops — and are equivalent-destruction to the git
    # set: `gh repo delete` (irreversible), `gh release delete` (irreversible),
    # `gh pr merge --admin` (bypasses branch protection / required reviews).
    ("npm publish", re.compile(r"npm\s+publish\b")),
    ("gh release create", re.compile(r"gh\s+release\s+create\b")),
    ("gh repo delete", re.compile(r"gh\s+repo\s+delete\b")),
    ("gh release delete", re.compile(r"gh\s+release\s+delete\b")),
    ("gh pr merge --admin", re.compile(r"gh\s+pr\s+merge\b.*--admin\b")),
]


def _matched_destructive(command: str):
    """Return the human label of the first destructive match, or None."""
    if not command:
        return None
    for label, pat in _DESTRUCTIVE_PATTERNS:
        if pat.search(command):
            return label
    return None


def _command_text(stdin_data: dict) -> str:
    """Extract the text to classify from the PreToolUse tool_input.

    Bash ONLY -> tool_input.command. The Bash `command` channel is the
    load-bearing destructive backstop; Write `content` is DELIBERATELY NOT
    scanned (round-4 P2). Classifying Write prose against the destructive
    command set false-positive-pauses the driving session's own ce-skill doc
    writes — /ce-plan, /ce-doc-review, /ce-brainstorm routinely emit
    plan/review markdown that quotes `rm -rf`/`push --force` as examples (this
    repo's CLAUDE.md lists the destructive set verbatim). That is nearly all
    false-positive cost: the in-scope driving-session doc Writes are the common
    case, while a real destructive operation runs through Bash, which IS gated.
    Defensive: a missing `command` reads as empty.
    """
    ti = stdin_data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return ""
    val = ti.get("command")
    return val if isinstance(val, str) else ""


def _read_stdin(raw: str):
    """Parse PreToolUse stdin -> (session_id, command_text). ((None, "") on failure)."""
    if not raw:
        return None, ""
    try:
        data = json.loads(raw)
    except Exception:
        return None, ""
    if not isinstance(data, dict):
        return None, ""
    sid = data.get("session_id")
    sid = sid if isinstance(sid, str) and sid else None
    return sid, _command_text(data)


def _load_ledger_safe(path):
    """Read a ledger JSON; return None on any read/parse failure (rel-001)."""
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except Exception:
        return None


def _owns_session(led, *, session_id):
    """True iff this run is a LIVE auto run owned by ``session_id`` that the
    destructive backstop must still gate.

    Base match: ``current phase != "done" AND session_id == driving_session_id``
    — DELIBERATELY OMITTING the ``last_beat_at`` staleness conjunct the question
    gate keeps, and NOT requiring ``driver == "self"`` (with ONE precise
    operator-pause exemption, below). Both choices exist because this hook fails
    CLOSED and a denied tool call does NOT end the agent's turn:

      * driver: THIS hook's own ``_pause_run`` flips the owned run to
        ``driver="manual"`` the instant it blocks the first destructive command.
        A plain ``driver=="self"`` requirement would make every SUBSEQUENT
        destructive command see ``driver=="manual"`` → no match → ALLOW
        (self-disarm after one fire). So we do NOT key on ``driver=="self"``.
      * staleness (round-2 P2 fix): ``_pause_run`` calls ``set_loop`` WITHOUT
        ``beat=True``, so it does NOT re-stamp ``last_beat_at``. If the operator
        deliberates past ``DRIVER_SELF_STALE_SECONDS`` (3900s) after the backstop
        fires once, a stale-conjunct would read the paused run as a dead chain →
        no match → ALLOW a second ``rm -rf`` / force-push — the exact self-disarm
        the driver omission was meant to prevent, reintroduced through the
        staleness door. A live session whose id equals the recorded driving id IS
        the run to gate regardless of beat freshness; pausing a genuinely-dead run
        is harmless (fail-safe). So staleness lives ONLY in the question hook
        (where stale→allow is a benign fail-OPEN), never here.

    OPERATOR-PAUSE EXEMPTION (P3-b): a run the OPERATOR manually paused
    (``driver=="manual"`` WITHOUT ``loop.backstop_latched``) is under human
    control — the autonomous tick loop is dormant, so the only actor issuing tool
    calls is the operator, and we must NOT gate their own cleanup (``rm`` etc.).
    The ONE ``driver=="manual"`` state we KEEP gating is a pause THIS backstop
    caused: ``_pause_run`` sets ``backstop_latched=True`` atomically with the
    pause, so a second destructive command in the same autonomous turn still
    matches (no self-disarm). The latch is STICKY across an agent-run
    ``auto-resume pause`` (that path does not clear it), so a self-driven agent
    cannot reach the exempt state with one benign command — only an operator
    ``continue``/``abort`` clears it (continue clears the latch; abort ends the
    run). Trade-off (documented, surfaced to the operator in the deny reason): a
    run that ALREADY tripped the backstop keeps blocking the operator's own
    destructive commands during a *pause* — they must ``continue`` or ``abort``
    first; ``abort`` → ``phase=done`` is the clean full-release cleanup path.

    Dimension #2 (a concurrent STANDALONE ce-skill is not gated) is preserved by
    the ``session_id`` equality conjunct alone — a standalone skill has a
    different session_id and never matches. Still NOT on-stop's `_is_blocking`
    (no met-state coupling).
    """
    if not isinstance(led, dict):
        return False
    if phase_grammar.current_phase(led) == "done":
        return False
    driving = led.get(_DRIVING_SESSION_KEY)
    if not (bool(driving) and driving == session_id):
        return False
    loop = led.get("loop") or {}
    if loop.get("driver") == "manual" and not loop.get("backstop_latched"):
        return False  # operator-controlled pause => allow the operator's own actions
    return True


def _owning_run_id(repo_root: str, session_id):
    """Return the run_id of the live auto run owning ``session_id``, or None.

    Per-worktree glob only (fan-out sub-runs are out of hook scope — KTD-5).
    Unlike the question hook we need the RUN ID, not just a bool, so we can pause
    it. No staleness/driver coupling — see ``_owns_session`` (round-2 P2: a stale
    or driver=manual conjunct would self-disarm the fail-closed backstop).
    """
    if not session_id:
        return None
    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        led = _load_ledger_safe(path)
        if led is None:
            continue
        if _owns_session(led, session_id=session_id):
            return led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
    return None


def _pause_run(repo_root: str, run_id: str, reason: str) -> None:
    """Halt the owned run via the pause seam (the fail-closed mechanism).

    Mirrors auto-resume.py's `_cmd_pause`: set_loop driver="manual" +
    blocked_on, WITHOUT marking the loop done — the run stays resumable. Routed
    through the ledger FACADE (import-topology facade discipline). Best-effort:
    a write failure must not propagate (rel-001), but the deny/systemMessage is
    still emitted, so the action is not silently allowed.
    """
    try:
        ledger = load_ledger()
        # backstop_latched=True in the SAME atomic write as driver="manual" (P3-b):
        # it marks this pause as backstop-initiated so the gate keeps firing on a
        # second destructive command in the same autonomous turn (no self-disarm),
        # while an OPERATOR pause (auto-resume.py pause, NOT latched) is exempt so
        # the operator can run their own cleanup. Set atomically => the latch
        # exists iff the pause does. NOT a separate best-effort write (the audit
        # record below is separate; a latch derived from it could split-brain).
        ledger.set_loop(
            repo_root, run_id, driver="manual", blocked_on=reason,
            backstop_latched=True,
        )
    except Exception:
        pass


def _audit_action(repo_root: str, run_id: str, *, command: str, label: str) -> None:
    """Append the kind="action" audit record for this fired backstop (KTD-5).

    Every fired action backstop is appended to the ledger's advisor_audit list
    (driver-reference.md §Audit, ledger-schema §2.1, SKILL.md §4.5) so a fired
    backstop is diagnosable in the exit report next to the P3 findings — without
    this the deny/pause is invisible to the driver (the hook denies out-of-band;
    no other code path runs at action-deny time). The ``subject`` is the
    classified Bash command; ``classification`` is the destructive-pattern
    label; ``resolution`` is the fixed "blocked-and-paused" (KTD-5 vocabulary).
    Best-effort like ``_pause_run`` — a write failure must not propagate
    (rel-001) and never suppresses the deny/systemMessage payload.
    """
    try:
        ledger = load_ledger()
        ledger.append_advisor_audit(
            repo_root, run_id,
            kind="action", subject=command, classification=label,
            resolution="blocked-and-paused",
        )
    except Exception:
        pass


def decide(repo_root: str, stdin_raw: str) -> dict | None:
    """Return the decision dict to print (deny OR systemMessage), or None to allow.

    Pauses the owned run on a confirmed destructive match (fail-closed), then
    emits the contract-appropriate payload. Allows silently on anything that is
    not a confirmed-destructive-command-on-an-owned-live-run.
    """
    session_id, command = _read_stdin(stdin_raw)
    label = _matched_destructive(command)
    if label is None:
        return None  # benign command => allow.
    run_id = _owning_run_id(repo_root, session_id)
    if run_id is None:
        return None  # not our live run (or unidentifiable) => allow (precise scope).

    reason = (
        f"auto destructive-action backstop: blocked `{label}` and PAUSED run "
        f"{run_id!r}. This is an irreversible/destructive operation auto will not "
        "run autonomously. Do NOT attempt to disarm or retry it — consult the "
        f"operator, then `/auto-resume continue {run_id}` once they approve. "
        f"(Operator: to run your OWN cleanup, take manual control first with "
        f"`/auto-resume abort {run_id}` — abort fully releases the gate.)"
    )
    _pause_run(repo_root, run_id, reason)
    _audit_action(repo_root, run_id, command=command, label=label)

    if test_hatch_enabled("CLAUDE_AUTO_TEST_DENY_UNSUPPORTED"):
        # Fail-closed under a missing deny contract: the run is ALREADY paused
        # above; surface a loud systemMessage instead of the deny payload — never
        # an empty/allow output on a destructive match.
        return {
            "systemMessage": (
                "auto destructive-action backstop fired but the PreToolUse deny "
                f"contract is unavailable — run {run_id!r} has been PAUSED "
                "(driver=manual) to fail closed. " + reason
            )
        }
    return {
        # P3-a: a top-level `systemMessage` is a LOUD operator-facing signal
        # surfaced in the transcript ALONGSIDE the deny (confirmed against the CC
        # hooks contract: systemMessage is a universal field, not suppressed by a
        # permissionDecision). Without it the production deny only surfaced the
        # agent-facing permissionDecisionReason + a ledger pause — silent to an
        # operator not watching the ledger. The deny-unsupported path already
        # emitted a systemMessage; this gives the normal path parity.
        "systemMessage": (
            f"auto: RUN PAUSED — destructive-action backstop blocked `{label}` "
            f"on run {run_id!r} (driver=manual). {reason}"
        ),
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
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
        decision = None  # any failure => allow (rel-001). Fail-closed is SCOPED
        # to a confirmed destructive match on a confirmed run, handled inside
        # decide(); an unrelated internal error must not brick the tool flow.
    if decision is not None:
        json.dump(decision, sys.stdout)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
