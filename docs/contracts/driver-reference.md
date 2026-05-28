# auto driver reference (theory + edge cases)

Reference doc for the `auto-driver` and `auto` skills. The active skills
cite this file by section. Load this only when you hit an edge case the
skills don't cover inline — routine ticks should not require parsing it.

This doc absorbs content previously inlined in `skills/auto/SKILL.md`
and `skills/auto-driver/SKILL.md` so the active skills can stay small
(≤60 / ≤120 line budgets). Nothing here changes engine behavior; it's
all explanatory.

---

## 1. Prepare/execute contract

**Auto is a prepare/execute engine, not a self-driving loop.** Most
common operator trap (multiple field bugs, two separate agents).

- **The tick PREPARES.** `lib/tick.py` advances the state machine ONE
  step, writes the ledger, prints a JSON INTENT envelope telling YOU
  what to do next (e.g. `{"action": "rearm", "advance": {"step":
  "plan"}, ...}`).
- **YOU EXECUTE.** When the INTENT names a `plan_step` (`plan`,
  `deepen`, `review_plan`), YOU run the corresponding invocation
  (`/ce-plan`, `/ce-doc-review`, …). When work-loop units exist, YOU
  drive `orchestrator.dispatch_batch`. The tick does NOT dispatch
  agents, does NOT run `/ce-plan`, does NOT write verdicts.

**Re-ticking without running the prepared invocation is a no-op.**
Ticking 5x in a bash loop produces `units: []`. The ledger advances
ONLY when you feed structured results back: `ledger.set_gaps_open(N)`
after a `review_plan`, `ledger.record_verdict(...)` from each
background unit-agent, etc.

### Two specific traps

1. **The bash-loop trap.** Calling `tick.sh` in a loop just cycles the
   state machine; it never executes prepared invocations. Units stay 0.
2. **The deepen↔review livelock.** Plan-met requires `plan_step ==
   "review_plan" AND gaps_open == 0`. If you never run a real review
   and call `set_gaps_open`, `gaps_open` stays null and the plan-loop
   cycles `plan → deepen → review_plan → deepen → …` forever. The tick
   INTENT carries a `gaps_open_guard` field when you are in this state
   — surface it.

### Source of truth is the disk ledger

Every decision reads the ledger at `<repo>/.claude/auto/<run>.json`
(via `lib/ledger.py` / `lib/orchestrator.py`). A `ScheduleWakeup`-fired
tick re-injects into the same conversation, so context grows across
ticks and is **advisory only** — the ledger is the durable truth. If
context runs out, the routine continuation is a normal `/auto-resume`
(reads the ledger fresh).

### The three pieces you integrate

- **`lib/tick.py`** — one self-paced advance. Reads ledger, does ONE
  smallest-useful step, writes atomically, returns a re-arm intent
  dict on stdout. The tick CANNOT call `ScheduleWakeup` (model tool,
  not CLI). YOU read the intent and, when `action == "rearm"`, issue
  the `ScheduleWakeup(delay, prompt)` call.
- **`lib/orchestrator.py`** — `ready_units`, `dispatch_batch`,
  `converge`. Surfaces ready-and-independent units; YOU decide the
  cap. Never hardcodes concurrency.
- **`lib/ledger.py`** — disk-persisted per-unit ledger. Read
  `exit_predicate_result.met` from it; never re-derive.

---

## 2. Outcomes-gated emission (v0.3.0)

A recipe may declare an `iteration` block letting a designated gate
unit's `verdict.decision` drive the loop directly.

### How it routes

`lib/tick.py::advance_iteration_loop` fires BEFORE the predicate-met
short-circuit at the top of `_tick_body`:

- **No `iteration` block on the ledger → no-op.** A1, W, and every
  v0.2.x recipe early-return through this path with zero side effects.
- **Gate verdict `decision == "advance"`** → falls through to standard
  predicate-met flow; loop advances to `done`.
