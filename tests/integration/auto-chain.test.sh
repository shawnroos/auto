#!/usr/bin/env bash
# auto U5 integration test: the dispatch DRIVER chain.
#
# This exercises the REAL tick (lib/tick.py) + dispatcher (lib/dispatcher.py)
# + ledger (lib/ledger.py) wired together exactly as skills/auto/SKILL.md
# instructs the driving agent to wire them. The ONLY injected seams are the
# documented ones:
#   * the BACKEND (a Python object exposing next_plan_step/plan/deepen/
#     review_plan) — injected the same way tick.test.sh injects BoomBackend;
#   * the background-agent verdict self-write — supplied as dispatcher
#     dispatch_batch's `launch_fn`, which calls the REAL ledger.record_verdict
#     synchronously (the documented "agent writes its own verdict atomically"
#     boundary, exercising the real I-1 write chokepoint).
# The tick, the dispatcher's ready/auto/converge, and every ledger write
# are the real code — NOT mocks. ScheduleWakeup is a model tool with no CLI, so
# the "re-arm" is modelled by the driver loop re-invoking dispatch_tick when the
# tick returns action=="rearm" (the literal intent the SKILL says to act on).
#
# Each Python block is run with a QUOTED heredoc (no bash expansion inside the
# Python) and receives the module paths + repo via argv — so the test is immune
# to $-substitution surprises in the embedded Python.
#
# SELF-CONTAINED harness (inline it/pass/fail), mirroring tests/unit/tick.test.sh
# and the run.sh summary-line format ("<name>.test.sh: N passed, M failed").
#
# Scenarios (U5 plan):
#   1. full chain: exits when work predicate met, emits minors report
#   2. findings-closure loop: verdict-returned WITH a blocker -> fix ->
#      re-enqueue -> re-dispatch -> re-review clean -> met==true exits; a
#      `fixed`-with-stale-blocker must NOT exit; deliberate-fail proves the
#      re-review is load-bearing
#   3. auto vs manual seam: a seam-paused tick stops without re-arming and leaves
#      driver=manual; auto flips plan->work via _maybe_seam (the auto branch)
#   4. dispatcher-driven fan-out + in-flight cap resize: wave1 cap=N, wave2 smaller
#   5. goal binding active: a self-pacing run is legible to the U7 Stop hook
#      (predicate present + unmet; driver=self) and the SKILL instructs goal binding

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TICK_PY="${AUTO_ROOT}/lib/tick.py"
ORCH_PY="${AUTO_ROOT}/lib/dispatcher.py"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
SKILL_MD="${AUTO_ROOT}/skills/auto/SKILL.md"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO"

# jq-free JSON field extractor over a one-line JSON string.
jqf() { "$PY" -c "import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])" "$1" "$2"; }

# ════════════════════════════════════════════════════════════════════════════
echo "dispatch-chain.test.sh"

# ─── Scenario 1: full chain exits on work predicate, emits minors report ──────
# A work-loop run that reaches exit: one unit verdict-returned with ONLY a minor
# finding (minors do not gate; the unit is therefore terminal). The driver runs
# the work-loop: ready/auto is a no-op (no pending units), and the REAL tick
# reads exit_predicate_result.met==true off the ledger, flips to done, and emits
# a report whose minor_findings carry the minor for operator promotion (R6).
#
# NOTE: this scenario starts in loop_phase="work". The plan->work / plan->seam
# transition is exercised structurally in Scenario 3; see the gaps noted there
# (the committed engine cannot currently drive a live plan->work flip with
# pending work units, because the plan predicate also requires all_units_terminal
# and nothing writes gaps_open). Starting in work isolates the work-loop exit +
# report path, which is what R5/R6 specify.
it "full chain: work-loop exits on work predicate (met), emits minors report (R6)"
out1="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py, orch_py = sys.argv[1:5]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py); orch=load("dispatcher",orch_py)

run="full-chain"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned",
                           "findings":[{"severity":"minor","note":"nit on U1"}]}],
                   loop_phase="work")

def launch_fn(uid, attempt=0):
    ledger.record_verdict(repo, run, uid, [])

