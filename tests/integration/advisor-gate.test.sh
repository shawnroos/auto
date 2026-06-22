#!/usr/bin/env bash
# auto U4 integration test: the advisor-gate PreToolUse hooks.
#
# Exercises the REAL ledger.py + the U4 hook scripts (.sh wrappers exec'ing into
# the sibling .py) wired exactly as the plugin manifest wires them. The ONLY
# injected seams are the repo path (a sandbox tmp repo) and the PreToolUse event
# JSON (fed on stdin, as the harness would). Nothing is mocked.
#
# `driving_session_id` is recorded on the ledger by U5 (the arm-time setter),
# which is not part of THIS unit. So — exactly as hooks.test.sh hand-ages
# last_beat_at — we inject driving_session_id by a direct read-edit-write of the
# ledger JSON. Without it the defensive read finds the key absent and ALLOWS, so
# every deny scenario depends on this injection.
#
# Scenarios (U4 plan):
#   askuser hook:
#     - live self-driven run + MATCHING session_id   -> deny + advisor redirect
#     - live run + MISMATCHED session_id (standalone) -> allow (KTD-5)
#     - no ledger / phase==done / driver==manual / stale (>3900s) -> allow
#     - malformed ledger -> allow + exit 0 (rel-001)
#   action hook (same ownership gate):
#     - destructive (push --force / rm -rf / reset --hard / branch -D) on a
#       live owned run -> deny + the run is PAUSED (driver=manual, blocked_on)
#     - benign (ls / git status) -> allow, ledger untouched
#     - fail-CLOSED: deny-unsupported hatch -> systemMessage (NOT empty) AND the
#       run is still PAUSED on the ledger
#     - mismatched session_id + destructive -> allow, ledger untouched (scope)
#   .sh shim: malformed ledger -> exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
ASKUSER_SH="${AUTO_ROOT}/.claude/hooks/on-pretooluse-askuser.sh"
ASKUSER_PY="${AUTO_ROOT}/lib/on-pretooluse-askuser.py"
ACTION_SH="${AUTO_ROOT}/.claude/hooks/on-pretooluse-action.sh"
ACTION_PY="${AUTO_ROOT}/lib/on-pretooluse-action.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
mkrepo() {
  local repo="${SANDBOX}/repo-${1}"
  mkdir -p "${repo}/.claude/auto"
  printf '%s' "$repo"
}

pyledger() {
  local repo="$1"; shift
  "$PY" - "$repo" "$LEDGER_PY"
}

# Inject driving_session_id onto a run's ledger by direct JSON edit (U5 owns the
# real setter — mirrors hooks.test.sh hand-aging last_beat_at).
set_driving_session() {
  local repo="$1" run="$2" sid="$3"
  "$PY" - "$repo" "$run" "$sid" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, sid, ledger_py = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
p = L.ledger_path(repo, run)
with open(p) as f: led = json.load(f)
led["driving_session_id"] = sid
with open(p,"w") as f: json.dump(led,f)
PYEOF
}

jget() { "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], ''))
except Exception:
    print('')" "$1" "$2"; }

# Read loop.driver / loop.blocked_on for ledger assertions.
rd_loop() {
  local repo="$1" run="$2" field="$3"
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$repo','$run');print(l['loop'].get('$field'))"
}

# Read the top-level advisor_audit list (NOT under loop) — count + a field of
# the most-recent record. usage: rd_audit <repo> <run> <count|kind|classification>
rd_audit() {
  local repo="$1" run="$2" what="$3"
  "$PY" -c "import importlib.util as u,sys
s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m)
l=m.read_ledger('$repo','$run');aud=l.get('advisor_audit') or []
what='$what'
if what=='count': print(len(aud))
elif aud: print(aud[-1].get(what,''))
else: print('')"
}

# Pull permissionDecision out of a hookSpecificOutput payload.
perm_decision() {
  "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get('hookSpecificOutput',{}).get('permissionDecision',''))
except Exception:
    print('')" "$1"
}

