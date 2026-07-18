#!/usr/bin/env bash
# auto U1+U2 unit test: agent steering surface — grammar edges + force_skip.
#
# SELF-CONTAINED (same convention as tests/unit/run-record-mutators.test.sh): inline
# it/pass/fail helpers, HOME isolation, python driver ops. Does NOT source shared
# helpers.
#
# Scenarios:
#   1. grammar: pending -> terminal-skip is a legal edge (U1)
#   2. grammar: verdict-returned -> terminal-skip is a legal edge (U1)
#   3. grammar: terminal-skip -> pending still rejected (terminal sink holds)
#   4. AE6: force_skip WITHOUT a reason is rejected (R20)
#   5. AE6: force_skip WITH a reason persists the reason and reaches terminal-skip
#   6. AE5: force_skip of a verdict-returned step carrying a blocker leaves
#      met == false — a skip cannot bury a finding (R16)
#   7. force_skip of the last pending step CAN clear the predicate (BLOCKER-1
#      resolution: dropping obsolete work is the capability being bought)
#   8. lock discipline: force_skip routes through _with_locked_run_record exactly once
#      and touches the run-record nowhere outside that closure (KTD-2)

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
assert_eq() {
  if [ "$1" = "$2" ]; then pass; else fail "expected: $1
      actual:   $2"; fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
REPO="$TMPROOT/repo"
mkdir -p "$REPO/.claude/auto"

driver() {
  AUTO_ROOT="$AUTO_ROOT" REPO="$REPO" "$PY" - "$1" <<'PYEOF'
import json, os, sys, importlib.util
run_record_py = os.path.join(os.environ["AUTO_ROOT"], "lib", "run_record.py")
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
core = m.run_record_core
pred = m.run_record_predicate
mut = m.run_record_steering  # the steering verbs moved out of run_record_mutators

repo = os.environ["REPO"]
op = sys.argv[1]


def fresh(run, steps):
    p = m.run_record_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    m.init_run_record(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=steps)
    return m.read_run_record(repo, run)


U = lambda i: {"id": i, "state": "pending", "phase": "work"}


def lock_report(fn):
    # KTD-2 / I-1 structural check, shared by the add_step + reshape_deps
    # lock-discipline ops: a mutator must enter _with_locked_run_record exactly once
    # and touch the run-record NOWHERE outside that closure (no raw read_run_record /
    # _atomic_write / _read_run_record call leaks the RMW out from under the flock).
    import ast, inspect
    tree = ast.parse(inspect.getsource(fn).lstrip())
    names = [n.func.attr if isinstance(n.func, ast.Attribute) else
             getattr(n.func, "id", "")
             for n in ast.walk(tree) if isinstance(n, ast.Call)]
    return json.dumps({
        "locked": names.count("_with_locked_run_record"),
        "leaks": [n for n in names
                  if n in ("read_run_record", "_atomic_write", "_read_run_record")],
    })


if op == "edge-pending-to-skip":
    fresh("s1", [U("a")])
    try:
        m.force_skip(repo, "s1", "a", reason="obsolete")
        led = m.read_run_record(repo, "s1")
        print(led["steps"][0]["state"])
    except core.InvalidTransition as e:
        print(f"rejected:{e}")

elif op == "edge-verdict-to-skip":
    fresh("s2", [U("a")])
    m.transition(repo, "s2", "a", "dispatched")
    m.record_verdict(repo, "s2", "a", [])
    m.force_skip(repo, "s2", "a", reason="superseded")
    print(m.read_run_record(repo, "s2")["steps"][0]["state"])

elif op == "sink-holds":
    fresh("s3", [U("a")])
    m.force_skip(repo, "s3", "a", reason="x")
    try:
        m.transition(repo, "s3", "a", "pending")
        print("ACCEPTED-BUG")
    except core.InvalidTransition:
        print("rejected")

elif op == "skip-needs-reason":
    fresh("s4", [U("a")])
    for bad in (None, "", "   "):
        try:
            m.force_skip(repo, "s4", "a", reason=bad)
            print("ACCEPTED-BUG")
            break
        except (ValueError, core.RunRecordError):
            continue
    else:
        print("rejected")

elif op == "skip-reason-persists":
    fresh("s5", [U("a")])
    m.force_skip(repo, "s5", "a", reason="upstream dropped this")
    u = m.read_run_record(repo, "s5")["steps"][0]
    print(json.dumps({"state": u["state"], "reason": u.get("skip_reason")}))

elif op == "skip-cannot-bury-finding":
    # AE5: a verdict-returned step carrying a blocker, force-skipped, must NOT
    # let the run go done — the finding still counts.
    fresh("s6", [U("a"), U("b")])
    m.transition(repo, "s6", "a", "dispatched")
    m.record_verdict(repo, "s6", "a",
                     [{"severity": "blocker", "summary": "boom"}])
    m.force_skip(repo, "s6", "a", reason="ignore the blocker")
    m.force_skip(repo, "s6", "b", reason="obsolete")
    led = m.read_run_record(repo, "s6")
    print(json.dumps({
        "a_terminal": pred.step_is_terminal(led["steps"][0]),
        "met": led["exit_predicate_result"]["met"],
    }))

elif op == "skip-can-clear-predicate":
    # BLOCKER-1 resolution: skipping un-run work legitimately clears the floor.
    fresh("s7", [U("a"), U("b")])
    m.transition(repo, "s7", "a", "dispatched")
    m.record_verdict(repo, "s7", "a", [])
    m.force_skip(repo, "s7", "b", reason="obsolete")
    led = m.read_run_record(repo, "s7")
    print(json.dumps({"met": led["exit_predicate_result"]["met"]}))

elif op == "no-reasonless-bypass":
    # R20 cannot be bypassed: plain transition() must NOT reach terminal-skip
    # from pending / verdict-returned (it takes no reason). Only force_skip may.
    fresh("s8", [U("a")])
    try:
        m.transition(repo, "s8", "a", "terminal-skip")
        print("BYPASSED-BUG")
    except core.InvalidTransition:
        print("rejected")

elif op == "lock-discipline":
    # KTD-2 / I-1: force_skip must enter _with_locked_run_record exactly once and
    # perform no run-record read/write outside that closure.
    import ast, inspect
    src = inspect.getsource(mut.force_skip)
    tree = ast.parse(src.lstrip())
    names = [n.func.attr if isinstance(n.func, ast.Attribute) else
             getattr(n.func, "id", "")
             for n in ast.walk(tree) if isinstance(n, ast.Call)]
    locked = names.count("_with_locked_run_record")
    leaks = [n for n in names
             if n in ("read_run_record", "_atomic_write", "_read_run_record")]
    print(json.dumps({"locked": locked, "leaks": leaks}))

# ── U2 (rest): add_step / reshape_deps steering mutators ──────────────────────
elif op == "add-happy":
    # Happy path: the new step appears, state `pending`, normalized (carries the
    # full step shape — findings/depends_on keys present via _normalize_step).
    fresh("s9", [U("a"), U("b")])
    m.add_step(repo, "s9", "c")
    led = m.read_run_record(repo, "s9")
    c = next((u for u in led["steps"] if u["id"] == "c"), None)
    print(json.dumps({
        "count": len(led["steps"]),
        "state": c and c["state"],
        "phase": c and c["phase"],
        "normalized": c is not None and "findings" in c and "depends_on" in c
                      and "skip_reason" in c,
    }))

elif op == "add-with-dep":
    # A valid edge to an existing step is preserved verbatim.
    fresh("s9d", [U("a")])
    m.add_step(repo, "s9d", "c", depends_on=["a"])
    c = next(u for u in m.read_run_record(repo, "s9d")["steps"] if u["id"] == "c")
    print(json.dumps(c["depends_on"]))

elif op == "add-unknown-dep":
    # Reject a dependency on an unknown step; run-record unchanged (no partial add).
    fresh("s10", [U("a")])
    before = len(m.read_run_record(repo, "s10")["steps"])
    try:
        m.add_step(repo, "s10", "c", depends_on=["ghost"])
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        after = len(m.read_run_record(repo, "s10")["steps"])
        print("rejected" if after == before else f"MUTATED:{after}")

elif op == "add-duplicate":
    # Reject a duplicate step id; run-record unchanged.
    fresh("s11", [U("a")])
    before = len(m.read_run_record(repo, "s11")["steps"])
    try:
        m.add_step(repo, "s11", "a")
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        after = len(m.read_run_record(repo, "s11")["steps"])
        print("rejected" if after == before else f"MUTATED:{after}")

elif op == "reshape-happy":
    # Happy path: deps fully REPLACED with the new list.
    fresh("s12", [{"id": "a", "state": "pending", "phase": "work",
                   "depends_on": ["b"]}, U("b"), U("c")])
    m.reshape_deps(repo, "s12", "a", ["c"])
    a = next(u for u in m.read_run_record(repo, "s12")["steps"] if u["id"] == "a")
    print(json.dumps(a["depends_on"]))

elif op == "reshape-cycle":
    # a -> b already; reshaping b -> a would close a 2-cycle. Reject; b unchanged.
    fresh("s13", [{"id": "a", "state": "pending", "phase": "work",
                   "depends_on": ["b"]}, U("b")])
    try:
        m.reshape_deps(repo, "s13", "b", ["a"])
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        b = next(u for u in m.read_run_record(repo, "s13")["steps"] if u["id"] == "b")
        print("rejected" if b["depends_on"] == [] else f"MUTATED:{b['depends_on']}")

elif op == "reshape-unknown-dep":
    # Reject an edge to an unknown step; the step's deps stay as they were.
    fresh("s14", [U("a"), U("b")])
    try:
        m.reshape_deps(repo, "s14", "a", ["ghost"])
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        a = next(u for u in m.read_run_record(repo, "s14")["steps"] if u["id"] == "a")
        print("rejected" if a["depends_on"] == [] else f"MUTATED:{a['depends_on']}")

elif op == "reshape-self-cycle":
    # A self-edge is the degenerate 1-cycle; the shared detector must catch it.
    fresh("s15", [U("a")])
    try:
        m.reshape_deps(repo, "s15", "a", ["a"])
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        a = next(u for u in m.read_run_record(repo, "s15")["steps"] if u["id"] == "a")
        print("rejected" if a["depends_on"] == [] else f"MUTATED:{a['depends_on']}")

elif op == "lock-discipline-add":
    print(lock_report(mut.add_step))

elif op == "lock-discipline-reshape":
    print(lock_report(mut.reshape_deps))

elif op == "cli-init":
    fresh("cli1", [U("a")])
    print("ok")

elif op == "cli-state":
    print(m.read_run_record(repo, "cli1")["steps"][0]["state"])

elif op == "status-setup":
    fresh("st1", [U("a"), U("b")])
    m.transition(repo, "st1", "a", "dispatched")
    m.record_verdict(repo, "st1", "a", [])
    m.force_skip(repo, "st1", "b", reason="dropped upstream requirement")
    print("ok")

# ── U6: per-run policy steering verbs (set_retry_budget / set_stall_threshold) ─
elif op == "retry-budget-honored":
    # set_retry_budget writes step["retry_budget"]; dispatcher.should_escalate reads
    # it where present, else the settled default of 2 (backward-compatible).
    disp = m.load_lib_module("dispatcher")
    fresh("rb1", [U("a")])
    m.set_retry_budget(repo, "rb1", "a", 1)
    step = m.read_run_record(repo, "rb1")["steps"][0]
    step_at1 = {**step, "attempt": 1}          # budget 1, attempt 1 -> escalate
    default_at1 = {"id": "x", "attempt": 1}    # no budget, attempt 1 -> default 2 holds
    print(json.dumps({
        "budget": step["retry_budget"],
        "escalates_at_budget": disp.should_escalate(step_at1),
        "default_holds": disp.should_escalate(default_at1),
    }))

elif op == "retry-budget-rejects":
    fresh("rb2", [U("a")])
    try:
        m.set_retry_budget(repo, "rb2", "a", -1)
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        step = m.read_run_record(repo, "rb2")["steps"][0]
        print("rejected" if "retry_budget" not in step else "MUTATED")

elif op == "stall-threshold-set":
    fresh("stt", [U("a")])
    m.set_stall_threshold(repo, "stt", "a", 999)
    print(str(m.read_run_record(repo, "stt")["steps"][0]["stall_threshold_seconds"]))

elif op == "stall-threshold-rejects":
    fresh("stt2", [U("a")])
    before = m.read_run_record(repo, "stt2")["steps"][0].get("stall_threshold_seconds")
    try:
        m.set_stall_threshold(repo, "stt2", "a", 0)
        print("ACCEPTED-BUG")
    except core.RunRecordError:
        after = m.read_run_record(repo, "stt2")["steps"][0].get("stall_threshold_seconds")
        print("rejected" if after == before else "MUTATED")

elif op == "lock-discipline-retry-budget":
    print(lock_report(mut.set_retry_budget))

elif op == "lock-discipline-stall-threshold":
    print(lock_report(mut.set_stall_threshold))
PYEOF
}

echo "steering-verbs: U1 grammar edges + U2 force_skip"

it "U1: pending -> terminal-skip is a legal edge"
assert_eq "terminal-skip" "$(driver edge-pending-to-skip)"

it "U1: verdict-returned -> terminal-skip is a legal edge"
assert_eq "terminal-skip" "$(driver edge-verdict-to-skip)"

it "U1: terminal-skip remains a sink (terminal-skip -> pending rejected)"
assert_eq "rejected" "$(driver sink-holds)"

it "AE6: force_skip without a reason is rejected (R20)"
assert_eq "rejected" "$(driver skip-needs-reason)"

it "AE6: force_skip persists its reason"
assert_eq '{"state": "terminal-skip", "reason": "upstream dropped this"}' \
  "$(driver skip-reason-persists)"

it "AE5: force_skip cannot bury a blocker — met stays false"
assert_eq '{"a_terminal": true, "met": false}' \
  "$(driver skip-cannot-bury-finding)"

it "BLOCKER-1: force_skip of un-run work can clear the predicate"
assert_eq '{"met": true}' "$(driver skip-can-clear-predicate)"

it "R20 cannot be bypassed: plain transition() cannot reach terminal-skip"
assert_eq "rejected" "$(driver no-reasonless-bypass)"

it "KTD-2: force_skip enters _with_locked_run_record once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline)"

# ── U2 (rest): add_step ───────────────────────────────────────────────────────
it "R3: add_step appends a normalized pending step"
assert_eq '{"count": 3, "state": "pending", "phase": "work", "normalized": true}' \
  "$(driver add-happy)"

it "R3: add_step preserves a valid depends_on edge to an existing step"
assert_eq '["a"]' "$(driver add-with-dep)"

it "R3: add_step rejects a dependency on an unknown step (run_record unchanged)"
assert_eq "rejected" "$(driver add-unknown-dep)"

it "R3: add_step rejects a duplicate step id (run_record unchanged)"
assert_eq "rejected" "$(driver add-duplicate)"

it "KTD-2: add_step enters _with_locked_run_record once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline-add)"

# ── U2 (rest): reshape_deps ───────────────────────────────────────────────────
it "R3: reshape_deps replaces a step's depends_on"
assert_eq '["c"]' "$(driver reshape-happy)"

it "R3: reshape_deps rejects a change that would introduce a cycle (unchanged)"
assert_eq "rejected" "$(driver reshape-cycle)"

it "R3: reshape_deps rejects a self-edge (degenerate cycle, unchanged)"
assert_eq "rejected" "$(driver reshape-self-cycle)"

it "R3: reshape_deps rejects an edge to an unknown step (unchanged)"
assert_eq "rejected" "$(driver reshape-unknown-dep)"

it "KTD-2: reshape_deps enters _with_locked_run_record once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline-reshape)"

# ── U6: per-run policy steering verbs ─────────────────────────────────────────
it "U6: set_retry_budget persists; should_escalate honors it; default holds when unset"
assert_eq '{"budget": 1, "escalates_at_budget": true, "default_holds": false}' \
  "$(driver retry-budget-honored)"

it "U6: set_retry_budget rejects a negative budget (run_record unchanged)"
assert_eq "rejected" "$(driver retry-budget-rejects)"

it "U6: set_stall_threshold persists the per-step threshold"
assert_eq "999" "$(driver stall-threshold-set)"

it "U6: set_stall_threshold rejects a non-positive seconds (run_record unchanged)"
assert_eq "rejected" "$(driver stall-threshold-rejects)"

it "KTD-2: set_retry_budget enters _with_locked_run_record once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline-retry-budget)"

it "KTD-2: set_stall_threshold enters _with_locked_run_record once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline-stall-threshold)"

# ── U2 (rest): concurrency — add_step serializes under the shared flock ────────
# Mirrors run-record.test.sh scenario 4: N concurrent writers each add a DISTINCT
# step; under the lock every add lands (no lost update). The NO_LOCK deliberate-
# fail proves the race is real — without the flock the read-modify-append of the
# steps array clobbers, so at least one add is lost across the iterations. Both
# add_step and reshape_deps route through the SAME _with_locked_run_record primitive
# (the lock-discipline AST assertions above prove that), so serialization proven
# for add_step holds for reshape_deps too.
race_add() {
  # race_add <run> <n>   (honors CLAUDE_AUTO_TEST_NO_LOCK from env)
  local run="$1" n="$2" i pids=()
  for i in $(seq 1 "$n"); do
    AUTO_ROOT="$AUTO_ROOT" REPO="$REPO" "$PY" - "$run" "$i" <<'PYEOF' &
import os, sys, importlib.util
run_record_py = os.path.join(os.environ["AUTO_ROOT"], "lib", "run_record.py")
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.add_step(os.environ["REPO"], sys.argv[1], "w%s" % sys.argv[2])
PYEOF
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

mkbase() {
  # (re)create <run> with a single base step so adds start from a known count.
  rm -f "$REPO/.claude/auto/$1.json" "$REPO/.claude/auto/$1.lock"
  AUTO_ROOT="$AUTO_ROOT" REPO="$REPO" "$PY" - "$1" <<'PYEOF' >/dev/null 2>&1
import os, sys, importlib.util
run_record_py = os.path.join(os.environ["AUTO_ROOT"], "lib", "run_record.py")
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_run_record(os.environ["REPO"], sys.argv[1], backend="ce", loop_phase="work",
              phase_order=["plan", "handoff", "work"], terminal_phase="work",
              steps=[{"id": "base", "state": "pending", "phase": "work"}])
PYEOF
}

count_steps() {
  AUTO_ROOT="$AUTO_ROOT" REPO="$REPO" "$PY" - "$1" <<'PYEOF'
import os, sys, importlib.util
run_record_py = os.path.join(os.environ["AUTO_ROOT"], "lib", "run_record.py")
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.read_run_record(os.environ["REPO"], sys.argv[1])["steps"]))
PYEOF
}