# The driver arms the tick chain (it does NOT pre-decide done — the tick reads
# the cached predicate, flips to done, and emits the report). Each loop turn: run
# a work wave if there is pending work, then fire one tick; act on the intent.
BUDGET=20; report=None
for _ in range(BUDGET):
    L=ledger.read_ledger(repo, run)
    if L.get("loop_phase")=="work":
        ready=orch.ready_units(repo, run)
        if ready:
            orch.dispatch_batch(repo, run, ready, cap=4, launch_fn=launch_fn)
            orch.converge(repo, run)
    intent=tick.dispatch_tick(repo, run)
    if intent["action"]=="stop":
        report=intent.get("report"); break
    # action == "rearm": the driver would issue ScheduleWakeup; here we just loop.

L=ledger.read_ledger(repo, run)
minors=(report or {}).get("minor_findings") or []
print(json.dumps({
    "done": L.get("loop_phase")=="done",
    "met": L.get("exit_predicate_result",{}).get("met"),
    "report_minors": [m.get("note") for m in minors],
}))
PYEOF
)"
done1="$(jqf "$out1" done)"
met1="$(jqf "$out1" met)"
minors1="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['report_minors']))" "$out1")"
if [ "$done1" = "True" ] && [ "$met1" = "True" ] && [ "$minors1" = "nit on U1" ]; then
  pass
else
  fail "done=$done1 met=$met1 minors=[$minors1]"
fi

# ─── Scenario 2: findings-closure loop (the livelock guard) ───────────────────
# Seed a work-loop unit verdict-returned WITH one blocker. Drive the work-loop:
# the tick applies a fix (verdict-returned -> fixed). A `fixed` unit with a STALE
# blocker must NOT let the loop exit (all_units_terminal==false). The driver then
# re-enqueues (fixed -> pending), re-dispatches, and the agent re-reviews with a
# CLEAN verdict -> verdict-returned with no blockers -> met.
#
# GAP THIS SURFACES: per the plan's state-grammar table the TICK owns BOTH
# verdict-returned->fixed AND fixed->pending (re-enqueue). The committed tick
# (advance_work_loop / _ready_fix_unit) only does verdict-returned->fixed; nothing
# re-enqueues a fixed-with-stale-blocker, so a driver relying on the tick alone
# livelocks at `fixed`. We assert the closure REQUIREMENT and bound the loop so
# the gap fails LOUDLY (never hangs).
it "findings-closure: blocker -> fix -> re-enqueue -> re-review clean -> met (a fixed-with-stale-blocker must NOT exit)"
out2="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py, orch_py = sys.argv[1:5]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py); orch=load("dispatcher",orch_py)

run="closure"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned",
                           "findings":[{"severity":"blocker","note":"boom"}]}],
                   loop_phase="work")

def launch_fn(uid, attempt=0):
    ledger.record_verdict(repo, run, uid, [])  # re-dispatched agent self-writes CLEAN

BUDGET=30; no_stale_exit=True; n=0
for _ in range(BUDGET):
    n+=1
    L=ledger.read_ledger(repo, run); pred=L.get("exit_predicate_result",{}); u1=L["units"][0]
    if u1["state"]=="fixed":
        stale=any(f["severity"]=="blocker" for f in u1.get("findings") or [])
        if stale and pred.get("met"):
            no_stale_exit=False
    if pred.get("met"):
        break
    ready=orch.ready_units(repo, run)
    if ready:
        orch.dispatch_batch(repo, run, ready, cap=4, launch_fn=launch_fn)
        orch.converge(repo, run)
    intent=tick.dispatch_tick(repo, run)
    if intent["action"]=="stop":
        break

L=ledger.read_ledger(repo, run)
print(json.dumps({
    "met": L.get("exit_predicate_result",{}).get("met"),
    "final_state": L["units"][0]["state"],
    "no_stale_exit": no_stale_exit,
    "ticks": n, "budget": BUDGET,
}))
PYEOF
)"
met2="$(jqf "$out2" met)"
nostale2="$(jqf "$out2" no_stale_exit)"
ticks2="$(jqf "$out2" ticks)"
budget2="$(jqf "$out2" budget)"
fstate2="$(jqf "$out2" final_state)"
if [ "$nostale2" = "True" ] && [ "$met2" = "True" ]; then
  pass
elif [ "$ticks2" = "$budget2" ] && [ "$met2" != "True" ]; then
  fail "LIVELOCK GAP: loop never closed in ${budget2} ticks (final unit state=${fstate2}). Committed tick does the verdict-to-fixed edge but NOT the fixed-to-pending re-enqueue, so a stale-blocker fixed unit is never re-reviewed. no_stale_exit=${nostale2}"
