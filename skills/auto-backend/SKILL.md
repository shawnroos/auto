---
name: auto-backend
description: >
  Author an auto backend (formerly auto-adapter) — the thin shim that maps one
  concrete workflow (native Claude, Compound Engineering, slate-devs, plain
  /plan, etc.) onto the engine's six fixed operations. Use when adding a new
  backend to auto, when implementing the native or CE backend (U6b), or when
  asked how a backend plugs into the auto loop engine. The locked
  interface lives at docs/contracts/backend-contract.md; this skill is the
  how-to-build guide for it.
---

# auto-backend skill

You are guiding the authoring of a **auto backend**. The engine runs
two loops — a plan-loop and a work-loop — but is workflow-blind. A backend
teaches it one workflow by implementing **six operations**. This skill walks the
author through building a conforming backend.

**Source of truth:** `auto/docs/contracts/backend-contract.md` is the
locked interface spec. This skill explains *how* to satisfy it; that file is
*what* must be satisfied. If they disagree, the contract wins, and the underlying
`ledger-schema.md` wins over both on shared persistence facts.

## The mental model

The engine is a mechanical loop driver. It never plans, deepens, reviews, or does
work — it delegates each of those to your backend, one named step at a time, and
records what you return in a disk ledger. Your backend is a **pure provider of
operations**: it returns data, it never writes the ledger. That single rule is
what keeps the loop's done-detection correct, so honor it strictly.

You implement six ops. Four drive the plan-loop; two drive the work-loop.

### Plan-loop ops (the tick calls these, one per tick)

1. **`plan(scope) -> plan`** — turn a scope description into an initial plan. The
   return is **opaque to the engine** — it can be a doc path, a string, or a
   structured object only your backend understands. The engine round-trips it back
   into `deepen` and `review_plan` without reading it.

2. **`deepen(plan) -> plan`** — run one deepening round and return the improved
   plan. If your workflow has no deepen concept, return the plan unchanged (a
   no-op) and simply never emit `"deepen"` from `next_plan_step`.

3. **`review_plan(plan) -> gap_set`** — run one plan-review pass and return an
   **array of gaps**. The engine reads only the array's **length** and writes it
   to `gaps_open`. Empty array means plan gaps are closed. Element shape is yours;
   the engine never inspects elements.

4. **`next_plan_step(ledger) -> token`** — **you own plan-step sequencing.** The
   engine never decides the plan order. Inspect the ledger and return the single
   next step: `"plan"`, `"deepen"`, `"review_plan"`, or `"done"`. Typical
   sequencers:
   - CE-style: `"plan"` → `"deepen"` → `"review_plan"` → loop deepen/review while
     gaps remain → `"done"`.
   - Native-style (no deepen): `"plan"` → `"review_plan"` → loop review while gaps
     remain → `"done"`.

   **Coherence rule (required):** once a `review_plan` round returns an empty
   gap-set (engine has written `gaps_open == 0`), your `next_plan_step` MUST
   return `"done"` next. Returning `"review_plan"` again would livelock the
   plan-loop.

### Work-loop ops (NOT called by the tick)

5. **`do_unit(unit) -> dispatch_handle`** — called by the **dispatcher**, not
   the tick. Dispatch one unit for execution and return an **opaque correlation
   token** (e.g. a Task id) the dispatcher uses to track the in-flight agent.

6. **`review(unit) -> findings[]`** — called by the **background work agent** on
   the unit it ran. Review the unit and return findings, each tagged on the shared
   severity scale: `[{ "severity": "blocker"|"major"|"minor", "note": "..." }]`.
   The agent records these through the engine's verdict path; **you do not write
   them to disk.**

## Severity translation — the heart of a backend

There is one shared severity scale with exactly three values:

```
blocker | major | minor
```

- `blocker` and `major` **gate** the work-loop — any open one keeps it running.
- `minor` does **not** gate — minors ship and are reported at exit for promotion.

Your workflow probably speaks a different vocabulary (P0/P1/P2/P3, error/warn/info,
etc.). Your `review` op must **translate every native level onto exactly one of the
three shared values** before returning. The engine only ever sees the three values.

You must **declare** two things up front — these are fixed backend properties, not
per-call decisions:

- **A severity mapping table** — your native vocabulary → `blocker`/`major`/`minor`.
  Example shape (CE): `P0 → blocker`, `P1/P2 → major`, `P3 → minor`.
- **An `adapter_scale`** — recorded in the ledger so the predicate evaluator knows
  which logic applies:
  - `"three-tier"` — you reliably produce all three severities.
  - `"blocker-only"` — you reliably produce `blocker` but your major/minor
    boundary is unreliable; the predicate then uses blocker-only logic.

### The rubric probe (for model-judged reviewers like the native backend)

If your backend's `review` relies on a model judging findings against a rubric
(rather than a deterministic command like `/ce-code-review`), run a **rubric probe
BEFORE writing the backend**: give a reviewer the blocker/major/minor rubric and
~five representative findings, and check whether it tags them consistently across
three tiers. Three outcomes set your `adapter_scale`:

- **Reliable** → ship `"three-tier"`.
- **Partial** (blocker solid, major/minor fuzzy) → ship `"blocker-only"`.
- **Unreliable** → defer this backend; ship the loop with a known-good backend only.

A command-driven reviewer with stable severity output (e.g. CE) skips the probe
and declares `"three-tier"` directly.

## The findings-write rule (do not violate)

Findings are written **only** by a `review` verdict. A new verdict **overwrites**
the findings array (never appends) — it is always the latest review's view. A tick
applying a fix does **not** clear findings inline; that would assert closure
without a review, which is forbidden. So a defect closes only when a fresh
`review` returns clean findings. Your job is just to emit accurate findings each
time `review` runs; the engine's re-enqueue-and-re-review loop handles closure.

## Exit predicates are the engine's, not yours

You never write an exit predicate. You supply inputs; the engine computes:

- **Plan-loop done:** empty gap-set (`gaps_open == 0`).
- **Work-loop done:** `blockers == 0 AND majors == 0 AND all_units_terminal == true`.

Get the severities right and the engine's predicate handles the rest. The
`all_units_terminal` conjunct is purely engine-side (it guards against stalled or
not-yet-reviewed units) — your backend does not influence it beyond returning
verdicts.

## Build checklist

- [ ] `plan(scope) -> plan` (opaque return)
- [ ] `deepen(plan) -> plan` (no-op allowed)
- [ ] `review_plan(plan) -> gap_set` (length is the open-gap count)
- [ ] `next_plan_step(ledger) -> token` (returns `"done"` once `gaps_open == 0`)
- [ ] `do_unit(unit) -> dispatch_handle` (opaque token; called by dispatcher)
- [ ] `review(unit) -> findings[]` (severities translated to the shared scale)
- [ ] A declared severity mapping table
- [ ] A declared `adapter_scale` (`"three-tier"` or `"blocker-only"`; native runs a rubric probe first)
- [ ] No ledger writes from any op — return data only

## References

- Locked interface: `auto/docs/contracts/backend-contract.md`
- Ledger contract (authoritative on shared facts): `auto/docs/contracts/ledger-schema.md`
- The two V1 backends this skill helps build (U6b): `lib/backend-native.*`, `lib/backend-ce.*`
- Plan: `docs/plans/2026-05-21-001-feat-auto-loop-engine-plan.md` (U6a / U6b)
