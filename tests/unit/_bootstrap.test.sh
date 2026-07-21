#!/usr/bin/env bash
# auto v0.3.0 F5 unit test: _bootstrap helpers.
#
# Covers:
#   1. is_iteration_disabled() — REAL operator knob (unfenced in F5).
#      Returns True when CLAUDE_AUTO_DISABLE_ITERATION=1 is set, WITHOUT
#      the CLAUDE_AUTO_TEST_HARNESS=1 sentinel also being set. This is the
#      load-bearing assertion of the F5 unfence — it MUST go RED in the
#      pre-F5 (still-fenced) world, and GREEN now.
#   2. is_iteration_disabled() — returns False when var is unset.
#   3. test_hatch_enabled() no longer recognizes CLAUDE_AUTO_DISABLE_ITERATION
#      (the kill-switch is its own function now). Probe with the var alone +
#      harness sentinel ALSO set, both unset, etc.
#   4. test_hatch_enabled() still works for the other test-only hatches.
#
# Institutional anchors:
#   - feedback_plan_documents_transition_code_doesnt_wire_it (round-1 was
#     prose-vs-code; F5 makes them consistent)
#   - feedback_deterministic_over_probabilistic_v1 (env-var check is
#     deterministic; that's the right shape)

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

# Driver: load lib/_bootstrap.py and call one of its helpers, printing the
# boolean result as "True" or "False" (Python repr).
probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
op = sys.argv[2]
if op == "is_iteration_disabled":
    print(b.is_iteration_disabled())
elif op == "test_hatch":
    var = sys.argv[3]
    print(b.test_hatch_enabled(var))
elif op == "driving_session_key":
    print(b.DRIVING_SESSION_KEY)
else:
    sys.exit(f"unknown op: {op}")
PYEOF
}

# ─── Scenario 1: is_iteration_disabled — the F5 unfence assertion ───────────
# Set DISABLE=1 but EXPLICITLY UNSET the harness sentinel. In the pre-F5
# world this would return False (the fence required the sentinel); post-F5
# it returns True (the var alone is sufficient — it's now a real operator
# knob). This is the load-bearing scenario for F5. We use a subshell + unset
# instead of `env -u` because `probe` is a shell function, not an executable.
it "is_iteration_disabled: DISABLE=1 alone (no harness sentinel) → True (F5 unfence)"
result="$(unset CLAUDE_AUTO_TEST_HARNESS; CLAUDE_AUTO_DISABLE_ITERATION=1 \
  probe is_iteration_disabled)"
assert_eq "True" "$result"

# ─── Scenario 2: is_iteration_disabled — unset var → False ──────────────────
it "is_iteration_disabled: DISABLE unset → False"
result="$(unset CLAUDE_AUTO_DISABLE_ITERATION; probe is_iteration_disabled)"
assert_eq "False" "$result"

# ─── Scenario 3: is_iteration_disabled — DISABLE=0 → False ──────────────────
it "is_iteration_disabled: DISABLE=0 → False (only '1' is True)"
result="$(CLAUDE_AUTO_DISABLE_ITERATION=0 probe is_iteration_disabled)"
assert_eq "False" "$result"

# ─── Scenario 4: lib/*.py no longer asks test_hatch_enabled about it ────────
# The contract is that NO code in lib/ asks test_hatch_enabled about
# DISABLE_ITERATION anymore (the kill-switch routes through
# is_iteration_disabled). Grep-check is the mechanical, deterministic
# enforcement (composes with feedback_deterministic_over_probabilistic_v1).
it "test_hatch_enabled: no lib/*.py module asks about CLAUDE_AUTO_DISABLE_ITERATION (F5: kill-switch is is_iteration_disabled-only)"
hits="$(grep -rn 'test_hatch_enabled[^)]*CLAUDE_AUTO_DISABLE_ITERATION' \
  "${AUTO_ROOT}/lib" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$hits"

