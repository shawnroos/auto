#!/usr/bin/env bash
# auto U8 integration test: PreToolUse ownership CHAIN (R21 / AE7 / KTD-7).
#
# The loop's phase work moves into background sub-agents, which carry their OWN
# CLAUDE_CODE_SESSION_ID. Both PreToolUse hooks previously matched a SCALAR
# `driving_session_id`, so neither fired inside the tree — the `fix` phase writes
# code and runs Bash, and it would have run with only prompt-carried (advisory)
# constraints. U8 turns ownership into a SET: a dispatched sub-agent registers its
# session id on the ledger, and the hooks test membership.
#
# Exercises the REAL hooks + REAL ledger, exactly as advisor-gate.test.sh does.
# Nothing is mocked; the only injection points are the sandbox repo and the
# PreToolUse event JSON on stdin.
#
# THE HAZARD THIS FILE EXISTS TO PIN DOWN (found while reading on-pretooluse-
# action.py:359-373): the action gate has an OPERATOR-PAUSE EXEMPTION — a run the
# human paused (driver=="manual" without backstop_latched) ALLOWS destructive
# commands, because the only actor issuing tool calls then is the operator doing
# their own cleanup. A naive widening of the identity match would extend that
# exemption to registered sub-agents, letting an in-flight sub-agent run `rm -rf`
# during an operator pause. A sub-agent is NEVER the operator. The exemption must
# stay scoped to the DRIVING session alone. Scenario 5 is the regression.
#
# Scenarios:
#   1. AE7  registered sub-agent + destructive -> deny + run PAUSED (fail-CLOSED)
#   2.      unregistered session + destructive -> allow, ledger untouched
#           (no cross-session capture of an unrelated Claude session)
#   3.      registered sub-agent + benign command -> allow
#   4.      driving session still gated (no regression of the scalar behaviour)
#   5. HAZARD operator-pause exemption is scoped to the DRIVING session:
#           - driving session + destructive during operator pause -> allow
#           - registered SUB-AGENT + destructive during operator pause -> DENY
#   6.      question gate widens to the tree (registered sub-agent -> deny+redirect)
#   7.      question gate still fails OPEN (malformed ledger -> allow, exit 0)
#   8.      action gate still fails CLOSED (deny-unsupported hatch -> pause anyway)
#   9.      register_session is idempotent and does not clobber driving_session_id

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
ASKUSER_PY="${AUTO_ROOT}/lib/on-pretooluse-askuser.py"
ACTION_PY="${AUTO_ROOT}/lib/on-pretooluse-action.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

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

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in */auto-test.*) rm -rf "$SANDBOX" ;; esac
}
trap cleanup EXIT

mkrepo() { local repo="${SANDBOX}/repo-${1}"; mkdir -p "${repo}/.claude/auto"; printf '%s' "$repo"; }

EVENT() {  # EVENT <session_id> <tool_name> <command>
  "$PY" -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'command':sys.argv[3]}}))" "$1" "$2" "$3"
}

perm_decision() {
  "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get('hookSpecificOutput',{}).get('permissionDecision',''))
except Exception:
    print('')" "$1"
}

rd_loop() {  # rd_loop <repo> <run> <field>
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$1','$2');print(l['loop'].get('$3'))"
}

set_driving_session() {  # <repo> <run> <sid>
  "$PY" - "$1" "$2" "$3" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, sid, ledger_py = sys.argv[1:5]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
p = L.ledger_path(repo, run)
with open(p) as f: led = json.load(f)
led["driving_session_id"] = sid
with open(p,"w") as f: json.dump(led,f)
PYEOF
}

# The U8 verb under test. A dispatched sub-agent calls this to join the owner set.
register_session() {  # <repo> <run> <sid>
  "$PY" - "$1" "$2" "$3" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, sid, ledger_py = sys.argv[1:5]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.register_session(repo, run, sid)
PYEOF
}

read_owners() {  # <repo> <run>
  "$PY" - "$1" "$2" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, ledger_py = sys.argv[1:4]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
led = L.read_ledger(repo, run)
print(json.dumps(led.get("agent_session_ids") or []))
PYEOF
}

