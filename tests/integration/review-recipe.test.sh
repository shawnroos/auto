#!/usr/bin/env bash
# auto v0.6.0 U11 integration test: the off-spine review recipe
# (recipes/review.json) drives a SINGLE review/fix loop to a P3-only terminal
# verdict and stops at `done` — it never auto-advances and never rebounds.
#
# WHY THIS TEST EXISTS (round-2 P2, lib/backend-ce.py):
# recipes.test.sh already pins that review.json validates / resolves / is
# distinct from w. But the DISPATCH path was never driven: review.json's work
# unit carries `dispatch_context.backend_op == "review"` (NOT "do_step"), and the
# DRIVER — not the backend, not the dispatcher — maps that backend_op to the
# skill it launches (`review` → /ce-code-review; `do_step` → /ce-work). This test
# drives the real engine end-to-end so the off-spine review path is locked, not
# inferred:
#   * init via `--recipe review` enters at `work` with one `review` unit whose
#     dispatch_context.backend_op is "review" (the model-facing dispatch label —
#     driver-reference.md §7, SKILL.md §4);
#   * a clean (P3-only) verdict drives the single phase to `loop_phase == "done"`;
#   * the run NEVER leaves `work` for another phase (single-phase, no spine).
#
# DELIBERATE-FAIL CONTROL (feedback_new_tests_need_deliberate_fail_smoke_check):
# the SECOND scenario records a GATING (blocker) verdict instead of a clean one.
# The work-loop MUST then NOT reach `done` (all_steps_terminal == false) — proving
# the `done` in scenario 1 is caused by the clean verdict, not an artifact of the
# single-unit recipe.

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

# Staleness off so the freshly-written ledger isn't read as a dead chain; the
# pulse-lock hatch fence needs the harness sentinel too.
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_TEST_NO_STALENESS_CHECK=1

# Drive review.json: init at work, dispatch the review unit, record a verdict
# (clean if clean=1 else a blocker), pulse once, read back. Prints a CSV:
#   backend_op | entry_phase | phase_order | loop_phase_after | unit_state
drive_review() {
  clean="${1:-1}"
  "$PY" - "$AUTO_ROOT" "$clean" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
clean = sys.argv[2] == "1"
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
pulse = load("pulse", os.path.join(auto_root, "lib", "pulse.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# x\n")

# Step 1: /auto --recipe review → off-spine run, entry at `work` (U11 wiring).
with contextlib.redirect_stdout(io.StringIO()):
    a.run(["--recipe", "review", plan])
run_id = [os.path.basename(f).rsplit(".json", 1)[0]
          for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))
          if not f.endswith(".lock")][0]
path = os.path.join(repo, ".claude", "auto", f"{run_id}.json")

def ld():
    with open(path) as fh:
        return json.load(fh)

entry = ld()
review_unit = next(u for u in entry["steps"] if u["id"] == "review")
# The model-facing dispatch label: backend_op lands on dispatch_context (the
# canonical write path strips it off `invokes`). review → /ce-code-review.
backend_op = (review_unit.get("dispatch_context") or {}).get("backend_op")
entry_phase = entry.get("loop_phase")
phase_order = ",".join(entry.get("phase_order") or [])

# Step 2: dispatch the review unit, then the agent self-writes its verdict. A
# clean verdict (P3-only — modelled as empty findings) makes the unit terminal;
# a blocker keeps it gating.
ledger.transition(repo, run_id, "review", "dispatched")
findings = [] if clean else [{"severity": "blocker", "note": "flaw"}]
ledger.record_verdict(repo, run_id, "review", findings)

# Step 3: pulse once. Single-phase work loop — a clean verdict drives it to done;
# a blocker leaves it at work (all_steps_terminal == false). No auto-advance to
# another phase under any verdict (phase_order is just ["work"]).
with contextlib.redirect_stdout(io.StringIO()):
    pulse.dispatch_pulse(repo, run_id, auto=True)

after = ld()
unit_state = next(u for u in after["steps"] if u["id"] == "review")["state"]
print("%s|%s|%s|%s|%s" % (
    backend_op, entry_phase, phase_order, after.get("loop_phase"), unit_state))
PYEOF
}

echo "review-recipe.test.sh"

# ─── Scenario 1: clean verdict → single phase drives to done ──────────────────
res="$(drive_review 1)"
IFS='|' read -r backend_op entry_phase phase_order loop_phase unit_state <<< "$res"

it "review unit carries dispatch_context.backend_op == 'review' (the dispatch label → /ce-code-review)"
assert_eq "review" "$backend_op"

it "review.json enters at the work phase (off-spine, no plan phase)"
assert_eq "work" "$entry_phase"

it "review.json phase_order is single-phase ['work'] (no spine, no auto-advance)"
assert_eq "work" "$phase_order"

it "a clean (P3-only) verdict drives the single review phase to loop_phase=done"
assert_eq "done" "$loop_phase"

# ─── Scenario 2 (DELIBERATE-FAIL CONTROL): a blocker does NOT reach done ──────
res_blk="$(drive_review 0)"
IFS='|' read -r _ _ _ loop_phase_blk unit_state_blk <<< "$res_blk"

it "DELIBERATE-FAIL: a GATING (blocker) verdict does NOT reach done (work-loop still open)"
case "$loop_phase_blk" in
  done) fail "blocker verdict reached done — scenario 1's done is an artifact, not the clean verdict" ;;
  *) pass ;;
esac

it "control: with a blocker the review unit is NOT clean-terminal (it has a fix to drive)"
case "$unit_state_blk" in
  verdict-returned|fixed|pending|dispatched) pass ;;
  *) fail "unexpected unit state with a gating verdict: $unit_state_blk" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "review-recipe.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
