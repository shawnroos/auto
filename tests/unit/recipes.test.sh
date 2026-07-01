#!/usr/bin/env bash
# auto U2/U3/U7 unit test: lib/recipes.py (validator + registry + A1_BUILTIN)
# and lib/topology-render.py.
#
# SELF-CONTAINED inline harness (same style as ledger.test.sh).
#
# Scenarios (U2 validate + U7 built-ins/constant/renderer; U3 resolver scenarios
# are added when U3 lands):
#   1. each built-in recipe (a1/a2/a4/w) validates
#   2. A1_BUILTIN equals the resolved a1.json topology (no drift) + validates
#   3. validate rejections: unknown field, bad emitter, traversal, non-default
#      phase_order (A3), missing required, depends_on integrity
#   4. work-only ([work]) accepted; reserved python_hook accepted
#   5. topology-render: deterministic, renders each built-in, names the emitter

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

# Driver: load recipes + topology-render via _bootstrap, run an op, print result.
rec() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
op = sys.argv[2]

def vresult(d):
    try:
        recipes.validate(d); return "valid"
    except recipes.RecipeError as e:
        return "rejected"

if op == "validate-builtins":
    out = []
    for name in ("a1", "a2", "a4", "w"):
        with open(os.path.join(auto_root, "recipes", name + ".json")) as f:
            out.append(name + ":" + vresult(json.load(f)))
    print(",".join(out))
elif op == "a1-no-drift":
    with open(os.path.join(auto_root, "recipes", "a1.json")) as f:
        disk = json.load(f)
    same = recipes.A1_BUILTIN == disk
    valid = vresult(recipes.A1_BUILTIN)
    print("%s,%s" % (same, valid))
elif op == "validate-json":
    print(vresult(json.loads(sys.argv[3])))
elif op == "render-builtin":
    tr = load_lib_module("topology-render")
    with open(os.path.join(auto_root, "recipes", sys.argv[3] + ".json")) as f:
        card = tr.render(json.load(f), 60)
    # print a few stable signals: contains the recipe name, the emitter, phase labels
    sigs = []
    sigs.append("name" if ("recipe: " + sys.argv[3]) in card else "NONAME")
    sigs.append("PLAN" if "PLAN" in card.upper() else "noplan")
    sigs.append("emit" if "emit:" in card else "noemit")
    print(",".join(sigs))
elif op == "render-deterministic":
    tr = load_lib_module("topology-render")
    with open(os.path.join(auto_root, "recipes", "a1.json")) as f:
        d = json.load(f)
    print("same" if tr.render(d, 60) == tr.render(d, 60) else "differs")

# ─── v0.6.0 U6 / U7 / U11: structural phase_order validator + new recipes ────
elif op == "validate-recipe-file":
    # Validate a built-in recipe FILE by name (generalizes validate-builtins
    # to the v0.6.0 recipes pipeline.json / review.json which the fixed
    # ("a1","a2","a4","w") loop above does not cover).
    with open(os.path.join(auto_root, "recipes", sys.argv[3] + ".json")) as f:
        print(vresult(json.load(f)))
elif op == "resolve-recipe-file":
    # Resolve a recipe through the three-tier registry in a fresh repo (proves
    # it lands at the built-in tier and loads+validates).
    import tempfile
    repo = tempfile.mkdtemp()
    try:
        r, tier = recipes.load_and_validate(sys.argv[3], repo)
        print("%s:%s:%s" % (r["name"], tier, vresult(r)))
    except recipes.RecipeError as e:
        print("ERROR:%s" % e)
elif op == "review-vs-w-distinct":
    # U11: review.json must be MEANINGFULLY distinct from w.json. review is a
    # genuine work-only ["work"] recipe whose single unit invokes the `review`
    # adapter op (one review/fix loop to P3). w (v0.4.3 KTD-15) is no longer its
    # work-only twin — it's plan_presatisfied, so its plan unit invokes
    # `next_plan_step` (the plan-loop sequencer) and it enumerates a reviewed plan
    # into work. Surface both ops so a silent convergence still trips this.
    with open(os.path.join(auto_root, "recipes", "review.json")) as f:
        rev = json.load(f)
    with open(os.path.join(auto_root, "recipes", "w.json")) as f:
        w = json.load(f)
    rev_op = rev["units"][0]["invokes"].get("adapter_op")
    w_op = w["units"][0]["invokes"].get("adapter_op")
    print("review:%s|w:%s|distinct:%s" % (rev_op, w_op, rev_op != w_op))
elif op == "validate-firsterr":
    # Pin the LOAD-BEARING first-error-wins order across the validate()
    # decomposition (was one 324-LOC function, now a ~30-line ordered
    # orchestrator over per-concern sub-validators). A doubly-malformed recipe
    # must surface the EARLIER block's error. Classify the first RecipeError
    # message into a stable token so the order is assertable.
    try:
        recipes.validate(json.loads(sys.argv[3]))
        print("valid")
    except recipes.RecipeError as e:
        m = str(e)
        if "unknown top-level field" in m:
            print("toplevel-unknown")
        elif "missing required field" in m or "must be a non-empty string" in m \
                or "units must be a list" in m:
            print("toplevel-shape")
        elif "phase_order" in m or "terminal_phase" in m:
            print("phase_order")
        elif "unit" in m:
            print("units")
        else:
            print("other:" + m)
elif op == "verification-cap":
    # v0.7.0 (U2): the per-unit `verification` array is capped at 16 criteria to
    # bound gate-evaluation cost. Build a unit carrying 17 INDIVIDUALLY-VALID
    # `human` criteria (unique ids) so the ONLY violation is the over-cap length
    # — proves the cap fires independent of per-criterion validity. Inlining 17
    # criteria as a shell JSON string is unwieldy, so build it here.
    crits = [{"id": "c%d" % i, "type": "human"} for i in range(17)]
    recipe = {"name": "x", "version": "1",
              "units": [{"id": "g", "phase": "plan", "invokes": {},
                         "verification": crits}]}
    print(vresult(recipe))
