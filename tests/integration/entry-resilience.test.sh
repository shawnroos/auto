#!/usr/bin/env bash
# auto v0.7.x U5: degrade-safe entry.
#
# The 2026-06 field report noted the entry stalled when the classifier was
# momentarily unavailable — a single dispatch line with no graceful fallback.
# The driver-side gap (a detector subprocess that won't run) is handled in
# skills/auto-driver/SKILL.md (degrade to `raw`) and pinned by the smoke test.
# This test pins the OTHER half at the handoff we can drive deterministically: the
# dispatch line surfaces a LEGIBLE non-zero failure rather than a silent stall.
#
# Scenarios:
#   1. missing plan file -> exit non-zero AND a message naming the missing file
#   2. the detector ALWAYS emits a parseable envelope + exits 0, even on a
#      degraded repo (so the driver's "no envelope -> raw" path is the genuine
#      env-hiccup fallback, never a normal-operation branch)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTO_SH="${AUTO_ROOT}/lib/auto.sh"
DET="${AUTO_ROOT}/lib/auto-detect.sh"
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
assert_true() { if eval "$1"; then pass; else fail "predicate false: $1"; fi; }

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-resil-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in */auto-resil-test.*) rm -rf "$SANDBOX" ;; esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q . ) >/dev/null 2>&1

# ── Scenario 1: a bad dispatch fails LEGIBLY (non-zero + named message) ───────
it "dispatch: missing plan file exits non-zero (not a silent stall)"
OUT="$(CLAUDE_AUTO_REPO="$REPO" bash "$AUTO_SH" "docs/plans/nope.md" 2>&1)"; rc=$?
assert_true "[ \"$rc\" -ne 0 ]"

it "dispatch: the failure message names the missing file (legible surface)"
assert_true "printf '%s' \"$OUT\" | grep -qF 'docs/plans/nope.md'"

# ── Scenario 2: the detector NEVER yields empty — the driver's degrade path is
# a genuine env-hiccup fallback, not a normal branch ─────────────────────────
it "detector: emits a non-empty parseable envelope on a degraded repo"
BADREPO="${SANDBOX}/badrepo"
mkdir -p "$BADREPO"
printf 'not a dir' > "${BADREPO}/.claude"   # .claude is a file → ledger scan degrades
RAW="$(CLAUDE_AUTO_REPO="$BADREPO" bash "$DET" 2>/dev/null)"
# Pipe RAW directly (never re-eval a string full of JSON quotes) and require the
# envelope be both non-empty AND valid JSON.
if [ -n "$RAW" ] && printf '%s' "$RAW" | "$PY" -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
  pass
else
  fail "detector produced empty or unparseable output"
fi

it "detector: exits 0 on the degraded repo (never a non-zero the driver must catch as normal)"
CLAUDE_AUTO_REPO="$BADREPO" bash "$DET" >/dev/null 2>&1
assert_eq "0" "$?"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "entry-resilience.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
