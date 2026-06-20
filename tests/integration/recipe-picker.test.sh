#!/usr/bin/env bash
# auto U8 integration test: the picker's DATA LAYER (recipes-list.sh).
#
# The picker UX is orchestrator prose in commands/auto.md (AskUserQuestion) — not
# directly unit-testable. But the picker only RENDERS what recipes-list.sh
# returns, so AE1/AE2 are verified at that data boundary: the list the picker
# shows, and the tier badges + shadowing it surfaces.
#
# AE1: fresh repo → picker shows exactly the 4 built-ins, each tagged built-in.
# AE2: a workspace recipe shadows a same-named built-in (workspace wins, one row,
#      tagged workspace) — the badge is the user's signal.
# Plus: --render <name> produces the topology card (the picker's preview surface).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIST_SH="${AUTO_ROOT}/lib/recipes-list.sh"

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

# ─── AE1: fresh repo → built-ins ────────────────────────────────────────────
# v0.6.0 U7/U11 added two built-ins: pipeline (brainstorm-rooted spine) and
# review (off-spine single-phase). The picker data lists all six, sorted.
it "AE1: picker data lists exactly the 6 built-ins, all tier=built-in"
fresh="$(mktemp -d)"; mkdir -p "$fresh/.claude/auto"
rows="$(CLAUDE_AUTO_REPO="$fresh" bash "$LIST_SH" | awk -F'\t' '{print $1":"$2}' | paste -sd, -)"
assert_eq "a1:built-in,a2:built-in,a4:built-in,pipeline:built-in,review:built-in,w:built-in" "$rows"

# ─── AE2: workspace shadows built-in ────────────────────────────────────────
it "AE2: a workspace recipe named a1 shadows the built-in (workspace, one row)"
ws="$(mktemp -d)"; mkdir -p "$ws/.claude/auto/recipes"
cat > "$ws/.claude/auto/recipes/a1.json" <<'JSON'
{"name":"a1","version":"1","phase_order":["plan","seam","work"],"terminal_phase":"work","units":[{"id":"plan","phase":"plan","invokes":{}}],"description":"WS override"}
JSON
a1row="$(CLAUDE_AUTO_REPO="$ws" bash "$LIST_SH" | awk -F'\t' '$1=="a1"{print $1":"$2; n++} END{print "count="n}')"
# a1 appears once, tagged workspace.
assert_eq "a1:workspace
count=1" "$a1row"

# ─── AE3: no CLAUDE_AUTO_REPO → shim roots to the git worktree (walk-up path) ──
# AE1/AE2 pin CLAUDE_AUTO_REPO explicitly, so they never exercise the shim's
# fresh-worktree resolution — exactly the path the 2026-06 mis-root bug lived in
# (an inlined walk-up escaped to $HOME, mislabeling the worktree's own recipe as
# the wrong tier). recipes-list.sh now defers to the shared _bootstrap.resolve_repo;
# this runs the shim from a nested subdir with CLAUDE_AUTO_REPO UNSET and asserts a
# recipe sitting in the worktree surfaces as tier=workspace — i.e. resolve_repo
# bounded the root to the git toplevel rather than escaping upward.
it "AE3: no CLAUDE_AUTO_REPO -> shim roots to the git worktree (worktree recipe tagged workspace)"
wt="$(mktemp -d)"
( cd "$wt" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$wt/.claude/auto/recipes" "$wt/sub/deep"
cat > "$wt/.claude/auto/recipes/wtonly.json" <<'JSON'
{"name":"wtonly","version":"1","phase_order":["work"],"terminal_phase":"work","units":[{"id":"u","phase":"work","invokes":{}}],"description":"worktree recipe"}
JSON
tier="$(cd "$wt/sub/deep" && unset CLAUDE_AUTO_REPO && bash "$LIST_SH" | awk -F'\t' '$1=="wtonly"{print $2}')"
assert_eq "workspace" "$tier"

# ─── preview surface ────────────────────────────────────────────────────────
it "picker preview: --render a4 produces a topology card naming the emitter"
card="$(CLAUDE_AUTO_REPO="$(mktemp -d)" bash "$LIST_SH" --render a4)"
case "$card" in
  *"recipe: a4"*"plan_output_to_paired_builders"*) pass ;;
  *) fail "card missing name or emitter: $(printf '%s' "$card" | head -3)" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-picker.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
