#!/usr/bin/env bash
# auto v0.2.0 fix-pass A.2 integration test: a1's plan→work transition fires the
# emitter (T1 from fix-pass C, hoisted to A.2 as the deliberate-fail control for
# the engine rewire).
#
# WHY THIS TEST EXISTS (memory feedback_plan_documents_transition_code_doesnt_wire_it):
# Round-1 review's P0 #1: the v0.1.x seam handler did raw set_loop(loop_phase="work")
# and never called the new transition_and_emit primitive — the recipe topology
# was built INTO the initial ledger but the runtime ignored it. A unit test on
# transition_and_emit in isolation passes; a unit test on emitters.resolve()
# passes; but neither proves that the engine ACTUALLY CALLS THEM on a real
# plan→work transition. This test does: it drives a1 from plan-done to a met
# work-loop state and asserts the emitter populated the work-phase units.
#
# STRUCTURE: prime the ledger to look like "plan unit is done, enumerated_units
# stashed, gaps_open=0" (the post-adapter-handoff state), call dispatch_tick once
# in auto mode, then read the ledger:
#   - loop_phase must have advanced past "plan" (to "work" via auto-flip)
#   - new units must appear with phase="work" (the emitter ran)
#   - the emitted unit ids must match the enumerated_units we stashed (the
#     emitter actually shaped them; this isn't just an artifact of init)
#
# DELIBERATE-FAIL CONTROL (memory feedback_new_tests_need_deliberate_fail_smoke_check):
# at the END of this file, we re-run the same scenario AFTER REPLACING
# transition_and_emit with a no-op (via monkey-patch on a fresh load). The test
# MUST observe zero new work units in that branch — proving this test FAILS
# when the wire is broken. Without that proof the green-path could be passing
# vacuously (e.g. if units were always emitted at init).

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

# Drive a1 to plan-done, then call dispatch_tick once and read back. Returns CSV:
#   loop_phase | work_unit_ids (comma-joined, sorted)
# emitter_off=1 monkey-patches transition_and_emit to a no-op (deliberate-fail
# control); legacy_no_recipe=1 strips the recipe field to exercise the v0.1.x
# fallback path.
drive_plan_to_work() {
  emitter_off="${1:-0}"
  legacy_no_recipe="${2:-0}"
  "$PY" - "$AUTO_ROOT" "$emitter_off" "$legacy_no_recipe" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
emitter_off = sys.argv[2] == "1"
legacy_no_recipe = sys.argv[3] == "1"
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

# Step 1: /auto plan.md (default recipe a1). This creates the ledger with one
# plan unit `plan` and phase_transitions=[{from:plan,to:work,emitter:plan_output_to_work_units}].
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

# Step 2: prime to plan-done. Stash enumerated_units on the plan unit, set
# gaps_open=0, plan_step=review_plan (the cached predicate sees plan-met).
enumerated = [
    {"id": "u-alpha", "invokes": {"adapter_op": "do_unit"}},
    {"id": "u-beta",  "invokes": {"adapter_op": "do_unit"}},
]
ledger.set_enumerated_units(repo, run_id, "plan", enumerated)
ledger.set_gaps_open(repo, run_id, 0)
# Force plan_step=review_plan so plan-met fires (the predicate requires it).
ledger.set_loop(repo, run_id, plan_step="review_plan")

# Step 2b (legacy branch): strip the recipe field on disk to simulate a v0.1.x
# ledger resumed under v0.2.0. The advance_to_phase helper MUST take the
# raw-set_loop fallback (no emitter, no new units), so the test asserts the
# legacy contract is honored.
if legacy_no_recipe:
    path = os.path.join(repo, ".claude", "auto", f"{run_id}.json")
    with open(path) as f:
        led_raw = json.load(f)
    led_raw["recipe"] = None
    led_raw["phase_transitions"] = []
    with open(path, "w") as f:
        json.dump(led_raw, f)

# Step 3 (deliberate-fail control): monkey-patch transition_and_emit to a no-op
# BEFORE the tick fires. If the engine routes through this primitive (it does
# in the green branch), the no-op will produce zero new units even though the
# recipe declares one.
if emitter_off:
    def _noop(*a, **kw): pass
    ledger.transition_and_emit = _noop
    tick.ledger.transition_and_emit = _noop  # tick imports ledger as a module

# Step 4: tick. auto=True so _maybe_seam takes the auto-flip branch.
with contextlib.redirect_stdout(io.StringIO()):
    tick.dispatch_tick(repo, run_id, auto=True)

led = json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))
work_units = sorted(u["id"] for u in led["units"] if u.get("phase") == "work")
print("%s|%s" % (led["loop_phase"], ",".join(work_units)))
PYEOF
}

it "fix-pass A.2: a1 plan-done → auto-flip fires the emitter (work units appear)"
res="$(drive_plan_to_work 0 0)"
# After auto-flip the tick reads predicate.met and sets loop_phase="done" (work
# loop is vacuously met if no work units — but the emitter ran FIRST and added
# u-alpha + u-beta, both pending, so all_units_terminal=false and met=false →
# stays at work). loop_phase MUST be "work" (or "done" if predicate flipped),
# units MUST contain u-alpha,u-beta.
case "$res" in
  "work|u-alpha,u-beta") pass ;;
  *) fail "expected 'work|u-alpha,u-beta', got '$res'" ;;
esac

it "fix-pass A.2 DELIBERATE-FAIL: with transition_and_emit no-op'd, no work units appear"
res_off="$(drive_plan_to_work 1 0)"
# With the primitive no-op'd, the green-path assertion above MUST NOT hold —
# the proof this test isn't passing vacuously. The legacy fallback also doesn't
# emit, but we're on the recipe path, so the helper would have RAISED if it
# couldn't find the emitter — only the no-op produces zero new units silently.
case "$res_off" in
  "work|u-alpha,u-beta") fail "deliberate-fail FAILED: emitter ran despite the no-op patch" ;;
  *) pass ;;
esac

it "fix-pass A.2 LEGACY: a v0.1.x ledger (no recipe) falls back to set_loop, no emission"
res_legacy="$(drive_plan_to_work 0 1)"
# Legacy ledger: no recipe → advance_to_phase uses raw set_loop, no work units
# emitted. The plan-loop's `plan` unit stays but no new units appear at work.
case "$res_legacy" in
  "work|") pass ;;
  *) fail "expected 'work|' (no work units; legacy fallback), got '$res_legacy'" ;;
esac

printf "%s: %d passed, %d failed\n" "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
