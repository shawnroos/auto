#!/usr/bin/env bash
# auto U3 unit test: lib/run_record.py persistence, transitions,
# concurrency, and the three hard invariants (I-1 / I-2 / I-3).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline. It does NOT source claude-modes' test-helpers
# (cross-plugin coupling forbidden) nor auto's own shared helpers
# (those are tests/helpers/test-helpers.sh, owned by U2 — not yet present).
# When U2 lands shared helpers, this file may migrate to them.
#
# Scenarios (mapped to the U3 plan):
#   1. round-trip write/read; transition dispatched -> verdict-returned
#   2. empty / unknown run-id -> clean error, no partial file
#   3. write-interruption -> atomic rename holds (no half file)
#   4. concurrent writers serialize via flock; NO_LOCK deliberate-fail hatch
#      proves the test goes RED without locking
#   5. I-1: met==true run-record + new blocker -> same snapshot has met==false;
#      NO_RECOMPUTE hatch proves the I-1 test goes RED without recompute
#   6. I-2: 3 steps, U_b/U_c depend on U_a, U_a stalled, U_b/U_c never
#      dispatched -> met==false (all_steps_terminal false)
#   7. I-2 closure: step `fixed` with a stale blocker -> all_steps_terminal==false
#   8. I-3: liveness/orphan predicate (manual / stale-beat / healthy-slow)
#   9. state grammar: every documented transition holds; undocumented rejected
#  10. fence: no production file enables a TEST_NO_* hatch

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"
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

# ── tiny python helpers run against the module ─────────────────────────────
# init <run> <json-steps>  — create a run-record with given steps list
run_record_init() {
  local run="$1" steps_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$backend" "$phase" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, backend, phase, run_record_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_run_record(repo, run, backend=backend, steps=json.loads(steps_json), loop_phase=phase)
PYEOF
}

# field <run> <python-expr-on-run-record-named-L>  — print a value from the run-record
run_record_field() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, expr, run_record_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L = m.read_run_record(repo, run)
print(eval(expr))
PYEOF
}

# init_scale <run> <json-steps> <backend_scale> [phase]  — like run_record_init but
# threads backend_scale (the run_record_init helper above is fixed at the default
# "three-tier"; the Bug #3 scale-aware scenarios need "blocker-only" too).
run_record_init_scale() {
  local run="$1" steps_json="$2" scale="$3" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$scale" "$phase" "$RUN_RECORD_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, scale, phase, run_record_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
backend = "native" if scale == "blocker-only" else "ce"
m.init_run_record(repo, run, backend=backend, backend_scale=scale,
              steps=json.loads(steps_json), loop_phase=phase)
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "run-record.test.sh"

# ─── Scenario 1: round-trip + transition ────────────────────────────────────
it "round-trip: write a run_record, read it back identical; dispatched -> verdict-returned"
run_record_init "feat foo/2026" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
run="feat foo/2026"
# slug should have collapsed the space + slash.
LP="$(auto_path() { "$PY" "$RUN_RECORD_PY" path "$REPO" "$run"; }; auto_path)"
if [ -f "$LP" ]; then
  # transition pending -> dispatched, then dispatched -> verdict-returned via record_verdict
  "$PY" - "$REPO" "$run" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z")
m.record_verdict(repo, run, "U1", [])
PYEOF
  st="$(run_record_field "$run" 'L["steps"][0]["state"]')"
  assert_eq "verdict-returned" "$st"
else
  fail "run_record file not created at $LP"
fi

# ─── Scenario 2: unknown run-id -> clean error, no partial file ──────────────
it "unknown run-id: read raises RunRecordNotFound, no partial file written"
out="$("$PY" "$RUN_RECORD_PY" read "$REPO" "does-not-exist" 2>&1)"; rc=$?
missing_file="$REPO/.claude/auto/does-not-exist.json"
if [ "$rc" -ne 0 ] && [ ! -f "$missing_file" ]; then
  pass
else
  fail "rc=$rc file-exists=$([ -f "$missing_file" ] && echo yes || echo no) out=$out"
fi

# ─── Scenario 3: write interruption -> atomic rename holds ───────────────────
it "write-interruption: a raised mutate leaves the prior run_record intact (no half file)"
run_record_init "atomic-run" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
"$PY" - "$REPO" "atomic-run" "$RUN_RECORD_PY" <<'PYEOF' 2>/dev/null
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def boom(L):
    L["steps"][0]["state"] = "dispatched"
    raise RuntimeError("simulated interruption mid-RMW")
try:
    m._with_locked_run_record(repo, run, boom)
except RuntimeError:
    pass
PYEOF
# Prior run-record must still be valid JSON, state unchanged (still pending), and
# no leftover .run_record.* tempfile in the dispatch dir.
st="$(run_record_field "atomic-run" 'L["steps"][0]["state"]')"
tmp_left="$(find "$REPO/.claude/auto" -name '.run_record.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$st" = "pending" ] && [ "$tmp_left" = "0" ]; then
  pass
else
  fail "state=$st tmpfiles-left=$tmp_left (expected pending / 0)"
fi

