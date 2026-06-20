#!/usr/bin/env bash
# auto v0.4.0 U1: shared-dir-resolution lint for _bootstrap helpers.
#
# v0.4.0 KTD-3 (round-3 finding R3-001 — empirically verified):
#   * resolve_host_repo_root() must return the MAIN repo from ANY worktree.
#   * resolve_shared_dir() returns <host-repo-root>/.claude/auto/.
#   * Both return None outside a git tree (so callers handle the None case).
#
# Why this matters: from inside a worktree, `git rev-parse --show-toplevel`
# returns the worktree's OWN path. For multi-plan fanout we need the host
# repo so spawned worktrees nest under the main checkout's worktrees/ — not
# under whichever worktree the parent session happens to be running in.
# `git rev-parse --git-common-dir` IS the resolver that works from both
# locations; this test pins that contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
SANDBOX="$(mktemp -d -t auto-share-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-share-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helper: probe _bootstrap from a given cwd. ─────────────────────────────
# probe <cwd> <python-expr-on-module-named-b>
probe() {
  local cwd="$1" expr="$2"
  (
    cd "$cwd"
    "$PY" - "$AUTO_ROOT" "$expr" <<'PYEOF'
import sys, os
auto_root, expr = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
val = eval(expr)
if val is None:
    print("None")
else:
    print(val)
PYEOF
  )
}

# ── Scenario 1: main repo — resolve_host_repo_root returns the repo root ──
# We compare via realpath: `os.path.abspath` does NOT follow symlinks, and on
# macOS /var/folders is a symlink to /private/var/folders. The CONTRACT is
# "the repo root"; whether it's the symlinked or canonical form is mechanism.
# realpath-ing both sides closes that mismatch in test land without forcing
# resolve_host_repo_root() to canonicalize (production callers chdir into the
# resolved path and don't care about the symlink form).
it "main repo: resolve_host_repo_root() returns the repo root"
main_repo="$(mktemp -d -t share-main.XXXXXX)"
(
  cd "$main_repo"
  git init -q .
  git config user.email t@t
  git config user.name t
)
expected="$(cd "$main_repo" && pwd -P)"
got="$(probe "$main_repo" 'b.resolve_host_repo_root()')"
got_real="$(cd "$got" && pwd -P)"
assert_eq "$expected" "$got_real"

# ── Scenario 2: main repo — resolve_shared_dir returns <root>/.claude/auto/
# resolve_shared_dir() just BUILDS the path; the directory itself need not
# exist (callers create it on demand). Compare via "host root + .claude/auto"
# rather than chdir into a maybe-absent path.
it "main repo: resolve_shared_dir() == host_root + /.claude/auto"
got_host="$(probe "$main_repo" 'b.resolve_host_repo_root()')"
got_shared="$(probe "$main_repo" 'b.resolve_shared_dir()')"
assert_eq "${got_host}/.claude/auto" "$got_shared"

it "main repo: resolve_shared_dir() ends with .claude/auto"
assert_eq "True" "$(probe "$main_repo" 'b.resolve_shared_dir().endswith(os.path.join(".claude","auto"))')"

# ── Scenario 3: WORKTREE — resolve_host_repo_root returns the MAIN repo ──
# This is the round-3 R3-001 regression: from inside a worktree, the wrong
# answer is "the worktree's own root"; we MUST get the main repo back.
it "worktree: resolve_host_repo_root() returns the MAIN repo, not the worktree"
(
  cd "$main_repo"
  # Make at least one commit so worktrees can be created.
  echo init > seed.txt
  git add seed.txt
  git -c commit.gpgsign=false commit -q -m seed
  # Create a worktree on a fresh branch.
  git worktree add -q -b auto-test-wt "${main_repo}-wt" >/dev/null 2>&1
)
worktree_path="${main_repo}-wt"
got="$(probe "$worktree_path" 'b.resolve_host_repo_root()')"
got_real="$(cd "$got" && pwd -P)"
assert_eq "$expected" "$got_real"

it "worktree: resolve_shared_dir() points at the MAIN repo's .claude/auto"
got_host_wt="$(probe "$worktree_path" 'b.resolve_host_repo_root()')"
got_shared_wt="$(probe "$worktree_path" 'b.resolve_shared_dir()')"
assert_eq "${got_host_wt}/.claude/auto" "$got_shared_wt"

# ── Scenario 4: non-git directory — both helpers return None ──────────────
it "non-git dir: resolve_host_repo_root() returns None"
nongit="$(mktemp -d -t share-nongit.XXXXXX)"
assert_eq "None" "$(probe "$nongit" 'b.resolve_host_repo_root()')"

it "non-git dir: resolve_shared_dir() returns None"
assert_eq "None" "$(probe "$nongit" 'b.resolve_shared_dir()')"

# ── Scenario 5: resolve_repo() must NOT escape the git worktree to $HOME ──
# Field bug (2026-06): resolve_repo()'s walk-up for `.claude/auto` had no upper
# bound, so from a fresh worktree under $HOME it escaped to $HOME/.claude/auto
# and bound runs against $HOME. The fix bounds the walk at the git worktree top
# (git rev-parse --show-toplevel); no-git => cwd, never $HOME.
#
# We plant the junk drawer at $HOME (== SANDBOX) and probe from a git repo
# nested under it that has NO .claude/auto of its own.
mkdir -p "$HOME/.claude/auto"
rr_repo="$HOME/projects/rr-widget"
mkdir -p "$rr_repo/src/deep"
(
  cd "$rr_repo"
  git init -q .
  git config user.email t@t
  git config user.name t
) >/dev/null 2>&1

it "resolve_repo: fresh worktree subdir resolves to the worktree root, not \$HOME"
expected_rr="$(cd "$rr_repo" && pwd -P)"
got_rr="$(probe "$rr_repo/src/deep" 'b.resolve_repo()')"
got_rr_real="$(cd "$got_rr" && pwd -P)"
assert_eq "$expected_rr" "$got_rr_real"

it "resolve_repo: an existing .claude/auto inside the worktree is still found"
mkdir -p "$rr_repo/.claude/auto"
got_rr2="$(probe "$rr_repo/src/deep" 'b.resolve_repo()')"
got_rr2_real="$(cd "$got_rr2" && pwd -P)"
assert_eq "$expected_rr" "$got_rr2_real"

it "resolve_repo: CLAUDE_AUTO_REPO override is honored verbatim (sub-run pin)"
assert_eq "/pinned/sub/run" "$(cd "$rr_repo" && CLAUDE_AUTO_REPO="/pinned/sub/run" "$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import _bootstrap as b
print(b.resolve_repo())
PYEOF
)"

it "resolve_repo: non-git dir under \$HOME returns cwd, does NOT escape to \$HOME"
rr_nongit="$HOME/loose/scratch"
mkdir -p "$rr_nongit"
expected_ng="$(cd "$rr_nongit" && pwd -P)"
got_ng="$(probe "$rr_nongit" 'b.resolve_repo()')"
got_ng_real="$(cd "$got_ng" && pwd -P)"
assert_eq "$expected_ng" "$got_ng_real"

# ── Cleanup the worktree (so subsequent test runs don't accumulate) ───────
(
  cd "$main_repo"
  git worktree remove -f "$worktree_path" >/dev/null 2>&1 || true
)
rm -rf "$main_repo" "$worktree_path" "$nongit"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "shared-dir-resolution.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
