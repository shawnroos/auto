#!/usr/bin/env bash
# auto unit test: the slash command the loop FIRES must (a) exist as a command
# file AND (b) be NAMESPACED so it actually resolves when fired programmatically.
#
# Two-layer regression guard for the self-pacing loop:
#
#   v0.6.2 bug: commands/auto-pulse.md did not exist → every re-arm fired
#   `/auto-pulse`, the harness said "Unknown command", the pulse never ran.
#
#   v0.6.5 bug: the command file existed, but the loop fired the BARE `/auto-pulse`.
#   Plugin slash commands fired PROGRAMMATICALLY (ScheduleWakeup / loop
#   re-injection) only resolve in their NAMESPACED `/<plugin>:<command>` form —
#   the bare token is still "Unknown command". So the loop STILL never self-paced
#   even with the file present. The fix: emit `/auto:auto-pulse` (plugin name is
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
    name="${token#/auto:}"                 # /auto:auto-pulse -> auto-pulse
    file="${AUTO_ROOT}/commands/${name}.md"
    [ -f "$file" ] || missing="${missing}${token} -> commands/${name}.md (MISSING)
"
  done <<EOF
$(collect_fired_namespaced)
EOF
  printf '%s' "$missing"
}

# BARE `claude '/auto...'` startup-args in the spawn/orphan-resume paths
# (lib/cmux-socket.sh, lib/auto-spawn.py). These launch a fresh `claude` with a
# slash command as its initial prompt — the SAME namespacing requirement as
# ScheduleWakeup re-injection (empirically: `claude -p '/auto-status'` → "Unknown
# command"; `/auto:auto-status` → runs). A bare form silently breaks fanout and
# orphan-resume. Match the `claude` BINARY invoked with a bare `/auto` command:
# `claude`, whitespace, optional opening quote, then `/auto` followed by `-`,
# space, or quote. The namespaced `/auto:` form has a colon there and never
# matches. The required whitespace after `claude` avoids matching the
# `.claude/auto` PATH (no space between `claude` and `/auto`).
collect_bare_startup_args() {
  ( cd "$AUTO_ROOT" && \
    grep -rnE "claude +'?/auto[- ']" lib/ \
      --include='*.py' --include='*.sh' --exclude-dir='__pycache__' 2>/dev/null \
    || true )
}

# ─── Scenario 1: the loop fires NAMESPACED commands (scraper finds them) ─────
it "loop fires namespaced /auto:<command> prompts (at least /auto:auto-pulse)"
fired="$(collect_fired_namespaced)"
case "$fired" in
  */auto:auto-pulse*) pass ;;
  *) fail "no /auto:auto-pulse emission found; scraped: ${fired:-<none>}" ;;
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
it "commands/auto-pulse.md exists (the self-pacing heartbeat command)"
[ -f "${AUTO_ROOT}/commands/auto-pulse.md" ] && pass \
  || fail "commands/auto-pulse.md missing — /auto:auto-pulse can't resolve, loop stalls"

# ─── Scenario 4b: the KEPT ALIAS command (concept-vocabulary rename U5, KTD-4) ─
# The rename made /auto:auto-pulse canonical, but runs armed BEFORE it have
# `/auto:auto-tick <run>` persisted inside a ScheduleWakeup prompt (and in stale
# rearm-intent JSON). If commands/auto-tick.md disappears, those in-flight runs
# fire an "Unknown command" and the chain wedges — the exact v0.6.2 bug class,
# re-introduced by a rename. Both command files must exist AND both must dispatch
# the SAME engine (lib/pulse.sh); the alias must NOT point at a stale lib/tick.sh.
it "commands/auto-tick.md alias survives the rename (in-flight ScheduleWakeup prompts fire it)"
[ -f "${AUTO_ROOT}/commands/auto-tick.md" ] && pass \
  || fail "commands/auto-tick.md missing — in-flight runs' persisted /auto:auto-tick can't resolve, loop stalls"

it "both command files (canonical + alias) dispatch lib/pulse.sh"
alias_ok=0; canon_ok=0
grep -qF 'lib/pulse.sh' "${AUTO_ROOT}/commands/auto-tick.md" 2>/dev/null && alias_ok=1
grep -qF 'lib/pulse.sh' "${AUTO_ROOT}/commands/auto-pulse.md" 2>/dev/null && canon_ok=1
if [ "$alias_ok" = 1 ] && [ "$canon_ok" = 1 ]; then
  pass
else
  fail "auto-tick.md dispatches pulse.sh: ${alias_ok}; auto-pulse.md dispatches pulse.sh: ${canon_ok} (both must be 1)"
fi

# ─── Scenario 5: no bare `claude '/auto...'` startup-args in spawn paths ──────
# Twin of the rearm bug: fanout (auto-spawn.py) + orphan-resume (cmux-socket.sh)
# launch `claude '/auto...'` as a startup-arg, which needs the same namespacing.
it "no bare claude '/auto...' startup-args in lib/ (fanout/orphan-resume must use /auto:auto...)"
bare_startup="$(collect_bare_startup_args)"
if [ -z "$bare_startup" ]; then
  pass
else
  fail "bare claude '/auto...' startup-args found — these won't resolve when launched
(empirically confirmed); namespace them as /auto:auto / /auto:auto-resume:
${bare_startup}"
fi

# ─── Scenario 6: deliberate-fail — a bare emission is caught ─────────────────
it "deliberate-fail: a bare /auto-pulse prompt emission trips the namespacing check"
tmpfile="${AUTO_ROOT}/lib/__rearm_probe__.py"
printf '%s\n' 'rearm_prompt = "/auto-pulse {run_id}"  # prompt' > "$tmpfile"
probe="$(collect_bare_emissions)"
rm -f "$tmpfile"
case "$probe" in
  */auto-pulse*) pass ;;
  *) fail "planted bare emission NOT caught: ${probe:-<empty>}" ;;
esac

# ─── Scenario 7: deliberate-fail — a bare startup-arg is caught ──────────────
it "deliberate-fail: a bare claude '/auto...' startup-arg trips the check"
tmpfile="${AUTO_ROOT}/lib/__startup_probe__.sh"
printf '%s\n' "cmd=\"claude '/auto-resume \${run}'\"" > "$tmpfile"
probe2="$(collect_bare_startup_args)"
rm -f "$tmpfile"
case "$probe2" in
  *__startup_probe__*) pass ;;
  *) fail "planted bare startup-arg NOT caught: ${probe2:-<empty>}" ;;
esac

echo ""
echo "rearm-command-exists.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