# ─── Scenario 4: concurrent writers serialize via flock (+ NO_LOCK red) ──────
# N writers each append a distinct minor finding via record_verdict-equivalent
# read-modify-write that increments a counter step. Locked: final count == N.
# NO_LOCK: lost updates -> final count < N at least once across iterations.
race_writers() {
  # race_writers <run> <n>   (honors CLAUDE_AUTO_TEST_NO_LOCK from env)
  local run="$1" n="$2" i pids=()
  for i in $(seq 1 "$n"); do
    "$PY" - "$REPO" "$run" "$RUN_RECORD_PY" <<'PYEOF' &
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def bump(L):
    u = L["steps"][0]
    cur = len(u["findings"])
    # read-then-write with a yield in between to widen the race window.
    import time; time.sleep(0.01)
    u["findings"] = u["findings"] + [{"severity": "minor", "note": str(cur)}]
m._with_locked_run_record(repo, run, bump)
PYEOF
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

it "locked: 6 concurrent writers all land (findings count == 6, no lost update)"
run_record_init "race-locked" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
race_writers "race-locked" 6
cnt="$(run_record_field "race-locked" 'len(L["steps"][0]["findings"])')"
assert_eq "6" "$cnt"

it "deliberate-fail: NO_LOCK writers lose updates (count < 6 at least once / 12 iters)"
saw_lost=0
for iter in $(seq 1 12); do
  rm -f "$REPO/.claude/auto/race-nolock.json" "$REPO/.claude/auto/race-nolock.lock"
  run_record_init "race-nolock" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
  CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_LOCK=1 race_writers "race-nolock" 6
  c="$(run_record_field "race-nolock" 'len(L["steps"][0]["findings"])')"
  [ "$c" -lt 6 ] && saw_lost=1 && break
done
if [ "$saw_lost" = "1" ]; then
  pass
else
  fail "NO_LOCK writers never lost an update across 12 iters — the race is not exercised, so the locked pass is not meaningful"
fi

# ─── Scenario 5: I-1 atomic predicate freshness (+ NO_RECOMPUTE red) ─────────
it "I-1: met==true run_record + new blocker -> same snapshot has met==false"
# Build a terminal, defect-free, single-step run-record -> met should be true.
run_record_init "i1-run" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
met_before="$(run_record_field "i1-run" 'L["exit_predicate_result"]["met"]')"
# Now write a blocker finding via record_verdict; the SAME write must recompute.
"$PY" - "$REPO" "i1-run" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"regression"}])
PYEOF
met_after="$(run_record_field "i1-run" 'L["exit_predicate_result"]["met"]')"
if [ "$met_before" = "True" ] && [ "$met_after" = "False" ]; then
  pass
else
  fail "met_before=$met_before met_after=$met_after (expected True then False)"
fi

it "deliberate-fail: with NO_RECOMPUTE, a new blocker leaves stale met==true"
run_record_init "i1-norecomp" '[{"id":"U1","state":"verdict-returned","findings":[]}]' >/dev/null 2>&1
CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_RECOMPUTE=1 "$PY" - "$REPO" "i1-norecomp" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"regression"}])
PYEOF
met_stale="$(run_record_field "i1-norecomp" 'L["exit_predicate_result"]["met"]')"
# Stale: blocker present but met still True because recompute was skipped.
assert_eq "True" "$met_stale"

# ─── Scenario 6: I-2 stalled-dependency false-done guard ─────────────────────
it "I-2: stalled U_a with un-dispatched dependents U_b/U_c -> met==false (all_steps_terminal false)"
run_record_init "i2-run" \
  '[{"id":"Ua","state":"pending"},{"id":"Ub","state":"pending","depends_on":["Ua"]},{"id":"Uc","state":"pending","depends_on":["Ua"]}]' \
  >/dev/null 2>&1
# Move Ua pending->dispatched->stalled; Ub/Uc remain pending (never dispatched).
"$PY" - "$REPO" "i2-run" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.transition(repo, run, "Ua", "dispatched")
m.transition(repo, run, "Ua", "stalled")
PYEOF
met="$(run_record_field "i2-run" 'L["exit_predicate_result"]["met"]')"
aut="$(run_record_field "i2-run" 'L["exit_predicate_result"]["all_steps_terminal"]')"
if [ "$met" = "False" ] && [ "$aut" = "False" ]; then
  pass
else
  fail "met=$met all_steps_terminal=$aut (expected False / False)"
fi

# ─── Scenario 7: I-2 closure — fixed with a stale blocker is NOT terminal ────
it "I-2 closure: a 'fixed' step with a stale blocker -> all_steps_terminal==false"
run_record_init "i2-closure" '[{"id":"U1","state":"verdict-returned"}]' >/dev/null 2>&1
# Record a blocker verdict, then a pulse applies a fix: verdict-returned -> fixed.
# Per §4.2 the fix does NOT clear findings, so the stale blocker remains.
"$PY" - "$REPO" "i2-closure" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"open"}])
m.transition(repo, run, "U1", "fixed")  # fix applied; findings untouched.
PYEOF
state="$(run_record_field "i2-closure" 'L["steps"][0]["state"]')"
aut="$(run_record_field "i2-closure" 'L["exit_predicate_result"]["all_steps_terminal"]')"
if [ "$state" = "fixed" ] && [ "$aut" = "False" ]; then
  pass
else
  fail "state=$state all_steps_terminal=$aut (expected fixed / False)"
fi

# ─── Scenario 8: I-3 liveness / orphan predicate ─────────────────────────────
it "I-3: manual driver -> orphaned; stale beat -> orphaned; healthy slow chain (3500s) -> NOT orphaned"
i3="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, datetime
run_record_py = sys.argv[1]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
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
grammar_ok="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
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
        m.run_record_path(repo, run)
    except Exception:
        pass
    # fresh run-record per edge, step seeded in `frm`
    import os
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    m.init_run_record(repo, run, backend="ce", steps=[{"id":"U1","state":frm}])
    try:
        m.transition(repo, run, "U1", to)
        new = m.read_run_record(repo, run)["steps"][0]["state"]
        if new != to: ok = False
    except m.InvalidTransition:
        ok = False
print("ok" if ok else "FAIL")
PYEOF
)"
assert_eq "ok" "$grammar_ok"

it "state grammar: undocumented transitions are rejected (e.g. pending -> fixed)"
rejected="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
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
    p = m.run_record_path(repo, run)
    if os.path.exists(p): os.unlink(p)
    m.init_run_record(repo, run, backend="ce", steps=[{"id":"U1","state":frm}])
    try:
        m.transition(repo, run, "U1", to)
        all_rejected = False  # should have raised
    except m.InvalidTransition:
        # also confirm the run-record was NOT mutated
        if m.read_run_record(repo, run)["steps"][0]["state"] != frm:
            all_rejected = False
print("all-rejected" if all_rejected else "FAIL")
PYEOF
)"
assert_eq "all-rejected" "$rejected"

it "findings: transition() refuses to write findings (record_verdict is the only path)"
run_record_init "findings-guard" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
guard="$("$PY" - "$REPO" "findings-guard" "$RUN_RECORD_PY" <<'PYEOF' 2>&1
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.transition(repo, run, "U1", "dispatched", findings=[{"severity":"minor","note":"x"}])
    print("ALLOWED")
except m.RunRecordError:
    print("blocked")
