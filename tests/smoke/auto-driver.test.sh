#!/usr/bin/env bash
# auto smoke test (fix-pass F): the auto-driver skill exists and exposes
# the voice contract.
#
# Fix-pass F extracted smart-entry + picker + NL routing out of
# commands/auto.md into skills/auto-driver/SKILL.md, and added an OUTPUT
# VOICE directive so agents stop narrating routing logic. This test
# locks in the contract structurally so a future edit that drops the
# voice directive (or the skill itself) goes RED at CI time.
#
# Asserts:
#   - skills/auto-driver/SKILL.md exists
#   - frontmatter declares name: auto-driver
#   - has an `## OUTPUT VOICE` section
#   - contains the phrase "decide silently" (load-bearing contract prose)
#   - commands/auto.md frontmatter lists Skill (the body delegates to
#     this skill via the Skill tool)
#   - commands/auto.md has its own `## OUTPUT VOICE` section
#   - commands/auto.md contains the phrase "decide silently"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
SKILL="$ROOT/skills/auto-driver/SKILL.md"
CMD="$ROOT/commands/auto.md"

# ── auto-driver skill ─────────────────────────────────────────────────────────
auto_test::it "auto-driver SKILL.md exists"
auto_test::assert_file_exists "$SKILL"

auto_test::it "auto-driver SKILL.md frontmatter names the skill"
auto_test::assert_true "grep -qE '^name:[[:space:]]*auto-driver' '$SKILL'"

auto_test::it "auto-driver SKILL.md has an OUTPUT VOICE section"
auto_test::assert_true "grep -qE '^##[[:space:]]+OUTPUT VOICE' '$SKILL'"

auto_test::it "auto-driver SKILL.md contains the 'decide silently' contract phrase"
auto_test::assert_true "grep -qiF 'decide silently' '$SKILL'"

# ── commands/auto.md voice + delegation surface ──────────────────────────────
auto_test::it "commands/auto.md frontmatter lists the Skill tool"
auto_test::assert_true "grep -qE '^allowed-tools:.*\\bSkill\\b' '$CMD'"

auto_test::it "commands/auto.md has an OUTPUT VOICE section"
auto_test::assert_true "grep -qE '^##[[:space:]]+OUTPUT VOICE' '$CMD'"

auto_test::it "commands/auto.md contains the 'decide silently' contract phrase"
auto_test::assert_true "grep -qiF 'decide silently' '$CMD'"

# ── $ARGUMENTS-uniqueness invariant (fix-pass I — round-2 P2 finding F3) ─────
# Per feedback_slash_command_arg_substitution + feedback_slash_command_nl_routing_pattern,
# a slash-command body must contain EXACTLY ONE $ARGUMENTS reference — the
# canonical dispatch line the harness substitutes before bash runs. A stray
# second $-arg line corrupts the substitution. commands/auto.md documents
# the invariant in prose but it was untested at the smoke layer until now.
auto_test::it "commands/auto.md has EXACTLY ONE \$ARGUMENTS reference (uniqueness invariant)"
arg_count="$(grep -c '\$ARGUMENTS' "$CMD")"
auto_test::assert_true "[ \"$arg_count\" = \"1\" ]"

# Deliberate-fail control (per feedback_new_tests_need_deliberate_fail_smoke_check):
# probe a synthetic scratch file shaped like a malformed auto.md (TWO $-arg
# lines). The same predicate must detect the regression class — proves the
# uniqueness check actually counts, not just trivially passes.
auto_test::it "deliberate-fail control: a two-\$ARGUMENTS body produces count=2 (uniqueness check actually counts)"
SCRATCH="$(mktemp)"
printf '%s\n%s\n' 'bash "$ARGUMENTS"' 'echo "$ARGUMENTS"' > "$SCRATCH"
scratch_count="$(grep -c '\$ARGUMENTS' "$SCRATCH")"
rm -f "$SCRATCH"
auto_test::assert_true "[ \"$scratch_count\" = \"2\" ]"

# ── Summary ──────────────────────────────────────────────────────────────────
auto_test::summary
exit $?
