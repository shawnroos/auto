#!/usr/bin/env bash
# auto launch-chooser: the `recommender.py --check-agrees <state> <stem>`
# primitive (agent-native hardening of `router_agrees`).
#
# The launch chooser (skills/auto-launch §4) must compute `router_agrees` BY the
# router, not by its own judgment. This primitive folds "classify -> run the
# router -> compare stems" into one deterministic shell step that prints exactly
# `true` / `false`, so the skip cross-check cannot be faked at the call boundary.
# It is `true` IFF the router's deterministic pick for <state> equals <stem>.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
REC="${AUTO_ROOT}/lib/recommender.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n      %s\n" "$CURRENT" "${1:-}"; return 0; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

agrees() { "$PY" "$REC" --check-agrees "$1" "$2"; }

# ── agreement on the two states that can skip (the only ones the router picks) ─
it "clear-intent-no-plan + a1 -> true (router picks a1)"
assert_eq "true" "$(agrees clear-intent-no-plan a1)"

it "reviewed-plan + w -> true (router picks w)"
assert_eq "true" "$(agrees reviewed-plan w)"

# ── the escape direction: a non-default stem on a skip-eligible state ─────────
it "clear-intent-no-plan + a2 -> false (router never picks a2)"
assert_eq "false" "$(agrees clear-intent-no-plan a2)"

it "reviewed-plan + a4 -> false (router never picks a4)"
assert_eq "false" "$(agrees reviewed-plan a4)"

it "clear-intent-no-plan + custom-stem -> false"
assert_eq "false" "$(agrees clear-intent-no-plan my-custom-spike)"

# ── skip-eligibility: a router pick outside {a1,w} never agrees (round-2) ─────
# The router legitimately returns non-skip stems for non-skip states; agreement
# on those must NOT green-light a skip, even though pick == stem exactly.
it "vague + pipeline -> false (pipeline is a router pick but NOT skip-eligible)"
assert_eq "false" "$(agrees vague pipeline)"

it "code-unreviewed + review -> false (review is a router pick but NOT skip-eligible)"
assert_eq "false" "$(agrees code-unreviewed review)"

# ── cross-state mismatch (stem of the OTHER skip state) ──────────────────────
it "clear-intent-no-plan + w -> false (router picks a1, not w)"
assert_eq "false" "$(agrees clear-intent-no-plan w)"

it "reviewed-plan + a1 -> false (router picks w, not a1)"
assert_eq "false" "$(agrees reviewed-plan a1)"

# ── unverifiable / degenerate inputs degrade to false (block skip) ───────────
it "unknown state -> false (workflow_or_entry is None, never matches a stem)"
assert_eq "false" "$(agrees totally-unknown-state a1)"

it "empty stem -> false (a None pick must not match an empty arg)"
assert_eq "false" "$(agrees clear-intent-no-plan "")"

it "unknown state + empty stem -> false (None pick never equals '')"
assert_eq "false" "$(agrees totally-unknown-state "")"

echo ""
echo "recommender-check-agrees.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
