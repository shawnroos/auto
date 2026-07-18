#!/usr/bin/env bash
# auto Stage C SPIKE + context-flatness gate: the thin pacing shell (U8/U10).
#
# THE QUESTION THIS PROBE SETTLES (agent-native plan, Stage C):
# Can a `fable` main session ("the boss") supervise a multi-beat /auto run while
# its resident context stays FLAT — i.e. does NOT grow with beat count? The v0.13.0
# tree runtime already proves convergence reads the run-record off disk (not
# sub-agent prose — tree-dispatch.test.sh). Stage C's residual question is the
# READ-BACK: what the boss reads each beat must be O(1), or its context grows.
#
# THE FINDING (deterministic, no live tokens):
#   * The full run-record GROWS with beats (each verdict/step-state accumulates).
#     A boss that reads the full record — or `converge`, which returns growing
#     completed/in_flight LISTS — has O(N) context after N beats. FAILURE MODE.
#   * `dispatcher.digest` is a BOUNDED summary (state COUNTS + phase + predicate,
#     never the step/verdict lists). Its size is O(1) in steps/verdicts, so a boss
#     that reads only the digest each beat stays FLAT. SUCCESS MODE.
# So the pacing shell is viable IFF the boss reads the bounded digest, not the full
# record. This probe demonstrates both curves and gates the flat one.
#
# THE FORK COLLAPSE (recorded, not re-litigated): the plan's U8 offered spawn-per-
# beat vs. a long-lived driver sub-agent. Both are sub-agents, and a sub-agent
# cannot self-pace (no ScheduleWakeup). So pacing + the Stop-hook MUST stay in the
# main session either way; the driver logic descends but the clock does not. The
# shapes collapse to one: the main session paces and reads the digest each beat.
#
# Each beat is simulated with SEPARATE python processes sharing one on-disk
# run-record via $CLAUDE_AUTO_REPO — the boss dispatches, a "sub-agent" process
# self-writes the verdict, and the boss reads back ONLY the digest. Same substrate
# tree-dispatch.test.sh uses; here we measure the read-back size across beats.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ORCH_SH="${AUTO_ROOT}/lib/dispatcher.sh"
RR_PY="${AUTO_ROOT}/lib/run_record.py"

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

REPO="$(mktemp -d)"
export CLAUDE_AUTO_REPO="$REPO"
mkdir -p "$REPO/.claude/auto"

N=12   # beats

# Seed a run with N work-phase steps.
"$PY" - "$AUTO_ROOT" pacing "$N" <<'PYEOF'
import sys, os, importlib.util
auto_root, run, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
run_record = load("run_record")
repo = os.environ["CLAUDE_AUTO_REPO"]
steps = [{"id": f"u{i}", "phase": "work",
          "dispatch_context": {"backend_op": "do_step"}} for i in range(1, n + 1)]
run_record.init_run_record(repo, run, backend="ce", loop_phase="work", steps=steps)
PYEOF

# One beat i: the boss dispatches u_i (bumps attempt), a SEPARATE "sub-agent"
# process self-writes u_i's verdict (a blocker-free finding), advancing the run.
beat() {
  local i="$1"
  "$PY" - "$AUTO_ROOT" pacing "u$i" <<'PYEOF' >/dev/null 2>&1
import sys, os, importlib.util
auto_root, run, step = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
def load(name):
    p = os.path.join(auto_root, "lib", name + ".py")
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
orch = load("dispatcher")
repo = os.environ["CLAUDE_AUTO_REPO"]
orch.dispatch_batch(repo, run, [step], cap=1)   # boss: pending -> dispatched
PYEOF
  # separate process = the sub-agent self-writing its verdict (attempt 1).
  "$PY" "$RR_PY" record-verdict pacing "u$i" '[]' 1 >/dev/null 2>&1
}

# What the boss reads back each beat under the pacing shell: ONLY the bounded digest.
digest_bytes() { bash "$ORCH_SH" digest "$REPO" pacing 2>/dev/null | wc -c | tr -d ' '; }
# The failure-mode read: the full run-record (grows with beats).
full_bytes()   { "$PY" "$RR_PY" read "$REPO" pacing 2>/dev/null | wc -c | tr -d ' '; }

echo "pacing-shell.test.sh (Stage C spike + context-flatness gate)"

# Run N beats, recording the digest + full-record read size after each.
digest_first=0; digest_last=0; digest_max=0; digest_min=0
full_first=0; full_last=0
for i in $(seq 1 "$N"); do
  beat "$i"
  d="$(digest_bytes)"; f="$(full_bytes)"
  if [ "$i" -eq 1 ]; then digest_first="$d"; full_first="$f"; digest_max="$d"; digest_min="$d"; fi
  digest_last="$d"; full_last="$f"
  [ "$d" -gt "$digest_max" ] && digest_max="$d"
  [ "$d" -lt "$digest_min" ] && digest_min="$d"
done

digest_range=$((digest_max - digest_min))
full_growth=$((full_last - full_first))

# ── The gate: the digest read is FLAT (O(1)); the full read is not (O(N)). ─────
it "SPIKE: the boss's per-beat digest read stays FLAT across ${N} beats (bounded, O(1))"
# The digest carries state COUNTS, not lists — its size varies only by count-digit
# and which state-names are present, never by beat count. A tight band proves it.
if [ "$digest_range" -lt 120 ]; then
  pass
else
  fail "digest size ranged ${digest_min}..${digest_max} (Δ${digest_range}B) across ${N} beats — not flat; a bounded digest must not grow with beats"
fi

it "CONTROL: the FULL run-record read GROWS with beats (O(N) — the failure mode a digest avoids)"
# Proves the flatness metric has teeth: reading the full record (or converge's
# growing lists) is exactly what the pacing shell must NOT do.
if [ "$full_growth" -gt "$digest_range" ] && [ "$full_last" -gt "$full_first" ]; then
  pass
else
  fail "full-record read grew ${full_growth}B (first=${full_first} last=${full_last}); expected it to grow much more than the digest range (${digest_range}B)"
fi

it "CRUX: after ${N} beats the boss's digest read is far smaller than the full record (O(1) vs O(N))"
# The load-bearing comparison: at the LAST beat, the digest (what the shell reads)
# is a small fraction of the full record (what boss-is-driver would carry).
if [ "$((digest_last * 2))" -lt "$full_last" ]; then
  pass
else
  fail "digest_last=${digest_last}B vs full_last=${full_last}B — digest is not decisively smaller; the flat-context claim is not demonstrated"
fi

it "digest is a bounded summary: counts + phase + predicate, never the step/verdict lists"
missing="$(bash "$ORCH_SH" digest "$REPO" pacing 2>/dev/null | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
need = ["step_counts", "current_phase", "predicate_met", "total_steps"]
# Reject ANY list-valued data anywhere in the digest (not just three known keys):
# a list is O(steps) and would break the flatness property regardless of its name.
def list_paths(value, path="$"):
    if isinstance(value, list):
        return [path]
    if isinstance(value, dict):
        return sum((list_paths(v, "%s.%s" % (path, k)) for k, v in value.items()), [])
    return []
leaked = list_paths(d)
missing = [k for k in need if k not in d]
print(",".join(missing + ["LIST:%s" % p for p in leaked]) or "ok")
')"
[ "$missing" = "ok" ] && pass || fail "digest shape wrong: $missing (must carry counts, not lists)"

# ── summary ───────────────────────────────────────────────────────────────────
printf "%s: %d passed, %d failed\n" "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
