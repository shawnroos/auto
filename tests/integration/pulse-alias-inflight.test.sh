#!/usr/bin/env bash
# auto integration test: the DEPRECATED pre-rename entry points still drive an
# IN-FLIGHT run (concept-vocabulary rename U5, KTD-4).
#
# WHY THIS TEST EXISTS:
# The rename made `/auto:auto-pulse` + `lib/pulse.sh` canonical. But a run armed
# BEFORE the rename has the OLD prompt `/auto:auto-tick <run>` already persisted
# inside its ScheduleWakeup (and in stale rearm-intent JSON on disk). When that
# wakeup fires, the harness resolves `commands/auto-tick.md` — if that file were
# deleted, or if it still dispatched the now-gone `lib/tick.sh` implementation,
# the in-flight run would wedge: "Unknown command", chain dead, no operator
# signal. Agents/scripts with the memorized `lib/tick.sh` path have the same
# exposure.
#
# So both legacy entries are KEPT for one minor version and must be PROVEN live,
# not merely present:
#   1. the canonical path emits the NEW rearm prompt (/auto:auto-pulse <run>);
#   2. the ALIAS COMMAND (commands/auto-tick.md — its dispatch line extracted from
#      the .md body and executed the way the harness would) ADVANCES a real run;
#   3. the STUB (lib/tick.sh) ADVANCES a real run and forwards to pulse.sh;
#   4. both legacy paths hand back the NEW prompt, so an in-flight run MIGRATES
#      itself onto /auto:auto-pulse on its very next beat;
#   5. the stub's deprecation notice goes to STDERR only — stdout stays the clean
#      single-JSON intent the driving model parses.
#
# A grep-only assertion ("the file exists") would not catch an alias that
# dispatches a dead path, so each legacy entry is driven END-TO-END against a
# real run record and the resulting state transition is asserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PULSE_SH="${AUTO_ROOT}/lib/pulse.sh"
STUB_SH="${AUTO_ROOT}/lib/tick.sh"
ALIAS_MD="${AUTO_ROOT}/commands/auto-tick.md"
CANON_MD="${AUTO_ROOT}/commands/auto-pulse.md"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness (mirrors tests/unit/pulse.test.sh) ──────────
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
mkdir -p "$REPO"

# init <run> — a work-loop run record with ONE step whose verdict is back and
# whose finding is still open: the predicate is NOT met, so a pulse applies one
# fix (verdict-returned -> fixed) and signals re-arm. That state flip is the
# "did this entry point actually advance the run?" discriminator below.
run_record_init() {
  "$PY" - "$REPO" "$1" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_run_record(
    repo, run, backend="ce", loop_phase="work",
    steps=[{"id": "U1", "state": "verdict-returned",
            "findings": [{"severity": "blocker", "note": "open"}]}],
)
PYEOF
}

step_state() {
  "$PY" - "$REPO" "$1" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.read_run_record(repo, run)["steps"][0]["state"])
PYEOF
}

# jget <json> <key> — read one key out of the emitted intent.
jget() { "$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }

echo "pulse-alias-inflight.test.sh"

# ─── Scenario 1: the canonical entry emits the NEW rearm prompt ──────────────
it "canonical lib/pulse.sh advances the run and rearms with /auto:auto-pulse"
run_record_init "canonrun"
canon_out="$(CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "canonrun" 2>/dev/null)"
if [ "$(jget "$canon_out" action)" = "rearm" ] \
   && [ "$(jget "$canon_out" prompt)" = "/auto:auto-pulse canonrun" ] \
   && [ "$(step_state canonrun)" = "fixed" ]; then
  pass
else
  fail "action=$(jget "$canon_out" action) prompt=$(jget "$canon_out" prompt) state=$(step_state canonrun)"
fi

# ─── Scenario 2: the KEPT ALIAS COMMAND drives an in-flight run ──────────────
# Simulate the harness firing the persisted `/auto:auto-tick <run>`: pull the
# dispatch line out of commands/auto-tick.md (the same line the harness runs
# after substituting $ARGUMENTS) and execute it with CLAUDE_PLUGIN_ROOT set.
# This proves the alias body points at a LIVE implementation, not a dead path.
it "commands/auto-tick.md exists (the persisted in-flight rearm target)"
[ -f "$ALIAS_MD" ] && pass || fail "alias command file missing — in-flight runs wedge"

it "the alias's dispatch line is extractable and names lib/pulse.sh"
alias_line="$(grep -oE 'bash "\$\{CLAUDE_PLUGIN_ROOT\}/lib/[a-z.-]+" "\$ARGUMENTS"' "$ALIAS_MD" | head -1)"
case "$alias_line" in
  *'/lib/pulse.sh"'*) pass ;;
  *) fail "alias dispatch line does not invoke lib/pulse.sh: ${alias_line:-<none>}" ;;
