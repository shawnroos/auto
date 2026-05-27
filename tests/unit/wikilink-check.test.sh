#!/usr/bin/env bash
# auto unit test: MECHANICAL Obsidian-wikilink leak check (G5 ps-r2-1).
#
# Round-1 ps-2 (P3) flagged `[[feedback_*]]` / `[[idea_*]]` / `[[project_*]]` /
# `[[reference_*]]` Obsidian wikilinks leaking from Shawn's private memory
# index into shipped public files (lib/, docs/contracts/, skills/, commands/).
# Round-2 elevated to P2 after F3 re-introduced 3 new instances — the class
# was recurring without a mechanical defense.
#
# This test IS the defense: greps the four public-shipping trees for memory-name
# wikilinks and fails if any are found. New consumers cannot re-introduce one
# without tripping this lint (per the "deterministic over probabilistic V1"
# rule — for behavioural infrastructure, V1 needs mechanical enforcement, not
# disposition shifts).
#
# Allowed places these wikilinks legitimately live: NONE in this tree. Shawn's
# private memory directory under ~/.claude/projects/.../memory/ is NOT
# part of this repo and is not scanned.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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

# The lint, as a reusable function the deliberate-fail control can re-run.
# Searches the four shipped public trees for memory-name wikilinks.
# Excludes this test file itself (it documents the forbidden pattern in prose).
# Excludes __pycache__/ and *.pyc — Python bytecode caches retain the old
# string contents from prior source state until they're regenerated, and
# those caches are gitignored so they don't belong in the lint scope.
run_wikilink_lint() {
  # `|| true` so an empty result (the green path) doesn't trip set -e and
  # collapse the result to empty correctly. Grep exits 1 on no-match.
  ( cd "$AUTO_ROOT" && \
    grep -rn -E '\[\[(feedback|idea|project|reference)_' \
      lib/ docs/contracts/ skills/ commands/ \
      --exclude-dir='.claude' \
      --exclude-dir='__pycache__' \
      --exclude='*.pyc' \
      2>/dev/null \
      || true \
  )
}

# ─── Scenario 1: the lint is clean on the real tree ─────────────────────────
it "no [[feedback_*|idea_*|project_*|reference_*]] wikilinks in shipped public files"
hits="$(run_wikilink_lint)"
if [ -z "$hits" ]; then
  pass
else
  fail "wikilinks found:
${hits}"
fi

# ─── Scenario 2: deliberate-fail control — a planted wikilink trips the lint ─
# Plant a wikilink in a temp file under one of the scanned trees, run the
# lint, confirm it catches the plant, remove it. Proves the lint actually
# works — a 0-assertion test or a never-firing grep would silently report
# green while testing nothing.
it "deliberate-fail: a planted wikilink in lib/ trips the lint"
tmpfile="${AUTO_ROOT}/lib/__wikilink_probe__.py"
printf '%s\n' '# Planted by wikilink-check deliberate-fail: [[feedback_planted_probe]]' > "$tmpfile"
probe_result="$(run_wikilink_lint)"
rm -f "$tmpfile"
case "$probe_result" in
  *__wikilink_probe__*) pass ;;
  *) fail "planted wikilink NOT caught: ${probe_result:-<empty>}" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "wikilink-check.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
