#!/usr/bin/env bash
# auto U8 integration test: cmux-socket auto-resume.
#
# Exercises lib/cmux-socket.sh against the REAL ledger.py (every fixture write
# goes through ledger.py's I-1 atomic chokepoint). The cmux binary is the ONLY
# mock: a shim on PATH that RECORDS its argv to a log file — we assert the
# spawn-command STRING is well-formed (with the mandatory `sleep 1;` lead-in,
# `/auto:auto-resume <run>`, and `--focus false`) WITHOUT spawning a real cmux
# workspace (per U8 constraints — never touch Shawn's cmux layout).
#
# Scenarios (U8 plan / task spec):
#   - orphaned run -> issues the correct `cmux new-workspace` command
#     (sleep lead-in + /auto:auto-resume <run> + --focus false), and the
#     standalone `command` builder produces the same well-formed string.
#   - DOUBLE-DRIVE: a run whose pulse lock is held by a LIVE pulse -> auto-resume
#     NO-OPS (no spawn). This is the load-bearing guard.
#   - non-orphaned run (driver==self, fresh last_beat_at) -> no spawn.
#   - done run -> no spawn.
#   - handoff-paused run -> no spawn (intentional orphan; never arm work uninvited).
#   - OPT-IN: scan is a no-op unless CLAUDE_AUTO_RESUME_ENABLE=1.
#   - runaway guard: a fresh in-flight sentinel -> no second spawn.
#
# SELF-CONTAINED harness (inline it/pass/fail) mirroring hooks.test.sh and the
# run.sh summary-line format ("<name>.test.sh: N passed, M failed").

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
CMUX_SOCKET_SH="${AUTO_ROOT}/lib/cmux-socket.sh"
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
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }
assert_nonempty() { [ -n "$1" ] && pass || fail "expected non-empty, got empty"; }

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"

# ── Mock cmux binary: records argv to $CMUX_LOG, never spawns anything. ──────
MOCK_BIN="${SANDBOX}/mockbin"
mkdir -p "$MOCK_BIN"
export CMUX_LOG="${SANDBOX}/cmux.log"
: > "$CMUX_LOG"
cat > "${MOCK_BIN}/cmux" <<'MOCK'
#!/usr/bin/env bash
# Record the invocation to the log the test reads. Each arg is written LITERALLY
# (not shell-quoted) on its own line under a "cmux <arg>" prefix, so the test can
# substring-match the real --command payload (e.g. "sleep 1; claude '/...'")
# without %q escaping mangling embedded spaces/quotes.
{ printf 'cmux\n'; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$CMUX_LOG"
exit 0
MOCK
chmod +x "${MOCK_BIN}/cmux"
export PATH="${MOCK_BIN}:${PATH}"

cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────
mkrepo() {
  local repo="${SANDBOX}/repo-${1}"
  mkdir -p "${repo}/.claude/auto"
  printf '%s' "$repo"
}

# Run a quoted-heredoc Python snippet against ledger.py (no bash $-leak).
pyledger() {
  local repo="$1"
  "$PY" - "$repo" "$LEDGER_PY"
}

reset_log() { : > "$CMUX_LOG"; }
log_text()  { cat "$CMUX_LOG" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
echo "cmux-resume.test.sh"

# ─── orphaned run -> issues the correct cmux new-workspace command ────────────
it "orphaned run: scan spawns a /auto:auto-resume workspace via cmux new-workspace"
REPO="$(mkrepo orphan)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"orphanrun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"orphanrun",driver="manual")  # -> is_orphaned() true.
PYEOF
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
out="$(log_text)"
assert_contains "$out" "new-workspace"
it "orphaned run: command carries the mandatory sleep lead-in (spike timing caveat)"
assert_contains "$out" "sleep 1; claude '/auto:auto-resume orphanrun'"
it "orphaned run: command invokes /auto:auto-resume for the orphaned run"
assert_contains "$out" "/auto:auto-resume orphanrun"
it "orphaned run: command keeps --focus false (does not steal Shawn's focus)"
# argv entries land on separate log lines; assert the flag is immediately
# followed by its `false` value (i.e. `--focus false` was passed as a pair).
assert_contains "$(printf '%s' "$out" | grep -A1 -x -- '--focus')" "false"

# ─── command builder: standalone well-formed spawn string ─────────────────────
it "command builder: produces a well-formed spawn string (no real spawn)"
cmd="$(bash "$CMUX_SOCKET_SH" command "$REPO" "orphanrun")"
assert_contains "$cmd" "cmux new-workspace"
it "command builder: includes sleep lead-in + claude '/auto:auto-resume <run>'"
assert_contains "$cmd" "sleep 1; claude '/auto:auto-resume orphanrun'"
it "command builder: includes --focus false"
assert_contains "$cmd" "--focus false"

# ─── DOUBLE-DRIVE: pulse lock held by a live pulse -> NO spawn ──────────────────
it "double-drive: a live pulse holding the lock makes auto-resume NO-OP (no spawn)"
REPO="$(mkrepo doubledrive)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"liverun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"liverun",driver="manual")  # orphaned by predicate...
PYEOF
# Resolve the pulse-lock path and HOLD it from a backgrounded Python "live pulse".
LOCK_PATH="$(bash "$CMUX_SOCKET_SH" command "$REPO" liverun >/dev/null 2>&1; \
             CLAUDE_AUTO_PYTHON3="$PY" bash -c '
               source "'"$CMUX_SOCKET_SH"'" 2>/dev/null || true
               auto::pulse_lock_path "'"$REPO"'" liverun')"
