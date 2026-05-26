#!/usr/bin/env bash
# auto U4 unit test: lib/tick.py — one ScheduleWakeup-paced advance
# of the ledger. The tick reads ALL loop state from the disk ledger, does ONE
# smallest-useful advance inside a try/except, persists atomically via
# ledger.py, and emits the re-arm INTENT as a JSON dict (it NEVER calls
# ScheduleWakeup — that is a model tool, not a CLI).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/ledger.test.sh. It does NOT
# source claude-modes' test-helpers nor auto shared helpers (those
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
#   7. anti-livelock: a plan-loop run advances plan -> deepen -> review_plan
#      ACROSS fresh-process ticks WITHOUT re-planning. The tick persists the
#      executed plan_step (schema §3.1) so the next tick reads it instead of
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
#      `dispatched` past its stall_threshold (the orchestrator rescue-swallow P3
#      bound) -> stalled. Deliberate-fail control: WITHOUT the reaper the phantom
#      stays dispatched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TICK_PY="${AUTO_ROOT}/lib/tick.py"
TICK_SH="${AUTO_ROOT}/lib/tick.sh"
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
if [ "$action" = "rearm" ] && [ "$delay" = "60" ] && [ "$prompt" = "/auto-tick rearm-run" ] \
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
tmp_left4="$(find "$REPO/.claude/auto" -name '.ledger.*' 2>/dev/null | wc -l | tr -d ' ')"
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
CLAUDE_AUTO_REPO="$REPO" bash "$TICK_SH" "stateless-run" >/dev/null 2>&1
st1_u1="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U1")')"
st1_u2="$(ledger_field "stateless-run" 'next(u["state"] for u in L["units"] if u["id"]=="U2")')"
# Second fresh process — must observe the first's mutation and advance the next.
CLAUDE_AUTO_REPO="$REPO" bash "$TICK_SH" "stateless-run" >/dev/null 2>&1
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

# ─── Scenario 7: anti-livelock — plan_step advances across fresh-process ticks ─
# THE integration-blocking bug this fix closes: next_plan_step is pure over the
# ledger and each tick is a fresh process. If the tick does not persist the
# executed plan_step, every tick reads plan_step==null, the adapter returns
# "plan", and the plan-loop re-plans forever. With the persist (ledger.set_loop
# plan_step=...), three fresh-process ticks walk plan -> deepen -> review_plan.
#
# We use the REAL ce adapter (its plan/deepen/review_plan ops are pure
# envelope-returning no-ops). One PENDING unit keeps all_units_terminal==false
# so the predicate never short-circuits the plan-loop to done. gaps_open stays
# NULL (Bug #5 fix: the live envelope carries no gap_set, so the engine never
# defaults it to 0 — the never-reviewed value is null, not zero), but the
# coherence guard keys on plan_step=="review_plan" specifically, so it does NOT
# fire until AFTER a real review_plan step has been persisted — exactly the walk
# we assert.
it "anti-livelock: 3 fresh-process plan ticks walk plan -> deepen -> review_plan (step persisted, no re-plan)"
ledger_init "antilivelock-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
step0="$(ledger_field "antilivelock-run" 'L.get("plan_step")')"
CLAUDE_AUTO_REPO="$REPO" bash "$TICK_SH" "antilivelock-run" >/dev/null 2>&1
step1="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
CLAUDE_AUTO_REPO="$REPO" bash "$TICK_SH" "antilivelock-run" >/dev/null 2>&1
step2="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
CLAUDE_AUTO_REPO="$REPO" bash "$TICK_SH" "antilivelock-run" >/dev/null 2>&1
step3="$(ledger_field "antilivelock-run" 'L["plan_step"]')"
# init -> null; tick1 ran "plan"; tick2 ran "deepen"; tick3 ran "review_plan".
# The walk MONOTONICALLY ADVANCES — it never gets stuck re-running "plan".
if [ "$step0" = "None" ] && [ "$step1" = "plan" ] && [ "$step2" = "deepen" ] \
   && [ "$step3" = "review_plan" ]; then
  pass
else
  fail "plan_step walk: init=$step0 t1=$step1 t2=$step2 t3=$step3 (expected None/plan/deepen/review_plan)"
fi

it "deliberate-fail control: WITHOUT the persist, plan_step stays stuck at the first step -> livelock (proves the persist is load-bearing)"
# Run the SAME plan-loop, but neuter the tick's persist by monkeypatching
# ledger.set_loop to DROP the plan_step kwarg (simulating the pre-fix tick that
# advanced the step but never wrote it back). Three ticks must then NEVER record
# a step beyond null — the adapter would re-return "plan" every time (livelock).
# This proves the prior test passes BECAUSE of the persist, not by accident.
stuck="$("$PY" - "$REPO" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, tick_py, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(spec); spec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)

run = "antilivelock-nopersist"
ledg.init_ledger(repo, run, adapter="ce", units=[{"id":"U1","state":"pending"}], loop_phase="plan")

# Neuter the persist: t.ledger.set_loop forwarded WITHOUT plan_step. The tick's
# beat write (set_loop(driver="self", beat=True)) still works; only the
# plan_step persist is dropped — exactly the pre-fix behaviour.
_real_set_loop = ledg.set_loop
def _no_plan_step_set_loop(repo_root, run_id, **kw):
    kw.pop("plan_step", None)
    return _real_set_loop(repo_root, run_id, **kw)
t.ledger.set_loop = _no_plan_step_set_loop

steps = []
for _ in range(3):
    t.dispatch_tick(repo, run)
    steps.append(ledg.read_ledger(repo, run).get("plan_step"))
# Without the persist every read is None -> the plan-loop is livelocked.
print("stuck" if all(s is None for s in steps) else "ADVANCED:%r" % steps)
PYEOF
)"
assert_eq "stuck" "$stuck"

# ─── Scenario 8: Bug #5 — gaps_open persisted from a DICT review_plan return ──
# advance_plan_loop must persist gaps_open from BOTH a bare list AND a dict
# envelope carrying `gap_set` (the LIVE adapters return a dict — that branch was
# previously dead, so gaps_open was never written from a real review and plan-met
# fired after a SINGLE review pass, making the deepen-refinement loop unreachable).
# We exercise the DICT path specifically with a stub adapter whose review_plan
# returns {"gap_set": [...]} of length N.
#
# Verify-RED: lib/tick.py advance_plan_loop, delete the
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
gaps_dict="$("$PY" - "$REPO" "gaps-dict-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)

class DictGapAdapter:
    # Live-adapter shape: review_plan returns a DICT envelope carrying gap_set.
    def next_plan_step(self, ledger):
        return "review_plan"
    def review_plan(self, ledger):
        return {"op": "review_plan", "gap_set": [{"id": "g1"}, {"id": "g2"}, {"id": "g3"}]}

