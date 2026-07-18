#!/usr/bin/env bash
# auto unit test: goal-aware plan-routing DOC-CONTRACT lint (plan 2026-07-08-001).
#
# The goal-aware routing behavior (recover a goal → weight plans via the rubric →
# reshape reviewed-plan/multi-plan) is AGENT-JUDGED prose in the driver skill —
# it is not bash-testable at runtime. What IS mechanically checkable is the
# WIRING: the rubric doc exists, the driver references it, and the driver's
# pre-step names each routing branch + guard with the exact marker strings the
# behavior depends on. This test IS that defense — it fails if the goal-aware
# pre-step is removed, renamed, or drifts to goal-blind, so the feature can't
# silently regress (per the "deterministic over probabilistic V1" rule: the
# behavioral part gets a mechanical wiring guard even though the routing itself
# is prose).
#
# The four branch marker strings are a CONTRACT shared with the driver SKILL.md
# pre-step (auto-driver step 3). If you rename a marker here, rename it there too
# (and vice versa) — the grep asserts the literal phrasing, so a paraphrase on
# either side breaks the guard silently.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRIVER_SKILL="${AUTO_ROOT}/skills/auto-driver/SKILL.md"
RUBRIC="${AUTO_ROOT}/skills/auto-driver/references/goal-plan-relevance-rubric.md"

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

# Reusable: is `$1` (a fixed string) present in the driver SKILL.md?
# -F fixed-string, -q quiet. Returns 0 when present.
skill_has() { grep -Fq -- "$1" "$DRIVER_SKILL"; }

# ─── Scenario 1: the rubric doc exists ──────────────────────────────────────
it "goal-plan-relevance-rubric.md exists"
if [ -f "$RUBRIC" ]; then pass; else fail "missing: ${RUBRIC}"; fi

# ─── Scenario 2: the driver references the rubric ───────────────────────────
it "driver SKILL.md references the relevance rubric"
if skill_has "goal-plan-relevance-rubric.md"; then pass; else fail "driver does not reference the rubric doc"; fi

# ─── Scenario 2b: the driver delegates routing to the deterministic handoff ─────
# The branch decision + guardrails live in lib/goal-route.py, not prose. If the
# driver stops calling it, the R12/R8 enforcement reverts to prose-only.
it "driver SKILL.md delegates the route decision to lib/goal-route.py"
if skill_has "lib/goal-route.py"; then pass; else fail "driver does not call the deterministic router lib/goal-route.py"; fi

# ─── Scenario 3: the four routing-branch markers are present ────────────────
# These are the contract strings the driver pre-step (step 3) writes and this
# test guards. Missing any one means a routing branch was dropped or renamed.
for marker in explicit-suppress inferred-re-rank no-match-unchanged no-goal-unchanged; do
  it "driver pre-step names branch marker: ${marker}"
  if skill_has "$marker"; then pass; else fail "branch marker absent from driver: ${marker}"; fi
done

# ─── Scenario 4: the recovery/scope guards are stated ───────────────────────
# R3 (read-only /goal), R12 (interactive-only), R2 (explicit-over-inferred).
it "driver states the R3 read-only /goal guard"
if skill_has "never query/run/bind/clear"; then pass; else fail "R3 read-only-/goal guard string absent"; fi

it "driver states the R12 interactive-only scope"
# Grep a string UNIQUE to the goal-aware pre-step's interactive-only sentence,
# not bare `driving_session_id` — that already appears in the pre-existing
# reviewed-plan situation-table row, so it would match even if the pre-step's
# R12 scope were deleted (a tautological guard proves nothing).
if skill_has "self-driven/headless runs skip this whole"; then pass; else fail "R12 interactive-only scope of the goal-aware pre-step absent"; fi

it "driver states explicit-over-inferred recovery precedence (R2)"
# Assert the ordered authority itself (explicit sources, THEN inferred as the
# fallback labelled advisory) rather than the bare word 'advisory'.
if skill_has "else infer from the session (advisory)"; then pass; else fail "R2 explicit-over-inferred precedence (inferred is the advisory fallback) absent"; fi

# ─── Scenario 5: deliberate-fail control ────────────────────────────────────
# Prove the mechanism actually fires by asserting a guaranteed-absent marker is
# reported MISSING. Without this, a broken skill_has (e.g. wrong path) could
# report green while testing nothing.
it "deliberate-fail: a guaranteed-absent marker is detected as missing"
if skill_has "__goal_aware_absent_marker_probe__"; then
  fail "control probe unexpectedly matched — skill_has is not discriminating"
else
  pass
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "goal-aware-routing.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
