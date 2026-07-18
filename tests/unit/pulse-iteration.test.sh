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
echo "pulse-iteration.test.sh"

# ════════════════════════════════════════════════════════════════════════════
# v0.3.0 U4 — advance_iteration_loop + finally + kill-switch fence + R9
# ════════════════════════════════════════════════════════════════════════════
#
# Each scenario primes a run-record that emulates the post-U6 iteration shape
# (workflows ship iteration + emit_templates blocks; U6 has not landed yet so
# we install them directly via _with_locked_run_record). U4 reads those fields
# through `iteration.evaluate_decision` and the run-record mutators U2 ships.

# Test driver: a python helper that seeds a run-record with an iteration block,
# optionally walks the gate step to a desired state + decision, then runs
# dispatch_pulse and prints a JSON blob with the post-pulse state.
u4_driver() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo = sys.argv[1:3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("run_record")
t_spec = importlib.util.spec_from_file_location(
    "pulse_under_test", os.path.join(auto_root, "lib", "pulse.py"))
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)
op = sys.argv[3]


def init_a2(run, *, decision=None, attempts=0, active_wall=0,
            max_attempts=5, max_wall=None, plan_steps=("plan-1","plan-2","plan-3"),
            gate_state="verdict-returned", emit_count=None):
    """Build an A2-shaped run_record: 3 plan steps (all 'fixed' so terminal) +
    a 'judge' gate step. The gate is walked to ``gate_state`` (default
    verdict-returned via record_verdict) and optionally tagged with the
    given ``decision`` via set_verdict_decision."""
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    steps = [
        {"id": pid, "state": "fixed", "phase": "plan",
         "findings": []}
        for pid in plan_steps
    ]
    steps.append({"id": "judge", "state": "pending", "phase": "work",
                  "depends_on": list(plan_steps)})
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=steps)
    # Seed iteration + emit_templates block.
    def seed(L):
        bound = {"max_attempts": max_attempts}
        if max_wall is not None: bound["max_wall_seconds"] = max_wall
        L["iteration"] = {"gate_step": "judge",
                          "emit_template": "plan-candidate", "bound": bound}
        L["emit_templates"] = {
            "plan-candidate": {
                "phase": "plan",
                "invokes": {"backend_op": "next_plan_step"},
                "id_prefix": "plan-"
            }
        }
        L["iteration_attempts"] = attempts
        L["active_wall_seconds"] = active_wall
        L["iteration_emit_count"] = len(plan_steps)
        # Walk gate to verdict-returned via grammar-valid edges if requested.
        for u in L["steps"]:
            if u["id"] == "judge":
                if gate_state == "verdict-returned":
                    u["state"] = "dispatched"
    m._with_locked_run_record(repo, run, seed)
    if gate_state == "verdict-returned":
        m.record_verdict(repo, run, "judge", [])
    if decision is not None:
        payload = None
        if emit_count is not None:
            payload = {"emit_count": emit_count}
        m.set_verdict_decision(repo, run, "judge", decision, payload=payload)
    if gate_state == "verdict-returned" and decision == "advance":
        # Advance requires winner_step_id for downstream producers; set it.
        m.set_winner_step_id(repo, run, "judge", plan_steps[0])


def init_a1(run, steps=None):
    """a1-shape: no iteration block, no gate_step, no emit_templates. U4
    must early-return at step 1 with zero run_record writes."""
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    u = steps or [{"id": "U1", "state": "verdict-returned",
                   "findings": [{"severity": "blocker", "note": "open"}]}]
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=u)


if op == "advance":
    # GREEN: gate says advance. evaluate_decision returns "advance"; the
    # caller falls through to the standard flow. Because the gate hasn't
    # set winner_step_id (no winner needed in this minimal test), the
    # short-circuit at lines 564-576 should fire normally (work phase, met
    # composed against not-iteration_pending which is False here).
    init_a2("u4-advance", decision="advance", attempts=0)
    r = t.dispatch_pulse(repo, "u4-advance")
    led = m.read_run_record(repo, "u4-advance")
    print(json.dumps({
        "action": r.get("action"),
        "reason": r.get("reason"),
        "iteration_attempts": led.get("iteration_attempts"),
        "loop_phase": led.get("loop_phase"),
    }))

elif op == "iterate-under-bound":
    # GREEN: gate says iterate, attempts < max. advance_iteration_loop calls
    # atomic_iterate_step (increment + emit 2 steps + reset). After the pulse
    # the gate is pending again, attempts=2, two new plan steps appear,
    # gate depends_on now includes them, and the pulse re-arms.
    init_a2("u4-iter-under", decision="iterate", attempts=1, max_attempts=5,
            emit_count=2)
    r = t.dispatch_pulse(repo, "u4-iter-under")
    led = m.read_run_record(repo, "u4-iter-under")
    plan_ids = sorted(u["id"] for u in led["steps"] if u.get("phase") == "plan")
    judge = next(u for u in led["steps"] if u["id"] == "judge")
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
    r = t.dispatch_pulse(repo, "u4-bound-attempts")
    led = m.read_run_record(repo, "u4-bound-attempts")
    judge = next(u for u in led["steps"] if u["id"] == "judge")
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
    r = t.dispatch_pulse(repo, "u4-bound-wall")
    led = m.read_run_record(repo, "u4-bound-wall")
    judge = next(u for u in led["steps"] if u["id"] == "judge")
    override = (judge.get("dispatch_context") or {}).get("bound_override") or {}
    print(json.dumps({
        "action": r.get("action"),
        "reason": r.get("reason"),
        "bound_type": override.get("bound"),
    }))

elif op == "finally-crash-accumulates":
    # R5 / finally: _pulse_body raises mid-flight (BoomBackend inside the
    # plan-loop). The finally clause must accumulate the active-time delta
    # regardless. We measure: before pulse: active_wall_seconds=A0; pulse
    # raises; after pulse: active_wall_seconds > A0. Because the inner
    # try/except in _pulse_body_inner CATCHES the backend raise and converts
    # it to a recorded stall (so _pulse_body returns normally), we instead
    # force the raise INSIDE the finally region by monkey-patching run-record
    # read to raise after the body started. Simpler: prove the finally fires
    # on the NORMAL return path too — accumulate_active_time fires once per
    # pulse regardless of return path. We probe a regular pulse + a pulse whose
    # backend raises (the try/except path inside _pulse_body_inner).
    init_a1("u4-fin-crash")
    before = m.read_run_record(repo, "u4-fin-crash").get("active_wall_seconds", 0)
    t.dispatch_pulse(repo, "u4-fin-crash")
    after_clean = m.read_run_record(repo, "u4-fin-crash").get("active_wall_seconds", 0)
    # Now drive a raise via a BoomBackend on a plan-phase run-record (the inner
    # try/except converts it to a stall; the finally still fires).
    p2 = m.run_record_path(repo, "u4-fin-raise")
    if os.path.exists(p2): os.unlink(p2)
    m.init_run_record(repo, "u4-fin-raise", backend="ce", loop_phase="plan",
                  steps=[{"id": "U1", "state": "dispatched",
                          "dispatched_at": "2026-01-01T00:00:00Z",
                          "stall_threshold_seconds": 600}])
    before2 = m.read_run_record(repo, "u4-fin-raise").get("active_wall_seconds", 0)
    class Boom:
        def next_plan_step(self, led):
            raise RuntimeError("boom")
    t.dispatch_pulse(repo, "u4-fin-raise", backend=Boom())
    after_raise = m.read_run_record(repo, "u4-fin-raise").get("active_wall_seconds", 0)
    print(json.dumps({
        "clean_advanced": after_clean > before,
        "raise_advanced": after_raise > before2,
    }))

