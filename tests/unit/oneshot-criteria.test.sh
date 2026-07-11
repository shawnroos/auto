#!/usr/bin/env bash
# auto U3 unit test (addressable-step-contents): validate_oneshot_criteria.
#
# The pre-dispatch ratify gate: before the ratified criteria flow into the
# terminal verdict, the list is validated against the SAME taxonomy shape a
# recipe's verification block uses. validate_oneshot_criteria
# REUSES recipe_validate._validate_verification (KTD-2 reuse discipline) so
# "malformed proposed criterion is rejected" is a REAL test, not just prose.
#
# SELF-CONTAINED: minimal inline it/pass/fail/assert_eq harness, python pinned
# via CLAUDE_AUTO_PYTHON3, module loaded via importlib from an absolute path
# (matching tests/unit/ledger.test.sh + one-shot-verdict.test.sh).
#
# Scenarios (U3 plan, AE1/AE2 pre-bake validation):
#   1. a well-formed criteria list (all four types) validates ok.
#   2. a `programmatic` criterion with a SHELL STRING instead of an argv list is
#      rejected (parity with the recipe validator's argv-only rule).
#   3. an unknown criterion `type` is rejected.
#   4. more than 16 criteria are rejected (the taxonomy cap).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${AUTO_ROOT}/lib"
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

echo "oneshot-criteria.test.sh"

# One python probe emits a ';'-joined token line the bash scenarios assert on.
# On any import/attr failure it prints IMPORT-FAIL so the test goes RED (the
# deliberate-fail-once smoke check before validate_oneshot_criteria exists).
probe() {
  "$PY" - "$LIB" <<'PYEOF'
import sys, importlib.util

lib = sys.argv[1]
if lib not in sys.path:
    sys.path.insert(0, lib)

def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{lib}/{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

try:
    co = load("content_oneshot")
    fn = co.validate_oneshot_criteria
except Exception as e:  # module/function missing -> RED
    print("IMPORT-FAIL:%s" % e)
    sys.exit(0)

results = []

# ── Scenario 1: a well-formed criteria list validates ok ─────────────────────
good = [
    {"id": "tests", "type": "programmatic", "argv": ["bash", "tests/run.sh"], "check": "exit_zero"},
    {"id": "reads-clean", "type": "model_judge"},
    {"id": "design-sound", "type": "advisor_judge"},
    {"id": "owner-signoff", "type": "human"},
]
ok, errs = fn(good)
results.append("good_ok=%s" % ok)
results.append("good_errs=%s" % len(errs))

# ── Scenario 2: programmatic with a SHELL STRING instead of argv is rejected ──
shell = [{"id": "c", "type": "programmatic", "argv": "bash tests/run.sh", "check": "exit_zero"}]
ok, errs = fn(shell)
results.append("shell_ok=%s" % ok)
results.append("shell_has_err=%s" % (len(errs) > 0))

# ── Scenario 3: an unknown criterion type is rejected ────────────────────────
unk = [{"id": "c", "type": "vibe_check"}]
ok, errs = fn(unk)
results.append("unk_ok=%s" % ok)

# ── Scenario 4: >16 criteria are rejected (the taxonomy cap) ─────────────────
over = [{"id": "c%d" % i, "type": "model_judge"} for i in range(17)]
ok, errs = fn(over)
results.append("over_ok=%s" % ok)

print(";".join(results))
PYEOF
}

OUT="$(probe)"
get() { printf '%s' "$OUT" | tr ';' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

it "a well-formed criteria list (all four types) validates ok"
assert_eq "True" "$(get good_ok)"

it "a valid list yields zero errors"
assert_eq "0" "$(get good_errs)"

it "a programmatic criterion with a shell string instead of argv is rejected"
assert_eq "False" "$(get shell_ok)"

it "a rejected criteria list carries at least one error message"
assert_eq "True" "$(get shell_has_err)"

it "an unknown criterion type is rejected"
assert_eq "False" "$(get unk_ok)"

it "more than 16 criteria are rejected (the taxonomy cap)"
assert_eq "False" "$(get over_ok)"

echo ""
echo "oneshot-criteria.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
