#!/usr/bin/env bash
# auto v0.3.0 F1 unit test: /auto-status iteration-awareness.
#
# F1 closes a 4-reviewer-corroborated P1 cluster from round-1 review of
# v0.3.0: lib/auto-status.py had zero knowledge of any v0.3.0 iteration
# fields. Agents couldn't see iteration state. This test asserts the
# rendered output surface for the new Iteration section + per-step
# bound_exit sub-bullet.
#
# Scenarios:
#   1. Iteration section OMITTED on a plain non-iteration ledger.
#   2. Iteration section RENDERED when the ledger declares an iteration
#      block + bound + counters + emit_count, including:
#         gate_step, attempts, wall_time, emit_count, last_active,
#         iteration_pending, but NOT kill_switch (env not set).
#   3. wall_time denominator renders "—" when no max_wall_seconds is set.
#   4. last_active is OMITTED when last_active_at is null.
#   5. iteration_pending line is OMITTED when not present on the cached
#      exit_predicate_result.
#   6. Section is RENDERED on the bound_override-only signal (iteration
#      block None, attempts==0, wall==0, but a step carries bound_override).
#   7. Per-step bound_exit sub-bullet renders bound + original_decision +
#      at on the affected step, anchored under the step's listing.
#   8. Kill-switch line renders ONLY when BOTH CLAUDE_AUTO_TEST_HARNESS=1
#      AND CLAUDE_AUTO_DISABLE_ITERATION=1 are set (per
#      _bootstrap.test_hatch_enabled).
#
# Test fixture pattern: auto-status reads <repo>/.claude/auto/<run>.json
# lock-free via ledger.read_ledger, so we write the JSON directly with
# python json.dump — bypasses ledger.init_ledger so this test stays
# decoupled from F3's eventual schema-validator surface. (Advisor advice:
# direct-write keeps the fixture surface narrow.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATUS_SH="${AUTO_ROOT}/lib/auto-status.sh"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Inline test harness (mirrors tests/unit/iteration.test.sh) ─────────────
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

assert_contains() {
  # assert_contains <haystack> <needle> [label]
  local haystack="$1" needle="$2" label="${3:-}"
  case "$haystack" in
    *"$needle"*) pass ;;
    *) fail "${label:-expected substring} '$needle' not found in output:
$haystack" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-}"
  case "$haystack" in
    *"$needle"*) fail "${label:-unexpected substring} '$needle' present in output:
$haystack" ;;
    *) pass ;;
  esac
}

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-f1-status.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-f1-status.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO/.claude/auto"

# write_ledger <run-id> <python-dict-expr>
#   Build the ledger dict via the given python expression and write it to
#   <repo>/.claude/auto/<run-id>.json via json.dump.
write_ledger() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" <<'PYEOF'
import json, os, sys
repo, run, expr = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = eval(expr, {"__builtins__": __builtins__})
ledger.setdefault("run_id", run)
path = os.path.join(repo, ".claude", "auto", f"{run}.json")
with open(path, "w") as fh:
    json.dump(ledger, fh)
PYEOF
}

# run_status <run-id>  → prints stdout from /auto-status for that run
run_status() {
  local run="$1"
  CLAUDE_AUTO_REPO="$REPO" bash "$STATUS_SH" "$run" 2>&1
}

# ── Fixtures ───────────────────────────────────────────────────────────────
# Plain non-iteration ledger (a1/W shape — iteration=None, no counters).
PLAIN_RUN="plain-run"
PLAIN_EXPR='{
  "run_id": "plain-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "work", "driver": "self"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": False},
  "steps": [{"id": "u1", "state": "dispatched", "phase": "work"}],
  "iteration": None,
  "iteration_attempts": 0,
  "iteration_emit_count": 0,
  "active_wall_seconds": 0,
  "last_active_at": None
}'

# Full iteration-aware ledger (a2-iter shape — gate + bound + counters).
ITER_RUN="iter-run"
ITER_EXPR='{
  "run_id": "iter-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "work", "driver": "self"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": False, "iteration_pending": True},
  "steps": [
    {"id": "writer", "state": "verdict-returned", "phase": "work"},
    {"id": "judge", "state": "verdict-returned", "phase": "work", "dispatch_context": {"decision": "iterate"}}
  ],
  "iteration": {"gate_step": "judge", "bound": {"max_attempts": 5, "max_wall_seconds": 900}},
  "iteration_attempts": 3,
  "iteration_emit_count": 7,
  "active_wall_seconds": 412.5,
  "last_active_at": "2026-05-26T10:23:00Z"
}'