# The test harness sentinel + a self-driven LIVE run is the common setup. The
# staleness gate stays ON (a fresh init_ledger stamps last_beat_at=now), so we
# do NOT set NO_STALENESS_CHECK except for the explicit stale scenario.
EVENT() {  # EVENT <session_id> <tool_name> <command>
  "$PY" -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'command':sys.argv[3]}}))" "$1" "$2" "$3"
}

# ════════════════════════════════════════════════════════════════════════════
echo "advisor-gate.test.sh"

# ─── askuser: live self-driven run + MATCHING session_id -> deny ──────────────
it "askuser: live self-driven run + matching session_id -> deny + advisor redirect"
REPO="$(mkrepo askuser-match)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"liverun",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
set_driving_session "$REPO" liverun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "askuser: deny reason redirects to the advisor and names both classification branches"
assert_contains "$out" "advisor"
it "askuser: deny reason names the pause-seam escalation for design forks"
assert_contains "$out" "auto-resume.py pause"

# ─── askuser FAIL-OPEN: deny-unsupported hatch -> systemMessage, NO deny ──────
# The question gate's asymmetry vs the action backstop (KTD-4 / plan VERIFY (a)):
# with no deny contract it ALLOWS the question through (operator asked directly)
# and surfaces a loud systemMessage — never a pause, never a deny.
it "askuser FAIL-OPEN: matching session + deny-unsupported -> systemMessage (allow, not deny)"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DENY_UNSUPPORTED=1 "$PY" "$ASKUSER_PY" "$REPO")"
assert_contains "$out" "systemMessage"
it "askuser FAIL-OPEN: deny-unsupported emits NO permissionDecision (allow, normal flow)"
assert_empty "$(perm_decision "$out")"

# ─── askuser: live run + MISMATCHED session_id -> allow (KTD-5) ───────────────
it "askuser: live run but MISMATCHED session_id (concurrent standalone) -> allow"
ev="$(EVENT sess-OTHER AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: no driving_session_id recorded -> allow (defensive read) ────────
it "askuser: live run but driving_session_id ABSENT (pre-U5 ledger) -> allow"
REPO="$(mkrepo askuser-nosid)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"nosid",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: no ledger at all -> allow ───────────────────────────────────────
it "askuser: empty dispatch dir (no run) -> allow"
REPO="$(mkrepo askuser-empty)"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: phase==done -> allow ────────────────────────────────────────────
it "askuser: a done run (matching session_id) -> allow (run finished)"
REPO="$(mkrepo askuser-done)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"donerun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"terminal-skip"}])
L.set_loop(repo,"donerun",loop_phase="done")
PYEOF
set_driving_session "$REPO" donerun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: driver==manual (seam/blocked pause) -> allow ────────────────────
it "askuser: a manual-driver (paused) run -> allow (not a live tick chain)"
REPO="$(mkrepo askuser-manual)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"manualrun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"manualrun",driver="manual")
PYEOF
set_driving_session "$REPO" manualrun "sess-AAA"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: stale driver==self chain (>3900s) -> allow ──────────────────────
it "askuser: a STALE self chain (last_beat_at > DRIVER_SELF_STALE_SECONDS) -> allow (dead chain)"
REPO="$(mkrepo askuser-stale)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util, json, datetime
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"staleself",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
old = (datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(seconds=L.DRIVER_SELF_STALE_SECONDS + 120)).strftime("%Y-%m-%dT%H:%M:%SZ")
p = L.ledger_path(repo,"staleself")
with open(p) as f: led = json.load(f)
led["loop"]["last_beat_at"] = old
led["loop"]["driver"] = "self"
led["driving_session_id"] = "sess-AAA"
with open(p,"w") as f: json.dump(led,f)
PYEOF
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"

# ─── askuser: malformed ledger -> allow + exit 0 (rel-001) ────────────────────
it "askuser: malformed ledger -> allow (no crash)"
REPO="$(mkrepo askuser-malformed)"
printf '{ not valid json' > "${REPO}/.claude/auto/broken.json"
ev="$(EVENT sess-AAA AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"
it "askuser.py: malformed ledger -> exit 0 (rel-001)"
printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO" >/dev/null 2>&1
assert_eq "0" "$?"
it "askuser.sh shim: malformed ledger -> exit 0 (rel-001)"
( cd "$REPO" && printf '%s' "$ev" | bash "$ASKUSER_SH" >/dev/null 2>&1 )
assert_eq "0" "$?"