led = ledg.read_ledger(repo, run)
t.advance_plan_loop(repo, run, led, DictGapAdapter())
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
empty_out="$("$PY" - "$REPO" "gaps-empty-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# Use the REAL ce adapter for next_plan_step (the live sequencer) but feed an
# empty-gap_set dict via a thin subclass of its review_plan, so the "done"
# coherence guard is exercised end-to-end after a real (empty) review.
import importlib.util as _il
aspec = _il.spec_from_file_location("adapter_ce", ledger_py.replace("ledger.py", "adapter-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)

class EmptyGapAdapter(ace.Adapter):
    def review_plan(self, ledger):
        return {"op": "review_plan", "gap_set": []}

led = ledg.read_ledger(repo, run)
adapter = EmptyGapAdapter()
t.advance_plan_loop(repo, run, led, adapter)
led2 = ledg.read_ledger(repo, run)
gaps = led2["exit_predicate_result"]["gaps_open"]
# Now ask the live sequencer for the next step: review_plan persisted +
# gaps_open==0 -> the §4.1 coherence guard returns "done".
nxt = adapter.next_plan_step(led2)
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
# no dedicated test: the REAL ce/native adapters' review_plan returns a PREPARE
# envelope WITHOUT a gap_set key — the model fills it out-of-band AFTER the engine
# reads. The correct behaviour (the round-2 premature-plan-met fix) is that
# gaps_open stays NULL (never a default 0), so plan-met does NOT fire after one
# un-reviewed pass and the deepen-refinement loop stays open. A regression that
# defaulted gap_set=[] for the keyless envelope would silently reopen the bug:
# gaps_open=0 -> plan-met -> the loop exits before a real review reports gaps.
#
# We drive advance_plan_loop with the REAL ce adapter (review_plan returns the
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
null_out="$("$PY" - "$REPO" "gaps-null-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
# REAL ce adapter: review_plan returns the live PREPARE envelope, which carries
# NO gap_set key (the model fills it out-of-band after the engine reads).
import importlib.util as _il
aspec = _il.spec_from_file_location("adapter_ce", ledger_py.replace("ledger.py", "adapter-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)
adapter = ace.Adapter()
# Guard: confirm the envelope really has NO gap_set key (the shape under test).
env = adapter.review_plan(ledg.read_ledger(repo, run))
assert isinstance(env, dict) and "gap_set" not in env, "envelope unexpectedly has gap_set: %r" % env

led = ledg.read_ledger(repo, run)
t.advance_plan_loop(repo, run, led, adapter)
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
buggy_out="$("$PY" - "$REPO" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, tick_py, ledger_py = sys.argv[1:4]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
import importlib.util as _il
aspec = _il.spec_from_file_location("adapter_ce", ledger_py.replace("ledger.py", "adapter-ce.py"))
ace = _il.module_from_spec(aspec); aspec.loader.exec_module(ace)

run = "gaps-null-buggy"
ledg.init_ledger(repo, run, adapter="ce", units=[{"id":"U1","state":"pending"}], loop_phase="plan")
ledg.set_loop(repo, run, plan_step="deepen")
adapter = ace.Adapter()
result = adapter.review_plan(ledg.read_ledger(repo, run))  # live envelope, NO gap_set
# THE BUG: default-zero extraction for a keyless envelope.
buggy_gap_set = result.get("gap_set", [])
ledg.set_gaps_open(repo, run, len(buggy_gap_set))
ledg.set_loop(repo, run, plan_step="review_plan")
L = ledg.read_ledger(repo, run)
go = L["exit_predicate_result"]["gaps_open"]
met = L["exit_predicate_result"]["met"]
nxt = adapter.next_plan_step(L)
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

# ─── Scenario 10: phantom-dispatch self-heal (orchestrator P3 bound) ──────────
# orchestrator.dispatch_batch's launch guard (Bug #8) marks a unit stalled if
# launch_fn raises. If the rescue transition (dispatched->stalled) ALSO raises,
# the broadened `except Exception` swallows it and the unit stays `dispatched`
# with no agent — a phantom. The CLAIM bounding that P3 is that the phantom
# self-heals: detect_and_halt_stalled reclaims ANY dispatched-past-stall_threshold
# unit on a later tick. This test proves that bound.
#
# We simulate the phantom directly (a unit stuck `dispatched` with dispatched_at
# older than its stall_threshold, no verdict) and run detect_and_halt_stalled.
# The reaper must transition it to `stalled` (reclaimed) with last_error null
# (a plain timeout, not an adapter-raise). The deliberate-fail control is the
# ABSENCE of the reaper call: without it, the phantom stays `dispatched` forever.
it "phantom-dispatch self-heal: detect_and_halt_stalled reclaims a dispatched-past-threshold phantom -> stalled (last_error null)"
PHANTOM_AT="$(now_minus 3600)"
ledger_init "phantom-run" \
  "$(printf '[{"id":"U1","state":"dispatched","dispatched_at":"%s","stall_threshold_seconds":10}]' "$PHANTOM_AT")" \
  ce work >/dev/null 2>&1
# Baseline: the phantom IS dispatched before the reaper runs (the swallowed-rescue
# state the orchestrator P3 leaves behind).
st_before="$(ledger_field "phantom-run" 'L["units"][0]["state"]')"
phantom_out="$("$PY" - "$REPO" "phantom-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
repo, run, tick_py, ledger_py = sys.argv[1:5]
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
ledg = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(ledg)
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
led = ledg.read_ledger(repo, run)
now = datetime.datetime.now(datetime.timezone.utc)
fresh, halted, newly = t.detect_and_halt_stalled(repo, run, led, now)
after = ledg.read_ledger(repo, run)
u = after["units"][0]
print("%s,%s,%s" % (u["state"], (",".join(newly)) if newly else "-", u.get("last_error")))
PYEOF
)"
st_after="$(ledger_field "phantom-run" 'L["units"][0]["state"]')"
# Before: dispatched (phantom). After the reaper: stalled, newly_stalled=[U1],
# last_error null (plain timeout — NOT an adapter-raise error object).
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
noreap_state="$(ledger_field "phantom-noreap-run" 'L["units"][0]["state"]')"
assert_eq "dispatched" "$noreap_state"

# ─── U6: plan-done enumerate→persist (the F4 producer wiring) ───────────────
# At plan-done, advance_plan_loop calls the adapter's enumerate_plan_units and
# persists the result onto the plan unit's dispatch_context.enumerated_units, so
# the U5b emitter can read it. Drive it with a fake adapter whose next_plan_step
# returns "done" and enumerate_plan_units returns a bare list.
it "U6: plan-done persists enumerate_plan_units output to dispatch_context"
ledger_init "enum-run" '[{"id":"plan","phase":"plan","state":"dispatched"}]' ce plan >/dev/null 2>&1
enum_res="$("$PY" - "$REPO" "enum-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(m)

class FakeAdapter:
    def next_plan_step(self, ledger): return "done"
    def enumerate_plan_units(self, ledger):
        return [{"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]

led = m.read_ledger(repo, run)
result, raised = t.advance_plan_loop(repo, run, led, FakeAdapter())
after = m.read_ledger(repo, run)
plan_unit = after["units"][0]
enum = (plan_unit.get("dispatch_context") or {}).get("enumerated_units") or []
print("%s,%s,%s" % (result.get("advanced"), raised,
                    ",".join(u["id"] for u in enum)))
PYEOF
)"
# advanced plan-done, no raise, and the 2 enumerated units are persisted.
assert_eq "plan-done,None,w1,w2" "$enum_res"

# ─── Fix-pass H: prepare/execute contract is LOUD in rearm intent ────────────
# Field bug (2026-05-25, second agent): ticked 5 times expecting units to
# materialize; ledger stayed at units=[] because they never executed the
# prepared invocation. The rearm intent now carries an operator_guidance
# field naming the contract phase-by-phase, plus a gaps_open_guard when
# plan_step==review_plan AND gaps_open is null (Trap 2 from the prepare/
# execute memory). Three assertions cover both new fields and a deliberate-
# fail control.

it "fix-pass H: plan-loop rearm carries operator_guidance naming prepare/execute"
ledger_init "guidance-plan-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guidance_plan="$("$PY" - "$REPO" "guidance-plan-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

# Use the bundled CE adapter so a real plan-loop tick fires.
intent = t.dispatch_tick(repo, run)
g = intent.get("operator_guidance", "")
print("ok" if ("prepare/execute contract" in g
               and "YOU must run it" in g
               and "NO-OP" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guidance_plan"

it "fix-pass H: gaps_open_guard fires when plan_step==review_plan AND gaps_open is null (Trap 2)"
ledger_init "gap-guard-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guard_msg="$("$PY" - "$REPO" "gap-guard-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(L)

# Force the exact trap state: plan_step=review_plan, gaps_open=null (default).
L.set_loop(repo, run, plan_step="review_plan")
intent = t.dispatch_tick(repo, run)
g = intent.get("gaps_open_guard", "")
print("ok" if ("gaps_open is NULL" in g and "set_gaps_open" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guard_msg"

it "fix-pass H DELIBERATE-FAIL: gaps_open_guard is ABSENT when gaps_open is set (proves the guard discriminates)"
ledger_init "gap-set-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
guard_absent="$("$PY" - "$REPO" "gap-set-run" "$TICK_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py, ledger_py = sys.argv[1:5]
tspec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(tspec); tspec.loader.exec_module(t)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(L)

# gaps_open populated to a real value → guard MUST NOT fire (it'd be noise).
L.set_loop(repo, run, plan_step="review_plan")
L.set_gaps_open(repo, run, 0)
intent = t.dispatch_tick(repo, run)
print("absent" if "gaps_open_guard" not in intent else f"PRESENT:{intent.get('gaps_open_guard')[:80]}")
PYEOF
)"
assert_eq "absent" "$guard_absent"

it "fix-pass H: work-loop rearm carries operator_guidance naming dispatch + yield (fix-pass G)"
ledger_init "guidance-work-run" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}]' \
  ce work >/dev/null 2>&1
guidance_work="$("$PY" - "$REPO" "guidance-work-run" "$TICK_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)

intent = t.dispatch_tick(repo, run)
g = intent.get("operator_guidance", "")
print("ok" if ("YOU drive the" in g
               and "YIELD silently" in g
               and "harness re-invokes" in g) else f"BAD:{g[:120]}")
PYEOF
)"
assert_eq "ok" "$guidance_work"

# ─── Task #31: NO_TICK_LOCK hatch — tested + fenced ─────────────────────────
# Two parts to the close (fix-pass J atop the round-3 P3 promotion):
#   (a) The double-drive guard works: a second tick raises _TickLockHeld while
#       the first holds the run's tick lock (green path).
#   (b) The hatch genuinely disables the guard (CLAUDE_AUTO_TEST_NO_TICK_LOCK=1
#       + CLAUDE_AUTO_TEST_HARNESS=1 → no raise) — the deliberate-fail control
#       per feedback_new_tests_need_deliberate_fail_smoke_check.
#   (c) The hatch is FENCED against accidental production exposure: setting the
#       hatch WITHOUT the harness sentinel does NOT disable the guard (the
#       second tick still raises _TickLockHeld). This is the actual close on
#       task #31's "unfenced" half.

it "task #31 GREEN: double-drive guard fires — second tick raises _TickLockHeld while first holds lock"
ledger_init "tick-lock-green" '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"minor","note":"x"}]}]' >/dev/null 2>&1
green_result="$("$PY" - "$REPO" "tick-lock-green" "$TICK_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
# Outer lock acquires; inner attempt MUST raise _TickLockHeld.
with t._tick_lock(repo, run):
    try:
        with t._tick_lock(repo, run):
            print("NO-RAISE")
    except t._TickLockHeld:
        print("blocked")
PYEOF
)"
assert_eq "blocked" "$green_result"

it "task #31 DELIBERATE-FAIL: with the hatch fully enabled (sentinel + var) the inner lock acquires (proves the guard is real and the hatch is reachable)"
ledger_init "tick-lock-disabled" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
disabled_result="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 "$PY" - "$REPO" "tick-lock-disabled" "$TICK_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
# Hatch ON + sentinel ON → both acquire successfully (no raise). This proves
# the test hatch is wired AND the guard would actually catch concurrent ticks
# in normal operation (otherwise this assertion would pass even without the
# hatch, telling us nothing).
with t._tick_lock(repo, run):
    try:
        with t._tick_lock(repo, run):
            print("both-acquired")
    except t._TickLockHeld:
        print("BLOCKED-DESPITE-HATCH")
PYEOF
)"
assert_eq "both-acquired" "$disabled_result"

it "task #31 FENCE: hatch alone WITHOUT the harness sentinel does NOT disable the guard (production-safety)"
ledger_init "tick-lock-fence" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
# CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 is exported BUT CLAUDE_AUTO_TEST_HARNESS is
# explicitly UNSET. The fence at lib/_bootstrap.py::test_hatch_enabled (and the
# local copy in lib/ledger.py) requires BOTH; with only one, the hatch is
# inert and the guard fires.
fence_result="$(env -u CLAUDE_AUTO_TEST_HARNESS CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 "$PY" - "$REPO" "tick-lock-fence" "$TICK_PY" <<'PYEOF'
import sys, importlib.util
repo, run, tick_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("tick", tick_py)
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
with t._tick_lock(repo, run):
    try:
        with t._tick_lock(repo, run):
            print("HATCH-LEAKED")  # would fire if the fence were broken
    except t._TickLockHeld:
        print("fenced")
PYEOF
)"
assert_eq "fenced" "$fence_result"

# ════════════════════════════════════════════════════════════════════════════
# v0.3.0 U4 — advance_iteration_loop + finally + kill-switch fence + R9
# ════════════════════════════════════════════════════════════════════════════
#
# Each scenario primes a ledger that emulates the post-U6 iteration shape
# (recipes ship iteration + emit_templates blocks; U6 has not landed yet so
# we install them directly via _with_locked_ledger). U4 reads those fields
# through `iteration.evaluate_decision` and the ledger mutators U2 ships.

# Test driver: a python helper that seeds a ledger with an iteration block,
# optionally walks the gate unit to a desired state + decision, then runs
# dispatch_tick and prints a JSON blob with the post-tick state.
u4_driver() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo = sys.argv[1:3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("ledger")
t_spec = importlib.util.spec_from_file_location(
    "tick_under_test", os.path.join(auto_root, "lib", "tick.py"))
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)
op = sys.argv[3]


def init_a2(run, *, decision=None, attempts=0, active_wall=0,
            max_attempts=5, max_wall=None, plan_units=("plan-1","plan-2","plan-3"),
            gate_state="verdict-returned", emit_count=None):
    """Build an A2-shaped ledger: 3 plan units (all 'fixed' so terminal) +
    a 'judge' gate unit. The gate is walked to ``gate_state`` (default
    verdict-returned via record_verdict) and optionally tagged with the
    given ``decision`` via set_verdict_decision."""
    p = m.ledger_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    units = [
        {"id": pid, "state": "fixed", "phase": "plan",
         "findings": []}
        for pid in plan_units
    ]
    units.append({"id": "judge", "state": "pending", "phase": "work",
                  "depends_on": list(plan_units)})
    m.init_ledger(repo, run, adapter="ce", loop_phase="work",
                  phase_order=["plan", "seam", "work"], terminal_phase="work",
                  units=units)
    # Seed iteration + emit_templates block.
    def seed(L):
        bound = {"max_attempts": max_attempts}
        if max_wall is not None: bound["max_wall_seconds"] = max_wall
        L["iteration"] = {"gate_unit": "judge",
                          "emit_template": "plan-candidate", "bound": bound}
        L["emit_templates"] = {
            "plan-candidate": {
                "phase": "plan",
                "invokes": {"adapter_op": "next_plan_step"},
                "id_prefix": "plan-"
            }
        }
        L["iteration_attempts"] = attempts
        L["active_wall_seconds"] = active_wall
        L["iteration_emit_count"] = len(plan_units)
        # Walk gate to verdict-returned via grammar-valid edges if requested.
        for u in L["units"]:
            if u["id"] == "judge":
                if gate_state == "verdict-returned":
                    u["state"] = "dispatched"
    m._with_locked_ledger(repo, run, seed)
    if gate_state == "verdict-returned":
        m.record_verdict(repo, run, "judge", [])
    if decision is not None:
        payload = None
        if emit_count is not None:
            payload = {"emit_count": emit_count}
        m.set_verdict_decision(repo, run, "judge", decision, payload=payload)
    if gate_state == "verdict-returned" and decision == "advance":
        # Advance requires winner_unit_id for downstream emitters; set it.
        m.set_winner_unit_id(repo, run, "judge", plan_units[0])


def init_a1(run, units=None):
    """a1-shape: no iteration block, no gate_unit, no emit_templates. U4
    must early-return at step 1 with zero ledger writes."""
    p = m.ledger_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    u = units or [{"id": "U1", "state": "verdict-returned",
                   "findings": [{"severity": "blocker", "note": "open"}]}]
    m.init_ledger(repo, run, adapter="ce", loop_phase="work",
                  phase_order=["plan", "seam", "work"], terminal_phase="work",
                  units=u)


if op == "advance":
    # GREEN: gate says advance. evaluate_decision returns "advance"; the
    # caller falls through to the standard flow. Because the gate hasn't
    # set winner_unit_id (no winner needed in this minimal test), the
    # short-circuit at lines 564-576 should fire normally (work phase, met
    # composed against not-iteration_pending which is False here).
    init_a2("u4-advance", decision="advance", attempts=0)
    r = t.dispatch_tick(repo, "u4-advance")
    led = m.read_ledger(repo, "u4-advance")
    print(json.dumps({
        "action": r.get("action"),
        "reason": r.get("reason"),
        "iteration_attempts": led.get("iteration_attempts"),
        "loop_phase": led.get("loop_phase"),
    }))

elif op == "iterate-under-bound":
    # GREEN: gate says iterate, attempts < max. advance_iteration_loop calls
    # atomic_iterate_step (increment + emit 2 units + reset). After the tick
    # the gate is pending again, attempts=2, two new plan units appear,
    # gate depends_on now includes them, and the tick re-arms.
    init_a2("u4-iter-under", decision="iterate", attempts=1, max_attempts=5,
            emit_count=2)
    r = t.dispatch_tick(repo, "u4-iter-under")
    led = m.read_ledger(repo, "u4-iter-under")
    plan_ids = sorted(u["id"] for u in led["units"] if u.get("phase") == "plan")
    judge = next(u for u in led["units"] if u["id"] == "judge")
    print(json.dumps({
        "action": r.get("action"),
        "advanced": (r.get("advance") or {}).get("advanced"),
        "iteration_attempts": led.get("iteration_attempts"),
        "plan_ids": plan_ids,
        "judge_state": judge.get("state"),
        "judge_depends_on": sorted(judge.get("depends_on") or []),
        "judge_decision_cleared": (
            judge.get("dispatch_context") or {}).get("decision") is None,
    }))

elif op == "iterate-over-attempts":
    # BOUND: gate says iterate, attempts == max. evaluate_decision returns
    # decision_effective="exit", bound_breached=True. U4 writes bound_override
    # + set_loop(loop_phase="done") DIRECTLY, NOT advance_to_phase. Report
    # carries bound_override + best_so_far (the gate's decision_payload).
    init_a2("u4-bound-attempts", decision="iterate", attempts=5,
            max_attempts=5, emit_count=2)
    r = t.dispatch_tick(repo, "u4-bound-attempts")
    led = m.read_ledger(repo, "u4-bound-attempts")
    judge = next(u for u in led["units"] if u["id"] == "judge")
    dc = judge.get("dispatch_context") or {}
    override = dc.get("bound_override") or {}
    print(json.dumps({
        "action": r.get("action"),
        "reason": r.get("reason"),
        "loop_phase": led.get("loop_phase"),
        "bound_type": override.get("bound"),
        "report_bound": ((r.get("report") or {}).get("bound_override") or {}).get("bound"),
        "report_has_best": (r.get("report") or {}).get("best_so_far") is not None,
        # No advance_to_phase: judge stays in its phase (gate is now pending,
        # but loop_phase is "done").
    }))

elif op == "iterate-over-wall":
    # BOUND: max_wall_seconds. Same shape as the attempts-bound but the bound
    # type names max_wall_seconds.
    init_a2("u4-bound-wall", decision="iterate", attempts=1,
            active_wall=1900, max_attempts=5, max_wall=1800, emit_count=1)
    r = t.dispatch_tick(repo, "u4-bound-wall")
    led = m.read_ledger(repo, "u4-bound-wall")
    judge = next(u for u in led["units"] if u["id"] == "judge")
    override = (judge.get("dispatch_context") or {}).get("bound_override") or {}
    print(json.dumps({
        "action": r.get("action"),
        "reason": r.get("reason"),
        "bound_type": override.get("bound"),
    }))

elif op == "finally-crash-accumulates":
    # R5 / finally: _tick_body raises mid-flight (BoomAdapter inside the
    # plan-loop). The finally clause must accumulate the active-time delta
    # regardless. We measure: before tick: active_wall_seconds=A0; tick
    # raises; after tick: active_wall_seconds > A0. Because the inner
    # try/except in _tick_body_inner CATCHES the adapter raise and converts
    # it to a recorded stall (so _tick_body returns normally), we instead
    # force the raise INSIDE the finally region by monkey-patching ledger
    # read to raise after the body started. Simpler: prove the finally fires
    # on the NORMAL return path too — accumulate_active_time fires once per
    # tick regardless of return path. We probe a regular tick + a tick whose
    # adapter raises (the try/except path inside _tick_body_inner).
    init_a1("u4-fin-crash")
    before = m.read_ledger(repo, "u4-fin-crash").get("active_wall_seconds", 0)
    t.dispatch_tick(repo, "u4-fin-crash")
    after_clean = m.read_ledger(repo, "u4-fin-crash").get("active_wall_seconds", 0)
    # Now drive a raise via a BoomAdapter on a plan-phase ledger (the inner
    # try/except converts it to a stall; the finally still fires).
    p2 = m.ledger_path(repo, "u4-fin-raise")
    if os.path.exists(p2): os.unlink(p2)
    m.init_ledger(repo, "u4-fin-raise", adapter="ce", loop_phase="plan",
                  units=[{"id": "U1", "state": "dispatched",
                          "dispatched_at": "2026-01-01T00:00:00Z",
                          "stall_threshold_seconds": 600}])
    before2 = m.read_ledger(repo, "u4-fin-raise").get("active_wall_seconds", 0)
    class Boom:
        def next_plan_step(self, led):
            raise RuntimeError("boom")
    t.dispatch_tick(repo, "u4-fin-raise", adapter=Boom())
    after_raise = m.read_ledger(repo, "u4-fin-raise").get("active_wall_seconds", 0)
    print(json.dumps({
        "clean_advanced": after_clean > before,
        "raise_advanced": after_raise > before2,
    }))

elif op == "shortcircuit-suppressed-by-iteration":
    # R6: an iteration-pending ledger composes met=False even when the work
    # branch would otherwise compute met=True. The short-circuit at lines
    # 564-576 yields; advance_iteration_loop runs FIRST and iterates.
    init_a2("u4-shortcircuit", decision="iterate", attempts=1, emit_count=1)
    # All plan units terminal + judge verdict-returned with NO findings →
    # blocker=0/major=0/all_units_terminal=True. Without iteration_pending,
    # met would be True. With it, met=False and the loop iterates.
    led = m.read_ledger(repo, "u4-shortcircuit")
    pred_before = led.get("exit_predicate_result") or {}
    r = t.dispatch_tick(repo, "u4-shortcircuit")
    print(json.dumps({
        "iteration_pending_before": pred_before.get("iteration_pending"),
        "met_before": pred_before.get("met"),
        "action": r.get("action"),
        "advanced": (r.get("advance") or {}).get("advanced"),
    }))

elif op == "a1-early-return":
    # R7 a1: no iteration block → advance_iteration_loop returns None at
    # step 1. Zero ledger writes from the helper. The tick proceeds as
    # v0.2.1 (a fix-applied advance on the verdict-returned+blocker unit).
    init_a1("u4-a1")
    before = json.dumps(m.read_ledger(repo, "u4-a1")["units"][0], sort_keys=True)
    # Probe the helper directly to assert it returns None.
    led = m.read_ledger(repo, "u4-a1")
    direct = t.advance_iteration_loop(repo, "u4-a1", led)
    r = t.dispatch_tick(repo, "u4-a1")
    after_state = m.read_ledger(repo, "u4-a1")["units"][0].get("state")
    print(json.dumps({
        "direct_is_none": direct is None,
        "action": r.get("action"),
        "advanced": (r.get("advance") or {}).get("advanced"),
        "state": after_state,
    }))

elif op == "w-early-return":
    # R7 W: same shape as a1 — no iteration block. Different unit set;
    # helper still early-returns at step 1.
    p = m.ledger_path(repo, "u4-w")
    if os.path.exists(p): os.unlink(p)
    m.init_ledger(repo, "u4-w", adapter="ce", loop_phase="work",
                  phase_order=["work"], terminal_phase="work",
                  units=[{"id": "W1", "state": "verdict-returned",
                          "findings": [{"severity": "blocker", "note": "x"}]}])
    led = m.read_ledger(repo, "u4-w")
    direct = t.advance_iteration_loop(repo, "u4-w", led)
    print(json.dumps({"direct_is_none": direct is None}))

elif op == "r9-last-attempt-guidance":
    # R9: iteration_attempts == max_attempts - 1 → INTENT carries
    # "last attempt before bound" guidance. We tick a non-iterating ledger
    # (decision="advance" with attempts=4 < 5) so the rearm path fires.
    # Actually we use a fix-applied path: a1 ledger with iteration block
    # tacked on so the guidance branch fires and we get a rearm intent.
    init_a2("u4-r9-last", decision=None, attempts=4, max_attempts=5)
    # Add a verdict-returned blocker unit so the tick produces a rearm.
    def seed(L):
        L["units"].append({
            "id": "X1", "state": "verdict-returned", "phase": "work",
            "depends_on": [],
            "findings": [{"severity": "blocker", "note": "open"}],
            "invokes": {}, "dispatch_context": {},
            "stall_threshold_seconds": 600, "last_error": None,
            "verdict_at": None, "dispatched_at": None, "attempt": 0,
        })
    m._with_locked_ledger(repo, "u4-r9-last", seed)
    r = t.dispatch_tick(repo, "u4-r9-last")
    guidance = r.get("operator_guidance") or ""
    print(json.dumps({
        "action": r.get("action"),
        "guidance_has_last_attempt": "last attempt before bound" in guidance,
    }))

elif op == "r9-bound-override-guidance":
    # R9: bound_override just written on this tick. operator_guidance must
    # name WHICH bound + best-so-far. This is a stop intent (bound-exit),
    # NOT a rearm — but operator_guidance is built only for rearm. The
    # actual surface is the report.bound_override + report.best_so_far,
    # which IS in the bound-exit return value. Also, immediately AFTER the
    # bound-exit a follow-up tick reads the same gate with bound_override
    # written; if it were to re-arm (a contrived scenario), guidance would
    # surface. For test purposes we probe the helper _iteration_guidance_
    # prefix directly with a primed ledger.
    init_a2("u4-r9-override", decision="iterate", attempts=5, max_attempts=5,
            emit_count=1)
    # Run the tick — it bound-exits. The next call to _operator_guidance_for
    # would surface the override; we probe the helper directly.
    r = t.dispatch_tick(repo, "u4-r9-override")
    led = m.read_ledger(repo, "u4-r9-override")
    prefix = t._iteration_guidance_prefix(led)
    print(json.dumps({
        "report_has_override": (r.get("report") or {}).get("bound_override") is not None,
        "prefix_names_bound": "bound tripped" in prefix and "max_attempts" in prefix,
        "prefix_has_best_so_far": "Best-so-far" in prefix,
    }))

elif op == "kill-switch":
    # Kill-switch: CLAUDE_AUTO_DISABLE_ITERATION=1 alone (v0.3.0 F5 unfenced
    # this — no harness sentinel required) → advance_iteration_loop returns
    # None at step 2. The iterate decision on disk is UNTOUCHED. Tick
    # proceeds as if iteration didn't exist.
    init_a2("u4-killswitch", decision="iterate", attempts=1, max_attempts=5,
            emit_count=2)
    led = m.read_ledger(repo, "u4-killswitch")
    os.environ["CLAUDE_AUTO_DISABLE_ITERATION"] = "1"
    os.environ["CLAUDE_AUTO_TEST_HARNESS"] = "1"
    try:
        direct = t.advance_iteration_loop(repo, "u4-killswitch", led)
    finally:
        del os.environ["CLAUDE_AUTO_DISABLE_ITERATION"]
        # Don't unset the sentinel — tests/run.sh exports it for the whole
        # process tree; locally setting it here is harmless.
    after = m.read_ledger(repo, "u4-killswitch")
    judge = next(u for u in after["units"] if u["id"] == "judge")
    print(json.dumps({
        "direct_is_none": direct is None,
        "attempts_unchanged": after.get("iteration_attempts") == 1,
        "decision_still_iterate": (
            (judge.get("dispatch_context") or {}).get("decision") == "iterate"
        ),
    }))

elif op == "integration-a2-iterate":
    # Production-path drive: init A2-shape ledger; gate writes record_verdict
    # + set_verdict_decision("iterate", payload={emit_count: 2}); tick re-
    # emits plan-4/5 + resets judge. Mirrors v0.2.0 fix-pass I's pattern.
    init_a2("u4-int-a2", decision="iterate", attempts=0, max_attempts=5,
            emit_count=2)
    t.dispatch_tick(repo, "u4-int-a2")
    led = m.read_ledger(repo, "u4-int-a2")
    new_plans = sorted(u["id"] for u in led["units"]
                       if u.get("phase") == "plan" and u["id"] not in
                       ("plan-1", "plan-2", "plan-3"))
    judge = next(u for u in led["units"] if u["id"] == "judge")
    print(json.dumps({
        "new_plan_ids": new_plans,
        "iteration_attempts": led.get("iteration_attempts"),
        "judge_state": judge.get("state"),
    }))

elif op == "integration-a4-iterate":
    # A4-shape: 1 plan unit, 2 builders ("build-clarity", "build-perf"), and
    # a "compare" gate. Comparator writes decision="iterate" with emit_count=
    # 1 → tick re-emits a 3rd builder + resets compare with extended
    # depends_on.
    p = m.ledger_path(repo, "u4-int-a4")
    if os.path.exists(p): os.unlink(p)
    units = [
        {"id": "plan-1", "state": "fixed", "phase": "plan", "findings": []},
        {"id": "build-clarity", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "build-perf", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "compare", "state": "pending", "phase": "work",
         "depends_on": ["build-clarity", "build-perf"]},
    ]
    m.init_ledger(repo, "u4-int-a4", adapter="ce", loop_phase="work",
                  phase_order=["plan","seam","work"], terminal_phase="work",
                  units=units)
    def seed(L):
        L["iteration"] = {"gate_unit": "compare", "emit_template":
                          "bias-builder", "bound": {"max_attempts": 3}}
        L["emit_templates"] = {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
        L["iteration_attempts"] = 0
        L["iteration_emit_count"] = 2  # build-clarity, build-perf
        for u in L["units"]:
            if u["id"] == "compare":
                u["state"] = "dispatched"
    m._with_locked_ledger(repo, "u4-int-a4", seed)
    m.record_verdict(repo, "u4-int-a4", "compare", [])
    m.set_verdict_decision(repo, "u4-int-a4", "compare", "iterate",
                            payload={"emit_count": 1})
    t.dispatch_tick(repo, "u4-int-a4")
    led = m.read_ledger(repo, "u4-int-a4")
    builders = sorted(u["id"] for u in led["units"] if (u.get("id") or "").startswith("build-"))
    cmp_unit = next(u for u in led["units"] if u["id"] == "compare")
    print(json.dumps({
        "builders": builders,
        "iteration_attempts": led.get("iteration_attempts"),
        "compare_state": cmp_unit.get("state"),
        "compare_depends_on": sorted(cmp_unit.get("depends_on") or []),
    }))

elif op == "shortcircuit-yielded-met-recompose":
    # Per advisor's note (R6): probe that when decision==iterate is set on a
    # gate unit, the predicate composition gives iteration_pending=True and
    # met=False even with all-terminal work units.
    init_a2("u4-r6-recompose", decision="iterate", attempts=0)
    led = m.read_ledger(repo, "u4-r6-recompose")
    pred = led.get("exit_predicate_result") or {}
    print(json.dumps({
        "iteration_pending": pred.get("iteration_pending"),
        "met": pred.get("met"),
    }))

else:
    print(f"unknown op: {op}")
    sys.exit(2)
PYEOF
}

# ─── U4 Scenario 1: GREEN advance — gate writes decision=advance ────────────
it "U4 GREEN advance: evaluate_decision returns advance → caller falls through; no iteration_attempts increment"
res="$(u4_driver advance)"
action="$("$PY" -c "import json,sys;d=json.loads(sys.argv[1]);print(d['action'])" "$res")"
attempts="$("$PY" -c "import json,sys;d=json.loads(sys.argv[1]);print(d['iteration_attempts'])" "$res")"
# The "advance" path falls through the short-circuit; with no winner_unit_id
# set, the existing flow doesn't terminate cleanly — the gate is verdict-
# returned in the work phase. We assert that advance_iteration_loop returned
# without mutating iteration_attempts.
if [ "$attempts" = "0" ]; then
  pass
else
  fail "iteration_attempts=$attempts (expected 0; advance must not increment) action=$action res=$res"
fi

# ─── U4 Scenario 2: GREEN iterate under bound ────────────────────────────────
it "U4 GREEN iterate under bound: emits plan-4/plan-5, gate resets to pending, attempts=2"
res="$(u4_driver iterate-under-bound)"
attempts="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['iteration_attempts'])" "$res")"
plan_ids="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['plan_ids']))" "$res")"
judge_state="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['judge_state'])" "$res")"
depends_on="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['judge_depends_on']))" "$res")"
cleared="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['judge_decision_cleared'])" "$res")"
if [ "$attempts" = "2" ] && [ "$plan_ids" = "plan-1,plan-2,plan-3,plan-4,plan-5" ] \
   && [ "$judge_state" = "pending" ] && [ "$depends_on" = "plan-1,plan-2,plan-3,plan-4,plan-5" ] \
   && [ "$cleared" = "True" ]; then
  pass
