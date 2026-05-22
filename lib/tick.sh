#!/usr/bin/env bash
# auto U4: thin bash shim around tick.py — the `/auto-tick <run>`
# entry, fired by a ScheduleWakeup-armed prompt.
#
# THE RE-ARM BOUNDARY (read before wiring this into a command):
#   tick.py CANNOT call ScheduleWakeup — that is a MODEL tool, not a CLI. This
#   shim runs the tick (one advance + atomic ledger write) and prints the
#   re-arm INTENT as JSON on stdout:
#       {"action":"rearm","delay":60,"prompt":"/auto-tick <run>", ...}
#       {"action":"stop", ...}    {"action":"noop", ...}
#   The MODEL driving the tick reads that JSON and, when action=="rearm",
#   issues the actual `ScheduleWakeup(delay, prompt)` tool call. Do NOT add a
#   ScheduleWakeup invocation here — there is no binary to call.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3` (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, matches lib/ledger.sh).
#
# $ARGUMENTS-safe: a command `.md` body's only $-bearing line is
# `bash lib/tick.sh "$ARGUMENTS"`; ALL $-logic lives HERE, never in the .md
# (memory `feedback_slash_command_arg_substitution`). tick.py parses argv
# positionally and never string-interpolates into a shell.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::tick "<run> [--auto] [--delay N] [--repo PATH]"
#   The /auto-tick command passes the raw "$ARGUMENTS" string as $1; we
#   re-split it into argv with `set --` so flags and the run-id are parsed by
#   tick.py's argparse. Empty args -> usage (exit 2).
auto::tick() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # If invoked with a single packed "$ARGUMENTS" string, split it; otherwise
  # pass the args through verbatim. We only word-split the FIRST positional
  # when it is the sole argument (the slash-command shape).
  if [ "$#" -eq 1 ]; then
    # shellcheck disable=SC2086 — deliberate word-split of the packed arg string.
    set -- $1
  fi

  if [ "$#" -eq 0 ]; then
    echo "usage: tick.sh <run-id> [--auto] [--delay N] [--repo PATH]" >&2
    return 2
  fi

  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/tick.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::tick "$@"
fi
