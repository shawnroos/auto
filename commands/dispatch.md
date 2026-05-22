---
argument-hint: <plan-or-spec> [auto] [--adapter ce|native] [--goal "<goal>"]
allowed-tools: Bash
---

Start a new dispatch run — the workflow-agnostic pulsed loop engine.

`/dispatch <plan-or-spec>` initializes a run from a plan or spec, sets a
native `/goal` bound to the loop's exit condition, writes the initial
per-unit ledger to `<repo>/.claude/dispatch/<run-slug>.json`, and arms the
first self-paced tick (via `ScheduleWakeup`, which re-arms its own
successor each tick). The engine then drives plan-loop -> seam -> work-loop,
exiting only when the adapter-supplied exit predicate holds AND every unit
is terminal.

Argument forms (parsed inside `lib/dispatch.sh`, not here):

- **Plan/spec**: `/dispatch path/to/plan.md` — start a run from a plan file.
- **Auto seam**: append `auto` to skip the plan->work seam pause (plan
  predicate met flips straight to the work-loop). Without `auto`, the loop
  pauses at the seam and surfaces a `/dispatch-resume continue` hint.
- **Adapter**: `--adapter ce|native` selects the workflow adapter
  (default per repo config).
- **Goal**: `--goal "<text>"` supplies a compound deliberate-stop goal
  (e.g. "until only minors remain AND one successful test"); defaults to
  the loop's own predicate.

Empty args -> `lib/dispatch.sh` prints usage and exits cleanly (no run
created).

To dispatch, run:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/dispatch.sh" "$ARGUMENTS"`
