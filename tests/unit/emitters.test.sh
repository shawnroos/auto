#!/usr/bin/env bash
# auto U5b unit test: lib/emitters.py (3 emitters + registry) and the
# ledger.transition_and_emit primitive (atomic emit).
#
# v0.3.0 / U3 additions: iterate_template emitter scenarios + judge_winner
# gate-unit generalization + backward-compat fallback + counter-integration
# through emit_within_phase.
#
# SELF-CONTAINED inline harness.
#
# Scenarios:
#   1. registry ↔ validator consistency: emitters.REGISTRY keys == recipes.V1_EMITTER_NAMES
#   2. plan_output_to_work_units: 1 plan unit's enumerated_units → N work units
#   3. plan_output_to_work_units: empty enumerated_units → [] (vacuous, no crash)
#   4. judge_winner_to_work_units: emits the WINNER's enumerated_units
#   5. judge_winner_to_work_units: no winner in findings → raises (hard error)
#   6. plan_output_to_paired_builders: 2 biased builders + comparator depends_on both
#   7. transition_and_emit: emits + advances + recomputes atomically within ONE
#      _with_locked_ledger body; a reader BETWEEN the emit and the advance sees
#      a consistent (predicate-recomputed-post-emit) snapshot — there is no
#      torn intermediate state (G3/F2 property). Narrower than "one write": no
#      external observer can witness new-phase-without-new-units OR
#      new-units-without-recomputed-predicate.
#   8. emitters are pure: a registry emitter never calls a ledger mutator (smoke:
#      transition_and_emit with a real emitter completes without deadlock)
#   9. iterate_template happy: 3 plan-* units, counter=3, emit_count=1 → plan-4
#  10. iterate_template happy: emit_count=2 → plan-4, plan-5
#  11. iterate_template counter-resume: counter=7, units plan-1..plan-4, emit_count=1 → plan-8
#  12. judge_winner generalized: iteration.gate_unit="custom_judge", no "judge" unit → still emits
#  13. judge_winner backward-compat: no iteration field, unit "judge" exists → still emits
#  14. iterate_template no-iteration: ledger lacks iteration field → raises
#  15. iterate_template missing counter: legacy ledger w/o iteration_emit_count → defaults to 0
#  16. emit_count validation: 0, 11, "five", -1, 1.5, True all raise
#  17. iterate_template bad template ref: emit_template names unknown key → raises
#  18. integration: emit_within_phase + iterate_template → counter advances atomically

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

em() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module, load_ledger
emitters = load_lib_module("emitters")
recipes = load_lib_module("recipes")
ledger = load_ledger()
op = sys.argv[2]


# U3 helper: build an in-memory ledger dict for the iterate_template emitter
# to read. The emitter is PURE — it reads ledger.iteration, ledger.emit_templates,
# ledger.iteration_emit_count, and the gate unit's dispatch_context.
# decision_payload. No flock needed; no file needed.
def _ledger_for_iter(units, *, gate_unit="judge", template_name="plan-candidate",
                    id_prefix="plan-", phase="plan", counter=0,
                    invokes=None, missing_iteration=False, missing_template=False):
    led = {
        "units": units,
        "iteration_emit_count": counter,
    }
    if not missing_iteration:
        led["iteration"] = {
            "gate_unit": gate_unit, "emit_template": template_name,
        }
    if not missing_template:
        led["emit_templates"] = {
            template_name: {
                "phase": phase,
                "invokes": invokes if invokes is not None else {"adapter_op": "next_plan_step"},
                "id_prefix": id_prefix,
            }
        }
    return led


if op == "registry-consistency":
    print("match" if set(emitters.REGISTRY) == set(recipes.V1_EMITTER_NAMES) else "MISMATCH")