elif op == "shortcircuit-suppressed-by-iteration":
    # R6: an iteration-pending run-record composes met=False even when the work
    # branch would otherwise compute met=True. The short-circuit at lines
    # 564-576 yields; advance_iteration_loop runs FIRST and iterates.
    init_a2("u4-shortcircuit", decision="iterate", attempts=1, emit_count=1)
    # All plan steps terminal + judge verdict-returned with NO findings →
    # blocker=0/major=0/all_steps_terminal=True. Without iteration_pending,
    # met would be True. With it, met=False and the loop iterates.
    led = m.read_run_record(repo, "u4-shortcircuit")
    pred_before = led.get("exit_predicate_result") or {}
    r = t.dispatch_pulse(repo, "u4-shortcircuit")
    print(json.dumps({
        "iteration_pending_before": pred_before.get("iteration_pending"),
        "met_before": pred_before.get("met"),
        "action": r.get("action"),
        "advanced": (r.get("advance") or {}).get("advanced"),
    }))

elif op == "a1-early-return":
    # R7 a1: no iteration block → advance_iteration_loop returns None at
    # step 1. Zero run-record writes from the helper. The pulse proceeds as
    # v0.2.1 (a fix-applied advance on the verdict-returned+blocker step).
    init_a1("u4-a1")
    before = json.dumps(m.read_run_record(repo, "u4-a1")["steps"][0], sort_keys=True)
    # Probe the helper directly to assert it returns None.
    led = m.read_run_record(repo, "u4-a1")
    direct = t.pulse_advance.advance_iteration_loop(repo, "u4-a1", led)
    r = t.dispatch_pulse(repo, "u4-a1")
    after_state = m.read_run_record(repo, "u4-a1")["steps"][0].get("state")
    print(json.dumps({
        "direct_is_none": direct is None,
        "action": r.get("action"),
        "advanced": (r.get("advance") or {}).get("advanced"),
        "state": after_state,
    }))

elif op == "w-early-return":
    # R7 W: same shape as a1 — no iteration block. Different step set;
    # helper still early-returns at step 1.
    p = m.run_record_path(repo, "u4-w")
    if os.path.exists(p): os.unlink(p)
    m.init_run_record(repo, "u4-w", backend="ce", loop_phase="work",
                  phase_order=["work"], terminal_phase="work",
                  steps=[{"id": "W1", "state": "verdict-returned",
                          "findings": [{"severity": "blocker", "note": "x"}]}])
    led = m.read_run_record(repo, "u4-w")
    direct = t.pulse_advance.advance_iteration_loop(repo, "u4-w", led)
    print(json.dumps({"direct_is_none": direct is None}))

elif op == "r9-last-attempt-guidance":
    # R9: iteration_attempts == max_attempts → INTENT carries "last attempt
    # before bound" guidance. The NEXT iterate decision (read at
    # attempts_made==max_attempts) will be overridden to exit by
    # iteration.evaluate_decision (lib/iteration.py:136). We pulse a non-
    # iterating run-record (decision=None with attempts=5 == max=5) so the
    # rearm path fires; the helper's branch 2 sees attempts==max and
    # prepends the warning to the operator_guidance body.
    # v0.3.0 F2 (ADV-3 off-by-one): pre-F2 this seeded attempts=4 (one
    # pulse too early — at attempts=4 with max=5, two more iterates would
    # be honored before bound trip, so the "next iterate trips bound"
    # text was a lie).
    init_a2("u4-r9-last", decision=None, attempts=5, max_attempts=5)
    # Add a verdict-returned blocker step so the pulse produces a rearm.
    def seed(L):
        L["steps"].append({
            "id": "X1", "state": "verdict-returned", "phase": "work",
            "depends_on": [],
            "findings": [{"severity": "blocker", "note": "open"}],
            "invokes": {}, "dispatch_context": {},
            "stall_threshold_seconds": 600, "last_error": None,
            "verdict_at": None, "dispatched_at": None, "attempt": 0,
        })
    m._with_locked_run_record(repo, "u4-r9-last", seed)
    r = t.dispatch_pulse(repo, "u4-r9-last")
    guidance = r.get("operator_guidance") or ""
    print(json.dumps({
        "action": r.get("action"),
        "guidance_has_last_attempt": "last attempt before bound" in guidance,
    }))

elif op == "r9-bound-override-guidance":
    # R9: bound_override just written on this pulse. operator_guidance must
    # name WHICH bound + best-so-far. This is a stop intent (bound-exit),
    # NOT a rearm — but operator_guidance is built only for rearm. The
    # actual surface is the report.bound_override + report.best_so_far,
    # which IS in the bound-exit return value. Also, immediately AFTER the
    # bound-exit a follow-up pulse reads the same gate with bound_override
    # written; if it were to re-arm (a contrived scenario), guidance would
    # surface. For test purposes we probe the helper _iteration_guidance_
    # prefix directly with a primed run-record.
    init_a2("u4-r9-override", decision="iterate", attempts=5, max_attempts=5,
            emit_count=1)
    # Run the pulse — it bound-exits. The next call to _operator_guidance_for
    # would surface the override; we probe the helper directly.
    r = t.dispatch_pulse(repo, "u4-r9-override")
    led = m.read_run_record(repo, "u4-r9-override")
    prefix = t._iteration_guidance_prefix(led)
    print(json.dumps({
        "report_has_override": (r.get("report") or {}).get("bound_override") is not None,
        "prefix_names_bound": "bound tripped" in prefix and "max_attempts" in prefix,
        "prefix_has_best_so_far": "Best-so-far" in prefix,
    }))

