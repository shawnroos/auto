#!/usr/bin/env bash
# claude-dispatch: shared test helpers and the $HOME isolation contract.
#
# # $HOME ISOLATION CONTRACT (P0 — read before writing tests)
#
# Every test that touches engine state MUST isolate $HOME before running
# any plugin code. The dispatch ledger lives at <repo>/.claude/dispatch/
# (NOT in $HOME), so dispatch's $HOME surface is small — but the engine's
# hooks and any future user-level state could touch ~/.claude/, so we keep
# the isolation framework intact and isolate $HOME by default. Tests that
# write a ledger should point the engine at a sandbox repo dir, not $HOME.
#
# Pattern:
#   . tests/helpers/test-helpers.sh
#   claude_dispatch_test::setup     # exports HOME to a fresh tempdir
#   # ... run plugin code ...
#   claude_dispatch_test::teardown  # restores HOME and cleans tempdir
#
# Verification: tests/run.sh records a hash of a set of real-$HOME paths
# before and after the suite. A mismatch means a test escaped isolation —
# the suite fails loudly.

# ──────────────────────────────────────────────────────────────────────────
# Canonical Python executable.
#
# WHY: on macOS the user's PATH often resolves `python3` to a Homebrew
# install (e.g., /opt/homebrew/bin/python3) that may differ from the
# Apple-provided /usr/bin/python3. Pinning to /usr/bin/python3 makes the
# plugin robust on macOS regardless of which Python the user prepended to
# PATH. Overridable via CLAUDE_DISPATCH_PYTHON3 (the plan's U3 convention).
#
# Plugin code that shells Python MUST use this var, not bare `python3`.
CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"
export CLAUDE_DISPATCH_PYTHON3

# ──────────────────────────────────────────────────────────────────────────
# Setup / teardown — isolate $HOME.

claude_dispatch_test::setup() {
  # Remember the real HOME so the runner can verify nothing leaked.
  : "${CLAUDE_DISPATCH_TEST_HOME_ORIGINAL:=$HOME}"
  export CLAUDE_DISPATCH_TEST_HOME_ORIGINAL

  # Fresh per-test sandbox.
  CLAUDE_DISPATCH_TEST_SANDBOX=$(mktemp -d -t claude-dispatch-test.XXXXXX)
  export CLAUDE_DISPATCH_TEST_SANDBOX

  export HOME="$CLAUDE_DISPATCH_TEST_SANDBOX"

  # Seed an empty ~/.claude/ inside the sandbox so plugin scripts that
  # short-circuit on its absence don't accidentally pass for the wrong
  # reason in tests that DO want plugin behavior to run.
  mkdir -m 0700 -p "$HOME/.claude"
}

claude_dispatch_test::teardown() {
  if [ -n "${CLAUDE_DISPATCH_TEST_SANDBOX:-}" ] && [ -d "${CLAUDE_DISPATCH_TEST_SANDBOX}" ]; then
    # Defensive: only delete things under our sandbox.
    case "$CLAUDE_DISPATCH_TEST_SANDBOX" in
      */claude-dispatch-test.*) rm -rf "$CLAUDE_DISPATCH_TEST_SANDBOX" ;;
      *) echo "test-helpers: refusing to rm '$CLAUDE_DISPATCH_TEST_SANDBOX' (unexpected path)" >&2 ;;
    esac
  fi
  unset CLAUDE_DISPATCH_TEST_SANDBOX
  export HOME="$CLAUDE_DISPATCH_TEST_HOME_ORIGINAL"
}

# ──────────────────────────────────────────────────────────────────────────
# Assertion helpers — minimal, no framework dependency.
#
# All assertions print PASS/FAIL with the test name, and on FAIL emit a
# diagnostic and increment CLAUDE_DISPATCH_TEST_FAIL_COUNT.

: "${CLAUDE_DISPATCH_TEST_PASS_COUNT:=0}"
: "${CLAUDE_DISPATCH_TEST_FAIL_COUNT:=0}"
: "${CLAUDE_DISPATCH_TEST_CURRENT:=anonymous}"
export CLAUDE_DISPATCH_TEST_PASS_COUNT CLAUDE_DISPATCH_TEST_FAIL_COUNT CLAUDE_DISPATCH_TEST_CURRENT

claude_dispatch_test::it() {
  CLAUDE_DISPATCH_TEST_CURRENT="${1:-anonymous}"
}

claude_dispatch_test::pass() {
  CLAUDE_DISPATCH_TEST_PASS_COUNT=$((CLAUDE_DISPATCH_TEST_PASS_COUNT + 1))
  printf "  \033[32m✓\033[0m %s\n" "${CLAUDE_DISPATCH_TEST_CURRENT}"
}

claude_dispatch_test::fail() {
  CLAUDE_DISPATCH_TEST_FAIL_COUNT=$((CLAUDE_DISPATCH_TEST_FAIL_COUNT + 1))
  printf "  \033[31m✗\033[0m %s\n" "${CLAUDE_DISPATCH_TEST_CURRENT}"
  if [ -n "${1:-}" ]; then
    printf "      %s\n" "$1"
  fi
}

claude_dispatch_test::assert_eq() {
  local expected="$1"
  local actual="$2"
  if [ "$expected" = "$actual" ]; then
    claude_dispatch_test::pass
  else
    claude_dispatch_test::fail "expected: '${expected}'  actual: '${actual}'"
  fi
}

claude_dispatch_test::assert_ne() {
  local notexpected="$1"
  local actual="$2"
  if [ "$notexpected" != "$actual" ]; then
    claude_dispatch_test::pass
  else
    claude_dispatch_test::fail "should NOT equal: '${notexpected}'"
  fi
}

claude_dispatch_test::assert_true() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    claude_dispatch_test::pass
  else
    claude_dispatch_test::fail "command should have succeeded: $cmd"
  fi
}

claude_dispatch_test::assert_false() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    claude_dispatch_test::fail "command should have failed: $cmd"
  else
    claude_dispatch_test::pass
  fi
}

claude_dispatch_test::assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) claude_dispatch_test::pass ;;
    *) claude_dispatch_test::fail "expected substring '${needle}' in: '${haystack}'" ;;
  esac
}

claude_dispatch_test::assert_file_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    claude_dispatch_test::pass
  else
    claude_dispatch_test::fail "expected file to exist: $path"
  fi
}

claude_dispatch_test::assert_file_absent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    claude_dispatch_test::pass
  else
    claude_dispatch_test::fail "expected file/dir NOT to exist: $path"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Summary line — emit at the end of every test file in the format
# tests/run.sh greps for, so this file's assertions are counted in the
# suite total (not silently dropped).
#
#   claude_dispatch_test::summary
#
# Exits 1 if any assertion failed, 0 otherwise — call it as the last line.
claude_dispatch_test::summary() {
  echo ""
  printf '%s: %d passed, %d failed\n' \
    "$(basename "${BASH_SOURCE[1]:-test}")" \
    "${CLAUDE_DISPATCH_TEST_PASS_COUNT}" \
    "${CLAUDE_DISPATCH_TEST_FAIL_COUNT}"
  if [ "${CLAUDE_DISPATCH_TEST_FAIL_COUNT}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────────────────
# Path resolution helpers.

# Returns the absolute path to the plugin root (parent of tests/).
claude_dispatch_test::plugin_root() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}