elif op == "a1-emit":
    led = {"units": [{"id": "plan", "phase": "plan",
            "dispatch_context": {"enumerated_units": [
                {"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]}}]}
    out = emitters.plan_output_to_work_units(led, "work")
    print(",".join(u["id"] + ":" + u["phase"] for u in out))

elif op == "a1-empty":
    led = {"units": [{"id": "plan", "phase": "plan", "dispatch_context": {}}]}
    print(len(emitters.plan_output_to_work_units(led, "work")))

# ─── v0.6.0 U8: brainstorm_output_to_plan_unit ──────────────────────────────
elif op == "brainstorm-emit":
    # The brainstorm unit carries its requirements-doc output on
    # dispatch_context.requirements_doc; the emitter materializes ONE plan unit
    # (5-key dict) carrying that path, invoking next_plan_step (a1's plan shape).
    led = {"units": [
        {"id": "brainstorm", "phase": "brainstorm",
         "dispatch_context": {"requirements_doc": "docs/brainstorms/x-requirements.md"}}]}
    out = emitters.brainstorm_output_to_plan_unit(led, "plan")
    u = out[0]
    print("%d|%s|%s|%s|%s|%s" % (
        len(out), u["id"], u["phase"],
        u["invokes"].get("adapter_op"),
        u["dispatch_context"].get("requirements_doc"),
        ",".join(sorted(u.keys()))))

elif op == "brainstorm-pure":
    # The emitter is PURE — it must not mutate the input ledger dict. Snapshot
    # the units list identity + content before/after; both must be unchanged.
    led = {"units": [
        {"id": "brainstorm", "phase": "brainstorm",
         "dispatch_context": {"requirements_doc": "docs/x.md"}}]}
    before = json.dumps(led, sort_keys=True)
    emitters.brainstorm_output_to_plan_unit(led, "plan")
    after = json.dumps(led, sort_keys=True)
    print("unchanged" if before == after else "MUTATED")

elif op == "brainstorm-no-unit":
    # No brainstorm unit at all → RecipeError (not a silent empty emit).
    led = {"units": [{"id": "plan", "phase": "plan", "dispatch_context": {}}]}
    try:
        emitters.brainstorm_output_to_plan_unit(led, "plan"); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "brainstorm-no-output":
    # brainstorm unit exists but carries no requirements_doc → RecipeError
    # (mirrors A2/A4 emitter failure; silent empty emit would leave plan vacuous).
    led = {"units": [{"id": "brainstorm", "phase": "brainstorm", "dispatch_context": {}}]}
    try:
        emitters.brainstorm_output_to_plan_unit(led, "plan"); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "judge-winner":
    # Fix-pass I (P0): winner_unit_id lives on judge.dispatch_context, NOT on
    # findings — record_verdict's findings normalize strips every key except
    # {severity, note}, so the prior findings-based contract was unreachable
    # from any production write path. dispatch_context is preserved by
    # transition() and the verdict-write path with no normalize.
    led = {"units": [
        {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": [{"id": "wA", "invokes": {}}]}},
        {"id": "plan-2", "phase": "plan", "dispatch_context": {"enumerated_units": [{"id": "wB", "invokes": {}}]}},
        {"id": "judge", "phase": "work", "dispatch_context": {"winner_unit_id": "plan-2"}},
    ]}
    out = emitters.judge_winner_to_work_units(led, "work")
    print(",".join(u["id"] for u in out))

elif op == "judge-no-winner":
    led = {"units": [
        {"id": "plan-1", "phase": "plan", "dispatch_context": {"enumerated_units": []}},
        # No winner_unit_id on dispatch_context, AND any leftover findings
        # are ignored by the new contract (the emitter only reads dispatch_context).
        {"id": "judge", "phase": "work", "dispatch_context": {}, "findings": [{"note": "undecided"}]},
    ]}
    # P2-7: emitter raises RecipeError (the recipe-shape error class) on a
    # malformed judge verdict — keeps the engine's "recipe-contract violation"
    # surface uniform whether validate() or an emitter raises.
    try:
        emitters.judge_winner_to_work_units(led, "work"); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "a4-pair":
    # v0.3.0 U6: compare is now structurally declared in a4's units[]; the
    # emitter only produces the two bias-differentiated builders. The test
    # asserts the emitter's NEW return shape (builders only, no compare).
    led = {"units": [{"id": "plan", "phase": "plan",
            "dispatch_context": {"enumerated_units": [{"id": "task", "invokes": {}}]}}]}
    out = emitters.plan_output_to_paired_builders(led, "work")
    ids = [u["id"] for u in out]
    biases = sorted((u["dispatch_context"].get("bias") for u in out if u["id"].startswith("build-")))
    has_compare = any(u["id"] == "compare" for u in out)
    print("%s|%s|%s" % (",".join(ids), ",".join(biases), "yes" if has_compare else "no"))

elif op == "atomic-emit":
    # transition_and_emit emits + advances + recomputes atomically within ONE
    # _with_locked_ledger body; a reader between the emit and the advance sees
    # a consistent (predicate-recomputed-post-emit) snapshot.
    repo = tempfile.mkdtemp(); run = "ae"
    ledger.init_ledger(repo, run, adapter="ce",
        recipe={"name": "a1", "source_tier": "built-in"},
        phase_order=["plan", "seam", "work"], terminal_phase="work",
        loop_phase="seam",
        units=[{"id": "plan", "phase": "plan", "state": "verdict-returned",
                "dispatch_context": {"enumerated_units": [
                    {"id": "w1", "invokes": {}}, {"id": "w2", "invokes": {}}]}}])
    appended = ledger.transition_and_emit(repo, run, "work",
        emitters.plan_output_to_work_units)
    led = ledger.read_ledger(repo, run)
    work_units = [u["id"] for u in led["units"] if u["phase"] == "work"]
    # phase advanced to work; 2 work units appended; predicate saw them (not met —
    # they're pending, so all_units_terminal is False).
    print("%s|%s|%s|%s" % (
        led["loop_phase"], ",".join(sorted(appended)),
        ",".join(sorted(work_units)), led["exit_predicate_result"]["met"]))

# ─── U3 (v0.3.0) iterate_template scenarios ───────────────────────────────
# The _ledger_for_iter helper is defined at the top (it must precede the
# if/elif dispatch chain). Each scenario below uses it to construct a fresh
# in-memory ledger and exercises one facet of the iterate_template contract.

elif op == "iter-tpl-happy-1":
    # 3 plan-* units exist, counter=3, emit_count=1 (default) → plan-4
    led = _ledger_for_iter(
        units=[
            {"id": "plan-1", "phase": "plan"},
            {"id": "plan-2", "phase": "plan"},
            {"id": "plan-3", "phase": "plan"},
            {"id": "judge", "phase": "work",
             "dispatch_context": {"decision_payload": {"emit_count": 1}}},
        ],
        counter=3,
    )
    out = emitters.iterate_template(led, "plan")
    print(",".join(u["id"] + ":" + u["phase"] for u in out))

elif op == "iter-tpl-happy-2":
    # emit_count=2 → plan-4, plan-5
    led = _ledger_for_iter(
        units=[
            {"id": "plan-1", "phase": "plan"},
            {"id": "plan-2", "phase": "plan"},
            {"id": "plan-3", "phase": "plan"},
            {"id": "judge", "phase": "work",
             "dispatch_context": {"decision_payload": {"emit_count": 2}}},
        ],
        counter=3,
    )
    out = emitters.iterate_template(led, "plan")
    print(",".join(u["id"] for u in out))

elif op == "iter-tpl-counter-resume":
    # Counter=7 but only plan-1..plan-4 exist (partial-emit crash deleted 5/6/7).
    # emit_count=1 → plan-8 (NOT plan-5). Closes round-3 P0-R3-2.
    led = _ledger_for_iter(
        units=[
            {"id": "plan-1", "phase": "plan"},
            {"id": "plan-2", "phase": "plan"},
            {"id": "plan-3", "phase": "plan"},
            {"id": "plan-4", "phase": "plan"},
            {"id": "judge", "phase": "work",
             "dispatch_context": {"decision_payload": {"emit_count": 1}}},
        ],
        counter=7,
    )
    out = emitters.iterate_template(led, "plan")
    print(",".join(u["id"] for u in out))

elif op == "judge-generalized":
    # iteration.gate_unit = "custom_judge", NO unit named "judge" exists.
    # judge_winner_to_work_units must find the gate via iteration.gate_unit.
    led = {
        "iteration": {"gate_unit": "custom_judge"},
        "units": [
            {"id": "plan-1", "phase": "plan",
             "dispatch_context": {"enumerated_units": [{"id": "wA", "invokes": {}}]}},
            {"id": "plan-2", "phase": "plan",
             "dispatch_context": {"enumerated_units": [{"id": "wB", "invokes": {}}]}},
            {"id": "custom_judge", "phase": "work",
             "dispatch_context": {"winner_unit_id": "plan-2"}},
        ],
    }
    out = emitters.judge_winner_to_work_units(led, "work")
    print(",".join(u["id"] for u in out))

elif op == "judge-backcompat":
    # No iteration field (v0.2.0 a2.json shape). Default fallback to literal
    # "judge" must still work — preserves v0.2.0 a2 behavior unchanged.
    led = {
        "units": [
            {"id": "plan-1", "phase": "plan",
             "dispatch_context": {"enumerated_units": [{"id": "wA", "invokes": {}}]}},
            {"id": "plan-2", "phase": "plan",
             "dispatch_context": {"enumerated_units": [{"id": "wB", "invokes": {}}]}},
            {"id": "judge", "phase": "work",
             "dispatch_context": {"winner_unit_id": "plan-1"}},
        ],
    }
    out = emitters.judge_winner_to_work_units(led, "work")
    print(",".join(u["id"] for u in out))

elif op == "iter-tpl-no-iteration":
    # Ledger has no iteration field → iterate_template raises RecipeError.
    led = {"units": [], "iteration_emit_count": 0}
    try:
        emitters.iterate_template(led, "plan"); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "iter-tpl-missing-counter":
    # v0.2.x-shaped ledger missing iteration_emit_count field. .get default
    # returns 0; first emit id is plan-1.
    led = {
        "iteration": {"gate_unit": "judge", "emit_template": "plan-candidate"},
        "emit_templates": {
            "plan-candidate": {
                "phase": "plan",
                "invokes": {"adapter_op": "next_plan_step"},
                "id_prefix": "plan-",
            }
        },
        # NO iteration_emit_count field.
        "units": [
            {"id": "judge", "phase": "work",
             "dispatch_context": {"decision_payload": {"emit_count": 1}}},
        ],
    }
    out = emitters.iterate_template(led, "plan")
    print(",".join(u["id"] for u in out))

elif op == "iter-tpl-emit-count-validation":
    # All out-of-range or wrong-type values must raise RecipeError.
    base_units = [
        {"id": "plan-1", "phase": "plan"},
        {"id": "judge", "phase": "work",
         "dispatch_context": {"decision_payload": {"emit_count": None}}},
    ]
    results = []
    for bad in (0, 11, "five", -1, 1.5, True):
        base_units[1]["dispatch_context"]["decision_payload"]["emit_count"] = bad
        led = _ledger_for_iter(units=list(base_units), counter=1)
        try:
            emitters.iterate_template(led, "plan")
            results.append(f"{bad!r}:NO-RAISE")
        except recipes.RecipeError:
            results.append(f"{bad!r}:raised")
    print(";".join(results))

elif op == "iter-tpl-bad-template-ref":
    # iteration.emit_template names a key that emit_templates doesn't contain.
    led = {
        "iteration": {"gate_unit": "judge", "emit_template": "nonexistent"},
        "emit_templates": {
            "plan-candidate": {
                "phase": "plan",
                "invokes": {"adapter_op": "next_plan_step"},
                "id_prefix": "plan-",
            }
        },
        "iteration_emit_count": 0,
        "units": [
            {"id": "judge", "phase": "work",
             "dispatch_context": {"decision_payload": {"emit_count": 1}}},
        ],
    }
    try:
        emitters.iterate_template(led, "plan"); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "iter-tpl-integration":
    # Integration: emit_within_phase + iterate_template prove the counter
    # advances atomically PER emitted unit through the locked body. Without
    # this scenario, both the emitter (pure read) and _apply_emit (per-unit
    # bump) could be individually correct but the composition broken.
    repo = tempfile.mkdtemp(); run = "iter-integration"
    ledger.init_ledger(repo, run, adapter="ce",
        recipe={"name": "a2", "source_tier": "built-in"},
        phase_order=["plan", "seam", "work"], terminal_phase="work",
        loop_phase="plan",
        units=[
            {"id": "plan-1", "phase": "plan", "state": "fixed"},
            {"id": "plan-2", "phase": "plan", "state": "fixed"},
            {"id": "plan-3", "phase": "plan", "state": "fixed"},
            {"id": "judge", "phase": "work", "state": "pending",
             "dispatch_context": {"decision_payload": {"emit_count": 2}}},
        ])
    # Inject iteration + emit_templates + counter directly on disk — these
    # ledger fields are populated by U6 (engine wiring) which is not yet
    # landed. The emitter only READS them, so direct injection is correct.
    path = ledger.ledger_path(repo, run)
    with open(path) as f:
        led = json.load(f)
    led["iteration"] = {"gate_unit": "judge", "emit_template": "plan-candidate"}
    led["emit_templates"] = {
        "plan-candidate": {
            "phase": "plan",
            "invokes": {"adapter_op": "next_plan_step"},
            "id_prefix": "plan-",
        }
    }
    led["iteration_emit_count"] = 3
    with open(path, "w") as f:
        json.dump(led, f)
    appended = ledger.emit_within_phase(repo, run, "plan", emitters.iterate_template)
    led = ledger.read_ledger(repo, run)
    new_ids = [u["id"] for u in led["units"] if u["id"].startswith("plan-")
               and u["id"] not in {"plan-1", "plan-2", "plan-3"}]
    print("%s|%s|%s" % (
        ",".join(sorted(appended)),
        ",".join(sorted(new_ids)),
        led["iteration_emit_count"]))
PYEOF
}

# ─── Scenario 1: registry ↔ validator consistency ───────────────────────────
it "emitters.REGISTRY keys == recipes.V1_EMITTER_NAMES (no drift)"
assert_eq "match" "$(em registry-consistency)"

# ─── Scenario 2-3: plan_output_to_work_units ────────────────────────────────
it "plan_output_to_work_units: enumerated → work units (phase set)"
assert_eq "w1:work,w2:work" "$(em a1-emit)"

it "plan_output_to_work_units: empty enumerated → [] (vacuous, no crash)"
assert_eq "0" "$(em a1-empty)"

# ─── v0.6.0 U8: brainstorm_output_to_plan_unit ──────────────────────────────
# The spine emitter that fires on arrival at `plan` from `brainstorm`: it reads
# the brainstorm unit's requirements-doc output and emits ONE structural plan
# unit (5-key dict), invoking next_plan_step so the downstream plan→work
# machinery is identical to a1's plan-entry path. Registry symmetry (Scenario 1)
# already asserts this emitter is in BOTH REGISTRY and V1_EMITTER_NAMES.
it "U8: brainstorm_output_to_plan_unit → one plan unit (5-key, requirements-doc carried)"
assert_eq "1|plan|plan|next_plan_step|docs/brainstorms/x-requirements.md|depends_on,dispatch_context,id,invokes,phase" "$(em brainstorm-emit)"

it "U8: brainstorm_output_to_plan_unit is pure (no ledger mutation)"
assert_eq "unchanged" "$(em brainstorm-pure)"

it "U8: no brainstorm unit → RecipeError (not a silent empty emit)"
assert_eq "raised" "$(em brainstorm-no-unit)"

it "U8: brainstorm unit with missing requirements_doc → RecipeError"
assert_eq "raised" "$(em brainstorm-no-output)"

# ─── Scenario 4-5: judge_winner_to_work_units ───────────────────────────────
it "judge_winner_to_work_units: emits the WINNER's units"
assert_eq "wB" "$(em judge-winner)"

it "judge_winner_to_work_units: no winner → raises (hard error)"
assert_eq "raised" "$(em judge-no-winner)"

# ─── Scenario 6: plan_output_to_paired_builders (v0.3.0 U6 — compare structural) ──
# Before v0.3.0 U6, this emitter synthesized 3 units (build-clarity, build-perf,
# compare). U6 moved compare into a4.json's `units[]` (declared with
# depends_on: [build-clarity, build-perf] — forward-referencing the bias-builder
# emit_template id_prefix). The emitter now produces ONLY the two builders;
# compare is on the ledger from init. This closes round-2 P0 #7 (compare's
# dual-source definition).
it "plan_output_to_paired_builders: 2 biased builders only; compare is structural (U6 — NOT in emitter output)"
assert_eq "build-clarity,build-perf|clarity,perf|no" "$(em a4-pair)"

# ─── Scenario 7: transition_and_emit atomic (G3/F2) ─────────────────────────
it "transition_and_emit: appends units + advances phase + predicate sees post-emission set"
assert_eq "work|w1,w2|w1,w2|False" "$(em atomic-emit)"

# ═══════════════════════════════════════════════════════════════════════════
# U3 (v0.3.0) — iterate_template emitter + judge_winner gate-unit generalization
# ═══════════════════════════════════════════════════════════════════════════

# ─── Scenario 9: iterate_template happy emit_count=1 ────────────────────────
it "iterate_template: counter=3 emit_count=1 → plan-4 (NOT recount-based plan-4)"
assert_eq "plan-4:plan" "$(em iter-tpl-happy-1)"

# ─── Scenario 10: iterate_template happy emit_count=2 ───────────────────────
it "iterate_template: emit_count=2 → plan-4,plan-5"
assert_eq "plan-4,plan-5" "$(em iter-tpl-happy-2)"

# ─── Scenario 11: counter-resume after partial-emit crash (P0-R3-2) ─────────
it "iterate_template: counter=7 with units 1-4 → plan-8 (monotonic counter wins)"
assert_eq "plan-8" "$(em iter-tpl-counter-resume)"

# ─── Scenario 12: judge_winner generalized via iteration.gate_unit ──────────
it "judge_winner_to_work_units: reads gate_unit from iteration block (no 'judge' literal)"
assert_eq "wB" "$(em judge-generalized)"

# ─── Scenario 13: judge_winner backward-compat (no iteration field) ─────────
it "judge_winner_to_work_units: no iteration field → falls back to literal 'judge'"
assert_eq "wA" "$(em judge-backcompat)"

# ─── Scenario 14: iterate_template with no iteration field → raises ─────────
it "iterate_template: ledger has no iteration block → raises RecipeError"
assert_eq "raised" "$(em iter-tpl-no-iteration)"

# ─── Scenario 15: missing iteration_emit_count → defaults to 0 ──────────────
it "iterate_template: legacy ledger missing iteration_emit_count → first id is plan-1"
assert_eq "plan-1" "$(em iter-tpl-missing-counter)"

# ─── Scenario 16: emit_count validation (round-3 P1-R3-4) ───────────────────
it "iterate_template: emit_count validation (0, 11, 'five', -1, 1.5, True all raise)"
assert_eq "0:raised;11:raised;'five':raised;-1:raised;1.5:raised;True:raised" "$(em iter-tpl-emit-count-validation)"

# ─── Scenario 17: bad emit_template reference ───────────────────────────────
it "iterate_template: emit_template names unknown key → raises RecipeError"
assert_eq "raised" "$(em iter-tpl-bad-template-ref)"

# ─── Scenario 18: integration through emit_within_phase (counter atomicity) ─
# Proves the counter-emitter contract composes: emitter returns N units off
# pre-emit counter=3, _apply_emit appends them under flock and bumps the
# counter PER unit (3 → 5). Without this, both sides could be individually
# green but the composition broken.
it "iterate_template ⇆ emit_within_phase: 2 emits → counter advances 3→5 atomically"
assert_eq "plan-4,plan-5|plan-4,plan-5|5" "$(em iter-tpl-integration)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "emitters.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
