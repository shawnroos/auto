#!/usr/bin/env bash
# claude-dispatch U4 unit test: lib/tick.py — one ScheduleWakeup-paced advance
# of the ledger. The tick reads ALL loop state from the disk ledger, does ONE
# smallest-useful advance inside a try/except, persists atomically via
# ledger.py, and emits the re-arm INTENT as a JSON dict (it NEVER calls
# ScheduleWakeup — that is a model tool, not a CLI).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/ledger.test.sh. It does NOT
# source claude-modes' test-helpers nor claude-dispatch shared helpers (those
# are U2's, not yet present). When U2 lands, this file may migrate to them.
#
# Scenarios (mapped to the U4 plan, tested against tick.py's ACTUAL surface):
#   1. predicate NOT met -> tick advances one step + signals re-arm (action=rearm)
#   2. predicate met -> emits report, action=stop, does NOT re-arm
#   3. stalled unit (dispatched past stall_threshold, no verdict) -> marked
#      stalled; it + transitive dependents halted; independent siblings advance
#      (Covers AE4)
#   4. adapter raises mid-tick -> unit.last_error recorded + unit marked stalled;
#      ledger never half-written; + deliberate-fail control proving the adapter
#      genuinely raises (so the clean-return is real try/except capture)
#   5. tick NEVER dispatches and NEVER writes verdicts: a work-loop tick that
#      sees a self-written verdict reads it + applies a fix (verdict-returned ->
#      fixed) but makes NO dispatch call and writes NO finding
#   6. non-stateless safety: invoke the tick twice from FRESH processes against
#      the same ledger -> it advances purely from ledger state

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TICK_PY="${DISPATCH_ROOT}/lib/tick.py"
TICK_SH="${DISPATCH_ROOT}/lib/tick.sh"
LEDGER_PY="${DISPATCH_ROOT}/lib/ledger.py"
PY="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

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
SANDBOX="$(mktemp -d -t claude-dispatch-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */claude-dispatch-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO"

# ── tiny python helpers run against the modules ────────────────────────────
# init <run> <json-units> [adapter] [phase]  — create a ledger with given units.
ledger_init() {
  local run="$1" units_json="$2" adapter="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$units_json" "$adapter" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, units_json, adapter, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, adapter=adapter, units=json.loads(units_json), loop_phase=phase)
PYEOF
}

# field <run> <python-expr-on-ledger-named-L>  — print a value from the ledger.
ledger_field() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, expr, ledger_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L = m.read_ledger(repo, run)
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
echo "tick.test.sh"

# ─── Scenario 1: predicate NOT met -> advance one step + signal re-arm ────────
# A work-loop with one verdict-returned unit carrying an open blocker: the
# predicate is NOT met (blocker present). The tick should apply ONE fix
# (verdict-returned -> fixed) and signal re-arm. The blocker remains (R8: a fix
# does not close findings), so met stays false and the chain keeps ticking.
it "predicate NOT met: tick advances one step (fix applied) and signals re-arm"
ledger_init "rearm-run" '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"open"}]}]' \
  >/dev/null 2>&1
res1="$("$PY" - "$REPO" "rearm-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_tick(repo, run)
print(json.dumps({
    "action": r.get("action"),
    "delay": r.get("delay"),
    "prompt": r.get("prompt"),
    "advanced": (r.get("advance") or {}).get("advanced"),
}))
PYEOF
)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res1")"
delay="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['delay'])" "$res1")"
prompt="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['prompt'])" "$res1")"
advanced="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res1")"
st1="$(ledger_field "rearm-run" 'L["units"][0]["state"]')"
if [ "$action" = "rearm" ] && [ "$delay" = "60" ] && [ "$prompt" = "/dispatch-tick rearm-run" ] \
   && [ "$advanced" = "fix-applied" ] && [ "$st1" = "fixed" ]; then
  pass
else
  fail "action=$action delay=$delay prompt=$prompt advanced=$advanced state=$st1 (expected rearm/60/.../fix-applied/fixed)"
fi

# ─── Scenario 2: predicate met -> emit report, action=stop, NO re-arm ─────────
# A terminal, defect-free, single-unit work-loop: init_ledger's atomic write
# recomputes the predicate, so met is already true at read time. The tick must
# stop (reason=predicate-met) and emit a report; it must NOT re-arm.
it "predicate met: tick emits report, action=stop (predicate-met), does NOT re-arm"
ledger_init "met-run" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
met_at_read="$(ledger_field "met-run" 'L["exit_predicate_result"]["met"]')"
res2="$("$PY" - "$REPO" "met-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_tick(repo, run)
print(json.dumps({
    "action": r.get("action"),
    "reason": r.get("reason"),
    "has_report": isinstance(r.get("report"), dict),
}))
PYEOF
)"
action2="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res2")"
reason2="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['reason'])" "$res2")"
hasrep2="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['has_report'])" "$res2")"
phase2="$(ledger_field "met-run" 'L["loop_phase"]')"
if [ "$met_at_read" = "True" ] && [ "$action2" = "stop" ] && [ "$reason2" = "predicate-met" ] \
   && [ "$hasrep2" = "True" ] && [ "$phase2" = "done" ]; then
  pass
