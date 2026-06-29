#!/usr/bin/env bash
# auto v0.4.3 unit test: the plan-loop FEEDBACK CLI surface — set-gaps-open and
# set-enumerated-units (project_auto_v042_stuck_root_causes ④).
#
# WHY THIS TEST EXISTS: the model drives the plan-loop through Bash — its only
# ledger-write tool is `lib/ledger.sh`, NOT the Python mutators. Before v0.4.3
# the CLI exposed only read/path/transition/is-orphaned, so the operator-guidance
# instructions to "set_gaps_open" / "enumerate" named functions the model could
# not invoke — the same uninvokable-instruction bug class as the missing
# /auto-tick command. This test asserts both feedback subcommands exist, persist
# correctly, resolve the repo from $CLAUDE_AUTO_REPO (so the model passes only the
# run-id), and reject malformed input — so the channel can't silently regress.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LEDGER_SH="${AUTO_ROOT}/lib/ledger.sh"

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

# Hermetic repo with one plan-phase unit on the ledger.
REPO="$(mktemp -d)"
export CLAUDE_AUTO_REPO="$REPO"
mkdir -p "$REPO/.claude/auto"
"$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF'
import sys, os, importlib.util
auto_root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
ledger.init_ledger(repo, "rF", adapter="ce",
                   units=[{"id":"plan","phase":"plan","invokes":{"adapter_op":"next_plan_step"}}],
                   loop_phase="plan")
PYEOF

read_field() {  # read_field <python-expr-over-led>
  "$PY" - "$AUTO_ROOT" "$REPO" "$1" <<'PYEOF'
import sys, os, importlib.util, json
auto_root, repo, expr = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
led = ledger.read_ledger(repo, "rF")
print(eval(expr))
PYEOF
}

# ─── set-enumerated-units persists via the CLI (repo auto-resolved) ──────────
it "ledger.sh set-enumerated-units persists onto the plan unit (run-id only)"
bash "$LEDGER_SH" set-enumerated-units rF plan '[{"id":"w1","invokes":{"adapter_op":"do_unit"}}]' >/dev/null 2>&1
got="$(read_field '[u for u in led["units"] if u["phase"]=="plan"][0]["dispatch_context"].get("enumerated_units")')"
case "$got" in
  *"w1"*) pass ;;
  *) fail "enumerated_units not persisted via CLI: ${got}" ;;
esac

# ─── set-gaps-open persists via the CLI ─────────────────────────────────────
it "ledger.sh set-gaps-open persists the gap count (run-id only)"
bash "$LEDGER_SH" set-gaps-open rF 0 >/dev/null 2>&1
got_g="$(read_field 'led["exit_predicate_result"]["gaps_open"]')"
[ "$got_g" = "0" ] && pass || fail "gaps_open not 0 after CLI set-gaps-open: ${got_g}"

# ─── deliberate-fail: malformed enumerate payload is rejected (non-zero) ─────
it "deliberate-fail: a non-array enumerate payload is rejected (rc != 0)"
if bash "$LEDGER_SH" set-enumerated-units rF plan '{"not":"an array"}' >/dev/null 2>&1; then
  fail "non-array payload was accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: unknown subcommand still rejected (guards the dispatch) ─
it "deliberate-fail: an unknown ledger subcommand is rejected (rc != 0)"
if bash "$LEDGER_SH" set-bogus rF 0 >/dev/null 2>&1; then
  fail "unknown subcommand was accepted"
else
  pass
fi

# ════════════════════════════════════════════════════════════════════════════
# Work-loop VERDICT channel (v0.6.8) — record-verdict / set-verdict-decision.
# Same uninvokable-instruction bug class as the v0.4.3 feedback verbs: the
# work-loop drives through Bash, so the verdict + gate-decision mutators must be
# reachable as CLI verbs, repo auto-resolved from $CLAUDE_AUTO_REPO.
# ════════════════════════════════════════════════════════════════════════════

