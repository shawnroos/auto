# auto driver reference (theory + edge cases)

Reference doc for the `auto-driver` and `auto` skills. The active skills
cite this file by section. Load this only when you hit an edge case the
skills don't cover inline — routine pulses should not require parsing it.

This doc absorbs content previously inlined in `skills/auto/SKILL.md`
and `skills/auto-driver/SKILL.md` so the active skills can stay small
(≤60 / ≤120 line budgets). Nothing here changes engine behavior; it's
all explanatory.

---

## 1. Prepare/execute contract

**Auto is a prepare/execute engine, not a self-driving loop.** Most
common operator trap (multiple field bugs, two separate agents).

- **The pulse PREPARES.** `lib/pulse.py` advances the state machine ONE
  step, writes the ledger, prints a JSON INTENT envelope telling YOU
  what to do next (e.g. `{"action": "rearm", "advance": {"step":
  "plan"}, ...}`).
- **YOU EXECUTE.** When the INTENT names a `plan_step` (`plan`,
  `deepen`, `review_plan`), YOU run the corresponding invocation
  (`/ce-plan`, `/ce-doc-review`, …). When work-loop units exist, YOU
  drive `dispatcher.dispatch_batch`. The pulse does NOT dispatch
  agents, does NOT run `/ce-plan`, does NOT write verdicts.

**Re-pulsing without running the prepared invocation is a no-op.**
Pulsing 5x in a bash loop produces `units: []`. The ledger advances
ONLY when you feed structured results back: `ledger.set_gaps_open(N)`
after a `review_plan`, `ledger.record_verdict(...)` from each
background unit-agent, etc.

### Two specific traps

1. **The bash-loop trap.** Calling `pulse.sh` in a loop just cycles the
   state machine; it never executes prepared invocations. Units stay 0.
2. **The deepen↔review livelock.** Plan-met requires `plan_step ==
   "review_plan" AND gaps_open == 0`. If you never run a real review
   and call `set_gaps_open`, `gaps_open` stays null and the plan-loop
   cycles `plan → deepen → review_plan → deepen → …` forever. The pulse
   INTENT carries a `gaps_open_guard` field when you are in this state
   — surface it.

### Source of truth is the disk ledger

Every decision reads the ledger at `<repo>/.claude/auto/<run>.json`
(via `lib/ledger.py` / `lib/dispatcher.py`). A `ScheduleWakeup`-fired
pulse re-injects into the same conversation, so context grows across
pulses and is **advisory only** — the ledger is the durable truth. If
context runs out, the routine continuation is a normal `/auto-resume`
(reads the ledger fresh).

### The three pieces you integrate

- **`lib/pulse.py`** — one self-paced advance. Reads ledger, does ONE
  smallest-useful step, writes atomically, returns a re-arm intent
  dict on stdout. The pulse CANNOT call `ScheduleWakeup` (model tool,
  not CLI). YOU read the intent and, when `action == "rearm"`, issue
  the `ScheduleWakeup(delay, prompt)` call.
- **`lib/dispatcher.py`** — `ready_units`, `dispatch_batch`,
  `converge`. Surfaces ready-and-independent units; YOU decide the
  cap. Never hardcodes concurrency.
- **`lib/ledger.py`** — disk-persisted per-unit ledger. Read
  `exit_predicate_result.met` from it; never re-derive.

---

## 2. Outcomes-gated emission (v0.3.0)

A recipe may declare an `iteration` block letting a designated gate
unit's `verdict.decision` drive the loop directly.

### How it routes

`lib/pulse.py::advance_iteration_loop` fires BEFORE the predicate-met
short-circuit at the top of `_pulse_body`:

- **No `iteration` block on the ledger → no-op.** A1, W, and every
  v0.2.x recipe early-return through this path with zero side effects.
- **Gate verdict `decision == "advance"`** → falls through to standard
  predicate-met flow; loop advances to `done`.
- **`decision == "iterate"` under bound** → engine calls
  `ledger.atomic_iterate_step` in ONE locked body: increments
  `iteration_attempts`, emits N sibling units via `iterate_template`
  (N from `decision_payload.emit_count`, default 1, capped at 10),
  resets the gate unit (`verdict-returned → pending`, `depends_on`
  extended, `dispatch_context.decision` cleared). Pulse emits a rearm
  intent; next pulse dispatches the new units.
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
  `_pulse_body`'s active duration.

A misbehaving gate agent cannot loop forever.

### Typed verification (v0.7.0, U4)

A gate unit may carry a typed `verification` block (criteria of kind
`programmatic` / `model_judge` / `advisor_judge` / `human` — see
`recipe-format.md` and `skills/auto-design/references/verification-taxonomy.md`).
`lib/iteration.py::resolve_gate_verification` runs the `programmatic` criteria
in-process (`lib/verification.py`) and folds them with any driver-supplied
`dispatch_context.judge_verdicts` into an advance/iterate **signal** via the
pure `verification.aggregate` (KTD-6). When non-programmatic criteria have no
supplied verdict the signal is None and `pending_judges` names them — the driver
(§ advisor gate, U5) consults the `advisor` for each `advisor_judge`, supplies
the verdicts, and the caller commits the resulting signal as the gate's
`decision` via `set_verdict_decision`. The deterministic exit predicate is
unchanged — verification only steers the gate; it never becomes a second exit
judge.

### Operator kill-switch

`CLAUDE_AUTO_DISABLE_ITERATION=1` makes `advance_iteration_loop`
return None — every pulse proceeds as if the recipe had no `iteration`
block. Emergency rollback knob without redeploying or editing the
recipe. The decision on disk is UNTOUCHED — unsetting resumes
outcomes-gating on the next pulse.

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
  reads: `"self"` while a pulse chain self-paces, `"manual"` when
  paused at a handoff or awaiting resume. The pulse maintains this; the
  driver confirms it on arm or resume.
- Activate the goal/status so the Stop hook engages. Never let a run
  proceed un-goaled.

Never fabricate or hand-edit a status file; the ledger's recomputed
predicate is the legible state.

---

## 4. Pulse intent dispatch

Each pulse returns a JSON INTENT. The action's handling is phase-aware:

| `action` | phase | what the driver does |
|----------|-------|----------------------|
| `rearm`  | `plan` | issue `ScheduleWakeup(intent.delay, intent.prompt)` — plan-loop runs backend steps inline, no background wake needed |
| `rearm`  | `work` | yield to the harness re-invocation on next verdict AND, at dispatch, arm ONE watchdog-heartbeat `ScheduleWakeup(watchdog_wakeup_delay(ledger), intent.prompt)` (delay clamped to `[60, 3600]s`) so a pulse fires even while work is in flight — a verdict landing first makes it a no-op. The LONG-delay (1200s+) ScheduleWakeup still applies when no background work is in flight and no ready units to dispatch (genuinely stalled) |
| `stop`   | any   | chain ends; do NOT re-arm. If `reason == "predicate-met*"`, emit report; if `reason == "handoff-pause"`, surface handoff |
| `noop`   | any   | another live pulse holds the lock (double-drive guard); do nothing; do NOT re-arm |

Never re-arm on `stop` or `noop`. Never short-poll in the work-loop —
the harness re-invokes on background verdict completion.

---

## 5. Plan-loop sequencing

While `loop_phase == "plan"` and `exit_predicate_result.met == false`,
pulses fire. Each plan-loop pulse asks the active backend
`next_plan_step(ledger)` and runs that one step (`plan` / `deepen` /
`review_plan`), then persists the executed step (`plan_step`) so the
next fresh-process pulse advances instead of re-planning.

**The backend owns plan-step sequencing — the driver never picks the
next step.** Re-arm on `rearm` until the plan predicate (`gaps_open
== 0`) closes.

