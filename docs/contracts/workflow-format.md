# Workflow Format (LOCKED — v0.5.0 contract)

> **Status: LOCKED v0.5.0 — vocabulary rename; supersedes `recipe-format.md`
> v0.4.0.** (KTD-5 re-lock. The normative key table was already cut over to v2 in
> U6 — this bump is the rename half: the file, the module names it pins, and every
> identifier in its prose. NO normative content change beyond the spelling; a
> workflow file that validated against the superseded contract validates against
> this one byte-for-byte.)
>
> **Changelog — v0.5.0 (concept-vocabulary rename, U8 — file rename + re-lock):**
> the topology term is now `workflow` as an IDENTIFIER, not just as a word — this
> file, the modules it pins (`lib/workflows.py`, `lib/workflow_validate.py`), the
> built-in directory (`workflows/`), the workspace/global tier directories, the
> `WorkflowError` exception, the `--workflow` flag, and the authoring skill
> (`skills/auto-author-workflow/`). **Two compat surfaces, both indefinite:** the
> pre-rename tier directories stay readable as legacy tiers (**§1**), and the
> pre-rename flag spelling is accepted for one more minor as a deprecated alias.
> The full retired-name map is the read-compat **Appendix**.
>
> **Changelog — v0.4.0 (concept-vocabulary rename, U6 — content re-lock):** EVERY
> persisted key and value in this format flipped ON DISK to format v2 — the step
> list (and its `$defs` entry), the default-backend field, the `invokes` op key and
> its op values, the producer key and its name values, the iteration gate, and the
> handoff phase value. **The full old→new map is the "Legacy keys (read-compat)"
> appendix at the end of this file** — it is normative. NO field-set or
> validation-rule change beyond the spelling. **v1-keyed workflow files on disk keep
> working, indefinitely.**
>
> This is the source-of-truth spec for the
> `auto` **workflow format** — the named, file-backed JSON declaration of a loop
> topology that `/auto` builds a run from. The validator (`lib/workflows.py::validate`)
> enforces it mechanically; the picker (`commands/auto.md`), the authoring skill
> (`skills/auto-author-workflow/`), and the engine loader all consume it. Do not
> change the field set, the validation rules, or the V1 acceptance boundary without
> re-locking with those consumers.
>
> **v0.3.0 additions** (purely additive over v0.2.0 — see §6 for the iteration
> block, §7 for `emit_templates`): the optional `iteration` and `emit_templates`
> top-level fields let a workflow declare an **outcomes-gated** loop where a
> designated gate step's `verdict.decision` (advance / iterate / exit) drives
> whether the loop advances to the terminal phase, emits another round of work
> within the same phase, or stops with an audit trail. A workflow that declares
> neither validates exactly as a v0.2.0 workflow (R7 backward compatibility).
>
> **v0.7.0 additions** (purely additive — see §11 for the typed `verification`
> block): a `steps[]` entry MAY carry an optional `verification` array — typed,
> checkable done-conditions (programmatic / model_judge / advisor_judge / human)
> layered onto the existing gate decision. A step that omits it validates exactly
> as before.
>
> **Reading test:** a workflow author (human or the authoring skill) should be able
> to write a valid workflow from THIS file alone. If `validate` rejects something
> this doc says is valid (or vice versa), that is a contract bug — fix the
> disagreement, don't paper over it.

---

## 1. What a workflow is

A workflow declares the **initial run-record topology** of an `auto` run: the steps,
their `depends_on` graph, the phase each runs in, the phase ordering, and which
producer produces work steps at a phase boundary. The engine reads the workflow at
`init_run_record` time and builds the run from it; everything downstream (pulse,
dispatch, predicate, resume) is workflow-blind once the run-record exists.

Workflows resolve from a three-tier registry (first-wins): **workspace**
(`<repo>/.claude/auto/workflows/<name>.json`) → **global**
(`~/.claude/auto/workflows/<name>.json`) → **built-in** (`<plugin>/workflows/<name>.json`).

