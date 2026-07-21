#!/usr/bin/env bash
# auto U10 (finding D): a baseline-health precheck before a run arms, plus an
# engine notion of "verification deferred to CI".
#
# WHY: the field run's target worktree had a baseline-RED `typecheck` (an
# ungenerated env file), so every step's "typecheck passes" gate was meaningless
# until fixed by hand — the engine had no baseline-health precheck to catch it
# before U1. Separately, a repo with a known-flaky local suite (Karma) stranded
# agents on a >120s inline run; a "verification deferred to CI" flag lets such a
# check be marked CI-owned rather than run inline.
#
# The gate is SPLIT for testability (feedback_split_fuzzy_judgment_from_crisp_
# decision_for_testability): baseline_health() runs the check (fuzzy I/O);
# baseline_blocks_arm() is the crisp decision. Both are INVOKED here, not
# asserted from source (feedback_test_behavior_not_source_for_security_gates).
#
# Institutional anchors:
#   - field-notes-2026-07-21 environmental section (baseline-RED typecheck; flaky Karma)
#   - no_hacks_make_it_a_deterministic_gate (baseline measured before any step runs)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
spec = importlib.util.spec_from_file_location("verification",
        os.path.join(auto_root, "lib", "verification.py"))
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
scenario = sys.argv[2]

GREEN = {"id": "typecheck", "argv": ["sh", "-c", "exit 0"], "check": "exit_zero"}
RED   = {"id": "typecheck", "argv": ["sh", "-c", "exit 1"], "check": "exit_zero"}
DEFER = {"id": "karma", "argv": ["sh", "-c", "exit 1"], "check": "exit_zero",
         "defer_to_ci": True}

if scenario == "red_blocks":
    r = v.baseline_health(RED)
    print("%s|%s|%s" % (r["healthy"], r["deferred"], v.baseline_blocks_arm([r])))
elif scenario == "green_ok":
    r = v.baseline_health(GREEN)
    print("%s|%s|%s" % (r["healthy"], r["deferred"], v.baseline_blocks_arm([r])))
elif scenario == "defer_not_run":
    # defer_to_ci: the check is NOT run inline (deferred), so it can't block arm
    # even though its command would exit 1 — it is a DIFFERENT signal (CI owns it).
    r = v.baseline_health(DEFER)
    print("%s|%s|%s" % (r["healthy"], r["deferred"], v.baseline_blocks_arm([r])))
elif scenario == "mixed_red":
    results = [v.baseline_health(GREEN), v.baseline_health(RED)]
    print(v.baseline_blocks_arm(results))
elif scenario == "mixed_deferred":
    results = [v.baseline_health(GREEN), v.baseline_health(DEFER)]
    print(v.baseline_blocks_arm(results))
else:
    sys.exit("unknown scenario: %s" % scenario)
PYEOF
}

echo "baseline-health.test.sh"

it "baseline-RED (typecheck exits 1) → not healthy, not deferred, BLOCKS arm"
assert_eq "False|False|True" "$(probe red_blocks)"

it "baseline-GREEN (typecheck exits 0) → healthy, not deferred, does NOT block"
assert_eq "True|False|False" "$(probe green_ok)"

it "defer_to_ci → NOT run inline (deferred), does NOT block (different signal from baseline breakage)"
assert_eq "True|True|False" "$(probe defer_not_run)"

it "mixed: green + red baseline → BLOCKS arm"
assert_eq "True" "$(probe mixed_red)"

it "mixed: green + deferred → does NOT block (deferred is CI-owned, not a baseline failure)"
assert_eq "False" "$(probe mixed_deferred)"

echo ""
echo "baseline-health.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