# No-wall-bound iteration ledger — exercises the "—" denominator.
NOWALL_RUN="nowall-run"
NOWALL_EXPR='{
  "run_id": "nowall-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "work", "driver": "self"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": False},
  "steps": [{"id": "judge", "state": "verdict-returned", "phase": "work"}],
  "iteration": {"gate_step": "judge", "bound": {"max_attempts": 5}},
  "iteration_attempts": 1,
  "iteration_emit_count": 2,
  "active_wall_seconds": 0,
  "last_active_at": None
}'

# Bound-override-only ledger: iteration block None, counters zero, but a
# step carries a bound_override. Section must still render because the
# bound_override is a v0.3.0 iteration signal.
BO_RUN="bound-override-run"
BO_EXPR='{
  "run_id": "bound-override-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "done", "driver": "self"},
  "exit_predicate_result": {"met": True, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": True},
  "steps": [
    {"id": "judge", "state": "verdict-returned", "phase": "work",
     "dispatch_context": {"bound_override": {"bound": "max_attempts", "original_decision": "iterate", "at": "2026-05-26T11:00:00Z"}}}
  ],
  "iteration": None,
  "iteration_attempts": 0,
  "iteration_emit_count": 0,
  "active_wall_seconds": 0,
  "last_active_at": None
}'

write_ledger "$PLAIN_RUN" "$PLAIN_EXPR"
write_ledger "$ITER_RUN" "$ITER_EXPR"
write_ledger "$NOWALL_RUN" "$NOWALL_EXPR"
write_ledger "$BO_RUN" "$BO_EXPR"

# ─── Scenario 1: section OMITTED on plain ledger ────────────────────────────
PLAIN_OUT="$(run_status "$PLAIN_RUN")"

it "iteration section OMITTED on non-iteration ledger (a1/W shape)"
assert_not_contains "$PLAIN_OUT" "  iteration:" "iteration: heading"

it "no iteration sub-fields leak on non-iteration ledger"
assert_not_contains "$PLAIN_OUT" "    gate_step:" "gate_step"

it "no bound_exit sub-bullet on non-iteration ledger"
assert_not_contains "$PLAIN_OUT" "        bound_exit:" "bound_exit"

# ─── Scenario 2: section RENDERED on iteration-aware ledger ────────────────
ITER_OUT="$(run_status "$ITER_RUN")"

it "iteration: heading rendered when ledger has iteration block"
assert_contains "$ITER_OUT" "  iteration:" "heading"

it "gate_step rendered with the configured gate id"
assert_contains "$ITER_OUT" "    gate_step: judge" "gate_step"

it "attempts rendered as <current> / <max>"
assert_contains "$ITER_OUT" "    attempts: 3 / 5" "attempts"

it "wall_time rendered as <active>s / <max>s with integer formatting"
assert_contains "$ITER_OUT" "    wall_time: 412s / 900s" "wall_time"

it "emit_count rendered from iteration_emit_count"
assert_contains "$ITER_OUT" "    emit_count: 7" "emit_count"

it "last_active rendered when last_active_at is non-null"
assert_contains "$ITER_OUT" "    last_active: 2026-05-26T10:23:00Z" "last_active"

it "iteration_pending rendered from cached exit_predicate_result"
assert_contains "$ITER_OUT" "    iteration_pending: True" "iteration_pending"

it "kill_switch line OMITTED when env vars not set"
assert_not_contains "$ITER_OUT" "kill_switch" "kill_switch"

# ─── Scenario 3: wall_time denominator is "—" without max_wall_seconds ────
NOWALL_OUT="$(run_status "$NOWALL_RUN")"

it "wall_time renders \"—\" denominator when no max_wall_seconds configured"
assert_contains "$NOWALL_OUT" "    wall_time: 0s / —" "wall_time no-bound"

it "iteration section renders on counters-only signal (no wall bound)"
assert_contains "$NOWALL_OUT" "    gate_step: judge" "gate_step no-wall"

# ─── Scenario 4: last_active omitted when null ─────────────────────────────
it "last_active OMITTED when last_active_at is null"
assert_not_contains "$NOWALL_OUT" "    last_active:" "last_active null"

# ─── Scenario 5: iteration_pending omitted when absent from epr ────────────
it "iteration_pending OMITTED when not present on exit_predicate_result"
assert_not_contains "$NOWALL_OUT" "    iteration_pending:" "iteration_pending absent"

# ─── Scenario 6: bound_override-only signal renders the section ────────────
BO_OUT="$(run_status "$BO_RUN")"

it "iteration section RENDERED on bound_override-only signal"
assert_contains "$BO_OUT" "  iteration:" "bound_override-only heading"

# ─── Scenario 7: per-step bound_exit sub-bullet renders the stored payload ─
it "bound_exit sub-bullet renders bound type"
assert_contains "$BO_OUT" "bound=max_attempts" "bound_exit bound"

