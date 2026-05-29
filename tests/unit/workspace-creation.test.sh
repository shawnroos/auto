#!/usr/bin/env bash
# auto v0.4.1 U4 (plan 004): auto_workspace.create() builds a project
# workspace via the declarative cmux layout JSON (spike addendum
# discovered the canonical shape), enumerates panes + surfaces, and
# writes the marker atomically.
#
# Verifies:
#   1. create() invokes new-workspace --layout with the correct shape
#      (direction: horizontal, split: 0.5, children: [{pane:{surfaces:[...]}}, ...])
#   2. The layout's left child carries the `claude` command, right is empty
#   3. After cmux returns "OK workspace:<id>", create() lists panes
#      then lists surfaces in the left pane
#   4. Marker is written atomically to <repo>/.claude/auto/workspace.json
#   5. Marker carries workspace_id, left/right pane_id, primary_surface_id,
#      layout_version, tabs[0] = primary
#   6. force=False with existing marker raises (refuses to overwrite)
#   7. force=True overwrites
#   8. cmux unavailable raises WorkspaceError with clear message
#   9. cmux new-workspace failure surfaces as WorkspaceError
#  10. <2 panes returned raises (workspace layout malformed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WS="$ROOT/lib/auto-workspace.py"

SANDBOX="$(mktemp -d -t ws-create.XXXXXX)"
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
export HOME="$SANDBOX"
trap 'export HOME="$ORIG_HOME" PATH="$ORIG_PATH"; rm -rf "$SANDBOX"' EXIT

# Stub cmux: log argv + emit deterministic IDs per subcommand.
STUB_BIN="$SANDBOX/bin"
CMUX_LOG="$SANDBOX/cmux.log"
mkdir -p "$STUB_BIN"
# Unquoted heredoc so $CMUX_LOG is interpolated to the literal path at
# stub-creation time. $* and $1 are escaped (\$) so they expand at
# stub-runtime instead.
cat > "$STUB_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CMUX_LOG"
case "\$1" in
  new-workspace)
    if [ -n "\${CLAUDE_AUTO_TEST_NEW_WS_RC:-}" ] && [ "\${CLAUDE_AUTO_TEST_NEW_WS_RC}" != "0" ]; then
      echo "\${CLAUDE_AUTO_TEST_NEW_WS_STDERR:-error: layout invalid}" >&2
      exit "\${CLAUDE_AUTO_TEST_NEW_WS_RC}"
    fi
    echo "\${CLAUDE_AUTO_TEST_NEW_WS_OUT:-OK workspace:stub-ws-1}"
    ;;
  list-panes)
    printf '%s\n' "\${CLAUDE_AUTO_TEST_LIST_PANES_OUT:-pane:stub-left-1  [1 surface]
pane:stub-right-1  [1 surface]}"
    ;;
  list-pane-surfaces)
    echo "\${CLAUDE_AUTO_TEST_LIST_SURFACES_OUT:-surface:stub-primary-1  [terminal]}"
    ;;
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

# ── Scenario 1: create() invokes new-workspace with the correct layout
auto_test::it "create invokes cmux new-workspace --layout with the documented shape"
R1="$(make_repo)"
: > "$CMUX_LOG"
"$PY" "$WS" create "$R1" --name "test-proj" >/dev/null 2>&1
new_ws_line="$(grep "^new-workspace" "$CMUX_LOG")"
if echo "$new_ws_line" | grep -q -- "--name test-proj" && \
   echo "$new_ws_line" | grep -q -- "--cwd $R1" && \
   echo "$new_ws_line" | grep -q -- "--layout" && \
   echo "$new_ws_line" | grep -q -- "--focus true"; then
  auto_test::pass
else
  auto_test::fail "new-workspace argv wrong: $new_ws_line"
fi
rm -rf "$R1"

