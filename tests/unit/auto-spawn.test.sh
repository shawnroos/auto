#!/usr/bin/env bash
# auto v0.4.0 U2 unit test: lib/auto-spawn.py — multi-plan fanout.
#
# Pins:
#   1. Three plans → three worktrees, three distinct ports, sidecar
#      committed after all worktrees succeed.
#   2. Slug collision: re-spawning the same plan in the same session
#      uniquifies the slug via `-2`, `-3`.
#   3. PortPoolExhausted: 99 pre-claimed ports raise with a clear message.
#   4. Round-3 R3-001 regression: worktree path is
#      <resolve_host_repo_root>/worktrees/<slug>, NOT under the calling
#      worktree (verified by running from inside a worktree).
#   5. Partial-failure rollback: a worktree-add failure tears down
#      successfully-created worktrees AND deletes the provisional sidecar.
#   6. Crash-recovery sweep (round-4 R4-002): a provisional sidecar older
#      than the TTL is silently dropped on the next port-discovery scan.
#   7. cmux unavailable → CmuxUnavailable with a clear message.
#   8. Sub-run dispatch shape: the cmux command matches the verified
#      shape from cmux-socket.sh::auto::spawn_resume.
#
# The cmux binary is stubbed for these scenarios — a fake `cmux` on PATH
# records args to a file, so we exercise the dispatcher without actually
# spawning workspaces.

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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
ORIG_PATH="$PATH"
SANDBOX="$(mktemp -d -t auto-spawn-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_PATH"
  case "$SANDBOX" in
    */auto-spawn-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Fake cmux binary on PATH ──────────────────────────────────────────────
# Stub `cmux` that records its argv to a file. Tests can grep the recording.
STUB_BIN="${SANDBOX}/bin"
mkdir -p "$STUB_BIN"
CMUX_LOG="${SANDBOX}/cmux.log"
cat > "${STUB_BIN}/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CMUX_LOG}"
exit 0
EOF
chmod +x "${STUB_BIN}/cmux"
export PATH="${STUB_BIN}:${ORIG_PATH}"

# ── Helper: build a fresh host repo + return its path. ────────────────────
make_host_repo() {
  local repo; repo="$(mktemp -d -t spawn-host.XXXXXX)"
  (
    cd "$repo"
    git init -q .
    git config user.email t@t
    git config user.name t
    # Real commit so worktrees can branch.
    printf '.claude/\nworktrees/\n' > .gitignore
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m init
  )
  echo "$repo"
}

# Helper: seed N plan files under docs/plans/.
seed_plans() {
  local repo="$1"; shift
  mkdir -p "${repo}/docs/plans"
  for name in "$@"; do
    echo "# ${name}" > "${repo}/docs/plans/${name}.md"
  done
}

# Helper: invoke auto-spawn.py from inside the repo (so resolve_host_repo_root
# binds to it) and return its exit code + manifest JSON. Stores the manifest
# at $repo/spawn-out.json for grep.
run_fanout() {
  local repo="$1"; shift
  (
    cd "$repo"
    "$PY" "$SPAWN" fanout "$@" > "${repo}/spawn-out.json" 2> "${repo}/spawn-err.txt"
  )
  echo $?
}

# ── Scenario 1: three plans → three worktrees, three ports, sidecar committed
it "fanout: 3 plans → 3 worktrees + 3 distinct ports + committed sidecar"
H1="$(make_host_repo)"
seed_plans "$H1" "alpha" "beta" "gamma"
rc=$(run_fanout "$H1" "docs/plans/alpha.md" "docs/plans/beta.md" "docs/plans/gamma.md")
assert_eq "0" "$rc"

# Worktrees exist under <host>/worktrees/<slug>
for slug in alpha beta gamma; do
  if [ ! -d "${H1}/worktrees/${slug}" ]; then
    fail "worktree ${slug} missing under ${H1}/worktrees/"
    break
  fi
done
[ -d "${H1}/worktrees/alpha" ] && [ -d "${H1}/worktrees/beta" ] && [ -d "${H1}/worktrees/gamma" ] && pass || true

# Three distinct ports
it "fanout: manifest has 3 distinct ports in 3001-3099 range"
distinct_ports="$("$PY" -c "
import json
m = json.load(open('${H1}/spawn-out.json'))
ports = [p['port'] for p in m]
print(len(set(ports)) == 3 and all(3001 <= p <= 3099 for p in ports))
")"
assert_eq "True" "$distinct_ports"

# Sidecar committed (status="committed")
it "fanout: sidecar status flipped from provisional to committed"
committed="$("$PY" -c "
import glob, json
files = glob.glob('${H1}/.claude/auto/batches/*.json')
assert len(files) == 1, files
s = json.load(open(files[0]))
print(s.get('status') == 'committed' and len(s.get('plans', [])) == 3)
")"
assert_eq "True" "$committed"

