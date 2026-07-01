#!/usr/bin/env bash
# auto v0.4.0 U1: hypothesis-shape lint for auto-detect.sh.
#
# v0.4.0 KTD-1: auto-detect.sh emits a JSON HYPOTHESIS envelope (not a TSV
# verdict). This test pins:
#   1. one of the six valid situations,
#   2. the envelope shape (every slot present, even when null),
#   3. discriminated-union population (single_plan vs multi_plan vs in_flight),
#   4. ambiguity-array shape on the ambiguous-runs branch,
#   5. dirty-tree triggers on uncommitted changes,
#   6. goal_intent (when present on the ledger) feeds the in-flight summary +
#      ambiguous-runs option descriptions,
#   7. exit 0 on every path (rel-001 / hook-safety).
#
# Each scenario is hermetic: a temp repo + git init + the minimum on-disk
# state to exercise one branch. The detector is invoked via the .sh shim so
# the test exercises the user-facing surface.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DET="${AUTO_ROOT}/lib/auto-detect.sh"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-hyp-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-hyp-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helper: build a hermetic repo, run detect, return parsed JSON via jq-ish python.
#
# json_field <setup-fn> <python-expr-on-hypothesis-named-H>
#   Each setup-fn takes the repo path and seeds whatever state the scenario
#   needs. We run `git init` so the dirty-tree branch can probe the index.
json_field() {
  local setup_fn="$1" expr="$2"
  local repo; repo="$(mktemp -d -t hyp-repo.XXXXXX)"
  (
    cd "$repo"
    git init -q .
    # Quiet down git's default-branch + user prompts.
    git config user.email test@test
    git config user.name test
    # Mirror the real-repo gitignore so .claude/auto/*.json and docs/plans/
    # don't show up in `git status` and falsely trigger the dirty-tree branch.
    # Then commit the gitignore so the working tree starts clean for the
    # setup-fn to mutate (only the explicit untracked-file scenario should
    # leave a dirty tree).
    printf '.claude/\ndocs/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  ) >/dev/null 2>&1
  mkdir -p "$repo/.claude/auto"
  "$setup_fn" "$repo"
  local raw
  raw="$(CLAUDE_AUTO_REPO="$repo" bash "$DET")"
  rm -rf "$repo"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
# Print booleans as Python literals (matches the rest of the suite).
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

# Same as json_field but exports one extra env var (KEY=VALUE) for the detect
# call — used to exercise CLAUDE_AUTO_INFLIGHT_TTL_SECONDS knob/floor.
json_field_env() {
  local kv="$1" setup_fn="$2" expr="$3"
  local repo; repo="$(mktemp -d -t hyp-repo.XXXXXX)"
  (
    cd "$repo"
    git init -q .
    git config user.email test@test
    git config user.name test
    printf '.claude/\ndocs/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  ) >/dev/null 2>&1
  mkdir -p "$repo/.claude/auto"
  "$setup_fn" "$repo"
  local raw
  raw="$(env "$kv" CLAUDE_AUTO_REPO="$repo" bash "$DET")"
  rm -rf "$repo"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

# Variant of json_field that TRACKS docs/ (only .claude/ gitignored) so a setup
# can commit plans with controlled dates and leave others uncommitted — the only
# way to exercise the U1/U2 fresh-vs-stale routing at the detector level (the
# default json_field gitignores docs/, making every plan git-silent → mtime-
# fresh, which is exactly the backward-compat path the other scenarios pin).
json_field_tracked() {
  local setup_fn="$1" expr="$2"
  local repo; repo="$(mktemp -d -t hyp-repo.XXXXXX)"
  (
    cd "$repo"
    git init -q .
    git config user.email test@test
    git config user.name test
    printf '.claude/\n' > .gitignore   # docs/ IS tracked here
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  ) >/dev/null 2>&1
  mkdir -p "$repo/.claude/auto"
  "$setup_fn" "$repo"
  local raw
  raw="$(CLAUDE_AUTO_REPO="$repo" bash "$DET")"
  rm -rf "$repo"
  "$PY" - "$raw" "$expr" <<'PYEOF'
import json, sys
raw, expr = sys.argv[1], sys.argv[2]
H = json.loads(raw)
val = eval(expr)
if isinstance(val, bool):
    print("True" if val else "False")
elif val is None:
    print("None")
else:
    print(val)
PYEOF
}

# ── Scenario setups ────────────────────────────────────────────────────────
setup_raw() { :; }

setup_plan() {
  mkdir -p "$1/docs/plans"
  echo "# Build the foo widget" > "$1/docs/plans/foo-plan.md"
}

setup_three_plans() {
  mkdir -p "$1/docs/plans"
  echo "# alpha" > "$1/docs/plans/alpha-plan.md"
  echo "# beta"  > "$1/docs/plans/beta-plan.md"
  echo "# gamma" > "$1/docs/plans/gamma-plan.md"
}

setup_inflight_one() {
  cat > "$1/.claude/auto/runA.json" <<'EOF'
{"run_id":"runA","exit_predicate_result":{"met":false},"goal_intent":"Ship the login fix"}
EOF
}

setup_inflight_two() {
  cat > "$1/.claude/auto/runA.json" <<'EOF'
{"run_id":"runA","exit_predicate_result":{"met":false},"goal_intent":"Ship the login fix"}
EOF
  # Touch a moment later so mtime ordering is stable.
  sleep 0.01
  cat > "$1/.claude/auto/runB.json" <<'EOF'
{"run_id":"runB","exit_predicate_result":{"met":false},"goal_intent":"Retire deprecated cron"}
EOF
}

setup_inflight_no_goal() {
  cat > "$1/.claude/auto/runX.json" <<'EOF'
{"run_id":"runX","exit_predicate_result":{"met":false}}
EOF
}

setup_inflight_stale() {
  # A single not-met run whose ledger has not been touched in months — well
  # beyond the default staleness TTL (1 day). Backdating mtime exercises the
  # real default, not a test-only env knob.
  cat > "$1/.claude/auto/runStale.json" <<'EOF'
{"run_id":"runStale","exit_predicate_result":{"met":false},"goal_intent":"Abandoned weeks ago"}
EOF
  touch -t 202601010000 "$1/.claude/auto/runStale.json"
}

setup_inflight_future() {
  # A not-met run with a FUTURE mtime (clock skew / restored backup). The gate
  # must treat this as anomalous → ask, NOT clamp-to-fresh → silent resume
  # (the adversarial-review P1 regression).
  cat > "$1/.claude/auto/runFuture.json" <<'EOF'
{"run_id":"runFuture","exit_predicate_result":{"met":false}}
EOF
  touch -t 203001010000 "$1/.claude/auto/runFuture.json"
}

setup_inflight_90min() {
  # A not-met run aged ~90 minutes — used with TTL=0 to exercise the _fmt_age
  # hours branch ("1h") in the operator-facing summary.
  cat > "$1/.claude/auto/run90.json" <<'EOF'
{"run_id":"run90","exit_predicate_result":{"met":false}}
EOF
  touch -t "$(date -v-90M +%Y%m%d%H%M 2>/dev/null || date -d '90 minutes ago' +%Y%m%d%H%M)" \
    "$1/.claude/auto/run90.json"
}

setup_done_run() {
  cat > "$1/.claude/auto/runZ.json" <<'EOF'
{"run_id":"runZ","exit_predicate_result":{"met":true}}
EOF
}

setup_dirty_tree() {
  echo "scratch" > "$1/scratch.txt"
  # We do NOT commit — leaving an untracked file makes git status non-empty.
}

setup_malformed() {
  echo "{ this is not valid json" > "$1/.claude/auto/bad.json"
}

# ── Scenario 1: raw envelope shape ─────────────────────────────────────────
it "raw: situation=raw with open-ambiguity question"
assert_eq "raw" "$(json_field setup_raw 'H["situation"]')"

it "raw: ambiguity.kind == open"
assert_eq "open" "$(json_field setup_raw 'H["ambiguity"]["kind"]')"

it "raw: single_plan slot is null"
assert_eq "None" "$(json_field setup_raw 'H["single_plan"]')"

it "raw: multi_plan slot is null"
assert_eq "None" "$(json_field setup_raw 'H["multi_plan"]')"

it "raw: in_flight slot is null"
assert_eq "None" "$(json_field setup_raw 'H["in_flight"]')"

# ── Scenario 2: reviewed-plan with single_plan populated ───────────────────
it "reviewed-plan: situation=reviewed-plan when exactly one plan present"
assert_eq "reviewed-plan" "$(json_field setup_plan 'H["situation"]')"

it "reviewed-plan: single_plan.path is the relpath to the plan"
assert_eq "docs/plans/foo-plan.md" "$(json_field setup_plan 'H["single_plan"]["path"]')"

it "reviewed-plan: ambiguity is null (no question to ask)"
assert_eq "None" "$(json_field setup_plan 'H["ambiguity"]')"

# ── Scenario 3: multi-plan (the v0.4.0 rename of ambiguous-plans) ──────────
it "multi-plan: situation=multi-plan when more than one plan present"
assert_eq "multi-plan" "$(json_field setup_three_plans 'H["situation"]')"

it "multi-plan: multi_plan.paths has all three plans"
assert_eq "3" "$(json_field setup_three_plans 'len(H["multi_plan"]["paths"])')"

# B2 (2026-06 misfire fix): multi-plan must NOT auto-dispatch a worktree fanout
# on scraped docs. The detector now sets ambiguity so the driver CONFIRMS first
# (the highest-blast-radius path — fanout spawns worktrees + ports).
it "multi-plan: ambiguity is NON-null — confirm before spawning worktrees"
assert_eq "False" "$(json_field setup_three_plans 'H["ambiguity"] is None')"

it "multi-plan: ambiguity.kind == choice"
assert_eq "choice" "$(json_field setup_three_plans 'H["ambiguity"]["kind"]')"

it "multi-plan: options = one per plan + a fan-out-all option (3 + 1)"
assert_eq "4" "$(json_field setup_three_plans 'len(H["ambiguity"]["options"])')"

it "multi-plan: each per-plan option carries its path"
assert_eq "3" "$(json_field setup_three_plans 'len([o for o in H["ambiguity"]["options"] if o.get("path")])')"

it "multi-plan: the fan-out-all option has a null path (uses multi_plan.paths)"
assert_eq "1" "$(json_field setup_three_plans 'len([o for o in H["ambiguity"]["options"] if o.get("path") is None])')"

it "multi-plan: multi_plan.paths is still populated (fanout target preserved)"
assert_eq "3" "$(json_field setup_three_plans 'len(H["multi_plan"]["paths"])')"

# ── Scenario 3b: U1/U2 freshness routing (docs/ tracked so git sees fresh/stale)
# A single FRESH plan (uncommitted this session) among STALE committed siblings
# is inferred as the reviewed plan — no multi-plan ask (the 2026-06 field case:
# 6 plans, 1 live). And an all-stale set drops the fan-out-all footgun.
setup_one_fresh_among_stale() {
  local repo="$1"
  mkdir -p "$repo/docs/plans"
  echo "# s1" > "$repo/docs/plans/s1-plan.md"
  echo "# s2" > "$repo/docs/plans/s2-plan.md"
  git -C "$repo" add docs/plans/ >/dev/null 2>&1
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
    git -C "$repo" -c commit.gpgsign=false commit -q -m stale >/dev/null 2>&1
  echo "# live" > "$repo/docs/plans/z-live-plan.md"   # uncommitted → fresh
}
it "one-fresh-among-stale: situation=reviewed-plan (live plan inferred)"
assert_eq "reviewed-plan" "$(json_field_tracked setup_one_fresh_among_stale 'H["situation"]')"
it "one-fresh-among-stale: single_plan.path is the fresh (uncommitted) plan"
assert_eq "docs/plans/z-live-plan.md" "$(json_field_tracked setup_one_fresh_among_stale 'H["single_plan"]["path"]')"

setup_all_stale_multi() {
  local repo="$1"
  mkdir -p "$repo/docs/plans"
  echo "# s1" > "$repo/docs/plans/s1-plan.md"
  echo "# s2" > "$repo/docs/plans/s2-plan.md"
  echo "# s3" > "$repo/docs/plans/s3-plan.md"
  git -C "$repo" add docs/plans/ >/dev/null 2>&1
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
    git -C "$repo" -c commit.gpgsign=false commit -q -m stale >/dev/null 2>&1
}
it "all-stale-multi: situation=multi-plan (no live plan to infer)"
assert_eq "multi-plan" "$(json_field_tracked setup_all_stale_multi 'H["situation"]')"
it "all-stale-multi: options = one per plan, NO fan-out-all (footgun suppressed)"
assert_eq "3" "$(json_field_tracked setup_all_stale_multi 'len(H["ambiguity"]["options"])')"
it "all-stale-multi: no null-path fan-out option present"
assert_eq "0" "$(json_field_tracked setup_all_stale_multi 'len([o for o in H["ambiguity"]["options"] if o.get("path") is None])')"
it "all-stale-multi: each option is staleness-marked"
assert_eq "3" "$(json_field_tracked setup_all_stale_multi 'len([o for o in H["ambiguity"]["options"] if "stale" in o["description"]])')"
it "all-stale-multi: multi_plan.paths still populated"
assert_eq "3" "$(json_field_tracked setup_all_stale_multi 'len(H["multi_plan"]["paths"])')"

# ── Scenario 4: in-flight single + goal_intent feeds summary ───────────────
it "in-flight: situation=in-flight when one not-met run present"
assert_eq "in-flight" "$(json_field setup_inflight_one 'H["situation"]')"

it "in-flight: in_flight.run_id is the single run-id"
assert_eq "runA" "$(json_field setup_inflight_one 'H["in_flight"]["run_id"]')"

it "in-flight: summary surfaces the goal_intent from the ledger"
# The exact phrasing is operator-friendly — we just assert goal_intent appears.
assert_eq "True" "$(json_field setup_inflight_one '"Ship the login fix" in H["summary"]')"

it "in-flight: ambiguity is null when there's exactly one FRESH run"
# A recently-active run is high-confidence → silent resume (unchanged behavior).
assert_eq "None" "$(json_field setup_inflight_one 'H["ambiguity"]')"

# B1 (2026-06 misfire fix): a STALE single run (idle beyond the TTL) is
# low-confidence — the detector keeps situation=in-flight but sets ambiguity so
# the driver ASKS (resume vs start-fresh) instead of silently auto-resuming a
# 15-day-old, possibly-unrelated run.
it "stale in-flight: situation is still in-flight"
assert_eq "in-flight" "$(json_field setup_inflight_stale 'H["situation"]')"

it "stale in-flight: ambiguity is NON-null — ask, do not silent-resume"
assert_eq "False" "$(json_field setup_inflight_stale 'H["ambiguity"] is None')"

it "stale in-flight: ambiguity.kind == choice"
assert_eq "choice" "$(json_field setup_inflight_stale 'H["ambiguity"]["kind"]')"

it "stale in-flight: a resume option still carries the run_id"
assert_eq "True" "$(json_field setup_inflight_stale 'any(o.get("run_id")=="runStale" for o in H["ambiguity"]["options"])')"

it "stale in-flight: a start-fresh option exists (run_id null)"
assert_eq "True" "$(json_field setup_inflight_stale 'any(o.get("run_id") is None for o in H["ambiguity"]["options"])')"

it "stale in-flight: in_flight.run_id still set so the driver can resume on confirm"
assert_eq "runStale" "$(json_field setup_inflight_stale 'H["in_flight"]["run_id"]')"

# B1 regression (adversarial review P1): a FUTURE-dated mtime (clock skew) must
# NOT be clamped to "fresh" and silently resumed — it must ask.
it "future-mtime in-flight: ambiguity is NON-null — anomalous clock does not silent-resume"
assert_eq "False" "$(json_field setup_inflight_future 'H["ambiguity"] is None')"

it "future-mtime in-flight: situation is still in-flight"
assert_eq "in-flight" "$(json_field setup_inflight_future 'H["situation"]')"

# CLAUDE_AUTO_INFLIGHT_TTL_SECONDS knob + floor (testing/standards review).
it "TTL=0 forces ask even on a run created this instant (always-ask floor)"
assert_eq "False" "$(json_field_env CLAUDE_AUTO_INFLIGHT_TTL_SECONDS=0 setup_inflight_one 'H["ambiguity"] is None')"

it "TTL negative is floored to 0 (still asks on a fresh run)"
assert_eq "False" "$(json_field_env CLAUDE_AUTO_INFLIGHT_TTL_SECONDS=-5 setup_inflight_one 'H["ambiguity"] is None')"

it "large TTL keeps a day-old run silent (knob raises the staleness threshold)"
# 1 year TTL → the months-old stale run is now within window → silent resume.
assert_eq "None" "$(json_field_env CLAUDE_AUTO_INFLIGHT_TTL_SECONDS=31536000 setup_inflight_stale 'H["ambiguity"]')"

it "_fmt_age hours branch: a 90-min-old run renders idle '1h' in the summary"
assert_eq "True" "$(json_field_env CLAUDE_AUTO_INFLIGHT_TTL_SECONDS=0 setup_inflight_90min '"1h" in H["summary"]')"

# ── Scenario 5: ambiguous-runs with options carrying goal_intent ───────────
it "ambiguous-runs: situation when more than one in-flight run"
assert_eq "ambiguous-runs" "$(json_field setup_inflight_two 'H["situation"]')"

it "ambiguous-runs: ambiguity.options has both run-ids"
assert_eq "2" "$(json_field setup_inflight_two 'len(H["ambiguity"]["options"])')"

it "ambiguous-runs: option description carries goal_intent for run B"
assert_eq "True" "$(json_field setup_inflight_two 'any(o["description"]=="Retire deprecated cron" for o in H["ambiguity"]["options"])')"

it "ambiguous-runs: in_flight.run_ids has both ids"
assert_eq "2" "$(json_field setup_inflight_two 'len(H["in_flight"]["run_ids"])')"

it "ambiguous-runs: ambiguity.kind == choice (N-option pick-one)"
assert_eq "choice" "$(json_field setup_inflight_two 'H["ambiguity"]["kind"]')"

# ── Scenario 6: in-flight WITHOUT goal_intent falls back gracefully ────────
it "in-flight no goal_intent: situation is still in-flight"
assert_eq "in-flight" "$(json_field setup_inflight_no_goal 'H["situation"]')"

it "in-flight no goal_intent: summary still references the run_id"
assert_eq "True" "$(json_field setup_inflight_no_goal '"runX" in H["summary"]')"

# ── Scenario 7: done run (met=true) is NOT detected as in-flight ───────────
# Same coverage as the v0.2.x test — guard against resuming a finished run.
it "done run is NOT in-flight — falls through to raw"
assert_eq "raw" "$(json_field setup_done_run 'H["situation"]')"

# ── Scenario 8: dirty-tree contextualizes `raw` (review round 1 finding C-2/C-3)
# v0.4.0's original `dirty-tree` situation had no actionable dispatch (the
# skill's `<derived-args>` couldn't be derived from a diff alone) AND its
# detection depended on downstream repos gitignoring `.claude/`. The fix
# collapsed dirty-tree into raw: situation stays `raw` (no run, no plan ⇒
# operator must answer the open question), but the summary names the
# branch + diff context so the operator sees what they were doing.
it "dirty-tree: situation falls through to raw (no actionable dispatch from a diff alone)"
assert_eq "raw" "$(json_field setup_dirty_tree 'H["situation"]')"

it "dirty-tree: ambiguity is still the open 'what should we work on?' question"
assert_eq "open" "$(json_field setup_dirty_tree 'H["ambiguity"]["kind"]')"

it "dirty-tree: summary surfaces git context (branch + diff)"
assert_eq "True" "$(json_field setup_dirty_tree '"branch" in H["summary"]')"

# ── Scenario 9: malformed ledger is skipped (parity with v0.2.x) ───────────
it "malformed ledger: skipped silently → falls through to raw"
assert_eq "raw" "$(json_field setup_malformed 'H["situation"]')"

# ── Scenario 10: every envelope has the canonical key set (shape invariant)
# v0.4.1 (plan 004): adds `workspace` + `workspace_action` to the envelope
# so the skill can route project-workspace handling from one read.
# v0.6.0 (U1): adds `recommendation` — present on EVERY envelope (the detector
# always emits null; the driver fills it via lib/recommender.py). The key-set
# grew from eight to nine in lockstep with the U1 contract change.
it "envelope shape: every emitted JSON has all nine top-level keys (incl. v0.6.0 recommendation)"
shape_setup() {
  setup_inflight_one "$1"
}
keys="$(json_field shape_setup 'sorted(H.keys())')"
assert_eq "['ambiguity', 'in_flight', 'multi_plan', 'recommendation', 'single_plan', 'situation', 'summary', 'workspace', 'workspace_action']" "$keys"

# ── Scenario 10b: workspace_action correctly derived
# v0.4.1 (plan 004): action routing rules per KTD-4
#   * raw situation → action=none (workspace not relevant)
#   * reviewed-plan + no marker → action=create
#   * multi-plan + no marker → action=create
#   * reviewed-plan + marker matches env → action=use
#   * reviewed-plan + marker mismatch env → action=ambiguous

# Helper: plant a marker, set env, return the action field.
get_action_for() {
  local setup_fn="$1"
  json_field "$setup_fn" 'H["workspace_action"]'
}

it "workspace_action: raw situation → action=none"
# setup_raw_empty exists in the test fixtures (no run, no plan).
raw_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto"
  # No plans, no runs.
}
assert_eq "none" "$(get_action_for raw_setup)"

it "workspace_action: reviewed-plan + no marker → action=create"
reviewed_unmarked_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  echo "# P1" > "$repo/docs/plans/p1.md"
  # No marker file.
}
assert_eq "create" "$(get_action_for reviewed_unmarked_setup)"

it "workspace_action: multi-plan + no marker → action=create"
multi_unmarked_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  echo "# P1" > "$repo/docs/plans/p1.md"
  echo "# P2" > "$repo/docs/plans/p2.md"
}
assert_eq "create" "$(get_action_for multi_unmarked_setup)"

# ── Scenario 10c: ROUND-1 P2 regression coverage for the non-degraded
# action paths. The plan 004 round-1 review's P0 was that
# _detect_workspace_safe referenced an undefined `script_dir` inside a
# single-quoted heredoc, so the workspace block was ALWAYS the degraded
# {unmarked, no-stale} fallback. The original scenario-10b assertions
# only covered values that the degraded path happens to produce
# (none / create / create) — none of these three new scenarios passes
# unless detect actually runs.
#
# Each scenario requires a stub `cmux` on PATH because detect() shells
# out to list-workspaces to check liveness. We set up the stub once and
# control its output per-scenario via env.

# Stub cmux on PATH for these scenarios.
ws_stub_dir="$(mktemp -d -t det-ws-stub.XXXXXX)"
cat > "$ws_stub_dir/cmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-workspaces) echo "${CLAUDE_AUTO_TEST_WS_LIST:-}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$ws_stub_dir/cmux"
ORIG_PATH_FOR_WS="$PATH"
export PATH="$ws_stub_dir:$PATH"

plant_marker() {
  local repo="$1" workspace_id="$2"
  mkdir -p "$repo/.claude/auto"
  cat > "$repo/.claude/auto/workspace.json" <<EOF
{"workspace_id":"$workspace_id","left_pane_id":"pane:left-1","layout_version":"v1","created_at":"2026-05-27T00:00:00Z"}
EOF
}

it "workspace_action: reviewed-plan + marker matches env → action=use"
project_match_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  echo "# P1" > "$repo/docs/plans/p1.md"
  plant_marker "$repo" "workspace:proj-A"
  export CLAUDE_AUTO_TEST_WS_LIST="workspace:proj-A (test)"
  export CMUX_WORKSPACE_ID="workspace:proj-A"
}
assert_eq "use" "$(get_action_for project_match_setup)"
unset CMUX_WORKSPACE_ID
unset CLAUDE_AUTO_TEST_WS_LIST

