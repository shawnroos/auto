#!/usr/bin/env bash
# auto v0.6.0 U7 unit test: recipes/pipeline.json (the brainstorm-rooted spine)
# + brainstorm entry-phase wiring through the init path.
#
# SELF-CONTAINED inline harness (same style as emitters.test.sh / recipes.test.sh).
#
# Scenarios:
#   1. pipeline.json validates and resolves through the three-tier registry.
#   2. Init at `brainstorm` bakes loop_phase="brainstorm" + the full phase_order
#      (the recipe-generic `loop_phase=phase_order[0]` init line threads it; no
#      auto.py change needed — init_ledger validates membership, line ~808).
#   3. Forward advance brainstorm→plan emits the plan unit via the EMITTER path
#      (transition_and_emit / direct-dict-mutation), not predicate-met.
#   4. A spine-phase loop_phase write via the direct-mutation path
#      (transition_and_emit) SUCCEEDS; via set_loop it RAISES — documents the
#      KTD-3 constraint (set_loop validates against LOOP_PHASES, which excludes
#      "brainstorm"; the direct-mutation path bypasses that gate).
#   5. terminal_phase is `work`; the run leaves brainstorm ONLY via forward
#      phase-advance (emitter), never via predicate-met (met stays False at a
#      non-terminal phase).
#   6. plan-entry still routes to a1, work-entry to w (no regression).

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

# Driver: load recipes/ledger/emitters via _bootstrap, run an op, print result.
pl() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
ledger = load_lib_module("ledger")
emitters = load_lib_module("emitters")
op = sys.argv[2]


def _init_from_recipe(repo, run, name):
    """Init a ledger from a built-in recipe exactly as lib/auto.py does (the
    recipe-generic init call: loop_phase=phase_order[0])."""
    r, tier = recipes.load_and_validate(name, repo)
    init_units = [recipes.unit_for(u, r) for u in r.get("units", [])]
    po = r.get("phase_order", ["plan", "seam", "work"])
    ledger.init_ledger(
        repo, run, adapter="ce", units=init_units,
        loop_phase=po[0],
        recipe={"name": r["name"], "source_tier": tier},
        phase_order=po, terminal_phase=r.get("terminal_phase", "work"),
        phase_transitions=r.get("phase_transitions", []))
    return r


if op == "validate-resolve":
    repo = tempfile.mkdtemp()
    r, tier = recipes.load_and_validate("pipeline", repo)
    print("%s:%s:%s:%s" % (
        r["name"], tier, ",".join(r["phase_order"]), r["terminal_phase"]))

elif op == "init-brainstorm":
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "pl", "pipeline")
    led = ledger.read_ledger(repo, "pl")
    print("%s|%s|%s" % (
        led["loop_phase"], ",".join(led["phase_order"]),
        ",".join(u["id"] for u in led["units"])))

elif op == "forward-advance":
    # Record the brainstorm output, then advance brainstorm→plan via
    # transition_and_emit (the direct-mutation/emitter path). Asserts the plan
    # unit is EMITTER-driven (appended), loop_phase moved to plan, and the
    # requirements-doc rode through onto the plan unit's dispatch_context.
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "pl", "pipeline")
    path = ledger.ledger_path(repo, "pl")
    with open(path) as f:
        d = json.load(f)
    for u in d["units"]:
        if u["id"] == "brainstorm":
            u.setdefault("dispatch_context", {})["requirements_doc"] = "docs/req.md"
            u["state"] = "verdict-returned"
    with open(path, "w") as f:
        json.dump(d, f)
    appended = ledger.transition_and_emit(
        repo, "pl", "plan", emitters.brainstorm_output_to_plan_unit)
    led = ledger.read_ledger(repo, "pl")
    plan = next(u for u in led["units"] if u["id"] == "plan")
    print("%s|%s|%s" % (
        led["loop_phase"], ",".join(sorted(appended)),
        plan["dispatch_context"].get("requirements_doc")))

elif op == "set-loop-rejects-brainstorm":
    # KTD-3: a spine-phase loop_phase write via set_loop RAISES (LOOP_PHASES
    # gate excludes "brainstorm"); the direct-mutation path (transition_and_emit,
    # exercised in forward-advance) is the sanctioned route. Here we prove the
    # set_loop rejection so the constraint is covered.
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "pl", "pipeline")
    try:
        ledger.set_loop(repo, "pl", loop_phase="brainstorm")
        print("NO-RAISE")
    except ledger.LedgerError:
        print("raised")

elif op == "predicate-not-met-at-brainstorm":
    # terminal_phase is work; at loop_phase="brainstorm" (non-terminal) the exit
    # predicate must NOT be met — the run leaves brainstorm only via forward
    # advance, never via predicate-met.
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "pl", "pipeline")
    led = ledger.read_ledger(repo, "pl")
    print("%s|%s" % (led["terminal_phase"], led["exit_predicate_result"]["met"]))

elif op == "plan-entry-a1":
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "r", "a1")
    led = ledger.read_ledger(repo, "r")
    print("%s|%s" % (led["loop_phase"], ",".join(led["phase_order"])))

elif op == "work-entry-w":
    repo = tempfile.mkdtemp()
    _init_from_recipe(repo, "r", "w")
    led = ledger.read_ledger(repo, "r")
    print("%s|%s" % (led["loop_phase"], ",".join(led["phase_order"])))
PYEOF
}

# ─── Scenario 1: validate + resolve ─────────────────────────────────────────
it "U7: pipeline.json validates + resolves (built-in, brainstorm-rooted spine, terminal work)"
assert_eq "pipeline:built-in:brainstorm,plan,seam,work:work" "$(pl validate-resolve)"

# ─── Scenario 2: init at brainstorm ─────────────────────────────────────────
it "U7: init bakes loop_phase=brainstorm + full phase_order + the brainstorm unit"
assert_eq "brainstorm|brainstorm,plan,seam,work|brainstorm" "$(pl init-brainstorm)"

# ─── Scenario 3: forward advance brainstorm→plan (emitter-driven) ───────────
it "U7: forward advance brainstorm→plan emits the plan unit (emitter path), carries the req-doc"
assert_eq "plan|plan|docs/req.md" "$(pl forward-advance)"

# ─── Scenario 4: set_loop rejects brainstorm (KTD-3 constraint) ─────────────
it "U7/KTD-3: set_loop(loop_phase=brainstorm) RAISES (LOOP_PHASES gate); direct-mutation path is the route"
assert_eq "raised" "$(pl set-loop-rejects-brainstorm)"

# ─── Scenario 5: predicate not met at non-terminal brainstorm ───────────────
it "U7: terminal_phase=work; predicate NOT met at brainstorm (leaves only via forward advance)"
assert_eq "work|False" "$(pl predicate-not-met-at-brainstorm)"

# ─── Scenario 6: no regression — plan-entry a1, work-entry w ────────────────
it "U7: plan-entry still routes to a1 (loop_phase=plan, default grammar)"
assert_eq "plan|plan,seam,work" "$(pl plan-entry-a1)"

it "U7: work-entry still routes to w (loop_phase=work, work-only grammar)"
assert_eq "work|work" "$(pl work-entry-w)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "pipeline-recipe.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