---

## 6. Handoff — the true pause

When the plan predicate is met:

- **Not `auto`:** the pulse writes `loop_phase = "handoff"`, `handoff_paused
  = true`, `loop.driver = "manual"`, and returns `action == "stop"`,
  `reason == "handoff-pause"`. The self-pace chain ends; the session can
  exit. Surface the plan + parallelism analysis and the resume
  options.
  - `/auto-resume continue <run>` transitions `handoff → work` and arms
    a fresh pulse chain.
  - `/auto-resume abort <run>` transitions `handoff → done`.
- **`auto` (default in v0.4.0):** the pulse that closes the plan
  predicate flips `plan → work` directly and keeps re-arming. The
  v0.4.0 default is `auto: True`; `--review-plan` opts back in to the
  pause.

### State transitions (enforced by ledger grammar)

| from | to | trigger |
|------|-----|---------|
| plan | handoff | plan predicate met AND not auto |
| plan | work | plan predicate met AND auto |
| handoff | work | `/auto-resume continue` |
| handoff | done | `/auto-resume abort` |
| work | done | work predicate met (pulse sets it) |

---

## 7. Work-loop fan-out (event-driven, not polled)

The harness re-invokes the driver automatically when a background
`Agent` finishes — that IS the natural wake signal. Do NOT
ScheduleWakeup as a sub-minute poll waiting for verdicts; that is the
polling antipattern the Agent tool explicitly forbids.

### Per-wave loop

1. `units = dispatcher.ready_units(repo, run)` — units dispatchable
   RIGHT NOW (pending, dependencies satisfied, no stalled ancestor).
2. **Decide a cap for THIS wave.** Live per-wave decision — resize
   between waves under machine pressure (16 when idle, 3 when
   grinding, 1 to serialize a probe). No fixed constant.
3. `dispatcher.dispatch_batch(repo, run, units, cap, launch_fn=...)`
   — marks up to `cap` units `pending → dispatched` and launches each
   background agent. **The agent self-writes its own verdict**
   (`ledger.record_verdict`) atomically on completion — durable the
   moment the agent finishes, independent of whether this driving
   session survives.
4. **YIELD for verdicts, and arm ONE watchdog heartbeat.** End the
   turn — do NOT loop checking the ledger; the harness re-invokes when
   the first verdict lands. But ALSO arm a single fallback
   `ScheduleWakeup(watchdog_wakeup_delay(ledger), "/auto:auto-pulse
   <run>")` at dispatch. This is a watchdog heartbeat, NOT the
   sub-minute poll forbidden above: it is ONE long wakeup at ~the
   soonest in-flight `stall_threshold_seconds` (clamped to `[60,
   3600]s`), superseded the instant any verdict re-invokes the driver.
   Its job is the alive-but-wedged agent — one that never returns a
   verdict and so never re-invokes you — which `detect_and_halt_stalled`
   can only reap if a pulse actually fires while work is in flight. If a
   verdict lands first, the heartbeat pulse finds nothing past-threshold
   and is a self-cancelling no-op.
5. **On re-invocation: `dispatcher.converge(repo, run)`** — reads
   landed verdicts off disk. Partial-completion-safe: a single verdict
   landing is enough to re-enter the wave. A resumed session reads
   completed verdicts straight off the ledger and does NOT
   re-dispatch them. After converge:
   - if `exit_predicate_result.met` → exit (no wait, act immediately
     on the cached predicate)
   - if `ready_units()` returns work → dispatch the next wave (back
     to step 1)
   - if work still in flight → yield again; next verdict re-invokes
6. The pulses **apply fixes** from converged verdicts: `verdict-returned
   → fixed`. A fix does NOT clear findings (closure only via a fresh
   verdict); the unit is re-enqueued (`fixed → pending`), re-dispatched,
   re-reviewed until a fresh verdict returns clean. Loop terminates
   only when every unit reaches a clean terminal verdict.

The driver owns the batching; the pulse is mechanical; the harness
owns the wake signal.

### Stalled-node policy — reap → retry → escalate

Whenever a unit is `stalled` — put there by EITHER the watchdog-heartbeat
timeout (`detect_and_halt_stalled`) OR the death path (`reap_unit`) —
the driver applies this per stalled node:

1. **Reap the live agent (model-side).** No reaping primitive exists in
   `lib/`, so the driver owns the kill: `TaskStop` the agent, then
   `kill -TERM` its process (the reap sequence — TaskStop then SIGTERM).
2. **Clear the reap marker.** `pulse_advance.clear_reap_pending(<run>,
   <unit>)` right after issuing the kill. The `dispatched → stalled`
   flip set `reap_pending=True` to record a kill was owed; clearing it
   is the driver's confirmation it issued one.
3. **Retry or escalate on the `attempt` budget.** If
   `dispatcher.should_escalate(<unit>)` is False (`attempt < 2`) →
   `bash lib/auto-resume.py retry <run> <unit>` (`stalled → pending`,
   clears `last_error`) to re-dispatch. If True (`attempt ≥ 2`) →
   `bash lib/auto-resume.py pause <run> "<unit> wedged after 2
   attempts"` to escalate to the operator instead of looping forever
   (the §4.5-style pause handoff; `driver=manual`, resumable).

`detect_and_halt_stalled` already halts a stalled node's transitive
dependents, so the policy runs **per stalled node while independent
siblings keep advancing** — a single wedged branch never freezes the
whole wave.

**Nested `do_step` reap.** A `do_step` fan-out agent is not its own
ledger row (KTD-5), so a wedged nested agent is reaped through its
**parent** fan-out unit: the parent flips to `stalled` and its entire
fan-out wave is reaped and re-dispatched together (coarse-grained v1;
node-level reap of a single nested agent is deferred). The watch view
still surfaces the individual wedged node.

**`reap_pending` semantics.** The stalled transition sets the marker;
the driver clears it (step 2) after the kill;
`pulse_advance.units_awaiting_reap(ledger)` returns the `stalled` units
whose marker is still set. An **uncleared marker on a later pulse means
"kill owed but unconfirmed"** — a forgotten kill (and its zombie agent)
that is otherwise invisible, since the kill itself is model-side and
Python owns only the marker.

### Work-unit `backend_op` → invocation (the model-facing dispatch label)

`dispatcher.dispatch_batch` is backend-agnostic: it flips the unit
`pending → dispatched` and calls the driver-injected `launch_fn`; it
NEVER consults the backend. So the DRIVER must map each work unit's
`invokes.backend_op` to the ce skill it launches in the background
`Agent`. The CE backend (`lib/backend-ce.py`) exposes two work-loop ops,
and the dispatch label differs per op:

| `invokes.backend_op` | launch this skill | used by |
|----------------------|-------------------|---------|
| `do_step`            | `/ce-work <unit-id>` | `a1` / `w` / `pipeline` work units (the default) |
| `review`             | `/ce-code-review`    | `review.json` off-spine unit (U11) |

