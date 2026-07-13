#!/usr/bin/env bash
# auto v0.4.3 unit test: the plan-loop FEEDBACK CLI surface — set-gaps-open and
# set-enumerated-steps (project_auto_v042_stuck_root_causes ④).
#
# WHY THIS TEST EXISTS: the model drives the plan-loop through Bash — its only
# run-record-write tool is `lib/run_record.sh`, NOT the Python mutators. Before v0.4.3
# the CLI exposed only read/path/transition/is-orphaned, so the operator-guidance
# instructions to "set_gaps_open" / "enumerate" named functions the model could
# not invoke — the same uninvokable-instruction bug class as the missing
# /auto-pulse command. This test asserts both feedback subcommands exist, persist
# correctly, resolve the repo from $CLAUDE_AUTO_REPO (so the model passes only the
# run-id), and reject malformed input — so the channel can't silently regress.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
RUN_RECORD_SH="${AUTO_ROOT}/lib/run_record.sh"

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

# Hermetic repo with one plan-phase step on the run-record.
REPO="$(mktemp -d)"
export CLAUDE_AUTO_REPO="$REPO"
mkdir -p "$REPO/.claude/auto"
"$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF'
import sys, os, importlib.util
auto_root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
run_record = load("run_record", os.path.join(auto_root, "lib", "run_record.py"))
run_record.init_run_record(repo, "rF", backend="ce",
                   steps=[{"id":"plan","phase":"plan","invokes":{"backend_op":"next_plan_step"}}],
                   loop_phase="plan")
PYEOF

read_field() {  # read_field <python-expr-over-led>
  "$PY" - "$AUTO_ROOT" "$REPO" "$1" <<'PYEOF'
import sys, os, importlib.util, json
auto_root, repo, expr = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
run_record = load("run_record", os.path.join(auto_root, "lib", "run_record.py"))
led = run_record.read_run_record(repo, "rF")
print(eval(expr))
PYEOF
}

# ─── set-enumerated-steps persists via the CLI (repo auto-resolved) ──────────
it "run_record.sh set-enumerated-steps persists onto the plan step (run-id only)"
bash "$RUN_RECORD_SH" set-enumerated-steps rF plan '[{"id":"w1","invokes":{"backend_op":"do_step"}}]' >/dev/null 2>&1
got="$(read_field '[u for u in led["steps"] if u["phase"]=="plan"][0]["dispatch_context"].get("enumerated_steps")')"
case "$got" in
  *"w1"*) pass ;;
  *) fail "enumerated_steps not persisted via CLI: ${got}" ;;
esac

# ─── set-gaps-open persists via the CLI ─────────────────────────────────────
it "run_record.sh set-gaps-open persists the gap count (run-id only)"
bash "$RUN_RECORD_SH" set-gaps-open rF 0 >/dev/null 2>&1
got_g="$(read_field 'led["exit_predicate_result"]["gaps_open"]')"
[ "$got_g" = "0" ] && pass || fail "gaps_open not 0 after CLI set-gaps-open: ${got_g}"

# ─── deliberate-fail: malformed enumerate payload is rejected (non-zero) ─────
it "deliberate-fail: a non-array enumerate payload is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" set-enumerated-steps rF plan '{"not":"an array"}' >/dev/null 2>&1; then
  fail "non-array payload was accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: unknown subcommand still rejected (guards the dispatch) ─
it "deliberate-fail: an unknown run_record subcommand is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" set-bogus rF 0 >/dev/null 2>&1; then
  fail "unknown subcommand was accepted"
else
  pass
fi

# ════════════════════════════════════════════════════════════════════════════
# U7 (concept-vocabulary rename): the work-node CLI verbs were HARD-CUT to their
# `step` spelling with NO deprecated aliases (KTD-4 — verbs are never persisted,
# so the only callers are this repo's skills, updated atomically, and driving
# agents, which the agent-tool-surface contract tells to orient via `describe`).
#
# Two things must hold, and only a CLI-level test can prove either:
#   1. the NEW verb actually round-trips through `lib/run_record.sh` (add → reshape-deps
#      → transition). The Python mutators are covered in steering-verbs.test.sh, but
#      the model's ONLY run-record-write tool is this shell CLI — the same
#      uninvokable-instruction bug class this file exists for.
#   2. the RETIRED verb is a hard exit 2, not a silent no-op, and the error points at
#      `describe` so a stale-vocabulary agent can re-orient in one step.
# ════════════════════════════════════════════════════════════════════════════

# ─── add-step round-trip through the CLI (add → reshape-deps → transition) ───
it "add-step round-trip: add a step, reshape its deps, then transition it"
rt_err=""
bash "$RUN_RECORD_SH" add-step rF w-rt '[]' work >/dev/null 2>&1 \
  || rt_err="add-step failed"
# depend it on the plan step (an existing id) — reshape-deps must accept the edge
[ -z "$rt_err" ] && { bash "$RUN_RECORD_SH" reshape-deps rF w-rt '["plan"]' >/dev/null 2>&1 \
  || rt_err="reshape-deps failed"; }
# transition takes the explicit <repo> argv (the legacy read-verb shape)
[ -z "$rt_err" ] && { bash "$RUN_RECORD_SH" transition "$REPO" rF w-rt dispatched >/dev/null 2>&1 \
  || rt_err="transition failed"; }
if [ -z "$rt_err" ]; then
  rt_state="$(read_field '[u for u in led["steps"] if u["id"]=="w-rt"][0]["state"]')"
  rt_deps="$(read_field '[u for u in led["steps"] if u["id"]=="w-rt"][0]["depends_on"]')"
  if [ "$rt_state" = "dispatched" ] && [ "$rt_deps" = "['plan']" ]; then
    pass
  else
    fail "add-step round-trip landed wrong: state=${rt_state} depends_on=${rt_deps}"
  fi