# ─── Scenario 5: test_hatch_enabled still fences the other test hatches ─────
# With BOTH sentinel + var set → True. The helper unchanged for these.
it "test_hatch_enabled: harness sentinel + NO_PULSE_LOCK=1 → True (existing test hatches unaffected)"
result="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_PULSE_LOCK)"
assert_eq "True" "$result"

# ─── Scenario 6: test_hatch_enabled fence — sentinel missing → False ────────
it "test_hatch_enabled: var alone (no harness sentinel) → False (other hatches still fenced)"
result="$(unset CLAUDE_AUTO_TEST_HARNESS; CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_PULSE_LOCK)"
assert_eq "False" "$result"

# ─── Scenario 7: test_hatch_enabled fence — var missing → False ─────────────
it "test_hatch_enabled: harness sentinel alone (no var) → False"
result="$(unset CLAUDE_AUTO_TEST_NO_PULSE_LOCK; CLAUDE_AUTO_TEST_HARNESS=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_PULSE_LOCK)"
assert_eq "False" "$result"

# ─── load_run_record_safe / iter_worktree_run_records (the shared run-record-scan home) ──
# These two helpers replaced 3 byte-identical _load_run_record_safe copies + ~5
# inline glob-scan scaffolds across the hooks. Two contracts are LOAD-BEARING
# and were previously only exercised indirectly:
#   1. load_run_record_safe folds in a dict-guard — a valid-JSON NON-dict value
#      (array/scalar) returns None, NOT the raw value. The 3 former copies
#      returned the raw value and let each caller isinstance-check it. This
#      guard is what keeps a non-dict run-record from disarming the fail-closed
#      destructive backstop (it reaches `_owns_session`/`_is_blocking` as a
#      skip, never as an AttributeError-or-truthy-match). rel-001.
#   2. iter_worktree_run_records never raises (missing dispatch dir → empty),
#      yields (run_id, led) SORTED by path, skips unparseable/non-dict files,
#      and derives run_id as led["run_id"] or the filename stem.
# Self-contained driver: creates a fresh tempdir, writes run-record files, calls
# the helper, prints a comparable token, cleans up.
probe_scan() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile, shutil
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
scenario = sys.argv[2]

def write(path, raw):
    with open(path, "w") as fh:
        fh.write(raw)

def shape(r):
    return "dict" if isinstance(r, dict) else ("None" if r is None else "other")

tmp = tempfile.mkdtemp(prefix="bootstrap-scan-")
try:
    if scenario == "safe_missing":
        print(shape(b.load_run_record_safe(os.path.join(tmp, "nope.json"))))
    elif scenario in ("safe_dict", "safe_array", "safe_scalar", "safe_badjson"):
        raw = {"safe_dict": '{"a": 1}', "safe_array": "[]",
               "safe_scalar": "42", "safe_badjson": "{bad"}[scenario]
        p = os.path.join(tmp, "l.json")
        write(p, raw)
        print(shape(b.load_run_record_safe(p)))
    elif scenario == "iter_missing_dir":
        # No .claude/auto dir exists at all — must yield nothing, never raise.
        got = list(b.iter_worktree_run_records(tmp))
        print("NORAISE:%d" % len(got))
    else:
        adir = os.path.join(tmp, ".claude", "auto")
        os.makedirs(adir)
        if scenario == "iter_order":
            # Written out of order; iteration must be sorted by PATH (a,b,c).
            write(os.path.join(adir, "c.json"), '{"run_id": "c-run"}')
            write(os.path.join(adir, "a.json"), '{"run_id": "a-run"}')
            write(os.path.join(adir, "b.json"), '{"run_id": "b-run"}')
            print(" ".join(rid for rid, _ in b.iter_worktree_run_records(tmp)))
        elif scenario == "iter_skip":
            # One valid dict + one non-dict array + one unparseable → only the
            # valid dict is yielded (the others are skipped, scan continues).
            write(os.path.join(adir, "good.json"), '{"run_id": "good-run"}')
            write(os.path.join(adir, "arr.json"), "[]")
            write(os.path.join(adir, "bad.json"), "{bad")
            print(" ".join(rid for rid, _ in b.iter_worktree_run_records(tmp)))
        elif scenario == "iter_runid_fallback":
            # A dict run-record with no run_id key → run_id falls back to the stem.
            write(os.path.join(adir, "stemname.json"), '{"loop_phase": "work"}')
            print(" ".join(rid for rid, _ in b.iter_worktree_run_records(tmp)))
        elif scenario == "iter_config_only":
            # U1 (finding A): the dir holds ONLY auto's own rules.json config —
            # a valid JSON dict lacking loop/loop_phase/run_id. It must NOT be
            # yielded as a run (else on-stop blocks stop forever from any session
            # under ~). Expect ZERO runs.
            write(os.path.join(adir, "rules.json"),
                  '{"format": "auto-rules/v1", "rules": [{"name": "honest"}]}')
            got = list(b.iter_worktree_run_records(tmp))
            print("RUNS:%d" % len(got))
        elif scenario == "iter_config_mixed":
            # A real run-record (has loop_phase) beside the rules.json config →
            # only the real run is yielded; the config is skipped by shape.
            write(os.path.join(adir, "rules.json"),
                  '{"format": "auto-rules/v1", "rules": []}')
            write(os.path.join(adir, "realrun.json"),
                  '{"run_id": "real-run", "loop_phase": "work"}')
            print(" ".join(rid for rid, _ in b.iter_worktree_run_records(tmp)))
        else:
            sys.exit("unknown scan scenario: %s" % scenario)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

