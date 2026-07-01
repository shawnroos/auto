#!/usr/bin/env bash
# auto launch-chooser U7: AE1–AE6 acceptance harness (end-to-end).
#
# Maps the six Acceptance Examples onto the REAL deterministic seams the launch
# chooser drives — `lib/launch-gate.py::classify_launch` (the tier), the in-tree
# router `lib/recommender.py::recommend` (the agreement cross-check), the one
# renderer `lib/topology-render.py::render_comparison` (the contrast block), and
# the `lib/recipes.py` validate/resolve write-gate (the run-scoped variant). A
# live `AskUserQuestion` can't run headless, so the chooser is exercised at its
# deterministic boundaries: each AE feeds fixed inputs, reads the tier, and
# asserts the *dispatch shape that tier implies* (skip ⇒ a1/w no-compile, no
# workspace recipe; two_step+gated ⇒ the a2/a4 variant compiles+validates+
# resolves at `workspace`; custom ⇒ two_step + validates). That tier→dispatch
# chaining is what makes this acceptance-level rather than a restatement of the
# U2 ladder / U5 compile unit tests.
#
# The two scenarios with NO executable seam — AE6's "silent-apply by
# construction" and the freeform "not /ce-plan-and-end" replacement — are the
# only grep-asserted checks (the chooser prose itself is asserted in U3/U4).
#
# SELF-CONTAINED inline harness (same style as launch-recipe-compile.test.sh):
# its own it/pass/fail/assert helpers + HOME/sandbox isolation. HOME is moved to
# the sandbox so resolve()'s GLOBAL tier (~/.claude/auto/recipes) can't leak the
# operator's real recipes; the workspace tier lives under a mktemp repo so any
# teardown `rm` stays inside ephemeral $TMPDIR.
#
# Scenarios (mapped to the U7 plan's Test scenarios):
#   AE1  typo-fix → skip; router agrees on a1; a1 no-compile (no workspace recipe);
#        notice names the a1 exit predicate, not a literal programmatic check.
#   AE2  reviewed-plan → skip; router agrees on w@work; w no-compile.
#   AE3  design-task → two_step; a2 + advisor_judge compiles+validates+resolves
#        at workspace, gate_unit `judge` carries the verification; contrast block
#        marks a2.
#   AE4  no-built-in-fits → two_step (custom rule 1); custom spike-before-build
#        validates and renders; contrast block marks the custom.
#   AE5  shape override a2→a4 → a4-<slug> compiles, gate_unit `compare` (distinct
#        from a2's `judge`), resolves at workspace.
#   AE6  self-driven/headless ownership signal → silent-apply by construction,
#        no question path (asserts the entry guard prose, the only headless seam).
#   single-confirm  (0.85,0.70,builtin,[],True) → confirm; contrast block prints
#        the a1 card; router agrees.
#   freeform behavior change  clear-intent-no-plan → a1@plan (the loop dispatch
#        that replaces the old /ce-plan-and-end route).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
GATE="${AUTO_ROOT}/lib/launch-gate.py"
LAUNCH_SKILL="${AUTO_ROOT}/skills/auto-launch/SKILL.md"
DRIVER_SKILL="${AUTO_ROOT}/skills/auto-driver/SKILL.md"

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
# assert_in <value> <allowed...>: pass iff value matches one of the allowed set.
assert_in() {
  local val="$1"; shift
  local a
  for a in "$@"; do
    if [ "$val" = "$a" ]; then pass; return 0; fi
  done
  fail "got '$val', expected one of: $*"
}
# assert_contains <haystack> <needle>: pass iff needle is a substring of haystack.
assert_contains() {
  case "$1" in
    *"$2"*) pass ;;
    *) fail "expected to find '$2'" ;;
  esac
}

# assert_not_contains <haystack> <needle>: pass iff needle is ABSENT.
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected NOT to find '$2'" ;;
    *) pass ;;
  esac
}

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

# field <key> <"k=v k=v ..."> — extract the value for key= from a token line.
# Used only for SPACE-FREE token lines (the gate/recommender ops). Render output
# (full of spaces + newlines) NEVER rides this line — those ops emit one
# comma-joined string asserted whole, U1-style.
field() {
  local key="$1"; shift
  printf '%s\n' "$*" | tr ' ' '\n' | sed -n "s/^${key}=//p"
}

