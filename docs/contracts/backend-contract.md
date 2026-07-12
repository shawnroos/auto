# Backend Contract (LOCKED)

> **Status: LOCKED v0.14.0 — vocabulary rename; supersedes `adapter-contract.md`
> (day-zero / v0.2.0 re-lock).** This file is the source-of-truth
> specification for the auto **backend interface**. U5 (the dispatch
> driver) and U6b (the native + CE backend implementations) build against THIS
> document. It is locked **before** either begins so they can build in parallel.
> Do not change the op set, the signatures, the caller assignments, the return
> shapes, the severity-declaration rule, or the exit-predicate constants without
> re-locking with all consumers.
>
> **Changelog — v0.14.0 (concept-vocabulary rename, U4):** renamed the contract
> and its vocabulary `adapter`→`backend` (file `adapter-contract.md` →
> `backend-contract.md`; formerly the "adapter interface", now the "backend interface").
> NO op-set / signature / severity / exit-predicate change. The persisted JSON
> keys (`adapter`, `adapter_scale`, `adapter_op`) are UNCHANGED on disk — their
> rename lands with format v2 (U6); the key names in this file show the current
> on-disk (v1) spelling. See the **Legacy keys (read-compat)** appendix, which is
> completed in U6.
>
> **Reading test:** a backend author should be able to implement a complete
> backend by reading *only* this file plus its companion `SKILL.md` — never the
> engine code, the pulse, or another backend's source. If something you need is
> not specified here, that is a contract gap; raise it, don't guess.
>
> **Relation to the ledger contract:** this file is self-contained for the
> backend surface — the load-bearing facts (severity values, the findings-write
> rule, the terminal definition) are inlined below. For the full persistence /
> concurrency spec, see `ledger-schema.md`. **If the two ever disagree on a
> shared fact, `ledger-schema.md` is authoritative** and this is the contract gap
> to report.

---

## 1. What a backend is

