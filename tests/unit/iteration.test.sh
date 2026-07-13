#!/usr/bin/env bash
# auto v0.3.0 U1 unit test: the ONE iteration-decision module.
#
# Mirrors tests/unit/phase-grammar.test.sh — every site that reads a gate
# step's verdict.decision routes through this module. AST lint (sibling
# file tests/unit/iteration-ast-lint.test.sh) mechanically enforces that
# no other lib/*.py raw-subscripts dispatch_context["decision"] — same
# discipline as phase-grammar's "loop_phase" literal lint.
#
# Behavior contract from plan U1:
#   evaluate_decision(led, gate_step_id, now_monotonic=None) -> dict with
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
#   6. unknown gate step id — raises clear error

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
    """A minimal ledger shape with one gate step named 'judge' carrying the
    given decision payload, plus the iteration block + bound."""
    judge = {"id": "judge", "phase": "work", "state": "verdict-returned",
             "dispatch_context": {}}
    if decision is not None:
        judge["dispatch_context"]["decision"] = decision
    bound = {"max_attempts": max_attempts}
    if max_wall_seconds is not None:
        bound["max_wall_seconds"] = max_wall_seconds
    return {
        "steps": [judge],
        "iteration": {"gate_step": "judge", "bound": bound},
        "iteration_attempts": attempts,
        "active_wall_seconds": active_wall_seconds,
    }

def make_verif_led(crits, dispatch_context=None):
    """A minimal ledger with one gate step 'g' carrying a verification block."""
    return {"steps": [{"id": "g", "phase": "work", "state": "verdict-returned",
                       "dispatch_context": dispatch_context or {},
                       "verification": crits}]}

_TRUE = {"argv": ["true"], "check": "exit_zero"}
_FALSE = {"argv": ["false"], "check": "exit_zero"}

if op == "advance":
    led = make_led("advance", attempts=1)
    r = iteration.evaluate_decision(led, "judge")
    print(json.dumps({k: r.get(k) for k in (
        "decision_effective","original_decision","bound_breached","bound_type")}))

elif op == "verif-advance":
    led = make_verif_led([dict(_TRUE, id="a", type="programmatic"),
                          dict(_TRUE, id="b", type="programmatic")])
    print(iteration.resolve_gate_verification(led, "g")["signal"])

elif op == "verif-iterate":
    led = make_verif_led([dict(_TRUE, id="a", type="programmatic"),
                          dict(_FALSE, id="b", type="programmatic")])
    print(iteration.resolve_gate_verification(led, "g")["signal"])

elif op == "verif-pending":
    led = make_verif_led([dict(_TRUE, id="a", type="programmatic"),
                          {"id": "j", "type": "advisor_judge"}])
    r = iteration.resolve_gate_verification(led, "g")
    print(f'{r["signal"]}|{",".join(r["pending_judges"])}')

elif op == "verif-injected":
    led = make_verif_led([dict(_TRUE, id="a", type="programmatic"),
                          {"id": "j", "type": "advisor_judge"}])
    print(iteration.resolve_gate_verification(led, "g", judge_verdicts={"j": "pass"})["signal"])

elif op == "verif-persisted":
    # judge verdict already persisted on dispatch_context (the U5 driver path)
    led = make_verif_led([dict(_TRUE, id="a", type="programmatic"),
                          {"id": "j", "type": "advisor_judge"}],
                         dispatch_context={"judge_verdicts": {"j": "fail"}})
    print(iteration.resolve_gate_verification(led, "g")["signal"])

elif op == "verif-legacy":
    led = make_verif_led([])  # no criteria → legacy gate, untouched
    r = iteration.resolve_gate_verification(led, "g")
    print(f'{r["signal"]}|{len(r["pending_judges"])}')

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
    rd = iteration.read_decision(led["steps"][0])
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
    print(iteration.compute_pending_state({"steps": []}))

elif op == "pending-no-gate-step-named":
    led = {"steps": [], "iteration": {"bound": {}}}
    print(iteration.compute_pending_state(led))

elif op == "pending-gate-not-found":
    led = {"steps": [], "iteration": {"gate_step": "ghost", "bound": {}}}
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

# ─── G1 / rel-r2-1: kill-switch read-side parity ───────────────────────────
# When the operator sets CLAUDE_AUTO_DISABLE_ITERATION=1, compute_pending_state
# must short-circuit to False — symmetric with pulse.advance_iteration_loop's
# write-side fence (lib/pulse.py:624). Without parity, a kill-switched mid-iter
# run still computes iteration_pending=True from the gate's stale "iterate"
# verdict and blocks the predicate's `met` branch via the AND-NOT clause.
#
# This test constructs a ledger that WOULD return True (iterate under bound)
# and asserts the kill-switch flips it to False. The deliberate-fail control
# (Edit-revert of iteration.py) proves the test isn't vacuous: without the
# top-of-function `if is_iteration_disabled(): return False` it returns True
# even with the env var set.