it "locked: 6 concurrent add_step all land (count == 7, no lost update)"
mkbase "add-locked"
race_add "add-locked" 6
assert_eq "7" "$(count_steps add-locked)"

it "deliberate-fail: NO_LOCK concurrent add_step lose an add (count < 7 at least once / 20 iters)"
saw_lost=0
for iter in $(seq 1 20); do
  mkbase "add-nolock"
  CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_LOCK=1 race_add "add-nolock" 6
  c="$(count_steps add-nolock)"
  [ "$c" -lt 7 ] && saw_lost=1 && break
done
if [ "$saw_lost" = "1" ]; then
  pass
else
  fail "NO_LOCK add_step never lost an add across 20 iters — the race is not exercised, so the locked pass is not meaningful"
fi

# ── U2 (rest): CLI verbs (force-skip round-trip + blank-reason reject) ─────────
RUN_RECORD_CLI="$AUTO_ROOT/lib/run_record.py"

it "CLI: force-skip verb round-trips a step to terminal-skip"
driver cli-init >/dev/null
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" force-skip cli1 a "retired via cli" \
  >/dev/null 2>&1
assert_eq "terminal-skip" "$(driver cli-state)"

it "CLI: force-skip rejects a blank reason (exit != 0, step unchanged)"
driver cli-init >/dev/null
if CLAUDE_AUTO_REPO="$REPO" "$PY" "$RUN_RECORD_CLI" force-skip cli1 a "   " \
     >/dev/null 2>&1; then
  fail "blank reason accepted at the CLI"
else
  assert_eq "pending" "$(driver cli-state)"
fi

# ── U2 (rest): /auto-status renders a terminal-skip step's skip_reason (R20) ───
it "/auto-status renders skip_reason for a terminal-skip step"
driver status-setup >/dev/null
status_out="$(CLAUDE_AUTO_REPO="$REPO" "$PY" "$AUTO_ROOT/lib/auto-status.py" st1 2>&1)"
if printf '%s' "$status_out" | grep -q "dropped upstream requirement"; then
  pass
else
  fail "skip_reason not surfaced by /auto-status; got:
$status_out"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "steering-verbs.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
