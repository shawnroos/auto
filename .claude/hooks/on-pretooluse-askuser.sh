#!/usr/bin/env bash
# auto U4 PreToolUse hook (AskUserQuestion gate): the advisor-routing seam.
#
# WHY THIS EXISTS (KTD-4/5):
#   During a LIVE self-driven /auto run, the wrapped ce skills' own
#   AskUserQuestion calls should not stop to ask the operator — auto is
#   hands-off for MECHANICAL work. This hook DENIES the AskUserQuestion and
#   redirects the driving agent to consult the `advisor` (prose advice) and
#   itself classify: mechanical clarification -> resolve and proceed; a
#   substantive design/architecture fork -> escalate via the pause seam.
#
# FIRES ONLY when the PreToolUse stdin `session_id` equals the ledger's
# `driving_session_id` AND a live self-driven run exists (KTD-5). A concurrent
# standalone /ce-plan in the same worktree has a DIFFERENT session_id and is
# never intercepted. The decision logic lives in the sibling lib/*.py.
#
# FAILS OPEN (the question gate's asymmetry vs the action backstop — KTD-4): if
# the deny contract is unavailable, the worst case is the operator is asked
# directly. So this hook emits nothing (allow) on any uncertainty.
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

# CLAUDE_PLUGIN_ROOT is set by the harness at hook-invocation time. Defensive
# fallback: derive from this script's location (.claude/hooks/ -> plugin root).
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Capture the PreToolUse event JSON from stdin ONCE (session_id + tool_input
# live here). `[ ! -t 0 ]` mirrors on-stop.sh's isatty guard so an interactive
# invocation does not hang on cat.
__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Hand off ALL decision logic to Python. `|| true` belt-and-braces so even an
# exec/python failure cannot propagate non-zero to the harness (fail-open).
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-askuser.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

# If exec returned (it shouldn't), defensive exit-0.
exit 0