PYEOF
)"
assert_eq "blocked" "$guard"

# ─── Scenario 9b: plan_step sub-state (anti-livelock field, schema §3.1) ─────
it "plan_step: init defaults to null; set_loop(plan_step=) round-trips; null is distinct from unset"
run_record_init "plan-step-run" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1
ps_init="$(run_record_field "plan-step-run" 'repr(L["plan_step"])')"
plan_step_walk="$("$PY" - "$REPO" "plan-step-run" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen = []
# Set a step, then read it back; then clear it via plan_step=None; then prove an
# OMITTED plan_step leaves the field unchanged (UNSET sentinel, not None).
m.set_loop(repo, run, plan_step="plan")
seen.append(m.read_run_record(repo, run)["plan_step"])
m.set_loop(repo, run, plan_step="deepen")
seen.append(m.read_run_record(repo, run)["plan_step"])
m.set_loop(repo, run, beat=True)  # OMIT plan_step -> must NOT clobber "deepen".
seen.append(m.read_run_record(repo, run)["plan_step"])
m.set_loop(repo, run, plan_step=None)  # explicit clear -> null.
seen.append(m.read_run_record(repo, run)["plan_step"])
# An invalid step is rejected (does not write).
try:
    m.set_loop(repo, run, plan_step="bogus")
    seen.append("ACCEPTED-BOGUS")
except m.RunRecordError:
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

# ─── Scenario 11: Bug #3 — scale-aware met predicate (blocker-only / native) ──
# Under backend_scale="blocker-only" (native), majors are ADVISORY: a step whose
# ONLY finding is a major is terminal, and a work run with majors>0 / blockers==0
# reaches met==true. A blocker, by contrast, still gates. recompute_predicate
# reads backend_scale (the fix); step_is_terminal uses the SAME scale so the two
# cannot disagree about done-ness.
#
# Verify-RED (neutralize BOTH sites of the fix, then run, then restore):
#   lib/run_record.py step_is_terminal: force  gating = GATING_SEVERITIES  (drop the
#     `("blocker",) if scale == "blocker-only"` branch); AND
#   lib/run_record.py recompute_predicate: force  no_majors = majors == 0  (drop the
#     `if scale != "blocker-only" else True`).
# Both limbs are load-bearing: with only the major finding present, the step is
# terminal ONLY because majors don't gate (limb 1), and met is True ONLY because
# no_majors is vacuously True under blocker-only (limb 2). Neutralizing either
# limb flips this test RED (step non-terminal -> all_steps_terminal False, OR
# no_majors False) — confirmed independently in the verify pass.
it "Bug #3: blocker-only + major-only verdict -> met==True (majors advisory, not gating)"
run_record_init_scale "scale-major" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"major","note":"advisory"}]}]' \
  blocker-only >/dev/null 2>&1
met_major="$(run_record_field "scale-major" 'L["exit_predicate_result"]["met"]')"
majors_major="$(run_record_field "scale-major" 'L["exit_predicate_result"]["majors"]')"
aut_major="$(run_record_field "scale-major" 'L["exit_predicate_result"]["all_steps_terminal"]')"
# Two-part claim: the major finding is GENUINELY present (majors==1) AND the
# scale gates it out (met==True, step terminal). A regression flips one or both.
if [ "$met_major" = "True" ] && [ "$majors_major" = "1" ] && [ "$aut_major" = "True" ]; then
  pass
else
  fail "met=$met_major majors=$majors_major all_steps_terminal=$aut_major (expected True/1/True)"
fi

it "Bug #3: blocker-only + blocker verdict -> met==False (blockers always gate)"
run_record_init_scale "scale-blocker" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"hard"}]}]' \
  blocker-only >/dev/null 2>&1
met_blk="$(run_record_field "scale-blocker" 'L["exit_predicate_result"]["met"]')"
blk_blk="$(run_record_field "scale-blocker" 'L["exit_predicate_result"]["blockers"]')"
aut_blk="$(run_record_field "scale-blocker" 'L["exit_predicate_result"]["all_steps_terminal"]')"
# blocker present (blockers==1), step NOT terminal, met False.
if [ "$met_blk" = "False" ] && [ "$blk_blk" = "1" ] && [ "$aut_blk" = "False" ]; then
  pass
else
  fail "met=$met_blk blockers=$blk_blk all_steps_terminal=$aut_blk (expected False/1/False)"
fi

# ─── Scenario 12: Bug #3 control — three-tier (CE/default) majors GATE ────────
# The contrasting scale: under "three-tier" a major DOES gate (met==False), while
# a minor does NOT (met==True). This proves the blocker-only behaviour above is a
# real scale switch, not majors becoming globally advisory.
it "Bug #3 control: three-tier + major verdict -> met==False (majors gate)"
run_record_init_scale "tier-major" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"major","note":"gating"}]}]' \
  three-tier >/dev/null 2>&1
met_tm="$(run_record_field "tier-major" 'L["exit_predicate_result"]["met"]')"
majors_tm="$(run_record_field "tier-major" 'L["exit_predicate_result"]["majors"]')"
aut_tm="$(run_record_field "tier-major" 'L["exit_predicate_result"]["all_steps_terminal"]')"
# Same major finding as scale-major, opposite verdict because the scale gates it.
if [ "$met_tm" = "False" ] && [ "$majors_tm" = "1" ] && [ "$aut_tm" = "False" ]; then
  pass
else
  fail "met=$met_tm majors=$majors_tm all_steps_terminal=$aut_tm (expected False/1/False)"
fi

it "Bug #3 control: three-tier + minor-only verdict -> met==True (minors never gate)"
run_record_init_scale "tier-minor" \
  '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"minor","note":"nit"}]}]' \
  three-tier >/dev/null 2>&1
met_tn="$(run_record_field "tier-minor" 'L["exit_predicate_result"]["met"]')"
minors_tn="$(run_record_field "tier-minor" 'L["exit_predicate_result"]["minors"]')"
aut_tn="$(run_record_field "tier-minor" 'L["exit_predicate_result"]["all_steps_terminal"]')"
if [ "$met_tn" = "True" ] && [ "$minors_tn" = "1" ] && [ "$aut_tn" = "True" ]; then
  pass
