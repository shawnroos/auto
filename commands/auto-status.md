---
argument-hint: "[<run> | freeform sentence]"
allowed-tools: Bash, AskUserQuestion
---

Show the ledger and health of an auto run.

`/auto-status` reads the durable ledger at
`<repo>/.claude/auto/<run-slug>.json` and reports the loop phase, the
cached exit-predicate result (blockers / majors / minors / gaps_open and
whether it is met), per-unit states, the driver (`self` while a tick chain
is self-pacing, `manual` when paused awaiting resume), and liveness
(`last_beat_at` vs the orphan GRACE). It surfaces stalled units with their
`last_error` cause and, at exit, the remaining minors report for operator
promotion.

It is read-only — it never mutates the ledger or arms a tick.

### Iteration section (v0.3.0)

When the run is iteration-aware — the ledger declares an `iteration`
block, or `iteration_attempts > 0`, or `active_wall_seconds > 0`, or any
unit carries a `dispatch_context.bound_override` — `/auto-status` prints
an additional `iteration:` block between the exit-predicate line and the
units list. Fields:

- `gate_unit` — the unit id whose `verdict.decision` drives the loop.
- `attempts` — `iteration_attempts` / `iteration.bound.max_attempts`
  (honored iterate decisions vs the configured cap).
- `wall_time` — `active_wall_seconds` /
  `iteration.bound.max_wall_seconds` (sum-of-deltas wall-time vs cap; the
  denominator renders as `—` when no wall bound is configured).
- `emit_count` — `iteration_emit_count`, the monotonic emit-id counter
  (KTD §D / OQ4) — bumped per emitted unit so re-emitted ids never
  collide.
- `last_active` — `last_active_at`, the ISO timestamp of the most recent
  `accumulate_active_time` call. Omitted when null.
- `iteration_pending` — the cached
  `exit_predicate_result.iteration_pending` bool (KTD §B / U2): true iff
  the gate's effective decision is `iterate` and the bound is unbreached,
  which short-circuits an otherwise-met predicate so the tick yields back
  for another work pass.
- `kill_switch` — rendered when the operator has set
  `CLAUDE_AUTO_DISABLE_ITERATION=1` (post-F5 unfence; the test-harness
  sentinel is no longer required). Printed as `DISABLED via
  CLAUDE_AUTO_DISABLE_ITERATION`. Indicates the iteration check is
  short-circuited at every tick — the recipe behaves as v0.2.x for the
  duration the env var is set.

Each unit's listing also gains a `bound_exit:` sub-bullet (alongside
`finding:`) when `dispatch_context.bound_override` is present — it shows
which bound was breached (`max_attempts` or `max_wall_seconds`), the
`original_decision` the engine would have honored, and the ISO timestamp
of the forced exit.

### Exit-reason line (v0.3.0 G2)

On done runs (`loop_phase == "done"`) that carry a non-null top-level
`exit_reason`, `/auto-status` prints an additional `exit_reason:` line
beneath the loop_phase line. It surfaces a forced exit driven by an
unexpected raise in the iteration check (NOT the clean predicate-met or
bound-breach paths — those are silent on this line because they're not
diagnostic). The line carries `kind: <error-type>: <message>`. Two
`kind` values exist (see `lib/ledger.py::EXIT_REASON_KINDS`):

- `iteration-check-failed` — `advance_iteration_loop` raised a
  non-`LedgerError` exception (typically a malformed iteration block, a
  corrupted gate verdict, or a raise from the producer). Investigate the
  ledger's `iteration` block + the gate unit's `dispatch_context`.
- `recipe-bug` — `advance_iteration_loop` raised a `LedgerError`
  subclass (`UnknownUnit`, `InvalidTransition`, `StaleVerdict`) — the
  recipe's `units[]` / `phase_transitions` don't match what the engine
  reached for. Investigate the recipe JSON against the schema in
  `docs/contracts/recipe-format.md`.

`exit_reason` is persisted on the ledger BEFORE the forced
`loop_phase=done` write, so the operator surface can distinguish a
crash-marked-done run from a clean exit. The transient harness stop
intent (`{action: "stop", reason: "..."}`) carries the same `kind` —
both are written by `lib/tick.py`'s F2 / G2 catches.

## Argument handling (dispatcher routes BEFORE invoking the script)

Inspect the argument string and route as follows:

1. **Empty** — invoke the script with no args; it resolves the most recent
   run in the repo, or prints usage if none exists. (Safe bare default.)

2. **Looks like a run id** (kebab-case slug, no spaces, e.g.
   `feat-foo-2026-05-21`) — invoke the script with the id verbatim.

3. **Freeform sentence** (e.g. "how's the latest run going?", "show me the
   auth one", "status of yesterday's run") — interpret intent:
   - If clearly the most recent / active run → invoke with no args.
   - If a specific run is named or implied AND only one ledger matches →
     invoke with that resolved run id.
   - If multiple ledgers could match (e.g. "the auth one" with two
     matching runs) → `AskUserQuestion` listing the candidates with the
     most-recent one as Recommended, then invoke with the chosen id.
   - If intent is unparseable → `AskUserQuestion` offering the recent
     runs (read `ls -t <repo>/.claude/auto/*.json` first).

Status is read-only, so picking the wrong run is harmless — bias toward
acting without asking when the recent-run interpretation is plausible.

## Dispatch

If the argument string is empty or a clean run-id pass-through, run the dispatch
line below directly (the harness substitutes the argument string before bash
runs):

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh" "$ARGUMENTS"`

If you resolved a freeform sentence into a specific run id, call Bash
explicitly with the resolved id rather than going through the
substitution path:

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh" "<resolved-run-id>"
```
(do NOT include this as a literal line in your response — invoke the Bash
tool with the constructed command.)

For the full agent operating contract (the verb surface, argument shapes,
and rejection modes), run `python3 lib/ledger.py describe` — see
`docs/contracts/agent-tool-surface.md`.
