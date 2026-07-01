#!/usr/bin/env bash
# auto launch-chooser (agent-native Gap 3): `auto.sh ... --teardown-recipe-after-init`
# makes auto.py delete the run-scoped WORKSPACE recipe itself, atomically once the
# ledger is initialized — so the chooser never infers "ledger initialized" from
# stdout. This pins: (a) WITH the flag the workspace recipe file is gone after a
# successful run-create and the ledger still exists; (b) WITHOUT the flag the file
# remains (the flag is what triggers teardown, not a side effect).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
AUTO_SH="${AUTO_ROOT}/lib/auto.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n      %s\n" "$CURRENT" "${1:-}"; return 0; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

SANDBOX="$(mktemp -d -t auto-teardown.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
export HOME="$SANDBOX"                 # isolate the global recipe tier
RECIPES_DIR="${SANDBOX}/.claude/auto/recipes"
LEDGER_DIR="${SANDBOX}/.claude/auto"
mkdir -p "$RECIPES_DIR"

PLAN="${SANDBOX}/plan.md"
printf '# Teardown test plan\n\nA minimal plan/spec for the run-create path.\n' > "$PLAN"

# Write a valid run-scoped workspace recipe by resolving a built-in and renaming
# it to the run-scoped stem (mirrors what the chooser compiles, minus the gates).
write_variant() {  # write_variant <stem>
  "$PY" - "$AUTO_ROOT" "$RECIPES_DIR" "$1" <<'PYEOF'
import sys, os, json
auto_root, recipes_dir, stem = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
recipe, _tier = recipes.resolve("a2", auto_root)   # a valid built-in topology
recipe = dict(recipe); recipe["name"] = stem
recipe["description"] = "run-scoped variant for the teardown test (distinct desc)"
with open(os.path.join(recipes_dir, stem + ".json"), "w") as fh:
    json.dump(recipe, fh)
PYEOF
}

run_auto() {  # run_auto "<arg string>"  -> runs auto.sh, repo pinned to sandbox
  CLAUDE_AUTO_REPO="$SANDBOX" CLAUDE_CODE_SESSION_ID="sess-teardown-test" \
    bash "$AUTO_SH" "$1" >/dev/null 2>&1
}

ledger_count() { ls "${LEDGER_DIR}"/*.json 2>/dev/null | grep -v '/recipes/' | wc -l | tr -d ' '; }

# ── 1. WITH the flag: recipe file is deleted, ledger still created ────────────
write_variant "a2-teardown-a"
rm -f "${LEDGER_DIR}"/*.json 2>/dev/null || true
run_auto "${PLAN} --recipe a2-teardown-a --teardown-recipe-after-init"
it "with --teardown-recipe-after-init: the workspace recipe file is gone post-init"
[ -f "${RECIPES_DIR}/a2-teardown-a.json" ] && fail "recipe file still present" || pass
it "with --teardown-recipe-after-init: the run ledger was still created"
[ "$(ledger_count)" -ge 1 ] && pass || fail "no ledger created"

# ── 2. WITHOUT the flag: recipe file remains (teardown is opt-in) ────────────
write_variant "a2-teardown-b"
rm -f "${LEDGER_DIR}"/*.json 2>/dev/null || true
run_auto "${PLAN} --recipe a2-teardown-b"
it "without the flag: the run ledger was created (control run succeeded)"
# Gate the control on success: without this, 'file remains' would pass even if
# run_auto bailed BEFORE init (leaving the file for the wrong reason), making the
# with-vs-without contrast meaningless.
[ "$(ledger_count)" -ge 1 ] && pass || fail "no ledger — control run failed, so 'file remains' proves nothing"
it "without the flag: the workspace recipe file remains (opt-in teardown)"
[ -f "${RECIPES_DIR}/a2-teardown-b.json" ] && pass || fail "recipe file was deleted without the flag"

echo ""
echo "auto-teardown-recipe.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