it "bound_exit sub-bullet renders original_decision"
assert_contains "$BO_OUT" "original_decision=iterate" "bound_exit original_decision"

it "bound_exit sub-bullet renders timestamp"
assert_contains "$BO_OUT" "at=2026-05-26T11:00:00Z" "bound_exit at"

it "bound_exit sub-bullet is anchored under the affected step's listing"
# The 'judge' step line precedes the bound_exit line in the rendered output.
case "$BO_OUT" in
  *"- judge:"*"        bound_exit:"*) pass ;;
  *) fail "bound_exit not anchored under 'judge' step:
$BO_OUT" ;;
esac

# ─── Scenario 8: kill-switch (F5 unfence — operator env var only) ───────────
# Sub-case 8a: CLAUDE_AUTO_DISABLE_ITERATION=1 alone, NO test-harness sentinel.
# Post-F5 the kill-switch is operator-only — is_iteration_disabled() reads
# only CLAUDE_AUTO_DISABLE_ITERATION (not the test_hatch_enabled pair).
KS_NO_HARNESS_OUT="$(CLAUDE_AUTO_DISABLE_ITERATION=1 env -u CLAUDE_AUTO_TEST_HARNESS CLAUDE_AUTO_REPO="$REPO" bash "$STATUS_SH" "$ITER_RUN" 2>&1)"

it "kill_switch RENDERED when DISABLE_ITERATION=1 alone (post-F5 unfence)"
assert_contains "$KS_NO_HARNESS_OUT" "kill_switch: DISABLED via CLAUDE_AUTO_DISABLE_ITERATION" "kill_switch operator-only"

# Sub-case 8b: env var unset → kill_switch line omitted.
KS_UNSET_OUT="$(env -u CLAUDE_AUTO_DISABLE_ITERATION CLAUDE_AUTO_REPO="$REPO" bash "$STATUS_SH" "$ITER_RUN" 2>&1)"

it "kill_switch OMITTED when DISABLE_ITERATION unset"
assert_not_contains "$KS_UNSET_OUT" "kill_switch" "kill_switch off"

# ─── Scenario 9 (G7 / ADV-R2-2): shape-defensive render boundary ──────────
# A corrupt iteration block, stringified iteration_attempts, or bound
# corruption that slipped past the WRITE-side gates (G2 in lib/iteration.py)
# must NOT crash /auto-status — the operator needs visibility during the
# exact incident that needs diagnosis. Defense-in-depth at the read
# chokepoint: render a single "<shape error: ...>" line instead of crashing.

# DF 1 — corrupt iteration as a string (not a dict, not None).
CORRUPT_ITER_RUN="corrupt-iter-run"
CORRUPT_ITER_EXPR='{
  "run_id": "corrupt-iter-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "work", "driver": "self"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": False},
  "steps": [{"id": "u1", "state": "dispatched", "phase": "work"}],
  "iteration": "broken",
  "iteration_attempts": 0,
  "iteration_emit_count": 0,
  "active_wall_seconds": 0,
  "last_active_at": None
}'
write_ledger "$CORRUPT_ITER_RUN" "$CORRUPT_ITER_EXPR"
CORRUPT_ITER_OUT="$(run_status "$CORRUPT_ITER_RUN")"

it "G7 DF1: corrupt iteration block renders shape-error line, not crash"
assert_contains "$CORRUPT_ITER_OUT" "iteration: <shape error:" "shape-error line"

# DF 2 — stringified iteration_attempts ("five" instead of an int).
STRING_ATTEMPTS_RUN="string-attempts-run"
STRING_ATTEMPTS_EXPR='{
  "run_id": "string-attempts-run",
  "backend": "ce",
  "backend_scale": "three-tier",
  "loop": {"loop_phase": "work", "driver": "self"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": False},
  "steps": [{"id": "u1", "state": "dispatched", "phase": "work"}],
  "iteration": None,
  "iteration_attempts": "five",
  "iteration_emit_count": 0,
  "active_wall_seconds": 0,
  "last_active_at": None
}'
write_ledger "$STRING_ATTEMPTS_RUN" "$STRING_ATTEMPTS_EXPR"
STRING_ATTEMPTS_OUT="$(run_status "$STRING_ATTEMPTS_RUN")"

it "G7 DF2: stringified iteration_attempts triggers render (not crash)"
# _should_render_iteration must return True on stringified attempts, so the
# iteration section renders (either happy-path or shape-error line — both
# acceptable; what's NOT acceptable is a crash that suppresses the section).
case "$STRING_ATTEMPTS_OUT" in
  *"iteration:"*) pass ;;
  *) fail "stringified iteration_attempts suppressed iteration section:
$STRING_ATTEMPTS_OUT" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "auto-status.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