The auto engine is **workflow-blind**. It runs two loops — a
**plan-loop** and a **work-loop** — but it does not know how to plan, deepen,
review, or do work. It delegates every workflow-bearing action to a **backend**:
a thin shim that maps one concrete workflow (e.g. native Claude editing, or
Compound Engineering's `/ce-*` commands) onto a fixed set of **seven operations**
(six in v0.1.x; the seventh, `enumerate_plan_units`, added in the v0.2.0 re-lock).

The engine drives the loops mechanically; the backend supplies the *content* of
each step. V1 ships exactly two backends — `native` and `ce` — chosen as the
structural extremes (a bare native workflow vs. a multi-command CE workflow).

**A backend is a pure provider of operations. It NEVER writes the ledger
directly.** Backend return values flow back through the engine's recording paths
(the pulse's ledger writes; the background agent's `record_verdict`). This is what
preserves the ledger's atomic-predicate-freshness invariant by construction — an
backend that wrote the ledger itself could skip the predicate recompute. Backends
return data; the engine persists it.

---

## 2. The operations (six in v0.1.x; seven since the v0.2.0 re-lock)

Each op is a **distinct, single-step call**. There are no compound black-box
steps: the engine invokes exactly one op per pulse (for plan-loop ops) or one op
per agent (for work-loop ops), one at a time. This is what makes the loop
observable — every advance is one named op the ledger can record.

| op | signature | caller | purpose |
|----|-----------|--------|---------|
| `plan(scope)` | → `plan` | pulse (U4) | initial plan creation from a scope description |
| `deepen(plan)` | → `plan` (improved, or unchanged = no-op) | pulse (U4) | one round of plan deepening |
| `review_plan(plan)` | → `gap_set` | pulse (U4) | one plan-review pass; returns the open gaps |
| `next_plan_step(ledger)` | → `"plan"` \| `"deepen"` \| `"review_plan"` \| `"done"` | pulse (U4) | **the backend owns plan-step sequencing** — the engine never picks the next plan step |
| `do_unit(unit)` | → `dispatch_handle` | dispatcher (U10) | dispatch one work-loop unit for execution |
| `review(unit)` | → `findings[]` (each tagged on the severity scale) | background agent (U10) | review one unit and translate its workflow's output onto `blocker`\|`major`\|`minor` |
| `enumerate_plan_units(ledger)` | → PREPARE envelope (model fills `units[]`) | pulse (U4), at `plan-done` | **v0.2.0 RE-LOCK** — the producer the recipe producers read. Turns a completed/reviewed plan into a concrete work-unit list. Prepare-only (like the plan-loop ops): the model executes the prepared invocation and returns `[{id, invokes, dispatch_context?}, ...]`; the engine persists it onto the plan unit's `dispatch_context.enumerated_units` (U6), and the phase-transition producer (U5b) shapes it into ledger units. |

> **v0.2.0 contract re-lock (KTD-4).** The op set grew from six to **seven** with
> `enumerate_plan_units`. This was a deliberate re-lock, not a drift: v0.1.x had no
> in-code work-unit producer (the seam paused for off-ledger manual creation), so
> the recipe producers had no source data (feasibility F4). Both `ce` and `native`
> backends implement the new op. `next_plan_step`'s signature is UNCHANGED — N>1
> parallel plan-loops advance serialized (one per pulse), so the backend still sees
> one logical advance-stream. A `unit_id` parameter on `next_plan_step` for
> concurrent advance is the planned v0.3.0 re-lock, not V1.

### 2.1 Who calls each op (this is load-bearing for contract coherence)

The phrase "the pulse invokes one op at a time" is true only for the **plan-loop
ops**. The work-loop ops are invoked by different actors, deliberately:

- **`plan`, `deepen`, `review_plan`, `next_plan_step`** — invoked by the **pulse**
  (U4) during the plan-loop. Each pulse asks `next_plan_step(ledger)` which step is
  next, then calls that one step. The pulse does NOT hardcode the plan→deepen→review
  order; the backend does (see §4).
- **`do_unit`** — invoked by the **dispatcher** (U10), NOT the pulse. The pulse
  never dispatches work. The dispatcher decides batch size and calls `do_unit`
  for each unit in a wave; `do_unit` returns a dispatch handle the dispatcher
  uses to correlate the in-flight agent.
- **`review`** — invoked by the **background work agent** on the unit it executed.
  The agent self-writes the resulting findings through the engine's
  `record_verdict` path (the `dispatched → verdict-returned` transition). The
  backend's `review` op produces the findings; the engine records them. **The
  backend does not write findings to disk.**

A consequence: a single dispatched unit's lifecycle touches `do_unit` (at
dispatch) and `review` (at completion), but never the pulse. The pulse only ever
reads the recorded verdict and applies fixes.

### 2.2 Return shapes

| return | shape | who consumes it |
|--------|-------|-----------------|
| `plan` | **opaque to the engine** — backend-internal state (a doc path, a string, a structured object the backend alone interprets). The engine passes it back into `deepen` / `review_plan` unread. | the backend (round-trips it) |
| `gap_set` | an **array** of gap descriptors. The engine reads only its **length**: it writes `exit_predicate_result.gaps_open = len(gap_set)`. Empty array ⇒ plan gaps closed. Element shape is backend-defined (the engine never inspects elements). | the engine (length only) |
| plan-step token | one of the four string literals `"plan"`, `"deepen"`, `"review_plan"`, `"done"`. Anything else is a contract violation. | the pulse (drives the plan-loop) |
| `dispatch_handle` | an **opaque** correlation token (e.g. a Task id, an agent handle). The dispatcher uses it to track the in-flight agent; the engine never interprets its internals. | the dispatcher |
| `findings[]` | an array of `{ "severity": "blocker" \| "major" \| "minor", "note": <string> }`. This is the ONE return the engine reads semantically — it counts severities to compute the predicate. See §3. | the engine (severity counts) |

---

## 3. Severity scale & translation (load-bearing — inlined for self-containment)

There is exactly **one shared severity scale**, and it has exactly **three
values**:

```
blocker | major | minor
```

(These are the ledger's `SEVERITIES` module constant — see `ledger-schema.md` §6.
Inlined here so this contract stands alone.)

- **`blocker`** — gates the work-loop. Any open blocker keeps the loop running.
- **`major`** — gates the work-loop. Any open major keeps the loop running.
- **`minor`** — does NOT gate. Minors are allowed to ship; they are **reported at
  exit** for operator promotion (they never block the loop from finishing).

