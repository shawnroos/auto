#!/usr/bin/env bash
# auto U9 (finding #8): record spawned agent-ids on the run-record so a died
# agent is auditable against the step that spawned it. The loop has no awareness
# of the boss's Agent spawns (they live outside the run-record), so a zombie
# sub-agent is invisible to reap/reconcile. record_spawned_agent appends the
# agent-id to the dispatched step; re-dispatch (retry) appends the new id so the
# spawn history stays auditable.
#
# (The reap SEQUENCE — TaskStop → SIGTERM → ps-verify — is already documented in
# SKILL.md §4; U9 adds the missing run-record side: who was spawned.)
#
# Institutional anchors:
#   - field-notes-2026-07-21 finding #8 (zombie sub-agents invisible to run-record)
#   - feedback_stop_background_agents_taskstop_then_sigterm

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() { export HOME="$ORIG_HOME"; case "$SANDBOX" in */auto-test.*) rm -rf "$SANDBOX";; esac; }
trap cleanup EXIT
REPO="${SANDBOX}/repo"; mkdir -p "$REPO"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

py() { "$PY" - "$REPO" "$RUN_RECORD_PY" "$@" <<'PYEOF'
import sys, json, importlib.util
repo, run_record_py = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
op = sys.argv[3]
if op == "init":
    m.init_run_record(repo, "r1", backend="ce",
                      steps=[{"id": "U1", "state": "pending", "phase": "work"}],
                      loop_phase="work")
elif op == "record":
    m.record_spawned_agent(repo, "r1", "U1", sys.argv[4])
elif op == "read_ids":
    L = m.read_run_record(repo, "r1")
    step = next(u for u in L["steps"] if u["id"] == "U1")
    print(",".join(step.get("spawned_agent_ids", [])))
PYEOF
}

echo "record-spawned-agent.test.sh"
py init

it "#8: record_spawned_agent appends the agent-id to the step, readable off disk"
py record agent-aaa
assert_eq "agent-aaa" "$(py read_ids)"

it "#8: a second spawn (retry) APPENDS — spawn history stays auditable"
py record agent-bbb
assert_eq "agent-aaa,agent-bbb" "$(py read_ids)"

it "#8: the CLI verb record-spawned-agent works via the shim (driver is model-side)"
( cd "$REPO" && bash "${AUTO_ROOT}/lib/run_record.sh" record-spawned-agent r1 U1 agent-ccc ) >/dev/null 2>&1
assert_eq "agent-aaa,agent-bbb,agent-ccc" "$(py read_ids)"

echo ""
echo "record-spawned-agent.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
