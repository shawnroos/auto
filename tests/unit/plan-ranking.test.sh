#!/usr/bin/env bash
# auto v0.7.x U1: plan freshness ranking unit test for lib/plan-rank.py.
#
# Pins the deterministic freshness rule (KTD-4): git opinion wins, mtime is the
# fallback where git is silent.
#   * uncommitted (untracked/modified) plan → fresh
#   * tracked+clean, recent last-commit → fresh; old last-commit → stale
#   * git-silent (gitignored / non-git) → mtime fallback (recent → fresh)
#   * the CLAUDE_AUTO_PLAN_FRESH_SECONDS knob + floor
#   * a missing/empty plan dir → empty list, no crash
#
# Each scenario is hermetic: a temp repo seeded with the minimum state to
# exercise one branch. Unlike the detector's hypothesis-shape harness (which
# gitignores docs/ to keep the dirty-tree scenario clean), this harness TRACKS
# docs/plans/ so committed-vs-uncommitted freshness is observable — except the
# one scenario that deliberately re-creates the gitignored-docs condition to
# prove the mtime fallback keeps the detector's own tests working.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RANK="${AUTO_ROOT}/lib/plan-rank.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-rank-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-rank-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
# rank_json <setup-fn> <python-expr-on-ranked-list-named-R> [extra-env KV]
#   setup-fn seeds a repo; we run `python plan-rank.py <repo>` and eval an
#   expression against the parsed JSON list R.
rank_json() {
  local setup_fn="$1" expr="$2" kv="${3:-}"
  local repo; repo="$(mktemp -d -t rank-repo.XXXXXX)"
  "$setup_fn" "$repo"
  local raw
  if [ -n "$kv" ]; then
    raw="$(env "$kv" "$PY" "$RANK" "$repo")"
  else
    raw="$("$PY" "$RANK" "$repo")"
  fi
  rm -rf "$repo"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
R = json.loads(raw)
val = eval(expr)
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

git_init() {
  (
    cd "$1"
    git init -q .
    git config user.email test@test
    git config user.name test
  ) >/dev/null 2>&1
}

# Commit every currently-staged/tracked change with a chosen committer date so
# %ct (last-commit time) is controllable. $2 = ISO date (empty → now).
git_commit_dated() {
  local repo="$1" when="$2"
  (
    cd "$repo"
    git add -A
    if [ -n "$when" ]; then
      GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
        git -c commit.gpgsign=false commit -q -m snapshot
    else
      git -c commit.gpgsign=false commit -q -m snapshot
    fi
  ) >/dev/null 2>&1
}

# ── Scenarios ──────────────────────────────────────────────────────────────

setup_untracked_one() {
  git_init "$1"
  mkdir -p "$1/docs/plans"
  echo "# live" > "$1/docs/plans/live-plan.md"   # created, never committed
}
it "untracked plan → fresh (actively worked on)"
assert_eq "fresh" "$(rank_json setup_untracked_one 'R[0]["freshness"]')"
it "untracked plan → single entry"
assert_eq "1" "$(rank_json setup_untracked_one 'len(R)')"

setup_committed_now() {
  git_init "$1"
  mkdir -p "$1/docs/plans"
  echo "# just" > "$1/docs/plans/just-plan.md"
  git_commit_dated "$1" ""            # committed at ~now
}
it "committed-just-now plan → fresh"
assert_eq "fresh" "$(rank_json setup_committed_now 'R[0]["freshness"]')"

setup_committed_old() {
  git_init "$1"
  mkdir -p "$1/docs/plans"
  echo "# old" > "$1/docs/plans/old-plan.md"
  git_commit_dated "$1" "2026-01-01T00:00:00"   # months ago
}
it "committed-long-ago plan → stale"
assert_eq "stale" "$(rank_json setup_committed_old 'R[0]["freshness"]')"

setup_mixed() {
  git_init "$1"
  mkdir -p "$1/docs/plans"
  echo "# a" > "$1/docs/plans/a-plan.md"
  echo "# b" > "$1/docs/plans/b-plan.md"
  echo "# c" > "$1/docs/plans/c-plan.md"
  git_commit_dated "$1" "2026-01-01T00:00:00"   # a,b,c stale (old commit)
  echo "# live" > "$1/docs/plans/z-live-plan.md"   # uncommitted → fresh
}
it "mixed set: exactly one fresh plan among the stale siblings"
assert_eq "1" "$(rank_json setup_mixed 'len([p for p in R if p["freshness"]=="fresh"])')"
it "mixed set: the fresh (uncommitted) plan sorts first"
assert_eq "docs/plans/z-live-plan.md" "$(rank_json setup_mixed 'R[0]["path"]')"
it "mixed set: three stale plans"
assert_eq "3" "$(rank_json setup_mixed 'len([p for p in R if p["freshness"]=="stale"])')"

it "FRESH_SECONDS=0 → a committed-just-now plan is stale (knob honored)"
assert_eq "stale" "$(rank_json setup_committed_now 'R[0]["freshness"]' CLAUDE_AUTO_PLAN_FRESH_SECONDS=0)"
it "FRESH_SECONDS negative → floored to 0 (committed-now still stale)"
assert_eq "stale" "$(rank_json setup_committed_now 'R[0]["freshness"]' CLAUDE_AUTO_PLAN_FRESH_SECONDS=-5)"
it "large FRESH_SECONDS → an old-committed plan is fresh again (window widened)"
assert_eq "fresh" "$(rank_json setup_committed_old 'R[0]["freshness"]' CLAUDE_AUTO_PLAN_FRESH_SECONDS=31536000)"

# git-silent fallbacks — both must behave the same (mtime fallback).
setup_gitignored_docs() {
  git_init "$1"
  printf 'docs/\n' > "$1/.gitignore"
  git_commit_dated "$1" ""
  mkdir -p "$1/docs/plans"
  echo "# ignored-but-recent" > "$1/docs/plans/ig-plan.md"   # gitignored → git silent
}
it "gitignored plan (detector-harness condition) → mtime fallback → fresh"
# This is the backward-compat guarantee: the detector's own hermetic tests
# gitignore docs/, so their just-created plans must still read fresh.
assert_eq "fresh" "$(rank_json setup_gitignored_docs 'R[0]["freshness"]')"

setup_non_git_recent() {
  mkdir -p "$1/docs/plans"          # NO git init
  echo "# recent" > "$1/docs/plans/r-plan.md"
}
it "non-git dir, recent mtime → fresh (mtime fallback), no crash"
assert_eq "fresh" "$(rank_json setup_non_git_recent 'R[0]["freshness"]')"

setup_non_git_old() {
  mkdir -p "$1/docs/plans"
  echo "# ancient" > "$1/docs/plans/anc-plan.md"
  touch -t 202601010000 "$1/docs/plans/anc-plan.md"   # old mtime
}
it "non-git dir, old mtime → stale (mtime fallback)"
assert_eq "stale" "$(rank_json setup_non_git_old 'R[0]["freshness"]')"

setup_empty() { mkdir -p "$1/docs/plans"; git_init "$1"; }
it "empty plan dir → empty list, no crash"
assert_eq "0" "$(rank_json setup_empty 'len(R)')"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "plan-ranking.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