else
  fail "met=${met2} no_stale_exit=${nostale2} final_state=${fstate2} ticks=${ticks2}"
fi

# Deliberate-fail proof that re-review is load-bearing: with NO re-dispatch (the
# fixed-to-pending closure path absent), the loop MUST NOT exit — the stale
# blocker holds. This proves the positive scenario's exit (if it ever passes)
# comes from a fresh clean verdict, not from `fixed` being treated as terminal.
it "deliberate-fail: WITHOUT re-review, a stale-blocker fixed loop never exits (re-review is load-bearing)"
out2b="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py = sys.argv[1:4]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py)

run="closure-noreenqueue"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned",
                           "findings":[{"severity":"blocker","note":"boom"}]}],
                   loop_phase="work")
BUDGET=12; exited=False
for _ in range(BUDGET):
    if ledger.read_ledger(repo, run).get("exit_predicate_result",{}).get("met"):
        exited=True; break
    if tick.dispatch_tick(repo, run)["action"]=="stop":
        exited=True; break
print(json.dumps({"exited": exited}))
PYEOF
)"
exited2b="$(jqf "$out2b" exited)"
assert_eq "False" "$exited2b"

# Deliberate-fail proof that the ENGINE's fixed->pending re-enqueue is the
# load-bearing edge (distinct from 2b, which proves re-review-via-redispatch).
# This re-runs Scenario 2's FULL setup — WITH launch_fn re-dispatch ready to fire
# — but disables the tick's fixed->pending re-enqueue via the test-only hatch
# CLAUDE_AUTO_TEST_NO_REENQUEUE=1 (schema §7). With the re-enqueue gone the
# unit fixes once (verdict-returned -> fixed) and is NEVER re-enqueued, so it is
# never re-dispatched, the stale blocker holds, and the loop livelocks at `fixed`.
# If the re-enqueue is removed from advance_work_loop, this whole closure goes RED
# in Scenario 2 — this control proves the positive scenario's exit comes from the
# engine's re-enqueue, not from any other path.
it "deliberate-fail: WITH NO_REENQUEUE the engine never re-enqueues -> livelock at fixed (re-enqueue is load-bearing)"
out2c="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_REENQUEUE=1 "$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py, orch_py = sys.argv[1:5]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py); orch=load("dispatcher",orch_py)

run="closure-noreenqueue-engine"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned",
                           "findings":[{"severity":"blocker","note":"boom"}]}],
                   loop_phase="work")

def launch_fn(uid, attempt=0):
    ledger.record_verdict(repo, run, uid, [])  # re-dispatched agent self-writes CLEAN

BUDGET=12; exited=False
for _ in range(BUDGET):
    L=ledger.read_ledger(repo, run)
    if L.get("exit_predicate_result",{}).get("met"):
        exited=True; break
    ready=orch.ready_units(repo, run)
    if ready:
        orch.dispatch_batch(repo, run, ready, cap=4, launch_fn=launch_fn)
        orch.converge(repo, run)
    if tick.dispatch_tick(repo, run)["action"]=="stop":
        exited=True; break
L=ledger.read_ledger(repo, run)
print(json.dumps({"exited": exited, "final_state": L["units"][0]["state"]}))
PYEOF
)"
exited2c="$(jqf "$out2c" exited)"
fstate2c="$(jqf "$out2c" final_state)"
if [ "$exited2c" = "False" ] && [ "$fstate2c" = "fixed" ]; then
  pass
else
  fail "exited=$exited2c final_state=$fstate2c (expected False / fixed: NO_REENQUEUE must livelock at fixed)"
fi

# ─── Scenario 3: auto vs manual seam ──────────────────────────────────────────
# MANUAL: a seam-paused tick (loop_phase="seam") must STOP without re-arming and
# leave driver=manual, seam_paused=true — the true-pause behavior the driver
# surfaces (the real tick "phase==seam" branch). AUTO: at the plan-predicate-met
# moment the engine's _maybe_seam(auto=True) flips plan->work directly (no pause)
# and keeps driver=self. We drive _maybe_seam against a forged met-true plan
# ledger to exercise the auto branch.
#
# GAP: a fully-driven LIVE plan->work / plan->seam transition is currently
# unreachable in committed code — recompute_predicate requires all_units_terminal
# even in plan phase, nothing writes gaps_open from review_plan's return, the
# top-of-tick met-check preempts the seam, and next_plan_step=="done" does not
# transition loop_phase. So we exercise the two transition behaviors at the
# tick/_maybe_seam seam (real engine functions), and report the live-transition
# gaps in the U5 reply.
it "seam (manual): a seam-paused tick stops without re-arming and leaves driver=manual"
out3="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py = sys.argv[1:4]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py)