elif op == "pending-kill-switch-on":
    # Same shape as `pending-iterate-under` (which returns True) — caller sets
    # CLAUDE_AUTO_DISABLE_ITERATION=1 in the environment before invoking.
    led = make_led("iterate", attempts=2, max_attempts=5)
    print(iteration.compute_pending_state(led))

# ─── G2 / ADV-R2-1: shape-corruption shield ────────────────────────────────
# compute_pending_state is called from the _atomic_write chokepoint. If the
# ``iteration`` key is corrupted to a non-dict scalar (e.g. partial write,
# torn recovery), the subsequent ``.get(...)`` calls would raise AttributeError
# and that raise would propagate through _atomic_write → recompute_predicate,
# BLOCKING the very ledger writes F2 needs to mark the loop done.
#
# The fix at iteration.py adds an isinstance check that fences the function to
# return False on non-dict iteration shapes (None stays the legitimate "no
# iteration declared" signal — already covered by pending-no-iteration-block).
#
# Sentinel uses ``raised:<exc_type>`` / ``returned:<value>`` so the bash
# discriminator can distinguish the raise (DF state) from the False return.

elif op == "pending-iteration-non-dict-string":
    led = {"steps": [], "iteration": "broken-string"}
    try:
        v = iteration.compute_pending_state(led)
        print(f"returned:{v}")
    except Exception as e:
        print(f"raised:{type(e).__name__}")

elif op == "pending-iteration-non-dict-list":
    led = {"steps": [], "iteration": ["broken", "list"]}
    try:
        v = iteration.compute_pending_state(led)
        print(f"returned:{v}")
    except Exception as e:
        print(f"raised:{type(e).__name__}")

elif op == "pending-bound-non-dict":
    # v0.3.0 H / corr-r3-1: shape guard on iteration.bound, symmetric to
    # G2's top-level iteration guard. A torn-write scalar (string here) on
    # the bound key would survive `iteration.get('bound') or {}` (truthy
    # non-dict), then `bound.get('max_attempts')` would raise AttributeError
    # — which propagates through _atomic_write → recompute_predicate and
    # blocks the very ledger writes F2 needs to mark the loop done. The
    # isinstance guard degrades to False, keeping the ledger writable.
    led = {
        "steps": [{"id": "judge", "phase": "work",
                   "dispatch_context": {"decision": "iterate"}}],
        "iteration": {"gate_step": "judge", "bound": "corrupted-string"},
    }
    try:
        v = iteration.compute_pending_state(led)
        print(f"returned:{v}")
    except Exception as e:
        print(f"raised:{type(e).__name__}")

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

# ─── Scenario 6: unknown gate step ──────────────────────────────────────────
it "evaluate_decision: unknown gate_step_id raises"
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

it "compute_pending_state: no gate_step named in iteration block → False"
assert_eq "False" "$(run_iter pending-no-gate-step-named)"

it "compute_pending_state: gate step id not present in steps[] → False"
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

# ─── G1 / rel-r2-1: kill-switch read-side parity ──────────────────────────
# Operator sets CLAUDE_AUTO_DISABLE_ITERATION=1; compute_pending_state must
# return False even on a ledger that would otherwise be iterate-under-bound.
# This mirrors the write-side check at lib/pulse.py:624. The same ledger
# shape WITHOUT the env var returns True (covered by pending-iterate-under
# above) — the only difference is the kill-switch, isolating the behavior
# the test is asserting.

it "compute_pending_state: kill-switch (CLAUDE_AUTO_DISABLE_ITERATION=1) → False even on iterate-under-bound"
assert_eq "False" "$(CLAUDE_AUTO_DISABLE_ITERATION=1 run_iter pending-kill-switch-on)"

# Sanity: kill-switch UNSET on the SAME ledger shape returns True. Without
# this paired check, a regression that flips both sides (e.g. accidentally
# returns False unconditionally) would still see this section "pass."
it "compute_pending_state: same ledger WITHOUT kill-switch → True (sanity for the pair above)"
assert_eq "True" "$(run_iter pending-kill-switch-on)"

