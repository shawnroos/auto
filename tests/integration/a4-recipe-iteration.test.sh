#!/usr/bin/env bash
# auto v0.3.0 U6 integration test: a4 recipe with iteration block + structural
# compare — three scenarios (GREEN/ITERATE/BOUND) driving the full recipe→
# ledger→tick path.
#
# WHY THIS TEST EXISTS (memory feedback_plan_documents_transition_code_doesnt_wire_it):
# After U6, a4's `compare` unit is declared structurally in units[] (with
# depends_on: [build-clarity, build-perf] forward-referencing the bias-builder
# emit_template id_prefix). The plan_output_to_paired_builders emitter no
# longer synthesizes compare — it only emits the two builders. This test
# proves the structural+emitter split survives the production init→tick path:
# the recipe→ledger→tick wire materializes builders AND honors compare as
# the iteration gate.
#
# CONTRACT (KTD §A+§C+§D — v0.3.0 U6):
#   a4 declares iteration.gate_unit="compare", iteration.emit_template=
#   "bias-builder", iteration.bound={max_attempts:4, max_wall_seconds:1200}.
#   plus emit_templates.bias-builder={phase:"work", invokes:{adapter_op:"do_unit"},
#   id_prefix:"build-"}. compare is structural with depends_on the bias-builder
#   prefix references. auto.run + init_ledger thread iteration+emit_templates
#   onto the ledger (U6 plumbing).
#
#   Drive: plan-done → auto-flip via plan_output_to_paired_builders emits
#   build-clarity + build-perf (NOT compare — structural already on ledger).
#   Then compare verdicts per scenario.
#
# STRUCTURE: init via auto.run with --recipe a4; prime the plan unit's
# enumerated_units (2 items so builders carry plan_items); tick auto=True →
# auto-flips to work emitting builders; mark builders fixed; record_verdict +
# set_verdict_decision on compare per scenario; tick again.
#
# Scenarios:
#   1. GREEN — compare decision=advance → no iteration fires; standard work
#      flow. iteration_attempts stays 0. compare ends in verdict-returned.
#   2. ITERATE — compare decision=iterate(emit_count=1) → iterate_template
#      emits build-3 (counter base 2 from builders + 1). iteration_attempts=1,
#      compare resets to pending with extended depends_on.
#   3. BOUND — iteration_attempts pre-seeded to max_attempts=4; compare writes
#      iterate → bound_override fires; loop forced to "done" via set_loop.

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

# Drive a4 end-to-end. Args:
#   $1 = scenario: "green" | "iterate" | "bound"
# Returns CSV: loop_phase|iteration_attempts|new_builders|compare_state|bound_override_present
drive_a4() {
  scenario="${1:-green}"
  "$PY" - "$AUTO_ROOT" "$scenario" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
scenario = sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))

from _bootstrap import load_lib_module
a = load_lib_module("auto")
ledger = load_lib_module("ledger")
tick = load_lib_module("tick")

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")

# Step 1: init via /auto plan.md --recipe a4 — PRODUCTION path. U6 plumbing
# carries recipe.iteration + recipe.emit_templates onto the ledger.
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--recipe", "a4"])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

# Sanity: U6 plumbing alive — iteration block on ledger, compare structural.
led0 = ledger.read_ledger(repo, run_id)
assert led0.get("iteration"), f"iteration block missing on ledger after init: {sorted(led0.keys())!r}"
assert led0["iteration"]["gate_unit"] == "compare", led0["iteration"]
assert led0.get("emit_templates", {}).get("bias-builder"), led0.get("emit_templates")
# Compare structural: in units[] from init (NOT emitter-synthesized).
unit_ids_at_init = sorted(u["id"] for u in led0["units"])
assert "compare" in unit_ids_at_init, f"compare not in initial units[]: {unit_ids_at_init!r}"