run="seam-manual"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"pending"}], loop_phase="seam")
intent=tick.dispatch_tick(repo, run)
L=ledger.read_ledger(repo, run)
print(json.dumps({
    "action": intent.get("action"),
    "reason": intent.get("reason"),
    "phase": L.get("loop_phase"),
    "seam_paused": L.get("seam_paused"),
    "driver": (L.get("loop") or {}).get("driver"),
}))
PYEOF
)"
m_action="$(jqf "$out3" action)"
m_reason="$(jqf "$out3" reason)"
m_phase="$(jqf "$out3" phase)"
m_paused="$(jqf "$out3" seam_paused)"
m_driver="$(jqf "$out3" driver)"
if [ "$m_action" = "stop" ] && [ "$m_reason" = "seam-pause" ] && [ "$m_phase" = "seam" ] \
   && [ "$m_paused" = "True" ] && [ "$m_driver" = "manual" ]; then
  pass
else
  fail "action=$m_action reason=$m_reason phase=$m_phase paused=$m_paused driver=$m_driver"
fi

it "seam (auto): the engine's _maybe_seam(auto) flips plan->work directly (no pause), driver stays self"
out3b="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py = sys.argv[1:4]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py)

run="seam-auto"
# A plan ledger forged into "a review_plan round just closed the gaps" state:
# loop_phase="plan", plan_step="review_plan", and a REAL review reported zero gaps
# (set_gaps_open(0)). The phase-aware predicate (schema §3.1) makes plan-met ==
# (gaps_open is not None AND gaps_open==0 AND plan_step=="review_plan") — so this
# honest "review complete, no gaps" state is met and _maybe_seam(auto) fires.
# Bug #5: gaps_open is now NULLABLE — a forged review_plan WITHOUT set_gaps_open
# leaves gaps_open null (no real review reported), and plan-met does NOT fire. We
# must seed the zero-gap count explicitly to model a completed review. (A plan
# ledger before any review runs is NOT met — that is the deepen-loop guard.)
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned","findings":[]}],
                   loop_phase="plan", plan_step="review_plan")
ledger.set_gaps_open(repo, run, 0)  # a real review ran and found zero gaps.
# v0.4.3 producer handshake: the model must have ENUMERATED the plan's work units
# before plan→work transitions (else it'd flip to a work phase with no units).
# This test exercises seam ROUTING (auto-flip vs manual-pause), so stash the
# units the model would have produced; the gate then lets the auto-flip proceed.
ledger.set_enumerated_units(repo, run, "U1", [{"id":"w1","invokes":{}}])
L=ledger.read_ledger(repo, run)
met_plan=L.get("exit_predicate_result",{}).get("met")
# Exercise the auto seam branch directly (the engine function), as the tick would.
out=tick.tick_advance._maybe_seam(repo, run, L, auto=True, advance_result={"advanced":"plan-step"})
L2=ledger.read_ledger(repo, run)
print(json.dumps({
    "met_plan": met_plan,
    "auto_seam": out.get("seam"),
    "phase": L2.get("loop_phase"),
    "driver": (L2.get("loop") or {}).get("driver"),
}))
PYEOF
)"
a_metplan="$(jqf "$out3b" met_plan)"
a_seam="$(jqf "$out3b" auto_seam)"
a_phase="$(jqf "$out3b" phase)"
a_driver="$(jqf "$out3b" driver)"
if [ "$a_metplan" = "True" ] && [ "$a_seam" = "auto-flip-to-work" ] \
   && [ "$a_phase" = "work" ] && [ "$a_driver" = "self" ]; then
  pass
else
  fail "met_plan=$a_metplan auto_seam=$a_seam phase=$a_phase driver=$a_driver"
fi

# ─── Scenario 4: dispatcher-driven fan-out + in-flight cap resize ───────────
# 6 independent pending work units. Wave 1: driver picks cap=4 -> 4 dispatched,
# 2 left pending. Wave 2: driver RESIZES to cap=2 (machine pressure) -> the
# remaining 2 dispatch. Confirms the DRIVER (not the tick) decides batch size,
# per-wave, resizable.
it "fan-out: wave1 cap=4 dispatches 4 of 6; wave2 cap=2 (resized) dispatches the remaining 2"
out4="$("$PY" - "$REPO" "$LEDGER_PY" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, orch_py = sys.argv[1:4]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); orch=load("dispatcher",orch_py)

