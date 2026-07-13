#!/usr/bin/env bash
# auto U10 unit test: lib/dispatcher.py — the agent-driven fan-out
# layer. It exposes THREE operations against the ledger schema contract:
#
#   * ready_steps(repo, run)                 -> dispatchable-now step ids (READER)
#   * dispatch_batch(repo, run, ids, cap, *, launch_fn=None)
#                                            -> pending->dispatched + launch (WRITER)
#   * converge(repo, run)                    -> reconcile/READ over durable state
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/ledger.test.sh and
# tests/unit/pulse.test.sh. It does NOT source claude-modes' test-helpers
# (cross-plugin coupling forbidden) nor auto shared helpers (U2's,
# not yet present). When U2 lands, this file may migrate to them.
#
# Scenarios (mapped to the U10 plan, tested against dispatcher.py's ACTUAL
# surface — ready_steps / dispatch_batch / converge):
#   1. ready_steps: 4 independent pending steps -> all returned
#   2. dependency gating (the "satisfied" definition): U_b depends on U_a;
#      U_a verdict-returned WITH an open blocker -> ready_steps EXCLUDES U_b;
#      clear the finding (still verdict-returned, no blockers) -> U_b appears;
#      AND the literal plan path: U_a -> fixed (no blockers) -> U_b appears
#   3. stalled-ancestor: U_a stalled, U_b depends on U_a -> ready excludes U_b
#   4. dispatch_batch cap: 10 ready, cap=3 -> exactly 3 dispatched (with
#      dispatched_at); next call picks the next wave
#   5. in-flight resize: dispatch cap=8 (of 16), then cap=2 next wave -> only 2
#   6. dispatch idempotency: dispatch_batch on an already-dispatched step ->
#      rejected, no second launch, no duplicate/changed dispatched_at
#   7. VERDICT SURVIVES SESSION DEATH: a separate process self-writes a verdict
#      AFTER the driving session "exited"; a fresh converge READS it and does NOT
#      treat it as in-flight (re-dispatchable). Deliberate-fail control proves
#      the test is real (without the self-write, converge leaves it in-flight)
#   8. concurrent self-write: two verdicts written concurrently via flock ->
#      neither clobbers; predicate (blockers/majors) correct after both

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCH_PY="${AUTO_ROOT}/lib/dispatcher.py"
ORCH_SH="${AUTO_ROOT}/lib/dispatcher.sh"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
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

# ── tiny python helpers ────────────────────────────────────────────────────
# ledger_init <run> <json-steps> [backend] [phase]  — create a ledger.
ledger_init() {
  local run="$1" steps_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$backend" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, backend, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, backend=backend, steps=json.loads(steps_json), loop_phase=phase)
PYEOF
}

# ledger_field <run> <python-expr-on-ledger-named-L>  — print a value.
ledger_field() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, expr, ledger_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L = m.read_ledger(repo, run)
print(eval(expr))
PYEOF
}

# orch_ready <run>  — print ready step ids, comma-joined (declaration order).
orch_ready() {
  local run="$1"
  "$PY" - "$REPO" "$run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
print(",".join(o.ready_steps(repo, run)))
PYEOF
}

# ledger_transition <run> <step> <state>  — grammar transition via ledger.py.
ledger_transition() {
  local run="$1" step="$2" state="$3"
  "$PY" - "$REPO" "$run" "$step" "$state" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, step, state, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, step, state)
PYEOF
}

# ledger_verdict <run> <step> <findings-json>  — record_verdict via ledger.py.
ledger_verdict() {
  local run="$1" step="$2" findings="$3"
  "$PY" - "$REPO" "$run" "$step" "$findings" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, step, findings, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, step, json.loads(findings))
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "dispatcher.test.sh"

# ─── Scenario 1: ready_steps — 4 independent pending steps -> all returned ────
it "ready_steps: 4 independent pending steps -> all four returned (declaration order)"
ledger_init "ready-4" \
  '[{"id":"U1","state":"pending"},{"id":"U2","state":"pending"},{"id":"U3","state":"pending"},{"id":"U4","state":"pending"}]' \
  >/dev/null 2>&1
ready="$(orch_ready "ready-4")"
assert_eq "U1,U2,U3,U4" "$ready"

# ─── Scenario 2: dependency gating — the "satisfied" definition ───────────────
# U_b depends on U_a. While U_a is verdict-returned WITH an open blocker, U_a is
# NOT satisfied -> ready_steps must EXCLUDE U_b (U_a itself is not pending, so it
# is never ready either). Clearing the finding (re-verdict to []) keeps U_a
# verdict-returned but now satisfied -> U_b becomes ready.
it "dependency gating: verdict-returned U_a WITH an open blocker -> ready EXCLUDES dependent U_b"
ledger_init "dep-gate" \
  '[{"id":"Ua","state":"pending"},{"id":"Ub","state":"pending","depends_on":["Ua"]}]' \
  >/dev/null 2>&1
# Drive Ua: pending -> dispatched -> verdict-returned(blocker).
ledger_transition "dep-gate" "Ua" "dispatched" >/dev/null 2>&1
ledger_verdict "dep-gate" "Ua" '[{"severity":"blocker","note":"open"}]' >/dev/null 2>&1
ready_blocked="$(orch_ready "dep-gate")"
# Ua is verdict-returned (not pending -> not ready); Ub gated by unsatisfied Ua.
assert_eq "" "$ready_blocked"

it "dependency gating: re-verdict U_a to no findings (still verdict-returned, satisfied) -> U_b appears"
ledger_verdict "dep-gate" "Ua" '[]' >/dev/null 2>&1
ready_unblocked="$(orch_ready "dep-gate")"
assert_eq "Ub" "$ready_unblocked"

