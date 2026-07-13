#!/usr/bin/env bash
# auto U6b: the native Claude backend.
#
# Implements the LOCKED backend contract (docs/contracts/backend-contract.md):
# the six ops `plan / deepen / review_plan / next_plan_step / do_step / review`,
# mapping a bare native-Claude workflow (prose plan, native edit/Task, self-review
# against an injected rubric) onto the engine's fixed interface.
#
# A backend is a PURE PROVIDER OF OPERATIONS. It NEVER writes the ledger
# (contract §1). Ops return data to stdout; the engine persists it. jq + the
# pinned python3 are the only external dependencies; all $-bearing logic lives
# here, never in a command `.md` (memory feedback_slash_command_arg_substitution).
#
# ════════════════════════════════════════════════════════════════════════════
# RUBRIC PROBE OUTCOME (gates this backend — contract §3.1, plan U6b "FIRST")
# ════════════════════════════════════════════════════════════════════════════
# A native reviewer is a Claude model judging findings against the
# blocker/major/minor rubric. The probe gives it ~5 representative findings and
# inspects whether it tags consistently across all three tiers. The five used,
# with the honest tags and where the boundary felt arbitrary:
#
#   1. SQL injection via unsanitized user input in a query   -> blocker  (clear)
#   2. Missing `await`: response sent before the DB write
#      commits (a data-loss race)                            -> blocker  (clear)
#   3. Off-by-one in pagination: last page drops one record  -> major*   (HEDGED:
#        a real correctness bug but bounded/non-destructive — felt arbitrary
#        between blocker and major)
#   4. Redundant local variable that could be inlined        -> minor*   (HEDGED:
#        could equally be "not worth flagging"; the major/minor line for
#        code-smell items is fuzzy)
#   5. Comment typo                                          -> minor    (clear)
#
# OUTCOME: **partial**. The `blocker` tier is reliable — security / correctness /
# data-loss findings (1, 2) tag unambiguously. The major/minor boundary is fuzzy:
# the probe HEDGED on findings 3 and 4 (where does a bounded correctness bug or a
# code smell land?). Per the contract's partial rule, a hedge on even one of the
# major/minor findings drops us off "three-tier".
#
# THEREFORE: `backend_scale = "blocker-only"`.
#   The predicate evaluator (which reads backend_scale from the ledger) applies
#   blocker-only logic for native runs: only `blocker` reliably gates the
#   work-loop. R2's "widest gap" rationale is therefore PARTIALLY met for native
#   — the blocker gate is trustworthy; the major gate is best-effort. Native
#   `review` still EMITS the full three-tier scale (it is the single shared
#   scale; there is no separate two-value vocabulary), but the engine treats
#   native majors as advisory rather than gating.
# ════════════════════════════════════════════════════════════════════════════
#
# ── THE LIVE-INVOCATION BOUNDARY (read before wiring this into the engine) ──
# `plan`, `review_plan`, `do_step`, and `review` correspond to live native model
# actions (write a prose plan; review + list gaps; native edit/Task; self-review
# against the rubric). A CLI cannot perform a model action, so each of those ops
# is a two-part shape, honored at the handoff, not faked:
#   1. PREPARE — emit the invocation envelope / rubric the model should act on.
#   2. PARSE   — validate the model's structured output onto the contract shape.
# The PARSE half (severity validation, gap-set passthrough) is pure and step-
# tested. `deepen` is a genuine no-op (native has no deepen step — see
# next_plan_step), and `next_plan_step` is a fully pure state machine.
#
# ── DECLARED SEVERITY MAPPING (contract §3.1) ──
#   Native reviewers self-tag directly on the shared scale (no foreign
#   vocabulary to translate), so the "mapping" is the rubric the reviewer is
#   given. `native_review_rubric` emits that rubric; `native_validate_findings`
#   asserts every emitted finding is one of blocker|major|minor and rejects
#   anything off-scale.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────────
# DELEGATION (no inline logic). The rubric + validate_findings + next_plan_step
# state machine + the PREPARE envelopes live ONCE, in backend-native.py — the
# module pulse.py imports. This shim used to re-implement them in an inline Python
# heredoc; that meant the contract-load-bearing logic existed in two places and
# could drift. The shim now pins the interpreter and execs backend-native.py's
# CLI, which dispatches the same subcommands onto the SAME pure functions. All
# $-bearing logic stays here, never in a command `.md` (memory
# feedback_slash_command_arg_substitution).
#
# Subcommands (forwarded verbatim to backend-native.py):
#   backend-scale | review-rubric | validate-findings <json> | next-plan-step <json>
#   deepen <plan>

auto::backend_native() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/backend-native.py" "$@"
}

# Direct invocation for testing / scripting (positional, quoted).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::backend_native "$@"
fi
