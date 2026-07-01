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

PATH-SCOPING (drive-friction fix — narrows the rm family ONLY): the `rm -rf`/
`rm -fr` matches are exempted when EVERY path target provably resolves to a real
child under a known-ephemeral root (/tmp / /private/tmp / /var/folders) — see
``_rm_targets_all_ephemeral``. Benign teardown of fan-out agents' scratch dirs
and the operator's finalize cleanup was false-firing the fail-closed backstop
and LATCHING the run. Exemption (unlike gating) is CONSERVATIVE about runtime
expansion: a target with a glob / command-substitution / brace / unresolved
`$`-var gates, the temp ROOT itself gates, `..` traversal gates, and `$TMPDIR` is
RESOLVED from the hook env (unset/empty -> gate, so `rm -rf "$TMPDIR/"` can't
expand to `rm -rf /`). This is an allowlist that only narrows in-scope rm
matches; it does NOT widen the residual set above and does NOT touch the
git/gh/npm patterns.

rel-001: ALWAYS exit 0 at the process level.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402
    DRIVING_SESSION_KEY,
    iter_worktree_ledgers,
    load_ledger,
    load_lib_module,
    test_hatch_enabled,
)

phase_grammar = load_lib_module("phase-grammar")

# ──────────────────────────────────────────────────────────────────────────
# Destructive pattern set (KTD-4 — anchored to the project's CLAUDE.md
# destructive list). Each entry is (human_label, compiled_regex). The regex is
# matched against the Bash `command` string ONLY (round-4 P2: NOT Write content
# — see ``_command_text``); the label is surfaced in the deny reason / pause
# record (never the raw regex source — that would be opaque to the agent reading
# permissionDecisionReason). The set is the documented minimum; residual bypasses
# (see module docstring) are out of scope.
# The two rm labels are named constants because the path-scoping exemption keys
# off them by value (``_PATH_SCOPED_RM_LABELS`` below): if a label string here
# and there ever drift apart, path-scoping silently becomes a dead no-op and
# every ephemeral rm starts false-pausing again. Sharing the constant makes that
# impossible.
_RM_RF_LABEL = "rm -rf"
_RM_FR_LABEL = "rm -fr"

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
    (_RM_RF_LABEL, re.compile(r"\brm\s+-rf\b")),
    (_RM_FR_LABEL, re.compile(r"\brm\s+-fr\b")),  # the one flag-reorder residual we DO catch
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


# ──────────────────────────────────────────────────────────────────────────
# Path-scoping for the rm family (drive-friction fix). The `rm -rf`/`rm -fr`
# patterns above match the verb+flags with no path awareness, so benign teardown
# of an EPHEMERAL temp dir (fan-out agents' $TMPDIR scratch, the operator's own
# finalize cleanup) false-fired the fail-closed backstop and LATCHED the run.
# We exempt an rm ONLY when EVERY one of its path targets provably resolves under
# a known-ephemeral root — an allowlist, so anything not provably ephemeral
# (relative paths under the repo, $HOME, the temp root ITSELF, traversal
# evasions, unparseable commands) still GATES. This refines the rm matches the
# classifier already catches; it does NOT widen the documented residual set
# (flag-reorder long-form, compound `a; rm -rf b`, eval/obfuscation all still
# bypass — see module docstring) and touches ONLY the rm family (the git/gh/npm
# patterns have no path-exemption concept).
_PATH_SCOPED_RM_LABELS = frozenset({_RM_RF_LABEL, _RM_FR_LABEL})

# Drift guard: every rm-family pattern MUST participate in path-scoping. Without
# this, adding a third `rm ` variant to _DESTRUCTIVE_PATTERNS but forgetting to
# list its label here would make that variant gate ALL ephemeral teardown again
# (a silent regression of the fix). Enforced at import, so the test suite catches
# it immediately.
assert all(
    label in _PATH_SCOPED_RM_LABELS
    for label, _ in _DESTRUCTIVE_PATTERNS
    if label.startswith("rm ")
), "every 'rm ' label in _DESTRUCTIVE_PATTERNS must be in _PATH_SCOPED_RM_LABELS"

# Ephemeral roots are ABSOLUTE, literal prefixes. Each carries a trailing
# separator AND ``_under_ephemeral_root`` additionally requires the target to be
# a real child (``norm != rootdir``), so deleting the temp ROOT itself
# (`rm -rf /tmp` / `rm -rf /tmp/`) is NOT exempted — only deletions UNDER it.
# `$TMPDIR` is handled separately (``_resolve_tmpdir_target``), NOT as a literal
# prefix: matching the literal token would exempt a string whose RUNTIME value
# the classifier cannot see — and exemption (unlike gating) must be conservative
# about expansion, or `rm -rf "$TMPDIR/"` with TMPDIR unset (the common case in a
# hook subprocess / CI) expands to `rm -rf /`.
_EPHEMERAL_ABS_PREFIXES = (
    "/tmp/",
    "/private/tmp/",
    "/var/folders/",          # full macOS user-temp tree: T/ (temp) AND C/
    "/private/var/folders/",  # (regenerable caches) — both ephemeral-safe for rm.
)
_TMPDIR_TOKENS = ("$TMPDIR/", "${TMPDIR}/")
# Metacharacters whose runtime expansion the classifier cannot resolve — a target
# containing any of these is NEVER provably ephemeral, so it gates: command
# substitution (`$(`, backtick), globs (`*`, `?`, `[`), brace expansion (`{`).
# (`$`-variables are handled separately: only an exact $TMPDIR/ prefix resolves.)
_UNRESOLVABLE_METACHARS = ("$(", "`", "*", "?", "[", "{")


