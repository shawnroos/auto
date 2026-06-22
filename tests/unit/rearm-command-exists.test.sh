#!/usr/bin/env bash
# auto unit test: the slash command the loop FIRES must (a) exist as a command
# file AND (b) be NAMESPACED so it actually resolves when fired programmatically.
#
# Two-layer regression guard for the self-pacing loop:
#
#   v0.6.2 bug: commands/auto-tick.md did not exist → every re-arm fired
#   `/auto-tick`, the harness said "Unknown command", the tick never ran.
#
#   v0.6.5 bug: the command file existed, but the loop fired the BARE `/auto-tick`.
#   Plugin slash commands fired PROGRAMMATICALLY (ScheduleWakeup / loop
#   re-injection) only resolve in their NAMESPACED `/<plugin>:<command>` form —
#   the bare token is still "Unknown command". So the loop STILL never self-paced
#   even with the file present. The fix: emit `/auto:auto-tick` (plugin name is
#   `auto`).
#
# This test pins BOTH: the programmatic emissions use `/auto:<command>` (never a
# bare `/auto-<sub>`), and each fired `/auto:<command>` has a commands/<command>.md.

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

# NAMESPACED tokens (/auto:<command>) the loop instructs the model to FIRE,
# scraped from prompt/ScheduleWakeup lines in the engine (lib/) + driver skill.
collect_fired_namespaced() {
  ( cd "$AUTO_ROOT" && \
    grep -rhnE 'prompt|ScheduleWakeup' lib/ skills/ \
      --include='*.py' --include='*.sh' --include='*.md' \
      --exclude-dir='__pycache__' 2>/dev/null \
    | grep -oE '/auto:[a-z-]+' \
    | sort -u || true )
}

# BARE auto sub-command tokens (/auto-<sub>) on a prompt-EMISSION line in lib/.
# These are the bug: a programmatic prompt that fires an un-namespaced plugin
# command, which the harness can't resolve. Scoped to lib/ (the f-string
# emissions) so prose that documents the bare form as WRONG doesn't false-trip.
collect_bare_emissions() {
  ( cd "$AUTO_ROOT" && \
    grep -rhnE 'prompt' lib/ --include='*.py' --exclude-dir='__pycache__' 2>/dev/null \
    | grep -oE '/auto-[a-z]+' \
    | sort -u || true )
}

missing_command_files() {
  local missing="" token name file
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    name="${token#/auto:}"                 # /auto:auto-tick -> auto-tick
    file="${AUTO_ROOT}/commands/${name}.md"
    [ -f "$file" ] || missing="${missing}${token} -> commands/${name}.md (MISSING)
"
  done <<EOF
$(collect_fired_namespaced)
EOF
  printf '%s' "$missing"
}

# ─── Scenario 1: the loop fires NAMESPACED commands (scraper finds them) ─────
it "loop fires namespaced /auto:<command> prompts (at least /auto:auto-tick)"
fired="$(collect_fired_namespaced)"
case "$fired" in
  */auto:auto-tick*) pass ;;
  *) fail "no /auto:auto-tick emission found; scraped: ${fired:-<none>}" ;;
esac

# ─── Scenario 2: NO bare un-namespaced /auto-<sub> emissions (the v0.6.5 bug) ─
it "no bare un-namespaced /auto-<command> in programmatic prompt emissions"
bare="$(collect_bare_emissions)"
if [ -z "$bare" ]; then
  pass
else
  fail "bare (un-namespaced) command emissions found — these won't resolve when
fired via ScheduleWakeup/loop; namespace them as /auto:<command>:
${bare}"
fi

# ─── Scenario 3: every fired /auto:<command> has a commands/<command>.md ─────
it "every fired /auto:<command> maps to a commands/<command>.md"
missing="$(missing_command_files)"
[ -z "$missing" ] && pass || fail "fired commands with no file:
${missing}"

# ─── Scenario 4: the heartbeat, named explicitly ────────────────────────────
it "commands/auto-tick.md exists (the self-pacing heartbeat command)"
[ -f "${AUTO_ROOT}/commands/auto-tick.md" ] && pass \
  || fail "commands/auto-tick.md missing — /auto:auto-tick can't resolve, loop stalls"

# ─── Scenario 5: deliberate-fail — a bare emission is caught ─────────────────
it "deliberate-fail: a bare /auto-tick prompt emission trips the namespacing check"
tmpfile="${AUTO_ROOT}/lib/__rearm_probe__.py"
printf '%s\n' 'rearm_prompt = "/auto-tick {run_id}"  # prompt' > "$tmpfile"
probe="$(collect_bare_emissions)"
rm -f "$tmpfile"
case "$probe" in
  */auto-tick*) pass ;;
  *) fail "planted bare emission NOT caught: ${probe:-<empty>}" ;;
esac

echo ""
echo "rearm-command-exists.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
