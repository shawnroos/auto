#!/usr/bin/env bash
# auto v0.4.0 U1: hypothesis-shape lint for auto-detect.sh.
#
# v0.4.0 KTD-1: auto-detect.sh emits a JSON HYPOTHESIS envelope (not a TSV
# verdict). This test pins:
#   1. one of the six valid situations,
#   2. the envelope shape (every slot present, even when null),
#   3. discriminated-union population (single_plan vs multi_plan vs in_flight),
#   4. ambiguity-array shape on the ambiguous-runs branch,
#   5. dirty-tree triggers on uncommitted changes,
#   6. goal_intent (when present on the ledger) feeds the in-flight summary +
#      ambiguous-runs option descriptions,
#   7. exit 0 on every path (rel-001 / hook-safety).
#
# Each scenario is hermetic: a temp repo + git init + the minimum on-disk
# state to exercise one branch. The detector is invoked via the .sh shim so
# the test exercises the user-facing surface.

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
SANDBOX="$(mktemp -d -t auto-hyp-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-hyp-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helper: build a hermetic repo, run detect, return parsed JSON via jq-ish python.
#
# json_field <setup-fn> <python-expr-on-hypothesis-named-H>
#   Each setup-fn takes the repo path and seeds whatever state the scenario
#   needs. We run `git init` so the dirty-tree branch can probe the index.
json_field() {
  local setup_fn="$1" expr="$2"
  local repo; repo="$(mktemp -d -t hyp-repo.XXXXXX)"
  (
    cd "$repo"
    git init -q .
    # Quiet down git's default-branch + user prompts.
    git config user.email test@test
    git config user.name test
    # Mirror the real-repo gitignore so .claude/auto/*.json and docs/plans/
    # don't show up in `git status` and falsely trigger the dirty-tree branch.
    # Then commit the gitignore so the working tree starts clean for the
    # setup-fn to mutate (only the explicit untracked-file scenario should
    # leave a dirty tree).
    printf '.claude/\ndocs/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  ) >/dev/null 2>&1
  mkdir -p "$repo/.claude/auto"
  "$setup_fn" "$repo"
  local raw
  raw="$(CLAUDE_AUTO_REPO="$repo" bash "$DET")"
  rm -rf "$repo"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
# Print booleans as Python literals (matches the rest of the suite).
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

# ── Scenario setups ────────────────────────────────────────────────────────
setup_raw() { :; }

setup_plan() {
  mkdir -p "$1/docs/plans"
  echo "# Build the foo widget" > "$1/docs/plans/foo-plan.md"
}

setup_three_plans() {
  mkdir -p "$1/docs/plans"
  echo "# alpha" > "$1/docs/plans/alpha-plan.md"
  echo "# beta"  > "$1/docs/plans/beta-plan.md"
  echo "# gamma" > "$1/docs/plans/gamma-plan.md"
}

setup_inflight_one() {
  cat > "$1/.claude/auto/runA.json" <<'EOF'
{"run_id":"runA","exit_predicate_result":{"met":false},"goal_intent":"Ship the login fix"}
EOF
}

setup_inflight_two() {
  cat > "$1/.claude/auto/runA.json" <<'EOF'
{"run_id":"runA","exit_predicate_result":{"met":false},"goal_intent":"Ship the login fix"}
EOF
  # Touch a moment later so mtime ordering is stable.
  sleep 0.01
  cat > "$1/.claude/auto/runB.json" <<'EOF'
{"run_id":"runB","exit_predicate_result":{"met":false},"goal_intent":"Retire deprecated cron"}
EOF
}

setup_inflight_no_goal() {
  cat > "$1/.claude/auto/runX.json" <<'EOF'
{"run_id":"runX","exit_predicate_result":{"met":false}}
EOF
}

setup_done_run() {
  cat > "$1/.claude/auto/runZ.json" <<'EOF'
{"run_id":"runZ","exit_predicate_result":{"met":true}}
EOF
}

setup_dirty_tree() {
  echo "scratch" > "$1/scratch.txt"
  # We do NOT commit — leaving an untracked file makes git status non-empty.
}

setup_malformed() {
  echo "{ this is not valid json" > "$1/.claude/auto/bad.json"
}

# ── Scenario 1: raw envelope shape ─────────────────────────────────────────
it "raw: situation=raw with open-ambiguity question"
assert_eq "raw" "$(json_field setup_raw 'H["situation"]')"

it "raw: ambiguity.kind == open"
assert_eq "open" "$(json_field setup_raw 'H["ambiguity"]["kind"]')"

it "raw: single_plan slot is null"
assert_eq "None" "$(json_field setup_raw 'H["single_plan"]')"

it "raw: multi_plan slot is null"
assert_eq "None" "$(json_field setup_raw 'H["multi_plan"]')"

it "raw: in_flight slot is null"
assert_eq "None" "$(json_field setup_raw 'H["in_flight"]')"

# ── Scenario 2: reviewed-plan with single_plan populated ───────────────────
it "reviewed-plan: situation=reviewed-plan when exactly one plan present"
assert_eq "reviewed-plan" "$(json_field setup_plan 'H["situation"]')"

it "reviewed-plan: single_plan.path is the relpath to the plan"
assert_eq "docs/plans/foo-plan.md" "$(json_field setup_plan 'H["single_plan"]["path"]')"

it "reviewed-plan: ambiguity is null (no question to ask)"
assert_eq "None" "$(json_field setup_plan 'H["ambiguity"]')"

# ── Scenario 3: multi-plan (the v0.4.0 rename of ambiguous-plans) ──────────
it "multi-plan: situation=multi-plan when more than one plan present"
assert_eq "multi-plan" "$(json_field setup_three_plans 'H["situation"]')"

it "multi-plan: multi_plan.paths has all three plans"
assert_eq "3" "$(json_field setup_three_plans 'len(H["multi_plan"]["paths"])')"

it "multi-plan: ambiguity is null — fanout, not question"
assert_eq "None" "$(json_field setup_three_plans 'H["ambiguity"]')"

# ── Scenario 4: in-flight single + goal_intent feeds summary ───────────────
it "in-flight: situation=in-flight when one not-met run present"
assert_eq "in-flight" "$(json_field setup_inflight_one 'H["situation"]')"

it "in-flight: in_flight.run_id is the single run-id"
assert_eq "runA" "$(json_field setup_inflight_one 'H["in_flight"]["run_id"]')"

it "in-flight: summary surfaces the goal_intent from the ledger"
# The exact phrasing is operator-friendly — we just assert goal_intent appears.
assert_eq "True" "$(json_field setup_inflight_one '"Ship the login fix" in H["summary"]')"

it "in-flight: ambiguity is null when there's exactly one run"
assert_eq "None" "$(json_field setup_inflight_one 'H["ambiguity"]')"

# ── Scenario 5: ambiguous-runs with options carrying goal_intent ───────────
it "ambiguous-runs: situation when more than one in-flight run"
assert_eq "ambiguous-runs" "$(json_field setup_inflight_two 'H["situation"]')"

it "ambiguous-runs: ambiguity.options has both run-ids"
assert_eq "2" "$(json_field setup_inflight_two 'len(H["ambiguity"]["options"])')"

it "ambiguous-runs: option description carries goal_intent for run B"
assert_eq "True" "$(json_field setup_inflight_two 'any(o["description"]=="Retire deprecated cron" for o in H["ambiguity"]["options"])')"

it "ambiguous-runs: in_flight.run_ids has both ids"
assert_eq "2" "$(json_field setup_inflight_two 'len(H["in_flight"]["run_ids"])')"

it "ambiguous-runs: ambiguity.kind == choice (N-option pick-one)"
assert_eq "choice" "$(json_field setup_inflight_two 'H["ambiguity"]["kind"]')"

# ── Scenario 6: in-flight WITHOUT goal_intent falls back gracefully ────────
it "in-flight no goal_intent: situation is still in-flight"
assert_eq "in-flight" "$(json_field setup_inflight_no_goal 'H["situation"]')"

it "in-flight no goal_intent: summary still references the run_id"
assert_eq "True" "$(json_field setup_inflight_no_goal '"runX" in H["summary"]')"

# ── Scenario 7: done run (met=true) is NOT detected as in-flight ───────────
# Same coverage as the v0.2.x test — guard against resuming a finished run.
it "done run is NOT in-flight — falls through to raw"
assert_eq "raw" "$(json_field setup_done_run 'H["situation"]')"

# ── Scenario 8: dirty-tree contextualizes `raw` (review round 1 finding C-2/C-3)
# v0.4.0's original `dirty-tree` situation had no actionable dispatch (the
# skill's `<derived-args>` couldn't be derived from a diff alone) AND its
# detection depended on downstream repos gitignoring `.claude/`. The fix
# collapsed dirty-tree into raw: situation stays `raw` (no run, no plan ⇒
# operator must answer the open question), but the summary names the
# branch + diff context so the operator sees what they were doing.
it "dirty-tree: situation falls through to raw (no actionable dispatch from a diff alone)"
assert_eq "raw" "$(json_field setup_dirty_tree 'H["situation"]')"

it "dirty-tree: ambiguity is still the open 'what should we work on?' question"
assert_eq "open" "$(json_field setup_dirty_tree 'H["ambiguity"]["kind"]')"

it "dirty-tree: summary surfaces git context (branch + diff)"
assert_eq "True" "$(json_field setup_dirty_tree '"branch" in H["summary"]')"

# ── Scenario 9: malformed ledger is skipped (parity with v0.2.x) ───────────
it "malformed ledger: skipped silently → falls through to raw"
assert_eq "raw" "$(json_field setup_malformed 'H["situation"]')"

# ── Scenario 10: every envelope has the canonical key set (shape invariant)
it "envelope shape: every emitted JSON has all six top-level keys"
shape_setup() {
  setup_inflight_one "$1"
}
keys="$(json_field shape_setup 'sorted(H.keys())')"
assert_eq "['ambiguity', 'in_flight', 'multi_plan', 'single_plan', 'situation', 'summary']" "$keys"

# ── Scenario 11: detector exits 0 on every path (rel-001) ──────────────────
it "exit code: detector exits 0 even on the unexpected-error fallback"
repo="$(mktemp -d -t hyp-repo.XXXXXX)"
# Don't even init git — the detector should still degrade to raw and exit 0.
mkdir -p "$repo/.claude/auto"
CLAUDE_AUTO_REPO="$repo" bash "$DET" >/dev/null 2>&1
rc=$?
rm -rf "$repo"
assert_eq "0" "$rc"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "hypothesis-shape.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
