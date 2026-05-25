# Recipe Format (LOCKED — v0.2.0 day-zero contract)

> **Status: LOCKED v0.2.0 contract.** This is the source-of-truth spec for the
> `auto` **recipe format** — the named, file-backed JSON declaration of a workflow
> topology that `/auto` builds a run from. The validator (`lib/recipes.py::validate`)
> enforces it mechanically; the picker (`commands/auto.md`), the authoring skill
> (`skills/auto-author-recipe/`), and the engine loader all consume it. Do not
> change the field set, the validation rules, or the V1 acceptance boundary without
> re-locking with those consumers.
>
> **Reading test:** a recipe author (human or the authoring skill) should be able
> to write a valid recipe from THIS file alone. If `validate` rejects something
> this doc says is valid (or vice versa), that is a contract bug — fix the
> disagreement, don't paper over it.

---

## 1. What a recipe is

A recipe declares the **initial ledger topology** of an `auto` run: the units,
their `depends_on` graph, the phase each runs in, the phase ordering, and which
emitter produces work units at a phase boundary. The engine reads the recipe at
`init_ledger` time and builds the run from it; everything downstream (tick,
dispatch, predicate, resume) is recipe-blind once the ledger exists.

Recipes resolve from a three-tier registry (first-wins): **workspace**
(`<repo>/.claude/auto/recipes/<name>.json`) → **global**
(`~/.claude/auto/recipes/<name>.json`) → **built-in** (`<plugin>/recipes/<name>.json`).

## 2. Top-level fields

| field | req | type | meaning |
|-------|-----|------|---------|
| `name` | yes | string | recipe id, non-empty. Matches the filename stem. |
| `version` | yes | string | format version (currently `"1"`). |
| `units` | yes | array | the declared units (§3). v0.2.0: MUST be non-empty for work-only (`phase_order: ["work"]`) recipes — init-time enumeration from `enumerate_plan_units` ships in v0.2.1 (KTD-15). |
| `description` | no | string | one-line summary; shown in the picker + rendered card. |
| `default_adapter` | no | `"ce"`\|`"native"` | the adapter to use when `--adapter` is not passed. |
| `phase_order` | no | array | the run's phase sequence. **V1 accepts ONLY `["plan","seam","work"]` (default) or `["work"]` (work-only).** Any other non-default value is REJECTED until v0.2.1 (A3's multi-phase grammar). |
| `terminal_phase` | no | string | the phase whose completion ends the run. Default `"work"`. MUST be a member of `phase_order`. |
| `phase_transitions` | no | array | emitter declarations (§4). |
| `python_hook` | no | (reserved) | RESERVED — parses but the V1 engine ignores it. The ONLY unknown-ish key tolerated; every OTHER unknown top-level field is rejected. |

## 3. `units[]` entries

| field | req | type | meaning |
|-------|-----|------|---------|
| `id` | yes | string | unique within the recipe, non-empty. |
| `phase` | yes | string | MUST be a member of `phase_order`. |
| `depends_on` | no | string[] | unit ids this unit waits for. Each MUST reference an existing unit id. |
| `invokes` | no | object | what the unit invokes — `adapter_op` (one of the locked ops) plus optional recipe-side metadata like `prompt_template`. Merged into the ledger unit's `dispatch_context` at load (after path-bounding). |

**`prompt_template` path-bounding (security):** if present, it MUST be a relative
path with no `..` segments and no leading `/`. A traversal or absolute value is
rejected — workspace recipes ship in committed code, so an unbounded path could
exfiltrate files into LLM context.

## 4. `phase_transitions[]` — emitters

Each entry declares which **emitter** fires at a phase boundary:

```json
{"from": "<phase>", "to": "<phase>", "emitter": "<name>"}
```

- `from` / `to` MUST be members of `phase_order`.
- `emitter` MUST be one of the **V1-registered names** (the validator rejects any
  other — a recipe can't name a v0.3.0 emitter that doesn't exist):
  - `plan_output_to_work_units` — one plan's output → work units (A1).
  - `judge_winner_to_work_units` — the winning plan's output, after a judge (A2).
  - `plan_output_to_paired_builders` — two bias-differentiated builders + a
    comparator (A4).
- The emitter fires when the run ARRIVES at its `to` phase (keyed on `to`), so a
  `{from: plan, to: work}` emitter fires entering `work` even though the run
  routes through `seam`.

## 5. The four built-in recipes (the conformance corpus)

- **a1** — Classic CE Stack. One plan unit; `plan_output_to_work_units` at
  plan→work. The v0.1.x-equivalent default. Also a Python constant
  (`A1_BUILTIN`) so a corrupt built-in JSON can't break bare `/auto`.
- **a2** — Parallel Theories + Judge. Three plan units + a judge work unit
  (`depends_on` all three); `judge_winner_to_work_units`.
- **a4** — Adversarial Pair + Comparator. One plan unit;
  `plan_output_to_paired_builders`.
- **w** — Work-only. `phase_order: ["work"]`, no emitter; units must be
  pre-declared in v0.2.0 (the shipped `recipes/w.json` carries a single stub
  unit). For an already-reviewed plan (skip the plan-loop). **v0.2.1 (KTD-15)**
  adds init-time enumeration so the adapter's `enumerate_plan_units` op can
  load work units from an operator-supplied plan at `init_ledger` time; until
  then, a work-only recipe with `units: []` is REJECTED by `validate()` (it
  would create a zero-unit ledger that re-arms forever).

## 6. V1 acceptance boundary (deferred to v0.2.1)

The validator REJECTS, in V1: non-default `phase_order` other than work-only
(A3's `["work_sketch","review","plan","work_refine"]`); unregistered emitter
names; a loaded `python_hook`; AND a work-only recipe (`phase_order: ["work"]`)
with an empty `units` list (the init-time enumeration path ships in v0.2.1 —
KTD-15). These ship in v0.2.1 with A3, the recipe-declared-emitter feature, and
W's init-time enumeration. The rejection is mechanical (a tested code path), so
no untested topology can ship.

## 7. Cross-references

- `lib/recipes.py` — the validator + registry (`validate`, `validate_and_lint`,
  `resolve`, `list_available`, `load_and_validate`, `unit_for`).
- `lib/emitters.py` — the emitter registry (`V1_EMITTER_NAMES` mirrors `validate`'s).
- `docs/contracts/ledger-schema.md` — the ledger fields a recipe populates.
- `docs/contracts/adapter-contract.md` — the ops a unit's `invokes` references
  (incl. the v0.2.0 `enumerate_plan_units` re-lock).
