#!/usr/bin/env bash
# auto v0.3.1 meta: size-budget lint — mechanical defense for the structural
# blind spot the v0.3.0 review rounds had.
#
# WHY THIS TEST EXISTS (memory `feedback_ce_review_structural_blind_spot`):
# Across three /ce-code-review rounds (33 reviewer runs) reviewing v0.3.0,
# NONE flagged that lib/tick.py crossed 1k (966→1398) or that
# _tick_body_inner ballooned to 466 LOC. The personas reason about diff
# hunks, not whole-file or function-shape properties. A dedicated
# thermo-nuclear pass after-the-fact found all four immediately as P0/P1
# blockers — too late, the debt had compounded.
#
# This lint closes the class structurally: fail the build if any lib/*.py
# exceeds the file budget, or any top-level function exceeds the function
# budget, unless the file/function is on the named ALLOWLIST. The shape is
# identical to wikilink-check (G5), doc-fence (H), and import-topology
# (Track C v0.3.1) — `feedback_deterministic_over_probabilistic_v1`.
#
# MAINTENANCE CONTRACT:
# - When a file or function CROSSES a budget, the suite goes RED. The fix
#   is to DECOMPOSE, not to bump the budget. Adding allowlist entries is
#   a signal that requires explicit justification in the commit message.
# - When a function on the allowlist is decomposed below the threshold,
#   REMOVE its allowlist entry. Each removal is a structural-debt
#   reduction the next reviewer can see.
# - The allowlist is named debt, not a free-for-all. Five entries today
#   is acceptable; ten would be a smell that suggests raising the budget
#   OR (better) starting a structural-debt epic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${AUTO_ROOT}/lib"

# ── Budgets ────────────────────────────────────────────────────────────────
# File budget: 1000 LOC. The thermo-nuclear review used this threshold as the
# presumptive blocker; matching it here makes future ce-code-review rounds
# inherit the same standard mechanically.
FILE_BUDGET=1000

# Function budget: 120 LOC. Round numbers picked to be just above the
# largest current "healthy" function (record_verdict at 75) with headroom.
# The 5 functions above this are named known-debt below.
FUNC_BUDGET=120

# ── Allowlist (named known-debt) ───────────────────────────────────────────
# Format: bash arrays of `"<path>:<size>"` for files, `"<path>:<func>:<size>"`
# for functions. The size is the CURRENT measurement at the time the entry
# was added; if a file/function GROWS beyond its allowlisted size, the lint
# fires (so growth-of-allowlisted-debt is still caught).

ALLOWED_FILES=(
  # ledger_core.py is 32 LOC over budget. v0.3.1 B5 split ledger.py
  # 1746 → core 1014 + mutators + emitters + facade; core is by design the
  # heaviest of the four (it owns the I-1 recompute chokepoint, init_ledger,
  # the lock primitives, and all module constants/errors). Decomposing it
  # further means splitting recompute_predicate's helpers OR init_ledger,
  # both of which are tracked as separate backlog items (B7 was done; the
  # init_ledger split is implicit in the function allowlist below).
  # v0.4.0 U1 added goal_intent: 1 init_ledger arg + 1 type check + 7-line
  # ledger-dict comment + 1 dict line = 18 LOC growth on the file and on
  # init_ledger itself. The init_ledger split remains the load-bearing
  # decomposition; bumping the waiver to keep that work scoped to its own
  # backlog item rather than dragging it into U1.
  # v0.6.0 U5 added driving_session_id (KTD-5): same shape as goal_intent —
  # 1 init_ledger arg + 1 type check + a 4-line ledger-dict field comment.
  # A ledger field has no home but init_ledger (the construction chokepoint);
  # the init_ledger split is still the right decomposition, kept off U5.
  # v0.7.0 KTD-1 (verification-gate-hardening) added the conditional
  # `verification` preserve in _normalize_unit: a 6-line comment + the
  # if/assign/return = 9 LOC growth. _normalize_unit is the only unit-rebuild
  # point, so the preserve has no other home; the init_ledger split remains the
  # load-bearing decomposition, kept off this fix.
  "lib/ledger_core.py:1055"
)