**Legacy tier dirs (v0.5.0, KTD-7 — normative).** The vocabulary rename also
renamed the two user-writable tier directories, and real user files still live
under the old name. Each user-writable tier is therefore probed at its **new**
directory first and then at its **legacy** directory, giving five directories.
**Resolution order is top to bottom:**

| directory | tier | |
|---|---|---|
| `<repo>/.claude/auto/workflows/` | workspace | |
| `<repo>/.claude/auto/recipes/` | workspace | legacy — read-only <!--legacy--> |
| `~/.claude/auto/workflows/` | global | |
| `~/.claude/auto/recipes/` | global | legacy — read-only <!--legacy--> |
| `<plugin>/workflows/` | built-in | ships with the plugin |

First-wins is unchanged: the new directory shadows the legacy one at the same
tier, and any workspace file still shadows every global one. A legacy file reports
the tier NAME of its modern sibling (`workspace` / `global`) — the tier badge is a
**precedence** fact, not a statement about which directory the bytes came from.
The legacy directories are **read-only**: `/auto` never writes to them, and the
run-scoped-variant write path (§5) targets the new directory only. They compose
with the v1 key shim (Appendix), so a **pre-rename file in a pre-rename
directory** — the actual state of an upgrading user's disk — resolves, validates,
and arms a run untouched. Support is indefinite; the legacy directories are
removed only with a breaking release.

## 2. Top-level fields

