---
title: Verification-Gate Hardening - Plan
type: feat
date: 2026-06-29
topic: verification-gate-hardening
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Verification-Gate Hardening - Plan

## Goal Capsule

- **Objective:** Make the v0.7.0 typed-verification gates actually function at runtime and close the four PR-#4 review P3s. A doc-review pass found the headline issue: `verification` is **stripped when a recipe is normalized into the ledger**, so on a real run it never reaches the gate the engine reads — the feature is currently exercised only by hand-attached in-memory test dicts. This plan adds the missing feeder, then covers the path end-to-end on a real ledger; plus the lint, doc, and audit-condition fixes.
- **Product authority:** Shawn.
- **Open blockers:** none. Design forks resolved at plan time (KTDs); the feeder-vs-test-only fork was resolved to **add the feeder**.

## Product Contract

### Summary

A hardening follow-up on v0.7.0 typed-verification gates. It (1) preserves the `verification` block through ledger normalization so it reaches the runtime gate unit (the currently-missing feeder), (2) adds an end-to-end test that drives the advisor-judge path — `resolve_gate_verification → set_verdict_decision → append_advisor_audit` — on a real on-disk ledger with an injected advisor verdict, (3) warns when `verification` is placed off the gate unit, (4) documents the `verification` field in the `auto-author-recipe` backend, and (5) corrects the §4.7 audit conditions. No new production helper; no engine-wiring of gate resolution.

### Problem Frame

The shipped gates are validated, evaluated, and unit-tested in isolation, but the doc-review found a wiring gap: `lib/ledger_core.py::_normalize_unit` rebuilds every ledger unit from a fixed key set that omits `verification`, and no emitter or init path mirrors it back. `ledger-schema.md` *claims* the field is "mirrored from the recipe unit," but no code does the mirror — the dominant from-a-plan bug class (a documented transition the code never wires). Consequently `resolve_gate_verification`, which reads the ledger gate unit, never sees criteria on a real run; the feature "works" only because the in-memory test harness hand-attaches the block. Separately: the advisor-judge driver path (`§4.7`) has no end-to-end test; the validator accepts `verification` on any unit while only the `iteration.gate_unit` is evaluated; `auto-author-recipe` never documents the field it now passes through; and §4.7's audit step is unconditional where it should fire only when a judge verdict resolved the gate.

### Requirements

- R1. `verification` survives ledger normalization — a recipe gate unit carrying `verification` retains it on the on-disk ledger unit the engine reads (the feeder), so `resolve_gate_verification` can see criteria on a real run.
- R2. The advisor-judge path (`resolve → commit decision → append audit`) is covered by an end-to-end test built on a **real on-disk ledger** (temp sandbox), using an injected advisor verdict — no live `advisor`, no new production helper.
- R3. `validate_and_lint` warns when a unit carries `verification` but is not the recipe's `iteration.gate_unit` (or the recipe declares no `iteration` block, so the criteria can never be evaluated). Warning, not hard error (KTD-2).
- R4. `auto-author-recipe`'s SKILL.md documents the optional `verification` field it now passes through, pointing at the authoritative taxonomy/contract.
- R5. `skills/auto/SKILL.md` §4.7 is corrected: the audit (`append_advisor_audit`) fires only when a **judge** verdict (advisor/model/human) resolved the gate — never for a programmatic-only gate — carries the required `subject`, and derives `classification` from the judge type rather than hardcoding `advisor-judge`. Steps 1–2 (consult `advisor`, map prose→verdict) are preserved.
- R6. The full suite stays green; new tests are additive.

### Scope Boundaries

- **Engine-enforcement** of gate resolution (tick.py auto-running criteria + committing) — declined. The path stays driver-invoked per §4.7; this plan makes the *data* reach the runtime and adds *coverage*, it does not move where the decision is made. (`tick.py` cannot call `advisor` anyway.)
- No change to the `verification` schema, `evaluate_programmatic`, or `aggregate` behavior.
- Forks (parallel loop variants) — still deferred.

