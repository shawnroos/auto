#!/usr/bin/env bash
# auto v0.4.1 U1 spike runner — verify cmux new-workspace --layout JSON shape.
#
# This script EXECUTES against a real cmux daemon. It cannot be run by a
# subagent (which has no reliable cmux access). Run it interactively:
#
#   bash tests/spike/cmux-layout/run-spike.sh
#
# It builds candidate layout JSON shapes, invokes `cmux new-workspace
# --layout` against each, captures stdout + the workspace's resulting
# pane/surface tree, and writes results to
# docs/research/cmux-layout-fanout-spike.md.
#
# Three runs:
#   A. Workspace with declarative left/right split + claude in left pane.
#   B. After A: add a tab to the left pane via new-surface; verify visible.
#   C. From inside B's tab: spawn another tab (recursion check).
#
# Outputs:
#   - On stdout: each step's verdict + the JSON shapes that worked.
#   - Appended to: docs/research/cmux-layout-fanout-spike.md
#
# Cleanup: each created workspace is closed at the end UNLESS
# CLAUDE_AUTO_SPIKE_KEEP=1 is set (helpful for visual inspection).

set -uo pipefail

REPO="$(cd "$(dirname "$0")"/../../.. && pwd)"
SPIKE_DOC="$REPO/docs/research/cmux-layout-fanout-spike.md"
RESULTS_DIR="$REPO/tests/spike/cmux-layout"

if ! command -v cmux >/dev/null 2>&1; then
  echo "FAIL: cmux CLI not on PATH"
  exit 1
fi

mkdir -p "$(dirname "$SPIKE_DOC")"

# Initialize the spike doc if it doesn't exist.
if [ ! -f "$SPIKE_DOC" ]; then
  cat > "$SPIKE_DOC" <<EOF
# U1 spike: cmux new-workspace --layout JSON shape

