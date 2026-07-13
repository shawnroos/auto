# auto — Concepts

The canonical vocabulary for `auto`. Plain names for the machinery — a fresh reader
should get each on sight, no metaphor.

**The code speaks this vocabulary.** These are not display names layered over
different internals: the filenames, symbols, JSON keys, CLI verbs, flags, phase
strings, commands, skills, and contracts all use the terms below. There is one
vocabulary to learn, not two.

---

## The vocabulary

| Concept | Term | One line |
|---|---|---|
| the ordered set of steps a run is built from | **workflow** | The named topology — an ordered graph of steps (`a1`/`plan-build-review`, …). |
| one node of work — the slot + its wiring | **step** | An addressable slot in a workflow (its phase + `depends_on`); runs one preset. |
| what a step runs — operation + tuning | **preset** | The named, reusable config a step runs: one operation (`review`/`do_step`) + its `prompt_template` tuning. Addressable independent of any workflow. |
| a stage of a run | **phase** | plan · handoff · work (and `brainstorm` on the creative spine). |
| the pluggable toolchain | **backend** | Maps auto's operations onto a concrete toolchain — CE (`/ce-*`) or native. |
| fan-out of work to agents | **dispatcher** | Decides batch size and hands steps to agents; never writes the record itself. |
| makes the next steps | **producer** | Materializes the following steps at a phase boundary or on iterate. |
| one advance of the loop | **pulse** | The engine is a *pulsed loop*; each pulse advances the run one beat. |
| the plan→work join | **handoff** | The pause/boundary where plan output becomes work steps (`handoff_paused`). |
| the iterate / advance / exit checkpoint | **gate** | Loop again, move on, or stop — bounded. |
| a step's result | **verdict** | Carries **findings** tagged `blocker` / `major` / `minor`. |
| a step's typed done-conditions | **verification** / **criteria** | programmatic · model-judge · advisor-judge · human. |
| the durable source of truth | **run-record** | Append-through state; the run's memory. Outlives any single agent. (Identifier form: `run_record`.) |
| the objective | **goal** | What a run drives to *done*. |
| the steering session | **driver** | The agent that steers a run — distinct from the *dispatcher*, which fans work out. |

## The shape in one line

> A **workflow** is an ordered set of **steps**; each step runs a **preset**.

Three levels, no word overloaded, no metaphor.

---

## Reading older code, plans, and run-records

Nine identifiers were retired when the code adopted this vocabulary. They survive in
plan documents written before the rename, in run-records and workflow files on disk,
and in anything you pulled from an older version. This table is how you read them —
it is **historical**, not a live alias list. Nothing in `lib/`, `skills/`,
`commands/`, or `docs/contracts/` spells the left column any more, and
`tests/unit/vocabulary-audit.test.sh` fails the build if it starts to.

| retired identifier | current term | where you still meet it | <!--legacy--> |
|---|---|---|---|
| `recipe` | **workflow** | `recipes/` dirs, `--recipe`, `default_adapter`-era files | <!--legacy--> |
| `unit` (U-IDs) | **step** | the `units` array of an old run-record; `add-unit`-era CLI transcripts | <!--legacy--> |
| `content` | **preset** | pre-rename branches only (never shipped a persisted key) | <!--legacy--> |
| `adapter` | **backend** | the `adapter` / `adapter_op` keys; `--adapter` | <!--legacy--> |
| `orchestrator` | **dispatcher** | `lib/orchestrator.sh` (stub); no persisted key ever existed | <!--legacy--> |
| `emitter` | **producer** | `phase_transitions[].emitter` | <!--legacy--> |
| `tick` | **pulse** | `/auto:auto-tick` in an in-flight rearm prompt; `lib/tick.sh` | <!--legacy--> |
| `seam` | **handoff** | the `"seam"` phase value and `seam_paused` | <!--legacy--> |
| `ledger` | **run-record** | `lib/ledger.py` (shim); the term throughout older plans | <!--legacy--> |

### The read-compat guarantee

**Files you already have keep working, indefinitely.** `lib/format_compat.py` maps the
retired on-disk keys and values to the current ones **in memory on every read** — it is
never version-gated and never skipped:

- **Run-records** (`.claude/auto/<run>.json`) written by pre-rename code load, resume,
  and complete unchanged. They migrate to the current shape lazily, on their first
  write, because every mutation funnels through one atomic-write path. No migration
  command, no bulk rewrite, nothing to run.
- **Workflow files** you authored resolve and validate unchanged — both in
  `.claude/auto/workflows/` and in the pre-rename directories the table above names,
  which stay readable as legacy tiers. auto never rewrites a file you wrote, so this
  acceptance has **no end date**. `python3 lib/workflows.py migrate <path>` modernizes
  one in place if you want it to — entirely optional.

The retired *code* surfaces (the forwarding stubs, the deprecated flag spellings, the
old command alias) are a different, **temporary** thing: they are deprecated and
scheduled for removal. [`docs/deprecations.md`](docs/deprecations.md) is the single
list — every one of them, what removing it would break, and the ones that can never be
removed.

---

## Deliberate carve-outs

Terms the rename left alone, on purpose:

- **`plan_step` / `PLAN_STEPS` / `next_plan_step`** — the plan phase's internal
  sub-state (`plan` → `deepen` → `review_plan`). It collides with the **step** term
  and is *not* a workflow step. Documented rather than renamed away: renaming it would
  invent vocabulary this rename had no mandate for. If the collision proves confusing
  in practice, it gets its own pass and its own entry here first.
- **`emit_*`** (`emit_templates`, `iteration_emit_count`, `expected_emit_outputs`) —
  the *producer* emits; "emit" is the verb, and was never itself a retired term.
- **The `a1` / `a2` / `a4` / `w` stems** and their legible aliases
  (`plan-build-review`, `parallel-theories`, `adversarial-pair`, `work-only`).
- **`.claude/auto/`** — keyed to the plugin name, not to any renamed concept.

## Deferred

A higher-level framing for multi-run structure, and a native **lore** runtime
(compounding best-practice + in-process worker self-heal, not delegated to a 3rd-party
solutions store), are a separate direction — captured for `/spinoff`, not part of this
vocabulary.
