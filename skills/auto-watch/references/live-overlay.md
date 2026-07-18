# Live-agent overlay — mapping run-record structure to task liveness

`lib/watch_tree.py` renders the run's STRUCTURE from the run-record. This reference
covers the model-side overlay: reconciling each rendered node against the harness
task tools (`TaskList` / `Monitor`) so a dead or wedged agent — including a nested
`do_step` agent with its own `session_id` — is visible in the view (R6, AE5).

## Why an overlay is needed

- The run-record records what the run BELIEVES: a step is `dispatched` from the
  `pending → dispatched` transition until a verdict lands. It does not know the
  agent's OS-process reality.
- A nested `do_step` fan-out agent carries its OWN `session_id` (`skills/auto/SKILL.md`
  §4 / KTD-5) and is not a run-record row of its own in the general case, so neither
  the run-record nor a PreToolUse hook can reach it. The task tools can.
- The two failure classes the watch view must surface both live in the gap
  between "run_record says dispatched" and "process reality":
  - **alive-but-wedged** — the agent is up but has produced nothing past its
    stall threshold. The renderer already flags this as `OVER-AGE` from the
    run-record alone (age > `stall_threshold_seconds`).
  - **silently dead** — the agent crashed or died to auth churn with no verdict.
    The run-record still calls it `dispatched`; only the task tools reveal the death.

## The mapping

| RunRecord node (from the renderer) | Task-tool signal | Read as |
|---|---|---|
| `dispatched`, not `OVER-AGE` | live task present | healthy, in flight |
| `dispatched`, `OVER-AGE` | live task present | alive-but-wedged (timeout-watchdog case) |
| `dispatched` | no live task / task reports finished or dead | silently dead — reap event-driven, don't wait out the threshold |
| `stalled` | (already reaped) | awaiting retry / escalation per §4 policy |
| non-dispatched (`pending`/`verdict-returned`/`fixed`/`terminal-skip`) | n/a | not live; shown for tree shape only |

## Resolving nested `do_step` agents

1. `TaskList` returns the run's live agents; each carries the `session_id` and the
   step id baked into its dispatch.
2. Match each task to the rendered node by step id — that is how a nested
   `do_step` agent (own `session_id`) is placed against the tree the run-record
   produced.
3. `Monitor` a specific agent's `session_id` when you need finer liveness detail
   than `TaskList`'s summary (e.g. confirming a suspected wedge before reaping).

## Handoff

The overlay is READ-ONLY. When it surfaces a dead or over-age node, the DRIVER
acts on it through the supervision policy in `skills/auto/SKILL.md` §4 — reap the
live agent (TaskStop then SIGTERM), `auto-resume.py retry`, and pause-escalate at
attempt N=2. This skill never reaps, retries, or escalates itself.