**Date:** $(date -u +%Y-%m-%d)
**Unit:** plan 004 U1 (gated spike — decides U2-U5's dispatch shape)
**Status:** in progress

## Question

Does \`cmux new-workspace --layout <json>\` reliably create a
declarative split + per-surface commands in one call, and what is
the actual JSON shape it accepts?

## Method

Run-A, Run-B, Run-C scripts under \`tests/spike/cmux-layout/\`,
invoked against a real cmux daemon. Capture each shape's verdict.

EOF
fi

log_section() {
  local title="$1"
  {
    echo ""
    echo "## $title"
    echo ""
    echo "**Time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } >> "$SPIKE_DOC"
}

record() {
  echo "$@" | tee -a "$SPIKE_DOC"
}

# Candidate layout shapes — we'll try them in order, recording which works.
CANDIDATES=(
  # Shape 1: nested "split" with "left"/"right" keys (the original guess).
  '{"split":"horizontal","ratio":0.5,"left":{"surfaces":[{"command":"echo LEFT-OK"}]},"right":{"surfaces":[{"command":"echo RIGHT-OK"}]}}'
  # Shape 2: tmux-style "panes" array with direction.
  '{"direction":"horizontal","panes":[{"command":"echo LEFT-OK"},{"command":"echo RIGHT-OK"}]}'
  # Shape 3: tree of splits with type tags.
  '{"type":"split","direction":"horizontal","children":[{"type":"surface","command":"echo LEFT-OK"},{"type":"surface","command":"echo RIGHT-OK"}]}'
  # Shape 4: simple surface array, cmux infers split.
  '{"surfaces":[{"command":"echo LEFT-OK"},{"command":"echo RIGHT-OK"}]}'
)

WS_ID=""
WORKING_SHAPE=""

log_section "Run A — layout JSON candidates"
record "Trying ${#CANDIDATES[@]} candidate JSON shapes against \`cmux new-workspace --layout\`."
record ""

for i in "${!CANDIDATES[@]}"; do
  shape="${CANDIDATES[$i]}"
  record "### Shape $((i+1))"
  record ''
  record '```json'
  record "$shape"
  record '```'
  record ''

  out="$(cmux new-workspace --name "spike-A-$i" --layout "$shape" --focus false 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    record "**Verdict:** PASS (rc=0)"
    record ''
    record '```'
    record "$out"
    record '```'
    record ''
    if [ -z "$WORKING_SHAPE" ]; then
      WORKING_SHAPE="$shape"
      WS_ID="$(echo "$out" | grep -oE 'workspace:[0-9a-f-]+' | head -1)"
      record "**Captured workspace ID:** \`$WS_ID\`"
    fi
  else
    record "**Verdict:** FAIL (rc=$rc)"
    record ''
    record '```'
    record "$out"
    record '```'
    record ''
  fi
done

if [ -z "$WORKING_SHAPE" ]; then
  record ""
  record "## OVERALL VERDICT: FAIL"
  record ""
  record "None of the candidate shapes were accepted by cmux. Plan 004"
  record "must reshape U2 to use the imperative chain"
  record "(new-workspace + new-split + new-surface + send) instead of"
  record "declarative layout JSON."
  echo ""
  echo "All candidates failed. See $SPIKE_DOC for the captured output."
  exit 1
fi

# ── Run B — add a tab via new-surface ─────────────────────────────────────
log_section "Run B — add tab via new-surface"

# Need to find the left pane. cmux list-panes returns them in order.
panes_out="$(cmux list-panes --workspace "$WS_ID" 2>&1)"
record '```'
record "$panes_out"
record '```'
record ''
LEFT_PANE="$(echo "$panes_out" | grep -oE 'pane:[0-9a-f-]+' | head -1)"
record "**Left pane (first):** \`$LEFT_PANE\`"
record ''

surface_out="$(cmux new-surface --pane "$LEFT_PANE" --focus false 2>&1)"
surface_rc=$?
record "**new-surface result (rc=$surface_rc):**"
record ''
record '```'
record "$surface_out"
record '```'
record ''

NEW_SURFACE="$(echo "$surface_out" | grep -oE 'surface:[0-9a-f-]+' | head -1)"
if [ -n "$NEW_SURFACE" ]; then
  record "**Captured new surface ID:** \`$NEW_SURFACE\`"
  # Send a command via send
  send_out="$(cmux send --surface "$NEW_SURFACE" "sleep 1; echo TAB-B-OK" 2>&1)"
  send_rc=$?
  record "**send result (rc=$send_rc):**"
  record '```'
  record "$send_out"
  record '```'
fi

# ── Run C — recursion check (light version) ─────────────────────────────
log_section "Run C — recursive new-surface from non-interactive context"

# Can a script running inside the workspace (we simulate via env-set) hit
# new-surface against the same pane? Use CMUX_WORKSPACE_ID env.
record "Probing whether CMUX_WORKSPACE_ID env-set call to new-surface works."
record ""
recur_out="$(CMUX_WORKSPACE_ID="$WS_ID" cmux new-surface --pane "$LEFT_PANE" --focus false 2>&1)"
recur_rc=$?
record "**Result (rc=$recur_rc):**"
record '```'
record "$recur_out"
record '```'

# ── tree dump for the final layout ───────────────────────────────────────
log_section "Final workspace tree"
tree_out="$(cmux tree --workspace "$WS_ID" 2>&1 || cmux tree 2>&1 | grep -A 20 "$WS_ID")"
record '```'
record "$tree_out"
record '```'

# ── Cleanup ────────────────────────────────────────────────────────────────
if [ "${CLAUDE_AUTO_SPIKE_KEEP:-0}" != "1" ]; then
  log_section "Cleanup"
  for i in "${!CANDIDATES[@]}"; do
    cmux close-workspace --workspace "$(cmux list-workspaces 2>&1 | grep -oE 'workspace:[0-9a-f-]+\s+spike-A-'"$i" | grep -oE 'workspace:[0-9a-f-]+' | head -1)" 2>&1 || true
  done
  record "Closed spike workspaces."
else
  record ""
  record "**CLAUDE_AUTO_SPIKE_KEEP=1 — leaving workspaces open for inspection.**"
fi

# ── Final verdict ─────────────────────────────────────────────────────────
log_section "Spike verdict"
record "**Working layout shape:**"
record ''
record '```json'
record "$WORKING_SHAPE"
record '```'
record ''
record "U2 builds on this shape. The shapes that failed are in the candidate"
record "list above; U2 should reject them at validation time."

echo ""
echo "Spike complete. Results recorded at:"
echo "  $SPIKE_DOC"