# ═══════════════════════════════════════════════════════════════════════════
# action hook (destructive backstop)
# ═══════════════════════════════════════════════════════════════════════════

# Build a fresh live owned run for the action scenarios.
mk_live_owned() {  # mk_live_owned <name> <run> <sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,run,adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

# ─── action: destructive commands on a live owned run -> deny + PAUSE ──────────
# Force-push is covered in EVERY flag position (fix-round-5 P1): the canonical
# flag-last spellings `git push origin main --force`/`-f`/`--force-with-lease`
# were silently bypassing the prior `push\s+--force`-adjacency classifier. The
# irreversible `gh` subcommands (fix-round-5 P2) run through the same gated Bash
# channel and are equivalent-destruction, so they deny+pause too.
for cmd in \
  'git push --force origin main' \
  'git push origin main --force' \
  'git push origin main -f' \
  'git push origin main --force-with-lease' \
  'rm -rf build/' \
  'git reset --hard HEAD~1' \
  'git branch -D feature/x' \
  'git checkout -- .' \
  'git restore -- .' \
  'gh repo delete owner/repo --yes' \
  'gh release delete v1.0 --yes' \
  'gh pr merge 42 --admin --squash'; do
  it "action: destructive '$cmd' on live owned run -> deny"
  REPO="$(mk_live_owned "action-$(echo "$cmd" | tr -dc 'a-z')" actrun sess-AAA)"
  ev="$(EVENT sess-AAA Bash "$cmd")"
  out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
  assert_eq "deny" "$(perm_decision "$out")"
  it "action: destructive '$cmd' -> run PAUSED (driver=manual)"
  assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"
  it "action: destructive '$cmd' -> blocked_on recorded"
  case "$(rd_loop "$REPO" actrun blocked_on)" in
    *destructive*) pass ;;
    *) fail "blocked_on not recorded: $(rd_loop "$REPO" actrun blocked_on)" ;;
  esac
done

# ─── action: benign command -> allow, ledger untouched ────────────────────────
it "action: benign 'git status' on a live owned run -> allow"
REPO="$(mk_live_owned action-benign actrun sess-AAA)"
ev="$(EVENT sess-AAA Bash 'git status')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "action: benign command leaves driver==self (run untouched)"
assert_eq "self" "$(rd_loop "$REPO" actrun driver)"

# ─── action: benign pushes with dashed/short-flag-ish branch names -> allow ────
# The ordering-based force-push regex (fix-round-5 P1) must NOT false-positive on
# ordinary pushes whose branch name contains dashes or where an unrelated short
# flag (`-u`) appears — only a literal `--force`/`--force-with-lease`/`-f` flag is
# destructive. Regression guard for the round-5 widening.
for benign in 'git push origin my-feature' 'git push origin bugfix/foo' 'git push -u origin main' 'gh pr merge 42 --squash'; do
  it "action: benign '$benign' on a live owned run -> allow (no false-positive)"
  REPO="$(mk_live_owned "action-benignpush-$(echo "$benign" | tr -dc 'a-z')" actrun sess-AAA)"
  ev="$(EVENT sess-AAA Bash "$benign")"
  out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
  assert_empty "$out"
  it "action: benign '$benign' leaves driver==self (no pause)"
  assert_eq "self" "$(rd_loop "$REPO" actrun driver)"
done

# ─── action: destructive but MISMATCHED session_id -> allow, untouched (scope) ─
it "action: destructive command but mismatched session_id -> allow (scope: not our run)"
REPO="$(mk_live_owned action-mismatch actrun sess-AAA)"
ev="$(EVENT sess-OTHER Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "action: mismatched-session destructive leaves driver==self (no pause)"
assert_eq "self" "$(rd_loop "$REPO" actrun driver)"

