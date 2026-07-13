#!/usr/bin/env bash
# auto U4 PreToolUse hook (destructive-action backstop): the deterministic
# irreversible-operation gate over Bash/Write.
#
# WHY THIS EXISTS (KTD-4/5):
#   The AskUserQuestion gate only intercepts decisions to *ask*, never decisions
#   to *act*. This second hook matches Bash command / Write content against the
#   CLAUDE.md-anchored destructive set (push --force, reset --hard, checkout .,
#   restore ., clean -f / git clean -fdx, branch -D, rm -rf, known publish
#   endpoints) and, under the SAME live-run + session_id gate, escalates via the
#   pause handoff — independent of any question. This gives the "irreversible/
#   destructive" boundary a real enforcement mechanism rather than prose the
#   agent might ignore.
#
# FAILS CLOSED (the action backstop's asymmetry vs the question gate — KTD-4):
#   on a confirmed destructive command for a confirmed live run, the hook PAUSES
#   the run (driver=manual + blocked_on) UNCONDITIONALLY — even if the deny
#   contract is unavailable. It never degrades to silent-allow on a destructive
#   match. The write happens in the sibling lib/*.py; this wrapper still always
#   exits 0 at the process level (the halt is on the ledger, not the exit code).
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level; heavy work
# exec'd into Python. Mirrors .claude/hooks/on-stop.sh.

set -uo pipefail

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
__cd_find_repo() {
  local dir="${PWD}"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "${dir}/.claude/auto" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

__cd_repo="$(__cd_find_repo)" || exit 0
[ -d "${__cd_repo}/.claude/auto" ] || exit 0

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Hand off ALL decision logic to Python. `|| true` keeps the PROCESS exit 0
# (rel-001); the fail-closed halt is recorded on the LEDGER inside the .py, not
# via a non-zero exit code.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-action.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

exit 0
