#!/usr/bin/env bash
# auto v0.13.0 U5 integration test: the phase sub-agent DISPATCH SEAM.
#
# WHY THIS TEST EXISTS (plan RISK-10 / KTD-1):
# U5 pushes the loop's context-heavy phase work into a sub-agent tree. The
# load-bearing (and counterintuitive) mechanism: spawning a Claude sub-agent is
# a MODEL-side `Agent` tool call. `orchestrator.dispatch_batch` runs inside a
# `python3` subprocess with NO access to that tool — its default `launch_fn` is a
# literal no-op (`orchestrator._default_launch_fn` returns None). So the BOSS
# (a model session) issues the `Agent` spawns itself, in-turn; `dispatch_batch`
# performs ONLY the `pending -> dispatched` ledger transition. `lib/orchestrator.py`
# is unchanged by U5.
#
# This test cannot spawn a real Claude Agent, so it proves the SEAM the runtime
# rests on, deterministically:
#   A. dispatch_batch transitions ready units pending->dispatched, capped, and
#      delegates the (no-op) launch to launch_fn — it never spawns anything itself.
#   B. a unit's `attempt` generation increments on dispatch (Bug #6).
#   C. DURABILITY: a verdict self-written by a SEPARATE PROCESS (simulating the
#      sub-agent, via `python3 lib/ledger.py record-verdict`) is converged by a
#      later read even though the "boss" process that dispatched it has exited.
#      This is the property the whole tree runtime rests on.
#   D. a stale-attempt verdict (from a superseded attempt) is REJECTED
#      (StaleVerdict), not merged (AE3).
#   E. a launch that RAISES marks its unit `stalled` with a `launch-failed`
#      last_error and CONTINUES the wave (the existing Bug #8 guard).
#   F. RISK-7: a long-running-but-alive sub-agent (dispatched, within its
#      stall threshold) is NOT reaped; only a past-threshold one is.
#
# Each scenario asserts the REAL behavior of the shipped engine — U5 adds no
# Python, so a green run proves the production dispatch path (not a stub) carries
# the tree runtime. Deliberate-fail CONTROLS are embedded per scenario (C, D) to
# prove the assertions have teeth and are not passing vacuously
# (feedback_new_tests_need_deliberate_fail_smoke_check).

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

# One shared on-disk repo for the whole file. The durability scenarios (C, D)
# rely on separate `python3` PROCESSES sharing the same ledger through
# $CLAUDE_AUTO_REPO — that is the point: the verdict-writer is not the dispatcher.
REPO="$(mktemp -d)"
export CLAUDE_AUTO_REPO="$REPO"
mkdir -p "$REPO/.claude/auto"

# Seed a run with N work-phase pending units (adapter_op=do_unit, the default
# work-loop op). Runs in one python process; the ledger persists on disk.
seed_run() {
  local run="$1"; local n="$2"; local threshold="${3:-}"
  "$PY" - "$AUTO_ROOT" "$run" "$n" "$threshold" <<'PYEOF'
import sys, os
auto_root, run, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
threshold = sys.argv[4]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
ledger = load("ledger")
repo = os.environ["CLAUDE_AUTO_REPO"]
units = []
for i in range(1, n + 1):
    u = {"id": f"u{i}", "phase": "work",
         "dispatch_context": {"adapter_op": "do_unit"}}
    if threshold:
        u["stall_threshold_seconds"] = int(threshold)
    units.append(u)
ledger.init_ledger(repo, run, adapter="ce", loop_phase="work", units=units)
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
it "KTD-1: dispatch_batch transitions ready units pending->dispatched, CAPPED, and delegates the (no-op) launch — it never spawns"
seed_run A 3
res="$("$PY" - "$AUTO_ROOT" A <<'PYEOF'
import sys, os
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator")
ledger = load("ledger")
repo = os.environ["CLAUDE_AUTO_REPO"]

# The default launcher is a literal no-op: it neither spawns nor records. This
# is KTD-1 — dispatch_batch cannot spawn a Claude Agent from a python subprocess.
default_is_noop = orch._default_launch_fn("u1", 1) is None

# A spy launcher proves dispatch_batch DELEGATES the launch (passing unit_id +
# attempt) rather than doing it itself. dispatch_batch's own body performs the
# ledger transition ONLY.
spy = []
def launch_fn(uid, attempt):
    spy.append((uid, attempt))

ready = orch.ready_units(repo, run)
results = orch.dispatch_batch(repo, run, ready, cap=2, launch_fn=launch_fn)

led = ledger.read_ledger(repo, run)
by = {u["id"]: u for u in led["units"]}
statuses = ",".join(s for _, s in results)
states = ",".join(f'{u}:{by[u]["state"]}' for u in ("u1", "u2", "u3"))
print("ready=%s|status=%s|states=%s|spy=%s|noop=%s" % (
    ",".join(ready), statuses, states,
    ",".join(f"{u}@{a}" for u, a in spy), default_is_noop))
PYEOF
)"
# cap=2: u1,u2 dispatched; u3 eligible but over-cap stays pending. The spy sees
# exactly the two dispatched units (with their bumped attempt=1). The default
# launcher is a no-op.
exp='ready=u1,u2,u3|status=dispatched,dispatched,rejected:over-cap|states=u1:dispatched,u2:dispatched,u3:pending|spy=u1@1,u2@1|noop=True'
assert_eq "$exp" "$res"

