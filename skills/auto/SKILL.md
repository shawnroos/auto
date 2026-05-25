---
name: auto
description: >
  Drive an auto run: chain the plan-loop -> seam -> work-loop using
  the self-pacing tick (lib/tick.py), the agent-managed orchestrator
  (lib/orchestrator.py), and a deliberate-stop /goal binding. Use when invoked
  via /auto, when asked to run the auto loop engine over a planned set
  of units, or when continuing an auto run after a seam or a resume. This
  skill IS the driving agent: it sets up the run, arms the tick chain, decides
  the work-loop fan-out cap per wave (resizable in flight), and reads the
  ledger's cached exit predicate to know when the loop is done. It NEVER
  re-evaluates the predicate itself.
---

# auto skill (the loop driver)

You are the **driving agent** for a auto run. The engine is split into
mechanical pieces (the tick, the ledger) and agent-driven pieces (the
orchestrator, this skill). Your job is to chain the two loops —
**plan-loop -> seam -> work-loop** — by arming the tick chain, driving the
orchestrator's fan-out in the work-loop, and honoring the seam gate. You do the
*policy*; the tick does the *mechanical advance + re-arm*.

**Source of truth is the disk ledger, never this conversation.** Every decision
you make reads the ledger at `<repo>/.claude/auto/<run>.json` (via
`lib/ledger.py` / `lib/orchestrator.py`). A `ScheduleWakeup`-fired tick
re-injects into the same conversation, so context grows across ticks and is
**advisory only** — treat the ledger as the durable truth. If context runs out,
the routine continuation is a normal `/auto-resume` (it reads the ledger
fresh).

The three pieces you integrate:

- **`lib/tick.py`** — one self-paced advance. It reads the ledger, does ONE
  smallest-useful step, writes atomically, and returns a **re-arm intent dict**
  on stdout (`{"action": "rearm" | "stop" | "noop", ...}`). The tick CANNOT call
  `ScheduleWakeup` — that is a model tool, not a CLI. **You** read the intent and,
  when `action == "rearm"`, issue the actual `ScheduleWakeup(delay, prompt)` call.
- **`lib/orchestrator.py`** — `ready_units(repo, run)`, `dispatch_batch(repo, run,
  unit_ids, cap, launch_fn=...)`, `converge(repo, run)`. The orchestrator surfaces
  ready-and-independent units; **you** decide the cap. It never hardcodes a
  concurrency constant.
- **`lib/ledger.py`** — the disk-persisted per-unit ledger; the loop's source of
  truth. Read `exit_predicate_result.met` from it; never re-derive it.

---

## 1. Goal binding (ALWAYS — there is no un-goaled run)

Before arming anything, **set a deliberate-stop goal bound to the loop's exit.**
Every `/auto` run is goaled — this guarantees deliberate-stop protection on
every run.

- **Default goal:** the loop's own exit predicate — "**until only P3 (minor)
  findings remain**" (equivalently: no blockers AND no majors AND every unit
  terminal). This is the work-loop's `exit_predicate_result.met` becoming true.
- **Compound goal (operator-supplied):** the operator may pass a stricter
  compound goal, e.g. *"until only P3 remain AND one successful test."* Honor it
  verbatim — bind the goal to BOTH the loop's `met` AND the operator's extra
  clause.

**Mechanism (per the U9 spike, referenced — not rebuilt here):** native `/goal`
cannot be driven externally, so auto uses **its own Stop hook**
(U7's `on-stop.sh`, which reads the ledger's `exit_predicate_result` via
`goal-status.sh`). Your job is **not** to build that hook — U7 owns it. Your job
is to **ensure a goal/status is active** so the engine's Stop hook holds the
session until the loop's `met` (and any compound clause) is satisfied. Concretely:

- Ensure the run's ledger exists and its `exit_predicate_result` is legible (it
  always is — `lib/ledger.py` recomputes it on every write, per invariant I-1).
- Ensure the ledger's `loop.driver` reflects the live chain state the Stop hook
  reads: `"self"` while a tick chain is self-pacing, `"manual"` when paused at a
  seam or awaiting resume. The tick maintains this; you only confirm it is set
  when you arm or resume.
- Activate the goal/status so the Stop hook engages. Do NOT let a run proceed
  un-goaled.