# ── tier helper: drive the launch-gate CLI, print just the tier. ───────────
# tier <shape> <gates> <recipe_kind> <gate_types_csv> <router_agrees>
tier() {
  "$PY" "$GATE" "$1" "$2" "$3" "$4" "$5" \
    | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["tier"])'
}

# ── router helper: the in-tree recommender's pick for a state label. ───────
# Prints "<recipe_or_entry> <entry> <kind>" — the deterministic agreement
# cross-check classify_launch's `router_agrees` is derived from.
router() {
  "$PY" "${AUTO_ROOT}/lib/recommender.py" "$1" \
    | "$PY" -c 'import sys,json; r=json.load(sys.stdin); print(r["recipe_or_entry"], r["entry"], r["kind"])'
}

# ── drv: load the real libs via _bootstrap and run one op. ─────────────────
# Compile/validate/resolve/render ops. Render ops emit a single comma-joined
# string (no spaces inside the asserted value); compile/resolve ops emit
# space-free key=value tokens.
drv() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<'PYEOF'
import sys, os, json, tempfile

auto_root, repo = sys.argv[1], sys.argv[2]
op = sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module

recipes = load_lib_module("recipes")
tr = load_lib_module("topology-render")
BUILTIN_DIR = os.path.join(auto_root, "recipes")
WS = os.path.join(repo, ".claude", "auto", "recipes")
MARK = "► recommended"


def load_builtin(name):
    with open(os.path.join(BUILTIN_DIR, name + ".json")) as f:
        return json.load(f)


def atomic_write(path, recipe):
    """mkstemp + os.rename — the auto-author-recipe write discipline."""
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


def builtin_variant(builtin, slug, *, description):
    """A run-scoped variant of a gated built-in (a2/a4): distinct stem, the
    operator's typed gate attached to the built-in's OWN declared gate_unit."""
    r = load_builtin(builtin)
    r["name"] = builtin + "-" + slug
    r["description"] = description
    gate_unit = r["iteration"]["gate_unit"]
    for u in r["units"]:
        if u["id"] == gate_unit:
            u["verification"] = [
                {"id": "design-sound", "type": "advisor_judge",
                 "rubric_ref": "verification-rubric"}
            ]
    return r