else
  fail "attempts=$attempts plans=[$plan_ids] state=$judge_state deps=[$depends_on] cleared=$cleared"
fi

# ─── U4 Scenario 3: BOUND max_attempts ───────────────────────────────────────
it "U4 BOUND max_attempts: bound_override written, loop_phase=done directly (no advance_to_phase)"
res="$(u4_driver iterate-over-attempts)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
reason="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['reason'])" "$res")"
phase="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['loop_phase'])" "$res")"
btype="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['bound_type'])" "$res")"
rep_bt="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['report_bound'])" "$res")"
has_best="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['report_has_best'])" "$res")"
if [ "$action" = "stop" ] && [ "$reason" = "bound-exit" ] && [ "$phase" = "done" ] \
   && [ "$btype" = "max_attempts" ] && [ "$rep_bt" = "max_attempts" ] && [ "$has_best" = "True" ]; then
  pass
else
  fail "action=$action reason=$reason phase=$phase btype=$btype rep=$rep_bt has_best=$has_best"
fi

# ─── U4 Scenario 4: BOUND max_wall_seconds ───────────────────────────────────
it "U4 BOUND max_wall_seconds: same shape with bound_type=max_wall_seconds"
res="$(u4_driver iterate-over-wall)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
btype="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['bound_type'])" "$res")"
if [ "$action" = "stop" ] && [ "$btype" = "max_wall_seconds" ]; then
  pass
