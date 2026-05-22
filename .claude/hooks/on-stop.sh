#!/usr/bin/env bash
# auto U7 Stop hook: the engine's OWN deliberate-stop guard.
#
# WHY THIS EXISTS (U9 spike — docs/research/native-goal-mechanism-spike.md):
#   Native `/goal` is a CLOSED, model-judged continuation loop with NO external
#   predicate seam — the engine CANNOT feed it the ledger result. So
#   auto ships its OWN thin Stop hook. This is NOT optional. Its
#   verdict is DETERMINISTIC and engine-owned (read from the ledger's I-1-fresh
#   `exit_predicate_result`), consistent with Shawn's
#   `feedback_deterministic_over_probabilistic_v1` preference.
#
# BLOCK MECHANISM (per U9 §4.2 + ralph-loop/hooks/stop-hook.sh:179-188):
#   To BLOCK a stop, emit `{"decision":"block","reason":"..."}` on stdout and
#   exit 0. This is the binary's `p.preventContinuation` gate, INDEPENDENT of
#   the native goal loop (U9 §2 — the two gates coexist). The U9 doc names exit-2
#   as an alternative, but the codebase convention (ralph-loop) is decision-JSON
#   + exit-0; we match that. "Always exit 0" (rel-001) is about the EXIT CODE,
#   not the decision — blocking-via-decision and exit-0 are not in conflict.
#
# LOOP-SAFETY (the infinite-block trap):
#   Claude Code RE-FIRES Stop after a block; the re-fire carries
#   `stop_hook_active: true`. If we unconditionally blocked we'd build a loop the
#   user cannot escape. So: if `stop_hook_active == true` we ALLOW the stop
#   (exit 0, no decision) regardless of predicate — surfacing a one-line warning
#   via systemMessage. The deterministic gate fires ONCE per stop attempt.
#
# ACTIVE-RUN POLICY:
#   There may be N ledgers under <repo>/.claude/auto/. We BLOCK if ANY has
#   `loop_phase != "done" AND exit_predicate_result.met == false`. The reason
#   names the offending run(s). This matches goal-status.sh's per-run verdict.
#   The all_units_terminal gate is honored implicitly: `met` already requires
#   `all_units_terminal == true` (schema §5 I-2), so a lurking stalled unit
#   (counters zero) keeps `met == false` and the stop stays blocked.
#
# READS THE LEDGER LOCK-FREE: the atomic-rename invariant gives a consistent
# snapshot; no flock => no contention with a slow writer => trivially under any
# hook timeout (the 10s cmux budget).
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level. Heavy work
# exec'd into Python. Mirrors claude-modes/scripts/on-session-start.sh.

set -uo pipefail

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
# auto is REPO-scoped (not user-global like claude-modes). The hook
# fires with a cwd we don't fully control; git is NOT an engine dependency, so
# we walk up the directory tree looking for .claude/auto/ rather than
# shelling to git rev-parse (which would hard-fail on a non-git checkout —
# a rel-001 violation). The moment the walk fails, fast no-op exit 0.
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

# Capture the Stop event JSON from stdin ONCE (the `stop_hook_active` field
# lives here). `[ ! -t 0 ]` mirrors claude-modes' isatty guard so an interactive
# invocation does not hang on cat.
__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Hand off ALL decision logic to Python (consistent snapshot read + loop-safety
# + decision JSON). `|| true` belt-and-braces so even an exec/python failure
# cannot propagate non-zero to the harness.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-stop.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

# If exec returned (it shouldn't), defensive exit-0.
exit 0
