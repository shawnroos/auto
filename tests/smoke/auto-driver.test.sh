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

auto_test::it "auto-driver SKILL.md is within the 73-line budget (v0.4.0 U4: ≤60; plan 004 widened to ≤70 for workspace handling; v0.7.x entry-routing widened to ≤73 for the conversation-signal setter + verb-routing + degrade-safe steps)"
skill_lines="$(wc -l < "$SKILL" | tr -d ' ')"
auto_test::assert_true "[ \"$skill_lines\" -le 73 ]"

auto_test::it "auto-driver SKILL.md cites driver-reference.md (theory lives there)"
auto_test::assert_true "grep -qF 'driver-reference.md' '$SKILL'"

auto_test::it "driver-reference.md exists (the citation target)"
auto_test::assert_file_exists "$REF"

auto_test::it "auto-driver SKILL.md does NOT carry an OUTPUT VOICE preamble (v0.4.0 U4)"
auto_test::assert_true "! grep -qE '^##[[:space:]]+OUTPUT VOICE' '$SKILL'"

# ── conversation-context is driver-owned; NO env backchannel (U4) ─────────────
# The retired CLAUDE_AUTO_CONVERSATION_SIGNAL backchannel had the detector reach
# for transcript signal it structurally can't sense. U4 removes it: the driver no
# longer sets any signal env var on the detector call, and it owns the
# conversation-vs-stale-plan decision from the transcript instead.
auto_test::it "auto-driver SKILL.md no longer sets the retired CLAUDE_AUTO_CONVERSATION_SIGNAL (U4)"
auto_test::assert_true "! grep -qE 'CLAUDE_AUTO_CONVERSATION_SIGNAL=1[[:space:]]+bash.*auto-detect\\.sh' '$SKILL'"

auto_test::it "auto-driver SKILL.md owns conversation-context as a driver decision (U4)"
auto_test::assert_true "grep -qiF 'driver-owned' '$SKILL'"

# ── verb-aware args routing wired into the driver (v0.7.x U4) ─────────────────
# The freeform-args rule must consult lib/verb-classify.py (not blindly route
# every non-plan-file arg to /ce-plan) so imperatives about existing work reach
# WORK — the fix for the 2026-06 field misroute. Pin the wiring; the routing
# itself is model-executed and covered behaviorally by verb-classify.test.sh.
auto_test::it "auto-driver SKILL.md wires lib/verb-classify.py into the args rule (U4)"
auto_test::assert_true "grep -qF 'verb-classify.py' '$SKILL'"

VC="$ROOT/lib/verb-classify.py"
auto_test::it "lib/verb-classify.py exists (the args classifier)"
auto_test::assert_file_exists "$VC"

# ── degrade-safe entry (v0.7.x U5) ────────────────────────────────────────────
# A detector subprocess that can't run (env hiccup) must not stall the entry;
# the driver degrades to a raw ask. Pin that the instruction is present.
auto_test::it "auto-driver SKILL.md degrades a detector failure to raw (U5: no stall on env hiccup)"
auto_test::assert_true "grep -qiE 'no parseable envelope|treat as .raw.' '$SKILL'"

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