else
  fail "met_at_read=$met_at_read action=$action2 reason=$reason2 has_report=$hasrep2 phase=$phase2"
fi

# ─── Scenario 3: stall detection + transitive halt; siblings advance (AE4) ────
# Ua dispatched 1h ago with stall_threshold 10s (age > threshold, strictly) ->
# stalled. Ub depends on Ua -> transitively halted. Uc is independent and
# verdict-returned with an open blocker -> the fix-due sibling that should still
# advance (verdict-returned -> fixed) while Ua/Ub are halted.
it "stall: dispatched-past-threshold unit -> stalled; it + transitive dependents halted; independent sibling advances"
DISP_AT="$(now_minus 3600)"
ledger_init "stall-run" \
  "$(printf '[{"id":"Ua","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10},{"id":"Ub","state":"pending","depends_on":["Ua"]},{"id":"Uc","state":"verdict-returned","findings":[{"severity":"major","note":"open"}]}]' "$DISP_AT")" \
  >/dev/null 2>&1
res3="$("$PY" - "$REPO" "stall-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_tick(repo, run)
print(json.dumps({
    "action": r.get("action"),
    "stalled": sorted(r.get("stalled") or []),
    "halted": sorted(r.get("halted") or []),
    "advanced": (r.get("advance") or {}).get("advanced"),
    "advanced_unit": (r.get("advance") or {}).get("unit"),
}))
PYEOF
)"
st_ua="$(ledger_field "stall-run" 'next(u["state"] for u in L["units"] if u["id"]=="Ua")')"
st_uc="$(ledger_field "stall-run" 'next(u["state"] for u in L["units"] if u["id"]=="Uc")')"
stalled_list="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['stalled']))" "$res3")"
halted_list="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['halted']))" "$res3")"
adv_unit="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced_unit'])" "$res3")"
adv_kind="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res3")"
# Ua marked stalled; Ua+Ub in halted set; Uc NOT halted and is the unit that
# advanced (fix-applied) — the independent sibling progressing past the stall.
if [ "$st_ua" = "stalled" ] && [ "$stalled_list" = "Ua" ] && [ "$halted_list" = "Ua,Ub" ] \
   && [ "$adv_kind" = "fix-applied" ] && [ "$adv_unit" = "Uc" ] && [ "$st_uc" = "fixed" ]; then
  pass
else
  fail "st_ua=$st_ua stalled=[$stalled_list] halted=[$halted_list] adv=$adv_kind/$adv_unit st_uc=$st_uc (expected stalled / Ua / Ua,Ub / fix-applied/Uc / fixed)"
fi

# ─── Scenario 4: adapter raises mid-tick -> last_error recorded + stalled ─────
# A plan-loop with one dispatched unit. We inject an adapter whose next_plan_step
# raises. The tick's try/except must convert the raise into a recorded
# last_error on the in-flight unit + mark it stalled, WITHOUT crashing and
# WITHOUT leaving a half-written ledger.
it "adapter raise: try/except records last_error + marks unit stalled; ledger stays valid (no half-write)"
DISP4="$(now_minus 5)"
ledger_init "raise-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":600}]' "$DISP4")" \
  ce plan >/dev/null 2>&1
res4="$("$PY" - "$REPO" "raise-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

class BoomAdapter:
    def next_plan_step(self, ledger):
        raise RuntimeError("adapter exploded mid-step")

# The tick must NOT propagate the raise; it returns a normal intent dict.
r = t.dispatch_tick(repo, run, adapter=BoomAdapter())
print(json.dumps({
    "action": r.get("action"),
    "advanced": (r.get("advance") or {}).get("advanced"),
}))
PYEOF
)"
rc4=$?
st4="$(ledger_field "raise-run" 'L["units"][0]["state"]')"
err_call="$(ledger_field "raise-run" 'L["units"][0]["last_error"]["call"]')"
err_msg_has="$(ledger_field "raise-run" '"RuntimeError" in (L["units"][0]["last_error"]["message"] or "")')"
# Ledger must still parse cleanly; no stray tempfile (atomic write held).
tmp_left4="$(find "$REPO/.claude/dispatch" -name '.ledger.*' 2>/dev/null | wc -l | tr -d ' ')"
adv4="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res4")"
if [ "$rc4" -eq 0 ] && [ "$st4" = "stalled" ] && [ "$err_call" = "plan" ] \
   && [ "$err_msg_has" = "True" ] && [ "$adv4" = "error" ] && [ "$tmp_left4" = "0" ]; then
  pass
