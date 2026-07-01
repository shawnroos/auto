#!/usr/bin/env bash
# auto U1 unit test: lib/topology-render.py::render_comparison + the
# lib/recipes-list.sh --compare shell surface (the launch chooser's contrast
# block, KTD-2/KTD-3).
#
# SELF-CONTAINED inline harness (same style as recipes.test.sh).
#
# Scenarios:
#   1. Happy path: two built-ins (a1, a4) → both cards present, in input order,
#      separated, neither marked when highlight=None.
#   2. (Covers AE3) highlight="a2" among [a2, a4] → only the a2 card carries the
#      ► recommended marker; a4 does not.
#   3. Edge: single-recipe list → one card, no separator artifacts.
#   4. Edge: highlight names a recipe not in the list → no marker, no crash.
#   5. Determinism: identical inputs → byte-identical output across two calls.
#   6. Shell: recipes-list.sh --compare a1 w --highlight w exits 0 and prints
#      both cards with w marked.

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

# Driver: load topology-render via _bootstrap, render_comparison over named
# built-in recipe files, emit a stable signal token per op.
cmp_op() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
tr = load_lib_module("topology-render")
op = sys.argv[2]

MARK = "► recommended"

def load(name):
    with open(os.path.join(auto_root, "recipes", name + ".json")) as f:
        return json.load(f)

def card_order(out):
    # Names in the order their "recipe: <name>" header appears in the output.
    order = []
    for line in out.splitlines():
        if line.startswith("recipe: "):
            order.append(line[len("recipe: "):].strip())
    return order

if op == "two-no-highlight":
    out = tr.render_comparison([load("a1"), load("a4")], highlight=None)
    markers = out.count(MARK)
    order = card_order(out)
    # rule separator present between the two cards (60-wide horizontal rule)
    sep = ("─" * 60) in out
    print("markers=%d,order=%s,sep=%s" % (markers, "+".join(order), sep))

elif op == "highlight-a2":
    out = tr.render_comparison([load("a2"), load("a4")], highlight="a2")
    markers = out.count(MARK)
    # The line immediately after the marker must be the a2 card header.
    lines = out.splitlines()
    idx = lines.index(MARK)
    after = lines[idx + 1] if idx + 1 < len(lines) else ""
    # a4's card must NOT be marked: no marker appears in the a4 block.
    a4_block = out.split("─" * 60, 1)[1] if ("─" * 60) in out else ""
    a4_marked = MARK in a4_block
    print("markers=%d,after=%s,a4marked=%s" % (markers, after, a4_marked))

elif op == "single":
    out = tr.render_comparison([load("a1")])
    headers = sum(1 for ln in out.splitlines() if ln.startswith("recipe: "))
    sep = ("─" * 60) in out
    markers = out.count(MARK)
    # Must equal a bare render() of the same recipe (no wrapping artifacts).
    same_as_render = (out == tr.render(load("a1"), 60))
    print("headers=%d,sep=%s,markers=%d,bare=%s"
          % (headers, sep, markers, same_as_render))

elif op == "highlight-absent":
    # highlight names a recipe not among the candidates → no marker, no crash.
    out = tr.render_comparison([load("a1"), load("a4")], highlight="zzz-nope")
    print("markers=%d,order=%s" % (out.count(MARK), "+".join(card_order(out))))

elif op == "determinism":
    a = tr.render_comparison([load("a1"), load("a4")], highlight="a4")
    b = tr.render_comparison([load("a1"), load("a4")], highlight="a4")
    print("same" if a == b else "differs")
PYEOF
}

# ─── Scenario 1: happy path, two cards, no highlight ────────────────────────
it "two cards (a1,a4) no highlight → both present, input order, separated, no marker"
assert_eq "markers=0,order=a1+a4,sep=True" "$(cmp_op two-no-highlight)"

# ─── Scenario 2 (Covers AE3): highlight marks exactly the named card ────────
it "highlight=a2 among [a2,a4] → one marker, immediately before a2's card, a4 unmarked"
assert_eq "markers=1,after=recipe: a2,a4marked=False" "$(cmp_op highlight-a2)"

# ─── Scenario 3: single recipe → one card, no separator artifacts ───────────
it "single-recipe list → one card, no separator, no marker, identical to bare render()"
assert_eq "headers=1,sep=False,markers=0,bare=True" "$(cmp_op single)"

# ─── Scenario 4: highlight not in list → no marker, no crash ────────────────
it "highlight names absent recipe → no marker emitted, still renders both cards"
assert_eq "markers=0,order=a1+a4" "$(cmp_op highlight-absent)"

# ─── Scenario 5: determinism ────────────────────────────────────────────────
it "identical inputs → byte-identical output across two calls"
assert_eq "same" "$(cmp_op determinism)"

# ─── Scenario 6: shell --compare surface ────────────────────────────────────
SHELL_OUT="$(bash "${AUTO_ROOT}/lib/recipes-list.sh" --compare a1 w --highlight w 2>/dev/null)"
SHELL_RC=$?

it "shell --compare a1 w --highlight w exits 0"
assert_eq "0" "$SHELL_RC"

it "shell --compare prints both cards (a1 and w headers present)"
A1_PRESENT=$(printf '%s\n' "$SHELL_OUT" | grep -c "^recipe: a1$")
W_PRESENT=$(printf '%s\n' "$SHELL_OUT" | grep -c "^recipe: w$")
assert_eq "1 1" "$A1_PRESENT $W_PRESENT"

it "shell --compare marks the highlighted recipe (w) exactly once"
MARK_COUNT=$(printf '%s\n' "$SHELL_OUT" | grep -c "► recommended")
assert_eq "1" "$MARK_COUNT"

it "shell --compare: the marker precedes the w card (w is the highlighted one)"
# Line number of the marker is exactly one above the 'recipe: w' header.
MARK_LINE=$(printf '%s\n' "$SHELL_OUT" | grep -n "► recommended" | head -1 | cut -d: -f1)
W_LINE=$(printf '%s\n' "$SHELL_OUT" | grep -n "^recipe: w$" | head -1 | cut -d: -f1)
assert_eq "1" "$((W_LINE - MARK_LINE))"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "topology-render-comparison.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
