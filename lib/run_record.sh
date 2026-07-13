#!/usr/bin/env bash
# auto U3: thin bash shim around run_record.py.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3`, which on macOS may resolve
# to a Homebrew Python lacking modules (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32).
#
# All argument handling is positional and quoted: the only $-bearing surface a
# command `.md` body should expose is `bash lib/run_record.sh "$ARGUMENTS"`-style
# delegation, with $-logic living HERE, never in the .md (memory
# `feedback_slash_command_arg_substitution`). run_record.py itself parses argv
# positionally and never string-interpolates into a shell.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::run-record <subcommand> [args...]
#   read <repo> <run>                   -> run-record JSON on stdout
#   path <repo> <run>                   -> run-record file path on stdout
#   transition <repo> <run> <step> <st> -> grammar-checked state change
#   is-orphaned <repo> <run>            -> "true" | "false"
#   # Plan-loop FEEDBACK (v0.4.3) — repo auto-resolved from cwd, pass only <run>:
#   set-gaps-open <run> <N>                       -> after /ce-doc-review
#   set-enumerated-steps <run> <plan-step> <json> -> after enumerate (plan-done)
#   # Work-loop VERDICT channel (v0.6.8) — repo auto-resolved, pass only <run>:
#   record-verdict <run> <step> <json-findings> [attempt] -> write a step verdict
#   set-verdict-decision <run> <gate> <decision> [json]    -> advance|iterate|exit
auto::run_record() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/run_record.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::run_record "$@"
fi
