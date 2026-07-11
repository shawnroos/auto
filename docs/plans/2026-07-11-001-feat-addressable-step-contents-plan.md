---
title: "Addressable Step Contents - Plan"
type: feat
date: 2026-07-11
deepened: 2026-07-11
topic: addressable-step-contents
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Addressable Step Contents - Plan

## Goal Capsule

- **Objective:** Make the *content* of a step — the payload that actually runs — a first-class, named, runnable object in `/auto`, so it can be fired one-shot standalone as a quick "mini-auto" (Phase 1), and later reused across flows, catalogued, and hot-swapped (Phase 2, deferred).
- **Product authority:** Shawn (owner of the `auto` plugin).
- **Phase 1 scope (this plan):** the one-shot runnable content + contextual verification + legible names — R1, R2, R4, R5, R9.
- **Deferred (Phase 2, sketched in *Deferred to Follow-Up Work*):** the browsable library, composition into flows, and hot-swap — R3, R6, R7, R8.
- **Open blockers:** None. The three brainstorm forks are resolved as Assumptions A1–A3; two design questions (the one-shot verdict mechanism, and the run-control lifecycle) were resolved during planning after two adversarial passes — see A4, A5.

---

## Planning Contract

**Product Contract preservation:** changed — Problem Frame clarified. The brainstorm cited "a specific plan-then-build" as trapped reusable value; planning confirmed a single content is *one* step's payload (one adapter op), so plan-then-build is a two-container **flow**, not a content. The example is narrowed to genuinely single-step contents (a tuned review, a tuned build); the multi-step case is named as a deferred flow. This is a scope *clarification* consistent with the existing Scope Boundary "Manual step-through of a multi-step flow is out of scope," not a product-scope reversal. All R-IDs, F-IDs, and AE-IDs are preserved.

---

## Product Contract

### Summary

Today the *flow* (recipe) is the only addressable object; the steps inside it are embedded fragments. This splits a step into its **container** (the slot: wiring, phase) and its **content** (the payload: the invocation that runs), and promotes the *content* to a named, **runnable** object. The Phase-1 headline is firing one content one-shot — grab it by name, point it at a target, go — with no flow and no loop. Verification is never baked into a content; the agent proposes a context-fit check at use time and the user accepts or edits it, and that ratified check produces the one-shot's verdict.

### Problem Frame

A good step — a well-tuned code-review, a specific build instruction — is trapped inside the recipe it was written in. You can't name it, edit it once, or run it on its own. The only addressable object is the whole loop, so every reuse is copy-paste and every "just run this one step against this thing" means arming a full plan→work run. The felt cost: the reusable value lives at the step level, but nothing at the step level is grabbable. (Multi-step reusable value — e.g. a plan-then-build sequence — is a *flow* of two containers, addressed by the deferred composition arc, not a single content.) The shorthand recipe names (`a1`/`a2`/`a4`/`w`) make even the flows hard to reach for by intent.

### Key Decisions

- **Content vs container split (the core reframe).** The step is two things: the *container* is the slot and its flow-local wiring (`id`, `phase`, `depends_on`); the *content* is the payload that runs there (`invokes`: one `adapter_op` + an optional `prompt_template`). The content is what gets packaged and addressed; the container stays part of the flow. This split already exists latent in the recipe schema — a unit's `invokes` is separable from its `id/phase/depends_on`.
- **A content is a first-class *data* object; the one-shot reuses the existing engine — it does not fork one.** A content is a small named JSON (`{name, version, description, invokes}`). Running it one-shot **synthesizes a single-unit work-only run from the content and drives it with the `auto-content` skill** — reusing the recipe loader's validation primitives and the orchestrator's dispatch. There is **no** parallel loader, run engine, or tick. (See KTD-2, KTD-3, and *Alternatives Considered* — this is the leaner path a design review chose over a parallel `contents.py`/`content_run` engine.)
- **A content is one step's payload.** One `adapter_op` invocation (plus optional `prompt_template` for tuning). Not a multi-step sequence — that is a flow.
- **Verification is generated, not stored.** A content carries no built-in gate (enforced: the content validator rejects a `verification` field). When a content runs one-shot, the agent proposes a context-appropriate verification and the user accepts or edits it; the ratified criteria are baked into that run and are what produce its verdict. Ephemeral by default — never written back to the content. Same agent-proposes / human-ratifies seam already used by `auto-design`, pushed to the step level and to run time.
- **Contents are runnable, not just composable.** The one-shot run is a new entry point, not merely a library. This is the primary itch.
- **Extend existing seams, don't rebuild.** Reused, not re-implemented: `recipe_validate`'s `_check_prompt_template`, the closed adapter-op set, the orchestrator's single dispatch, and the pure `verification.evaluate_programmatic`/`aggregate` evaluator. The one-shot adds a thin driver-orchestrated path, not a parallel engine.

### Requirements

**Content packaging**

- R1. A content — the payload that runs in a step (an `adapter_op` invocation) — is a first-class named object, addressable independently of any flow.
- R2. A content is pure payload: it carries no built-in verification gate.
- R3. Contents are catalogued and discoverable — a library you can browse and reference by name. *(Deferred to Phase 2.)*

**Running a content**

- R4. A content can be fired one-shot standalone: quick setup, point it at a target, run, get the result plus a verdict — no flow, no loop.
- R5. On a one-shot run, the agent proposes a context-appropriate verification and the user accepts or edits it before it applies; the ratified check produces the run's verdict.

