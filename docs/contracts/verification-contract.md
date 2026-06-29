# Contract: typed verification gates (v0.7.0, LOCKED)

Status: **LOCKED** (v0.7.0, U8). Changes here are breaking — bump and migrate.

Typed verification lets a recipe gate unit carry checkable done-conditions that
steer the gate's advance/iterate decision. It is **additive**: a unit without a
`verification` block behaves exactly as pre-v0.7.0 (a1/a2/a4/w unaffected). It
never replaces auto's deterministic exit predicate — verification only steers a
gate; the predicate (`blockers == 0 AND majors == 0 AND all_units_terminal`,
i.e. "only P3 findings remain") stays the run's single source of truth.

## 1. The `verification` block

A unit MAY carry `verification`: an array of **≤ 16** criteria. Each criterion:

```
{ "id": "<unique non-empty string>", "type": "<one of four>", ... }
```

Validated at recipe **load** time by `lib/recipes.py::validate()` (hand-rolled,
no pip — install-anywhere). Rejected: an unknown `type`, an unknown key for the
criterion's type (per-type key sets, not a flat union), a duplicate `id`, an
array over the cap.

| `type` | required fields | optional fields | evaluated by |
|---|---|---|---|
| `programmatic` | `argv` (non-empty list[str]), `check` | `timeout_sec` (positive int) | engine, in-process |
| `model_judge` | — | `rubric_ref` (str) | driver / work agent |
| `advisor_judge` | — | `rubric_ref` (str) | driver (consults `advisor`) |
| `human` | — | `prompt` (str) | driver (pause seam) |

`check` is one of: `"exit_zero"` | `{"stdout_contains": str}` | `{"stdout_equals": str}`.

## 2. Programmatic evaluation (`lib/verification.py`)

`evaluate_programmatic(criterion, cwd) -> {criterion_id, status, evidence}`:
runs `argv` via subprocess with `timeout_sec` (default 30s), captures combined
stdout+stderr, applies `check`. `status` ∈ `pass`/`fail`. `evidence` is the
combined output truncated to an **8192-byte** cap, decoded binary-safe
(`errors="replace"`). A timeout or a non-existent binary is a `fail` with
descriptive evidence — `evaluate_programmatic` NEVER raises.

## 3. Aggregation — signal, not decision (KTD-6)

`aggregate(criteria, programmatic_results, judge_verdicts) -> {signal, pending_judges}`
is a **pure** function:

- `pending_judges`: ids of non-programmatic criteria with no supplied verdict.
  Non-empty → `signal` is `None` (the gate cannot decide yet).
- else `signal`: `"advance"` if every resolved criterion passed, `"iterate"` if
  any failed. The engine's bound logic (`iteration.bound`), not `aggregate`,
  turns a persistent `iterate` into `exit`.

The key is `signal`, deliberately **not** `decision`: the iteration-decision
field literal is centralized to the decision-owning modules
(`tests/unit/iteration-ast-lint.test.sh`). `lib/iteration.py` owns the
translation from signal to the committed `dispatch_context.decision`.

## 4. Resolution + commit (the single write)

`lib/iteration.py::resolve_gate_verification(ledger, gate_unit_id, *, repo_root,
judge_verdicts)` runs the programmatic criteria, folds in `judge_verdicts` (the
arg, plus any persisted on `dispatch_context.judge_verdicts`), and returns
`{signal, pending_judges, programmatic_results}` — **no ledger write**. The
caller commits a non-None signal as the gate decision via **exactly one**
`ledger_mutators.set_verdict_decision` call. Driver-side advisor-judging is
`skills/auto/SKILL.md` §4.7.

## 5. Invariants

- The `verification` block is additive; absent → pre-v0.7.0 behavior.
- `aggregate` is pure (judge verdicts are data) → unit-testable without a live
  `advisor`.
- Exactly one decision write per gate resolution (no double-write).
- The deterministic exit predicate is never re-derived by verification.
- No model registry, no CLI shell-out, no cross-vendor egress — `advisor` is the
  whole cross-model surface.