# ─────────────────────────────────────────────────────────────────────────────
it "Bug #6: a unit's attempt generation increments on dispatch (0 -> 1)"
seed_run B 1
res="$("$PY" - "$AUTO_ROOT" B <<'PYEOF'
import sys, os
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator"); ledger = load("ledger")
repo = os.environ["CLAUDE_AUTO_REPO"]
before = ledger.read_ledger(repo, run)["units"][0].get("attempt", 0)
orch.dispatch_batch(repo, run, ["u1"], cap=1)
after = ledger.read_ledger(repo, run)["units"][0].get("attempt", 0)
print("%s->%s" % (before, after))
PYEOF
)"
assert_eq "0->1" "$res"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario C — DURABILITY (the property the tree runtime rests on).
# The dispatch happens in one python process that EXITS (the boss's turn ends).
# A SEPARATE process (the simulated sub-agent) self-writes the verdict via the
# `record-verdict` CLI verb. A THIRD process converges it. If convergence read
# from sub-agent return text instead of the ledger, this would be impossible.
seed_run C 1
# Process 1: the boss dispatches u1 (attempt -> 1), then EXITS.
"$PY" - "$AUTO_ROOT" C <<'PYEOF' >/dev/null
import sys, os
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator")
repo = os.environ["CLAUDE_AUTO_REPO"]
orch.dispatch_batch(repo, run, ["u1"], cap=1)
PYEOF

it "durability control: BEFORE the sub-agent writes, converge shows the unit in_flight (not completed)"
res_before="$("$PY" "$AUTO_ROOT/lib/orchestrator.py" converge "$CLAUDE_AUTO_REPO" C 2>/dev/null | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print("in_flight=%s completed=%s" % (d["in_flight"], d["completed"]))')"
assert_eq "in_flight=['u1'] completed=[]" "$res_before"

it "durability: a verdict self-written by a SEPARATE process converges on a later read (boss already exited)"
# Process 2: the simulated sub-agent self-writes its verdict for attempt 1.
"$PY" "$AUTO_ROOT/lib/ledger.py" record-verdict C u1 '[]' 1 >/dev/null 2>&1
vrc=$?
# Process 3: a fresh converge reads the durable verdict off disk.
res_after="$("$PY" "$AUTO_ROOT/lib/orchestrator.py" converge "$CLAUDE_AUTO_REPO" C 2>/dev/null | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print("rc=%s in_flight=%s completed=%s" % ("'"$vrc"'", d["in_flight"], d["completed"]))')"
assert_eq "rc=0 in_flight=[] completed=['u1']" "$res_after"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario D — stale-attempt verdict REJECTED (AE3). Dispatch bumps attempt to 1;
# a verdict written for attempt 0 (a superseded attempt) is rejected, not merged.
seed_run D 1
"$PY" - "$AUTO_ROOT" D <<'PYEOF' >/dev/null
import sys, os
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator")
repo = os.environ["CLAUDE_AUTO_REPO"]
orch.dispatch_batch(repo, run, ["u1"], cap=1)  # attempt -> 1
PYEOF

it "stale verdict (attempt 0 < current 1) is REJECTED (StaleVerdict) — non-zero exit, ledger unchanged"
"$PY" "$AUTO_ROOT/lib/ledger.py" record-verdict D u1 '[]' 0 >/dev/null 2>&1
stale_rc=$?
state_after="$("$PY" "$AUTO_ROOT/lib/ledger.py" read "$CLAUDE_AUTO_REPO" D 2>/dev/null | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print(d["units"][0]["state"])')"
# rejected: non-zero exit AND the unit stays `dispatched` (no verdict merged).
if [ "$stale_rc" -ne 0 ] && [ "$state_after" = "dispatched" ]; then pass; else
  fail "expected non-zero rc + state 'dispatched', got rc=$stale_rc state='$state_after'"; fi

it "deliberate-fail control: a CURRENT-attempt verdict (attempt 1) is accepted — proves the rejection is staleness-specific"
"$PY" "$AUTO_ROOT/lib/ledger.py" record-verdict D u1 '[]' 1 >/dev/null 2>&1
fresh_rc=$?
state_fresh="$("$PY" "$AUTO_ROOT/lib/ledger.py" read "$CLAUDE_AUTO_REPO" D 2>/dev/null | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print(d["units"][0]["state"])')"
if [ "$fresh_rc" -eq 0 ] && [ "$state_fresh" = "verdict-returned" ]; then pass; else
  fail "expected rc=0 + state 'verdict-returned', got rc=$fresh_rc state='$state_fresh'"; fi

