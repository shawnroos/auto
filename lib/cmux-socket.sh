#!/usr/bin/env bash
# claude-dispatch U8: automatic cross-session resume via the cmux control socket.
#
# When a run is ORPHANED (its self-paced ScheduleWakeup tick chain died with a
# prior session), this spawns a FRESH cmux workspace running `/dispatch-resume
# <run>` so the loop continues WITHOUT the operator manually typing it. U7's
# on-session-start.py only SURFACES a resume hint; U8 makes resume AUTOMATIC.
#
# MECHANISM (verified by the U1 spike — docs/research/cmux-socket-spike.md):
#   cmux new-workspace --command "sleep 1; claude '/dispatch-resume <run>'" \
#     --focus false
#   * The spawned workspace is APP-OWNED, so it survives the parent Claude
#     session exiting — exactly the U8 use case.
#   * `--focus false` keeps Shawn's current pane/layout undisturbed.
#   * The `sleep 1;` lead-in is LOAD-BEARING: `--command` sends text+Enter the
#     instant the surface is created, and a still-initializing login shell can
#     SWALLOW those keystrokes (spike §"Timing caveat"). The lead-in lets the
#     shell settle so the command runs reliably.
#
# DOUBLE-DRIVE GUARD (the load-bearing piece): before spawning, this probes the
# SAME per-run tick lock that lib/tick.py::_tick_lock holds (the `.tick.lock`
# sibling of the ledger). If a LIVE tick already holds it, a driver is already
# running — auto-resume NO-OPS (it must never spawn a competing driver). The
# probe is a non-blocking flock-then-release; the spawned /dispatch-resume will
# itself contend for that same lock, so any tick that arrives after the probe
# window simply loses non-blockingly. We derive the lock base from the PUBLIC
# ledger.lock_path() and swap `.lock` -> `.tick.lock` (we do NOT import tick.py's
# private _tick_lock_path).
#
# RUNAWAY PREVENTION (auto-resume must never spawn runaway workspaces):
#   1. OPT-IN: does nothing unless CLAUDE_DISPATCH_AUTO_RESUME=1. Default OFF —
#      this ships as dormant, verified-safe infrastructure until a trigger wires
#      it up (see INTEGRATION GAP below).
#   2. SPAWN-IN-FLIGHT sentinel: a per-run `<slug>.spawn.attempt` file, mtime-
#      gated (default 60s). The flock probe alone is insufficient because the
#      spawned terminal takes time to reach its FIRST tick (and grab the lock);
#      back-to-back invocations inside that window would otherwise double-spawn.
#      The sentinel closes that window.
#
# SEAM EXCLUSION: a seam-paused run (loop_phase=="seam" AND seam_paused==true) is
# the INTENTIONAL "awaiting human confirmation" orphan — is_orphaned() returns
# true for it (its driver is "manual"), but auto-resuming it would arm WORK
# before the operator confirmed. We skip seam-paused runs explicitly (parity with
# on-session-start.py's seam-before-orphan ordering).
#
# INTEGRATION GAP (RAISED, not silently worked around): U8's scope forbids
# editing on-session-start.py, which is where U7's orphan scan lives. So this
# file ships as a callable scan+spawn primitive, but NOTHING currently INVOKES
# it. Closing the loop needs a separate, deferred edit: on-session-start.py (or a
# dedicated in-cmux watcher hook) must call `cmux-socket.sh scan <repo>` to fire
# auto-resume. U8 delivers the verified-safe spawn primitive; the wire-up is the
# next step.
#
# Pins the interpreter to /usr/bin/python3 (overridable via
# CLAUDE_DISPATCH_PYTHON3) — never bare `python3` (parity: lib/resume.sh:41,
# lib/ledger.sh, lib/tick.sh).

set -uo pipefail

CLAUDE_DISPATCH_PYTHON3="${CLAUDE_DISPATCH_PYTHON3:-/usr/bin/python3}"
# The cmux binary. Overridable for tests (a mock shim on PATH records its args).
CLAUDE_DISPATCH_CMUX="${CLAUDE_DISPATCH_CMUX:-cmux}"
# Spawn-in-flight window (seconds): skip re-spawn if a sentinel was touched this
# recently. Overridable for tests.
CLAUDE_DISPATCH_SPAWN_TTL="${CLAUDE_DISPATCH_SPAWN_TTL:-60}"