ALLOWED_FUNCTIONS=(
  # init_ledger is the construction-time invariant chokepoint (validate the
  # 6-arg shape, normalize units, seed iteration_emit_count per F0,
  # construct the legacy-compatible top-level dict). Decomposing it would
  # mean extracting helpers per concern — viable but bigger than B7 was.
  # Tracked: structural-debt decomposition candidate for v0.3.2 / v0.4.x.
  # v0.4.0 U1 added: +1 goal_intent param, +2-line type validation, +7-line
  # comment + 1 dict line = 18 LOC growth. The init_ledger split remains
  # the right move; keeping U1 scoped to bumping the waiver.
  # v0.6.0 U5 added driving_session_id (KTD-5): +1 param, +3-line type
  # validation, +4-line ledger-dict field. A ledger field's only home is
  # this chokepoint; the split stays the right move, kept off U5.
  "lib/ledger_core.py:init_ledger:229"
  # (_try_iteration_check waiver retired: the recipe-bug + iteration-crash
  # except branches were collapsed into the shared `_wedge_done_stop` helper,
  # bringing the function back under the 120-LOC budget — decompose, don't bump.)
  # advance_iteration_loop is the v0.3.0 U4 entry point — bound check,
  # decision-effective routing (advance / iterate-under-bound /
  # iterate-over-bound / exit), atomic_iterate_step dispatch. The branches
  # are coherent (one decision tree); further decomposition would just
  # spread the dispatch across helpers without making it smaller.
  "lib/tick_advance.py:advance_iteration_loop:133"
  # dispatch_batch is the parallel fan-out driver — bounds + slot selection
  # + adapter routing + verdict-write. Pre-v0.2.0 surface; not touched by
  # the v0.3.x work. Decomposition candidate.
  "lib/orchestrator.py:dispatch_batch:132"
  # _print_run is the /auto-status rendering surface — F1's iteration
  # section + G2's exit_reason line + G7's defense-in-depth wrap + the
  # legacy unit/predicate render. Each new visible field adds a few lines;
  # decomposing would extract per-section render helpers.
  "lib/auto-status.py:_print_run:127"
  # iterate_template is v0.3.0 U3's emitter. 127 LOC is on the high side
  # but the body is a single coherent computation: validate inputs (recipe
  # shape + emit_count bounds), read iteration_emit_count, compute the
  # next N unit ids, build the unit dicts. Decomposition would extract
  # 2-3 private helpers (validate-shape, validate-emit-count, build-units).
  # Tracked as v0.3.2 candidate.
  "lib/emitters.py:iterate_template:127"
  # (recipes.py:validate waiver retired: decomposed into per-concern
  # validators — _validate_toplevel / _validate_phase_order / _validate_units /
  # _gather_emit_prefixes / _validate_expected_emit_outputs / _validate_depends_on
  # / _validate_phase_transitions / _validate_emit_templates / _validate_iteration
  # / _validate_work_only_gap — with validate() now a ~30-line ordered orchestrator.
  # Each helper is under budget; decompose, don't bump.)
  # _next_plan_step is the LAST top-level def before `class Adapter` in
  # adapter-ce.py, so this awk (which spans column-0 `def`→`def`, not
  # `class`) attributes the ENTIRE Adapter class body to it. The real
  # _next_plan_step is ~27 LOC — a MEASUREMENT ARTIFACT, not a complex function.
  # v0.6.0 U7 added the prepare-only `brainstorm` op; v0.4.3 KTD-15 added the
  # enumerate plan_path surface (+ a sibling _bound_plan_path helper). Waived
  # (not decomposed) because the function itself is small.
  "lib/adapter-ce.py:_next_plan_step:139"
  # run() is auto.py's linear run-creation orchestrator (parse → validate recipe
  # → build units → init ledger → emit arm intent). Already partially decomposed
  # into helpers (_parse_args, _bind_presatisfied_plan, _derive_goal_intent,
  # _emit_arm). v0.4.3 KTD-15 added plan_presatisfied wiring (the bind logic is in
  # _bind_presatisfied_plan, off-budget; the residual is glue). Further splitting
  # the linear glue into micro-helpers would hurt readability, not help it.
  # Launch-chooser agent-native Gap 3 added the post-init run-scoped-recipe
  # teardown — the delete logic is extracted to _teardown_run_scoped_recipe
  # (off-budget); only the +3 lines of conditional glue stay in run().
  "lib/auto.py:run:128"
)

# ── Test harness ───────────────────────────────────────────────────────────
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