else
  fail "met=$met_tn minors=$minors_tn all_steps_terminal=$aut_tn (expected True/1/True)"
fi

# ─── Scenario 13: Bug #4 — vacuous work-phase exit guard ──────────────────────
# all_steps_terminal = all([]) is vacuously True. WITHOUT the non-empty `steps`
# conjunct (has_steps) in recompute_predicate, an auto plan->work flip with ZERO
# dispatched steps would declare met==True before any fan-out. The guard makes a
# work-phase run-record with steps==[] NOT met. A contrasting work run WITH one
# terminal step IS met — proving the guard is the empty-set check, not a blanket
# false on the work phase.
#
# Verify-RED: lib/run_record.py recompute_predicate, drop the `and has_steps` conjunct
# from the work-loop `met = ...` line (or force has_steps = True). The empty-steps
# test then flips to met==True -> RED.
it "Bug #4: work phase with ZERO steps -> met==False (vacuous-exit guard; all([])==True is NOT done)"
run_record_init "vacuous-run" '[]' ce work >/dev/null 2>&1
met_vac="$(run_record_field "vacuous-run" 'L["exit_predicate_result"]["met"]')"
aut_vac="$(run_record_field "vacuous-run" 'L["exit_predicate_result"]["all_steps_terminal"]')"
phase_vac="$(run_record_field "vacuous-run" 'L["loop_phase"]')"
# all_steps_terminal is vacuously True (all([])), yet met must be False because
# the work-loop requires at least one step. The guard is what breaks the tie.
if [ "$met_vac" = "False" ] && [ "$aut_vac" = "True" ] && [ "$phase_vac" = "work" ]; then
  pass
else
  fail "met=$met_vac all_steps_terminal=$aut_vac phase=$phase_vac (expected False/True/work)"
fi

it "Bug #4 contrast: work phase WITH one terminal step -> met==True (guard is the empty-set check, not a blanket work-phase false)"
run_record_init "nonvacuous-run" '[{"id":"U1","state":"verdict-returned","findings":[]}]' ce work >/dev/null 2>&1
met_nv="$(run_record_field "nonvacuous-run" 'L["exit_predicate_result"]["met"]')"
aut_nv="$(run_record_field "nonvacuous-run" 'L["exit_predicate_result"]["all_steps_terminal"]')"
# Identical work phase, one terminal defect-free step -> met True. Proves the
# vacuous test's False comes from the empty-set guard, not from "work never met".
if [ "$met_nv" = "True" ] && [ "$aut_nv" = "True" ]; then
  pass
else
  fail "met=$met_nv all_steps_terminal=$aut_nv (expected True/True)"
fi

# ─── Scenario 14: Bug #6 — stall+retry verdict clobber (attempt-identity) ─────
# A slow agent A is dispatched (attempt 1), stalls, the operator retries, agent B
# is dispatched as a FRESH attempt (attempt 2) and self-writes a clean verdict.
# Agent A — still alive — then self-writes a verdict for attempt 1. The
# attempt-identity check MUST reject A's stale verdict (StaleVerdict) so it does
# NOT clobber B's findings. Without the check, A's stale findings would win
# (latest-write-wins keyed only on step_id).
#
# Verify-RED: set CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK=1 — record_verdict skips
# the attempt rejection, A's stale verdict overwrites B's, and the assertion that
# B's findings survive flips RED (proven below + by the deliberate-fail control).
it "Bug #6: a late verdict from a SUPERSEDED attempt is rejected (does not clobber the fresh attempt's verdict)"
clobber="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "bug6-clobber"
import os
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])

# Attempt 1: dispatch (attempt -> 1). Simulate the dispatcher's bump.
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
a1 = m.read_run_record(repo, run)["steps"][0]["attempt"]
# A stalls.
m.transition(repo, run, "U1", "stalled")
# Operator retries: stalled -> pending (clears last_error).
m.transition(repo, run, "U1", "pending")
# Attempt 2: re-dispatch (attempt -> 2). Agent B.
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:20:00Z", attempt=2)
a2 = m.read_run_record(repo, run)["steps"][0]["attempt"]
# Agent B (attempt 2) self-writes a CLEAN verdict.
m.record_verdict(repo, run, "U1", [], attempt=2)
after_b = m.read_run_record(repo, run)["steps"][0]
sev_b = "clean" if not after_b["findings"] else after_b["findings"][0]["severity"]

# Agent A (still alive, attempt 1) self-writes a STALE blocker verdict. MUST be
# rejected — it would otherwise clobber B's clean verdict.
rejected = "NO"
try:
    m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"stale-from-A"}], attempt=1)
except m.StaleVerdict:
    rejected = "yes"
after_a = m.read_run_record(repo, run)["steps"][0]
# B's clean verdict must survive: findings still empty, state still verdict-returned.
survived = "clean" if not after_a["findings"] else after_a["findings"][0]["severity"]
print("%s,%s,%s,%s,%s" % (a1, a2, sev_b, rejected, survived))
PYEOF
)"
# attempt 1 -> 2 ; B verdict clean ; A's stale rejected ; B's clean survives.
if [ "$clobber" = "1,2,clean,yes,clean" ]; then
  pass
else
  fail "a1,a2,sev_b,rejected,survived = $clobber (expected 1,2,clean,yes,clean)"
fi

it "Bug #6 deliberate-fail: WITHOUT the attempt check, A's stale verdict CLOBBERS B's clean one"
# Same scenario, but NO_ATTEMPT_CHECK neuters the rejection: A's attempt-1 stale
# blocker overwrites B's attempt-2 clean verdict (the clobber the fix prevents).
clobbered="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK=1 "$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "bug6-clobber-nofix"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
m.transition(repo, run, "U1", "stalled")
m.transition(repo, run, "U1", "pending")
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:20:00Z", attempt=2)
m.record_verdict(repo, run, "U1", [], attempt=2)  # B clean.
# A's stale blocker for attempt 1 — with the hatch, this is NOT rejected.
clobbered = "no"
try:
    m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"stale-from-A"}], attempt=1)
    after = m.read_run_record(repo, run)["steps"][0]
    if after["findings"] and after["findings"][0]["severity"] == "blocker":
        clobbered = "yes"