# ─── action: a fired backstop appends a kind="action" audit record (KTD-5) ────
# driver-reference.md §Audit / SKILL.md §4.5 / ledger-schema §2.1 assert the
# action backstop appends its OWN advisor_audit record when it pauses — without
# it a fired backstop is invisible in the exit report (round-1 P1).
it "action: a destructive command on a live owned run appends ONE advisor_audit record"
REPO="$(mk_live_owned action-audit actrun sess-AAA)"
ev="$(EVENT sess-AAA Bash 'git push --force origin main')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "action audit: exactly one record appended"
assert_eq "1" "$(rd_audit "$REPO" actrun count)"
it "action audit: record kind == action"
assert_eq "action" "$(rd_audit "$REPO" actrun kind)"
it "action audit: classification is the destructive-pattern label"
case "$(rd_audit "$REPO" actrun classification)" in
  *push*) pass ;;
  *) fail "classification not the destructive label: $(rd_audit "$REPO" actrun classification)" ;;
esac

# ─── action: the backstop STAYS armed across a pause it caused (round-1 P0) ────
# A denied tool call does NOT end the agent's turn. The FIRST destructive
# command denies + flips the owned run to driver=manual; the SECOND from the
# same driving session MUST still be denied — the action gate must NOT couple to
# driver=="self" (it would self-disarm after firing once, then allow unlimited
# rm -rf / force-push). NO staleness workaround needed: round-2 P2 dropped the
# staleness conjunct from the ACTION hook entirely, so the freshly-init'd run is
# owned regardless of beat freshness (the stale-owned case is its own scenario
# below).
it "action: SECOND destructive command after a backstop-induced pause -> STILL deny"
REPO="$(mk_live_owned action-stayarmed actrun sess-AAA)"
ev1="$(EVENT sess-AAA Bash 'rm -rf build/')"
out1="$(printf '%s' "$ev1" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out1")"
it "action: first command DID pause the run (driver=manual)"
assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"
it "action: SECOND destructive command on the now-paused owned run -> STILL deny (no self-disarm)"
ev2="$(EVENT sess-AAA Bash 'git push --force origin main')"
out2="$(printf '%s' "$ev2" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out2")"
it "action: the backstop-induced pause armed loop.backstop_latched=True (P3-b mechanism)"
assert_eq "True" "$(rd_loop "$REPO" actrun backstop_latched)"

# ─── action P3-a: the PRODUCTION deny ALSO emits a loud operator systemMessage ─
# Parity with the deny-unsupported path: a normal (deny-supported) destructive
# match must surface a top-level `systemMessage` (a transcript-visible operator
# signal) ALONGSIDE the deny — confirmed against the CC hooks contract that
# systemMessage is not suppressed by a permissionDecision. Without it the deny
# only surfaced the agent-facing reason + a ledger pause (silent to an operator
# not watching the ledger — the P3-a finding).
it "action P3-a: production destructive deny emits a top-level systemMessage"
REPO="$(mk_live_owned action-sysmsg actrun sess-AAA)"
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "action P3-a: the systemMessage coexists with the deny and says RUN PAUSED"
case "$out" in *systemMessage*RUN\ PAUSED*) pass ;; *) fail "no loud systemMessage alongside deny: $out" ;; esac

# ═══════════════════════════════════════════════════════════════════════════
# action P3-b: the latch distinguishes a BACKSTOP pause from an OPERATOR pause
# ═══════════════════════════════════════════════════════════════════════════
# A backstop pause sets driver=manual + backstop_latched (sticky); an OPERATOR
# pause (auto-resume.py pause) sets driver=manual WITHOUT the latch. The action
# gate EXEMPTS the latter (the operator's own cleanup) but keeps firing on the
# former (no self-disarm) — and the latch is sticky even across an agent-run
# `auto-resume pause`, which is the door a text-only marker would have left open.
RESUME_PY="${AUTO_ROOT}/lib/auto-resume.py"

# (1) Operator pauses a HEALTHY run (no prior backstop fire) -> destructive ALLOWED.
it "action P3-b: operator pause of a healthy run -> driver=manual, NOT latched"
REPO="$(mk_live_owned action-oppause actrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RESUME_PY" pause actrun "operator cleanup" >/dev/null 2>&1
assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"
it "action P3-b: operator pause did NOT arm the backstop latch"
assert_eq "None" "$(rd_loop "$REPO" actrun backstop_latched)"
it "action P3-b: destructive cmd during an OPERATOR pause -> ALLOW (operator's own cleanup)"
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"

