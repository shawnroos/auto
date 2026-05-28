#!/usr/bin/env bash
# auto v0.4.0 U4: on-stop.py discovers committed batch sidecars and blocks
# stop until every sub-run's ledger predicate is met.
#
# Asserts:
#   - committed batch with all sub-runs unmet → BLOCK
#   - committed batch with all sub-runs met → ALLOW
#   - committed batch with sub-runs done (loop_phase=="done") → ALLOW
#   - provisional batch → IGNORED (half-built batch does NOT gate stop)
#   - batch with missing sub-run ledgers → ALLOW (no proof to block on)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="$ROOT/lib/on-stop.py"

# Each test gets a fresh fixture: a git repo with a worktree-per-plan
# layout. resolve_shared_dir() resolves to the main repo's .claude/auto/.
make_fixture() {
  local d
  d="$(mktemp -d)"
  (
    cd "$d"
    git init -q
    git commit --allow-empty -q -m "init"
    mkdir -p .claude/auto/batches
  )
  echo "$d"
}

# Plant a sub-run ledger inside a worktree.
# Args: <worktree-abs-path> <run-id> <met:true|false> <phase:plan|work|done>
plant_subrun() {
  local wt="$1" run="$2" met="$3" phase="$4"
  # Convert shell true/false to Python True/False for the heredoc.
  local py_met="True"
  [ "$met" = "false" ] && py_met="False"
  mkdir -p "${wt}/.claude/auto"
  "$PY" - <<PYEOF
import json, os
path = "${wt}/.claude/auto/${run}.json"
met = ${py_met}
data = {
  "run_id": "${run}",
  "loop_phase": "${phase}",
  "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00+00:00"},
  "exit_predicate_result": {
    "met": met,
    "blockers": 0 if met else 1,
    "majors": 0,
    "all_units_terminal": met,
  },
}
with open(path, "w") as f:
  json.dump(data, f)
PYEOF
}

# Plant a batch sidecar.
# Args: <repo> <batch-id> <status:provisional|committed> <plan-entries-json>
plant_sidecar() {
  local repo="$1" id="$2" status="$3" plans_json="$4"
  "$PY" - <<PYEOF
import json
sidecar = {
  "id": "${id}",
  "created_at": "2099-01-01T00:00:00Z",
  "status": "${status}",
  "composite_intent": "test batch",
  "plans": ${plans_json},
}
with open("${repo}/.claude/auto/batches/${id}.json", "w") as f:
  json.dump(sidecar, f)
PYEOF
}

# Invoke on-stop.py with cwd at the repo and check whether stdout decided
# to block.
on_stop_decision() {
  local repo="$1"
  (cd "$repo" && "$PY" "$ON_STOP" "$repo" </dev/null 2>/dev/null) || true
}

# ── Scenario 1: committed batch, both sub-runs unmet → BLOCK
auto_test::it "committed batch with unmet sub-runs blocks stop"
R1="$(make_fixture)"
WT_A="${R1}/worktrees/plan-a"
WT_B="${R1}/worktrees/plan-b"
mkdir -p "$WT_A" "$WT_B"
plant_subrun "$WT_A" "plan-a-2026-05-28" "false" "work"
plant_subrun "$WT_B" "plan-b-2026-05-28" "false" "work"
plant_sidecar "$R1" "test-batch-1" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"},
    {"path":"b","slug":"plan-b","worktree":"'"$WT_B"'","branch":"y","port":3002,"suggested_run_id":"plan-b-2026-05-28"}]'
out="$(on_stop_decision "$R1")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::pass
else
  auto_test::fail "expected block; got: $out"
fi
rm -rf "$R1"

# ── Scenario 2: committed batch, all sub-runs met → ALLOW
auto_test::it "committed batch with all sub-runs met allows stop"
R2="$(make_fixture)"
WT_A2="${R2}/worktrees/plan-a"
mkdir -p "$WT_A2"
plant_subrun "$WT_A2" "plan-a-2026-05-28" "true" "done"
plant_sidecar "$R2" "test-batch-2" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A2"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"}]'
out="$(on_stop_decision "$R2")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::fail "expected allow; got block: $out"
else
  auto_test::pass
fi
rm -rf "$R2"

# ── Scenario 3: provisional batch → IGNORED (does NOT gate stop)
auto_test::it "provisional batch does NOT block stop"
R3="$(make_fixture)"
WT_A3="${R3}/worktrees/plan-a"
mkdir -p "$WT_A3"
plant_subrun "$WT_A3" "plan-a-2026-05-28" "false" "work"
plant_sidecar "$R3" "test-batch-3" "provisional" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A3"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"}]'
out="$(on_stop_decision "$R3")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::fail "expected allow (provisional ignored); got block: $out"
else
  auto_test::pass
fi
rm -rf "$R3"

# ── Scenario 4: committed batch with missing sub-run ledgers → ALLOW
auto_test::it "committed batch with no sub-run ledgers allows stop"
R4="$(make_fixture)"
# Sidecar references a worktree but the sub-run never wrote its ledger.
mkdir -p "${R4}/worktrees/plan-a"
plant_sidecar "$R4" "test-batch-4" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"${R4}/worktrees/plan-a"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"}]'
out="$(on_stop_decision "$R4")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::fail "expected allow (no sub-run ledgers); got block: $out"
else
  auto_test::pass
fi
rm -rf "$R4"

# ── Scenario 5: mixed — one met, one unmet → BLOCK (the unmet one)
auto_test::it "committed batch with mixed states blocks on the unmet sub-run"
R5="$(make_fixture)"
WT_A5="${R5}/worktrees/plan-a"
WT_B5="${R5}/worktrees/plan-b"
mkdir -p "$WT_A5" "$WT_B5"
plant_subrun "$WT_A5" "plan-a-2026-05-28" "true" "done"
plant_subrun "$WT_B5" "plan-b-2026-05-28" "false" "work"
plant_sidecar "$R5" "test-batch-5" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A5"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"},
    {"path":"b","slug":"plan-b","worktree":"'"$WT_B5"'","branch":"y","port":3002,"suggested_run_id":"plan-b-2026-05-28"}]'
out="$(on_stop_decision "$R5")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"' && echo "$out" | grep -q "plan-b"; then
  auto_test::pass
else
  auto_test::fail "expected block citing plan-b; got: $out"
fi
rm -rf "$R5"

auto_test::summary
exit $?
