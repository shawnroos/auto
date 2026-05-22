#!/usr/bin/env bash
# auto U6b unit test: the native + CE adapters' pure surface.
#
# WHAT IS TESTED (and what is NOT):
#   The adapters' live-Claude ops (plan / do_unit / native review / /ce-*
#   invocations) PREPARE an envelope the model runs and PARSE its structured
#   result. A unit test cannot invoke a slash command or a model, so we test the
#   PURE parts that carry the contract's correctness load:
#     - CE severity mapping (P0->blocker, P1/P2->major, P3->minor) — deterministic
#     - native finding validation (on-scale passthrough; off-scale rejected)
#     - next_plan_step state machines + the §4.1 coherence guard
#     - the declared adapter_scale (rubric-probe fixture)
#   The work-loop "exit predicate" is the engine's (ledger.py §I-2). We do NOT
#   import it (U6b must not touch ledger.py); we assert the adapter SUPPLIES the
#   right inputs by computing `blockers + majors == 0` inline over the mapped
#   findings, which is exactly the input the engine consumes.
#
# SCENARIOS (mapped to the U6b plan):
#   1. Rubric probe (GATING): the 5 representative findings + their tags are a
#      fixture; assert the chosen adapter_scale outcome (native = blocker-only).
#   2. CE happy path: {1 P0, 2 P2, 3 P3} -> {1 blocker, 2 major, 3 minor};
#      predicate false (blocker present).
#   3. Native happy path: reviewer output tagged on the rubric -> same scale,
#      identical engine path (count blockers+majors the same way).
#   4. Edge: zero findings -> predicate true for the work-loop.
#   5. Plan adapter: gap-set non-empty -> plan exit predicate false; empty -> true.
#   6. §4.1 coherence guard: gaps_open==0 after a review_plan -> next_plan_step
#      returns "done" (CE and native).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
. "${AUTO_ROOT}/tests/helpers/test-helpers.sh"

CE="${AUTO_ROOT}/lib/adapter-ce.sh"
NATIVE="${AUTO_ROOT}/lib/adapter-native.sh"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto_test::setup

# ── shared helpers ─────────────────────────────────────────────────────────

# count_severity <findings-json> <severity> -> integer count.
count_severity() {
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
findings = json.loads(sys.argv[1])
sev = sys.argv[2]
print(sum(1 for f in findings if f.get("severity") == sev))
PYEOF
}

# work_predicate_met <findings-json> -> "true" if blockers+majors == 0, else "false".
#   Mirrors the gating half of the engine's I-2 predicate (blockers==0 AND
#   majors==0). The engine ALSO requires all_units_terminal; we exercise only
#   the severity-supplied half here (that is the adapter's contribution).
work_predicate_met() {
  local b m
  b=$(count_severity "$1" blocker)
  m=$(count_severity "$1" major)
  if [ "$b" -eq 0 ] && [ "$m" -eq 0 ]; then printf 'true'; else printf 'false'; fi
}

# plan_predicate_met <gapset-json> -> "true" if gap-set is empty, else "false".
plan_predicate_met() {
  local n
  n=$(printf '%s' "$1" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)))')
  if [ "$n" -eq 0 ]; then printf 'true'; else printf 'false'; fi
}

# A ledger fixture with a given plan_step + gaps_open (the only fields
# next_plan_step reads). Keeps the test independent of ledger.py's full shape.
ledger_fixture() {
  local plan_step="$1" gaps_open="$2"
  if [ "$plan_step" = "null" ]; then
    printf '{"plan_step":null,"exit_predicate_result":{"gaps_open":%s}}' "$gaps_open"
  else
    printf '{"plan_step":"%s","exit_predicate_result":{"gaps_open":%s}}' "$plan_step" "$gaps_open"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# 1. RUBRIC PROBE (gating) — the 5 representative findings + tags as a fixture.
#    Assert the chosen adapter_scale outcome. Per the probe recorded at the top
#    of adapter-native.sh, the major/minor boundary HEDGED on 2 of 5 findings ->
#    outcome = partial -> adapter_scale = "blocker-only".
# ════════════════════════════════════════════════════════════════════════════

# The fixture: probe findings with the honest tags from adapter-native.sh.
RUBRIC_PROBE='[
  {"severity":"blocker","note":"SQL injection via unsanitized user input"},
  {"severity":"blocker","note":"missing await: response sent before DB commit"},
  {"severity":"major","note":"off-by-one in pagination drops last record"},
  {"severity":"minor","note":"redundant local variable could be inlined"},
  {"severity":"minor","note":"comment typo"}
]'