else
  fail "action=$action btype=$btype"
fi

# ─── U4 Scenario 5: R5 finally — active-time accumulates on raise + clean ────
it "U4 R5 finally: active_wall_seconds accumulates on BOTH clean returns AND adapter-raise returns"
res="$(u4_driver finally-crash-accumulates)"
clean="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['clean_advanced'])" "$res")"
raise_adv="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['raise_advanced'])" "$res")"
if [ "$clean" = "True" ] && [ "$raise_adv" = "True" ]; then
  pass
else
  fail "clean=$clean raise=$raise_adv (both must be True; finally must fire on both paths)"
fi

# ─── U4 Scenario 6: R6 short-circuit suppression ─────────────────────────────
it "U4 R6 short-circuit: iteration_pending=True suppresses predicate-met short-circuit → iterate fires"
res="$(u4_driver shortcircuit-suppressed-by-iteration)"
pending="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['iteration_pending_before'])" "$res")"
met_before="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['met_before'])" "$res")"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
advanced="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res")"
if [ "$pending" = "True" ] && [ "$met_before" = "False" ] \
   && [ "$action" = "rearm" ] && [ "$advanced" = "iterate-step" ]; then
  pass
else
  fail "pending=$pending met=$met_before action=$action advanced=$advanced"
fi