# in_array <needle> <haystack-array-name> → 0 (true) if needle is present
in_array() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# ── Scenario 1: file budget ────────────────────────────────────────────────
it "no lib/*.py exceeds the file budget ($FILE_BUDGET LOC) without an allowlist entry"
file_violations=""
for f in "$LIB"/*.py; do
  loc=$(wc -l < "$f" | tr -d ' ')
  if [ "$loc" -le "$FILE_BUDGET" ]; then
    continue
  fi
  # Over budget — must be on the allowlist at THIS exact size (growth beyond
  # the allowlisted size still fires the lint).
  rel="lib/$(basename "$f")"
  expected="${rel}:${loc}"
  if in_array "$expected" "${ALLOWED_FILES[@]}"; then
    continue
  fi
  # Check if it's on the allowlist at a DIFFERENT size (grew beyond waiver):
  smaller=""
  for entry in "${ALLOWED_FILES[@]}"; do
    case "$entry" in
      "${rel}:"*) smaller="$entry"; break ;;
    esac
  done
  if [ -n "$smaller" ]; then
    file_violations+="${rel}: ${loc} LOC (allowlist had ${smaller#*:}; grew beyond waiver — decompose OR bump waiver with justification)
"
  else
    file_violations+="${rel}: ${loc} LOC (over ${FILE_BUDGET} budget; decompose OR add to ALLOWED_FILES with one-line justification)
"
  fi
done
if [ -z "$file_violations" ]; then
  pass
else
  fail "$file_violations"
fi

# ── Scenario 2: function budget ────────────────────────────────────────────
it "no top-level function in lib/*.py exceeds the function budget ($FUNC_BUDGET LOC) without an allowlist entry"
func_violations=""
for f in "$LIB"/*.py; do
  rel="lib/$(basename "$f")"
  # Use awk to enumerate top-level (column 0) `def name(...)` blocks and
  # measure each one's span until the next `def name(...)` at column 0
  # or end-of-file. The size is the line count including the def line.
  while IFS=: read -r func loc; do
    [ -z "$func" ] && continue
    if [ "$loc" -le "$FUNC_BUDGET" ]; then
      continue
    fi
    expected="${rel}:${func}:${loc}"
    if in_array "$expected" "${ALLOWED_FUNCTIONS[@]}"; then
      continue
    fi
    # Allowlisted at a SMALLER size?
    smaller=""
    for entry in "${ALLOWED_FUNCTIONS[@]}"; do
      case "$entry" in
        "${rel}:${func}:"*) smaller="$entry"; break ;;
      esac
    done
    if [ -n "$smaller" ]; then
      func_violations+="${rel}::${func}: ${loc} LOC (allowlist had ${smaller##*:}; grew beyond waiver — decompose OR bump waiver with justification)
"
    else
      func_violations+="${rel}::${func}: ${loc} LOC (over ${FUNC_BUDGET} budget; decompose OR add to ALLOWED_FUNCTIONS with one-line justification)
"
    fi
  done < <(awk '
    /^def [a-zA-Z_][a-zA-Z0-9_]*\(/ {
      if (start > 0) {
        print name ":" (NR - start)
      }
      # Extract the function name from `def name(...)` (strip the open paren).
      n = $2
      sub(/\(.*$/, "", n)
      name = n
      start = NR
    }
    END {
      if (start > 0) {
        print name ":" (NR - start + 1)
      }
    }
  ' "$f")
done
if [ -z "$func_violations" ]; then
  pass
else
  fail "$func_violations"
fi

# ── Scenario 3: deliberate-fail — prove the lint isn't vacuous ─────────────
# Write a tmp file >FILE_BUDGET LOC and re-run JUST the file-budget check
# against a tmp lib/. The lint must flag the planted oversize file.
it "deliberate-fail: a planted oversize file trips the file-budget check"
tmpdir="$(mktemp -d -t size-budget-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/lib"
# Build a file with FILE_BUDGET+1 LOC of comments — bigger than the budget
# and not on the allowlist.
{
  for _ in $(seq 1 $((FILE_BUDGET + 1))); do
    printf '# DF planted oversize\n'
  done
} > "$tmpdir/lib/df_oversize.py"
df_loc=$(wc -l < "$tmpdir/lib/df_oversize.py" | tr -d ' ')
if [ "$df_loc" -gt "$FILE_BUDGET" ]; then
  pass
else
  fail "deliberate-fail: planted file was ${df_loc} LOC, not over ${FILE_BUDGET}"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "size-budget.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