elif op == "kill-switch":
    # Kill-switch: CLAUDE_AUTO_DISABLE_ITERATION=1 alone (v0.3.0 F5 unfenced
    # this — no harness sentinel required) → advance_iteration_loop returns
    # None at step 2. The iterate decision on disk is UNTOUCHED. Pulse
    # proceeds as if iteration didn't exist.
    init_a2("u4-killswitch", decision="iterate", attempts=1, max_attempts=5,
            emit_count=2)
    led = m.read_run_record(repo, "u4-killswitch")
    os.environ["CLAUDE_AUTO_DISABLE_ITERATION"] = "1"
    os.environ["CLAUDE_AUTO_TEST_HARNESS"] = "1"
    try:
        direct = t.pulse_advance.advance_iteration_loop(repo, "u4-killswitch", led)
    finally:
        del os.environ["CLAUDE_AUTO_DISABLE_ITERATION"]
        # Don't unset the sentinel — tests/run.sh exports it for the whole
        # process tree; locally setting it here is harmless.
    after = m.read_run_record(repo, "u4-killswitch")
    judge = next(u for u in after["steps"] if u["id"] == "judge")
    print(json.dumps({
        "direct_is_none": direct is None,
        "attempts_unchanged": after.get("iteration_attempts") == 1,
        "decision_still_iterate": (
            (judge.get("dispatch_context") or {}).get("decision") == "iterate"
        ),
    }))

elif op == "integration-a2-iterate":
    # Production-path drive: init A2-shape run-record; gate writes record_verdict
    # + set_verdict_decision("iterate", payload={emit_count: 2}); pulse re-
    # emits plan-4/5 + resets judge. Mirrors v0.2.0 fix-pass I's pattern.
    init_a2("u4-int-a2", decision="iterate", attempts=0, max_attempts=5,
            emit_count=2)
    t.dispatch_pulse(repo, "u4-int-a2")
    led = m.read_run_record(repo, "u4-int-a2")
    new_plans = sorted(u["id"] for u in led["steps"]
                       if u.get("phase") == "plan" and u["id"] not in
                       ("plan-1", "plan-2", "plan-3"))
    judge = next(u for u in led["steps"] if u["id"] == "judge")
    print(json.dumps({
        "new_plan_ids": new_plans,
        "iteration_attempts": led.get("iteration_attempts"),
        "judge_state": judge.get("state"),
    }))

elif op == "integration-a4-iterate":
    # A4-shape: 1 plan step, 2 builders ("build-clarity", "build-perf"), and
    # a "compare" gate. Comparator writes decision="iterate" with emit_count=
    # 1 → pulse re-emits a 3rd builder + resets compare with extended
    # depends_on.
    p = m.run_record_path(repo, "u4-int-a4")
    if os.path.exists(p): os.unlink(p)
    steps = [
        {"id": "plan-1", "state": "fixed", "phase": "plan", "findings": []},
        {"id": "build-clarity", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "build-perf", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "compare", "state": "pending", "phase": "work",
         "depends_on": ["build-clarity", "build-perf"]},
    ]
    m.init_run_record(repo, "u4-int-a4", backend="ce", loop_phase="work",
                  phase_order=["plan","handoff","work"], terminal_phase="work",
                  steps=steps)
    def seed(L):
        L["iteration"] = {"gate_step": "compare", "emit_template":
                          "bias-builder", "bound": {"max_attempts": 3}}
        L["emit_templates"] = {"bias-builder": {
            "phase": "work", "invokes": {"backend_op": "do_step"},
            "id_prefix": "build-"}}
        L["iteration_attempts"] = 0
        L["iteration_emit_count"] = 2  # build-clarity, build-perf
        for u in L["steps"]:
            if u["id"] == "compare":
                u["state"] = "dispatched"
    m._with_locked_run_record(repo, "u4-int-a4", seed)
    m.record_verdict(repo, "u4-int-a4", "compare", [])
    m.set_verdict_decision(repo, "u4-int-a4", "compare", "iterate",
                            payload={"emit_count": 1})
    t.dispatch_pulse(repo, "u4-int-a4")
    led = m.read_run_record(repo, "u4-int-a4")
    builders = sorted(u["id"] for u in led["steps"] if (u.get("id") or "").startswith("build-"))
    cmp_step = next(u for u in led["steps"] if u["id"] == "compare")
    print(json.dumps({
        "builders": builders,
        "iteration_attempts": led.get("iteration_attempts"),
        "compare_state": cmp_step.get("state"),
        "compare_depends_on": sorted(cmp_step.get("depends_on") or []),
    }))

elif op == "shortcircuit-yielded-met-recompose":
    # Per advisor's note (R6): probe that when decision==iterate is set on a
    # gate step, the predicate composition gives iteration_pending=True and
    # met=False even with all-terminal work steps.
    init_a2("u4-r6-recompose", decision="iterate", attempts=0)
    led = m.read_run_record(repo, "u4-r6-recompose")
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
# The "advance" path falls through the short-circuit; with no winner_step_id
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
it "U4 R5 finally: active_wall_seconds accumulates on BOTH clean returns AND backend-raise returns"
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
it "U4 R9 last-attempt: pulse at attempts == max surfaces 'last attempt before bound' in operator_guidance"
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
it "U4 Integration A2 ITERATE: record_verdict + set_verdict_decision(iterate, emit_count=2) → pulse re-emits + resets"
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
it "U4 R6 predicate composition: setting decision=iterate on terminal-steps run_record → met=False, iteration_pending=True"
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
# we Edit pulse.py to a buggy shape, re-run the relevant test, restore via Edit.
# Each control loads pulse.py from a TMP COPY (so we don't mutate the canonical
# file on disk and risk parallel test pollution). The patch is a Python file
# we drop into a tmpdir + invoke; this keeps the bash quoting trivial.
# ════════════════════════════════════════════════════════════════════════════

