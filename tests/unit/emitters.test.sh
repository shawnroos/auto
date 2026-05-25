#!/usr/bin/env bash
# auto U5b unit test: lib/emitters.py (3 emitters + registry) and the
# ledger.transition_and_emit primitive (atomic emit).
#
# SELF-CONTAINED inline harness.
#
# Scenarios:
#   1. registry ↔ validator consistency: emitters.REGISTRY keys == recipes.V1_EMITTER_NAMES
#   2. plan_output_to_work_units: 1 plan unit's enumerated_units → N work units
#   3. plan_output_to_work_units: empty enumerated_units → [] (vacuous, no crash)
#   4. judge_winner_to_work_units: emits the WINNER's enumerated_units
#   5. judge_winner_to_work_units: no winner in findings → raises (hard error)
#   6. plan_output_to_paired_builders: 2 biased builders + comparator depends_on both
#   7. transition_and_emit: atomic — appends units AND advances phase in one write;
#      predicate recomputed against POST-emission set (the G3/F2 property)
#   8. emitters are pure: a registry emitter never calls a ledger mutator (smoke:
#      transition_and_emit with a real emitter completes without deadlock)

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

em() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module, load_ledger
emitters = load_lib_module("emitters")
recipes = load_lib_module("recipes")
ledger = load_ledger()
op = sys.argv[2]

if op == "registry-consistency":
    print("match" if set(emitters.REGISTRY) == set(recipes.V1_EMITTER_NAMES) else "MISMATCH")

elif op == "a1-emit":
    led = {"units": [{"id": "plan", "phase": "plan",
            "dispatch_context": {"enumerated_units": [
                {"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]}}]}
    out = emitters.plan_output_to_work_units(led, "work")
    print(",".join(u["id"] + ":" + u["phase"] for u in out))

elif op == "a1-empty":
    led = {"units": [{"id": "plan", "phase": "plan", "dispatch_context": {}}]}
    print(len(emitters.plan_output_to_work_units(led, "work")))

elif op == "judge-winner":
    led = {"units": [
        {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": [{"id": "wA", "invokes": {}}]}},
        {"id": "plan-2", "phase": "plan", "dispatch_context": {"enumerated_units": [{"id": "wB", "invokes": {}}]}},
        {"id": "judge", "phase": "work", "findings": [{"winner_unit_id": "plan-2"}]},
    ]}
    out = emitters.judge_winner_to_work_units(led, "work")
    print(",".join(u["id"] for u in out))

elif op == "judge-no-winner":
    led = {"units": [
        {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": []}},
        {"id": "judge", "phase": "work", "findings": [{"note": "undecided"}]},
    ]}
    try:
        emitters.judge_winner_to_work_units(led, "work"); print("NO-RAISE")
    except ValueError:
        print("raised")

elif op == "a4-pair":
    led = {"units": [{"id": "plan", "phase": "plan",
            "dispatch_context": {"enumerated_units": [{"id": "task", "invokes": {}}]}}]}
    out = emitters.plan_output_to_paired_builders(led, "work")
    ids = [u["id"] for u in out]
    comp = next(u for u in out if u["id"] == "compare")
    biases = sorted((u["dispatch_context"].get("bias") for u in out if u["id"].startswith("build-")))
    print("%s|%s|%s" % (",".join(ids), ",".join(biases), ",".join(comp["depends_on"])))

elif op == "atomic-emit":
    # transition_and_emit appends units AND advances phase in ONE write; the
    # post-write predicate is computed against the post-emission unit set.
    repo = tempfile.mkdtemp(); run = "ae"
    ledger.init_ledger(repo, run, adapter="ce",
        recipe={"name": "a1", "source_tier": "built-in"},
        phase_order=["plan", "seam", "work"], terminal_phase="work",
        loop_phase="seam",
        units=[{"id": "plan", "phase": "plan", "state": "verdict-returned",
                "dispatch_context": {"enumerated_units": [
                    {"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]}}])
    appended = ledger.transition_and_emit(repo, run, "work",
        emitters.plan_output_to_work_units)
    led = ledger.read_ledger(repo, run)
    work_units = [u["id"] for u in led["units"] if u["phase"] == "work"]
    # phase advanced to work; 2 work units appended; predicate saw them (not met —
    # they're pending, so all_units_terminal is False).
    print("%s|%s|%s|%s" % (
        led["loop_phase"], ",".join(sorted(appended)),
        ",".join(sorted(work_units)), led["exit_predicate_result"]["met"]))
PYEOF
}

# ─── Scenario 1: registry ↔ validator consistency ───────────────────────────
it "emitters.REGISTRY keys == recipes.V1_EMITTER_NAMES (no drift)"
assert_eq "match" "$(em registry-consistency)"

# ─── Scenario 2-3: plan_output_to_work_units ────────────────────────────────
it "plan_output_to_work_units: enumerated → work units (phase set)"
assert_eq "w1:work,w2:work" "$(em a1-emit)"

it "plan_output_to_work_units: empty enumerated → [] (vacuous, no crash)"
assert_eq "0" "$(em a1-empty)"

# ─── Scenario 4-5: judge_winner_to_work_units ───────────────────────────────
it "judge_winner_to_work_units: emits the WINNER's units"
assert_eq "wB" "$(em judge-winner)"

it "judge_winner_to_work_units: no winner → raises (hard error)"
assert_eq "raised" "$(em judge-no-winner)"

# ─── Scenario 6: plan_output_to_paired_builders ─────────────────────────────
it "plan_output_to_paired_builders: 2 biased builders + comparator depends_on both"
assert_eq "build-clarity,build-perf,compare|clarity,perf|build-clarity,build-perf" "$(em a4-pair)"

# ─── Scenario 7: transition_and_emit atomic (G3/F2) ─────────────────────────
it "transition_and_emit: appends units + advances phase + predicate sees post-emission set"
assert_eq "work|w1,w2|w1,w2|False" "$(em atomic-emit)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "emitters.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