`review.json`'s single unit carries `backend_op: "review"` — a work unit
that runs a single review/fix loop to a P3-only terminal verdict (the
work-loop's own exit predicate, KTD-1), so it must dispatch as
`/ce-code-review`, NOT `/ce-work`. Defaulting every work unit to
`/ce-work` would run the wrong skill for an off-spine review run. The
backend's `do_step()` returns `"invocation": "/ce-work %s"` and `review()`
is the PARSE half (it maps the returned findings onto the shared severity
scale); the launch label for `review` is `/ce-code-review`, set here.

### One-shot preset verdict (v0.14.0 — driver-orchestrated, READ-ONLY)

The `auto-preset` skill runs a *preset* one-shot: it loads a preset,
dispatches its op **once**, and produces a terminal pass/fail verdict —
WITHOUT the pulse loop, a `/goal`, or any `ScheduleWakeup`. Two thin
helpers in `lib/preset_oneshot.py` back this; the skill owns all control
flow (KTD-3), and drives both through each module's CLI (`_cli`/`__main__`):

- `build_oneshot_launch(preset, repo)` — the driver-side launch
  descriptor: the preset's `backend_op`, plus the `prompt_template` body
  when the preset declares one (KTD-5 — the tuning folds at the DRIVER
  launch, never via a backend edit). The template resolves workspace-repo
  first, then the built-in root.
- `oneshot_verdict(ratified_criteria, programmatic_results, judge_verdicts)`
  — the terminal verdict. It takes the ratified criteria list **directly**
  (there is no synthesized unit). The skill resolves every ratified
  criterion **inline before** calling it (programmatic in-process;
  `model_judge` from the dispatched agent; `advisor_judge`/`human` by a
  blocking resolution), so there are no `pending_judges` at verdict time —
  a pending judge here is a caller error and raises `OneShotIncomplete`,
  never a silent pass.

**Boundary from the iteration gate (KTD-1).** `oneshot_verdict` reuses
ONLY the pure `verification.aggregate` evaluator and re-labels its
advance/iterate SIGNAL to a terminal `pass`/`fail` (all resolved pass →
`pass`; any resolved fail → `fail`; **no ratified criteria →
`unverified`**, never a silent `pass` in a gating mechanism). It is **read-only** over the
criteria: it does NOT import `lib/iteration.py`, does NOT commit an
iteration `decision`, and writes no `decision` field. This is
distinct from §2's *Reading the decision* path — that is the looping
recipe's gate-decision commit (`iteration.resolve_gate_verification` →
`set_verdict_decision`); the one-shot verdict is a terminal report that
touches neither the §11 gate-steering semantics nor the ledger's
`decision` channel. `tests/unit/import-topology.test.sh` pins the
no-`iteration`-import boundary; `tests/unit/one-shot-verdict.test.sh`
pins the no-`decision`-written boundary.

### When ScheduleWakeup IS the right mechanism

Polling is correct ONLY when activity stopped for a long period
**outside** the agentic loop — no natural harness signal. Canonical
case: rate-limit reset (next viable wake is a calendar timestamp, no
event will fire). Also: external deploy with known ETA, CI run polled
across sessions.

A work-loop wave SHOULD ScheduleWakeup with a LONG (1200-1800s) delay
when:
- the predicate is not met,
- no background units are in flight,
- AND there is no ready work to dispatch.

That state is rare and indicates a stalled chain; the work resuming the
loop is a separate session or external event, not a near-term pulse.

The one OTHER legitimate wakeup is the **watchdog heartbeat armed at
dispatch** (§7 step 4): a single `ScheduleWakeup(watchdog_wakeup_delay(
ledger), …)` per wave so a pulse can fire while work is in flight and
`detect_and_halt_stalled` can reap an alive-but-wedged agent. This is
NOT the sub-minute verdict poll: it is one long wakeup sized to the
soonest in-flight stall threshold (clamped to `[60, 3600]s`) and
superseded by any verdict re-invoke, so it costs nothing on the happy
path and only ever fires when a unit has genuinely gone past-threshold
with no verdict.

---

## 8. Exit — minors report

The loop exits when the pulse returns `action == "stop"` with a
`predicate-met` reason and the ledger shows `loop_phase == "done"`.
**Never re-evaluate the predicate** — read
`exit_predicate_result.met` from the ledger. The pulse supplies a
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
- `workflow-bug` — a `LedgerError` subclass (`UnknownUnit`,
  `InvalidTransition`, `StaleVerdict`) escaped the iteration check.
  Surface `error.type` + `error.message`; recommend inspecting the
  recipe JSON against `docs/contracts/recipe-format.md`.

`exit_reason` is the durable on-ledger record. Do not invent
additional `kind` values; the constant tuple is the contract.

---

## 9. Multi-plan batch fanout (v0.4.0; confirm-gated 2026-06; freshness-ranked v0.7.x)

The `multi-plan` hypothesis no longer auto-dispatches a fanout. After the
2026-06 misfire (a fresh session silently fanned out two stale, unrelated
plans found in `docs/plans/`), the detector sets `ambiguity` on every
`multi-plan` envelope, so the driver **asks first** (auto-driver SKILL.md
routing table): the operator either picks one plan (`auto.sh "<path>"`) or
confirms "Fan out all N". Only on a confirmed fan-out-all does the driver
invoke `lib/auto-spawn.py` with `multi_plan.paths`.

**Freshness ranking (v0.7.x, U1/U2).** The detector no longer treats discovered
plans as an unordered set. `lib/plan-rank.py` classifies each plan **fresh**
(uncommitted, or a recent commit — the one you're working on) vs **stale** (old
`docs/plans/` clutter); the freshness rule is git-opinion-wins with an mtime
fallback (see the module header). The plan step then keys on the FRESH count,
not the raw count:

- exactly **one fresh** plan (among any number of stale siblings) → `reviewed-plan`
  — the live plan is *inferred*, no ask (the 2026-06 field case: 6 plans, 1
  authored that session, lost to a fan-out ask over all six);
- **≥2 fresh** → `multi-plan` ask over the FRESH set, fan-out-all offered
  (fanning out over genuinely-live plans is legitimate);
- **all stale** → `multi-plan` ask with each option staleness-marked and the
  fan-out-all footgun **suppressed** (never offer to spawn N worktrees on old
  clutter) — OR, when the driver set `CLAUDE_AUTO_CONVERSATION_SIGNAL`, the stale
  ask is **preempted** by `conversation-context` (§11): a live session beats a
  stale plan set. A single lone plan (fresh or stale) stays `reviewed-plan` —
  one plan carries no fan-out footgun.

So `multi-plan` now fires only for genuinely-competing plans, and a
`path: null` fan-out-all option appears only when the target set is fresh.

### Ambiguity option shape (discriminated union — read the payload key by situation)

`ambiguity.options[]` carries a **situation-specific** payload key. Branch on
`situation` before reading it:

| situation | payload key | sentinel | meaning |
|-----------|-------------|----------|---------|
| `ambiguous-runs` | `run_id` (always set) | — | resume the chosen run |
| `in-flight` (stale) | `run_id` | `run_id: null` → "Start fresh" | resume the run, or `null` ⇒ drop to `raw` (ask what to work on) |
| `multi-plan` | `path` (repo-relative) | `path: null` → "Fan out all N" | run just that plan via `auto.sh "<path>"`, or `null` ⇒ fan out `multi_plan.paths` |

A null payload value is the **action sentinel** for that surface, not missing
data — `run_id: null` means start-fresh, `path: null` means fan-out-all. The
detector header (auto-detect.sh) and the auto-driver routing table both encode
this; this table is the authoritative schema.

When fanout IS confirmed, the driver invokes `lib/auto-spawn.py` which:

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
  `all_steps_terminal` straight from the ledger. Re-deriving the
  predicate in the driver is a regression — the engine recomputes it
  atomically on every write.
- **Never re-arm past completion.** Re-arm ONLY on `action ==
  "rearm"`. On `stop` or `noop`, the chain ends.
- **The driver owns the cap; the engine owns the advance.** Never
  hardcode a concurrency constant; never dispatch from the pulse;
  never write verdicts from the driver.
- **Always goaled.** No `/auto` run proceeds without an active
  deliberate-stop goal/status engaging the Stop hook.

## 11. Conversation-driven entry (v0.6.0 — `conversation-context`; wired v0.7.x U3)

