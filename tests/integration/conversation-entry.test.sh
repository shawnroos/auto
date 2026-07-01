#!/usr/bin/env bash
# auto v0.6.0 integration test: conversation-driven smart entry (U1-U3).
#
# Exercises the REAL lib/auto-detect.sh (.sh shim) + the REAL lib/recommender.py
# (via _bootstrap.load_lib_module) — the surfaces the auto-driver skill consumes
# when bare /auto fires after a rich conversation. Nothing is mocked: the
# detector runs as a subprocess and the recommender is the production module.
#
# SELF-CONTAINED inline harness mirroring tests/integration/hooks.test.sh and
# the run.sh summary-line format ("<name>.test.sh: N passed, M failed").
#
# Scenarios:
#   U1 — detector / envelope:
#     1. signal SET + no run + no plan -> situation=conversation-context
#     2. conversation-context envelope carries ALL nine canonical keys
#     3. conversation-context recommendation is null (driver fills it, not detect)
#     4. signal UNSET -> falls through to raw (existing situation), byte-unchanged
#        in the existing-field subset; recommendation present + null on raw too
#     5. recommendation present on EVERY path incl. the catastrophic-error fallback
#     6. signal SET but a plan exists -> reviewed-plan still wins (no override)
#     7. signal SET but an in-flight run exists -> in-flight still wins
#     8. READ-ONLY: detector writes nothing (hash .claude/auto + worktree
#        before/after, signal SET)
#     9. exit 0 on the conversation-context path AND on a forced internal error
#   U2 — recommender taxonomy:
#    10. each taxonomy row maps to its expected (step, recipe/entry, is_spine, kind)
#    11. off-spine states never return a spine recipe or an auto-advance entry
#    12. low confidence below threshold sets escalate=True (known state)
#    13. unknown / non-string state degrades to a safe escalate default, no crash
#    14. confident known spine state does NOT escalate

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DET="${AUTO_ROOT}/lib/auto-detect.sh"
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
SANDBOX="$(mktemp -d -t auto-conv-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-conv-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
# Make a fresh sandbox repo with .claude/auto present, echo its path.
mkrepo() {
  local repo="${SANDBOX}/repo-${1}"
  mkdir -p "${repo}/.claude/auto"
  printf '%s' "$repo"
}

# Run the detector against $1 (repo) with optional signal env (arg2 nonempty
# sets CLAUDE_AUTO_CONVERSATION_SIGNAL); print the raw JSON line.
detect() {
  local repo="$1" signal="${2:-}"
  if [ -n "$signal" ]; then
    CLAUDE_AUTO_REPO="$repo" CLAUDE_AUTO_CONVERSATION_SIGNAL=1 bash "$DET"
  else
    CLAUDE_AUTO_REPO="$repo" bash "$DET"
  fi
}

# Extract a python-eval expr (var H = the parsed envelope) from a raw JSON line.
hfield() {
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

# Run a recommender op via the production module loader; print one line.
rec() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
recommender = load_lib_module("recommender")
op = sys.argv[2]

if op == "row":
    # row <state> -> "step|recipe_or_entry|entry|is_spine|kind|escalate"
    r = recommender.recommend(sys.argv[3], 1.0)
    print("%s|%s|%s|%s|%s|%s" % (
        r["ce_step"], r["recipe_or_entry"], r["entry"],
        r["is_spine"], r["kind"], r["escalate"]))
elif op == "escalate":
    # escalate <state> <confidence> -> True/False
    r = recommender.recommend(sys.argv[3], float(sys.argv[4]))
    print("True" if r["escalate"] else "False")
elif op == "unknown":
    # unknown <state-or-NONE> -> "state|escalate|recipe_or_entry|is_spine"
    state = None if sys.argv[3] == "NONE" else sys.argv[3]
    r = recommender.recommend(state, 1.0)
    print("%s|%s|%s|%s" % (
        r["state"], r["escalate"], r["recipe_or_entry"], r["is_spine"]))
elif op == "offspine-safe":
    # No off-spine row may return is_spine=True; none may carry an entry on a
    # skill rec. Returns "ok" iff every off-spine row honours the invariant.
    bad = []
    for st in ("code-unreviewed", "bug", "what-to-improve", "perf"):
        r = recommender.recommend(st, 1.0)
        if r["is_spine"]:
            bad.append(st + ":spine")
        if r["kind"] == recommender.KIND_SKILL and r["entry"] is not None:
            bad.append(st + ":entry")
    print("ok" if not bad else ",".join(bad))
PYEOF
}

