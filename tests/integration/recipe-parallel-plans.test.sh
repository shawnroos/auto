#!/usr/bin/env bash
# auto v0.2.0 fix-pass C integration test (T2): drive recipe a2 end-to-end
# from plan-done → auto-flip → judge_winner_to_work_units emission.
#
# WHY THIS TEST EXISTS (memory feedback_plan_documents_transition_code_doesnt_wire_it):
# Unit tests on judge_winner_to_work_units (emitters.test.sh scenario 4/5) cover
# the emitter in isolation; the a1 integration test covers the engine wire for
# the SIMPLE (one plan unit) case. Neither proves the engine actually routes a2
# — three parallel plan units + a judge with a winner_unit_id finding — through
# the same auto-flip path. This test does: it primes the ledger to the
# post-judge state and asserts the emitter emitted the WINNER's enumerated set,
# not some other plan's.
#
# CONTRACT (round-2 P0 fix — fix-pass I, post-reconcile):
#   The judge declares its winner via judge.dispatch_context.winner_unit_id,
#   written by the new ledger.set_winner_unit_id mutator. The emitter reads
#   from there. dispatch_context is the right home: same channel as
#   enumerated_units, preserved by transition() and the verdict-write path
#   with no normalize step. record_verdict's findings normalize ({severity,
#   note} only) is left intact — narrow findings is the schema, dispatch_context
#   carries the routing data. The round-1 design (winner on findings) was
#   unreachable because record_verdict stripped the key before disk.
#
# STRUCTURE: init via auto.run with --recipe a2; the recipe declares 3 plan
# units + a judge work unit. Prime each plan unit with stashed enumerated_units,
# set gaps_open=0 + plan_step=review_plan so plan-met fires, dispatch the judge
# and write its verdict via the PRODUCTION path (record_verdict + set_winner_unit_id —
# no on-disk sidestep), then dispatch_tick(auto=True). Auto-flip fires
# judge_winner_to_work_units which reads the winner's enumerated set + emits.
#
# Scenarios:
#   1. green: judge calls set_winner_unit_id("plan-2") → emitter emits plan-2's
#      enumerated units (production path proof).
#   2. deliberate-fail (no winner): judge records a verdict WITHOUT calling
#      set_winner_unit_id → dispatch_context.winner_unit_id is absent →
#      emitter raises RecipeError; tick catches it, ledger stays at loop_phase=plan
#      with NO new work units.
#   3. malformed message: a judge dict with no winner_unit_id on dispatch_context
#      raises a clear message naming dispatch_context AND set_winner_unit_id so
#      the operator knows exactly what to call.
#   4. production-path proof: full record_verdict + set_winner_unit_id flow on
#      a freshly-init ledger; the emitter sees the winner's enumerated set.
#   5. write-boundary guard: set_winner_unit_id rejects an unknown winner id
#      BEFORE writing, with the bad id in the message.

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

