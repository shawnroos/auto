#!/usr/bin/env bash
# auto U8 integration test: typed-verification gate end-to-end.
#
# Ties together the three steps: a workflow with a verification gate VALIDATES
# (lib/workflows.py), then lib/iteration.py::resolve_gate_verification runs its
# programmatic criteria (lib/verification.py) and folds in an injected advisor
# verdict to produce the advance/iterate SIGNAL — with the deterministic exit
# predicate left untouched. The live `advisor` call is integration-only and NOT
# exercised here; the advisor verdict is injected as data (KTD-6), which is the
# whole point of the pure aggregate.

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

e2e() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
workflows = load_lib_module("workflows")
iteration = load_lib_module("iteration")
op = sys.argv[2]

# A workflow whose work-phase gate step carries a typed verification block:
# one programmatic criterion + one advisor_judge criterion.
def workflow(prog_argv):
    return {
        "name": "vgate", "version": "1", "default_backend": "ce",
        "phase_order": ["plan", "work"], "terminal_phase": "work",
        "phase_transitions": [{"from": "plan", "to": "work",
                               "producer": "plan_output_to_work_steps"}],
        "steps": [
            {"id": "plan", "phase": "plan", "depends_on": [],
             "invokes": {"backend_op": "next_plan_step"}},
            {"id": "gate", "phase": "work", "depends_on": [],
             "invokes": {"backend_op": "do_step"},
             "verification": [
                 {"id": "tests", "type": "programmatic",
                  "argv": prog_argv, "check": "exit_zero"},
                 {"id": "sound", "type": "advisor_judge", "rubric_ref": "design-sound"},
             ]},
        ],
    }

def led_from(workflow_dict):
    # minimal ledger mirror of the gate step (engine reads steps[])
    gate = next(u for u in workflow_dict["steps"] if u["id"] == "gate")
    return {"steps": [{"id": "gate", "phase": "work", "state": "verdict-returned",
                       "dispatch_context": {}, "verification": gate["verification"]}]}

if op == "validates":
    r = workflow(["true"])
    try:
        workflows.validate(r); print("valid")
    except workflows.WorkflowError as e:
        print("rejected:" + str(e)[:60])

elif op == "pass-and-advisor-pass":
    led = led_from(workflow(["true"]))
    print(iteration.resolve_gate_verification(led, "gate",
          judge_verdicts={"sound": "pass"})["signal"])

elif op == "prog-fail":
    led = led_from(workflow(["false"]))
    print(iteration.resolve_gate_verification(led, "gate",
          judge_verdicts={"sound": "pass"})["signal"])

elif op == "advisor-pending":
    led = led_from(workflow(["true"]))
    r = iteration.resolve_gate_verification(led, "gate")  # no advisor verdict yet
    print(f'{r["signal"]}|{",".join(r["pending_judges"])}')

elif op == "predicate-untouched":
    # A verification block on a step must not break the predicate recompute path
    # (compute_pending_state is called on every ledger write). No iteration block
    # here → iteration_pending must be False regardless of the verification data.
    led = led_from(workflow(["true"]))
    print("pending=" + str(iteration.compute_pending_state(led)))

else:
    print("UNKNOWN_OP")
PYEOF
}

echo "verification-gate.test.sh (U8 e2e)"

it "workflow with a typed verification gate validates"
assert_eq "valid" "$(e2e validates)"

it "programmatic pass + injected advisor pass → advance"
assert_eq "advance" "$(e2e pass-and-advisor-pass)"

it "programmatic fail (advisor pass) → iterate"
assert_eq "iterate" "$(e2e prog-fail)"

it "advisor_judge with no verdict → signal None, pending 'sound'"
assert_eq "None|sound" "$(e2e advisor-pending)"

it "verification block does not perturb the exit-predicate recompute (no iteration block → not pending)"
assert_eq "pending=False" "$(e2e predicate-untouched)"

echo ""
echo "verification-gate.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
