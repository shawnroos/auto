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

it "reserved python_hook accepted (R3)"
assert_eq "valid" "$(rec validate-json '{"name":"x","version":"1","units":[],"python_hook":"x"}')"

it "non-default phase_order (A3 grammar) rejected in V1"
assert_eq "rejected" "$(rec validate-json '{"name":"a3","version":"1","phase_order":["work_sketch","review","plan","work_refine"],"terminal_phase":"work_refine","units":[]}')"

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

it "list_available in a fresh repo → exactly the built-ins (a1/a2/a4/w)"
assert_eq "a1,a2,a4,w" "$(reg list-fresh)"

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

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
