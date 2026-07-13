#!/usr/bin/env bash
# auto U5 unit test: the advisor-gate decision audit + driving_session_id.
#
# SELF-CONTAINED inline harness (same style as ledger-mutators.test.sh /
# producers.test.sh). Shells into Python via _bootstrap.load_lib_module against
# the REAL ledger facade — nothing mocked except a sandbox tmp repo.
#
# Scenarios (U5 plan):
#   1. init_ledger records driving_session_id at arm time; absent => null.
#   2. set_driving_session_id round-trips; None clears the field.
#   3. append_advisor_audit round-trips both kinds (advisor + action), each
#      timestamped; the records survive a subsequent predicate recompute (I-1).
#   4. The audit mutator routes through the LOCKED atomic-write path — a
#      concurrent record_verdict landing between two audit appends does NOT
#      clobber the list (all three writes are observed).
#   5. Validation: bad kind / empty field / non-string session_id -> LedgerError.
#   6. Both new mutators are re-exported through the ledger FACADE (ledger.py).
#   7. Doc-content checks on skills/auto/SKILL.md + commands/auto.md:
#      escalation rule, pause routing, audit surfacing, and the fan-out
#      two-handoff instruction carrying BOTH (i) question-routing AND
#      (ii) destructive-action avoidance.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SKILL_MD="${AUTO_ROOT}/skills/auto/SKILL.md"
CMD_MD="${AUTO_ROOT}/commands/auto.md"
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
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

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

REPO="${SANDBOX}/repo"
mkdir -p "${REPO}/.claude/auto"

echo "advisor-audit.test.sh"

# ════════════════════════════════════════════════════════════════════════════
# Scenarios 1-6 run inside ONE Python driver (the deterministic ledger surface).
# It prints a "tag=value" line per assertion; bash asserts on each.
# ════════════════════════════════════════════════════════════════════════════
out="$("$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF'
import sys, os
auto_root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_ledger
ledger = load_ledger()

def emit(tag, val):
    print(f"{tag}={val}")

# ── 1. init records driving_session_id at arm time ──────────────────────────
ledger.init_ledger(repo, "armed", backend="ce", loop_phase="work",
                   units=[{"id": "U1", "state": "pending"}],
                   driving_session_id="sess-ARM")
L = ledger.read_ledger(repo, "armed")
emit("init_sid", L.get("driving_session_id"))

# init WITHOUT the kwarg => field present and null (always-present field).
ledger.init_ledger(repo, "noarm", backend="ce", loop_phase="work",
                   units=[{"id": "U1", "state": "pending"}])
L = ledger.read_ledger(repo, "noarm")
emit("noarm_has_key", "driving_session_id" in L)
emit("noarm_sid", L.get("driving_session_id"))

# ── 2. setter round-trip + None clears ──────────────────────────────────────
ledger.set_driving_session_id(repo, "noarm", "sess-SET")
emit("set_sid", ledger.read_ledger(repo, "noarm").get("driving_session_id"))
ledger.set_driving_session_id(repo, "noarm", None)
emit("cleared_absent", "driving_session_id" not in ledger.read_ledger(repo, "noarm"))

# ── 3. append_advisor_audit both kinds, timestamped ─────────────────────────
ledger.append_advisor_audit(repo, "armed", kind="advisor",
    subject="which output directory?", classification="mechanical",
    resolution="resolved-autonomously")
ledger.append_advisor_audit(repo, "armed", kind="action",
    subject="git push --force origin main", classification="git push --force / -f / --force-with-lease",
    resolution="blocked-and-paused")
L = ledger.read_ledger(repo, "armed")
aud = L.get("advisor_audit", [])
emit("audit_len", len(aud))
emit("audit0_kind", aud[0]["kind"])
emit("audit1_kind", aud[1]["kind"])
emit("audit0_has_at", "at" in aud[0] and bool(aud[0]["at"]))
emit("audit0_class", aud[0]["classification"])

