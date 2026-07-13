#!/usr/bin/env bash
# auto U6 (R9) unit test: legible names alias the a1/a2/a4/w shorthand.
#
# A pure ALIAS layer — a legible name resolves to the SAME recipe as its
# shorthand stem; the stems and the A1_BUILTIN fallback constant are NEVER
# renamed (KTD-6). SELF-CONTAINED inline harness (same style as
# recipes.test.sh / ledger.test.sh).
#
# Legible name → stem aliases under test:
#   plan-build-review → a1      parallel-theories → a2
#   adversarial-pair  → a4      work-only         → w
#
# Scenarios:
#   1. Resolving a legible name returns the SAME recipe dict as its stem (R9).
#   2. Bare /auto still falls back to A1_BUILTIN when no a1.json resolves
#      (KTD-6 — the fallback path is intact; the alias inherits it too).
#   3. recommender routing still produces a resolvable recipe; the alias
#      round-trips (legible name resolves to the same recipe as the stem).
#   4. `recommender.py --check-agrees` agrees END TO END on an ALIAS-form
#      recommendation (not just set membership): the agent may pass the legible
#      name (skills/auto-launch §2 promotes it as primary); it must canonicalize
#      to its stem and reach the skip tier exactly where the bare stem does.
#   5. Every existing a1/a2/a4/w reference still resolves (no rename regression).
#   6. A recipe AUTHORED under a reserved alias name is rejected by validate()
#      (fail fast, not silently shadowed); the bare stems stay valid.
#   7. Drift guard: recipes._ALIASES == recipe_validate._RESERVED_ALIAS_STEMS
#      (the two copies of the reserved map can never diverge).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
REC="${AUTO_ROOT}/lib/recommender.py"

# Hermeticity (CodeRabbit): isolate HOME to a throwaway sandbox so resolve()'s
# GLOBAL tier (~/.claude/auto/recipes) can never read the developer's real
# recipes. The workspace tier already uses per-test tempdirs; the built-in tier
# reads the repo's own recipes/ (deterministic). Cleaned up on exit.
_HOME_SANDBOX="$(mktemp -d)"
export HOME="$_HOME_SANDBOX"
trap 'rm -rf "$_HOME_SANDBOX"' EXIT

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

# Driver: load lib modules via _bootstrap, run an op, print a stable signal.
drv() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
op = sys.argv[2]

# The alias → stem pairs under test (legible name, shorthand stem).
PAIRS = [
    ("plan-build-review", "a1"),
    ("parallel-theories", "a2"),
    ("adversarial-pair", "a4"),
    ("work-only", "w"),
]

def _resolve(name, repo):
    try:
        d, tier = recipes.resolve(name, repo)
        return d, tier, None
    except recipes.RecipeError as e:
        return None, None, str(e)

if op == "alias-parity":
    # Each legible name resolves to the SAME recipe dict (and tier) as its stem.
    repo = tempfile.mkdtemp()
    out = []
    for alias, stem in PAIRS:
        ad, at, aerr = _resolve(alias, repo)
        sd, st, serr = _resolve(stem, repo)
        if aerr is not None:
            out.append("%s=%s:ERROR" % (alias, stem))
        elif ad == sd and at == st:
            out.append("%s=%s:same" % (alias, stem))
        else:
            out.append("%s=%s:differ" % (alias, stem))
    print(",".join(out))

elif op == "fallback-intact":
    # KTD-6: with no a1.json anywhere (fresh repo, built-in dir untouched but the
    # constant path is the tested one), bare `a1` resolves to the A1_BUILTIN
    # constant at the built-in tier. The alias plan-build-review INHERITS that
    # fallback (it maps to the a1 stem BEFORE the file lookup + constant guard).
    repo = tempfile.mkdtemp()
    sd, st, _ = _resolve("a1", repo)
    ad, at, _ = _resolve("plan-build-review", repo)
    stem_ok = (sd == recipes.A1_BUILTIN and st == "built-in")
    alias_ok = (ad == recipes.A1_BUILTIN and at == "built-in")
    print("stem:%s,alias:%s" % (stem_ok, alias_ok))

elif op == "recommender-roundtrip":
    # The recommender's spine picks (a1 for clear-intent-no-plan, w for
    # reviewed-plan) still resolve; each stem's legible alias round-trips to the
    # SAME recipe name. Proves both stem and alias route after the change.
    recommender = load_lib_module("recommender")
    repo = tempfile.mkdtemp()
    alias_for = {stem: alias for alias, stem in PAIRS}
    out = []
    for state in ("clear-intent-no-plan", "reviewed-plan"):
        stem = recommender.recommend(state)["recipe_or_entry"]
        sd, _, serr = _resolve(stem, repo)
        alias = alias_for.get(stem)
        ad, _, aerr = _resolve(alias, repo) if alias else (None, None, "no-alias")
        ok = (serr is None and aerr is None and ad is not None
              and sd is not None and ad["name"] == sd["name"])
        out.append("%s->%s/%s:%s" % (state, stem, alias, "ok" if ok else "bad"))
    print(",".join(out))