_cmux_socket::script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# claude_dispatch::tick_lock_path <repo> <run>
#   Echo the per-run tick-lock path (the .tick.lock sibling of the ledger),
#   derived from the PUBLIC ledger.lock_path(). Empty on slugify failure.
claude_dispatch::tick_lock_path() {
  local repo="$1" run="$2" script_dir
  script_dir="$(_cmux_socket::script_dir)"
  "$CLAUDE_DISPATCH_PYTHON3" - "$repo" "$run" "${script_dir}/ledger.py" <<'PYEOF'
import importlib.util, sys
repo, run, ledger_py = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
try:
    lpath = L.lock_path(repo, run)
except Exception:
    sys.exit(0)  # slugify reject -> empty -> caller treats as un-spawnable.
# Swap the trailing .lock for .tick.lock (parity with tick.py::_tick_lock_path).
assert lpath.endswith(".lock")
print(lpath[: -len(".lock")] + ".tick.lock")
PYEOF
}

# claude_dispatch::tick_lock_held <repo> <run>
#   Exit 0 if a LIVE tick holds the run's tick lock (double-drive guard fires —
#   do NOT spawn); exit 1 if the lock is free or absent (safe to spawn).
#   Non-blocking flock-then-release: we never queue behind the live tick.
claude_dispatch::tick_lock_held() {
  local repo="$1" run="$2" lock_path
  lock_path="$(claude_dispatch::tick_lock_path "$repo" "$run")"
  # No lock file => no tick ever ran for this run => lock is free.
  [ -n "$lock_path" ] && [ -e "$lock_path" ] || return 1
  "$CLAUDE_DISPATCH_PYTHON3" - "$lock_path" <<'PYEOF'
import fcntl, sys
path = sys.argv[1]
fh = open(path, "a+")
try:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)   # held by a live tick -> guard fires.
else:
    fcntl.flock(fh.fileno(), fcntl.LOCK_UN)  # release immediately.
    sys.exit(1)   # free -> safe to spawn.
finally:
    fh.close()
PYEOF
}

# claude_dispatch::resumable_orphans <repo>
#   Print run-ids that are AUTO-RESUMABLE: is_orphaned()==true AND NOT seam-
#   paused. A seam-paused run is is_orphaned()==true but is the intentional
#   "awaiting confirmation" orphan — excluded so we never arm work uninvited.
#   A malformed ledger is skipped (never aborts the scan of its siblings).
claude_dispatch::resumable_orphans() {
  local repo="$1" script_dir
  script_dir="$(_cmux_socket::script_dir)"
  "$CLAUDE_DISPATCH_PYTHON3" - "$repo" "${script_dir}/ledger.py" <<'PYEOF'
import glob, importlib.util, json, os, sys
repo, ledger_py = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
dispatch_dir = os.path.join(repo, ".claude", "dispatch")
for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
    try:
        with open(path) as fh:
            led = json.load(fh)
    except Exception:
        continue  # malformed -> skip, keep scanning siblings.
    if not isinstance(led, dict):
        continue
    # Seam-paused is the INTENTIONAL orphan (awaiting human confirmation) — never
    # auto-resume it (parity with on-session-start.py seam-before-orphan order).
    if led.get("loop_phase") == "seam" and led.get("seam_paused"):
        continue
    try:
        if not L.is_orphaned(led):
            continue
    except Exception:
        continue
    run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
    print(run_id)
PYEOF
}

# claude_dispatch::build_spawn_command <repo> <run>
#   Echo the EXACT `cmux new-workspace` command that auto-resume issues. Factored
#   out so the test can assert the command STRING shape without spawning a real
#   workspace. The `sleep 1;` lead-in is mandatory (spike timing caveat).
claude_dispatch::build_spawn_command() {
  local repo="$1" run="$2"
  printf '%s new-workspace --name %s --cwd %s --command %s --focus false' \
    "$CLAUDE_DISPATCH_CMUX" \
    "dispatch-resume-${run}" \
    "$repo" \
    "sleep 1; claude '/dispatch-resume ${run}'"
}

