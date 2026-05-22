#!/usr/bin/env bash
# claude-dispatch U3 unit test: lib/ledger.py persistence, transitions,
# concurrency, and the three hard invariants (I-1 / I-2 / I-3).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline. It does NOT source claude-modes' test-helpers
# (cross-plugin coupling forbidden) nor claude-dispatch's own shared helpers
# (those are tests/helpers/test-helpers.sh, owned by U2 — not yet present).
# When U2 lands shared helpers, this file may migrate to them.
#
# Scenarios (mapped to the U3 plan):
#   1. round-trip write/read; transition dispatched -> verdict-returned
#   2. empty / unknown run-id -> clean error, no partial file
#   3. write-interruption -> atomic rename holds (no half file)
#   4. concurrent writers serialize via flock; NO_LOCK deliberate-fail hatch
#      proves the test goes RED without locking
#   5. I-1: met==true ledger + new blocker -> same snapshot has met==false;
#      NO_RECOMPUTE hatch proves the I-1 test goes RED without recompute
#   6. I-2: 3 units, U_b/U_c depend on U_a, U_a stalled, U_b/U_c never
#      dispatched -> met==false (all_units_terminal false)
#   7. I-2 closure: unit `fixed` with a stale blocker -> all_units_terminal==false
#   8. I-3: liveness/orphan predicate (manual / stale-beat / healthy-slow)
#   9. state grammar: every documented transition holds; undocumented rejected
#  10. fence: no production file enables a TEST_NO_* hatch

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

# ── tiny python helpers run against the module ─────────────────────────────
# init <run> <json-units>  — create a ledger with given units list
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

# field <run> <python-expr-on-ledger-named-L>  — print a value from the ledger
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

# ════════════════════════════════════════════════════════════════════════════
echo "ledger.test.sh"

# ─── Scenario 1: round-trip + transition ────────────────────────────────────
it "round-trip: write a ledger, read it back identical; dispatched -> verdict-returned"
ledger_init "feat foo/2026" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
run="feat foo/2026"
# slug should have collapsed the space + slash.
LP="$(claude_dispatch_path() { "$PY" "$LEDGER_PY" path "$REPO" "$run"; }; claude_dispatch_path)"
if [ -f "$LP" ]; then
  # transition pending -> dispatched, then dispatched -> verdict-returned via record_verdict
  "$PY" - "$REPO" "$run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z")
m.record_verdict(repo, run, "U1", [])
PYEOF
  st="$(ledger_field "$run" 'L["units"][0]["state"]')"
  assert_eq "verdict-returned" "$st"
else
  fail "ledger file not created at $LP"
fi

# ─── Scenario 2: unknown run-id -> clean error, no partial file ──────────────
it "unknown run-id: read raises LedgerNotFound, no partial file written"
out="$("$PY" "$LEDGER_PY" read "$REPO" "does-not-exist" 2>&1)"; rc=$?
missing_file="$REPO/.claude/dispatch/does-not-exist.json"
if [ "$rc" -ne 0 ] && [ ! -f "$missing_file" ]; then
  pass
else
  fail "rc=$rc file-exists=$([ -f "$missing_file" ] && echo yes || echo no) out=$out"
fi

# ─── Scenario 3: write interruption -> atomic rename holds ───────────────────
it "write-interruption: a raised mutate leaves the prior ledger intact (no half file)"
ledger_init "atomic-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
"$PY" - "$REPO" "atomic-run" "$LEDGER_PY" <<'PYEOF' 2>/dev/null
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def boom(L):
    L["units"][0]["state"] = "dispatched"
    raise RuntimeError("simulated interruption mid-RMW")
try:
    m._with_locked_ledger(repo, run, boom)
except RuntimeError:
    pass
PYEOF
# Prior ledger must still be valid JSON, state unchanged (still pending), and
# no leftover .ledger.* tempfile in the dispatch dir.
st="$(ledger_field "atomic-run" 'L["units"][0]["state"]')"
tmp_left="$(find "$REPO/.claude/dispatch" -name '.ledger.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$st" = "pending" ] && [ "$tmp_left" = "0" ]; then
  pass