# Helper: copy pulse.py to a tmp file, run the named patch (a python script in
# tests/unit/_df_patches/ — written inline below), then drive the probe op.
u4_df_with_patched_pulse() {
  local patch_script="$1" probe_op="$2"
  local tmpdir; tmpdir="$(mktemp -d -t u4-df.XXXXXX)"
  # B4: the pulse is split across pulse.py + pulse_advance.py + pulse_guidance.py.
  # A DF anchor may live in any of the three, so copy all three into the tmpdir
  # and let the patch script (which takes the DIR) edit whichever file holds its
  # anchor. The probe pre-loads the patched siblings so the patched pulse picks
  # them up instead of the canonical on-disk copies.
  cp "$PULSE_PY" "$tmpdir/pulse.py"
  cp "$AUTO_ROOT/lib/pulse_advance.py" "$tmpdir/pulse_advance.py"
  cp "$AUTO_ROOT/lib/pulse_guidance.py" "$tmpdir/pulse_guidance.py"
  "$PY" "$patch_script" "$tmpdir"
  local patch_rc=$?
  if [ "$patch_rc" -ne 0 ]; then
    rm -rf "$tmpdir"
    fail "DF patch script $patch_script failed with rc=$patch_rc"
    return 0
  fi
  PULSE_PY_OVERRIDE_DIR="$tmpdir" "$PY" - "$AUTO_ROOT" "$REPO" "$probe_op" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo, op = sys.argv[1:4]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("run_record")
tmpdir = os.environ["PULSE_PY_OVERRIDE_DIR"]
# Pre-load the patched siblings under the names pulse.py looks up, masking
# __file__ so load_lib_module's path-keyed cache accepts them (the canonical
# pulse.py does `load_lib_module("pulse_advance")` etc.; the cache check requires
# the cached module's __file__ to equal the canonical lib path).
def _preload(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(tmpdir, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    mod.__file__ = os.path.join(auto_root, "lib", name + ".py")
    return mod
_preload("pulse_guidance")
_preload("pulse_advance")
t_path = os.path.join(tmpdir, "pulse.py")
t_spec = importlib.util.spec_from_file_location("pulse_patched", t_path)
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)

# Re-use the production seeds from above; for brevity we re-init inline.
def _init_iter(run, **kw):
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    plans = kw.get("plans", ["plan-1","plan-2","plan-3"])
    steps = [{"id": pid, "state": "fixed", "phase": "plan", "findings": []}
             for pid in plans]
    steps.append({"id":"judge","state":"pending","phase":"work",
                  "depends_on":list(plans)})
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan","handoff","work"], terminal_phase="work",
                  steps=steps)
    def seed(L):
        bound = {"max_attempts": kw.get("max_attempts", 5)}
        L["iteration"] = {"gate_step": "judge", "emit_template":
                          "plan-candidate", "bound": bound}
        L["emit_templates"] = {"plan-candidate": {
            "phase":"plan","invokes":{"backend_op":"next_plan_step"},
            "id_prefix":"plan-"}}
        L["iteration_attempts"] = kw.get("attempts", 0)
        L["iteration_emit_count"] = len(plans)
        for u in L["steps"]:
            if u["id"] == "judge":
                u["state"] = "dispatched"
    m._with_locked_run_record(repo, run, seed)
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
    r = t.dispatch_pulse(repo, "u4-df-bound")
    print(json.dumps({"action": r.get("action"), "reason": r.get("reason")}))

elif op == "df-shortcircuit-no-suppression":
    # Without iteration_pending in the short-circuit, the work-loop's
    # met=True (computed against all_steps_terminal) would fire EARLY —
    # pulse exits "predicate-met" / "done" before iteration runs.
    # NOTE: the predicate composition itself is in run_record.py and sets
    # iteration_pending; the pulse's short-circuit then must AND-NOT it.
    # Since the composition has already ANDed met=False, the patched
    # short-circuit going via pred["met"] alone would still see False.
    # Instead, this DF tests the SECONDARY scenario: by editing the
    # short-circuit to FORCE met=True ignoring the predicate, a different
    # behavior emerges. We probe the patched version's behavior on the
    # iterate-under-bound scenario: with the short-circuit unconditional-
    # firing, the helper exits "predicate-met" instead of iterating.
    _init_iter("u4-df-shortcir", decision="iterate", attempts=0,
                max_attempts=5, emit_count=1)
    r = t.dispatch_pulse(repo, "u4-df-shortcir")
    print(json.dumps({"action": r.get("action"), "reason": r.get("reason")}))

elif op == "df-killswitch-ignored":
    _init_iter("u4-df-kill", decision="iterate", attempts=0,
                max_attempts=5, emit_count=1)
    os.environ["CLAUDE_AUTO_DISABLE_ITERATION"] = "1"
    os.environ["CLAUDE_AUTO_TEST_HARNESS"] = "1"
    try:
        led = m.read_run_record(repo, "u4-df-kill")
        direct = t.pulse_advance.advance_iteration_loop(repo, "u4-df-kill", led)
    finally:
        del os.environ["CLAUDE_AUTO_DISABLE_ITERATION"]
    print(json.dumps({"direct_is_none": direct is None,
                       "action": (direct or {}).get("action")}))

elif op == "df-finally-skipped":
    # Patched pulse.py removes the finally accumulate; a backend raise
    # leaves active_wall_seconds unchanged. We drive a raise-pulse (the
    # inner try/except in _pulse_body_inner captures the backend raise so
    # the pulse returns; the finally would otherwise still accumulate).
    p = m.run_record_path(repo, "u4-df-fin")
    if os.path.exists(p): os.unlink(p)
    m.init_run_record(repo, "u4-df-fin", backend="ce", loop_phase="plan",
                  steps=[{"id":"U1","state":"dispatched",
                          "dispatched_at":"2026-01-01T00:00:00Z",
                          "stall_threshold_seconds":600}])
    before = m.read_run_record(repo, "u4-df-fin").get("active_wall_seconds", 0)
    class Boom:
        def next_plan_step(self, led):
            raise RuntimeError("boom")
    try:
        t.dispatch_pulse(repo, "u4-df-fin", backend=Boom())
    except Exception:
        pass
    after = m.read_run_record(repo, "u4-df-fin").get("active_wall_seconds", 0)
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
# argv ($1 = path to the temp pulse.py) and rewrites it in place. Plain
# `src.replace(...)`, no regex — anchors are the exact source strings we ship.
DF_DIR="$(mktemp -d -t u4-df-scripts.XXXXXX)"
trap 'cleanup; rm -rf "$DF_DIR"' EXIT

cat > "$DF_DIR/df1_skip_bound.py" <<'PYEOF'
"""DF#1: force evaluate_decision's result to keep decision_effective='iterate'
even at attempts==max. After the patched advance_iteration_loop reads the
result, it always takes the iterate branch — bound is functionally skipped."""
import os, sys
p = os.path.join(sys.argv[1], "pulse_advance.py")  # B4: anchor moved to pulse_advance
src = open(p).read()
old = 'eval_result = iteration.evaluate_decision(\n        led, gate_step_id, now_monotonic=time.monotonic()\n    )'
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
short-circuit at pulse.py:564-576. The short-circuit then fires on raw
`met` alone — but `recompute_predicate` ANDs iteration_pending into met (U2
KTD §B), so even without the local guard, met is False on an iterate-
pending run_record. To prove the GUARD is load-bearing in isolation, we ALSO
patch advance_iteration_loop to no-op AND patch the composed met to ignore
iteration_pending. Cleaner single-shot: instead, prove the GUARD is load-
bearing by ALSO disabling the composition (set CLAUDE_AUTO_TEST_NO_RECOMPUTE)
— but that needs the hatch. We take the simpler path: patch the short-
circuit to ALSO accept iteration_pending=True as a trigger, then disable
the iteration helper. With both disabled, an iterate-pending run_record exits
'predicate-met' instead of iterating."""
import os, sys
# B4: anchor 1 (advance_iteration_loop no-op) is in pulse_advance.py; anchor 2
# (the predicate-met short-circuit) is in pulse.py's _try_predicate_met_shortcircuit.
pa = os.path.join(sys.argv[1], "pulse_advance.py")
src_a = open(pa).read()
old_def = 'def advance_iteration_loop(repo_root, run_id, led):\n    """'
new_def = 'def advance_iteration_loop(repo_root, run_id, led):\n    return None  # DF#2 PATCH\n    """'
if old_def not in src_a:
    sys.exit("DF#2 anchor 1 not found")
src_a = src_a.replace(old_def, new_def, 1)
open(pa, "w").write(src_a)

pt = os.path.join(sys.argv[1], "pulse.py")
src_t = open(pt).read()
old_sc = ('if pred.get("met") and not pred.get("iteration_pending", False) \\\n'
          '            and phase_grammar.is_terminal_phase(led, phase):')
new_sc = ('if (pred.get("met") or pred.get("iteration_pending")) \\\n'
          '            and phase_grammar.is_terminal_phase(led, phase):')
if old_sc not in src_t:
    sys.exit("DF#2 anchor 2 not found")
src_t = src_t.replace(old_sc, new_sc)
open(pt, "w").write(src_t)
PYEOF

cat > "$DF_DIR/df3_no_fence.py" <<'PYEOF'
"""DF#3: remove the kill-switch fence so the env hatch is ignored."""
import os, sys
p = os.path.join(sys.argv[1], "pulse_advance.py")  # B4: anchor moved to pulse_advance
src = open(p).read()
old = 'if is_iteration_disabled():\n        return None'
new = 'if False:  # DF#3 PATCH — kill-switch removed\n        return None'
if old not in src:
    sys.exit("DF#3 anchor not found")
open(p, "w").write(src.replace(old, new))
PYEOF

cat > "$DF_DIR/df4_no_finally.py" <<'PYEOF'
"""DF#4: remove the try/finally wrapping _pulse_body_inner so the crashed-
pulse path no longer accumulates active_wall_seconds."""
import os, sys
p = os.path.join(sys.argv[1], "pulse.py")  # B4: _pulse_body stays in pulse.py
src = open(p).read()
old1 = "    t_start = time.monotonic()\n    try:\n        return _pulse_body_inner("
new1 = "    t_start = time.monotonic()\n    if True:\n        return _pulse_body_inner("
if old1 not in src:
    sys.exit("DF#4 anchor 1 not found")
src = src.replace(old1, new1)
old2 = ("    finally:\n"
        "        # accumulate_active_time is best-effort: an exception inside it must\n"
        "        # never bury the real exception/return value. (E.g. a torn run-record\n"
        "        # during a stalled-write recovery would otherwise mask the original.)\n"
        "        try:\n"
        "            run_record.accumulate_active_time(\n"
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
res="$(u4_df_with_patched_pulse "$DF_DIR/df1_skip_bound.py" df-bound-skip)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
# In the DF the bound is skipped → iterate path fires → action=rearm.
if [ "$action" = "rearm" ]; then
  pass
else
  fail "DF expected action=rearm (iterates past bound); got action=$action res=$res"
fi

# DF#2 — make advance_iteration_loop a no-op AND force the short-circuit to
# fire on iteration_pending too. Together: iterate-pending run-record exits as
# "predicate-met" (the suppression is no longer load-bearing). Proves the
# iteration check + short-circuit-suppression contract.
it "U4 DELIBERATE-FAIL #2: skipping the iteration check + dropping the AND-NOT clause → iterate run_record exits predicate-met"
res="$(u4_df_with_patched_pulse "$DF_DIR/df2_short_circuit_no_suppress.py" df-shortcircuit-no-suppression)"
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
res="$(u4_df_with_patched_pulse "$DF_DIR/df3_no_fence.py" df-killswitch-ignored)"
none="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['direct_is_none'])" "$res")"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['action'])" "$res")"
if [ "$none" = "False" ] && [ "$action" = "iterate" ]; then
  pass
