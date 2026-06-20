#!/usr/bin/env bash
# auto unit test: every slash command the loop FIRES must be a real command.
#
# Regression guard for the class of bug where the engine re-arms into a
# slash command that was never registered. The loop self-paces by emitting
# a `rearm` intent whose `prompt` is `/auto-tick <run>` and by telling the
# model (SKILL.md §2) to `ScheduleWakeup(prompt="/auto-tick <run>")`. For a
# long time `commands/auto-tick.md` did not exist — so every re-arm fired
# `/auto-tick`, the harness reported "Unknown command: /auto-tick", the tick
# never ran, and the run stalled by construction. The full engine test suite
# was 572/0 GREEN the whole time because it asserts the rearm STRING is
# `/auto-tick` (tick.test.sh) but never that the string RESOLVES to a command.
#
# This test IS that missing check: it scrapes every `/auto-*` slash-command
# token that appears on a prompt-bearing or ScheduleWakeup-bearing line in
# the shipped engine (lib/) and driver docs (skills/), and asserts each one
# maps to a `commands/<name>.md` file. A new re-arm target cannot ship
# without its command, or this lint trips.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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

# Collect the distinct /auto-* command tokens the loop instructs the model to
# FIRE. We scope to lines that mention `prompt` or `ScheduleWakeup` so prose
# references (e.g. "see /auto-status") don't count — only commands the engine
# actually submits as a prompt are load-bearing for self-pacing.
#
# `|| true` so a no-match (would be a surprise) doesn't trip set -e.
collect_fired_commands() {
  ( cd "$AUTO_ROOT" && \
    grep -rhnE 'prompt|ScheduleWakeup' lib/ skills/ \
      --include='*.py' --include='*.sh' --include='*.md' \
      --exclude-dir='__pycache__' \
      2>/dev/null \
    | grep -oE '/auto(-[a-z]+)*' \
    | sort -u \
    || true \
  )
}

# Map a fired command token (e.g. "/auto-tick") to its expected command file
# and report any that are missing.
missing_command_files() {
  local missing=""
  local token name file
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    name="${token#/}"                      # strip leading slash
    file="${AUTO_ROOT}/commands/${name}.md"
    if [ ! -f "$file" ]; then
      missing="${missing}${token} -> commands/${name}.md (MISSING)
"
    fi
  done <<EOF
$(collect_fired_commands)
EOF
  printf '%s' "$missing"
}

# ─── Scenario 1: every fired /auto-* command resolves to a command file ─────
it "every /auto-* command the loop fires has a commands/<name>.md"
fired="$(collect_fired_commands)"
if [ -z "$fired" ]; then
  fail "no /auto-* fired-command tokens found — the scraper is broken (it should at least find /auto-tick)"
else
  missing="$(missing_command_files)"
  if [ -z "$missing" ]; then
    pass
  else
    fail "fired commands with no command file:
${missing}"
  fi
fi

# ─── Scenario 2: the load-bearing case, named explicitly ────────────────────
# /auto-tick is the heartbeat; assert its file directly so a regression names
# the exact symptom Shawn saw ("Unknown command: /auto-tick").
it "commands/auto-tick.md exists (the self-pacing heartbeat command)"
if [ -f "${AUTO_ROOT}/commands/auto-tick.md" ]; then
  pass
else
  fail "commands/auto-tick.md is missing — every re-arm will report 'Unknown command: /auto-tick' and the run will stall"
fi

# ─── Scenario 3: deliberate-fail control — a fired-but-missing command trips ─
# Plant a temp lib file that fires a command with no command file, run the
# missing-file check, confirm it catches the plant. Proves the lint actually
# detects the gap (a 0-assertion test would report green while testing nothing).
it "deliberate-fail: a rearm into a nonexistent command is caught"
tmpfile="${AUTO_ROOT}/lib/__rearm_probe__.py"
printf '%s\n' 'rearm_prompt = "/auto-nonexistent-probe {run_id}"  # prompt' > "$tmpfile"
probe_result="$(missing_command_files)"
rm -f "$tmpfile"
case "$probe_result" in
  *auto-nonexistent-probe*) pass ;;
  *) fail "planted rearm into a missing command NOT caught: ${probe_result:-<empty>}" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "rearm-command-exists.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