# ─── G2 / ADV-R2-1: shape-corruption shield ────────────────────────────────
# If ``iteration`` is a non-dict scalar (string, list — torn-write shapes),
# compute_pending_state MUST return False, NOT raise. A raise here would
# propagate through _atomic_write → recompute_predicate and block the very
# ledger writes F2 (lib/pulse.py) needs to force-mark the loop done.
#
# The DF cycle: comment out the isinstance check in iteration.py → these tests
# go RED with "raised:AttributeError" (the iteration_block.get('gate_step')
# line crashes on a str/list). With the fix, both return "returned:False".

it "compute_pending_state: iteration='broken-string' (non-dict scalar) → returns False (no raise)"
assert_eq "returned:False" "$(run_iter pending-iteration-non-dict-string)"

it "compute_pending_state: iteration=['broken','list'] (non-dict list) → returns False (no raise)"
assert_eq "returned:False" "$(run_iter pending-iteration-non-dict-list)"

# ─── v0.3.0 H / corr-r3-1: bound shape guard symmetry ──────────────────────
# G2 added isinstance(iter_block, dict) at the top of compute_pending_state
# but did NOT add the parallel guard for iteration.bound. A torn ledger
# writing iteration.bound="corrupted" survives `iteration.get('bound') or {}`
# (truthy non-dict string), then bound.get('max_attempts') raises
# AttributeError — propagating through _atomic_write → recompute_predicate
# and blocking the recovery writes. H closes the read-side asymmetry.
# DF cycle: comment out the new isinstance(bound, dict) line in
# iteration.py → this test goes RED with "raised:AttributeError".
it "compute_pending_state: iteration.bound='corrupted-string' (non-dict) → returns False (no raise)"
assert_eq "returned:False" "$(run_iter pending-bound-non-dict)"

# ── U4: resolve_gate_verification (typed-verification → advance/iterate signal) ─
it "U4 resolve_gate_verification: all programmatic pass → signal 'advance'"
assert_eq "advance" "$(run_iter verif-advance)"

it "U4: one programmatic fail → signal 'iterate'"
assert_eq "iterate" "$(run_iter verif-iterate)"

it "U4: advisor_judge with no verdict → signal None, pending 'j'"
assert_eq "None|j" "$(run_iter verif-pending)"

it "U4: injected advisor verdict (pass) + programmatic pass → 'advance'"
assert_eq "advance" "$(run_iter verif-injected)"

it "U4: judge verdict persisted on dispatch_context (fail) → 'iterate'"
assert_eq "iterate" "$(run_iter verif-persisted)"

it "U4: gate without verification block → signal None, no pending (legacy untouched)"
assert_eq "None|0" "$(run_iter verif-legacy)"

# ── U12: typed dispatch_context accessors (read_dc + named) ───────────────────
# A MISSPELLED key must fail LOUD (KeyError) at the accessor, not swallow into a
# silent None the way `(dc or {}).get("<typo>")` would; a declared-but-ABSENT key
# returns None (real-miss semantics); a named accessor reads the declared key.
it "U12: read_dc typed-miss on misspelled key raises; absent key -> None; named accessor reads"
dcres="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, json
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
iteration = load_lib_module("iteration")

step = {"dispatch_context": {"enumerated_steps": [{"id": "w1"}]}}

# 1. misspelled key -> KeyError (loud), NOT a silent None.
try:
    iteration.read_dc(step, "enumarated_steps")  # typo
    typo = "no-raise"
except KeyError:
    typo = "raised"

# 2. declared-but-absent key -> None (real-miss semantics preserved).
absent = iteration.read_dc(step, "winner_step_id")

# 3. named accessor reads the declared key.
named = iteration.read_enumerated_steps(step)

# 4. read_decision still delegates through read_dc (behavior identical).
dec = iteration.read_decision({"dispatch_context": {"decision": "iterate"}})

print(json.dumps({
    "typo": typo,
    "absent_is_none": absent is None,
    "named": named,
    "decision": dec,
}))
PYEOF
)"
dc_typo="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['typo'])" "$dcres")"
dc_absent="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['absent_is_none'])" "$dcres")"
dc_named="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['named'])" "$dcres")"
dc_dec="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['decision'])" "$dcres")"
if [ "$dc_typo" = "raised" ] && [ "$dc_absent" = "True" ] \
   && [ "$dc_named" = "[{'id': 'w1'}]" ] && [ "$dc_dec" = "iterate" ]; then
  pass
else
  fail "typo=$dc_typo absent=$dc_absent named=$dc_named decision=$dc_dec (expected raised / True / [{'id': 'w1'}] / iterate)"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "iteration.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