auto_test::it "rubric probe: all 5 findings are on the shared scale"
PROBE_VALID=$(bash "$NATIVE" validate-findings "$RUBRIC_PROBE")
auto_test::assert_eq "2" "$(count_severity "$PROBE_VALID" blocker)"

auto_test::it "rubric probe: blocker tier is reliable (2 unambiguous blockers)"
auto_test::assert_eq "1" "$(count_severity "$PROBE_VALID" major)"

auto_test::it "rubric probe: minor tier present (the fuzzy major/minor boundary)"
auto_test::assert_eq "2" "$(count_severity "$PROBE_VALID" minor)"

auto_test::it "rubric probe OUTCOME: native declares adapter_scale=blocker-only (partial)"
# DELIBERATE-FAIL NOTE (memory feedback_new_tests_need_deliberate_fail_smoke_check):
# flip CLAUDE_AUTO_NATIVE_ADAPTER_SCALE in adapter-native.sh to "three-tier"
# and this assertion goes RED — verified during authoring.
auto_test::assert_eq "blocker-only" "$(bash "$NATIVE" adapter-scale)"

auto_test::it "CE declares adapter_scale=three-tier (command-driven, P-levels map cleanly)"
auto_test::assert_eq "three-tier" "$(bash "$CE" adapter-scale)"

# ════════════════════════════════════════════════════════════════════════════
# 2. CE HAPPY PATH — {1 P0, 2 P2, 3 P3} -> {1 blocker, 2 major, 3 minor}.
# ════════════════════════════════════════════════════════════════════════════

CE_FINDINGS='[
  {"level":"P0","note":"crash on null tenant"},
  {"level":"P2","note":"N+1 query on dashboard"},
  {"level":"P2","note":"missing index"},
  {"level":"P3","note":"dead import"},
  {"level":"P3","note":"stale comment"},
  {"level":"P3","note":"long line"}
]'
CE_MAPPED=$(bash "$CE" map-findings "$CE_FINDINGS")

auto_test::it "CE: 1 P0 -> 1 blocker"
auto_test::assert_eq "1" "$(count_severity "$CE_MAPPED" blocker)"

auto_test::it "CE: 2 P2 -> 2 major"
auto_test::assert_eq "2" "$(count_severity "$CE_MAPPED" major)"

auto_test::it "CE: 3 P3 -> 3 minor"
auto_test::assert_eq "3" "$(count_severity "$CE_MAPPED" minor)"

auto_test::it "CE: P1 -> major (single-level table check)"
auto_test::assert_eq "major" "$(bash "$CE" map-level P1)"

auto_test::it "CE happy path: blocker present -> work predicate FALSE"
auto_test::assert_eq "false" "$(work_predicate_met "$CE_MAPPED")"

auto_test::it "CE: unknown level is rejected (off-scale guard)"
auto_test::assert_false "bash '$CE' map-findings '[{\"level\":\"P9\",\"note\":\"x\"}]'"

# ════════════════════════════════════════════════════════════════════════════
# 3. NATIVE HAPPY PATH — reviewer output tagged on the rubric -> same scale,
#    identical engine path (count blockers+majors exactly as for CE).
# ════════════════════════════════════════════════════════════════════════════

NATIVE_FINDINGS='[
  {"severity":"blocker","note":"auth bypass"},
  {"severity":"major","note":"unbounded retry loop"},
  {"severity":"minor","note":"typo in log line"}
]'
NATIVE_MAPPED=$(bash "$NATIVE" validate-findings "$NATIVE_FINDINGS")

auto_test::it "native: validated findings preserve the blocker tag"
auto_test::assert_eq "1" "$(count_severity "$NATIVE_MAPPED" blocker)"