def _under_ephemeral_root(path: str) -> bool:
    """True iff a FULLY-LITERAL path is a real child strictly UNDER an ephemeral
    root — never the root itself, never via a ``..`` segment."""
    if ".." in path.split("/"):
        return False  # traversal evasion (e.g. /tmp/../etc) -> gate.
    norm = os.path.normpath(path)
    for root in _EPHEMERAL_ABS_PREFIXES:
        rootdir = root.rstrip("/")
        if norm != rootdir and norm.startswith(rootdir + "/"):
            return True
    return False


def _resolve_tmpdir_target(t: str):
    """Resolve a ``$TMPDIR/<rest>`` / ``${TMPDIR}/<rest>`` token to its literal
    runtime path, or None when it cannot be SAFELY resolved (→ gate).

    Gates (returns None) on: a bare-root token (`$TMPDIR/` with empty remainder,
    which expands to the temp root or — if TMPDIR is unset — to `/`), a nested
    variable in the remainder, or an unset/empty TMPDIR (the `rm -rf /` hole).
    The resolved path is still subject to ``_under_ephemeral_root`` by the caller,
    so a `$TMPDIR/../x` remainder is caught there.
    """
    for tok in _TMPDIR_TOKENS:
        if t.startswith(tok):
            rest = t[len(tok):]
            if not rest or "$" in rest:
                return None  # bare temp root, or a further unresolvable var.
            base = os.environ.get("TMPDIR")
            if not base:
                return None  # unset/empty -> `$TMPDIR/x` expands to `/x` -> gate.
            return base.rstrip("/") + "/" + rest
    return None


def _rm_targets_all_ephemeral(command: str) -> bool:
    """True iff ``command`` is an ``rm`` whose EVERY path target provably resolves
    to a real child under an ephemeral-temp root.

    Fail-closed: returns False (→ the backstop still gates) on anything not
    provably ephemeral — a relative target (resolves under cwd = repo root), a
    ``$HOME``/repo path, the temp root itself, a ``..`` traversal, a glob /
    command-substitution / brace target whose expansion is unknowable, an
    unresolvable ``$TMPDIR``, an unparseable command, or zero targets. Requires at
    least one target. Documented residual (NOT chased): an inline
    ``TMPDIR=/repo rm -rf "$TMPDIR/x"`` resolves against the hook's outer TMPDIR —
    this is the eval/obfuscation residual class (see module docstring).
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False  # unbalanced quotes / unparseable -> gate.
    # Locate the rm invocation (bare `rm` or a `/path/to/rm`); classify only the
    # tokens after it. A compound command (`rm -rf /tmp/a && rm -rf /repo`) is a
    # documented residual that still gates here: the shell operators (`&&`, `;`)
    # and the second command's tokens are collected as non-ephemeral targets and
    # fail the check below — fail-closed, not exempt.
    idx = next(
        (i for i, t in enumerate(tokens) if t == "rm" or t.endswith("/rm")),
        None,
    )
    if idx is None:
        return False
    targets = []
    end_of_opts = False
    for tok in tokens[idx + 1:]:
        if not end_of_opts and tok == "--":
            end_of_opts = True
            continue
        if not end_of_opts and tok.startswith("-"):
            continue  # an rm flag (-rf, -r, -f, --verbose, ...).
        targets.append(tok)
    if not targets:
        return False
    for t in targets:
        # Resolve a leading $TMPDIR FIRST (its `${...}` braces are not brace
        # EXPANSION), then run the metachar + root checks on the literal result.
        # Any other `$`-var is unresolvable -> gate.
        if "$" in t:
            t = _resolve_tmpdir_target(t)
            if t is None:
                return False  # unresolvable $-var (incl. $HOME, $(...), /tmp/$X).
        if any(m in t for m in _UNRESOLVABLE_METACHARS):
            return False  # glob / command-subst / brace -> unknowable -> gate.
        if not _under_ephemeral_root(t):
            return False  # relative / $HOME / repo / temp-root-itself -> gate.
    return True


def _matched_destructive(command: str):
    """Return the human label of the first destructive match, or None.

    rm-family matches are PATH-SCOPED: an ``rm -rf``/``rm -fr`` whose targets are
    all ephemeral-temp (``_rm_targets_all_ephemeral``) is treated as benign and
    skipped — so a real destructive op spelled differently can still match a
    LATER pattern, and a genuinely destructive rm still returns its label.
    """
    if not command:
        return None
    for label, pat in _DESTRUCTIVE_PATTERNS:
        if pat.search(command):
            if label in _PATH_SCOPED_RM_LABELS and _rm_targets_all_ephemeral(command):
                continue  # ephemeral-temp teardown -> not gated (path-scoping).
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
    driving = led.get(DRIVING_SESSION_KEY)
    if not (bool(driving) and driving == session_id):
        return False
    loop = led.get("loop") or {}
    if loop.get("driver") == "manual" and not loop.get("backstop_latched"):
        return False  # operator-controlled pause => allow the operator's own actions
    return True


def _owning_run_id(repo_root: str, session_id):
    """Return the run_id of the live auto run owning ``session_id``, or None.

    Scans the per-worktree ledgers (``iter_worktree_ledgers`` — fan-out sub-runs
    are out of hook scope by design, KTD-5). Unlike the question hook we need the
    RUN ID, not just a bool, so we can pause it. No staleness/driver coupling —
    see ``_owns_session`` (round-2 P2: a stale or driver=manual conjunct would
    self-disarm the fail-closed backstop).
    """
    if not session_id:
        return None
    for run_id, led in iter_worktree_ledgers(repo_root):
        if _owns_session(led, session_id=session_id):
            return run_id
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
