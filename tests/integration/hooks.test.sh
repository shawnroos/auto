#!/usr/bin/env bash
# claude-dispatch U7 integration test: the hooks + resume + goal-status surface.
#
# Exercises the REAL ledger.py + the U7 scripts wired exactly as the plugin
# manifest / command body wire them. The ONLY injected seam is the repo path
# (a sandbox tmp repo) and the Stop event JSON (fed on stdin, as the harness
# would). Nothing is mocked — every ledger write goes through ledger.py's I-1
# atomic chokepoint; every classification goes through the real hook scripts.
#
# Per U9 spike (docs/research/native-goal-mechanism-spike.md): native /goal is a
# closed model-judged loop with no external predicate seam, so claude-dispatch
# ships its OWN Stop hook. These tests assert THAT hook's deterministic verdict.
#
# SELF-CONTAINED harness (inline it/pass/fail) mirroring tests/unit/tick.test.sh
# and the run.sh summary-line format ("<name>.test.sh: N passed, M failed").
#
# Scenarios (U7 plan):
#   on-session-start:
#     - orphaned ledger (driver==manual / last_beat_at>GRACE) -> resume hint
#     - seam_paused -> seam-specific hint (continue/abort)
#     - done -> skipped (no line)
#     - no active run -> fast no-op (no output)
#     - malformed ledger -> never exits non-zero
#   on-stop:
#     - predicate unmet (driver=self) -> blocks (decision JSON)
#     - met -> allows stop (no decision)
#     - all_units_terminal gate: counters zero but a stalled unit lurking -> blocked
#     - seam-paused (driver=manual) -> ALLOWS stop (engine's own stop-point signal)
#     - stop_hook_active==true -> ALLOWS stop (loop-safety; no inescapable block)
#   goal-status freshness:
#     - met flips true->false (re-review reopens) -> status reflects it (no stale done)
#   resume subcommands:
#     - continue: seam -> work + arm-tick intent
#     - abort: -> done
#     - retry: stalled -> pending + clears last_error
#     - skip: stalled -> terminal-skip
#     - ambiguous run-id (>1 resumable, none given) -> disambiguation prompt

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${DISPATCH_ROOT}/lib/ledger.py"
GOAL_STATUS_SH="${DISPATCH_ROOT}/lib/goal-status.sh"
RESUME_SH="${DISPATCH_ROOT}/lib/resume.sh"
ON_STOP_SH="${DISPATCH_ROOT}/.claude/hooks/on-stop.sh"
ON_STOP_PY="${DISPATCH_ROOT}/lib/on-stop.py"
ON_SESSION_PY="${DISPATCH_ROOT}/lib/on-session-start.py"
PY="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"

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
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }
assert_nonempty() { [ -n "$1" ] && pass || fail "expected non-empty, got empty"; }

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t claude-dispatch-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */claude-dispatch-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
# Make a fresh sandbox repo with .claude/dispatch present, echo its path.
mkrepo() {
  local repo="${SANDBOX}/repo-${1}"
  mkdir -p "${repo}/.claude/dispatch"
  printf '%s' "$repo"
}

# Run a Python snippet against ledger.py with the repo as argv[1]; the snippet
# body is fed on stdin via a QUOTED heredoc so no bash $-expansion leaks in.
pyledger() {
  local repo="$1"; shift
  "$PY" - "$repo" "$LEDGER_PY"
}

# Extract a JSON field from a one-line JSON string (jq-free).
jget() { "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get(sys.argv[2], ''))
except Exception:
    print('')" "$1" "$2"; }

# ════════════════════════════════════════════════════════════════════════════
echo "hooks.test.sh"

# ─── on-session-start: orphaned (driver==manual) -> resume hint ───────────────
it "on-session-start: orphaned run (driver==manual) surfaces a resume hint"
REPO="$(mkrepo orphan-manual)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"orphanrun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"orphanrun",driver="manual")
PYEOF
out="$("$PY" "$ON_SESSION_PY" "$REPO")"
assert_contains "$out" "loop orphanrun can be resumed: /dispatch-resume orphanrun"

# ─── on-session-start: orphaned (last_beat_at > GRACE) -> resume hint ──────────
it "on-session-start: orphaned run (last_beat_at older than GRACE) surfaces a hint"
REPO="$(mkrepo orphan-stale)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util, datetime, json, os
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"staleorphan",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
# Hand-age last_beat_at well beyond GRACE_SECONDS while keeping driver=self
# (so ONLY the time branch can flag it — proves the GRACE path, not driver).
old = (datetime.datetime.now(datetime.timezone.utc)
       - datetime.timedelta(seconds=L.GRACE_SECONDS + 600)).strftime("%Y-%m-%dT%H:%M:%SZ")
