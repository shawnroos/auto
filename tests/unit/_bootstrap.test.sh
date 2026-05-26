#!/usr/bin/env bash
# auto v0.3.0 F5 unit test: _bootstrap helpers.
#
# Covers:
#   1. is_iteration_disabled() — REAL operator knob (unfenced in F5).
#      Returns True when CLAUDE_AUTO_DISABLE_ITERATION=1 is set, WITHOUT
#      the CLAUDE_AUTO_TEST_HARNESS=1 sentinel also being set. This is the
#      load-bearing assertion of the F5 unfence — it MUST go RED in the
#      pre-F5 (still-fenced) world, and GREEN now.
#   2. is_iteration_disabled() — returns False when var is unset.
#   3. test_hatch_enabled() no longer recognizes CLAUDE_AUTO_DISABLE_ITERATION
#      (the kill-switch is its own function now). Probe with the var alone +
#      harness sentinel ALSO set, both unset, etc.
#   4. test_hatch_enabled() still works for the other test-only hatches.
#
# Institutional anchors:
#   - feedback_plan_documents_transition_code_doesnt_wire_it (round-1 was
#     prose-vs-code; F5 makes them consistent)
#   - feedback_deterministic_over_probabilistic_v1 (env-var check is
#     deterministic; that's the right shape)

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

# Driver: load lib/_bootstrap.py and call one of its helpers, printing the
# boolean result as "True" or "False" (Python repr).
probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
op = sys.argv[2]
if op == "is_iteration_disabled":
    print(b.is_iteration_disabled())
elif op == "test_hatch":
    var = sys.argv[3]
    print(b.test_hatch_enabled(var))
else:
    sys.exit(f"unknown op: {op}")
PYEOF
}

# ─── Scenario 1: is_iteration_disabled — the F5 unfence assertion ───────────
# Set DISABLE=1 but EXPLICITLY UNSET the harness sentinel. In the pre-F5
# world this would return False (the fence required the sentinel); post-F5
# it returns True (the var alone is sufficient — it's now a real operator
# knob). This is the load-bearing scenario for F5. We use a subshell + unset
# instead of `env -u` because `probe` is a shell function, not an executable.
it "is_iteration_disabled: DISABLE=1 alone (no harness sentinel) → True (F5 unfence)"
result="$(unset CLAUDE_AUTO_TEST_HARNESS; CLAUDE_AUTO_DISABLE_ITERATION=1 \
  probe is_iteration_disabled)"
assert_eq "True" "$result"

# ─── Scenario 2: is_iteration_disabled — unset var → False ──────────────────
it "is_iteration_disabled: DISABLE unset → False"
result="$(unset CLAUDE_AUTO_DISABLE_ITERATION; probe is_iteration_disabled)"
assert_eq "False" "$result"

# ─── Scenario 3: is_iteration_disabled — DISABLE=0 → False ──────────────────
it "is_iteration_disabled: DISABLE=0 → False (only '1' is True)"
result="$(CLAUDE_AUTO_DISABLE_ITERATION=0 probe is_iteration_disabled)"
assert_eq "False" "$result"

# ─── Scenario 4: lib/*.py no longer asks test_hatch_enabled about it ────────
# The contract is that NO code in lib/ asks test_hatch_enabled about
# DISABLE_ITERATION anymore (the kill-switch routes through
# is_iteration_disabled). Grep-check is the mechanical, deterministic
# enforcement (composes with feedback_deterministic_over_probabilistic_v1).
it "test_hatch_enabled: no lib/*.py module asks about CLAUDE_AUTO_DISABLE_ITERATION (F5: kill-switch is is_iteration_disabled-only)"
hits="$(grep -rn 'test_hatch_enabled[^)]*CLAUDE_AUTO_DISABLE_ITERATION' \
  "${AUTO_ROOT}/lib" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$hits"

# ─── Scenario 5: test_hatch_enabled still fences the other test hatches ─────
# With BOTH sentinel + var set → True. The helper unchanged for these.
it "test_hatch_enabled: harness sentinel + NO_TICK_LOCK=1 → True (existing test hatches unaffected)"
result="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_TICK_LOCK)"
assert_eq "True" "$result"

# ─── Scenario 6: test_hatch_enabled fence — sentinel missing → False ────────
it "test_hatch_enabled: var alone (no harness sentinel) → False (other hatches still fenced)"
result="$(unset CLAUDE_AUTO_TEST_HARNESS; CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_TICK_LOCK)"
assert_eq "False" "$result"

# ─── Scenario 7: test_hatch_enabled fence — var missing → False ─────────────
it "test_hatch_enabled: harness sentinel alone (no var) → False"
result="$(unset CLAUDE_AUTO_TEST_NO_TICK_LOCK; CLAUDE_AUTO_TEST_HARNESS=1 \
  probe test_hatch CLAUDE_AUTO_TEST_NO_TICK_LOCK)"
assert_eq "False" "$result"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "_bootstrap.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