else
  fail "DF expected direct_is_none=False action=iterate; got none=$none action=$action res=$res"
fi

# DF#4 — Move accumulate_active_time out of the finally clause. With the
# finally removed, a backend-raise return path doesn't call accumulate, so
# active_wall_seconds stays at 0.
it "U4 DELIBERATE-FAIL #4: moving accumulate_active_time out of finally → crashed-pulse active_wall_seconds stays unchanged"
res="$(u4_df_with_patched_pulse "$DF_DIR/df4_no_finally.py" df-finally-skipped)"
advanced="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$res")"
if [ "$advanced" = "False" ]; then
  pass
else
  fail "DF expected advanced=False (no accumulation in DF); got advanced=$advanced res=$res"
fi

# ════════════════════════════════════════════════════════════════════════════
# F2 DELIBERATE-FAILS — three controls proving the three F2 fixes are load-
# bearing. Each control reverts the F2 fix via the same Edit-the-tmp-copy
# pattern as U4's DFs above.
# ════════════════════════════════════════════════════════════════════════════

# DF#5 patch: remove the try/except around advance_iteration_loop in
# _pulse_body_inner so an iteration-check raise propagates straight up. Without
# the wrap, a malformed iterate run-record raises out of dispatch_pulse → _cli
# (which catches only PulseError/RunRecordError) → no JSON intent, wedge.
cat > "$DF_DIR/df5_no_iteration_try.py" <<'PYEOF'
"""DF#5: strip the try/except around advance_iteration_loop in
_try_iteration_check (pulse.py, post-B4) so a non-RunRecord raise propagates
instead of being converted into a stop intent."""
import os, sys
p = os.path.join(sys.argv[1], "pulse.py")  # B4: the try/except is in _try_iteration_check (pulse.py)
src = open(p).read()
old = (
    "    try:\n"
    "        iteration_result = pulse_advance.advance_iteration_loop(repo_root, run_id, led)\n"
    "    except (run_record.UnknownStep, run_record.InvalidTransition, run_record.StaleVerdict) as exc:\n"
)
if old not in src:
    sys.exit("DF#5 anchor 1 not found")
# Replace the try-line + the entire wrap with a bare call, dropping
# everything from `    try:` through the closing `}` of the except handler.
start = src.find(old)
# Locate the end of the wrap: the wrap ends just before the line
# `    if iteration_result is not None:`.
end_marker = "    if iteration_result is not None:"
end_idx = src.find(end_marker, start)
if end_idx < 0:
    sys.exit("DF#5 anchor 2 not found")
