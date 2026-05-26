#!/usr/bin/env bash
# auto v0.3.0 U1 unit test: the ONE iteration-decision module.
#
# Mirrors tests/unit/phase-grammar.test.sh — every site that reads a gate
# unit's verdict.decision routes through this module. AST lint (sibling
# file tests/unit/iteration-ast-lint.test.sh) mechanically enforces that
# no other lib/*.py raw-subscripts dispatch_context["decision"] — same
# discipline as phase-grammar's "loop_phase" literal lint.
#
# Behavior contract from plan U1:
#   evaluate_decision(led, gate_unit_id, now_monotonic=None) -> dict with
#     decision_effective: "advance" | "iterate" | "exit" | None
#     original_decision: <same string or None>
#     bound_breached: bool
#     bound_type: "max_attempts" | "max_wall_seconds" | None
#     attempts_made: int
#
# Test scenarios (from plan U1):
#   1. advance — decision="advance" → decision_effective="advance", not breached
#   2. iterate under bound — attempts < max → effective stays "iterate"
#   3. bound: max_attempts — attempts == max → effective forced to "exit"
#   4. bound: max_wall_seconds — active_wall_seconds > max → effective forced to "exit"
#   5. no decision yet — read_decision returns None, evaluate returns None
#   6. unknown gate unit id — raises clear error

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

# Driver: load lib/iteration.py via _bootstrap, run an op, print result.
run_iter() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
iteration = load_lib_module("iteration")
op = sys.argv[2]

def make_led(decision, attempts=0, active_wall_seconds=0,
             max_attempts=5, max_wall_seconds=None):
    """A minimal ledger shape with one gate unit named 'judge' carrying the
    given decision payload, plus the iteration block + bound."""
    judge = {"id": "judge", "phase": "work", "state": "verdict-returned",
             "dispatch_context": {}}
    if decision is not None:
        judge["dispatch_context"]["decision"] = decision
    bound = {"max_attempts": max_attempts}
    if max_wall_seconds is not None:
        bound["max_wall_seconds"] = max_wall_seconds
    return {
        "units": [judge],
        "iteration": {"gate_unit": "judge", "bound": bound},
        "iteration_attempts": attempts,
        "active_wall_seconds": active_wall_seconds,
    }

if op == "advance":
    led = make_led("advance", attempts=1)
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({k: r.get(k) for k in (
        "decision_effective","original_decision","bound_breached","bound_type")}))

elif op == "iterate-under":
    led = make_led("iterate", attempts=2, max_attempts=5)
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({k: r.get(k) for k in (
        "decision_effective","bound_breached","bound_type")}))

elif op == "bound-attempts":
    led = make_led("iterate", attempts=5, max_attempts=5)
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({k: r.get(k) for k in (
        "decision_effective","bound_breached","bound_type","original_decision")}))

elif op == "bound-wall":
    led = make_led("iterate", attempts=1, max_attempts=5,
                   active_wall_seconds=1900, max_wall_seconds=1800)
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({k: r.get(k) for k in (
        "decision_effective","bound_breached","bound_type")}))

elif op == "no-decision":
    led = make_led(decision=None)
    rd = iteration.read_decision(led["units"][0])
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({
        "read_decision": rd,
        "decision_effective": r.get("decision_effective"),
    }))

elif op == "unknown-gate":
    led = make_led("advance")
    try:
        iteration.evaluate_decision(led, "ghost")
        print("NO-RAISE")
    except (KeyError, ValueError, Exception) as e:
        print("raised:" + type(e).__name__)

elif op == "decisions-constant":
    print(",".join(iteration.DECISIONS))

PYEOF
}

# ─── Scenario 1: advance ────────────────────────────────────────────────────
it "evaluate_decision: decision='advance' → effective='advance', not breached"
assert_eq \
  '{"decision_effective": "advance", "original_decision": "advance", "bound_breached": false, "bound_type": null}' \
  "$(run_iter advance)"

# ─── Scenario 2: iterate under bound ────────────────────────────────────────
it "evaluate_decision: decision='iterate' under bound → effective='iterate'"
assert_eq \
  '{"decision_effective": "iterate", "bound_breached": false, "bound_type": null}' \
  "$(run_iter iterate-under)"

# ─── Scenario 3: bound — max_attempts breached ──────────────────────────────
it "evaluate_decision: attempts==max_attempts → effective forced 'exit' (R4)"
assert_eq \
  '{"decision_effective": "exit", "bound_breached": true, "bound_type": "max_attempts", "original_decision": "iterate"}' \
  "$(run_iter bound-attempts)"

# ─── Scenario 4: bound — max_wall_seconds breached ──────────────────────────
it "evaluate_decision: active_wall_seconds>max → effective forced 'exit' (R4)"
assert_eq \
  '{"decision_effective": "exit", "bound_breached": true, "bound_type": "max_wall_seconds"}' \
  "$(run_iter bound-wall)"

# ─── Scenario 5: no decision yet ────────────────────────────────────────────
it "evaluate_decision: gate has no decision → read_decision=None, effective=None"
assert_eq \
  '{"read_decision": null, "decision_effective": null}' \
  "$(run_iter no-decision)"

# ─── Scenario 6: unknown gate unit ──────────────────────────────────────────
it "evaluate_decision: unknown gate_unit_id raises"
result="$(run_iter unknown-gate)"
case "$result" in
  raised:*) pass ;;
  *) fail "expected a raise, got '$result'" ;;
esac

# ─── Scenario 7: DECISIONS constant ─────────────────────────────────────────
it "DECISIONS constant exports the three allowed values"
assert_eq "advance,iterate,exit" "$(run_iter decisions-constant)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "iteration.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