# ─── U4 Scenario 7: R7 a1 early-return ───────────────────────────────────────
it "U4 R7 a1: advance_iteration_loop returns None on a1-shape (no iteration block)"
res="$(u4_driver a1-early-return)"
direct_is_none="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['direct_is_none'])" "$res")"
state="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['state'])" "$res")"
if [ "$direct_is_none" = "True" ] && [ "$state" = "fixed" ]; then
  pass
else
  fail "direct_is_none=$direct_is_none state=$state (expected None, then fix-applied) res=$res"
fi

# ─── U4 Scenario 8: R7 W early-return ────────────────────────────────────────
it "U4 R7 W: advance_iteration_loop returns None on W-shape (no iteration block)"
res="$(u4_driver w-early-return)"
direct_is_none="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['direct_is_none'])" "$res")"
assert_eq "True" "$direct_is_none"

# ─── U4 Scenario 9: R9 last-attempt guidance ─────────────────────────────────
it "U4 R9 last-attempt: tick at attempts == max-1 surfaces 'last attempt before bound' in operator_guidance"
res="$(u4_driver r9-last-attempt-guidance)"
has="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['guidance_has_last_attempt'])" "$res")"
assert_eq "True" "$has"

# ─── U4 Scenario 10: R9 bound-override guidance ──────────────────────────────
it "U4 R9 bound-override: _iteration_guidance_prefix surfaces bound type + best-so-far when override present"
res="$(u4_driver r9-bound-override-guidance)"
ro="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['report_has_override'])" "$res")"
prefix_named="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['prefix_names_bound'])" "$res")"
prefix_best="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['prefix_has_best_so_far'])" "$res")"
if [ "$ro" = "True" ] && [ "$prefix_named" = "True" ] && [ "$prefix_best" = "True" ]; then
  pass
