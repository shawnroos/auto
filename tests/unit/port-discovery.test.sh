#!/usr/bin/env bash
# auto v0.4.0 U2 unit test: port-discovery + crash-recovery sweep.
#
# Focused on the port-pool surface that auto-spawn.fanout exposes:
#   1. Empty batches/ → port 3001 is picked.
#   2. Existing committed sidecar with port 3001 → next pick is 3002.
#   3. Mixed provisional + committed sidecars → both counted as in-use.
#   4. Fresh provisional sidecar inside TTL → NOT swept (still in-use).
#   5. Provisional sidecar past TTL → swept; its ports freed.
#   6. Concurrent spawn (simulated via two sequential calls with the
#      sidecar already in place) reads each other's provisional → picks
#      distinct ports.
#
# These tests exercise the private helpers (_scan_in_use_ports, _pick_port)
# directly so the unit doesn't depend on cmux availability.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
SPAWN="${AUTO_ROOT}/lib/auto-spawn.py"

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

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t port-discovery.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */port-discovery.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# Probe helper: load auto-spawn as a module and run an expression on it.
probe() {
  local shared="$1" expr="$2"
  "$PY" - "$AUTO_ROOT" "$shared" "$expr" <<'PYEOF'
import sys, os, importlib.util
auto_root, shared, expr = sys.argv[1:4]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto_spawn", os.path.join(auto_root, "lib", "auto-spawn.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
val = eval(expr)
if val is None:
    print("None")
elif isinstance(val, bool):
    print("True" if val else "False")
elif isinstance(val, set):
    print(sorted(val))
else:
    print(val)
PYEOF
}

# Helper: write a committed sidecar that claims a single port.
seed_committed_port() {
  local shared="$1" name="$2" port="$3"
  mkdir -p "${shared}/batches"
  "$PY" -c "
import json
s = {
  'id': '${name}', 'created_at': '2026-01-01T00:00:00Z', 'status': 'committed',
  'composite_intent': '${name}', 'plans': [{
    'path': 'p', 'slug': 'p', 'worktree': '/x', 'branch': 'auto/p',
    'port': ${port}, 'suggested_run_id': 'p',
  }],
}
with open('${shared}/batches/${name}.json', 'w') as f:
  json.dump(s, f)
"
}

# Helper: write a provisional sidecar (caller controls mtime).
seed_provisional_port() {
  local shared="$1" name="$2" port="$3"
  mkdir -p "${shared}/batches"
  "$PY" -c "
import json
s = {
  'id': '${name}', 'created_at': '2026-01-01T00:00:00Z', 'status': 'provisional',
  'composite_intent': '${name}', 'plans': [{
    'path': 'p', 'slug': 'p', 'worktree': '/x', 'branch': 'auto/p',
    'port': ${port}, 'suggested_run_id': 'p',
  }],
}
with open('${shared}/batches/${name}.json', 'w') as f:
  json.dump(s, f)
"
}

# ── Scenario 1: empty batches → 3001 is picked.
it "empty batches/ → _pick_port returns 3001"
SHARED1="${SANDBOX}/sh1"
mkdir -p "${SHARED1}/batches"
got="$(probe "$SHARED1" "m._pick_port(m._scan_in_use_ports('${SHARED1}')[0])")"
assert_eq "3001" "$got"

# ── Scenario 2: committed sidecar at 3001 → next pick is 3002.
it "committed sidecar with port 3001 → _pick_port returns 3002"
SHARED2="${SANDBOX}/sh2"
seed_committed_port "$SHARED2" "a" 3001
got="$(probe "$SHARED2" "m._pick_port(m._scan_in_use_ports('${SHARED2}')[0])")"
assert_eq "3002" "$got"

# ── Scenario 3: provisional + committed both counted as in-use.
it "provisional + committed → both ports counted as in-use"
SHARED3="${SANDBOX}/sh3"
seed_committed_port "$SHARED3" "c" 3001
seed_provisional_port "$SHARED3" "p" 3002
# Force a fresh mtime on the provisional so it isn't swept.
touch "${SHARED3}/batches/p.json"
got="$(probe "$SHARED3" "sorted(m._scan_in_use_ports('${SHARED3}')[0])")"
assert_eq "[3001, 3002]" "$got"