echo "conversation-entry.test.sh"

# ── Scenario setups ─────────────────────────────────────────────────────────
setup_plan() {
  mkdir -p "$1/docs/plans"
  echo "# Build the widget" > "$1/docs/plans/widget-plan.md"
}
setup_inflight() {
  cat > "$1/.claude/auto/runA.json" <<'EOF'
{"run_id":"runA","exit_predicate_result":{"met":false},"goal_intent":"Ship it"}
EOF
}

# A git repo whose docs/plans/ holds only STALE (old-committed) plans. Used for
# the U3 preemption scenarios: a rich conversation must beat this stale set.
mkrepo_stale_plans() {
  local repo="${SANDBOX}/repo-$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  (
    cd "$repo"
    git init -q .; git config user.email t@t; git config user.name t
    printf '.claude/\n' > .gitignore
    echo "# s1" > docs/plans/s1-plan.md
    echo "# s2" > docs/plans/s2-plan.md
    git add -A
    GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
      git -c commit.gpgsign=false commit -q -m stale
  ) >/dev/null 2>&1
  printf '%s' "$repo"
}

# Same, plus one uncommitted (FRESH) plan — a live plan must beat conversation.
mkrepo_fresh_among_stale() {
  local repo; repo="$(mkrepo_stale_plans "$1")"
  echo "# live" > "$repo/docs/plans/z-live-plan.md"   # uncommitted → fresh
  printf '%s' "$repo"
}

# ════════════════════════════════════════════════════════════════════════════
# U1 — detector / envelope
# ════════════════════════════════════════════════════════════════════════════

# ─── Scenario 1: signal SET + no run + no plan -> conversation-context ────────
it "U1: signal SET + no run + no plan -> situation=conversation-context"
REPO="$(mkrepo conv)"
RAW="$(detect "$REPO" signal)"
assert_eq "conversation-context" "$(hfield "$RAW" 'H["situation"]')"

# ─── Scenario 2: envelope carries all nine canonical keys ─────────────────────
it "U1: conversation-context envelope has all nine canonical keys"
assert_eq "['ambiguity', 'in_flight', 'multi_plan', 'recommendation', 'single_plan', 'situation', 'summary', 'workspace', 'workspace_action']" \
  "$(hfield "$RAW" 'sorted(H.keys())')"

# ─── Scenario 3: recommendation is null on conversation-context ───────────────
it "U1: conversation-context recommendation is null (driver fills it, not detect)"
assert_eq "None" "$(hfield "$RAW" 'H["recommendation"]')"

it "U1: conversation-context ambiguity is null (driver computes the route)"
assert_eq "None" "$(hfield "$RAW" 'H["ambiguity"]')"

# ─── Scenario 4: signal UNSET -> raw; existing fields unchanged + rec present ─
# Per the U1 contract (recommendation lands on EVERY envelope), "byte-unchanged"
# means the EXISTING-FIELD SUBSET is unchanged vs the new code with the signal
# unset — NOT identical to the pre-U1 envelope. We assert situation=raw AND the
# recommendation key is present-and-null on the raw path too.
it "U1: signal UNSET -> falls through to raw (existing situation preserved)"
REPO="$(mkrepo unset)"
RAW_RAW="$(detect "$REPO")"
assert_eq "raw" "$(hfield "$RAW_RAW" 'H["situation"]')"

it "U1: raw still carries the open 'what should we work on?' ambiguity (unchanged)"
assert_eq "open" "$(hfield "$RAW_RAW" 'H["ambiguity"]["kind"]')"

it "U1: recommendation key present + null on the raw path"
assert_eq "None" "$(hfield "$RAW_RAW" 'H["recommendation"]')"

# ─── Scenario 5: recommendation present on the catastrophic-error fallback ────
# The catastrophic-error fallback is a LITERAL dict (it bypasses _safe_envelope),
# so it must carry `recommendation` independently. The detector is defensively
# written — glob on a missing/unreadable dir returns [] rather than raising — so
# rather than contort a fragile runtime trigger, we (a) prove the literal
# fallback dict in the source emits `recommendation`, and (b) confirm the key is
# present on a degraded-repo envelope at runtime. Together these pin the
# "recommendation on EVERY path incl. the error fallback" contract.
it "U1: the catastrophic-error fallback dict in the source carries recommendation"
# Pull the literal fallback dict (the `except BaseException` json.dump block) and
# assert it includes a `recommendation` key. The fallback is the ONLY json.dump
# of a literal dict in the file (every other emit goes through _safe_envelope).
ERR_BLOCK="$("$PY" - "$DET" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# The except-path dump is `json.dump({ ... }, sys.stdout)` after the handler.
# Find the dict literal that contains "detector error" (the fallback summary).
m = re.search(r'json\.dump\(\{.*?"detector error.*?\}, sys\.stdout\)', src, re.S)
print("present" if (m and '"recommendation"' in m.group(0)) else "MISSING")
PYEOF
)"
assert_eq "present" "$ERR_BLOCK"