it "dependency gating (literal plan path): U_a -> fixed (no blockers) -> U_b appears"
ledger_init "dep-fixed" \
  '[{"id":"Ua","state":"pending"},{"id":"Ub","state":"pending","depends_on":["Ua"]}]' \
  >/dev/null 2>&1
# pending -> dispatched -> verdict-returned([]) -> fixed (the closure path).
ledger_transition "dep-fixed" "Ua" "dispatched" >/dev/null 2>&1
ledger_verdict "dep-fixed" "Ua" '[]' >/dev/null 2>&1
ledger_transition "dep-fixed" "Ua" "fixed" >/dev/null 2>&1
ready_fixed="$(orch_ready "dep-fixed")"
assert_eq "Ub" "$ready_fixed"

# ─── Scenario 3: stalled-ancestor gate ────────────────────────────────────────
# U_a stalled, U_b depends on U_a -> ready_steps excludes U_b (the transitive
# stalled-ancestor gate; U_a is not pending so is not ready either).
it "stalled-ancestor: stalled U_a with dependent U_b -> ready excludes U_b"
ledger_init "stall-gate" \
  '[{"id":"Ua","state":"pending"},{"id":"Ub","state":"pending","depends_on":["Ua"]}]' \
  >/dev/null 2>&1
ledger_transition "stall-gate" "Ua" "dispatched" >/dev/null 2>&1
ledger_transition "stall-gate" "Ua" "stalled" >/dev/null 2>&1
ready_stalled="$(orch_ready "stall-gate")"
assert_eq "" "$ready_stalled"

# ─── Scenario 4: dispatch_batch cap — 10 ready, cap=3 -> exactly 3, then next ──
it "dispatch_batch cap: 10 ready, cap=3 -> exactly 3 dispatched (with dispatched_at); next call takes the next wave"
ledger_init "cap-run" \
  "$("$PY" -c 'import json;print(json.dumps([{"id":f"U{i}","state":"pending"} for i in range(1,11)]))')" \
  >/dev/null 2>&1
wave="$("$PY" - "$REPO" "cap-run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
# Wave 1: 10 ready, cap=3.
r1 = o.ready_steps(repo, run)
res1 = o.dispatch_batch(repo, run, r1, 3)
d1 = [uid for uid, st in res1 if st == "dispatched"]
# Wave 2: from the remaining pending, cap=3 again -> the next three.
r2 = o.ready_steps(repo, run)
res2 = o.dispatch_batch(repo, run, r2, 3)
d2 = [uid for uid, st in res2 if st == "dispatched"]
print(json.dumps({"d1": d1, "d2": d2, "r2_len": len(r2)}))
PYEOF
)"
d1_count="$("$PY" -c "import json,sys;print(len(json.loads(sys.argv[1])['d1']))" "$wave")"
d2_count="$("$PY" -c "import json,sys;print(len(json.loads(sys.argv[1])['d2']))" "$wave")"
r2_len="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['r2_len'])" "$wave")"
# After wave 1: exactly 3 dispatched; remaining ready == 7 (the 3 are now
# 'dispatched', not pending). Wave 2 dispatches the next 3.
# Each dispatched step must have a non-null dispatched_at.
disp_at_nulls="$(ledger_field "cap-run" 'sum(1 for u in L["steps"] if u["state"]=="dispatched" and u["dispatched_at"] is None)')"
dispatched_total="$(ledger_field "cap-run" 'sum(1 for u in L["steps"] if u["state"]=="dispatched")')"
if [ "$d1_count" = "3" ] && [ "$r2_len" = "7" ] && [ "$d2_count" = "3" ] \
   && [ "$dispatched_total" = "6" ] && [ "$disp_at_nulls" = "0" ]; then
  pass
else
  fail "d1=$d1_count r2_len=$r2_len d2=$d2_count dispatched_total=$dispatched_total disp_at_nulls=$disp_at_nulls (expected 3/7/3/6/0)"
fi

# ─── Scenario 5: in-flight resize — cap=8 then cap=2 (shrinking cap) ───────────
it "in-flight resize: cap=8 of 16 pending dispatches 8; next wave cap=2 dispatches only 2"
ledger_init "resize-run" \
  "$("$PY" -c 'import json;print(json.dumps([{"id":f"U{i}","state":"pending"} for i in range(1,17)]))')" \
  >/dev/null 2>&1
resize="$("$PY" - "$REPO" "resize-run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
# Wave 1: cap=8.
r1 = o.ready_steps(repo, run)
n1 = len([1 for uid, st in o.dispatch_batch(repo, run, r1, 8) if st == "dispatched"])
# Wave 2: cap shrinks to 2.
r2 = o.ready_steps(repo, run)
n2 = len([1 for uid, st in o.dispatch_batch(repo, run, r2, 2) if st == "dispatched"])
print(json.dumps({"n1": n1, "n2": n2, "r1_len": len(r1), "r2_len": len(r2)}))
PYEOF
)"
n1="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['n1'])" "$resize")"
n2="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['n2'])" "$resize")"
r1_len="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['r1_len'])" "$resize")"
r2_len="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['r2_len'])" "$resize")"
total_dispatched="$(ledger_field "resize-run" 'sum(1 for u in L["steps"] if u["state"]=="dispatched")')"
# 16 ready, dispatch 8; remaining ready 8; cap shrinks to 2 -> dispatch 2 (6
# remain pending). Total dispatched == 10.
if [ "$r1_len" = "16" ] && [ "$n1" = "8" ] && [ "$r2_len" = "8" ] && [ "$n2" = "2" ] \
   && [ "$total_dispatched" = "10" ]; then
  pass
else
  fail "r1_len=$r1_len n1=$n1 r2_len=$r2_len n2=$n2 total_dispatched=$total_dispatched (expected 16/8/8/2/10)"
fi

