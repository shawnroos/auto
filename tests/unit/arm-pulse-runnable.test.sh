#!/usr/bin/env bash
# auto U6 (finding #5): the `arm-pulse` intent must name the exact shell RUNNABLE
# (`bash lib/pulse.sh "<run> --auto"`), not only a `/auto:auto-pulse <run>`
# slash-command prompt the driving model may be unable to invoke (that command
# isn't in the skill list, and re-invoking `auto:auto` is circular). A driver
# reads the `runnable` field and fires the pulse directly.
#
# Institutional anchors:
#   - field-notes-2026-07-21 finding #5 (no clean way to fire the pulse)

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
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

probe() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
import _bootstrap as b
scenario = sys.argv[2]
if scenario == "runnable_field":
    intent = b.build_arm_intent("r1", b.build_pulse_prompt("r1"), "note")
    print(intent.get("runnable"))
elif scenario == "builder":
    print(b.build_pulse_runnable("r1"))
elif scenario == "prompt_preserved":
    # The slash-command prompt is retained (back-compat) alongside runnable.
    intent = b.build_arm_intent("r1", b.build_pulse_prompt("r1"), "note")
    print("%s|%s" % (intent.get("action"), intent.get("prompt")))
elif scenario == "extra_and_note_intact":
    from collections import OrderedDict
    intent = b.build_arm_intent(
        "r1", b.build_pulse_prompt("r1"), "the-note",
        extra=OrderedDict([("auto", True), ("backend", "ce")]))
    print("%s|%s|%s" % (intent.get("auto"), intent.get("backend"), intent.get("note")))
else:
    sys.exit("unknown scenario: %s" % scenario)
PYEOF
}

echo "arm-pulse-runnable.test.sh"

it "#5: arm-pulse intent carries the exact runnable string"
assert_eq 'bash lib/pulse.sh "r1 --auto"' "$(probe runnable_field)"

it "#5: build_pulse_runnable(run) is the single builder of that string"
assert_eq 'bash lib/pulse.sh "r1 --auto"' "$(probe builder)"

it "#5: the slash-command prompt is preserved (back-compat, alongside runnable)"
assert_eq 'arm-pulse|/auto:auto-pulse r1' "$(probe prompt_preserved)"

it "#5: extra keys and trailing note are still emitted (envelope shape intact)"
assert_eq 'True|ce|the-note' "$(probe extra_and_note_intact)"

echo ""
echo "arm-pulse-runnable.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
