#!/usr/bin/env bash
# auto U5 unit test: inline gate compilation for gated recipes.
#
# Exercises the REAL lib/recipes.py / lib/ledger.py / lib/tick.py surfaces the
# auto-launch §6.1 compile-and-dispatch step drives — independent of
# AskUserQuestion (the chooser is prose; this tests the mechanics under it).
#
# SELF-CONTAINED inline harness (same style as ledger.test.sh / recipes.test.sh):
# its own it/pass/fail/assert helpers + HOME/sandbox isolation. HOME is moved to
# the sandbox so resolve()'s GLOBAL tier (~/.claude/auto/recipes) can't leak the
# operator's real recipes into the run, and the workspace tier lives under a
# mktemp repo so the teardown `rm` stays inside ephemeral $TMPDIR.
#
# Scenarios (mapped to the U5 plan's Test scenarios):
#   1. Covers AE3 — an a2 recommendation with an edited advisor_judge gate
#      compiles to a2-<slug>.json in the WORKSPACE tier through the real
#      validate_and_lint write gate; validate accepts it; resolve("a2-<slug>")
#      returns it at tier `workspace` (and the gate unit carries the verification).
#   2. Covers AE4 — a custom spike-before-build loop validates before it is offered.
#   3. a1/w take the no-compile branch — the built-ins declare no iteration gate
#      unit, so there is nothing to attach a verification array to; no workspace
#      recipe is written.
#   4. Anti-shadow + verbatim-description-warning-is-blocking — the distinct stem
#      a2-<slug> resolves at `workspace` WHILE the canonical built-in a2 stays
#      `built-in` (unshadowed); a verbatim-built-in description triggers only a
#      validate_and_lint WARNING (not a hard error), which the agent treats as
#      blocking; a distinct description clears it.
#   5. Teardown / recipe-blind-after-init — after init_ledger the run-scoped
#      recipe file is deleted, yet a post-init drive (dispatch_tick, which
#      resolves emitters off the LEDGER, never the recipe file) still advances the
#      run, read_ledger still carries the topology, and nothing persists in
#      .claude/auto/recipes/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
WORKSPACE_RECIPES="${REPO}/.claude/auto/recipes"
mkdir -p "$REPO"

# field <key> <"k=v k=v ..."> — extract the value for key= from a result line.
field() {
  local key="$1"; shift
  printf '%s\n' "$*" | tr ' ' '\n' | sed -n "s/^${key}=//p"
}

# drv <op> [args...] — load the real libs via _bootstrap and run one op.
# Each op prints space-separated key=value tokens the bash side asserts on.
drv() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<'PYEOF'
import sys, os, json, tempfile

auto_root, repo = sys.argv[1], sys.argv[2]
op = sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module

recipes = load_lib_module("recipes")
BUILTIN_DIR = os.path.join(auto_root, "recipes")
WS = os.path.join(repo, ".claude", "auto", "recipes")


def load_builtin(name):
    with open(os.path.join(BUILTIN_DIR, name + ".json")) as f:
        return json.load(f)