- **`decision == "iterate"` under bound** → engine calls
  `ledger.atomic_iterate_step` in ONE locked body: increments
  `iteration_attempts`, emits N sibling units via `iterate_template`
  (N from `decision_payload.emit_count`, default 1, capped at 10),
  resets the gate unit (`verdict-returned → pending`, `depends_on`
  extended, `dispatch_context.decision` cleared). Tick emits a rearm
  intent; next tick dispatches the new units.
- **`decision == "exit"` OR `"iterate"` over bound** → engine writes
  `dispatch_context.bound_override = { bound, original_decision, at }`
  on the gate unit and flips loop directly to `done` /
  `driver = "manual"`. The bound breach is a recorded decision, not
  an error — surface it from the `bound_override` audit trail when
  reporting the run's exit.

### Bounds are engine-enforced

- `bound.max_attempts` caps honored iterate count (pre-increment
  check, so Nth attempt blocked when `iteration_attempts ==
  max_attempts` on entry).
- Optional `bound.max_wall_seconds` caps cumulative ACTIVE wall-time
  (`active_wall_seconds`) — pauses don't burn budget, only
  `_tick_body`'s active duration.

A misbehaving gate agent cannot loop forever.

### Operator kill-switch

`CLAUDE_AUTO_DISABLE_ITERATION=1` makes `advance_iteration_loop`
return None — every tick proceeds as if the recipe had no `iteration`
block. Emergency rollback knob without redeploying or editing the
recipe. The decision on disk is UNTOUCHED — unsetting resumes
outcomes-gating on the next tick.

### Reading the decision

Every consumer routes through `lib/iteration.py::read_decision` /
`evaluate_decision`. The AST lint
(`tests/unit/iteration-ast-lint.test.sh`) forbids the raw `"decision"`
literal anywhere in `lib/*.py` except `lib/iteration.py` +
`lib/ledger.py` (the writer). NEVER reach into a unit's
`dispatch_context["decision"]` from the driver — the lint exists
because that's how the "plan documents a behavior the code never
wires" build-bug class keeps happening.

See `docs/contracts/recipe-format.md` §6 + §7 (recipe shape) and
`docs/contracts/ledger-schema.md` §2.1 + §2.3 (ledger fields).

---

## 3. Goal binding (every run is goaled)

- **Default goal:** the loop's own exit predicate — *until only P3
  (minor) findings remain* (no blockers AND no majors AND every unit
  terminal). This is the work-loop's `exit_predicate_result.met`
  becoming true.
- **Compound goal (operator-supplied via `--goal`):** stricter — e.g.
  *until only P3 remain AND one successful test*. Honor verbatim.
  Bind to BOTH the loop's `met` AND the operator's extra clause.

### Mechanism

Per the U9 spike: native `/goal` cannot be driven externally, so auto
uses its own Stop hook (`lib/on-stop.py`, which reads the ledger's
`exit_predicate_result` via `lib/goal-status.py`). The driver's job is
to **ensure a goal/status is active** so the engine's Stop hook holds
the session until the loop's `met` is satisfied:

- Ensure the run's ledger exists and its `exit_predicate_result` is
  legible (it always is — `lib/ledger.py` recomputes on every write,
  per invariant I-1).
- Ensure `loop.driver` reflects the live chain state the Stop hook
  reads: `"self"` while a tick chain self-paces, `"manual"` when
  paused at a seam or awaiting resume. The tick maintains this; the
  driver confirms it on arm or resume.
- Activate the goal/status so the Stop hook engages. Never let a run
  proceed un-goaled.

Never fabricate or hand-edit a status file; the ledger's recomputed
predicate is the legible state.

---

## 4. Tick intent dispatch

Each tick returns a JSON INTENT. The action's handling is phase-aware:

| `action` | phase | what the driver does |
|----------|-------|----------------------|
| `rearm`  | `plan` | issue `ScheduleWakeup(intent.delay, intent.prompt)` — plan-loop runs adapter steps inline, no background wake needed |
| `rearm`  | `work` | do NOT immediately ScheduleWakeup; yield to the harness re-invocation on next verdict. Only ScheduleWakeup with a LONG delay (1200s+) when no background work is in flight and no ready units to dispatch (genuinely stalled) |
| `stop`   | any   | chain ends; do NOT re-arm. If `reason == "predicate-met*"`, emit report; if `reason == "seam-pause"`, surface seam |
| `noop`   | any   | another live tick holds the lock (double-drive guard); do nothing; do NOT re-arm |