# claude_dispatch::spawn_resume <repo> <run>
#   Spawn ONE fresh /dispatch-resume workspace for an orphaned run, IF safe:
#     * tick lock free (no live driver) — else NO-OP (double-drive guard).
#     * no recent spawn-in-flight sentinel — else NO-OP (runaway guard).
#   Returns 0 on spawn, 10 on double-drive no-op, 11 on in-flight no-op.
claude_dispatch::spawn_resume() {
  local repo="$1" run="$2"

  # ── Double-drive guard: a live tick is already driving this run. ──────────
  if claude_dispatch::tick_lock_held "$repo" "$run"; then
    return 10  # NO-OP: do not spawn a competing driver.
  fi

  # ── Runaway guard: a spawn for this run is already in flight. ─────────────
  local sentinel="${repo}/.claude/dispatch/$(
    "$CLAUDE_DISPATCH_PYTHON3" - "$repo" "$run" "$(_cmux_socket::script_dir)/ledger.py" <<'PYEOF'
import importlib.util, os, sys
repo, run, ledger_py = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
try:
    print(os.path.basename(L.ledger_path(repo, run))[: -len(".json")] + ".spawn.attempt")
except Exception:
    sys.exit(0)
PYEOF
  )"
  if [ -e "$sentinel" ]; then
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if [ "$age" -lt "$CLAUDE_DISPATCH_SPAWN_TTL" ]; then
      return 11  # NO-OP: a spawn is already in flight inside the TTL window.
    fi
  fi

  # Stamp the in-flight sentinel BEFORE spawning so a racing invocation backs off.
  ( umask 077; : > "$sentinel" ) 2>/dev/null || true

  # ── Spawn the app-owned /dispatch-resume workspace (verified mechanism). ──
  # shellcheck disable=SC2046 — deliberate: the command is built as a string and
  # we want word-splitting into argv for the cmux binary.
  $CLAUDE_DISPATCH_CMUX new-workspace \
    --name "dispatch-resume-${run}" \
    --cwd "$repo" \
    --command "sleep 1; claude '/dispatch-resume ${run}'" \
    --focus false
  return 0
}

# claude_dispatch::scan <repo>
#   The top-level auto-resume entrypoint: opt-in gated, scans for resumable
#   orphans, and spawns a resume workspace for each (subject to the per-run
#   double-drive + in-flight guards). A no-op unless CLAUDE_DISPATCH_AUTO_RESUME=1.
claude_dispatch::scan() {
  local repo="${1:-${CLAUDE_DISPATCH_REPO:-$PWD}}"
  [ "${CLAUDE_DISPATCH_AUTO_RESUME:-0}" = "1" ] || return 0  # OPT-IN: default OFF.
  local run
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    claude_dispatch::spawn_resume "$repo" "$run" || true
  done < <(claude_dispatch::resumable_orphans "$repo")
}

# Allow direct invocation for testing / scripting.
#   cmux-socket.sh scan <repo>            -> opt-in scan + spawn
#   cmux-socket.sh spawn <repo> <run>     -> single-run guarded spawn
#   cmux-socket.sh command <repo> <run>   -> echo the spawn command string
#   cmux-socket.sh orphans <repo>         -> echo resumable orphan run-ids
#   cmux-socket.sh lock-held <repo> <run> -> exit 0 if a live tick holds the lock
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  sub="${1:-scan}"; shift || true
  case "$sub" in
    scan)      claude_dispatch::scan "$@" ;;
    spawn)     claude_dispatch::spawn_resume "$@" ;;
    command)   claude_dispatch::build_spawn_command "$@" ;;
    orphans)   claude_dispatch::resumable_orphans "$@" ;;
    lock-held) claude_dispatch::tick_lock_held "$@" ;;
    *)
      echo "cmux-socket.sh: unknown subcommand '${sub}'" >&2
      exit 2
      ;;
  esac
fi
