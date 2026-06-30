---
title: Auto Launch Chooser - Plan
type: feat
date: 2026-06-30
topic: auto-launch-chooser
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Auto Launch Chooser - Plan

## Goal Capsule

- **Objective:** Make interactive `/auto` open with a worked-out, context-grounded loop recommendation the operator confirms — the agent picks (or composes) the loop and proposes its gating before asking — while skipping the prompt entirely when both the shape and its gates are obvious.
- **Product authority:** Shawn (operator and owner).
- **Open blockers:** None block planning. Two design details are deferred to planning: how "obvious" is computed (the bias-to-show bar) and whether the contrast drawings extend the existing renderer or get a new view.

## Product Contract

### Summary

Replace `/auto`'s silent mechanical dispatch with an agent-first launch. On interactive `/auto <prompt>`, a loop-design agent reads the session and repo, recommends a fitting built-in recipe or composes a new one, and proposes typed verification gating at each gate point. It then presents a two-step chooser (confirm the shape drawn for contrast, then confirm or edit the gates) — and skips the chooser when both shape and gates are obvious, proceeding with a one-line notice.

### Problem Frame

Today `commands/auto.md` loads `auto-driver`, which surfaces one action line and auto-dispatches. `lib/recommender.py` is state-keyed: have-a-plan routes to `w`, raw intent recommends `/ce-plan`, clear intent picks `a1` — so the recommendation only ever lands on `a1` or `w`. The `a2` (competing plans) and `a4` (adversarial pair) recipes are reachable only through an explicit menu or `--recipe`. The topology cards (`lib/topology-render.py`) are wired to the picker but render only on an explicit ambiguity, so in the common path they are dead UI the operator never sees. Nothing reads the work's shape to reason about which loop fits, and nothing reasons about gating at launch at all. The result: the operator can't see or steer the loop choice, and the richer recipes go unused.

### Key Decisions

- **Agent-first, not menu-first.** The recommendation is computed before the question. The chooser shows the agent's work — a pick with rationale and proposed gates — not a blank menu.
- **Skip-when-obvious over always-show, biased to show.** The launch skips the prompt only when confidence is high on both the shape and its gates; any uncertainty shows the chooser. The skip bar is gating-aware and high — that is the safety property against regressing to the dead-UI problem.
- **Two-step over one combined prompt.** Confirming shape and gates separately keeps each decision readable.
- **Pre-compose custom loops inline.** "Design a new one" is a first-class recommendation outcome — when no built-in fits, the agent composes the custom loop up front and presents it drawn and confirmable, not as a fallback the operator must invoke.
- **Ground on the vendored looper rubrics.** Shape and gating reasoning use the in-tree `auto-design` rubrics; no live looper dependency is introduced.

### Key Flows

F1. **Interactive launch.** **Trigger:** a human runs `/auto <prompt>` without `--recipe`. The loop-design agent assesses session and repo state, determines the next step, and produces a recommended loop (built-in or composed) with typed gating per gate point. The launch then takes one of three paths by confidence: skip and dispatch with a one-line notice; a single confirm; or the full two-step chooser. On confirm (or skip), the run dispatches the chosen loop with its gates.

### Requirements

**Recommendation engine**

R1. On interactive `/auto`, a loop-design agent runs before any dispatch — it reads session and repo state, determines the next step, and produces a recommendation: a fitting built-in recipe (`a1`/`a2`/`a4`/`w`) or a newly composed custom loop.

R2. The agent proposes typed verification gating at each gate point of the recommended loop. Each criterion is typed as `programmatic`, `model_judge`, `advisor_judge`, or `human` per the v0.7.0 taxonomy.

R3. The agent grounds its shape and gating choices in the vendored `auto-design` rubrics (goal, verification, control, and the verification taxonomy). No live looper dependency is added.

R4. When no built-in recipe fits the work, the agent composes a custom recipe up front via the `auto-design` → `auto-author-recipe` / `auto-author-goal` backends and presents it as the recommended option, drawn like the built-ins. The composed recipe must pass recipe validation before it is offered.

**Chooser UX**

R5. When the chooser is shown, it is two-step: step 1 confirms the loop shape; step 2 confirms or edits the proposed gates.

R6. Step 1 presents the candidate recipes drawn for contrast so the shape difference is visible at a glance, with the agent's recommendation highlighted and a one-line rationale. A manual "design new" option is always available as an escape hatch into `auto-design` coaching.

R7. Overriding the recommended shape at step 1 re-derives the proposed gates for the chosen shape before step 2.