it "load_run_record_safe: valid JSON object → returns the dict"
assert_eq "dict" "$(probe_scan safe_dict)"

it "load_run_record_safe: valid JSON array (non-dict) → None (folded dict-guard, the deliberate behavior change)"
assert_eq "None" "$(probe_scan safe_array)"

it "load_run_record_safe: valid JSON scalar (non-dict) → None (folded dict-guard)"
assert_eq "None" "$(probe_scan safe_scalar)"

it "load_run_record_safe: unparseable JSON → None (rel-001 never raises)"
assert_eq "None" "$(probe_scan safe_badjson)"

it "load_run_record_safe: missing file → None (rel-001 never raises)"
assert_eq "None" "$(probe_scan safe_missing)"

it "iter_worktree_run_records: missing dispatch dir → yields nothing, never raises"
assert_eq "NORAISE:0" "$(probe_scan iter_missing_dir)"

it "iter_worktree_run_records: yields (run_id, led) SORTED by path"
assert_eq "a-run b-run c-run" "$(probe_scan iter_order)"

it "iter_worktree_run_records: skips unparseable + non-dict files, keeps scanning siblings"
assert_eq "good-run" "$(probe_scan iter_skip)"

it "iter_worktree_run_records: run_id falls back to the filename stem when run_record has no run_id"
assert_eq "stemname" "$(probe_scan iter_runid_fallback)"

it "iter_worktree_run_records: U1 finding A — a lone rules.json config yields ZERO runs (shape guard)"
assert_eq "RUNS:0" "$(probe_scan iter_config_only)"

it "iter_worktree_run_records: U1 finding A — real run beside rules.json → only the real run"
assert_eq "real-run" "$(probe_scan iter_config_mixed)"

# ── coerce_confidence (U6: the shared confidence clamp) ─────────────────────
# One clamp consolidated from two byte-identical private copies — a SAFETY gate
# (launch-gate) and the recommender. The load-bearing contract: a bad value must
# NEVER crash and must degrade toward LOW (0.0), never toward a high value that
# could green-light an accidental skip / autonomous dispatch. Type rejection
# (bool, non-numeric) can't be exercised through stringified CLI args, so the
# probe constructs the real Python values in-heredoc via scenario dispatch.
probe_coerce() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
val = {
    "bool": True,        # isinstance(True, int) is True — must still reject.
    "nonnum": "abc",     # non-numeric -> low.
    "neg": -0.5,         # below range -> clamp to 0.0.
    "over": 1.5,         # above range -> clamp to 1.0.
    "pass": 0.5,         # in-range, exactly representable -> passthrough.
}[sys.argv[2]]
print(b.coerce_confidence(val))
PYEOF
}