# ─── Scenario 6: dispatch idempotency — already-dispatched step is rejected ────
# Instrument launch_fn to count launches. First dispatch_batch launches U1 once
# and stamps dispatched_at. A second dispatch_batch on the SAME (now-dispatched)
# step must REJECT it (rejected:not-pending(dispatched)), launch nothing more,
# and leave dispatched_at byte-identical (no second stamp).
it "dispatch idempotency: re-dispatching an already-dispatched step -> rejected, no second launch, dispatched_at unchanged"
ledger_init "idem-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
idem="$("$PY" - "$REPO" "idem-run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)

launches = []
def counting_launch(uid, attempt=0):
    launches.append(uid)

# First dispatch: pending -> dispatched, one launch.
res1 = o.dispatch_batch(repo, run, ["U1"], 4, launch_fn=counting_launch)
disp_at_1 = o.read_ledger(repo, run)["steps"][0]["dispatched_at"]

# Second dispatch on the now-dispatched step: must be rejected (idempotency),
# no second launch, dispatched_at unchanged.
res2 = o.dispatch_batch(repo, run, ["U1"], 4, launch_fn=counting_launch)
disp_at_2 = o.read_ledger(repo, run)["steps"][0]["dispatched_at"]

print(json.dumps({
    "res1": res1,
    "res2_status": res2[0][1] if res2 else None,
    "launch_count": len(launches),
    "disp_at_stable": disp_at_1 == disp_at_2 and disp_at_1 is not None,
}))
PYEOF
)"
res1_status="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['res1'][0][1])" "$idem")"
res2_status="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['res2_status'])" "$idem")"
launch_count="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['launch_count'])" "$idem")"
disp_at_stable="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['disp_at_stable'])" "$idem")"
if [ "$res1_status" = "dispatched" ] \
   && printf '%s' "$res2_status" | grep -q "^rejected:not-pending(dispatched)$" \
   && [ "$launch_count" = "1" ] && [ "$disp_at_stable" = "True" ]; then
  pass
else
  fail "res1=$res1_status res2=$res2_status launch_count=$launch_count disp_at_stable=$disp_at_stable (expected dispatched / rejected:not-pending(dispatched) / 1 / True)"
fi

# ─── Scenario 6b: backend_op validation (U12) ─────────────────────────────────
# dispatch_batch rejects a step whose declared backend_op is not in
# VALID_BACKEND_OPS — the op must NOT flow to launch. The backend_op is injected
# on `dispatch_context` (the durable home: _normalize_step preserves
# dispatch_context but drops raw `invokes`). Uvalid carries a valid op (do_step)
# and is the deliberate-fail CONTROL: same injected shape, valid value -> it
# dispatches and launches, proving the guard keys on the op VALUE, not on the
# step's presence.
it "backend_op: unknown op -> rejected:bad-backend-op, not launched, stays pending; valid op dispatches (control)"
ledger_init "backend-op" \
  '[{"id":"Uvalid","state":"pending","dispatch_context":{"backend_op":"do_step"}},{"id":"Ubad","state":"pending","dispatch_context":{"backend_op":"totally-bogus-op"}}]' \
  >/dev/null 2>&1
aop="$("$PY" - "$REPO" "backend-op" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)

launches = []
def counting_launch(uid, attempt=0):
    launches.append(uid)

res = dict(o.dispatch_batch(repo, run, ["Uvalid", "Ubad"], 4, launch_fn=counting_launch))
led = o.read_ledger(repo, run)
states = {u["id"]: u["state"] for u in led["steps"]}
print(json.dumps({
    "valid_status": res.get("Uvalid"),
    "bad_status": res.get("Ubad"),
    "bad_launched": "Ubad" in launches,
    "bad_state": states.get("Ubad"),
    "valid_launched": "Uvalid" in launches,
    "valid_state": states.get("Uvalid"),
    "valid_in_ops": "do_step" in o.VALID_BACKEND_OPS,
}))
PYEOF
)"
vstat="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['valid_status'])" "$aop")"
bstat="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['bad_status'])" "$aop")"
blaunch="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['bad_launched'])" "$aop")"
bstate="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['bad_state'])" "$aop")"
vlaunch="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['valid_launched'])" "$aop")"
vstate="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['valid_state'])" "$aop")"
if [ "$vstat" = "dispatched" ] && [ "$bstat" = "rejected:bad-backend-op" ] \
   && [ "$blaunch" = "False" ] && [ "$bstate" = "pending" ] \
   && [ "$vlaunch" = "True" ] && [ "$vstate" = "dispatched" ]; then
  pass
else
  fail "valid=$vstat bad=$bstat bad_launched=$blaunch bad_state=$bstate valid_launched=$vlaunch valid_state=$vstate (expected dispatched / rejected:bad-backend-op / False / pending / True / dispatched)"
fi

# ─── Scenario 7: VERDICT SURVIVES SESSION DEATH ───────────────────────────────
# The load-bearing property. A background agent self-writes its verdict to the
# durable ledger AFTER the driving session has exited. A FRESH converge (a
# resumed session) reads the verdict straight off disk and does NOT re-dispatch
# the step (it is 'completed', not 'in_flight').
it "verdict survives session death: a separately-written verdict is read by a fresh converge (step completed, NOT in-flight)"
ledger_init "survive-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
# Driving session dispatches U1 (now 'dispatched' / in-flight), then "exits".
"$PY" - "$REPO" "survive-run" "$ORCH_PY" <<'PYEOF' >/dev/null 2>&1
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
o.dispatch_batch(repo, run, ["U1"], 4)
PYEOF
# A SEPARATE process (the background agent, outliving the driver) self-writes a
# clean verdict via ledger.record_verdict.
ledger_verdict "survive-run" "U1" '[]' >/dev/null 2>&1
# A FRESH converge (resumed session) reads durable state off disk.
survive="$("$PY" - "$REPO" "survive-run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
c = o.converge(repo, run)
# A resumed session would re-dispatch only steps still 'pending'/ready. After a
# durable verdict, U1 is verdict-returned -> completed, NOT in_flight, and NOT
# ready (never re-dispatchable from converge's read).
print(json.dumps({
    "in_flight": c["in_flight"],
    "completed": c["completed"],
    "ready_after": o.ready_steps(repo, run),
}))
PYEOF
)"
in_flight="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['in_flight']))" "$survive")"
completed="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['completed']))" "$survive")"
ready_after="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['ready_after']))" "$survive")"
if [ "$completed" = "U1" ] && [ "$in_flight" = "" ] && [ "$ready_after" = "" ]; then
  pass