**Composition and swap** *(all deferred to Phase 2)*

- R6. A flow is a graph of containers; a container references a content by name, and the same content is reusable across flows.
- R7. A container's content can be swapped without editing the flow's wiring — at design time and at run-time.
- R8. The container↔content boundary is typed enough that a swapped-in content is checked for compatibility.

**Identity**

- R9. Addressable flows carry legible, meaningful names, aliasing the `a1`/`a2`/`a4`/`w` shorthand.

### Key Flows

- F1. One-shot content run (the Phase-1 headline)
  - **Trigger:** Operator wants to run one step against a target, ad-hoc.
  - **Steps:** Name a content → point it at the target → agent proposes a context-fit verification → operator accepts or edits → content dispatches once → ratified criteria resolve inline → result plus verdict returned → run terminates.
  - **Outcome:** A single step ran with a ratified check, no flow armed.
  - **Covers:** R1, R2, R4, R5.
- F2. Compose a flow from contents *(Phase 2, deferred)* — place named contents into containers; the flow owns the wiring. **Covers:** R3, R6.
- F3. Swap a content *(Phase 2, deferred)* — re-point a container to another named content, compatibility-checked. **Covers:** R7, R8.

### Acceptance Examples

- AE1. **Contextual verification on a one-shot run.** Given a content fired standalone, when it starts, then the agent proposes a verification derived from the target/context and the run does not apply a check until the operator accepts or edits it. **Covers R5.**
- AE2. **Edit the proposed check.** Given a proposed verification the operator disagrees with, when they edit it, then the edited check is what applies to that run. **Covers R5.**
- AE3. **Incompatible swap is caught.** *(Phase 2, deferred.)* Given a container whose slot provides inputs a candidate content does not consume, when the operator swaps that content in, then the swap is flagged as incompatible. **Covers R8.**

### Scope Boundaries

- **Manual step-through of a multi-step flow is out of scope.** The chosen run mode is one-shot single-content.
- **The loop runtime is unchanged.** The tick/orchestrator, the ledger, the deterministic exit predicate, and the iteration machinery stay as-is. The one-shot is driver-orchestrated by the `auto-content` skill and never enters the tick loop — Phase 1 adds an authoring-adjacent data object plus a run-one-content entry point, not an engine change.
- **The locked contracts are extended additively, never re-locked.** The one-shot reuses the verification *evaluator* in a new terminal context; it does not change the §11 gate-steering semantics for normal looping recipes, nor the adapter op set.
- **Composition, library/catalog, and hot-swap (R3, R6, R7, R8) are Phase 2** — see *Deferred to Follow-Up Work*.

### Sources / Research

- `recipes/*.json` + `recipes/schema.json` — the current flow format; `units[].invokes` is the content-in-a-container.
- `docs/contracts/recipe-format.md` §3 (units), §11 (typed `verification`) — the locked prose contract.
- `docs/contracts/adapter-contract.md` §2 (the seven ops; `do_unit`, `review`), §2.2 (opaque invocation), §5 (exit predicate).
- `docs/contracts/driver-reference.md` §7 — the driver launch map (`orchestrator.dispatch_batch` never consults the adapter; the driver maps `invokes.adapter_op` → the skill it launches). Load-bearing for KTD-5.
- `lib/recipes.py` (`resolve`, `load_and_validate`), `lib/recipe_validate.py` (`validate`, `_check_prompt_template`) — the validator primitives to reuse. **Note:** `VALID_ADAPTER_OPS` lives in `lib/orchestrator.py`, **not** the validator (which is a pure-stdlib DAG root) — see KTD-2.
- `lib/verification.py` (`evaluate_programmatic`, `aggregate`) + `lib/iteration.py` (`resolve_gate_verification`) — the criterion evaluator reused in a new terminal context.
- `lib/ledger.py` (`init`/`_h_init`), `lib/orchestrator.py` (`dispatch_batch`, `_unit_adapter_op`, `VALID_ADAPTER_OPS`) — single-unit record + one-shot dispatch.
- `lib/ledger_core.py` (`_normalize_unit`, `DISPATCH_CONTEXT_KEYS`) — dispatch-context carry + the read-key guard KTD-4 must respect.
- `skills/auto-design` + `references/verification-taxonomy.md`, `skills/auto-author-recipe`, `skills/auto-author-goal` — the agent-proposes / human-ratifies ladder R5 extends to step granularity and run time.
- `lib/recommender.py` (`_TAXONOMY`), `lib/launch-gate.py` (`SKIP_ELIGIBLE_RECIPES`), `recipes.py` `A1_BUILTIN` fallback — the hardcoded stem sites R9's alias touches.
- `docs/contracts/ledger-schema.md` §5 (I-1 lost-update invariant) — cited by KTD-4.

---

## Assumptions

Resolved planning forks, recorded because they were decided without a live confirmation (headless enrichment). Each is the accepted lean.