else
  fail "state=$st tmpfiles-left=$tmp_left (expected pending / 0)"
fi

# ─── Scenario 4: concurrent writers serialize via flock (+ NO_LOCK red) ──────
# N writers each append a distinct minor finding via record_verdict-equivalent
# read-modify-write that increments a counter unit. Locked: final count == N.
# NO_LOCK: lost updates -> final count < N at least once across iterations.
race_writers() {
  # race_writers <run> <n>   (honors CLAUDE_DISPATCH_TEST_NO_LOCK from env)
  local run="$1" n="$2" i pids=()
  for i in $(seq 1 "$n"); do
    "$PY" - "$REPO" "$run" "$LEDGER_PY" <<'PYEOF' &
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def bump(L):
    u = L["units"][0]
    cur = len(u["findings"])
    # read-then-write with a yield in between to widen the race window.
    import time; time.sleep(0.01)
    u["findings"] = u["findings"] + [{"severity": "minor", "note": str(cur)}]
m._with_locked_ledger(repo, run, bump)
PYEOF
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

it "locked: 6 concurrent writers all land (findings count == 6, no lost update)"
ledger_init "race-locked" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
race_writers "race-locked" 6
cnt="$(ledger_field "race-locked" 'len(L["units"][0]["findings"])')"
assert_eq "6" "$cnt"

it "deliberate-fail: NO_LOCK writers lose updates (count < 6 at least once / 12 iters)"
saw_lost=0
for iter in $(seq 1 12); do
  rm -f "$REPO/.claude/dispatch/race-nolock.json" "$REPO/.claude/dispatch/race-nolock.lock"
  ledger_init "race-nolock" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
  CLAUDE_DISPATCH_TEST_NO_LOCK=1 race_writers "race-nolock" 6
  c="$(ledger_field "race-nolock" 'len(L["units"][0]["findings"])')"
  [ "$c" -lt 6 ] && saw_lost=1 && break
done
if [ "$saw_lost" = "1" ]; then
  pass
else
  fail "NO_LOCK writers never lost an update across 12 iters — the race is not exercised, so the locked pass is not meaningful"
fi

# ─── Scenario 5: I-1 atomic predicate freshness (+ NO_RECOMPUTE red) ─────────
it "I-1: met==true ledger + new blocker -> same snapshot has met==false"
# Build a terminal, defect-free, single-unit ledger -> met should be true.
ledger_init "i1-run" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
met_before="$(ledger_field "i1-run" 'L["exit_predicate_result"]["met"]')"
# Now write a blocker finding via record_verdict; the SAME write must recompute.
"$PY" - "$REPO" "i1-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"regression"}])
PYEOF
met_after="$(ledger_field "i1-run" 'L["exit_predicate_result"]["met"]')"
if [ "$met_before" = "True" ] && [ "$met_after" = "False" ]; then
  pass
else
  fail "met_before=$met_before met_after=$met_after (expected True then False)"
fi

it "deliberate-fail: with NO_RECOMPUTE, a new blocker leaves stale met==true"
ledger_init "i1-norecomp" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
CLAUDE_DISPATCH_TEST_NO_RECOMPUTE=1 "$PY" - "$REPO" "i1-norecomp" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"regression"}])
PYEOF
met_stale="$(ledger_field "i1-norecomp" 'L["exit_predicate_result"]["met"]')"
# Stale: blocker present but met still True because recompute was skipped.
assert_eq "True" "$met_stale"

# ─── Scenario 6: I-2 stalled-dependency false-done guard ─────────────────────
it "I-2: stalled U_a with un-dispatched dependents U_b/U_c -> met==false (all_units_terminal false)"
ledger_init "i2-run" \
  '[{"id":"Ua","state":"pending"},{"id":"Ub","state":"pending","depends_on":["Ua"]},{"id":"Uc","state":"pending","depends_on":["Ua"]}]' \
  >/dev/null 2>&1
