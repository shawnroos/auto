#!/usr/bin/env bash
# claude-dispatch U10 unit test: lib/orchestrator.py — the agent-driven fan-out
# layer. It exposes THREE operations against the ledger schema contract:
#
#   * ready_units(repo, run)                 -> dispatchable-now unit ids (READER)
#   * dispatch_batch(repo, run, ids, cap, *, launch_fn=None)
#                                            -> pending->dispatched + launch (WRITER)
#   * converge(repo, run)                    -> reconcile/READ over durable state
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline, mirroring tests/unit/ledger.test.sh and
# tests/unit/tick.test.sh. It does NOT source claude-modes' test-helpers
# (cross-plugin coupling forbidden) nor claude-dispatch shared helpers (U2's,
# not yet present). When U2 lands, this file may migrate to them.
#
# Scenarios (mapped to the U10 plan, tested against orchestrator.py's ACTUAL
# surface — ready_units / dispatch_batch / converge):
#   1. ready_units: 4 independent pending units -> all returned
#   2. dependency gating (the "satisfied" definition): U_b depends on U_a;
#      U_a verdict-returned WITH an open blocker -> ready_units EXCLUDES U_b;
#      clear the finding (still verdict-returned, no blockers) -> U_b appears;
#      AND the literal plan path: U_a -> fixed (no blockers) -> U_b appears
#   3. stalled-ancestor: U_a stalled, U_b depends on U_a -> ready excludes U_b
#   4. dispatch_batch cap: 10 ready, cap=3 -> exactly 3 dispatched (with
#      dispatched_at); next call picks the next wave
#   5. in-flight resize: dispatch cap=8 (of 16), then cap=2 next wave -> only 2
#   6. dispatch idempotency: dispatch_batch on an already-dispatched unit ->
#      rejected, no second launch, no duplicate/changed dispatched_at
#   7. VERDICT SURVIVES SESSION DEATH: a separate process self-writes a verdict
#      AFTER the driving session "exited"; a fresh converge READS it and does NOT
#      treat it as in-flight (re-dispatchable). Deliberate-fail control proves
#      the test is real (without the self-write, converge leaves it in-flight)
#   8. concurrent self-write: two verdicts written concurrently via flock ->
#      neither clobbers; predicate (blockers/majors) correct after both

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ORCH_PY="${DISPATCH_ROOT}/lib/orchestrator.py"
ORCH_SH="${DISPATCH_ROOT}/lib/orchestrator.sh"
LEDGER_PY="${DISPATCH_ROOT}/lib/ledger.py"
PY="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

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
SANDBOX="$(mktemp -d -t claude-dispatch-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */claude-dispatch-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO"

# ── tiny python helpers ────────────────────────────────────────────────────
# ledger_init <run> <json-units> [adapter] [phase]  — create a ledger.
ledger_init() {
  local run="$1" units_json="$2" adapter="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$units_json" "$adapter" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, units_json, adapter, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, adapter=adapter, units=json.loads(units_json), loop_phase=phase)
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

# orch_ready <run>  — print ready unit ids, comma-joined (declaration order).
orch_ready() {
  local run="$1"
  "$PY" - "$REPO" "$run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
print(",".join(o.ready_units(repo, run)))
PYEOF
}

# ledger_transition <run> <unit> <state>  — grammar transition via ledger.py.
ledger_transition() {
  local run="$1" unit="$2" state="$3"
  "$PY" - "$REPO" "$run" "$unit" "$state" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, unit, state, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, unit, state)
PYEOF
}

# ledger_verdict <run> <unit> <findings-json>  — record_verdict via ledger.py.
ledger_verdict() {
  local run="$1" unit="$2" findings="$3"
  "$PY" - "$REPO" "$run" "$unit" "$findings" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, unit, findings, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, unit, json.loads(findings))
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "orchestrator.test.sh"

# ─── Scenario 1: ready_units — 4 independent pending units -> all returned ────
it "ready_units: 4 independent pending units -> all four returned (declaration order)"
ledger_init "ready-4" \
  '[{"id":"U1","state":"pending"},{"id":"U2","state":"pending"},{"id":"U3","state":"pending"},{"id":"U4","state":"pending"}]' \
  >/dev/null 2>&1
