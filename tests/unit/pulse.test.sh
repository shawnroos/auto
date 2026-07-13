#!/usr/bin/env bash
# auto U4 unit test: lib/pulse.py — one ScheduleWakeup-paced advance
# of the ledger. The pulse reads ALL loop state from the disk ledger, does ONE
# smallest-useful advance inside a try/except, persists atomically via
# ledger.py, and emits the re-arm INTENT as a JSON dict (it NEVER calls
# ScheduleWakeup — that is a model tool, not a CLI).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/ledger.test.sh. It does NOT
# source claude-modes' test-helpers nor auto shared helpers (those
# are U2's, not yet present). When U2 lands, this file may migrate to them.
#
# Scenarios (mapped to the U4 plan, tested against pulse.py's ACTUAL surface):
#   1. predicate NOT met -> pulse advances one step + signals re-arm (action=rearm)
#   2. predicate met -> emits report, action=stop, does NOT re-arm
#   3. stalled unit (dispatched past stall_threshold, no verdict) -> marked
#      stalled; it + transitive dependents halted; independent siblings advance
#      (Covers AE4)
#   4. backend raises mid-pulse -> unit.last_error recorded + unit marked stalled;
#      ledger never half-written; + deliberate-fail control proving the backend
#      genuinely raises (so the clean-return is real try/except capture)
#   5. pulse NEVER dispatches and NEVER writes verdicts: a work-loop pulse that
#      sees a self-written verdict reads it + applies a fix (verdict-returned ->
#      fixed) but makes NO dispatch call and writes NO finding
#   6. non-stateless safety: invoke the pulse twice from FRESH processes against
#      the same ledger -> it advances purely from ledger state
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
#  10. phantom-dispatch self-heal: detect_and_halt_stalled reclaims a unit stuck
#      `dispatched` past its stall_threshold (the dispatcher rescue-swallow P3
#      bound) -> stalled. Deliberate-fail control: WITHOUT the reaper the phantom
#      stays dispatched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PULSE_PY="${AUTO_ROOT}/lib/pulse.py"
PULSE_SH="${AUTO_ROOT}/lib/pulse.sh"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
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
# init <run> <json-units> [backend] [phase]  — create a ledger with given units.
ledger_init() {
  local run="$1" units_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$units_json" "$backend" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, units_json, backend, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, backend=backend, units=json.loads(units_json), loop_phase=phase)
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
echo "pulse.test.sh"

# ─── Scenario 1: predicate NOT met -> advance one step + signal re-arm ────────
# A work-loop with one verdict-returned unit carrying an open blocker: the
# predicate is NOT met (blocker present). The pulse should apply ONE fix
# (verdict-returned -> fixed) and signal re-arm. The blocker remains (R8: a fix
# does not close findings), so met stays false and the chain keeps pulsing.
it "predicate NOT met: pulse advances one step (fix applied) and signals re-arm"
ledger_init "rearm-run" '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"open"}]}]' \
  >/dev/null 2>&1
res1="$("$PY" - "$REPO" "rearm-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_pulse(repo, run)
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
st1="$(ledger_field "rearm-run" 'L["steps"][0]["state"]')"
if [ "$action" = "rearm" ] && [ "$delay" = "60" ] && [ "$prompt" = "/auto:auto-pulse rearm-run" ] \
   && [ "$advanced" = "fix-applied" ] && [ "$st1" = "fixed" ]; then
  pass
else
  fail "action=$action delay=$delay prompt=$prompt advanced=$advanced state=$st1 (expected rearm/60/.../fix-applied/fixed)"
fi

# ─── Scenario 2: predicate met -> emit report, action=stop, NO re-arm ─────────
# A terminal, defect-free, single-unit work-loop: init_ledger's atomic write
# recomputes the predicate, so met is already true at read time. The pulse must
# stop (reason=predicate-met) and emit a report; it must NOT re-arm.
it "predicate met: pulse emits report, action=stop (predicate-met), does NOT re-arm"
ledger_init "met-run" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
met_at_read="$(ledger_field "met-run" 'L["exit_predicate_result"]["met"]')"
res2="$("$PY" - "$REPO" "met-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_pulse(repo, run)
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
res3="$("$PY" - "$REPO" "stall-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
r = t.dispatch_pulse(repo, run)
print(json.dumps({
    "action": r.get("action"),
    "stalled": sorted(r.get("stalled") or []),
    "halted": sorted(r.get("halted") or []),
    "advanced": (r.get("advance") or {}).get("advanced"),
    "advanced_unit": (r.get("advance") or {}).get("unit"),
}))
PYEOF
)"
st_ua="$(ledger_field "stall-run" 'next(u["state"] for u in L["steps"] if u["id"]=="Ua")')"
st_uc="$(ledger_field "stall-run" 'next(u["state"] for u in L["steps"] if u["id"]=="Uc")')"
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

# ─── Scenario 4: backend raises mid-pulse -> last_error recorded + stalled ─────
# A plan-loop with one dispatched unit. We inject a backend whose next_plan_step
# raises. The pulse's try/except must convert the raise into a recorded
# last_error on the in-flight unit + mark it stalled, WITHOUT crashing and
# WITHOUT leaving a half-written ledger.
it "backend raise: try/except records last_error + marks unit stalled; ledger stays valid (no half-write)"
DISP4="$(now_minus 5)"
ledger_init "raise-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":600}]' "$DISP4")" \
  ce plan >/dev/null 2>&1
res4="$("$PY" - "$REPO" "raise-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

class BoomBackend:
    def next_plan_step(self, ledger):
        raise RuntimeError("backend exploded mid-step")

# The pulse must NOT propagate the raise; it returns a normal intent dict.
r = t.dispatch_pulse(repo, run, backend=BoomBackend())
print(json.dumps({
    "action": r.get("action"),
    "advanced": (r.get("advance") or {}).get("advanced"),
}))
PYEOF
)"
rc4=$?
st4="$(ledger_field "raise-run" 'L["steps"][0]["state"]')"
err_call="$(ledger_field "raise-run" 'L["steps"][0]["last_error"]["call"]')"
err_msg_has="$(ledger_field "raise-run" '"RuntimeError" in (L["steps"][0]["last_error"]["message"] or "")')"
# Ledger must still parse cleanly; no stray tempfile (atomic write held).
tmp_left4="$(find "$REPO/.claude/auto" -name '.ledger.*' 2>/dev/null | wc -l | tr -d ' ')"
adv4="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res4")"
if [ "$rc4" -eq 0 ] && [ "$st4" = "stalled" ] && [ "$err_call" = "plan" ] \
   && [ "$err_msg_has" = "True" ] && [ "$adv4" = "error" ] && [ "$tmp_left4" = "0" ]; then
  pass
