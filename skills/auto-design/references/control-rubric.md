<!--
Adapted from ksimback/looper (references/control-rubric.md), MIT License.
Rewritten in auto's vocabulary (workflow / run-record / driver / exit-predicate);
looper's execution + council framing stripped. Original © the looper authors.
-->

# Control rubric

Use this when setting the loop's stop conditions — the bounds that keep a run
from grinding forever. In auto these map onto the workflow's `iteration.bound`
and the run-record's existing staleness gates; the design skill coaches the user to
set them deliberately rather than inherit silent defaults.

## What every loop must have

- **A hard iteration cap.** The workflow's `iteration.bound.max_attempts` — the
  maximum number of times a gate may verdict `iterate` before the engine forces
  `iterate → exit`. Without it a failing gate loops to the agent-launch ceiling.
- **A wall-time cap** when the work is open-ended: `iteration.bound.max_wall_seconds`
  (cumulative *active* wall time). Breach forces exit the same way.
- **An explicit exit predicate.** Auto's deterministic predicate —
  `blockers == 0 AND majors == 0 AND all_steps_terminal` ("only P3 findings
  remain") — is the run's single source of truth for done. Typed verification
  criteria are gate conditions layered on top; they never replace it.

## Coach-only in v1 (surfaced, not yet engine-enforced)

The design skill should still *coach* these and write them into the goal doc,
even though the engine does not enforce new bounds for them yet:

- **No-progress detection** — stop after N consecutive iterations that change
  nothing material. Today auto approximates this with the per-step stall
  threshold and the per-run dead-chain gate; a dedicated no-progress signal is
  deferred.
- **Budget caps** — usd / tokens / wall-clock the user is willing to spend.
  Surface them in the goal doc as intent; engine enforcement is deferred.

Name the gap honestly when you coach these: "auto will cut this off via
`max_attempts` / wall / stall, but it has no dedicated no-progress or budget
guard yet."

## Critique prompts

- What is the maximum number of fix cycles this gate should get before the run
  gives up and surfaces failure?
- Is the work bounded enough that `max_attempts` alone suffices, or does it need
  a wall-time cap too?
- Where should a human be in the loop? (A `human` verification criterion routes
  through the pause handoff — use it for irreversible or judgment-heavy gates.)
- What is the single condition that means "done" — and is it the deterministic
  predicate, or does it need extra typed criteria?

## Anti-patterns

- No iteration cap → the loop runs to the agent-launch ceiling on any persistent
  failure.
- A `revise_until_clean`-style gate with no judge or human verdict source — it
  can never resolve. Give such a gate an `advisor_judge` or `human` criterion.
- Treating bounds as failure-only fine print instead of a design decision: a run
  that exits on `max_attempts` exited as a *failure*, not a win. Size the bound
  to the work.
- Budgets stated as prose hopes with no surfaced number for the user to confirm.
