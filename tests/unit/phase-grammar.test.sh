#!/usr/bin/env bash
# auto U5 unit test: lib/phase-grammar.py — the centralized phase-decision helper.
#
# SELF-CONTAINED inline harness (same style as ledger.test.sh — no cross-plugin
# coupling, no shared helpers yet).
#
# Scenarios:
#   1. recipe-blind ledger (no phase_order/terminal_phase) → legacy defaults
#   2. recipe ledger (default grammar) → current_phase/next/terminal correct
#   3. work-only ledger (phase_order ["work"]) → work is terminal, no next
#   4. current_phase reads loop_phase, NOT phase_order[0] (resume invariant)
#   5. is_terminal_phase only true at the terminal phase
#   6. next_phase_after_met returns None at terminal, the successor elsewhere

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

# A tiny python driver that loads phase-grammar via _bootstrap and prints a CSV.
pg() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
pg = load_lib_module("phase-grammar")
ledger = json.loads(sys.argv[2])
op = sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else None
if op == "current":
    print(pg.current_phase(ledger))
elif op == "order":
    print(",".join(pg.phase_order(ledger)))
elif op == "terminal":
    print(pg.terminal_phase(ledger))
elif op == "is_terminal":
    print(pg.is_terminal_phase(ledger, arg))
elif op == "next":
    print(pg.next_phase_after_met(ledger, arg))
PYEOF
}

# ─── Scenario 1: recipe-blind → legacy defaults ─────────────────────────────
it "recipe-blind ledger → phase_order defaults to legacy [plan,seam,work]"
assert_eq "plan,seam,work" "$(pg '{"loop_phase":"plan"}' order)"

it "recipe-blind ledger → terminal_phase defaults to work"
assert_eq "work" "$(pg '{"loop_phase":"plan"}' terminal)"

# ─── Scenario 2: recipe ledger, default grammar ─────────────────────────────
it "default-grammar recipe: current_phase reads loop_phase"
assert_eq "seam" "$(pg '{"loop_phase":"seam","phase_order":["plan","seam","work"],"terminal_phase":"work"}' current)"

it "default-grammar: next_phase_after_met(plan) → seam"
assert_eq "seam" "$(pg '{"loop_phase":"plan","phase_order":["plan","seam","work"],"terminal_phase":"work"}' next plan)"

# ─── Scenario 3: work-only (KTD-15) ─────────────────────────────────────────
it "work-only: phase_order is [work]"
assert_eq "work" "$(pg '{"loop_phase":"work","phase_order":["work"],"terminal_phase":"work"}' order)"

it "work-only: work IS terminal (next is None)"
assert_eq "None" "$(pg '{"loop_phase":"work","phase_order":["work"],"terminal_phase":"work"}' next work)"

# ─── Scenario 4: resume invariant — current_phase ≠ phase_order[0] ───────────
it "resume invariant: current_phase reads loop_phase, NOT phase_order[0]"
# A run whose start phase (phase_order[0]) is 'work' but is currently paused mid
# 'seam' must report 'seam', not 'work'. (Synthetic: proves the helper never
# substitutes phase_order[0] for the live loop_phase.)
assert_eq "seam" "$(pg '{"loop_phase":"seam","phase_order":["work","seam"],"terminal_phase":"seam"}' current)"

# ─── Scenario 5: is_terminal_phase ──────────────────────────────────────────
it "is_terminal_phase: plan (non-terminal) → False"
assert_eq "False" "$(pg '{"loop_phase":"plan","phase_order":["plan","seam","work"],"terminal_phase":"work"}' is_terminal plan)"

it "is_terminal_phase: work (terminal) → True"
assert_eq "True" "$(pg '{"loop_phase":"work","phase_order":["plan","seam","work"],"terminal_phase":"work"}' is_terminal work)"

# ─── Scenario 6: next_phase_after_met at terminal ───────────────────────────
it "next_phase_after_met(work) at terminal → None"
assert_eq "None" "$(pg '{"loop_phase":"work","phase_order":["plan","seam","work"],"terminal_phase":"work"}' next work)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "phase-grammar.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
