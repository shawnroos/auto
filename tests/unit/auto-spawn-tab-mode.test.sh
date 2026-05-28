#!/usr/bin/env bash
# auto v0.4.1 U3 (plan 004): auto-spawn.py routes to tab-mode when a
# project workspace marker is present AND $CMUX_WORKSPACE_ID matches.
# Otherwise it falls through to the v0.4.0 workspace-per-plan mode.
#
# Verifies:
#   1. No marker → workspace-per-plan dispatch (each plan = new workspace).
#   2. Marker + matching env → tab-mode (each plan = new-surface in left pane).
#   3. Marker + mismatched env → workspace-per-plan fallback.
#   4. Tab-mode records cmux.tab_surface_id in the batch sidecar.
#   5. Workspace mode records cmux.mode = "workspace" + tab_surface_id null.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
SPAWN="$ROOT/lib/auto-spawn.py"

SANDBOX="$(mktemp -d -t spawn-tab.XXXXXX)"
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
export HOME="$SANDBOX"
trap 'export HOME="$ORIG_HOME" PATH="$ORIG_PATH"; rm -rf "$SANDBOX"' EXIT

# Stub cmux: log argv and emit surface IDs for new-surface.
STUB_BIN="$SANDBOX/bin"
CMUX_LOG="$SANDBOX/cmux.log"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CMUX_LOG"
case "\$1" in
  new-surface) echo "surface:stub-surface-id" ;;
  list-workspaces) echo "\${CLAUDE_AUTO_TEST_WS_LIST:-workspace:proj-1}" ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/cmux"
export PATH="$STUB_BIN:$PATH"

make_host_repo() {
  local repo; repo="$(mktemp -d -t spawn-host.XXXXXX)"
  (
    cd "$repo"
    git init -q
    git config user.email t@t
    git config user.name t
    printf '.claude/\nworktrees/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  )
  echo "$repo"
}

seed_plans() {
  local repo="$1"; shift
  mkdir -p "$repo/docs/plans"
  for name in "$@"; do
    printf '# %s\n' "$name" > "$repo/docs/plans/${name}.md"
  done
}

plant_marker() {
  local repo="$1" workspace_id="$2"
  mkdir -p "$repo/.claude/auto"
  cat > "$repo/.claude/auto/workspace.json" <<EOF
{
  "workspace_id": "$workspace_id",
  "left_pane_id": "pane:left-1",
  "created_at": "2026-05-27T00:00:00Z"
}
EOF
}

run_fanout() {
  local repo="$1"; shift
  (cd "$repo" && "$PY" "$SPAWN" fanout "$@" >/dev/null 2>&1; echo $?)
}

read_sidecar_field() {
  local repo="$1" jq_path="$2"
  local sidecar
  sidecar="$(find "$repo/.claude/auto/batches" -name "*.json" 2>/dev/null | head -1)"
  [ -z "$sidecar" ] && return 1
  "$PY" -c "import json,sys; d=json.load(open('$sidecar')); print($jq_path)"
}

# ── Scenario 1: no marker → workspace-per-plan dispatch
auto_test::it "no marker → workspace-per-plan dispatch (new-workspace per plan)"
R1="$(make_host_repo)"
seed_plans "$R1" "p1" "p2"
: > "$CMUX_LOG"
unset CMUX_WORKSPACE_ID
rc="$(run_fanout "$R1" "docs/plans/p1.md" "docs/plans/p2.md")"
auto_test::assert_eq "0" "$rc"
ws_count="$(grep -c "new-workspace" "$CMUX_LOG" || true)"
auto_test::assert_eq "2" "$ws_count"
mode_p1="$(read_sidecar_field "$R1" 'd["plans"][0]["cmux"]["mode"]')"
auto_test::assert_eq "workspace" "$mode_p1"
rm -rf "$R1"

# ── Scenario 2: marker + matching env → tab-mode (new-surface per plan)
auto_test::it "marker + matching env → tab-mode (new-surface + send per plan)"
R2="$(make_host_repo)"
seed_plans "$R2" "p1" "p2"
plant_marker "$R2" "workspace:proj-2"
: > "$CMUX_LOG"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:proj-2"
export CMUX_WORKSPACE_ID="workspace:proj-2"
rc="$(run_fanout "$R2" "docs/plans/p1.md" "docs/plans/p2.md")"
auto_test::assert_eq "0" "$rc"
surface_count="$(grep -c "new-surface" "$CMUX_LOG" || true)"
send_count="$(grep -c "^send --surface" "$CMUX_LOG" || true)"
# Each plan = 1 new-surface + 1 send. detect() also calls list-workspaces.
auto_test::assert_eq "2" "$surface_count"
auto_test::assert_eq "2" "$send_count"
mode_p1="$(read_sidecar_field "$R2" 'd["plans"][0]["cmux"]["mode"]')"
auto_test::assert_eq "tab" "$mode_p1"
surface_p1="$(read_sidecar_field "$R2" 'd["plans"][0]["cmux"]["tab_surface_id"]')"
auto_test::assert_eq "surface:stub-surface-id" "$surface_p1"
rm -rf "$R2"

# ── Scenario 3: marker + mismatched env → workspace-per-plan fallback
auto_test::it "marker + mismatched env → workspace-per-plan fallback"
R3="$(make_host_repo)"
seed_plans "$R3" "p1"
plant_marker "$R3" "workspace:proj-3"
: > "$CMUX_LOG"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:proj-3"
export CMUX_WORKSPACE_ID="workspace:different-id"
rc="$(run_fanout "$R3" "docs/plans/p1.md")"
auto_test::assert_eq "0" "$rc"
ws_count="$(grep -c "new-workspace" "$CMUX_LOG" || true)"
surface_count="$(grep -c "new-surface" "$CMUX_LOG" || true)"
auto_test::assert_eq "1" "$ws_count"
auto_test::assert_eq "0" "$surface_count"
rm -rf "$R3"

# ── Scenario 4: marker exists but cmux says workspace gone → fallback
auto_test::it "marker stale (cmux workspace missing) → workspace-per-plan fallback"
R4="$(make_host_repo)"
seed_plans "$R4" "p1"
plant_marker "$R4" "workspace:proj-4"
: > "$CMUX_LOG"
# Cmux only knows about a different workspace; marker is stale.
export CLAUDE_AUTO_TEST_WS_LIST="workspace:something-else"
export CMUX_WORKSPACE_ID="workspace:proj-4"
rc="$(run_fanout "$R4" "docs/plans/p1.md")"
auto_test::assert_eq "0" "$rc"
ws_count="$(grep -c "new-workspace" "$CMUX_LOG" || true)"
auto_test::assert_eq "1" "$ws_count"
rm -rf "$R4"

auto_test::summary
exit $?