else
  fail "completed=[$completed] in_flight=[$in_flight] ready_after=[$ready_after] (expected U1 / empty / empty)"
fi

it "deliberate-fail control: WITHOUT the self-written verdict, the dispatched step stays in-flight (re-dispatchable) — proves S7 measures the verdict, not a tautology"
ledger_init "survive-control" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
# Same dispatch, but the background agent NEVER self-writes (session died before
# the verdict landed).
"$PY" - "$REPO" "survive-control" "$ORCH_PY" <<'PYEOF' >/dev/null 2>&1
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
o.dispatch_batch(repo, run, ["U1"], 4)
PYEOF
control="$("$PY" - "$REPO" "survive-control" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
c = o.converge(repo, run)
print(json.dumps({"in_flight": c["in_flight"], "completed": c["completed"]}))
PYEOF
)"
c_in_flight="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['in_flight']))" "$control")"
c_completed="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['completed']))" "$control")"
# Without the verdict, U1 is still 'dispatched' -> in_flight, NOT completed.
if [ "$c_in_flight" = "U1" ] && [ "$c_completed" = "" ]; then
  pass
else
  fail "in_flight=[$c_in_flight] completed=[$c_completed] (expected U1 / empty) — control did not go RED, so S7 is not meaningful"
fi

# ─── Scenario 8: concurrent self-write — flock serializes the RMW ─────────────
# Two background agents on two distinct steps self-write verdicts CONCURRENTLY
# (the bash `&` + PYEOF race pattern from ledger.test.sh). The flock serializes
# the full read-modify-write, so neither clobbers the other: both findings
# persist and the recomputed predicate (blockers/majors) reflects BOTH.
it "concurrent self-write: two agents record_verdict at once -> neither clobbers, predicate reflects both (flock serializes RMW)"
ledger_init "concurrent-run" \
  '[{"id":"U1","state":"dispatched","dispatched_at":"2026-05-21T14:00:00Z"},{"id":"U2","state":"dispatched","dispatched_at":"2026-05-21T14:00:00Z"}]' \
  >/dev/null 2>&1
# Two concurrent self-writers: U1 gets a blocker, U2 gets a major. A widened
# race window (sleep inside the locked RMW) maximizes the chance a missing lock
# would clobber; with the lock both must land.
verdict_writer() {
  # verdict_writer <step> <severity>
  "$PY" - "$REPO" "concurrent-run" "$1" "$2" "$LEDGER_PY" <<'PYEOF' &
import sys, importlib.util, time
repo, run, step, severity, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# record_verdict routes through the single locked RMW chokepoint; the sleep
# below only widens the OS-scheduling window between the two processes.
time.sleep(0.02)
m.record_verdict(repo, run, step, [{"severity": severity, "note": step}])
PYEOF
}
verdict_writer "U1" "blocker"
p1=$!
verdict_writer "U2" "major"
p2=$!
wait "$p1"; wait "$p2"
# Both verdicts must have landed: U1 verdict-returned w/ a blocker finding,
# U2 verdict-returned w/ a major finding; predicate counts reflect BOTH.
st_u1="$(ledger_field "concurrent-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U1")')"
st_u2="$(ledger_field "concurrent-run" 'next(u["state"] for u in L["steps"] if u["id"]=="U2")')"
sev_u1="$(ledger_field "concurrent-run" 'next((f["severity"] for u in L["steps"] if u["id"]=="U1" for f in u["findings"]), "NONE")')"
sev_u2="$(ledger_field "concurrent-run" 'next((f["severity"] for u in L["steps"] if u["id"]=="U2" for f in u["findings"]), "NONE")')"
blockers="$(ledger_field "concurrent-run" 'L["exit_predicate_result"]["blockers"]')"
majors="$(ledger_field "concurrent-run" 'L["exit_predicate_result"]["majors"]')"
if [ "$st_u1" = "verdict-returned" ] && [ "$st_u2" = "verdict-returned" ] \
   && [ "$sev_u1" = "blocker" ] && [ "$sev_u2" = "major" ] \
   && [ "$blockers" = "1" ] && [ "$majors" = "1" ]; then
  pass
else
  fail "st_u1=$st_u1 st_u2=$st_u2 sev_u1=$sev_u1 sev_u2=$sev_u2 blockers=$blockers majors=$majors (expected verdict-returned x2 / blocker / major / 1 / 1)"
fi

# ─── Scenario 9: Bug #8 — a launch raise does not abandon the wave ────────────
# launch_fn raises on step 2 of 4. The guarded launch must: (a) still process
# steps 1, 3, 4 (they dispatch + launch normally), (b) record step 2 as
# launch-failed and mark it `stalled` with a launch last_error (NOT a phantom
# `dispatched` with no agent), and (c) NOT propagate the raise / abandon the batch.
it "Bug #8: launch_fn raises on step 2 of 4 -> steps 1,3,4 still dispatched, step 2 recorded launch-failed (stalled), batch not abandoned"
ledger_init "launch-fail" \
  '[{"id":"U1","state":"pending"},{"id":"U2","state":"pending"},{"id":"U3","state":"pending"},{"id":"U4","state":"pending"}]' \
  >/dev/null 2>&1
