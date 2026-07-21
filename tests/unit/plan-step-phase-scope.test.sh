#!/usr/bin/env bash
# auto U4 (findings #3 + #4): the plan step is DELIBERATELY left `pending` after
# plan-done (the plan-loop's advance lives in run_record["plan_step"], not a step
# state transition — see run_record_predicate.py _compute_terminality docstring).
# Because it stays pending in the `work` phase, two read-side bugs surface:
#
#   #3 — dispatcher.ready_steps returns the phase=plan step during work phase, so
#        a naive driver dispatches `/ce-work plan`.
#   #4 — recompute_predicate reports all_steps_terminal:false (the GLOBAL all())
#        beside met:true at work-exit — a self-contradictory exit report.
#
# Fix is read-side (OQ1 resolved to read-side — write-side terminalization would
# fight the engine's intentional pending plan step and violate the transition
# grammar): phase-scope ready_steps to the current phase, and report the
# eval-phase-scoped all_steps_terminal (retain the global under a new key).
#
# Institutional anchors:
#   - field-notes-2026-07-21 findings #3, #4
#   - feedback_reproduce_before_you_plan (both symptoms reproduced first)

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
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

# Driver: build a post-flip w-shape run-record in-heredoc and probe one fact.
probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
def load(n, f):
    s = importlib.util.spec_from_file_location(n, os.path.join(auto_root, "lib", f))
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
scenario = sys.argv[2]

# loop_phase=work; a pending plan step (phase=plan) + a terminal work step.
rr = {
    "loop_phase": "work", "terminal_phase": "work", "backend_scale": "three-tier",
    "plan_step": "review_plan",
    "steps": [
        {"id": "plan", "phase": "plan", "state": "pending",
         "invokes": {"backend_op": "next_plan_step"}},
        {"id": "U1", "phase": "work", "state": "verdict-returned", "findings": []},
    ],
}

if scenario == "ready_excludes_plan":
    disp = load("dispatcher", "dispatcher.py")
    # plan step (phase=plan, pending) beside a PENDING work step: during the work
    # phase the plan step must be filtered out while the work step stays ready.
    steps = [
        {"id": "plan", "phase": "plan", "state": "pending",
         "invokes": {"backend_op": "next_plan_step"}},
        {"id": "Uw", "phase": "work", "state": "pending"},
    ]
    by_id = {u["id"]: u for u in steps}
    ready = [u["id"] for u in steps
             if disp._is_ready(u, by_id, "three-tier", current_phase="work")]
    print(",".join(ready))
elif scenario == "ready_keeps_work_in_own_phase":
    # Sanity: during the PLAN phase, the plan step IS ready (not filtered).
    disp = load("dispatcher", "dispatcher.py")
    plan_rr_steps = [{"id": "plan", "phase": "plan", "state": "pending"}]
    by_id = {u["id"]: u for u in plan_rr_steps}
    ready = [u["id"] for u in plan_rr_steps
             if disp._is_ready(u, by_id, "three-tier", current_phase="plan")]
    print(",".join(ready))
elif scenario == "legacy_phaseless_step_ready":
    # A legacy step with NO phase field must NOT be filtered (backward compat).
    disp = load("dispatcher", "dispatcher.py")
    steps = [{"id": "L1", "state": "pending"}]
    by_id = {u["id"]: u for u in steps}
    ready = [u["id"] for u in steps
             if disp._is_ready(u, by_id, "three-tier", current_phase="work")]
    print(",".join(ready))
elif scenario == "predicate_no_contradiction":
    pred = load("run_record_predicate", "run_record_predicate.py")
    p = pred.recompute_predicate(rr)
    # At work-met the reported all_steps_terminal must agree with met.
    print("met=%s ast=%s" % (p["met"], p["all_steps_terminal"]))
elif scenario == "predicate_global_retained":
    pred = load("run_record_predicate", "run_record_predicate.py")
    p = pred.recompute_predicate(rr)
    # The global value (includes the pending plan step) stays available.
    print(p.get("all_steps_terminal_global"))
else:
    sys.exit("unknown scenario: %s" % scenario)
PYEOF
}

echo "plan-step-phase-scope.test.sh"

it "#3: ready_steps EXCLUDES the phase=plan step during work phase, keeps the work step"
assert_eq "Uw" "$(probe ready_excludes_plan)"

it "#3: the plan step IS ready during the plan phase (filter is phase-scoped, not a blanket drop)"
assert_eq "plan" "$(probe ready_keeps_work_in_own_phase)"

it "#3: a legacy phaseless step is NOT filtered (backward compat)"
assert_eq "L1" "$(probe legacy_phaseless_step_ready)"

it "#4: work-met exit report is self-consistent (met=True ast=True, no contradiction)"
assert_eq "met=True ast=True" "$(probe predicate_no_contradiction)"

it "#4: the global all_steps_terminal is retained under all_steps_terminal_global"
assert_eq "False" "$(probe predicate_global_retained)"

echo ""
echo "plan-step-phase-scope.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