# (2) Backstop fires -> agent runs `auto-resume pause` -> destructive STILL denied.
it "action P3-b: agent-run \`auto-resume pause\` after a backstop fire keeps the latch"
REPO="$(mk_live_owned action-stickylatch actrun sess-AAA)"
ev1="$(EVENT sess-AAA Bash 'rm -rf build/')"
printf '%s' "$ev1" | "$PY" "$ACTION_PY" "$REPO" >/dev/null
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RESUME_PY" pause actrun "sneaky disarm attempt" >/dev/null 2>&1
assert_eq "True" "$(rd_loop "$REPO" actrun backstop_latched)"
it "action P3-b: destructive cmd after that pause -> STILL deny (latch closed the self-disarm door)"
ev2="$(EVENT sess-AAA Bash 'git push --force origin main')"
out2="$(printf '%s' "$ev2" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out2")"

# (3) A clean `auto-resume continue` clears the latch (forgiveness) so a LATER
# operator pause on the same run again allows the operator's own cleanup.
it "action P3-b: a clean \`auto-resume continue\` clears the latch"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-AAA" CLAUDE_CODE_CHILD_SESSION="" \
  "$PY" "$RESUME_PY" continue actrun >/dev/null 2>&1
assert_eq "None" "$(rd_loop "$REPO" actrun backstop_latched)"

# ─── action: a STALE owned run + destructive -> STILL deny+pause (round-2 P2) ──
# The fail-CLOSED invariant: the action hook must NOT couple to last_beat_at
# freshness. _pause_run does NOT re-stamp last_beat_at (set_loop without
# beat=True), so a run paused-by-backstop goes stale while the operator
# deliberates; if the action hook read stale->allow, a SECOND rm -rf would slip
# through. This primes the IDENTICAL stale ledger the askuser hook ALLOWS (lines
# ~228-246) but asserts the OPPOSITE: the action hook still DENIES + PAUSES. That
# contrast (same stale ledger: askuser allows / action denies) is the invariant.
# NO NO_STALENESS workaround — staleness is genuinely irrelevant to this hook now.
REPO="$(mkrepo action-stale)"
"$PY" - "$REPO" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json, datetime
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"staleact",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
old = (datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(seconds=L.DRIVER_SELF_STALE_SECONDS + 120)).strftime("%Y-%m-%dT%H:%M:%SZ")
p = L.ledger_path(repo,"staleact")
with open(p) as f: led = json.load(f)
led["loop"]["last_beat_at"] = old
led["loop"]["driver"] = "self"
led["driving_session_id"] = "sess-AAA"
with open(p,"w") as f: json.dump(led,f)
PYEOF
# Contrast control FIRST (before the action hook mutates the ledger): the
# askuser hook on this SAME stale self-driven ledger ALLOWS (fail-open) —
# staleness stays in the question hook.
it "contrast: askuser on the stale self-driven owned ledger -> ALLOW (fail-open; staleness kept here)"
out_q="$(printf '%s' "$(EVENT sess-AAA AskUserQuestion 'noop')" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out_q"
# Now the action hook on the IDENTICAL stale ledger DENIES + PAUSES (fail-closed).
it "action: a STALE self chain (>3900s) + destructive -> STILL deny (fail-closed, no staleness coupling)"
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "action: the STALE owned run is STILL paused (fail-closed despite stale beat)"
assert_eq "manual" "$(rd_loop "$REPO" staleact driver)"

# ─── action: FAIL-CLOSED under deny-unsupported -> systemMessage + still PAUSED ─
it "action FAIL-CLOSED: deny-unsupported hatch -> systemMessage (NOT empty) on destructive"
REPO="$(mk_live_owned action-failclosed actrun sess-AAA)"
ev="$(EVENT sess-AAA Bash 'git push --force')"
out="$(printf '%s' "$ev" | CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DENY_UNSUPPORTED=1 "$PY" "$ACTION_PY" "$REPO")"
assert_contains "$out" "systemMessage"
it "action FAIL-CLOSED: deny-unsupported emits NO permissionDecision (deny contract gone)"
assert_empty "$(perm_decision "$out")"
it "action FAIL-CLOSED: the run is STILL paused (fail closed, not allow)"
assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"

