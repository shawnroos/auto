#!/usr/bin/env bash
# auto: the /auto run-creation entry point (the path the engine
# otherwise lacks).
#
# /auto initializes a NEW run from a plan/spec: it creates the durable
# ledger at <repo>/.claude/auto/<run-slug>.json (loop_phase="plan", empty
# units — the plan-loop populates work units later via the backend), and emits
# an arm-first-tick INTENT (JSON) that the MODEL acts on by setting the
# deliberate-stop /goal and firing the first ScheduleWakeup /auto:auto-tick.
#
# Subcommands / flags (Claude Code does not dispatch space-separated
# subcommands, so the argument string is PARSED HERE — never in the .md body,
# per memory `feedback_slash_command_arg_substitution`):
#   <plan-or-spec>            required: start a run from this plan/spec file.
#   ... auto                  skip the plan->work seam pause (tick gets --auto).
#   ... --backend ce|native   workflow backend (default ce).
#   ... --goal "<text>"       compound deliberate-stop goal (default: the loop's
#                             own exit predicate).
#
# DOUBLE-DRIVE GUARD: run creation routes through ledger.py::init_ledger, which
# holds the per-run init flock across the existence-check + atomic write (two
# concurrent inits cannot both win — one raises LedgerExists). The "arm first
# tick" path emits a re-arm INTENT (JSON) that the MODEL acts on by firing
# /auto:auto-tick; the tick then acquires its OWN non-blocking process-held
# _tick_lock (lib/tick.py::_tick_lock) which is the actual double-drive guard.
# Adding a flock here would deadlock against the tick. So: init inherits the
# init flock; arm-first-tick defers to the tick's process-held lock. Both are
# flock-based and released on clean exit — there is NO file sentinel to go stale.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3` (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, matches lib/ledger.sh / lib/auto-resume.sh).
#
# $ARGUMENTS-safe: the command .md body's only $-bearing line is
#   bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "$ARGUMENTS"
# ALL $-logic lives HERE; dispatch.py parses argv positionally and never
# string-interpolates into a shell.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::auto "<packed $ARGUMENTS string>" | <split args...>
#   Splits a single packed "$ARGUMENTS" string into argv (the slash-command
#   shape), then routes to dispatch.py. The --repo is resolved by dispatch.py
#   (defaults to $CLAUDE_AUTO_REPO or a walk-up from cwd).
auto::auto() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # If invoked with a single packed "$ARGUMENTS" string, split it; otherwise
  # pass args through verbatim.
  if [ "$#" -eq 1 ]; then
    # shellcheck disable=SC2086 — deliberate word-split of the packed arg string.
    set -- $1
  fi

  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/auto.py" "$@"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::auto "$@"
fi
