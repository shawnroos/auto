<!--
Verification taxonomy for auto's typed-verification gates.
The criterion-type discipline is adapted from ksimback/looper's verification
rubric (MIT); auto's cross-model "council" is intentionally NOT vendored —
auto's `advisor` tool replaces it (see "advisor_judge" below).
-->

# Verification taxonomy

This file pins the **exact shape** of a typed verification criterion. It is the
contract the recipe validator (`lib/recipes.py::validate()`) enforces and the
shape the verification engine (`lib/verification.py`) consumes. The design skill
coaches users to express a gate's done-condition as a list of these criteria
instead of a vibe.

## The `verification` block

A gate's step may carry an optional `verification` array (max 16 criteria). Each
entry is a criterion object:

```
{ "id": "<unique non-empty string>", "type": "<one of the four below>", ... }
```

`type` must be one of exactly four values. An unknown `type`, an unknown key
inside a criterion, or an array longer than 16 is a validation error at recipe
**load** time (not only write time).

### 1. programmatic

A deterministic check the engine runs with no model in the loop.

```
{ "id": "tests-green", "type": "programmatic",
  "argv": ["bash", "tests/run.sh"],
  "check": "exit_zero",
  "timeout_sec": 120 }            # timeout_sec optional (default 30)
```

- `argv` — required, non-empty list of strings (no shell string; argv only).
- `check` — required, one of:
  - `"exit_zero"` — pass iff the process exits 0.
  - `{ "stdout_contains": "<substr>" }` — pass iff stdout contains the substring.
  - `{ "stdout_equals": "<string>" }` — pass iff stdout (stripped) equals it.
- `timeout_sec` — optional positive int.

Evidence (combined stdout+stderr) is captured, truncated to an 8 KB byte cap,
and decoded binary-safe.

### 2. model_judge

The dispatched work agent's own verdict (auto's existing same-model review).

```
{ "id": "reads-clean", "type": "model_judge", "rubric_ref": "..." }   # rubric_ref optional
```

### 3. advisor_judge

A stronger, transcript-aware second opinion from auto's `advisor` tool — the
in-house replacement for looper's cross-vendor council. **Driver-evaluated:**
the driving session (not a work agent) consults `advisor`, which returns *prose,
not a structured verdict* (see `docs/research/advisor-contract-spike.md`), maps
the prose to a per-criterion pass/fail, and feeds it into aggregation. No model
registry, no CLI shell-out, no cross-vendor egress.

```
{ "id": "design-sound", "type": "advisor_judge", "rubric_ref": "..." }   # rubric_ref optional
```

### 4. human

A checkpoint only a human can clear — routes through auto's pause handoff.

```
{ "id": "owner-signoff", "type": "human", "prompt": "..." }   # prompt optional
```

## How criteria become a gate decision (KTD-6)

The engine evaluates `programmatic` criteria in-process, then calls the pure
aggregator:

```
aggregate(criteria, programmatic_results, judge_verdicts) -> { signal, pending_judges }
```

`aggregate` emits a **signal** (advance/iterate/None), not the committed
iteration decision — `lib/iteration.py` is the sole owner that translates the
signal into `dispatch_context`'s decision field (a centralization enforced by
`tests/unit/iteration-ast-lint.test.sh`, which is why `verification.py` avoids
the literal "decision").

- All resolved criteria pass → `signal = "advance"`.
- Any resolved criterion fails → `signal = "iterate"` (bounded by
  `iteration.bound`; breach forces `exit`).
- Non-programmatic criteria with no supplied verdict come back as
  `pending_judges` — the driver satisfies them (`advisor_judge` by consulting
  `advisor`; `human` via the pause handoff) and feeds `{criterion_id, status}` data
  back into a single `aggregate` call. `iteration.py` then commits one
  decision write.

`aggregate` is a **pure function** — judge verdicts are data, so the signal
logic is unit-testable without a live `advisor`. The deterministic exit
predicate stays the run's single source of truth; criteria only steer the gate.
