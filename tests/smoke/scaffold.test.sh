#!/usr/bin/env bash
# auto smoke test: the plugin shell is well-formed.
#
# Verifies (U2 acceptance):
#   - the manifest parses as JSON and wires commands/skills/hooks
#   - the hooks.json scaffold parses as JSON
#   - the three commands resolve (the .md files exist)
#   - each command body's ONLY $-bearing line is the canonical
#     `bash "${CLAUDE_PLUGIN_ROOT}/lib/X.sh" "$ARGUMENTS"` dispatch
#     (memory feedback_slash_command_arg_substitution) — this is also
#     what guarantees the "empty args -> lib gets empty positional"
#     edge behavior: the .md does no $-logic, so an empty $ARGUMENTS is
#     handed straight to the lib script unchanged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

MANIFEST="$ROOT/.claude-plugin/plugin.json"
HOOKS="$ROOT/.claude/hooks/hooks.json"

# ── Manifest exists and parses as JSON ──────────────────────────────────────
auto_test::it "manifest file exists"
auto_test::assert_file_exists "$MANIFEST"

auto_test::it "manifest parses as JSON"
auto_test::assert_true "'$PY' -c 'import json,sys; json.load(open(sys.argv[1]))' '$MANIFEST'"

# ── Manifest wires the expected keys to the expected paths ───────────────────
_manifest_get() {
  "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$MANIFEST" "$1"
}

auto_test::it "manifest name is auto"
auto_test::assert_eq "auto" "$(_manifest_get name)"

auto_test::it "manifest has a version"
auto_test::assert_ne "" "$(_manifest_get version)"

auto_test::it "manifest wires commands -> ./commands"
auto_test::assert_eq "./commands" "$(_manifest_get commands)"

auto_test::it "manifest wires skills -> ./skills"
auto_test::assert_eq "./skills" "$(_manifest_get skills)"

auto_test::it "manifest wires hooks -> ./.claude/hooks/hooks.json"
auto_test::assert_eq "./.claude/hooks/hooks.json" "$(_manifest_get hooks)"

# ── Wired paths actually exist (so the plugin loads) ─────────────────────────
auto_test::it "wired commands dir exists"
auto_test::assert_true "[ -d '$ROOT/commands' ]"

auto_test::it "wired skills dir exists"
auto_test::assert_true "[ -d '$ROOT/skills' ]"

auto_test::it "wired hooks.json exists"
auto_test::assert_file_exists "$HOOKS"

auto_test::it "hooks.json parses as JSON"
auto_test::assert_true "'$PY' -c 'import json,sys; json.load(open(sys.argv[1]))' '$HOOKS'"

# ── The three commands resolve, and each is $ARGUMENTS-safe ──────────────────
# Map command file -> the lib script its body must invoke.
check_command() {
  local cmd_file="$ROOT/commands/$1"
  local lib_basename="$2"

  auto_test::it "command resolves: $1"
  auto_test::assert_file_exists "$cmd_file"

  # P0 GUARD: the lib script the command DELEGATES TO must actually exist on
  # disk. A command pointing at a missing lib/X.sh is a dead command (the bug
  # this test class exists to catch). Without this, /auto and
  # /auto-status shipped invoking lib/auto.sh / lib/auto-status.sh that did
  # not exist. Asserted for every command via the shared check_command loop, so
  # any future command->missing-script regression goes RED at CI time.
  auto_test::it "$1 referenced lib script exists: lib/${lib_basename}"
  auto_test::assert_file_exists "$ROOT/lib/${lib_basename}"

  [ -f "$cmd_file" ] || return

  # The body must contain the canonical dispatch line for its lib script.
  local expected="bash \"\${CLAUDE_PLUGIN_ROOT}/lib/${lib_basename}\" \"\$ARGUMENTS\""
  auto_test::it "$1 invokes lib/${lib_basename} with \"\$ARGUMENTS\""
  auto_test::assert_true "grep -qF '$expected' '$cmd_file'"

  # CRITICAL ($ARGUMENTS gotcha, memory feedback_slash_command_arg_substitution):
  # the ONLY line in the body that references a $-token (ARGUMENTS / 0 / 1 / 2)
  # must be that single dispatch line. Any other $-arg reference in the .md
  # would be substituted by the harness before bash runs — a latent bug.
  # We grep for $ARGUMENTS / $0 / $1 / $2 / $@ and assert there is exactly one
  # such line, and it is the dispatch line.
  local arg_lines
  arg_lines=$(grep -nE '\$(ARGUMENTS|[0-9]|@|\{ARGUMENTS)' "$cmd_file" || true)
  local arg_line_count
  arg_line_count=$(printf '%s\n' "$arg_lines" | grep -c . || true)

  auto_test::it "$1 has exactly one \$-arg line (the dispatch line)"
  auto_test::assert_eq "1" "$arg_line_count"

  auto_test::it "$1 sole \$-arg line is the dispatch line"
  case "$arg_lines" in
    *"$expected"*) auto_test::pass ;;
    *) auto_test::fail "sole \$-arg line is not the dispatch line: $arg_lines" ;;
  esac
}

check_command "auto.md" "auto.sh"
check_command "auto-status.md" "auto-status.sh"
check_command "auto-resume.md" "auto-resume.sh"
check_command "auto-pulse.md" "pulse.sh"
# The kept DEPRECATED alias (concept-vocabulary rename U5, KTD-4): in-flight runs
# have `/auto:auto-tick <run>` persisted inside ScheduleWakeup, so the old command
# file must survive one minor version AND must dispatch the SAME engine as the
# canonical command (lib/pulse.sh) — not a stale lib/tick.sh path. Removing this
# line is part of the alias removal, not of this rename.
check_command "auto-tick.md" "pulse.sh"

# ── Summary ──────────────────────────────────────────────────────────────────
auto_test::summary
exit $?
