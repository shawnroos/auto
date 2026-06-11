#!/usr/bin/env bash
# auto v0.3.0 H mechanical defense: doc-fence for the ledger-schema contract.
#
# WHY THIS TEST EXISTS (the recurring class meta-finding from round-3 review):
# Round-1 / Round-2 / Round-3 each surfaced an instance of the recurring class
# "code adds a public ledger field or mutator without documenting it in
# docs/contracts/ledger-schema.md" — same shape as the prose-vs-code mismatch
# pattern, but applied to docs/code drift. G3 closed the round-2 instance for
# the recipe-format.md side (the F4-added expected_emit_outputs field); G2
# reproduced the SAME class on the ledger side by adding `exit_reason` +
# `set_exit_reason` without touching ledger-schema.md. H (this fix-pass) closes
# the instance AND adds this mechanical defense so the class can't quietly
# recur a fourth time.
#
# Mirror of tests/unit/wikilink-check.test.sh (G5's mechanical defense for the
# wikilink-leak class). Pattern: for every public ledger surface, the docs
# MUST mention it by name; the lint greps the doc + fails on absence.
#
# Maintenance contract: when you add a new top-level ledger field OR a new
# public ledger.py function, update this lint's `REQUIRED` list AND
# docs/contracts/ledger-schema.md. The lint fails fast; the doc keeps the
# operator surface discoverable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_DOC="${AUTO_ROOT}/docs/contracts/ledger-schema.md"

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

# The required-symbols list: every public ledger surface that the operator or
# an agent reading the docs would need. Adding a new public symbol to
# lib/ledger.py without adding it here is fine — but then this lint won't catch
# a doc-drift on that symbol. Adding it here is the load-bearing step. Keep
# the list narrow: only fields/functions an external consumer would need to
# understand. Helpers prefixed with `_` are NOT in scope.
#
# Order matters for readability only — the lint runs an unordered grep.
REQUIRED=(
  # v0.2.0 ledger surface (covered by U8's doc lock)
  "recipe"
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
  # v0.4.0 U1: goal_intent ledger field — one-line user-facing intent sentence
  "goal_intent"
  # v0.6.0 U5 (KTD-5): the advisor-gate session-ownership field + audit record
  # and their mutators.
  "driving_session_id"
  "advisor_audit"
  "set_driving_session_id"
  "append_advisor_audit"
)

# ─── Scenario 1: each REQUIRED symbol appears in the schema doc ─────────────
missing=""
for sym in "${REQUIRED[@]}"; do
  if ! grep -q -F -- "$sym" "$SCHEMA_DOC"; then
    missing+="${sym}\n"
  fi
done

it "every public ledger symbol is mentioned in docs/contracts/ledger-schema.md"
if [ -z "$missing" ]; then
  pass
else
  fail "missing from ledger-schema.md:
$(printf '%b' "$missing")"
fi

# ─── Scenario 2: deliberate-fail — proves the lint isn't vacuous ────────────
# Write a temporary copy of the schema doc with a known symbol removed; the
# lint MUST flag it. Mirrors G5's wikilink-check DF pattern.
it "deliberate-fail: stripping exit_reason from the schema doc trips the lint"
tmpdir="$(mktemp -d -t doc-fence-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
# Copy doc with exit_reason occurrences removed.
grep -v "exit_reason" "$SCHEMA_DOC" > "$tmpdir/schema.md"
# Re-run the grep against the planted-broken copy.
df_missing=""
for sym in "exit_reason" "set_exit_reason"; do
  if ! grep -q -F -- "$sym" "$tmpdir/schema.md"; then
    df_missing+="${sym} "
  fi
done
if [ -n "$df_missing" ]; then
  pass
else
  fail "deliberate-fail: lint did NOT catch removed symbols ${df_missing}"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "doc-fence-ledger-schema.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