# ─── action: malformed ledger -> allow + exit 0 ───────────────────────────────
it "action: malformed ledger + destructive command -> allow (no crash)"
REPO="$(mkrepo action-malformed)"
printf '{ not valid json' > "${REPO}/.claude/auto/broken.json"
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "action.sh shim: malformed ledger -> exit 0 (rel-001)"
( cd "$REPO" && printf '%s' "$ev" | bash "$ACTION_SH" >/dev/null 2>&1 )
assert_eq "0" "$?"

# ─── action: a sibling NON-DICT ledger does NOT disarm the backstop ───────────
# load_ledger_safe folds in a dict-guard: a valid-JSON-but-non-dict ledger file
# (array/scalar) returns None and is SKIPPED by iter_worktree_ledgers — it must
# NOT abort the scan that finds the real owning ledger sitting beside it. If the
# scan ever propagated a non-dict through to `_owns_session` (AttributeError on
# `led.get(...)`) or stopped early on it, a single junk file in .claude/auto/
# would silently disarm the fail-closed destructive backstop. Pins the
# deliberate dict-guard behavior change at the security-load-bearing site.
it "action: a sibling non-dict ledger file does NOT disarm the destructive backstop -> still deny"
REPO="$(mk_live_owned action-nondict actrun sess-AAA)"
printf '[]' > "${REPO}/.claude/auto/junk.json"   # valid JSON, non-dict
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "action: non-dict sibling present -> the real owned run is STILL paused"
assert_eq "manual" "$(rd_loop "$REPO" actrun driver)"

# ─── action: Write content is NOT scanned (round-4 P2) ────────────────────────
# Write `content` is deliberately NOT classified: a driving-session ce-skill doc
# Write (a plan/review markdown quoting `rm -rf` as an example — this repo's
# CLAUDE.md lists the destructive set verbatim) must NOT pause the run. The Bash
# `command` channel is the load-bearing backstop; Write prose matching was nearly
# all false-positive cost in auto's own brainstorm/plan domain.
it "action: a Write whose content carries 'rm -rf' on a live owned run -> ALLOW (content not scanned)"
REPO="$(mk_live_owned action-write actrun sess-AAA)"
ev="$("$PY" -c "import json; print(json.dumps({'session_id':'sess-AAA','tool_name':'Write','tool_input':{'file_path':'deploy.sh','content':'#!/bin/sh\nrm -rf /tmp/x\n'}}))")"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "action: the Write content scan leaves driver==self (run untouched)"
assert_eq "self" "$(rd_loop "$REPO" actrun driver)"

# ════════════════════════════════════════════════════════════════════════════
# resume re-arm re-records the driving session (fix-round-6 P1)
# ════════════════════════════════════════════════════════════════════════════
# THE BUG: a run armed under session A, paused, then resumed from a DIFFERENT
# interactive session B (the common case: after a seam pause / crash / next-day
# fresh window) USED TO keep the stale arm-time driving_session_id=A. The
# re-armed run is self-driven again, but BOTH advisor gates match on
# driving_session_id == stdin.session_id — so under session B a destructive
# command never matched (A != B) and the action backstop fell through to ALLOW.
# The fix: auto-resume.py::_cmd_continue RE-records the driving session before
# re-arming. These tests drive the REAL auto-resume.py + the REAL action hook.
RESUME_PY="${AUTO_ROOT}/lib/auto-resume.py"

# Read the top-level driving_session_id off a ledger (the field the gates match).
rd_driving() {
  local repo="$1" run="$2"
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$repo','$run');print(l.get('driving_session_id') or '')"
}

