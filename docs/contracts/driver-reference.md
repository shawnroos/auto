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

### Work-unit `adapter_op` → invocation (the model-facing dispatch label)

`orchestrator.dispatch_batch` is adapter-agnostic: it flips the unit
`pending → dispatched` and calls the driver-injected `launch_fn`; it
NEVER consults the adapter. So the DRIVER must map each work unit's
`invokes.adapter_op` to the ce skill it launches in the background
`Agent`. The CE adapter (`lib/adapter-ce.py`) exposes two work-loop ops,
and the dispatch label differs per op:

| `invokes.adapter_op` | launch this skill | used by |
|----------------------|-------------------|---------|
| `do_unit`            | `/ce-work <unit-id>` | `a1` / `w` / `pipeline` work units (the default) |
| `review`             | `/ce-code-review`    | `review.json` off-spine unit (U11) |

`review.json`'s single unit carries `adapter_op: "review"` — a work unit
that runs a single review/fix loop to a P3-only terminal verdict (the
work-loop's own exit predicate, KTD-1), so it must dispatch as
`/ce-code-review`, NOT `/ce-work`. Defaulting every work unit to
`/ce-work` would run the wrong skill for an off-spine review run. The
adapter's `do_unit()` returns `"invocation": "/ce-work %s"` and `review()`
is the PARSE half (it maps the returned findings onto the shared severity
scale); the launch label for `review` is `/ce-code-review`, set here.

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

## 11. Conversation-driven entry (v0.6.0 — `conversation-context`)

The `conversation-context` situation (lib/auto-detect.sh, U1) fires when there is
no in-flight run AND no plan, but the driver judged the **current conversation**
rich enough to route on and set `CLAUDE_AUTO_CONVERSATION_SIGNAL` before loading
the hypothesis. The envelope's `recommendation` is null — the driver computes it.

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

**The dispatch procedure (KTD-2/3/7):**
1. **Classify** the session into ONE state label from `lib/recommender.py`'s
   taxonomy (vague / clear-intent-no-plan / reviewed-plan / code-unreviewed /
   bug / what-to-improve / perf), with a confidence in [0,1].
2. **Recommend** — call the recommender:
   `python "${CLAUDE_PLUGIN_ROOT}/lib/recommender.py" <state> <confidence>`.
   It returns one JSON line: `{state, ce_step, recipe_or_entry, entry, is_spine,
   kind, confidence, escalate}`.
3. **Escalate-or-dispatch (PRE-DISPATCH GATE):** if `escalate` is true OR the
   state is ambiguous, escalate to the operator via the **pause seam** BEFORE
   dispatch — surface the candidate recommendation + why you're unsure and ask
   one `AskUserQuestion`; create NO run. This is NOT "via the gate": the advisor
   gate (PreToolUse hook) fires only once a LIVE self-driven run exists, and
   pre-dispatch there is none. Do not fabricate an `auto-resume.py pause` call
   against a run that does not exist yet.
4. **kind == "skill"** (bug→`/ce-debug`, what-to-improve→`/ce-ideate`,
   perf→`/ce-optimize`): recommend the skill command — NO auto-wrap, no run
   created (the `ce-ideate` precedent; the CE adapter has no debug/optimize op).
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
  tick to redirect, so allowing the question through is correct. The action hook
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
prompt-embedded two-seam instruction instead (KTD-5; set by the driver when it
builds the unit prompt).

> **⛔ Session-id parity — REQUIRED, UNPROVEN pre-release gate (round-1/round-2 P2).
> CI CANNOT certify the advisor gate fires; only the live parity check below can.
> Until that check is recorded green, treat BOTH gates as UNPROVEN in production.**
>
> The whole gate is load-bearing on the PreToolUse stdin `session_id` being the
> SAME string the run recorded as `driving_session_id` at arm time. The arm-time
> source is confirmed in-tree: `lib/auto.py::_driving_session_id()` reads
> `CLAUDE_CODE_SESSION_ID` (asserting `CLAUDE_CODE_CHILD_SESSION` is falsey first).
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
prompt-embedded two-seam instruction (KTD-5) covering the destructive set instead.

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
existing pause seam. v0.6.0 ships the *detection* half only — there is **no
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

`lib/tick_advance.py::detect_upstream_cluster` runs the classifier **read-only**
(any failure collapses to not-detected, so a torn verdict can never raise out of
the work-loop). On a positive detection,
`_escalate_upstream_cluster` calls `ledger.set_loop(driver="manual",
blocked_on=<message>)` — the SAME mechanism `auto-resume.py pause` uses — and
returns `seam_pause: True` so the tick short-circuits before re-stamping
`driver="self"` and re-arming (which would otherwise immediately undo the pause).
The `blocked_on` message names the upstream phase and the converging roles. From
the seam the operator revisits the upstream artifact; `/auto-resume continue`
will re-detect the same cluster and re-pause (the upstream flaw is unchanged),
so the run does not get past the cluster on its own — autonomous rebound is
v0.7.0.
