#!/usr/bin/env bash
# auto v0.3.0 H mechanical defense: doc-fence for the run-record-schema contract.
#
# WHY THIS TEST EXISTS (the recurring class meta-finding from round-3 review):
# Round-1 / Round-2 / Round-3 each surfaced an instance of the recurring class
# "code adds a public run-record field or mutator without documenting it in
# docs/contracts/run-record-schema.md" — same shape as the prose-vs-code mismatch
# pattern, but applied to docs/code drift. G3 closed the round-2 instance for
# the workflow-format.md side (the F4-added expected_emit_outputs field); G2
# reproduced the SAME class on the run-record side by adding `exit_reason` +
# `set_exit_reason` without touching run-record-schema.md. H (this fix-pass) closes
# the instance AND adds this mechanical defense so the class can't quietly
# recur a fourth time.
#
# Mirror of tests/unit/wikilink-check.test.sh (G5's mechanical defense for the
# wikilink-leak class). Pattern: for every public run-record surface, the docs
# MUST mention it by name; the lint greps the doc + fails on absence.
#
# Maintenance contract: when you add a new top-level run-record field OR a new
# public run_record.py function, update this lint's `REQUIRED` list AND
# docs/contracts/run-record-schema.md. The lint fails fast; the doc keeps the
# operator surface discoverable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_DOC="${AUTO_ROOT}/docs/contracts/run-record-schema.md"

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

# The required-symbols list: every public run-record surface that the operator or
# an agent reading the docs would need. Adding a new public symbol to
# lib/run_record.py without adding it here is fine — but then this lint won't catch
# a doc-drift on that symbol. Adding it here is the load-bearing step. Keep
# the list narrow: only fields/functions an external consumer would need to
# understand. Helpers prefixed with `_` are NOT in scope.
#
# Order matters for readability only — the lint runs an unordered grep.
REQUIRED=(
  # v0.2.0 run-record surface (covered by U8's doc lock)
  "workflow"
  "phase_order"
  "terminal_phase"
  # v0.3.0 iteration surface (covered by U8 + F3's AC-1 closure)
  "active_wall_seconds"
  "last_active_at"
  "iteration_attempts"
  "iteration_emit_count"
  "iteration"
  "emit_templates"
  # v0.3.0 G2: exit_reason field (round-3 API-R3-1 — the gap this lint exists to prevent)
  "exit_reason"
  # Public mutators added in v0.3.0
  "set_verdict_decision"
  "set_bound_override"
  "accumulate_active_time"
  "increment_iteration_attempts"
  "reset_for_iteration"
  "emit_within_phase"
  "atomic_iterate_step"
  # v0.3.0 G2: set_exit_reason mutator (round-3 API-R3-1 — the gap this lint exists to prevent)
  "set_exit_reason"
  # v0.3.1 B11: ExitReason StrEnum (replaces H's three top-level EXIT_REASON_* names)
  "ExitReason"
  # v0.4.0 U1: goal_intent run-record field — one-line user-facing intent sentence
  "goal_intent"
  # v0.6.0 U5 (KTD-5): the advisor-gate session-ownership field + audit record
  # and their mutators.
  "driving_session_id"
  "advisor_audit"
  "set_driving_session_id"
  "append_advisor_audit"
  # v0.6.0 P3-b: the destructive-backstop pause latch (loop.backstop_latched)
  # that distinguishes a backstop pause from an operator pause.
  "backstop_latched"
)

# ─── Scenario 0: anti-vacuity floors ────────────────────────────────────────
# Both of these guard the same failure mode: the fence reporting SUCCESS because it
# checked nothing. With `REQUIRED=()` — or with `SCHEMA_DOC` pointing at a file that
# does not exist — every loop below runs zero times, or trivially, and this file goes
# GREEN while enforcing precisely nothing.
it "the fenced doc exists (else every grep below passes vacuously)"
if [ -f "$SCHEMA_DOC" ]; then
  pass
