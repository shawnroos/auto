#!/usr/bin/env bash
# claude-dispatch U6b: the native Claude adapter.
#
# Implements the LOCKED adapter contract (docs/contracts/adapter-contract.md):
# the six ops `plan / deepen / review_plan / next_plan_step / do_unit / review`,
# mapping a bare native-Claude workflow (prose plan, native edit/Task, self-review
# against an injected rubric) onto the engine's fixed interface.
#
# An adapter is a PURE PROVIDER OF OPERATIONS. It NEVER writes the ledger
# (contract §1). Ops return data to stdout; the engine persists it. jq + the
# pinned python3 are the only external dependencies; all $-bearing logic lives
# here, never in a command `.md` (memory feedback_slash_command_arg_substitution).
#
# ════════════════════════════════════════════════════════════════════════════
# RUBRIC PROBE OUTCOME (gates this adapter — contract §3.1, plan U6b "FIRST")
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
# THEREFORE: `adapter_scale = "blocker-only"`.
#   The predicate evaluator (which reads adapter_scale from the ledger) applies
#   blocker-only logic for native runs: only `blocker` reliably gates the
#   work-loop. R2's "widest gap" rationale is therefore PARTIALLY met for native
#   — the blocker gate is trustworthy; the major gate is best-effort. Native
#   `review` still EMITS the full three-tier scale (it is the single shared
#   scale; there is no separate two-value vocabulary), but the engine treats
#   native majors as advisory rather than gating.
# ════════════════════════════════════════════════════════════════════════════
#
# ── THE LIVE-INVOCATION BOUNDARY (read before wiring this into the engine) ──
# `plan`, `review_plan`, `do_unit`, and `review` correspond to live native model
# actions (write a prose plan; review + list gaps; native edit/Task; self-review
# against the rubric). A CLI cannot perform a model action, so each of those ops
# is a two-part shape, honored at the seam, not faked:
#   1. PREPARE — emit the invocation envelope / rubric the model should act on.
#   2. PARSE   — validate the model's structured output onto the contract shape.
# The PARSE half (severity validation, gap-set passthrough) is pure and unit-
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

CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

CLAUDE_DISPATCH_NATIVE_ADAPTER_NAME="native"
# Set by the rubric probe above (partial -> blocker-only).
CLAUDE_DISPATCH_NATIVE_ADAPTER_SCALE="blocker-only"

# ──────────────────────────────────────────────────────────────────────────
# Pure helpers (unit-tested).

# native_adapter_scale -> the declared adapter_scale token.
native_adapter_scale() { printf '%s\n' "$CLAUDE_DISPATCH_NATIVE_ADAPTER_SCALE"; }

# native_review_rubric -> the blocker/major/minor rubric injected into the
#   native reviewer. This IS the native adapter's severity "mapping" — there is
#   no foreign vocabulary; the reviewer tags directly on the shared scale.
native_review_rubric() {
  cat <<'RUBRIC'
Tag each finding with exactly one severity:
  blocker — security holes, data loss/corruption, crashes, or incorrect
            results that ship to users. GATES the loop.
  major   — real defects that should be fixed but do not lose data or ship
            wrong results (e.g. bounded correctness bugs, missing tests on a
            critical path). Best-effort under blocker-only scale.
  minor   — style, naming, clarity, comments. Reported at exit; never gates.
Emit findings as a JSON array: [{"severity":"blocker|major|minor","note":"..."}].
RUBRIC
}

# native_validate_findings <findings-json> -> findings[] JSON (validated passthrough).
#   PARSE half of `review`. The native reviewer tags findings against the rubric
#   out of band (a model action). This validates the structured result is on the
#   shared scale and passes it through unchanged. Off-scale severities are a
#   contract violation -> fail loudly.
native_validate_findings() {
  local findings_json="$1"
  "$CLAUDE_DISPATCH_PYTHON3" - "$findings_json" <<'PYEOF'
import json, sys
SEVERITIES = ("blocker", "major", "minor")
findings = json.loads(sys.argv[1])
out = []
for f in findings:
    sev = str(f.get("severity", ""))
    if sev not in SEVERITIES:
        sys.stderr.write("adapter-native: off-scale severity %r (expected blocker|major|minor)\n" % sev)
        sys.exit(1)
    out.append({"severity": sev, "note": f.get("note", "")})
json.dump(out, sys.stdout)
PYEOF
}

