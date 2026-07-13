#!/usr/bin/env bash
# auto U8 integration test: the picker's DATA LAYER (workflows-list.sh).
#
# The picker UX is dispatcher prose in commands/auto.md (AskUserQuestion) — not
# directly unit-testable. But the picker only RENDERS what workflows-list.sh
# returns, so AE1/AE2 are verified at that data boundary: the list the picker
# shows, and the tier badges + shadowing it surfaces.
#
# AE1: fresh repo → picker shows exactly the 4 built-ins, each tagged built-in.
# AE2: a workspace workflow shadows a same-named built-in (workspace wins, one row,
#      tagged workspace) — the badge is the user's signal.
# Plus: --render <name> produces the topology card (the picker's preview surface).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIST_SH="${AUTO_ROOT}/lib/workflows-list.sh"

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
it "AE2: a workspace workflow named a1 shadows the built-in (workspace, one row)"
ws="$(mktemp -d)"; mkdir -p "$ws/.claude/auto/workflows"
cat > "$ws/.claude/auto/workflows/a1.json" <<'JSON'
{"name":"a1","version":"1","phase_order":["plan","handoff","work"],"terminal_phase":"work","steps":[{"id":"plan","phase":"plan","invokes":{}}],"description":"WS override"}
JSON
a1row="$(CLAUDE_AUTO_REPO="$ws" bash "$LIST_SH" | awk -F'\t' '$1=="a1"{print $1":"$2; n++} END{print "count="n}')"
# a1 appears once, tagged workspace.
assert_eq "a1:workspace
count=1" "$a1row"

# ─── AE3: no CLAUDE_AUTO_REPO → shim roots to the git worktree (walk-up path) ──
# AE1/AE2 pin CLAUDE_AUTO_REPO explicitly, so they never exercise the shim's
# fresh-worktree resolution — exactly the path the 2026-06 mis-root bug lived in
# (an inlined walk-up escaped to $HOME, mislabeling the worktree's own workflow as
# the wrong tier). workflows-list.sh now defers to the shared _bootstrap.resolve_repo;
# this runs the shim from a nested subdir with CLAUDE_AUTO_REPO UNSET and asserts a
# workflow sitting in the worktree surfaces as tier=workspace — i.e. resolve_repo
# bounded the root to the git toplevel rather than escaping upward.
it "AE3: no CLAUDE_AUTO_REPO -> shim roots to the git worktree (worktree workflow tagged workspace)"
wt="$(mktemp -d)"
( cd "$wt" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$wt/.claude/auto/workflows" "$wt/sub/deep"
cat > "$wt/.claude/auto/workflows/wtonly.json" <<'JSON'
{"name":"wtonly","version":"1","phase_order":["work"],"terminal_phase":"work","steps":[{"id":"u","phase":"work","invokes":{}}],"description":"worktree workflow"}
JSON
tier="$(cd "$wt/sub/deep" && unset CLAUDE_AUTO_REPO && bash "$LIST_SH" | awk -F'\t' '$1=="wtonly"{print $2}')"
assert_eq "workspace" "$tier"

# ─── preview surface ────────────────────────────────────────────────────────
it "picker preview: --render a4 produces a topology card naming the producer"
card="$(CLAUDE_AUTO_REPO="$(mktemp -d)" bash "$LIST_SH" --render a4)"
case "$card" in
  *"workflow: a4"*"plan_output_to_paired_builders"*) pass ;;
  *) fail "card missing name or producer: $(printf '%s' "$card" | head -3)" ;;
esac

# ─── U8 / KTD-4: the forwarding stub at the RETIRED path still works ─────────
# `lib/recipes-list.sh` was the picker's data layer before the rename, and older
# skill prose named it directly — so it survives one minor version as a 2-line
# forwarding stub. It is GLOBALLY PATH-WHITELISTED in the vocabulary audit (it must
# spell the retired name; that is its whole job), which means the audit can never
# fail on it — and therefore nothing else would notice if the stub broke. A stub
# that silently stops forwarding is worse than no stub: the caller gets an empty
# picker, not an error. So pin BOTH halves of the contract here.
STUB_SH="${AUTO_ROOT}/lib/recipes-list.sh"

it "the retired lib/recipes-list.sh path still exists as a forwarding stub"
[ -f "$STUB_SH" ] && pass || fail "the KTD-4 forwarding stub is missing"

it "the stub forwards: its OUTPUT is byte-identical to workflows-list.sh"
_repo="$(mktemp -d)"
stub_out="$(CLAUDE_AUTO_REPO="$_repo" bash "$STUB_SH" 2>/dev/null)"
real_out="$(CLAUDE_AUTO_REPO="$_repo" bash "$LIST_SH" 2>/dev/null)"
if [ -n "$real_out" ] && [ "$stub_out" = "$real_out" ]; then
  pass
else
  fail "stub output diverged from workflows-list.sh (stub=$(printf '%s' "$stub_out" | wc -l) lines, real=$(printf '%s' "$real_out" | wc -l) lines)"
fi

it "the stub forwards ARGS too (--render a4 still produces the topology card)"
card="$(CLAUDE_AUTO_REPO="$(mktemp -d)" bash "$STUB_SH" --render a4 2>/dev/null)"
case "$card" in
  *"workflow: a4"*"plan_output_to_paired_builders"*) pass ;;
  *) fail "stub did not forward --render: $(printf '%s' "$card" | head -3)" ;;
esac

it "the stub writes a deprecation notice to STDERR, never to stdout (it must not corrupt the list)"
stub_err="$(CLAUDE_AUTO_REPO="$(mktemp -d)" bash "$STUB_SH" 2>&1 >/dev/null)"
case "$stub_err" in
  *deprecated*workflows-list.sh*) pass ;;
  *) fail "expected a deprecation notice on stderr naming the new path; got: $stub_err" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "workflow-picker.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
