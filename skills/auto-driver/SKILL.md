---
name: auto-driver
description: >
  Orient the agent BEFORE /auto starts a run. Use when /auto is invoked
  without an explicit `--recipe` flag — this skill runs the deterministic
  smart-entry detector (in-flight run? reviewed plan? raw?), fires the
  recipe picker when a plan is named without a recipe, and interprets
  freeform sentences ("run the auth plan", "use the native adapter") into
  a flag-form invocation. Ends by handing off to `lib/auto.sh` with a
  resolved argument string. Distinct from the `auto` skill (the loop
  driver): `auto-driver` runs BEFORE the run starts; `auto` takes over
  AFTER the run is armed.
---

# auto-driver (the pre-flight orientation skill)

## OUTPUT VOICE (read before doing anything)

Decide silently. Run detectors, fire AskUserQuestion when ambiguity is
real, and dispatch — but DO NOT narrate the routing logic to the
operator. Surface ONE short action line per branch ("resuming run
`<id>`", "starting the work-only recipe on `<plan>`", "recommend
`/ce-plan <issue>` first") and act. No narration. No thinking out loud
about which branch applies. The agent that loads this skill keeps its
prose to a single action line plus whatever AskUserQuestion needs.

The orchestrator command that loaded this skill is `commands/auto.md`;
it has already routed here because the operator's invocation does NOT
contain `--recipe`. The argument string is whatever the operator typed
after `/auto`.

## 1. Smart-entry (bare `/auto` and plan-name-only invocations)

If the argument string is empty OR is just a freeform reference with no
explicit recipe, run the deterministic situation detector first. It
prints ONE verdict line — branch on it silently.

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-detect.sh"
```

The five verdicts and the action per verdict:

- **`in-flight\t<run-id>`** — a run is mid-flight (its
  `exit_predicate_result.met` is False). RESUME it: invoke the Bash tool
  with `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"`.
  Surface "resuming run `<run-id>`" — that is the one action line.
- **`ambiguous-runs\t<n>`** — more than one in-flight run. Do NOT
  guess. Fire AskUserQuestion listing the runs (use `bash
  "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh"` to describe each), then
  resume the chosen one via
  `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"`.
- **`reviewed-plan\t<path>`** — no in-flight run, one reviewed plan
  present. The user likely wants to BUILD it. Fire AskUserQuestion:
  "Start the work-loop on `<path>` (work-only recipe — skip the
  plan-loop)?" with options "yes, build it" / "no, pick a recipe" /
  "no, just show me". On "yes" dispatch
  `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<path> --recipe w"`. On
  "no, pick a recipe" fall through to the picker (section 3) for that
  plan. (Work-only is the green-plan path — the plan-loop would
  re-derive finished work; see the prepare/execute note at the bottom.)
- **`ambiguous-plans\t<n>`** — no run, multiple plans. Pick the plan
  via AskUserQuestion first (enumerate with glob on `docs/plans/*.md`,
  `plans/*.md`, `*-plan.md`), then fall through to the picker (section
  3).
- **`raw`** — no run, no plan. Plan-production is UPSTREAM of `/auto`'s
  work-loop. Recommend `/ce-plan <issue>` (or `/ce-brainstorm` if the
  work is ambiguous) and STOP. Do not start an empty run. Offer the A1
  plan-loop only if the user explicitly wants the engine to drive
  planning.
- **anything else** — CLI-002 unknown-verdict guard (fix-pass E intent
  preserved on top of F's auto-driver extraction). If `auto-detect.sh`
  returns a verdict that is NOT one of the five above (an unexpected or
  garbled line), treat it as the SAFEST action: recommend `/ce-plan
  <issue>` (same surface as `raw`) and do NOT start a run. Surface the
  unexpected verdict so the operator can file it.

## 2. NL routing (freeform sentences)

If the operator's argument is a natural-language sentence rather than
flag-form, interpret intent into a flag-form invocation silently:

- "run the auth refactor plan" / "start the X plan" → resolve `X` to a
  plan file (glob `docs/plans/*.md`, `plans/*.md`, `*-plan.md`). One
  match → use it. Multiple matches → AskUserQuestion listing
  candidates. No match → AskUserQuestion listing all discovered plans.
- "use the native adapter" / "with CE" → append `--adapter native|ce`.
- "no seam pause" / "don't stop at the seam" / "auto through" → append
  the literal `auto` token.
- 'goal: "<...>"' or "stop when ..." → append `--goal "<text>"`.
- "start something" / "begin a run" with no plan implied → behave as
  bare smart-entry (section 1).

Once a plan is identified WITHOUT an explicit recipe, fall through to
the picker (section 3) before dispatching.

## 3. Recipe picker (a plan is named, no `--recipe` chosen)

When a plan is identified to START a run and the user did NOT name a
recipe, pick one before dispatching:

- Enumerate recipes: `bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh"`
  — each line is `<name>\t<tier>\t<description>`.
- Fire AskUserQuestion with one option per recipe: label =
  `<name> (<tier>)`, description = the recipe's description. For the
  preview, use
  `bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh" --render <name>`
  (the ASCII topology card) IF the AskUserQuestion preview field
  renders multi-line ASCII; otherwise omit the preview and rely on
  label + description (KTD-9 fallback — picker still works, just
  without the visual card).
- The default/first option is `a1 (built-in)` — the classic stack — so
  a user who just hits enter gets the v0.1.x-equivalent workflow.
- Tier badge matters: a `<name> (workspace)` option is a project-local
  recipe that may shadow a built-in of the same name — the badge is
  the user's signal (security: KTD-13 also logs the resolved tier to
  stderr at run start).
- On selection, append `--recipe <chosen>` to the resolved flag-form
  and dispatch via the Bash tool directly:
  `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<resolved-string>"`. Do
  NOT route back through `commands/auto.md`'s substitution dispatch.

## 4. Hand-off — `lib/auto.sh` owns from here

Once a final flag-form string is resolved (with `--recipe` present),
invoke `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<resolved>"` via the
Bash tool. From that point forward the `auto` skill (the loop driver)
takes over: it arms the tick chain, drives the plan-loop → seam →
work-loop, and reports at exit. `auto-driver` is done.

## Prepare/execute contract (surface this when starting/resuming)

`auto` is a **prepare/execute** engine, not a self-driving loop. Each
tick PREPARES an INTENT (what to do next); the MODEL executes it
(`/ce-plan`, `/ce-doc-review`, `do_unit`, etc.) and feeds results back
via the next tick. When a run starts or resumes, make this unmissable:

- "Run the prepared invocation, then feed results back" — do NOT loop
  `tick.sh` expecting units to appear; ticking alone only cycles the
  state machine (units stay 0).
- **Plan-loop livelock guard:** the plan-loop escapes to the work-loop
  only when `plan_step == "review_plan"` AND `gaps_open == 0`. If you
  reach `review_plan` and `gaps_open` is still null, you MUST run a
  real review and feed back a gap count — otherwise the loop
  deepen↔review cycles forever.
- For an ALREADY-REVIEWED plan, prefer `--recipe w` (work-only) so the
  engine skips the plan-loop instead of re-deriving finished work.

## Explicit argument grammar (for reference)

- **Plan/spec**: `/auto path/to/plan.md` — start a run from a plan.
- **Auto seam**: append `auto` to skip the plan→work seam pause.
- **Adapter**: `--adapter ce|native` selects the workflow adapter.
- **Recipe**: `--recipe <name>` selects a registered workflow topology.
- **Goal**: `--goal "<text>"` supplies a compound deliberate-stop goal
  (e.g. "until only minors remain AND one successful test").
