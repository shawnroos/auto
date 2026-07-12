# Preset Format (PROVISIONAL — Phase 1)

> **⚠️ Status: PROVISIONAL.** The preset object shape below is **not locked**.
> Phase 1 (addressable-step-contents) ships the one-shot runnable preset, but
> the container↔preset boundary — how a flow's *container* references a preset
> by name and hands it inputs — is not built until Phase 2 (`preset_ref`, R6/R7/
> R8). The field set here may change once a real container consumer validates the
> boundary. Do **not** treat this as a locked contract or build external tooling
> against it yet. (Contrast: [`recipe-format.md`](recipe-format.md) is a LOCKED
> v0.3.0 contract.)

## 1. What a preset is

A **preset** is the pure payload of a step — the `invokes` that actually runs —
promoted to a first-class, named, addressable object. The reframe: a step is two
things, a **container** (its flow-local slot: `id`, `phase`, `depends_on`) and a
**preset** (the payload that runs there: one `adapter_op` invocation, optionally
tuned by a `prompt_template`). This spec covers the *preset*; the container stays
part of the recipe/flow — see [`recipe-format.md` §3 (`units[]`
entries)](recipe-format.md), where a unit's `invokes` is exactly the preset
embedded in a container.

A preset is **pure payload**: it carries **no** verification gate (R2). When a
preset is fired one-shot, the agent proposes a context-fit verification and the
user ratifies it at run time; that ratified check is ephemeral and is never
written back onto the preset.

## 2. Shape

```json
{
  "name": "tuned-review",
  "version": "1",
  "description": "A tuned code-review preset — runs `review` with a focused prompt.",
  "invokes": {
    "adapter_op": "review",
    "prompt_template": "presets/tuned-review.prompt.md"
  }
}
```

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `name` | yes | string | filename-safe (`^[a-z0-9][a-z0-9._-]*$`); the resolution key. Reuses the recipe name guard to prevent path traversal. |
| `version` | yes | string | opaque version tag. |
| `description` | yes | string | one-line human description — what this preset does and when to reach for it. |
| `invokes` | yes | object | the payload: `{adapter_op, prompt_template?}` and nothing else. |
| `invokes.adapter_op` | yes | string | one of the closed set `{brainstorm, do_unit, next_plan_step, review}` (shared with recipes via `lib/backend_ops.py::VALID_BACKEND_OPS`). |
| `invokes.prompt_template` | no | string | a **relative** path (no `..`, no leading `/`) to a tuning prompt. Path-bounded by the same `_check_prompt_template` recipes use. |

### Forbidden keys (hard errors)

A preset is payload, not payload-plus-wiring. These keys are rejected with a
message naming the field:

- `verification` — a preset carries no gate (R2). Verification is proposed and
  ratified at run time, never stored on the preset.
- `phase`, `depends_on` — container/flow concerns, not preset concerns.

Any other unknown top-level key, or an unknown key inside `invokes`, is also
rejected.

## 3. Resolution

`lib/presets.py::load_preset(name, repo)` resolves a preset by name across two
tiers, **first-wins** (a deliberate subset of the recipe registry — Phase 1 ships
no global tier and no browsable catalog; that is R3/Phase 2):

1. **workspace** — `<repo>/.claude/auto/presets/<name>.json` (override)
2. **built-in** — `<auto_root>/presets/<name>.json` (shipped seed)

A workspace file of the same name **overrides** the built-in. An unknown name
raises `PresetError` with a clear message listing what was searched — never a
bare traceback.

Validation is code, not schema: `validate_preset(obj) -> (ok, errors)` enforces
the rules above (hand-rolled, pure stdlib — same install-anywhere constraint as
the recipe validator). There is deliberately no `presets/schema.json` — a second
unenforced schema doc would just duplicate this one.

## 4. Built-in seeds

- **`tuned-review`** — `review` backend op + a focused review prompt. Fire it
  one-shot against a diff/branch.
- **`scoped-build`** — `do_unit` backend op + a tightly-scoped build prompt. Fire
  it one-shot to implement one bounded change.

## 5. DAG discipline

`lib/presets.py` reuses `lib/recipe_validate.py`'s `_check_prompt_template` and
`_validate_recipe_name`, and imports `VALID_BACKEND_OPS` from the pure-stdlib leaf
`lib/backend_ops.py`. It **must not** import `lib/dispatcher.py` (the heavy
dispatch module that pulls in the ledger) — the validator stays a light DAG leaf.
`tests/unit/import-topology.test.sh` asserts this boundary, and
`tests/unit/presets.test.sh` asserts `backend_ops.VALID_BACKEND_OPS` equals the
set `dispatcher.py` uses.