PYEOF
}

# ─── Scenario 1: built-ins validate ─────────────────────────────────────────
it "all four built-in recipes (a1/a2/a4/w) validate"
assert_eq "a1:valid,a2:valid,a4:valid,w:valid" "$(rec validate-builtins)"

# ─── Scenario 2: A1_BUILTIN no-drift + validates ────────────────────────────
it "A1_BUILTIN equals resolved a1.json AND validates (no drift)"
assert_eq "True,valid" "$(rec a1-no-drift)"

# ─── Scenario 3: validate rejections ────────────────────────────────────────
it "unknown top-level field rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[],"bogus":1}')"

# Order-preserving decomposition (M-? regression): a doubly-malformed recipe
# must surface the EARLIER sub-validator's error. validate() runs
# _validate_toplevel → _validate_phase_order → _validate_units → … in a fixed
# order; the 58 single-violation tests below cannot catch a transposition, so
# pin two cross-block boundaries explicitly.
it "validate order: unknown top-level field + bad phase_order -> top-level error wins (toplevel before phase_order)"
assert_eq "toplevel-unknown" "$(rec validate-firsterr '{"name":"x","version":"1","units":[],"bogus":1,"phase_order":[]}')"

it "validate order: bad terminal_phase + malformed unit -> phase_order error wins (phase_order before units)"
assert_eq "phase_order" "$(rec validate-firsterr '{"name":"x","version":"1","phase_order":["work"],"terminal_phase":"nope","units":[{"bad":"unit"}]}')"

it "reserved python_hook accepted (R3)"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[],"python_hook":"x"}')"

# v0.6.0 U6: the literal allow-list gate is gone — a multi-phase grammar that
# is STRUCTURALLY sound (non-empty-string phases, terminal_phase ∈ phase_order)
# now validates. Pre-U6 this exact recipe was REJECTED (the A3 grammar was not
# in _V1_ALLOWED_PHASE_ORDERS); U6 deliberately unlocks it. Units list is
# non-empty here (each unit's phase ∈ phase_order) so the work-only empty-units
# guard is not in play.
it "U6: structurally-sound non-default phase_order now VALIDATES (literal allow-list dropped)"
assert_eq "valid" "$(rec validate-json '{"name":"a3","version":"1","phase_order":["work_sketch","review","plan","work_refine"],"terminal_phase":"work_refine","units":[{"id":"s","phase":"work_sketch","invokes":{}}]}')"

it "work-only phase_order [work] accepted when units are pre-declared (KTD-15)"
assert_eq "valid" "$(rec validate-json '{"name":"w-test","version":"1","phase_order":["work"],"terminal_phase":"work","units":[{"id":"u1","phase":"work","invokes":{}}]}')"

# Fix-pass D (P1 #6): a work-only recipe with NO pre-declared units is
# unrunnable in v0.2.0 — init-time enumeration ships in v0.2.1 (KTD-15).
# validate() must hard-reject this shape so the engine never creates a
# zero-unit ledger that re-arms forever without dispatching.
it "fix-pass D: work-only phase_order [work] with empty units REJECTED (v0.2.1 reservation)"
assert_eq "rejected" "$(rec validate-json '{"name":"w-test","version":"1","phase_order":["work"],"terminal_phase":"work","units":[]}')"

# Deliberate-fail proof: the new rule must NOT fire on the default phase_order
# with empty units (still a vacuous run, but a different — and lint-warned —
# shape, not the work-only init-time gap). Surfaces a false-positive if the
# check ever broadens too far.
it "fix-pass D: default phase_order with empty units NOT rejected by the work-only rule"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[]}')"

it "unregistered emitter name rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"plan","phase":"plan","invokes":{}}],"phase_transitions":[{"from":"plan","to":"work","emitter":"nope"}]}')"

it "prompt_template path traversal rejected (security Finding 1)"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"u","phase":"plan","invokes":{"prompt_template":"../../etc/passwd"}}]}')"

it "depends_on referencing unknown unit rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"u","phase":"plan","depends_on":["ghost"],"invokes":{}}]}')"

it "missing required field (units) rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1"}')"

# ─── v0.7.0 U2: typed `verification` block on a (gate) unit (KTD-1/2/3) ───────
# A unit MAY carry an optional `verification` array of typed, checkable done-
# conditions (programmatic | model_judge | advisor_judge | human), validated at
# LOAD time in validate() — the SAME gate the skill's write-time
# validate_and_lint runs (KTD-3). Shape per
# skills/auto-design/references/verification-taxonomy.md. The base recipe is the
# minimal valid shape (one plan-phase unit, default phase_order); only the
# `verification` array varies, so a valid/rejected verdict isolates the criterion
# validator. Covers AE1 (schema half).
it "U2: programmatic exit_zero criterion → valid"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"tests-green","type":"programmatic","argv":["bash","tests/run.sh"],"check":"exit_zero","timeout_sec":120}]}]}')"

it "U2: programmatic stdout_contains criterion → valid"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"has-ok","type":"programmatic","argv":["echo","ok"],"check":{"stdout_contains":"ok"}}]}]}')"

it "U2: advisor_judge criterion → valid"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"design-sound","type":"advisor_judge","rubric_ref":"verification-rubric"}]}]}')"

it "U2: model_judge criterion → valid"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"reads-clean","type":"model_judge"}]}]}')"

it "U2: human criterion → valid"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"owner-signoff","type":"human","prompt":"Sign off?"}]}]}')"

it "U2: unknown criterion type → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"c1","type":"telepathic"}]}]}')"

it "U2: programmatic missing argv → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"c1","type":"programmatic","check":"exit_zero"}]}]}')"

it "U2: programmatic with malformed check (unknown check key) → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"c1","type":"programmatic","argv":["true"],"check":{"stdout_startswith":"x"}}]}]}')"

