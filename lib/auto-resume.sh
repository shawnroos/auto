#!/usr/bin/env bash
# auto U7: the /auto-resume manual floor (F4).
#
# A self-paced ScheduleWakeup tick chain does NOT survive a full session exit.
# No work is lost (durable ledger; agents self-write verdicts atomically); resume
# after any suspend is this one cheap command, reading the durable ledger fresh.
# Resume is also the routine long-run continuation path, not just the crash path.
#
# Subcommands (Claude Code does not dispatch space-separated subcommands, so the
# subcommand is PARSED HERE from the argument string — never in the .md body,
# per memory `feedback_slash_command_arg_substitution`):
#   [<run>]              default `continue`: arm a fresh tick chain (flips a
#                        paused seam -> work first if needed).
#   continue <run>       explicit continue (seam -> work, arm a tick).
#   abort <run>          flip the run to loop_phase="done" (cancellation).
#   retry <run> <unit>   stalled unit -> pending; clears last_error.
#   skip <run> <unit>    stalled unit -> terminal-skip (counts as terminal).
#
# DOUBLE-DRIVE GUARD (process-held flock, released on clean exit — NO stale
# sentinel file): this script ADDS NO NEW FLOCK. State transitions route through
# ledger.py (set_loop / transition), which holds the per-run RMW flock for the
# whole read-modify-write. The "arm a tick" path emits a re-arm INTENT (JSON)
# that the MODEL acts on by firing /auto-tick; the tick then acquires its
# OWN non-blocking _tick_lock (lib/tick.py::_tick_lock — process-held, released
# on exit) which is the actual double-drive guard. Adding a third flock here
# would deadlock against the tick. So: transitions inherit the RMW lock;
# arm-a-tick defers to the tick's process-held lock. Both are flock-based and
# released on clean exit — there is NO file sentinel to go stale.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3` (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, matches lib/ledger.sh / lib/tick.sh).
#
# $ARGUMENTS-safe: the command .md body's only $-bearing line is
#   bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "$ARGUMENTS"
# ALL $-logic lives HERE; resume.py parses argv positionally and never
# string-interpolates into a shell.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::resume "<packed $ARGUMENTS string>" | <split args...>
#   Splits a single packed "$ARGUMENTS" string into argv (the slash-command
#   shape), then routes to resume.py. The --repo is resolved by resume.py
#   (defaults to $CLAUDE_AUTO_REPO or a walk-up from cwd).
auto::resume() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # If invoked with a single packed "$ARGUMENTS" string, split it; otherwise
  # pass args through verbatim.
  if [ "$#" -eq 1 ]; then
    # shellcheck disable=SC2086 — deliberate word-split of the packed arg string.
    set -- $1
  fi

  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/auto-resume.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::resume "$@"
fi
