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

rm -rf "$REPO"
echo ""
echo "ledger-cli-feedback.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