Never re-arm on `stop` or `noop`. Never short-poll in the work-loop —
the harness re-invokes on background verdict completion.

---

## 5. Plan-loop sequencing

While `loop_phase == "plan"` and `exit_predicate_result.met == false`,
ticks fire. Each plan-loop tick asks the active adapter
`next_plan_step(ledger)` and runs that one step (`plan` / `deepen` /
`review_plan`), then persists the executed step (`plan_step`) so the
next fresh-process tick advances instead of re-planning.

**The adapter owns plan-step sequencing — the driver never picks the
next step.** Re-arm on `rearm` until the plan predicate (`gaps_open
== 0`) closes.

---

## 6. Seam — the true pause

When the plan predicate is met:

- **Not `auto`:** the tick writes `loop_phase = "seam"`, `seam_paused
  = true`, `loop.driver = "manual"`, and returns `action == "stop"`,
  `reason == "seam-pause"`. The self-pace chain ends; the session can
  exit. Surface the plan + parallelism analysis and the resume
  options.
  - `/auto-resume continue <run>` transitions `seam → work` and arms
    a fresh tick chain.
  - `/auto-resume abort <run>` transitions `seam → done`.
- **`auto` (default in v0.4.0):** the tick that closes the plan
  predicate flips `plan → work` directly and keeps re-arming. The
  v0.4.0 default is `auto: True`; `--review-plan` opts back in to the
  pause.

### State transitions (enforced by ledger grammar)

| from | to | trigger |
|------|-----|---------|
| plan | seam | plan predicate met AND not auto |
| plan | work | plan predicate met AND auto |
| seam | work | `/auto-resume continue` |
| seam | done | `/auto-resume abort` |
| work | done | work predicate met (tick sets it) |

---

## 7. Work-loop fan-out (event-driven, not polled)

The harness re-invokes the driver automatically when a background
`Agent` finishes — that IS the natural wake signal. Do NOT
ScheduleWakeup as a sub-minute poll waiting for verdicts; that is the
polling antipattern the Agent tool explicitly forbids.

### Per-wave loop

1. `units = orchestrator.ready_units(repo, run)` — units dispatchable
   RIGHT NOW (pending, dependencies satisfied, no stalled ancestor).
2. **Decide a cap for THIS wave.** Live per-wave decision — resize
   between waves under machine pressure (16 when idle, 3 when
   grinding, 1 to serialize a probe). No fixed constant.
3. `orchestrator.dispatch_batch(repo, run, units, cap, launch_fn=...)`
   — marks up to `cap` units `pending → dispatched` and launches each
   background agent. **The agent self-writes its own verdict**
   (`ledger.record_verdict`) atomically on completion — durable the
   moment the agent finishes, independent of whether this driving
   session survives.
4. **YIELD silently after dispatch.** End the turn — do NOT
   ScheduleWakeup, do NOT loop checking the ledger. The harness
   re-invokes when the first verdict lands.
5. **On re-invocation: `orchestrator.converge(repo, run)`** — reads
   landed verdicts off disk. Partial-completion-safe: a single verdict
   landing is enough to re-enter the wave. A resumed session reads
   completed verdicts straight off the ledger and does NOT
   re-dispatch them. After converge:
   - if `exit_predicate_result.met` → exit (no wait, act immediately
     on the cached predicate)
   - if `ready_units()` returns work → dispatch the next wave (back
     to step 1)
   - if work still in flight → yield again; next verdict re-invokes
6. The ticks **apply fixes** from converged verdicts: `verdict-returned
   → fixed`. A fix does NOT clear findings (closure only via a fresh
   verdict); the unit is re-enqueued (`fixed → pending`), re-dispatched,
   re-reviewed until a fresh verdict returns clean. Loop terminates
   only when every unit reaches a clean terminal verdict.

The driver owns the batching; the tick is mechanical; the harness
owns the wake signal.

### When ScheduleWakeup IS the right mechanism

