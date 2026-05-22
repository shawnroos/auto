#!/usr/bin/env bash
# claude-dispatch U10: thin bash shim around orchestrator.py.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_DISPATCH_PYTHON3) — never bare `python3`, which on macOS may resolve
# to a Homebrew Python lacking modules (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, and sibling lib/ledger.sh).
#
# All argument handling is positional and quoted: the only $-bearing surface a
# command `.md` body should expose is `bash lib/orchestrator.sh "$ARGUMENTS"`-
# style delegation, with $-logic living HERE, never in the .md (memory
# `feedback_slash_command_arg_substitution`). orchestrator.py itself parses argv
# positionally and never string-interpolates into a shell.

set -uo pipefail

CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

# claude_dispatch::orchestrator <subcommand> [args...]
#   ready    <repo> <run>                     -> one ready unit id per line
#   dispatch <repo> <run> <cap> <unit...>     -> "<unit>\t<status>" per line
#   converge <repo> <run>                     -> converge summary JSON on stdout
#
# NOTE: the agent-launch boundary (launch_fn) is a Python-level injected
# callable wired by U5's driver; the CLI `dispatch` path uses the default
# no-op launcher (it only performs the pending->dispatched ledger transition).
claude_dispatch::orchestrator() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_DISPATCH_PYTHON3" "${script_dir}/orchestrator.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_dispatch::orchestrator "$@"
fi
