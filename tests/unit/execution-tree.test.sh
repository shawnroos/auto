#!/usr/bin/env bash
# auto U6 unit test: lib/execution_tree.py::derive_execution_tree.
#
# SELF-CONTAINED inline harness (same style as recipes.test.sh): a python-
# invocation helper loads execution_tree via _bootstrap.load_lib_module and runs
# an op against the built-in recipe fixtures (recipes/a2.json, recipes/a4.json)
# or a small inline recipe dict.
#
# Scenarios (write, see FAIL, implement):
#   1. derive_execution_tree(a2, cap=16) → wave1 {plan-1,plan-2,plan-3}, wave2 {judge}
#      (a2's parallel units are STATIC — no emit-template expansion).
#   2. derive_execution_tree(a4, cap=16) → {plan} then the paired-builder wave
#      (build-clarity/build-perf synthesized from expected_emit_outputs) then
#      {compare}. Asserting the builders appear PROVES expansion happened.
#   3. cap=1 serializes a2's 3-wide parallel wave into 3 ordered waves.
#   4. a fan-out unit nests its expanded do_unit children under the emitter parent.
#   5. substrate heuristic: "workflow-script" for a bounded parallel-fan-in loop;
#      "subagent-tree" for a ce-work/review dispatch loop (a2/a4).

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

# Driver: load execution_tree via _bootstrap, derive a tree, print a stable signal.
et() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
xt = load_lib_module("execution_tree")
op = sys.argv[2]

def load_recipe(name):
    with open(os.path.join(auto_root, "recipes", name + ".json")) as f:
        return json.load(f)

def fmt_waves(res):
    # Deterministic, order-insensitive WITHIN a wave (sorted); wave ORDER matters.
    return "|".join(",".join(sorted(w)) for w in res["waves"])

# A minimal bounded parallel-fan-in loop with NO ce-work/review adapter op —
# the branch a2/a4 don't exercise (both carry review/do_unit). Single-phase +
# bounded + no ce-dispatch → workflow-script routing label.
def wfs_recipe():
    return {
        "name": "wfs", "version": "1",
        "phase_order": ["work"], "terminal_phase": "work",
        "units": [
            {"id": "map-1", "phase": "work", "depends_on": [], "invokes": {}},
            {"id": "map-2", "phase": "work", "depends_on": [], "invokes": {}},
            {"id": "reduce", "phase": "work",
             "depends_on": ["map-1", "map-2"], "invokes": {}},
        ],
        "iteration": {"gate_unit": "reduce", "bound": {"max_attempts": 3}},
    }

if op == "a2-waves":
    print(fmt_waves(xt.derive_execution_tree(load_recipe("a2"), 16)))
elif op == "a4-waves":
    print(fmt_waves(xt.derive_execution_tree(load_recipe("a4"), 16)))
elif op == "a2-cap1":
    print(fmt_waves(xt.derive_execution_tree(load_recipe("a2"), 1)))
elif op == "a4-nesting":
    res = xt.derive_execution_tree(load_recipe("a4"), 16)
    nest = res["nesting"]
    print(";".join("%s:%s" % (p, ",".join(sorted(c)))
                   for p, c in sorted(nest.items())))
elif op == "substrate":
    print(xt.derive_execution_tree(load_recipe(sys.argv[3]), 16)["substrate"])
elif op == "substrate-wfs":
    print(xt.derive_execution_tree(wfs_recipe(), 16)["substrate"])
elif op == "preview-deterministic":
    r = load_recipe("a4")
    a = xt.derive_execution_tree(r, 16)["preview"]
    b = xt.derive_execution_tree(r, 16)["preview"]
    print("same" if (a == b and a) else "differs")
PYEOF
}

# ─── Scenario 1: a2 static parallel wave + fan-in ───────────────────────────
it "derive_execution_tree(a2, cap=16): wave1 {plan-1,plan-2,plan-3}, wave2 {judge}"
assert_eq "plan-1,plan-2,plan-3|judge" "$(et a2-waves)"

# ─── Scenario 2: a4 emit-template expansion (builders synthesized) ───────────
# A raw frontier walk over a4 yields only {plan} (compare depends on emitter-
# produced build-clarity/build-perf which are NOT in units[]). The builders
# appearing in wave 2 proves the expected_emit_outputs expansion ran.
it "derive_execution_tree(a4, cap=16): {plan} then paired builders then {compare}"
assert_eq "plan|build-clarity,build-perf|compare" "$(et a4-waves)"

# ─── Scenario 3: cap=1 serializes the 3-wide parallel wave ──────────────────
it "derive_execution_tree(a2, cap=1): 3 ordered plan waves then {judge}"
assert_eq "plan-1|plan-2|plan-3|judge" "$(et a2-cap1)"

# ─── Scenario 4: fan-out do_unit children nest under the emitter parent ─────
it "a4: build-clarity/build-perf nest under their emitter parent (plan)"
assert_eq "plan:build-clarity,build-perf" "$(et a4-nesting)"

# ─── Scenario 5: substrate selection heuristic (both branches) ──────────────
it "substrate: a4 (do_unit + review dispatch) → subagent-tree"
assert_eq "subagent-tree" "$(et substrate a4)"

it "substrate: a2 (review fan-in dispatch) → subagent-tree"
assert_eq "subagent-tree" "$(et substrate a2)"

it "substrate: bounded parallel-fan-in loop, no ce-work/review op → workflow-script"
assert_eq "workflow-script" "$(et substrate-wfs)"

# ─── Determinism: the topology-render preview is stable ─────────────────────
it "topology preview is deterministic (same recipe → byte-identical preview)"
assert_eq "same" "$(et preview-deterministic)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "execution-tree.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