def atomic_write(path, recipe):
    """mkstemp + os.rename — the auto-author-recipe write discipline (no torn
    file a concurrent reader could see)."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(recipe, f)
        os.rename(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def a2_variant(slug, *, description, with_verification=True):
    """A run-scoped a2 variant: distinct stem name, the operator-edited
    advisor_judge gate attached to the EXISTING iteration.gate_unit (`judge`)."""
    r = load_builtin("a2")
    r["name"] = "a2-" + slug
    r["description"] = description
    if with_verification:
        for u in r["units"]:
            if u["id"] == r["iteration"]["gate_unit"]:  # 'judge'
                u["verification"] = [
                    {"id": "design-sound", "type": "advisor_judge",
                     "rubric_ref": "verification-rubric"}
                ]
    return r


def vresult(d):
    try:
        recipes.validate(d); return "valid"
    except recipes.RecipeError:
        return "rejected"


if op == "compile-a2":
    # AE3: build the variant, run the REAL write gate, write atomically to the
    # workspace tier, read it back, and resolve both the variant and the builtin.
    slug = sys.argv[4]
    draft = a2_variant(slug, description="Run-scoped a2 variant for the checkout-fix run (launch-compile).")
    path = os.path.join(WS, draft["name"] + ".json")
    warnings = recipes.validate_and_lint(draft, filename=path)
    atomic_write(path, draft)
    # read-back verification (load_and_validate is the engine's load path)
    rb, rb_tier = recipes.load_and_validate(draft["name"], repo)
    readback = "valid"  # load_and_validate raises on failure
    _, vtier = recipes.resolve(draft["name"], repo)
    _, btier = recipes.resolve("a2", repo)
    gate = rb["iteration"]["gate_unit"]
    gate_has_verif = any(
        u["id"] == gate and u.get("verification") for u in rb["units"]
    )
    print(
        f"warnings={len(warnings)} readback={readback} "
        f"resolve_variant={vtier} resolve_builtin={btier} "
        f"gate_has_verif={int(gate_has_verif)}"
    )

elif op == "custom-validates":
    # AE4: a custom spike-before-build loop must validate before it is offered.
    custom = {
        "name": "spike-" + sys.argv[4],
        "version": "1",
        "description": "Custom spike-before-build loop (launch-compile test provenance).",
        "default_adapter": "ce",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "phase_transitions": [
            {"from": "plan", "to": "work", "emitter": "plan_output_to_work_units"}
        ],
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [],
             "invokes": {"adapter_op": "next_plan_step"}},
            {"id": "spike-gate", "phase": "work", "depends_on": [],
             "invokes": {"adapter_op": "review", "prompt_template": "gate.md"},
             "verification": [
                 {"id": "spike-validates", "type": "programmatic",
                  "argv": ["bash", "spike.sh"], "check": "exit_zero"}
             ]},
        ],
        "iteration": {"gate_unit": "spike-gate", "bound": {"max_attempts": 3}},
    }
    print(f"custom={vresult(custom)}")

elif op == "a1w-nocompile":
    # a1/w declare NO iteration block, so there is no gate_unit to attach a
    # verification array to → the no-compile branch (KTD-4).
    a1 = load_builtin("a1"); w = load_builtin("w")
    print(
        f"a1_iter={int('iteration' in a1)} w_iter={int('iteration' in w)} "
        f"a1_gate={a1.get('iteration', {}).get('gate_unit', 'none')}"
    )

elif op == "desc-warning":
    # The verbatim-description lint is a WARNING (not a hard error). Two drafts:
    #   verbatim  — description copied from the built-in a2 → spoof warning fires.
    #   distinct  — a distinct provenance description → no spoof warning.
    builtin_desc = load_builtin("a2")["description"]
    verbatim = a2_variant("verbatim", description=builtin_desc)
    distinct = a2_variant("distinct", description="A distinct provenance line for this run.")

    def spoof_warns(d):
        path = os.path.join(WS, d["name"] + ".json")
        ws = recipes.validate_and_lint(d, filename=path)
        return sum(1 for w in ws if "matches built-in" in w)

    # both must pass the HARD validate() — the lint is editorial, not a reject.
    print(
        f"verbatim_valid={vresult(verbatim)} distinct_valid={vresult(distinct)} "
        f"verbatim_spoof={int(spoof_warns(verbatim) > 0)} "
        f"distinct_spoof={int(spoof_warns(distinct) > 0)}"
    )

elif op == "teardown":
    # Write the run-scoped recipe, init a ledger from it (the ONLY point the
    # engine reads the recipe), delete the recipe, then drive a post-init tick
    # purely from ledger state — recipe-blind-after-init (recipe-format §1).
    ledger = load_lib_module("ledger")
    tick = load_lib_module("tick")
    slug = sys.argv[4]
    # Snapshot the workspace tier BEFORE this run so "nothing accumulates across
    # runs" is measured as net residue (other scenarios in this shared sandbox
    # leave their own recipes on purpose — they test resolve, not teardown).
    before = set(os.listdir(WS)) if os.path.isdir(WS) else set()
    draft = a2_variant(slug, description="Run-scoped a2 variant — teardown scenario.")
    path = os.path.join(WS, draft["name"] + ".json")
    recipes.validate_and_lint(draft, filename=path)
    atomic_write(path, draft)

    recipe, tier = recipes.load_and_validate(draft["name"], repo)
    init_units = [recipes.unit_for(u, recipe) for u in recipe.get("units", [])]
    phase_order = recipe.get("phase_order", ["plan", "seam", "work"])
    run_id = "teardown-" + slug
    ledger.init_ledger(
        repo, run_id,
        adapter=recipe.get("default_adapter", "ce"),
        units=init_units,
        loop_phase=phase_order[0],
        recipe={"name": recipe["name"], "source_tier": tier},
        phase_order=phase_order,
        terminal_phase=recipe.get("terminal_phase", "work"),
        phase_transitions=recipe.get("phase_transitions", []),
        iteration=recipe.get("iteration"),
        emit_templates=recipe.get("emit_templates"),
    )

    # Tear down the run-scoped recipe — engine is recipe-blind from here on.
    os.unlink(path)
    file_gone = int(not os.path.exists(path))
    after = set(os.listdir(WS)) if os.path.isdir(WS) else set()
    net_residue = len(after - before)  # new files this run left behind (expect 0)

    # resolve() now fails for the deleted variant (file is gone)...
    try:
        recipes.resolve(draft["name"], repo)
        resolve_after = "found"
    except recipes.RecipeError:
        resolve_after = "missing"

    # ...yet read_ledger still carries the persisted topology...
    led = ledger.read_ledger(repo, run_id)
    led_units = sorted(u["id"] for u in led.get("units", []))
    expected = sorted(u["id"] for u in init_units)
    topo_ok = int(led_units == expected)

    # ...and a post-init drive still advances the run (no recipe file needed).
    intent = tick.dispatch_tick(repo, run_id)
    print(
        f"file_gone={file_gone} net_residue={net_residue} "
        f"resolve_after={resolve_after} topo_ok={topo_ok} "
        f"tick_action={intent.get('action')}"
    )

else:
    print(f"unknown-op={op}")
PYEOF
}

echo "launch-recipe-compile (U5 inline gate compilation)"

# ── 1. Covers AE3: a2 + edited advisor_judge gate → workspace recipe ────────
R="$(drv compile-a2 fix-checkout)"
it "AE3: validate_and_lint write gate produces zero blocking warnings (distinct desc)"
assert_eq "0" "$(field warnings "$R")"
it "AE3: read-back load_and_validate accepts the compiled recipe"
assert_eq "valid" "$(field readback "$R")"
it "AE3: resolve('a2-fix-checkout') returns the variant at tier workspace"
assert_eq "workspace" "$(field resolve_variant "$R")"
it "AE3: the gate unit (judge) carries the operator-edited verification array"
assert_eq "1" "$(field gate_has_verif "$R")"

# ── 2. Covers AE4: a custom spike-before-build loop validates ───────────────
it "AE4: custom spike-before-build loop validates before being offered"
assert_eq "valid" "$(field custom "$(drv custom-validates one)")"

# ── 3. a1/w take the no-compile branch (KTD-4) ──────────────────────────────
R="$(drv a1w-nocompile)"
it "no-compile: a1 declares no iteration gate unit (nothing to attach a gate to)"
assert_eq "0" "$(field a1_iter "$R")"
it "no-compile: w declares no iteration gate unit"
assert_eq "0" "$(field w_iter "$R")"
it "no-compile: a1's gate unit is absent (no-compile branch, KTD-4)"
assert_eq "none" "$(field a1_gate "$R")"

# ── 4. Anti-shadow distinct stem + verbatim-description-warning-is-blocking ──
R="$(drv compile-a2 anti-shadow)"
it "anti-shadow: the distinct stem a2-anti-shadow resolves at the workspace tier"
assert_eq "workspace" "$(field resolve_variant "$R")"
it "anti-shadow: the canonical built-in a2 stays built-in (NOT shadowed by the variant)"
assert_eq "built-in" "$(field resolve_builtin "$R")"

R="$(drv desc-warning)"
it "verbatim-desc: a verbatim built-in description is still a HARD-valid recipe"
assert_eq "valid" "$(field verbatim_valid "$R")"
it "verbatim-desc: the verbatim description fires the spoof lint WARNING (agent treats as blocking)"
assert_eq "1" "$(field verbatim_spoof "$R")"
it "verbatim-desc: a distinct provenance description clears the spoof warning"
assert_eq "0" "$(field distinct_spoof "$R")"

# ── 5. Teardown / recipe-blind-after-init ───────────────────────────────────
R="$(drv teardown ledger-run)"
it "teardown: the run-scoped recipe file is deleted after ledger init"
assert_eq "1" "$(field file_gone "$R")"
it "teardown: nothing persists in .claude/auto/recipes/ (zero net residue across the run)"
assert_eq "0" "$(field net_residue "$R")"
it "teardown: resolve() can no longer find the deleted run-scoped recipe"
assert_eq "missing" "$(field resolve_after "$R")"
it "teardown: read_ledger still carries the run's persisted topology"
assert_eq "1" "$(field topo_ok "$R")"
it "teardown: a post-init dispatch_tick still drives the run (recipe-blind after init)"
assert_eq "rearm" "$(field tick_action "$R")"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "launch-recipe-compile.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