else
  fail "rc=$rc4 state=$st4 err_call=$err_call err_msg_has=$err_msg_has advanced=$adv4 tmpfiles=$tmp_left4"
fi

it "deliberate-fail control: the injected backend genuinely raises (proves S4's clean return is real try/except capture, not a benign no-op)"
# If we call the backend op directly — OUTSIDE the pulse's try/except — it MUST
# propagate. This proves the backend is not silently benign, so the prior test's
# clean return + recorded last_error is meaningful (the try/except did the work).
raised="$("$PY" - <<'PYEOF'
class BoomBackend:
    def next_plan_step(self, ledger):
        raise RuntimeError("backend exploded mid-step")
try:
    BoomBackend().next_plan_step({})
    print("DID-NOT-RAISE")
except RuntimeError:
    print("raised")
PYEOF
)"
assert_eq "raised" "$raised"

# ─── Scenario 5: pulse NEVER dispatches and NEVER writes verdicts ──────────────
# A work-loop pulse that sees a self-written verdict (verdict-returned + open
# major) applies ONE fix (-> fixed) but makes NO dispatch call and writes NO
# finding. Assert: (a) the fix-due unit becomes fixed; (b) its findings are
# byte-identical to setup (a fix does not touch findings — R8); (c) no pending
# sibling was moved to dispatched (the pulse never owns pending -> dispatched).
it "pulse never dispatches / never writes verdicts: applies a fix, leaves findings + pending siblings untouched"
ledger_init "no-dispatch-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"major","note":"fix me"}]},{"id":"U2","state":"pending"}]' \
  >/dev/null 2>&1
findings_before="$(ledger_field "no-dispatch-run" 'json.dumps(next(u["findings"] for u in L["steps"] if u["id"]=="U1"), sort_keys=True)')"
"$PY" - "$REPO" "no-dispatch-run" "$PULSE_PY" <<'PYEOF' >/dev/null
import sys, importlib.util
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
t.dispatch_pulse(repo, run)
PYEOF
st_u1="$(ledger_field "no-dispatch-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U1")')"
st_u2="$(ledger_field "no-dispatch-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U2")')"
findings_after="$(ledger_field "no-dispatch-run" 'json.dumps(next(u["findings"] for u in L["steps"] if u["id"]=="U1"), sort_keys=True)')"
# U1 fixed (fix applied); U2 still pending (NEVER dispatched by the pulse);
# U1 findings unchanged (NO verdict written by the pulse).
if [ "$st_u1" = "fixed" ] && [ "$st_u2" = "pending" ] && [ "$findings_before" = "$findings_after" ]; then
  pass
else
  fail "st_u1=$st_u1 st_u2=$st_u2 findings_changed=$([ "$findings_before" = "$findings_after" ] && echo no || echo YES)"
fi

# ─── Scenario 6: non-stateless safety — two FRESH-process pulses, one ledger ───
# Invoke the pulse TWICE via the bash shim (each a separate process; no shared
# in-memory state). It must advance purely from the disk ledger: pulse 1 applies
# the fix to U1; pulse 2, from a clean process, sees U1 already fixed and applies
# the fix to U2. Proves the pulse treats conversation/process context as
# irrelevant (re-injection-safe under ScheduleWakeup).
it "non-stateless: two pulses from FRESH processes advance purely from the disk ledger"
ledger_init "stateless-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"a"}]},{"id":"U2","state":"verdict-returned","findings":[{"severity":"blocker","note":"b"}]}]' \
  >/dev/null 2>&1
# First fresh process.
CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "stateless-run" >/dev/null 2>&1
st1_u1="$(ledger_field "stateless-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U1")')"
st1_u2="$(ledger_field "stateless-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U2")')"
# Second fresh process — must observe the first's mutation and advance the next.
CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "stateless-run" >/dev/null 2>&1
st2_u1="$(ledger_field "stateless-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U1")')"
st2_u2="$(ledger_field "stateless-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U2")')"
# After pulse 1: one of U1/U2 fixed, the other still verdict-returned.
# After pulse 2: both fixed (the second process picked up where the first left).
if [ "$st1_u1" = "fixed" ] && [ "$st1_u2" = "verdict-returned" ] \
   && [ "$st2_u1" = "fixed" ] && [ "$st2_u2" = "fixed" ]; then
  pass
else
  fail "after-pulse1: U1=$st1_u1 U2=$st1_u2 ; after-pulse2: U1=$st2_u1 U2=$st2_u2 (expected fixed/verdict-returned then fixed/fixed)"
fi

# ─── Scenario 7: anti-livelock — plan_step advances across fresh-process pulses ─
# THE integration-blocking bug this fix closes: next_plan_step is pure over the
# ledger and each pulse is a fresh process. If the pulse does not persist the
# executed plan_step, every pulse reads plan_step==null, the backend returns
# "plan", and the plan-loop re-plans forever. With the persist (ledger.set_loop
# plan_step=...), three fresh-process pulses walk plan -> deepen -> review_plan.
#
# We use the REAL ce backend (its plan/deepen/review_plan ops are pure
# envelope-returning no-ops). One PENDING unit keeps all_steps_terminal==false
# so the predicate never short-circuits the plan-loop to done. gaps_open stays
# NULL (Bug #5 fix: the live envelope carries no gap_set, so the engine never
# defaults it to 0 — the never-reviewed value is null, not zero), but the
# coherence guard keys on plan_step=="review_plan" specifically, so it does NOT
# fire until AFTER a real review_plan step has been persisted — exactly the walk
# we assert.
it "anti-livelock: 3 fresh-process plan pulses walk plan -> deepen -> review_plan (step persisted, no re-plan)"
ledger_init "antilivelock-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
step0="$(ledger_field "antilivelock-run" 'L.get("plan_step")')"
CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "antilivelock-run" >/dev/null 2>&1
step1="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "antilivelock-run" >/dev/null 2>&1
step2="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
CLAUDE_AUTO_REPO="$REPO" bash "$PULSE_SH" "antilivelock-run" >/dev/null 2>&1
step3="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
# init -> null; pulse1 ran "plan"; pulse2 ran "deepen"; pulse3 ran "review_plan".
# The walk MONOTONICALLY ADVANCES — it never gets stuck re-running "plan".
if [ "$step0" = "None" ] && [ "$step1" = "plan" ] && [ "$step2" = "deepen" ] \
   && [ "$step3" = "review_plan" ]; then
  pass
