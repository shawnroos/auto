# auto

A workflow-agnostic **pulsed loop engine** for Claude Code. `auto` runs the loop
pattern you run by hand — plan → build → review → fix until only the small stuff
remains — as a durable, observable state machine. A disk-persisted per-unit
run-record is the source of truth, so a run survives rate limits and session exits;
resume is one command off the run-record.

The engine is **workflow-blind**: it drives any workflow through a thin adapter
(Compound Engineering's `/ce-*` commands, native Claude, or your own).

## Commands

- **`/auto [<plan>]`** — start (or, bare, *gather context and pick up*: resume an
  in-flight run, offer to build a reviewed plan, or recommend `/ce-plan` for raw
  work). Pick a workflow at start, or pass `--workflow <name>` to skip the picker.
- **`/auto-status [<run>]`** — read-only run-record + health of a run.
- **`/auto-resume [continue|abort|retry|skip] [<run>] [<unit>]`** — the durable
  recovery / continuation path.
- **`/auto-author-workflow`** — author a new workflow from a plain-language
  description (you never write JSON).
- **`/auto-preset <name> <target>`** — run one **preset** (a named, reusable
  step payload — a tuned review, a scoped build) one-shot against a target: no
  flow, no loop. The agent proposes a context-fit check you accept or edit, runs
  it once, and returns a `pass` / `fail` / `unverified` verdict.

## Workflows (v0.3.0)

A **workflow** is a named loop topology — an ordered graph of steps. Fire `/auto <plan>` and a picker lets
you choose; or `--workflow <name>` to pick directly. Four ship built-in:

| workflow | shape |
|--------|-------|
| **a1** — Classic CE Stack | plan → build → review → fix to P3-only exit (the v0.1.x default) |
| **a2** — Parallel Theories + Judge | N competing plans in parallel → a judge picks the winner → build it |
| **a4** — Adversarial Pair + Comparator | two builders, same plan, different biases → a comparator picks/merges |
| **w** — Work-only | you already have a reviewed plan — skip the plan-loop, build its units directly |

*(A3 Build-First Feedback ships in v0.2.1 — it needs non-default phase ordering
that's deferred so its engine path gets its own review.)*

**v0.3.0 adds outcomes-gated emission.** A workflow can declare an optional
`iteration` block so a designated gate unit's verdict (advance / iterate /
exit) drives the loop directly — A2's judge can re-spawn another round of
competing plans, A4's comparator can re-engage its builders, all under an
engine-enforced `max_attempts` + `max_wall_seconds` bound. v0.2.x workflows
validate unchanged. See `docs/contracts/workflow-format.md` §6.

### Your own workflows

Workflows resolve from three tiers, first-wins: **workspace**
(`<repo>/.claude/auto/workflows/`) → **global** (`~/.claude/auto/workflows/`) →
**built-in**. Author one with `/auto-author-workflow` — describe the workflow
(what runs in parallel, where a judge gates, whether the plan's already written)
and the skill compiles + validates it. See `docs/contracts/workflow-format.md`
for the format.

## How it works (prepare/execute)

`auto` is a **prepare/execute** engine, not a self-driving loop. Each tick
*prepares* an INTENT (what to do next); the *model* executes it (`/ce-plan`,
`/ce-work`, `/ce-code-review`, …) and feeds results back via the next tick. Don't
loop the tick blind — run the prepared invocation and report back. For an
already-reviewed plan, `--workflow w` skips the plan-loop so it doesn't re-derive
finished work.

## Concepts

`CONCEPTS.md` is the canonical vocabulary, and **the code now speaks it** — the
identifiers, filenames, JSON keys, CLI flags, and contracts were renamed to match
(there is no longer a doc/code vocabulary split to translate). The shape in one
line: **a workflow is an ordered set of steps; each step runs a preset.**

For reading older code, plans, and run-records, the **retired** identifiers map:
`recipe` → **workflow**, `unit` → **step**, `content` → **preset**, `adapter` →
**backend**, `orchestrator` → **dispatcher**, `emitter` → **producer**, `tick` →
**pulse**, `seam` → **handoff**, `ledger` → **run-record**.
Run-records and workflow files written before the rename **keep working** — old
keys are upgraded on read, indefinitely.

## Contracts

- `docs/contracts/workflow-format.md` — the workflow JSON format (LOCKED v0.5.0).
- `docs/contracts/run-record-schema.md` — the per-unit run-record (the source of truth).
- `docs/contracts/backend-contract.md` — the seven backend ops a workflow maps onto.

## Tests

`bash tests/run.sh all` — pure stdlib + bash, no install. (427 passing at v0.3.0.)
