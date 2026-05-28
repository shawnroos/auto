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
  "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
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

# ── Scenario 4b: sub-run with driver=manual (seam pause) → ALLOW
# Regression for review round 1 finding C-1: the batch loop must apply
# the same seam/manual carve-out as the per-worktree loop. Otherwise a
# fanned-out sub-run paused at the seam blocks the parent forever.
auto_test::it "committed batch with sub-run paused at seam (driver=manual) allows stop"
R4b="$(make_fixture)"
WT_A4b="${R4b}/worktrees/plan-a"
mkdir -p "$WT_A4b/.claude/auto"
"$PY" - <<PYEOF
import json
data = {
  "run_id": "plan-a-2026-05-28",
  "loop_phase": "seam",
  "loop": {"driver": "manual", "last_beat_at": "2099-01-01T00:00:00Z"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "all_units_terminal": False},
}
with open("${WT_A4b}/.claude/auto/plan-a-2026-05-28.json", "w") as f:
  json.dump(data, f)
PYEOF
plant_sidecar "$R4b" "test-batch-4b" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A4b"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"}]'
out="$(on_stop_decision "$R4b")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::fail "expected allow (seam-paused sub-run); got block: $out"
else
  auto_test::pass
fi
rm -rf "$R4b"

# ── Scenario 4c: sub-run with driver=self + stale last_beat → ALLOW
# Regression for review round 1 finding C-1: the batch loop must apply
# the dead-self-chain staleness gate. A sub-run whose tick chain died
# (driver=self, last_beat far in the past) must NOT block stop forever.
auto_test::it "committed batch with stale self-driven sub-run allows stop"
R4c="$(make_fixture)"
WT_A4c="${R4c}/worktrees/plan-a"
mkdir -p "$WT_A4c/.claude/auto"
"$PY" - <<PYEOF
import json
data = {
  "run_id": "plan-a-2026-05-28",
  "loop_phase": "work",
  "loop": {"driver": "self", "last_beat_at": "2020-01-01T00:00:00Z"},
  "exit_predicate_result": {"met": False, "blockers": 1, "majors": 0, "all_units_terminal": False},
}
with open("${WT_A4c}/.claude/auto/plan-a-2026-05-28.json", "w") as f:
  json.dump(data, f)
PYEOF
plant_sidecar "$R4c" "test-batch-4c" "committed" \
  '[{"path":"a","slug":"plan-a","worktree":"'"$WT_A4c"'","branch":"x","port":3001,"suggested_run_id":"plan-a-2026-05-28"}]'
out="$(on_stop_decision "$R4c")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::fail "expected allow (stale dead chain); got block: $out"
else
  auto_test::pass
fi
rm -rf "$R4c"

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

# ── Scenario 6: worktree-resident Stop sees the host's batches/
# Regression for review round 2 finding R2-1: the round-1 isdir fast-path
# used `isdir(.git/worktrees)` to detect worktree contexts, but inside
# a worktree `.git` is a gitlink FILE not a directory, so the check
# always returned False there. Round-2 fix uses `isfile(.git)` as the
# worktree signal.
auto_test::it "worktree-resident Stop discovers host batches and blocks correctly"
R6="$(make_fixture)"
WT_R6="${R6}/worktrees/plan-z"
# Create a real git worktree (its .git is a gitlink file).
(cd "$R6" && git worktree add -b auto/plan-z "$WT_R6" >/dev/null 2>&1)
# Sub-run ledger at worktree-local path.
plant_subrun "$WT_R6" "plan-z-2026-05-28" "false" "work"
# Host's batches/ sidecar references it.
plant_sidecar "$R6" "test-batch-6" "committed" \
  '[{"path":"z","slug":"plan-z","worktree":"'"$WT_R6"'","branch":"auto/plan-z","port":3001,"suggested_run_id":"plan-z-2026-05-28"}]'
# Invoke on-stop with REPO arg pointing at the WORKTREE (operator stops from inside it).
out="$(on_stop_decision "$WT_R6")"
if echo "$out" | grep -q '"decision":[[:space:]]*"block"'; then
  auto_test::pass
else
  auto_test::fail "expected block (worktree-resident Stop sees host batches); got: $out"
fi
(cd "$R6" && git worktree remove -f "$WT_R6" >/dev/null 2>&1 || true)
rm -rf "$R6"

auto_test::summary
exit $?