else
  fail "plan_step walk: init=$step0 t1=$step1 t2=$step2 t3=$step3 (expected None/plan/deepen/review_plan)"
fi

it "deliberate-fail control: WITHOUT the persist, plan_step stays stuck at the first step -> livelock (proves the persist is load-bearing)"
# Run the SAME plan-loop, but neuter the pulse's persist by monkeypatching
# ledger.set_loop to DROP the plan_step kwarg (simulating the pre-fix pulse that
# advanced the step but never wrote it back). Three pulses must then NEVER record
# a step beyond null — the backend would re-return "plan" every time (livelock).
# This proves the prior test passes BECAUSE of the persist, not by accident.
stuck="$("$PY" - "$REPO" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, pulse_py, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)

run = "antilivelock-nopersist"
ledg.init_ledger(repo, run, backend="ce", units=[{"id":"U1","state":"pending"}], loop_phase="plan")

# Neuter the persist: t.ledger.set_loop forwarded WITHOUT plan_step. The pulse's
# beat write (set_loop(driver="self", beat=True)) still works; only the
# plan_step persist is dropped — exactly the pre-fix behaviour.
_real_set_loop = ledg.set_loop
def _no_plan_step_set_loop(repo_root, run_id, **kw):
    kw.pop("plan_step", None)
    return _real_set_loop(repo_root, run_id, **kw)
t.ledger.set_loop = _no_plan_step_set_loop

steps = []
for _ in range(3):
    t.dispatch_pulse(repo, run)
    steps.append(ledg.read_ledger(repo, run).get("plan_step"))
# Without the persist every read is None -> the plan-loop is livelocked.
print("stuck" if all(s is None for s in steps) else "ADVANCED:%r" % steps)
PYEOF
)"
assert_eq "stuck" "$stuck"

# ─── Scenario 8: Bug #5 — gaps_open persisted from a DICT review_plan return ──
# advance_plan_loop must persist gaps_open from BOTH a bare list AND a dict
# envelope carrying `gap_set` (the LIVE backends return a dict — that branch was
# previously dead, so gaps_open was never written from a real review and plan-met
# fired after a SINGLE review pass, making the deepen-refinement loop unreachable).
# We exercise the DICT path specifically with a stub backend whose review_plan
# returns {"gap_set": [...]} of length N.
#
# Verify-RED: lib/pulse.py advance_plan_loop, delete the
#   `elif isinstance(result, dict) and isinstance(result.get("gap_set"), list):`
# branch (the dict extraction). gap_set stays None for the dict envelope, the
# `step == "review_plan" and gap_set is not None` write never fires, gaps_open
# stays 0, and these dict-path assertions go RED.
it "Bug #5: dict review_plan return with gap_set of N -> gaps_open==N, plan NOT met (deepen loop stays open)"
# Seed plan_step="deepen" so the stub's next_plan_step -> "review_plan" lands on
# the review step (the only step that persists gaps).
ledger_init "gaps-dict-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
"$PY" - "$REPO" "gaps-dict-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.set_loop(repo, run, plan_step="deepen")
PYEOF
gaps_dict="$("$PY" - "$REPO" "gaps-dict-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)

class DictGapBackend:
    # Live-backend shape: review_plan returns a DICT envelope carrying gap_set.
    def next_plan_step(self, ledger):
        return "review_plan"
    def review_plan(self, ledger):
        return {"op": "review_plan", "gap_set": [{"id": "g1"}, {"id": "g2"}, {"id": "g3"}]}

led = ledg.read_ledger(repo, run)
t.pulse_advance.advance_plan_loop(repo, run, led, DictGapBackend())
print(ledg.read_ledger(repo, run)["exit_predicate_result"]["gaps_open"])
PYEOF
)"
# gaps_open must equal the gap_set length (3), persisted from the dict envelope.
assert_eq "3" "$gaps_dict"

it "Bug #5: gaps_open==3 keeps the PLAN loop open (plan-met requires gaps_open==0)"
# With three gaps open, the plan predicate is NOT met regardless of plan_step.
met_dict="$(ledger_field "gaps-dict-run" 'L["exit_predicate_result"]["met"]')"
gaps_chk="$(ledger_field "gaps-dict-run" 'L["exit_predicate_result"]["gaps_open"]')"
phase_chk="$(ledger_field "gaps-dict-run" 'L["loop_phase"]')"
if [ "$met_dict" = "False" ] && [ "$gaps_chk" = "3" ] && [ "$phase_chk" = "plan" ]; then
  pass
else
  fail "met=$met_dict gaps_open=$gaps_chk phase=$phase_chk (expected False/3/plan)"
fi