- **A1 — Sequencing (phased, one-shot first).** Phase 1 ships the one-shot runnable content + contextual verification + legible names (R1, R2, R4, R5, R9). The browsable library, composition, and swap (R3, R6, R7, R8) are Phase 2 (*Deferred to Follow-Up Work*). Rationale: the one-shot is the itch; the library is the fuller arc. To lower the reversal cost of locking the content shape before a container consumes it, `content-format.md` ships **provisional** (see A5 note in KTD-2).
- **A2 — Ephemeral verification.** A ratified check lives only on that one-shot run; it is never persisted back onto the content object. "Remember this check for this content" is a deferred opt-in — a saved default would quietly turn a content back into payload-plus-gate, violating R2.
- **A3 — Payload granularity.** A content is exactly one step's `invokes` payload: one `adapter_op` (from the locked set `{brainstorm, do_unit, next_plan_step, review}`) plus an optional path-bounded `prompt_template`. Multi-step reusable value is a flow of containers (deferred), not a content.
- **A4 — The one-shot verdict mechanism.** The one-shot's verdict is the **ratified-criteria aggregate**, evaluated once via the existing `verification.evaluate_programmatic` + `aggregate` primitives. It is deliberately **not** the findings-based Stop predicate (a `do_unit` content produces no findings), **not** `review.json`'s fix-loop (which loops to P3-only, contradicting "run once"), and **not** the iteration gate (`verification[]` only steers advance/iterate inside a looping recipe with an `iteration` block — dead config on a single-unit run). This keeps the locked §11 semantics for normal recipes untouched while giving the one-shot a real single-pass pass/fail. See KTD-1.
- **A5 — The one-shot is driver-orchestrated, not tick-armed.** The `auto-content` skill is the orchestrator: it loads the content, runs propose/ratify, launches the content's op **once** as an awaited sub-agent, resolves every ratified criterion **inline** (programmatic in-process; `model_judge` from the dispatched agent's own verdict; `advisor_judge` by a blocking `advisor` consult; `human` by a blocking pause), aggregates, and returns the verdict. No tick, no `ScheduleWakeup`, no `/goal`, no re-arm. This is why "the loop runtime is unchanged" holds literally, and why async criterion types resolve without a next tick. See KTD-3.

---

## Key Technical Decisions

### KTD-1. The one-shot verdict is a new terminal use of the verification *evaluator*, not the iteration gate or the Stop predicate.

`lib/verification.py` exposes two pure primitives — `evaluate_programmatic(criterion, cwd)` and `aggregate(criteria, programmatic_results, judge_verdicts) -> {signal, pending_judges}`. In normal recipes these are wired *only* through `lib/iteration.py::resolve_gate_verification`, which reads criteria off a looping recipe's `iteration.gate_unit` and folds them into an advance/iterate signal (recipe-format §11: criteria "only steer the gate decision," never a terminator). A single-unit one-shot has no `iteration` block, so that path never fires (confirmed: `resolve_gate_verification` short-circuits with no iteration block).

The one-shot therefore calls `evaluate_programmatic` + `aggregate` **directly** in a small terminal path: after the content dispatches once, resolve every ratified criterion (see KTD-3 for inline resolution of all four types), aggregate, and map **all-resolved-pass → verdict `pass`; any-resolved-fail → verdict `fail`**. (The evaluator's internal `signal` values `advance`/`iterate` are an implementation detail of the aggregator; the one-shot re-labels the terminal outcome `pass`/`fail` rather than borrowing the loop's "iterate" semantics.) This reuses the pure evaluator and touches neither the locked §11 gate-steering contract nor the adapter op set. **Boundary to defend in review:** the terminal path must not import or reuse `iteration.py`'s decision-commit — it is a read-only aggregate for verdict reporting, not an iteration decision.

### KTD-2. A content is a distinct first-class data object; its validator reuses `recipe_validate`'s primitives without cloning the loader.

A content is `{name, version, description, invokes:{adapter_op, prompt_template?}}` with **no** `verification`, `phase`, or `depends_on`. `validate_content` reuses:
- `recipe_validate._check_prompt_template` for path-bounding (relative, no `..`/leading `/`) — a direct reuse.
- The closed adapter-op set. **`VALID_ADAPTER_OPS` lives in `lib/orchestrator.py`, not the validator** (which is a deliberate pure-stdlib DAG root importing no sibling lib module). So the op-set check must **not** import `orchestrator.py` into the loader. Lift `VALID_ADAPTER_OPS` into a tiny shared stdlib leaf (`lib/adapter_ops.py`) that both `orchestrator.py` and `contents.py` import, **or** duplicate the small frozenset in `contents.py` guarded by a symmetry test asserting it equals `orchestrator.VALID_ADAPTER_OPS`. Chosen: the shared leaf (single source of truth; smaller blast radius than a drift-prone duplicate).
- One new assertion: a `verification` key is a hard error (R2 made structural).

Phase 1 ships a **minimal** name→content loader (built-in `contents/` dir + workspace-tier override for parity) — **not** the full tri-tier registry + `list_available` catalog, which is R3 (Phase 2). The written contract is `content-format.md`, marked **provisional** until a Phase-2 `content_ref` consumer validates the container/content boundary (A1/A5 reversal-cost mitigation). No `contents/schema.json` — validation is code, and a second unenforced schema doc would duplicate `content-format.md`.

### KTD-3. The one-shot is driver-orchestrated by the `auto-content` skill; the engine is untouched, and all four criterion types resolve inline.

