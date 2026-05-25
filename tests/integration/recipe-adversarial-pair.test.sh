#!/usr/bin/env bash
# auto v0.2.0 fix-pass C integration test (T3): drive recipe a4 end-to-end
# from plan-done → auto-flip → plan_output_to_paired_builders emission.
#
# WHY THIS TEST EXISTS (memory feedback_plan_documents_transition_code_doesnt_wire_it):
# Unit tests on plan_output_to_paired_builders (emitters.test.sh scenario 6)
# cover the emitter in isolation; a1's integration test covers the engine wire
# for the simple case. Neither proves the engine routes a4 — one plan unit
# producing TWO bias-differentiated builders plus a comparator gating on both —
# through the auto-flip path correctly (the comparator's depends_on links the
# emitted builder ids, so a routing bug that drops one builder makes the
# comparator unsatisfiable).
#
# STRUCTURE: init via auto.run with --recipe a4; the recipe declares one plan
# unit + phase_transitions=[{from:plan,to:work,emitter:plan_output_to_paired_builders}].
# Prime the plan unit's enumerated_units (2 items so the bias-applied builders
# carry real plan_items), set gaps_open=0 + plan_step=review_plan,
# dispatch_tick(auto=True). Auto-flip fires the emitter which produces:
#   build-clarity (depends_on=[]),
#   build-perf    (depends_on=[]),
#   compare       (depends_on=[build-clarity, build-perf]).
#
# Scenarios:
#   1. green: 2 enumerated items → 3 work units (build-clarity, build-perf,
#      compare) with correct depends_on and bias dispatch_context.
#   2. deliberate-fail: empty enumerated_units → emitter returns [] (per
#      emitters.py lines 113-116), no work units appear.

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

# Drive a4 from a primed plan-done state through one dispatch_tick. Args:
#   $1 = empty_plan:  "0" | "1" (1 → don't stash any enumerated_units, deliberate-fail)
#   $2 = emitter_off: "0" | "1" (1 → monkey-patch transition_and_emit to a no-op,
#                                deliberate-fail control parity with a1's test)
# Returns a pipe-delimited string:
#   loop_phase | emitted_work_unit_ids (sorted) | compare.depends_on (sorted) | builder_biases (sorted)
drive_a4() {
  empty_plan="${1:-0}"
  emitter_off="${2:-0}"
  "$PY" - "$AUTO_ROOT" "$empty_plan" "$emitter_off" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
empty_plan = sys.argv[2] == "1"
emitter_off = sys.argv[3] == "1"
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
tick = load("tick", os.path.join(auto_root, "lib", "tick.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")

# Step 1: init via /auto plan.md --recipe a4. Creates a ledger with one plan
# unit (`plan`) + phase_transitions=[{from:plan,to:work,emitter:plan_output_to_paired_builders}].
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--recipe", "a4"])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

# Step 2: prime the plan unit's enumerated_units (or leave it empty for the
# deliberate-fail scenario). The emitter passes these through as plan_items on
# each builder's dispatch_context (per emitters.py lines 119-126).
if not empty_plan:
    ledger.set_enumerated_units(repo, run_id, "plan",
        [{"id": "task-1", "invokes": {"adapter_op": "do_unit"}},
         {"id": "task-2", "invokes": {"adapter_op": "do_unit"}}])

# Set gaps_open=0 + plan_step=review_plan so plan-met fires.
ledger.set_gaps_open(repo, run_id, 0)
ledger.set_loop(repo, run_id, plan_step="review_plan")

# Step 2b (deliberate-fail control parity with a1): monkey-patch
# transition_and_emit to a no-op BEFORE the tick fires. If the engine routes
# through this primitive (it does in the green branch), the no-op produces
# zero new units even though the recipe declares an emitter for {to:work}.
if emitter_off:
    def _noop(*a, **kw): pass
    ledger.transition_and_emit = _noop
    tick.ledger.transition_and_emit = _noop  # tick imports ledger as a module

# Step 3: tick. auto=True so _maybe_seam takes the auto-flip branch.
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

led = json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))
work_units = [u for u in led["units"] if u.get("phase") == "work"]
work_ids = sorted(u["id"] for u in work_units)
compare = next((u for u in work_units if u["id"] == "compare"), None)
compare_deps = ",".join(sorted(compare["depends_on"])) if compare else ""
builder_biases = sorted(
    (u.get("dispatch_context") or {}).get("bias", "")
    for u in work_units if u["id"].startswith("build-")
)
print("%s|%s|%s|%s" % (
    led["loop_phase"], ",".join(work_ids),
    compare_deps, ",".join(builder_biases)))
PYEOF
}

# ─── Scenario 1: green — 3 work units with correct dependencies and bias ────
it "fix-pass C T3 GREEN: a4 plan-done → emitter produces build-clarity, build-perf, compare"
res="$(drive_a4 0 0)"
# Expected: loop_phase=work; work units {build-clarity, build-perf, compare}
# sorted alphabetically; compare.depends_on = [build-clarity, build-perf];
# builder biases = [clarity, perf]. All four fields are load-bearing:
#   - work_ids proves the emitter ran and produced the right shape
#   - compare's depends_on proves the comparator gates on both builders
#     (a routing bug that drops one builder makes this string mismatch)
#   - biases prove the dispatch_context carries the per-builder bias
case "$res" in
  "work|build-clarity,build-perf,compare|build-clarity,build-perf|clarity,perf") pass ;;
  *) fail "expected 'work|build-clarity,build-perf,compare|build-clarity,build-perf|clarity,perf', got '$res'" ;;
esac

# ─── Scenario 2: deliberate-fail — empty enumerated_units → no work units ───
it "fix-pass C T3 DELIBERATE-FAIL: empty enumerated_units → emitter returns [], no work units"
res_empty="$(drive_a4 1 0)"
# Empty enumerated_units returns [] from the emitter (emitters.py:113-116).
# transition_and_emit appends nothing then advances loop_phase to "work". So:
#   loop_phase=work, work_ids="" (empty — no builders, no comparator),
#   compare_deps="" (no comparator), biases="" (no builders).
# This is the DELIBERATE-FAIL CONTROL per memory
# feedback_new_tests_need_deliberate_fail_smoke_check: if the wire were broken
# the green scenario above would also produce no units, so we'd see false
# greens. The pair only makes sense together: green proves emission happens,
# empty proves it's gated on real plan output (not always-emit).
case "$res_empty" in
  "work|||") pass ;;
  *) fail "expected 'work|||' (empty enumeration → empty work set), got '$res_empty'" ;;
esac

# ─── Scenario 3: deliberate-fail (no-op patch) — engine routes through the
# primitive, so monkey-patching it produces no emission. This is the WIRE-ALIVE
# proof (parity with the a1 integration test): a green scenario alone could be
# vacuous if the primitive were never called; this asserts that disabling the
# primitive flips the outcome.
it "fix-pass C T3 DELIBERATE-FAIL (no-op): transition_and_emit no-op'd → no work units appear"
res_off="$(drive_a4 0 1)"
case "$res_off" in
  "work|build-clarity,build-perf,compare|build-clarity,build-perf|clarity,perf")
    fail "deliberate-fail FAILED: emitter ran despite the no-op patch" ;;
  *) pass ;;
esac

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "$(basename "$0"): ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