else
  fail "report_has_override=$ro prefix_names_bound=$prefix_named prefix_has_best_so_far=$prefix_best"
fi

# ─── U4 Scenario 11: kill-switch fence ───────────────────────────────────────
it "U4 kill-switch: CLAUDE_AUTO_DISABLE_ITERATION=1 → advance_iteration_loop returns None at step 2"
res="$(u4_driver kill-switch)"
none="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['direct_is_none'])" "$res")"
attempts="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['attempts_unchanged'])" "$res")"
dec="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['decision_still_iterate'])" "$res")"
if [ "$none" = "True" ] && [ "$attempts" = "True" ] && [ "$dec" = "True" ]; then
  pass
else
  fail "none=$none attempts_unchanged=$attempts decision_iterate=$dec"
fi

# ─── U4 Scenario 12: Integration A2 ITERATE (production write path) ──────────
it "U4 Integration A2 ITERATE: record_verdict + set_verdict_decision(iterate, emit_count=2) → tick re-emits + resets"
res="$(u4_driver integration-a2-iterate)"
new_plans="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['new_plan_ids']))" "$res")"
attempts="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['iteration_attempts'])" "$res")"
gstate="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['judge_state'])" "$res")"
if [ "$new_plans" = "plan-4,plan-5" ] && [ "$attempts" = "1" ] && [ "$gstate" = "pending" ]; then
  pass
