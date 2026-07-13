#!/usr/bin/env bash
# auto U7 SessionStart hook: resurrection / handoff surfacing.
#
# A self-paced ScheduleWakeup pulse chain does NOT survive a full session exit
# (in-session only; durable cron is denied by cmux). No work is lost — the
# ledger is durable on disk and each background agent self-writes its verdict
# atomically — but the lost re-arm leaves a run "orphaned" (no live driver).
# This hook SURFACES resumable runs at the start of a fresh session so the
# operator can `/auto-resume` them. It SURFACES ONLY — it never auto-runs
# (auto-resume is U8, spike-gated).
#
# For each <repo>/.claude/auto/*.json:
#   * loop_phase == "done"                          -> skip.
#   * loop_phase == "handoff" AND handoff_paused == true  -> handoff-specific hint
#     (plan complete; awaiting work confirmation). Checked BEFORE the time-based
#     orphan branch (schema §5 I-3 — handoff is the INTENTIONAL orphan).
#   * else if loop.driver == "manual" OR loop.last_beat_at older than GRACE
#     (4200s; the pulse chain died with a prior session) -> resume hint.
#
# rel-001: presence-gate first; ALWAYS exit 0 (never block session start).
# Heavy work exec'd into Python. Mirrors claude-modes/scripts/on-session-start.sh.

set -uo pipefail

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
# auto is REPO-scoped. git is NOT an engine dependency, so we walk up
# the tree rather than shelling to git rev-parse (which would hard-fail on a
# non-git checkout). Fast no-op exit 0 the moment the walk fails.
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

# Hand off the per-ledger scan + GRACE/orphan/handoff classification to Python
# (which imports ledger.py's is_orphaned + GRACE_SECONDS — never hardcoded).
# It prints surfacing lines on stdout; the harness shows them to the operator.
# `|| true` belt-and-braces so an exec/python failure cannot propagate non-zero.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-session-start.py" "$__cd_repo" || true

# If exec returned (it shouldn't), defensive exit-0.
exit 0