else
  fail "run-record-schema.md is missing — every check below would pass vacuously"
fi

it "REQUIRED is non-empty and covers the surface (anti-vacuity floor)"
if [ "${#REQUIRED[@]}" -ge 20 ]; then
  pass
else
  fail "REQUIRED has ${#REQUIRED[@]} entries (floor: 20) — the fence is checking almost nothing.
      If a symbol was deliberately retired, lower the floor in the same commit and say why."
fi

# The fence's ACTUAL check, factored into a function so the deliberate-fail control
# below can re-point it at a PLANTED-BROKEN copy of the doc and prove it fires.
#
# This factoring is the whole point (F2). The DF control this replaces built
# `grep -v exit_reason "$doc"` and then asserted that `exit_reason` was absent from the
# result. That proves `grep -v` works. It never ran Scenario 1's loop, never touched
# `REQUIRED`, and would have passed with `REQUIRED=()` — i.e. the control was green on a
# fence that checked nothing, which is the exact condition it existed to detect. Same
# anti-pattern named and fixed in tests/unit/doc-fence-agent-tool-surface.test.sh.
#
# missing_symbols <doc> → prints the REQUIRED symbols not named in <doc>.
missing_symbols() {
  local doc="$1" sym esym out=""
  for sym in "${REQUIRED[@]}"; do
    # Word-boundary match, NOT a substring: `grep -F "exit_reason"` is satisfied by
    # `set_exit_reason` alone, so the fence counted a symbol documented only as part of a
    # LONGER name (review r3). Require a non-[alnum_] boundary (or line edge) on each side,
    # so `exit_reason` must be named in its own right. The symbol is regex-escaped first —
    # today all REQUIRED entries are bare `[A-Za-z0-9_]`, but a future entry with a `.` or
    # `[` would otherwise become a wildcard and re-open the same false-positive.
    esym="$(printf '%s' "$sym" | sed 's/[.[(){}+*?^$|\\]/\\&/g')"
    grep -Eq "(^|[^[:alnum:]_])${esym}([^[:alnum:]_]|$)" "$doc" || out+="${sym} "
  done
  printf '%s' "$out"
}

# ─── Scenario 1: each REQUIRED symbol appears in the schema doc ─────────────
it "every public run_record symbol is mentioned in docs/contracts/run-record-schema.md"
missing="$(missing_symbols "$SCHEMA_DOC")"
if [ -z "$missing" ]; then
  pass
else
  fail "missing from run-record-schema.md: ${missing}"
fi

# ─── Scenario 2: deliberate-fail — the fence's OWN checker, on a broken doc ──
# Plant a copy of the schema doc with a REQUIRED symbol stripped, and run
# missing_symbols — the real check, the real REQUIRED list — against it. It must name
# the stripped symbol. Nothing here re-implements the fence, so a fence that stopped
# working cannot leave this control green.
it "deliberate-fail: the fence's checker flags a symbol stripped from a planted doc"
tmpdir="$(mktemp -d -t doc-fence-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
# `exit_reason` is a substring of `set_exit_reason`, so stripping one strips both —
# and the control asserts BOTH come back, which also pins that REQUIRED still holds
# them (a REQUIRED that quietly lost them would fail here, not pass).
grep -v "exit_reason" "$SCHEMA_DOC" > "$tmpdir/schema.md"
df_missing="$(missing_symbols "$tmpdir/schema.md")"
df_bad=""
case "$df_missing" in *exit_reason*)     ;; *) df_bad="exit_reason " ;;     esac
case "$df_missing" in *set_exit_reason*) ;; *) df_bad+="set_exit_reason " ;; esac
if [ -z "$df_bad" ]; then
  pass
else
  fail "deliberate-fail: the fence did NOT flag ${df_bad}as missing from the planted-broken doc
      (checker returned: '${df_missing}') — the fence is vacuous."
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "doc-fence-run-record-schema.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