# Drive a2 from a primed post-judge state through one dispatch_tick. Args:
#   $1 = scenario: "green" | "no-winner" | "bad-winner"
# Returns CSV:
#   loop_phase | work_unit_ids_in_phase_work (sorted, comma-joined)
# Fix-pass I (round-2 P0): the judge writes its verdict via the PRODUCTION
# write path — record_verdict for findings, set_winner_unit_id for the
# winner pick (which lives on dispatch_context, immune to record_verdict's
# findings normalize). No on-disk sidestep.
drive_a2() {
  scenario="${1:-green}"
  "$PY" - "$AUTO_ROOT" "$scenario" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
scenario = sys.argv[2]
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

# Step 1: init via /auto plan.md --recipe a2. Creates a ledger with 3 plan units
# (plan-1, plan-2, plan-3) + a judge work unit depending on all three +
# phase_transitions=[{from:plan,to:work,emitter:judge_winner_to_work_units}].
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--recipe", "a2"])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

# Step 2: prime each plan unit's enumerated_units. Each plan emitted a distinct
# set so the winner's emission is identifiable (not just "any plan").
ledger.set_enumerated_units(repo, run_id, "plan-1",
    [{"id": "wA-1", "invokes": {"adapter_op": "do_unit"}},
     {"id": "wA-2", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_enumerated_units(repo, run_id, "plan-2",
    [{"id": "wB-1", "invokes": {"adapter_op": "do_unit"}},
     {"id": "wB-2", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_enumerated_units(repo, run_id, "plan-3",
    [{"id": "wC-1", "invokes": {"adapter_op": "do_unit"}}])

# Set gaps_open=0 + plan_step=review_plan so the predicate sees plan-met.
ledger.set_gaps_open(repo, run_id, 0)
ledger.set_loop(repo, run_id, plan_step="review_plan")

# Step 3: drive the judge through the PRODUCTION write path — fix-pass I
# (round-2 P0). v0.2.0 round-1 contract had judge.findings[].winner_unit_id;
# record_verdict normalize stripped it, so production A2 was unrunnable.
# Round-2 fix moves the winner onto judge.dispatch_context.winner_unit_id
# via ledger.set_winner_unit_id, called alongside record_verdict. This test
# now exercises that path end-to-end (no on-disk sidestep).
ledger.transition(repo, run_id, "judge", "dispatched")
if scenario == "green":
    ledger.record_verdict(repo, run_id, "judge",
        [{"severity": "minor", "note": "winner=plan-2"}])
    ledger.set_winner_unit_id(repo, run_id, "judge", "plan-2")
elif scenario == "no-winner":
    # deliberate-fail: judge verdicted WITHOUT calling set_winner_unit_id.
    # dispatch_context.winner_unit_id is absent → emitter raises.
    ledger.record_verdict(repo, run_id, "judge",
        [{"severity": "minor", "note": "undecided"}])
elif scenario == "bad-winner":
    # Defense-in-depth: set_winner_unit_id rejects an unknown id BEFORE
    # the verdict is written. We assert that rejection in a dedicated
    # message-check scenario below; here we still want the loop_phase=plan
    # end-state assertion, so we record the verdict and skip the set —
    # behaviorally equivalent to no-winner from the emitter's viewpoint.
    ledger.record_verdict(repo, run_id, "judge",
        [{"severity": "minor", "note": "winner=ghost (write rejected)"}])

# Step 4: tick. auto=True so _maybe_seam takes the auto-flip branch and routes
# advance_to_phase → transition_and_emit → judge_winner_to_work_units.
# dispatch_tick catches emitter exceptions (lib/tick.py:614) and converts them
# to a recorded stall, so the no-winner / bad-winner scenarios still complete
# the call — the ledger just stays at loop_phase=plan with no new work units.
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

led = ledger.read_ledger(repo, run_id)
work_units = sorted(u["id"] for u in led["units"] if u.get("phase") == "work")
# Filter out the pre-existing judge unit so the test asserts on the EMITTED set.
emitted = sorted(uid for uid in work_units if uid != "judge")
print("%s|%s" % (led["loop_phase"], ",".join(emitted)))
PYEOF
}

# ─── Scenario 1: green — emitter emits the winner's enumerated_units ────────
it "fix-pass C T2 GREEN: a2 with judge winner=plan-2 → emitter emits plan-2's units"
res="$(drive_a2 green)"
# After auto-flip the emitter ran inside transition_and_emit; loop_phase=work,
# new work units = plan-2's enumerated set (wB-1, wB-2). The judge unit is
# excluded from the comparison so we're asserting purely on the EMITTED set.
case "$res" in
  "work|wB-1,wB-2") pass ;;
  *) fail "expected 'work|wB-1,wB-2', got '$res'" ;;
esac

# ─── Scenario 2: deliberate-fail — judge findings have no winner_unit_id ────
it "fix-pass C T2 DELIBERATE-FAIL: judge findings have no winner_unit_id → emitter raises, no work units"
res_nowin="$(drive_a2 no-winner)"
# emitters.py raises ValueError. tick.py:614 catches it and records a stall,
# but the atomic transition_and_emit body raised BEFORE writing — so the ledger
# stays at loop_phase=plan with no new work units. (Recipe-declared judge work
# unit stays in the ledger but we exclude it from the emitted set above.)
case "$res_nowin" in
  "plan|") pass ;;
  *) fail "expected 'plan|' (raise → no emission, phase unchanged), got '$res_nowin'" ;;
esac

# ─── Scenario 3: malformed judge — winner_unit_id names a non-existent unit ─
it "fix-pass C T2 MALFORMED: judge winner names non-existent unit → emitter raises with right message"
res_bad="$(drive_a2 bad-winner)"
# Same behavior as scenario 2: emitter raises (different message — "winner
# 'plan-999' not in ledger"), tick catches, ledger stays at loop_phase=plan,
# no new work units appear. We assert the visible end-state; the raise message
# is asserted in the dedicated message-check scenario below.
case "$res_bad" in
  "plan|") pass ;;
  *) fail "expected 'plan|' (raise → no emission, phase unchanged), got '$res_bad'" ;;
esac

# Assert the raise message for the malformed case carries actionable diagnostic
# language. Fix-pass I changed the emitter to read from dispatch_context, so
# the "no winner_unit_id" raise now names dispatch_context + set_winner_unit_id
# so the operator knows EXACTLY where to look and what to call.
it "fix-pass I T2 MALFORMED MESSAGE: emitter raise names dispatch_context + set_winner_unit_id"
msg="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
# Use _bootstrap.load_lib_module so emitters and recipes share the SAME
# sys.modules cache → emitters.judge_winner_to_work_units raises the SAME
# RecipeError class that this test catches.
from _bootstrap import load_lib_module
emitters = load_lib_module("emitters")
recipes = load_lib_module("recipes")
# Judge without dispatch_context.winner_unit_id → the emitter raises with a
# message pointing the operator at the right fix.
led = {"units": [
    {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": []}},
    {"id": "judge", "phase": "work", "dispatch_context": {}},
]}
try:
    emitters.judge_winner_to_work_units(led, "work"); print("NO-RAISE")
except recipes.RecipeError as e:
    s = str(e)
    print("dispatch_context.winner_unit_id" in s and "set_winner_unit_id" in s)
PYEOF
)"
assert_eq "True" "$msg"