except m.StaleVerdict:
    clobbered = "rejected-unexpectedly"
print(clobbered)
PYEOF
)"
# Without the fix, the stale verdict wins: clobbered == "yes".
assert_eq "yes" "$clobbered"

# ─── Scenario 15: Bug #7 — healthy slow review's late verdict recovered ───────
# A legit review takes longer than stall_threshold_seconds, gets marked `stalled`
# (a plain timeout, last_error null). It THEN finishes and self-writes a genuine
# verdict. The recovery edge (stalled -> verdict-returned) must accept it (it is
# real work) instead of silently discarding it via InvalidTransition. Coordinated
# with Bug #6: a late verdict from a SUPERSEDED attempt is still REJECTED.
#
# Verify-RED: set CLAUDE_AUTO_TEST_NO_STALLED_RECOVERY=1 — record_verdict
# reverts to the pre-fix check that rejects a stalled step's verdict, so the
# genuine late verdict is lost to InvalidTransition (proven by the control below).
it "Bug #7: a genuine late verdict from a STALLED step (current attempt) is RECOVERED to verdict-returned"
recovered="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "bug7-recover"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
# Attempt 1 dispatch, then a plain timeout stall (last_error stays null).
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
m.transition(repo, run, "U1", "stalled")
le_before = m.read_run_record(repo, run)["steps"][0]["last_error"]
# The slow-but-healthy review finishes and self-writes a clean verdict for its
# CURRENT attempt (1). Recovery must accept it.
m.record_verdict(repo, run, "U1", [], attempt=1)
after = m.read_run_record(repo, run)["steps"][0]
le_after = after["last_error"]
print("%s,%s,%s,%s" % (after["state"], "null" if le_before is None else le_before,
                       "null" if le_after is None else le_after,
                       m.read_run_record(repo, run)["exit_predicate_result"]["met"]))
PYEOF
)"
# state recovered to verdict-returned; last_error was null (plain timeout) and
# stays null after recovery; clean verdict -> met True (terminal, no findings).
if [ "$recovered" = "verdict-returned,null,null,True" ]; then
  pass
else
  fail "state,le_before,le_after,met = $recovered (expected verdict-returned,null,null,True)"
fi

it "Bug #7: a STALE late verdict (superseded attempt) from a stalled step is still REJECTED (not recovered)"
# Recovery must NOT resurrect a stale verdict: agent A (attempt 1) stalls, operator
# retries, B is dispatched (attempt 2). A finishes and tries to recover-via-late-
# verdict for attempt 1 — but its attempt is superseded, so StaleVerdict, NOT a
# recovery to verdict-returned. (B is still in flight as `dispatched` here.)
stale_recover="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "bug7-stale-recover"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
m.transition(repo, run, "U1", "stalled")
# Operator retries; B dispatched as attempt 2 (step now `dispatched`, attempt 2).
m.transition(repo, run, "U1", "pending")
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:20:00Z", attempt=2)
# A (attempt 1) tries to land its late verdict — superseded -> StaleVerdict.
outcome = "ACCEPTED"
try:
    m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"stale-A"}], attempt=1)
except m.StaleVerdict:
    outcome = "rejected-stale"
after = m.read_run_record(repo, run)["steps"][0]
# Step must remain `dispatched` (B in flight) — A's stale verdict had NO effect.
print("%s,%s" % (outcome, after["state"]))
PYEOF
)"
assert_eq "rejected-stale,dispatched" "$stale_recover"

it "Bug #7 deliberate-fail: WITHOUT the recovery edge, a genuine late verdict from a stalled step is LOST to InvalidTransition"
# NO_STALLED_RECOVERY forces the pre-fix check: a stalled step's verdict raises
# InvalidTransition (the silent-discard bug), instead of being recovered.
lost="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_STALLED_RECOVERY=1 "$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "bug7-recover-nofix"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
m.transition(repo, run, "U1", "stalled")
outcome = "RECOVERED"
try:
    m.record_verdict(repo, run, "U1", [], attempt=1)
except m.InvalidTransition:
    outcome = "lost-invalid-transition"
# Without recovery the step is STILL stalled (verdict discarded).
state = m.read_run_record(repo, run)["steps"][0]["state"]
print("%s,%s" % (outcome, state))
PYEOF
)"
assert_eq "lost-invalid-transition,stalled" "$lost"

# ─── Scenario 16: init_run_record routes its lock through the shared _flock_run ───
# Cleanup #P2: init_run_record no longer hand-rolls flock acquire/release; it shares
# the _flock_run primitive with _with_locked_run_record (only the body inside the
# lock differs — check-absent-then-write vs read-mutate-write). The OBSERVABLE
# contract that must survive the refactor: init still rejects creating an
# existing run, and two concurrent inits cannot both win (exactly one creates,
# the other gets RunRecordExists).
it "init_run_record: a second init of the same run-id is rejected (RunRecordExists), original untouched"
run_record_init "init-once" '[{"id":"U1","state":"pending"}]' >/dev/null 2>&1
second="$("$PY" - "$REPO" "init-once" "$RUN_RECORD_PY" <<'PYEOF' 2>&1
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.init_run_record(repo, run, backend="native", steps=[{"id":"X"}])
    print("ACCEPTED-CLOBBER")
except m.RunRecordExists:
    # Original must be untouched: still the ce backend + the original step.
    led = m.read_run_record(repo, run)
    print("rejected:%s:%s" % (led["backend"], led["steps"][0]["id"]))
PYEOF
)"
assert_eq "rejected:ce:U1" "$second"