# ── 3b. records survive a predicate recompute (I-1) ─────────────────────────
before = list(ledger.read_ledger(repo, "armed").get("advisor_audit", []))
# record_verdict forces a recompute in the same atomic snapshot.
ledger.transition(repo, "armed", "U1", "dispatched")
ledger.record_verdict(repo, "armed", "U1", [{"severity": "blocker", "note": "x"}])
after = list(ledger.read_ledger(repo, "armed").get("advisor_audit", []))
emit("audit_survives_recompute", before == after and len(after) == 2)

# ── 4. concurrent record_verdict between appends does not clobber the list ───
# Init a run, append one audit, do an unrelated locked write, append another:
# all three end states must coexist (the append-inside-the-lock contract).
ledger.init_ledger(repo, "concur", backend="ce", loop_phase="work",
                   units=[{"id": "V1", "state": "pending"}],
                   driving_session_id="sess-C")
ledger.append_advisor_audit(repo, "concur", kind="advisor",
    subject="q1", classification="mechanical", resolution="resolved-autonomously")
ledger.transition(repo, "concur", "V1", "dispatched")        # interleaved locked write
ledger.record_verdict(repo, "concur", "V1", [])              # another locked write
ledger.append_advisor_audit(repo, "concur", kind="action",
    subject="rm -rf build/", classification="rm -rf", resolution="blocked-and-paused")
L = ledger.read_ledger(repo, "concur")
emit("concur_audit_len", len(L.get("advisor_audit", [])))
emit("concur_unit_state", L["steps"][0]["state"])

# ── 5. validation rejections ────────────────────────────────────────────────
def rejects(fn):
    try:
        fn(); return False
    except ledger.LedgerError:
        return True

emit("reject_bad_kind", rejects(lambda: ledger.append_advisor_audit(
    repo, "armed", kind="bogus", subject="s", classification="c", resolution="r")))
emit("reject_empty_subject", rejects(lambda: ledger.append_advisor_audit(
    repo, "armed", kind="advisor", subject="", classification="c", resolution="r")))
emit("reject_nonstr_sid", rejects(lambda: ledger.set_driving_session_id(
    repo, "armed", 123)))

# ── 6. facade re-exports ────────────────────────────────────────────────────
emit("facade_set", hasattr(ledger, "set_driving_session_id"))
emit("facade_append", hasattr(ledger, "append_advisor_audit"))
PYEOF
)"

# Pull a tag's value out of the driver output.
g() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2-; }

it "init_ledger records driving_session_id at arm time"
assert_eq "sess-ARM" "$(g init_sid)"
it "init without the kwarg => field present"
assert_eq "True" "$(g noarm_has_key)"
it "init without the kwarg => field is null"
assert_eq "None" "$(g noarm_sid)"
it "set_driving_session_id round-trips"
assert_eq "sess-SET" "$(g set_sid)"
it "set_driving_session_id(None) clears the field"
assert_eq "True" "$(g cleared_absent)"

it "append_advisor_audit appends both kinds"
assert_eq "2" "$(g audit_len)"
it "audit record 0 is the advisor kind"
assert_eq "advisor" "$(g audit0_kind)"
it "audit record 1 is the action kind"
assert_eq "action" "$(g audit1_kind)"
it "audit records are timestamped"
assert_eq "True" "$(g audit0_has_at)"
it "audit record preserves the classification field"
assert_eq "mechanical" "$(g audit0_class)"
it "audit records survive a subsequent predicate recompute (I-1)"
assert_eq "True" "$(g audit_survives_recompute)"

it "interleaved locked writes do not clobber the audit list (concurrent-safe)"
assert_eq "2" "$(g concur_audit_len)"
it "interleaved record_verdict still landed (the audit append is on the locked path)"
assert_eq "verdict-returned" "$(g concur_unit_state)"

it "append_advisor_audit rejects a bad kind"
assert_eq "True" "$(g reject_bad_kind)"
it "append_advisor_audit rejects an empty subject"
assert_eq "True" "$(g reject_empty_subject)"
it "set_driving_session_id rejects a non-string id"
assert_eq "True" "$(g reject_nonstr_sid)"

it "ledger facade re-exports set_driving_session_id"
assert_eq "True" "$(g facade_set)"
it "ledger facade re-exports append_advisor_audit"
assert_eq "True" "$(g facade_append)"