lf="$("$PY" - "$REPO" "launch-fail" "$ORCH_PY" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py, ledger_py = sys.argv[1:5]
ospec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(ospec); ospec.loader.exec_module(o)
lspec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(lspec); lspec.loader.exec_module(m)

launched = []
def flaky_launch(uid, attempt=0):
    if uid == "U2":
        raise RuntimeError("agent spawn failed for U2")
    launched.append(uid)

# A SINGLE dispatch_batch over all 4, cap high enough to take them all. U2's
# launch raises; the wave must continue.
res = o.dispatch_batch(repo, run, ["U1","U2","U3","U4"], 4, launch_fn=flaky_launch)
status = {uid: st for uid, st in res}
led = m.read_ledger(repo, run)
states = {u["id"]: u["state"] for u in led["steps"]}
u2 = next(u for u in led["steps"] if u["id"] == "U2")
print(json.dumps({
    "launched": sorted(launched),
    "u1_status": status.get("U1"),
    "u2_status_prefix": (status.get("U2") or "").split(":")[0],
    "u3_status": status.get("U3"),
    "u4_status": status.get("U4"),
    "u2_state": states.get("U2"),
    "u1_state": states.get("U1"),
    "u2_err_call": (u2.get("last_error") or {}).get("call"),
    "n_results": len(res),
}))
PYEOF
)"
launched="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['launched']))" "$lf")"
u1s="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u1_status'])" "$lf")"
u2sp="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u2_status_prefix'])" "$lf")"
u3s="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u3_status'])" "$lf")"
u4s="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u4_status'])" "$lf")"
u2state="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u2_state'])" "$lf")"
u1state="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u1_state'])" "$lf")"
u2errcall="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['u2_err_call'])" "$lf")"
nres="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['n_results'])" "$lf")"
# Steps 1,3,4 launched + dispatched; U2 launch-failed -> stalled w/ a launch
# last_error (not a phantom dispatched); all 4 in the results (batch not abandoned).
if [ "$launched" = "U1,U3,U4" ] && [ "$u1s" = "dispatched" ] && [ "$u2sp" = "launch-failed" ] \
   && [ "$u3s" = "dispatched" ] && [ "$u4s" = "dispatched" ] && [ "$u2state" = "stalled" ] \
   && [ "$u1state" = "dispatched" ] && [ "$u2errcall" = "launch" ] && [ "$nres" = "4" ]; then
  pass
else
  fail "launched=[$launched] u1=$u1s u2=$u2sp u3=$u3s u4=$u4s u2state=$u2state u1state=$u1state u2errcall=$u2errcall nres=$nres (expected U1,U3,U4 / dispatched / launch-failed / dispatched / dispatched / stalled / dispatched / launch / 4)"
fi

it "Bug #8 deliberate-fail control: the injected launch_fn genuinely raises on U2 (so the wave-survival above is real guarding, not a benign no-op)"
# Call the launcher directly OUTSIDE dispatch_batch's guard: it MUST propagate on
# U2. Proves the prior test's clean continuation came from the try/except, not a
# silently-benign launcher.
raised8="$("$PY" - <<'PYEOF'
def flaky_launch(uid, attempt=0):
    if uid == "U2":
        raise RuntimeError("agent spawn failed for U2")
try:
    flaky_launch("U2")
    print("DID-NOT-RAISE")
except RuntimeError:
    print("raised")
PYEOF
)"
assert_eq "raised" "$raised8"

