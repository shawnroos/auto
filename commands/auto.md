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

1. **Empty (bare `/auto`)** — show help + state, do NOT start a run:
   - List in-repo runs from `<repo>/.claude/auto/*.json` (most recent
     first) with their phase + state (pull from each ledger's
     `loop.phase` and `exit_predicate_result.met` — use
     `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh"` per run if it has
     a `--brief` form, else read the JSON directly).
   - List candidate plans: `Glob` for `docs/plans/*.md`,
     `plans/*.md`, or `*-plan.md` in the repo root.
   - Print the usage forms below.
   - Offer the obvious next moves: continue the latest run, start from
     the newest plan, or "type `/auto <plan>` / `/auto-resume`".
   - If exactly ONE candidate plan exists AND no active runs exist,
     `AskUserQuestion` whether to start it (with "yes, start" /
     "no, just show me").

2. **Looks like a flag-form invocation** (starts with a path, or contains
   `--adapter` / `--goal` / the literal token `auto`) — pass the argument string
   through to the script verbatim. This is the explicit power-user form.

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

For rule 1's bare path, do NOT execute the dispatch — list runs and plans
in chat instead. The dispatch line only fires if the orchestrator decides
to start a run.

If you resolved a freeform sentence into a different flag-form string,
invoke the Bash tool explicitly with that resolved string rather than
going through the substitution path.

## Explicit argument grammar (for reference)

- **Plan/spec**: `/auto path/to/plan.md` — start a run from a plan file.
- **Auto seam**: append `auto` to skip the plan->work seam pause.
- **Adapter**: `--adapter ce|native` selects the workflow adapter.
- **Goal**: `--goal "<text>"` supplies a compound deliberate-stop goal
  (e.g. "until only minors remain AND one successful test").