it "Bug #5: dict review_plan return with EMPTY gap_set -> gaps_open==0; next_plan_step -> done (real length, not accidental zero)"
# Empty gap_set must write gaps_open==0 (the actual length), AND because the dict
# path persisted plan_step="review_plan", the REAL ce sequencer then returns
# "done" (gaps closed by a real review). Proves the write is len(gap_set), not a
# default 0 that happened to match.
ledger_init "gaps-empty-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
"$PY" - "$REPO" "gaps-empty-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.set_loop(repo, run, plan_step="deepen")
PYEOF
empty_out="$("$PY" - "$REPO" "gaps-empty-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# Use the REAL ce backend for next_plan_step (the live sequencer) but feed an
# empty-gap_set dict via a thin subclass of its review_plan, so the "done"
# coherence guard is exercised end-to-end after a real (empty) review.
import importlib.util as _il
aspec = _il.spec_from_file_location("backend_ce", ledger_py.replace("ledger.py", "backend-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)

class EmptyGapBackend(ace.Backend):
    def review_plan(self, ledger):
        return {"op": "review_plan", "gap_set": []}

led = ledg.read_ledger(repo, run)
backend = EmptyGapBackend()
t.pulse_advance.advance_plan_loop(repo, run, led, backend)
led2 = ledg.read_ledger(repo, run)
gaps = led2["exit_predicate_result"]["gaps_open"]
# Now ask the live sequencer for the next step: review_plan persisted +
# gaps_open==0 -> the §4.1 coherence guard returns "done".
nxt = backend.next_plan_step(led2)
print("%s,%s,%s" % (gaps, led2.get("plan_step"), nxt))
PYEOF
)"
# gaps_open==0 (real length of empty list), plan_step persisted as review_plan,
# next step "done" — the plan loop CAN now reach met (gaps closed by a real review).
if [ "$empty_out" = "0,review_plan,done" ]; then
  pass
else
  fail "gaps,plan_step,next = $empty_out (expected 0,review_plan,done)"
fi

# ─── Scenario 9: Bug #5 null-path — LIVE PREPARE envelope (NO gap_set key) ────
# The previous Bug #5 scenarios drive review_plan returns that CARRY a gap_set
# (dict-with-key, bare list). This scenario covers the OTHER live shape that has
# no dedicated test: the REAL ce/native backends' review_plan returns a PREPARE
# envelope WITHOUT a gap_set key — the model fills it out-of-band AFTER the engine
# reads. The correct behaviour (the round-2 premature-plan-met fix) is that
# gaps_open stays NULL (never a default 0), so plan-met does NOT fire after one
# un-reviewed pass and the deepen-refinement loop stays open. A regression that
# defaulted gap_set=[] for the keyless envelope would silently reopen the bug:
# gaps_open=0 -> plan-met -> the loop exits before a real review reports gaps.
#
# We drive advance_plan_loop with the REAL ce backend (review_plan returns the
# live envelope shape, NO gap_set), then assert gaps_open is still null and plan
# is NOT met after the review pass. The deliberate-fail control below replicates
# the buggy default-zero extraction and proves it produces a DIFFERENT, plan-met
# outcome — so this test genuinely distinguishes correct-from-broken.
it "Bug #5 null-path: LIVE review_plan envelope (no gap_set key) -> gaps_open stays NULL, plan NOT met (deepen loop stays open)"
ledger_init "gaps-null-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
# Seed plan_step="deepen" so the live sequencer's next step lands on review_plan.
"$PY" - "$REPO" "gaps-null-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.set_loop(repo, run, plan_step="deepen")
PYEOF
null_out="$("$PY" - "$REPO" "gaps-null-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# REAL ce backend: review_plan returns the live PREPARE envelope, which carries
# NO gap_set key (the model fills it out-of-band after the engine reads).
import importlib.util as _il
aspec = _il.spec_from_file_location("backend_ce", ledger_py.replace("ledger.py", "backend-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)
backend = ace.Backend()
# Guard: confirm the envelope really has NO gap_set key (the shape under test).
env = backend.review_plan(ledg.read_ledger(repo, run))
assert isinstance(env, dict) and "gap_set" not in env, "envelope unexpectedly has gap_set: %r" % env

led = ledg.read_ledger(repo, run)
t.pulse_advance.advance_plan_loop(repo, run, led, backend)
L2 = ledg.read_ledger(repo, run)
go = L2["exit_predicate_result"]["gaps_open"]
met = L2["exit_predicate_result"]["met"]
phase = L2.get("loop_phase")
step = L2.get("plan_step")
# go is None (NOT 0); met False; loop stays in plan; step persisted as review_plan.
print("%s,%s,%s,%s" % (go, met, phase, step))
PYEOF
)"
# gaps_open stays None; plan NOT met; loop stays in plan phase; review_plan persisted.
if [ "$null_out" = "None,False,plan,review_plan" ]; then
  pass
else
  fail "gaps_open,met,phase,step = $null_out (expected None,False,plan,review_plan)"
fi

it "deliberate-fail control: the BUGGY gap_set=[] default for a keyless envelope writes gaps_open=0 and FIRES plan-met (proves the null-path test discriminates)"
# Replicate the regression inline: extract with result.get("gap_set", []) — the
# default-zero short-circuit the engine MUST NOT have — against the SAME live ce
# envelope. This must produce a DIFFERENT outcome from the correct path above:
# gaps_open=0, plan-met True, next step "done". If this control matched the
# correct path, the prior test would prove nothing.
buggy_out="$("$PY" - "$REPO" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, pulse_py, ledger_py = sys.argv[1:4]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
import importlib.util as _il
aspec = _il.spec_from_file_location("backend_ce", ledger_py.replace("ledger.py", "backend-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)

run = "gaps-null-buggy"
ledg.init_ledger(repo, run, backend="ce", units=[{"id":"U1","state":"pending"}], loop_phase="plan")
ledg.set_loop(repo, run, plan_step="deepen")
backend = ace.Backend()
result = backend.review_plan(ledg.read_ledger(repo, run))  # live envelope, NO gap_set
# THE BUG: default-zero extraction for a keyless envelope.
buggy_gap_set = result.get("gap_set", [])
ledg.set_gaps_open(repo, run, len(buggy_gap_set))
ledg.set_loop(repo, run, plan_step="review_plan")
L = ledg.read_ledger(repo, run)
go = L["exit_predicate_result"]["gaps_open"]
met = L["exit_predicate_result"]["met"]
nxt = backend.next_plan_step(L)
print("%s,%s,%s" % (go, met, nxt))
PYEOF
)"
# The buggy default produces gaps_open=0 (NOT None), plan-met True, next "done" —
# materially different from the correct None/False path. Discriminator confirmed.
if [ "$buggy_out" = "0,True,done" ]; then
  pass
else
  fail "buggy default outcome = $buggy_out (expected 0,True,done — the regression this null-path guards)"
fi

# ─── Scenario 10: phantom-dispatch self-heal (dispatcher P3 bound) ──────────
# dispatcher.dispatch_batch's launch guard (Bug #8) marks a unit stalled if
# launch_fn raises. If the rescue transition (dispatched->stalled) ALSO raises,
# the broadened `except Exception` swallows it and the unit stays `dispatched`
# with no agent — a phantom. The CLAIM bounding that P3 is that the phantom
# self-heals: detect_and_halt_stalled reclaims ANY dispatched-past-stall_threshold
# unit on a later pulse. This test proves that bound.
#
# We simulate the phantom directly (a unit stuck `dispatched` with dispatched_at
# older than its stall_threshold, no verdict) and run detect_and_halt_stalled.
# The reaper must transition it to `stalled` (reclaimed) with last_error null
# (a plain timeout, not a backend-raise). The deliberate-fail control is the
# ABSENCE of the reaper call: without it, the phantom stays `dispatched` forever.
it "phantom-dispatch self-heal: detect_and_halt_stalled reclaims a dispatched-past-threshold phantom -> stalled (last_error null)"
PHANTOM_AT="$(now_minus 3600)"
ledger_init "phantom-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10}]' "$PHANTOM_AT")" \
  ce work >/dev/null 2>&1
# Baseline: the phantom IS dispatched before the reaper runs (the swallowed-rescue
# state the dispatcher P3 leaves behind).
st_before="$(ledger_field "phantom-run" 'L["steps"][0]["state"]')"
phantom_out="$("$PY" - "$REPO" "phantom-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
led = ledg.read_ledger(repo, run)
now = datetime.datetime.now(datetime.timezone.utc)
fresh, halted, newly = t.pulse_advance.detect_and_halt_stalled(repo, run, led, now)
after = ledg.read_ledger(repo, run)
u = after["steps"][0]
print("%s,%s,%s" % (u["state"], (",".join(newly)) if newly else "-", u.get("last_error")))
PYEOF
)"
st_after="$(ledger_field "phantom-run" 'L["steps"][0]["state"]')"
# Before: dispatched (phantom). After the reaper: stalled, newly_stalled=[U1],
# last_error null (plain timeout — NOT a backend-raise error object).
if [ "$st_before" = "dispatched" ] && [ "$phantom_out" = "stalled,U1,None" ] \
   && [ "$st_after" = "stalled" ]; then
  pass
else
  fail "before=$st_before reaper_out=$phantom_out after=$st_after (expected dispatched / stalled,U1,None / stalled)"
fi

it "deliberate-fail control: WITHOUT the reaper, the phantom stays dispatched forever (proves the reclaim is load-bearing)"
# Same phantom, but we DO NOT call detect_and_halt_stalled. The unit must remain
# `dispatched` — the absence of the reaper IS the control. If the phantom self-
# healed without the reaper, the prior test would prove nothing.
ledger_init "phantom-noreap-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10}]' "$PHANTOM_AT")" \
  ce work >/dev/null 2>&1
noreap_state="$(ledger_field "phantom-noreap-run" 'L["steps"][0]["state"]')"
assert_eq "dispatched" "$noreap_state"

# ─── U6: plan-done enumerate→persist (the F4 producer wiring) ───────────────
# At plan-done, advance_plan_loop calls the backend's enumerate_plan_units and
# persists the result onto the plan unit's dispatch_context.enumerated_steps, so
# the U5b producer can read it. Drive it with a fake backend whose next_plan_step
# returns "done" and enumerate_plan_units returns a bare list.
it "U6: plan-done persists enumerate_plan_units output to dispatch_context"
ledger_init "enum-run" '[{"id":"plan","phase":"plan","state":"dispatched"}]' ce plan >/dev/null 2>&1
enum_res="$("$PY" - "$REPO" "enum-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(m)

class FakeBackend:
    def next_plan_step(self, ledger): return "done"
    def enumerate_plan_units(self, ledger):
        return [{"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]

led = m.read_ledger(repo, run)
result = t.pulse_advance.advance_plan_loop(repo, run, led, FakeBackend())
after = m.read_ledger(repo, run)
plan_unit = after["steps"][0]
enum = (plan_unit.get("dispatch_context") or {}).get("enumerated_steps") or []
print("%s,%s" % (result.get("advanced"),
                 ",".join(u["id"] for u in enum)))
PYEOF
)"
# advanced plan-done (U18: advance_plan_loop returns a bare dict now), and the
# 2 enumerated units are persisted.
assert_eq "plan-done,w1,w2" "$enum_res"

# ─── Fix-pass H: prepare/execute contract is LOUD in rearm intent ────────────
# Field bug (2026-05-25, second agent): pulsed 5 times expecting units to
# materialize; ledger stayed at units=[] because they never executed the
# prepared invocation. The rearm intent now carries an operator_guidance
# field naming the contract phase-by-phase, plus a gaps_open_guard when
# plan_step==review_plan AND gaps_open is null (Trap 2 from the prepare/
# execute memory). Three assertions cover both new fields and a deliberate-
# fail control.

it "fix-pass H: plan-loop rearm carries operator_guidance naming prepare/execute"
ledger_init "guidance-plan-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guidance_plan="$("$PY" - "$REPO" "guidance-plan-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

# Use the bundled CE backend so a real plan-loop pulse fires.
intent = t.dispatch_pulse(repo, run)
g = intent.get("operator_guidance", "")
print("ok" if ("prepare/execute contract" in g
               and "YOU must run it" in g
               and "NO-OP" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guidance_plan"

it "fix-pass H: gaps_open_guard fires when plan_step==review_plan AND gaps_open is null (Trap 2)"
ledger_init "gap-guard-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guard_msg="$("$PY" - "$REPO" "gap-guard-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(L)

# Force the exact trap state: plan_step=review_plan, gaps_open=null (default).
L.set_loop(repo, run, plan_step="review_plan")
intent = t.dispatch_pulse(repo, run)
g = intent.get("gaps_open_guard", "")
print("ok" if ("gaps_open is NULL" in g and "set_gaps_open" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guard_msg"

it "fix-pass H DELIBERATE-FAIL: gaps_open_guard is ABSENT when gaps_open is set (proves the guard discriminates)"
ledger_init "gap-set-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guard_absent="$("$PY" - "$REPO" "gap-set-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(L)

# gaps_open populated to a real value → guard MUST NOT fire (it'd be noise).
L.set_loop(repo, run, plan_step="review_plan")
L.set_gaps_open(repo, run, 0)
intent = t.dispatch_pulse(repo, run)
print("absent" if "gaps_open_guard" not in intent else f"PRESENT:{intent.get('gaps_open_guard')[:80]}")
PYEOF
)"
assert_eq "absent" "$guard_absent"

it "fix-pass H: work-loop rearm carries operator_guidance naming dispatch + yield (fix-pass G)"
ledger_init "guidance-work-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}]' \
  ce work >/dev/null 2>&1
guidance_work="$("$PY" - "$REPO" "guidance-work-run" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

intent = t.dispatch_pulse(repo, run)
g = intent.get("operator_guidance", "")
print("ok" if ("YOU drive the" in g
               and "YIELD silently" in g
               and "harness re-invokes" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guidance_work"


# ─── U5: both terminal-phase guards route through phase_grammar.is_terminal_phase ─
# The two hand-rolled terminal-phase guards in pulse.py agreed ONLY because every
# shipped recipe's terminal_phase == "work":
#   Guard A (_try_predicate_met_shortcircuit): a DENYLIST — `phase != "plan" and
#            phase != "handoff"` — which stops at ANY phase that isn't plan/handoff.
#   Guard B (_try_post_advance_predicate_met): an ALLOWLIST — `phase == "work"` —
#            which stops ONLY at work.
# For a non-work terminal recipe (e.g. terminal_phase == "brainstorm") they
# DIVERGE: Guard A over-fires (stops at any non-plan/handoff phase, even non-terminal
# ones) while Guard B under-fires (never stops at the real terminal). Routing both
# through phase_grammar.is_terminal_phase(led, phase) makes them agree on the
# recipe's ACTUAL terminal phase. This is behavior-changing for non-work recipes
# and behavior-preserving for the shipped work-terminal ones (the regression case).
#
# Verify-RED (against pre-fix pulse.py): the main-fixture Guard B assertion goes RED
# (Guard B returns None because brainstorm != "work") AND the converse Guard A
# assertion goes RED (Guard A's denylist over-fires and stops at a non-terminal
# brainstorm). After the fix both flip GREEN. The regression assertions pass on
# BOTH sides of the fix (the work-terminal path is unchanged).

# u5_guard <run> <units_json> <phase_order_json> <terminal> <loop_phase> <phase> <A|B> <stale_met 0|1>
#   Inits a fresh ledger, invokes ONE guard, prints "<action>,<loop_phase-on-disk>".
#   stale_met=1 forces exit_predicate_result.met=true on the IN-MEMORY led (Guard A
#   reads its led param) to model a stale cached predicate at a NON-terminal phase —
#   the exact shape that must NOT stop after the fix. Natural-met fixtures (stale=0)
#   let init_ledger's recompute set met, so they need no hatch and behave identically
#   whether this file runs standalone or under run.sh.
u5_guard() {
  "$PY" - "$REPO" "$PULSE_PY" "$LEDGER_PY" "$@" <<'PYEOF'
import sys, importlib.util, json
repo, pulse_py, ledger_py = sys.argv[1:4]
run, units_json, po_json, terminal, loop_phase, phase, guard, stale = sys.argv[4:12]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
ledg.init_ledger(repo, run, backend="ce", units=json.loads(units_json),
                 loop_phase=loop_phase, phase_order=json.loads(po_json),
                 terminal_phase=terminal)
led = ledg.read_ledger(repo, run)
if stale == "1":
    led["exit_predicate_result"] = {"met": True, "iteration_pending": False}
if guard == "A":
    r = t._try_predicate_met_shortcircuit(repo, run, led, phase=phase)
else:
    r = t._try_post_advance_predicate_met(repo, run, {"advanced": "x"}, phase=phase)
action = (r or {}).get("action") or "none"
disk_phase = ledg.read_ledger(repo, run).get("loop_phase")
print("%s,%s" % (action, disk_phase))
PYEOF
}

BS_UNITS='[{"id":"U1","phase":"brainstorm","state":"verdict-returned","findings":[]}]'
BS_ORDER='["plan","handoff","brainstorm"]'

# Sanity: the brainstorm-terminal fixture genuinely reaches met (so the guard
# tests below exercise a real met predicate, not a vacuous one).
it "U5 fixture sanity: brainstorm-terminal ledger with a clean brainstorm unit -> predicate met"
bs_met="$("$PY" - "$REPO" "$LEDGER_PY" "$BS_UNITS" "$BS_ORDER" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, units_json, po_json = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, "u5-met", backend="ce", units=json.loads(units_json),
              loop_phase="brainstorm", phase_order=json.loads(po_json),
              terminal_phase="brainstorm")
print(m.read_ledger(repo, "u5-met")["exit_predicate_result"]["met"])
PYEOF
)"
assert_eq "True" "$bs_met"

# Main fixture — Guard A at the real terminal (brainstorm) stops -> done.
# (Guard A's denylist already stopped here pre-fix; the fix keeps it stopping,
#  now for the RIGHT reason: is_terminal_phase(brainstorm)==True.)
it "U5 Guard A: predicate-met at the recipe's terminal phase (brainstorm) -> stop, loop_phase=done"
assert_eq "stop,done" "$(u5_guard u5a-main "$BS_UNITS" "$BS_ORDER" brainstorm brainstorm brainstorm A 0)"

# Main fixture — Guard B at the real terminal (brainstorm) stops -> done.
# DELIBERATE-FAIL: pre-fix Guard B is `phase == "work"`, so brainstorm != work
# returns None (no stop) -> "none,brainstorm". Post-fix it routes through
# is_terminal_phase(brainstorm)==True -> "stop,done".
it "U5 Guard B: predicate-met-after-advance at the terminal phase (brainstorm) -> stop, loop_phase=done"
assert_eq "stop,done" "$(u5_guard u5b-main "$BS_UNITS" "$BS_ORDER" brainstorm brainstorm brainstorm B 0)"

# Converse — brainstorm is NOT terminal (terminal=work) and a STALE met is cached
# at the mid-run brainstorm phase. Guard A must NOT stop.
# DELIBERATE-FAIL: pre-fix Guard A's denylist (`phase != plan and phase != handoff`)
# over-fires and stops at the non-terminal brainstorm -> "stop,done". Post-fix it
# routes through is_terminal_phase(brainstorm)==False -> "none,brainstorm".
it "U5 converse: stale met at a NON-terminal phase (brainstorm, terminal=work) -> Guard A does NOT stop"
assert_eq "none,brainstorm" \
  "$(u5_guard u5-conv '[{"id":"U1","phase":"brainstorm","state":"dispatched"}]' '["plan","handoff","brainstorm","work"]' work brainstorm brainstorm A 1)"

# Regression — a shipped work-terminal recipe still stops exactly as before at the
# work phase, through BOTH guards. is_terminal_phase(work)==True keeps the default
# grammar's behavior byte-for-byte.
it "U5 regression: work-terminal recipe -> Guard A stops at work (unchanged) -> done"
assert_eq "stop,done" \
  "$(u5_guard u5-reg-a '[{"id":"U1","state":"verdict-returned","findings":[]}]' '["plan","handoff","work"]' work work work A 0)"

it "U5 regression: work-terminal recipe -> Guard B stops at work (unchanged) -> done"
assert_eq "stop,done" \
  "$(u5_guard u5-reg-b '[{"id":"U1","state":"verdict-returned","findings":[]}]' '["plan","handoff","work"]' work work work B 0)"


# ─── U1: watchdog_wakeup_delay — dispatch-time fallback heartbeat delay ───────
# Closes the inverted work-phase carve-out: the driver arms ONE long fallback
# ScheduleWakeup at dispatch so detect_and_halt_stalled fires while work is in
# flight. watchdog_wakeup_delay is the pure helper that computes that delay —
# the MINIMUM in-flight stall_threshold_seconds (default 600), clamped to the
# ScheduleWakeup bound [60, 3600]. Returns None when nothing is dispatched (the
# driver arms nothing). Pure over a ledger dict; no I/O, no on-disk ledger.

# wwd <units-json>  — print watchdog_wakeup_delay({"steps": <units-json>}).
wwd() {
  "$PY" - "$PULSE_PY" "$1" <<'PYEOF'
import sys, importlib.util, json
pulse_py, units_json = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
print(t.watchdog_wakeup_delay({"steps": json.loads(units_json)}))
PYEOF
}

it "U1 watchdog_wakeup_delay: single dispatched unit, no override -> default 600"
assert_eq "600" "$(wwd '[{"id":"U1","state":"dispatched"}]')"

it "U1 watchdog_wakeup_delay: MIN across dispatched units (non-dispatched ignored)"
# U1=300, U2=120 dispatched -> min 120; U3 pending with a smaller 10 is ignored.
assert_eq "120" "$(wwd '[{"id":"U1","state":"dispatched","stall_threshold_seconds":300},{"id":"U2","state":"dispatched","stall_threshold_seconds":120},{"id":"U3","state":"pending","stall_threshold_seconds":10}]')"

it "U1 watchdog_wakeup_delay: a 30s override clamps UP to the 60s floor"
assert_eq "60" "$(wwd '[{"id":"U1","state":"dispatched","stall_threshold_seconds":30}]')"

it "U1 watchdog_wakeup_delay: a 4000s override clamps DOWN to the 3600s ceiling"
assert_eq "3600" "$(wwd '[{"id":"U1","state":"dispatched","stall_threshold_seconds":4000}]')"

it "U1 watchdog_wakeup_delay: nothing dispatched -> None (driver arms nothing)"
assert_eq "None" "$(wwd '[{"id":"U1","state":"pending"},{"id":"U2","state":"verdict-returned","findings":[]}]')"

# ─── U2: reap_unit — attempt-gated idempotent reap primitive ──────────────────
# The death path's counterpart to detect_and_halt_stalled's timeout path. On a
# native death signal the driver reconciles the dead unit via reap_unit, which
# idempotently flips dispatched -> stalled ONLY when the unit is `dispatched`
# AND its current `attempt` equals the passed attempt. The attempt gate is the
# load-bearing correctness point: without it a late death event from a driver-
# killed attempt-1 agent would stall a fresh, healthy attempt-2 retry. The two
# detection paths (timeout watchdog + native death) therefore converge on exactly
# ONE stall per attempt. Covers R3, AE2, AE3.

# reap <run> <unit> <attempt>  — call reap_unit on the on-disk ledger; print its
# return value (True/False/None). Mirrors scenario 10's t.pulse_advance access.
reap() {
  "$PY" - "$REPO" "$1" "$2" "$3" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util
repo, run, unit, attempt, pulse_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
print(t.pulse_advance.reap_unit(repo, run, unit, int(attempt)))
PYEOF
}

it "U2 reap_unit: flips a dispatched unit at the matching attempt -> stalled (returns True)"
DISP_R="$(now_minus 5)"
ledger_init "reap-match-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","attempt":1}]' "$DISP_R")" \
  >/dev/null 2>&1
# Verify the fixture actually produced attempt 1 before asserting on the gate.
attempt_match="$(ledger_field "reap-match-run" 'L["steps"][0]["attempt"]')"
ret_match="$(reap "reap-match-run" "U1" 1)"
st_match="$(ledger_field "reap-match-run" 'L["steps"][0]["state"]')"
if [ "$attempt_match" = "1" ] && [ "$ret_match" = "True" ] && [ "$st_match" = "stalled" ]; then
  pass
else
  fail "attempt=$attempt_match ret=$ret_match state=$st_match (expected 1/True/stalled)"
fi

it "U2 reap_unit: no-op on an already-stalled unit (returns False, state unchanged)"
# Second reap of a unit the timeout watchdog already stalled: stalled -> stalled
# is not a legal edge, so reap is a no-op, not a transition.
ledger_init "reap-stalled-run" '[{"id":"U1","state":"stalled","attempt":1}]' >/dev/null 2>&1
ret_stalled="$(reap "reap-stalled-run" "U1" 1)"
st_stalled="$(ledger_field "reap-stalled-run" 'L["steps"][0]["state"]')"
if [ "$ret_stalled" = "False" ] && [ "$st_stalled" = "stalled" ]; then
  pass
else
  fail "ret=$ret_stalled state=$st_stalled (expected False/stalled)"
fi

it "U2 reap_unit: no-op on a verdict-returned unit (returns False, state unchanged)"
ledger_init "reap-vr-run" '[{"id":"U1","state":"verdict-returned","findings":[],"attempt":1}]' >/dev/null 2>&1
ret_vr="$(reap "reap-vr-run" "U1" 1)"
st_vr="$(ledger_field "reap-vr-run" 'L["steps"][0]["state"]')"
if [ "$ret_vr" = "False" ] && [ "$st_vr" = "verdict-returned" ]; then
  pass
else
  fail "ret=$ret_vr state=$st_vr (expected False/verdict-returned)"
fi

it "U2 reap_unit: no-op when passed attempt is OLDER than current (late death after retry) -> stays dispatched"
# The load-bearing case: a fresh attempt-2 retry is in flight; a late death event
# from the superseded attempt-1 agent must NOT stall it. Unit dispatched at
# attempt 2; reap with attempt 1 is a no-op.
DISP_S="$(now_minus 5)"
ledger_init "reap-super-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","attempt":2}]' "$DISP_S")" \
  >/dev/null 2>&1
# Verify the fixture actually produced attempt 2 (the retry generation).
cur_attempt="$(ledger_field "reap-super-run" 'L["steps"][0]["attempt"]')"
ret_super="$(reap "reap-super-run" "U1" 1)"
st_super="$(ledger_field "reap-super-run" 'L["steps"][0]["state"]')"
if [ "$cur_attempt" = "2" ] && [ "$ret_super" = "False" ] && [ "$st_super" = "dispatched" ]; then
  pass
else
  fail "cur_attempt=$cur_attempt ret=$ret_super state=$st_super (expected 2/False/dispatched)"
fi

it "U2 double detection: past-threshold AND reaped yields exactly ONE stalled (second path is a no-op)"
# The dedup-by-design property (AE3): a unit flagged by BOTH the native death
# path (reap_unit) and the timeout watchdog (detect_and_halt_stalled) is stalled
# exactly once. reap flips it first; the timeout path then finds nothing NEW to
# stall; a re-fire of reap is a no-op.
DISP_D="$(now_minus 3600)"
ledger_init "reap-double-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10,"attempt":1}]' "$DISP_D")" \
  >/dev/null 2>&1
double_out="$("$PY" - "$REPO" "reap-double-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# Path 1 (native death): reap_unit flips dispatched -> stalled.
r1 = t.pulse_advance.reap_unit(repo, run, "U1", 1)
# Path 2 (timeout watchdog) fires on the SAME unit: it is already stalled, so
# detect_and_halt_stalled records NO NEW stall (newly_stalled is empty).
now = datetime.datetime.now(datetime.timezone.utc)
led = ledg.read_ledger(repo, run)
fresh, halted, newly = t.pulse_advance.detect_and_halt_stalled(repo, run, led, now)
# A re-fire of the death path is also a no-op.
r2 = t.pulse_advance.reap_unit(repo, run, "U1", 1)
after = ledg.read_ledger(repo, run)
print("%s,%s,%s,%s" % (r1, (",".join(newly) if newly else "-"), r2, after["steps"][0]["state"]))
PYEOF
)"
# reap reaped once (True); the timeout path found nothing NEW (-); the re-fire is
# a no-op (False); net state is exactly one stalled.
if [ "$double_out" = "True,-,False,stalled" ]; then
  pass
else
  fail "double_out=$double_out (expected True,-,False,stalled)"
fi

# ─── U3: reap_pending marker — kill-verifiability across the reap paths ────────
# The `dispatched -> stalled` transition (in BOTH detect_and_halt_stalled and
# reap_unit) sets `reap_pending=True` to record that a live-agent kill is OWED —
# the kill itself (TaskStop + SIGTERM) is model-side (no reaping primitive in
# lib/, KTD2), so Python cannot observe it. The driver clears the marker via
# clear_reap_pending right AFTER issuing the kill; anything still in
# units_awaiting_reap on a later pulse is a forgotten kill ("requested but
# unconfirmed"). Covers U3's reap_pending semantics.

it "U3 reap_pending: reap_unit sets reap_pending; unit is in units_awaiting_reap; clear_reap_pending removes it"
DISP_RP="$(now_minus 5)"
ledger_init "reap-pending-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","attempt":1}]' "$DISP_RP")" \
  >/dev/null 2>&1
rp_flow="$("$PY" - "$REPO" "reap-pending-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# Reap the dispatched unit at its matching attempt -> stalled + reap_pending set.
t.pulse_advance.reap_unit(repo, run, "U1", 1)
led1 = ledg.read_ledger(repo, run)
marker_after_reap = led1["steps"][0].get("reap_pending")
awaiting_before = t.pulse_advance.units_awaiting_reap(led1)
# Driver issues the model-side kill, then clears the marker.
t.pulse_advance.clear_reap_pending(repo, run, "U1")
led2 = ledg.read_ledger(repo, run)
marker_after_clear = led2["steps"][0].get("reap_pending")
awaiting_after = t.pulse_advance.units_awaiting_reap(led2)
print("%s|%s|%s|%s" % (
    marker_after_reap,
    ",".join(awaiting_before) or "-",
    marker_after_clear,
    ",".join(awaiting_after) or "-",
))
PYEOF
)"
# After reap: reap_pending True, U1 awaiting. After clear: reap_pending False, none awaiting.
if [ "$rp_flow" = "True|U1|False|-" ]; then
  pass
else
  fail "rp_flow=$rp_flow (expected True|U1|False|-)"
fi

it "U3 reap_pending: detect_and_halt_stalled (the timeout path) ALSO sets reap_pending"
DISP_DP="$(now_minus 3600)"
ledger_init "reap-pending-timeout" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10,"attempt":1}]' "$DISP_DP")" \
  >/dev/null 2>&1