it "U1: recommendation key present on a degraded-repo envelope at runtime"
REPO_ERR="${SANDBOX}/errrepo"
mkdir -p "$REPO_ERR"
# A repo whose .claude is a regular file: the ledger scan finds nothing and the
# detector degrades safely; the emitted envelope must still carry the key.
printf 'not a dir' > "${REPO_ERR}/.claude"
RAW_ERR="$(CLAUDE_AUTO_REPO="$REPO_ERR" bash "$DET" 2>/dev/null)"
assert_eq "True" "$(hfield "$RAW_ERR" '"recommendation" in H')"

# ─── Scenario 6: signal does NOT override an existing plan ────────────────────
it "U1: signal SET but a plan exists -> reviewed-plan wins (no override)"
REPO="$(mkrepo conv-plan)"
setup_plan "$REPO"
assert_eq "reviewed-plan" "$(hfield "$(detect "$REPO" signal)" 'H["situation"]')"

# ─── Scenario 7: signal does NOT override an in-flight run ────────────────────
it "U1: signal SET but an in-flight run exists -> in-flight wins (no override)"
REPO="$(mkrepo conv-run)"
setup_inflight "$REPO"
assert_eq "in-flight" "$(hfield "$(detect "$REPO" signal)" 'H["situation"]')"

# ─── Scenario 7b (U3): conversation PREEMPTS an all-stale plan set ────────────
# The reworked precedence: a rich session beats stale docs/plans/ clutter, but
# only when the driver signals it — and a FRESH plan still wins over both.
it "U3: signal SET + all-stale plans -> conversation-context preempts the stale ask"
REPO="$(mkrepo_stale_plans convstale)"
assert_eq "conversation-context" "$(hfield "$(detect "$REPO" signal)" 'H["situation"]')"

it "U3: signal UNSET + all-stale plans -> multi-plan ask (no preemption without the signal)"
assert_eq "multi-plan" "$(hfield "$(detect "$REPO")" 'H["situation"]')"

it "U3: all-stale multi-plan ask suppresses the fan-out-all footgun (no null-path option)"
assert_eq "0" "$(hfield "$(detect "$REPO")" 'len([o for o in H["ambiguity"]["options"] if o.get("path") is None])')"

it "U3: signal SET + one fresh plan among stale -> reviewed-plan (fresh wins over conversation)"
REPO="$(mkrepo_fresh_among_stale convfresh)"
assert_eq "reviewed-plan" "$(hfield "$(detect "$REPO" signal)" 'H["situation"]')"

it "U3: reviewed-plan picks the FRESH plan, not a stale sibling"
assert_eq "docs/plans/z-live-plan.md" "$(hfield "$(detect "$REPO" signal)" 'H["single_plan"]["path"]')"

# ─── Scenario 8: READ-ONLY — detector writes nothing on the signal path ───────
it "U1: detector is READ-ONLY on the conversation-context path (hash unchanged)"
REPO="$(mkrepo readonly)"
# Seed a file so the hash has content to compare.
echo "seed" > "$REPO/.claude/auto/seed.txt"
hash_before="$(find "$REPO" -type f -exec shasum {} \; | sort | shasum)"
detect "$REPO" signal >/dev/null
hash_after="$(find "$REPO" -type f -exec shasum {} \; | sort | shasum)"
assert_eq "$hash_before" "$hash_after"

# ─── Scenario 9: exit 0 on the conversation-context path AND on internal error ─
it "U1: exit 0 on the conversation-context path"
REPO="$(mkrepo exit0)"
detect "$REPO" signal >/dev/null 2>&1
assert_eq "0" "$?"

it "U1: exit 0 even on a forced internal error (rel-001)"
CLAUDE_AUTO_REPO="$REPO_ERR" bash "$DET" >/dev/null 2>&1
assert_eq "0" "$?"