it "Bug #8: attempt counter increments on dispatch (the burnt-attempt record for a launch failure)"
# Verify the Bug #6 attempt bump happens at dispatch: a fresh pending step goes to
# attempt 1 on its first dispatch (so a launch-failed step's burnt attempt is
# recorded, and a later retry would be attempt 2).
ledger_init "attempt-bump" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
a0="$(ledger_field "attempt-bump" 'L["steps"][0]["attempt"]')"
"$PY" - "$REPO" "attempt-bump" "$ORCH_PY" <<'PYEOF' >/dev/null
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("dispatcher", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
o.dispatch_batch(repo, run, ["U1"], 4)
PYEOF
a1="$(ledger_field "attempt-bump" 'L["steps"][0]["attempt"]')"
if [ "$a0" = "0" ] && [ "$a1" = "1" ]; then
  pass
else
  fail "attempt before=$a0 after=$a1 (expected 0 then 1)"
fi

# ════════════════════════════════════════════════════════════════════════════
# Scenario 10: CLASS-1 — scale-aware gating, end to end, blocker-only run.
#
# The Bug #3 livelock class: a `blocker-only` run with a MAJOR-only finding must
# (a) treat the major-bearing step as TERMINAL (converge), (b) NOT churn it
# fix→re-enqueue forever (advance_work_loop), and (c) UNBLOCK its dependents
# (ready_steps), so the run reaches met=True. Majors are advisory under
# blocker-only; only a blocker gates. We drive ONE ledger through all three
# engine entry points the brief names: ready_steps, converge, advance_work_loop.
#
# The whole point is to prove the CLASS is closed, not one instance: the
# deliberate-fail control (Scenario 11) sets CLAUDE_AUTO_TEST_FORCE_THREETIER_
# GATING=1, which makes the SINGLE central helper ledger.gating_severities ignore
# scale at EVERY site at once, and asserts the SAME scenario livelocks. Because all
# six+ gating consumers route through that one helper, one hatch reverts them all —
# a green Scenario 10 + a red Scenario 11 means no site bypasses the scale.
PULSE_PY="${AUTO_ROOT}/lib/pulse.py"

it "CLASS-1 (blocker-only): a major-only step is TERMINAL + its dependent UNBLOCKS + advance_work_loop does NOT churn -> run reaches met=True (no livelock)"
bo="$("$PY" - "$REPO" "$ORCH_PY" "$LEDGER_PY" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, orch_py, ledger_py, pulse_py = sys.argv[1:5]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
o=load("dispatcher",orch_py); m=load("ledger",ledger_py); t=load("pulse",pulse_py)

run="class1-bo"
# blocker-only run: Ua (will carry a major), Ub depends on Ua.
m.init_ledger(repo, run, backend="native", backend_scale="blocker-only",
              loop_phase="work",
              steps=[{"id":"Ua","state":"pending"},
                     {"id":"Ub","state":"pending","depends_on":["Ua"]}])
# Drive Ua: pending -> dispatched -> verdict-returned WITH a MAJOR (advisory under
# blocker-only, so it must NOT gate).
m.transition(repo, run, "Ua", "dispatched", dispatched_at="2026-05-21T14:00:00Z")
m.record_verdict(repo, run, "Ua", [{"severity":"major","note":"advisory"}])

# (a) ready_steps: Ua's major does NOT make it unsatisfied, so dependent Ub is READY.
ready = o.ready_steps(repo, run)

# (b) converge: Ua (verdict-returned, major-only) is TERMINAL under blocker-only.
conv = o.converge(repo, run)

# (c) advance_work_loop: must NOT pick Ua as fix-due (a major is advisory under
# blocker-only). Drive Ub to a clean verdict so all steps terminal, then confirm
# the loop does not churn and the predicate is met.
led = m.read_ledger(repo, run)
# advance over the current state: Ua has a major-only verdict -> no fix-due,
# no re-enqueue-due (the livelock would re-enqueue Ua here under three-tier).
adv_before = t.pulse_advance.advance_work_loop(repo, run, m.read_ledger(repo, run), set())
# Finish Ub cleanly so the whole run can be terminal.
m.transition(repo, run, "Ub", "dispatched", dispatched_at="2026-05-21T14:05:00Z")
m.record_verdict(repo, run, "Ub", [])
# One more advance: still nothing to do (no gating findings anywhere).
adv_after = t.pulse_advance.advance_work_loop(repo, run, m.read_ledger(repo, run), set())
final = m.read_ledger(repo, run)
pred = final.get("exit_predicate_result") or {}
print(json.dumps({
    "ready": ready,
    "ua_terminal": "Ua" in conv["terminal"],
    "adv_before": adv_before.get("advanced"),
    "adv_after": adv_after.get("advanced"),
    "met": pred.get("met"),
    "majors": pred.get("majors"),
    "all_terminal": pred.get("all_steps_terminal"),
}))
PYEOF
)"
bo_ready="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['ready']))" "$bo")"
bo_uaterm="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['ua_terminal'])" "$bo")"
bo_advb="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['adv_before'])" "$bo")"
bo_adva="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['adv_after'])" "$bo")"
bo_met="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['met'])" "$bo")"
bo_majors="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['majors'])" "$bo")"
bo_allterm="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['all_terminal'])" "$bo")"
# Ub ready (Ua's major did not gate); Ua terminal; no churn (advance == none both
# times); met True; the major is COUNTED (advisory, surfaced) but does NOT gate.
if [ "$bo_ready" = "Ub" ] && [ "$bo_uaterm" = "True" ] \
   && [ "$bo_advb" = "none" ] && [ "$bo_adva" = "none" ] \
   && [ "$bo_met" = "True" ] && [ "$bo_majors" = "1" ] && [ "$bo_allterm" = "True" ]; then
  pass
else
  fail "ready=[$bo_ready] ua_terminal=$bo_uaterm adv_before=$bo_advb adv_after=$bo_adva met=$bo_met majors=$bo_majors all_terminal=$bo_allterm (expected Ub/True/none/none/True/1/True)"
fi

it "CLASS-1 deliberate-fail: FORCE_THREETIER_GATING reverts ALL sites at once -> the SAME blocker-only run LIVELOCKS (major gates, dependent blocked, advance churns, met False)"
# Set the hatch so the SINGLE central helper ignores scale everywhere. If the
# class were NOT closed (a site hardcoding the tuple), this control would be a
# no-op for that site; because ALL sites route through the helper, the hatch makes
# the whole run behave three-tier -> the major now gates at every site. RED proves
# the helper is load-bearing (the class is closed via the single chokepoint).
bofail="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_FORCE_THREETIER_GATING=1 "$PY" - "$REPO" "$ORCH_PY" "$LEDGER_PY" "$PULSE_PY" <<'PYEOF'
import sys, importlib.util, json
repo, orch_py, ledger_py, pulse_py = sys.argv[1:5]
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
o=load("dispatcher",orch_py); m=load("ledger",ledger_py); t=load("pulse",pulse_py)

run="class1-bo-fail"
m.init_ledger(repo, run, backend="native", backend_scale="blocker-only",
              loop_phase="work",
              steps=[{"id":"Ua","state":"pending"},
                     {"id":"Ub","state":"pending","depends_on":["Ua"]}])