it "init_run_record: concurrent double-init -> EXACTLY one wins, the other gets RunRecordExists (flock holds across check+create)"
# Two processes race to create the SAME fresh run. The shared flock primitive
# must serialize the existence-check + write so exactly one creates the run-record
# and the other observes it already exists.
rm -f "$REPO/.claude/auto/init-race.json" "$REPO/.claude/auto/init-race.lock"
race_init() {
  "$PY" - "$REPO" "init-race" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.init_run_record(repo, run, backend="ce", steps=[{"id":"U1","state":"pending"}])
    print("won")
except m.RunRecordExists:
    print("exists")
except Exception as e:
    print("ERR:%s" % e)
PYEOF
}
race_init >"$SANDBOX/init-a.out" 2>&1 &
pa=$!
race_init >"$SANDBOX/init-b.out" 2>&1 &
pb=$!
wait "$pa"; wait "$pb"
outcomes="$(cat "$SANDBOX/init-a.out" "$SANDBOX/init-b.out" | sort | tr '\n' ',')"
wins="$(cat "$SANDBOX/init-a.out" "$SANDBOX/init-b.out" | grep -c '^won$' || true)"
exists="$(cat "$SANDBOX/init-a.out" "$SANDBOX/init-b.out" | grep -c '^exists$' || true)"
# Exactly one "won" and one "exists" — never two wins (no torn double-create),
# never an error. The flock across check+create is what makes this deterministic.
if [ "$wins" = "1" ] && [ "$exists" = "1" ]; then
  pass
else
  fail "wins=$wins exists=$exists outcomes=$outcomes (expected exactly one won + one exists)"
fi

# ─── Scenario 17: record_verdict self-edge (verdict-returned -> verdict-returned)
# Cleanup #P2: confirm the verdict-returned -> verdict-returned self-edge is
# INTENTIONAL (a re-review of the CURRENT attempt overwrites findings) and that
# attempt-identity (Bug #6) is the real guard discriminating a legit re-review
# from a stale clobber — NOT a coincidental latest-write-wins.
it "record_verdict self-edge: a SAME-attempt re-verdict overwrites the current findings (intended re-review)"
reverdict="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "reverdict-same-attempt"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
# First verdict (attempt 1): a blocker. Step -> verdict-returned, met False.
m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"first-pass"}], attempt=1)
first = m.read_run_record(repo, run)["steps"][0]
# A re-review of the SAME attempt finds the blocker resolved -> clean verdict.
# This is the verdict-returned -> verdict-returned self-edge; equal attempt is
# ACCEPTED and the findings are OVERWRITTEN (latest-only, §4.2).
m.record_verdict(repo, run, "U1", [], attempt=1)
second = m.read_run_record(repo, run)
u = second["steps"][0]
print("%s,%s,%s,%s" % (
    first["state"],
    "clean" if not u["findings"] else u["findings"][0]["severity"],
    u["state"],
    second["exit_predicate_result"]["met"],
))
PYEOF
)"
# first verdict-returned ; re-verdict findings now clean ; still verdict-returned ;
# clean re-verdict -> met True (terminal, no gating findings).
assert_eq "verdict-returned,clean,verdict-returned,True" "$reverdict"

it "record_verdict self-edge: a re-verdict from an OLDER attempt is REJECTED (attempt-identity, not write-order, is the guard)"
# The self-edge does NOT blindly accept any re-verdict: a verdict carrying an
# attempt OLDER than the step's current attempt is rejected even when the step is
# already verdict-returned. This proves attempt-identity guards the self-edge.
self_stale="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, os
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "reverdict-stale-self"
p = m.run_record_path(repo, run)
if os.path.exists(p): os.unlink(p)
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id":"U1","state":"pending"}])
# Bump the step to attempt 2 and land a clean verdict for it (verdict-returned).
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:00:00Z", attempt=1)
m.record_verdict(repo, run, "U1", [], attempt=1)
m.transition(repo, run, "U1", "pending")
m.transition(repo, run, "U1", "dispatched", dispatched_at="2026-05-21T14:20:00Z", attempt=2)
m.record_verdict(repo, run, "U1", [], attempt=2)  # clean, verdict-returned, attempt 2.
# A late verdict from attempt 1 tries the self-edge (verdict-returned -> ...)
# with a STALE blocker. Must be rejected; the clean attempt-2 findings survive.
outcome = "ACCEPTED"
try:
    m.record_verdict(repo, run, "U1", [{"severity":"blocker","note":"stale-self"}], attempt=1)
except m.StaleVerdict:
    outcome = "rejected-stale"
u = m.read_run_record(repo, run)["steps"][0]
print("%s,%s" % (outcome, "clean" if not u["findings"] else u["findings"][0]["severity"]))
PYEOF
)"
assert_eq "rejected-stale,clean" "$self_stale"

# ─── Scenario 10: fence — no production file enables a test hatch ────────────
it "fence: no production file sets a CLAUDE_AUTO_TEST_* hatch to 1"
# Covers the TEST_NO_* deliberate-fail hatches AND the TEST_FORCE_THREETIER_GATING
# hatch (the class-1 deliberate-fail control): a production file must never ENABLE
# any of them. The helper only READS the env var (== "1"); SETTING it in lib/ would
# wedge a deliberate-fail control on in production, so the fence forbids it.
offenders="$(grep -rlE "CLAUDE_AUTO_TEST_(NO_(LOCK|RECOMPUTE|REENQUEUE|ATTEMPT_CHECK|STALLED_RECOVERY|STALENESS_CHECK)|FORCE_THREETIER_GATING)[[:space:]]*=[[:space:]]*[\"']?1" \
  "${AUTO_ROOT}/lib" 2>/dev/null || true)"
if [ -z "$offenders" ]; then
  pass
else
  fail "production files enable a test hatch: $offenders"
fi

# ─── Scenario 11 (U1, v0.2.0): additive workflow schema fields ────────────────
# The workflow work adds top-level workflow/phase_order/terminal_phase and per-step
# phase/plan_step/gaps_open/dispatch_context/last_advanced_at. ALL must be
# additive: a v0.1.x run-record with none of them reads + predicates identically
# (the attempt-field precedent). New run-records carrying them round-trip cleanly.

it "U1: a v0.1.x on-disk run_record (no new keys) reads back + predicates unchanged"
# The REAL backward-compat property: a run-record FILE written in the old shape
# (no workflow/phase_order/terminal_phase keys, no per-step phase/etc.) must load
# via the additive defaults and predicate IDENTICALLY to v0.1.1. We write such a
# file by hand (NOT via the new init_run_record, which adds the keys) and read it.
v01x="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, json, os, tempfile
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo = tempfile.mkdtemp(); run = "v01x"
# Hand-write a legacy-shaped run-record: exactly the v0.1.x keys, no v0.2.0 fields.
legacy = {
    "run_id": run, "loop_phase": "work", "plan_step": None,
    "handoff_paused": False, "backend": "ce", "backend_scale": "three-tier",
    "exit_predicate_result": {}, "loop": {"driver": "self", "last_beat_at": "x"},
    "steps": [{"id": "U1", "state": "verdict-returned", "depends_on": [],
               "dispatched_at": None, "verdict_at": None,
               "stall_threshold_seconds": 600, "last_error": None,
               "attempt": 0, "findings": [{"severity": "blocker"}]}],
}
path = m.run_record_path(repo, run)
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
with open(path, "w") as f:
    json.dump(legacy, f)
