#!/usr/bin/env bash
# auto U7: deterministic loop-status surface for the engine's OWN
# Stop hook (.claude/hooks/on-stop.sh).
#
# WHY THIS EXISTS (U9 spike — docs/research/native-goal-mechanism-spike.md):
#   Native `/goal` is a CLOSED, model-judged continuation loop. It consults the
#   model's judgement, NOT any file or queryable predicate — there is no seam to
#   feed it the ledger result. So auto ships its OWN thin Stop hook
#   (on-stop.sh) whose verdict is DETERMINISTIC and engine-owned. This script
#   writes the status that Stop hook reads. The consumer is on-stop.sh, NOT
#   native `/goal`.
#
# FRESHNESS GUARANTEE (C2 / I-1 — read this, it is load-bearing):
#   No cached copy exists; we read the I-1-fresh field directly off the ledger.
#   `exit_predicate_result` is recomputed inside ledger.py's single atomic-write
#   chokepoint on EVERY write (schema §5 I-1), so reading it back is always a
#   consistent, current snapshot. We do NOT maintain a second copy of `done`
#   that could drift from the ledger predicate — there is therefore NO staleness
#   window where this status says done while the ledger says not (e.g. when a
#   re-review flips verdict-returned → pending and reopens the predicate). Every
#   invocation re-reads the ledger; `done` IS `exit_predicate_result.met` from
#   the same atomic snapshot, never a derived/remembered value.
#
# OUTPUT (one JSON object on stdout, mirroring native /goal's familiar shape):
#   { "active": <bool>, "done": <bool>, "reason": <str>, "iterations": <int> }
#     active      — the run exists and loop_phase != "done" (a live loop the
#                   Stop hook should gate on). false => the Stop hook allows stop.
#     done        — exit_predicate_result.met (the I-1-fresh predicate). When
#                   active && !done the Stop hook BLOCKS the stop.
#     reason      — human-readable defect summary (N blockers / M majors / K
#                   not-yet-terminal), surfaced to the agent on a block.
#     iterations  — best-effort advance count (placeholder 0; the ledger has no
#                   iteration counter — it is informational only, never gates).
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_AUTO_PYTHON3) — never bare `python3` (rationale parity:
# claude-modes/lib/mode-yaml.sh:24-32, matches lib/ledger.sh / lib/pulse.sh).
#
# $ARGUMENTS-safe: all parsing is positional; never string-interpolated into a
# shell (memory `feedback_slash_command_arg_substitution`).

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# auto::goal_status <repo> <run>
#   Prints the deterministic status JSON for ONE run. Reads the ledger
#   lock-free (atomic-rename invariant => consistent snapshot; well under any
#   hook timeout). On a missing/malformed ledger, emits active:false (allow
#   stop) and exits 0 — never breaks the harness (rel-001).
auto::goal_status() {
  local repo="${1:-}"
  local run="${2:-}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/goal-status.py" "$repo" "$run"
}

# Allow direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::goal_status "$@"
fi