p = L.ledger_path(repo,"staleorphan")
with open(p) as f: led = json.load(f)
led["loop"]["last_beat_at"] = old
led["loop"]["driver"] = "self"
with open(p,"w") as f: json.dump(led,f)
PYEOF
out="$("$PY" "$ON_SESSION_PY" "$REPO")"
assert_contains "$out" "loop staleorphan can be resumed"

# ─── on-session-start: seam_paused -> seam-specific hint ──────────────────────
it "on-session-start: seam_paused surfaces the seam-specific continue/abort hint"
REPO="$(mkrepo seam)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"seamrun",adapter="ce",loop_phase="seam",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"seamrun",driver="manual")
PYEOF
out="$("$PY" "$ON_SESSION_PY" "$REPO")"
assert_contains "$out" "paused at seam"
it "on-session-start: seam hint offers BOTH continue and abort"
assert_contains "$out" "/dispatch-resume continue seamrun"

# ─── on-session-start: done -> skipped (no line) ──────────────────────────────
it "on-session-start: a done run is skipped (no surfacing line)"
REPO="$(mkrepo done)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"donerun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"terminal-skip"}])
L.set_loop(repo,"donerun",loop_phase="done",driver="manual")
PYEOF
out="$("$PY" "$ON_SESSION_PY" "$REPO")"
assert_empty "$out"

# ─── on-session-start: no active run -> fast no-op ────────────────────────────
it "on-session-start: empty dispatch dir is a fast no-op (no output)"
REPO="$(mkrepo empty)"
out="$("$PY" "$ON_SESSION_PY" "$REPO")"
assert_empty "$out"

# ─── on-session-start: malformed ledger -> never non-zero ─────────────────────
it "on-session-start: malformed ledger never exits non-zero (rel-001)"
REPO="$(mkrepo malformed)"
printf '{ this is not valid json' > "${REPO}/.claude/dispatch/broken.json"
"$PY" "$ON_SESSION_PY" "$REPO" >/dev/null 2>&1
assert_eq "0" "$?"

# ─── on-stop: predicate unmet (driver=self) -> blocks ─────────────────────────
it "on-stop: unmet predicate (driver=self) blocks via decision JSON"
REPO="$(mkrepo stop-unmet)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"unmet",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "block" "$(jget "$out" decision)"
it "on-stop: block reason names the offending run and the blocker count"
assert_contains "$out" "unmet (1 blocker"

# ─── on-stop: met -> allows stop (no decision) ────────────────────────────────
it "on-stop: met predicate allows the stop (no decision JSON)"
REPO="$(mkrepo stop-met)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# verdict-returned with ONLY a minor (does not gate) -> terminal -> met==true.
L.init_ledger(repo,"clean",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"minor","note":"nit"}]}])
PYEOF
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_empty "$out"

# ─── on-stop: all_units_terminal gate (counters zero, stalled unit lurking) ───
it "on-stop: counters zero but a stalled unit lurks -> still BLOCKED (I-2 gate)"
REPO="$(mkrepo stop-stalled)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# A dispatched unit -> stalled (NOT terminal). No findings anywhere, so
# blockers==majors==0, but all_units_terminal==false => met==false.
L.init_ledger(repo,"lurking",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"dispatched"}])
L.transition(repo,"lurking","U1","stalled")
PYEOF
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "block" "$(jget "$out" decision)"
it "on-stop: the stalled-unit block reason cites units-not-terminal (not findings)"
assert_contains "$out" "units not yet terminal"

# ─── on-stop: seam-paused (driver=manual) -> ALLOWS stop ──────────────────────
# The seam pause is the engine's OWN signal that this is a valid stop-point
# (it emits action:"stop" + driver:"manual"). The Stop hook must respect it.
it "on-stop: seam-paused run (driver=manual) ALLOWS stop (no self-conflict)"
REPO="$(mkrepo stop-seam)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"seamstop",adapter="ce",loop_phase="seam",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"seamstop",driver="manual")
PYEOF
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_empty "$out"

# ─── on-stop: stop_hook_active==true -> ALLOWS stop (loop-safety) ─────────────
it "on-stop: stop_hook_active=true allows stop even with an unmet run (loop-safety)"
REPO="$(mkrepo stop-refire)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"unmet2",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"x"}]}])
PYEOF
out="$(printf '{"stop_hook_active":true}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "" "$(jget "$out" decision)"

# ─── on-stop: the .sh shim never exits non-zero on a malformed ledger ─────────
it "on-stop.sh shim: malformed ledger -> exit 0 (rel-001)"
REPO="$(mkrepo stop-malformed)"
printf 'not json' > "${REPO}/.claude/dispatch/x.json"
( cd "$REPO" && printf '{}' | bash "$ON_STOP_SH" >/dev/null 2>&1 )
assert_eq "0" "$?"

