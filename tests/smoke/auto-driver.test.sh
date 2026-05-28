#!/usr/bin/env bash
# auto smoke test (v0.4.0 U4): the auto-driver skill is structurally sized
# and cites the driver-reference doc instead of inlining theory.
#
# Fix-pass F (predecessor) added an OUTPUT VOICE preamble to stop agents
# narrating routing logic. v0.4.0 U4 went further — the entire preamble
# was itself the narration symptom (an agent reading "do not narrate"
# tends to narrate). The fix is structural: cut the skill surface to a
# size budget, move mechanism prose to docs/contracts/driver-reference.md,
# and let the slim body enforce brevity instead of rules-about-brevity.
#
# Asserts:
#   - skills/auto-driver/SKILL.md exists and ≤ 60 lines (U4 budget)
#   - frontmatter declares name: auto-driver
#   - cites docs/contracts/driver-reference.md (theory lives there)
#   - no OUTPUT VOICE preamble (it was the disease; cutting surface is the cure)
#   - commands/auto.md frontmatter lists Skill (the body delegates to
#     this skill via the Skill tool)
#   - commands/auto.md has EXACTLY ONE $ARGUMENTS reference

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../helpers/test-helpers.sh"

ROOT="$(auto_test::plugin_root)"
SKILL="$ROOT/skills/auto-driver/SKILL.md"
CMD="$ROOT/commands/auto.md"
REF="$ROOT/docs/contracts/driver-reference.md"

# ── auto-driver skill ─────────────────────────────────────────────────────────
auto_test::it "auto-driver SKILL.md exists"
auto_test::assert_file_exists "$SKILL"

auto_test::it "auto-driver SKILL.md frontmatter names the skill"
auto_test::assert_true "grep -qE '^name:[[:space:]]*auto-driver' '$SKILL'"

auto_test::it "auto-driver SKILL.md is within the 60-line budget (U4)"
skill_lines="$(wc -l < "$SKILL" | tr -d ' ')"
auto_test::assert_true "[ \"$skill_lines\" -le 60 ]"

auto_test::it "auto-driver SKILL.md cites driver-reference.md (theory lives there)"
auto_test::assert_true "grep -qF 'driver-reference.md' '$SKILL'"

auto_test::it "driver-reference.md exists (the citation target)"
auto_test::assert_file_exists "$REF"

auto_test::it "auto-driver SKILL.md does NOT carry an OUTPUT VOICE preamble (v0.4.0 U4)"
auto_test::assert_true "! grep -qE '^##[[:space:]]+OUTPUT VOICE' '$SKILL'"

# ── commands/auto.md delegation surface ──────────────────────────────────────
auto_test::it "commands/auto.md frontmatter lists the Skill tool"
auto_test::assert_true "grep -qE '^allowed-tools:.*\\bSkill\\b' '$CMD'"

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