ready="$(orch_ready "ready-4")"
assert_eq "U1,U2,U3,U4" "$ready"

# ─── Scenario 2: dependency gating — the "satisfied" definition ───────────────
# U_b depends on U_a. While U_a is verdict-returned WITH an open blocker, U_a is
# NOT satisfied -> ready_units must EXCLUDE U_b (U_a itself is not pending, so it
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
# U_a stalled, U_b depends on U_a -> ready_units excludes U_b (the transitive
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
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
# Wave 1: 10 ready, cap=3.
r1 = o.ready_units(repo, run)
res1 = o.dispatch_batch(repo, run, r1, 3)
d1 = [uid for uid, st in res1 if st == "dispatched"]
# Wave 2: from the remaining pending, cap=3 again -> the next three.
r2 = o.ready_units(repo, run)
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
# Each dispatched unit must have a non-null dispatched_at.
disp_at_nulls="$(ledger_field "cap-run" 'sum(1 for u in L["units"] if u["state"]=="dispatched" and u["dispatched_at"] is None)')"
dispatched_total="$(ledger_field "cap-run" 'sum(1 for u in L["units"] if u["state"]=="dispatched")')"
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
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
# Wave 1: cap=8.
r1 = o.ready_units(repo, run)
n1 = len([1 for uid, st in o.dispatch_batch(repo, run, r1, 8) if st == "dispatched"])
# Wave 2: cap shrinks to 2.
r2 = o.ready_units(repo, run)
n2 = len([1 for uid, st in o.dispatch_batch(repo, run, r2, 2) if st == "dispatched"])
print(json.dumps({"n1": n1, "n2": n2, "r1_len": len(r1), "r2_len": len(r2)}))
PYEOF
)"
n1="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['n1'])" "$resize")"
n2="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['n2'])" "$resize")"
r1_len="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['r1_len'])" "$resize")"
r2_len="$("$PY" -c "import json,sys;print(json.loads(sys.argv[1])['r2_len'])" "$resize")"
total_dispatched="$(ledger_field "resize-run" 'sum(1 for u in L["units"] if u["state"]=="dispatched")')"
# 16 ready, dispatch 8; remaining ready 8; cap shrinks to 2 -> dispatch 2 (6
# remain pending). Total dispatched == 10.
if [ "$r1_len" = "16" ] && [ "$n1" = "8" ] && [ "$r2_len" = "8" ] && [ "$n2" = "2" ] \
   && [ "$total_dispatched" = "10" ]; then
  pass
else
  fail "r1_len=$r1_len n1=$n1 r2_len=$r2_len n2=$n2 total_dispatched=$total_dispatched (expected 16/8/8/2/10)"
fi

# ─── Scenario 6: dispatch idempotency — already-dispatched unit is rejected ────
# Instrument launch_fn to count launches. First dispatch_batch launches U1 once
# and stamps dispatched_at. A second dispatch_batch on the SAME (now-dispatched)
# unit must REJECT it (rejected:not-pending(dispatched)), launch nothing more,
# and leave dispatched_at byte-identical (no second stamp).
it "dispatch idempotency: re-dispatching an already-dispatched unit -> rejected, no second launch, dispatched_at unchanged"
ledger_init "idem-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
idem="$("$PY" - "$REPO" "idem-run" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)

launches = []
def counting_launch(uid):
    launches.append(uid)

# First dispatch: pending -> dispatched, one launch.
res1 = o.dispatch_batch(repo, run, ["U1"], 4, launch_fn=counting_launch)
disp_at_1 = o.read_ledger(repo, run)["units"][0]["dispatched_at"]

# Second dispatch on the now-dispatched unit: must be rejected (idempotency),
# no second launch, dispatched_at unchanged.
res2 = o.dispatch_batch(repo, run, ["U1"], 4, launch_fn=counting_launch)
disp_at_2 = o.read_ledger(repo, run)["units"][0]["dispatched_at"]

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