m.transition(repo, run, "Ua", "dispatched", dispatched_at="2026-05-21T14:00:00Z")
m.record_verdict(repo, run, "Ua", [{"severity":"major","note":"now-gates"}])
ready = o.ready_steps(repo, run)              # Ub should be BLOCKED now.
conv = o.converge(repo, run)                  # Ua should NOT be terminal now.
adv = t.pulse_advance.advance_work_loop(repo, run, m.read_ledger(repo, run), set())  # fix-due now.
pred = (m.read_ledger(repo, run).get("exit_predicate_result") or {})
print(json.dumps({
    "ready": ready,
    "ua_terminal": "Ua" in conv["terminal"],
    "advanced": adv.get("advanced"),
    "met": pred.get("met"),
}))
PYEOF
)"
bf_ready="$("$PY" -c "import json,sys;print(','.join(json.loads(sys.argv[1])['ready']))" "$bofail")"
bf_uaterm="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['ua_terminal'])" "$bofail")"
bf_adv="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['advanced'])" "$bofail")"
bf_met="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['met'])" "$bofail")"
# Under the forced three-tier gate the major GATES: Ub blocked (ready empty), Ua
# not terminal, advance picks a fix (the churn), met False. This is the livelock
# the class-1 fix prevents — the control going RED proves the fix is real.
if [ "$bf_ready" = "" ] && [ "$bf_uaterm" = "False" ] \
   && [ "$bf_adv" = "fix-applied" ] && [ "$bf_met" = "False" ]; then
  pass
else
  fail "ready=[$bf_ready] ua_terminal=$bf_uaterm advanced=$bf_adv met=$bf_met (expected empty/False/fix-applied/False — control did not go RED, class-1 not proven closed)"
fi

# ─── U6: round-robin plan-step selector + stalled exclusion ─────────────────
rr() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
orch = load_lib_module("dispatcher")
ledger = json.loads(sys.argv[2])
print(orch.pick_next_plan_step_to_advance(ledger))
PYEOF
}

it "round-robin: all never-advanced → first by declaration order"
assert_eq "plan-1" "$(rr '{"steps":[{"id":"plan-1","phase":"plan","state":"dispatched","last_advanced_at":null},{"id":"plan-2","phase":"plan","state":"dispatched","last_advanced_at":null},{"id":"plan-3","phase":"plan","state":"dispatched","last_advanced_at":null}]}')"

it "round-robin: a never-advanced step beats an already-advanced one"
assert_eq "plan-2" "$(rr '{"steps":[{"id":"plan-1","phase":"plan","state":"dispatched","last_advanced_at":"2026-05-25T10:00:00Z"},{"id":"plan-2","phase":"plan","state":"dispatched","last_advanced_at":null},{"id":"plan-3","phase":"plan","state":"dispatched","last_advanced_at":null}]}')"

it "round-robin: all advanced → oldest last_advanced_at wins"
assert_eq "plan-3" "$(rr '{"steps":[{"id":"plan-1","phase":"plan","state":"dispatched","last_advanced_at":"2026-05-25T10:00:02Z"},{"id":"plan-2","phase":"plan","state":"dispatched","last_advanced_at":"2026-05-25T10:00:01Z"},{"id":"plan-3","phase":"plan","state":"dispatched","last_advanced_at":"2026-05-25T10:00:00Z"}]}')"

it "round-robin: stalled plan step excluded; next eligible wins (adversarial F3)"
assert_eq "plan-2" "$(rr '{"steps":[{"id":"plan-1","phase":"plan","state":"stalled","last_advanced_at":null},{"id":"plan-2","phase":"plan","state":"dispatched","last_advanced_at":null}]}')"

it "round-robin: no eligible plan step → None"
assert_eq "None" "$(rr '{"steps":[{"id":"w1","phase":"work","state":"dispatched"}]}')"

# ════════════════════════════════════════════════════════════════════════════
# U3 — should_escalate: the retry-budget predicate (R8 / KTD4). A pure read of
# the EXISTING `attempt` counter (bumped mechanically on each pending->dispatched
# dispatch). At `attempt >= max_attempts` (default 2) the driver STOPS auto-
# retrying a wedged step and pause-escalates to the operator instead of looping.
# ════════════════════════════════════════════════════════════════════════════
esc() {
  # esc <step-json> [max_attempts]  — print should_escalate(step[, max_attempts]).
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
orch = load_lib_module("dispatcher")
step = json.loads(sys.argv[2])
if len(sys.argv) > 3:
    print(orch.should_escalate(step, int(sys.argv[3])))
else:
    print(orch.should_escalate(step))
PYEOF
}

it "should_escalate: attempt 1 (under the default N=2 budget) -> False (retry)"
assert_eq "False" "$(esc '{"attempt":1}')"

it "should_escalate: attempt 2 (at the default N=2 budget) -> True (escalate)"
assert_eq "True" "$(esc '{"attempt":2}')"

it "should_escalate: attempt 3 (past the default budget) -> True (escalate)"
assert_eq "True" "$(esc '{"attempt":3}')"

it "should_escalate: missing/zero attempt -> False (a fresh step never escalates)"
assert_eq "False" "$(esc '{}')"

it "should_escalate: respects a custom max_attempts -> attempt 2 under max=3 is False"
assert_eq "False" "$(esc '{"attempt":2}' 3)"

it "should_escalate: respects a custom max_attempts -> attempt 3 at max=3 is True"
assert_eq "True" "$(esc '{"attempt":3}' 3)"

# ════════════════════════════════════════════════════════════════════════════
# U14 — edge-driven ordering of a producer fan-out (the readiness engine, once
# fed real depends_on edges, sequences the work steps). This is the consumer
# side of U14: step-producers.test.sh proves the edges are materialized; here we
# prove ready_steps ORDERS on them.
# ════════════════════════════════════════════════════════════════════════════

# ─── Ordering: w3 depends on BOTH w1 and w2; edges gate its readiness ─────────
# w1,w2,w3 pending; w3.depends_on=[w1,w2]. The gate is edge-driven: w3 becomes
# ready ONLY after BOTH predecessors are satisfied (per _dependency_satisfied).
it "U14 ordering: w1 verdict-returned WITH open blocker -> ready is exactly [w2] (w3 gated on both edges)"
ledger_init "u14-order" \
  '[{"id":"w1","state":"pending"},{"id":"w2","state":"pending"},{"id":"w3","state":"pending","depends_on":["w1","w2"]}]' \
  >/dev/null 2>&1
