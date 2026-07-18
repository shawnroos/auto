#!/usr/bin/env bash
# auto unit test: the KTD-4 DEPRECATED FLAG-ALIAS layer (concept-vocabulary rename).
#
# WHY THIS TEST EXISTS:
# The rename retired three /auto flag spellings but did NOT hard-cut them
# (docs/plans/2026-07-12-001-refactor-concept-vocabulary-rename-plan.md, KTD-4):
#
#     --adapter                      -> --backend                       (U4)
#     --recipe                       -> --workflow                      (U8)
#     --teardown-recipe-after-init   -> --teardown-workflow-after-init  (U8)
#
# They are kept one minor version as deprecated aliases because these are flags a
# MODEL composes from skill prose, and an in-flight run can be holding an older
# spelling inside a persisted ScheduleWakeup / rearm prompt — a hard cut would fail
# those runs at re-arm, in the one place the operator isn't watching.
#
# The alias layer had NO test before U8 (the U4 `--adapter` alias shipped unpinned).
# U8 collapsed three copy-pasted alias branches into one `_DEPRECATED_FLAGS` map +
# a single rewrite site in `_parse_args`; that refactor is only safe if the
# behavior is nailed down. So this pins the whole layer:
#
#   1. EQUIVALENCE   — the alias parses to the SAME result as its canonical flag,
#                      field for field. This is the actual compat guarantee.
#   2. ONE NOTICE    — using an alias emits exactly one stderr line naming BOTH the
#                      retired flag and its replacement (an operator must be able to
#                      fix their invocation from the notice alone).
#   3. SILENT CANON  — the canonical flag emits NOTHING on stderr. (A rewrite that
#                      accidentally routed every flag through the alias path would
#                      spam every clean run; equivalence alone would not catch it.)
#   4. ARITY         — a value-taking alias with no value still raises (it does not
#                      silently swallow the next flag).
#   5. SSOT          — the map holds exactly the three retired spellings, and no
#                      alias maps to another alias (a two-hop rewrite would leave a
#                      retired flag in the resolved args).
#
# Tests pin _parse_args directly (the same idiom as handoff-default.test.sh) — no
# run is spawned; the bound between flag-string and resolved dict is the claim.

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

# Probe: parse argv, print {args, stderr} as JSON. stderr is CAPTURED (not leaked)
# so the notice itself is an assertable value rather than test noise.
probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, io, contextlib, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        parsed = m._parse_args(sys.argv[2:])
except ValueError as e:
    print(json.dumps({"error": str(e), "stderr": err.getvalue()}, sort_keys=True))
else:
    print(json.dumps({"args": parsed, "stderr": err.getvalue()}, sort_keys=True))
PYEOF
}

# Extract one field from a probe's JSON.
field() { "$PY" -c 'import sys,json;print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }
# The parsed args, normalized (sorted keys) for equivalence comparison.
args_of() { "$PY" -c 'import sys,json;print(json.dumps(json.loads(sys.argv[1]).get("args"), sort_keys=True))' "$1"; }

echo "── 1. EQUIVALENCE: each alias parses identically to its canonical flag ──"

it "--recipe <name> parses identically to --workflow <name>"
assert_eq "$(args_of "$(probe plan.md --workflow a1)")" "$(args_of "$(probe plan.md --recipe a1)")"

it "--teardown-recipe-after-init parses identically to --teardown-workflow-after-init"
assert_eq "$(args_of "$(probe plan.md --teardown-workflow-after-init)")" \
          "$(args_of "$(probe plan.md --teardown-recipe-after-init)")"

it "--adapter <backend> parses identically to --backend <backend> (the U4 alias, previously unpinned)"
assert_eq "$(args_of "$(probe plan.md --backend native)")" "$(args_of "$(probe plan.md --adapter native)")"

it "the resolved args carry the CANONICAL keys (workflow/backend), never a retired one"
assert_eq '{"auto": true, "backend": "native", "goal": null, "plan": "plan.md", "teardown_workflow": true, "workflow": "a2"}' \
          "$(args_of "$(probe plan.md --recipe a2 --adapter native --teardown-recipe-after-init)")"

echo ""
echo "── 2/3. ONE deprecation notice per alias; the canonical flag is SILENT ──"

it "--recipe emits ONE stderr notice naming the retired flag AND its replacement"
r="$(field "$(probe plan.md --recipe a1)" stderr)"
assert_eq "auto: --recipe is deprecated; use --workflow" "$(printf '%s' "$r" | tr -d '\n')"

it "--teardown-recipe-after-init emits ONE stderr notice naming both flags"
r="$(field "$(probe plan.md --teardown-recipe-after-init)" stderr)"
assert_eq "auto: --teardown-recipe-after-init is deprecated; use --teardown-workflow-after-init" \
          "$(printf '%s' "$r" | tr -d '\n')"

it "--adapter emits ONE stderr notice naming both flags"
r="$(field "$(probe plan.md --adapter ce)" stderr)"
assert_eq "auto: --adapter is deprecated; use --backend" "$(printf '%s' "$r" | tr -d '\n')"

it "exactly ONE notice line per alias used (two aliases → two lines, not four)"
r="$(field "$(probe plan.md --recipe a1 --adapter ce)" stderr)"
assert_eq "2" "$(printf '%s' "$r" | grep -c 'is deprecated')"

it "the CANONICAL flags are silent — a clean invocation writes nothing to stderr"
r="$(field "$(probe plan.md --workflow a1 --backend ce --teardown-workflow-after-init)" stderr)"
assert_eq "" "$r"

echo ""
echo "── 4. ARITY: a value-taking alias with no value still raises ──"

it "--recipe with no value raises (does not silently swallow the next token)"
r="$(field "$(probe plan.md --recipe)" error)"
case "$r" in
  *"requires a value"*) pass ;;
  *) fail "expected a 'requires a value' ValueError, got '$r'" ;;
esac

it "--adapter with no value raises"
r="$(field "$(probe plan.md --adapter)" error)"
case "$r" in
  *"requires a value"*) pass ;;
  *) fail "expected a 'requires a value' ValueError, got '$r'" ;;
esac

echo ""
echo "── 5. SSOT: _DEPRECATED_FLAGS holds exactly the retired spellings, one hop ──"

it "_DEPRECATED_FLAGS maps exactly the three retired flags, and no alias maps to another alias"
ssot="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, json, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = m._DEPRECATED_FLAGS
# A canonical target must NOT itself be a retired spelling — otherwise one rewrite
# hop would leave a still-deprecated flag in `tok` and the notice would name a flag
# that is itself on the way out.
one_hop = all(v not in d for v in d.values())
print(json.dumps({"keys": sorted(d), "one_hop": one_hop}, sort_keys=True))
PYEOF
)"
assert_eq '{"keys": ["--adapter", "--recipe", "--teardown-recipe-after-init"], "one_hop": true}' "$ssot"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "flag-aliases.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