it "U2: unknown key for criterion type (human carrying argv) → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"c1","type":"human","prompt":"ok","argv":["true"]}]}]}')"

it "U2: verification over the 16-criteria cap (17 entries) → rejected"
assert_eq "rejected" "$(rec verification-cap)"

it "U2: criterion missing type → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"c1"}]}]}')"

it "U2: duplicate criterion id within a unit → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","units":[{"id":"g","phase":"plan","invokes":{},"verification":[{"id":"dup","type":"human"},{"id":"dup","type":"human"}]}]}')"

# Regression anchor: the four built-ins (none carry a `verification` array) MUST
# still validate after the additive U2 field — proves no regression (AE1).
it "U2: a1/a2/a4/w still validate after the additive verification field"
assert_eq "a1:valid,a2:valid,a4:valid,w:valid" "$(rec validate-builtins)"

# ─── v0.6.0 U6: structural phase_order validator (literal allow-list dropped) ─
# U6 replaced the `phase_order not in _V1_ALLOWED_PHASE_ORDERS` literal gate
# with a STRUCTURAL rule: every element a non-empty string, members cross-
# checked downstream (terminal_phase / unit phase / phase_transitions). The
# spine ["brainstorm","plan","seam","work"] must now validate; a1/a2/a4/w must
# STILL validate unchanged (Scenario 1 above covers the four built-ins).
it "U6: brainstorm-rooted spine phase_order validates (structural rule unlocks it)"
assert_eq "valid" "$(rec validate-json '{"name":"pipeline","version":"1","phase_order":["brainstorm","plan","seam","work"],"terminal_phase":"work","phase_transitions":[{"from":"brainstorm","to":"plan","emitter":"brainstorm_output_to_plan_unit"},{"from":"plan","to":"work","emitter":"plan_output_to_work_units"}],"units":[{"id":"brainstorm","phase":"brainstorm","invokes":{"adapter_op":"brainstorm"}}]}')"

it "U6: terminal_phase not in phase_order → rejected (downstream member-check intact)"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","phase_order":["brainstorm","plan","seam","work"],"terminal_phase":"ship","units":[{"id":"b","phase":"brainstorm","invokes":{}}]}')"

it "U6: a unit whose phase is not in phase_order → rejected"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","phase_order":["brainstorm","plan","seam","work"],"terminal_phase":"work","units":[{"id":"u","phase":"deploy","invokes":{}}]}')"

it "U6: phase_order with a non-string element → rejected (structural)"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","phase_order":["plan",3,"work"],"terminal_phase":"work","units":[{"id":"u","phase":"plan","invokes":{}}]}')"

it "U6: phase_order with an empty-string element → rejected (structural)"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","phase_order":["plan","","work"],"terminal_phase":"work","units":[{"id":"u","phase":"plan","invokes":{}}]}')"

it "U6: work-only empty-units guard STILL fires (regression — guard retained)"
assert_eq "rejected" "$(rec validate-json '{"name":"w-test","version":"1","phase_order":["work"],"terminal_phase":"work","units":[]}')"

it "U6: phase_transitions naming an unregistered emitter STILL rejected on a spine"
assert_eq "rejected" "$(rec validate-json '{"name":"x","version":"1","phase_order":["brainstorm","plan","seam","work"],"terminal_phase":"work","phase_transitions":[{"from":"brainstorm","to":"plan","emitter":"nope"}],"units":[{"id":"b","phase":"brainstorm","invokes":{}}]}')"

# ─── v0.6.0 U7: pipeline.json (the brainstorm-rooted spine) validates+resolves ─
it "U7: pipeline.json validates"
assert_eq "valid" "$(rec validate-recipe-file pipeline)"

it "U7: pipeline.json resolves through the three-tier registry (built-in)"
assert_eq "pipeline:built-in:valid" "$(rec resolve-recipe-file pipeline)"

# ─── v0.6.0 U11: review.json (off-spine single-phase) validates + distinct ───
it "U11: review.json validates"
assert_eq "valid" "$(rec validate-recipe-file review)"

it "U11: review.json resolves through the three-tier registry (built-in)"
assert_eq "review:built-in:valid" "$(rec resolve-recipe-file review)"

it "U11: review.json is MEANINGFULLY distinct from w.json (review op vs do_unit)"
assert_eq "review:review|w:next_plan_step|distinct:True" "$(rec review-vs-w-distinct)"

# ─── Scenario 5: topology-render ────────────────────────────────────────────
it "topology-render: a1 card names recipe + has PLAN + names emitter"
assert_eq "name,PLAN,emit" "$(rec render-builtin a1)"

it "topology-render: deterministic (same input → same output)"
assert_eq "same" "$(rec render-deterministic)"

# ─── U3: three-tier registry ────────────────────────────────────────────────
reg() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json, tempfile
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
op = sys.argv[2]

def mk_workspace_repo(recipe_dicts):
    """A temp repo with given workspace recipes; returns repo root."""
    repo = tempfile.mkdtemp()
    d = os.path.join(repo, ".claude", "auto", "recipes")
    os.makedirs(d)
    for r in recipe_dicts:
        with open(os.path.join(d, r["name"] + ".json"), "w") as f:
            json.dump(r, f)
    return repo

if op == "list-fresh":
    # A fresh repo (no workspace recipes) → exactly the built-ins.
    repo = tempfile.mkdtemp()
    names = [n for n, t in recipes.list_available(repo) if t == "built-in"]
    print(",".join(sorted(names)))

elif op == "shadow":
    # AE2: a workspace recipe named "a1" SHADOWS the built-in.
    repo = mk_workspace_repo([{"name": "a1", "version": "1",
        "phase_order": ["plan","seam","work"], "terminal_phase": "work",
        "units": [{"id":"plan","phase":"plan","invokes":{}}], "description": "WS"}])
    recipe, tier = recipes.resolve("a1", repo)
    # workspace wins; and a1 appears ONCE in list_available, tagged workspace.
    a1_entries = [(n, t) for n, t in recipes.list_available(repo) if n == "a1"]
    print("%s,%s,%d" % (tier, recipe.get("description"), len(a1_entries)))