# A blocked-paused run owned by session A (driver=manual + driving_session_id=A),
# mirroring auto-resume.py `pause` then a cross-session `continue`.
mk_paused_owned() {  # mk_paused_owned <name> <run> <sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1], sys.argv[2], sys.argv[3]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,run,adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,run,driver="manual",blocked_on="waiting on a human")
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

# ─── resume under session B re-records the driving session, gate follows ──────
it "resume: continue under a NEW session re-records driving_session_id (A -> B)"
REPO="$(mk_paused_owned resume-rearm rrun sess-AAA)"
# Sanity: armed under A.
assert_eq "sess-AAA" "$(rd_driving "$REPO" rrun)"
it "resume: re-arm flips driving_session_id to the resuming session B"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "sess-BBB" "$(rd_driving "$REPO" rrun)"
it "resume: a destructive command from the RESUMING session B -> deny (gate now owns it)"
ev="$(EVENT sess-BBB Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"
it "resume: the destructive command from session B PAUSES the run (backstop fired)"
assert_eq "manual" "$(rd_loop "$REPO" rrun driver)"

# ─── seam->work branch ALSO re-records (different write path) ─────────────────
# _cmd_continue records the session BEFORE branching, but seam->work routes
# through tick.advance_to_phase -> ledger.transition_and_emit (a DIFFERENT write
# path than the blocked-pause set_loop). transition_and_emit does an in-place
# locked RMW (it never reconstructs the dict), so the top-level
# driving_session_id survives the phase advance. This asserts that explicitly so
# a future refactor of the emit path can't silently reintroduce the P1 bug.
it "resume: seam-paused legacy run resumed under session B re-records the session through the seam->work path"
REPO="$(mkrepo resume-seam)"
"$PY" - "$REPO" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# Legacy ledger (recipe=None) so advance_to_phase falls through to the raw
# set_loop branch; a seam pause is the precondition for the seam->work flip.
L.init_ledger(repo,"seamrun",adapter="ce",loop_phase="seam",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"seamrun",driver="manual",seam_paused=True)
PYEOF
set_driving_session "$REPO" seamrun "sess-AAA"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue seamrun >/dev/null 2>&1
assert_eq "sess-BBB" "$(rd_driving "$REPO" seamrun)"
it "resume: the seam->work flip still advanced the phase (session re-record did not break the advance)"
assert_eq "work" "$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','seamrun')['loop_phase'])")"

# ─── regression guard: WITHOUT the fix, the stale id would let B through ──────
# Same destructive command but issued from the STALE arm-time session A: it must
# NOT match the re-armed run (the gate now owns B, not A), so it ALLOWS. This is
# the contrapositive proving the gate keyed off the freshly-recorded id.
it "resume: a command from the STALE arm-time session A -> allow (no longer owns the run)"
REPO="$(mk_paused_owned resume-staleA rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" env -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
ev="$(EVENT sess-AAA Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"

# ─── refuse to re-arm when the driving session cannot be determined ───────────
# None must NEVER reach set_driving_session_id (None CLEARS the field => both
# gates fail OPEN). With no CLAUDE_CODE_SESSION_ID, _cmd_continue refuses: leaves
# the run paused (driver=manual, driving_session_id UNCHANGED), exits non-zero.
it "resume: refuse to re-arm when CLAUDE_CODE_SESSION_ID is unset -> exit non-zero"
REPO="$(mk_paused_owned resume-norearm rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "1" "$?"
it "resume: refusal leaves the run PAUSED (driver=manual, not flipped to self)"
assert_eq "manual" "$(rd_loop "$REPO" rrun driver)"
it "resume: refusal does NOT clear driving_session_id (no fail-open)"
assert_eq "sess-AAA" "$(rd_driving "$REPO" rrun)"
# v0.6.4: CHILD_SESSION truthy is the NORMAL case (the harness sets it in every
# Bash-tool subprocess, where auto-resume.sh runs). With a real session id present,
# resume must PROCEED and re-record THIS session as the owner — not refuse.
it "resume: CHILD_SESSION set WITH a real id re-arms (exit 0), re-records the new owner"
REPO="$(mk_paused_owned resume-childproceed rrun sess-AAA)"
CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID="sess-BBB" CLAUDE_CODE_CHILD_SESSION="1" \
  "$PY" "$RESUME_PY" continue rrun >/dev/null 2>&1
assert_eq "0" "$?"
it "resume: re-arm re-records driving_session_id to the resuming session"
assert_eq "sess-BBB" "$(rd_driving "$REPO" rrun)"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "advisor-gate.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
