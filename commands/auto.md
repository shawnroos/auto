---
argument-hint: "[<plan-or-spec> [auto] [--adapter ce|native] [--goal \"...\"] [--recipe <name>]] | freeform sentence"
allowed-tools: Bash, Skill, AskUserQuestion
---

Start a new auto run — the workflow-agnostic pulsed loop engine.

## OUTPUT VOICE (read before doing anything)

Decide which branch SILENTLY. Print ONE short action line stating what
you are doing (e.g. "Loading auto-driver to orient." or "Dispatching the
work-only recipe."), then act. Do NOT narrate routing logic, do NOT
think out loud about which branch applies, do NOT enumerate options the
operator did not ask for. The agent that reads this command keeps its
prose to a single line.

## Dispatch

Two branches. Decide silently which applies.

1. **Argument string does NOT contain the literal `--recipe`** (covers
   bare `/auto`, freeform sentences, and plan-only flag-form without an
   explicit recipe). Load the `auto-driver` skill via the Skill tool —
   it owns smart-entry detection, the recipe picker, NL routing, and
   the final hand-off to `lib/auto.sh`. Pass the operator's argument
   string through to the skill. Do not narrate.

2. **Argument string contains `--recipe`** (explicit power-user form —
   the operator already chose a recipe). Pass the argument string
   straight to the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "$ARGUMENTS"`

That single dispatch line is the ONLY $-bearing line in this file
(memory `feedback_slash_command_arg_substitution`). All other routing
lives in the `auto-driver` skill.