auto_test::it "native happy path: blocker present -> work predicate FALSE (same engine path as CE)"
auto_test::assert_eq "false" "$(work_predicate_met "$NATIVE_MAPPED")"

auto_test::it "native: off-scale severity (P0 vocabulary) is rejected"
auto_test::assert_false "bash '$NATIVE' validate-findings '[{\"severity\":\"P0\",\"note\":\"x\"}]'"

# ════════════════════════════════════════════════════════════════════════════
# 4. EDGE — zero findings -> work predicate TRUE.
# ════════════════════════════════════════════════════════════════════════════

auto_test::it "edge: zero CE findings -> work predicate TRUE"
EMPTY_CE=$(bash "$CE" map-findings '[]')
auto_test::assert_eq "true" "$(work_predicate_met "$EMPTY_CE")"

auto_test::it "edge: zero native findings -> work predicate TRUE"
EMPTY_NATIVE=$(bash "$NATIVE" validate-findings '[]')
auto_test::assert_eq "true" "$(work_predicate_met "$EMPTY_NATIVE")"

auto_test::it "edge: only minors -> work predicate TRUE (minors never gate)"
ONLY_MINOR=$(bash "$CE" map-findings '[{"level":"P3","note":"a"},{"level":"P3","note":"b"}]')
auto_test::assert_eq "true" "$(work_predicate_met "$ONLY_MINOR")"

# ════════════════════════════════════════════════════════════════════════════
# 5. PLAN ADAPTER — gap-set non-empty -> plan predicate FALSE; empty -> TRUE.
# ════════════════════════════════════════════════════════════════════════════

auto_test::it "plan: non-empty gap-set -> plan predicate FALSE"
auto_test::assert_eq "false" "$(plan_predicate_met '[{"gap":"missing rollback"}]')"

auto_test::it "plan: empty gap-set -> plan predicate TRUE"
auto_test::assert_eq "true" "$(plan_predicate_met '[]')"

# ── next_plan_step state machines (CE: plan->deepen->review_plan->done) ──

auto_test::it "CE next_plan_step: fresh ledger -> plan"
auto_test::assert_eq "plan" "$(bash "$CE" next-plan-step "$(ledger_fixture null 0)")"

auto_test::it "CE next_plan_step: after plan -> deepen"
auto_test::assert_eq "deepen" "$(bash "$CE" next-plan-step "$(ledger_fixture plan 0)")"

auto_test::it "CE next_plan_step: after deepen -> review_plan"
auto_test::assert_eq "review_plan" "$(bash "$CE" next-plan-step "$(ledger_fixture deepen 0)")"

auto_test::it "CE next_plan_step: review_plan with gaps open -> deepen (loop)"
auto_test::assert_eq "deepen" "$(bash "$CE" next-plan-step "$(ledger_fixture review_plan 3)")"

# ── native next_plan_step (plan->review_plan->done, NEVER deepen) ──

auto_test::it "native next_plan_step: fresh ledger -> plan"
auto_test::assert_eq "plan" "$(bash "$NATIVE" next-plan-step "$(ledger_fixture null 0)")"

auto_test::it "native next_plan_step: after plan -> review_plan (no deepen)"
auto_test::assert_eq "review_plan" "$(bash "$NATIVE" next-plan-step "$(ledger_fixture plan 0)")"

auto_test::it "native next_plan_step: review_plan with gaps open -> review_plan (loop, never deepen)"
auto_test::assert_eq "review_plan" "$(bash "$NATIVE" next-plan-step "$(ledger_fixture review_plan 2)")"

auto_test::it "native deepen is a no-op (returns plan unchanged)"
auto_test::assert_eq "PLAN-X" "$(bash "$NATIVE" deepen "PLAN-X")"

# ════════════════════════════════════════════════════════════════════════════
# 6. §4.1 COHERENCE GUARD — gaps_open==0 after a review_plan -> "done".
# ════════════════════════════════════════════════════════════════════════════

auto_test::it "coherence: CE gaps_open==0 after review_plan -> done (no livelock)"
auto_test::assert_eq "done" "$(bash "$CE" next-plan-step "$(ledger_fixture review_plan 0)")"