Polling is correct ONLY when activity stopped for a long period
**outside** the agentic loop — no natural harness signal. Canonical
case: rate-limit reset (next viable wake is a calendar timestamp, no
event will fire). Also: external deploy with known ETA, CI run polled
across sessions.

A work-loop wave SHOULD ScheduleWakeup only when:
- the predicate is not met,
- no background units are in flight,
- AND there is no ready work to dispatch.

That state is rare and indicates a stalled chain. Right delay is long
(1200-1800s), not 60s — the work resuming the loop is a separate
session or external event, not a near-term tick.

---

## 8. Exit — minors report

The loop exits when the tick returns `action == "stop"` with a
`predicate-met` reason and the ledger shows `loop_phase == "done"`.
**Never re-evaluate the predicate** — read
`exit_predicate_result.met` from the ledger. The tick supplies a
`report` in its stop intent; surface it.

The exit report lists the remaining minor findings for operator
promotion — minors never gate the loop (they ship), but they are
reported so the operator can promote any that are actually long-term
work. Format: per remaining minor, the unit id and the finding note.

### Non-clean exit reasons (v0.3.0)

If the ledger's top-level `exit_reason` is non-null, the loop did
NOT exit via the clean predicate-met path — `advance_iteration_loop`
raised and the F2 catches forced `loop_phase=done`. Surface this in
the exit report. Two `kind` values exist (`lib/ledger.py::ExitReason.KINDS`):

- `iteration-check-failed` — unexpected raise from
  `advance_iteration_loop` (typically malformed iteration block or
  corrupted gate verdict). Surface `error.type` + `error.message`;
  recommend inspecting the ledger's `iteration` block.
- `recipe-bug` — a `LedgerError` subclass (`UnknownUnit`,
  `InvalidTransition`, `StaleVerdict`) escaped the iteration check.
  Surface `error.type` + `error.message`; recommend inspecting the
  recipe JSON against `docs/contracts/recipe-format.md`.

`exit_reason` is the durable on-ledger record. Do not invent
additional `kind` values; the constant tuple is the contract.

---

## 9. Multi-plan batch fanout (v0.4.0)

When the hypothesis is `multi-plan`, the driver invokes
`lib/auto-spawn.py` which:

1. Creates one worktree per plan under `<host-repo>/worktrees/<slug>`
   (slug = full plan-file stem; `resolve_host_repo_root()` resolves
   the main repo even when invoked from inside a worktree).
2. Assigns ports from `[3001, 3099]` via scan-and-pick across active
   batch sidecars (no flock; provisional sidecars older than
   `CLAUDE_AUTO_PROVISIONAL_TTL` are swept).
3. Writes a `provisional` batch sidecar at
   `<shared-dir>/batches/<id>.json` (the claim record).
4. Calls `git worktree add` per plan; on any failure, rolls back
   (removes successfully-created worktrees, deletes the provisional
   sidecar) and raises.
5. Commits the sidecar (`status: "committed"`).
6. Spawns each backgrounded `/auto <plan>` via the cmux primitive
   `auto::cmux_spawn_workspace` factored out of `lib/cmux-socket.sh`.

The composite goal for the batch reads from
`sidecar.composite_intent`. `lib/on-stop.py` discovers committed
batches via the shared-dir glob and blocks Stop until every sub-run's
ledger predicate is met. Provisional sidecars are ignored by the Stop
hook so a half-built batch doesn't gate session exit.

See `docs/contracts/batch-sidecar-schema.md` for the sidecar format.

---

## 10. Invariants the driver must respect

- **Read, never re-derive.** Use `exit_predicate_result.met` and
  `all_units_terminal` straight from the ledger. Re-deriving the
  predicate in the driver is a regression — the engine recomputes it
  atomically on every write.
- **Never re-arm past completion.** Re-arm ONLY on `action ==
  "rearm"`. On `stop` or `noop`, the chain ends.
- **The driver owns the cap; the engine owns the advance.** Never
  hardcode a concurrency constant; never dispatch from the tick;
  never write verdicts from the driver.
- **Always goaled.** No `/auto` run proceeds without an active
  deliberate-stop goal/status engaging the Stop hook.
