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
#   4. launch-gate SKIP_ELIGIBLE_RECIPES recognizes alias AND stem.
#   5. Every existing a1/a2/a4/w reference still resolves (no rename regression).

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

elif op == "skip-eligible":
    # launch-gate SKIP_ELIGIBLE_RECIPES recognizes the alias wherever its stem is
    # eligible. a1/w are skip-eligible → so are plan-build-review/work-only.
    lg = load_lib_module("launch-gate")
    elig = lg.SKIP_ELIGIBLE_RECIPES
    checks = ["a1", "plan-build-review", "w", "work-only"]
    print(",".join("%s:%s" % (n, n in elig) for n in checks))

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

# ─── Scenario 4: launch-gate skip-eligibility (alias AND stem) ─────────────
it "SKIP_ELIGIBLE_RECIPES recognizes both the stem and its alias"
assert_eq "a1:True,plan-build-review:True,w:True,work-only:True" "$(drv skip-eligible)"

# ─── Scenario 5: no rename regression — every stem still resolves ──────────
it "every existing a1/a2/a4/w reference still resolves at the built-in tier"
assert_eq "a1:a1:built-in,a2:a2:built-in,a4:a4:built-in,w:w:built-in" "$(drv stems-resolve)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-aliases.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