The `conversation-context` situation (lib/auto-detect.sh) fires when there is no
in-flight run and no **live** plan, but the driver judged the **current
conversation** rich enough to route on and set `CLAUDE_AUTO_CONVERSATION_SIGNAL`
before loading the hypothesis. The envelope's `recommendation` is null — the
driver computes it.

**v0.7.x U3 — the signal is now actually set, and it can preempt stale plans.**
v0.6.0 shipped this branch but specified the signal-set only as prose; no
production code ever set the env var (only an integration test did), so the
branch was dead — a context-rich bare `/auto` always fell through to `raw` or a
plan ask. The auto-driver now sets it **inline** on the detector call
(`CLAUDE_AUTO_CONVERSATION_SIGNAL=1 bash …/auto-detect.sh`) whenever the session
is worth routing on. And the precedence changed: "no live plan" now includes the
case where **every discovered plan is stale** (§9) — a stale plan set no longer
blocks conversation-context. A **fresh** plan (`reviewed-plan`) still wins over
conversation; only stale clutter yields to it.

**Context sources (D2 — the split that keeps the classification honest):**
- **Current conversation** = the driver reflecting on its OWN live transcript.
  `ce-sessions` refuses the current session, so this is the agent's own read of
  what just happened, not a tool call.
- **~2-day lookback** = the `ce-sessions` discover+extract pipeline
  (`discover-sessions.sh <repo> 2` then the extract scripts). Use the EXTRACTS —
  never whole session files or thinking blocks.
- **AVOID raw compaction text** — compaction summaries may hallucinate APIs /
  decisions (`feedback_compaction_summary_may_hallucinate_apis_verify_against_git`);
  verify any claim against git/the live transcript before acting on it.

**Goal-aware plan routing reuses D2's current-transcript read, NOT the lookback.**
The goal-aware pre-step (auto-driver `SKILL.md` → `references/goal-plan-relevance-rubric.md`)
recovers the operative goal — the current `/auto` intent or a current-session
`/goal <…>` text — from the driver's own live context for **this** invocation.
The ~2-day `ce-sessions` lookback above is for session *classification* only; it
is never a goal source, so a `/goal` bound for a prior completed run is not
treated as the current goal (that would suppress today's fanout under a stale
intent). Recovery is best-effort — extracting a slash-command argument, not
classifying a session — so if a bound `/goal`'s text isn't reliably present, the
pre-step degrades to inferred/no-goal handling rather than asserting an explicit
goal. Like conversation-context, goal-aware suppression is interactive-only
(`driving_session_id` null).

**The dispatch procedure (KTD-2/3/7):**
1. **Classify** the session into ONE state label from `lib/recommender.py`'s
   taxonomy (vague / clear-intent-no-plan / reviewed-plan / code-unreviewed /
   bug / what-to-improve / perf), with a confidence in [0,1].
2. **Recommend** — call the recommender:
   `python "${CLAUDE_PLUGIN_ROOT}/lib/recommender.py" <state> <confidence>`.
   It returns one JSON line: `{state, ce_step, recipe_or_entry, entry, is_spine,
   kind, confidence, escalate}`.
3. **Escalate-or-dispatch (PRE-DISPATCH GATE):** if `escalate` is true OR the
   state is ambiguous, escalate to the operator via the **pause handoff** BEFORE
   dispatch — surface the candidate recommendation + why you're unsure and ask
   one `AskUserQuestion`; create NO run. This is NOT "via the gate": the advisor
   gate (PreToolUse hook) fires only once a LIVE self-driven run exists, and
   pre-dispatch there is none. Do not fabricate an `auto-resume.py pause` call
   against a run that does not exist yet.
4. **kind == "skill"** (bug→`/ce-debug`, what-to-improve→`/ce-ideate`,
   perf→`/ce-optimize`): recommend the skill command — NO auto-wrap, no run
   created (the `ce-ideate` precedent; the CE backend has no debug/optimize op).
5. **kind == "recipe"** (vague→`pipeline`@brainstorm, clear-intent-no-plan→`a1`@plan,
   reviewed-plan→`w`@work, code-unreviewed→`review`@work):
   a. **Author a phase goal** by performing the `auto-author-goal` procedure
      (skills/auto-author-goal) — draft `.claude/auto/goals/<slug>.md` whose
      PRIMARY criterion is auto's own exit predicate (all units terminal, only
      P3 findings remain). The authored doc is also the run's spec file.
   b. **Dispatch** the entry recipe and bind auto's OWN deterministic predicate:
      `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<goal-doc-path> --recipe <recipe_or_entry>"`.
      The recipe's `phase_order[0]` IS the entry phase (`pipeline`→brainstorm,
      `a1`→plan, `w`/`review`→work). The vague→`pipeline` dispatch enters at the
      `brainstorm` phase and auto-advances brainstorm→plan→work (the spine ships
      in this same v0.6.0 diff — §13, recipes/pipeline.json).
   c. **NEVER run native `/goal`.** Auto can neither arm nor clear a native
      model-judged goal (never-met-loop risk); the deterministic Stop-hook
      predicate armed by the run is the single source of truth (§1, §3).

## 12. Advisor gate (v0.6.0 — KTD-4/5)

During a self-driven run the driver is hands-off for the *mechanical* work the
operator types today, but **substantive design/architecture forks and
irreversible/destructive actions still escalate to the operator**. Two
`PreToolUse` hooks enforce this; both fire **only** when a live self-driven run
owns the calling session.

### Ownership predicate (the load-bearing fact)

Both hooks scan `<repo>/.claude/auto/*.json` and treat a question/command as
belonging to a live auto run iff, for some ledger:

- current phase `!= "done"` (run not finished), AND
- `driving_session_id == ` the hook's stdin `session_id` (KTD-5 — **equality**,
  not presence; the field is read defensively, absent ⇒ no match).

**Two conjuncts diverge between the hooks (deliberate). The action hook
deliberately OMITS both, because it fails CLOSED and a denied tool call does not
end the agent's turn — so any conjunct that goes false after the first fire would
self-disarm the backstop:**

- **`loop.driver == "self"` — question hook ONLY (round-1 P0).** The question
  hook keeps it: it fails OPEN, and once a run is paused/manual there is no live
  pulse to redirect, so allowing the question through is correct. The action hook
  drops it: its own `_pause_run` flips the owned run to `driver="manual"` the
  moment it blocks the first destructive command; if it coupled to
  `driver=="self"` it would self-disarm after firing once and then allow
  unlimited `rm -rf` / force-push.
- **`loop.last_beat_at` freshness (`< DRIVER_SELF_STALE_SECONDS`, 3900s) —
  question hook ONLY (round-2 P2).** The question hook keeps it as a dead-chain
  guard (stale ⇒ allow is a benign fail-OPEN). The action hook drops it because
  `_pause_run` calls `set_loop` WITHOUT `beat=True` — it does NOT re-stamp
  `last_beat_at`. So a run paused-by-backstop goes stale while the operator
  deliberates; a stale-conjunct would then read the paused run as a dead chain
  and ALLOW a second destructive command — the same self-disarm hole the driver
  omission closes, reopened through the staleness door. For a fail-CLOSED
  backstop stale⇒allow is a fail-open hole; for the fail-OPEN question gate it is
  correct. A live session whose id equals the recorded driving id IS the run to
  gate regardless of beat freshness, and pausing a genuinely-dead run is harmless
  (fail-safe).

A run paused-by-backstop must STAY armed (the action hook fails CLOSED) until an
operator runs `/auto-resume continue`. Dimension #2 (a concurrent standalone
ce-skill is never gated) is preserved by the `session_id` equality conjunct
alone, independent of the driver/staleness checks.