it "coerce_confidence: bool (True) -> 0.0 (rejected despite isinstance(True, int))"
assert_eq "0.0" "$(probe_coerce bool)"

it "coerce_confidence: non-numeric ('abc') -> 0.0 (degrades to low)"
assert_eq "0.0" "$(probe_coerce nonnum)"

it "coerce_confidence: below range (-0.5) -> 0.0 (clamp)"
assert_eq "0.0" "$(probe_coerce neg)"

it "coerce_confidence: above range (1.5) -> 1.0 (clamp)"
assert_eq "1.0" "$(probe_coerce over)"

it "coerce_confidence: valid in-range (0.5) -> passthrough as float"
assert_eq "0.5" "$(probe_coerce pass)"

# ── iter_active_runs (U7: the shared active-run scan) ───────────────────────
# One generator consolidated from two divergent _active_runs copies — auto-status
# yielded (run_id, led) tuples; auto-resume yielded bare run_id strings and dragged
# a dead `run_record` param. Both filtered `current_phase(led) != "done"` over
# iter_worktree_run_records. Load-bearing contract: yields the RICHER (run_id, led)
# tuple shape, drops done runs, and preserves iter_worktree_run_records' PATH sort so
# a mixed done/active dir proves filtering AND ordering in one assertion.
# Driver mirrors probe_scan: fresh tempdir, run-record files with a loop_phase field
# (current_phase reads loop_phase; "done" is filtered, anything else is active).
probe_active() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile, shutil
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
scenario = sys.argv[2]

def write(path, raw):
    with open(path, "w") as fh:
        fh.write(raw)

tmp = tempfile.mkdtemp(prefix="bootstrap-active-")
try:
    if scenario == "empty_dir":
        # .claude/auto exists but holds NO run-records → yields nothing, never raises.
        os.makedirs(os.path.join(tmp, ".claude", "auto"))
        got = list(b.iter_active_runs(tmp))
        print("NORAISE:%d" % len(got))
    elif scenario == "missing_dir":
        # No dispatch dir at all → also empty (delegates to iter_worktree_run_records).
        got = list(b.iter_active_runs(tmp))
        print("NORAISE:%d" % len(got))
    else:
        adir = os.path.join(tmp, ".claude", "auto")
        os.makedirs(adir)
        if scenario == "mixed":
            # Interleave by filename so ONE assertion proves filter + PATH sort:
            # a=active, b=done (filtered), c=active → expect "a-run c-run".
            write(os.path.join(adir, "a.json"), '{"run_id": "a-run", "loop_phase": "work"}')
            write(os.path.join(adir, "b.json"), '{"run_id": "b-run", "loop_phase": "done"}')
            write(os.path.join(adir, "c.json"), '{"run_id": "c-run", "loop_phase": "handoff"}')
            print(" ".join(rid for rid, _ in b.iter_active_runs(tmp)))
        elif scenario == "all_done":
            # Every run is done → active scan is empty.
            write(os.path.join(adir, "x.json"), '{"run_id": "x-run", "loop_phase": "done"}')
            write(os.path.join(adir, "y.json"), '{"run_id": "y-run", "loop_phase": "done"}')
            got = list(b.iter_active_runs(tmp))
            print("EMPTY:%d" % len(got))
        elif scenario == "tuple_shape":
            # Yields the richer (run_id, led) tuple, not a bare run_id string.
            write(os.path.join(adir, "one.json"), '{"run_id": "one-run", "loop_phase": "plan"}')
            (rid, led), = list(b.iter_active_runs(tmp))
            print("%s:%s" % (rid, isinstance(led, dict)))
        else:
            sys.exit("unknown active scenario: %s" % scenario)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