assert_nonempty "$LOCK_PATH"
# Background a process that grabs an exclusive flock and holds it, signalling
# readiness via a flag file, then waits for a release flag.
HELD_FLAG="${SANDBOX}/held.flag"
RELEASE_FLAG="${SANDBOX}/release.flag"
rm -f "$HELD_FLAG" "$RELEASE_FLAG"
"$PY" - "$LOCK_PATH" "$HELD_FLAG" "$RELEASE_FLAG" <<'PYEOF' &
import fcntl, os, sys, time
lock_path, held_flag, release_flag = sys.argv[1], sys.argv[2], sys.argv[3]
fh = open(lock_path, "a+")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)  # blocking acquire -> definitely held.
open(held_flag, "w").close()
for _ in range(600):  # up to ~60s safety bound.
    if os.path.exists(release_flag):
        break
    time.sleep(0.1)
fcntl.flock(fh.fileno(), fcntl.LOCK_UN); fh.close()
PYEOF
HOLDER_PID=$!
# Wait for the holder to confirm the lock is held.
for _ in $(seq 1 100); do [ -e "$HELD_FLAG" ] && break; sleep 0.05; done
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
out="$(log_text)"
assert_empty "$out"  # double-drive guard fired -> NO spawn while lock is held.
# Release the holder and reap it.
touch "$RELEASE_FLAG"
wait "$HOLDER_PID" 2>/dev/null || true

# ─── DOUBLE-DRIVE control: same run, lock FREE -> DOES spawn ──────────────────
it "double-drive control: once the lock is released, the same run DOES spawn"
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
out="$(log_text)"
assert_contains "$out" "/auto:auto-resume liverun"

# ─── non-orphaned run (driver==self, fresh beat) -> no spawn ──────────────────
it "non-orphaned run (driver==self, fresh last_beat_at): no spawn"
REPO="$(mkrepo fresh)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# init_ledger sets driver=self + last_beat_at=now -> NOT orphaned.
L.init_ledger(repo,"freshrun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
PYEOF
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
assert_empty "$(log_text)"

# ─── done run -> no spawn ─────────────────────────────────────────────────────
it "done run: no spawn (is_orphaned()==false for loop_phase==done)"
REPO="$(mkrepo done)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"donerun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"terminal-skip"}])
L.set_loop(repo,"donerun",loop_phase="done",driver="manual")
PYEOF
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
assert_empty "$(log_text)"

# ─── handoff-paused run -> no spawn (intentional orphan; awaiting confirmation) ──
it "handoff-paused run: no spawn (intentional orphan; never arm work uninvited)"
REPO="$(mkrepo handoff)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# handoff phase + driver=manual -> is_orphaned() would be TRUE, but handoff_paused
# excludes it from auto-resume.
L.init_ledger(repo,"handoffrun",backend="ce",loop_phase="handoff",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"handoffrun",driver="manual")
PYEOF
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
assert_empty "$(log_text)"

# ─── OPT-IN: scan is a no-op unless CLAUDE_AUTO_RESUME_ENABLE=1 ──────────────
it "opt-in: an orphaned run does NOT spawn when CLAUDE_AUTO_RESUME_ENABLE unset"
REPO="$(mkrepo optin)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"optinrun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"optinrun",driver="manual")
PYEOF
reset_log
bash "$CMUX_SOCKET_SH" scan "$REPO"   # no CLAUDE_AUTO_RESUME_ENABLE -> default OFF.
assert_empty "$(log_text)"
it "opt-in control: the SAME run DOES spawn with CLAUDE_AUTO_RESUME_ENABLE=1"
reset_log
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
assert_contains "$(log_text)" "/auto:auto-resume optinrun"

# ─── runaway guard: a fresh in-flight sentinel -> no second spawn ─────────────
it "runaway guard: a fresh spawn-in-flight sentinel suppresses a second spawn"
REPO="$(mkrepo runaway)"
pyledger "$REPO" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo,"runawayrun",backend="ce",loop_phase="work",units=[{"id":"U1","state":"pending"}])
L.set_loop(repo,"runawayrun",driver="manual")
PYEOF
reset_log
# First scan spawns once (stamps the sentinel).
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
# Immediate second scan: sentinel is fresh (well within TTL) -> suppressed.
CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
spawn_count="$(grep -c "new-workspace" "$CMUX_LOG" 2>/dev/null)"
spawn_count="${spawn_count:-0}"
assert_eq "1" "$spawn_count"
it "runaway guard control: a long-expired sentinel (TTL=0) allows a re-spawn"
reset_log
CLAUDE_AUTO_SPAWN_TTL=0 CLAUDE_AUTO_RESUME_ENABLE=1 bash "$CMUX_SOCKET_SH" scan "$REPO"
assert_contains "$(log_text)" "/auto:auto-resume runawayrun"

# ════════════════════════════════════════════════════════════════════════════
printf "\ncmux-resume.test.sh: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