# Worktree paths in sidecar are ABSOLUTE (round-3 R3-001 contract)
it "fanout: sidecar plans[].worktree paths are absolute (cleanup-readiness)"
abs_ok="$("$PY" -c "
import glob, json, os
s = json.load(open(glob.glob('${H1}/.claude/auto/batches/*.json')[0]))
print(all(os.path.isabs(p['worktree']) for p in s['plans']))
")"
assert_eq "True" "$abs_ok"

# cmux was invoked once per plan, with the verified --command shape
it "fanout: cmux invoked once per plan with sleep+CLAUDE_AUTO_REPO+/auto pattern"
spawn_count="$(grep -c "new-workspace" "${CMUX_LOG}" || true)"
assert_eq "3" "$spawn_count"

it "fanout: cmux command embeds CLAUDE_AUTO_REPO=<worktree> for each spawn"
repo_pin_count="$(grep -c "CLAUDE_AUTO_REPO" "${CMUX_LOG}" || true)"
assert_eq "3" "$repo_pin_count"

it "fanout: cmux command includes the load-bearing 'sleep 1;' lead-in"
sleep_count="$(grep -c "sleep 1;" "${CMUX_LOG}" || true)"
assert_eq "3" "$sleep_count"

# Reset cmux log for next scenario
: > "${CMUX_LOG}"
rm -rf "$H1"

# ── Scenario 2: slug collision → -2 / -3 suffix
it "fanout: same plan twice → second slug gets '-2' suffix"
H2="$(make_host_repo)"
seed_plans "$H2" "duplo"
# First spawn (so worktrees/duplo exists)
run_fanout "$H2" "docs/plans/duplo.md" >/dev/null
# Second spawn of the SAME plan — should land at worktrees/duplo-2
rc=$(run_fanout "$H2" "docs/plans/duplo.md")
assert_eq "0" "$rc"
if [ -d "${H2}/worktrees/duplo" ] && [ -d "${H2}/worktrees/duplo-2" ]; then
  pass
else
  fail "expected worktrees/duplo and worktrees/duplo-2; got $(ls ${H2}/worktrees/)"
fi
: > "${CMUX_LOG}"
rm -rf "$H2"

# ── Scenario 3: PortPoolExhausted with a clear message
it "fanout: 99 ports pre-claimed → PortPoolExhausted error"
H3="$(make_host_repo)"
seed_plans "$H3" "lonely"
# Plant a sidecar that claims all 99 ports.
mkdir -p "${H3}/.claude/auto/batches"
"$PY" -c "
import json
ports = list(range(3001, 3100))
side = {
  'id': '2026-00-00-pre',
  'created_at': '2026-01-01T00:00:00Z',
  'status': 'committed',
  'composite_intent': 'pre',
  'plans': [{'path': 'p', 'slug': 'p', 'worktree': '/x', 'branch': 'auto/p', 'port': p, 'suggested_run_id': 'p'} for p in ports],
}
import os
with open('${H3}/.claude/auto/batches/pre.json', 'w') as f:
  json.dump(side, f)
"
rc=$(run_fanout "$H3" "docs/plans/lonely.md")
# Exit code 3 from the CLI; error message references the port pool.
if [ "$rc" = "3" ] && grep -q "no free port" "${H3}/spawn-err.txt"; then
  pass
else
  fail "rc=$rc, err=$(cat ${H3}/spawn-err.txt)"
fi
: > "${CMUX_LOG}"
rm -rf "$H3"

# ── Scenario 4: R3-001 regression — fanout FROM a worktree lands worktrees
# under the MAIN repo's worktrees/, not under the calling worktree.
it "R3-001 regression: fanout from inside a worktree lands worktrees under MAIN repo"
H4="$(make_host_repo)"
seed_plans "$H4" "fromwt"
# Create a host-side worktree and run fanout from inside it.
(
  cd "$H4"
  git worktree add -q -b sandwich-wt "${H4}-sandwich" >/dev/null 2>&1
)
WT="${H4}-sandwich"
seed_plans "$WT" "fromwt"  # worktree's own docs/plans copy
(
  cd "$WT"
  "$PY" "$SPAWN" fanout "docs/plans/fromwt.md" > "${H4}/spawn-out.json" 2> "${H4}/spawn-err.txt"
)
# Worktree should be at $H4/worktrees/fromwt, NOT at $WT/worktrees/fromwt
if [ -d "${H4}/worktrees/fromwt" ] && [ ! -d "${WT}/worktrees/fromwt" ]; then
  pass
