#!/usr/bin/env bash
# auto v0.4.3 unit test: /auto-resume advance — the "declare the phase satisfied,
# move on" verb (KTD-15 / project_auto_v042_stuck_root_causes ③).
#
# advance is the general affordance for auto's missing concept of phase-
# satisfaction: the driving agent tells auto a phase is already done so it stops
# re-deriving finished work. Phase-aware:
#   * plan  → mark satisfied (plan_step=review_plan, gaps_open=0) + arm a tick;
#             the next tick enumerates straight to work, no re-planning.
#   * seam  → identical to continue (seam→work).
#   * work  → no-op (work advances by unit verdicts, not by fiat).

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

run_scenario() {
  scenario="$1"
  "$PY" - "$AUTO_ROOT" "$scenario" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root, scenario = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
resume = load("auto_resume", os.path.join(auto_root, "lib", "auto-resume.py"))
tick = load("tick", os.path.join(auto_root, "lib", "tick.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
# v0.6.x: advance re-arms a self-driven run, so it re-records the driving session
# (advisor-gate ownership) and REFUSES without one. Provide an interactive session
# id and clear the child-session marker so driver_session.driving_session_id()
# resolves — matching how hooks.test.sh drives the resume re-arm path.
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-ADVANCE-TEST"
os.environ.pop("CLAUDE_CODE_CHILD_SESSION", None)
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")

# Fresh a1 run: starts at loop_phase=plan, plan_step=null (NOT satisfied).
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

def read():
    return json.load(open(os.path.join(repo, ".claude", "auto", f"{run_id}.json")))

if scenario == "plan":
    # advance from the plan phase: declare it satisfied.
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = resume._cmd_advance(ledger, repo, run_id)
    led = read()
    epr = led.get("exit_predicate_result") or {}
    emitted = out.getvalue().strip()
    is_arm = '"action": "arm-tick"' in emitted or '"action":"arm-tick"' in emitted
    # Then a tick (model stashed the enumerated units) → should reach work.
    ledger.set_enumerated_units(repo, run_id, "plan", [
        {"id": "u-x", "invokes": {"adapter_op": "do_unit"}},
    ])
    with contextlib.redirect_stdout(io.StringIO()):
        tick.dispatch_tick(repo, run_id, auto=True)
    led2 = read()
    work = sorted(u["id"] for u in led2["units"] if u.get("phase") == "work")
    print("%s|%s|%s|%s|%s" % (
        led.get("plan_step"), epr.get("gaps_open"), is_arm,
        led2["loop_phase"], ",".join(work),
    ))

elif scenario == "work":
    # Put the run in the work phase, then advance → must be a no-op.
    ledger.set_loop(repo, run_id, loop_phase="work")
    before = read()["loop_phase"]
    with contextlib.redirect_stdout(io.StringIO()):
        rc = resume._cmd_advance(ledger, repo, run_id)
    after = read()["loop_phase"]
    print("%s|%s|%s" % (before, after, rc))

elif scenario == "seam":
    # Put the run at a paused seam, then advance → behaves like continue (→work).
    ledger.set_loop(repo, run_id, loop_phase="seam", seam_paused=True, driver="manual")
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = resume._cmd_advance(ledger, repo, run_id)
    after = read()["loop_phase"]
    emitted = out.getvalue().strip()
    is_arm = '"action": "arm-tick"' in emitted or '"action":"arm-tick"' in emitted
    print("%s|%s" % (after, is_arm))

elif scenario == "pause_operator":
    # U9: operator pause (auto-resume) → driver=manual, blocked_on recorded, and
    # backstop_latched NOT set (default False) so the operator can run their own
    # cleanup. The run stays resumable (loop_phase unchanged, not done) → a
    # follow-up continue re-arms it. Also assert the /goal-clear reminder stdout.
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = resume._cmd_pause(ledger, repo, run_id, "waiting on auth login")
    led = read()
    loop = led.get("loop") or {}
    latched = loop.get("backstop_latched")  # absent => None => not latched
    goal_note = "/goal clear" in out.getvalue()
    cont = io.StringIO()
    with contextlib.redirect_stdout(cont):
        resume._cmd_continue(ledger, repo, run_id)
    emitted = cont.getvalue()
    is_arm = '"action": "arm-tick"' in emitted or '"action":"arm-tick"' in emitted
    print("%s|%s|%s|%s|%s|%s" % (
        loop.get("driver"), latched, led.get("loop_phase"), rc, goal_note, is_arm,
    ))

elif scenario == "pause_backstop":
    # U9: the shared core with backstop_latched=True (the backstop path) LATCHES
    # the fail-closed gate so it keeps firing on a second destructive command in
    # the same turn. Exercise apply_pause directly (the shared core is the unit;
    # the full hook path is covered by advisor-gate/hooks suites).
    ledger.apply_pause(repo, run_id, "destructive command denied", backstop_latched=True)
    led = read()
    loop = led.get("loop") or {}
    print("%s|%s|%s" % (
        loop.get("driver"), loop.get("backstop_latched"), led.get("loop_phase"),
    ))

elif scenario == "pause_done":
    # U9: an already-done run → operator pause no-ops (message + rc 0, loop
    # untouched — no driver flip, no blocked_on/latch written).
    ledger.set_loop(repo, run_id, loop_phase="done")
    before = read().get("loop") or {}
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = resume._cmd_pause(ledger, repo, run_id, "too late")
    after = read().get("loop") or {}
    msg = "already done" in out.getvalue()
    unchanged = (
        before.get("driver") == after.get("driver")
        and after.get("blocked_on") is None
        and after.get("backstop_latched") is None
    )
    print("%s|%s|%s" % (rc, msg, unchanged))
PYEOF
}

# ─── plan-phase advance: marks satisfied, ticks straight to work ────────────
it "advance(plan): sets plan_step=review_plan + gaps_open=0, arms a tick, reaches work"
res="$(run_scenario plan)"
IFS='|' read -r step gaps arm phase work <<EOF
$res
EOF
[ "$step" = "review_plan" ] && [ "$gaps" = "0" ] && [ "$arm" = "True" ] \
  && [ "$phase" = "work" ] && [ "$work" = "u-x" ] \
  && pass || fail "expected review_plan|0|True|work|u-x, got ${res}"

# ─── work-phase advance: no-op ──────────────────────────────────────────────
it "advance(work): no-op (phase unchanged, exits 0)"
res_w="$(run_scenario work)"
IFS='|' read -r b_before b_after b_rc <<EOF
$res_w
EOF
[ "$b_before" = "work" ] && [ "$b_after" = "work" ] && [ "$b_rc" = "0" ] \
  && pass || fail "expected work|work|0, got ${res_w}"

# ─── seam advance: behaves like continue (→ work, arms tick) ────────────────
it "advance(seam): flips seam→work and arms a tick (== continue)"
res_s="$(run_scenario seam)"
IFS='|' read -r s_phase s_arm <<EOF
$res_s
EOF
[ "$s_phase" = "work" ] && [ "$s_arm" = "True" ] \
  && pass || fail "expected work|True, got ${res_s}"

# ─── U9: operator pause → backstop_latched False + run stays resumable ───────
it "pause(operator): driver=manual, NOT latched, /goal-clear note, continue re-arms"
res_po="$(run_scenario pause_operator)"
IFS='|' read -r po_driver po_latched po_phase po_rc po_note po_arm <<EOF
$res_po
EOF
[ "$po_driver" = "manual" ] && [ "$po_latched" = "None" ] && [ "$po_phase" = "plan" ] \
  && [ "$po_rc" = "0" ] && [ "$po_note" = "True" ] && [ "$po_arm" = "True" ] \
  && pass || fail "expected manual|None|plan|0|True|True, got ${res_po}"

# ─── U9: backstop pause → backstop_latched True ─────────────────────────────
it "pause(backstop): apply_pause(latched=True) sets driver=manual + backstop_latched True"
res_pb="$(run_scenario pause_backstop)"
IFS='|' read -r pb_driver pb_latched pb_phase <<EOF
$res_pb
EOF
[ "$pb_driver" = "manual" ] && [ "$pb_latched" = "True" ] && [ "$pb_phase" = "plan" ] \
  && pass || fail "expected manual|True|plan, got ${res_pb}"

# ─── U9: already-done run → operator pause no-ops ───────────────────────────
it "pause(done): already-done run no-ops (message, exits 0, loop untouched)"
res_pd="$(run_scenario pause_done)"
IFS='|' read -r pd_rc pd_msg pd_unchanged <<EOF
$res_pd
EOF
[ "$pd_rc" = "0" ] && [ "$pd_msg" = "True" ] && [ "$pd_unchanged" = "True" ] \
  && pass || fail "expected 0|True|True, got ${res_pd}"

echo ""
echo "auto-resume-advance.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