mk_live_owned() {  # <name> <run> <driving-sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,run,backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

operator_pause() {  # <repo> <run> — a HUMAN pause: driver=manual, no backstop latch
  "$PY" - "$1" "$2" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, ledger_py = sys.argv[1:4]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
p = L.ledger_path(repo, run)
with open(p) as f: led = json.load(f)
led["loop"]["driver"] = "manual"
led["loop"].pop("backstop_latched", None)
with open(p,"w") as f: json.dump(led,f)
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "tree-ownership.test.sh"

# ─── 1. AE7: registered sub-agent + destructive -> deny + PAUSE ───────────────
it "AE7: registered sub-agent + destructive -> deny (fail-CLOSED)"
REPO="$(mk_live_owned reg-deny r1 sess-BOSS)"
register_session "$REPO" r1 sess-KID
ev="$(EVENT sess-KID Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

it "AE7: the run is PAUSED by the sub-agent's destructive attempt"
assert_eq "manual" "$(rd_loop "$REPO" r1 driver)"

# ─── 2. unregistered session -> allow (no cross-session capture) ──────────────
it "unregistered session + destructive -> allow (no cross-session capture)"
REPO="$(mk_live_owned unreg r2 sess-BOSS)"
ev="$(EVENT sess-STRANGER Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"
it "unregistered session leaves the ledger untouched (driver still self)"
assert_eq "self" "$(rd_loop "$REPO" r2 driver)"

# ─── 3. registered sub-agent + benign -> allow ────────────────────────────────
it "registered sub-agent + benign command -> allow"
REPO="$(mk_live_owned reg-benign r3 sess-BOSS)"
register_session "$REPO" r3 sess-KID
ev="$(EVENT sess-KID Bash 'ls -la')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"

# ─── 4. driving session still gated (no regression) ──────────────────────────
it "driving session + destructive -> deny (scalar behaviour preserved)"
REPO="$(mk_live_owned drv r4 sess-BOSS)"
ev="$(EVENT sess-BOSS Bash 'git push origin main --force')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

# ─── 5. HAZARD: operator-pause exemption is DRIVING-SESSION-ONLY ──────────────
# The exemption exists so the operator's own cleanup is not gated during a pause
# they initiated. A sub-agent is never the operator.
it "operator pause: the DRIVING session's destructive command is allowed (exemption holds)"
REPO="$(mk_live_owned exempt-drv r5 sess-BOSS)"
register_session "$REPO" r5 sess-KID
operator_pause "$REPO" r5
ev="$(EVENT sess-BOSS Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_empty "$out"

it "operator pause: a registered SUB-AGENT's destructive command is STILL DENIED"
ev="$(EVENT sess-KID Bash 'rm -rf build/')"
out="$(printf '%s' "$ev" | "$PY" "$ACTION_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

# ─── 6. question gate widens to the tree ─────────────────────────────────────
it "askuser: registered sub-agent -> deny + advisor redirect"
REPO="$(mk_live_owned q-reg r6 sess-BOSS)"
register_session "$REPO" r6 sess-KID
ev="$(EVENT sess-KID AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

# ─── 7. question gate still fails OPEN ───────────────────────────────────────
it "askuser still fails OPEN: malformed ledger -> allow"
REPO="$(mkrepo q-malformed)"
printf '{ not valid json' > "${REPO}/.claude/auto/broken.json"
ev="$(EVENT sess-KID AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"
it "askuser still exits 0 on a malformed ledger (rel-001)"
printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO" >/dev/null 2>&1
assert_eq "0" "$?"

# ─── 8. action gate still fails CLOSED for a registered sub-agent ─────────────
it "action still fails CLOSED for the tree: deny-unsupported -> systemMessage"
REPO="$(mk_live_owned failclosed r8 sess-BOSS)"
register_session "$REPO" r8 sess-KID
ev="$(EVENT sess-KID Bash 'git push --force')"
out="$(printf '%s' "$ev" | CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DENY_UNSUPPORTED=1 "$PY" "$ACTION_PY" "$REPO")"
assert_contains "$out" "systemMessage"
it "action fail-CLOSED: the run is paused even without the deny contract"
assert_eq "manual" "$(rd_loop "$REPO" r8 driver)"

# ─── 9. register_session hygiene ─────────────────────────────────────────────
it "register_session is idempotent (no duplicate entries)"
REPO="$(mk_live_owned idem r9 sess-BOSS)"
register_session "$REPO" r9 sess-KID
register_session "$REPO" r9 sess-KID
assert_eq '["sess-KID"]' "$(read_owners "$REPO" r9)"

it "register_session does not clobber driving_session_id"
assert_eq "deny" "$(perm_decision "$(printf '%s' "$(EVENT sess-BOSS Bash 'rm -rf x/')" | "$PY" "$ACTION_PY" "$REPO")")"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "tree-ownership.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