elif op == "a1-fallback":
    # No a1.json anywhere (empty repo + we can't delete built-in, so test the
    # CONSTANT fallback path by resolving in a repo and checking a missing name
    # uses the constant only for 'a1'): resolve a1 in fresh repo → built-in/constant.
    repo = tempfile.mkdtemp()
    recipe, tier = recipes.resolve("a1", repo)
    print("%s,%s" % (recipe["name"], tier))

elif op == "missing":
    repo = tempfile.mkdtemp()
    try:
        recipes.resolve("does-not-exist", repo); print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "resolve-traversal":
    # P0 #4 fix-pass B: layer 2 — resolve() must reject a CLI-supplied recipe
    # name with traversal segments BEFORE touching the filesystem. We feed each
    # malicious name and assert all raise; if ANY one returns without raising,
    # the attack would succeed in production.
    import os, tempfile
    repo = tempfile.mkdtemp()
    bad_names = [
        "../../../etc/passwd",       # classic traversal
        "..",                         # parent dir on its own
        "/etc/passwd",                # absolute path
        "a/b",                        # slash mid-name
        "a\\b",                       # backslash (Windows-style)
        ".hidden",                    # leading dot
        "A1",                         # uppercase (not in the charset)
        "",                           # empty
        "x*",                         # glob meta
    ]
    raised = 0
    for n in bad_names:
        try:
            recipes.resolve(n, repo)
        except recipes.RecipeError:
            raised += 1
    print(f"{raised}/{len(bad_names)}")

elif op == "resolve-valid-names":
    # The regex must NOT reject legitimately-named recipes. Built-in names
    # (a1, a2, a4, w) are the conformance corpus; resolve() should accept them
    # (return either a built-in or raise "not found" — never a "name invalid"
    # RecipeError). We surface the error MESSAGE for the not-found case so a
    # false-positive name-rejection would be visible.
    import tempfile
    repo = tempfile.mkdtemp()
    out = []
    for n in ["a1", "a2", "my-recipe", "team_foo", "v2.1"]:
        try:
            _, tier = recipes.resolve(n, repo)
            out.append(f"{n}:{tier}")
        except recipes.RecipeError as e:
            msg = str(e)
            if "invalid recipe name" in msg:
                out.append(f"{n}:NAME-REJECTED")
            else:
                out.append(f"{n}:not-found")
    print(",".join(out))

elif op == "validate-traversal-name":
    # P0 #4 layer 1: validate() also rejects an unsafe `name:` field on a
    # recipe-file dict. Defense in depth — a recipe with the right shape but a
    # malicious name should fail validation.
    try:
        recipes.validate({"name": "../evil", "version": "1", "units": []})
        print("NO-RAISE")
    except recipes.RecipeError as e:
        print("raised" if "invalid recipe name" in str(e) else "raised-wrong-message")

elif op == "unit-for-traversal":
    # unit_for re-validates the prompt_template path bound (2nd enforcement point).
    try:
        recipes.unit_for({"id": "u", "phase": "work",
            "invokes": {"prompt_template": "../../etc/passwd"}}, {})
        print("NO-RAISE")
    except recipes.RecipeError:
        print("raised")

elif op == "unit-for-merge":
    u = recipes.unit_for({"id": "u", "phase": "work",
        "invokes": {"adapter_op": "do_unit", "prompt_template": "p/x.md"}}, {})
    print("%s,%s,%s" % (u["id"], u["dispatch_context"]["adapter_op"],
                        u["dispatch_context"]["prompt_template"]))

elif op == "lint-empty-phase":
    # validate_and_lint warns on a phase with no units + no emitter targeting it.
    warns = recipes.validate_and_lint({"name": "x", "version": "1",
        "phase_order": ["plan","seam","work"], "terminal_phase": "work",
        "units": [{"id":"plan","phase":"plan","invokes":{}}]})
    # work phase has no units and (no phase_transitions) no emitter → a warning.
    print("warned" if any("work" in w for w in warns) else "no-warning")
PYEOF
}

# v0.6.0 U7/U11 added two built-in recipes: pipeline (brainstorm-rooted spine)
# and review (off-spine single-phase). list_available is sorted by name.
it "list_available in a fresh repo → exactly the built-ins (a1/a2/a4/pipeline/review/w)"
assert_eq "a1,a2,a4,pipeline,review,w" "$(reg list-fresh)"

it "AE2: workspace recipe shadows built-in (workspace wins, appears once)"
assert_eq "workspace,WS,1" "$(reg shadow)"

it "resolve a1 with no a1.json → built-in (A1_BUILTIN fallback path)"
assert_eq "a1,built-in" "$(reg a1-fallback)"

it "resolve unknown recipe → raises with searched paths"
assert_eq "raised" "$(reg missing)"

# P0 #4 fix-pass B: layer-2 path-traversal defense at the CLI entry to resolve().
it "fix-pass B: resolve() rejects all path-traversal recipe names (9/9 raise)"
assert_eq "9/9" "$(reg resolve-traversal)"

# Deliberate-fail proof that the GREEN path isn't over-rejecting valid names.
# A regex tightened too far would fail this case — surfaces a false-positive
# that would block legitimate workspace/global recipes from resolving.
it "fix-pass B: resolve() accepts legitimate recipe names (built-ins + dashes/dots)"
assert_eq "a1:built-in,a2:built-in,my-recipe:not-found,team_foo:not-found,v2.1:not-found" \
  "$(reg resolve-valid-names)"

# P0 #4 layer 1: validate() also rejects an unsafe `name:` on the recipe dict.
it "fix-pass B: validate() rejects an unsafe recipe.name field"
assert_eq "raised" "$(reg validate-traversal-name)"

it "unit_for re-validates prompt_template traversal (2nd enforcement point)"
assert_eq "raised" "$(reg unit-for-traversal)"

