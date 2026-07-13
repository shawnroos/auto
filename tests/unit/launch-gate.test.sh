#!/usr/bin/env bash
# auto launch-chooser U2: deterministic launch confidence ladder.
#
# lib/launch-gate.py::classify_launch maps the launch agent's two self-assessed
# confidences (shape, gates) + the structural facts (workflow_kind, gate_types,
# router_agrees) to one of skip / confirm / two_step (plan KTD-1). The fuzzy
# step (how confident am I?) is the model's; the crisp tier mapping is code —
# `feedback_deterministic_over_probabilistic_v1`. This file pins the full
# KTD-1 truth table, with the load-bearing focus on the SAFETY rows that must
# never return `skip` (a judge/human gate, a custom workflow, or a router
# disagreement). Those rows are the dead-UI-regression guard (R10).
#
# Test-first target (U2 Execution note): the router-disagrees-but-confident row
# `(0.95, 0.95, builtin, [], False)` must never `skip`. That is the assertion
# that bites before the `router_agrees` guard is wired.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
GATE="${AUTO_ROOT}/lib/launch-gate.py"

# ── Minimal inline test harness ────────────────────────────────────────────
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
# assert_in <value> <allowed...>: pass iff value matches one of the allowed set.
assert_in() {
  local val="$1"; shift
  local a
  for a in "$@"; do
    if [ "$val" = "$a" ]; then pass; return 0; fi
  done
  fail "got '$val', expected one of: $*"
}

# ── Helper: drive the launch-gate CLI, print just the tier. ────────────────
# tier <shape> <gates> <workflow_kind> <gate_types_csv> <router_agrees>
#   gate_types_csv: comma-separated (use "" for an empty list).
#   router_agrees: true|false
tier() {
  "$PY" "$GATE" "$1" "$2" "$3" "$4" "$5" \
    | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["tier"])'
}

# ── skip rows (both dims high, builtin, programmatic-or-empty, router agrees) ─
it "Covers AE1: (0.95,0.95,builtin,[],True) -> skip"
assert_eq "skip" "$(tier 0.95 0.95 builtin "" true)"

it "Covers AE1: (0.9,0.9,builtin,[programmatic],True) -> skip"
assert_eq "skip" "$(tier 0.9 0.9 builtin programmatic true)"

it "Covers AE2: reviewed-plan (0.9,0.88,builtin,[],True) -> skip"
assert_eq "skip" "$(tier 0.9 0.88 builtin "" true)"

# ── agreement gate: router disagreement never skips (the test-first row) ─────
# Deterministic two_step (both high + agrees=false => skip blocked by rule 3, and
# rule 4 cannot fire when BOTH dims clear SKIP_BAR). Pin it exactly — assert_in
# over {confirm,two_step} would let a regression to "confirm" slip through on
# this load-bearing safety row.
it "agreement gate: (0.95,0.95,builtin,[],False) -> two_step (never skip)"
assert_eq "two_step" "$(tier 0.95 0.95 builtin "" false)"

# ── judge / human / model_judge gates forbid skip (rule 2) ───────────────────
it "Covers AE3: (0.7,0.6,builtin,[advisor_judge],True) -> two_step"
assert_eq "two_step" "$(tier 0.7 0.6 builtin advisor_judge true)"

# Both dims maxed + a human gate => rule 3 blocked, rule 4 can't fire (both high)
# => deterministic two_step. Pin exactly (was assert_in, which under-specified).
it "safety: (0.99,0.99,builtin,[human],True) -> two_step (never skip)"
assert_eq "two_step" "$(tier 0.99 0.99 builtin human true)"

# model_judge is the third name in JUDGE_OR_HUMAN_GATES and previously had NO
# coverage. (Note: a pure model_judge gate is also blocked from skip by the
# programmatic_only check, since "model_judge" != "programmatic" — so this row
# documents the intended outcome rather than guarding the only path to it.)
it "safety: (0.99,0.99,builtin,[model_judge],True) -> two_step (never skip)"
assert_eq "two_step" "$(tier 0.99 0.99 builtin model_judge true)"

# ── custom workflow always two_step (rule 1, R4) ───────────────────────────────
it "safety: (0.99,0.99,custom,[],True) -> two_step"
assert_eq "two_step" "$(tier 0.99 0.99 custom "" true)"

# ── single-confirm tier (rule 4: exactly one dim clears SKIP_BAR) ────────────
it "single-confirm: (0.9,0.72,builtin,[programmatic],True) -> confirm"
assert_eq "confirm" "$(tier 0.9 0.72 builtin programmatic true)"

it "single-confirm: (0.72,0.9,builtin,[],True) -> confirm"
assert_eq "confirm" "$(tier 0.72 0.9 builtin "" true)"

# Rule 4 (single-confirm) does NOT re-check has_blocking_gate — by design a
# blocking gate forbids skip ONLY, so a settled shape with a judge/human gate may
# still single-confirm. Pin that documented subcase so a future "safety" guard
# added to rule 4 can't silently turn it into two_step.
it "confirm with blocking gate: (0.9,0.72,builtin,[advisor_judge],True) -> confirm"
assert_eq "confirm" "$(tier 0.9 0.72 builtin advisor_judge true)"

# ── bias-to-show default (rule 5) ────────────────────────────────────────────
it "bias-to-show: (0.6,0.6,builtin,[],True) -> two_step"
assert_eq "two_step" "$(tier 0.6 0.6 builtin "" true)"

# ── robustness: bad input degrades to two_step, never crashes ────────────────
it "robustness: non-numeric confidence -> two_step, no exception"
assert_eq "two_step" "$(tier abc def builtin "" true)"

it "robustness: out-of-range (negative) confidence -> two_step"
assert_eq "two_step" "$(tier -0.5 -0.5 builtin "" true)"

it "robustness: unknown workflow_kind -> treated as custom -> two_step"
assert_eq "two_step" "$(tier 0.99 0.99 weird "" true)"

# ── direct Python API smoke (the function is the real contract, not the CLI) ─
it "python API: classify_launch importable and returns a str tier"
api_out="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "launch_gate", os.path.join(auto_root, "lib", "launch-gate.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# skip path
a = m.classify_launch(0.95, 0.95, "builtin", [], True)
# custom always two_step
b = m.classify_launch(0.99, 0.99, "custom", [], True)
# constants present with the documented values
assert m.SKIP_BAR == 0.85, m.SKIP_BAR
assert m.CONFIRM_BAR == 0.70, m.CONFIRM_BAR
print(a, b)
PYEOF
)"
assert_eq "skip two_step" "$api_out"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "launch-gate.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
