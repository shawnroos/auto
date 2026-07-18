# auto

A toolchain-agnostic **pulsed loop engine** for Claude Code. `auto` runs the loop
pattern you run by hand — plan → build → review → fix until only the small stuff
remains — as a durable, observable state machine. A disk-persisted per-step
run-record is the source of truth, so a run survives rate limits and session exits;
resume is one command off the run-record.

The engine is **workflow-blind**: it drives any toolchain through a thin backend
(Compound Engineering's `/ce-*` commands, native Claude, or your own).

## Commands

- **`/auto [<plan>]`** — start (or, bare, *gather context and pick up*: resume an
  in-flight run, offer to build a reviewed plan, or recommend `/ce-plan` for raw
  work). Pick a workflow at start, or pass `--workflow <name>` to skip the picker.
- **`/auto-status [<run>]`** — read-only run-record + health of a run.
- **`/auto-resume [continue|advance|pause|abort|retry|skip] [<run>] [<step>]`** — the
  durable recovery / continuation path.
- **`/auto-author-workflow`** — author a new workflow from a plain-language
  description (you never write JSON).
- **`/auto-preset <name> <target>`** — run one **preset** (a named, reusable
  step payload — a tuned review, a scoped build) one-shot against a target: no
  flow, no loop. The agent proposes a context-fit check you accept or edit, runs
  it once, and returns a `pass` / `fail` / `unverified` verdict.

## Workflows

A **workflow** is a named loop topology — an ordered graph of steps. Fire `/auto <plan>`
and a picker lets you choose; or `--workflow <name>` to pick directly. Six ship
built-in:

| workflow | shape |
|--------|-------|
| **a1** — Classic CE Stack | plan → build → review → fix to P3-only exit (the default) |
| **a2** — Parallel Theories + Judge | N competing plans in parallel → a judge picks the winner → build it |
| **a4** — Adversarial Pair + Comparator | two builders, same plan, different biases → a comparator picks/merges |
| **w** — Work-only | you already have a reviewed plan — skip the plan-loop, build its steps directly |
| **pipeline** — Creative spine | brainstorm-rooted: brainstorm → plan → build → review |
| **review** — Review-only | code is written but unreviewed — run the review/fix loop over it |

**Outcomes-gated emission.** A workflow can declare an optional `iteration` block so a
designated gate step's verdict (advance / iterate / exit) drives the loop directly —
a2's judge can re-spawn another round of competing plans, a4's comparator can re-engage
its builders, all under an engine-enforced `max_attempts` + `max_wall_seconds` bound.
See `docs/contracts/workflow-format.md` §6.

### Your own workflows

Workflows resolve from three tiers, first-wins: **workspace**
(`<repo>/.claude/auto/workflows/`) → **global** (`~/.claude/auto/workflows/`) →
**built-in**. Author one with `/auto-author-workflow` — describe the workflow
(what runs in parallel, where a judge gates, whether the plan's already written)
and the skill compiles + validates it. See `docs/contracts/workflow-format.md`
for the format.

## How it works (prepare/execute)

`auto` is a **prepare/execute** engine, not a self-driving loop. Each pulse
*prepares* an INTENT (what to do next); the *model* executes it (`/ce-plan`,
`/ce-work`, `/ce-code-review`, …) and feeds results back on the next pulse. Don't
loop the pulse blind — run the prepared invocation and report back. For an
already-reviewed plan, `--workflow w` skips the plan-loop so it doesn't re-derive
finished work.

## Concepts

`CONCEPTS.md` is the canonical vocabulary, and **the code speaks it** — the
identifiers, filenames, JSON keys, CLI flags, and contracts all use these terms, so
there is no doc/code split to translate. The shape in one line: **a workflow is an
ordered set of steps; each step runs a preset.**

Nine identifiers were retired to get there. To read older code, plans, and
run-records:

| retired identifier | current term | <!--legacy--> |
|---|---|---|
| `recipe` | **workflow** | <!--legacy--> |
| `unit` | **step** | <!--legacy--> |
| `content` | **preset** | <!--legacy--> |
| `adapter` | **backend** | <!--legacy--> |
| `orchestrator` | **dispatcher** | <!--legacy--> |
| `emitter` | **producer** | <!--legacy--> |
| `tick` | **pulse** | <!--legacy--> |
| `seam` | **handoff** | <!--legacy--> |
| `ledger` | **run-record** | <!--legacy--> |

Run-records and workflow files written before the rename **keep working** — the old
keys are upgraded on read, indefinitely, and auto never rewrites a file you authored.
The deprecated *code* surfaces kept for one version (forwarding stubs, flag aliases,
the old command alias) are listed in `docs/deprecations.md`.

## Contracts

The load-bearing ones (`docs/contracts/` has the rest):

- `workflow-format.md` — the workflow JSON format (LOCKED v0.5.0).
- `run-record-schema.md` — the per-step run-record, the source of truth (LOCKED v0.3.0).
- `backend-contract.md` — the backend ops a workflow maps onto (LOCKED v0.15.0).
- `verification-contract.md` — the typed verification gates (LOCKED v0.7.0).
- `agent-tool-surface.md` — the CLI verbs a driving agent may call.
- `preset-format.md` — the preset format (PROVISIONAL).

## Tests

`bash tests/run.sh all` — pure stdlib + bash, no install.