# record_verdict only writes from a dispatched/verdict-returned/stalled unit, so
# move the seed plan unit to dispatched first (transition takes an explicit repo).
bash "$LEDGER_SH" transition "$REPO" rF plan dispatched >/dev/null 2>&1

# ─── record-verdict round-trips findings into the ledger (run-id only) ───────
it "ledger.sh record-verdict persists findings + flips the unit to verdict-returned"
bash "$LEDGER_SH" record-verdict rF plan '[{"severity":"blocker","note":"boom"}]' >/dev/null 2>&1
got_state="$(read_field '[u for u in led["units"] if u["id"]=="plan"][0]["state"]')"
got_note="$(read_field '[u for u in led["units"] if u["id"]=="plan"][0]["findings"][0]["note"]')"
if [ "$got_state" = "verdict-returned" ] && [ "$got_note" = "boom" ]; then
  pass
else
  fail "record-verdict did not persist (state=${got_state} note=${got_note})"
fi

# ─── set-verdict-decision persists the gate decision (run-id only) ───────────
it "ledger.sh set-verdict-decision persists dispatch_context.decision (run-id only)"
bash "$LEDGER_SH" set-verdict-decision rF plan advance >/dev/null 2>&1
got_dec="$(read_field '[u for u in led["units"] if u["id"]=="plan"][0]["dispatch_context"].get("decision")')"
[ "$got_dec" = "advance" ] && pass || fail "decision not persisted via CLI: ${got_dec}"

# ─── set-verdict-decision carries an optional JSON payload ───────────────────
it "ledger.sh set-verdict-decision persists an optional decision_payload"
bash "$LEDGER_SH" set-verdict-decision rF plan iterate '{"emit_count":2}' >/dev/null 2>&1
got_pl="$(read_field '[u for u in led["units"] if u["id"]=="plan"][0]["dispatch_context"]["decision_payload"]["emit_count"]')"
[ "$got_pl" = "2" ] && pass || fail "decision_payload not persisted: ${got_pl}"

# ─── deliberate-fail: non-array findings rejected (rc != 0) ──────────────────
it "deliberate-fail: record-verdict with non-array findings is rejected (rc != 0)"
if bash "$LEDGER_SH" record-verdict rF plan '{"not":"array"}' >/dev/null 2>&1; then
  fail "non-array findings accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: invalid finding severity rejected (rc != 0) ────────────
it "deliberate-fail: record-verdict with an invalid severity is rejected (rc != 0)"
if bash "$LEDGER_SH" record-verdict rF plan '[{"severity":"bogus","note":"x"}]' >/dev/null 2>&1; then
  fail "invalid severity accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: decision not in the enum rejected (rc != 0) ────────────
it "deliberate-fail: set-verdict-decision with a non-enum decision is rejected (rc != 0)"
if bash "$LEDGER_SH" set-verdict-decision rF plan bogus >/dev/null 2>&1; then
  fail "non-enum decision accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: unknown gate unit rejected (rc != 0) ───────────────────
it "deliberate-fail: set-verdict-decision on an unknown unit is rejected (rc != 0)"
if bash "$LEDGER_SH" set-verdict-decision rF nosuchunit advance >/dev/null 2>&1; then
  fail "unknown unit accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: non-dict decision payload rejected (rc != 0) ───────────
it "deliberate-fail: set-verdict-decision with a non-object payload is rejected (rc != 0)"
if bash "$LEDGER_SH" set-verdict-decision rF plan advance '[1,2]' >/dev/null 2>&1; then
  fail "non-object decision payload accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: non-integer record-verdict attempt rejected (rc != 0) ──
it "deliberate-fail: record-verdict with a non-integer attempt is rejected (rc != 0)"
if bash "$LEDGER_SH" record-verdict rF plan '[{"severity":"minor","note":"x"}]' notanint >/dev/null 2>&1; then
  fail "non-integer attempt accepted (should have failed)"
else
  pass
fi

rm -rf "$REPO"
echo ""
echo "ledger-cli-feedback.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
