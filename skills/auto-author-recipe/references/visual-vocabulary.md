# Visual vocabulary — the recipe topology card

This is the contract doc for `lib/topology-render.py::render(recipe, width)` — the
ONE renderer (KTD-10) used by the picker (commands/auto.md), this authoring skill,
and `auto-status`. There is no separate per-surface art; all three call `render`,
so the card looks identical everywhere. When you show a draft to the user, you are
showing exactly what the picker will show — that consistency is the point.

## The card shape

`render` derives the card from recipe STRUCTURE, so a user-authored recipe looks
like a built-in:

```
recipe: <name>
  <description, word-wrapped>

  ┌─ PLAN
  │   • <unit-id>   ← <dep, dep>   (deps shown when present)
  └─
      ▼  emit: <producer-name>      (the producer that fires arriving at the next phase)
  ┌─ WORK  (terminal)
  │   • (units emitted at runtime)  (a phase with no declared units)
  └─
```

## What the parts mean (so you can explain a draft to the user)

- **Each `┌─ PHASE` box** is one phase in `phase_order`, top to bottom.
- **`• <unit-id>`** is a declared unit in that phase. `← a, b` shows its
  `depends_on` (it waits for a and b).
- **`(units emitted at runtime)`** means the phase has no pre-declared units —
  they're produced by the producer when the run reaches that phase (A1's work
  phase, A2's chosen-plan work, A4's builders).
- **`▼ emit: <name>`** on a between-phase arrow names the producer that fires when
  the run ARRIVES at the next phase (the producer is keyed on its `to` phase, so a
  `{from: plan, to: work}` producer shows on the arrow entering `work` even though
  the run routes through `seam`).
- **`(terminal)`** marks the phase whose completion ends the run.

## The four built-in cards (the reference set)

Render each with `bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh" --render <name>`:
- `a1` — one plan unit → `plan_output_to_work_units` → work (the classic stack).
- `a2` — plan-1/2/3 (parallel) + judge → `judge_winner_to_work_units` → work.
- `a4` — one plan unit → `plan_output_to_paired_builders` → two biased builders +
  comparator.
- `w` — work-only: `phase_order: ["work"]`, no plan, no producer; units come from
  `enumerate_plan_units` at init (an already-reviewed plan, built directly).

## Comparison — stacking cards for the launch chooser (KTD-2/KTD-3)

The launch chooser (`skills/auto-launch`) draws candidate shapes side-by-side so
the operator can see the shape difference at a glance. That contrast block is
`lib/topology-render.py::render_comparison(recipes, *, highlight=None, width=60)`
— a thin COMPOSING wrapper, **not** a second renderer. It calls the one `render`
once per candidate and stacks the cards, so the KTD-10 one-renderer rule still
holds: a comparison is just N invocations of `render`, and a user-authored recipe
contrasts against a built-in identically. A separate parallel renderer is rejected
— it would reintroduce exactly the drift the single-renderer invariant guards
against.

- Cards stack in **input order** (preserved), separated by a blank-line +
  horizontal rule (`─ × width`).
- The card whose recipe `name` equals `highlight` is prefixed with a
  `► recommended` marker line; `highlight=None` (or a name not among the
  candidates) emits no marker.
- A single-recipe list renders one card with no separator artifacts. Output is
  deterministic (byte-identical across calls), so tests can assert it exactly.

Render a contrast block with
`bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh" --compare <name>... [--highlight <name>]`
— it resolves each candidate through the same first-wins `recipes.resolve` as
`--render`, then prints the stacked cards (KTD-3: the cards go to stdout above the
`AskUserQuestion`, not crammed into an option field).