auto_test::it "coherence: native gaps_open==0 after review_plan -> done (no livelock)"
auto_test::assert_eq "done" "$(bash "$NATIVE" next-plan-step "$(ledger_fixture review_plan 0)")"

# ════════════════════════════════════════════════════════════════════════════
# 7. PYTHON ADAPTER SURFACE — the modules tick.py (U4) actually imports.
#    resolve_adapter (tick.py:170-197) loads lib/adapter-{name}.py, instantiates
#    module.Adapter(), and calls ops as `getattr(adapter, step)(ledger)`. We
#    drive the .py modules the SAME way to prove the import shape matches and the
#    pure logic mirrors the bash sibling.
# ════════════════════════════════════════════════════════════════════════════

# py_adapter <ce|native> <expr> — load the .py adapter, instantiate Adapter(),
# eval an expression against `a` (the instance) + `json`, print the result.
py_adapter() {
  local fname="$1" expr="$2"
  "$PY" - "${AUTO_ROOT}/lib/adapter-${fname}.py" "$expr" <<'PYEOF'
import json, sys, importlib.util
path, expr = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("adapter_under_test", path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = m.Adapter()
val = eval(expr)
sys.stdout.write(val if isinstance(val, str) else json.dumps(val))
PYEOF
}

auto_test::it "py CE: exposes an Adapter factory with adapter_scale=three-tier"
auto_test::assert_eq "three-tier" "$(py_adapter ce 'a.adapter_scale')"

auto_test::it "py native: exposes an Adapter factory with adapter_scale=blocker-only"
auto_test::assert_eq "blocker-only" "$(py_adapter native 'a.adapter_scale')"

auto_test::it "py CE map_findings: {1 P0, 2 P2, 3 P3} -> 1 blocker (matches bash sibling)"
PY_CE_MAPPED=$(py_adapter ce 'a.review({"ce_findings":[{"level":"P0","note":"x"},{"level":"P2","note":"y"},{"level":"P2","note":"z"},{"level":"P3","note":"a"},{"level":"P3","note":"b"},{"level":"P3","note":"c"}]})')
auto_test::assert_eq "1" "$(count_severity "$PY_CE_MAPPED" blocker)"

auto_test::it "py CE map_findings: -> 2 major, 3 minor"
auto_test::assert_eq "2" "$(count_severity "$PY_CE_MAPPED" major)"

auto_test::it "py native validate: off-scale severity raises"
auto_test::assert_false "py_adapter native 'a.review({\"findings\":[{\"severity\":\"P0\",\"note\":\"x\"}]})'"

# next_plan_step called exactly as tick.py:337 does — getattr(adapter, op) shape.
auto_test::it "py CE next_plan_step: fresh ledger -> plan (tick.py import shape)"
auto_test::assert_eq "plan" "$(py_adapter ce 'a.next_plan_step({"plan_step":None,"exit_predicate_result":{"gaps_open":0}})')"

auto_test::it "py CE next_plan_step: plan->deepen, then deepen->review_plan"
auto_test::assert_eq "review_plan" "$(py_adapter ce 'a.next_plan_step({"plan_step":"deepen","exit_predicate_result":{"gaps_open":0}})')"

auto_test::it "py CE coherence: gaps_open==0 after review_plan -> done"
auto_test::assert_eq "done" "$(py_adapter ce 'a.next_plan_step({"plan_step":"review_plan","exit_predicate_result":{"gaps_open":0}})')"

auto_test::it "py native next_plan_step: plan -> review_plan (no deepen)"
auto_test::assert_eq "review_plan" "$(py_adapter native 'a.next_plan_step({"plan_step":"plan","exit_predicate_result":{"gaps_open":0}})')"

auto_test::it "py native coherence: gaps_open==0 after review_plan -> done"
auto_test::assert_eq "done" "$(py_adapter native 'a.next_plan_step({"plan_step":"review_plan","exit_predicate_result":{"gaps_open":0}})')"

auto_test::it "py native deepen is a no-op (returns plan unchanged)"
auto_test::assert_eq "PLAN-Y" "$(py_adapter native 'a.deepen("PLAN-Y")')"

# ── done ────────────────────────────────────────────────────────────────────
auto_test::teardown
auto_test::summary