it "unit_for merges invokes into dispatch_context"
assert_eq "u,do_unit,p/x.md" "$(reg unit-for-merge)"

it "validate_and_lint warns: phase with no units + no emitter"
assert_eq "warned" "$(reg lint-empty-phase)"

# ─── U5 (v0.3.0): iteration + emit_templates validation ─────────────────────
# Twelve scenarios covering R2, R3, R7 (a1/W backward compat), the pairing
# rule per round-3 P2 #21 (iteration WITHOUT emit_templates is valid IFF
# iteration.emit_template is also absent), and the editorial warnings.
# Plus one DELIBERATE-FAIL probe (gate_unit ghost) — Edit removes the check,
# the test goes RED, Edit restores.
itr() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recipes = load_lib_module("recipes")
op = sys.argv[2]

def vresult(d):
    try:
        recipes.validate(d); return "valid"
    except recipes.RecipeError:
        return "rejected"

# Full v0.3.0 A2 recipe shape — the GREEN reference. Per the plan's
# High-Level Technical Design block (lines 158-187). Every error-case test
# below mutates a single field off this base.
def a2_v030():
    return {
        "name": "a2", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan-1", "phase": "plan", "invokes": {}},
            {"id": "plan-2", "phase": "plan", "invokes": {}},
            {"id": "plan-3", "phase": "plan", "invokes": {}},
            {"id": "judge", "phase": "work",
             "depends_on": ["plan-1","plan-2","plan-3"], "invokes": {}},
        ],
        "phase_transitions": [
            {"from": "plan", "to": "work", "emitter": "judge_winner_to_work_units"}
        ],
        "iteration": {
            "gate_unit": "judge",
            "emit_template": "plan-candidate",
            "bound": {"max_attempts": 5, "max_wall_seconds": 1800},
        },
        "emit_templates": {
            "plan-candidate": {
                "phase": "plan",
                "invokes": {"adapter_op": "next_plan_step"},
                "id_prefix": "plan-",
            }
        },
    }

def _verif():
    # A minimal, validate()-passing verification criterion.
    return {"id": "c1", "type": "programmatic", "argv": ["true"], "check": "exit_zero"}

def lint_verif(r):
    # "valid:N" where N = # warnings mentioning verification ("rejected" if
    # validate_and_lint's internal validate() raised). The "valid:" prefix proves
    # validate() passed (R3: load must still succeed); N isolates the U2 warning.
    try:
        warns = recipes.validate_and_lint(r)
    except recipes.RecipeError:
        return "rejected"
    return "valid:%d" % sum(1 for w in warns if "verification" in w)

def _builtin_desc(name):
    # The verbatim description of a built-in recipe (read from disk).
    with open(os.path.join(auto_root, "recipes", name + ".json")) as f:
        return (json.load(f).get("description") or "").strip()

def spoof_result(r):
    # "spoof:N" where N = # description-spoofing warnings ("rejected" if
    # validate_and_lint's internal validate() raised — the "spoof:" prefix keeps a
    # validate() rejection from silently reading as spoof:0, mirroring lint_verif).
    try:
        warns = recipes.validate_and_lint(r)
    except recipes.RecipeError:
        return "rejected"
    return "spoof:%d" % sum(1 for w in warns if "spoofing" in w)

if op == "a2-v030-happy":
    print(vresult(a2_v030()))

elif op == "a1-still-valid":
    # R7: v0.2.0 a1 shape (no iteration, no emit_templates) still validates.
    with open(os.path.join(auto_root, "recipes", "a1.json")) as f:
        print(vresult(json.load(f)))

elif op == "w-still-valid":
    # R7: W recipe (no iteration, no emit_templates) still validates.
    with open(os.path.join(auto_root, "recipes", "w.json")) as f:
        print(vresult(json.load(f)))

elif op == "gate-unit-ghost":
    r = a2_v030()
    r["iteration"]["gate_unit"] = "ghost"
    print(vresult(r))

elif op == "emit-template-missing":
    r = a2_v030()
    r["iteration"]["emit_template"] = "does-not-exist"
    print(vresult(r))

elif op == "bound-negative":
    r = a2_v030()
    r["iteration"]["bound"]["max_attempts"] = -1
    print(vresult(r))

elif op == "bound-string":
    r = a2_v030()
    r["iteration"]["bound"]["max_attempts"] = "5"
    print(vresult(r))

elif op == "emit-template-phase-bad":
    r = a2_v030()
    r["emit_templates"]["plan-candidate"]["phase"] = "nonexistent"
    print(vresult(r))

elif op == "pairing-template-without-templates":
    # iteration.emit_template named but emit_templates ABSENT → must reject.
    # The round-3 P2 #21 relaxation only applies when iteration.emit_template
    # is ALSO absent (bare iteration: re-engage gate, no new siblings).
    r = a2_v030()
    del r["emit_templates"]
    # iteration.emit_template is "plan-candidate" — points at a now-missing key
    print(vresult(r))

elif op == "pairing-bare-iteration-valid":
    # Round-3 P2 #21 relaxation: iteration without emit_template is valid;
    # emit_templates may be absent too. Supports A4's "re-compare without new
    # candidates" use case.
    r = a2_v030()
    del r["emit_templates"]
    del r["iteration"]["emit_template"]
    print(vresult(r))

elif op == "bound-missing-max-attempts":
    r = a2_v030()
    del r["iteration"]["bound"]["max_attempts"]
    print(vresult(r))

elif op == "lint-max-attempts-loud":
    # Editorial — max_attempts = 15 > 10 → warning surface.
    r = a2_v030()
    r["iteration"]["bound"]["max_attempts"] = 15
    warns = recipes.validate_and_lint(r)
    print("warned" if any("max_attempts" in w for w in warns) else "no-warning")

elif op == "lint-max-wall-short":
    # Editorial — max_wall_seconds < 60 → warning surface.
    r = a2_v030()
    r["iteration"]["bound"]["max_wall_seconds"] = 30
    warns = recipes.validate_and_lint(r)
    print("warned" if any("max_wall_seconds" in w for w in warns) else "no-warning")

