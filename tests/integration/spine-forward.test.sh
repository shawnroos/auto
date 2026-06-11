#!/usr/bin/env bash
# auto U9 (v0.6.0) integration test: the brainstorm-rooted spine
# (recipes/pipeline.json) advances brainstorm → plan → work FORWARD, and an
# injected upstream cluster PAUSES + escalates to the operator with NO
# loop_phase change and NO new persisted ledger field.
#
# WHY THIS TEST EXISTS (KTD-6 / feedback_a1_recipe_cant_rebound_to_brainstorm):
# v0.6.0 ships the DETECTION half of the upstream-flaw problem. When review
# findings cluster on an upstream spine phase (weighting reviewer-role
# DIVERSITY over raw count), auto must NOT ratchet fix passes against a gap the
# current phase can't close — it escalates the cluster to the operator via the
# EXISTING pause seam (driver=manual + blocked_on). The autonomous backward edge
# (rebound) is deferred to v0.7.0; this test asserts v0.6.0's narrow contract:
#   * forward advance works (the spine recipe's emitters fire on arrival), AND
#   * on a detected cluster the run PAUSES (driver=manual, blocked_on names the
#     upstream phase), loop_phase is UNCHANGED (no backward move), and NO new
#     top-level ledger field is written.
#
# DELIBERATE-FAIL CONTROL (feedback_new_tests_need_deliberate_fail_smoke_check):
# the LAST scenario primes the identical work-phase ledger but withOUT the
# role-tagged cluster_findings. The work-loop MUST then take its normal fix
# advance (no pause), proving the pause in scenario 2 is caused by the cluster,
# not an artifact of the priming.

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

# Staleness check off so the freshly-written ledger isn't read as a dead chain;
# tick-lock hatch fence requires the harness sentinel too.
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_TEST_NO_STALENESS_CHECK=1

# ── Shared driver. Builds a spine run, advances brainstorm→plan→work forward,
# then optionally injects an upstream cluster and ticks once. Prints a CSV.
#   inject_cluster=1 → write role-tagged cluster_findings on the work unit.
# Output CSV: forward_ok | tick_reason | loop_phase | driver | blocked_on_named | top_keys_unchanged | work_unit_state
drive_spine() {
  inject_cluster="${1:-0}"
  "$PY" - "$AUTO_ROOT" "$inject_cluster" <<'PYEOF'
import sys, os, tempfile, json, io, contextlib, importlib.util, glob
auto_root = sys.argv[1]
inject_cluster = sys.argv[2] == "1"
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
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# x\n")

# Step 1: /auto --recipe pipeline → spine run at brainstorm entry (U7 wiring).
with contextlib.redirect_stdout(io.StringIO()):
    a.run(["--recipe", "pipeline", plan])
run_id = [os.path.basename(f).rsplit(".json", 1)[0]
          for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))
          if not f.endswith(".lock")][0]
path = os.path.join(repo, ".claude", "auto", f"{run_id}.json")

def ld():
    with open(path) as fh:
        return json.load(fh)

# Sanity: entered at brainstorm with the full spine phase_order.
entry = ld()
forward_ok = (entry.get("loop_phase") == "brainstorm"
              and entry.get("phase_order") == ["brainstorm", "plan", "seam", "work"])

# Step 2: forward advance brainstorm → plan through the REAL per-tick path
# (round-1 P1 fix: this leg used to hand-call advance_to_phase, which masked the
# missing brainstorm advance trigger — the feature livelocked in a real run
# while the test stayed green). Prime the brainstorm unit verdict-returned with
# its requirements-doc output, then drive dispatch_tick exactly as the plan→work
# leg below does. dispatch_tick's brainstorm branch fires the U8
# brainstorm_output_to_plan_unit emitter on advance to plan (emitter-driven, not
# predicate-met). If the brainstorm trigger is missing this goes RED (the
# deliberate-fail control for the wiring).
led = ld()
for u in led["units"]:
    if u["id"] == "brainstorm":
        u["state"] = "verdict-returned"
        u.setdefault("dispatch_context", {})["requirements_doc"] = "docs/brainstorms/x.md"