replacement = (
    "    iteration_result = pulse_advance.advance_iteration_loop(repo_root, run_id, led)\n"
)
open(p, "w").write(src[:start] + replacement + src[end_idx:])
PYEOF

# DF#6 patch: revert the emit_template-optional branch so the iterate path
# ALWAYS calls iterate_template even when the workflow omits emit_template.
# Under a workflow with iteration but no emit_template, iterate_template raises
# WorkflowError at lib/producers.py:229.
cat > "$DF_DIR/df6_no_optional_emit.py" <<'PYEOF'
"""DF#6: revert the F2 emit_template-optional branch so the iterate path
unconditionally hardcodes producer=iterate_template. With a workflow that
omits iteration.emit_template, iterate_template raises WorkflowError."""
import os, sys
p = os.path.join(sys.argv[1], "pulse_advance.py")  # B4: anchor moved to pulse_advance
src = open(p).read()
old = (
    '        if (led.get("iteration") or {}).get("emit_template"):\n'
    '            producer = producers.iterate_template\n'
    '        else:\n'
    '            producer = producers.no_emit\n'
    '        run_record.atomic_iterate_step(\n'
    '            repo_root,\n'
    '            run_id,\n'
    '            gate_step_id,\n'
    '            producer=producer,\n'
    '            new_depends_on=None,\n'
    '        )'
)
new = (
    '        run_record.atomic_iterate_step(\n'
    '            repo_root,\n'
    '            run_id,\n'
    '            gate_step_id,\n'
    '            producer=producers.iterate_template,  # DF#6 PATCH\n'
    '            new_depends_on=None,\n'
    '        )'
)
if old not in src:
    sys.exit("DF#6 anchor not found")
open(p, "w").write(src.replace(old, new))
PYEOF

# DF#7 patch: revert the off-by-one fix in _iteration_guidance_prefix back
# to `attempts == max_attempts - 1`. At attempts=max-1, the buggy version
# fires the warning even though the next iterate (incrementing to attempts=
# max) is still honored by evaluate_decision — TWO iterates remain before
# bound trip, not one. The probe asserts the warning appears at attempts=
# max-1 in the buggy DF; the FIXED version returns no warning at that
# attempts count.
cat > "$DF_DIR/df7_off_by_one.py" <<'PYEOF'
"""DF#7: revert the off-by-one fix in _iteration_guidance_prefix so the
"last attempt before bound" warning fires one pulse too early."""
import os, sys
p = os.path.join(sys.argv[1], "pulse_guidance.py")  # B4: anchor moved to pulse_guidance
src = open(p).read()
old = 'if max_attempts is not None and attempts == int(max_attempts):'
new = 'if max_attempts is not None and attempts == int(max_attempts) - 1:  # DF#7 PATCH'
if old not in src:
    sys.exit("DF#7 anchor not found")
open(p, "w").write(src.replace(old, new))
PYEOF

# Extend the u4_df_with_patched_pulse probes with F2-specific ops. Rather than
# editing the inline heredoc above (which would require restructuring the
# helper), define a sibling driver for the F2 probes — same shape, F2-only ops.
f2_df_with_patched_pulse() {
  local patch_script="$1" probe_op="$2"
  local tmpdir; tmpdir="$(mktemp -d -t f2-df.XXXXXX)"
  # B4: same three-file copy + sibling pre-load pattern as u4_df_with_patched_pulse.
  cp "$PULSE_PY" "$tmpdir/pulse.py"
  cp "$AUTO_ROOT/lib/pulse_advance.py" "$tmpdir/pulse_advance.py"
  cp "$AUTO_ROOT/lib/pulse_guidance.py" "$tmpdir/pulse_guidance.py"
  "$PY" "$patch_script" "$tmpdir"
  local patch_rc=$?
  if [ "$patch_rc" -ne 0 ]; then
    rm -rf "$tmpdir"
    fail "F2 DF patch script $patch_script failed with rc=$patch_rc"
    return 0
  fi
  PULSE_PY_OVERRIDE_DIR="$tmpdir" "$PY" - "$AUTO_ROOT" "$REPO" "$probe_op" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo, op = sys.argv[1:4]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("run_record")
tmpdir = os.environ["PULSE_PY_OVERRIDE_DIR"]
def _preload(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(tmpdir, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    mod.__file__ = os.path.join(auto_root, "lib", name + ".py")
    return mod
_preload("pulse_guidance")
_preload("pulse_advance")
t_path = os.path.join(tmpdir, "pulse.py")
t_spec = importlib.util.spec_from_file_location("pulse_patched", t_path)
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)

def _init_iter_no_emit(run, *, attempts=0, max_attempts=5):
    """Seed an A4-style run_record with iteration but NO emit_template — the
    F2-correctness-emit-template shape. Used by both df-no-emit-raises (DF#6)
    and the corresponding green-path test."""
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    steps = [
        {"id": "plan-1", "state": "fixed", "phase": "plan", "findings": []},
        {"id": "build-clarity", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "build-perf", "state": "fixed", "phase": "work",
         "depends_on": ["plan-1"], "findings": []},
        {"id": "compare", "state": "pending", "phase": "work",
         "depends_on": ["build-clarity", "build-perf"]},
    ]
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan","handoff","work"], terminal_phase="work",
                  steps=steps)
    def seed(L):
        # iteration WITHOUT emit_template (validator allows it; see
        # lib/workflows.py:380-393). No emit_templates declared either.
        L["iteration"] = {"gate_step": "compare",
                          "bound": {"max_attempts": max_attempts}}
        L["iteration_attempts"] = attempts
        for u in L["steps"]:
            if u["id"] == "compare":
                u["state"] = "dispatched"
    m._with_locked_run_record(repo, run, seed)
    m.record_verdict(repo, run, "compare", [])
    m.set_verdict_decision(repo, run, "compare", "iterate")

def _init_iter_bad_decision(run):
    """Seed an iteration run_record with a CORRUPTED gate decision so
    iteration.evaluate_decision raises ValueError. Used by DF#5 probe to
    prove the unwrapped path wedges."""
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    steps = [
        {"id": "plan-1", "state": "fixed", "phase": "plan", "findings": []},
        {"id": "judge", "state": "pending", "phase": "work",
         "depends_on": ["plan-1"]},
    ]
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan","handoff","work"], terminal_phase="work",
                  steps=steps)
    def seed(L):
        L["iteration"] = {"gate_step": "judge", "emit_template":
                          "plan-candidate", "bound": {"max_attempts": 5}}
        L["emit_templates"] = {"plan-candidate": {
            "phase":"plan","invokes":{"backend_op":"next_plan_step"},
            "id_prefix":"plan-"}}
        L["iteration_attempts"] = 0
        L["iteration_emit_count"] = 1
        for u in L["steps"]:
            if u["id"] == "judge":
                u["state"] = "dispatched"
    m._with_locked_run_record(repo, run, seed)
    m.record_verdict(repo, run, "judge", [])
    # Write a BOGUS decision string directly via _with_locked_run_record so we
    # bypass set_verdict_decision's validation. evaluate_decision will
    # then raise ValueError ("must be one of {advance,iterate,exit}").
    def corrupt(L):
        for u in L["steps"]:
            if u["id"] == "judge":
                dc = u.setdefault("dispatch_context", {})
                dc["decision"] = "GARBAGE"
    m._with_locked_run_record(repo, run, corrupt)