# Step 2: prime the plan unit's enumerated_units (the emitter passes these to
# each builder's dispatch_context as plan_items). Set gaps_open=0 + plan_step=
# review_plan so plan-met fires.
ledger.set_enumerated_units(repo, run_id, "plan",
    [{"id": "task-1", "invokes": {"adapter_op": "do_unit"}},
     {"id": "task-2", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_gaps_open(repo, run_id, 0)
ledger.set_loop(repo, run_id, plan_step="review_plan")

# Step 3: tick auto=True → _maybe_seam auto-flips → plan_output_to_paired_builders
# emits build-clarity + build-perf (NOT compare — structural). loop_phase=work.
# iteration_emit_count increments to 2 (one per emitted builder).
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

# Sanity: builders emitted, compare still structural. NOTE: iteration_emit_count
# stays 0 here — transition_and_emit (the phase-transition primitive) does NOT
# bump the counter; only _apply_emit (used by iterate_template) does. This means
# the first iterate-emit produces `build-<counter+1>` = "build-1" (no collision
# with build-clarity / build-perf because the suffix is numeric vs word).
led1 = ledger.read_ledger(repo, run_id)
builders_now = sorted(u["id"] for u in led1["units"] if u["id"].startswith("build-"))
assert builders_now == ["build-clarity", "build-perf"], builders_now
assert led1["iteration_emit_count"] == 0, f"counter={led1['iteration_emit_count']!r}"

# Step 4: mark both builders fixed (no findings) so compare's dependencies are
# satisfied; pre-seed iteration_attempts for BOUND scenario.
ledger.transition(repo, run_id, "build-clarity", "dispatched")
ledger.transition(repo, run_id, "build-clarity", "verdict-returned")
ledger.record_verdict(repo, run_id, "build-clarity", [])
ledger.transition(repo, run_id, "build-perf", "dispatched")
ledger.transition(repo, run_id, "build-perf", "verdict-returned")
ledger.record_verdict(repo, run_id, "build-perf", [])

def seed(L):
    if scenario == "bound":
        L["iteration_attempts"] = 4
ledger._with_locked_ledger(repo, run_id, seed)

# Step 5: dispatch compare + write its verdict per scenario.
ledger.transition(repo, run_id, "compare", "dispatched")
ledger.record_verdict(repo, run_id, "compare",
    [{"severity": "minor", "note": f"scenario={scenario}"}])
if scenario == "green":
    # advance: iteration block does NOT fire; standard work-flow.
    ledger.set_verdict_decision(repo, run_id, "compare", "advance")
elif scenario == "iterate":
    # iterate under bound: iterate_template emits build-3 (counter 2 + 1 = 3).
    ledger.set_verdict_decision(repo, run_id, "compare", "iterate",
        payload={"emit_count": 1})
elif scenario == "bound":
    # iterate over bound (attempts == max=4): bound_override fires.
    ledger.set_verdict_decision(repo, run_id, "compare", "iterate",
        payload={"emit_count": 1})

# Step 6: tick. advance_iteration_loop fires at the top of _tick_body_inner.
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

led = ledger.read_ledger(repo, run_id)
compare = next(u for u in led["units"] if u["id"] == "compare")
new_builders = sorted(u["id"] for u in led["units"]
                      if u["id"].startswith("build-")
                      and u["id"] not in ("build-clarity", "build-perf"))
bound_override_present = "bound_override" in (compare.get("dispatch_context") or {})
print("%s|%d|%s|%s|%s" % (
    led["loop_phase"],
    int(led.get("iteration_attempts", 0)),
    ",".join(new_builders),
    compare.get("state"),
    "yes" if bound_override_present else "no",
))
PYEOF
}

# ─── Scenario 1: GREEN — compare advance → no iteration; standard flow ──────
it "U6 a4 GREEN: compare decision=advance → iteration block doesn't fire, iteration_attempts=0"
res="$(drive_a4 green)"
# Expected: iteration logic does NOT fire (advance_iteration_loop returns
# {"action":"advance"}). Compare is in verdict-returned. iteration_attempts=0.
# loop_phase: depends on predicate composition. With compare verdict-returned
# and no other pending work units, the work predicate met=True → done.
case "$res" in
  "done|0||verdict-returned|no") pass ;;
  *) fail "expected 'done|0||verdict-returned|no', got '$res'" ;;
esac

# ─── Scenario 2: ITERATE — compare iterate under bound → emit build-1 ───────
it "U6 a4 ITERATE: compare decision=iterate(emit_count=1) → build-1 emitted, attempts=1, compare pending"
res="$(drive_a4 iterate)"
# Expected: iterate_template emits build-1 (id_prefix "build-" + counter 0+1=1
# — see Sanity-check above: transition_and_emit does NOT bump the counter for
# build-clarity/build-perf, so the first iterate-emit's id has suffix 1).
# iteration_attempts=1. compare resets to pending with depends_on extended to
# include build-1. loop_phase stays "work" — iteration adds siblings within
# the current phase. No bound_override (under bound).
case "$res" in
  "work|1|build-1|pending|no") pass ;;
  *) fail "expected 'work|1|build-1|pending|no', got '$res'" ;;
esac

# ─── Scenario 3: BOUND — attempts==max → bound_override + done ─────────────
it "U6 a4 BOUND: iteration_attempts=4==max, compare writes iterate → bound_override, loop=done"
res="$(drive_a4 bound)"
# Expected: evaluate_decision returns decision_effective="exit"/bound_breached.
# advance_iteration_loop writes bound_override on compare.dispatch_context +
# forces loop_phase to "done" via set_loop DIRECTLY (NOT advance_to_phase, per
# KTD §C). iteration_attempts STAYS at 4. No new builders. bound_override present.
case "$res" in
  "done|4||verdict-returned|yes") pass ;;
  *) fail "expected 'done|4||verdict-returned|yes', got '$res'" ;;
esac

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "$(basename "$0"): ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
