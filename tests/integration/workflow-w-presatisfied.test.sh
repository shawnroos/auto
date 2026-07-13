#!/usr/bin/env bash
# auto v0.4.3 integration test: W (work-only) finishes the deferred KTD-15 —
# a reviewed plan goes STRAIGHT to work without re-running the plan-loop.
#
# WHY THIS TEST EXISTS (memory project_auto_v042_stuck_root_causes, root cause ③):
# Before this, smart-entry detected `reviewed-plan` but routed to a1, whose
# plan-loop re-ran /ce-plan + /ce-doc-review on the already-green plan ("auto
# re-plans a finished plan"). The W workflow that should skip the plan-loop was a
# v0.2.0 stub with no plan→steps enumeration. The fix makes W declare its plan
# phase `plan_presatisfied`: init sets plan_step="review_plan" + gaps_open=0 so
# the FIRST pulse's next_plan_step returns "done" → enumerate_plan_steps →
# plan→work, with NO plan/deepen/review pass.
#
# STRUCTURE: create a real W run via `/auto <plan> --workflow w`, assert the
# pre-satisfied run-record state, stash the model-enumerated work steps (what the
# model does when it executes the enumerate_plan_steps prepare op), pulse once in
# auto mode, and assert the run is now in `work` with those steps — proving the
# plan-loop was skipped entirely.
#
# DELIBERATE-FAIL CONTROL: a second run created WITHOUT plan_presatisfied (plain
# a1) on the same priming MUST NOT be plan-met at init — proving the green-path
# assertion is caused by the pre-satisfied init, not by something always-true.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

# Drive a workflow from /auto creation through one auto-mode pulse. Prints CSV:
#   init_plan_step | init_gaps_open | init_met | plan_path_bound | post_phase | work_step_ids
# workflow arg selects the workflow (w | a1).
drive_presatisfied() {
  workflow="${1:-w}"
  "$PY" - "$AUTO_ROOT" "$workflow" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
workflow = sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
run_record = load("run_record", os.path.join(auto_root, "lib", "run_record.py"))
pulse = load("pulse", os.path.join(auto_root, "lib", "pulse.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "reviewed-plan.md"); open(plan, "w").write("# Reviewed Plan\n")

with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--workflow", workflow])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

led = json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))
init_step = led.get("plan_step")
epr = led.get("exit_predicate_result") or {}
init_gaps = epr.get("gaps_open")
init_met = epr.get("met")
plan_steps = [u for u in led["steps"] if u.get("phase") == "plan"]
plan_path_bound = bool(plan_steps) and (plan_steps[0].get("dispatch_context") or {}).get("plan_path") == plan

# PULSE 1 — the model has NOT enumerated yet (production reality). The producer
# handshake must NOT transition to work with zero steps: it stays in the plan
# phase and surfaces the enumerate prepare op.
with contextlib.redirect_stdout(io.StringIO()):
    intent1 = pulse.dispatch_pulse(repo, run_id, auto=True)
led1 = json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))
pulse1_phase = led1["loop_phase"]
guidance1 = intent1.get("operator_guidance", "")
enumerate_surfaced = "ENUMERATE" in guidance1 or "enumerate" in guidance1

# The model executes the enumerate_plan_steps prepare op → stashes work steps.
run_record.set_enumerated_steps(repo, run_id, plan_steps[0]["id"], [
    {"id": "u-a", "invokes": {"backend_op": "do_step"}},
    {"id": "u-b", "invokes": {"backend_op": "do_step"}},
])

# PULSE 2 — now the steps exist, so the handshake passes and we transition.
with contextlib.redirect_stdout(io.StringIO()):
    pulse.dispatch_pulse(repo, run_id, auto=True)
led2 = json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))
work = sorted(u["id"] for u in led2["steps"] if u.get("phase") == "work")
print("%s|%s|%s|%s|%s|%s|%s|%s" % (
    init_step, init_gaps, init_met, plan_path_bound,
    pulse1_phase, enumerate_surfaced, led2["loop_phase"], ",".join(work),
))
PYEOF
}

# ─── Green path: W is pre-satisfied, handshakes for steps, then works ───────
res="$(drive_presatisfied w)"
IFS='|' read -r g_step g_gaps g_met g_bound g_t1phase g_enum g_phase g_work <<EOF
$res
EOF

it "W inits plan-presatisfied (plan_step=review_plan, gaps_open=0, plan-met)"
[ "$g_step" = "review_plan" ] && [ "$g_gaps" = "0" ] && [ "$g_met" = "True" ] \
  && pass || fail "expected review_plan|0|True, got ${g_step}|${g_gaps}|${g_met}"

it "W binds the plan doc path to the plan step (enumerate knows which plan)"
[ "$g_bound" = "True" ] && pass || fail "plan_path not bound: ${g_bound}"

# THE PRODUCER HANDSHAKE: without it, pulse 1 would flip to work with ZERO steps
# and the run would wedge. The fix keeps it in the plan phase and surfaces the
# enumerate prepare op until the model stashes steps.
it "W pulse 1 (no steps yet) stays in plan and surfaces the enumerate prepare (handshake)"
[ "$g_t1phase" = "plan" ] && [ "$g_enum" = "True" ] \
  && pass || fail "expected plan|True (enumerate-pending), got ${g_t1phase}|${g_enum}"

it "W pulse 2 (steps stashed) transitions to work with the enumerated steps"
[ "$g_phase" = "work" ] && [ "$g_work" = "u-a,u-b" ] \
  && pass || fail "expected work|u-a,u-b, got ${g_phase}|${g_work}"

# ─── Deliberate-fail control: a1 (no plan_presatisfied) is NOT met at init ──
it "DELIBERATE-FAIL: a1 is NOT plan-met at init (proves pre-satisfied is the cause)"
res_a1="$(drive_presatisfied a1)"
IFS='|' read -r a_step a_gaps a_met a_rest <<EOF
$res_a1
EOF
# a1 inits plan_step=null, gaps_open=null → not met; it would need a real
# plan-loop. If a1 came back plan-met at init, the green path above would be
# vacuous (something other than plan_presatisfied set the state).
[ "$a_met" != "True" ] && pass || fail "a1 was plan-met at init (${a_met}) — green path is vacuous"

printf "%s: %d passed, %d failed\n" "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