led = m.read_run_record(repo, run)
pr = m.recompute_predicate(led)  # recompute against the legacy-shaped dict
# Predicate must evaluate exactly as v0.1.1: a blocker means not-met.
# The legacy file has NO new top-level keys (read returns it verbatim).
has_new = any(k in led for k in ("workflow", "phase_order", "terminal_phase"))
print("%s,%s,%s" % (pr["met"], pr["blockers"], has_new))
PYEOF
)"
# met False (blocker present), blockers 1, AND the legacy file carries no new
# keys — proving an old on-disk run-record reads + predicates identically.
assert_eq "False,1,False" "$v01x"

it "U1: per-step additive fields default cleanly on a v0.1.x step (no fields set)"
defaults="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import tempfile
repo = tempfile.mkdtemp(); run = "defs"
m.init_run_record(repo, run, backend="ce", steps=[{"id": "U1"}])
u = m.read_run_record(repo, run)["steps"][0]
# additive per-step fields read as their documented defaults.
print("%s,%s,%s,%s" % (
    u.get("phase"), u.get("plan_step"), u.get("dispatch_context"),
    u.get("last_advanced_at")))
PYEOF
)"
# phase defaults to plan (a step with no phase in a plan-default run-record),
# plan_step None, dispatch_context {} , last_advanced_at None.
assert_eq "plan,None,{},None" "$defaults"

it "U1: new top-level workflow/phase_order/terminal_phase round-trip"
toplevel="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import tempfile
repo = tempfile.mkdtemp(); run = "rcp"
m.init_run_record(repo, run, backend="ce",
              workflow={"name": "a1", "source_tier": "built-in"},
              phase_order=["plan", "handoff", "work"], terminal_phase="work",
              steps=[{"id": "U1"}])
led = m.read_run_record(repo, run)
print("%s,%s,%s" % (
    led["workflow"]["name"], led["phase_order"][2], led["terminal_phase"]))
PYEOF
)"
assert_eq "a1,work,work" "$toplevel"

it "U1: terminal_phase not in phase_order -> init rejects"
rej="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
import tempfile
repo = tempfile.mkdtemp(); run = "bad"
try:
    m.init_run_record(repo, run, backend="ce",
                  phase_order=["plan", "handoff", "work"], terminal_phase="nope",
                  steps=[{"id": "U1"}])
    print("accepted")
except m.RunRecordError:
    print("rejected")
PYEOF
)"
assert_eq "rejected" "$rej"

# ─── Scenario 18 (U3, v0.7.0): _normalize_step preserves `verification` ───────
# KTD-1: a workflow gate step's `verification` block must survive normalization so
# resolve_gate_verification sees it on a real run. CONDITIONAL preservation —
# present iff the source carried it; a step WITHOUT it gets NO key (not None/[]),
# so legacy run-record step shapes are unchanged (the regression guard).

it "U3: _normalize_step preserves a step's verification block unchanged"
got="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, json
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
crit = [{"id": "c1", "type": "programmatic", "check": "x"}]
nu = m.run_record_core._normalize_step({"id": "G1", "verification": crit})
print("ok" if nu.get("verification") == crit else "mismatch:%r" % nu.get("verification"))
PYEOF
)"
assert_eq "ok" "$got"

it "U3: _normalize_step on a step WITHOUT verification leaves NO key (no shape change)"
got="$("$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("run_record", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
nu = m.run_record_core._normalize_step({"id": "U1"})
# Assert the KEY IS ABSENT — not None, not [] (that would change every run-record's shape).
print("absent" if "verification" not in nu else "present:%r" % nu.get("verification"))
PYEOF
)"
assert_eq "absent" "$got"

it "U3: round-trip init_run_record -> read_run_record retains the gate step's verification"
got="$("$PY" - "$REPO" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run_record_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
run = "vgate"
crit = [{"id": "c1", "type": "programmatic", "check": "x"},
        {"id": "c2", "type": "advisor_judge", "prompt": "ok?"}]
m.init_run_record(repo, run, backend="ce", loop_phase="work",
              steps=[{"id": "G1", "state": "pending", "verification": crit},
                     {"id": "U1", "state": "pending"}],
              iteration={"gate_step": "G1"})
L = m.read_run_record(repo, run)
by = {u["id"]: u for u in L["steps"]}
gate_ok = by["G1"].get("verification") == crit
# the non-gate step must NOT have grown a verification key (regression).
legacy_clean = "verification" not in by["U1"]
print("ok" if (gate_ok and legacy_clean) else "fail gate=%r legacy=%r" % (
    by["G1"].get("verification"), "verification" in by["U1"]))
PYEOF
)"
assert_eq "ok" "$got"

# ─── U4: public time helpers round-trip through the facade ──────────────────
it "run_record.now_iso() / run_record.parse_iso() are public and round-trip an ISO-Z stamp"
got="$(
  "$PY" - "$RUN_RECORD_PY" <<'PYEOF'
import datetime, importlib.util, sys
run_record_py = sys.argv[1]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# Both must be PUBLIC on the facade (no leading underscore).
assert hasattr(m, "now_iso") and hasattr(m, "parse_iso"), "public names missing"
stamp = m.now_iso()
parsed = m.parse_iso(stamp)
shape_ok = stamp.endswith("Z") and parsed is not None
tz_ok = parsed.tzinfo == datetime.timezone.utc and parsed.microsecond == 0
# Round-trip: re-formatting the parsed value reproduces the stamp exactly.
roundtrip_ok = parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == stamp
print("ok" if (shape_ok and tz_ok and roundtrip_ok) else "fail %r %r" % (stamp, parsed))
PYEOF
)"
assert_eq "ok" "$got"

