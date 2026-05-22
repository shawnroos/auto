#!/usr/bin/env bash
# auto: shared test helpers and the $HOME isolation contract.
#
# # $HOME ISOLATION CONTRACT (P0 — read before writing tests)
#
# Every test that touches engine state MUST isolate $HOME before running
# any plugin code. The dispatch ledger lives at <repo>/.claude/auto/
# (NOT in $HOME), so dispatch's $HOME surface is small — but the engine's
# hooks and any future user-level state could touch ~/.claude/, so we keep
# the isolation framework intact and isolate $HOME by default. Tests that
# write a ledger should point the engine at a sandbox repo dir, not $HOME.
#
# Pattern:
#   . tests/helpers/test-helpers.sh
#   auto_test::setup     # exports HOME to a fresh tempdir
#   # ... run plugin code ...
#   auto_test::teardown  # restores HOME and cleans tempdir
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
# PATH. Overridable via CLAUDE_AUTO_PYTHON3 (the plan's U3 convention).
#
# Plugin code that shells Python MUST use this var, not bare `python3`.
CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
export CLAUDE_AUTO_PYTHON3

# ──────────────────────────────────────────────────────────────────────────
# Setup / teardown — isolate $HOME.

auto_test::setup() {
  # Remember the real HOME so the runner can verify nothing leaked.
  : "${CLAUDE_AUTO_TEST_HOME_ORIGINAL:=$HOME}"
  export CLAUDE_AUTO_TEST_HOME_ORIGINAL

  # Fresh per-test sandbox.
  CLAUDE_AUTO_TEST_SANDBOX=$(mktemp -d -t auto-test.XXXXXX)
  export CLAUDE_AUTO_TEST_SANDBOX

  export HOME="$CLAUDE_AUTO_TEST_SANDBOX"

  # Seed an empty ~/.claude/ inside the sandbox so plugin scripts that
  # short-circuit on its absence don't accidentally pass for the wrong
  # reason in tests that DO want plugin behavior to run.
  mkdir -m 0700 -p "$HOME/.claude"
}

auto_test::teardown() {
  if [ -n "${CLAUDE_AUTO_TEST_SANDBOX:-}" ] && [ -d "${CLAUDE_AUTO_TEST_SANDBOX}" ]; then
    # Defensive: only delete things under our sandbox.
    case "$CLAUDE_AUTO_TEST_SANDBOX" in
      */auto-test.*) rm -rf "$CLAUDE_AUTO_TEST_SANDBOX" ;;
      *) echo "test-helpers: refusing to rm '$CLAUDE_AUTO_TEST_SANDBOX' (unexpected path)" >&2 ;;
    esac
  fi
  unset CLAUDE_AUTO_TEST_SANDBOX
  export HOME="$CLAUDE_AUTO_TEST_HOME_ORIGINAL"
}

# ──────────────────────────────────────────────────────────────────────────
# Assertion helpers — minimal, no framework dependency.
#
# All assertions print PASS/FAIL with the test name, and on FAIL emit a
# diagnostic and increment CLAUDE_AUTO_TEST_FAIL_COUNT.

: "${CLAUDE_AUTO_TEST_PASS_COUNT:=0}"
: "${CLAUDE_AUTO_TEST_FAIL_COUNT:=0}"
: "${CLAUDE_AUTO_TEST_CURRENT:=anonymous}"
export CLAUDE_AUTO_TEST_PASS_COUNT CLAUDE_AUTO_TEST_FAIL_COUNT CLAUDE_AUTO_TEST_CURRENT

auto_test::it() {
  CLAUDE_AUTO_TEST_CURRENT="${1:-anonymous}"
}

auto_test::pass() {
  CLAUDE_AUTO_TEST_PASS_COUNT=$((CLAUDE_AUTO_TEST_PASS_COUNT + 1))
  printf "  \033[32m✓\033[0m %s\n" "${CLAUDE_AUTO_TEST_CURRENT}"
}

auto_test::fail() {
  CLAUDE_AUTO_TEST_FAIL_COUNT=$((CLAUDE_AUTO_TEST_FAIL_COUNT + 1))
  printf "  \033[31m✗\033[0m %s\n" "${CLAUDE_AUTO_TEST_CURRENT}"
  if [ -n "${1:-}" ]; then
    printf "      %s\n" "$1"
  fi
}

auto_test::assert_eq() {
  local expected="$1"
  local actual="$2"
  if [ "$expected" = "$actual" ]; then
    auto_test::pass
  else
    auto_test::fail "expected: '${expected}'  actual: '${actual}'"
  fi
}

auto_test::assert_ne() {
  local notexpected="$1"
  local actual="$2"
  if [ "$notexpected" != "$actual" ]; then
    auto_test::pass
  else
    auto_test::fail "should NOT equal: '${notexpected}'"
  fi
}

auto_test::assert_true() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    auto_test::pass
  else
    auto_test::fail "command should have succeeded: $cmd"
  fi
}

auto_test::assert_false() {
  local cmd="$1"
  if eval "$cmd" >/dev/null 2>&1; then
    auto_test::fail "command should have failed: $cmd"
  else
    auto_test::pass
  fi
}

auto_test::assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) auto_test::pass ;;
    *) auto_test::fail "expected substring '${needle}' in: '${haystack}'" ;;
  esac
}

auto_test::assert_file_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    auto_test::pass
  else
    auto_test::fail "expected file to exist: $path"
  fi
}

auto_test::assert_file_absent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    auto_test::pass
  else
    auto_test::fail "expected file/dir NOT to exist: $path"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Summary line — emit at the end of every test file in the format
# tests/run.sh greps for, so this file's assertions are counted in the
# suite total (not silently dropped).
#
#   auto_test::summary
#
# Exits 1 if any assertion failed, 0 otherwise — call it as the last line.
auto_test::summary() {
  echo ""
  printf '%s: %d passed, %d failed\n' \
    "$(basename "${BASH_SOURCE[1]:-test}")" \
    "${CLAUDE_AUTO_TEST_PASS_COUNT}" \
    "${CLAUDE_AUTO_TEST_FAIL_COUNT}"
  if [ "${CLAUDE_AUTO_TEST_FAIL_COUNT}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────────────────
# Path resolution helpers.

# Returns the absolute path to the plugin root (parent of tests/).
auto_test::plugin_root() {
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}
