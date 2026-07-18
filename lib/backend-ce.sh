#!/usr/bin/env bash
# auto U6b: the Compound Engineering (CE) backend.
#
# Implements the LOCKED backend contract (docs/contracts/backend-contract.md):
# the six ops `plan / deepen / review_plan / next_plan_step / do_step / review`,
# mapping the CE `/ce-*` workflow onto the engine's fixed interface.
#
# A backend is a PURE PROVIDER OF OPERATIONS. It NEVER writes the run-record
# (contract §1). The four ops below return data to stdout (JSON or a literal
# token); the engine persists it through run_record.py's recording paths. We pin
# the interpreter (jq is the only external dependency) and keep all $-bearing
# logic here, never in a command `.md` (memory feedback_slash_command_arg_substitution).
#
# ── THE LIVE-INVOCATION BOUNDARY (read before wiring this into the engine) ──
# `plan`, `deepen`, `review_plan`, `do_step`, and `review` each correspond to a
# live Claude command (/ce-plan, /ce-doc-review, /ce-work, /ce-code-review). A
# CLI cannot *run* a slash command — that is a model action. So each of those
# ops here is a two-part shape, and the contract is honored at the handoff, not faked:
#   1. PREPARE  — emit the invocation envelope the engine/model should run
#                 (`ce_prepare_*`). The model issues the actual /ce-* command.
#   2. PARSE    — translate the command's structured output back onto the
#                 contract's return shape (`ce_map_findings`, gap-set passthrough).
# The PARSE half is pure and fully unit-tested (severity mapping is deterministic
# for CE). The PREPARE half emits a documented envelope; what is NOT faked is a
# live command result — that genuinely requires the model. `next_plan_step` is
# fully pure (a state machine over the run-record) and needs no live invocation.
#
# ── DECLARED SEVERITY MAPPING (contract §3.1, fixed property of this backend) ──
#   CE verdict level   ->  shared scale
#   ----------------       ------------
#   P0                 ->  blocker
#   P1                 ->  major
#   P2                 ->  major
#   P3                 ->  minor
#
# ── DECLARED backend_scale ──  "three-tier"
#   CE's `/ce-code-review` emits stable P0/P1/P2/P3 levels that map cleanly onto
#   all three shared severities, so CE skips the rubric probe and declares
#   three-tier directly (contract §3.1, SKILL.md "command-driven reviewer").

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────────
# DELEGATION (no inline logic). The severity table + next_plan_step state
# machine + the PREPARE envelopes live ONCE, in backend-ce.py — the module
# pulse.py imports. This shim used to re-implement them in an inline Python
# heredoc; that meant the contract-load-bearing logic existed in two places and
# could drift. The shim now pins the interpreter and execs backend-ce.py's CLI,
# which dispatches the same subcommands onto the SAME pure functions. All
# $-bearing logic stays here, never in a command `.md` (memory
# feedback_slash_command_arg_substitution).
#
# Subcommands (forwarded verbatim to backend-ce.py):
#   backend-scale | map-level <lvl> | map-findings <json> | next-plan-step <json>

auto::backend_ce() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/backend-ce.py" "$@"
}

# Direct invocation for testing / scripting (positional, quoted).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::backend_ce "$@"
fi