it "iter_active_runs: mixed done/active → only active yielded, in PATH-sorted order"
assert_eq "a-run c-run" "$(probe_active mixed)"

it "iter_active_runs: all runs done → yields nothing (every run filtered)"
assert_eq "EMPTY:0" "$(probe_active all_done)"

it "iter_active_runs: yields the richer (run_id, led) tuple, not a bare run_id"
assert_eq "one-run:True" "$(probe_active tuple_shape)"

it "iter_active_runs: empty dispatch dir → yields nothing, never raises"
assert_eq "NORAISE:0" "$(probe_active empty_dir)"

it "iter_active_runs: missing dispatch dir → yields nothing, never raises"
assert_eq "NORAISE:0" "$(probe_active missing_dir)"

# ── DRIVING_SESSION_KEY (U8: the shared advisor-gate run-record key) ────────────
# One definition consumed by the arm-time WRITER (run_record_mutators.set_driving_
# session_id) and BOTH PreToolUse hook READERS, which used to each inline the
# literal. The value is load-bearing: it IS the run-record field the destructive
# backstop matches session-id equality on, so a drift silently darkens the gate.
it "DRIVING_SESSION_KEY: is exactly 'driving_session_id' (writer/reader share one source)"
assert_eq "driving_session_id" "$(probe driving_session_key)"

# ── plan_step_sequencer (U10: the shared plan-loop sequencer) ───────────────
# One pure function both backends delegate to. CE injects
# ("plan","deepen","review_plan"); native injects ("plan","review_plan") — same
# coherence guard + None-tolerance, ONLY the sequence differs. These probe the
# shared function DIRECTLY (backend-severity.test.sh is the end-to-end guard).
#
# Driver: call plan_step_sequencer with a per-backend sequence + a run-record built
# from (plan_step, gaps_open). Prints the returned step.
seq_step() {
  # args: <backend: ce|native> <plan_step|null> <gaps_open>
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
backend, plan_step, gaps_open = sys.argv[2], sys.argv[3], int(sys.argv[4])
sequence = ("plan", "deepen", "review_plan") if backend == "ce" else ("plan", "review_plan")
run_record = {
    "plan_step": None if plan_step == "null" else plan_step,
    "exit_predicate_result": {"gaps_open": gaps_open},
}
print(b.plan_step_sequencer(run_record, sequence=sequence))
PYEOF
}

# CE full walk: plan -> deepen -> review_plan, loop-back to deepen.
it "plan_step_sequencer CE: fresh run_record (plan_step None) -> plan"
assert_eq "plan" "$(seq_step ce null 0)"
it "plan_step_sequencer CE: after plan -> deepen"
assert_eq "deepen" "$(seq_step ce plan 0)"
it "plan_step_sequencer CE: after deepen -> review_plan"
assert_eq "review_plan" "$(seq_step ce deepen 0)"
it "plan_step_sequencer CE: review_plan with gaps open -> deepen (loop-back)"
assert_eq "deepen" "$(seq_step ce review_plan 3)"

# native full walk: plan -> review_plan, loop-back to review_plan (NEVER deepen).
it "plan_step_sequencer native: fresh run_record (plan_step None) -> plan"
assert_eq "plan" "$(seq_step native null 0)"
it "plan_step_sequencer native: after plan -> review_plan (never deepen)"
assert_eq "review_plan" "$(seq_step native plan 0)"
it "plan_step_sequencer native: review_plan with gaps open -> review_plan (loop, never deepen)"
assert_eq "review_plan" "$(seq_step native review_plan 2)"

# §4.1 coherence guard: livelock case — review_plan + gaps_open==0 -> done.
it "plan_step_sequencer CE: coherence guard, review_plan + gaps_open==0 -> done"
assert_eq "done" "$(seq_step ce review_plan 0)"
it "plan_step_sequencer native: coherence guard, review_plan + gaps_open==0 -> done"
assert_eq "done" "$(seq_step native review_plan 0)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "_bootstrap.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