`session_id` equality is what cleanly **allows a concurrent standalone
`/ce-plan`** in the same worktree: it has a different session, so no ledger
matches and the gate never fires. Reads are lock-free (the atomic-rename
invariant gives a consistent snapshot). Fan-out sub-agents have their OWN
`session_id` and are out of hook scope **by design** — they carry the
prompt-embedded two-handoff instruction instead (KTD-5; set by the driver when it
builds the unit prompt).

> **⛔ Session-id parity — REQUIRED, UNPROVEN pre-release gate (round-1/round-2 P2).
> CI CANNOT certify the advisor gate fires; only the live parity check below can.
> Until that check is recorded green, treat BOTH gates as UNPROVEN in production.**
>
> The whole gate is load-bearing on the PreToolUse stdin `session_id` being the
> SAME string the run recorded as `driving_session_id` at arm time. The arm-time
> source is confirmed in-tree: `lib/auto.py::_driving_session_id()` reads
> `CLAUDE_CODE_SESSION_ID` directly. (v0.6.4 removed an earlier
> `CLAUDE_CODE_CHILD_SESSION`-falsey assertion — the harness sets that var in
> every Bash-tool subprocess, where arm/resume run, so it darkened the backstop
> on every run; it is not a driver-vs-sub-agent signal.)
> The PreToolUse-stdin half CANNOT be verified by any in-tree test — no live
> Claude Code harness runs in CI, and a synthetic test that constructs both id
> strings equal passes BY CONSTRUCTION (`advisor-gate.test.sh` injects matching
> ids into both the stdin payload and the ledger), so it proves nothing about
> whether the two identifiers share a namespace in the live harness. A mismatch
> would SILENTLY no-op BOTH gates — the question gate never redirects to the
> advisor AND the destructive backstop never recognizes the run (`_owning_run_id`
> returns None ⇒ allow), so destructive ops proceed unintercepted. This is NOT
> caught by the fail-closed design, which covers only an unavailable `deny`
> contract ("deny unavailable ⇒ pause"), NOT a session mismatch ("not my run ⇒
> allow").
>
> **REQUIRED pre-merge / pre-release step (blocking, record the result):** from
> one real `/auto` run, capture one PreToolUse stdin payload and the armed ledger,
> and assert `stdin.session_id == ` what `_driving_session_id()` recorded as
> `driving_session_id`. If they differ, switch the arm-time source in
> `lib/auto.py::_driving_session_id()` (and the stdin-read key in BOTH
> `lib/on-pretooluse-askuser.py::_read_session_id` and
> `lib/on-pretooluse-action.py::_read_stdin`) to whatever the PreToolUse payload
> actually carries. No code change is required if parity holds — this is a
> one-time empirical confirmation gate, but it MUST be recorded green before the
> gate is trusted in production.
>
> **The check is now a runnable artifact, not prose (fix-round-5).** Do NOT
> hand-eyeball it — run `bash tests/verify-session-parity.sh <captured-stdin.json>
> <repo>/.claude/auto/<run_id>.json` (capture instructions are in the script
> header). It reads the SAME `session_id` / `driving_session_id` keys the hooks
> read, prints `PASS`/`FAIL`, and exits NON-ZERO on mismatch so a release pipeline
> cannot skip it silently. It is intentionally NOT a `*.test.sh` (so the in-tree
> suite never auto-runs it / never reports a false green) and CANNOT run in CI —
> it requires a live-run capture by construction.
>
> ### Release checklist — v0.6.0 advisor-gate sign-off (BLOCKING)
>
> Tag/publish 0.6.0 ONLY after this row is recorded green. Until then, treat BOTH
> gates as NON-FUNCTIONAL in production.
>
> | Gate | How | Status |
> | --- | --- | --- |
> | Session-id parity (live) | `bash tests/verify-session-parity.sh <stdin.json> <ledger.json>` against ONE real `/auto` run | ☐ NOT YET RECORDED — requires a live operator run; cannot be certified in-tree or in CI |
>
> **Partial confirmation (2026-06-11, fix-round-3 P2 probe — NOT the live gate):**
> Two of the three load-bearing facts are now confirmed; the third still requires
> a live `/auto` run. (1) `CLAUDE_CODE_SESSION_ID` is a real, present env var in a
> live Claude Code session, holding a 36-char UUID — so `_driving_session_id()`
> reads an existing var, not a typo'd one. (2) Current Claude Code hooks docs
> (code.claude.com/docs/en/hooks) confirm PreToolUse stdin carries a `session_id`
> field and that `permissionDecision: "deny"` via `hookSpecificOutput` is
> supported. STILL UNPROVEN (the actual gate): that the stdin `session_id` *value*
> is byte-equal to the recorded `driving_session_id` at a real arm time — only the
> live capture above can certify this. Treat both gates as UNPROVEN until that
> value-equality check is recorded green.

### Question hook (`AskUserQuestion` → advisor redirect, fails OPEN)

`lib/on-pretooluse-askuser.py`. On a denied `AskUserQuestion`, the deny reason
tells the driving agent to **consult the `advisor` tool** with the question's
context and then **classify it itself** using that prose advice:

- **Mechanical clarification** (which file, formatting, an unambiguous default)
  → resolve autonomously and proceed.
- **Substantive design/architecture fork** (which architecture, is this scope
  right, a premise/positioning call) → **escalate** via
  `auto-resume.py pause <run> "<the fork>"`. When unsure between the two, **treat
  it as a fork and escalate** — the default for substantive choices is escalate,
  not auto-resolve.

The question hook **fails open**: any uncertainty (malformed ledger, absent
`driving_session_id`, internal error, or an unavailable PreToolUse `deny`
contract) degrades to allowing the question through — worst case the operator is
asked directly. Under a confirmed-unavailable `deny` contract it allows the
question but surfaces a loud `systemMessage` (never a pause).

### Action hook (`Bash`/`Write` destructive backstop, fails CLOSED)

`lib/on-pretooluse-action.py`. Because the question hook only intercepts the
decision to *ask*, a separate hook matches `Bash`/`Write` and applies a
deterministic classifier for the irreversible/destructive set, anchored to the
project's CLAUDE.md list: `git push --force`/`-f`/`--force-with-lease` (matched in
ANY flag position — `git push --force origin main` AND the canonical flag-last
`git push origin main --force`/`-f`/`--force-with-lease`; fix-round-5 P1),
`reset --hard`, the whole-tree-discard `checkout .`/`restore .` family (any
spelling whose trailing ` .` pathspec discards the working tree —
`checkout -- .`, `checkout HEAD -- .`, `restore -- .`, `restore --source=… .` —
while a scoped pathspec like `checkout -- file.py` correctly does NOT fire),
`clean -f`/`-fdx`, `branch -D`, `rm -rf`/`rm -fr`, the external-publish endpoints
`npm publish` / `gh release create`, and the irreversible `gh` subcommands that
run through the same gated Bash channel (fix-round-5 P2): `gh repo delete`,
`gh release delete`, and `gh pr merge --admin` (the `--admin` flag bypasses
branch protection / required reviews). Only the Bash `command` channel
is classified: a `Write` reaches the hook (it is wired to both tool names) but
its `content` is **deliberately NOT scanned** (round-4 P2) — classifying Write
prose against the command set false-positive-pauses the driving session's own
ce-skill doc Writes (a `/ce-plan` / `/ce-doc-review` markdown quoting `rm -rf`
as an example), nearly all false-positive cost in auto's own domain. A real
destructive operation runs through Bash, which IS gated. On a confirmed-destructive command for a confirmed live
owned run it **pauses the run unconditionally** (`set_loop driver="manual"` +
`blocked_on`) — even when the PreToolUse `deny` contract is unavailable (then it
emits a `systemMessage` instead of the deny payload, never a silent allow). The
halt is observable on the **ledger** (`driver=manual` / `blocked_on`), not the
process exit code (which always stays 0). Fail-closed scope is precise: a
malformed ledger, an unidentifiable/non-owned run, or a benign command all fall
through to allow (an unrelated internal error must not brick the tool flow).

