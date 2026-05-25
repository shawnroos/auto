#!/usr/bin/env bash
# auto U2/U3/U7 unit test: lib/recipes.py (validator + registry + A1_BUILTIN)
# and lib/topology-render.py.
#
# SELF-CONTAINED inline harness (same style as ledger.test.sh).
#
# Scenarios (U2 validate + U7 built-ins/constant/renderer; U3 resolver scenarios
# are added when U3 lands):
#   1. each built-in recipe (a1/a2/a4/w) validates
#   2. A1_BUILTIN equals the resolved a1.json topology (no drift) + validates
#   3. validate rejections: unknown field, bad emitter, traversal, non-default
#      phase_order (A3), missing required, depends_on integrity
#   4. work-only ([work]) accepted; reserved python_hook accepted
#   5. topology-render: deterministic, renders each built-in, names the emitter

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

# Driver: load recipes + topology-render via _bootstrap, run an op, print result.
rec() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
op = sys.argv[2]

def vresult(d):
    try:
        recipes.validate(d); return "valid"
    except recipes.RecipeError as e:
        return "rejected"

if op == "validate-builtins":
    out = []
    for name in ("a1", "a2", "a4", "w"):
        with open(os.path.join(auto_root, "recipes", name + ".json")) as f:
            out.append(name + ":" + vresult(json.load(f)))
    print(",".join(out))
elif op == "a1-no-drift":
    with open(os.path.join(auto_root, "recipes", "a1.json")) as f:
        disk = json.load(f)
    same = recipes.A1_BUILTIN == disk
    valid = vresult(recipes.A1_BUILTIN)
    print("%s,%s" % (same, valid))
elif op == "validate-json":
    print(vresult(json.loads(sys.argv[3])))
elif op == "render-builtin":
    tr = load_lib_module("topology-render")
    with open(os.path.join(auto_root, "recipes", sys.argv[3] + ".json")) as f:
        card = tr.render(json.load(f), 60)
    # print a few stable signals: contains the recipe name, the emitter, phase labels
    sigs = []
    sigs.append("name" if ("recipe: " + sys.argv[3]) in card else "NONAME")
    sigs.append("PLAN" if "PLAN" in card.upper() else "noplan")
    sigs.append("emit" if "emit:" in card else "noemit")
    print(",".join(sigs))
elif op == "render-deterministic":
    tr = load_lib_module("topology-render")
    with open(os.path.join(auto_root, "recipes", "a1.json")) as f:
        d = json.load(f)
    print("same" if tr.render(d, 60) == tr.render(d, 60) else "differs")
PYEOF
}

# ─── Scenario 1: built-ins validate ─────────────────────────────────────────
it "all four built-in recipes (a1/a2/a4/w) validate"
assert_eq "a1:valid,a2:valid,a4:valid,w:valid" "$(rec validate-builtins)"

# ─── Scenario 2: A1_BUILTIN no-drift + validates ────────────────────────────
it "A1_BUILTIN equals resolved a1.json AND validates (no drift)"
assert_eq "True,valid" "$(rec a1-no-drift)"

# ─── Scenario 3: validate rejections ────────────────────────────────────────
it "unknown top-level field rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[],"bogus":1}')"

it "reserved python_hook accepted (R3)"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[],"python_hook":"x"}')"

it "non-default phase_order (A3 grammar) rejected in V1"
assert_eq "rejected" "$(rec validate-json '{"name":"a3","version":"1","phase_order":["work_sketch","review","plan","work_refine"],"terminal_phase":"work_refine","units":[]}')"

it "work-only phase_order [work] accepted (KTD-15)"
assert_eq "valid" "$(rec validate-json '{"name":"w","version":"1","phase_order":["work"],"terminal_phase":"work","units":[]}')"

it "unregistered emitter name rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"plan","phase":"plan","invokes":{}}],"phase_transitions":[{"from":"plan","to":"work","emitter":"nope"}]}')"

it "prompt_template path traversal rejected (security Finding 1)"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"u","phase":"plan","invokes":{"prompt_template":"../../etc/passwd"}}]}')"

it "depends_on referencing unknown unit rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"u","phase":"plan","depends_on":["ghost"],"invokes":{}}]}')"

it "missing required field (units) rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1"}')"

# ─── Scenario 5: topology-render ────────────────────────────────────────────
it "topology-render: a1 card names recipe + has PLAN + names emitter"
assert_eq "name,PLAN,emit" "$(rec render-builtin a1)"

it "topology-render: deterministic (same input → same output)"
assert_eq "same" "$(rec render-deterministic)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