def custom_spike(slug):
    """A custom spike-before-build loop that fits no built-in (AE4): a
    programmatic spike gate the four built-ins don't express."""
    return {
        "name": "spike-" + slug,
        "version": "1",
        "description": "Custom spike-before-build loop (U7 acceptance provenance).",
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


def vresult(d):
    try:
        recipes.validate(d); return "valid"
    except recipes.RecipeError:
        return "rejected"


def compile_variant(builtin, slug):
    """Build a run-scoped variant, run the REAL write gate, write atomically to
    the workspace tier, read it back, resolve the variant and the built-in."""
    draft = builtin_variant(
        builtin, slug,
        description=f"Run-scoped {builtin} variant for the U7 {slug} run (launch-compile).")
    path = os.path.join(WS, draft["name"] + ".json")
    warnings = recipes.validate_and_lint(draft, filename=path)
    atomic_write(path, draft)
    rb, _ = recipes.load_and_validate(draft["name"], repo)   # raises on bad read-back
    _, vtier = recipes.resolve(draft["name"], repo)
    _, btier = recipes.resolve(builtin, repo)
    gate = rb["iteration"]["gate_unit"]
    gate_has_verif = any(u["id"] == gate and u.get("verification") for u in rb["units"])
    return {
        "warnings": len(warnings), "readback": "valid",
        "resolve_variant": vtier, "resolve_builtin": btier,
        "gate_unit": gate, "gate_has_verif": int(bool(gate_has_verif)),
        "stem": draft["name"],
    }


if op == "ae3-compile-a2":
    r = compile_variant("a2", sys.argv[4])
    print("warnings={warnings} readback={readback} resolve_variant={resolve_variant} "
          "resolve_builtin={resolve_builtin} gate_unit={gate_unit} "
          "gate_has_verif={gate_has_verif} stem={stem}".format(**r))

elif op == "ae3-render":
    # The contrast block marks the recommended a2 among [a2, a4] (one renderer).
    out = tr.render_comparison([load_builtin("a2"), load_builtin("a4")], highlight="a2")
    lines = out.splitlines()
    idx = lines.index(MARK) if MARK in lines else -1
    after = lines[idx + 1] if 0 <= idx and idx + 1 < len(lines) else ""
    print("markers=%d|after=%s" % (out.count(MARK), after))

elif op == "ae4-custom":
    # Custom validates, renders (smoke — render may read fields validate doesn't
    # enforce), and is the highlighted card among [a1, custom].
    custom = custom_spike(sys.argv[4])
    valid = vresult(custom)
    out = tr.render_comparison([load_builtin("a1"), custom], highlight=custom["name"])
    lines = out.splitlines()
    idx = lines.index(MARK) if MARK in lines else -1
    after = lines[idx + 1] if 0 <= idx and idx + 1 < len(lines) else ""
    has_custom_header = ("recipe: " + custom["name"]) in out
    print("valid=%s|markers=%d|after=%s|customhdr=%s"
          % (valid, out.count(MARK), after, has_custom_header))

elif op == "ae5-override-a4":
    # Shape override a2→a4: the compiled variant is a4-<slug>, gate_unit `compare`
    # — distinct from a2's `judge` (the dispatch shape differs by construction).
    a4 = compile_variant("a4", sys.argv[4])
    a2_gate = load_builtin("a2")["iteration"]["gate_unit"]
    print("resolve_variant={resolve_variant} gate_unit={gate_unit} "
          "gate_has_verif={gate_has_verif} stem={stem}".format(**a4)
          + " a2_gate=%s differs=%s" % (a2_gate, int(a4["gate_unit"] != a2_gate)))

elif op == "ae1ae2-nocompile":
    # a1/w declare NO iteration block → nothing to attach a typed gate to → the
    # no-compile branch (KTD-4): skip dispatches the built-in directly, no
    # workspace recipe is written.
    a1 = load_builtin("a1"); w = load_builtin("w")
    print("a1_iter=%d w_iter=%d a1_gate=%s w_gate=%s"
          % (int("iteration" in a1), int("iteration" in w),
             a1.get("iteration", {}).get("gate_unit", "none"),
             w.get("iteration", {}).get("gate_unit", "none")))

elif op == "confirm-render":
    # Single-confirm tier still prints the contrast block (one card here).
    out = tr.render_comparison([load_builtin("a1")])
    has_a1 = "recipe: a1" in out
    print("a1hdr=%s|markers=%d|nonempty=%s"
          % (has_a1, out.count(MARK), int(len(out.strip()) > 0)))

elif op == "ws-residue":
    # Net workspace-tier residue check used by the AE1/AE2 no-compile assertion:
    # the skip path writes nothing to .claude/auto/recipes.
    n = len(os.listdir(WS)) if os.path.isdir(WS) else 0
    print("ws_files=%d" % n)

else:
    print("unknown-op=%s" % op)
PYEOF
}

echo "launch-chooser (U7 AE1–AE6 acceptance harness)"

# ════════════════════════════════════════════════════════════════════════════
# AE1 — typo fix: a1 with a tests-pass-ish gate is obvious → skip, a1 notice.
#   Covers R8, R9, R10. router agrees on a1 (the skip cross-check); a1 takes the
#   no-compile branch (no iteration gate_unit), so skip dispatches the built-in.
# ════════════════════════════════════════════════════════════════════════════
it "AE1: typo-fix (0.95,0.95,builtin,[],True) → skip"
AE1_TIER="$(tier 0.95 0.95 builtin "" true)"
assert_eq "skip" "$AE1_TIER"

it "AE1: the router (recommender) picks a1 for clear-intent-no-plan → router_agrees is real, not asserted"
A1_ROUTER="$(router clear-intent-no-plan)"
assert_eq "a1 plan recipe" "$A1_ROUTER"

it "AE1: a1 takes the no-compile branch — no declared iteration gate_unit (skip ⇒ dispatch built-in)"
NC="$(drv ae1ae2-nocompile)"
assert_eq "none" "$(field a1_gate "$NC")"

it "AE1: the a1 skip notice names the review-to-P3 exit predicate, not a literal programmatic check (KTD-4)"
# The R9 notice for a1/w is the inherent exit predicate, surfaced for visibility —
# the only headless surface is the SKILL prose that defines it. (Executable seam
# is the skip tier above; this pins the notice CLAIM to the real file.)
assert_contains "$(cat "$LAUNCH_SKILL")" "review-clean to P3"