# ─── Scenario 7: VERDICT SURVIVES SESSION DEATH ───────────────────────────────
# The load-bearing property. A background agent self-writes its verdict to the
# durable ledger AFTER the driving session has exited. A FRESH converge (a
# resumed session) reads the verdict straight off disk and does NOT re-dispatch
# the unit (it is 'completed', not 'in_flight').
it "verdict survives session death: a separately-written verdict is read by a fresh converge (unit completed, NOT in-flight)"
ledger_init "survive-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
# Driving session dispatches U1 (now 'dispatched' / in-flight), then "exits".
"$PY" - "$REPO" "survive-run" "$ORCH_PY" <<'PYEOF' >/dev/null 2>&1
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
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
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
c = o.converge(repo, run)
# A resumed session would re-dispatch only units still 'pending'/ready. After a
# durable verdict, U1 is verdict-returned -> completed, NOT in_flight, and NOT
# ready (never re-dispatchable from converge's read).
print(json.dumps({
    "in_flight": c["in_flight"],
    "completed": c["completed"],
    "ready_after": o.ready_units(repo, run),
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

it "deliberate-fail control: WITHOUT the self-written verdict, the dispatched unit stays in-flight (re-dispatchable) — proves S7 measures the verdict, not a tautology"
ledger_init "survive-control" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
# Same dispatch, but the background agent NEVER self-writes (session died before
# the verdict landed).
"$PY" - "$REPO" "survive-control" "$ORCH_PY" <<'PYEOF' >/dev/null 2>&1
import sys, importlib.util
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
o = importlib.util.module_from_spec(spec); spec.loader.exec_module(o)
o.dispatch_batch(repo, run, ["U1"], 4)
PYEOF
control="$("$PY" - "$REPO" "survive-control" "$ORCH_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, orch_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("orchestrator", orch_py)
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
# Two background agents on two distinct units self-write verdicts CONCURRENTLY
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
  # verdict_writer <unit> <severity>
  "$PY" - "$REPO" "concurrent-run" "$1" "$2" "$LEDGER_PY" <<'PYEOF' &
import sys, importlib.util, time
repo, run, unit, severity, ledger_py = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# record_verdict routes through the single locked RMW chokepoint; the sleep
# below only widens the OS-scheduling window between the two processes.
time.sleep(0.02)
m.record_verdict(repo, run, unit, [{"severity": severity, "note": unit}])
PYEOF
}
verdict_writer "U1" "blocker"
p1=$!
verdict_writer "U2" "major"
p2=$!
wait "$p1"; wait "$p2"
# Both verdicts must have landed: U1 verdict-returned w/ a blocker finding,
# U2 verdict-returned w/ a major finding; predicate counts reflect BOTH.
st_u1="$(ledger_field "concurrent-run" 'next(u["state"] for u in L["units"] if u["id"]=="U1")')"
st_u2="$(ledger_field "concurrent-run" 'next(u["state"] for u in L["units"] if u["id"]=="U2")')"
sev_u1="$(ledger_field "concurrent-run" 'next((f["severity"] for u in L["units"] if u["id"]=="U1" for f in u["findings"]), "NONE")')"
sev_u2="$(ledger_field "concurrent-run" 'next((f["severity"] for u in L["units"] if u["id"]=="U2" for f in u["findings"]), "NONE")')"
blockers="$(ledger_field "concurrent-run" 'L["exit_predicate_result"]["blockers"]')"
majors="$(ledger_field "concurrent-run" 'L["exit_predicate_result"]["majors"]')"
if [ "$st_u1" = "verdict-returned" ] && [ "$st_u2" = "verdict-returned" ] \
   && [ "$sev_u1" = "blocker" ] && [ "$sev_u2" = "major" ] \
   && [ "$blockers" = "1" ] && [ "$majors" = "1" ]; then
  pass
else
  fail "st_u1=$st_u1 st_u2=$st_u2 sev_u1=$sev_u1 sev_u2=$sev_u2 blockers=$blockers majors=$majors (expected verdict-returned x2 / blocker / major / 1 / 1)"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "orchestrator.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
