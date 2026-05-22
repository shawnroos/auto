#!/usr/bin/env bash
# claude-dispatch U3: thin bash shim around ledger.py.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_DISPATCH_PYTHON3) — never bare `python3`, which on macOS may resolve
# to a Homebrew Python lacking modules (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32).
#
# All argument handling is positional and quoted: the only $-bearing surface a
# command `.md` body should expose is `bash lib/ledger.sh "$ARGUMENTS"`-style
# delegation, with $-logic living HERE, never in the .md (memory
# `feedback_slash_command_arg_substitution`). ledger.py itself parses argv
# positionally and never string-interpolates into a shell.

set -uo pipefail

CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

# claude_dispatch::ledger <subcommand> [args...]
#   read <repo> <run>                   -> ledger JSON on stdout
#   path <repo> <run>                   -> ledger file path on stdout
#   transition <repo> <run> <unit> <st> -> grammar-checked state change
#   is-orphaned <repo> <run>            -> "true" | "false"
claude_dispatch::ledger() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_DISPATCH_PYTHON3" "${script_dir}/ledger.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_dispatch::ledger "$@"
fi