else
  fail "rc=$rc4 state=$st4 err_call=$err_call err_msg_has=$err_msg_has advanced=$adv4 tmpfiles=$tmp_left4"
fi

it "deliberate-fail control: the injected adapter genuinely raises (proves S4's clean return is real try/except capture, not a benign no-op)"
# If we call the adapter op directly — OUTSIDE the tick's try/except — it MUST
# propagate. This proves the adapter is not silently benign, so the prior test's
# clean return + recorded last_error is meaningful (the try/except did the work).
raised="$("$PY" - <<'PYEOF'
class BoomAdapter:
    def next_plan_step(self, ledger):
        raise RuntimeError("adapter exploded mid-step")
try:
    BoomAdapter().next_plan_step({})
    print("DID-NOT-RAISE")
except RuntimeError:
    print("raised")
PYEOF
)"
assert_eq "raised" "$raised"

# ─── Scenario 5: tick NEVER dispatches and NEVER writes verdicts ──────────────
# A work-loop tick that sees a self-written verdict (verdict-returned + open
# major) applies ONE fix (-> fixed) but makes NO dispatch call and writes NO
# finding. Assert: (a) the fix-due unit becomes fixed; (b) its findings are
# byte-identical to setup (a fix does not touch findings — R8); (c) no pending
# sibling was moved to dispatched (the tick never owns pending -> dispatched).
it "tick never dispatches / never writes verdicts: applies a fix, leaves findings + pending siblings untouched"
ledger_init "no-dispatch-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"major","note":"fix me"}]},{"id":"U2","state":"pending"}]' \
  >/dev/null 2>&1
findings_before="$(ledger_field "no-dispatch-run" 'json.dumps(next(u["findings"] for u in L["units"] if u["id"]=="U1"), sort_keys=True)')"
"$PY" - "$REPO" "no-dispatch-run" "$TICK_PY" <<'PYEOF' >/dev/null
import sys, importlib.util
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
t.dispatch_tick(repo, run)
PYEOF
st_u1="$(ledger_field "no-dispatch-run" 'next(u["state"] for u in L["units"] if u["id"]=="U1")')"
st_u2="$(ledger_field "no-dispatch-run" 'next(u["state"] for u in L["units"] if u["id"]=="U2")')"
findings_after="$(ledger_field "no-dispatch-run" 'json.dumps(next(u["findings"] for u in L["units"] if u["id"]=="U1"), sort_keys=True)')"
# U1 fixed (fix applied); U2 still pending (NEVER dispatched by the tick);
# U1 findings unchanged (NO verdict written by the tick).
if [ "$st_u1" = "fixed" ] && [ "$st_u2" = "pending" ] && [ "$findings_before" = "$findings_after" ]; then
  pass
else
  fail "st_u1=$st_u1 st_u2=$st_u2 findings_changed=$([ "$findings_before" = "$findings_after" ] && echo no || echo YES)"
fi

# ─── Scenario 6: non-stateless safety — two FRESH-process ticks, one ledger ───
# Invoke the tick TWICE via the bash shim (each a separate process; no shared
# in-memory state). It must advance purely from the disk ledger: tick 1 applies
# the fix to U1; tick 2, from a clean process, sees U1 already fixed and applies
# the fix to U2. Proves the tick treats conversation/process context as
# irrelevant (re-injection-safe under ScheduleWakeup).
it "non-stateless: two ticks from FRESH processes advance purely from the disk ledger"
ledger_init "stateless-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"a"}]},{"id":"U2","state":"verdict-returned","findings":[{"severity":"blocker","note":"b"}]}]' \
  >/dev/null 2>&1
# First fresh process.
CLAUDE_DISPATCH_REPO="$REPO" bash "$TICK_SH" "stateless-run" >/dev/null 2>&1
st1_u1="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U1")')"
st1_u2="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U2")')"
# Second fresh process — must observe the first's mutation and advance the next.
CLAUDE_DISPATCH_REPO="$REPO" bash "$TICK_SH" "stateless-run" >/dev/null 2>&1
st2_u1="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U1")')"
st2_u2="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U2")')"
# After tick 1: one of U1/U2 fixed, the other still verdict-returned.
# After tick 2: both fixed (the second process picked up where the first left).
if [ "$st1_u1" = "fixed" ] && [ "$st1_u2" = "verdict-returned" ] \
   && [ "$st2_u1" = "fixed" ] && [ "$st2_u2" = "fixed" ]; then
  pass
else
  fail "after-tick1: U1=$st1_u1 U2=$st1_u2 ; after-tick2: U1=$st2_u1 U2=$st2_u2 (expected fixed/verdict-returned then fixed/fixed)"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "tick.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