elif op == "u6-depends-on-id-prefix-valid":
    # v0.3.0 U6 (F4-tightened): a structural unit may forward-reference units
    # produced by an emit_template. With F4 SCHEMA TIGHTENING the recipe must
    # DECLARE the emitter-produced ids via `expected_emit_outputs` — they are
    # no longer accepted on prefix-match alone. A4's `compare` is the canonical
    # example: its depends_on names "build-clarity" and "build-perf"
    # (materialized by the bias-builder emit_template + the
    # plan_output_to_paired_builders phase-transition emitter). The validator
    # MUST accept this AFTER the recipe declares them in expected_emit_outputs.
    r = {
        "name": "u6-fwdref", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["build-clarity", "build-perf"],
             "invokes": {"adapter_op": "review"}}
        ],
        "expected_emit_outputs": ["build-clarity", "build-perf"],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "u6-depends-on-unrelated-rejected":
    # The carve-out is NARROW: depends_on must either reference an existing
    # unit id, an iterate-shaped id ({id_prefix}{positive_int}), or a member
    # of expected_emit_outputs. An unrelated string ("totally-unrelated")
    # still rejects — proving the carve-out is not a blanket "accept any
    # forward reference."
    r = {
        "name": "u6-bad", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["totally-unrelated"],
             "invokes": {"adapter_op": "review"}}
        ],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "f4-build-typo-rejected":
    # F4 DF control (a): the prior carve-out accepted ANY depends_on string
    # starting with an emit_template's id_prefix — `"build-typo"` would pass
    # against id_prefix `"build-"` even though no emitter would ever produce
    # `build-typo`. After F4 the validator requires either iterate-shape
    # ({id_prefix}{positive_int}) OR declaration in expected_emit_outputs.
    # `build-typo` matches NEITHER, so it must reject.
    r = {
        "name": "f4-typo", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["build-typo"],
             "invokes": {"adapter_op": "review"}}
        ],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "f4-iterate-shape-accepted":
    # F4 DF control (b): iterate-shape ids ({id_prefix}{positive_int}) are
    # plausibly produced by `iterate_template` (see lib/emitters.py: the emit
    # math is `f"{id_prefix}{base + i + 1}"`), so `build-1`, `build-7`, etc.
    # must validate WITHOUT requiring expected_emit_outputs.
    r = {
        "name": "f4-iterate", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["build-1", "build-2"],
             "invokes": {"adapter_op": "review"}}
        ],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "f4-bare-prefix-rejected":
    # F4 edge: the bare id_prefix string itself (`"build-"` with no suffix) is
    # NOT a valid iterate output (iterate emits `{id_prefix}{N}`, N >= 1), so
    # it must reject unless declared in expected_emit_outputs. Guards against
    # off-by-one in the iterate-shape check.
    r = {
        "name": "f4-bare", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["build-"],
             "invokes": {"adapter_op": "review"}}
        ],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "f4-eeo-rejects-non-list":
    # F4 shape: expected_emit_outputs must be a list of non-empty strings.
    r = {
        "name": "f4-eeo-bad", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [{"id": "plan", "phase": "plan", "invokes": {}}],
        "expected_emit_outputs": "build-clarity",  # str, not list
    }
    print(vresult(r))

elif op == "g3-doc-claim-parity-without-eeo":
    # G3 (API-R2-1): doc-claim ↔ validator-behavior parity check (§8 of
    # docs/contracts/recipe-format.md). The doc says depends_on members are
    # accepted iff (a) in units[], (b) iterate-shape, OR (c) in
    # expected_emit_outputs. Toggle pair: same recipe, depends_on names
    # `unicorn` (not in units[], not iterate-shape, NOT in EEO) → must reject.
    r = {
        "name": "g3-no-eeo", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["unicorn"],
             "invokes": {"adapter_op": "review"}}
        ],
        # NO expected_emit_outputs declared, and `unicorn` isn't iterate-shape
        # against any declared id_prefix.
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "g3-doc-claim-parity-with-eeo":
    # G3 (API-R2-1): same recipe as g3-doc-claim-parity-without-eeo BUT with
    # `unicorn` declared in expected_emit_outputs → must validate. Together
    # these two prove the third branch of the documented contract (§8) is
    # exactly what the validator enforces.
    r = {
        "name": "g3-with-eeo", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["unicorn"],
             "invokes": {"adapter_op": "review"}}
        ],
        "expected_emit_outputs": ["unicorn"],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "g1-isdigit-unicode-superscript":
    # G1 / ADV-R2-3: `_matches_iterate_shape` previously used
    # `suffix.isdigit() and int(suffix) >= 1`. The trap: `'²'.isdigit()` is
    # True but `int('²')` raises ValueError, so a depends_on of "build-²"
    # would crash the validator with an unhandled exception instead of
    # rejecting cleanly. G1 swaps isdigit→isdecimal: `'²'.isdecimal()` is
    # False, so "build-²" falls through to "not iterate-shaped" and the
    # validator rejects it via the existing unknown-unit path — same final
    # verdict the author intended.
    #
    # The DF revert (Edit isdecimal→isdigit in lib/recipes.py) shows the
    # un-fixed validator RAISES on this input (test goes RED with a
    # `raised:ValueError` shape instead of `rejected`).
    r = {
        "name": "g1-isdigit-trap", "version": "1",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "units": [
            {"id": "plan", "phase": "plan", "depends_on": [], "invokes": {}},
            {"id": "compare", "phase": "work",
             "depends_on": ["build-²"],  # 'build-²' — isdigit True, int raises
             "invokes": {"adapter_op": "review"}}
        ],
        "iteration": {"gate_unit": "compare", "emit_template": "bias-builder",
                      "bound": {"max_attempts": 4}},
        "emit_templates": {"bias-builder": {
            "phase": "work", "invokes": {"adapter_op": "do_unit"},
            "id_prefix": "build-"}}
    }
    print(vresult(r))