# ════════════════════════════════════════════════════════════════════════════
# U2 — recommender taxonomy
# ════════════════════════════════════════════════════════════════════════════

# ─── Scenario 10: each taxonomy row maps to its expected tuple ────────────────
# vague dispatches the brainstorm-rooted spine recipe `pipeline` entering at the
# `brainstorm` phase (the spine ships in this same v0.6.0 diff — U7/U8). The
# recipe_or_entry is the BARE STEM "pipeline" (--recipe resolves f"{name}.json").
it "U2 row vague -> ce-brainstorm pipeline @ brainstorm (recipe, spine)"
assert_eq "ce-brainstorm|pipeline|brainstorm|True|recipe|False" "$(rec row vague)"

it "U2 row clear-intent-no-plan -> ce-plan a1 @ plan (recipe, spine)"
assert_eq "ce-plan|a1|plan|True|recipe|False" "$(rec row clear-intent-no-plan)"

it "U2 row reviewed-plan -> work-only w @ work (recipe, spine)"
assert_eq "work-only|w|work|True|recipe|False" "$(rec row reviewed-plan)"

# recipe_or_entry is the BARE recipe STEM ("review"), NOT the filename: the
# driver feeds it to `--recipe`, which auto.py resolves via f"{name}.json".
# Passing "review.json" would resolve to review.json.json and fail.
it "U2 row code-unreviewed -> ce-code-review BARE STEM 'review' @ work (recipe, OFF-spine)"
assert_eq "ce-code-review|review|work|False|recipe|False" "$(rec row code-unreviewed)"

it "U2 row bug -> ce-debug /ce-debug (skill, off-spine, no entry)"
assert_eq "ce-debug|/ce-debug|None|False|skill|False" "$(rec row bug)"

it "U2 row what-to-improve -> ce-ideate /ce-ideate (skill, no entry)"
assert_eq "ce-ideate|/ce-ideate|None|False|skill|False" "$(rec row what-to-improve)"

it "U2 row perf -> ce-optimize /ce-optimize (skill, off-spine, no entry)"
assert_eq "ce-optimize|/ce-optimize|None|False|skill|False" "$(rec row perf)"

# ─── Scenario 11: off-spine states never return a spine recipe / advance entry ─
it "U2: off-spine states never claim is_spine, and skill recs never carry an entry"
assert_eq "ok" "$(rec offspine-safe)"

# ─── Scenario 12: low confidence below threshold sets escalate=True ───────────
it "U2: low confidence (0.3) on a known spine state sets escalate=True"
assert_eq "True" "$(rec escalate clear-intent-no-plan 0.3)"

# ─── Scenario 13: unknown / non-string state degrades to safe escalate ────────
it "U2: unknown state -> state=unknown, escalate, no recipe (safe default)"
assert_eq "unknown|True|None|False" "$(rec unknown zzz-not-a-state)"

it "U2: non-string (None) state -> safe escalate default, never crashes"
assert_eq "unknown|True|None|False" "$(rec unknown NONE)"

# ─── Scenario 14: confident known spine state does NOT escalate ───────────────
it "U2: confident (1.0) known spine state does NOT escalate"
assert_eq "False" "$(rec escalate reviewed-plan 1.0)"

# ─── Scenario 15: the documented CLI invocation path (_cli) works ─────────────
# SKILL.md + driver-reference.md §11 tell the driver to run
# `python lib/recommender.py <state> <confidence>` and read the JSON line. This
# exercises that exact path (not just load_lib_module) — the surface the driver
# actually uses — and emits the bare recipe stem the dispatch line consumes.
it "U2: CLI 'recommender.py code-unreviewed 0.9' emits the bare 'review' stem JSON"
CLI_OUT="$("$PY" "${AUTO_ROOT}/lib/recommender.py" code-unreviewed 0.9)"
assert_eq "review" "$(hfield "$CLI_OUT" 'H["recipe_or_entry"]')"

it "U2: CLI low-confidence escalates; CLI bad-confidence arg degrades to escalate (no crash)"
LOW_OUT="$("$PY" "${AUTO_ROOT}/lib/recommender.py" clear-intent-no-plan 0.2)"
BAD_OUT="$("$PY" "${AUTO_ROOT}/lib/recommender.py" vague not-a-number)"
assert_eq "True|True" "$(hfield "$LOW_OUT" 'H["escalate"]')|$(hfield "$BAD_OUT" 'H["escalate"]')"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "conversation-entry.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