# ─────────────────────────────────────────────────────────────────────────────
it "Bug #8: a launch that RAISES marks its unit stalled (last_error.call=launch) and CONTINUES the wave"
seed_run E 3
res="$("$PY" - "$AUTO_ROOT" E <<'PYEOF'
import sys, os
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator"); ledger = load("ledger")
repo = os.environ["CLAUDE_AUTO_REPO"]
def launch_fn(uid, attempt):
    if uid == "u2":
        raise RuntimeError("spawn boom")
results = orch.dispatch_batch(repo, run, ["u1", "u2", "u3"], cap=3, launch_fn=launch_fn)
led = ledger.read_ledger(repo, run)
by = {u["id"]: u for u in led["units"]}
u2 = by["u2"]
call = (u2.get("last_error") or {}).get("call")
u2status = next(s for uid, s in results if uid == "u2")
print("u1=%s u2=%s(%s) u3=%s status2=%s" % (
    by["u1"]["state"], u2["state"], call, by["u3"]["state"],
    u2status.split(":")[0]))
PYEOF
)"
# u2's launch raised: it is stalled with a launch last_error and a launch-failed
# status; u1 and u3 (before and AFTER the raise) still dispatched — the wave
# was not abandoned.
assert_eq "u1=dispatched u2=stalled(launch) u3=dispatched status2=launch-failed" "$res"

# ─────────────────────────────────────────────────────────────────────────────
it "RISK-7: a long-running-but-alive sub-agent (within stall threshold) is NOT reaped; past-threshold IS (age > threshold)"
seed_run F 1 3600
res="$("$PY" - "$AUTO_ROOT" F <<'PYEOF'
import sys, os
from datetime import timedelta
auto_root, run = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("orchestrator"); ledger = load("ledger")
ta = load("tick_advance")
repo = os.environ["CLAUDE_AUTO_REPO"]
orch.dispatch_batch(repo, run, ["u1"], cap=1)  # dispatched_at = now
led = ledger.read_ledger(repo, run)
dispatched_at = led["units"][0]["dispatched_at"]
base = ledger.parse_iso(dispatched_at)

# ALIVE: 60s in, far below the unit's 3600s threshold -> not stalled.
alive = base + timedelta(seconds=60)
_, halted_alive, confirmed_alive = ta.detect_and_halt_stalled(repo, run, led, alive)
state_alive = ledger.read_ledger(repo, run)["units"][0]["state"]

# PAST THRESHOLD: 3601s in (age > 3600) -> stalled.
led2 = ledger.read_ledger(repo, run)
dead = base + timedelta(seconds=3601)
_, halted_dead, confirmed_dead = ta.detect_and_halt_stalled(repo, run, led2, dead)
state_dead = ledger.read_ledger(repo, run)["units"][0]["state"]

print("alive: confirmed=%s state=%s | dead: confirmed=%s state=%s" % (
    confirmed_alive, state_alive, confirmed_dead, state_dead))
PYEOF
)"
assert_eq "alive: confirmed=[] state=dispatched | dead: confirmed=['u1'] state=stalled" "$res"

# ─── G. WIRING GUARD: the dispatch contract actually arms the backstop ───────
# The ownership-set backstop (U8) only reaches a phase sub-agent if that agent
# calls `register-session` on start — and that call is authored by the §4.8
# dispatch prompt, not by any Python. tree-ownership.test.sh proves the HOOK
# gates a registered session, but it injects the registration via a test helper;
# it cannot catch the production step going missing. This guard does: if §4.8's
# prompt contract stops telling the sub-agent to register itself, the backstop is
# silently dark in the tree and this fails. (Adversarial review, v0.13.0.)
it_dispatch_contract_names_register_session() {
  local skill="${AUTO_ROOT}/skills/auto/SKILL.md"
  if grep -q 'register-session <run>' "$skill" \
     && grep -qi 'FIRST line of every phase sub-agent prompt' "$skill" \
     && grep -q 'CLAUDE_CODE_SESSION_ID` from the env' "$skill"; then
    PASS=$((PASS + 1)); printf "  ok %d - §4.8 dispatch contract arms the backstop (register-session, own session id)\n" "$PASS"
  else
    FAIL=$((FAIL + 1)); printf "  not ok - §4.8 dispatch contract no longer tells the sub-agent to register-session: backstop dark in the tree\n"
  fi
}
it_dispatch_contract_names_register_session

# ─────────────────────────────────────────────────────────────────────────────
printf "%s: %d passed, %d failed\n" "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