else
  fail "new_plans=[$new_plans] attempts=$attempts judge_state=$gstate"
fi

# ─── U4 Scenario 13: Integration A4 ITERATE (production write path) ──────────
it "U4 Integration A4 ITERATE: comparator decision=iterate emit_count=1 → 3rd builder emitted, compare reset"
res="$(u4_driver integration-a4-iterate)"
builders="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['builders']))" "$res")"
attempts="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['iteration_attempts'])" "$res")"
cstate="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['compare_state'])" "$res")"
if [ "$attempts" = "1" ] && [ "$cstate" = "pending" ] \
   && [ "$builders" = "build-3,build-clarity,build-perf" ]; then
  pass
else
  fail "builders=[$builders] attempts=$attempts compare_state=$cstate"
fi

# ─── U4 Scenario 14: predicate composition recomposes met under iteration ────
it "U4 R6 predicate composition: setting decision=iterate on terminal-units ledger → met=False, iteration_pending=True"
res="$(u4_driver shortcircuit-yielded-met-recompose)"
pending="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['iteration_pending'])" "$res")"
met="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['met'])" "$res")"
if [ "$pending" = "True" ] && [ "$met" = "False" ]; then
  pass
else
  fail "pending=$pending met=$met"
fi

# ════════════════════════════════════════════════════════════════════════════
# U4 DELIBERATE-FAILS — Hand-Edit reverts that prove each new behavior is
# load-bearing. Per memory feedback_deliberate_fail_revert_via_edit_not_inscript:
# we Edit tick.py to a buggy shape, re-run the relevant test, restore via Edit.
# Each control loads tick.py from a TMP COPY (so we don't mutate the canonical
# file on disk and risk parallel test pollution). The patch is a Python file
# we drop into a tmpdir + invoke; this keeps the bash quoting trivial.
# ════════════════════════════════════════════════════════════════════════════

# Helper: copy tick.py to a tmp file, run the named patch (a python script in
# tests/unit/_df_patches/ — written inline below), then drive the probe op.
u4_df_with_patched_tick() {
  local patch_script="$1" probe_op="$2"
  local tmpdir; tmpdir="$(mktemp -d -t u4-df.XXXXXX)"
  cp "$TICK_PY" "$tmpdir/tick.py"
  "$PY" "$patch_script" "$tmpdir/tick.py"
  local patch_rc=$?
  if [ "$patch_rc" -ne 0 ]; then
    rm -rf "$tmpdir"
    fail "DF patch script $patch_script failed with rc=$patch_rc"
    return 0
  fi
  TICK_PY_OVERRIDE="$tmpdir/tick.py" "$PY" - "$AUTO_ROOT" "$REPO" "$probe_op" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo, op = sys.argv[1:4]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("ledger")
t_path = os.environ["TICK_PY_OVERRIDE"]
t_spec = importlib.util.spec_from_file_location("tick_patched", t_path)
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)

# Re-use the production seeds from above; for brevity we re-init inline.
def _init_iter(run, **kw):
    p = m.ledger_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    plans = kw.get("plans", ["plan-1","plan-2","plan-3"])
    units = [{"id": pid, "state": "fixed", "phase": "plan", "findings": []}
             for pid in plans]
    units.append({"id":"judge","state":"pending","phase":"work",
                  "depends_on":list(plans)})
    m.init_ledger(repo, run, adapter="ce", loop_phase="work",
                  phase_order=["plan","seam","work"], terminal_phase="work",
                  units=units)
    def seed(L):
        bound = {"max_attempts": kw.get("max_attempts", 5)}
        L["iteration"] = {"gate_unit": "judge", "emit_template":
                          "plan-candidate", "bound": bound}
        L["emit_templates"] = {"plan-candidate": {
            "phase":"plan","invokes":{"adapter_op":"next_plan_step"},
            "id_prefix":"plan-"}}
        L["iteration_attempts"] = kw.get("attempts", 0)
        L["iteration_emit_count"] = len(plans)
        for u in L["units"]:
            if u["id"] == "judge":
                u["state"] = "dispatched"
    m._with_locked_ledger(repo, run, seed)
    m.record_verdict(repo, run, "judge", [])
    if kw.get("decision"):
        payload = None
        if kw.get("emit_count") is not None:
            payload = {"emit_count": kw["emit_count"]}
        m.set_verdict_decision(repo, run, "judge", kw["decision"], payload=payload)

if op == "df-bound-skip":
    # Probe: without the bound check, attempts==max with iterate decision
    # iterates instead of bound-exiting → action should be rearm, not stop.
    _init_iter("u4-df-bound", decision="iterate", attempts=5,
                max_attempts=5, emit_count=1)
    r = t.dispatch_tick(repo, "u4-df-bound")
    print(json.dumps({"action": r.get("action"), "reason": r.get("reason")}))

elif op == "df-shortcircuit-no-suppression":
    # Without iteration_pending in the short-circuit, the work-loop's
    # met=True (computed against all_units_terminal) would fire EARLY —
    # tick exits "predicate-met" / "done" before iteration runs.
    # NOTE: the predicate composition itself is in ledger.py and sets
    # iteration_pending; the tick's short-circuit then must AND-NOT it.
    # Since the composition has already ANDed met=False, the patched
    # short-circuit going via pred["met"] alone would still see False.
    # Instead, this DF tests the SECONDARY scenario: by editing the
    # short-circuit to FORCE met=True ignoring the predicate, a different
    # behavior emerges. We probe the patched version's behavior on the
    # iterate-under-bound scenario: with the short-circuit unconditional-
    # firing, the helper exits "predicate-met" instead of iterating.
    _init_iter("u4-df-shortcir", decision="iterate", attempts=0,
                max_attempts=5, emit_count=1)
    r = t.dispatch_tick(repo, "u4-df-shortcir")
    print(json.dumps({"action": r.get("action"), "reason": r.get("reason")}))

elif op == "df-killswitch-ignored":
    _init_iter("u4-df-kill", decision="iterate", attempts=0,
                max_attempts=5, emit_count=1)
    os.environ["CLAUDE_AUTO_DISABLE_ITERATION"] = "1"
    os.environ["CLAUDE_AUTO_TEST_HARNESS"] = "1"
    try:
        led = m.read_ledger(repo, "u4-df-kill")
        direct = t.advance_iteration_loop(repo, "u4-df-kill", led)
    finally:
        del os.environ["CLAUDE_AUTO_DISABLE_ITERATION"]
    print(json.dumps({"direct_is_none": direct is None,
                       "action": (direct or {}).get("action")}))

elif op == "df-finally-skipped":
    # Patched tick.py removes the finally accumulate; an adapter raise
    # leaves active_wall_seconds unchanged. We drive a raise-tick (the
    # inner try/except in _tick_body_inner captures the adapter raise so
    # the tick returns; the finally would otherwise still accumulate).
    p = m.ledger_path(repo, "u4-df-fin")
    if os.path.exists(p): os.unlink(p)
    m.init_ledger(repo, "u4-df-fin", adapter="ce", loop_phase="plan",
                  units=[{"id":"U1","state":"dispatched",
                          "dispatched_at":"2026-01-01T00:00:00Z",
                          "stall_threshold_seconds":600}])
    before = m.read_ledger(repo, "u4-df-fin").get("active_wall_seconds", 0)
    class Boom:
        def next_plan_step(self, led):
            raise RuntimeError("boom")
    try:
        t.dispatch_tick(repo, "u4-df-fin", adapter=Boom())
    except Exception:
        pass
    after = m.read_ledger(repo, "u4-df-fin").get("active_wall_seconds", 0)
    print(json.dumps({"advanced": after > before}))

