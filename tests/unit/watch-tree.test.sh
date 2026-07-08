#!/usr/bin/env bash
# auto U4 unit test: lib/watch_tree.py — the deterministic agent-tree renderer.
#
# render_agent_tree(ledger, now) turns a live ledger into a compact ASCII tree
# of driver -> work unit -> do_unit fan-out agent, annotating each dispatched
# node with age-vs-threshold + attempt, and nesting do_unit children under their
# emitter parent. It is PURE (now is passed in as an ISO-8601 string, never
# datetime.now()) so a fixed ledger + fixed now yields byte-identical output.
#
# SELF-CONTAINED inline harness (same style as recipes.test.sh): fixtures are
# built as minimal ledger dicts with a PINNED `now`, so age/over-age/determinism
# are fully controlled (no wall-clock).
#
# Scenarios (mapped to the U4 plan):
#   1. nests a do_unit child under its parent fan-out unit
#   2. flags a past-threshold dispatched node as over-age (age > threshold)
#   3. shows the attempt count for a dispatched node
#   4. BYTE-IDENTICAL output for a fixed ledger + fixed now (determinism)
#   5. empty/no-dispatched ledger renders the empty-tree sentinel

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

# Driver: load watch_tree via _bootstrap, build a fixture ledger, run a scenario
# op, print a stable signal for assertion. Pinned `now` keeps every age exact.
wt() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
watch_tree = load_lib_module("watch_tree")
op = sys.argv[2]

NOW = "2026-07-08T12:00:00Z"

def unit(uid, **kw):
    u = {"id": uid, "state": kw.get("state", "pending"),
         "depends_on": kw.get("depends_on", []),
         "attempt": kw.get("attempt", 0),
         "stall_threshold_seconds": kw.get("stall_threshold_seconds", 600)}
    if "dispatched_at" in kw:
        u["dispatched_at"] = kw["dispatched_at"]
    if kw.get("do_unit"):
        # Materialized do_unit units carry adapter_op on dispatch_context (the
        # invokes->dispatch_context merge in recipes.unit_for). The renderer also
        # honors a raw `invokes.adapter_op`, but dispatch_context is the on-disk
        # shape (init_ledger's _normalize_unit drops a bare `invokes`).
        u["dispatch_context"] = {"adapter_op": "do_unit"}
    return u

def ledger(units, run_id="run-x"):
    return {"run_id": run_id, "units": units}

def indent_of(line):
    return len(line) - len(line.lstrip())

def node_line(out, uid):
    for ln in out.splitlines():
        if ln.lstrip().startswith("• " + uid + "  "):
            return ln
    return None

if op == "nest":
    # A fan-out parent (dispatched) with one do_unit child depending on it, plus
    # an independent root sibling. The child must render INDENTED under the parent.
    led = ledger([
        unit("parent", state="dispatched", dispatched_at="2026-07-08T11:59:00Z", attempt=1),
        unit("child", state="dispatched", dispatched_at="2026-07-08T11:59:00Z",
             attempt=1, depends_on=["parent"], do_unit=True),
        unit("sibling", state="pending"),
    ])
    out = watch_tree.render_agent_tree(led, NOW)
    lines = out.splitlines()
    p = node_line(out, "parent"); c = node_line(out, "child")
    if p is None or c is None:
        print("MISSING")
    else:
        deeper = indent_of(c) > indent_of(p)
        after = lines.index(c) > lines.index(p)
        print("nested" if (deeper and after) else "flat")

elif op == "over-age":
    # One dispatched unit dispatched 3600s before `now` with a 600s threshold
    # (age > threshold -> OVER-AGE) and one dispatched only 60s ago (under).
    led = ledger([
        unit("stale", state="dispatched", dispatched_at="2026-07-08T11:00:00Z",
             attempt=2, stall_threshold_seconds=600),
        unit("fresh", state="dispatched", dispatched_at="2026-07-08T11:59:00Z",
             attempt=1, stall_threshold_seconds=600),
    ])
    out = watch_tree.render_agent_tree(led, NOW)
    print("%s,%s" % ("OVER-AGE" in node_line(out, "stale"),
                     "OVER-AGE" in node_line(out, "fresh")))

elif op == "attempt":
    # A dispatched node on its 3rd attempt surfaces attempt=3 in its annotation.
    led = ledger([
        unit("u", state="dispatched", dispatched_at="2026-07-08T11:59:00Z", attempt=3),
    ])
    out = watch_tree.render_agent_tree(led, NOW)
    print("present" if "attempt=3" in node_line(out, "u") else "absent")

elif op == "determinism":
    # Byte-identical output for a fixed ledger + fixed now across two renders.
    led = ledger([
        unit("parent", state="dispatched", dispatched_at="2026-07-08T11:00:00Z", attempt=1),
        unit("child", state="dispatched", dispatched_at="2026-07-08T11:59:00Z",
             attempt=2, depends_on=["parent"], do_unit=True),
        unit("judge", state="verdict-returned", depends_on=["parent"]),
    ])
    a = watch_tree.render_agent_tree(led, NOW)
    b = watch_tree.render_agent_tree(led, NOW)
    print("same" if a == b else "differs")

elif op == "empty":
    # No dispatched units anywhere -> the empty-tree sentinel, and the pending
    # unit id does NOT appear (the sentinel short-circuits the node walk).
    led = ledger([
        unit("p1", state="pending"),
        unit("v1", state="verdict-returned"),
    ])
    out = watch_tree.render_agent_tree(led, NOW)
    print("%s,%s" % ("(no dispatched units)" in out, "p1" in out))
PYEOF
}

echo "watch-tree.test.sh"

it "nests a do_unit child under its parent fan-out unit"
assert_eq "nested" "$(wt nest)"

it "flags a past-threshold dispatched node as over-age; a fresh node is not flagged"
assert_eq "True,False" "$(wt over-age)"

it "shows the attempt count for a dispatched node"
assert_eq "present" "$(wt attempt)"

it "byte-identical output for a fixed ledger + fixed now (determinism)"
assert_eq "same" "$(wt determinism)"

it "empty/no-dispatched ledger renders the empty-tree sentinel (node walk short-circuited)"
assert_eq "True,False" "$(wt empty)"

echo ""
echo "watch-tree.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