If the operator's goal references the loop status, the engine keeps it legible —
do not fabricate or hand-edit a status file; the ledger's recomputed predicate is
the legible state.

---

## 2. Arm the tick chain

Fire the first tick by calling **`ScheduleWakeup`** with a literal prompt:

```
ScheduleWakeup(delay=60, prompt="/auto-tick <run>")
```

`ScheduleWakeup` clamps the delay to `[60, 3600]s`. Each tick re-arms its own
successor: it returns a re-arm intent, and the model acts on it. Your handling
of the intent dict the tick returns is PHASE-AWARE:

| `action` | phase | what you do |
|----------|-------|-------------|
| `rearm`  | `plan` | issue `ScheduleWakeup(intent.delay, intent.prompt)` — the plan-loop runs adapter steps inline, no background work to wake on, so a short delay is correct |
| `rearm`  | `work` | **do NOT immediately ScheduleWakeup**; you are in the work-loop's event-driven flow. Step 5 below: yield to the harness re-invocation on the next verdict. Only ScheduleWakeup with a LONG delay (1200s+) when no background work is in flight and you have no ready units to dispatch (genuinely stalled / waiting outside the loop) |
| `stop`   | any   | chain ends; do NOT re-arm. If `reason == "predicate-met*"`, emit the report (step 6); if `reason == "seam-pause"`, surface the seam (step 4) |
| `noop`   | any   | another live tick holds the lock (double-drive guard); do nothing; do NOT re-arm |

You own policy (the batch caps, the goal, when to yield); the tick owns the
mechanical advance and tells you whether the chain continues. **Never re-arm on
`stop` or `noop`.** And in the work-loop specifically, **never short-poll** —
the harness re-invokes you on background verdict completion (see §5).

---

## 3. Plan-loop

While `loop_phase == "plan"` and `exit_predicate_result.met == false`, ticks
fire. Each plan-loop tick asks the active adapter `next_plan_step(ledger)` and
runs that one step (`plan` / `deepen` / `review_plan`), then persists the
executed step (`plan_step`) so the next fresh-process tick advances instead of
re-planning. **The adapter owns plan-step sequencing — you never pick the next
step.** You simply keep re-arming on `rearm` until the plan predicate
(`gaps_open == 0`) closes.

---

## 4. Seam (the true pause)

When the plan predicate is met:

- **Not `auto`:** the tick writes `loop_phase = "seam"`, `seam_paused = true`,
  `loop.driver = "manual"`, and returns `action == "stop"`, `reason ==
  "seam-pause"` — it does **NOT** re-arm. The self-pace chain ends and the session
  can exit. Surface the plan + parallelism analysis and the resume options. The
  run is now intentionally paused (distinct from an orphan); U7's SessionStart
  hook surfaces a resume hint.
  - `/auto-resume continue <run>` (U7) transitions `seam -> work` and arms a
    **fresh** tick chain (you re-arm the first work tick).
  - `/auto-resume abort <run>` transitions `seam -> done`.
- **`auto`:** the tick that closes the plan predicate flips `plan -> work`
  directly and keeps re-arming (no pause). Pass `--auto` to the tick so it skips
  the seam.

---

## 5. Work-loop (you drive the orchestrator's fan-out)

