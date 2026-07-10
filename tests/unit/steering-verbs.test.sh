#!/usr/bin/env bash
# auto U1+U2 unit test: agent steering surface — grammar edges + force_skip.
#
# SELF-CONTAINED (same convention as tests/unit/ledger-mutators.test.sh): inline
# it/pass/fail helpers, HOME isolation, python driver ops. Does NOT source shared
# helpers.
#
# Scenarios:
#   1. grammar: pending -> terminal-skip is a legal edge (U1)
#   2. grammar: verdict-returned -> terminal-skip is a legal edge (U1)
#   3. grammar: terminal-skip -> pending still rejected (terminal sink holds)
#   4. AE6: force_skip WITHOUT a reason is rejected (R20)
#   5. AE6: force_skip WITH a reason persists the reason and reaches terminal-skip
#   6. AE5: force_skip of a verdict-returned unit carrying a blocker leaves
#      met == false — a skip cannot bury a finding (R16)
#   7. force_skip of the last pending unit CAN clear the predicate (BLOCKER-1
#      resolution: dropping obsolete work is the capability being bought)
#   8. lock discipline: force_skip routes through _with_locked_ledger exactly once
#      and touches the ledger nowhere outside that closure (KTD-2)

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
ledger_py = os.path.join(os.environ["AUTO_ROOT"], "lib", "ledger.py")
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
core = m.ledger_core
pred = m.ledger_predicate
mut = m.ledger_mutators

repo = os.environ["REPO"]
op = sys.argv[1]


def fresh(run, units):
    p = m.ledger_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    m.init_ledger(repo, run, adapter="ce", loop_phase="work",
                  phase_order=["plan", "seam", "work"], terminal_phase="work",
                  units=units)
    return m.read_ledger(repo, run)


U = lambda i: {"id": i, "state": "pending", "phase": "work"}

if op == "edge-pending-to-skip":
    fresh("s1", [U("a")])
    try:
        m.force_skip(repo, "s1", "a", reason="obsolete")
        led = m.read_ledger(repo, "s1")
        print(led["units"][0]["state"])
    except core.InvalidTransition as e:
        print(f"rejected:{e}")

elif op == "edge-verdict-to-skip":
    fresh("s2", [U("a")])
    m.transition(repo, "s2", "a", "dispatched")
    m.record_verdict(repo, "s2", "a", [])
    m.force_skip(repo, "s2", "a", reason="superseded")
    print(m.read_ledger(repo, "s2")["units"][0]["state"])

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
        except (ValueError, core.LedgerError):
            continue
    else:
        print("rejected")

elif op == "skip-reason-persists":
    fresh("s5", [U("a")])
    m.force_skip(repo, "s5", "a", reason="upstream dropped this")
    u = m.read_ledger(repo, "s5")["units"][0]
    print(json.dumps({"state": u["state"], "reason": u.get("skip_reason")}))

elif op == "skip-cannot-bury-finding":
    # AE5: a verdict-returned unit carrying a blocker, force-skipped, must NOT
    # let the run go done — the finding still counts.
    fresh("s6", [U("a"), U("b")])
    m.transition(repo, "s6", "a", "dispatched")
    m.record_verdict(repo, "s6", "a",
                     [{"severity": "blocker", "summary": "boom"}])
    m.force_skip(repo, "s6", "a", reason="ignore the blocker")
    m.force_skip(repo, "s6", "b", reason="obsolete")
    led = m.read_ledger(repo, "s6")
    print(json.dumps({
        "a_terminal": pred.unit_is_terminal(led["units"][0]),
        "met": led["exit_predicate_result"]["met"],
    }))

elif op == "skip-can-clear-predicate":
    # BLOCKER-1 resolution: skipping un-run work legitimately clears the floor.
    fresh("s7", [U("a"), U("b")])
    m.transition(repo, "s7", "a", "dispatched")
    m.record_verdict(repo, "s7", "a", [])
    m.force_skip(repo, "s7", "b", reason="obsolete")
    led = m.read_ledger(repo, "s7")
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
    # KTD-2 / I-1: force_skip must enter _with_locked_ledger exactly once and
    # perform no ledger read/write outside that closure.
    import ast, inspect
    src = inspect.getsource(mut.force_skip)
    tree = ast.parse(src.lstrip())
    names = [n.func.attr if isinstance(n.func, ast.Attribute) else
             getattr(n.func, "id", "")
             for n in ast.walk(tree) if isinstance(n, ast.Call)]
    locked = names.count("_with_locked_ledger")
    leaks = [n for n in names
             if n in ("read_ledger", "_atomic_write", "_read_ledger")]
    print(json.dumps({"locked": locked, "leaks": leaks}))
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

it "KTD-2: force_skip enters _with_locked_ledger once, leaks no I/O"
assert_eq '{"locked": 1, "leaks": []}' "$(driver lock-discipline)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "steering-verbs.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
