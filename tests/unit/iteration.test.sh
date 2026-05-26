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

# ─── compute_pending_state ops (F3 / kieran-7) ──────────────────────────────
# compute_pending_state is the centralized bound-check that
# recompute_predicate calls (replacing the prior duplicate copy in ledger.py).
# These ops exercise the same scenarios as evaluate_decision but on the
# pending-bool surface compute_pending_state exposes.

elif op == "pending-no-iteration-block":
    print(iteration.compute_pending_state({"units": []}))

elif op == "pending-no-gate-unit-named":
    led = {"units": [], "iteration": {"bound": {}}}
    print(iteration.compute_pending_state(led))

elif op == "pending-gate-not-found":
    led = {"units": [], "iteration": {"gate_unit": "ghost", "bound": {}}}
    print(iteration.compute_pending_state(led))

elif op == "pending-decision-not-iterate":
    led = make_led("advance", attempts=0)
    print(iteration.compute_pending_state(led))

elif op == "pending-iterate-under":
    led = make_led("iterate", attempts=2, max_attempts=5)
    print(iteration.compute_pending_state(led))

elif op == "pending-attempts-breached":
    led = make_led("iterate", attempts=5, max_attempts=5)
    print(iteration.compute_pending_state(led))

elif op == "pending-wall-breached":
    led = make_led("iterate", attempts=1, max_attempts=5,
                   active_wall_seconds=1900, max_wall_seconds=1800)
    print(iteration.compute_pending_state(led))

# ─── rel-2: brittleness — coercion failure on a bound counter ───────────────
# A corrupted numeric ledger field MUST NOT raise from compute_pending_state
# — it is called from the _atomic_write chokepoint, so a raise here locks
# out every subsequent ledger mutation including writes needed to recover.

elif op == "pending-corrupt-iteration-attempts":
    led = make_led("iterate", attempts=2, max_attempts=5)
    led["iteration_attempts"] = "garbage"
    # Must not raise; falls back to "iteration not pending" (safe default).
    print(iteration.compute_pending_state(led))

elif op == "pending-corrupt-max-attempts":
    led = make_led("iterate", attempts=2, max_attempts=5)
    led["iteration"]["bound"]["max_attempts"] = "garbage"
    print(iteration.compute_pending_state(led))

elif op == "pending-corrupt-active-wall":
    led = make_led("iterate", attempts=1, max_attempts=5,
                   active_wall_seconds=10, max_wall_seconds=1800)
    led["active_wall_seconds"] = "not-a-number"
    print(iteration.compute_pending_state(led))

elif op == "pending-corrupt-max-wall":
    led = make_led("iterate", attempts=1, max_attempts=5,
                   active_wall_seconds=10, max_wall_seconds=1800)
    led["iteration"]["bound"]["max_wall_seconds"] = "not-a-number"
    print(iteration.compute_pending_state(led))

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

# ─── F3 / kieran-7: compute_pending_state — central iteration_pending compute ─
it "compute_pending_state: no iteration block → False"
assert_eq "False" "$(run_iter pending-no-iteration-block)"

it "compute_pending_state: no gate_unit named in iteration block → False"
assert_eq "False" "$(run_iter pending-no-gate-unit-named)"

it "compute_pending_state: gate unit id not present in units[] → False"
assert_eq "False" "$(run_iter pending-gate-not-found)"

it "compute_pending_state: gate decision != 'iterate' → False"
assert_eq "False" "$(run_iter pending-decision-not-iterate)"

it "compute_pending_state: iterate under bound → True"
assert_eq "True" "$(run_iter pending-iterate-under)"

it "compute_pending_state: attempts == max_attempts → False (engine forces exit)"
assert_eq "False" "$(run_iter pending-attempts-breached)"

it "compute_pending_state: active_wall_seconds > max_wall_seconds → False"
assert_eq "False" "$(run_iter pending-wall-breached)"

# ─── F3 / rel-2: graceful degradation on corrupt numeric fields ─────────────
# A single corrupt numeric field MUST NOT raise from compute_pending_state;
# every call site (notably _atomic_write -> recompute_predicate) requires the
# function to return a bool no matter what shape the ledger has.

it "compute_pending_state: corrupt iteration_attempts → False (no raise)"
assert_eq "False" "$(run_iter pending-corrupt-iteration-attempts)"

it "compute_pending_state: corrupt max_attempts → False (no raise)"
assert_eq "False" "$(run_iter pending-corrupt-max-attempts)"

it "compute_pending_state: corrupt active_wall_seconds → False (no raise)"
assert_eq "False" "$(run_iter pending-corrupt-active-wall)"

it "compute_pending_state: corrupt max_wall_seconds → False (no raise)"
assert_eq "False" "$(run_iter pending-corrupt-max-wall)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "iteration.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
