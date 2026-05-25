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
# CONTRACT DISAGREEMENT FOUND (route to fix-pass E):
#   lib/emitters.py::judge_winner_to_work_units reads winner_unit_id from
#   judge.findings[].winner_unit_id, BUT lib/ledger.py::record_verdict
#   (lines 885-890) hard-strips ALL keys except {severity, note} when
#   normalizing the findings list. So the canonical write path (a real judge
#   adapter calling record_verdict) can NEVER deliver winner_unit_id to the
#   emitter — the field is dropped on the way to disk. The unit test
#   (emitters.test.sh:67) sidesteps this by constructing the ledger dict
#   directly; this integration test does the same to assert the CURRENT
#   contract on emitters.py, AND adds a dedicated scenario that asserts the
#   record_verdict-strip behavior so the disagreement is loudly documented.
#   See commit message + report for routing.
#
# STRUCTURE: init via auto.run with --recipe a2; the recipe declares 3 plan
# units + a judge work unit. Prime each plan unit with stashed enumerated_units
# (different ids per plan), set gaps_open=0 + plan_step=review_plan so plan-met
# fires, inject judge findings ON DISK (sidestepping record_verdict — see
# disagreement above), then dispatch_tick(auto=True). Auto-flip fires
# judge_winner_to_work_units which reads the winner's enumerated set + emits.
#
# Scenarios:
#   1. green: winner_unit_id="plan-2" → emitter emits plan-2's enumerated units
#   2. deliberate-fail (no winner): judge findings carry no winner_unit_id →
#      emitter raises ValueError; tick catches it, ledger stays at loop_phase=plan
#      with NO new work units (the wire is alive; the failure is the contract).
#   3. malformed judge: winner_unit_id names a non-existent unit → emitter
#      raises with the right message; same catch-and-stay-at-plan behavior.
#   4. CONTRACT DISAGREEMENT (documents fix-pass E work): record_verdict strips
#      winner_unit_id from the findings dict, so the canonical write path can
#      never feed the emitter. Asserts the strip behavior on a fresh ledger.

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
# The judge unit's id is `judge`; its findings are written ON DISK
# (sidestepping record_verdict's strip — see contract disagreement at top).
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

# Step 3: inject the judge's findings directly on disk. This sidesteps
# record_verdict, which strips winner_unit_id (the CONTRACT DISAGREEMENT
# scenario at the bottom of this file asserts the strip independently).
path = os.path.join(repo, ".claude", "auto", f"{run_id}.json")
with open(path) as f:
    led_raw = json.load(f)
for u in led_raw["units"]:
    if u["id"] == "judge":
        if scenario == "green":
            u["findings"] = [{"severity": "minor", "note": "winner=plan-2",
                              "winner_unit_id": "plan-2"}]
        elif scenario == "no-winner":
            # deliberate-fail: the emitter raises if no winner is named.
            u["findings"] = [{"severity": "minor", "note": "undecided"}]
        elif scenario == "bad-winner":
            # malformed: winner names a non-existent unit.
            u["findings"] = [{"severity": "minor", "note": "winner=ghost",
                              "winner_unit_id": "plan-999"}]
        u["state"] = "verdict-returned"
        u["verdict_at"] = "2026-01-01T00:00:00Z"
with open(path, "w") as f:
    json.dump(led_raw, f)

# Step 4: tick. auto=True so _maybe_seam takes the auto-flip branch and routes
# advance_to_phase → transition_and_emit → judge_winner_to_work_units.
# dispatch_tick catches emitter exceptions (lib/tick.py:614) and converts them
# to a recorded stall, so the no-winner / bad-winner scenarios still complete
# the call — the ledger just stays at loop_phase=plan with no new work units.
with contextlib.redirect_stdout(io.StringIO()):
    with contextlib.redirect_stderr(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)

led = json.load(open(path))
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

# Assert the raise message for the malformed case carries the bad winner id —
# this protects the operator-facing diagnostic (a recipe bug pointing at the
# wrong unit id should show that unit id in the error).
it "fix-pass C T2 MALFORMED MESSAGE: emitter raise mentions the missing winner unit id"
msg="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
emitters = load("emitters", os.path.join(auto_root, "lib", "emitters.py"))
led = {"units": [
    {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": []}},
    {"id": "judge", "phase": "work",
     "findings": [{"severity": "minor", "note": "x", "winner_unit_id": "plan-999"}]},
]}
try:
    emitters.judge_winner_to_work_units(led, "work"); print("NO-RAISE")
except ValueError as e:
    print("plan-999" in str(e))
PYEOF
)"
assert_eq "True" "$msg"

# ─── Scenario 4: CONTRACT DISAGREEMENT (documents fix-pass E work) ──────────
# record_verdict strips ALL keys except {severity, note} when normalizing
# findings (ledger.py:885-890). emitters.py::judge_winner_to_work_units reads
# winner_unit_id from those findings. The canonical write path therefore CANNOT
# feed the emitter — winner_unit_id is dropped on the way to disk. This is the
# integration-level proof of the disagreement (the unit + the contract see
# different shapes); fix-pass E should reconcile, likely by moving winner_unit_id
# to dispatch_context (which IS persisted intact by transition()) or by widening
# record_verdict's normalize to preserve additional keys.
it "fix-pass C T2 CONTRACT DISAGREEMENT: record_verdict strips winner_unit_id (route to fix-pass E)"
strip_result="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util, tempfile, contextlib, io
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))

repo = tempfile.mkdtemp(); run = "strip-probe"
ledger.init_ledger(repo, run, adapter="ce",
    units=[{"id": "judge", "phase": "work", "state": "pending"}])
# Realistic write path: dispatch then record_verdict with winner_unit_id set.
ledger.transition(repo, run, "judge", "dispatched")
ledger.record_verdict(repo, run, "judge",
    [{"severity": "minor", "note": "winner=plan-2",
      "winner_unit_id": "plan-2"}])
led = ledger.read_ledger(repo, run)
finding = led["units"][0]["findings"][0]
# Assert the strip: the keys are exactly {severity, note} — winner_unit_id is gone.
keys = sorted(finding.keys())
print("STRIPPED" if keys == ["note", "severity"] and "winner_unit_id" not in finding else "PRESERVED")
PYEOF
)"
# We ASSERT "STRIPPED" — proving the contract disagreement is on disk today.
# When fix-pass E lands a fix this flips to "PRESERVED" and the test breaks
# deliberately — that's the signal to update the test (or remove it) along
# with the fix. The test name + commit message route the work.
assert_eq "STRIPPED" "$strip_result"

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "$(basename "$0"): ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