# ════════════════════════════════════════════════════════════════════════════
# AE2 — reviewed plan with standard gating → skip with a one-line `w` notice
#   (rather than the current silent route). Covers R8, R9.
# ════════════════════════════════════════════════════════════════════════════
it "AE2: reviewed-plan (0.9,0.88,builtin,[],True) → skip"
assert_eq "skip" "$(tier 0.9 0.88 builtin "" true)"

it "AE2: the router picks w@work for reviewed-plan → router_agrees is real"
assert_eq "w work recipe" "$(router reviewed-plan)"

it "AE2: w takes the no-compile branch — no declared iteration gate_unit"
assert_eq "none" "$(field w_gate "$NC")"

# ════════════════════════════════════════════════════════════════════════════
# AE3 — high-uncertainty design task → two_step; a2 with an advisor_judge gate
#   compiles + validates + resolves at workspace, gate_unit `judge` carries the
#   verification. Covers R5, R6, R7, R8.
# ════════════════════════════════════════════════════════════════════════════
it "AE3: design-task (0.7,0.6,builtin,[advisor_judge],True) → two_step (judge gate forbids skip)"
assert_eq "two_step" "$(tier 0.7 0.6 builtin advisor_judge true)"

AE3="$(drv ae3-compile-a2 design)"
it "AE3: the a2+advisor_judge variant passes the validate_and_lint write gate (0 blocking warnings, distinct desc)"
assert_eq "0" "$(field warnings "$AE3")"
it "AE3: read-back load_and_validate accepts the compiled a2 variant"
assert_eq "valid" "$(field readback "$AE3")"
it "AE3: resolve('a2-design') returns the variant at tier workspace (wins over the built-in)"
assert_eq "workspace" "$(field resolve_variant "$AE3")"
it "AE3: the canonical built-in a2 stays built-in (the variant does not shadow it)"
assert_eq "built-in" "$(field resolve_builtin "$AE3")"
it "AE3: the verification rides a2's declared gate_unit 'judge'"
assert_eq "judge" "$(field gate_unit "$AE3")"
it "AE3: the gate unit carries the operator-edited advisor_judge verification array"
assert_eq "1" "$(field gate_has_verif "$AE3")"

it "AE3: the contrast block marks exactly the recommended a2 card (one renderer)"
assert_eq "markers=1|after=recipe: a2" "$(drv ae3-render)"

# ════════════════════════════════════════════════════════════════════════════
# AE4 — work that fits no built-in → a custom spike-before-build loop is composed,
#   validates before being offered, and is the highlighted step-1 card.
#   Covers R4, R6. classify_launch → two_step by rule 1 (custom never skips).
# ════════════════════════════════════════════════════════════════════════════
it "AE4: custom recipe (0.9,0.9,custom,[],True) → two_step (rule 1, R4 — always drawn)"
assert_eq "two_step" "$(tier 0.9 0.9 custom "" true)"

AE4="$(drv ae4-custom spike)"
it "AE4: the composed custom spike-before-build loop validates before it is offered (R4)"
assert_eq "valid" "$(printf '%s' "$AE4" | cut -d'|' -f1 | sed 's/valid=//')"
it "AE4: the custom card renders and is the highlighted step-1 option, marked exactly once"
# Whole comma/pipe-joined string asserted (render output kept off the token line).
assert_eq "valid=valid|markers=1|after=recipe: spike-spike|customhdr=True" "$AE4"

# ════════════════════════════════════════════════════════════════════════════
# AE5 — the operator overrides the recommended a2 and picks a4 at step 1 → the
#   compiled run-scoped recipe is a4-<slug>, gate_unit `compare` (NOT a2's
#   `judge`): the dispatch shape is re-derived for a4. Covers R7.
#   (The R7 re-derivation logic itself is U3/U4 prose; U7 proves the a4 dispatch
#   shape is distinct from a2's by the gate_unit the compiled recipe carries.)
# ════════════════════════════════════════════════════════════════════════════
AE5="$(drv ae5-override-a4 override)"
it "AE5: the a4 override variant resolves at tier workspace"
assert_eq "workspace" "$(field resolve_variant "$AE5")"
it "AE5: the a4 variant's gate rides a4's declared gate_unit 'compare'"
assert_eq "compare" "$(field gate_unit "$AE5")"
it "AE5: a4's gate_unit differs from a2's 'judge' (gates re-derived for a4, not a2)"
assert_eq "1" "$(field differs "$AE5")"
it "AE5: the a4 variant carries the typed verification array"
assert_eq "1" "$(field gate_has_verif "$AE5")"