else
  fail "expected ${H4}/worktrees/fromwt; got: main=$(ls ${H4}/worktrees/ 2>/dev/null) wt=$(ls ${WT}/worktrees/ 2>/dev/null)"
fi
# Cleanup the sandwich worktree
(cd "$H4" && git worktree remove -f "${H4}/worktrees/fromwt" >/dev/null 2>&1 || true)
(cd "$H4" && git worktree remove -f "$WT" >/dev/null 2>&1 || true)
rm -rf "$H4" "$WT"
: > "${CMUX_LOG}"

# ── Scenario 5: partial-failure rollback
it "fanout: 2nd worktree-add fails → 1st worktree removed + provisional sidecar deleted"
H5="$(make_host_repo)"
seed_plans "$H5" "p_first" "p_second"
# Pre-create worktrees/p_second to force `git worktree add` to fail on the 2nd plan.
mkdir -p "${H5}/worktrees/p_second"
echo "blocker" > "${H5}/worktrees/p_second/.guard"
rc=$(run_fanout "$H5" "docs/plans/p_first.md" "docs/plans/p_second.md")
# Expect failure (rc=3 from CLI).
if [ "$rc" = "3" ]; then
  # First worktree should have been rolled back.
  if [ ! -d "${H5}/worktrees/p_first" ]; then
    # Provisional sidecar should be gone too.
    if [ -z "$(ls ${H5}/.claude/auto/batches/ 2>/dev/null)" ]; then
      pass
    else
      fail "sidecar still present: $(ls ${H5}/.claude/auto/batches/)"
    fi
  else
    fail "p_first worktree should have been rolled back"
  fi
else
  fail "expected rc=3 (rollback after failure); got rc=$rc"
fi
: > "${CMUX_LOG}"
rm -rf "$H5"

# ── Scenario 6: crash-recovery sweep (round-4 R4-002)
it "crash-recovery sweep: stale provisional sidecar dropped on next port-discovery"
H6="$(make_host_repo)"
seed_plans "$H6" "fresh"
# Plant a provisional sidecar that's "old" (force mtime far in the past).
mkdir -p "${H6}/.claude/auto/batches"
"$PY" -c "
import json
side = {
  'id': 'stale', 'created_at': '2020-01-01T00:00:00Z', 'status': 'provisional',
  'composite_intent': 'stale', 'plans': [{
    'path': 'old', 'slug': 'old', 'worktree': '/x', 'branch': 'auto/old', 'port': 3001,
    'suggested_run_id': 'old',
  }],
}
with open('${H6}/.claude/auto/batches/stale.json', 'w') as f:
  json.dump(side, f)
"
# Force mtime 1 hour in the past so the default 600s TTL trips.
touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)" "${H6}/.claude/auto/batches/stale.json"
# Set provisional TTL to 60s so we don't need to wait.
rc=$(CLAUDE_AUTO_PROVISIONAL_TTL=60 run_fanout "$H6" "docs/plans/fresh.md")
assert_eq "0" "$rc"
# The stale sidecar should be GONE.
it "crash-recovery sweep: stale sidecar removed from disk"
if [ ! -f "${H6}/.claude/auto/batches/stale.json" ]; then
  pass
else
  fail "stale sidecar still present"
fi
# New batch should claim port 3001 (the freed port).
it "crash-recovery sweep: freed port (3001) is re-claimed by the new batch"
new_port="$("$PY" -c "
import glob, json
files = [f for f in glob.glob('${H6}/.claude/auto/batches/*.json') if 'stale' not in f]
s = json.load(open(files[0]))
print(s['plans'][0]['port'])
")"
assert_eq "3001" "$new_port"
: > "${CMUX_LOG}"
rm -rf "$H6"

# ── Scenario 7: cmux unavailable → clear error
it "cmux unavailable: fanout raises CmuxUnavailable with clear message"
# Temporarily hide cmux by emptying PATH (preserving stdlib paths via /usr/bin).
H7="$(make_host_repo)"
seed_plans "$H7" "nocmux"
(
  cd "$H7"
  PATH="/usr/bin:/bin" "$PY" "$SPAWN" fanout "docs/plans/nocmux.md" \
    > "${H7}/spawn-out.json" 2> "${H7}/spawn-err.txt"
  echo $?
) > "${H7}/rc.txt"
rc="$(cat ${H7}/rc.txt)"
if [ "$rc" = "3" ] && grep -q "cmux required" "${H7}/spawn-err.txt"; then
  pass
else
  fail "rc=$rc; err=$(cat ${H7}/spawn-err.txt)"
fi
rm -rf "$H7"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "auto-spawn.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