tp_flow="$("$PY" - "$REPO" "reap-pending-timeout" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
now = datetime.datetime.now(datetime.timezone.utc)
led = ledg.read_ledger(repo, run)
fresh, halted, newly = t.pulse_advance.detect_and_halt_stalled(repo, run, led, now)
after = ledg.read_ledger(repo, run)
awaiting = t.pulse_advance.units_awaiting_reap(after)
print("%s,%s,%s" % (
    after["steps"][0]["state"],
    after["steps"][0].get("reap_pending"),
    ",".join(awaiting) or "-",
))
PYEOF
)"
# The timeout-stalled unit is stalled, carries reap_pending=True, and is awaiting reap.
if [ "$tp_flow" = "stalled,True,U1" ]; then
  pass
else
  fail "tp_flow=$tp_flow (expected stalled,True,U1)"
fi

it "U1 race-regression: heartbeat detect over a STALE snapshot whose unit landed a verdict -> no crash, unit dropped from newly_stalled"
# U1's dispatch-time heartbeat runs detect_and_halt_stalled WHILE background agents
# are live. If a healthy sibling lands its verdict (record_verdict) between the
# snapshot read and the per-unit stalled flip, `stalled` is no longer a legal edge
# from verdict-returned. Before the try/except guard this raised InvalidTransition
# and wedged the run — the exact hang the watchdog exists to prevent.
RACE_AT="$(now_minus 3600)"
ledger_init "race-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10,"attempt":1}]' "$RACE_AT")" \
  ce work >/dev/null 2>&1
race_out="$("$PY" - "$REPO" "race-run" "$PULSE_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
repo, run, pulse_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# Snapshot read WHILE dispatched (what the heartbeat pulse holds).
led = ledg.read_ledger(repo, run)
# A concurrent healthy sibling lands its verdict on disk AFTER the snapshot.
ledg.record_verdict(repo, run, "U1", [], attempt=1)
now = datetime.datetime.now(datetime.timezone.utc)
newly = []
try:
    fresh, halted, newly = t.pulse_advance.detect_and_halt_stalled(repo, run, led, now)
    crashed = "no"
except Exception as e:  # noqa: BLE001 — the point is that NOTHING escapes.
    crashed = type(e).__name__
after = ledg.read_ledger(repo, run)
print("%s,%s,%s" % (crashed, after["steps"][0]["state"], (",".join(newly) if newly else "-")))
PYEOF
)"
# No crash; the raced unit stays verdict-returned and is dropped from newly_stalled.
if [ "$race_out" = "no,verdict-returned,-" ]; then
  pass
else
  fail "race_out=$race_out (expected no,verdict-returned,-)"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "pulse.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