| field | req | type | meaning |
|-------|-----|------|---------|
| `name` | yes | string | workflow id, non-empty. Matches the filename stem. |
| `version` | yes | string | format version (currently `"1"`). |
| `steps` | yes | array | the declared steps (§3). v0.2.0: MUST be non-empty for work-only (`phase_order: ["work"]`) workflows — init-time enumeration from `enumerate_plan_steps` ships in v0.2.1 (KTD-15). |
| `description` | no | string | one-line summary; shown in the picker + rendered card. |
| `default_backend` | no | `"ce"`\|`"native"` | the backend to use when `--backend` is not passed. |
| `phase_order` | no | array | the run's phase sequence. **v0.6.0 (U6): validated STRUCTURALLY** — every element MUST be a non-empty string, and all phase-membership invariants (`terminal_phase`, every step/emit_template `phase`, every `phase_transitions` from/to ∈ `phase_order`) hold. The earlier literal allow-list (`["plan","handoff","work"]` or `["work"]` only) is gone, so arbitrary spines like `["brainstorm","plan","handoff","work"]` (the `pipeline` workflow) validate. |
| `terminal_phase` | no | string | the phase whose completion ends the run. Default `"work"`. MUST be a member of `phase_order`. |
| `phase_transitions` | no | array | producer declarations (§4). |
| `iteration` | no | object | **(v0.3.0, additive)** the outcomes-gated iteration block (§6). Declares the gate step, the optional emit-template name to re-emit from on `iterate`, and the engine-enforced bound (`max_attempts` + optional `max_wall_seconds`). Absent on v0.2.x workflows — they validate unchanged. |
| `emit_templates` | no | object | **(v0.3.0, additive)** map of `<template_name> → {phase, invokes, id_prefix}` consumed by the `iterate_template` producer at iteration time (§7). MUST be present (and contain the named template) when `iteration.emit_template` is set; MAY be absent when `iteration` is absent or when `iteration.emit_template` is omitted (the "re-engage the gate without spawning new siblings" shape, round-3 P2 #21). |
| `expected_emit_outputs` | no | string[] | **(v0.3.0, additive — F4)** explicit list of step ids the workflow declares will be materialized by a **phase-boundary producer** (e.g. `plan_output_to_paired_builders`'s `build-clarity` / `build-perf`). Used by the validator to accept `depends_on` references to ids that are NOT in `steps[]` and NOT iterate-shape (§8). Default `[]`. |
| `python_hook` | no | (reserved) | RESERVED — parses but the V1 engine ignores it. The ONLY unknown-ish key tolerated; every OTHER unknown top-level field is rejected. |

## 3. `steps[]` entries

| field | req | type | meaning |
|-------|-----|------|---------|
| `id` | yes | string | unique within the workflow, non-empty. |
| `phase` | yes | string | MUST be a member of `phase_order`. |
| `depends_on` | no | string[] | step ids this step waits for. Each member is accepted iff it satisfies AT LEAST ONE of: (a) references an existing id in `steps[]`; (b) matches an **iterate-shape** id `{id_prefix}{positive_int}` where `id_prefix` is declared by some `emit_templates[].id_prefix` (the `iterate_template` producer materializes these — see §7); (c) is explicitly declared in the top-level `expected_emit_outputs` list (a non-iterate phase-boundary producer materializes these — see §8). A `depends_on` member matching none of (a)/(b)/(c) is REJECTED. |
| `invokes` | no | object | what the step invokes — `backend_op` (one of the locked ops) plus optional workflow-side metadata like `prompt_template`. Merged into the run-record step's `dispatch_context` at load (after path-bounding). |
| `verification` | no | array | **(v0.7.0, additive — §11)** typed, checkable done-conditions (≤ 16 criteria) layered onto the gate decision. Each criterion is `{id, type, …type-fields}` with `type ∈ {programmatic, model_judge, advisor_judge, human}`. Absent on v0.2.x–v0.6.x workflows — they validate unchanged. |

**`prompt_template` path-bounding (security):** if present, it MUST be a relative
path with no `..` segments and no leading `/`. A traversal or absolute value is
rejected — workspace workflows ship in committed code, so an unbounded path could
exfiltrate files into LLM context.

## 4. `phase_transitions[]` — producers

Each entry declares which **producer** fires at a phase boundary:

```json
{"from": "<phase>", "to": "<phase>", "producer": "<name>"}
```

- `from` / `to` MUST be members of `phase_order`.
- `producer` MUST be one of the **V1-registered names** (the validator rejects any
  other — a workflow can't name a non-existent producer):
  - `plan_output_to_work_steps` — one plan's output → work steps (A1).
  - `judge_winner_to_work_steps` — the winning plan's output, after a judge (A2).
  - `plan_output_to_paired_builders` — two bias-differentiated builders + a
    comparator (A4).
- The producer fires when the run ARRIVES at its `to` phase (keyed on `to`), so a
  `{from: plan, to: work}` producer fires entering `work` even though the run
  routes through `handoff`.

> **Note.** `iterate_template` is also registered in `lib/step_producers.py::REGISTRY`
> but is a **within-phase** producer — it never appears in `phase_transitions[]`.
> The engine calls it directly through `run_record.emit_within_phase` when the gate
> step verdicts `iterate` under bound (§6). It is not a workflow-selectable
> phase-boundary producer.

## 5. The built-in workflows (the conformance corpus)

- **a1** — Classic CE Stack. One plan step; `plan_output_to_work_steps` at
  plan→work. The v0.1.x-equivalent default. Also a Python constant
  (`A1_BUILTIN`) so a corrupt built-in JSON can't break bare `/auto`.
- **a2** — Parallel Theories + Judge. Three plan steps + a judge work step
  (`depends_on` all three); `judge_winner_to_work_steps`.
- **a4** — Adversarial Pair + Comparator. One plan step;
  `plan_output_to_paired_builders`.
- **w** — Work-only. `phase_order: ["work"]`, no producer; steps must be
  pre-declared in v0.2.0 (the shipped `workflows/w.json` carries a single stub
  step). For an already-reviewed plan (skip the plan-loop). **v0.2.1 (KTD-15)**
  adds init-time enumeration so the backend's `enumerate_plan_steps` op can
  load work steps from an operator-supplied plan at `init_run_record` time; until
  then, a work-only workflow with `steps: []` is REJECTED by `validate()` (it
  would create a zero-step run-record that re-arms forever).
- **pipeline** — **(v0.6.0, U7)** Brainstorm-rooted creative spine.
  `phase_order: ["brainstorm","plan","handoff","work"]`, terminal `work`. One
  structural `brainstorm` step; `brainstorm_output_to_plan_step` at
  brainstorm→plan, then `plan_output_to_work_steps` at plan→work. The
  conversation-entry forward chain — brainstorm-entry runs auto-advance
  brainstorm→plan→work. Spine-only phase (`brainstorm`) is advanced via the
  direct-mutation `transition_and_emit` path, never `set_loop` (KTD-3).
- **review** — **(v0.6.0, U11)** Off-spine code-review-only entry.
  `phase_order: ["work"]`, terminal `work`; a single step invoking the `review`
  backend op (one review/fix loop to P3, then stop). Distinct from `w` (which
  invokes `do_step` to build): same single-phase shape, different op — no
  plan phase, no auto-advance, no rebound.

> **Launch run-scoped variants (v0.7.0).** The interactive launch chooser
> (`skills/auto-launch`, `driver-reference.md` §14) may compile a **run-scoped
> variant** when the operator edits a gated workflow's gates or composes a custom
> loop: it is a plain **workspace-tier** workflow (`<repo>/.claude/auto/workflows/`)
> carrying the typed `verification` array on its `iteration.gate_step` (§11), so
> the ordinary first-wins resolver and `validate()` apply to it unchanged — it is
> **not** a new built-in and not part of the conformance corpus above. Its only
> distinguishing trait is a **distinct stem `<builtin>-<run-slug>`** (e.g.
> `a2-fix-checkout`), which is the anti-shadow guard: a distinct name (not a
> description check) keeps `resolve("a2", repo)` returning the built-in unshadowed
> while the variant resolves at the workspace tier. Because the engine reads the
> workflow only at `init_run_record` time and is workflow-blind thereafter (§1), the
> variant is **torn down once the run's run-record is initialized** — nothing
> accumulates in the workspace tier across runs (the "inline compile-and-run"
> scope boundary; persistent saves stay with `auto-author-workflow`).

## 6. `iteration` — outcomes-gated emission (v0.3.0+)

A workflow MAY declare an `iteration` block to make the loop **outcomes-gated**:
a designated **gate step**'s `verdict.decision` drives whether the run advances
to its terminal phase (`advance`), emits another round of steps within the
gate's current phase and re-engages the gate (`iterate`), or stops with an
audit trail (`exit`). An engine-enforced **bound** caps runaway iteration so a
misbehaving gate agent cannot loop forever (deterministic over probabilistic
— the bound lives in the engine, not in the gate agent's disposition).

> **Carve-outs.** `iteration.gate_step` may reference an `emit_templates[].id_prefix`
> (documented inline in the block below). Separately, `depends_on` integrity has
> its own three-branch contract (steps[] / iterate-shape / `expected_emit_outputs`)
> — see §3 + §8.

```
iteration:
  gate_step: "<step_id>"        # required — references a step declared in
                                #   steps[]  OR  an emit_templates[].id_prefix
                                #   (forward-looking carve-out per round-3 P2
                                #   #21; for V1 the step-id form is the canonical
                                #   path — see §5's built-in shapes).
  emit_template: "<name>"       # optional — when set, MUST name an entry in the
                                #   top-level `emit_templates` map (§7). Omit it
                                #   for the "re-engage the gate without spawning
                                #   siblings" shape (e.g. a comparator that
                                #   re-compares the same builders after a
                                #   clarifying signal). When set, the
                                #   `iterate_template` within-phase producer
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
                                      #   §2 of run-record-schema.md). Pauses
                                      #   between pulses don't burn budget; the
                                      #   accumulator only grows during a pulse's
                                      #   `_pulse_body`. Omit for unbounded.
```

**Decision enum** (`lib/iteration.py::DECISIONS`):

- `advance` — gate is satisfied; the engine advances to the terminal phase via
  the normal flow. The predicate-met short-circuit fires as it would have without
  iteration.
- `iterate` (under bound) — engine calls `run_record.atomic_iterate_step` in ONE
  locked body: increments `iteration_attempts`, emits new steps via the
  `iterate_template` producer (using `emit_template` when declared) into the
  gate's current phase, then resets the gate step (`verdict-returned → pending`,
  `depends_on` extended with the new sibling ids, `dispatch_context.decision`
  cleared so the next pulse reads a fresh verdict).
- `iterate` (over bound) **or** `exit` — engine writes
  `dispatch_context.bound_override = { bound, original_decision, at: <iso> }`
  on the gate step (audit trail) and flips the loop directly to `done`
  / `driver = "manual"` via `set_loop`. The phase transition is NOT routed
  through the normal handoff-handler — that would re-invoke
  `judge_winner_to_work_steps`, which raises on a missing `winner_step_id` when
  the gate said iterate rather than advance.

**Bound semantics.** Both bounds are checked against `iteration.evaluate_decision`'s
view of the run-record BEFORE honoring an iterate. `max_attempts` is checked against
`iteration_attempts` pre-increment; `max_wall_seconds` is checked against
`active_wall_seconds` (cumulative pulse-active time accumulated from
`_pulse_body`'s `finally` clause so a crashed pulse still contributes its delta).
A bound breach is recorded as a decision override, NOT an error — the engine
proceeds as if the gate said `exit` and surfaces the override on `/auto-status`
(R9 surface). See `docs/contracts/run-record-schema.md` §2.1 + §2.3 for the
`active_wall_seconds`, `last_active_at`, `iteration_attempts`,
`iteration_emit_count` run-record fields and the `dispatch_context.decision` /
`dispatch_context.bound_override` sub-fields the engine writes.

**Decision writes.** The gate step's verdict-time decision is persisted via
`run_record.set_verdict_decision(repo, run, gate_step_id, decision, payload=None)` —
NOT through `findings[]` (which `record_verdict` normalizes to `{severity, note}`
only and would strip the decision). All reads route through
`lib/iteration.py::read_decision`; the AST lint in
`tests/unit/iteration-ast-lint.test.sh` forbids the literal `"decision"` as an
`ast.Constant` outside `lib/iteration.py` + `lib/run_record.py`. A new consumer cannot
re-introduce a divergent literal access without tripping the lint (the institutional
mitigation for the "plan documents a behavior the code never wires" build-bug
class).

## 7. `emit_templates` — within-phase emit definitions (v0.3.0+)

Each entry in the top-level `emit_templates` map declares the partial step
shape `iterate_template` materializes when the gate verdicts `iterate`:

```
emit_templates:
  <template_name>:
    id_prefix: "<string>"   # required — non-empty. The Nth emitted step
                            #   across the WHOLE run gets id
                            #   `id_prefix + (iteration_emit_count + N)`
                            #   (`iteration_emit_count` is the monotonic
                            #   run_record counter; `iterate_template` NEVER
                            #   recounts existing steps — see
                            #   `lib/step_producers.py::iterate_template`).
    phase: "<loop_phase>"   # required — MUST be a member of `phase_order`.
                            #   The phase the new sibling steps land in.
    invokes:                # required — object, same depth/shape as
                            #   `steps[].invokes` (§3). `prompt_template`
                            #   is path-bounded identically.
      backend_op: "..."
      prompt_template: "<relative path>"
```

The `iteration.emit_template` field's value MUST name a key in this map; the
validator rejects any mismatch. The producer NAME is implicit — `iterate_template`
is the within-phase producer the engine calls; workflows do not choose it.

`emit_count` (the number of siblings emitted per iterate step) is read from the
gate step's `dispatch_context.decision_payload.emit_count` at iteration time,
defaulting to `1`. The producer validates `1 ≤ emit_count ≤ 10` (round-3 P1-R3-4
upper bound prevents a misbehaving gate from DOS-emitting a thousand steps in
one pulse).

## 8. `expected_emit_outputs` — declared phase-boundary emit ids (v0.3.0+)

A workflow MAY declare a top-level `expected_emit_outputs: [<step-id-str>, ...]`
list. It names step ids the workflow asserts will be **materialized at run time
by a phase-boundary producer** (one of the `phase_transitions[]` producers listed
in §4 — `plan_output_to_work_steps`, `judge_winner_to_work_steps`, or
`plan_output_to_paired_builders`). The validator consults this list when
checking `depends_on` integrity (§3 row 3): a `depends_on` member that is NOT
in `steps[]` AND NOT iterate-shape (§7's `iterate_template` id math) is
accepted iff it is listed here.

```
expected_emit_outputs: ["<step_id>", "<step_id>", ...]    # optional; default []
```

**Why this exists.** Two producer classes produce work steps the workflow author
declares structurally:

- **`iterate_template`** (within-phase, §7) emits ids of the form
  `{id_prefix}{positive_int}` — the validator infers acceptance from the
  id-prefix-and-integer-suffix shape, no declaration needed.
- **Phase-boundary producers** (§4) emit **explicitly-named** ids. A4's
  `plan_output_to_paired_builders` produces `build-clarity` and `build-perf`;
  these are concrete strings without an iterate-shape suffix, so the validator
  cannot infer them from any id-prefix coincidence (F4 closed the prior loose
  prefix-match — `"build-typo"` no longer passes against id_prefix `"build-"`
  by accident). The workflow author declares the producer-output contract here.

**When to use.** Declare a member in `expected_emit_outputs` when a `steps[]`
step's `depends_on` names an id that:

1. is NOT in `steps[]` (no structural producer), AND
2. is NOT iterate-shape (i.e., NOT `{id_prefix}{positive_int}` for any
   `emit_templates[].id_prefix`), AND
3. WILL be produced at run time by a `phase_transitions[]` producer.

If none of those apply, you don't need this field. A4 is the only built-in
that uses it (see §5); a v0.2.x workflow never needed it because the prior
carve-out accepted any prefix-matching string — F4 tightened that to require
an explicit declaration, and A4 was updated atomically.

**Worked example — A4's `compare` step.** A4 declares a structural `compare`
step in `steps[]` whose `depends_on` names `build-clarity` and `build-perf`:

```json
{
  "steps": [
    {"id": "plan",    "phase": "plan", "invokes": {...}},
    {"id": "compare", "phase": "work",
     "depends_on": ["build-clarity", "build-perf"],
     "invokes": {"backend_op": "review", "prompt_template": "compare.md"}}
  ],
  "expected_emit_outputs": ["build-clarity", "build-perf"],
  "phase_transitions": [
    {"from": "plan", "to": "work", "producer": "plan_output_to_paired_builders"}
  ]
}
```

The `plan_output_to_paired_builders` producer (§4) fires at plan→work and
materializes the two builder steps; `compare` waits on both. Because neither
id is in `steps[]` and neither is iterate-shape, the workflow declares them in
`expected_emit_outputs` so `depends_on` integrity passes. (A4 also declares an
`iteration` block with an `iterate_template` named `bias-builder`; that's the
RE-EMIT path on `iterate` verdicts, distinct from the initial plan-output
emission — see §6 + §7.)

**Validator cross-reference.** `lib/workflows.py::validate`:

- shape check (~line 269-280): each entry must be a non-empty string; the
  field itself must be a list.
- integrity check (~line 300-311): `depends_on` accepts members iff (a) in
  `steps[]`, (b) iterate-shape per §7, OR (c) in `expected_emit_outputs`.

## 9. Acceptance boundary

The validator REJECTS: a `phase_order` with a non-string or empty element (the
v0.6.0/U6 structural rule); a `terminal_phase`, step `phase`, or
`phase_transitions` from/to not a member of `phase_order`; unregistered producer
names; a loaded `python_hook` (parsed but ignored); AND a work-only workflow
(`phase_order: ["work"]`) with an empty `steps` list (the init-time enumeration
path ships in v0.2.1 — KTD-15). **v0.6.0 (U6)** dropped the earlier literal
allow-list, so a structurally-sound multi-phase `phase_order` (e.g. the
`pipeline` spine) now validates. The rejection is mechanical (a tested code
path), so no malformed topology can ship.

## 10. Cross-references

- `lib/workflows.py` — the validator + registry (`validate`, `validate_and_lint`,
  `resolve`, `list_available`, `load_and_validate`, `step_for`).
- `lib/step_producers.py` — the producer registry (`V1_PRODUCER_NAMES` mirrors `validate`'s
  phase-boundary producers; `iterate_template` is registered but within-phase only).
- `lib/iteration.py` — the ONE iteration-decision module (`DECISIONS`,
  `read_decision`, `evaluate_decision`); AST-lint-enforced single source of truth.
- `docs/contracts/run-record-schema.md` — the run-record fields a workflow populates
  (including the v0.3.0 iteration fields + `dispatch_context.decision` /
  `bound_override` sub-keys).
- `docs/contracts/backend-contract.md` — the ops a step's `invokes` references.
  **Unchanged for v0.3.0** — the iteration primitive lives entirely on the
  engine side; no new backend ops are introduced.
- `skills/auto-design/references/verification-taxonomy.md` — the canonical shape
  of a typed `verification` criterion (§11); `workflows/schema.json` documents the
  same shape as a JSON Schema. `validate()` is the enforcer of both.

## 11. `verification` — typed gate criteria (v0.7.0+)

A `steps[]` entry MAY carry an optional `verification` array: typed, checkable
done-conditions layered onto the existing iterate/advance/exit gate decision
(KTD-1). It attaches to the gate step (the `iteration.gate_step` mechanism); it
is **not** a new producer and does **not** add topology grammar. It is also **not**
a second exit judge — the deterministic Stop predicate
(`blockers==0 ∧ majors==0 ∧ all_steps_terminal`) stays the run's exit spine;
criteria only steer the gate decision (R11). A step that omits `verification`
validates exactly as a pre-v0.7.0 workflow (additive — R7).

The array is capped at **16 criteria** (bounds gate-evaluation cost). Each entry
is a criterion object `{ "id": <unique non-empty str>, "type": <one of four>, … }`.
Criterion `id`s MUST be unique within the step. `type` MUST be one of exactly
four values; an unknown `type`, an unknown key for the criterion's type, a
duplicate `id`, or an array longer than 16 is a validation error at workflow
**load** time (the same `validate()` the skill's write-time `validate_and_lint`
runs — KTD-3), not only at write time.

**Per-type fields** (the allowed-key set is keyed on `type` — NOT a flat union,
so a programmatic criterion carrying `prompt`, or a human criterion carrying
`argv`, is rejected as an unknown field for its type):

| `type` | required type-fields | optional type-fields |
|--------|----------------------|----------------------|
| `programmatic` | `argv` (non-empty list of strings — argv only, no shell string) + `check` | `timeout_sec` (positive int; default 30; booleans rejected) |
| `model_judge` | — | `rubric_ref` (non-empty string) |
| `advisor_judge` | — | `rubric_ref` (non-empty string) |
| `human` | — | `prompt` (non-empty string) |

- **programmatic** — a deterministic check the engine runs with no model in the
  loop. `check` is one of: the string `"exit_zero"` (pass iff the process exits
  0); the object `{ "stdout_contains": <substr> }` (pass iff stdout contains the
  substring); or the object `{ "stdout_equals": <string> }` (pass iff stripped
  stdout equals it). A `check` object MUST carry exactly one of those two keys.
- **model_judge** — the dispatched work agent's own verdict (auto's existing
  same-model review).
- **advisor_judge** — a stronger, transcript-aware second opinion from auto's
  `advisor` tool (driver-evaluated — the in-house replacement for looper's
  cross-vendor council; no model registry, no CLI shell-out).
- **human** — a checkpoint only a human can clear; routes through auto's pause
  handoff.

```json
{
  "steps": [
    {
      "id": "gate", "phase": "work",
      "invokes": {"backend_op": "review"},
      "verification": [
        {"id": "tests-green", "type": "programmatic",
         "argv": ["bash", "tests/run.sh"], "check": "exit_zero",
         "timeout_sec": 120},
        {"id": "prints-ok", "type": "programmatic",
         "argv": ["echo", "ok"], "check": {"stdout_contains": "ok"}},
        {"id": "design-sound", "type": "advisor_judge",
         "rubric_ref": "verification-rubric"},
        {"id": "owner-signoff", "type": "human", "prompt": "Ship it?"}
      ]
    }
  ]
}
```

The criterion shape is pinned in
`skills/auto-design/references/verification-taxonomy.md` (the design skill's
canonical reference) and mirrored as a JSON Schema in `workflows/schema.json`. The
hand-rolled `lib/workflows.py::validate()` is the enforcer of all three; if the
doc, the schema, and the validator ever disagree, that is a contract bug —
`validate()` wins.

---

## Appendix — Legacy keys (read-compat)

The format-v2 cutover (v0.4.0, U6 of the concept-vocabulary rename) flipped every
persisted key and value in one step. The key names throughout this file are the
**current on-disk (v2)** spelling.

**A v1-keyed workflow file on disk keeps working, indefinitely.** `resolve()` runs
`format_compat.upgrade_workflow` on every read, before `validate()` — auto never
rewrites a user's workflow file, so acceptance of the old keys has no end date.
The authoring write-gate (`validate_and_lint`) likewise validates an internally
UPGRADED COPY of a draft, so a v1-keyed draft is accepted; a file the authoring
flow writes may itself persist v1-keyed and still resolve cleanly forever.

| legacy (v1) key | current (v2) key | where | <!--legacy--> |
|---|---|---|---|
| `units` | `steps` | workflow top-level (and `$defs.unit` → `$defs.step`) | <!--legacy--> |
| `default_adapter` | `default_backend` | workflow top-level | <!--legacy--> |
| `invokes.adapter_op` | `invokes.backend_op` | per step, and in `emit_templates.*.invokes` | <!--legacy--> |
| `do_unit` (value) | `do_step` | the backend-op VALUE (`brainstorm` / `next_plan_step` / `review` unchanged) | <!--legacy--> |
| `phase_transitions[].emitter` | `.producer` | mapped PER ITEM | <!--legacy--> |
| `plan_output_to_work_units` (value) | `plan_output_to_work_steps` | producer name; likewise `judge_winner_to_work_units`, `brainstorm_output_to_plan_unit`. `plan_output_to_paired_builders` is unchanged | <!--legacy--> |
| `iteration.gate_unit` | `iteration.gate_step` | the iteration block | <!--legacy--> |
| `"seam"` (value) | `"handoff"` | the phase VALUE in `phase_order`, `terminal_phase`, `phase_transitions[].from`/`.to`, and a step's `phase` | <!--legacy--> |

**Legacy LOCATION (v0.5.0, U8 — not a key).** The rename also moved the directory a
workflow file lives in. This is read-compat of the same kind, resolved by the tier
fallback in §1 rather than by the key shim, and it COMPOSES with the key map above
(a v1-keyed file in a legacy dir is the normal state of an upgrading user's disk):

| legacy (v1) location | current (v2) location | where | <!--legacy--> |
|---|---|---|---|
| `.claude/auto/recipes/` | `.claude/auto/workflows/` | the workspace + global tier dirs; the old dirs stay as READ-ONLY legacy tiers (§1). Never written to | <!--legacy--> |

**Shim guarantee:** old keys are accepted on READ indefinitely; the map is applied
unconditionally, is pure, and is idempotent, so a mixed old/new file resolves to
the new shape with the new key winning and the stale twin dropped. A workflow file
is NEVER stamped with a `format` marker — the schema is
`additionalProperties: false`, and a workflow carries its own `version` field.
