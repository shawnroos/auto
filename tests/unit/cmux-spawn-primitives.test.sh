#!/usr/bin/env bash
# auto v0.4.1 U2: cmux primitives in lib/cmux-socket.sh — both the
# existing workspace spawn and the new auto::cmux_spawn_tab.
#
# Verifies:
#   1. auto::cmux_spawn_workspace invokes `cmux new-workspace` with
#      the verified argv shape (name, cwd, --command, --focus false).
#   2. auto::cmux_spawn_tab invokes `cmux new-surface --pane <ref>
#      --focus false` FIRST, then `cmux send --surface <captured>
#      <command-with-sleep-leadin>`.
#   3. cmux_spawn_tab echoes the new surface ID on stdout.
#   4. cmux_spawn_tab returns non-zero when new-surface fails.
#   5. The `sleep 1;` lead-in AND explicit `cd <cwd>` are in the
#      sent command (the surface doesn't accept --cwd).
#   6. The `cwd` is shell-escaped (apostrophe-safe).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"

# Sandbox + cmux stub
SANDBOX="$(mktemp -d -t cmux-prim-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

STUB_BIN="$SANDBOX/bin"
CMUX_LOG="$SANDBOX/cmux.log"
mkdir -p "$STUB_BIN"

# Stub `cmux` records argv + a controllable exit code per scenario.
write_stub() {
  local rc="$1" surface_id_line="${2:-surface:abc12345-1111-2222-3333-444455556666}"
  cat > "$STUB_BIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CMUX_LOG"
# new-surface should emit a surface ID so cmux_spawn_tab can parse it.
case "\$1" in
  new-surface) echo "$surface_id_line" ;;
esac
exit $rc
EOF
  chmod +x "$STUB_BIN/cmux"
}

export PATH="$STUB_BIN:$PATH"
export CLAUDE_AUTO_CMUX="cmux"

# Source the lib.
. "$ROOT/lib/cmux-socket.sh"

# ── Scenario 1: cmux_spawn_workspace shape (existing, regression guard)
auto_test::it "cmux_spawn_workspace invokes new-workspace with name/cwd/command/focus"
: > "$CMUX_LOG"
write_stub 0
auto::cmux_spawn_workspace "test-name" "/tmp/cwd" "echo hi" >/dev/null
grep -q "new-workspace" "$CMUX_LOG"           && \
grep -q -- "--name test-name" "$CMUX_LOG"     && \
grep -q -- "--cwd /tmp/cwd" "$CMUX_LOG"       && \
grep -q -- "--command echo hi" "$CMUX_LOG"    && \
grep -q -- "--focus false" "$CMUX_LOG"        && auto_test::pass || \
auto_test::fail "shape mismatch: $(cat $CMUX_LOG)"

# ── Scenario 2: cmux_spawn_tab calls new-surface FIRST then send
auto_test::it "cmux_spawn_tab issues new-surface then send in order"
: > "$CMUX_LOG"
write_stub 0
auto::cmux_spawn_tab "pane:1" "/tmp/wt" "claude '/auto plan.md'" >/dev/null
first_line="$(head -1 "$CMUX_LOG")"
second_line="$(sed -n '2p' "$CMUX_LOG")"
if echo "$first_line" | grep -q "new-surface --pane pane:1 --focus false" && \
   echo "$second_line" | grep -q "send --surface surface:"; then
  auto_test::pass
else
  auto_test::fail "order/shape wrong. log:\n$(cat $CMUX_LOG)"
fi

# ── Scenario 3: cmux_spawn_tab echoes the new surface ID
auto_test::it "cmux_spawn_tab echoes captured surface ID on stdout"
: > "$CMUX_LOG"
write_stub 0 "surface:test-surface-id-9999"
out="$(auto::cmux_spawn_tab "pane:1" "/tmp/wt" "claude '/auto plan.md'" 2>/dev/null)"
if [ "$out" = "surface:test-surface-id-9999" ]; then
  auto_test::pass
else
  auto_test::fail "expected 'surface:test-surface-id-9999', got: '$out'"
fi

# ── Scenario 4: send command includes the sleep 1; lead-in
auto_test::it "cmux_spawn_tab send command includes sleep 1; lead-in"
: > "$CMUX_LOG"
write_stub 0
auto::cmux_spawn_tab "pane:1" "/tmp/wt" "claude '/auto plan.md'" >/dev/null
if grep -q "sleep 1;" "$CMUX_LOG"; then
  auto_test::pass
else
  auto_test::fail "sleep 1; lead-in missing. log:\n$(cat $CMUX_LOG)"
fi

# ── Scenario 5: send command includes explicit cd <cwd>
auto_test::it "cmux_spawn_tab send command includes explicit 'cd <cwd>'"
: > "$CMUX_LOG"
write_stub 0
auto::cmux_spawn_tab "pane:1" "/tmp/wt" "claude '/auto plan.md'" >/dev/null
if grep -q "cd /tmp/wt" "$CMUX_LOG"; then
  auto_test::pass
else
  auto_test::fail "explicit cd missing. log:\n$(cat $CMUX_LOG)"
fi

# ── Scenario 6: new-surface failure propagates non-zero
auto_test::it "cmux_spawn_tab returns non-zero when new-surface fails"
: > "$CMUX_LOG"
write_stub 7  # arbitrary non-zero
set +e
auto::cmux_spawn_tab "pane:1" "/tmp/wt" "claude '/auto plan.md'" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  auto_test::pass
else
  auto_test::fail "expected non-zero rc, got: $rc"
fi

# ── Scenario 7: cwd with apostrophe is shell-escaped (printf %q)
auto_test::it "cmux_spawn_tab quotes cwd containing apostrophe (round-1 finding parity)"
: > "$CMUX_LOG"
write_stub 0
auto::cmux_spawn_tab "pane:1" "/Users/o'malley/proj" "claude '/auto plan.md'" >/dev/null
# %q produces \\' or '\\'' depending on shell — must NOT have a raw apostrophe inside
# in a way that breaks the surrounding quote. The send line is one argv element to
# cmux, but it should be a safely-escaped string.
send_line="$(grep "send" "$CMUX_LOG")"
# The escaped path should appear somewhere — either as escaped-quote or backslash form.
if echo "$send_line" | grep -qE "(o\\\\'malley|o'\"'\"'malley|o\\\\\\'malley)"; then
  auto_test::pass
else
  auto_test::fail "cwd not properly escaped. send line: $send_line"
fi

auto_test::summary
exit $?