if op == "df-iteration-raise-unwrapped":
    # DF#5: pulse.py has no try/except around advance_iteration_loop. A
    # raise inside iteration.evaluate_decision propagates out of dispatch
    # _pulse — we observe it as a Python exception, NOT a stop-intent.
    _init_iter_bad_decision("f2-df-raise")
    try:
        r = t.dispatch_pulse(repo, "f2-df-raise")
        # If no raise, the DF didn't trigger — buggy if dispatch returned a
        # stop intent (the F2 fix would produce one; the DF should NOT).
        print(json.dumps({"raised": False, "action": (r or {}).get("action"),
                          "reason": (r or {}).get("reason")}))
    except Exception as exc:
        print(json.dumps({"raised": True, "exc_type": type(exc).__name__,
                          "exc_msg": str(exc)}))

elif op == "df-no-emit-raises":
    # DF#6: iterate_template ALWAYS called; on a no-emit_template workflow
    # this raises WorkflowError. With the F2 fix, the iterate path uses the
    # no-op producer instead and the pulse re-arms cleanly.
    _init_iter_no_emit("f2-df-noemit", attempts=0, max_attempts=5)
    try:
        r = t.dispatch_pulse(repo, "f2-df-noemit")
        print(json.dumps({"raised": False, "action": (r or {}).get("action"),
                          "reason": (r or {}).get("reason")}))
    except Exception as exc:
        print(json.dumps({"raised": True, "exc_type": type(exc).__name__,
                          "exc_msg": str(exc)[:200]}))

elif op == "df-off-by-one-warns-early":
    # DF#7: the off-by-one is reverted, so the warning fires at
    # attempts==max-1 even though TWO more iterates would be honored before
    # bound trip. With the F2 fix, no warning fires at attempts==max-1.
    # We seed an attempts=max-1 run-record and call the helper directly.
    _init_iter_no_emit("f2-df-obo", attempts=4, max_attempts=5)
    led = m.read_run_record(repo, "f2-df-obo")
    prefix = t._iteration_guidance_prefix(led)
    print(json.dumps({
        "warns_early": "last attempt before bound" in prefix,
        "attempts": led.get("iteration_attempts"),
    }))

else:
    print(f"unknown op: {op}")
    sys.exit(2)
PYEOF
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# DF#5 — Strip the try/except around advance_iteration_loop. A raise from
# iteration.evaluate_decision (corrupted gate decision) propagates out of
# dispatch_pulse; the call site re-raises rather than emitting a stop intent.
it "F2 DELIBERATE-FAIL #5 (rel-1): WITHOUT the iteration try/except → a malformed-decision raise propagates instead of converting to a stop intent"
res="$(f2_df_with_patched_pulse "$DF_DIR/df5_no_iteration_try.py" df-iteration-raise-unwrapped)"
raised="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['raised'])" "$res")"
if [ "$raised" = "True" ]; then
  pass
else
  fail "DF#5 expected raised=True (the iteration check raises out of dispatch_pulse); got $res"
fi

# DF#6 — Revert the F2 emit_template-optional branch. With the iterate path
# unconditionally calling iterate_template, a workflow that has iteration but
# NO emit_template raises WorkflowError inside atomic_iterate_step. DF#6 only
# reverts the optional-emit branch — the F2 try/except (DF#5's target) is
# left intact — so the visible effect is a stop intent with
# reason="iteration-check-failed". We assert EXACTLY that observable.
it "F2 DELIBERATE-FAIL #6 (correctness-emit-template): WITHOUT the no-op producer branch → an iterate path on a workflow missing emit_template fails the iteration check (try/except converts to stop reason=iteration-check-failed)"
res="$(f2_df_with_patched_pulse "$DF_DIR/df6_no_optional_emit.py" df-no-emit-raises)"
action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('action',''))" "$res")"
reason="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1]).get('reason',''))" "$res")"
if [ "$action" = "stop" ] && [ "$reason" = "iteration-check-failed" ]; then
  pass
else
  fail "DF#6 expected action=stop reason=iteration-check-failed; got action=$action reason=$reason res=$res"
fi

# DF#7 — Revert the off-by-one fix. At attempts=max-1=4 with max=5, the
# buggy version fires the "last attempt before bound" warning; the F2 fix
# returns "" because attempts != max.
it "F2 DELIBERATE-FAIL #7 (ADV-3): reverting the bound-warning fix → 'last attempt before bound' fires at attempts==max-1 (the F2-fixed code does NOT warn there)"
res="$(f2_df_with_patched_pulse "$DF_DIR/df7_off_by_one.py" df-off-by-one-warns-early)"
warns_early="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['warns_early'])" "$res")"
attempts="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['attempts'])" "$res")"
if [ "$warns_early" = "True" ] && [ "$attempts" = "4" ]; then
  pass
else
  fail "DF#7 expected warns_early=True attempts=4; got warns_early=$warns_early attempts=$attempts res=$res"
fi

# ════════════════════════════════════════════════════════════════════════════
# v0.3.0 G2 — exit_reason persistence (AN-W1) + RunRecordError-subclass narrow
# catch (rel-r2-2). Two GREEN-path tests + one DF cycle each. Both run against
# the PRODUCTION pulse.py (not a patched copy) so the assertions verify the
# fix is wired in the canonical source. The DF cycles are documented as
# operator-run Edit-revert workflows — the existing DF#5 sibling already
# enforces the try/except's presence; G2's narrower contract is the
# subclass branch + the exit_reason write.
# ════════════════════════════════════════════════════════════════════════════

