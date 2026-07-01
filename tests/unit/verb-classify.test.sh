#!/usr/bin/env bash
# auto v0.7.x U4: verb-classify.py unit test.
#
# Pins the deterministic {work|plan|both|ambiguous} taxonomy over freeform args:
#   * work verbs about existing work → work (the 2026-06 field misroute #2)
#   * creation verb + "plan" noun, or "plan" as a verb, + work → both (#1)
#   * plan/design verb, no work → plan
#   * "the plan" (noun) does NOT read as plan-creation
#   * no verb signal → ambiguous (bare topics / improvement verbs → model decides)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VC="${AUTO_ROOT}/lib/verb-classify.py"
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

# cls "<args>" → the class string.
cls() {
  "$PY" "$VC" "$1" | "$PY" -c 'import sys,json; print(json.loads(sys.stdin.read())["class"])'
}

# ── work: imperatives about existing work ──────────────────────────────────
it "field case #2: 'execute, code-review and verify the plan, then open a PR' → work"
assert_eq "work" "$(cls "execute, code-review and verify the plan, then open a PR")"

it "'ship it' → work"
assert_eq "work" "$(cls "ship it")"

it "'complete the work, review to green and open PR' → work (this very invocation)"
assert_eq "work" "$(cls "complete the work, review to green and open PR")"

it "case-insensitive: 'EXECUTE THE PLAN' → work"
assert_eq "work" "$(cls "EXECUTE THE PLAN")"

# ── both: plan-creation + work ─────────────────────────────────────────────
it "field case #1: 'develop and implement a plan to add X' → both (create + build)"
assert_eq "both" "$(cls "develop and implement a plan to add X")"

it "'plan and implement dark mode' → both ('plan' as verb + work)"
assert_eq "both" "$(cls "plan and implement dark mode")"

# ── plan: plan-creation, no work ───────────────────────────────────────────
it "'plan a faster image cache' → plan ('plan' as verb, no work)"
assert_eq "plan" "$(cls "plan a faster image cache")"

it "'design the onboarding flow' → plan"
assert_eq "plan" "$(cls "design the onboarding flow")"

it "'write a plan for billing' → plan (creation verb + plan noun)"
assert_eq "plan" "$(cls "write a plan for billing")"

# ── the 'the plan' noun MUST NOT read as plan-creation ─────────────────────
it "'run the plan' → work (article-preceded 'plan' is a noun, not a verb)"
assert_eq "work" "$(cls "run the plan")"

# ── collision nouns (review/run) as topic objects must NOT read as work ─────
it "'design a review workflow' → plan (article-preceded 'review' is a noun)"
assert_eq "plan" "$(cls "design a review workflow")"

it "'plan a run-rate dashboard' → plan (article-preceded 'run' is a noun)"
assert_eq "plan" "$(cls "plan a run-rate dashboard")"

# ── punctuation / possessive before 'plan' must still read it as a noun ─────
it "'review (the plan)' → work (punctuation-wrapped article still gates the noun)"
assert_eq "work" "$(cls "review (the plan)")"

it "'review team'\''s plan' → work (possessive makes 'plan' a noun)"
assert_eq "work" "$(cls "review team's plan")"

# ── ambiguous: no verb signal → model decides ──────────────────────────────
it "'make it better' → ambiguous (improvement verb, no work/plan intent)"
assert_eq "ambiguous" "$(cls "make it better")"

it "'dark mode for settings' → ambiguous (bare topic, no verbs)"
assert_eq "ambiguous" "$(cls "dark mode for settings")"

it "empty args → ambiguous"
assert_eq "ambiguous" "$(cls "")"

it "whitespace-only args → ambiguous"
assert_eq "ambiguous" "$(cls "   ")"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "verb-classify.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