# native_next_plan_step <ledger-json> -> "plan" | "review_plan" | "done"
#   The native plan-loop sequencer (contract §4). Native has NO deepen step, so
#   it NEVER emits "deepen": plan -> review_plan -> (loop review while gaps
#   remain) -> done.
#
#   Coherence rule (contract §4.1, REQUIRED): once a review_plan round writes
#   gaps_open == 0, return "done". The gaps_open==0 short-circuit is FIRST.
native_next_plan_step() {
  local ledger_json="$1"
  "$CLAUDE_DISPATCH_PYTHON3" - "$ledger_json" <<'PYEOF'
import json, sys
ledger = json.loads(sys.argv[1])
epr = ledger.get("exit_predicate_result", {}) or {}
plan_step = ledger.get("plan_step")
# Coherence guard FIRST (contract §4.1): gaps closed after a review => done.
if plan_step in ("review_plan", "done") and epr.get("gaps_open", 0) == 0:
    print("done"); sys.exit(0)
if plan_step is None:
    print("plan")
elif plan_step == "plan":
    print("review_plan")
elif plan_step == "review_plan":
    # gaps still open (else the guard fired) -> review again. Native never deepens.
    print("review_plan")
else:
    print("done")
PYEOF
}

# native_deepen <plan> -> plan (UNCHANGED).
#   Contract §6.2: native has no deepen concept; deepen is a no-op that returns
#   the plan verbatim. next_plan_step never emits "deepen", so this is only ever
#   reached if the engine calls it defensively; either way it must not mutate.
native_deepen() { printf '%s' "$1"; }

# ──────────────────────────────────────────────────────────────────────────
# Live-invocation PREPARE halves (emit an envelope; the model performs the action).

# native_prepare_plan <scope> -> prose-plan invocation envelope.
native_prepare_plan() {
  jq -nc --arg scope "$1" \
    '{adapter:"native", op:"plan", invocation:"write-prose-plan", scope:$scope}'
}

# native_prepare_review_plan <plan> -> review+list-gaps invocation envelope.
#   The model reviews the plan and returns a gap-set array; the engine reads
#   only its length (contract §2.2).
native_prepare_review_plan() {
  jq -nc --arg plan "$1" \
    '{adapter:"native", op:"review_plan", invocation:"review-and-list-gaps", plan:$plan}'
}

# native_prepare_do_unit <unit-id> -> dispatch_handle envelope (opaque to the engine).
#   Native dispatch is a native edit / Task. The orchestrator (U10) correlates
#   the in-flight agent via this handle; U10 defines the correlation contract.
native_prepare_do_unit() {
  jq -nc --arg unit "$1" \
    '{adapter:"native", op:"do_unit", unit_id:$unit, invocation:("native-task " + $unit)}'
}

# ──────────────────────────────────────────────────────────────────────────
# Direct invocation for testing / scripting (positional, quoted).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    adapter-scale)        native_adapter_scale ;;
    review-rubric)        native_review_rubric ;;
    validate-findings)    native_validate_findings "$@" ;;
    next-plan-step)       native_next_plan_step "$@" ;;
    deepen)               native_deepen "$@" ;;
    prepare-plan)         native_prepare_plan "$@" ;;
    prepare-review-plan)  native_prepare_review_plan "$@" ;;
    prepare-do-unit)      native_prepare_do_unit "$@" ;;
    *) printf 'adapter-native: unknown subcommand %q\n' "$sub" >&2; exit 2 ;;
  esac
fi