else:
    print(f"unknown op: {op}")
    sys.exit(2)
PYEOF
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# Write the patch scripts to disk (one per DF). Each script takes a single
# argv ($1 = path to the temp tick.py) and rewrites it in place. Plain
# `src.replace(...)`, no regex — anchors are the exact source strings we ship.
DF_DIR="$(mktemp -d -t u4-df-scripts.XXXXXX)"
trap 'cleanup; rm -rf "$DF_DIR"' EXIT

cat > "$DF_DIR/df1_skip_bound.py" <<'PYEOF'
"""DF#1: force evaluate_decision's result to keep decision_effective='iterate'
even at attempts==max. After the patched advance_iteration_loop reads the
result, it always takes the iterate branch — bound is functionally skipped."""
import sys
p = sys.argv[1]
src = open(p).read()
old = 'eval_result = iteration.evaluate_decision(\n        led, gate_unit_id, now_monotonic=time.monotonic()\n    )'
new = (old + '\n'
       '    if eval_result.get("original_decision") == "iterate":\n'
       '        eval_result["decision_effective"] = "iterate"  # DF#1: bound check skipped\n'
       '        eval_result["bound_breached"] = False\n'
       '        eval_result["bound_type"] = None')
if old not in src:
    sys.exit("DF#1 anchor not found")
open(p, "w").write(src.replace(old, new))
PYEOF

cat > "$DF_DIR/df2_short_circuit_no_suppress.py" <<'PYEOF'
"""DF#2: drop the `not pred.get("iteration_pending", False)` guard from the
short-circuit at tick.py:564-576. The short-circuit then fires on raw
`met` alone — but `recompute_predicate` ANDs iteration_pending into met (U2
KTD §B), so even without the local guard, met is False on an iterate-
pending ledger. To prove the GUARD is load-bearing in isolation, we ALSO
patch advance_iteration_loop to no-op AND patch the composed met to ignore
iteration_pending. Cleaner single-shot: instead, prove the GUARD is load-
bearing by ALSO disabling the composition (set CLAUDE_AUTO_TEST_NO_RECOMPUTE)
— but that needs the hatch. We take the simpler path: patch the short-
circuit to ALSO accept iteration_pending=True as a trigger, then disable
the iteration helper. With both disabled, an iterate-pending ledger exits
'predicate-met' instead of iterating."""
import sys
p = sys.argv[1]
src = open(p).read()
old_def = 'def advance_iteration_loop(repo_root, run_id, led):\n    """'
new_def = 'def advance_iteration_loop(repo_root, run_id, led):\n    return None  # DF#2 PATCH\n    """'
if old_def not in src:
    sys.exit("DF#2 anchor 1 not found")
src = src.replace(old_def, new_def, 1)
old_sc = ('if pred.get("met") and not pred.get("iteration_pending", False) \\\n'
          '            and phase != "plan" and phase != "seam":')
new_sc = ('if (pred.get("met") or pred.get("iteration_pending")) \\\n'
          '            and phase != "plan" and phase != "seam":')
if old_sc not in src:
    sys.exit("DF#2 anchor 2 not found")
src = src.replace(old_sc, new_sc)
open(p, "w").write(src)
PYEOF

cat > "$DF_DIR/df3_no_fence.py" <<'PYEOF'
"""DF#3: remove the kill-switch fence so the env hatch is ignored."""
import sys
p = sys.argv[1]
src = open(p).read()
old = 'if is_iteration_disabled():\n        return None'
new = 'if False:  # DF#3 PATCH — kill-switch removed\n        return None'
if old not in src:
    sys.exit("DF#3 anchor not found")
open(p, "w").write(src.replace(old, new))
PYEOF

cat > "$DF_DIR/df4_no_finally.py" <<'PYEOF'
"""DF#4: remove the try/finally wrapping _tick_body_inner so the crashed-
tick path no longer accumulates active_wall_seconds."""
import sys
p = sys.argv[1]
src = open(p).read()
old1 = "    t_start = time.monotonic()\n    try:\n        return _tick_body_inner("
new1 = "    t_start = time.monotonic()\n    if True:\n        return _tick_body_inner("
if old1 not in src:
    sys.exit("DF#4 anchor 1 not found")
src = src.replace(old1, new1)
old2 = ("    finally:\n"
        "        # accumulate_active_time is best-effort: an exception inside it must\n"
        "        # never bury the real exception/return value. (E.g. a torn ledger\n"
        "        # during a stalled-write recovery would otherwise mask the original.)\n"
        "        try:\n"
        "            ledger.accumulate_active_time(\n"
        "                repo_root, run_id, time.monotonic() - t_start\n"
        "            )\n"
        "        except Exception:  # noqa: BLE001\n"
        "            pass")
new2 = "    # finally removed by DF#4 PATCH"
if old2 not in src:
    sys.exit("DF#4 anchor 2 not found")
src = src.replace(old2, new2)
open(p, "w").write(src)
PYEOF

# DF#1 — Skip the bound check in advance_iteration_loop. Without it, the
# iterate-over-attempts test would re-arm (iterate) instead of bound-exit.
it "U4 DELIBERATE-FAIL #1: skipping the bound check → iterate at attempts==max re-iterates (NOT bound-exit)"
res="$(u4_df_with_patched_tick "$DF_DIR/df1_skip_bound.py" df-bound-skip)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
# In the DF the bound is skipped → iterate path fires → action=rearm.
if [ "$action" = "rearm" ]; then
  pass
else
  fail "DF expected action=rearm (iterates past bound); got action=$action res=$res"
fi

# DF#2 — make advance_iteration_loop a no-op AND force the short-circuit to
# fire on iteration_pending too. Together: iterate-pending ledger exits as
# "predicate-met" (the suppression is no longer load-bearing). Proves the
# iteration check + short-circuit-suppression contract.
it "U4 DELIBERATE-FAIL #2: skipping the iteration check + dropping the AND-NOT clause → iterate ledger exits predicate-met"
res="$(u4_df_with_patched_tick "$DF_DIR/df2_short_circuit_no_suppress.py" df-shortcircuit-no-suppression)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
reason="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['reason'])" "$res")"
if [ "$action" = "stop" ] && [ "$reason" = "predicate-met" ]; then
  pass
else
  fail "DF expected stop/predicate-met; got action=$action reason=$reason res=$res"
fi

# DF#3 — Ignore the kill-switch. Without the fence, iteration runs even
# with CLAUDE_AUTO_DISABLE_ITERATION=1.
it "U4 DELIBERATE-FAIL #3: ignoring the kill-switch fence → iteration runs despite the env hatch"
res="$(u4_df_with_patched_tick "$DF_DIR/df3_no_fence.py" df-killswitch-ignored)"
none="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['direct_is_none'])" "$res")"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
if [ "$none" = "False" ] && [ "$action" = "iterate" ]; then
  pass
else
  fail "DF expected direct_is_none=False action=iterate; got none=$none action=$action res=$res"
fi

# DF#4 — Move accumulate_active_time out of the finally clause. With the
# finally removed, an adapter-raise return path doesn't call accumulate, so
# active_wall_seconds stays at 0.
it "U4 DELIBERATE-FAIL #4: moving accumulate_active_time out of finally → crashed-tick active_wall_seconds stays unchanged"
res="$(u4_df_with_patched_tick "$DF_DIR/df4_no_finally.py" df-finally-skipped)"
advanced="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res")"
if [ "$advanced" = "False" ]; then
  pass
else
  fail "DF expected advanced=False (no accumulation in DF); got advanced=$advanced res=$res"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "tick.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
