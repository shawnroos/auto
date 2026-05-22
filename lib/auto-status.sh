#!/usr/bin/env bash
# auto: the /auto-status read-only reporter.
#
# /auto-status [<run>] reads the durable ledger(s) at
# <repo>/.claude/auto/<run-slug>.json and prints a human-readable status:
# loop_phase (+ plan_step), the CACHED exit_predicate_result (blockers / majors
# / minors / gaps_open / met), per-unit states, the driver, last_beat_at +
# liveness vs the orphan GRACE, and any stalled units with their last_error
# cause. With no run-id and >1 active run, it lists them.
#
# READ-ONLY: it never mutates the ledger, never arms a tick, never takes a write
# lock. It reads the cached exit_predicate_result field directly and NEVER
# re-derives it (memory `feedback_loop_monitor_terminal_state_field`).
#
# Subcommands / args (Claude Code does not dispatch space-separated subcommands,
# so the argument string is PARSED HERE — never in the .md body, per memory
# `feedback_slash_command_arg_substitution`):
#   (no args)   resolve the active run; list if >1 active; report none cleanly.
#   <run>       report that specific run.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3` (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, matches lib/ledger.sh / lib/auto-resume.sh).
#
# $ARGUMENTS-safe: the command .md body's only $-bearing line is
#   bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh" "$ARGUMENTS"
# ALL $-logic lives HERE; status.py parses argv positionally and never
# string-interpolates into a shell.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::status "<packed $ARGUMENTS string>" | <split args...>
#   Splits a single packed "$ARGUMENTS" string into argv (the slash-command
#   shape), then routes to status.py. The --repo is resolved by status.py
#   (defaults to $CLAUDE_AUTO_REPO or a walk-up from cwd).
auto::status() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # If invoked with a single packed "$ARGUMENTS" string, split it; otherwise
  # pass args through verbatim.
  if [ "$#" -eq 1 ]; then
    # shellcheck disable=SC2086 — deliberate word-split of the packed arg string.
    set -- $1
  fi

  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/auto-status.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::status "$@"
fi
