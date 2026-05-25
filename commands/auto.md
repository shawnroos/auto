---
argument-hint: "[<plan-or-spec> [auto] [--adapter ce|native] [--goal \"...\"]] | freeform sentence"
allowed-tools: Bash, AskUserQuestion, Read, Glob
---

Start a new auto run — the workflow-agnostic pulsed loop engine.

`/auto` initializes a run from a plan or spec, sets a native `/goal` bound
to the loop's exit condition, writes the initial per-unit ledger to
`<repo>/.claude/auto/<run-slug>.json`, and arms the first self-paced tick
(via `ScheduleWakeup`, which re-arms its own successor each tick). The
engine then drives plan-loop -> seam -> work-loop, exiting only when the
adapter-supplied exit predicate holds AND every unit is terminal.

## Argument handling (orchestrator routes BEFORE invoking the script)

Starting a run is the only inherently consequential entry point in the
plugin (`/auto-status` is read-only; `/auto-resume`'s bare default is the
safe `continue`). So bare `/auto` does **not** start anything — it
reports what's available.

Inspect the argument string and route:

1. **Empty (bare `/auto`) — SMART ENTRY (v0.2.0, U12): gather context and
   determine where to pick up.** Bare `/auto` orients itself instead of making
   the user choose the right verb. Run the deterministic situation detector
   first: `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-detect.sh"` — it prints ONE
   verdict line. Branch on it:

   - **`in-flight\t<run-id>`** — a run is mid-flight (its
     `exit_predicate_result.met` is False). RESUME it: invoke the Bash tool with
     `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"`.
     Surface "resuming run `<run-id>`" so the choice is visible. This is the
     `/auto-resume continue` path, auto-chosen — the user didn't have to know to
     type it.
   - **`ambiguous-runs\t<n>`** — more than one in-flight run. Do NOT guess:
     `AskUserQuestion` listing the runs (use `bash
     "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh"` to describe each), then resume
     the chosen one via `auto-resume.sh "continue <run-id>"`.
   - **`reviewed-plan\t<path>`** — no in-flight run, but a reviewed plan is
     present. The user likely wants to BUILD it, not re-plan it. `AskUserQuestion`:
     "Start the work-loop on `<path>` (work-only recipe — skip the plan-loop)?"
     with options "yes, build it" / "no, pick a recipe" / "no, just show me". On
     "yes" invoke `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<path> --recipe w"`.
     (Work-only is the green-plan path — the plan-loop would re-derive finished
     work; see the prepare/execute contract note in the dispatch section.)
   - **`ambiguous-plans\t<n>`** — no run, multiple plans. Fall through to the
     recipe picker (rule 2.5) after the user picks which plan (`Glob` +
     `AskUserQuestion`).
   - **`raw`** — no run, no plan. Plan-production is UPSTREAM of `/auto`'s
     work-loop: recommend `/ce-plan <issue>` (or `/ce-brainstorm` if the work is
     ambiguous) to author + review a plan first, THEN `/auto <plan>`. Do NOT
     start an empty run. Offer the A1 plan-loop only if the user explicitly wants
     the engine to drive planning.

2. **Looks like a flag-form invocation** (starts with a path, or contains
   `--adapter` / `--goal` / `--recipe` / the literal token `auto`) — pass the
   argument string through to the script verbatim. This is the explicit
   power-user form. **If it already contains `--recipe <name>`, skip the picker
   (rule 2.5) entirely** — the user chose the recipe.