elif op == "verif-on-gate":
    # R3: verification on the iteration.gate_unit ("judge") → no warning.
    r = a2_v030()
    r["units"][3]["verification"] = [_verif()]  # index 3 is the "judge" gate unit
    print(lint_verif(r))

elif op == "verif-off-gate":
    # R3: verification on a non-gate unit (iteration present) → exactly one warning
    # naming the unit + the gate.
    r = a2_v030()
    r["units"][0]["verification"] = [_verif()]  # plan-1 is not the gate unit
    print(lint_verif(r))

elif op == "verif-no-iteration":
    # R3: verification present but NO iteration block at all → one warning
    # (criteria can never be evaluated). Drop iteration (emit_templates may stay —
    # the pairing rule is one-directional).
    r = a2_v030()
    del r["iteration"]
    r["units"][3]["verification"] = [_verif()]
    print(lint_verif(r))

elif op == "verif-two-off-gate":
    # R3: two non-gate units each carrying verification → one warning each.
    r = a2_v030()
    r["units"][0]["verification"] = [_verif()]  # plan-1
    r["units"][1]["verification"] = [_verif()]  # plan-2
    print(lint_verif(r))

elif op == "verif-none":
    # R3 control: no verification anywhere → no new warning. Proves the U2 block
    # is silent on the common (verification-free) recipe.
    print(lint_verif(a2_v030()))

elif op == "spoof-a1":
    # Regression guard: a workspace recipe copying a1's description verbatim is
    # flagged (a1 was in the old hardcoded tuple — must stay flagged).
    r = a2_v030()
    r["name"] = "a2-run-abc123"
    r["description"] = _builtin_desc("a1")
    print(spoof_result(r))

elif op == "spoof-pipeline":
    # NEW coverage (deliberate-fail on old code): pipeline was NOT in the old
    # ("a1","a2","a4","w") tuple, so copying its description was silently allowed.
    # The dynamic scan now flags it.
    r = a2_v030()
    r["name"] = "a2-run-abc123"
    r["description"] = _builtin_desc("pipeline")
    print(spoof_result(r))

elif op == "spoof-review":
    # NEW coverage (deliberate-fail on old code): review was also outside the old
    # tuple — now flagged by the dynamic scan.
    r = a2_v030()
    r["name"] = "a2-run-abc123"
    r["description"] = _builtin_desc("review")
    print(spoof_result(r))

elif op == "spoof-self-match":
    # Self-match exemption preserved: a recipe whose name equals the built-in whose
    # description it carries is NOT flagged (it IS that built-in, not a spoof).
    # Uses a newly-covered built-in (pipeline) to exercise the exemption on the
    # new scan path.
    r = a2_v030()
    r["name"] = "pipeline"
    r["description"] = _builtin_desc("pipeline")
    print(spoof_result(r))

elif op == "spoof-builtins-clean":
    # R2 regression guard: widening the reference set to all six built-ins must not
    # make any shipped built-in spoof-warn against another (their descriptions are
    # distinct). Each built-in validated against itself → spoof:0.
    bad = []
    for nm in ("a1", "a2", "a4", "w", "pipeline", "review"):
        with open(os.path.join(auto_root, "recipes", nm + ".json")) as f:
            res = spoof_result(json.load(f))
        if res != "spoof:0":
            bad.append(nm + "=" + res)
    print("clean" if not bad else "dirty:" + ",".join(bad))
PYEOF
}

it "U5 happy path: full A2 v0.3.0 recipe (iteration + emit_templates) validates"
assert_eq "valid" "$(itr a2-v030-happy)"

it "U5 R7: a1 (no iteration, no emit_templates) still validates"
assert_eq "valid" "$(itr a1-still-valid)"

it "U5 R7: W (no iteration, no emit_templates) still validates"
assert_eq "valid" "$(itr w-still-valid)"

it "U5 error: iteration.gate_unit references nonexistent unit ('ghost') → rejected"
assert_eq "rejected" "$(itr gate-unit-ghost)"

it "U5 error: iteration.emit_template references missing template key → rejected"
assert_eq "rejected" "$(itr emit-template-missing)"

it "U5 error: iteration.bound.max_attempts = -1 → rejected"
assert_eq "rejected" "$(itr bound-negative)"

it "U5 error: iteration.bound.max_attempts = '5' (string) → rejected"
assert_eq "rejected" "$(itr bound-string)"

it "U5 error: emit_templates.<x>.phase not in phase_order → rejected"
assert_eq "rejected" "$(itr emit-template-phase-bad)"

it "U5 error: iteration.emit_template present but emit_templates absent → rejected (pairing)"
assert_eq "rejected" "$(itr pairing-template-without-templates)"

it "U5 relaxed pairing: bare iteration (no emit_template, no emit_templates) → valid"
assert_eq "valid" "$(itr pairing-bare-iteration-valid)"

it "U5 error: iteration.bound missing max_attempts (required) → rejected"
assert_eq "rejected" "$(itr bound-missing-max-attempts)"

it "U5 editorial: validate_and_lint warns on max_attempts > 10"
assert_eq "warned" "$(itr lint-max-attempts-loud)"

it "U5 editorial: validate_and_lint warns on max_wall_seconds < 60"
assert_eq "warned" "$(itr lint-max-wall-short)"

# ── v0.3.0 U6: depends_on may forward-reference emit_template id_prefixes ──
# This carve-out (mirror of the gate_unit carve-out) is mandated by U6's
# "compare is structural" contract — A4's `compare` declares
# depends_on: [build-clarity, build-perf] in units[], but those concrete ids
# don't exist at validate-time; they're materialized by the bias-builder
# emit_template (id_prefix "build-").
it "U6 carve-out: depends_on forward-refs an emit_template id_prefix → valid"
assert_eq "valid" "$(itr u6-depends-on-id-prefix-valid)"