While `loop_phase == "work"` and `exit_predicate_result.met == false`, drive the
fan-out yourself, wave by wave. **The work-loop is event-driven, not polled.**
The Claude harness re-invokes you automatically when a background `Agent`
finishes — that IS the natural wake signal. Do NOT ScheduleWakeup as a
sub-minute poll waiting for verdicts; that is the polling antipattern the
Agent tool explicitly forbids ("when harness-tracked work finishes, you are
re-invoked automatically; do NOT sleep, poll, or proactively check").

Each wave:

1. `units = orchestrator.ready_units(repo, run)` — the units dispatchable RIGHT
   NOW (pending, dependencies satisfied, no stalled ancestor).
2. **Decide a cap for THIS wave.** The cap is a live, per-wave decision — resize
   it between waves under machine pressure (16 when idle, 3 when grinding, 1 to
   serialize a probe). There is no fixed constant.
3. `orchestrator.dispatch_batch(repo, run, units, cap, launch_fn=...)` — marks up
   to `cap` units `pending -> dispatched` and launches each background agent.
   **The agent self-writes its own verdict** (`ledger.record_verdict`) atomically
   on completion — the verdict is durable the moment the agent finishes,
   independent of whether this driving session survives. Your `launch_fn` wraps an
   `Agent` `run_in_background` dispatch whose prompt instructs the agent to call
   `record_verdict` when done.
4. **YIELD silently after dispatch.** When the wave is dispatched and you have
   nothing else to do this turn, end the turn — do NOT ScheduleWakeup, do NOT
   loop checking the ledger. The harness re-invokes you when the first verdict
   lands. On re-invocation, fall through to step 5.
5. **On re-invocation: `orchestrator.converge(repo, run)`** — **reads** landed
   verdicts off disk (a reconcile/read step, never the verdict-writer). It is
   partial-completion-safe: a single verdict landing is enough to re-enter the
   wave. A resumed session reads completed verdicts straight off the ledger and
   does NOT re-dispatch them. After converge:
   - if `exit_predicate_result.met` → exit (step 6 — no wait, you act immediately
     on the cached predicate)
   - if `ready_units()` returns work → dispatch the next wave (back to step 1)
   - if work is still in flight → yield again (step 4); the next verdict will
     re-invoke you
6. The ticks **apply fixes** from converged verdicts: `verdict-returned -> fixed`.
   A fix does NOT clear findings (R8 — closure only via a fresh verdict); the
   unit is re-enqueued (`fixed -> pending`), re-dispatched, and re-reviewed until
   a fresh verdict returns clean. The loop terminates only when every unit
   reaches a clean terminal verdict.

You own the batching; the tick is mechanical; the harness owns the wake signal.

### When ScheduleWakeup IS the right mechanism (the long-tail fallback)

Polling is correct ONLY when activity has stopped for a long period **outside**
the agentic loop — that is, when no natural harness signal will wake you. The
canonical case: a rate-limit reset (the next viable wake time is a calendar
timestamp, no event will fire). Other examples: an external deploy with a
known ETA, a CI run polled across sessions.

Per the ScheduleWakeup tool's own description: short-interval wakeups for
"polling background work you started" are explicitly wasted — the harness
re-invokes on completion. Long-tail wakeups (1200s+, calibrated to the wake
event) are the legitimate use. If you find yourself reaching for
ScheduleWakeup(60s) in the work-loop, the answer is to yield to the harness
instead.

A work-loop wave SHOULD ScheduleWakeup only when:
- the predicate is not met,
- no background units are in flight (nothing for the harness to re-invoke on),
- AND there is no ready work to dispatch.

That state is rare and indicates a stalled chain. The right delay is long
(1200-1800s), not 60s — the work that would resume the loop is a separate
session or an external event, not a near-term tick.

**State transitions you drive (enforced by the ledger grammar):**

| from | to | trigger |
|------|-----|---------|
| plan | seam | plan predicate met AND not auto |
| plan | work | plan predicate met AND auto |
| seam | work | `/auto-resume continue` |
| seam | done | `/auto-resume abort` |
| work | done | work predicate met (tick sets it) |

---

## 6. Exit — emit the minors report (R6)

The loop exits when the tick returns `action == "stop"` with a `predicate-met`
reason and the ledger shows `loop_phase == "done"`. **You NEVER re-evaluate the
predicate** — read `exit_predicate_result.met` from the ledger (the cached field;
honoring the loop-monitor terminal-state rule). The tick supplies a `report` in
its stop intent; surface it.

The exit report lists the **remaining minor findings** for operator promotion —
minors never gate the loop (they ship), but they are reported so the operator can
promote any that are actually long-term work. Format: per remaining minor, the
unit id and the finding note.

---

## Invariants you must respect

- **Read, never re-derive.** Use `exit_predicate_result.met` and
  `all_units_terminal` straight from the ledger. Re-deriving the predicate in the
  driver is a regression — the engine recomputes it atomically on every write.
- **Never re-arm past completion.** Re-arm ONLY on `action == "rearm"`. On `stop`
  or `noop`, the chain ends.
- **You own the cap; the engine owns the advance.** Never hardcode a concurrency
  constant; never dispatch from the tick; never write verdicts from the driver.
- **Always goaled.** No `/auto` run proceeds without an active deliberate-stop
  goal/status engaging the engine's Stop hook.