### Dependencies / Assumptions

- Follow-up on the v0.7.0 surface (PR #4, `feature/auto-looper-forks`): `lib/verification.py`, `lib/iteration.py::resolve_gate_verification`, `skills/auto/SKILL.md` §4.7, `recipes/schema.json`.
- `lib/ledger_mutators.py` exposes `set_verdict_decision` (line 396) and `append_advisor_audit` (line 536, keyword-only `*, kind, subject, classification, resolution`; `subject` validated non-empty). `lib/ledger.py` re-exports both (lines 107/110) plus `init_ledger`/`read_ledger` for the test sandbox.
- `validate_and_lint` (recipes.py:843) returns a warning-string list and runs `validate()` first.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. **Additive feeder in `_normalize_unit`.** Preserve `verification` through normalization by carrying it onto the returned unit dict only when present (additive — absent on legacy/non-gate units, so existing ledgers and the 897-test baseline are unchanged). This is the minimal mirror that makes the data reach the runtime gate.
- KTD-2. **Lint-warning, not hard reject (#4).** Off-gate `verification` is surfaced by `validate_and_lint` (the warning layer `auto-author-recipe` step 2 already shows), not rejected by `validate()`. Rationale (corrected from the first draft): a `validate()` hard error would reject recipes that load fine today — the field is additive and `validate()` accepts it — violating this plan's own "no behavior change to the shipped validator." Warning is the right layer; it has a real, exercised consumer.
- KTD-3. **No new production helper; e2e tests the existing three calls.** The "fake-verdict seam" already exists — `resolve_gate_verification`'s `judge_verdicts` parameter. The e2e calls `resolve_gate_verification → set_verdict_decision → append_advisor_audit` directly with an injected verdict; it needs zero new production code. (A `commit_gate_verification` wrapper was considered and dropped: it added a write-bearing function whose only benefit was prose-tidiness in §4.7, not testability.)
- KTD-4. **Audit fires only when a judge verdict resolved the gate.** In §4.7, `append_advisor_audit` is written iff the gate carries a judge-type criterion that contributed a verdict (advisor/model/human) — never for a programmatic-only gate (which commits a signal with no audit). `classification` is derived from the judge `type`; `kind` stays `"advisor"` across all judge types (the audit `kind` enum is intentionally coarse — only `"advisor"`/`"action"` exist; judge audits reuse `"advisor"`). `subject` (already passed by the current §4.7) is required non-empty.
- KTD-5. **"Coverage," not "enforcement."** The e2e covers the deterministic `resolve→commit→audit` plumbing leg. The risk-bearing leg — the driver consulting `advisor` and mapping prose→verdict — is model behavior the harness cannot stub and stays session-verified; the plan says so rather than claiming end-to-end advisor-judge coverage.

### Sequencing

U1 (doc) and U2 (lint) are independent. U3 (feeder) unblocks U4 (the on-disk e2e + §4.7 fixes): without the feeder, the e2e would have to hand-attach `verification` and test a synthetic path. U3 → U4; U1 ∥ U2 ∥ (U3→U4).

---

## Implementation Units

### U1. Document `verification` in the auto-author-recipe backend

- **Goal:** `auto-author-recipe` documents the optional `verification` field it now passes through (R4).
- **Dependencies:** none.
- **Files:** `skills/auto-author-recipe/SKILL.md`.
- **Approach:** add a short subsection noting a gate unit may carry an optional `verification` array, that it belongs on the `iteration.gate_unit`, and pointing at `skills/auto-design/references/verification-taxonomy.md` + `docs/contracts/verification-contract.md` as authoritative. Do not restate the field rules (cite the SSOT; avoid drift).
- **Patterns to follow:** the reference-citation style already in that SKILL.md (its lint-warning surfacing note is in step 2).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** the field is documented with a pointer to the taxonomy/contract; no rule duplicated.

### U2. Lint-warning for `verification` on a non-gate unit

- **Goal:** `validate_and_lint` warns when `verification` is placed off the gate unit (R3).
- **Dependencies:** none.
- **Files:** `lib/recipes.py` (extend `validate_and_lint`), `tests/unit/recipes.test.sh`.
- **Approach:** after the existing lint checks, for each unit with a non-empty `verification`: warn when the recipe declares an `iteration` block (guarded by `isinstance(recipe.get("iteration"), dict)`) and the unit's `id` != `iteration.gate_unit`; OR when the recipe declares no `iteration` block at all (criteria can never be evaluated). Warning text names the unit and the gate (or the missing-iteration case). `validate()` untouched.
- **Patterns to follow:** the `warnings.append(...)` entries in `validate_and_lint` (recipes.py around the name-stem check, ~line 867).
- **Test scenarios:**
  - `verification` on the gate unit → no warning. (happy path)
  - `verification` on a non-gate unit, iteration block present → exactly one warning naming unit + gate. (edge)
  - `verification` present, no `iteration` block → one warning (never-evaluated). (edge)
  - two non-gate units each with `verification` → one warning each. (edge)
  - recipe with no `verification` anywhere → no new warning. (regression)
  - `validate()` still passes for all the above (warning ≠ error). (failure-path guard)
- **Verification:** the off-gate warning appears; `validate` still accepts the recipe; existing recipe tests green.

### U3. Feeder — preserve `verification` through ledger normalization

- **Goal:** `verification` survives ledger init/normalization so the runtime gate unit carries it (R1) — the missing mirror.
- **Dependencies:** none.
- **Files:** `lib/ledger_core.py` (`_normalize_unit`), `docs/contracts/ledger-schema.md` (correct the "mirrored" claim to describe the real mechanism), `tests/unit/ledger.test.sh` (or the nearest ledger-normalization unit test). (NOT `lib/emitters.py` — emitted units route through `_normalize_unit` via `lib/ledger_emitters.py`, so the one fix covers them; the emitter unit-builders don't carry `verification` anyway, so editing them is a no-op.)
- **Approach:** in `_normalize_unit`, preserve `verification` **conditionally** — append it to the built unit dict only when the source unit has it (`nu = {...}; if u.get("verification"): nu["verification"] = list(u["verification"])`). This is deliberately **NOT** the unconditional defaulted-key pattern used for `dispatch_context`/`attempt`: an unconditional `list(u.get("verification") or [])` would write `[]` onto every unit and change the shape of all 897 baseline ledgers' units. `_normalize_unit` is the only unit-rebuild point (two callers: `init_ledger`'s `norm_units` loop and `ledger_emitters._emit_units_core`); `_atomic_write` and the mutators preserve units verbatim, so preserving here is sufficient. Update `ledger-schema.md` so the verification note describes this normalization-preserve mechanism rather than an unwired "mirror."
- **Technical design (directional):** a single conditional key append after the unit dict is built — present iff the source unit carried it.
- **Patterns to follow:** the additive-key handling in `_normalize_unit` for *structure*, but NOT its unconditional defaulting — `verification` must be absent when the source lacks it (preserve the existing unit shape).
- **Test scenarios:**
  - a unit dict with `verification` → after `_normalize_unit`, the block is present and unchanged. (happy path — Covers R1)
  - a unit dict without `verification` → normalized unit has no `verification` key (not `None`, not `[]` — no shape change). (regression)
  - round-trip: `init_ledger(units=[{id, verification:[...]}], iteration={gate_unit:...})` — `init_ledger` takes a units list directly, it does not expand a recipe — then `read_ledger` → the gate unit still carries the block. (integration — Covers R1)
- **Verification:** a recipe's verification gate, taken through `init_ledger`/`read_ledger`, retains its `verification` block on disk; legacy ledgers unchanged; suite green.

### U4. §4.7 audit fixes + end-to-end advisor-judge test on a real ledger

- **Goal:** correct §4.7's audit conditions and cover the `resolve → commit → audit` plumbing end-to-end on a real on-disk ledger with an injected verdict (R2, R5).
- **Dependencies:** U3 (the on-disk gate must carry `verification`).
- **Files:** `skills/auto/SKILL.md` (§4.7), `tests/integration/verification-gate.test.sh` (add an on-disk case) or a new `tests/unit/verification-gate-commit.test.sh`, `docs/contracts/verification-contract.md` (note the audit condition).
- **Approach (§4.7 prose):** state that `append_advisor_audit` fires **only when a judge-type criterion contributed a verdict** (a programmatic-only gate commits the signal with no audit); pass the required `subject=` (e.g. `"<gate_unit_id>: <criterion id>"`); derive `classification` from the judge `type` (`advisor_judge`/`model_judge`/`human`), not a hardcoded string; keep steps 1–2 (consult `advisor`, map prose→verdict) intact. **Approach (test):** build a real ledger sandbox the way `tests/unit/advisor-audit.test.sh` / `ledger-mutators.test.sh` do (`mktemp -d` + `HOME` isolation + `init_ledger`), with a verification gate (now carried through by U3); then drive `resolve_gate_verification` → on a non-None signal `set_verdict_decision` → on a judge-resolved gate `append_advisor_audit`; assert via `read_ledger` + `iteration.read_decision`. Do NOT extend the pure in-memory `led_from` harness for the commit/audit assertions — it never touches the mutators.
- **Patterns to follow:** `tests/unit/advisor-audit.test.sh`, `tests/unit/ledger-mutators.test.sh` (on-disk sandbox); `resolve_gate_verification` (iteration.py); `set_verdict_decision` / `append_advisor_audit` (ledger_mutators.py).
- **Test scenarios:**
  - injected advisor `pass` + programmatic pass → `set_verdict_decision` commits `decision="advance"` (read back via `read_decision`); one `advisor_audit` record, `resolution="advance"`, `classification="advisor_judge"`. (happy path — Covers R2)
  - injected advisor `fail` → `decision="iterate"`; audit `resolution="iterate"`. (happy path)
  - persisted `dispatch_context.judge_verdicts` (no caller-supplied verdict) → still resolves + audits (the merge path). (edge — the underspecified case the review flagged)
  - programmatic-only gate (no judge criterion) → commits the signal, **no** audit record written. (edge — Covers R5)
  - no verdict supplied and a judge criterion pending → `resolve_gate_verification` returns `pending_judges`, nothing committed, no audit. (edge)
- **Verification:** the on-disk e2e commits the decision + writes the audit only on judge-resolved gates, with `subject` present and `classification` matching the judge type; programmatic-only writes no audit; `tests/run.sh` green.

---

## Verification Contract

| Gate | Command | Applies to | Done signal |
|---|---|---|---|
| Unit + integration tests | `bash tests/run.sh` | all | exits 0; new feeder / lint / commit-audit cases green |
| Feeder round-trip | `init_ledger` → `read_ledger` retains `verification` | U3 | gate unit on disk carries the block; legacy units unchanged |
| Recipe lint | `validate_and_lint` returns the off-gate warning | U2 | warning present off-gate; `validate` still passes |

## Definition of Done

- R1–R6 satisfied; `bash tests/run.sh` exits 0 with the new cases.
- A recipe's verification gate survives `init_ledger`/`read_ledger` with its block intact (feeder); legacy ledgers unchanged.
- The advisor-judge plumbing (`resolve → commit → audit`) is covered on a real on-disk ledger with an injected verdict, including the programmatic-only-no-audit and persisted-verdict cases; the live `advisor` consult remains session-verified by nature (documented, not claimed as covered).
- `validate_and_lint` warns on off-gate `verification`; `validate()` unchanged.
- §4.7 audits only judge-resolved gates, with `subject` and a `type`-derived `classification`, steps 1–2 preserved.
- `auto-author-recipe` documents the `verification` field with a pointer to the taxonomy/contract.
