#!/usr/bin/env bash
# auto v0.4.1 U3 (plan 004): auto-workspace.detect() reports the
# workspace status correctly for each scenario.
#
# Verifies the four cases in plan 004 KTD-4:
#   * unmarked — no marker file
#   * project — marker exists AND $CMUX_WORKSPACE_ID matches
#   * non-project — marker exists but env doesn't match
#   * unmarked + marker_stale — marker references a workspace cmux
#     says doesn't exist

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WS="$ROOT/lib/auto-workspace.py"

SANDBOX="$(mktemp -d -t ws-detect.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Stub cmux: --list-workspaces returns whatever WS_LIST is set to.
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-workspaces) echo "${CLAUDE_AUTO_TEST_WS_LIST:-}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/cmux"
export PATH="$STUB_BIN:$PATH"

make_repo() {
  local d; d="$(mktemp -d -t repo.XXXXXX)"
  (cd "$d" && git init -q && git commit --allow-empty -q -m init)
  echo "$d"
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

field() {
  local repo="$1" key="$2"
  "$PY" "$WS" detect "$repo" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['$key'])"
}

# ── Scenario 1: no marker → status=unmarked
auto_test::it "no marker → status=unmarked"
R1="$(make_repo)"
unset CMUX_WORKSPACE_ID
auto_test::assert_eq "unmarked" "$(field "$R1" status)"
rm -rf "$R1"

# ── Scenario 2: marker + matching env → status=project
auto_test::it "marker + matching CMUX_WORKSPACE_ID → status=project"
R2="$(make_repo)"
plant_marker "$R2" "workspace:abc123"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:abc123 (My workspace)"
export CMUX_WORKSPACE_ID="workspace:abc123"
auto_test::assert_eq "project" "$(field "$R2" status)"
rm -rf "$R2"

# ── Scenario 3: marker + mismatched env → status=non-project
auto_test::it "marker + mismatched CMUX_WORKSPACE_ID → status=non-project"
R3="$(make_repo)"
plant_marker "$R3" "workspace:abc123"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:abc123"
export CMUX_WORKSPACE_ID="workspace:different-id"
auto_test::assert_eq "non-project" "$(field "$R3" status)"
rm -rf "$R3"

# ── Scenario 4: marker but cmux says workspace gone → status=unmarked + marker_stale
auto_test::it "marker but cmux workspace missing → status=unmarked + marker_stale=true"
R4="$(make_repo)"
plant_marker "$R4" "workspace:abc123"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:other-only"
export CMUX_WORKSPACE_ID="workspace:abc123"
auto_test::assert_eq "unmarked" "$(field "$R4" status)"
auto_test::assert_eq "True" "$(field "$R4" marker_stale)"
rm -rf "$R4"

# ── Scenario 5: marker with no env (e.g. claude run outside cmux)
auto_test::it "marker but no CMUX_WORKSPACE_ID set → status=non-project"
R5="$(make_repo)"
plant_marker "$R5" "workspace:abc123"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:abc123"
unset CMUX_WORKSPACE_ID
auto_test::assert_eq "non-project" "$(field "$R5" status)"
rm -rf "$R5"

# ── Scenario 6: malformed marker → status=unmarked (rel-001 safe degrade)
auto_test::it "malformed marker JSON → status=unmarked (degrades safely)"
R6="$(make_repo)"
mkdir -p "$R6/.claude/auto"
echo "not valid json {" > "$R6/.claude/auto/workspace.json"
auto_test::assert_eq "unmarked" "$(field "$R6" status)"
rm -rf "$R6"

# ── Scenario 7: marker_path field populated when marker exists
auto_test::it "marker_path field is the absolute marker path when marker exists"
R7="$(make_repo)"
plant_marker "$R7" "workspace:abc123"
export CLAUDE_AUTO_TEST_WS_LIST="workspace:abc123"
export CMUX_WORKSPACE_ID="workspace:abc123"
actual_path="$(field "$R7" marker_path)"
expected_path="$R7/.claude/auto/workspace.json"
auto_test::assert_eq "$expected_path" "$actual_path"
rm -rf "$R7"

auto_test::summary
exit $?
