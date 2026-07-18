#!/usr/bin/env bash
# auto v0.6.0 — REQUIRED, operator-runnable session-id parity gate (KTD-4/5,
# fix-round-5 P1/P2 dupe of round-1/2/3 P2). NOT a *.test.sh — `tests/run.sh`
# discovers only `*.test.sh`, so the in-tree suite never auto-runs this. It
# CANNOT be run in CI: it needs a real PreToolUse stdin payload captured from a
# live `/auto` run, which no in-tree harness produces.
#
# WHY THIS EXISTS:
#   Both advisor-gate PreToolUse hooks are load-bearing on the live PreToolUse
#   stdin `session_id` being BYTE-EQUAL to the `driving_session_id` that
#   lib/auto.py::_driving_session_id() records (from CLAUDE_CODE_SESSION_ID) at
#   arm time. advisor-gate.test.sh injects matching id strings into BOTH the
#   stdin payload and the run-record, so it passes BY CONSTRUCTION and proves nothing
#   about whether the two identifiers share a namespace in the live harness. A
#   mismatch silently no-ops BOTH gates (question gate never redirects; action
#   gate's _owning_run_id returns None -> destructive ops proceed). This is NOT
#   caught by the fail-closed design (which covers only an unavailable `deny`
#   contract, never "not my run -> allow").
#
# HOW TO RUN (the documented §12 blocking step):
#   1. Start one real `/auto` run. In its worktree the run arms a run-record at
#      <repo>/.claude/auto/<run_id>.json carrying `driving_session_id`.
#   2. Capture ONE PreToolUse stdin payload from that same run. The simplest
#      capture: temporarily prepend `tee /tmp/auto-pretooluse.json` ahead of the
#      python exec in .claude/hooks/on-pretooluse-action.sh (or askuser.sh), let
#      the run reach any Bash/AskUserQuestion tool call, then restore the hook.
#   3. Run this script:
#        bash tests/verify-session-parity.sh \
#          /tmp/auto-pretooluse.json \
#          <repo>/.claude/auto/<run_id>.json
#      (the stdin payload may also be piped on stdin instead of arg 1: `-`)
#   4. Record the PASS line in the release checklist
#      (docs/contracts/driver-reference.md §12). If it FAILS, follow the §12
#      remediation: switch the arm-time source in
#      lib/auto.py::_driving_session_id() AND the stdin-read key in BOTH
#      lib/on-pretooluse-askuser.py::_read_session_id and
#      lib/on-pretooluse-action.py::_read_stdin to whatever the live payload
#      actually carries, then re-run until green.
#
# This script reads the SAME `session_id` key the hooks read (data["session_id"])
# and the SAME `driving_session_id` run-record key, so a PASS here is the exact
# equality both gates depend on. Exits NON-ZERO on mismatch so the gate cannot be
# silently skipped in a release pipeline.

set -uo pipefail

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

usage() {
  echo "Usage: bash tests/verify-session-parity.sh <pretooluse-stdin.json|-> <run_record.json>" >&2
  echo "  arg1: captured PreToolUse stdin payload file, or '-' to read it from stdin" >&2
  echo "  arg2: the armed run_record JSON (<repo>/.claude/auto/<run_id>.json)" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

PAYLOAD_ARG="$1"
RUN_RECORD_ARG="$2"

PAYLOAD_JSON=""
if [ "$PAYLOAD_ARG" = "-" ]; then
  PAYLOAD_JSON="$(cat 2>/dev/null || true)"
else
  if [ ! -f "$PAYLOAD_ARG" ]; then
    echo "verify-session-parity: payload file not found: $PAYLOAD_ARG" >&2
    exit 2
  fi
  PAYLOAD_JSON="$(cat "$PAYLOAD_ARG" 2>/dev/null || true)"
fi

if [ ! -f "$RUN_RECORD_ARG" ]; then
  echo "verify-session-parity: run_record file not found: $RUN_RECORD_ARG" >&2
  exit 2
fi

# All comparison logic in Python so it reads the exact same keys the hooks read.
PARITY_PAYLOAD="$PAYLOAD_JSON" "$PYTHON3" - "$RUN_RECORD_ARG" <<'PYEOF'
import json
import os
import sys

run_record_path = sys.argv[1]

# The hooks read data["session_id"] from PreToolUse stdin (see
# on-pretooluse-action.py::_read_stdin and on-pretooluse-askuser.py::_read_session_id).
try:
    payload = json.loads(os.environ.get("PARITY_PAYLOAD") or "")
except Exception as exc:
    print(f"FAIL: PreToolUse payload is not valid JSON ({exc}).")
    sys.exit(1)
if not isinstance(payload, dict):
    print("FAIL: PreToolUse payload is not a JSON object.")
    sys.exit(1)
stdin_sid = payload.get("session_id")

# The hooks compare against run_record["driving_session_id"] (the field
# lib/auto.py::_driving_session_id records at arm time).
try:
    with open(run_record_path) as fh:
        run_record = json.load(fh)
except Exception as exc:
    print(f"FAIL: run_record is not readable/valid JSON ({exc}).")
    sys.exit(1)
if not isinstance(run_record, dict):
    print("FAIL: run_record is not a JSON object.")
    sys.exit(1)
driving_sid = run_record.get("driving_session_id")

print(f"  stdin.session_id        = {stdin_sid!r}")
print(f"  run_record.driving_session_id = {driving_sid!r}")

if not isinstance(stdin_sid, str) or not stdin_sid:
    print("FAIL: PreToolUse stdin carries no string session_id — both gates no-op.")
    sys.exit(1)
if not isinstance(driving_sid, str) or not driving_sid:
    print("FAIL: run_record carries no string driving_session_id — both gates no-op.")
    sys.exit(1)

if stdin_sid == driving_sid:
    print("PASS: stdin.session_id == run_record.driving_session_id (byte-equal). "
          "Both advisor gates fire in production.")
    sys.exit(0)

print("FAIL: stdin.session_id != run_record.driving_session_id — BOTH gates "
      "silently no-op. Apply the §12 remediation (switch the arm-time source "
      "and the stdin-read keys to the live namespace) and re-run.")
sys.exit(1)
PYEOF
exit $?