else
  fail "add-step round-trip broke at: ${rt_err}"
fi

# ─── the retired verbs are GONE: exit 2, and the error names `describe` ──────
# NB: the loop below necessarily SPELLS the retired verb names — it is the only place
# in the tree that may. The vocabulary-audit exempts exactly those two tokens, in
# exactly this file (path + content anchored), so any OTHER stale token from the
# retired vocabulary still fails the audit here.
for retired in add-unit set-enumerated-units; do
  it "hard-cut (KTD-4): retired verb '${retired}' exits 2 and points at describe"
  hc_out="$(bash "$RUN_RECORD_SH" "$retired" rF plan '[]' 2>&1)"
  hc_rc=$?
  if [ "$hc_rc" -ne 2 ]; then
    fail "retired verb '${retired}' exited ${hc_rc}, expected 2 (bad-args) — an alias may have crept back in"
  elif ! printf '%s' "$hc_out" | grep -q "unknown subcommand"; then
    fail "retired verb '${retired}' did not report 'unknown subcommand'; got: ${hc_out}"
  elif ! printf '%s' "$hc_out" | grep -q "describe"; then
    fail "retired verb '${retired}' rejected but did NOT point at \`describe\` — a stale-vocabulary agent cannot re-orient. got: ${hc_out}"
  else
    pass
  fi
done

# ════════════════════════════════════════════════════════════════════════════
# Work-loop VERDICT channel (v0.6.8) — record-verdict / set-verdict-decision.
# Same uninvokable-instruction bug class as the v0.4.3 feedback verbs: the
# work-loop drives through Bash, so the verdict + gate-decision mutators must be
# reachable as CLI verbs, repo auto-resolved from $CLAUDE_AUTO_REPO.
# ════════════════════════════════════════════════════════════════════════════

# record_verdict only writes from a dispatched/verdict-returned/stalled step, so
# move the seed plan step to dispatched first (transition takes an explicit repo).
bash "$RUN_RECORD_SH" transition "$REPO" rF plan dispatched >/dev/null 2>&1

# ─── record-verdict round-trips findings into the run-record (run-id only) ───────
it "run_record.sh record-verdict persists findings + flips the step to verdict-returned"
bash "$RUN_RECORD_SH" record-verdict rF plan '[{"severity":"blocker","note":"boom"}]' >/dev/null 2>&1
got_state="$(read_field '[u for u in led["steps"] if u["id"]=="plan"][0]["state"]')"
got_note="$(read_field '[u for u in led["steps"] if u["id"]=="plan"][0]["findings"][0]["note"]')"
if [ "$got_state" = "verdict-returned" ] && [ "$got_note" = "boom" ]; then
  pass
else
  fail "record-verdict did not persist (state=${got_state} note=${got_note})"
fi

# ─── set-verdict-decision persists the gate decision (run-id only) ───────────
it "run_record.sh set-verdict-decision persists dispatch_context.decision (run-id only)"
bash "$RUN_RECORD_SH" set-verdict-decision rF plan advance >/dev/null 2>&1
got_dec="$(read_field '[u for u in led["steps"] if u["id"]=="plan"][0]["dispatch_context"].get("decision")')"
[ "$got_dec" = "advance" ] && pass || fail "decision not persisted via CLI: ${got_dec}"

# ─── set-verdict-decision carries an optional JSON payload ───────────────────
it "run_record.sh set-verdict-decision persists an optional decision_payload"
bash "$RUN_RECORD_SH" set-verdict-decision rF plan iterate '{"emit_count":2}' >/dev/null 2>&1
got_pl="$(read_field '[u for u in led["steps"] if u["id"]=="plan"][0]["dispatch_context"]["decision_payload"]["emit_count"]')"
[ "$got_pl" = "2" ] && pass || fail "decision_payload not persisted: ${got_pl}"

# ─── deliberate-fail: non-array findings rejected (rc != 0) ──────────────────
it "deliberate-fail: record-verdict with non-array findings is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" record-verdict rF plan '{"not":"array"}' >/dev/null 2>&1; then
  fail "non-array findings accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: invalid finding severity rejected (rc != 0) ────────────
it "deliberate-fail: record-verdict with an invalid severity is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" record-verdict rF plan '[{"severity":"bogus","note":"x"}]' >/dev/null 2>&1; then
  fail "invalid severity accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: decision not in the enum rejected (rc != 0) ────────────
it "deliberate-fail: set-verdict-decision with a non-enum decision is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" set-verdict-decision rF plan bogus >/dev/null 2>&1; then
  fail "non-enum decision accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: unknown gate step rejected (rc != 0) ───────────────────
it "deliberate-fail: set-verdict-decision on an unknown step is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" set-verdict-decision rF nosuchunit advance >/dev/null 2>&1; then
  fail "unknown step accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: non-dict decision payload rejected (rc != 0) ───────────
it "deliberate-fail: set-verdict-decision with a non-object payload is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" set-verdict-decision rF plan advance '[1,2]' >/dev/null 2>&1; then
  fail "non-object decision payload accepted (should have failed)"
else
  pass
fi

# ─── deliberate-fail: non-integer record-verdict attempt rejected (rc != 0) ──
it "deliberate-fail: record-verdict with a non-integer attempt is rejected (rc != 0)"
if bash "$RUN_RECORD_SH" record-verdict rF plan '[{"severity":"minor","note":"x"}]' notanint >/dev/null 2>&1; then
  fail "non-integer attempt accepted (should have failed)"
else
  pass
fi

rm -rf "$REPO"
echo ""
echo "run-record-cli-feedback.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
