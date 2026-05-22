#!/usr/bin/env bash
# claude-dispatch U6b: the Compound Engineering (CE) adapter.
#
# Implements the LOCKED adapter contract (docs/contracts/adapter-contract.md):
# the six ops `plan / deepen / review_plan / next_plan_step / do_unit / review`,
# mapping the CE `/ce-*` workflow onto the engine's fixed interface.
#
# An adapter is a PURE PROVIDER OF OPERATIONS. It NEVER writes the ledger
# (contract §1). The four ops below return data to stdout (JSON or a literal
# token); the engine persists it through ledger.py's recording paths. We pin
# the interpreter (jq is the only external dependency) and keep all $-bearing
# logic here, never in a command `.md` (memory feedback_slash_command_arg_substitution).
#
# ── THE LIVE-INVOCATION BOUNDARY (read before wiring this into the engine) ──
# `plan`, `deepen`, `review_plan`, `do_unit`, and `review` each correspond to a
# live Claude command (/ce-plan, /ce-doc-review, /ce-work, /ce-code-review). A
# CLI cannot *run* a slash command — that is a model action. So each of those
# ops here is a two-part shape, and the contract is honored at the seam, not faked:
#   1. PREPARE  — emit the invocation envelope the engine/model should run
#                 (`ce_prepare_*`). The model issues the actual /ce-* command.
#   2. PARSE    — translate the command's structured output back onto the
#                 contract's return shape (`ce_map_findings`, gap-set passthrough).
# The PARSE half is pure and fully unit-tested (severity mapping is deterministic
# for CE). The PREPARE half emits a documented envelope; what is NOT faked is a
# live command result — that genuinely requires the model. `next_plan_step` is
# fully pure (a state machine over the ledger) and needs no live invocation.
#
# ── DECLARED SEVERITY MAPPING (contract §3.1, fixed property of this adapter) ──
#   CE verdict level   ->  shared scale
#   ----------------       ------------
#   P0                 ->  blocker
#   P1                 ->  major
#   P2                 ->  major
#   P3                 ->  minor
#
# ── DECLARED adapter_scale ──  "three-tier"
#   CE's `/ce-code-review` emits stable P0/P1/P2/P3 levels that map cleanly onto
#   all three shared severities, so CE skips the rubric probe and declares
#   three-tier directly (contract §3.1, SKILL.md "command-driven reviewer").

set -uo pipefail

CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

# The fixed properties of this adapter (contract §3.1).
CLAUDE_DISPATCH_CE_ADAPTER_NAME="ce"
CLAUDE_DISPATCH_CE_ADAPTER_SCALE="three-tier"

# ──────────────────────────────────────────────────────────────────────────
# Pure helpers (unit-tested).

# ce_adapter_scale -> the declared adapter_scale token.
ce_adapter_scale() { printf '%s\n' "$CLAUDE_DISPATCH_CE_ADAPTER_SCALE"; }

# ce_map_level <ce-level> -> shared severity (blocker|major|minor).
#   The static CE -> shared-scale table. Unknown levels are a contract
#   violation (the engine only ever sees the three shared values), so we
#   fail loudly rather than silently emit an out-of-scale value.
ce_map_level() {
  case "$1" in
    P0|p0) printf 'blocker\n' ;;
    P1|p1|P2|p2) printf 'major\n' ;;
    P3|p3) printf 'minor\n' ;;
    *)
      printf 'adapter-ce: unknown CE level %q (expected P0|P1|P2|P3)\n' "$1" >&2
      return 1
      ;;
  esac
}

# ce_map_findings <ce-findings-json> -> shared findings[] JSON.
#   PARSE half of `review`. Input: an array of CE findings, each
#   `{"level":"P0|P1|P2|P3","note":"..."}` (the structured shape /ce-code-review
#   yields). Output: the contract's `findings[]` shape — an array of
#   `{"severity":"blocker|major|minor","note":"..."}`. Deterministic; no model.
ce_map_findings() {
  local findings_json="$1"
  "$CLAUDE_DISPATCH_PYTHON3" - "$findings_json" <<'PYEOF'
import json, sys
TABLE = {"P0": "blocker", "P1": "major", "P2": "major", "P3": "minor"}
findings = json.loads(sys.argv[1])
out = []
for f in findings:
    level = str(f.get("level", "")).upper()
    if level not in TABLE:
        sys.stderr.write("adapter-ce: unknown CE level %r\n" % level)
        sys.exit(1)
    out.append({"severity": TABLE[level], "note": f.get("note", "")})
json.dump(out, sys.stdout)
PYEOF
}

