#!/usr/bin/env bash
# auto: repo-root resolution must NOT escape the git worktree.
#
# Field bug (2026-06): bare `/auto` in a fresh worktree mis-rooted to $HOME.
# `_repo_root()` (auto-detect.sh) and `resolve_repo()` (_bootstrap.py) both
# walked up from cwd looking for `.claude/auto` with NO upper bound — so from a
# worktree that has no `.claude/auto` of its own yet, the walk escaped all the
# way to `$HOME/.claude/auto`. The detector then scanned `$HOME/.claude/auto`
# (a stale 15-day run) and `$HOME/docs/plans` (unrelated plans), producing the
# `in-flight` and `multi-plan` misfires — and the worktree's own plan was never
# in scope.
#
# The fix bounds the walk-up at the git worktree top (`git rev-parse
# --show-toplevel`); with no git tree it returns cwd, never $HOME.
#
# This test plants the junk drawer ($HOME/.claude/auto + $HOME/docs/plans) and
# runs the detector — with NO CLAUDE_AUTO_REPO — from inside a git repo nested
# UNDER that $HOME. The detector must resolve to the repo, not $HOME.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DET="${AUTO_ROOT}/lib/auto-detect.sh"
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
# The whole point is to exercise the walk-up-to-$HOME path, so we POINT $HOME
# at a sandbox and plant the junk drawer there. Never touches the real $HOME.
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-rooting-test.XXXXXX)"
export HOME="$SANDBOX"
# Make sure no inherited override defeats the walk-up under test.
unset CLAUDE_AUTO_REPO
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-rooting-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Plant the junk drawer at $HOME (the mis-root target) ───────────────────
mkdir -p "$HOME/.claude/auto" "$HOME/docs/plans"
cat > "$HOME/.claude/auto/stale-home-run.json" <<'EOF'
{"run_id":"stale-home-run","exit_predicate_result":{"met":false},"goal_intent":"unrelated home-level run"}
EOF
echo "# home plan one" > "$HOME/docs/plans/home-plan-one-plan.md"
echo "# home plan two" > "$HOME/docs/plans/home-plan-two-plan.md"

# ── Build a git repo nested under $HOME with NO .claude/auto of its own ─────
REPO="$HOME/projects/widget"
mkdir -p "$REPO/src/deep"
(
  cd "$REPO"
  git init -q .
  git config user.email t@t
  git config user.name t
  printf '.claude/\ndocs/\n' > .gitignore
  git add .gitignore
  git -c commit.gpgsign=false commit -q -m init
) >/dev/null 2>&1

# Run the detector from a deep subdir of the repo, NO CLAUDE_AUTO_REPO.
run_from() {
  local cwd="$1"
  ( cd "$cwd" && unset CLAUDE_AUTO_REPO && bash "$DET" )
}

field() {
  local raw="$1" expr="$2"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
print("None" if val is None else val)
PYEOF
}

# ── Scenario 1: clean repo subdir must NOT inherit $HOME's stale run/plans ──
it "rooting: deep repo subdir resolves to the repo, not \$HOME — situation is raw"
raw="$(run_from "$REPO/src/deep")"
assert_eq "raw" "$(field "$raw" 'H["situation"]')"

it "rooting: does NOT surface the stale \$HOME in-flight run"
assert_eq "None" "$(field "$raw" 'H["in_flight"]')"

it "rooting: does NOT surface \$HOME/docs/plans as a multi-plan fanout"
assert_eq "None" "$(field "$raw" 'H["multi_plan"]')"

# ── Scenario 2: the repo's OWN plan is what gets discovered, not $HOME's ────
it "rooting: the repo's own single plan is discovered (reviewed-plan)"
mkdir -p "$REPO/docs/plans"
echo "# the real widget plan" > "$REPO/docs/plans/widget-plan.md"
raw2="$(run_from "$REPO/src/deep")"
assert_eq "reviewed-plan" "$(field "$raw2" 'H["situation"]')"

it "rooting: single_plan.path is the REPO plan (relative), not a \$HOME plan"
assert_eq "docs/plans/widget-plan.md" "$(field "$raw2" 'H["single_plan"]["path"]')"

# ── Scenario 3: no-git dir under $HOME must still not escape to $HOME ───────
it "rooting: non-git dir under \$HOME does not inherit \$HOME's plans (raw, no multi_plan)"
NONGIT="$HOME/loose/scratch"
mkdir -p "$NONGIT"
raw3="$(run_from "$NONGIT")"
assert_eq "None" "$(field "$raw3" 'H["multi_plan"]')"

# ── Scenario 4: PARITY — the detector's inlined _repo_root() and the shared
# _bootstrap.resolve_repo() must resolve the SAME cwd to the SAME worktree root.
# The two copies are kept in sync by comment only; this fixture makes a
# divergence on the load-bearing case (fresh-ish worktree under a junk-drawer
# $HOME) a CI failure, not a production surprise. We plant a sentinel not-met
# run in the repo and a DECOY in $HOME: the detector surfaces the sentinel iff
# its _repo_root resolved to the repo (not $HOME), and resolve_repo() must
# return that same repo root.
PARITY_REPO="$HOME/projects/parity"
mkdir -p "$PARITY_REPO/sub" "$PARITY_REPO/.claude/auto"
(
  cd "$PARITY_REPO" && git init -q . && git config user.email t@t && git config user.name t
) >/dev/null 2>&1
printf '{"run_id":"SENTINEL","exit_predicate_result":{"met":false}}\n' > "$PARITY_REPO/.claude/auto/sentinel.json"
printf '{"run_id":"DECOY","exit_predicate_result":{"met":false}}\n' > "$HOME/.claude/auto/decoy.json"

it "parity: detector _repo_root resolves to the worktree (surfaces SENTINEL, not DECOY)"
rawp="$(run_from "$PARITY_REPO/sub")"
assert_eq "SENTINEL" "$(field "$rawp" 'H["in_flight"]["run_id"]')"

it "parity: _bootstrap.resolve_repo() resolves the SAME cwd to the SAME worktree root"
expected_parity="$(cd "$PARITY_REPO" && pwd -P)"
got_parity="$(cd "$PARITY_REPO/sub" && unset CLAUDE_AUTO_REPO && "$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import _bootstrap as b
print(b.resolve_repo())
PYEOF
)"
got_parity_real="$(cd "$got_parity" && pwd -P)"
assert_eq "$expected_parity" "$got_parity_real"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "detector-rooting.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