**Every backend MUST translate its own workflow's review output onto this scale.**
A workflow whose reviewer emits "P0/P1/P2/P3" or "error/warning/info" or any other
vocabulary must map each native level onto exactly one of `blocker`/`major`/`minor`
inside its `review` op, before returning `findings[]`. The engine only ever sees
the three shared values; it never sees the backend's native vocabulary.

### 3.1 The severity-declaration rule

Each backend MUST **declare** two things up front (not decide them per-call):

1. **Its severity mapping** — the static table from its native verdict vocabulary
   onto `blocker`/`major`/`minor`. This is a fixed property of the backend, not a
   per-finding judgment. (The concrete tables for `native` and `ce` are U6b's
   deliverable; this contract specifies only that a declared mapping MUST exist.)

2. **Its `adapter_scale`** — one of:
   - `"three-tier"` — the backend reliably produces all three severities.
   - `"blocker-only"` — the backend reliably produces `blocker` but its
     major/minor boundary is unreliable; the predicate then uses blocker-only
     logic for this backend.

   `adapter_scale` is recorded in the ledger so the engine's predicate evaluator
   knows which severity logic applies. For the `native` backend it is set by
   U6b's **rubric probe** (does a native reviewer tag findings consistently across
   three tiers?). For `ce` it is `"three-tier"` (CE's P-levels map cleanly).

### 3.2 Findings-write rule (R8 — closure ONLY via a fresh verdict)

This rule is inlined verbatim because a backend author MUST understand it to
implement `review` correctly:

- `findings[]` is written **ONLY** by a `review` verdict (the
  `dispatched → verdict-returned` transition). **Nothing else writes findings.**
- A new verdict **OVERWRITES** the findings array — it does not append. The array
  always reflects exactly the most recent review's view of the unit.
- A pulse applying a fix does **NOT** clear or modify findings inline. Asserting a
  defect is closed without a fresh review is forbidden. The fix is a state change
  only; stale findings remain until the next `review` overwrites them.
- Therefore closure happens only when a **re-review** returns clean findings:
  `verdict-returned →(fix)→ fixed →(re-enqueue)→ pending →(re-dispatch)→ dispatched →(review)→ verdict-returned` with new (ideally empty) findings.

For the engine-side persistence / atomicity guarantees behind this rule, see
`ledger-schema.md` §4.2 and §5 (I-1).

---

## 4. Plan-loop sequencing (`next_plan_step` owns it)

The engine does **not** know whether a given workflow deepens its plans, or how
many review passes it runs. The backend encodes that as a state machine inside
`next_plan_step(ledger)`:

- The pulse calls `next_plan_step(ledger)` at the start of each plan-loop pulse.
- The backend inspects the ledger and returns the **single next step** to run:
  `"plan"`, `"deepen"`, `"review_plan"`, or `"done"`.
- The pulse then calls exactly that one op (or, on `"done"`, ends the plan-loop).

Two illustrative sequencers (concrete logic is U6b's deliverable):

- A CE-style backend: `"plan"` → `"deepen"` → `"review_plan"` → (loop back to
  `"deepen"`/`"review_plan"` while gaps remain) → `"done"`.
- A native-style backend that has no deepen step: `"plan"` → `"review_plan"` →
  (loop `"review_plan"` while gaps remain) → `"done"`.

### 4.1 `next_plan_step` ↔ exit-predicate coherence (REQUIRED)

Two things can signal plan-loop termination: the backend's `next_plan_step`
returning `"done"`, and the engine's cached predicate showing plan gaps closed.
They MUST agree, or the loop diverges. The contract:

- `next_plan_step` is the **pure sequencer** — it decides which op runs next.
- The engine **confirms** plan-loop termination from its cached
  `exit_predicate_result` (specifically `gaps_open == 0`).
- **Coherence requirement:** once a `review_plan` round returns an **empty
  gap-set** (so the engine has written `gaps_open == 0`), `next_plan_step` MUST
  return `"done"` on its next call. A backend that keeps returning
  `"review_plan"` after gaps are closed would livelock the plan-loop.

---

## 5. Exit predicates (engine-computed constants — backend supplies inputs only)

The exit predicates are **NOT functions the backend writes.** The backend supplies
the *inputs* (findings tagged on the severity scale; the gap-set length); the
engine evaluates the predicates from its cached `exit_predicate_result`. Both
predicates are fixed constants:

- **Plan-loop exit:** the gap-set is empty — i.e. `gaps_open == 0` — which is the
  return of the last `review_plan` pass (length 0).

- **Work-loop exit:**
  ```
  blockers == 0  AND  majors == 0  AND  all_units_terminal == true
  ```
  All three conjuncts are required. The first two come from counting the
  `findings[]` the backend's `review` ops returned. The third —
  `all_units_terminal` — is an engine-computed guard that no unit is still
  `pending`, `dispatched`, or `stalled`, and no `fixed` unit is carrying a stale
  blocker/major. (Full terminal definition: a unit is terminal iff it is
  `terminal-skip`, OR it is `verdict-returned`/`fixed` with **no** open
  `blocker`/`major` finding. See `ledger-schema.md` §4.1 for the exact predicate.)

Minors never appear in either predicate — they are reported at exit, never gating.

The backend's job for the work-loop is therefore narrow and clear: **produce
correctly-severity-tagged findings.** Get the severities right and the engine's
predicate does the rest.

---

## 6. Backend author checklist

To implement a conforming backend, provide:

1. `plan(scope) -> plan` — create the initial plan (return value is opaque to the engine).
2. `deepen(plan) -> plan` — one deepening round; return the plan unchanged if the workflow has no deepen step.
3. `review_plan(plan) -> gap_set` — one review pass; return an array whose length is the open-gap count (empty ⇒ done).
4. `next_plan_step(ledger) -> token` — the plan-loop sequencer; MUST return `"done"` once `gaps_open == 0`.
5. `do_unit(unit) -> dispatch_handle` — dispatch one unit; return an opaque correlation token.
6. `review(unit) -> findings[]` — review one unit; translate the workflow's output onto `blocker`/`major`/`minor` and return `[{severity, note}, ...]`.
7. **A declared severity mapping** from the workflow's native vocabulary onto the three-value scale.
8. **A declared `adapter_scale`** (`"three-tier"` or `"blocker-only"`).

Do NOT write the ledger from any op. Return data; the engine records it.

---

## 7. Cross-references

- Ledger contract (authoritative on shared facts): `ledger-schema.md`
  — §4 (terminal definition + findings semantics), §5 (I-1/I-2/I-3 invariants),
  §6 (`SEVERITIES` and other module constants), §3 (state grammar / who-writes-what).
- Plan: `docs/plans/2026-05-21-001-feat-auto-loop-engine-plan.md`
  — U6a (this contract), U6b (the two backend implementations), U5 (the driver),
  U4 (the pulse that calls the plan-loop ops), U10 (the dispatcher that calls `do_unit`).

---

## Appendix — Legacy keys (read-compat)

The `adapter`→`backend` rename (v0.14.0, U4 of the concept-vocabulary rename)
renamed the CONTRACT and code vocabulary but deliberately did NOT change the
persisted JSON keys. The on-disk run-record and workflow keys still spell the v1
names; their rename lands with the format-v2 cutover (U6, KTD-6), which flips
every persisted literal in one unit. The key names throughout this file show the
current on-disk (v1) spelling.

| current on-disk (v1) key | v2 key (lands in U6) | where |
|---|---|---|
| `adapter` | `backend` | run-record top-level — the backend name (`ce` \| `native`) |
| `adapter_scale` | `backend_scale` | run-record top-level (`three-tier` \| `blocker-only`) |
| `adapter_op` | `backend_op` | `invokes.adapter_op` / `dispatch_context.adapter_op` |

**Shim guarantee:** old keys are accepted on read indefinitely (the format-v2
read-shim, U6, maps v1→v2 on every read); records are always WRITTEN in the
current on-disk format. This appendix is *completed* in U6 when the key table
above flips to v2 (and this contract takes a second, content version bump per
KTD-6).
- Companion authoring guide: `skills/auto-backend/SKILL.md`.
