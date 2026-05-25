#!/usr/bin/env bash
# auto U12 integration test: smart-entry's DETERMINISTIC DETECTOR (auto-detect.sh).
#
# Bare /auto's routing is orchestrator prose; the DETECTION it branches on is
# deterministic (deterministic-over-probabilistic for load-bearing infra). These
# tests pin the detector's verdict for each situation — the contract the prose
# relies on:
#   raw             → no run, no plan  → prose recommends /ce-plan
#   reviewed-plan   → one plan, no run → prose offers work-only
#   in-flight       → one not-met run  → prose resumes it
#   (done run)      → not in-flight    → falls through to plan/raw
#   ambiguous-runs  → >1 not-met run   → prose asks which to resume
#   ambiguous-plans → no run, >1 plan  → prose shows the picker
# Plus a deliberate-fail: a "done" run (met=true) must NOT be detected as
# in-flight (else smart-entry would try to resume a finished run).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DET="${AUTO_ROOT}/lib/auto-detect.sh"

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

# Build a temp repo, optionally with a ledger and/or plan, run the detector.
detect_in() {  # $1=setup-fn
  local repo; repo="$(mktemp -d)"; mkdir -p "$repo/.claude/auto"
  "$1" "$repo"
  CLAUDE_AUTO_REPO="$repo" bash "$DET"
}

setup_raw()      { :; }
setup_plan()     { mkdir -p "$1/docs/plans"; echo "# p" > "$1/docs/plans/x-plan.md"; }
setup_inflight() { echo '{"run_id":"rA","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/rA.json"; }
setup_done()     { echo '{"run_id":"rB","exit_predicate_result":{"met":true}}' > "$1/.claude/auto/rB.json"; }
setup_two_runs() {
  echo '{"run_id":"r1","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/r1.json"
  echo '{"run_id":"r2","exit_predicate_result":{"met":false}}' > "$1/.claude/auto/r2.json"
}
# fix-pass C T5: ambiguous-plans branch — no run, multiple plan files. The
# detector counts plans under docs/plans/*.md, plans/*.md, *-plan.md
# (lib/auto-detect.sh:75) and emits `ambiguous-plans\t<n>` when >1 are present.
# This is the prose's signal to show the picker. We plant 3 distinct plans so
# the count field — not just the verdict bucket — is exercised. The
# `.claude/auto/` dir is created (empty) by detect_in's mkdir, so the in-flight
# branch is exercised-and-fails before falling through to the plans branch.
setup_three_plans() {
  mkdir -p "$1/docs/plans"
  echo "# p1" > "$1/docs/plans/alpha-plan.md"
  echo "# p2" > "$1/docs/plans/beta-plan.md"
  echo "# p3" > "$1/docs/plans/gamma-plan.md"
}
# Deliberate-correctness companion to ambiguous-plans: a 2-plan setup must
# detect with count=2 (not 1, not 3). Pairs with the 3-plan case to assert the
# count is the actual file count, not a hardcoded value.
setup_two_plans() {
  mkdir -p "$1/docs/plans"
  echo "# p1" > "$1/docs/plans/alpha-plan.md"
  echo "# p2" > "$1/docs/plans/beta-plan.md"
}

it "smart-entry detect: no run + no plan → raw (recommend /ce-plan)"
assert_eq "raw" "$(detect_in setup_raw)"

it "smart-entry detect: one plan + no run → reviewed-plan (offer work-only)"
assert_eq "reviewed-plan	docs/plans/x-plan.md" "$(detect_in setup_plan)"

it "smart-entry detect: one not-met run → in-flight (resume it)"
assert_eq "in-flight	rA" "$(detect_in setup_inflight)"

it "smart-entry detect: >1 not-met run → ambiguous-runs (ask which)"
assert_eq "ambiguous-runs	2" "$(detect_in setup_two_runs)"

# Deliberate-correctness: a DONE run (met=true) must NOT be in-flight — else
# smart-entry would try to resume a finished run. It falls through to raw.
it "smart-entry detect: a done run (met=true) is NOT in-flight → raw"
assert_eq "raw" "$(detect_in setup_done)"

# fix-pass C T5: ambiguous-plans branch. Three plans planted → count=3.
it "smart-entry detect: >1 plan + no run → ambiguous-plans (with file count)"
assert_eq "ambiguous-plans	3" "$(detect_in setup_three_plans)"

# fix-pass C T5: count-field exercise. Two plans → count=2 (not 3, not 1).
# Together with the 3-plan case above, this proves the count field is the
# actual number of plans found, not a hardcoded value or always-3 bug.
it "smart-entry detect: ambiguous-plans count matches actual file count (2)"
assert_eq "ambiguous-plans	2" "$(detect_in setup_two_plans)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-smart-entry.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
