# Ledger Schema Contract (LOCKED)

> **Status: LOCKED day-zero contract.** This file is the source-of-truth
> specification for the auto per-unit ledger. U4 (tick), U6a/U6b
> (adapters), U7 (hooks), and U10 (orchestrator) build against THIS document.
> `lib/ledger.py` is the canonical implementation; this spec is authoritative
> if the two ever disagree. Do not change the JSON shape, the invariants, the
> state grammar, or the module constants without re-locking with all consumers.
>
> **Reading test:** a unit author should be able to implement their unit by
> reading *only* this file — never `lib/ledger.py`. If something you need is
> not specified here, that is a contract gap; raise it, don't guess.

---

## 1. Location & keying

The ledger is a JSON file on disk, one file per run:

```
<repo>/.claude/auto/<run-slug>.json    # the ledger
<repo>/.claude/auto/<run-slug>.lock    # the flock file (read-modify-write guard)
```

- `<repo>` is the git repository root (the run's home directory).
- `<run-slug>` is the `run_id` passed through `slugify_branch` (vendored from
  claude-modes `lib/validate-mode-name.sh`; see §7). The slug is a filesystem-safe
  rendering: characters outside `[A-Za-z0-9_-]` become `-`, runs of `-` collapse,
  leading/trailing `-` are stripped; empty / `.` / `..` / `..`-containing slugs are
  rejected.
- It lives under `.claude/auto/`, **NOT** `.claude/modes/` (modes-owned).
- Directory and files are created with mode `0700` (dir) / `0600` (files).

`lib/ledger.py` exposes the path helpers so consumers never hardcode the layout:

```
ledger_path(repo_root, run_id)  -> "<repo>/.claude/auto/<run-slug>.json"
lock_path(repo_root, run_id)    -> "<repo>/.claude/auto/<run-slug>.lock"
```

Both take the raw `run_id` and slugify internally — pass the run_id, not a slug.

---

## 2. Concrete schema

This is the exact on-disk JSON. Field order is not significant; presence and
type are. `<iso>` denotes an ISO-8601 UTC timestamp string (e.g.
`2026-05-21T14:03:00Z`) or `null` when unset.

```json
{
  "run_id": "feat-foo-2026-05-21",
  "loop_phase": "plan",
  "plan_step": null,
  "seam_paused": false,
  "adapter": "ce",
  "adapter_scale": "three-tier",
  "exit_predicate_result": {
    "met": false,
    "blockers": 1,
    "majors": 2,
    "minors": 5,
    "gaps_open": 0,
    "all_units_terminal": false
  },
  "units": [
    {
      "id": "U1",
      "state": "verdict-returned",
      "depends_on": [],
      "dispatched_at": "2026-05-21T14:00:00Z",
      "verdict_at": "2026-05-21T14:02:00Z",
      "stall_threshold_seconds": 600,
      "last_error": null,
      "attempt": 0,
      "findings": [
        { "severity": "major", "note": "..." }
      ]
    }
  ],
  "loop": {
    "driver": "self",
    "last_beat_at": "2026-05-21T14:02:00Z"
  }
}
```

### 2.1 Top-level fields

| field | type | values / meaning |
|-------|------|------------------|
| `run_id` | string | the human-supplied run identifier; slugified for the filename, stored raw here |
| `loop_phase` | enum | `"plan"` \| `"seam"` \| `"work"` \| `"done"` |
| `plan_step` | enum/null | `null` \| `"plan"` \| `"deepen"` \| `"review_plan"` — the LAST plan step the tick completed (the adapter reads it to compute the NEXT step; `null` = none yet). A plan-phase **sub-state**: meaningless outside `loop_phase == "plan"` (ignored elsewhere — adapters read it only under `loop_phase == "plan"`; it retains its last value after the plan→seam/work transition). Feeds `exit_predicate_result` ONLY in the plan phase: plan-met requires `plan_step == "review_plan"` (the §3.1 coherence guard — a default `gaps_open==0` before any review must not short-circuit). Persisted by the tick after each plan-loop advance so a fresh tick is not amnesiac — this is the anti-livelock field (§3.1). |
| `seam_paused` | bool | `true` ONLY while `loop_phase == "seam"`; the intentional-orphan flag (§5, I-3) |
| `adapter` | enum | `"ce"` \| `"native"` — which workflow adapter drives the run |
| `adapter_scale` | enum | `"three-tier"` \| `"blocker-only"` — set by U6b's rubric probe; tells the predicate evaluator which severity logic applies |
| `exit_predicate_result` | object | the **cached** loop-done computation; see §2.2. NEVER re-derive downstream — read this field (memory `feedback_loop_monitor_terminal_state_field`) |
| `units` | array | per-unit ledger entries; see §2.3 |
| `loop` | object | liveness / driver metadata; see §2.4 |
| `recipe` | object/null | **(v0.2.0, additive)** `{ "name": str, "source_tier": "workspace"\|"global"\|"built-in" }` — the recipe this run was built from. **`null` on a recipe-blind (v0.1.x) ledger**, which the engine treats as the implicit A1 (classic) topology. The recipe is baked into the ledger at `init_ledger`; resume reads it here, never re-loading the recipe file. |
| `phase_order` | string[] | **(v0.2.0, additive)** the run's ordered phase sequence. **Defaults to `["plan", "seam", "work"]`** (the v0.1.x grammar) when absent — so a recipe-blind ledger routes phases exactly as before. A recipe may declare a different order; the V1 validator accepts only the default and the work-only `["work"]` (KTD-15), rejecting all other non-default values until v0.2.1 (A3). `terminal_phase` MUST be a member. |
| `terminal_phase` | string | **(v0.2.0, additive)** the phase whose completion ends the run. **Defaults to `"work"`** when absent. `exit_predicate_result.met` can be `true` only when `loop_phase == terminal_phase`. For all V1 recipes this is `"work"`, so the predicate behaves identically to v0.1.x. |
| `active_wall_seconds` | int/float | **(v0.3.0, additive)** wall-time accumulator for the iteration `max_wall_seconds` bound (R5 / U2). **Defaults to `0`** on a legacy ledger; all reads use `ledger.get("active_wall_seconds", 0)`. Only `accumulate_active_time` writes it — atomic add-write, never overwrite. Counted from a `finally` clause around `_tick_body` so a crashed tick still contributes its delta. |
| `last_active_at` | `<iso>`/null | **(v0.3.0, additive)** ISO timestamp of the most recent `accumulate_active_time` call. **Defaults to `null`** on a legacy ledger. Diagnostic only — the bound math reads `active_wall_seconds`. |
| `iteration_attempts` | int | **(v0.3.0, additive)** count of HONORED iterate decisions (KTD §D / U2). **Defaults to `0`** on a legacy ledger; all reads use `ledger.get("iteration_attempts", 0)`. Incremented atomically by `atomic_iterate_step` (or the standalone `increment_iteration_attempts`). Pre-increment value drives `iteration.evaluate_decision`'s bound check — the Nth attempt is checked BEFORE its decision is honored, so the override path fires when `iteration_attempts == max_attempts` on entry. |
| `iteration_emit_count` | int | **(v0.3.0, additive)** monotonic emit-id counter (KTD §D / OQ4). **Defaults to `0`** on a legacy ledger. `emit_within_phase` increments it per emitted unit. Drives `iterate_template`'s id assignment via `id_prefix + (counter+1)` — never recounts existing units, so it survives partial-emit crashes that delete units. |
| `iteration` | object/null | **(v0.3.0, additive — written by U5's recipe wiring)** `{ "gate_unit": str, "emit_template": str?, "bound": { "max_attempts": int, "max_wall_seconds": int? } }`. **`null` on a non-iterating recipe (a1 / W)** — the iteration_pending compute returns `false`, every iteration mutator short-circuits to legacy behavior. The recipe layer writes this at `init_ledger`; U2 only DEFINES the read shape (no init param). |
| `emit_templates` | object/null | **(v0.3.0, additive — written by U5's recipe wiring)** `{ "<template_name>": { "phase": str, "invokes": str, "id_prefix": str } }` — the recipe's emit-template registry, the source the `iterate_template` emitter resolves when the gate's `iteration.emit_template` names a key. **`null` on a recipe that declares no templates** (legacy / non-iterating). Baked into the ledger at `init_ledger` so a resume reads the templates from disk without re-loading the recipe file (mirrors the `phase_transitions` precedent). Validator (`lib/recipes.py::_KNOWN_EMIT_TEMPLATE_KEYS`) rejects unknown inner keys so a typo doesn't silently no-op at emit. |

### 2.2 `exit_predicate_result` (the cached predicate — I-1)

| field | type | meaning |
|-------|------|---------|
| `met` | bool | loop is done. **Phase-aware** (I-2) and **scale-aware** (`adapter_scale`): in `loop_phase == "work"` (and seam/done) `met` requires `blockers==0 AND all_units_terminal==true AND units is non-empty`, plus `majors==0` **only when `adapter_scale != "blocker-only"`** (the three-tier default; for `"blocker-only"` runs majors are advisory — surfaced at exit, never gating). The non-empty-`units` conjunct is the vacuous-exit guard: a work phase with ZERO dispatched units must not declare done (`all([])==true` would otherwise short-circuit it before any fan-out). In `loop_phase == "plan"` `met` requires `gaps_open==0 AND plan_step=="review_plan"` ONLY — there are no work units yet, so neither `all_units_terminal` nor the non-empty-`units` guard applies, and the `plan_step=="review_plan"` conjunct mirrors the adapter coherence guard (§3.1): a default `gaps_open==0` before any review has run does NOT short-circuit. |
| `blockers` | int | count of `blocker`-severity findings across all units' `findings[]` |
| `majors` | int | count of `major`-severity findings across all units' `findings[]` |
| `minors` | int | count of `minor`-severity findings (reported at exit, never gate — R5/R6) |
| `gaps_open` | int | open plan-loop gaps (adapter-supplied); `0` outside plan-loop |
| `all_units_terminal` | bool | `true` iff EVERY unit is terminal (see "terminal" definition, §4, I-2) |
| `iteration_pending` | bool | **(v0.3.0, additive — KTD §B)** `true` iff the run declares an `iteration` block AND the gate unit's `dispatch_context.decision == "iterate"` AND the bound is unbreached (`iteration_attempts < max_attempts` AND `active_wall_seconds < max_wall_seconds`). The new `met` rule is `met = (existing met conditions) AND NOT iteration_pending` — without this AND-NOT clause, a recipe that emits plan-N units while `loop_phase == "work"` would see work-met fire spuriously (the phase-scoped terminal check ignores plan-N units; they are phase=plan, invisible). A ledger with no `iteration` block reads `iteration_pending = false` and the predicate behaves exactly as v0.2.x. |

This whole object is **recomputed from the in-memory unit state on every write**
(I-1) and persisted in the same atomic snapshot. It is a cache of a pure function
of `units[]` (+ `gaps_open` / `loop_phase`); consumers read it, they do not
recompute it.

### 2.3 `units[]` entry

| field | type | meaning |
|-------|------|---------|
| `id` | string | unit identifier, unique within the run (e.g. `"U1"`) |
| `state` | enum | `"pending"` \| `"dispatched"` \| `"verdict-returned"` \| `"fixed"` \| `"stalled"` \| `"terminal-skip"` — see §3 grammar |
| `depends_on` | string[] | unit ids this unit depends on (for fan-out gating; resolved by U10) |
| `dispatched_at` | `<iso>`/null | when the orchestrator marked it `dispatched`; null until then |
| `verdict_at` | `<iso>`/null | timestamp of the **latest** verdict self-write (overwrites on re-verdict — latest-only semantics; null until first verdict) |
| `stall_threshold_seconds` | int | per-unit timeout; adapter-set, defaults to `DEFAULT_STALL_THRESHOLD_SECONDS` (600). After this many seconds `dispatched` with no verdict, U4's tick may mark it `stalled` |
| `last_error` | object/null | `{ "call": str, "message": str, "at": <iso> }` if an adapter raised, a launch failed, or a stall recorded an error; `null` otherwise. Set when `dispatched → stalled` via a raise (vs a plain timeout, which leaves it `null`) OR via a launch failure (`call == "launch"`, Bug #8). Cleared on `stalled → pending` (retry) AND on a recovered late verdict (`stalled → verdict-returned`, Bug #7) |
| `attempt` | int | **dispatch generation counter** (Bug #6 attempt-identity). Default `0`; **additive / backward-compatible** — an old ledger with no `attempt` field reads as `0`. INCREMENTED by the orchestrator on each `pending → dispatched` (in the same atomic snapshot as the transition). The background agent launched for attempt N carries N into `record_verdict(... attempt=N)`; a verdict whose `attempt` is **older** than the unit's current `attempt` is REJECTED (`StaleVerdict`) — a stale verdict from a SUPERSEDED attempt (e.g. a slow agent that was retried-past). `attempt=None` skips the check (back-compat); equal-attempt is accepted (re-review / recovery) |
| `phase` | string | **(v0.2.0, additive)** the unit's phase. When absent, defaults to the run's start phase if that is a plan phase, else `"work"` — matching v0.1.x (plan-phase runs have no work units yet; any pre-declared unit is a work unit). Recipes set it explicitly. |
| `plan_step` | enum/null | **(v0.2.0, additive)** per-unit plan-step for N>1 parallel plan-loops (R11). `null` default. A1's single plan-loop keeps using the **top-level** `plan_step` scalar (so A1's first-tick ledger stays byte-identical to v0.1.x); this per-unit field is populated only when a recipe declares multiple plan-phase units. |
| `gaps_open` | int/null | **(v0.2.0, additive)** per-unit open-gap count for N>1 plan-loops. `null` until a review feeds one back. Same A1-uses-the-scalar rule as `plan_step`. |
| `dispatch_context` | object | **(v0.2.0, additive)** `{}` default. Recipe-side metadata merged from the recipe unit's `invokes` (e.g. `prompt_template`, `bias`) — after path-bounding validation — plus engine-written keys such as `enumerated_units` (the plan unit's `enumerate_plan_units` output, persisted at `plan-done` so emitters read it without re-calling the adapter). The adapter reads it via its existing `unit` parameter. **(v0.3.0, additive sub-keys on a gate unit's `dispatch_context`):** `decision` ∈ `iteration.DECISIONS` (`"advance" \| "iterate" \| "exit"`) — the gate's verdict-time decision, written by `set_verdict_decision` (replaces the v0.2.x `winner_unit_id` pattern: the gate's outcome lives on `dispatch_context`, never on `findings[]` which `record_verdict` normalizes to `{severity, note}` only; readers MUST go through `lib/iteration.py::read_decision`, the AST lint enforces); `decision_payload` (optional dict) — caller-supplied data accompanying an `iterate` decision (e.g. `emit_count` for `iterate_template`); `bound_override` (object) — `{ "bound": "max_attempts"\|"max_wall_seconds", "original_decision": <enum>, "at": <iso> }`, written by `set_bound_override` when the engine forced `iterate → exit` because the bound was breached. Both `decision`/`decision_payload` are cleared by `reset_for_iteration` so a fresh iteration doesn't read the stale decision (round-3 P0-R3-1). |
| `last_advanced_at` | `<iso>`/null | **(v0.2.0, additive)** `null` default (sorts oldest → picked first). The round-robin tiebreaker for serialized N>1 plan-loop advance: `orchestrator.pick_next_plan_unit_to_advance` picks the ready plan unit with the oldest `last_advanced_at`, ties broken by `units[]` declaration order. State lives here so resume continues round-robin correctly. |
| `findings` | array | LATEST review verdict's findings; each `{ "severity": "blocker"\|"major"\|"minor", "note": str }`. See §4 findings semantics |

### 2.4 `loop` object (liveness — I-3)

| field | type | meaning |
|-------|------|---------|
| `driver` | enum | `"self"` = a tick chain is self-pacing via `ScheduleWakeup`; `"manual"` = paused / awaiting `/auto-resume` |
| `last_beat_at` | `<iso>` | updated each tick; powers orphan detection (§5). There is **no** `next_beat` field — each tick re-arms its own successor, so liveness is inferred from `last_beat_at` + `driver`, not a stored next-fire time |

---

## 3. State grammar

A unit's `state` may move ONLY along these edges. `lib/ledger.py::transition`
rejects any transition not in this table (it raises; the ledger is not written).

```
pending          → dispatched          (ORCHESTRATOR via dispatch_batch — the ONLY entry transition; non-pending units are rejected)
dispatched       → verdict-returned    (the BACKGROUND AGENT self-writes its verdict + findings atomically)
dispatched       → stalled             (past stall_threshold_seconds with no verdict, OR an adapter raised mid-dispatch)
verdict-returned → fixed               (a TICK applies a fix for this unit's findings — fixed is NOT terminal-with-closure; see §4)
verdict-returned → pending             (no fix needed / next round: re-dispatch this unit)
fixed            → pending             (a TICK that applied fixes re-enqueues for re-review — this is the closure loop)
stalled          → pending             (OPERATOR: /auto-resume retry <unit>; clears last_error)
stalled          → terminal-skip       (OPERATOR: /auto-resume skip <unit>; counts as terminal for I-2)
stalled          → verdict-returned     (RECOVERY, record_verdict-ONLY — Bug #7; see below)
```

Terminal sink: `terminal-skip` has no outgoing transition.

**`record_verdict`-only edges** (NOT in `transition()`'s grammar — they write
`findings[]`, which `transition()` forbids). `record_verdict` accepts a verdict
from a unit currently in `{dispatched, verdict-returned, stalled}`:

- `dispatched → verdict-returned` — the normal first verdict self-write.
- `verdict-returned → verdict-returned` — a re-verdict (re-review; latest-only).
- **`stalled → verdict-returned`** (Bug #7 **late-verdict recovery**) — a healthy
  but slow review that was marked `stalled` past `stall_threshold_seconds`
  finishes and self-writes a GENUINE verdict. That is real work; discarding it
  (the pre-fix behaviour silently raised `InvalidTransition` and left `last_error`
  null, so a lost verdict looked identical to a true timeout) is wrong. We RECOVER
  it to `verdict-returned` and clear `last_error`. **Coordinated with Bug #6
  attempt-identity:** recovery is only for the CURRENT attempt — a late verdict
  from a SUPERSEDED attempt (the operator already retried and a fresh agent
  verdicted) is still rejected (`StaleVerdict`), never recovered. So a stale late
  verdict cannot resurrect itself by routing through the recovery edge.

These edges are enforced in `record_verdict`, NOT `ALLOWED_TRANSITIONS`, because
adding them to the latter would let `transition()` change state without findings —
exactly what the "use `record_verdict()` to write findings" guard blocks.

### 3.x `reset_for_iteration` reuses the existing `verdict-returned → pending` edge (v0.3.0)

v0.3.0's `reset_for_iteration` mutator (KTD §C / U2) cycles the gate unit back
to `pending` to re-engage it for the next iteration. It does **NOT** introduce
a new state-grammar edge — the `verdict-returned → pending` edge already exists
in the table above (and in `ALLOWED_TRANSITIONS` at `lib/ledger.py:84`). What is
new is the atomic **COMBINATION** the mutator wraps in ONE locked body:

1. State edge `verdict-returned → pending` (the existing edge; grammar-checked
   inline because `transition()` cannot be re-called from a held lock).
2. `depends_on` is replaced with the caller-supplied list (the union of the
   gate's prior deps + newly-emitted sibling ids — caller computes the union).
3. `dispatch_context.decision` and `dispatch_context.decision_payload` are
   CLEARED. Without this clear, a subsequent tick would re-read the stale
   `decision: "iterate"` and re-fire the iteration loop before the gate
   re-verdicts (double-incrementing `iteration_attempts` until bound trip).
4. `verdict_at` is cleared.
5. `findings` is cleared.

`reset_for_iteration` is the **engine-only** caller for this combo. The
composite `atomic_iterate_step` wraps an increment + emit + reset in ONE
locked body for all-or-nothing semantics (a failing emit leaves the ledger
in the pre-iterate state).

**Explicitly rejected** (illustrative — anything not in the table above is rejected):
`pending → fixed` (skips review), `pending → verdict-returned`, `pending → terminal-skip`,
`verdict-returned → dispatched`, `terminal-skip → *`, any self-edge.

**Who writes which transition** (no two writers contend for the same edge):
- **Orchestrator** (U10) owns `pending → dispatched`.
- **Background agent** (U10) owns `dispatched → verdict-returned` (self-write; survives the driving session's death) and is the **only writer of `findings[]`**.
- **Tick** (U4) owns `verdict-returned → fixed`, `fixed → pending`, `verdict-returned → pending`, `dispatched → stalled`, and all `loop_phase` phase transitions.
- **Operator** (U7, via `/auto-resume`) owns the `stalled →` recoveries.

### 3.1 Plan-step sub-grammar (`plan_step` — the anti-livelock field)

`plan_step` records the LAST plan step the tick completed. It is a sub-state of
`loop_phase == "plan"` and is `null` (ignored) in every other phase. The
**adapter** owns the sequencing — it reads `plan_step` (+ `gaps_open`) and
returns the NEXT step; the **tick** persists the step it just ran. The two
adapters differ only in whether a `deepen` step exists:

```
CE:      null → plan → deepen → review_plan
                          ↑          │
                          └──────────┘  (gaps_open > 0: another round → deepen)
         review_plan AND gaps_open == 0  → done   (coherence guard, §4.1 of the adapter contract)

native:  null → plan → review_plan
                            ↑     │
                            └─────┘  (gaps_open > 0: review again — native NEVER deepens)
         review_plan AND gaps_open == 0  → done
```

**Round / reset rule.** A "round" is one pass through the sequence ending in a
`review_plan`. After a `review_plan` whose gap-set is non-empty (`gaps_open > 0`)
the adapter starts a fresh round by returning `deepen` (CE) / `review_plan`
(native) — it does NOT reset to `plan` (re-planning from scratch would discard
the existing plan; the loop refines it). The loop terminates the moment a
`review_plan` round returns an empty gap-set (`gaps_open == 0`), at which point
`next_plan_step` returns `"done"` — this is the coherence guard that prevents the
livelock. Because the guard keys on `plan_step == "review_plan"` specifically, a
default `gaps_open == 0` BEFORE any review has run (e.g. at `plan` / `deepen`)
does NOT short-circuit.

**Why it must be persisted.** `next_plan_step` is pure over the ledger. A tick is
a fresh process that reads ALL state from disk. If the tick does not write back
the step it ran, the next tick reads `plan_step == null`, the adapter returns
`"plan"`, and the plan-loop re-plans forever (the plan-loop livelock). The tick
therefore persists the executed step via `set_loop(plan_step=...)` AFTER the
adapter op returns successfully (a step that raised is recorded as a stall, not
as completed).

---

## 4. Terminal definition & findings semantics

### 4.1 `terminal(unit)` (load-bearing for I-2)

```
terminal(u) = u.state == "terminal-skip"
              OR ( u.state in {"verdict-returned", "fixed"}
                   AND no finding in u.findings has severity in {"blocker","major"} )
```

A unit that is `pending`, `dispatched`, or `stalled` is NOT terminal. A `fixed`
unit whose `findings[]` STILL carries an open `blocker` or `major` is **NOT
terminal** — this is the findings-closure livelock guard: a unit cannot end the
loop merely by being marked `fixed` while its last review still shows a defect.

`lib/ledger.py` exposes this as a pure function `unit_is_terminal(unit) -> bool`
so consumers (and the I-2 test) can call it directly.

`all_units_terminal == true` iff `terminal(u)` holds for every `u in units`.

### 4.2 Findings semantics (honors R8 — closure only via a verdict)

- `findings[]` holds the **latest review verdict's** output. A new verdict
  **OVERWRITES** the array (it does not append). It always reflects exactly the
  most recent review's view of the unit.
- `findings[]` is written **ONLY** by a background agent's review verdict
  (the `dispatched → verdict-returned` transition). NOTHING else writes it.
- A tick applying a fix (`verdict-returned → fixed`) does **NOT** clear or modify
  `findings[]`. Asserting closure without a verdict is forbidden (R8). The fix is
  recorded as a state change only; the stale findings remain until a fresh review
  overwrites them.
- Therefore the closure path is:
  `verdict-returned →(fix)→ fixed →(re-enqueue)→ pending →(re-dispatch)→ dispatched →(fresh review)→ verdict-returned` with NEW findings (ideally empty).
  The predicate clears only when a re-review returns no blockers/majors.

---

## 5. Hard invariants (enforced in code)

### I-1 — Atomic predicate freshness (generalized to ALL writers)

EVERY ledger write that mutates unit state or findings — whether by a tick (U4),
a background agent's verdict self-write (U10), or the orchestrator's
`dispatch_batch` (U10) — MUST recompute `exit_predicate_result` (including
`all_units_terminal`) from the SAME in-memory state and persist both in ONE
atomic `mkstemp + os.rename` under flock.

This is enforced structurally: `lib/ledger.py` has exactly one serialization
chokepoint (`_atomic_write`) that ALWAYS recomputes the predicate immediately
before writing. There is no public path that writes the ledger without
recomputing. Any writer that mutates state via the module API inherits I-1 by
construction — that is what "generalized to ALL writers" means: U10's callers
route their mutations through this module and get freshness for free.

All consumers — the tick's stop-check, native `/goal` (via `goal-status.sh`),
U7's hooks — read `exit_predicate_result` directly and NEVER re-derive it.

### I-2 — Done requires terminal units

`exit_predicate_result.met == true` is **phase-aware**:

```
work-loop  (loop_phase in {"work","seam","done"}):
    blockers == 0  AND  majors == 0  AND  all_units_terminal == true

plan-loop  (loop_phase == "plan"):
    gaps_open == 0  AND  plan_step == "review_plan"
```

The plan-loop predicate is gaps-only — there are no work units yet, so
`all_units_terminal` is NOT a requirement (it would never hold while units are
still pending). The `plan_step == "review_plan"` conjunct mirrors the adapter
coherence guard (§3.1) one-to-one: a default `gaps_open == 0` BEFORE any review
has run (at `plan` / `deepen` / `null`) must NOT short-circuit the plan loop to
met. Both `next_plan_step`'s "done" guard and this predicate key on the same
condition, so they agree (adapter-contract §4.1 / §5).

The work-loop predicate closes two failure modes at once:
- **stalled-dependency false-done:** a stalled unit with un-dispatched dependents
  keeps `all_units_terminal == false`, so the loop cannot falsely report done even
  if no findings exist yet.
- **findings-closure livelock:** a `fixed` unit whose findings still show a blocker
  is NOT terminal (§4.1), so the loop re-enqueues it for re-review rather than
  exiting.

### I-3 — Liveness / orphan detection

`loop.last_beat_at` records the last tick time; `loop.driver` is `"self"` while a
tick chain is self-pacing or `"manual"` when paused / awaiting resume.

A run is **resumable (orphaned)** iff:

```
loop_phase != "done"
AND ( loop.driver == "manual"
      OR loop.last_beat_at is older than GRACE_SECONDS )
```

`GRACE_SECONDS = 4200` (70 min). It MUST exceed the maximum tick delay (3600s,
the `ScheduleWakeup` clamp ceiling) plus tick-execution slack, so a healthy
slow-paced tick chain (e.g. last beat 3500s ago, `driver == "self"`) is NEVER
false-flagged as orphaned — a false flag could induce a double-drive.

`seam_paused == true` is the *intentional* orphan: it is surfaced as a seam (a
plan-complete pause awaiting confirmation), not a crash. The SessionStart hook
(U7) checks `seam_paused` BEFORE the time-based orphan branch.

`lib/ledger.py` exposes `is_orphaned(ledger, now=None) -> bool` implementing the
predicate above (excluding the seam-paused special-casing, which is U7's
surfacing concern).

---

## 6. Module constants (importable; do not re-declare in consumers)

`lib/ledger.py` declares these at module scope. U4/U7/U10 MUST import/read them,
not hardcode copies — hardcoding causes drift.

| constant | value | meaning |
|----------|-------|---------|
| `GRACE_SECONDS` | `4200` | orphan-detection grace window (I-3) |
| `DRIVER_SELF_STALE_SECONDS` | `3900` | Bug #9 dead-self-chain gate for the Stop hook: a `driver=="self"` run whose `last_beat_at` is older than this is treated as a dead chain and does NOT block stop. Sits ABOVE the 3600s max-tick-delay + slack (a healthy slow chain is never falsely un-blocked) and BELOW `GRACE_SECONDS` (a dead chain stops blocking before `is_orphaned` surfaces it for resume) |
| `DEFAULT_STALL_THRESHOLD_SECONDS` | `600` | per-unit stall timeout default |
| `LOOP_PHASES` | `("plan","seam","work","done")` | valid `loop_phase` values |
| `PLAN_STEPS` | `("plan","deepen","review_plan")` | valid non-null `plan_step` values (`null` is also valid: no step yet) |
| `UNIT_STATES` | the six states | valid `state` values |
| `SEVERITIES` | `("blocker","major","minor")` | valid finding severities (shared scale, R3) |

---

## 7. Concurrency, atomicity, Python pin (implementation contract)

- **Atomic write:** `mkstemp` in the target dir → `os.fchmod(fd, 0o600)` → write →
  `os.rename(tmp, dest)`. A crash mid-write leaves the old file intact and the tmp
  orphaned (cleaned on the next write); never a half-written ledger. Mirrors
  `claude-modes/scripts/on-session-start.sh:162-175`.
- **Locking:** `fcntl.flock(LOCK_EX)` on the `.lock` file (NOT `flock(1)` — macOS
  lacks it). **The lock spans the WHOLE read-modify-write** — acquire, read,
  mutate, recompute, atomic-rename, release — NOT just the rename. Holding only
  across the rename would permit a lost update (two writers each read the old
  snapshot, both mutate, the second clobbers the first). This is the lost-update
  guard and is the critical correctness property of the lock.
- **Python pin:** `/usr/bin/python3`, overridable via `CLAUDE_AUTO_PYTHON3`
  (default `/usr/bin/python3`). Never bare `python3` — on macOS PATH may resolve a
  Homebrew Python lacking modules. Rationale parity: `claude-modes/lib/mode-yaml.sh:24-32`.
- **Slugify:** a vendored copy of `claude_modes::slugify_branch` lives inside
  `lib/ledger.py` (`_slugify_branch`). It is NOT cross-imported from claude-modes
  (avoids cross-plugin coupling). Logic parity:
  `claude-modes/lib/validate-mode-name.sh:104-136`.

### Test-only escape hatches (deliberate-fail discipline)

These are read ONLY by `lib/ledger.py` and ONLY honored under tests; a fence test
asserts no production file enables them.

| env var | effect | proves |
|---------|--------|--------|
| `CLAUDE_AUTO_TEST_NO_LOCK` | `=1` skips `flock` acquisition | the concurrency test goes RED (lost update) without the lock |
| `CLAUDE_AUTO_TEST_NO_RECOMPUTE` | `=1` skips the I-1 predicate recompute on write | the I-1 test goes RED (stale `met:true` after a new blocker) without recompute |
| `CLAUDE_AUTO_TEST_NO_REENQUEUE` | `=1` makes the tick's work-loop advance SKIP the `fixed → pending` re-enqueue (read by `lib/tick.py::advance_work_loop`) | the work-loop closure test goes RED (livelock at `fixed` — the stale blocker is never re-reviewed) without the re-enqueue |
| `CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK` | `=1` makes `record_verdict` SKIP the Bug #6 attempt-identity rejection | the stall+retry clobber test goes RED (a stale verdict from a superseded attempt overwrites the fresh one) without the attempt check |
| `CLAUDE_AUTO_TEST_NO_STALLED_RECOVERY` | `=1` makes `record_verdict` reject a verdict from a `stalled` unit (the pre-fix behaviour) | the late-verdict recovery test goes RED (a genuine slow verdict is lost to `InvalidTransition`) without the recovery edge |
| `CLAUDE_AUTO_TEST_NO_STALENESS_CHECK` | `=1` makes `lib/on-stop.py::_blocking_runs` SKIP the Bug #9 dead-self-chain freshness gate | the stale-block test goes RED (a dead `driver=="self"` chain keeps blocking stop) without the gate |

---

## 8. Public API surface (`lib/ledger.py`)

Consumers use these; the schema above is what they read/write through them.

| function | purpose |
|----------|---------|
| `ledger_path(repo_root, run_id)` / `lock_path(repo_root, run_id)` | path helpers (§1) |
| `init_ledger(repo_root, run_id, *, adapter, adapter_scale, units, loop_phase=..., plan_step=None)` | create a new ledger; rejects if one already exists; recomputes predicate; atomic write. `plan_step` defaults to `null` (no plan step yet) |
| `read_ledger(repo_root, run_id)` | return the ledger dict; raises a clean error (no partial file) on unknown run-id |
| `transition(repo_root, run_id, unit_id, new_state, **fields)` | grammar-checked state change under flock; recompute + atomic write |
| `record_verdict(repo_root, run_id, unit_id, findings, attempt=None)` | `{dispatched, verdict-returned, stalled} → verdict-returned`; OVERWRITES `findings[]`; sets `verdict_at`; clears `last_error`; recompute + atomic write (the verdict-self-write path, U10). `attempt` (Bug #6) is the dispatch generation the verdict is for — a verdict whose attempt is older than the unit's current `attempt` is rejected (`StaleVerdict`); `None` skips the check. Accepts `stalled` as a recovery edge (Bug #7) unless the verdict is stale |
| `set_loop(repo_root, run_id, *, loop_phase=None, seam_paused=None, driver=None, beat=False, plan_step=<unset>)` | phase / liveness / plan-step updates (U4); recompute + atomic write. `plan_step` uses an UNSET sentinel default (not `None`) because `null` is a valid stored value — pass `plan_step=None` to clear it, or a step name to set it |
| `set_gaps_open(repo_root, run_id, gaps_open)` | persist the plan-loop open-gap count from `review_plan`'s return length (U4); writes `exit_predicate_result.gaps_open` then recompute + atomic write (I-1). The ONLY writer of `gaps_open` |
| `unit_is_terminal(unit)` | pure `terminal(u)` predicate (§4.1) |
| `is_orphaned(ledger, now=None)` | pure I-3 orphan predicate (§5) |
| `recompute_predicate(ledger)` | pure predicate computation; used internally by `_atomic_write`, exposed for tests. **(v0.3.0)** also returns `iteration_pending: bool` (KTD §B) |
| `set_verdict_decision(repo, run, gate_unit_id, decision, payload=None)` | **(v0.3.0, U2)** write `dispatch_context.decision` (validated against `iteration.DECISIONS`) + optional `dispatch_context.decision_payload`. Mirrors `set_winner_unit_id`. Atomic; predicate recomputed |
| `set_bound_override(repo, run, gate_unit_id, bound_type, original_decision)` | **(v0.3.0, U2)** engine-only audit trail for iterate→exit. Writes `dispatch_context.bound_override = {bound, original_decision, at: <iso>}` |
| `accumulate_active_time(repo, run, delta_seconds)` | **(v0.3.0, U2)** atomic ADD-write of `active_wall_seconds` (NEVER overwrite); stamps `last_active_at`. Negative deltas clamped to 0; rounded to 3dp. Called from U4's `finally` clause |
| `increment_iteration_attempts(repo, run, gate_unit_id)` | **(v0.3.0, U2)** atomic `iteration_attempts += 1`. Validates `gate_unit_id` exists |
| `reset_for_iteration(repo, run, gate_unit_id, new_depends_on)` | **(v0.3.0, U2 / KTD §C)** atomic gate-unit cycle-back combo (state edge `verdict-returned → pending` + depends_on replace + clear `dispatch_context.decision/decision_payload` + clear `verdict_at` + clear `findings`). Re-uses the existing state edge — see §3.x |
| `emit_within_phase(repo, run, to_phase, emitter)` | **(v0.3.0, U2)** sibling to `transition_and_emit`: emits new units into `to_phase` WITHOUT advancing `loop_phase`. Increments `iteration_emit_count` per emitted unit. Same emitter contract (pure `(ledger, to_phase) -> list[unit_dict]`; F3 deadlock guard) |
| `atomic_iterate_step(repo, run, gate_unit_id, emitter, new_depends_on)` | **(v0.3.0, U2)** composite — wraps `iteration_attempts++` + emit + reset in ONE locked body (all-or-nothing). Engine-only caller (U4's `advance_iteration_loop`) |

CLI entry (for `lib/ledger.sh` and ad-hoc scripting): `python3 ledger.py <subcommand> ...`.

---

## 9. Cross-references

- Plan: `docs/plans/2026-05-21-001-feat-auto-loop-engine-plan.md` (U3 section).
- Atomic write precedent: `claude-modes/scripts/on-session-start.sh:162-175`.
- Lock precedent: `claude-modes/lib/cascade-engine.sh::with_flock_run`.
- Slugify source: `claude-modes/lib/validate-mode-name.sh:104-136`.
- Deliberate-fail test precedent: `claude-modes/tests/integration/concurrent-mode-set.test.sh`.
- Memory: `feedback_loop_monitor_terminal_state_field` (read the cached terminal-state field, never a proxy), `feedback_new_tests_need_deliberate_fail_smoke_check` (deliberate-fail hatches).