with open(path, "w") as fh:
    json.dump(led, fh)
with contextlib.redirect_stdout(io.StringIO()):
    tick.dispatch_tick(repo, run_id, auto=True)
led = ld()
plan_units = [u["id"] for u in led["units"] if u["phase"] == "plan"]
forward_ok = forward_ok and led.get("loop_phase") == "plan" and len(plan_units) == 1

# Step 3: forward advance plan → work. Prime plan-done (enumerated units +
# gaps_open=0 + plan_step=review_plan) and auto-flip; the plan→work emitter
# materializes the work unit.
plan_uid = plan_units[0]
ledger.set_enumerated_units(
    repo, run_id, plan_uid,
    [{"id": "w-alpha", "invokes": {"adapter_op": "do_unit"}}])
ledger.set_gaps_open(repo, run_id, 0)
ledger.set_loop(repo, run_id, plan_step="review_plan")
with contextlib.redirect_stdout(io.StringIO()):
    tick.dispatch_tick(repo, run_id, auto=True)
led = ld()
work_units = [u["id"] for u in led["units"] if u["phase"] == "work"]
forward_ok = forward_ok and led.get("loop_phase") == "work" and "w-alpha" in work_units

# Step 4: bring the work unit to verdict-returned with a GATING finding (so the
# work-loop has a fix to apply absent any cluster — the negative-control path).
w_uid = "w-alpha"
ledger.transition(repo, run_id, w_uid, "dispatched")
ledger.record_verdict(repo, run_id, w_uid, [{"severity": "blocker", "note": "flaw"}])

# Inject (or not) the role-tagged upstream cluster on dispatch_context —
# the `decision`/`winner_unit_id` channel, since findings[] is normalized to
# {severity, note}. 3 DISTINCT roles attributing to the upstream `plan` phase.
if inject_cluster:
    led = ld()
    for u in led["units"]:
        if u["id"] == w_uid:
            u.setdefault("dispatch_context", {})["cluster_findings"] = [
                {"role": "adversarial", "phase": "plan"},
                {"role": "feasibility", "phase": "plan"},
                {"role": "security",    "phase": "plan"},
            ]
    with open(path, "w") as fh:
        json.dump(led, fh)

# Snapshot loop_phase + top-level key set BEFORE the work-loop tick.
before = ld()
before_phase = before.get("loop_phase")
before_top = sorted(before.keys())

with contextlib.redirect_stdout(io.StringIO()):
    intent = tick.dispatch_tick(repo, run_id, auto=True)

after = ld()
loop = after.get("loop") or {}
blocked_on = loop.get("blocked_on") or ""
print("%s|%s|%s|%s|%s|%s|%s" % (
    "yes" if forward_ok else "no",
    intent.get("reason"),
    after.get("loop_phase"),
    loop.get("driver"),
    "yes" if (before_phase == after.get("loop_phase")) else "PHASE-MOVED",
    "yes" if ("plan" in blocked_on and "upstream" in blocked_on) else "no",
    "unchanged" if before_top == sorted(after.keys()) else "NEW-FIELD",
))
PYEOF
}