# ce_next_plan_step <ledger-json> -> "plan" | "deepen" | "review_plan" | "done"
#   The CE plan-loop sequencer (contract §4). Pure: reads only the ledger.
#   CE order: plan -> deepen -> review_plan -> (loop deepen/review while gaps
#   remain) -> done.
#
#   Coherence rule (contract §4.1, REQUIRED): once a review_plan round has
#   written gaps_open == 0, this MUST return "done" — otherwise the plan-loop
#   livelocks. The gaps_open==0 short-circuit is FIRST, so it dominates the
#   state machine regardless of internal step.
ce_next_plan_step() {
  local ledger_json="$1"
  "$CLAUDE_DISPATCH_PYTHON3" - "$ledger_json" <<'PYEOF'
import json, sys
ledger = json.loads(sys.argv[1])
epr = ledger.get("exit_predicate_result", {}) or {}
# Coherence guard FIRST (contract §4.1): once a review_plan round has closed
# the gaps (gaps_open == 0), the NEXT call MUST return "done" — else livelock.
# This is keyed on plan_step == "review_plan" specifically: gaps_open is also 0
# by default BEFORE any review has run (e.g. at the "deepen" step), and the
# guard must not short-circuit then — only AFTER a real review_plan pass.
plan_step = ledger.get("plan_step")
if plan_step in ("review_plan", "done") and epr.get("gaps_open", 0) == 0:
    print("done"); sys.exit(0)
# Otherwise advance the CE state machine: plan -> deepen -> review_plan -> loop.
if plan_step is None:
    print("plan")
elif plan_step == "plan":
    print("deepen")
elif plan_step == "deepen":
    print("review_plan")
elif plan_step == "review_plan":
    # gaps still open here (else the guard above fired) -> another deepen round.
    print("deepen")
else:
    print("done")
PYEOF
}

# ──────────────────────────────────────────────────────────────────────────
# Live-invocation PREPARE halves (emit an envelope; the model runs the command).
# These are documented seams, not faked results — see the boundary note above.

# ce_prepare_plan <scope> -> invocation envelope (opaque `plan` round-trips it).
ce_prepare_plan() {
  jq -nc --arg scope "$1" \
    '{adapter:"ce", op:"plan", invocation:"/ce-plan", scope:$scope}'
}

# ce_prepare_deepen <plan> -> deepen-pass invocation envelope.
ce_prepare_deepen() {
  jq -nc --arg plan "$1" \
    '{adapter:"ce", op:"deepen", invocation:"deepen-pass", plan:$plan}'
}

# ce_prepare_review_plan <plan> -> /ce-doc-review invocation envelope.
#   The model runs /ce-doc-review and returns a gap-set array; the engine reads
#   only its length (contract §2.2). We pass that array through unchanged.
ce_prepare_review_plan() {
  jq -nc --arg plan "$1" \
    '{adapter:"ce", op:"review_plan", invocation:"/ce-doc-review", plan:$plan}'
}

# ce_prepare_do_unit <unit-id> -> dispatch_handle envelope (opaque to the engine).
#   The orchestrator (U10) uses this to correlate the in-flight /ce-work agent.
#   Shape is adapter-chosen; U10 will define the correlation contract over it.
ce_prepare_do_unit() {
  jq -nc --arg unit "$1" \
    '{adapter:"ce", op:"do_unit", unit_id:$unit, invocation:("/ce-work " + $unit)}'
}

# ──────────────────────────────────────────────────────────────────────────
# Direct invocation for testing / scripting (positional, quoted).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    adapter-scale)   ce_adapter_scale ;;
    map-level)       ce_map_level "$@" ;;
    map-findings)    ce_map_findings "$@" ;;
    next-plan-step)  ce_next_plan_step "$@" ;;
    prepare-plan)         ce_prepare_plan "$@" ;;
    prepare-deepen)       ce_prepare_deepen "$@" ;;
    prepare-review-plan)  ce_prepare_review_plan "$@" ;;
    prepare-do-unit)      ce_prepare_do_unit "$@" ;;
    *) printf 'adapter-ce: unknown subcommand %q\n' "$sub" >&2; exit 2 ;;
  esac
fi