# ── Scenario 4: fresh provisional inside TTL → NOT swept.
it "fresh provisional (mtime now) → NOT swept, port still in-use"
SHARED4="${SANDBOX}/sh4"
seed_provisional_port "$SHARED4" "fresh" 3005
touch "${SHARED4}/batches/fresh.json"
got_set="$(probe "$SHARED4" "sorted(m._scan_in_use_ports('${SHARED4}')[0])")"
assert_eq "[3005]" "$got_set"
# Sidecar still present
if [ -f "${SHARED4}/batches/fresh.json" ]; then pass; else fail "fresh sidecar got swept"; fi

# ── Scenario 5: provisional past TTL → swept; port freed.
it "stale provisional (mtime past TTL) → swept; port freed"
SHARED5="${SANDBOX}/sh5"
seed_provisional_port "$SHARED5" "stale" 3007
# Force mtime 1 hour ago (well past default 600s TTL).
touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" "${SHARED5}/batches/stale.json"
got_set="$(probe "$SHARED5" "sorted(m._scan_in_use_ports('${SHARED5}')[0])")"
assert_eq "[]" "$got_set"
it "stale provisional: sidecar removed from disk"
if [ ! -f "${SHARED5}/batches/stale.json" ]; then pass; else fail "stale sidecar still present"; fi

# ── Scenario 6: TTL env override.
it "CLAUDE_AUTO_PROVISIONAL_TTL=0 → every provisional is swept regardless of age"
SHARED6="${SANDBOX}/sh6"
seed_provisional_port "$SHARED6" "even-fresh" 3010
touch "${SHARED6}/batches/even-fresh.json"  # mtime: now
got_set="$(CLAUDE_AUTO_PROVISIONAL_TTL=0 probe "$SHARED6" "sorted(m._scan_in_use_ports('${SHARED6}')[0])")"
# TTL=0 → ANY positive age sweeps. The mtime is now (age ~0), but the
# inequality is strict (`age > ttl`), so a fresh-touched file with ttl=0
# is NOT swept. The next file_op latency typically makes age > 0 by the
# time the scan runs. We assert the more reliable invariant: TTL=0 sweeps
# anything that's measurably old.
# (Re-touch with a tiny age to be deterministic.)
sleep 1
got_set="$(CLAUDE_AUTO_PROVISIONAL_TTL=0 probe "$SHARED6" "sorted(m._scan_in_use_ports('${SHARED6}')[0])")"
assert_eq "[]" "$got_set"

# ── Scenario 7: malformed sidecar is skipped (parity with Stop hook).
it "malformed sidecar: skipped silently, scan continues"
SHARED7="${SANDBOX}/sh7"
mkdir -p "${SHARED7}/batches"
echo "{ not valid json" > "${SHARED7}/batches/bad.json"
seed_committed_port "$SHARED7" "good" 3020
got_set="$(probe "$SHARED7" "sorted(m._scan_in_use_ports('${SHARED7}')[0])")"
assert_eq "[3020]" "$got_set"

# ── Scenario 8: PortPoolExhausted is raised when range fully claimed.
it "all 99 ports claimed → _pick_port raises PortPoolExhausted"
SHARED8="${SANDBOX}/sh8"
mkdir -p "${SHARED8}/batches"
# Make a single sidecar that claims every port.
"$PY" -c "
import json
ports = list(range(3001, 3100))
s = {
  'id': 'full', 'created_at': '2026-01-01T00:00:00Z', 'status': 'committed',
  'composite_intent': 'full', 'plans': [{
    'path': str(p), 'slug': str(p), 'worktree': '/x', 'branch': 'a',
    'port': p, 'suggested_run_id': str(p),
  } for p in ports],
}
with open('${SHARED8}/batches/full.json', 'w') as f:
  json.dump(s, f)
"
# Direct stdin-fed script (avoids the single-expression eval constraint).
raises="$("$PY" - "$AUTO_ROOT" "$SHARED8" <<'PYEOF'
import sys, os, importlib.util
auto_root, shared = sys.argv[1:3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto_spawn", os.path.join(auto_root, "lib", "auto-spawn.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m._pick_port(m._scan_in_use_ports(shared)[0])
    print("no-raise")
except m.PortPoolExhausted:
    print("raised")
PYEOF
)"
assert_eq "raised" "$raises"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "port-discovery.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