Because this hook pauses the run it fires on (flipping it to `driver="manual"`
WITHOUT re-stamping `last_beat_at`) and a denied tool call does not end the
agent's turn, the action gate's ownership check deliberately **omits BOTH the
`driver=="self"` and the `last_beat_at` staleness conjuncts** (see the Ownership
predicate divergence above) — so it STAYS armed across a pause it caused, and
across the staleness window while the operator deliberates, and a second
destructive command from the same driving session is still denied. When it fires
it appends its own `kind="action"` audit record (see Audit).

**Documented out-of-scope residual bypasses** (NOT covered — the classifier is a
deterministic minimum-set backstop, not a sandbox): the general
flag-reorder/long-form class (`rm -vrf`, `rm --recursive --force`; only the
literal `rm -rf`/`rm -fr` are caught), refspec force-push
(`git push origin +<ref>`), compound commands (`a; rm -rf b`), and
eval/obfuscation. **GitHub MCP write tools** (`delete_file`,
`merge_pull_request`, `push_files`, `create_or_update_file`) are also an
acknowledged residual (fix-round-5 P2): they do NOT flow through the Bash
`command` channel the classifier reads (their `tool_input` carries no `command`),
and the hook is wired to the `Bash`/`Write` tool names only, so an MCP tool name
never reaches it at all. Gating MCP-write tools would be a tool-name interception
change beyond v0.6.0's detect-and-escalate scope; fan-out units carry the
prompt-embedded two-handoff instruction (KTD-5) covering the destructive set instead.

### Audit (KTD-5)

Every autonomous advisor resolution AND every fired action backstop is appended
to the ledger's `advisor_audit` list via `append_advisor_audit` (ledger-schema
§2.1) — inside the locked write so concurrent fan-out denials/verdicts cannot
clobber it. The exit report surfaces the list next to the P3 findings, so a
wrong autonomous call or a fired backstop is diagnosable. `advisor_audit` is
NEVER read by any predicate.

## 13. Upstream-cluster detection → operator escalation (v0.6.0 — KTD-6)

On a spine run, when a review verdict's findings **cluster on a single upstream
phase**, auto detects it and **escalates the cluster to the operator** via the
existing pause handoff. v0.6.0 ships the *detection* half only — there is **no
autonomous backward edge**: `loop_phase` is never moved backward, no rebound
counter, no new persisted ledger field. (The autonomous rebound is deferred to
v0.7.0.)

### The weighting — reviewer-role diversity over raw count

`lib/upstream-cluster.py` is a pure classifier. The trigger is **≥ 3 distinct
reviewer roles attributing to ONE upstream phase**, NOT a finding-count
threshold: three findings from three distinct lenses (e.g. adversarial +
feasibility + security) converging on the same upstream phase is a far stronger
signal than N same-role findings on local issues — independent lenses converging
on one root cause is what makes an upstream flaw credible. Many same-role local
findings never trigger (a single role is diversity == 1 < threshold), and
current-phase / downstream findings are excluded from the upstream set.

### Where the metadata lives

`record_verdict` normalizes findings to `{severity, note}` only, so any
reviewer-role / target-phase tag is stripped on the canonical write path.
Role-tagged findings therefore survive on the unit's `dispatch_context` (same
precedent as the iteration `decision`). The **producer** that tags review
findings with role + attributed-phase is out of scope for v0.6.0 — until a
producer populates the tags, the classifier returns "no cluster" (degrade-safe).

### Escalation (same pause mechanism, no new field)

`lib/pulse_advance.py::detect_upstream_cluster` runs the classifier **read-only**
(any failure collapses to not-detected, so a torn verdict can never raise out of
the work-loop). On a positive detection,
`_escalate_upstream_cluster` calls `ledger.set_loop(driver="manual",
blocked_on=<message>)` — the SAME mechanism `auto-resume.py pause` uses — and
returns `handoff_pause: True` so the pulse short-circuits before re-stamping
`driver="self"` and re-arming (which would otherwise immediately undo the pause).
The `blocked_on` message names the upstream phase and the converging roles. From
the handoff the operator revisits the upstream artifact; `/auto-resume continue`
will re-detect the same cluster and re-pause (the upstream flaw is unchanged),
so the run does not get past the cluster on its own — autonomous rebound is
v0.7.0.

---

## 14. Argument routing — the two entry trees (v0.7.x — U4)

