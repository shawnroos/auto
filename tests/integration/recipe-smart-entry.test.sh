#!/usr/bin/env bash
# auto U12 integration test: smart-entry's DETERMINISTIC DETECTOR (auto-detect.sh).
#
# Bare /auto's routing is orchestrator prose; the DETECTION it branches on is
# deterministic (deterministic-over-probabilistic for load-bearing infra). These
# tests pin the detector's verdict for each situation — the contract the prose
# relies on:
#   raw            → no run, no plan  → prose recommends /ce-plan
#   reviewed-plan  → one plan, no run → prose offers work-only
#   in-flight      → one not-met run  → prose resumes it
#   (done run)     → not in-flight    → falls through to plan/raw
#   ambiguous-runs → >1 not-met run   → prose asks which to resume
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

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "recipe-smart-entry.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