# ── Scenario 2: layout JSON shape (direction horizontal, split 0.5, two panes)
# Use python to parse the entire log file (avoids shell-string-into-python
# quoting hazards). The log line has --layout followed by an inline JSON
# blob that spans the rest of the line up to ` --focus`.
parse_layout_field() {
  local repo="$1" field="$2"
  "$PY" - "$CMUX_LOG" "$field" <<'PYEOF'
import json, re, sys
log = open(sys.argv[1]).read()
field = sys.argv[2]
# Find the --layout arg up to the next ' --' (next CLI flag).
m = re.search(r'--layout (.*?) --(?:focus|cwd|name)', log)
if not m:
    print("ERR-no-layout")
    sys.exit(0)
try:
    d = json.loads(m.group(1))
except Exception as exc:
    print(f"ERR-json: {exc}")
    sys.exit(0)
# Walk dotted-field accessor.
cur = d
for part in field.split('.'):
    if part.isdigit():
        cur = cur[int(part)]
    else:
        cur = cur.get(part) if isinstance(cur, dict) else None
    if cur is None:
        print("ERR-missing-field")
        sys.exit(0)
print(cur)
PYEOF
}

auto_test::it "layout JSON declares horizontal split with two child panes"
R2="$(make_repo)"
: > "$CMUX_LOG"
"$PY" "$WS" create "$R2" >/dev/null 2>&1
dir="$(parse_layout_field "$R2" direction)"
split="$(parse_layout_field "$R2" split)"
if [ "$dir" = "horizontal" ] && [ "$split" = "0.5" ]; then
  auto_test::pass
else
  auto_test::fail "expected horizontal/0.5; got direction=$dir split=$split"
fi
rm -rf "$R2"

# ── Scenario 3: left child runs `claude`, right is plain terminal
auto_test::it "layout left pane runs claude, right pane is plain terminal"
R3="$(make_repo)"
: > "$CMUX_LOG"
"$PY" "$WS" create "$R3" >/dev/null 2>&1
left_cmd="$(parse_layout_field "$R3" children.0.pane.surfaces.0.command)"
right_type="$(parse_layout_field "$R3" children.1.pane.surfaces.0.type)"
if [ "$left_cmd" = "claude" ] && [ "$right_type" = "terminal" ]; then
  auto_test::pass
else
  auto_test::fail "expected left.command=claude / right.type=terminal; got left=$left_cmd / right=$right_type"
fi
rm -rf "$R3"

# ── Scenario 4: after new-workspace, lists panes then surfaces
# The log captures the whole argv on one line per call (newline-separated
# between calls). So we count newlines and check the order of substrings.
auto_test::it "create lists panes then lists surfaces in left pane (order)"
R4="$(make_repo)"
: > "$CMUX_LOG"
"$PY" "$WS" create "$R4" >/dev/null 2>&1
# Sequence check via grep line numbers (each call is on its own line).
order_ok="$("$PY" - "$CMUX_LOG" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
seen_new_ws = seen_list_panes = seen_list_surfaces = False
for i, line in enumerate(lines):
    if line.startswith("new-workspace") and not seen_new_ws:
        seen_new_ws = i
    elif line.startswith("list-panes") and seen_new_ws is not False and seen_list_panes is False:
        seen_list_panes = i
    elif line.startswith("list-pane-surfaces") and seen_list_panes is not False and seen_list_surfaces is False:
        seen_list_surfaces = i
ok = (seen_new_ws is not False and
      seen_list_panes is not False and
      seen_list_surfaces is not False and
      seen_new_ws < seen_list_panes < seen_list_surfaces)
print("yes" if ok else f"no: new_ws={seen_new_ws} list_panes={seen_list_panes} list_surfaces={seen_list_surfaces}")
PYEOF
)"
if [ "$order_ok" = "yes" ]; then
  auto_test::pass
else
  auto_test::fail "wrong order: $order_ok / log:\n$(cat $CMUX_LOG)"
fi
rm -rf "$R4"

# ── Scenario 5: marker carries all required fields
auto_test::it "marker carries workspace_id, left/right pane_id, primary_surface_id, layout_version, primary tab"
R5="$(make_repo)"
"$PY" "$WS" create "$R5" >/dev/null 2>&1
shape_ok="$("$PY" -c "
import json
m = json.load(open('$R5/.claude/auto/workspace.json'))
required = ('workspace_id', 'left_pane_id', 'right_pane_id',
            'primary_surface_id', 'layout_version', 'created_at', 'tabs')