# ─── U3 (R4): `init` CLI verb — create a run + steps from the tool surface ──
# The plan-loop/work-loop steering family (force-skip/add-step/reshape-deps)
# auto-resolves the repo via resolve_repo() and takes only the run-id; `init`
# joins that family so a run can be CREATED — not just mutated — from the CLI.
RUN_RECORD_CLI="$RUN_RECORD_PY"

it "init: CLI verb creates a readable run_record (predicate met==false, phase plan)"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" init cliinit1 '[{"id":"u1"}]' ce plan \
  >/dev/null 2>&1
assert_eq "False|plan" \
  "$(run_record_field cliinit1 '"%s|%s" % (L["exit_predicate_result"]["met"], L["loop_phase"])')"

it "init: against an existing run-id fails (exit!=0) and leaves the run_record byte-identical"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" init cliexist '[{"id":"u1"}]' ce plan \
  >/dev/null 2>&1
LPX="$(CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" path "$REPO" cliexist)"
before="$(cat "$LPX")"
# Re-init with a DIFFERENT spec must be rejected AND must not touch the file.
if CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" init cliexist '[{"id":"DIFFERENT"}]' native work \
     >/dev/null 2>&1; then
  fail "init succeeded against an existing run-id (should raise RunRecordExists)"
else
  # byte-for-byte file contents (mtime-independent; stat is not compared).
  [ "$before" = "$(cat "$LPX")" ] && pass \
    || fail "a rejected init modified/truncated the existing run_record"
fi

it "init: an invalid backend is rejected (exit!=0, no run_record file created)"
LPBAD="$(CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" path "$REPO" clibad)"
if CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" init clibad '[{"id":"u1"}]' bogus plan \
     >/dev/null 2>&1; then
  fail "invalid backend accepted at the CLI"
else
  [ ! -f "$LPBAD" ] && pass || fail "invalid backend left a run_record file on disk"
fi

it "init: steps passed as JSON are normalized (state=pending, phase set, attempt counter)"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" init clinorm '[{"id":"n1"}]' ce plan \
  >/dev/null 2>&1
assert_eq "pending|True|True" \
  "$(run_record_field clinorm '"%s|%s|%s" % (L["steps"][0]["state"], "phase" in L["steps"][0], "attempt" in L["steps"][0])')"

# ── U4: the `describe` self-orientation verb ────────────────────────────────
# describe emits the stable operating contract as ONE JSON object so a driving
# agent stops re-deriving "what is auto" from ~2000 lines of skill prose each
# session (R6/R7). The completeness check is the load-bearing one: every CLI verb
# must be documented, or an agent reading `describe` gets an incomplete surface.

it "describe: emits exactly one valid JSON object (no surrounding prose)"
describe_out="$("$PY" "$RUN_RECORD_PY" describe 2>/dev/null)"
one_obj="$("$PY" - "$describe_out" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    print("ok" if isinstance(d, dict) else "not-object")
except Exception as e:
    print(f"parse-fail: {e}")
PYEOF
)"
assert_eq "ok" "$one_obj"

it "describe: COMPLETENESS — describe's verb catalog IS the _VERBS registry"
# Dispatch and docs share one source (_VERBS): _cli routes through it and describe
# derives its catalog from it, so drift is structurally impossible. This asserts
# that invariant directly — describe's verbs must equal _VERBS.keys(). It fails if
# a future change re-hardcodes describe or breaks _describe_surface's derivation.
verb_diff="$("$PY" - "$RUN_RECORD_PY" "$describe_out" <<'PYEOF'
import json, sys, importlib.util
run_record_py, describe_out = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
registered = set(m._VERBS)
described = set(json.loads(describe_out).get("verbs", {}))
print(json.dumps({"missing": sorted(registered - described),
                  "extra": sorted(described - registered)}))
PYEOF
)"
assert_eq '{"missing": [], "extra": []}' "$verb_diff"

it "describe: each steering verb names a rejection mode"
rej="$("$PY" - "$describe_out" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
verbs = d.get("verbs", {})
need = ["force-skip", "add-step", "reshape-deps", "record-verdict"]
bad = [v for v in need
       if not (isinstance(verbs.get(v), dict) and verbs[v].get("rejects"))]
print("ok" if not bad else f"missing-rejects: {bad}")
PYEOF
)"
assert_eq "ok" "$rej"

# ── U2: the run-scoped `describe <run>` overlay ─────────────────────────────
# `describe <run>` overlays THIS run's phase model (phase_order + current phase)
# onto the static surface — a PURE READ. No-arg describe stays byte-identical.
run_record_init "describe-overlay" '[{"id":"U1","state":"pending"}]' ce plan >/dev/null 2>&1

it "describe <run>: overlays this run's phase_order and current_phase"
ov="$(CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_PY" describe "describe-overlay" 2>/dev/null)"
ov_ok="$("$PY" - "$ov" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
rp = d.get("run_phase") or {}
ok = (rp.get("current_phase") == "plan"
      and isinstance(rp.get("phase_order"), list) and rp["phase_order"]
      and rp.get("run") == "describe-overlay")
print("ok" if ok else f"bad: {rp}")
PYEOF
)"
assert_eq "ok" "$ov_ok"

it "describe (no arg): emits no run_phase overlay (static surface unchanged)"
noarg="$("$PY" "$RUN_RECORD_PY" describe 2>/dev/null)"
has_rp="$("$PY" - "$noarg" <<'PYEOF'
import json, sys
print("yes" if "run_phase" in json.loads(sys.argv[1]) else "no")
PYEOF
)"
assert_eq "no" "$has_rp"

it "describe <run>: is a pure read (run-record content unchanged)"
# Content fingerprint, not mtime (second-resolution mtime could miss a same-second
# write): a sha256 of the bytes cannot.
ov_fp() { "$PY" - "$1" <<'PYEOF'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PYEOF
}
ovpath="$("$PY" "$RUN_RECORD_PY" path "$REPO" "describe-overlay")"
fp_before="$(ov_fp "$ovpath")"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_PY" describe "describe-overlay" >/dev/null 2>&1
fp_after="$(ov_fp "$ovpath")"
assert_eq "$fp_before" "$fp_after"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "run-record.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