The skill owns control flow (A5): load content → propose/ratify (U3) → launch the content's op once as an awaited sub-agent → resolve criteria inline → aggregate (KTD-1) → report → terminate. A `lib/content_oneshot.py` helper provides the two pure/thin pieces the skill calls: `synthesize_oneshot_unit(content, ratified_criteria)` (a single work-phase unit dict, criteria baked per KTD-4) and `oneshot_verdict(unit, programmatic_results, judge_verdicts)` (the terminal aggregate of KTD-1). The ledger records the single unit for observability, but **no tick, `ScheduleWakeup`, or `/goal` is armed** — this is the concrete guarantee behind "loop runtime unchanged." Inline resolution: `programmatic` in-process via `evaluate_programmatic`; `model_judge` = the dispatched agent's own verdict returned with its result; `advisor_judge` = a blocking `advisor` consult by the skill; `human` = a blocking pause. Because the skill drives synchronously, there is no "pending across ticks" state — every ratified criterion resolves before the verdict returns.

### KTD-4. Ratified criteria are baked in at synthesis, not written at run time — and read directly, not via `read_dc`.

The propose/ratify exchange (U3) happens *before* the run unit exists. `synthesize_oneshot_unit` writes the ratified criteria into the single-unit dict at construction, so no preconditioned steering mutator and no lost-update concern (ledger-schema.md §5, invariant I-1) is introduced — this is a compile-time write, not a concurrent one. **Guard:** if the criteria ride on the unit's `dispatch_context`, they must be read directly, because `iteration.read_dc` raises `KeyError` for any key outside `ledger_core.DISPATCH_CONTEXT_KEYS`. Either read the baked criteria without `read_dc`, or add the new key to the declared set — the plan prefers reading directly (the one-shot path never uses `read_dc`).

### KTD-5. For the one-shot, the *driver* honors the content's `prompt_template` at launch — no adapter edit.

`orchestrator.dispatch_batch` is adapter-agnostic: it flips the unit `pending → dispatched` and calls the driver-injected `launch_fn`; it **never consults the adapter** (driver-reference §7). So the load-bearing site for "a content's tuning reaches the dispatched agent" is the **driver launch**, not `adapter-ce.py::do_unit`. In the driver-orchestrated one-shot (KTD-3), the `auto-content` skill *is* the launcher: it reads the content's `prompt_template` and folds it into the sub-agent launch directly. No adapter change is required on the one-shot path, and there is no `adapter.review()` edit (that op is the parse half — it returns findings, not an invocation). *(The `adapter.do_unit` generalization — so a recipe-embedded `content_ref` running through the tick also honors `prompt_template` — moves to Phase 2, where contents run inside flows via the orchestrator's `launch_fn`.)*

### KTD-6. R9 aliases, never renames.

`recipes.resolve()` is name-agnostic (a new file resolves with zero code change), but bare `/auto` falls back to `recipes.py::A1_BUILTIN` on `name == "a1"`, and stems are keyed in `recommender._TAXONOMY`, `launch-gate.SKIP_ELIGIBLE_RECIPES`, `auto-detect` hypotheses, teardown `<builtin>-<run-slug>` naming, and tests asserting `a1.json == A1_BUILTIN`. Add legible names as *aliases* that resolve to the same recipes; do not rename the stems or the fallback constant. U6 is technically independent of U1–U5 (a disjoint file set) and independently shippable — it is included here as the Phase-1 identity requirement (R9), but the Definition of Done treats its completion separately so a naming bikeshed cannot block the content headline.

---

## Alternatives Considered

- **Content as a wholly new object type with a parallel run engine** (`lib/contents.py` mirroring `recipes.py`, `lib/content_run.py` mirroring `auto.py`, `contents/schema.json` mirroring `recipes/schema.json`). *Rejected.* KTD-2 establishes a content is a strict subset of a single-unit work-only recipe, so a parallel loader/engine duplicates ~200 LOC and two contracts for no field a synthesized single-unit run cannot carry. It also contradicts the plan's own "extend, don't rebuild" decision. The chosen path keeps the content as a distinct *data* object but reuses the validator primitives + orchestrator dispatch, driver-orchestrated (KTD-2, KTD-3).
- **One-shot as a tick-armed run** (synthesize a work-only recipe, arm via `auto.py` → `ScheduleWakeup` + `/goal`, let the Stop predicate terminate). *Rejected.* It re-introduces the tick, `/goal`, and a `one_shot` marker that every tick/predicate/resume site must honor — enlarging the "engine unchanged" blast radius — and it cannot resolve async `human`/`advisor_judge` criteria in a single pass without extra tick machinery. Driver-orchestration (KTD-3) resolves all criterion types inline and leaves the engine literally untouched.
- **`content_ref`-first sequencing** (make a real recipe container consume a named content before building the standalone runner, validating the container/content split against its actual consumer). *Deferred, not chosen* — the operator explicitly prioritized the one-shot itch. Reversal-cost mitigation: `content-format.md` ships provisional until a Phase-2 consumer validates the split (A1/A5).

---

## High-Level Technical Design

**The container/content split (structure):**

```
        CONTAINER (flow-local wiring)              CONTENT (portable data object)
        ┌───────────────────────────┐             ┌────────────────────────────┐
 unit = │ id · phase · depends_on    │  ──uses──▶  │ name · version · description│
        └───────────────────────────┘             │ invokes:{adapter_op,        │
             stays in the recipe                   │          prompt_template?}  │
                                                   │  (no verification — R2)     │
                                                   └────────────────────────────┘
```

**The one-shot lifecycle (F1) — driver-orchestrated, engine untouched:**

