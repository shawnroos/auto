#!/usr/bin/env bash
# auto U3 (finding #1) regression guard: emitted verdict-write guidance must
# never instruct running `run_record.py` DIRECTLY under `bash`.
#
# run_record.py has a `python3` shebang; `bash lib/run_record.py …` interprets
# Python as shell and silently corrupts the verdict write — the loop's spine.
# The interpreter-pinned shim `lib/run_record.sh` (or a `python3 …` prefix) is
# the correct entry. This test fails on ANY `bash <path>/run_record.py`
# occurrence in shipped guidance (skills/, docs/, lib/), so the class of bug
# cannot silently reappear. docs/handoff.md and docs/plans/ are excluded — they
# are working notes ABOUT the bug, not emitted guidance.
#
# Institutional anchors:
#   - field-notes-2026-07-21 finding #1 (Top-3): bash vs python3 corrupts verdict
#   - feedback_no_hacks_make_it_a_deterministic_gate (grep guard, not prose)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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

# Grep shipped guidance surfaces for `bash <anything>/run_record.py` or the bare
# `bash run_record.py`. Exclude working-notes dirs (handoff, plans, research)
# and this test file itself (which necessarily names the pattern).
count_bad() {
  grep -rnE 'bash [^ ]*run_record\.py|bash run_record\.py' \
    "${AUTO_ROOT}/skills" "${AUTO_ROOT}/lib" "${AUTO_ROOT}/docs/contracts" \
    "${AUTO_ROOT}/commands" 2>/dev/null \
    | grep -v 'run-record-guidance-interpreter.test.sh' \
    | wc -l | tr -d ' '
}

it "no shipped guidance runs run_record.py directly under bash (finding #1)"
assert_eq "0" "$(count_bad)"

# Positive: the corrected shim entry IS present (guidance still tells agents how
# to write a verdict — via run_record.sh, not the raw .py).
it "verdict-write guidance routes through the interpreter-pinned run_record.sh shim"
shim_hits="$(grep -rnE 'bash [^ ]*run_record\.sh' \
  "${AUTO_ROOT}/skills" "${AUTO_ROOT}/docs/contracts" 2>/dev/null | wc -l | tr -d ' ')"
[ "$shim_hits" -ge 1 ] && pass || fail "expected >=1 run_record.sh guidance ref, got ${shim_hits}"

echo ""
echo "run-record-guidance-interpreter.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
