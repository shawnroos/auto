# Recipe Format (LOCKED — v0.3.0 contract)

> **Status: LOCKED v0.3.0 contract.** This is the source-of-truth spec for the
> `auto` **recipe format** — the named, file-backed JSON declaration of a workflow
> topology that `/auto` builds a run from. The validator (`lib/recipes.py::validate`)
> enforces it mechanically; the picker (`commands/auto.md`), the authoring skill
> (`skills/auto-author-recipe/`), and the engine loader all consume it. Do not
> change the field set, the validation rules, or the V1 acceptance boundary without
> re-locking with those consumers.
>
> **v0.3.0 additions** (purely additive over v0.2.0 — see §6 for the iteration
> block, §7 for `emit_templates`): the optional `iteration` and `emit_templates`
> top-level fields let a recipe declare an **outcomes-gated** workflow where a
> designated gate unit's `verdict.decision` (advance / iterate / exit) drives
> whether the loop advances to the terminal phase, emits another round of work
> within the same phase, or stops with an audit trail. A recipe that declares
> neither validates exactly as a v0.2.0 recipe (R7 backward compatibility).
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
| `iteration` | no | object | **(v0.3.0, additive)** the outcomes-gated iteration block (§6). Declares the gate unit, the optional emit-template name to re-emit from on `iterate`, and the engine-enforced bound (`max_attempts` + optional `max_wall_seconds`). Absent on v0.2.x recipes — they validate unchanged. |
| `emit_templates` | no | object | **(v0.3.0, additive)** map of `<template_name> → {phase, invokes, id_prefix}` consumed by the `iterate_template` emitter at iteration time (§7). MUST be present (and contain the named template) when `iteration.emit_template` is set; MAY be absent when `iteration` is absent or when `iteration.emit_template` is omitted (the "re-engage the gate without spawning new siblings" shape, round-3 P2 #21). |
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
  other — a recipe can't name a non-existent emitter):
  - `plan_output_to_work_units` — one plan's output → work units (A1).
  - `judge_winner_to_work_units` — the winning plan's output, after a judge (A2).
  - `plan_output_to_paired_builders` — two bias-differentiated builders + a
    comparator (A4).
- The emitter fires when the run ARRIVES at its `to` phase (keyed on `to`), so a
  `{from: plan, to: work}` emitter fires entering `work` even though the run
  routes through `seam`.

> **Note.** `iterate_template` is also registered in `lib/emitters.py::REGISTRY`
> but is a **within-phase** emitter — it never appears in `phase_transitions[]`.
> The engine calls it directly through `ledger.emit_within_phase` when the gate
> unit verdicts `iterate` under bound (§6). It is not a recipe-selectable
> phase-boundary emitter.

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

## 6. `iteration` — outcomes-gated emission (v0.3.0+)

A recipe MAY declare an `iteration` block to make the loop **outcomes-gated**:
a designated **gate unit**'s `verdict.decision` drives whether the run advances
to its terminal phase (`advance`), emits another round of units within the
gate's current phase and re-engages the gate (`iterate`), or stops with an
audit trail (`exit`). An engine-enforced **bound** caps runaway iteration so a
misbehaving gate agent cannot loop forever (deterministic over probabilistic
— the bound lives in the engine, not in the gate agent's disposition).

```
iteration:
  gate_unit: "<unit_id>"        # required — references a unit declared in
                                #   units[]  OR  an emit_templates[].id_prefix
                                #   (forward-looking carve-out per round-3 P2
                                #   #21; for V1 the unit-id form is the canonical
                                #   path — see §5's built-in shapes).
  emit_template: "<name>"       # optional — when set, MUST name an entry in the
                                #   top-level `emit_templates` map (§7). Omit it
                                #   for the "re-engage the gate without spawning
                                #   siblings" shape (e.g. a comparator that
                                #   re-compares the same builders after a
                                #   clarifying signal). When set, the
                                #   `iterate_template` within-phase emitter
                                #   reads this template at iteration time.
  bound:                        # required when `iteration` is declared
    max_attempts: <positive int>      # required — cap on HONORED iterate
                                      #   decisions (the Nth attempt is
                                      #   bound-checked PRE-increment, so the
                                      #   engine overrides iterate→exit when
                                      #   `iteration_attempts == max_attempts`
                                      #   on entry). MUST be a positive int;
                                      #   bool values are rejected.
    max_wall_seconds: <positive int>  # optional — cap on cumulative active
                                      #   wall-time (`active_wall_seconds`,
                                      #   §2 of ledger-schema.md). Pauses
                                      #   between ticks don't burn budget; the
                                      #   accumulator only grows during a tick's
                                      #   `_tick_body`. Omit for unbounded.
```

**Decision enum** (`lib/iteration.py::DECISIONS`):

- `advance` — gate is satisfied; the engine advances to the terminal phase via
  the normal flow. The predicate-met short-circuit fires as it would have without
  iteration.
- `iterate` (under bound) — engine calls `ledger.atomic_iterate_step` in ONE
  locked body: increments `iteration_attempts`, emits new units via the
  `iterate_template` emitter (using `emit_template` when declared) into the
  gate's current phase, then resets the gate unit (`verdict-returned → pending`,
  `depends_on` extended with the new sibling ids, `dispatch_context.decision`
  cleared so the next tick reads a fresh verdict).
- `iterate` (over bound) **or** `exit` — engine writes
  `dispatch_context.bound_override = { bound, original_decision, at: <iso> }`
  on the gate unit (audit trail) and flips the loop directly to `done`
  / `driver = "manual"` via `set_loop`. The phase transition is NOT routed
  through the normal seam-handler — that would re-invoke
  `judge_winner_to_work_units`, which raises on a missing `winner_unit_id` when
  the gate said iterate rather than advance.

**Bound semantics.** Both bounds are checked against `iteration.evaluate_decision`'s
view of the ledger BEFORE honoring an iterate. `max_attempts` is checked against
`iteration_attempts` pre-increment; `max_wall_seconds` is checked against
`active_wall_seconds` (cumulative tick-active time accumulated from
`_tick_body`'s `finally` clause so a crashed tick still contributes its delta).
A bound breach is recorded as a decision override, NOT an error — the engine
proceeds as if the gate said `exit` and surfaces the override on `/auto-status`
(R9 surface). See `docs/contracts/ledger-schema.md` §2.1 + §2.3 for the
`active_wall_seconds`, `last_active_at`, `iteration_attempts`,
`iteration_emit_count` ledger fields and the `dispatch_context.decision` /
`dispatch_context.bound_override` sub-fields the engine writes.

**Decision writes.** The gate unit's verdict-time decision is persisted via
`ledger.set_verdict_decision(repo, run, gate_unit_id, decision, payload=None)` —
NOT through `findings[]` (which `record_verdict` normalizes to `{severity, note}`
only and would strip the decision). All reads route through
`lib/iteration.py::read_decision`; the AST lint in
`tests/unit/iteration-ast-lint.test.sh` forbids the literal `"decision"` as an
`ast.Constant` outside `lib/iteration.py` + `lib/ledger.py`. A new consumer cannot
re-introduce a divergent literal access without tripping the lint (the institutional
mitigation for the "plan documents a behavior the code never wires" build-bug
class).

## 7. `emit_templates` — within-phase emit definitions (v0.3.0+)

Each entry in the top-level `emit_templates` map declares the partial unit
shape `iterate_template` materializes when the gate verdicts `iterate`:

```
emit_templates:
  <template_name>:
    id_prefix: "<string>"   # required — non-empty. The Nth emitted unit
                            #   across the WHOLE run gets id
                            #   `id_prefix + (iteration_emit_count + N)`
                            #   (`iteration_emit_count` is the monotonic
                            #   ledger counter; `iterate_template` NEVER
                            #   recounts existing units — see
                            #   `lib/emitters.py::iterate_template`).
    phase: "<loop_phase>"   # required — MUST be a member of `phase_order`.
                            #   The phase the new sibling units land in.
    invokes:                # required — object, same depth/shape as
                            #   `units[].invokes` (§3). `prompt_template`
                            #   is path-bounded identically.
      adapter_op: "..."
      prompt_template: "<relative path>"
```

The `iteration.emit_template` field's value MUST name a key in this map; the
validator rejects any mismatch. The emitter NAME is implicit — `iterate_template`
is the within-phase emitter the engine calls; recipes do not choose it.

`emit_count` (the number of siblings emitted per iterate step) is read from the
gate unit's `dispatch_context.decision_payload.emit_count` at iteration time,
defaulting to `1`. The emitter validates `1 ≤ emit_count ≤ 10` (round-3 P1-R3-4
upper bound prevents a misbehaving gate from DOS-emitting a thousand units in
one tick).

## 8. V1 acceptance boundary (deferred to v0.2.1)

The validator REJECTS, in V1: non-default `phase_order` other than work-only
(A3's `["work_sketch","review","plan","work_refine"]`); unregistered emitter
names; a loaded `python_hook`; AND a work-only recipe (`phase_order: ["work"]`)
with an empty `units` list (the init-time enumeration path ships in v0.2.1 —
KTD-15). These ship in v0.2.1 with A3, the recipe-declared-emitter feature, and
W's init-time enumeration. The rejection is mechanical (a tested code path), so
no untested topology can ship.

## 9. Cross-references

- `lib/recipes.py` — the validator + registry (`validate`, `validate_and_lint`,
  `resolve`, `list_available`, `load_and_validate`, `unit_for`).
- `lib/emitters.py` — the emitter registry (`V1_EMITTER_NAMES` mirrors `validate`'s
  phase-boundary emitters; `iterate_template` is registered but within-phase only).
- `lib/iteration.py` — the ONE iteration-decision module (`DECISIONS`,
  `read_decision`, `evaluate_decision`); AST-lint-enforced single source of truth.
- `docs/contracts/ledger-schema.md` — the ledger fields a recipe populates
  (including the v0.3.0 iteration fields + `dispatch_context.decision` /
  `bound_override` sub-keys).
- `docs/contracts/adapter-contract.md` — the ops a unit's `invokes` references.
  **Unchanged for v0.3.0** — the iteration primitive lives entirely on the
  engine side; no new adapter ops are introduced.