# ════════════════════════════════════════════════════════════════════════════
# Scenario 7: doc-content checks (mirror existing SKILL doc-lint tests — grep
# for the load-bearing phrases the U5 prose MUST carry).
# ════════════════════════════════════════════════════════════════════════════
has() { grep -qi -- "$2" "$1" && pass || fail "'$1' missing: $2"; }

it "SKILL.md documents consulting the advisor on a denied question"
has "$SKILL_MD" "advisor"
it "SKILL.md documents the mechanical -> resolve / fork -> escalate classification"
grep -qi "mechanical" "$SKILL_MD" && grep -qi "fork" "$SKILL_MD" && pass \
  || fail "SKILL.md missing mechanical/fork classification"
it "SKILL.md documents pause-handoff escalation for design forks"
has "$SKILL_MD" "auto-resume.py pause"
it "SKILL.md documents surfacing the advisor/action audit in the exit report"
grep -qi "advisor_audit" "$SKILL_MD" && grep -qi "exit report" "$SKILL_MD" && pass \
  || fail "SKILL.md missing audit-surfacing in exit report"
it "SKILL.md documents append_advisor_audit as the logging mutator"
has "$SKILL_MD" "append_advisor_audit"

# The two-handoff (ii) requirement: the fan-out unit prompt MUST carry BOTH
# question-routing AND destructive-action avoidance.
it "SKILL.md fan-out instruction carries (i) question routing for fan-out units"
grep -qi "do not call" "$SKILL_MD" && grep -qi "AskUserQuestion" "$SKILL_MD" && pass \
  || fail "SKILL.md missing fan-out question-routing instruction"
it "SKILL.md fan-out instruction carries (ii) destructive-action avoidance"
grep -qi "destructive" "$SKILL_MD" \
  && grep -qi "rm -rf" "$SKILL_MD" \
  && grep -qi "push --force" "$SKILL_MD" && pass \
  || fail "SKILL.md missing fan-out destructive-action constraint"
it "SKILL.md names the two-handoff split for fan-out units"
grep -qi "two-handoff" "$SKILL_MD" && pass || fail "SKILL.md missing two-handoff split mention"

it "commands/auto.md adds advisor to allowed-tools"
grep -qE "^allowed-tools:.*\badvisor\b" "$CMD_MD" && pass \
  || fail "commands/auto.md allowed-tools missing advisor"
it "commands/auto.md documents the advisor gate"
has "$CMD_MD" "advisor gate"

# ════════════════════════════════════════════════════════════════════════════
# Scenario 8: lib/auto.py::_driving_session_id() — the arm-time read. v0.6.4
# REMOVED the CLAUDE_CODE_CHILD_SESSION guard: the harness sets that var in EVERY
# Bash-tool subprocess (where arm/resume always run), so the old guard returned
# None unconditionally — the backstop was dark on every run and resume refused.
# The session id (CLAUDE_CODE_SESSION_ID) is now trusted directly; it equals the
# PreToolUse hook's stdin session_id. Drive the REAL function under controlled env.
DSID_PY="
import sys, os
sys.path.insert(0, os.path.join('$AUTO_ROOT', 'lib'))
from _bootstrap import load_lib_module
auto = load_lib_module('auto')
r = auto._driving_session_id()
print(r if r is not None else 'NONE')
"

it "_driving_session_id: CLAUDE_CODE_SESSION_ID set, no child -> returns the id"
out_sid="$(env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID="sess-LIVE" "$PY" -c "$DSID_PY")"
assert_eq "sess-LIVE" "$out_sid"

it "_driving_session_id: CLAUDE_CODE_CHILD_SESSION truthy STILL returns the id (v0.6.4 — guard removed)"
out_child="$(env CLAUDE_CODE_SESSION_ID="sess-LIVE" CLAUDE_CODE_CHILD_SESSION="1" "$PY" -c "$DSID_PY")"
assert_eq "sess-LIVE" "$out_child"

it "_driving_session_id: env unset -> returns None"
out_unset="$(env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID "$PY" -c "$DSID_PY")"
assert_eq "NONE" "$out_unset"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "advisor-audit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
