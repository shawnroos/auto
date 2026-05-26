#!/usr/bin/env bash
# auto v0.3.0 U6 integration test: a2 recipe with iteration block — three
# scenarios (GREEN/ITERATE/BOUND) driving the full recipe→ledger→tick path.
#
# WHY THIS TEST EXISTS (memory feedback_plan_documents_transition_code_doesnt_wire_it):
# Unit tests on iterate_template (emitters.test.sh) and advance_iteration_loop
# (tick.test.sh) cover the iteration primitives in isolation; this file proves
# that a recipe DECLARING iteration in JSON actually drives the production
# init→tick path. Without it, the recipe→ledger→tick wire could silently
# regress to recipe-iteration-ignored (the dominant build-bug class — prose
# claims a transition the code doesn't enforce).
#
# CONTRACT (KTD §A+§B+§D — v0.3.0 U6):
#   The a2 recipe declares iteration.gate_unit="judge", iteration.emit_template
#   ="plan-candidate", iteration.bound={max_attempts:5, max_wall_seconds:900}.
#   plus emit_templates.plan-candidate={phase:"plan", invokes:{adapter_op:
#   "next_plan_step"}, id_prefix:"plan-"}. auto.run + init_ledger thread these
#   onto the ledger at init (U6 plumbing). Subsequent ticks drive:
#     - judge decision=advance → standard flow (matches v0.2.x A2 GREEN).
#     - judge decision=iterate (under bound) → atomic_iterate_step emits a new
#       plan unit (plan-4), increments iteration_attempts, resets judge to
#       pending with extended depends_on, loop stays in plan phase.
#     - judge decision=iterate (over bound) → bound_override written to
#       judge.dispatch_context, loop forced to "done" via set_loop (NOT
#       advance_to_phase, per KTD §C).
#
# STRUCTURE: init via auto.run with --recipe a2 (carries iteration to ledger);
# prime each plan unit's enumerated_units; set gaps_open=0; record_verdict +
# set_verdict_decision on judge per scenario; dispatch_tick. Assert end-state
# (loop_phase, iteration_attempts, ids of newly-emitted plan units, bound_override
# presence).
#
# Scenarios:
#   1. GREEN — judge decision=advance → no iteration fires; existing v0.2.x
#      A2 behavior reproduced. iteration_attempts stays 0. loop progresses to
#      done via standard predicate-met short-circuit.
#   2. ITERATE — judge decision=iterate (attempts < max). atomic_iterate_step
#      emits plan-4 (id_prefix "plan-" + counter 3+1=4 since 3 initial planks).
#      iteration_attempts=1. judge.state=pending. loop_phase stays plan.
#      Then advance: re-arms standard flow.
#   3. BOUND — iteration_attempts pre-seeded to max_attempts=5; judge writes
#      iterate; evaluate_decision returns "exit"/bound_breached=True.
#      advance_iteration_loop writes bound_override + set_loop(done). loop_phase
#      is "done"; judge.dispatch_context.bound_override has bound:"max_attempts".

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

