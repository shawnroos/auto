# auto

A workflow-agnostic **pulsed loop engine** for Claude Code. `auto` runs the loop
pattern you run by hand — plan → build → review → fix until only the small stuff
remains — as a durable, observable state machine. A disk-persisted per-unit
ledger is the source of truth, so a run survives rate limits and session exits;
resume is one command off the ledger.

The engine is **workflow-blind**: it drives any workflow through a thin adapter
(Compound Engineering's `/ce-*` commands, native Claude, or your own).

## Commands

- **`/auto [<plan>]`** — start (or, bare, *gather context and pick up*: resume an
  in-flight run, offer to build a reviewed plan, or recommend `/ce-plan` for raw
  work). Pick a recipe at start, or pass `--recipe <name>` to skip the picker.
- **`/auto-status [<run>]`** — read-only ledger + health of a run.
- **`/auto-resume [continue|abort|retry|skip] [<run>] [<unit>]`** — the durable
  recovery / continuation path.
- **`/auto-author-recipe`** — author a new recipe from a plain-language
  description (you never write JSON).

## Recipes (v0.3.0)

A **recipe** is a named workflow topology. Fire `/auto <plan>` and a picker lets
you choose; or `--recipe <name>` to pick directly. Four ship built-in:

| recipe | shape |
|--------|-------|
| **a1** — Classic CE Stack | plan → build → review → fix to P3-only exit (the v0.1.x default) |
| **a2** — Parallel Theories + Judge | N competing plans in parallel → a judge picks the winner → build it |
| **a4** — Adversarial Pair + Comparator | two builders, same plan, different biases → a comparator picks/merges |
| **w** — Work-only | you already have a reviewed plan — skip the plan-loop, build its units directly |

*(A3 Build-First Feedback ships in v0.2.1 — it needs non-default phase ordering
that's deferred so its engine path gets its own review.)*

**v0.3.0 adds outcomes-gated emission.** A recipe can declare an optional
`iteration` block so a designated gate unit's verdict (advance / iterate /
exit) drives the loop directly — A2's judge can re-spawn another round of
competing plans, A4's comparator can re-engage its builders, all under an
engine-enforced `max_attempts` + `max_wall_seconds` bound. v0.2.x recipes
validate unchanged. See `docs/contracts/recipe-format.md` §6.

### Your own recipes

Recipes resolve from three tiers, first-wins: **workspace**
(`<repo>/.claude/auto/recipes/`) → **global** (`~/.claude/auto/recipes/`) →
**built-in**. Author one with `/auto-author-recipe` — describe the workflow
(what runs in parallel, where a judge gates, whether the plan's already written)
and the skill compiles + validates it. See `docs/contracts/recipe-format.md`
for the format.

## How it works (prepare/execute)

`auto` is a **prepare/execute** engine, not a self-driving loop. Each tick
*prepares* an INTENT (what to do next); the *model* executes it (`/ce-plan`,
`/ce-work`, `/ce-code-review`, …) and feeds results back via the next tick. Don't
loop the tick blind — run the prepared invocation and report back. For an
already-reviewed plan, `--recipe w` skips the plan-loop so it doesn't re-derive
finished work.

## Contracts

- `docs/contracts/recipe-format.md` — the recipe JSON format (LOCKED v0.3.0).
- `docs/contracts/ledger-schema.md` — the per-unit ledger (the source of truth).
- `docs/contracts/adapter-contract.md` — the seven adapter ops a workflow maps onto.

## Tests

`bash tests/run.sh all` — pure stdlib + bash, no install. (427 passing at v0.3.0.)