2.5. **Recipe picker (v0.2.0, U8)** — when a plan is identified to START a run
   (rule 2 with a plan but NO `--recipe`, or a freeform "run the X plan" from
   rule 3) and the user did not name a recipe, pick one before dispatching:
   - Enumerate recipes: `bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh"` —
     each line is `<name>\t<tier>\t<description>`.
   - Fire `AskUserQuestion` with one option per recipe: label = `<name>
     (<tier>)`, description = the recipe's description. For the preview, use
     `bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh" --render <name>` (the
     ASCII topology card) IF the AskUserQuestion preview field renders multi-line
     ASCII; otherwise omit the preview and rely on the label + description
     (KTD-9 fallback — the picker still works, just without the visual card).
   - The default/first option is `a1 (built-in)` — the classic stack — so a user
     who just hits enter gets the v0.1.x-equivalent workflow.
   - On selection, append `--recipe <chosen-name>` to the resolved flag-form and
     invoke the Bash tool with that string directly (the explicit-invoke path
     below) — do NOT route back through the bare argument-substitution dispatch
     line.
   - Tier badge matters: a `<name> (workspace)` option is a project-local recipe
     that may shadow a built-in of the same name — the badge is the user's signal
     (security: KTD-13 also logs the resolved tier to stderr at run start).

3. **Freeform sentence** — interpret intent into a flag-form invocation:
   - "run the auth refactor plan" / "start the X plan" → resolve `X` to a
     plan file via `Glob`. If exactly one matches, invoke with that path.
     If multiple match, `AskUserQuestion` listing candidates.
     If none match, `AskUserQuestion` listing all discovered plans.
   - "use the native adapter" / "with CE" → set `--adapter native|ce`.
   - "no seam pause" / "don't stop at the seam" / "auto through" → append
     the literal `auto` token.
   - 'goal: "<...>"' or "stop when ..." → append `--goal "<text>"`.
   - "start something" / "begin a run" with no plan implied → behave as
     bare `/auto` (route to rule 1's `AskUserQuestion`).

4. **Ambiguous plan reference** — `AskUserQuestion` with the matched
   plans as options; include the plan's first heading or one-line
   description per option for context.

5. **Confirmation before starting a run is NOT required** — starting is
   the explicit positive action the user invoked. The destructive guard
   lives in `/auto-resume abort`, not here. The one exception is the
   bare-`/auto`-with-single-plan path (rule 1's "yes, start") because the
   user did not name a plan.

After routing, the resolved flag-form string goes to the script.

## Dispatch

If the argument string is empty (rule 1) or already in explicit flag-form (rule
2), run the dispatch line below directly (the harness substitutes
the argument string before bash runs):

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "$ARGUMENTS"`

For rule 1's bare path, do NOT use this substitution dispatch line — smart
entry routes per the detector (resume / work-only / picker / recommend
`/ce-plan`) and invokes the relevant `lib/*.sh` via the Bash tool directly.

If you resolved a freeform sentence into a different flag-form string,
invoke the Bash tool explicitly with that resolved string rather than
going through the substitution path.

## Prepare/execute contract (state this whenever a run starts or resumes)

`auto` is a **prepare/execute** engine, not a self-driving loop. Each tick
PREPARES an INTENT (what to do next); the MODEL executes it (`/ce-plan`,
`/ce-doc-review`, `do_unit`, etc.) and feeds results back via the next tick.
When you start or resume a run, make this unmissable to the operator:

- "Run the prepared invocation, then feed results back" — do NOT loop
  `tick.sh` expecting units to appear; ticking alone only cycles the state
  machine (units stay 0).
- **Plan-loop livelock guard:** the plan-loop escapes to the work-loop only
  when `plan_step == "review_plan"` AND `gaps_open == 0`. If you reach
  `review_plan` and `gaps_open` is still null, you MUST run a real review and
  feed back a gap count — otherwise the loop deepen↔review cycles forever.
- For an ALREADY-REVIEWED plan, prefer `--recipe w` (work-only) so the engine
  skips the plan-loop instead of re-deriving finished work.

## Explicit argument grammar (for reference)

- **Plan/spec**: `/auto path/to/plan.md` — start a run from a plan file.
- **Auto seam**: append `auto` to skip the plan->work seam pause.
- **Adapter**: `--adapter ce|native` selects the workflow adapter.
- **Goal**: `--goal "<text>"` supplies a compound deliberate-stop goal
  (e.g. "until only minors remain AND one successful test").