**Confidence ladder**

R8. Launch follows a three-tier confidence ladder: both shape and gates obvious → skip the chooser and proceed; one dimension settled and the other quick → a single confirm showing the drawing, pick, and gates; a real choice or non-obvious gating → the full two-step chooser.

R9. On a skip, the run proceeds without a prompt but prints a one-line non-blocking notice naming the chosen recipe and its gates (for example `-> a1 · gate: tests green`), so the decision stays visible and auditable.

R10. The skip clears a high bar on both dimensions; any genuine uncertainty on either falls back to showing the chooser.

**Scope of the reshape**

R11. This reshape applies to interactive `/auto` only. Self-driven, conversation-context, and headless runs keep auto-applying the recommendation silently, since the advisor no-questions gate denies blocking prompts there.

R12. Passing an explicit `--recipe` bypasses the chooser entirely; the power-user dispatch form is unchanged.

### Acceptance Examples

AE1. **Covers R8, R9, R10.** A one-line typo fix where `a1` with a tests-pass gate is obvious → no prompt; the run dispatches and prints `-> a1 · gate: tests green`.

AE2. **Covers R8, R9.** A reviewed plan with standard tests-pass gating → skip with a one-line `w` notice rather than the current silent route.

AE3. **Covers R5, R6, R7, R8.** A high-uncertainty design task → the agent recommends `a2` with an `advisor_judge` criterion at the judge gate; the two-step chooser fires; the operator confirms the shape, then edits one gate.

AE4. **Covers R4, R6.** Work that fits no built-in (it needs a spike-before-build gate no built-in expresses) → the agent composes a custom loop and presents it as the highlighted step-1 option, drawn for contrast; the operator confirms it directly.

AE5. **Covers R7.** The operator overrides the recommended `a2` and picks `a4` at step 1 → step 2 shows gates re-derived for `a4`, not `a2`'s.

AE6. **Covers R11.** A self-driven conversation-context run → no chooser; the recommendation is applied silently.

### Scope Boundaries

- Self-driven, conversation-context, and headless runs get no chooser — interactive `/auto` only.
- The gate mechanics, the deterministic exit predicate (`blockers == 0 && majors == 0 && all units terminal`), and the verification taxonomy are not changed; this feature consumes the v0.7.0 surfaces, it does not redesign them.
- No new built-in recipe topologies; the four built-ins plus agent-composed customs are the set.
- Persisting or re-editing agent-composed custom recipes beyond the launch moment stays with `auto-author-recipe`; this feature needs only inline compile-and-run.

### Outstanding Questions

**Deferred to Planning**

- **The "obvious" confidence signal.** How the agent operationally decides skip vs single-confirm vs two-step. This is the load-bearing safety property — planning must pin a bias-to-show bar that requires high confidence on both shape and gates, so a wrong skip cannot quietly reinstate the dead-UI problem.
- **Renderer mode.** Whether the contrast drawings extend `lib/topology-render.py` with a comparison mode (honoring the KTD-10 "one renderer" rule) or get a separate chooser view. The drawings are product-visible; the rendering mechanism is an implementation choice.
- **Drawing delivery in the prompt.** How the per-option contrast drawing is carried into the chooser (for example the `AskUserQuestion` preview field).

### Dependencies / Assumptions

- Depends on v0.7.0 surfaces: the verification taxonomy, `auto-design` plus `auto-author-recipe` / `auto-author-goal`, `lib/topology-render.py`, `lib/recommender.py`, and the `auto-driver` smart-entry path.
- Assumes interactive launch can run a blocking question (true for a human-typed `/auto`; denied for self-driven runs by the advisor gate, which R11 relies on).
- Assumes inline recipe compilation at launch is acceptable latency for the custom-loop case.

### Sources / Research

- `commands/auto.md` → `skills/auto-driver/SKILL.md` — the launch surfaces one action line and auto-dispatches (the dead-UI cause).
- `lib/recommender.py` — state-keyed routing that only ever reaches `a1` or `w`.
- `lib/topology-render.py` + `skills/auto-author-recipe/references/visual-vocabulary.md` — the single topology-card renderer (KTD-10) and its card contract.
- `skills/auto-design/SKILL.md` + `skills/auto-design/references/{goal,verification,control}-rubric.md`, `verification-taxonomy.md` — the looper-grounded rubrics this agent reasons from.
- `docs/contracts/recipe-format.md` (iteration block and gates) and `docs/contracts/ledger-schema.md` (the unit `verification` field) — the gate and gating substrate.