it "U6 carve-out is narrow: unrelated depends_on id still rejects"
assert_eq "rejected" "$(itr u6-depends-on-unrelated-rejected)"

# ── v0.3.0 F4: depends_on carve-out tightened (ADV-2 + maint-4) ─────────────
# The prior carve-out accepted ANY depends_on string starting with an
# emit_template id_prefix — `"build-typo"` would pass against id_prefix
# `"build-"`. F4 narrows to: in units[], OR iterate-shape ({id_prefix}{N}),
# OR explicitly declared in expected_emit_outputs.
#
# DF rationale (memory feedback_new_tests_need_deliberate_fail_smoke_check):
# we proved these tests are real by widening the validator (adding
# `"build-typo"` to a4.json's expected_emit_outputs) and confirming RED, then
# restoring. Without the DF the green here proves nothing.
it "F4 (DF-a): build-typo in depends_on rejected — loose prefix-match closed"
assert_eq "rejected" "$(itr f4-build-typo-rejected)"

it "F4 (DF-b): build-1 iterate-shape id accepted without expected_emit_outputs"
assert_eq "valid" "$(itr f4-iterate-shape-accepted)"

it "F4 edge: bare id_prefix 'build-' (no suffix) rejects unless declared"
assert_eq "rejected" "$(itr f4-bare-prefix-rejected)"

it "F4 shape: expected_emit_outputs must be a list of non-empty strings"
assert_eq "rejected" "$(itr f4-eeo-rejects-non-list)"

# ── G3 (API-R2-1): doc-claim ↔ validator-behavior parity check ─────────────
# docs/contracts/recipe-format.md §8 documents `expected_emit_outputs`. The
# doc claims depends_on members are accepted iff (a) in units[], (b)
# iterate-shape, OR (c) in expected_emit_outputs. These two tests are a
# toggle pair on branch (c) — same recipe, only `expected_emit_outputs`
# differs. If the doc and validator ever drift on this contract, one of
# these will flip.
#
# DF rationale (memory feedback_new_tests_need_deliberate_fail_smoke_check):
# we proved this test is real by commenting out the `if d in
# expected_emit_outputs_set: continue` lines in lib/recipes.py via Edit and
# observing the g3-doc-claim-parity-with-eeo case flip from valid → rejected
# (red), then restoring. Without the DF the green here proves nothing.
it "G3 doc-parity (§8): depends_on='unicorn' without expected_emit_outputs → rejected"
assert_eq "rejected" "$(itr g3-doc-claim-parity-without-eeo)"

it "G3 doc-parity (§8): depends_on='unicorn' WITH expected_emit_outputs → valid"
assert_eq "valid" "$(itr g3-doc-claim-parity-with-eeo)"

# ── v0.3.0 G1 / ADV-R2-3: isdigit() Unicode trap closed ────────────────────
# `_matches_iterate_shape` previously called `suffix.isdigit()` then
# `int(suffix)`. `'²'.isdigit()` is True but `int('²')` raises ValueError —
# an author-crafted depends_on of "build-²" would crash the validator
# (unhandled ValueError escapes through `validate` → caller). G1 uses
# `isdecimal()` which matches exactly the chars `int()` accepts, so
# "build-²" is treated as not-iterate-shaped and rejected via the standard
# unknown-unit path (i.e. with a RecipeError, not a ValueError).
#
# DF-verified (commit message): with the production fix reverted
# (isdecimal → isdigit), this test fails RED — vresult returns a
# non-"rejected" value because the underlying `int(suffix)` raises
# ValueError, which vresult only handles for RecipeError.
it "G1 / ADV-R2-3: depends_on 'build-²' rejects cleanly (no isdigit/int Unicode crash)"
assert_eq "rejected" "$(itr g1-isdigit-unicode-superscript)"

# ── v0.7.0 U2 (R3): verification must live on the iteration.gate_unit ────────
# validate() accepts `verification` on any unit (additive, load must still
# succeed), but only the gate unit's block is evaluated. validate_and_lint warns
# when a non-empty block sits off the gate, or when there's no iteration block at
# all (criteria can never be evaluated). The "valid:N" prefix on each case also
# asserts validate() still passes (R3).
it "U2: verification on the gate unit (iteration present) → no warning"
assert_eq "valid:0" "$(itr verif-on-gate)"

it "U2: verification on a non-gate unit (iteration present) → one warning"
assert_eq "valid:1" "$(itr verif-off-gate)"

it "U2: verification present but no iteration block → one warning (never evaluated)"
assert_eq "valid:1" "$(itr verif-no-iteration)"

it "U2: two non-gate units with verification → one warning each"
assert_eq "valid:2" "$(itr verif-two-off-gate)"

it "U2: no verification anywhere → no new warning"
assert_eq "valid:0" "$(itr verif-none)"

# ── U2 (this unit): description-spoofing guard scans ALL built-ins ────────────
# The guard used to loop a stale ("a1","a2","a4","w") tuple, silently missing the
# pipeline/review built-ins. It now scans recipes/ dynamically. The pipeline and
# review cases below are the deliberate-fail proof: they return spoof:0 (✗) on the
# pre-change tuple and spoof:1 (✓) after the fix, while spoof-a1 stays ✓ on both.
it "U2: workspace recipe copying a1's description verbatim → flagged (regression)"
assert_eq "spoof:1" "$(itr spoof-a1)"

it "U2: workspace recipe copying pipeline's description verbatim → flagged (new)"
assert_eq "spoof:1" "$(itr spoof-pipeline)"

it "U2: workspace recipe copying review's description verbatim → flagged (new)"
assert_eq "spoof:1" "$(itr spoof-review)"

it "U2: recipe whose name equals the matched built-in → not flagged (self-match)"
assert_eq "spoof:0" "$(itr spoof-self-match)"

it "U2: all six shipped built-ins stay spoof-warning-free under the widened scan"
assert_eq "clean" "$(itr spoof-builtins-clean)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
