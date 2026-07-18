#!/usr/bin/env bash
# auto U5 unit test: lib/phase-grammar.py — the centralized phase-decision helper.
#
# SELF-CONTAINED inline harness (same style as run-record.test.sh — no cross-plugin
# coupling, no shared helpers yet).
#
# Scenarios:
#   1. workflow-blind run-record (no phase_order/terminal_phase) → legacy defaults
#   2. workflow run-record (default grammar) → current_phase/next/terminal correct
#   3. work-only run-record (phase_order ["work"]) → work is terminal, no next
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
run_record = json.loads(sys.argv[2])
op = sys.argv[3]
arg = sys.argv[4] if len(sys.argv) > 4 else None
if op == "current":
    print(pg.current_phase(run_record))
elif op == "order":
    print(",".join(pg.phase_order(run_record)))
elif op == "terminal":
    print(pg.terminal_phase(run_record))
elif op == "is_terminal":
    print(pg.is_terminal_phase(run_record, arg))
elif op == "next":
    print(pg.next_phase_after_met(run_record, arg))
PYEOF
}

# ─── Scenario 1: workflow-blind → legacy defaults ─────────────────────────────
it "workflow-blind run_record → phase_order defaults to legacy [plan,handoff,work]"
assert_eq "plan,handoff,work" "$(pg '{"loop_phase":"plan"}' order)"

it "workflow-blind run_record → terminal_phase defaults to work"
assert_eq "work" "$(pg '{"loop_phase":"plan"}' terminal)"

# ─── Scenario 2: workflow run-record, default grammar ─────────────────────────────
it "default-grammar workflow: current_phase reads loop_phase"
assert_eq "handoff" "$(pg '{"loop_phase":"handoff","phase_order":["plan","handoff","work"],"terminal_phase":"work"}' current)"

it "default-grammar: next_phase_after_met(plan) → handoff"
assert_eq "handoff" "$(pg '{"loop_phase":"plan","phase_order":["plan","handoff","work"],"terminal_phase":"work"}' next plan)"

# ─── Scenario 3: work-only (KTD-15) ─────────────────────────────────────────
it "work-only: phase_order is [work]"
assert_eq "work" "$(pg '{"loop_phase":"work","phase_order":["work"],"terminal_phase":"work"}' order)"

it "work-only: work IS terminal (next is None)"
assert_eq "None" "$(pg '{"loop_phase":"work","phase_order":["work"],"terminal_phase":"work"}' next work)"

# ─── Scenario 4: resume invariant — current_phase ≠ phase_order[0] ───────────
it "resume invariant: current_phase reads loop_phase, NOT phase_order[0]"
# A run whose start phase (phase_order[0]) is 'work' but is currently paused mid
# 'handoff' must report 'handoff', not 'work'. (Synthetic: proves the helper never
# substitutes phase_order[0] for the live loop_phase.)
assert_eq "handoff" "$(pg '{"loop_phase":"handoff","phase_order":["work","handoff"],"terminal_phase":"handoff"}' current)"

# ─── Scenario 5: is_terminal_phase ──────────────────────────────────────────
it "is_terminal_phase: plan (non-terminal) → False"
assert_eq "False" "$(pg '{"loop_phase":"plan","phase_order":["plan","handoff","work"],"terminal_phase":"work"}' is_terminal plan)"

it "is_terminal_phase: work (terminal) → True"
assert_eq "True" "$(pg '{"loop_phase":"work","phase_order":["plan","handoff","work"],"terminal_phase":"work"}' is_terminal work)"

# Non-work terminal workflow (the shape pulse.py's two guards now route through):
# is_terminal_phase must key on the workflow's DECLARED terminal, not the literal
# "work". brainstorm IS terminal here; work is not even in the order.
it "is_terminal_phase: brainstorm IS terminal for a brainstorm-terminal workflow"
assert_eq "True" "$(pg '{"loop_phase":"brainstorm","phase_order":["plan","handoff","brainstorm"],"terminal_phase":"brainstorm"}' is_terminal brainstorm)"

it "is_terminal_phase: a mid-run non-terminal phase (brainstorm, terminal=work) → False"
assert_eq "False" "$(pg '{"loop_phase":"brainstorm","phase_order":["plan","handoff","brainstorm","work"],"terminal_phase":"work"}' is_terminal brainstorm)"

it "is_terminal_phase: phase=None defaults to current_phase (loop_phase) → True at terminal"
assert_eq "True" "$(pg '{"loop_phase":"brainstorm","phase_order":["plan","handoff","brainstorm"],"terminal_phase":"brainstorm"}' is_terminal)"

# ─── Scenario 6: next_phase_after_met at terminal ───────────────────────────
it "next_phase_after_met(work) at terminal → None"
assert_eq "None" "$(pg '{"loop_phase":"work","phase_order":["plan","handoff","work"],"terminal_phase":"work"}' next work)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "phase-grammar.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
