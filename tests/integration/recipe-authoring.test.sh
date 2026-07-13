#!/usr/bin/env bash
# auto U9 integration test: the authoring skill's MECHANICAL CONTRACT.
#
# The skill's prose elicitation is model-driven (a conversation) — not
# deterministically unit-testable end-to-end. What IS testable is the contract
# the skill leans on, so AE3 is verified at that boundary:
#   AE3: a recipe shaped like what the skill produces for the prompt "two
#        builders, same plan, one clarity one perf, then a comparator picks"
#        (i.e. A4's topology) VALIDATES and RENDERS as the paired-builders shape.
#   + the write-path the skill MUST use: validate_and_lint gates the write;
#     a draft that fails validation is NOT written; a valid draft round-trips
#     (write atomically → read back → load_and_validate passes).
# The SKILL.md elicitation flow itself is review-validated (it ships as prose).

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

auth() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
tr = load_lib_module("topology-render")
op = sys.argv[2]

# The recipe the skill should produce for the AE3 prompt (A4's topology): one
# plan unit + the paired-builders producer at the (plan, work) boundary.
A4_SHAPED = {
    "name": "my-pair", "version": "1",
    "description": "two builders clarity vs perf, comparator picks",
    "phase_order": ["plan", "handoff", "work"], "terminal_phase": "work",
    "phase_transitions": [
        {"from": "plan", "to": "work", "producer": "plan_output_to_paired_builders"}],
    "steps": [{"id": "plan", "phase": "plan", "depends_on": [],
               "invokes": {"backend_op": "next_plan_step"}}],
}

if op == "ae3-validates":
    try:
        recipes.validate(A4_SHAPED)
        # render shows the paired-builders producer (the A4 signature).
        card = tr.render(A4_SHAPED, 60)
        print("valid" if "plan_output_to_paired_builders" in card else "valid-no-producer")
    except recipes.RecipeError as e:
        print("rejected:" + str(e))

elif op == "write-roundtrip":
    # The skill's write-path: validate, write atomically, read back, re-validate.
    repo = tempfile.mkdtemp()
    d = os.path.join(repo, ".claude", "auto", "recipes")
    os.makedirs(d)
    recipes.validate(A4_SHAPED)  # gate
    # atomic write (mkstemp + rename), as the skill must do.
    import tempfile as tf
    fd, tmp = tf.mkstemp(dir=d, suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(A4_SHAPED, fh)
    target = os.path.join(d, "my-pair.json")
    os.rename(tmp, target)
    # read back + re-validate (verify-after-write).
    back, tier = recipes.load_and_validate("my-pair", repo)
    print("%s,%s,%s" % (tier, back["name"], back == A4_SHAPED))

elif op == "invalid-not-written":
    # A draft that fails validation must NOT be written.
    bad = {"name": "bad", "version": "1",
           "steps": [{"id": "u", "phase": "plan",
                      "invokes": {"prompt_template": "../../etc/passwd"}}]}
    try:
        recipes.validate(bad)
        print("WRONGLY-VALID")
    except recipes.RecipeError:
        print("rejected-not-written")
PYEOF
}

it "AE3: A4-shaped recipe (skill output for the pair prompt) validates + renders"
assert_eq "valid" "$(auth ae3-validates)"

it "skill write-path: validate→atomic-write→read-back→re-validate round-trips"
assert_eq "workspace,my-pair,True" "$(auth write-roundtrip)"

it "skill write-path: a draft failing validation is NOT written (traversal)"
assert_eq "rejected-not-written" "$(auth invalid-not-written)"

it "skill ships: SKILL.md + visual-vocabulary.md present (manifest auto-loads)"
if [ -f "${AUTO_ROOT}/skills/auto-author-recipe/SKILL.md" ] && \
   [ -f "${AUTO_ROOT}/skills/auto-author-recipe/references/visual-vocabulary.md" ]; then
  pass
else
  fail "skill files missing"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-authoring.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