run="fanout"
units=[{"id":"U%d"%i,"state":"pending"} for i in range(1,7)]
ledger.init_ledger(repo, run, backend="native", units=units, loop_phase="work")

def n_disp():
    return sum(1 for u in ledger.read_ledger(repo, run)["units"] if u["state"]=="dispatched")

r1=orch.ready_units(repo, run)
res1=orch.dispatch_batch(repo, run, r1, cap=4)
d1=n_disp()
r2=orch.ready_units(repo, run)
res2=orch.dispatch_batch(repo, run, r2, cap=2)
d2=n_disp()
print(json.dumps({
    "ready1": len(r1), "n1": sum(1 for _,s in res1 if s=="dispatched"), "d1": d1,
    "ready2": len(r2), "n2": sum(1 for _,s in res2 if s=="dispatched"), "d2": d2,
}))
PYEOF
)"
ready1="$(jqf "$out4" ready1)"; ndw1="$(jqf "$out4" n1)"; daw1="$(jqf "$out4" d1)"
ready2="$(jqf "$out4" ready2)"; ndw2="$(jqf "$out4" n2)"; daw2="$(jqf "$out4" d2)"
if [ "$ready1" = "6" ] && [ "$ndw1" = "4" ] && [ "$daw1" = "4" ] \
   && [ "$ready2" = "2" ] && [ "$ndw2" = "2" ] && [ "$daw2" = "6" ]; then
  pass
else
  fail "ready1=$ready1 n1=$ndw1 d1=$daw1 ready2=$ready2 n2=$ndw2 d2=$daw2"
fi

# ─── Scenario 5: goal binding active (deliberate-stop engaged) ────────────────
# The SKILL guarantees no un-goaled run: a goal/status must be active so the
# engine's (U7) Stop hook holds the session until the loop's met. We don't
# rebuild U7; we verify the engine state the U7 hook reads is present and honest:
#   (a) the ledger's exit_predicate_result is legible (recomputed; met present);
#   (b) while a tick chain is self-pacing, loop.driver == "self" (the live-chain
#       signal the Stop hook reads to know the loop is engaged, not orphaned);
#   (c) SKILL.md prose instructs the driver to ALWAYS set a goal bound to the exit.
it "goal binding: a self-pacing run is legible to the Stop hook (predicate present + unmet; driver=self) and SKILL instructs goal binding"
out5="$("$PY" - "$REPO" "$LEDGER_PY" "$TICK_PY" <<'PYEOF'
import sys, importlib.util, json
repo, ledger_py, tick_py = sys.argv[1:4]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ledger=load("ledger",ledger_py); tick=load("tick",tick_py)

run="goaled"
ledger.init_ledger(repo, run, backend="native",
                   units=[{"id":"U1","state":"verdict-returned",
                           "findings":[{"severity":"blocker","note":"open"}]}],
                   loop_phase="work")
intent=tick.dispatch_tick(repo, run)   # one advance; predicate still unmet -> hook HOLDS
L=ledger.read_ledger(repo, run); pred=L.get("exit_predicate_result",{})
print(json.dumps({
    "action": intent["action"],
    "met_present": "met" in pred,
    "met": pred.get("met"),
    "driver": (L.get("loop") or {}).get("driver"),
}))
PYEOF
)"
g_action="$(jqf "$out5" action)"
g_present="$(jqf "$out5" met_present)"
g_met="$(jqf "$out5" met)"
g_driver="$(jqf "$out5" driver)"
skill_has_goal="$(grep -ci 'goal' "$SKILL_MD" 2>/dev/null || true)"
skill_has_always="$(grep -ci 'no un-goaled run\|ALWAYS' "$SKILL_MD" 2>/dev/null || true)"
if [ "$g_action" = "rearm" ] && [ "$g_present" = "True" ] && [ "$g_met" = "False" ] \
   && [ "$g_driver" = "self" ] && [ "${skill_has_goal:-0}" -gt 0 ] && [ "${skill_has_always:-0}" -gt 0 ]; then
  pass
else
  fail "action=$g_action met_present=$g_present met=$g_met driver=$g_driver skill_goal=${skill_has_goal} skill_always=${skill_has_always}"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "dispatch-chain.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