# Move Ua pending->dispatched->stalled; Ub/Uc remain pending (never dispatched).
"$PY" - "$REPO" "i2-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, "Ua", "dispatched")
m.transition(repo, run, "Ua", "stalled")
PYEOF
met="$(ledger_field "i2-run" 'L["exit_predicate_result"]["met"]')"
aut="$(ledger_field "i2-run" 'L["exit_predicate_result"]["all_units_terminal"]')"
if [ "$met" = "False" ] && [ "$aut" = "False" ]; then
  pass
else
  fail "met=$met all_units_terminal=$aut (expected False / False)"
fi

# ─── Scenario 7: I-2 closure — fixed with a stale blocker is NOT terminal ────
it "I-2 closure: a 'fixed' unit with a stale blocker -> all_units_terminal==false"
ledger_init "i2-closure" '[{"id":"U1","state":"verdict-returned"}]' >/dev/null 2>&1
# Record a blocker verdict, then a tick applies a fix: verdict-returned -> fixed.
# Per §4.2 the fix does NOT clear findings, so the stale blocker remains.
"$PY" - "$REPO" "i2-closure" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"open"}])
m.transition(repo, run, "U1", "fixed")  # fix applied; findings untouched.
PYEOF
state="$(ledger_field "i2-closure" 'L["units"][0]["state"]')"
aut="$(ledger_field "i2-closure" 'L["exit_predicate_result"]["all_units_terminal"]')"
if [ "$state" = "fixed" ] && [ "$aut" = "False" ]; then
  pass
else
  fail "state=$state all_units_terminal=$aut (expected fixed / False)"
fi

# ─── Scenario 8: I-3 liveness / orphan predicate ─────────────────────────────
it "I-3: manual driver -> orphaned; stale beat -> orphaned; healthy slow chain (3500s) -> NOT orphaned"
i3="$("$PY" - "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, datetime
ledger_py = sys.argv[1]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now = datetime.datetime(2026,5,21,15,0,0, tzinfo=datetime.timezone.utc)
def iso(dt): return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

# (a) manual driver, recent beat -> orphaned True
a = {"loop_phase":"work","loop":{"driver":"manual","last_beat_at":iso(now)}}
# (b) self driver, beat older than GRACE (4200s) -> orphaned True
b = {"loop_phase":"work","loop":{"driver":"self",
     "last_beat_at":iso(now - datetime.timedelta(seconds=5000))}}
# (c) self driver, healthy slow chain (3500s < GRACE) -> orphaned False
c = {"loop_phase":"work","loop":{"driver":"self",
     "last_beat_at":iso(now - datetime.timedelta(seconds=3500))}}
# (d) done phase -> never orphaned even if manual
d = {"loop_phase":"done","loop":{"driver":"manual","last_beat_at":iso(now)}}
print(",".join(str(m.is_orphaned(x, now=now)) for x in (a,b,c,d)))
PYEOF
)"
assert_eq "True,True,False,False" "$i3"

# ─── Scenario 9: state grammar ───────────────────────────────────────────────
it "state grammar: every documented transition is accepted"
grammar_ok="$("$PY" - "$REPO" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
edges = [
    ("pending","dispatched"),
    ("dispatched","verdict-returned"),
    ("dispatched","stalled"),
    ("verdict-returned","fixed"),
    ("verdict-returned","pending"),
    ("fixed","pending"),
    ("stalled","pending"),
    ("stalled","terminal-skip"),
]
ok = True
for i,(frm,to) in enumerate(edges):
    run = f"grammar-ok-{i}"
    try:
        m.ledger_path(repo, run)
    except Exception:
        pass
    # fresh ledger per edge, unit seeded in `frm`
    import os
    p = m.ledger_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    m.init_ledger(repo, run, adapter="ce", units=[{"id":"U1","state":frm}])
    try:
        m.transition(repo, run, "U1", to)
        new = m.read_ledger(repo, run)["units"][0]["state"]
        if new != to: ok = False
    except m.InvalidTransition:
        ok = False