it "workspace_action: reviewed-plan + marker mismatches env → action=ambiguous"
non_project_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  echo "# P1" > "$repo/docs/plans/p1.md"
  plant_marker "$repo" "workspace:proj-B"
  export CLAUDE_AUTO_TEST_WS_LIST="workspace:proj-B (test)"
  export CMUX_WORKSPACE_ID="workspace:different"
}
assert_eq "ambiguous" "$(get_action_for non_project_setup)"
unset CMUX_WORKSPACE_ID
unset CLAUDE_AUTO_TEST_WS_LIST

it "workspace_action: reviewed-plan + marker stale (cmux doesn't list it) → action=recreate"
stale_setup() {
  local repo="$1"
  mkdir -p "$repo/.claude/auto" "$repo/docs/plans"
  echo "# P1" > "$repo/docs/plans/p1.md"
  plant_marker "$repo" "workspace:proj-C"
  # Stub returns a DIFFERENT workspace, so cmux says proj-C is gone.
  export CLAUDE_AUTO_TEST_WS_LIST="workspace:something-else"
  export CMUX_WORKSPACE_ID="workspace:proj-C"
}
assert_eq "recreate" "$(get_action_for stale_setup)"
unset CMUX_WORKSPACE_ID
unset CLAUDE_AUTO_TEST_WS_LIST

# Restore PATH; clean up the stub dir.
export PATH="$ORIG_PATH_FOR_WS"
rm -rf "$ws_stub_dir"

# ── Scenario 11: detector exits 0 on every path (rel-001) ──────────────────
it "exit code: detector exits 0 even on the unexpected-error fallback"
repo="$(mktemp -d -t hyp-repo.XXXXXX)"
# Don't even init git — the detector should still degrade to raw and exit 0.
mkdir -p "$repo/.claude/auto"
CLAUDE_AUTO_REPO="$repo" bash "$DET" >/dev/null 2>&1
rc=$?
rm -rf "$repo"
assert_eq "0" "$rc"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "hypothesis-shape.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
