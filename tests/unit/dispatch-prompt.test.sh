#!/usr/bin/env bash
# auto U7 (finding #6, Top-3): the canonical dispatch-prompt template as a library
# asset. `dispatch_batch`'s launch_fn is an injected no-op recorder; there was no
# wrapper that turns "dispatch step U3" into "spawn a ce-work agent scoped to U3's
# packet that self-writes its verdict with the attempt tag." The boss hand-built
# each prompt + record-verdict call + attempt tag, and standard /ce-work has no
# run-record awareness — the gap nearly triggered an abort. This asset renders the
# whole contract so every driver wires it identically.
#
# Also carries finding #2's record-before-yield mandate (R8): the prompt MUST tell
# the agent to record its verdict BEFORE any long-running background wait, so a
# slow/flaky verification step cannot strand the verdict at `dispatched`.
#
# Institutional anchors:
#   - field-notes-2026-07-21 findings #6 (Top-3) and #2 (Top-3)
#   - U3: the verdict-write must route through run_record.sh, never `bash …py`

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

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
assert_contains() { case "$2" in *"$1"*) pass ;; *) fail "missing: $1" ;; esac; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

render() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import importlib.util
spec = importlib.util.spec_from_file_location("dispatch_prompt",
        os.path.join(auto_root, "lib", "dispatch_prompt.py"))
dp = importlib.util.module_from_spec(spec); spec.loader.exec_module(dp)
run, step, attempt = sys.argv[2], sys.argv[3], int(sys.argv[4])
goal = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
print(dp.build_dispatch_prompt(run, step, attempt, goal=goal))
PYEOF
}

echo "dispatch-prompt.test.sh"

P="$(render myrun U3 2 'Add the shape guard')"

it "#6: prompt carries the step packet (run id + step id)"
assert_contains "myrun" "$P"

it "#6: prompt names the step being dispatched"
assert_contains "U3" "$P"

it "#6: prompt carries the goal when supplied"
assert_contains "Add the shape guard" "$P"

it "#6: prompt carries the attempt tag (Bug #6 generation)"
assert_contains "2" "$P"

it "#6/U3: verdict-write routes through run_record.sh, NOT bash …run_record.py"
assert_contains "run_record.sh record-verdict" "$P"

it "#6/U3: prompt does NOT instruct running run_record.py directly under bash"
case "$P" in *"bash lib/run_record.py"*|*"run_record.py record-verdict"*) fail "leaks raw .py under bash" ;; *) pass ;; esac

it "#2/R8: prompt carries the record-before-yield mandate"
case "$P" in *"BEFORE"*|*"before any long-running"*|*"before any background"*) pass ;; *) fail "no record-before-yield mandate" ;; esac

it "#6: the record-verdict command embeds this run, step, and attempt"
assert_contains "record-verdict myrun U3" "$P"

# Parameterized: a DIFFERENT step renders a different packet (reusable asset).
Q="$(render otherrun U9 1 'Reap agents')"
it "#6: template is parameterized (different step → different packet)"
case "$Q" in *"U9"*"otherrun"*|*"otherrun"*"U9"*) pass ;; *) fail "packet not parameterized" ;; esac

echo ""
echo "dispatch-prompt.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