# ─── Scenario 4: production-path proof (fix-pass I — the strip is closed) ───
# Before fix-pass I, the canonical write path (record_verdict) stripped
# winner_unit_id from findings → production A2 was unrunnable. Fix-pass I
# moved the field onto dispatch_context.winner_unit_id, written by a new
# mutator set_winner_unit_id. This test proves the full production path now
# works: dispatch judge, record_verdict (still strips findings — that's
# correct/intended), set_winner_unit_id, then the emitter reads the winner
# from dispatch_context and emits the winning plan's units.
it "fix-pass I T2 PRODUCTION PATH: record_verdict + set_winner_unit_id → emitter wires the winner"
prod_result="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util, tempfile, contextlib, io
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
ledger = load_lib_module("ledger")
emitters = load_lib_module("emitters")

repo = tempfile.mkdtemp(); run = "prod-path"
ledger.init_ledger(repo, run, adapter="ce", units=[
    {"id": "plan-1", "phase": "plan"},
    {"id": "plan-2", "phase": "plan"},
    {"id": "judge", "phase": "work", "state": "pending"},
])
# plan-2 is the winner; stash its enumerated_units (would normally come from
# the plan adapter's enumerate_plan_units output).
ledger.set_enumerated_units(repo, run, "plan-2",
    [{"id": "wB-1", "invokes": {"adapter_op": "do_unit"}},
     {"id": "wB-2", "invokes": {"adapter_op": "do_unit"}}])

# THE PRODUCTION WRITE PATH (no on-disk sidestep):
ledger.transition(repo, run, "judge", "dispatched")
ledger.record_verdict(repo, run, "judge",
    [{"severity": "minor", "note": "winner=plan-2"}])
ledger.set_winner_unit_id(repo, run, "judge", "plan-2")

# Now read the ledger fresh and run the emitter — proving the winner
# survives the canonical write path AND the emitter consumes it.
led = ledger.read_ledger(repo, run)
emitted = emitters.judge_winner_to_work_units(led, "work")
print(",".join(sorted(u["id"] for u in emitted)))
PYEOF
)"
# The emitter sees plan-2's enumerated set on disk (wB-1, wB-2). If
# winner_unit_id were stripped on the way to disk, this would emit [] and the
# assertion would break — proving the production path is now closed.
assert_eq "wB-1,wB-2" "$prod_result"

# Defense-in-depth check: set_winner_unit_id rejects an unknown winner BEFORE
# writing, with a clear message naming the bad id. This catches the malformed
# case at the WRITE boundary rather than waiting for the emitter to raise.
it "fix-pass I T2 WRITE-BOUNDARY GUARD: set_winner_unit_id rejects unknown winner with the bad id in the message"
guard_msg="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
ledger = load_lib_module("ledger")
repo = tempfile.mkdtemp(); run = "winner-guard"
ledger.init_ledger(repo, run, adapter="ce", units=[
    {"id": "judge", "phase": "work", "state": "pending"},
])
try:
    ledger.set_winner_unit_id(repo, run, "judge", "plan-999")
    print("NO-RAISE")
except ledger.LedgerError as e:
    print("plan-999" in str(e))
PYEOF
)"
assert_eq "True" "$guard_msg"

# Round-3 P3 promotion (fix-pass J): set_winner_unit_id must REJECT a judge
# naming itself as winner. The previous existence check was over the full
# unit set, so judge could be its own winner — guard passed, but the emitter
# would silently emit [] (judges don't carry enumerated_units). The fix
# excludes judge_unit_id from the eligible set; the malformed case now
# surfaces at the write boundary with a message naming the constraint.
it "fix-pass J: set_winner_unit_id rejects judge naming itself as winner (P3 promotion)"
self_msg="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
ledger = load_lib_module("ledger")
repo = tempfile.mkdtemp(); run = "self-winner"
# Realistic A2 shape: plan units + judge. The malformed verdict names the
# judge itself, which used to slip past the guard.
ledger.init_ledger(repo, run, adapter="ce", units=[
    {"id": "plan-1", "phase": "plan"},
    {"id": "judge",  "phase": "work", "state": "pending"},
])
try:
    ledger.set_winner_unit_id(repo, run, "judge", "judge")
    print("NO-RAISE")
except ledger.LedgerError as e:
    s = str(e)
    # Reject AND name both the bad id and the constraint (judge must differ).
    print("judge" in s and ("must differ" in s or "eligible" in s))
PYEOF
)"
assert_eq "True" "$self_msg"

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "$(basename "$0"): ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
