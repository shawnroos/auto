---
argument-hint: "[<plan-or-spec> [--review-plan] [--adapter ce|native] [--goal \"...\"] [--recipe <name>]] | freeform sentence"
allowed-tools: Bash, Skill, AskUserQuestion
---

Start a new auto run — the workflow-agnostic pulsed loop engine.

## Dispatch

Two branches.

1. **Argument string does NOT contain the literal `--recipe`** (covers
   bare `/auto`, freeform sentences, and plan-only flag-form). Load
   the `auto-driver` skill via the Skill tool. The skill loads the
   hypothesis JSON from `lib/auto-detect.sh`, surfaces one action
   line, dispatches when ambiguity is null, or asks one blocking
   question when it isn't. Pass the operator's argument string through.

2. **Argument string contains `--recipe`** (explicit power-user form
   — the operator already chose a recipe). Pass straight to the
   dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "$ARGUMENTS"`

That single dispatch line is the ONLY `$`-bearing line in this file
(memory `feedback_slash_command_arg_substitution`). All other routing
lives in the `auto-driver` skill; theory + edge cases live in
`docs/contracts/driver-reference.md`.

## Environment variables (operator levers)

- `CLAUDE_AUTO_DISABLE_ITERATION=1` — kill-switch for outcomes-gated
  iteration. When set, `advance_iteration_loop` short-circuits and
  the run exits through the standard predicate-met path. Use for
  emergency rollback of a misbehaving recipe without redeploying.
- `CLAUDE_AUTO_PROVISIONAL_TTL=<seconds>` — TTL for provisional batch
  sidecars during fanout (default 600s). Discovery-time sweep drops
  older ones, recovering ports leaked by a crash between worktree
  creation and sidecar commit.

## v0.4.0 seam-default flip (KTD-4)

`/auto <plan>` now PROCEEDS past the plan→work seam by default. Pass
`--review-plan` to opt in to the pause for first-pass plans where you
want to inspect the planned units before work fans out. The legacy
`auto` positional token still parses (no-op against the new default)
so scripted callers keep working without forced rewrites. A one-time
stderr notice fires on the first post-upgrade run.