ok = (all(k in m for k in required) and
      m['workspace_id'] == 'workspace:stub-ws-1' and
      m['left_pane_id'] == 'pane:stub-left-1' and
      m['right_pane_id'] == 'pane:stub-right-1' and
      m['primary_surface_id'] == 'surface:stub-primary-1' and
      m['layout_version'] == 'v1' and
      len(m['tabs']) == 1 and
      m['tabs'][0]['kind'] == 'primary')
print('yes' if ok else f'no: {m}')
")"
if [ "$shape_ok" = "yes" ]; then
  auto_test::pass
else
  auto_test::fail "marker shape wrong: $shape_ok"
fi
rm -rf "$R5"

# ── Scenario 6: existing marker without --force raises
auto_test::it "existing marker without --force raises with clear error"
R6="$(make_repo)"
mkdir -p "$R6/.claude/auto"
echo '{"workspace_id":"workspace:pre-existing"}' > "$R6/.claude/auto/workspace.json"
set +e
out="$("$PY" "$WS" create "$R6" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "marker already exists"; then
  auto_test::pass
else
  auto_test::fail "expected non-zero + 'marker already exists', got rc=$rc: $out"
fi
rm -rf "$R6"

# ── Scenario 7: --force overwrites existing marker
auto_test::it "--force overwrites existing marker"
R7="$(make_repo)"
mkdir -p "$R7/.claude/auto"
echo '{"workspace_id":"workspace:pre-existing"}' > "$R7/.claude/auto/workspace.json"
"$PY" "$WS" create "$R7" --force >/dev/null 2>&1
new_id="$("$PY" -c "import json; print(json.load(open('$R7/.claude/auto/workspace.json'))['workspace_id'])")"
auto_test::assert_eq "workspace:stub-ws-1" "$new_id"
rm -rf "$R7"

# ── Scenario 8: cmux unavailable raises WorkspaceError
auto_test::it "cmux unavailable → exits 1 with clear error"
R8="$(make_repo)"
set +e
out="$(PATH="/usr/bin:/bin" "$PY" "$WS" create "$R8" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "cmux required"; then
  auto_test::pass
else
  auto_test::fail "expected rc=1 + 'cmux required', got rc=$rc: $out"
fi
rm -rf "$R8"

# ── Scenario 9: cmux new-workspace failure surfaces as WorkspaceError
auto_test::it "cmux new-workspace failure → exits 1 with the cmux error"
R9="$(make_repo)"
set +e
out="$(CLAUDE_AUTO_TEST_NEW_WS_RC=1 \
       CLAUDE_AUTO_TEST_NEW_WS_STDERR="error: layout invalid" \
       "$PY" "$WS" create "$R9" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "cmux new-workspace failed"; then
  auto_test::pass
else
  auto_test::fail "expected rc=1 + cmux error, got rc=$rc: $out"
fi
rm -rf "$R9"

# ── Scenario 10: <2 panes returned raises
auto_test::it "list-panes returns <2 panes → raises (layout malformed)"
R10="$(make_repo)"
set +e
out="$(CLAUDE_AUTO_TEST_LIST_PANES_OUT="pane:only-one" \
       "$PY" "$WS" create "$R10" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "panes (expected"; then
  auto_test::pass
else
  auto_test::fail "expected pane-count error, got rc=$rc: $out"
fi
rm -rf "$R10"

# ── Scenario 11: marker written with 0600 mode
auto_test::it "marker file is created with 0600 mode (operator-only)"
R11="$(make_repo)"
"$PY" "$WS" create "$R11" >/dev/null 2>&1
mode="$(stat -f '%Lp' "$R11/.claude/auto/workspace.json" 2>/dev/null || stat -c '%a' "$R11/.claude/auto/workspace.json")"
auto_test::assert_eq "600" "$mode"
rm -rf "$R11"

auto_test::summary
exit $?