elif op == "reserved-reject":
    # Finding 2: a recipe AUTHORED under a reserved alias name must be rejected by
    # validate() (fail fast) — resolve() would otherwise silently shadow it with
    # the stem's recipe. The bare stems (a1/w) are NOT reserved and stay valid.
    def vresult(name):
        try:
            recipes.validate({"name": name, "version": "1", "steps": []})
            return "%s:valid" % name
        except recipes.RecipeError:
            return "%s:rejected" % name
    checks = ["plan-build-review", "parallel-theories", "adversarial-pair",
              "work-only", "a1", "w"]
    print(",".join(vresult(n) for n in checks))

elif op == "reserved-drift":
    # Drift guard: the reserved-alias map copied into recipe_validate (the DAG
    # root, which can't import recipes without a cycle) MUST equal recipes._ALIASES
    # (the alias→stem SSOT). If a future edit adds/renames an alias in one place
    # only, this flips to "differ".
    rv = load_lib_module("recipe_validate")
    print("same" if recipes._ALIASES == rv._RESERVED_ALIAS_STEMS else "differ")

elif op == "stems-resolve":
    # No rename regression: every existing shorthand stem still resolves to a
    # recipe whose name is the stem, at the built-in tier.
    repo = tempfile.mkdtemp()
    out = []
    for stem in ("a1", "a2", "a4", "w"):
        d, tier, err = _resolve(stem, repo)
        if err is not None:
            out.append("%s:ERROR" % stem)
        else:
            out.append("%s:%s:%s" % (stem, d["name"], tier))
    print(",".join(out))
PYEOF
}

# ─── Scenario 1: alias↔stem parity ──────────────────────────────────────────
it "each legible name resolves to the SAME recipe dict as its shorthand stem (R9)"
assert_eq "plan-build-review=a1:same,parallel-theories=a2:same,adversarial-pair=a4:same,work-only=w:same" \
  "$(drv alias-parity)"

# ─── Scenario 2: A1_BUILTIN fallback intact (KTD-6) ─────────────────────────
it "bare /auto falls back to A1_BUILTIN with no a1.json; alias inherits the fallback"
assert_eq "stem:True,alias:True" "$(drv fallback-intact)"

# ─── Scenario 3: recommender routing round-trips through the alias ──────────
it "recommender picks still resolve; each stem's alias round-trips to the same recipe"
assert_eq "clear-intent-no-plan->a1/plan-build-review:ok,reviewed-plan->w/work-only:ok" \
  "$(drv recommender-roundtrip)"

# ─── Scenario 4: --check-agrees agrees on an ALIAS-form recommendation ──────
# END-TO-END through the real `router_agrees` primitive (not set membership).
# The launch agent (skills/auto-launch §2) promotes the LEGIBLE name as the
# primary recommendation, so it may pass `plan-build-review`/`work-only` to
# --check-agrees. The value must canonicalize to its stem and reach the skip
# tier exactly where the bare stem does. This is the flow the old membership-only
# scenario 4 never exercised (the alias could never string-equal the router's
# bare-stem pick, so an alias-form recommendation could never skip).
agrees() { "$PY" "$REC" --check-agrees "$1" "$2"; }

it "check-agrees: clear-intent-no-plan + ALIAS plan-build-review -> true (canonicalizes to a1)"
assert_eq "true" "$(agrees clear-intent-no-plan plan-build-review)"

it "check-agrees: clear-intent-no-plan + STEM a1 -> true (stem path unchanged)"
assert_eq "true" "$(agrees clear-intent-no-plan a1)"

it "check-agrees: reviewed-plan + ALIAS work-only -> true (canonicalizes to w)"
assert_eq "true" "$(agrees reviewed-plan work-only)"

it "check-agrees: reviewed-plan + STEM w -> true (stem path unchanged)"
assert_eq "true" "$(agrees reviewed-plan w)"

# The alias does NOT blanket-agree: an alias whose stem the router never picks
# for this state stays false (adversarial-pair -> a4, router picks a1).
it "check-agrees: clear-intent-no-plan + ALIAS adversarial-pair -> false (a4 not the pick / not skip-eligible)"
assert_eq "false" "$(agrees clear-intent-no-plan adversarial-pair)"

# ─── Scenario 5: no rename regression — every stem still resolves ──────────
it "every existing a1/a2/a4/w reference still resolves at the built-in tier"
assert_eq "a1:a1:built-in,a2:a2:built-in,a4:a4:built-in,w:w:built-in" "$(drv stems-resolve)"

# ─── Scenario 6: reserved-name enforcement (Finding 2) ─────────────────────
# A recipe authored under a reserved legible-alias name is rejected by validate()
# (fail fast) instead of being silently shadowed by resolve()'s alias→stem
# rewrite. The bare stems (a1/w) are NOT reserved and must stay valid.
it "validate() rejects a recipe named after a reserved alias; bare stems stay valid"
assert_eq "plan-build-review:rejected,parallel-theories:rejected,adversarial-pair:rejected,work-only:rejected,a1:valid,w:valid" \
  "$(drv reserved-reject)"

# ─── Scenario 7: drift guard between the two copies of the reserved map ─────
it "recipes._ALIASES == recipe_validate._RESERVED_ALIAS_STEMS (no drift)"
assert_eq "same" "$(drv reserved-drift)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-aliases.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