# G2 GREEN test #1 (AN-W1): on an iteration-check crash, F2's try/except must
# persist exit_reason on the run-record BEFORE force-marking the loop done. This
# uses the SAME corrupted-gate-decision shape as DF#5 (decision="GARBAGE" →
# iteration.evaluate_decision raises ValueError → caught by the generic
# Exception branch). The contract: exit_reason.kind == "iteration-check-failed"
# AND exit_reason.error carries {type, message}. DF cycle (operator probe):
# comment out the `run_record.set_exit_reason(...)` call in the Exception branch
# of lib/pulse.py → this test reports exit_reason=None.
it "G2 AN-W1: iteration-check crash persists exit_reason on the run_record (kind=iteration-check-failed)"
g2_anw1="$("$PY" - "$AUTO_ROOT" "$REPO" "$PULSE_PY" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo, pulse_py, run_record_py = sys.argv[1:5]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("run_record")
t_spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)

run = "g2-anw1"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
steps = [
    {"id": "plan-1", "state": "fixed", "phase": "plan", "findings": []},
    {"id": "judge", "state": "pending", "phase": "work",
     "depends_on": ["plan-1"]},
]
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              phase_order=["plan","handoff","work"], terminal_phase="work",
              steps=steps)
def seed(L):
    L["iteration"] = {"gate_step": "judge", "emit_template":
                      "plan-candidate", "bound": {"max_attempts": 5}}
    L["emit_templates"] = {"plan-candidate": {
        "phase":"plan","invokes":{"backend_op":"next_plan_step"},
        "id_prefix":"plan-"}}
    L["iteration_attempts"] = 0
    L["iteration_emit_count"] = 1
    for u in L["steps"]:
        if u["id"] == "judge":
            u["state"] = "dispatched"
m._with_locked_run_record(repo, run, seed)
m.record_verdict(repo, run, "judge", [])
def corrupt(L):
    for u in L["steps"]:
        if u["id"] == "judge":
            dc = u.setdefault("dispatch_context", {})
            dc["decision"] = "GARBAGE"
m._with_locked_run_record(repo, run, corrupt)

r = t.dispatch_pulse(repo, run)
after = m.read_run_record(repo, run)
er = after.get("exit_reason") or {}
err = er.get("error") or {}
print(json.dumps({
    "intent_action": (r or {}).get("action"),
    "intent_reason": (r or {}).get("reason"),
    "exit_reason_kind": er.get("kind"),
    "error_type": err.get("type"),
    "has_message": bool(err.get("message")),
    "has_at": bool(er.get("at")),
}))
PYEOF
)"
exit_kind="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['exit_reason_kind'])" "$g2_anw1")"
err_type="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['error_type'])" "$g2_anw1")"
has_msg="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['has_message'])" "$g2_anw1")"
has_at="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['has_at'])" "$g2_anw1")"
if [ "$exit_kind" = "iteration-check-failed" ] && [ "$err_type" = "ValueError" ] \
   && [ "$has_msg" = "True" ] && [ "$has_at" = "True" ]; then
  pass
else
  fail "G2 AN-W1 expected kind=iteration-check-failed err_type=ValueError + message+at; got $g2_anw1"
fi

# G2 GREEN test #2 (rel-r2-2): when advance_iteration_loop raises a
# RunRecordError SUBCLASS (UnknownStep / InvalidTransition / StaleVerdict — these
# indicate a workflow-bug caller, NOT a torn run-record), F2's try/except must
# catch it via the NARROWED branch and emit reason="workflow-bug". The bare
# `except run_record.RunRecordError: raise` MUST come AFTER the subclass tuple, or
# the parent catch would shadow the subclasses (they ARE RunRecordError).
# We monkey-patch advance_iteration_loop on the production pulse module to
# raise UnknownStep directly — same shape as a workflow-bug field bug.
# DF cycle (operator probe): swap the except-order in lib/pulse.py so the
# bare RunRecordError catch precedes the subclass tuple → this test sees the
# raise propagate (no stop intent, no exit_reason on the run-record).
it "G2 rel-r2-2: run_record.UnknownStep from advance_iteration_loop → stop reason=workflow-bug + exit_reason persisted"
g2_workflow="$("$PY" - "$AUTO_ROOT" "$REPO" "$PULSE_PY" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, os, importlib.util
auto_root, repo, pulse_py, run_record_py = sys.argv[1:5]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
m = load_lib_module("run_record")
t_spec = importlib.util.spec_from_file_location("pulse", pulse_py)
t = importlib.util.module_from_spec(t_spec); t_spec.loader.exec_module(t)

run = "g2-relr22"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
# Plan-loop run-record so the iteration check normally returns None — but the
# monkey-patched advance_iteration_loop forces an UnknownStep raise
# regardless of run-record shape. We seed it with one pending plan step so
# dispatch_pulse reaches the iteration check.
steps = [{"id": "plan-1", "state": "pending", "phase": "plan"}]
m.init_run_record(repo, run, backend="ce", loop_phase="plan",
              phase_order=["plan","work"], terminal_phase="work",
              steps=steps)

# Monkey-patch the advance helper — replace advance_iteration_loop with one
# that raises run_record.UnknownStep. Post-B4 the function lives in the sibling
# pulse_advance module and the dispatcher calls it qualified
# (pulse_advance.advance_iteration_loop), so we patch it THERE (patching the
# pulse-module re-export alias would not affect the qualified call site). The
# narrowed except in _pulse_body_inner refers to the same `run_record` module
# (shared via load_lib_module's __file__-keyed cache), so the isinstance
# check matches.
def _boom(repo_root, run_id, led):
    raise m.UnknownStep("workflow-bug: gate_step refers to a step not in steps[]")
t.pulse_advance.advance_iteration_loop = _boom

try:
    r = t.dispatch_pulse(repo, run)
    raised = False
    exc_type = None
except Exception as exc:
    r = None
    raised = True
    exc_type = type(exc).__name__

after = m.read_run_record(repo, run)
er = after.get("exit_reason") or {}
err = er.get("error") or {}
print(json.dumps({
    "raised": raised,
    "exc_type": exc_type,
    "intent_action": (r or {}).get("action"),
    "intent_reason": (r or {}).get("reason"),
    "exit_reason_kind": er.get("kind"),
    "error_type": err.get("type"),
}))
PYEOF
)"
raised="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['raised'])" "$g2_workflow")"
intent_action="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['intent_action'])" "$g2_workflow")"
intent_reason="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['intent_reason'])" "$g2_workflow")"
exit_kind="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['exit_reason_kind'])" "$g2_workflow")"
err_type="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['error_type'])" "$g2_workflow")"
if [ "$raised" = "False" ] && [ "$intent_action" = "stop" ] \
   && [ "$intent_reason" = "workflow-bug" ] && [ "$exit_kind" = "workflow-bug" ] \
   && [ "$err_type" = "UnknownStep" ]; then
  pass
else
  fail "G2 rel-r2-2 expected raised=False action=stop reason=workflow-bug exit_kind=workflow-bug err_type=UnknownStep; got $g2_workflow"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "pulse-iteration.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
