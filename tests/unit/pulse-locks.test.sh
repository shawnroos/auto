#!/usr/bin/env bash
# auto U4 unit test: lib/pulse.py — one ScheduleWakeup-paced advance
# of the run-record. The pulse reads ALL loop state from the disk run-record, does ONE
# smallest-useful advance inside a try/except, persists atomically via
# run_record.py, and emits the re-arm INTENT as a JSON dict (it NEVER calls
# ScheduleWakeup — that is a model tool, not a CLI).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/run-record.test.sh. It does NOT
# source claude-modes' test-helpers nor auto shared helpers (those
# are U2's, not yet present). When U2 lands, this file may migrate to them.
#
# Scenarios (mapped to the U4 plan, tested against pulse.py's ACTUAL surface):
#   1. predicate NOT met -> pulse advances one step + signals re-arm (action=rearm)
#   2. predicate met -> emits report, action=stop, does NOT re-arm
#   3. stalled step (dispatched past stall_threshold, no verdict) -> marked
#      stalled; it + transitive dependents halted; independent siblings advance
#      (Covers AE4)
#   4. backend raises mid-pulse -> step.last_error recorded + step marked stalled;
#      run-record never half-written; + deliberate-fail control proving the backend
#      genuinely raises (so the clean-return is real try/except capture)
#   5. pulse NEVER dispatches and NEVER writes verdicts: a work-loop pulse that
#      sees a self-written verdict reads it + applies a fix (verdict-returned ->
#      fixed) but makes NO dispatch call and writes NO finding
#   6. non-stateless safety: invoke the pulse twice from FRESH processes against
#      the same run-record -> it advances purely from run-record state
#   7. anti-livelock: a plan-loop run advances plan -> deepen -> review_plan
#      ACROSS fresh-process pulses WITHOUT re-planning. The pulse persists the
#      executed plan_step (schema §3.1) so the next pulse reads it instead of
#      re-reading null and re-running "plan" forever. Includes a deliberate-fail
#      control (env-gated no-persist) proving the test goes RED without the write.
#   8. Bug #5 gap-write: advance_plan_loop persists gaps_open from a DICT
#      review_plan return carrying `gap_set` (the live envelope shape), AND from
#      an empty gap_set (real length 0 -> "done"), keeping the plan loop open
#      until a real review reports.
#   9. Bug #5 null-path: the LIVE PREPARE envelope has NO gap_set key (model fills
#      it out-of-band); gaps_open must stay NULL (never default 0), so plan-met
#      does NOT fire after one un-reviewed pass. Deliberate-fail control replicates
#      the buggy gap_set=[] default and proves it produces a DIFFERENT plan-met
#      outcome (the discriminator).
#  10. phantom-dispatch self-heal: detect_and_halt_stalled reclaims a step stuck
#      `dispatched` past its stall_threshold (the dispatcher rescue-swallow P3
#      bound) -> stalled. Deliberate-fail control: WITHOUT the reaper the phantom
#      stays dispatched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PULSE_PY="${AUTO_ROOT}/lib/pulse.py"
PULSE_SH="${AUTO_ROOT}/lib/pulse.sh"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"
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
mkdir -p "$REPO"

# ── tiny python helpers run against the modules ────────────────────────────
# init <run> <json-steps> [backend] [phase]  — create a run-record with given steps.
run_record_init() {
  local run="$1" steps_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$backend" "$phase" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, backend, phase, run_record_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_run_record(repo, run, backend=backend, steps=json.loads(steps_json), loop_phase=phase)
PYEOF
}

# field <run> <python-expr-on-run-record-named-L>  — print a value from the run-record.
run_record_field() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, expr, run_record_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L = m.read_run_record(repo, run)
print(eval(expr))
PYEOF
}

# now_minus <seconds>  — print an ISO-8601 UTC timestamp <seconds> in the past.
now_minus() {
  "$PY" - "$1" <<'PYEOF'
import sys, datetime
secs = int(sys.argv[1])
dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=secs)
print(dt.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"))
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "pulse-locks.test.sh"

# ─── Task #31: NO_PULSE_LOCK hatch — tested + fenced ─────────────────────────
# Two parts to the close (fix-pass J atop the round-3 P3 promotion):
#   (a) The double-drive guard works: a second pulse raises _PulseLockHeld while
#       the first holds the run's pulse lock (green path).
#   (b) The hatch genuinely disables the guard (CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1
#       + CLAUDE_AUTO_TEST_HARNESS=1 → no raise) — the deliberate-fail control
#       per feedback_new_tests_need_deliberate_fail_smoke_check.
#   (c) The hatch is FENCED against accidental production exposure: setting the
#       hatch WITHOUT the harness sentinel does NOT disable the guard (the
#       second pulse still raises _PulseLockHeld). This is the actual close on
#       task #31's "unfenced" half.

it "task #31 GREEN: double-drive guard fires — second pulse raises _PulseLockHeld while first holds lock"
run_record_init "pulse-lock-green" '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"minor","note":"x"}]}]' >/dev/null 2>&1
green_result="$("$PY" - "$REPO" "pulse-lock-green" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
# Outer lock acquires; inner attempt MUST raise _PulseLockHeld.
with t._pulse_lock(repo, run):
    try:
        with t._pulse_lock(repo, run):
            print("NO-RAISE")
    except t._PulseLockHeld:
        print("blocked")
PYEOF
)"
assert_eq "blocked" "$green_result"

it "task #31 DELIBERATE-FAIL: with the hatch fully enabled (sentinel + var) the inner lock acquires (proves the guard is real and the hatch is reachable)"
run_record_init "pulse-lock-disabled" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
disabled_result="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 "$PY" - "$REPO" "pulse-lock-disabled" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
# Hatch ON + sentinel ON → both acquire successfully (no raise). This proves
# the test hatch is wired AND the guard would actually catch concurrent pulses
# in normal operation (otherwise this assertion would pass even without the
# hatch, telling us nothing).
with t._pulse_lock(repo, run):
    try:
        with t._pulse_lock(repo, run):
            print("both-acquired")
    except t._PulseLockHeld:
        print("BLOCKED-DESPITE-HATCH")
PYEOF
)"
assert_eq "both-acquired" "$disabled_result"

it "task #31 FENCE: hatch alone WITHOUT the harness sentinel does NOT disable the guard (production-safety)"
run_record_init "pulse-lock-fence" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
# CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 is exported BUT CLAUDE_AUTO_TEST_HARNESS is
# explicitly UNSET. The fence at lib/_bootstrap.py::test_hatch_enabled (and the
# local copy in lib/run_record.py) requires BOTH; with only one, the hatch is
# inert and the guard fires.
fence_result="$(env -u CLAUDE_AUTO_TEST_HARNESS CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 "$PY" - "$REPO" "pulse-lock-fence" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
with t._pulse_lock(repo, run):
    try:
        with t._pulse_lock(repo, run):
            print("HATCH-LEAKED")  # would fire if the fence were broken
    except t._PulseLockHeld:
        print("fenced")
PYEOF
)"
assert_eq "fenced" "$fence_result"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "pulse-locks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