Entry routing is **two disjoint trees**, not one ranking. The args path
short-circuits the detector entirely (auto-driver SKILL.md, "before loading the
hypothesis"), so `$ARGUMENTS` never reaches the situation enum:

- **Args tree** (driver, pre-detector): a plan-file path → run it
  (`auto.sh "<path> --recipe w"`); otherwise classify the string with
  `lib/verb-classify.py`.
- **Bare tree** (detector envelope): in-flight → ambiguous-runs → ranked-plans /
  conversation (§9) → raw.

**`lib/verb-classify.py` (the deterministic half).** Pre-v0.7.x the args rule
routed EVERY non-plan-file arg to `/ce-plan`, so an imperative about existing
work ("execute, review and verify the plan, then open a PR") was re-planned
instead of executed — the 2026-06 field misroute (it bit twice). The classifier
returns one of `{work | plan | both | ambiguous}`:

- `work` — a work verb (execute/run/implement/verify/review/…/open a PR) and no
  plan-creation intent → route to WORK on a discovered plan (`auto.sh "<plan>
  --recipe w"`). The args path short-circuits the detector, so the driver picks
  the plan itself — run `python lib/plan-rank.py <repo>` and take the freshest
  entry. If no plan exists, the driver (the model) decides — nothing to execute yet.
- `plan` — plan-creation intent (`plan`/`design`/…, or a creation verb + the
  noun "plan") and no work verb → `/ce-plan <ARGUMENTS>`.
- `both` — both a work verb AND plan-creation intent ("develop and implement a
  plan", "plan and ship X") → `/ce-plan <ARGUMENTS>` to create the plan, then work
  it (`--recipe w`). (NOT `auto.sh "<ARGUMENTS> --recipe a1"` — `auto.sh` needs a
  plan/spec *file*, and freeform args are not one; a1 is the bare-tree /
  conversation-context entry, where a goal doc exists.)
- `ambiguous` — no verb signal (bare topics, "make it better") → the driver
  decides; the safe default stays `/ce-plan`.

The one subtlety is a **verb** ("plan a feature" → create; "run the build") vs a
**noun object** ("execute the plan", "design a review workflow" → the words
"plan"/"review" are nouns): a verb keyword counts only when NOT immediately
preceded by an article/possessive (`_used_as_verb`). This keeps the split
deterministic (the load-bearing mandate). The residual is handed to the model:
`ambiguous`, work-with-no-plan-to-run, AND cases the keyword layer can't see —
it is **negation-blind** ("don't implement" reads as work) and can misread a
domain noun, so the driver should sanity-check a `both`/`work` result against the
literal request before arming a run. This mirrors the detector ↔ `recommender.py`
division of labor.

---

## 15. Interactive launch chooser (v0.7.0 — KTD-1/4/5/6)

Interactive `/auto` no longer dispatches the loop silently. The launch agent
(`skills/auto-launch/SKILL.md`) runs one step between situation-detection and
dispatch: it reads the session, picks (or composes) a loop shape the
deterministic router can't reach, proposes typed gates, and lets the operator
confirm — **skipping the question entirely when both the shape and its gates are
obvious.** This section is the theory; the rules themselves live in code
(`lib/launch-gate.py`) and the orchestration in the skill. Load this only when an
edge case isn't covered inline there.

### The confidence ladder (KTD-1)

The skip-vs-confirm-vs-two-step decision splits the same way `lib/recommender.py`
splits classification: the **fuzzy** half (how sure am I of the shape, and of the
gates) stays in the launch agent; the **crisp** half — which tier that maps to —
is `lib/launch-gate.py::classify_launch(...)`, a pure, IO-free function. The agent
emits two self-assessed confidences in `[0,1]` (`shape_confidence`,
`gates_confidence`) plus structural facts (`recipe_kind ∈ {builtin, custom}`, the
proposed `gate_types`, and a precomputed `router_agrees` boolean);
`classify_launch` returns `skip` / `confirm` / `two_step`. The three tiers:

- **`skip`** — proceed with no question, printing a one-line notice (R9). Permitted
  ONLY inside a tight envelope (below). This is the load-bearing safety property:
  a wrong autonomous skip (a loop the operator never saw) costs more than one extra
  question, so the bar is high and the default leans to showing the chooser.
- **`confirm`** — one `AskUserQuestion` showing the drawn shape + pick + gates;
  dispatch on confirm.
- **`two_step`** — the full chooser: step 1 confirms the shape (candidates drawn
  for contrast, recommendation highlighted, a "design new" escape hatch always
  present); on a shape override the gates are re-derived for the chosen shape (R7);
  step 2 confirms or edits the gates.

`lib/launch-gate.py` owns the exact rules and the two constants (`SKIP_BAR = 0.85`
on both dimensions, `CONFIRM_BAR = 0.70` for the settled-but-soft dimension). Do
not restate the thresholds as independent assertions elsewhere — read them from
that module. The rules, evaluated in order, are what the code enforces:

1. `recipe_kind == "custom"` → **`two_step`**. A composed loop is always drawn and
   confirmed (R4); it never skips and never single-confirms.
2. Any `gate_type ∈ {advisor_judge, human, model_judge}` → **never `skip`** (a
   non-deterministic gate is by definition not "obvious"). Note this forbids skip
   *only* — with a settled shape such a launch may still **single-confirm** (rule 4
   does not re-check for a blocking gate), and otherwise falls to `two_step`. It is
   not forced to the two-step chooser.
3. `skip` iff both confidences `≥ SKIP_BAR` **and** `recipe_kind == "builtin"`
   **and** `gate_types ⊆ {programmatic}` (empty is allowed — a1/w emit no typed
   gate) **and** `router_agrees`.
4. else `confirm` iff `recipe_kind == "builtin"` **and** exactly one dimension
   clears `SKIP_BAR` while the other clears `CONFIRM_BAR` but stays below
   `SKIP_BAR`. (If both clear `SKIP_BAR` but the skip envelope failed for some
   other reason, this does not fire — it falls through.)
5. otherwise → **`two_step`** (the bias-to-show default).

Bad inputs degrade toward safety, never toward an accidental skip: a non-numeric
or out-of-range confidence coerces to `0.0`, an unknown `recipe_kind` is treated as
`custom` (→ `two_step`), malformed `gate_types` block the rule-3 subset check, and
only the literal boolean `True` counts as `router_agrees`.

### `router_agrees` — the deterministic cross-check on skip (KTD-1)

The skip inputs are model-self-assessed, and LLM self-confidence is uncalibrated
and biased high. The structural guards (builtin ∧ programmatic-or-no-typed-gates ∧
not custom) are *necessary but not sufficient* — they can't catch a confidently
wrong shape *inside* the builtin+programmatic envelope (work that truly needs `a2`
misjudged as `a1` at `shape_confidence=0.9`). So skip carries a fourth,
**deterministic** precondition: `router_agrees` — the agent's recommended stem must
equal `lib/recommender.py`'s pick for the launch's classified state label
(`reviewed-plan`→`w`, `clear-intent-no-plan`→`a1`). The caller (the launch agent)
precomputes the boolean so `classify_launch` stays IO-free.

This is a real discriminator precisely because the router only ever reaches `a1`/`w`
and skip itself already collapses to `a1`/`w` — the router is **exactly
authoritative for the only shapes that can skip.** An agent recommending `a2`/`a4`/
custom on a `reviewed-plan` state can never match the router's `w`, so
`router_agrees` is `False` and the chooser fires instead of skipping. The float
stays the discriminator; the router corroborates it with deterministic code where
skip is possible.

### Interception point (KTD-5)

The chooser fires for interactive `/auto` exactly where the driver today picks a
*loop shape* and dispatches it — wired in `skills/auto-driver/SKILL.md`:

- **`reviewed-plan`** (was: silent `auto.sh "<path> --recipe w"`) → routes through
  `auto-launch`, which classifies the state, runs the ladder, and dispatches.
- **Freeform-not-a-plan** (`$ARGUMENTS` is a sentence, not a plan file) → was
  `/ce-plan <ARGUMENTS>`-and-end; now classifies to `clear-intent-no-plan`
  (recommend `a1`@plan) and runs the chooser, dispatching a loop. This is an
  intended behavior change (KTD-5).

It does **not** fire for `in-flight` / `ambiguous-runs` / `multi-plan` (those
select a *run*, not a loop shape — run-selection, deferred), for
`conversation-context` (self-applied silently, R11), or for `--recipe`
(`commands/auto.md` branch 2, bypassed entirely, R12).

**Interactive-only by construction (R11 / AE6).** The chooser must never reach an
`AskUserQuestion` on a self-driven or headless run. It does not lean on the
advisor gate's mid-question denial (§12): at chooser entry the launch agent checks
the same `driving_session_id` ownership signal and, when a self-driven run owns the
session (or no interactive operator is present), routes straight to silent-apply —
computing the recommendation and dispatching it with the R9 notice, never entering
the question path. So a self-driven `reviewed-plan` run silent-applies by
construction.

### Gate attachment: a1/w vs a2/a4/custom (KTD-4 — the load-bearing wiring split)

The v0.7.0 typed `verification` array rides on `iteration.gate_step`, which must
name a **declared** unit (`recipe-format.md` §6, §11). `a2`/`a4` declare structural
gate units (`judge` / `compare`); `a1`/`w` do not — their work units are emitted at
runtime by `plan_output_to_work_steps` with dynamic ids that can't be enumerated.
Adding an iteration block + gate unit to a1/w would be a new built-in topology,
which is out of scope. So gating attaches differently by shape:

- **`a1` / `w`** — **no iteration gate point.** What the chooser/notice surfaces for
  them is a *description of the inherent review-to-P3 exit predicate*
  (`blockers == 0 ∧ majors == 0 ∧ all_steps_terminal`), for visibility only — **not**
  a new `verification` block. R2's "at each gate point" is vacuously satisfied
  (a1/w have no iteration gate point). The notice names that predicate, not a literal
  programmatic check.
- **`a2` / `a4` / custom** — a declared gate unit exists, so typed `verification`
  attaches via the existing mechanism. When the operator's confirmed gates differ
  from the built-in default (or it is a custom recipe), the launch agent compiles a
  **run-scoped workspace recipe** through `auto-author-recipe`'s validation gate
  carrying the `verification` array on the gate unit, then dispatches
  `--recipe <run-scoped-name>` (see `recipe-format.md` §5, and KTD-6 below). When the
  gates are the built-in default, it dispatches the built-in directly.

This keeps the feature clear of the "plan documents a behavior the code never wires"
bug class (§2's AST lint guards the same boundary) and adds no new gate mechanism.

### Skip notice format (R9)

On a `skip` the run dispatches without a prompt but prints one non-blocking line so
the decision stays visible and auditable:

```
-> <recipe> · gate: <summary>
```

`<summary>` is shape-specific (KTD-4):

- For **a1 / w** it names the inherent review-to-P3 exit predicate, e.g.
  `-> a1 · gate: review-clean to P3` — **not** a literal programmatic check. (A
  "gate: tests green" phrasing for a1/w would misrepresent what actually gates the
  run; that wording in AE1 is illustrative shorthand for the exit predicate.)
- For **a2 / a4** with a default gate it names the gate unit's check, e.g.
  `-> a2 · gate: judge picks a winner`.

See `lib/launch-gate.py` (the ladder + `SKIP_BAR` / `CONFIRM_BAR`),
`skills/auto-launch/SKILL.md` (the agent, its §6/§6.1 compile step), and KTD-1 /
KTD-4 / KTD-5 / KTD-6 in the plan for the full rationale.

---

## 16. Phase sub-agent dispatch — the tree runtime (v0.13.0 — KTD-1)

v0.13.0 pushes the loop's context-heavy phase work DOWN into a sub-agent tree
beneath a light boss session (the goal doc + phase digests are its whole resident
context). The dispatch path does NOT change to make this happen — it is the same
`ready_units → dispatch_batch → yield → converge` cycle §7 already describes,
generalized so every phase's work descends into a disposable sub-agent that
self-writes its verdict. This section is the theory; the operational steps live in
`skills/auto/SKILL.md` §4 + §4.8.

### `launch_fn` is and REMAINS a no-op — spawning is model-side

This is the load-bearing, counterintuitive fact. Spawning a Claude sub-agent is a
MODEL-side `Agent` tool call. `dispatcher.dispatch_batch` runs inside a
`python3` subprocess and has NO access to that tool. So its injected
`launch_fn` **stays the no-op recorder** — `dispatcher._default_launch_fn`
returns `None` (`lib/dispatcher.py`), and the `dispatcher.py dispatch` CLI
path uses that default. There is deliberately no "real launcher" wired into
`dispatch_batch`; the earlier interface note about a driver-injected launcher is
superseded — U5 wires no Python launcher, because none can spawn an `Agent`.

Therefore `dispatch_batch` performs EXACTLY ONE thing: the `pending → dispatched`
ledger transition (capped, `attempt`-incrementing, Bug #8-guarded). **The boss —
a model session — issues the `Agent` spawns itself, in-turn**, exactly as the
existing work-loop fan-out spawn (§7) and the model-side reap (§7 stalled-node
policy) already operate. This is the standing "the pulse PREPARES, YOU EXECUTE"
contract (§1) applied to dispatch: `dispatch_batch` PREPARES (transitions the
ledger); the boss EXECUTES (spawns the sub-agents). No new code lands on the
dispatch path; `lib/dispatcher.py`, `lib/pulse.py`, and the ledger family are
untouched by U5.

### Convergence reads the LEDGER, never sub-agent return text

Each dispatched sub-agent self-writes its verdict via
`bash lib/ledger.py record-verdict <run> <unit> '<findings>' <attempt>` — the I-1
atomic write chokepoint — on completion. The verdict is durable the moment that
(separate) process writes it, independent of whether the boss turn that
dispatched it is still alive. `dispatcher.converge` is a pure READER (§7): a
later pulse reads the landed verdict straight off disk. So a verdict lands even
though the dispatching turn has exited — the durability property the whole tree
runtime rests on, and the reason the boss context stays flat (it never reads
sub-agent prose back in). `tests/integration/tree-dispatch.test.sh` proves this
handoff end-to-end deterministically (dispatch in one process, `record-verdict` in a
separate process, converge in a third), plus attempt-identity (Bug #6), stale
rejection (AE3 / `StaleVerdict`), the Bug #8 launch-failure guard, and the RISK-7
alive-vs-past-threshold reap boundary.

### The heartbeat still distinguishes a live boss from a dead tree (R19)

Pacing and keep-alive stay in the boss session — a sub-agent cannot self-pace
(no `ScheduleWakeup`; the spike settled this). The boss stamps `last_beat_at`
every pulse (the pulse's `beat=True` write); `lib/on-stop.py` treats a chain stale
past `DRIVER_SELF_STALE_SECONDS` (3900s) as dead. The sub-agent prompt-builder
sources its operating contract from the `describe` CLI verb (U4), not a line-range
citation into this file, so R6/R7 hold where the work actually runs.

## 17. Goal-aware plan routing — the pre-step detail (v0.11.0)

The `auto-driver` skill runs a goal-aware pre-step for the `reviewed-plan` and
`multi-plan` situations, **interactive runs only** (`driving_session_id` null —
self-driven/headless runs skip it; the confirm gate that makes it safe cannot
fire on them). The skill carries the operational skeleton; the mechanism detail
lives here so the skill stays inside its size budget. Full rubric:
`skills/auto-driver/references/goal-plan-relevance-rubric.md`.

### Step 1 — recover the goal for THIS invocation

From the context window: the typed `/auto` intent, or the text of a `/goal <…>`
bound in the current session for this invocation (explicit); else infer from the
session (advisory). Read `/goal` text ONLY — never query/run/bind/clear it. Ignore
a `/goal` bound for a prior completed run (the ~2-day `ce-sessions` lookback is for
session classification, not goal recovery). If a bound `/goal`'s text is not
reliably recoverable, degrade to inferred/no-goal.

### Step 2 — weight the plans (the fuzzy judgment)

Weight `multi_plan.paths` / `single_plan.path` against the goal using the rubric's
observable match bar: a plan matches when its stated Objective/Summary names the
goal's target outcome (NOT filename or freshness). This is the model's call;
produce the ordered list of matched plan paths, best first.

### Step 3 — route deterministically via `goal-route.py`

Hand the verdicts to the crisp router; do NOT decide the branch in prose. It owns
the routing logic and enforces the guardrails in code — it will not emit a fan-out
suppression unless the goal is `explicit` AND the run is interactive, so a
self-driven run or an inferred goal can never bypass the confirm gate (truth-tested
by `tests/unit/goal-route.test.sh`). The reason → action map the driver executes:

- `explicit-suppress` → goal-ranked pick-one `AskUserQuestion` over `ranked`
  (`path` → `auto.sh "<path>"`), `preselect` on top, **fan-out-all suppressed**
  (`suppress_fanout: true`), confirm even on a single match.
- `inferred-re-rank` → same ask over `ranked` (matches on top), `preselect` on
  top, but **keep** the fan-out-all option.
- `no-match-unchanged` / `no-goal-unchanged` / `self-driven-unchanged`
  (`action: passthrough`) → act on the detector's row unchanged (its freshness
  verdict; fan-out-all offered per its own rules).

The detector (`lib/auto-detect.py`) is untouched by this — it still emits
`reviewed-plan`/`multi-plan` on freshness; the pre-step reshapes the routing before
dispatch and never changes the detector's verdict.

### Conversation-context routing (situation `conversation-context`, §11)

Classify the session (transcript + ~2-day `ce-sessions` lookback, NOT raw
compaction) → `python lib/recommender.py <state> <confidence>`.
`escalate`/ambiguous → one `AskUserQuestion`, no run. `kind=skill` → recommend the
ce command. `kind=recipe` → `auto-author-goal` (bind auto's OWN predicate, NEVER
native `/goal`) → `bash lib/auto.sh "<goal-doc> --recipe <name>"`.
