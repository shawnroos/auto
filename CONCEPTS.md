# auto — Concepts

The canonical vocabulary for `auto`. Plain names for the machinery — a fresh reader
should get each on sight, no metaphor. This file is the source of truth for what each
concept is called; prose and skills should use these terms.

Where a term differs from the historical code identifier, the old name is shown so the
mapping is unambiguous. Public term is canonical; code keeps its identifier.

---

## The vocabulary

| Concept | Term | (code / was) | One line |
|---|---|---|---|
| the ordered set of steps a run is built from | **workflow** | `recipe` | The named topology — an ordered graph of steps (`a1`/`plan-build-review`, …). |
| one node of work — the slot + its wiring | **step** | `unit` (U-IDs) | An addressable slot in a workflow (its phase + `depends_on`); runs one preset. |
| what a step runs — operation + tuning | **preset** | `content` | The named, reusable config a step runs: one operation (`review`/`do_unit`) + its `prompt_template` tuning. Addressable independent of any workflow. |
| a stage of a run | **phase** | `phase` | plan · handoff · work (and `brainstorm` on the creative spine). |
| the pluggable toolchain | **backend** | `adapter` | Maps auto's operations onto a concrete workflow — CE (`/ce-*`) or native. |
| fan-out of work to agents | **dispatcher** | `orchestrator` | Decides batch size and hands steps to agents; never writes the record itself. |
| makes the next steps | **producer** | `emitter` | Materializes the following steps at a phase boundary or on iterate. |
| one advance of the loop | **pulse** | `tick` | The engine is a *pulsed loop*; each pulse advances the run one beat. |
| the plan→work join | **handoff** | `seam` | The pause/boundary where plan output becomes work steps (`seam_paused`). |
| the iterate / advance / exit checkpoint | **gate** | `gate` | Loop again, move on, or stop — bounded. |
| a step's result | **verdict** | `verdict` | Carries **findings** tagged `blocker` / `major` / `minor`. |
| a step's typed done-conditions | **verification** / **criteria** | `verification` | programmatic · model-judge · advisor-judge · human. |
| the durable source of truth | **run-record** | `ledger` | Append-through state; the run's memory. Outlives any single agent. |
| the objective | **goal** | `goal` | What a run drives to *done*. |
| the steering session | **driver** | `driver` | The agent that steers a run — distinct from the *dispatcher*, which fans work out. |

## The shape in one line

> A **workflow** is an ordered set of **steps**; each step runs a **preset**.

Three levels, no word overloaded, no metaphor.

---

## Depth policy

These are the canonical **public terms**. Load-bearing code identifiers and JSON keys
(`ledger`, `recipe`, `unit`, `tick`, `adapter`) stay as-is — referenced in the
thousands and pinned by locked contracts — and are mapped here. Full code renames
happen only when deliberately chosen, not swept:

- **`content → preset`** — queued for the addressable-step-contents code (rename the
  freshly-added surface: `contents.py`, `content_oneshot.py`, `content-format.md`, the
  `auto-content` skill, the `content-*` tests). Lands with the naming-adoption branch,
  after PR #11 merges, so doc and code agree.
- **`orchestrator → dispatcher`** — the one cheap, unlocked full rename (273 refs).
- **`recipe` / `ledger` / `unit` / `tick` / `adapter`** — stay code identifiers;
  adopt the public term in prose over time, mapped here.

## Deferred

A higher-level framing for multi-run structure, and a native **lore** runtime
(compounding best-practice + in-process worker self-heal, not delegated to a 3rd-party
solutions store), are a separate direction — captured for `/spinoff`, not part of this
vocabulary.
