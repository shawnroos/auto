#!/usr/bin/env bash
# auto v0.4.0 U1 integration test: smart-entry's DETERMINISTIC DETECTOR
# (auto-detect.sh) — JSON hypothesis-envelope contract.
#
# v0.2.x emitted a TSV verdict line; v0.4.0 (KTD-1) emits a JSON hypothesis
# envelope. This integration test pins the situation discriminator for each
# of the six branches — the contract every downstream driver relies on.
#
# Six situations:
#   raw            → no run, no plan, clean tree           → driver recommends /ce-plan
#   reviewed-plan  → one plan, no run                       → driver starts the run
#   in-flight      → one not-met run                        → driver resumes
#   ambiguous-runs → >1 not-met run                         → driver AskUserQuestion
#   multi-plan     → no run, >1 plan  (v0.4.0 rename of    → driver fans out via auto-spawn
#                    v0.2.x's `ambiguous-plans`)
#   dirty-tree     → no run, no plan, uncommitted changes  → driver surfaces summary (NEW)
#
# Plus a deliberate-fail: a "done" run (met=true) must NOT be detected as
# in-flight (else smart-entry would try to resume a finished run).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DET="${AUTO_ROOT}/lib/auto-detect.sh"
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

# detect_situation <setup-fn>  — build a hermetic repo, run the detector,
# print the resolved `.situation` field of the emitted JSON envelope.
detect_situation() {
  local repo; repo="$(mktemp -d)"
  mkdir -p "$repo/.claude/auto"
  # git init + gitignore so .claude/ and docs/ don't show up in `git status`
  # and falsely route to the dirty-tree branch on scenarios that seed under
  # those paths. Mirrors the real-repo gitignore.
  (
    cd "$repo"
    git init -q .
    git config user.email t@t
    git config user.name t
    printf '.claude/\ndocs/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  ) >/dev/null 2>&1
  "$1" "$repo"
  local raw; raw="$(CLAUDE_AUTO_REPO="$repo" bash "$DET")"
  rm -rf "$repo"
  "$PY" -c "import json,sys; print(json.loads(sys.argv[1])['situation'])" "$raw"
}

setup_raw() { :; }
setup_plan() {
  mkdir -p "$1/docs/plans"
  echo "# p" > "$1/docs/plans/x-plan.md"
}
setup_inflight() {
  echo '{"run_id":"rA","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/rA.json"
}
setup_done() {
  echo '{"run_id":"rB","exit_predicate_result":{"met":true}}' > "$1/.claude/auto/rB.json"
}
setup_two_runs() {
  echo '{"run_id":"r1","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/r1.json"
  echo '{"run_id":"r2","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/r2.json"
}
# v0.4.0 RENAME: v0.2.x's `ambiguous-plans` → `multi-plan`. Multiple plans is a
# fanout SIGNAL under v0.4.0, not an ambiguity to resolve.
setup_three_plans() {
  mkdir -p "$1/docs/plans"
  echo "# p1" > "$1/docs/plans/alpha-plan.md"
  echo "# p2" > "$1/docs/plans/beta-plan.md"
  echo "# p3" > "$1/docs/plans/gamma-plan.md"
}
setup_two_plans() {
  mkdir -p "$1/docs/plans"
  echo "# p1" > "$1/docs/plans/alpha-plan.md"
  echo "# p2" > "$1/docs/plans/beta-plan.md"
}
# v0.4.0 NEW: dirty-tree branch. No run, no plan, but the working tree has
# uncommitted changes (untracked file → git status non-empty).
setup_dirty_tree() {
  echo "scratch" > "$1/scratch.txt"
}

it "smart-entry detect: no run + no plan + clean tree → situation=raw"
assert_eq "raw" "$(detect_situation setup_raw)"

it "smart-entry detect: one plan + no run → situation=reviewed-plan"
assert_eq "reviewed-plan" "$(detect_situation setup_plan)"

it "smart-entry detect: one not-met run → situation=in-flight"
assert_eq "in-flight" "$(detect_situation setup_inflight)"

it "smart-entry detect: >1 not-met run → situation=ambiguous-runs"
assert_eq "ambiguous-runs" "$(detect_situation setup_two_runs)"

# Deliberate-correctness: a done run (met=true) must NOT be in-flight — else
# smart-entry would try to resume a finished run.
it "smart-entry detect: a done run (met=true) is NOT in-flight → situation=raw"
assert_eq "raw" "$(detect_situation setup_done)"

it "smart-entry detect: >1 plan + no run → situation=multi-plan (v0.4.0 rename)"
assert_eq "multi-plan" "$(detect_situation setup_three_plans)"

it "smart-entry detect: 2 plans still multi-plan (count agnostic, all >1 fan out)"
assert_eq "multi-plan" "$(detect_situation setup_two_plans)"

it "smart-entry detect: dirty tree (no run, no plan) → situation=raw (round-1 C-2/C-3: dirty-tree collapsed into raw)"
assert_eq "raw" "$(detect_situation setup_dirty_tree)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-smart-entry.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