# Drive a2 end-to-end. Args:
#   $1 = scenario: "green" | "iterate" | "bound"
# Returns CSV: loop_phase|iteration_attempts|new_plan_ids|judge_state|bound_override_present
drive_a2() {
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

# Step 1: init via /auto plan.md --recipe a2 — the PRODUCTION path. U6 plumbing
# (auto.py + init_ledger) carries recipe.iteration + recipe.emit_templates onto
# the ledger. This is the wire being tested.
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--recipe", "a2"])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

# Sanity: confirm the ledger carries the iteration block (U6 plumbing alive).
led0 = ledger.read_ledger(repo, run_id)
assert led0.get("iteration"), f"iteration block missing on ledger after init: {sorted(led0.keys())!r}"
assert led0.get("emit_templates"), "emit_templates missing on ledger after init"
assert led0["iteration"]["gate_unit"] == "judge", led0["iteration"]
assert led0["iteration_emit_count"] == 3, f"iteration_emit_count={led0['iteration_emit_count']!r}"  # F0: init_ledger seeds from max numeric suffix matching id_prefix; a2 has plan-1/2/3 + id_prefix='plan-' → seed=3 (production-faithful — the test no longer rigs this)

# Step 2: prime plan units' enumerated_units (needed for GREEN's downstream
# emitter), set gaps_open=0 + plan_step=review_plan so predicate composition
# is at "plan-met" (modulo iteration_pending).
ledger.set_enumerated_units(repo, run_id, "plan-1",
    [{"id": "wA-1", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_enumerated_units(repo, run_id, "plan-2",
    [{"id": "wB-1", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_enumerated_units(repo, run_id, "plan-3",
    [{"id": "wC-1", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_gaps_open(repo, run_id, 0)
ledger.set_loop(repo, run_id, plan_step="review_plan")

# For BOUND, pre-seed iteration_attempts = max_attempts (5). Direct write under
# the lock — counter mutation is internal. The bound check fires PRE-increment
# inside evaluate_decision; with attempts_made=5 == max_attempts=5, iterate
# decisions are forced to "exit" + bound_breached.
def seed(L):
    if scenario == "bound":
        L["iteration_attempts"] = 5
ledger._with_locked_ledger(repo, run_id, seed)

# F0 fix-pass: NO MANUAL COUNTER SEEDING. init_ledger now seeds
# iteration_emit_count from the max numeric suffix of unit ids matching any
# emit_templates[*].id_prefix. For a2 (units=plan-1/2/3, id_prefix='plan-'),
# the production seed is 3 — the first iterate naturally produces 'plan-4'.
# Before this fix, the test masked a P0 emit-id collision by rigging the
# counter; now the production path and the test path are the same path.

# Step 3: dispatch the judge unit + write its verdict per scenario via the
# PRODUCTION path (record_verdict + set_verdict_decision). dispatch must come
# first because set_verdict_decision only writes on dispatched-or-later units.
ledger.transition(repo, run_id, "judge", "dispatched")
ledger.record_verdict(repo, run_id, "judge",
    [{"severity": "minor", "note": f"scenario={scenario}"}])
if scenario == "green":
    # GREEN: gate says advance. iteration logic does NOT fire (advance_iteration_loop
    # returns {"action":"advance"} and the caller falls through). The standard
    # flow needs a winner_unit_id for the judge_winner_to_work_units emitter.
    ledger.set_verdict_decision(repo, run_id, "judge", "advance")
    ledger.set_winner_unit_id(repo, run_id, "judge", "plan-1")
elif scenario == "iterate":
    # ITERATE: gate says iterate with emit_count=1 → iterate_template emits
    # plan-4. iteration_attempts becomes 1; judge resets to pending with
    # extended depends_on.
    ledger.set_verdict_decision(repo, run_id, "judge", "iterate",
        payload={"emit_count": 1})
elif scenario == "bound":
    # BOUND: iteration_attempts already at max (5). evaluate_decision returns
    # "exit"/bound_breached. advance_iteration_loop writes bound_override +
    # set_loop(done). No iteration_attempts increment (override does NOT count).
    ledger.set_verdict_decision(repo, run_id, "judge", "iterate",
        payload={"emit_count": 1})

# Step 4: tick. advance_iteration_loop fires at the top of _tick_body_inner.
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

led = ledger.read_ledger(repo, run_id)
judge = next(u for u in led["units"] if u["id"] == "judge")
new_plans = sorted(u["id"] for u in led["units"]
                   if u.get("phase") == "plan" and u["id"] not in ("plan-1", "plan-2", "plan-3"))
bound_override_present = "bound_override" in (judge.get("dispatch_context") or {})
print("%s|%d|%s|%s|%s" % (
    led["loop_phase"],
    int(led.get("iteration_attempts", 0)),
    ",".join(new_plans),
    judge.get("state"),
    "yes" if bound_override_present else "no",
))
PYEOF
}

# ─── Scenario 1: GREEN — judge advance → no iteration; standard flow ────────
it "U6 a2 GREEN: judge decision=advance → iteration block doesn't fire, iteration_attempts=0"
res="$(drive_a2 green)"
# Expected (R7 backward compat): standard A2 GREEN behavior, iteration_attempts
# unchanged at 0, no new plan units, judge ends up in verdict-returned (with
# winner_unit_id set), no bound_override. After tick:
#   - loop_phase: standard advance path (the predicate-met short-circuit lifts
#     to "done" since iteration_pending=False). For A2 with no new winner units
#     emitted prior to this tick, the work predicate met=True only if all
#     pending work units terminal; here judge_winner_to_work_units emits plan-1's
#     enumerated set (wA-1 — pending) so met=False and loop stays in work.
#   - iteration_attempts: 0 (no iterate decision honored).
#   - new_plans: "" (no iteration emission).
#   - judge.state: verdict-returned (the standard auto-flip path leaves it).
#   - bound_override: no (no bound breach).
case "$res" in
  "work|0||verdict-returned|no") pass ;;
  *) fail "expected 'work|0||verdict-returned|no', got '$res'" ;;
esac

# ─── Scenario 2: ITERATE — judge iterate under bound → emit plan-4 ──────────
it "U6 a2 ITERATE: judge decision=iterate(emit_count=1) → plan-4 emitted, attempts=1, judge pending"
res="$(drive_a2 iterate)"
# Expected: iterate_template emits plan-4 (id_prefix "plan-" + counter base 3
# + 1). iteration_attempts increments to 1. Judge resets to pending with
# depends_on extended to include plan-4 (lib/ledger.py::_reset_gate_for_iteration).
# loop_phase stays "plan" — iteration adds siblings WITHIN the current phase
# per KTD §D. No bound_override (under bound).
case "$res" in
  "plan|1|plan-4|pending|no") pass ;;
  *) fail "expected 'plan|1|plan-4|pending|no', got '$res'" ;;
esac

# ─── Scenario 3: BOUND — iteration_attempts==max → bound_override + done ────
it "U6 a2 BOUND: iteration_attempts=5==max, judge writes iterate → bound_override, loop=done"
res="$(drive_a2 bound)"
# Expected: evaluate_decision returns decision_effective="exit"/bound_breached.
# advance_iteration_loop writes bound_override on judge.dispatch_context +
# forces loop_phase to "done" via set_loop DIRECTLY (NOT advance_to_phase, per
# KTD §C). iteration_attempts STAYS at 5 (override does not count as a honored
# attempt). No new plan units. Judge stays in verdict-returned (set_verdict_decision
# does not advance state; the override doesn't touch unit state). bound_override
# present.
case "$res" in
  "done|5||verdict-returned|yes") pass ;;
  *) fail "expected 'done|5||verdict-returned|yes', got '$res'" ;;
esac

# ─── DF Scenario 4: counter-init-seed-prevents-emit-collision ───────────────
# WHY: v0.3.0 review-round-1 surfaced a cross-reviewer P0 (ADV-1 + testing +
# correctness). When init_ledger naively seeded `iteration_emit_count = 0`,
# iterate_template's first emit produced `plan-1` — which collides with the
# recipe-declared `plan-1` unit, raising LedgerError in _apply_emit. The
# previous version of THIS test rigged the counter to 3 post-init, masking
# the bug. F0 closes it: init_ledger now scans units[] for the max numeric
# suffix matching any emit_templates[*].id_prefix and seeds to that.
#
# This DF probes BOTH directions of the contract:
#   (a) GREEN: init_ledger of a "plan-1/2/3 + id_prefix='plan-'" recipe shape
#       MUST seed iteration_emit_count=3 (proving the F0 fix is wired).
#   (b) GREEN: init_ledger of a non-iteration shape (no emit_templates) MUST
#       seed iteration_emit_count=0 (proving F0 doesn't over-fire).
#   (c) GREEN: init_ledger of a "build-clarity/build-perf + id_prefix='build-'"
#       shape (a4-like, word-suffixed) MUST seed iteration_emit_count=0
#       (proving F0's isdigit() check correctly skips non-numeric suffixes).
#
# These three cases lock the F0 invariant against silent regression: if the
# seed logic is reverted to 0, (a) fails; if the seed logic over-fires on
# missing emit_templates, (b) fails; if it greedy-matches non-numeric
# suffixes, (c) fails.
it "F0 DF: init_ledger seeds iteration_emit_count from max numeric suffix matching id_prefix"
res="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_ledger
ledger = load_ledger()

with tempfile.TemporaryDirectory() as repo:
    # (a) a2-shape: plan-1/2/3 + id_prefix 'plan-' → expect seed=3
    led_a = ledger.init_ledger(
        repo, "df-a", adapter="ce",
        units=[{"id":"plan-1","phase":"plan"},
               {"id":"plan-2","phase":"plan"},
               {"id":"plan-3","phase":"plan"},
               {"id":"judge","phase":"work","depends_on":["plan-1","plan-2","plan-3"]}],
        iteration={"gate_unit":"judge","emit_template":"pc",
                   "bound":{"max_attempts":5}},
        emit_templates={"pc":{"phase":"plan","invokes":{},"id_prefix":"plan-"}})
    assert led_a["iteration_emit_count"] == 3, f"(a) expected 3, got {led_a['iteration_emit_count']}"

    # (b) no emit_templates → expect seed=0 (F0 is a no-op when emit_templates is None)
    led_b = ledger.init_ledger(
        repo, "df-b", adapter="ce",
        units=[{"id":"plan-1","phase":"plan"},{"id":"plan-2","phase":"plan"}])
    assert led_b["iteration_emit_count"] == 0, f"(b) expected 0, got {led_b['iteration_emit_count']}"

    # (c) a4-shape: word-suffixed units (build-clarity/build-perf) + id_prefix
    # 'build-' → expect seed=0 (isdigit() filters non-numeric suffixes).
    # NOTE: a4's actual production recipe has NO 'build-*' units in units[] —
    # those are emitted by plan_output_to_paired_builders. This synthetic
    # scenario probes the F0 isdigit guard directly.
    led_c = ledger.init_ledger(
        repo, "df-c", adapter="ce",
        units=[{"id":"plan","phase":"plan"},
               {"id":"build-clarity","phase":"work","depends_on":["plan"]},
               {"id":"build-perf","phase":"work","depends_on":["plan"]},
               {"id":"compare","phase":"work","depends_on":["build-clarity","build-perf"]}],
        iteration={"gate_unit":"compare","emit_template":"bb",
                   "bound":{"max_attempts":4}},
        emit_templates={"bb":{"phase":"work","invokes":{},"id_prefix":"build-"}})
    assert led_c["iteration_emit_count"] == 0, f"(c) expected 0, got {led_c['iteration_emit_count']}"

print("OK")
PYEOF
)"
case "$res" in
  *OK*) pass ;;
  *) fail "F0 DF assertions failed: $res" ;;
esac

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "$(basename "$0"): ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