print("ok" if ok else "FAIL")
PYEOF
)"
assert_eq "ok" "$grammar_ok"

it "state grammar: undocumented transitions are rejected (e.g. pending -> fixed)"
rejected="$("$PY" - "$REPO" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util, os
repo, ledger_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = [
    ("pending","fixed"),
    ("pending","verdict-returned"),
    ("pending","terminal-skip"),
    ("verdict-returned","dispatched"),
    ("terminal-skip","pending"),
    ("fixed","verdict-returned"),
]
all_rejected = True
for i,(frm,to) in enumerate(bad):
    run = f"grammar-bad-{i}"
    p = m.ledger_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    m.init_ledger(repo, run, adapter="ce", units=[{"id":"U1","state":frm}])
    try:
        m.transition(repo, run, "U1", to)
        all_rejected = False  # should have raised
    except m.InvalidTransition:
        # also confirm the ledger was NOT mutated
        if m.read_ledger(repo, run)["units"][0]["state"] != frm:
            all_rejected = False
print("all-rejected" if all_rejected else "FAIL")
PYEOF
)"
assert_eq "all-rejected" "$rejected"

it "findings: transition() refuses to write findings (record_verdict is the only path)"
ledger_init "findings-guard" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
guard="$("$PY" - "$REPO" "findings-guard" "$LEDGER_PY" <<'PYEOF' 2>&1
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.transition(repo, run, "U1", "dispatched", findings=[{"severity":"minor","note":"x"}])
    print("ALLOWED")
except m.LedgerError:
    print("blocked")
PYEOF
)"
assert_eq "blocked" "$guard"

# ─── Scenario 9b: plan_step sub-state (anti-livelock field, schema §3.1) ─────
it "plan_step: init defaults to null; set_loop(plan_step=) round-trips; null is distinct from unset"
ledger_init "plan-step-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
ps_init="$(ledger_field "plan-step-run" 'repr(L["plan_step"])')"
plan_step_walk="$("$PY" - "$REPO" "plan-step-run" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, run, ledger_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen = []
# Set a step, then read it back; then clear it via plan_step=None; then prove an
# OMITTED plan_step leaves the field unchanged (UNSET sentinel, not None).
m.set_loop(repo, run, plan_step="plan")
seen.append(m.read_ledger(repo, run)["plan_step"])
m.set_loop(repo, run, plan_step="deepen")
seen.append(m.read_ledger(repo, run)["plan_step"])
m.set_loop(repo, run, beat=True)  # OMIT plan_step -> must NOT clobber "deepen".
seen.append(m.read_ledger(repo, run)["plan_step"])
m.set_loop(repo, run, plan_step=None)  # explicit clear -> null.
seen.append(m.read_ledger(repo, run)["plan_step"])
# An invalid step is rejected (does not write).
try:
    m.set_loop(repo, run, plan_step="bogus")
    seen.append("ACCEPTED-BOGUS")
except m.LedgerError:
    seen.append("rejected-bogus")
print(",".join(str(s) for s in seen))
PYEOF
)"
# init=None ; set plan ; set deepen ; omit keeps deepen ; clear to None ; bogus rejected.
if [ "$ps_init" = "None" ] && [ "$plan_step_walk" = "plan,deepen,deepen,None,rejected-bogus" ]; then
  pass
else
  fail "ps_init=$ps_init walk=$plan_step_walk (expected None / plan,deepen,deepen,None,rejected-bogus)"
fi

# ─── Scenario 10: fence — no production file enables a test hatch ────────────
it "fence: no production file sets CLAUDE_DISPATCH_TEST_NO_LOCK/NO_RECOMPUTE=1"
offenders="$(grep -rlE "CLAUDE_DISPATCH_TEST_NO_(LOCK|RECOMPUTE)[[:space:]]*=[[:space:]]*[\"']?1" \
  "${DISPATCH_ROOT}/lib" 2>/dev/null || true)"
if [ -z "$offenders" ]; then
  pass
else
  fail "production files enable a test hatch: $offenders"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "ledger.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