```mermaid
sequenceDiagram
    participant Op as Operator
    participant Skill as auto-content skill (the orchestrator)
    participant Load as lib/contents.py
    participant Help as lib/content_oneshot.py
    participant Sub as dispatched sub-agent (do_unit/review)
    participant Ver as verification.py (existing evaluator)

    Op->>Skill: run <content-name> against <target>
    Skill->>Load: load_content(name) → validate_content (KTD-2)
    Skill->>Op: PROPOSE context-fit criteria (seed, don't interview)
    Op->>Skill: accept / edit criteria  (R5, AE1, AE2)
    Skill->>Help: synthesize_oneshot_unit(content, ratified) (KTD-4)
    Skill->>Sub: launch content op ONCE, honoring prompt_template (KTD-5), await
    Sub-->>Skill: output (findings or artifact) + model_judge self-verdict
    Skill->>Ver: evaluate_programmatic (in-process)
    Skill->>Skill: resolve advisor_judge (blocking advisor) / human (blocking pause) (KTD-3)
    Skill->>Help: oneshot_verdict(unit, programmatic_results, judge_verdicts) → aggregate (KTD-1)
    Help-->>Skill: pass | fail
    Skill->>Op: RESULT + VERDICT ; run terminates (no tick, no re-arm)
```

The boundary that matters (KTD-1): `oneshot_verdict`'s `aggregate` is a read-only terminal verdict, distinct from `iteration.py`'s gate-decision commit used by looping recipes.

---

## Output Structure

New and touched files (Phase 1):

```
contents/                          # NEW — built-in content data objects
  tuned-review.json                #   seed: a review content (invokes review + prompt_template)
  scoped-build.json                #   seed: a do_unit content (invokes do_unit + prompt_template)
lib/
  adapter_ops.py                   # NEW — shared stdlib leaf: VALID_ADAPTER_OPS (KTD-2)
  contents.py                      # NEW — load_content + validate_content (reuses recipe_validate primitives)
  content_oneshot.py               # NEW — synthesize_oneshot_unit + oneshot_verdict (thin helpers, KTD-3)
  orchestrator.py                  # MOD — import VALID_ADAPTER_OPS from adapter_ops (no behavior change)
  recommender.py                   # MOD — legible aliases in _TAXONOMY (R9)
  launch-gate.py                   # MOD — legible aliases in SKIP_ELIGIBLE_RECIPES (R9)
  recipes.py                       # MOD — alias table resolving legible names → stems (R9)
skills/
  auto-content/SKILL.md            # NEW — the one-shot orchestrator + user entry (F1)
  auto-content/references/one-shot-verification.md   # NEW — deriving/ratifying criteria
  auto-launch/SKILL.md             # MOD — picker prose uses legible names (R9)
docs/contracts/
  content-format.md                # NEW (provisional) — the content data-object contract
  driver-reference.md              # MOD — §7 documents the one-shot verdict path + its boundary from the gate
tests/                             # see per-unit Test scenarios
```

No `lib/content_run.py` and no `lib/contents.py` registry/catalog — the one-shot is skill-orchestrated over thin helpers (KTD-3), and the registry/catalog is R3 (Phase 2). The tree is a scope declaration; per-unit `Files:` remain authoritative.

---

## Implementation Units

### U1. Content data object: seeds, loader, and validator

- **Goal:** A content is a first-class named object, loadable by name and validated as pure `invokes` payload with no gate.
- **Requirements:** R1, R2. **Assumptions:** A2, A3. **KTDs:** KTD-2.
- **Dependencies:** none.
- **Files:**
  - `lib/adapter_ops.py` (create) — `VALID_ADAPTER_OPS` as a shared stdlib leaf.
  - `lib/orchestrator.py` (modify) — import `VALID_ADAPTER_OPS` from `adapter_ops` (behavior-preserving).
  - `contents/tuned-review.json`, `contents/scoped-build.json` (create) — two seeds (`review` + `prompt_template`; `do_unit` + `prompt_template`).
  - `lib/contents.py` (create) — `load_content(name, repo) -> dict` (built-in `contents/` + workspace `.claude/auto/contents/` override) and `validate_content(obj) -> (ok, errors)`.
  - `docs/contracts/content-format.md` (create, marked **provisional**).
  - `tests/unit/contents.test.sh` (create).