# ════════════════════════════════════════════════════════════════════════════
# AE6 — a self-driven / headless run → no chooser; the recommendation is applied
#   silently. Covers R11. The "silent-apply by construction" guard has no
#   executable seam (no live AskUserQuestion headless), so this asserts the entry
#   guard prose that routes self-driven runs out of the question path.
# ════════════════════════════════════════════════════════════════════════════
LAUNCH_TXT="$(cat "$LAUNCH_SKILL")"
it "AE6: the launch skill gates on driving_session_id at entry (interactive-only by construction)"
assert_contains "$LAUNCH_TXT" "driving_session_id"
it "AE6: a self-driven / headless run silent-applies by construction"
assert_contains "$LAUNCH_TXT" "silent-apply by construction"
it "AE6: the entry guard states self-driven runs never reach AskUserQuestion (R11)"
assert_contains "$LAUNCH_TXT" "never call \`AskUserQuestion\`"
it "AE6: the driver's reviewed-plan row gates on driving_session_id (self-driven silent-applies)"
assert_contains "$(cat "$DRIVER_SKILL")" "self-driven silent-applies"

# ════════════════════════════════════════════════════════════════════════════
# Single-confirm tier (R8 middle rung) — builtin a1 with one dimension at
#   SKIP_BAR and the other at CONFIRM_BAR, router agreeing → confirm; the
#   render_comparison block prints (and dispatch fires on confirm).
# ════════════════════════════════════════════════════════════════════════════
it "single-confirm: (0.85,0.70,builtin,[],True) → confirm (one dim at SKIP_BAR, one at CONFIRM_BAR)"
assert_eq "confirm" "$(tier 0.85 0.70 builtin "" true)"
it "single-confirm: the confirm tier still prints the render_comparison contrast block (a1 card present)"
assert_eq "a1hdr=True|markers=0|nonempty=1" "$(drv confirm-render)"
it "single-confirm: the router agrees on a1 (the confirm path's settled shape)"
assert_eq "a1 plan recipe" "$(router clear-intent-no-plan)"

# ════════════════════════════════════════════════════════════════════════════
# Freeform behavior change — a freeform non-plan `/auto <sentence>` classifies to
#   clear-intent-no-plan → recommends a1@plan and enters the chooser, REPLACING
#   the old bare `/ce-plan`-and-end route (KTD-5 intended behavior change).
# ════════════════════════════════════════════════════════════════════════════
it "freeform: clear-intent-no-plan routes to the a1 plan-loop @ entry phase plan (a real loop dispatch, not a skill)"
assert_eq "a1 plan recipe" "$(router clear-intent-no-plan)"
it "freeform: the driver runs the auto-launch chooser on freeform intent instead of /ce-plan-and-end (KTD-5)"
# Scope the assertions to the FREEFORM block specifically (not anywhere in the
# 70-line file): extract the "Argument-aware freeform" paragraph and assert the
# chooser hop is wired on THAT branch — a file-wide grep would pass even if the
# auto-launch hop moved off the freeform row.
FREEFORM_BLOCK="$(awk '/Argument-aware freeform/{f=1} f{print} f&&NR>1&&/^$/{exit}' "$DRIVER_SKILL")"
assert_contains "$FREEFORM_BLOCK" "auto-launch"
assert_contains "$FREEFORM_BLOCK" "clear-intent-no-plan"
# Regression guard for the replaced route: the OLD freeform behavior was "invoke
# /ce-plan ... and end the turn". The block may still NAME /ce-plan (to say it
# replaced it), so guard on the old terminal action phrase instead — if someone
# reinstates the /ce-plan-and-end route on this branch, "end the turn" returns.
assert_not_contains "$FREEFORM_BLOCK" "end the turn"

# ── No-compile residue: the skip path (AE1/AE2) wrote nothing to the workspace
#    tier. Only the AE3/AE4/AE5 two_step compile ops write; skip never does. ──
it "skip dispatch shape: AE1/AE2 a1/w never wrote a workspace recipe (the gated AEs did)"
# After all ops: the workspace tier holds only the compiled two_step variants
# (a2-design, a4-override) — never an a1/w one. Assert no a1-/w- stem leaked.
WS_LEAK="$(ls "${WORKSPACE_RECIPES}" 2>/dev/null | grep -cE '^(a1|w)-' || true)"
assert_eq "0" "$WS_LEAK"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "launch-chooser.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