# ─── goal-status freshness: met flips true->false (re-review reopens) ─────────
# A clean unit (met==true) is re-reviewed and the verdict reopens a blocker.
# Because goal-status reads exit_predicate_result.met DIRECTLY (no cached copy),
# the status MUST flip done:true -> done:false in the SAME snapshot — proving
# there is no staleness window where it says done while the ledger says not.
it "goal-status: done flips true with a clean (met) unit"
REPO="$(mkrepo gs-fresh)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# Start clean: verdict-returned with no gating findings -> terminal -> met.
L.init_ledger(repo,"reopen",adapter="ce",loop_phase="work",
              units=[{"id":"U1","state":"verdict-returned","findings":[]}])
PYEOF
out1="$(bash "$GOAL_STATUS_SH" "$REPO" reopen)"
assert_eq "True" "$(jget "$out1" done)"
it "goal-status: a re-review reopening a blocker flips done:true -> false (no stale done)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# Re-review surfaces a blocker (verdict OVERWRITES findings; predicate recomputed
# in the SAME atomic write). met must now be false.
L.record_verdict(repo,"reopen","U1",[{"severity":"blocker","note":"regressed"}])
PYEOF
out2="$(bash "$GOAL_STATUS_SH" "$REPO" reopen)"
assert_eq "False" "$(jget "$out2" done)"
it "goal-status: the reopened status carries the reopened blocker in its reason"
assert_contains "$out2" "1 blocker"

# ─── resume continue: seam -> work + arm-tick intent ──────────────────────────
it "resume continue: flips seam -> work"
REPO="$(mkrepo resume-continue)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"contrun",adapter="ce",loop_phase="seam",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"contrun",driver="manual")
PYEOF
out="$(CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH" continue contrun)"
phase="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','contrun')['loop_phase'])")"
assert_eq "work" "$phase"
it "resume continue: emits an arm-tick intent for the model to fire /dispatch-tick"
assert_eq "arm-tick" "$(jget "$out" action)"
it "resume continue: clears seam_paused on the seam->work flip"
sp="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','contrun')['seam_paused'])")"
assert_eq "False" "$sp"

# ─── resume abort: -> done ────────────────────────────────────────────────────
it "resume abort: flips the run to loop_phase=done"
REPO="$(mkrepo resume-abort)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"abortrun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
PYEOF
CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH" abort abortrun >/dev/null
phase="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','abortrun')['loop_phase'])")"
assert_eq "done" "$phase"

# ─── resume retry: stalled -> pending + clears last_error ─────────────────────
it "resume retry: stalled unit -> pending"
REPO="$(mkrepo resume-retry)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"retryrun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"dispatched"}])
L.transition(repo,"retryrun","U1","stalled",last_error={"call":"plan","message":"boom","at":"2026-01-01T00:00:00Z"})
PYEOF
CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH" retry retryrun U1 >/dev/null
state="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','retryrun')['units'][0]['state'])")"
assert_eq "pending" "$state"
it "resume retry: clears last_error on the stalled -> pending edge"
le="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','retryrun')['units'][0]['last_error'])")"
assert_eq "None" "$le"

# ─── resume skip: stalled -> terminal-skip ────────────────────────────────────
it "resume skip: stalled unit -> terminal-skip (counts as terminal for I-2)"
REPO="$(mkrepo resume-skip)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"skiprun",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"dispatched"}])
L.transition(repo,"skiprun","U1","stalled")
PYEOF
CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH" skip skiprun U1 >/dev/null
state="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.read_ledger('$REPO','skiprun')['units'][0]['state'])")"
assert_eq "terminal-skip" "$state"

# ─── resume ambiguous: >1 resumable, none given -> disambiguation prompt ──────
it "resume (no run, >1 resumable): lists the runs and asks for disambiguation"
REPO="$(mkrepo resume-ambiguous)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
for r in ("alpha","beta"):
    L.init_ledger(repo,r,adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
    L.set_loop(repo,r,driver="manual")  # both resumable (orphaned).
PYEOF
out="$(CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH")"
assert_contains "$out" "multiple resumable runs"
it "resume disambiguation: lists each resumable run by id"
case "$out" in *alpha*beta*|*beta*alpha*) pass ;; *) fail "expected both alpha and beta listed, got '$out'" ;; esac

# ─── resume single resumable (no run given) -> auto-selects it ────────────────
it "resume (no run, exactly 1 resumable): auto-selects it and emits arm-tick"
REPO="$(mkrepo resume-single)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"solo",adapter="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"solo",driver="manual")
PYEOF
out="$(CLAUDE_DISPATCH_REPO="$REPO" bash "$RESUME_SH")"
assert_eq "solo" "$(jget "$out" run)"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "hooks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