- **Approach:** `validate_content` imports `recipe_validate._check_prompt_template` and `adapter_ops.VALID_ADAPTER_OPS`; asserts `invokes.adapter_op ∈ VALID_ADAPTER_OPS`, path-bounds `prompt_template`, and rejects a `verification` key (R2). Loader resolves built-in first, workspace override second; unknown name → clear error. Do **not** import `orchestrator.py` into `contents.py` (KTD-2 DAG boundary).
- **Patterns to follow:** `lib/recipes.py::resolve`/`load_and_validate` (subset, don't clone); `lib/recipe_validate.py::_check_prompt_template`; the pure-stdlib DAG-root discipline in `recipe_validate.py`'s header.
- **Execution note:** Start from a failing test that loads `tuned-review.json` and asserts validation passes, plus a failing test that a `verification`-bearing content is rejected — see both fail once before implementing.
- **Test scenarios:**
  - A valid built-in content loads and validates. Covers R1.
  - A content carrying a `verification` field is rejected with a message naming the field. Covers R2.
  - A content with `adapter_op` outside the set is rejected.
  - A `prompt_template` with `..` or a leading `/` is rejected (parity with recipes).
  - An unknown content name yields a clear not-found error, not a traceback.
  - A workspace `.claude/auto/contents/<name>.json` overrides a built-in of the same name.
  - `adapter_ops.VALID_ADAPTER_OPS` equals the set `orchestrator.py` uses (symmetry — proves the shared-leaf refactor preserved the dispatch guard).
- **Verification:** seeds validate; the two negative cases fail closed; orchestrator's dispatch-op guard is unchanged.

### U2. One-shot synthesis + dispatch helper

- **Goal:** Turn a loaded content + ratified criteria into a single-unit run and dispatch its op exactly once.
- **Requirements:** R1, R4. **KTDs:** KTD-3, KTD-4.
- **Dependencies:** U1.
- **Files:**
  - `lib/content_oneshot.py` (create) — `synthesize_oneshot_unit(content, ratified_criteria) -> unit_dict` (one work-phase unit; content's `invokes` in `dispatch_context`; ratified criteria baked; no `iteration`, no `phase_transitions`); optional `ledger.init` record for observability.
  - `tests/unit/content-oneshot-synth.test.sh` (create).
- **Approach:** The synthesized unit is a plain single work-unit — the `auto-content` skill (U7) drives its single dispatch via the orchestrator/awaited sub-agent (KTD-3). No arm intent, no tick, no `/goal`. Baked criteria are readable without `read_dc` (KTD-4).
- **Patterns to follow:** `recipes/review.json`/`recipes/w.json` for the work-only single-unit *shape*; `lib/orchestrator.py::dispatch_batch` for the single dispatch the skill invokes.
- **Execution note:** Test-first: assert the synthesized unit has exactly the content's `adapter_op`, the baked criteria, and no loop machinery.
- **Test scenarios:**
  - Synthesizing from a valid content yields one work unit whose `dispatch_context.adapter_op` equals the content's op. Covers R4.
  - The unit has no `iteration` block and no `phase_transitions` (KTD-3).
  - Ratified criteria are present on the unit and readable without `read_dc` (KTD-4 guard).
  - No criteria supplied → the unit carries none (not an empty-gate default).
- **Verification:** a one-shot unit synthesizes with the content's op and baked criteria, no loop machinery.

### U3. Contextual verification: propose, ratify, bake (pre-dispatch)

- **Goal:** At one-shot use time the skill proposes a context-fit verification, the user accepts or edits it, and the ratified criteria are handed to synthesis — never persisted to the content.
- **Requirements:** R5, R2. **Acceptance:** AE1, AE2. **Assumptions:** A2. **KTDs:** KTD-3, KTD-4.
- **Dependencies:** U1, U2.
- **Files:**
  - `skills/auto-content/references/one-shot-verification.md` (create) — how to derive criteria from a target/context, using all four criterion types with their inline-resolution rules (KTD-3).
  - `skills/auto-content/SKILL.md` (create the propose-ratify section; finalized in U7).
  - `tests/integration/one-shot-verification.test.sh` (create).
- **Approach:** Reuse `auto-design`'s "Seed, don't interview" invariant and the `verification-taxonomy.md` criterion shapes. The skill proposes a small criteria list derived from the target; the user accepts or edits; the ratified list is validated against the taxonomy shape, then handed to U2's synthesis. Nothing is written back to the content (A2/R2). The reference doc states plainly how each type resolves inline (KTD-3), so proposers know `human`/`advisor_judge` block rather than defer.
- **Patterns to follow:** `skills/auto-design/SKILL.md` (propose → iterate → confirm); `skills/auto-design/references/verification-taxonomy.md`.
- **Test scenarios:**
  - Covers AE1. A one-shot does not dispatch until criteria are accepted.
  - Covers AE2. An edited criterion is what lands in the baked list, not the proposed original.
  - A proposed criterion failing taxonomy validation (e.g. `programmatic` with a shell string) is rejected before baking.
  - Ratified criteria never appear on the content JSON on disk after the run (ephemeral — A2/R2).
- **Verification:** the ratified (possibly edited) criteria are the ones baked; the content file is unchanged post-run.

### U4. One-shot terminal verdict: resolve inline, aggregate, return

- **Goal:** After the content dispatches once, resolve every ratified criterion inline and return result + pass/fail verdict, then terminate.
- **Requirements:** R4. **KTDs:** KTD-1, KTD-3.
- **Dependencies:** U2, U3.
- **Files:**
  - `lib/content_oneshot.py` (modify) — `oneshot_verdict(unit, programmatic_results, judge_verdicts) -> {"verdict": "pass"|"fail", ...}` calling `verification.aggregate`; map all-pass→`pass`, any-fail→`fail` (KTD-1 re-labeling).
  - `docs/contracts/driver-reference.md` (modify §7) — document the one-shot verdict path and its boundary from the iteration gate.
  - `tests/unit/one-shot-verdict.test.sh` (create).
- **Approach:** The terminal path is read-only over the criteria — it must **not** import `iteration.py`'s decision-commit or write an iteration decision (KTD-1 boundary). It reuses `evaluate_programmatic` (in the skill, in-process) + `aggregate` only. All four criterion types are resolved before `oneshot_verdict` is called: `programmatic` in-process, `model_judge` from the dispatched agent's returned verdict, `advisor_judge`/`human` by the skill's blocking resolution (KTD-3) — so there are no `pending_judges` at verdict time.
- **Patterns to follow:** `lib/verification.py::evaluate_programmatic`/`aggregate`; `lib/iteration.py::resolve_gate_verification` for how programmatic results + judge verdicts fold into one `aggregate` call — reused *as a pattern*, not called.
- **Execution note:** Test-first on the pure mapping: given criteria + programmatic results + judge verdicts, assert all-pass→`pass` / any-fail→`fail`, with no iteration decision written.
- **Test scenarios:**
  - All programmatic criteria pass → verdict `pass`. Covers R4.
  - One programmatic criterion fails → verdict `fail`.
  - A `model_judge` verdict from the dispatched agent folds into the aggregate (pass and fail).
  - An `advisor_judge` resolution folds into the aggregate (pass and fail).
  - A `human` resolution folds in (accept → pass contribution; reject → fail).
  - No `pending_judges` remain at verdict time (all types resolve inline — KTD-3).
  - The path writes no `iteration` decision (KTD-1 boundary) — assert the unit's `dispatch_context` has no `decision` field.
- **Verification:** verdict reflects the aggregate over all four resolved types; no iteration decision committed.

### U5. The `auto-content` launch honors the content's `prompt_template`

- **Goal:** A tuned content's `prompt_template` reaches the dispatched sub-agent, so tuning travels with the content.
- **Requirements:** R4 (value realized). **KTDs:** KTD-5.
- **Dependencies:** U2, U7.
- **Files:**
  - `skills/auto-content/SKILL.md` (modify) — the launch step reads the content's `prompt_template` and folds it into the sub-agent invocation (path-bounded already at U1 load).
  - `tests/integration/content-prompt-template.test.sh` (create).
- **Approach:** Driver-side only (KTD-5) — no `adapter-ce.py`/`adapter-native.py` edit on the one-shot path, and no `adapter.review()` edit. When a content has no `prompt_template`, the launch is the plain op invocation (regression-safe). When present, the template content is folded into the launched sub-agent's prompt.
- **Patterns to follow:** `docs/contracts/driver-reference.md` §7 (the driver launch map is the site that reaches the agent); `skills/auto/SKILL.md` §4 (op→skill mapping shape).
- **Test scenarios:**
  - A content with no `prompt_template` launches the plain op invocation (regression).
  - A content with a `prompt_template` launches with the template folded into the sub-agent prompt.
  - A malformed/traversal `prompt_template` never reaches launch (rejected at U1 load — assert the skill also tolerates absence).
- **Verification:** template-less launch is unchanged; a tuned content's template reaches the sub-agent.

### U6. Legible names alias the `a1`/`a2`/`a4`/`w` shorthand

- **Goal:** Flows carry legible names; the shorthand keeps working as an alias.
- **Requirements:** R9. **KTDs:** KTD-6.
- **Dependencies:** none (independent of U1–U5, U7 — disjoint file set).
- **Files:**
  - `lib/recipes.py` (modify) — an alias table mapping legible names → stems, consulted in `resolve()`; the `A1_BUILTIN` fallback and stem files untouched.
  - `lib/recommender.py` (modify) — `_TAXONOMY` gains/maps the legible names.
  - `lib/launch-gate.py` (modify) — `SKIP_ELIGIBLE_RECIPES` recognizes the aliases.
  - `skills/auto-launch/SKILL.md` (modify) — picker prose uses legible names, shorthand shown as alias.
  - `tests/unit/recipe-aliases.test.sh` (create).
- **Approach:** Pure alias layer. Enumerate the hardcoded stem sites (KTD-6) and resolve each alias to the stem; never rename a stem or the fallback constant. Legible names (e.g. `a1`→`plan-build-review`, `a2`→`parallel-theories`, `a4`→`adversarial-pair`, `w`→`work-only`) confirmed against each recipe's description at implementation.
- **Patterns to follow:** `lib/recipes.py::resolve` (the `name == "a1"` fallback shows the exact site to guard).
- **Test scenarios:**
  - Resolving a legible name returns the same recipe as its shorthand stem. Covers R9.
  - Bare `/auto` still falls back to `A1_BUILTIN` (KTD-6).
  - `recommender` routing still routes correctly; the alias round-trips.
  - `launch-gate` skip-eligibility holds for alias and stem.
  - Every existing `a1/a2/a4/w` reference still resolves (no rename regression).
- **Verification:** alias and stem resolve identically; the corrupt-JSON fallback is unbroken.

### U7. The `auto-content` one-shot orchestrator + user entry

- **Goal:** A single skill that runs a content one-shot against a target end to end (the orchestrator of KTD-3).
- **Requirements:** R4. **Flows:** F1.
- **Dependencies:** U1, U2, U3, U4, U5.
- **Files:**
  - `skills/auto-content/SKILL.md` (finalize) — the F1 flow: name a content → load (U1) → propose/ratify (U3) → synthesize (U2) → launch once honoring `prompt_template` (U5) → resolve criteria inline + verdict (U4) → report → terminate.
  - plugin/command wiring per repo convention (mirror `auto-launch`/`auto-design` registration).
  - `tests/integration/auto-content-oneshot.test.sh` (create).
- **Approach:** The skill is the orchestrator (KTD-3); it owns the propose/ratify conversation, the single awaited dispatch, inline criterion resolution, and the result+verdict presentation. No tick, no `/goal`, no new engine logic.
- **Patterns to follow:** `skills/auto-launch/SKILL.md`, `skills/auto-design/SKILL.md` (skill surface + driver conversation shape).
- **Test scenarios:**
  - Covers F1 end to end: a built-in content runs against a target, criteria are ratified, a verdict returns, the run is terminal (no tick armed).
  - The skill refuses an unknown content name with a clear message; the message points multi-step reuse at the deferred flow arc (R-D mitigation).
  - The skill surfaces the content's output and the verdict distinctly.
- **Verification:** one-shot F1 runs green from the skill entry against a built-in content.

---

## Verification Contract

- **Programmatic (per unit):** each unit's `tests/…` file passes; the full suite (`tests/run.sh`) is green. New tests must be seen failing once before they pass (deliberate-fail smoke check).
- **Regression (locked-surface guard):** template-less launch is unchanged (U5); every existing recipe still validates and resolves (U6); the shared-leaf refactor preserves `orchestrator`'s dispatch-op guard (U1 symmetry test); no `iteration`/§11 semantics changed for looping recipes (KTD-1 boundary — assert no iteration decision written in the one-shot path).
- **Structural invariants:** a content with a `verification` field is rejected (R2); a one-shot unit has no loop machinery (KTD-3); ratified criteria are ephemeral — absent from the content file after a run (A2); the loader never imports `orchestrator.py` (KTD-2 DAG boundary — assert via `import-topology`).
- **Behavioral (F1):** the integration test arms a built-in content, ratifies a criterion, dispatches once, resolves it inline, and returns a correct pass/fail verdict with the content's output.
- **Lint/size:** repo `size-budget`, `import-topology`, and `phase-grammar` allowlists updated for new `lib/` modules; no waivers — decompose if a file crosses budget.

---

## Definition of Done

- U1–U5 and U7 landed; each unit's test scenarios pass and the full suite is green.
- One-shot F1 runs end to end from `skills/auto-content` against a built-in content: propose → ratify/edit → dispatch once → inline resolution → correct verdict → terminate (no tick armed).
- R2 is structural (content-with-verification rejected); A2 holds (criteria ephemeral); KTD-1 boundary holds (no iteration decision); KTD-2 DAG boundary holds (loader imports no `orchestrator`).
- U5 preserves template-less launch; the shared-leaf refactor preserves the dispatch-op guard.
- New contracts written: `content-format.md` (provisional); `driver-reference.md` §7 documents the one-shot verdict path and its boundary from the iteration gate.
- **U6 (R9 legible aliases) is verified independently** (alias↔stem parity, `A1_BUILTIN` fallback intact) — it does not gate the content headline; a naming bikeshed must not block sign-off on U1–U5/U7.
- Phase 2 (R3, R6, R7, R8) remains deferred and sketched below — not started.

---

## Deferred to Follow-Up Work (Phase 2 — composition, library, swap)

Fully sketched so it is ready to promote; **not** part of this plan's active scope. Phase 1 does not depend on any of it (confirmed: the one-shot resolves a content by name and synthesizes a single-unit run without container→content indirection).

- **R3 — Content library/catalog.** Promote U1's minimal loader to the full tri-tier registry (workspace → global → built-in) with `list_available` browse, mirroring `lib/recipes.py`. An `auto-content` "browse the catalog" surface.
- **R6 — `content_ref` on recipe units.** A container references a content by name instead of inline `invokes`; resolved at recipe load via U1's loader. Additive recipe-format field; `validate()` learns `content_ref XOR invokes`. This is the first *container* consumer of the split — it validates the boundary shape and lets `content-format.md` graduate from provisional to locked.
- **R7 — Hot-swap.** Design-time (edit `content_ref`) and run-time (a new `swap_content` steering verb in `lib/ledger_steering.py`, preconditioned like `force_skip`) re-point a container to another content.
- **R8 — Typed compatibility check.** The container↔content boundary typed on the slot's role; a swap that violates it is flagged (AE3), not silently applied.
- **`adapter.do_unit` `prompt_template` generalization.** So a recipe-embedded `content_ref` running through the tick (not the driver-orchestrated one-shot) also honors a content's `prompt_template` — the driver `launch_fn` reads it from the unit's `dispatch_context`. Deferred with R6 because it is only exercised when contents run inside flows.

---

## Risks & Mitigations

- **R-A. The one-shot verdict path drifts back into the iteration gate.** If an implementer wires U4 through `iteration.py`, it silently re-acquires looping/gate semantics and the "run once" guarantee dies. *Mitigation:* KTD-1 boundary is an explicit test (no iteration decision written); called out for review.
- **R-B. The op-set shared leaf drifts from the dispatch guard.** If `orchestrator` and `contents` diverge on `VALID_ADAPTER_OPS`, the validator and dispatch disagree. *Mitigation:* single shared leaf (`adapter_ops.py`) + U1 symmetry test.
- **R-C. R9 alias breaks the corrupt-JSON fallback.** Touching the `name == "a1"` site or renaming a stem breaks bare `/auto`. *Mitigation:* KTD-6 enumerates the sites; test asserts the fallback intact.
- **R-D. Content granularity confusion.** Users expect a content to hold a multi-step sequence (the plan-then-build intuition). *Mitigation:* A3 + Problem-Frame clarification name the boundary; the skill's unknown-content message points multi-step reuse at the deferred flow arc (U7).
- **R-E. Async criterion types stall the one-shot.** A `human`/`advisor_judge` criterion has no next tick to resolve on. *Mitigation:* KTD-3 resolves every type inline in the driver (blocking pause / blocking advisor consult), so no `pending_judges` survive to verdict time (U4 test).