ledger_transition "u14-order" "w1" "dispatched" >/dev/null 2>&1
ledger_verdict "u14-order" "w1" '[{"severity":"blocker","note":"open"}]' >/dev/null 2>&1
# w1 not pending (verdict-returned+blocker); w3 gated by unsatisfied w1 AND pending w2.
assert_eq "w2" "$(orch_ready "u14-order")"

it "U14 ordering: satisfy w2 only -> w3 STILL gated (w1's open blocker holds the edge)"
ledger_transition "u14-order" "w2" "dispatched" >/dev/null 2>&1
ledger_verdict "u14-order" "w2" '[]' >/dev/null 2>&1
# w2 now verdict-returned+satisfied (not pending); w1 still carries a blocker;
# w3 remains gated on the unsatisfied w1 edge -> nothing ready.
assert_eq "" "$(orch_ready "u14-order")"

it "U14 ordering: satisfy w1 too -> w3 appears (edge-driven, not incidental)"
ledger_verdict "u14-order" "w1" '[]' >/dev/null 2>&1
# Both edges satisfied -> w3 is the only pending step and becomes ready.
assert_eq "w3" "$(orch_ready "u14-order")"

# ─── Regression: an edgeless fan-out (a1/pipeline) — all siblings ready now ───
# A fan-out that declares no depends_on (Sites 2 & 4, or a1's plain plan->work)
# materializes depends_on:[] and every sibling is immediately dispatchable.
it "U14 regression: edgeless fan-out (depends_on:[]) -> all three siblings immediately ready"
ledger_init "u14-edgeless" \
  '[{"id":"w1","state":"pending","depends_on":[]},{"id":"w2","state":"pending","depends_on":[]},{"id":"w3","state":"pending","depends_on":[]}]' \
  >/dev/null 2>&1
assert_eq "w1,w2,w3" "$(orch_ready "u14-edgeless")"

# ════════════════════════════════════════════════════════════════════════════
# U14 P2 anti-livelock — the FULL chain proves no silent stall. A bad
# model-emitted depends_on (dangling / self / cycle) enters via
# set_enumerated_steps, flows through the A1 producer, materializes onto a work
# ledger, and ready_steps MUST still return a dispatchable step (never the empty
# set forever). ledger-mutators.test.sh proves the edge is cleaned; here we
# prove the readiness engine is actually un-stalled — the real cure for the
# livelock the finding describes.
# ════════════════════════════════════════════════════════════════════════════
livelock_chain() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module, load_ledger
m = load_ledger()
e = load_lib_module("step_producers")
o = load_lib_module("dispatcher")
op = sys.argv[2]


def chain(run, batch):
    """plan ledger → set_enumerated_steps(batch) → A1 producer → work ledger →
    ready_steps. Returns the comma-joined ready ids of the materialized work
    steps. A non-empty result means the livelock is cured."""
    repo = os.path.join(os.environ["HOME"], "chain-repo")
    os.makedirs(repo, exist_ok=True)
    p = m.ledger_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    m.init_ledger(repo, run, backend="ce", loop_phase="plan",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=[{"id": "plan", "state": "pending", "phase": "plan"}])
    m.set_enumerated_steps(repo, run, "plan", batch)
    led = m.read_ledger(repo, run)
    work = e.plan_output_to_work_steps(led, "work")
    wrun = run + "-w"
    wp = m.ledger_path(repo, wrun)
    if os.path.exists(wp):
        os.unlink(wp)
    steps = [{"id": w["id"], "state": "pending", "phase": "work",
              "depends_on": w["depends_on"]} for w in work]
    m.init_ledger(repo, wrun, backend="ce", loop_phase="work",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=steps)
    print(",".join(o.ready_steps(repo, wrun)))


if op == "dangling":
    chain("ll-dangling", [{"id": "w1", "invokes": {}, "depends_on": ["ghost"]}])
elif op == "self":
    chain("ll-self", [{"id": "w1", "invokes": {}, "depends_on": ["w1"]}])
elif op == "two-cycle":
    chain("ll-2cyc",
          [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
           {"id": "w2", "invokes": {}, "depends_on": ["w1"]}])
elif op == "three-cycle":
    chain("ll-3cyc",
          [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
           {"id": "w2", "invokes": {}, "depends_on": ["w3"]},
           {"id": "w3", "invokes": {}, "depends_on": ["w1"]}])
elif op == "forward-ref":
    chain("ll-fwd",
          [{"id": "w1", "invokes": {}, "depends_on": []},
           {"id": "w2", "invokes": {}, "depends_on": ["w1"]}])
elif op == "mixed":
    chain("ll-mixed",
          [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
           {"id": "w2", "invokes": {}, "depends_on": ["w1"]},
           {"id": "w3", "invokes": {}, "depends_on": ["w1"]}])
PYEOF
}

it "U14 no-hang: dangling id edge → work step materializes ready (NOT permanently pending)"
assert_eq "w1" "$(livelock_chain dangling)"

it "U14 no-hang: self-edge → work step materializes ready (a self-dep never satisfies)"
assert_eq "w1" "$(livelock_chain self)"

it "U14 no-hang: 2-cycle → broken; w2 becomes ready (progress, not a mutual dead-lock)"
assert_eq "w2" "$(livelock_chain two-cycle)"

it "U14 no-hang: 3-cycle → broken; w3 becomes ready (generalizes past pairwise)"
assert_eq "w3" "$(livelock_chain three-cycle)"

it "U14 preserved: valid sibling forward-ref survives AND is enforced (only w1 ready; w2 waits)"
assert_eq "w1" "$(livelock_chain forward-ref)"

it "U14 combined: cycle+forward-ref batch → cycle broken (w2 ready), w3's valid edge still enforced"
assert_eq "w2" "$(livelock_chain mixed)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "dispatcher.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