esac

it "firing the OLD /auto:auto-tick command path ADVANCES an in-flight run"
run_record_init "aliasrun"
CLAUDE_PLUGIN_ROOT="$AUTO_ROOT"
ARGUMENTS="aliasrun --repo ${REPO}"
export CLAUDE_PLUGIN_ROOT ARGUMENTS
# shellcheck disable=SC2086 — deliberately eval the .md's own dispatch line.
alias_out="$(eval "$alias_line" 2>/dev/null)"
alias_state="$(step_state aliasrun)"
if [ "$(jget "$alias_out" action)" = "rearm" ] && [ "$alias_state" = "fixed" ]; then
  pass
else
  fail "alias command did not advance the run: action=$(jget "$alias_out" action) state=${alias_state}"
fi

it "the alias hands back the NEW prompt (an in-flight run migrates itself to /auto:auto-pulse)"
assert_eq "/auto:auto-pulse aliasrun" "$(jget "$alias_out" prompt)"

# ─── Scenario 3: the KEPT lib/tick.sh STUB drives an in-flight run ───────────
it "the lib/tick.sh forwarding stub ADVANCES an in-flight run"
run_record_init "stubrun"
stub_out="$(CLAUDE_AUTO_REPO="$REPO" bash "$STUB_SH" "stubrun" 2>/dev/null)"
stub_state="$(step_state stubrun)"
if [ "$(jget "$stub_out" action)" = "rearm" ] && [ "$stub_state" = "fixed" ]; then
  pass
else
  fail "stub did not advance the run: action=$(jget "$stub_out" action) state=${stub_state}"
fi

it "the stub hands back the NEW prompt (/auto:auto-pulse)"
assert_eq "/auto:auto-pulse stubrun" "$(jget "$stub_out" prompt)"

# ─── Scenario 4: the stub's deprecation notice never pollutes the intent ─────
# The driving model parses stdout as a single JSON object. A deprecation line on
# stdout would break every legacy-path rearm — the stub must speak on stderr.
it "the stub's deprecation notice goes to stderr, stdout stays a clean JSON intent"
run_record_init "cleanrun"
stub_err="$(CLAUDE_AUTO_REPO="$REPO" bash "$STUB_SH" "cleanrun" 2>&1 >/dev/null)"
stub_stdout="$(CLAUDE_AUTO_REPO="$REPO" bash "$STUB_SH" "cleanrun" 2>/dev/null)"
parses="$("$PY" -c "import json,sys
try:
    json.loads(sys.argv[1]); print('yes')
except Exception:
    print('no')" "$stub_stdout")"
case "$stub_err" in
  *deprecated*) [ "$parses" = "yes" ] && pass \
                  || fail "stdout is not a single JSON object: ${stub_stdout}" ;;
  *) fail "no deprecation notice on stderr: ${stub_err:-<empty>}" ;;
esac

# ─── Scenario 5: deliberate-fail control — the drive is real, not vacuous ────
# If the alias/stub silently no-op'd, the assertions above could pass on a run
# that was ALREADY in the terminal state. Drive a FRESH run with a deliberately
# broken command path and prove it does NOT advance (state stays verdict-returned)
# — so "state == fixed" above is genuinely caused by the legacy entry point.
it "deliberate-fail: a broken dispatch path does NOT advance the run"
run_record_init "dfrun"
CLAUDE_AUTO_REPO="$REPO" bash "${AUTO_ROOT}/lib/__no_such_entry__.sh" "dfrun" >/dev/null 2>&1 || true
df_state="$(step_state dfrun)"
assert_eq "verdict-returned" "$df_state"

# ─── Scenario 6: the canonical command file still dispatches pulse.sh ────────
it "commands/auto-pulse.md (canonical) dispatches lib/pulse.sh"
grep -qF 'lib/pulse.sh' "$CANON_MD" && pass || fail "canonical command does not invoke lib/pulse.sh"

echo ""
echo "pulse-alias-inflight.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