# ── First-brainstorm-tick dispatch driver (P0 fix-round-3). A REAL first tick:
# brainstorm unit PENDING, NO requirements_doc — the state advance_brainstorm_loop
# re-arms on. Asserts the rearm intent's operator_guidance surfaces the DISPATCH
# half (run /ce-brainstorm + record the doc + self-write verdict-returned), which
# the pre-seeded forward-advance leg above CANNOT cover (it skips straight to the
# advance half). Without the brainstorm guidance branch the phase wedges forever
# (every tick re-arms with only the generic prepare/execute reminder, /ce-brainstorm
# nowhere) — feedback_plan_documents_transition_code_doesnt_wire_it. Output CSV:
#   action | has_brainstorm_cmd | has_record_doc_instr | advance_reason
drive_first_brainstorm_tick() {
  "$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, tempfile, json, io, contextlib, importlib.util, glob
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
tick = load("tick", os.path.join(auto_root, "lib", "tick.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# x\n")

# Spine run at brainstorm entry; brainstorm unit is PENDING (init state), NO
# requirements_doc — do NOT pre-seed it (that is exactly the green-by-construction
# masking this scenario exists to remove).
with contextlib.redirect_stdout(io.StringIO()):
    a.run(["--recipe", "pipeline", plan])
run_id = [os.path.basename(f).rsplit(".json", 1)[0]
          for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))
          if not f.endswith(".lock")][0]

with contextlib.redirect_stdout(io.StringIO()):
    intent = tick.dispatch_tick(repo, run_id, auto=True)

g = intent.get("operator_guidance") or ""
adv = intent.get("advance") or {}
print("%s|%s|%s|%s" % (
    intent.get("action"),
    "yes" if "/ce-brainstorm" in g else "no",
    "yes" if ("requirements_doc" in g and "verdict-returned" in g) else "no",
    adv.get("reason"),
))
PYEOF
}

# ─── Scenario 0 (P0 fix-round-3): first brainstorm tick surfaces the DISPATCH ──
res0="$(drive_first_brainstorm_tick)"
IFS='|' read -r action0 has_cmd has_doc adv_reason <<< "$res0"

it "first brainstorm tick re-arms (pending unit, no requirements_doc yet)"
assert_eq "rearm" "$action0"

it "first brainstorm tick advance is brainstorm-pending (advance half not yet ready)"
assert_eq "brainstorm-pending" "$adv_reason"

it "P0: brainstorm operator_guidance surfaces the /ce-brainstorm invocation"
assert_eq "yes" "$has_cmd"

it "P0: brainstorm guidance instructs record requirements_doc + self-write verdict-returned"
assert_eq "yes" "$has_doc"

# ─── Scenario 1: forward advance + upstream cluster → pause + escalate ────────
res="$(drive_spine 1)"
IFS='|' read -r forward reason phase driver phase_unchanged blocked_named keys <<< "$res"

it "spine recipe advances brainstorm → plan → work forward (emitter-driven)"
assert_eq "yes" "$forward"

it "injected upstream cluster PAUSES the run (tick stop reason = seam-pause)"
assert_eq "seam-pause" "$reason"

it "escalation flips driver=manual (the existing pause seam)"
assert_eq "manual" "$driver"

it "NO backward loop_phase move (stays at work — rebound is v0.7.0, KTD-6)"
assert_eq "yes" "$phase_unchanged"

it "blocked_on names the upstream phase + the cluster (operator message)"
assert_eq "yes" "$blocked_named"

it "NO new persisted top-level ledger field (driver/blocked_on already exist)"
assert_eq "unchanged" "$keys"

# ─── Scenario 2 (DELIBERATE-FAIL CONTROL): no cluster → normal fix, no pause ──
res_off="$(drive_spine 0)"
IFS='|' read -r f2 reason2 phase2 driver2 _ _ _ <<< "$res_off"

it "control: forward advance still works without a cluster"
assert_eq "yes" "$f2"

it "DELIBERATE-FAIL: WITHOUT a cluster the work-loop does NOT pause (drives a fix)"
# No cluster → the work-loop applies the fix and re-arms (driver stays self,
# the tick re-arms rather than stopping on seam-pause). If this branch ALSO
# showed seam-pause/manual, the pause in scenario 1 would be a priming artifact.
case "${reason2}:${driver2}" in
  seam-pause:manual) fail "control paused without a cluster — scenario 1's pause is an artifact" ;;
  *) pass ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "spine-forward.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
