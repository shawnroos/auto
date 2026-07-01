---
name: auto-driver
description: >
  Orient before /auto starts. Loads the hypothesis JSON from
  lib/auto-detect.sh, surfaces one action line, dispatches when
  ambiguity is null, or asks one blocking question when it isn't.
  No verdict-tree enumeration, no recipe-picker prose. Hands off to
  lib/auto.sh (single plan) or lib/auto-spawn.py (multi-plan batch).
  Distinct from the `auto` skill (the loop driver): auto-driver runs
  BEFORE the run starts; `auto` takes over AFTER it's armed.
---

# auto-driver

One action line per branch. Dispatch. Do not narrate.

## Load the hypothesis

Set `CLAUDE_AUTO_CONVERSATION_SIGNAL=1` inline when THIS session is worth routing
on (a just-built plan / imperative about existing work) so it preempts stale plans; else drop it:

```
CLAUDE_AUTO_CONVERSATION_SIGNAL=1 bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-detect.sh"
```

If the detector yields NO parseable envelope (empty/non-zero — an env hiccup, not
a normal path; it otherwise always emits + exits 0), don't stall: treat as `raw`.

Returns one JSON object with `situation`, `summary`, `ambiguity`,
`single_plan`, `multi_plan`, `in_flight`, `workspace`,
`workspace_action`, `recommendation` (driver-filled, U2). Surface
`summary`; act on `situation` + `ambiguity`:

| situation         | ambiguity null → dispatch                                                    | ambiguity non-null → AskUserQuestion |
|-------------------|------------------------------------------------------------------------------|--------------------------------------|
| `in-flight`       | (FRESH run) `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"` | (STALE run) options = resume vs start-fresh; on the resume option (carries `run_id`) → `auto-resume.sh "continue <run-id>"`; on "Start fresh" (`run_id` null) → treat as `raw` (ask what to work on) |
| `ambiguous-runs`  | (n/a — always ambiguous)                                                     | options = the in-flight run-ids; on answer, resume the chosen run |
| `reviewed-plan`   | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<path> --recipe w"`               | (n/a — single plan unambiguous)      |
| `multi-plan`      | (n/a — multi-plan ALWAYS asks now; never auto-fans-out)                       | options = each plan (carries `path` → `auto.sh "<path>"`, runs just that one) + a "Fan out all N" option (`path` null → `auto-spawn.py fanout <multi_plan.paths>`) |
| `conversation-context` | classify state → recommend → author goal → dispatch entry recipe (see below) | (n/a — pre-dispatch escalate if unsure) |
| `raw`             | (n/a — always ambiguous)                                                     | open "what should we work on?"; on answer, route as freeform text. Summary may include dirty-tree context. |

**Argument-aware freeform** (before loading the hypothesis): a plan-file path →
`auto.sh "<path> --recipe w"`. Else `python lib/verb-classify.py "$ARGUMENTS"`:
`work`→WORK a discovered plan (none? you decide); `both`→`/ce-plan` then work; `plan`/`ambiguous`→`/ce-plan <ARGUMENTS>`.

**Workspace handling** (plan 004): branch on `workspace_action`.
`create`/`recreate`: chain in ONE Bash call so the workspace id
propagates: `WS=$(python lib/auto-workspace.py create <repo> [--force]
--print-id) && CMUX_WORKSPACE_ID="$WS" python lib/auto-spawn.py fanout`.
`use`/`none`: dispatch. `ambiguous`: ask switch/create/one-off.

**Conversation-context** (signal set at load above; full detail in
`driver-reference.md` §11): classify the session (transcript + ~2-day
`ce-sessions` lookback, NOT raw compaction) → `python lib/recommender.py
<state> <confidence>`. `escalate`/ambiguous → one AskUserQuestion, no run.
`kind=skill` → recommend the ce command. `kind=recipe` → `auto-author-goal`
(bind auto's OWN predicate, NEVER native `/goal`) → `bash lib/auto.sh "<goal-doc> --recipe <name>"`.

**Unknown situation** (defensive guard): treat as `raw`.

## Dispatch grammar (reference)

- Single plan: `bash lib/auto.sh "<plan-path> [auto] [--review-plan]
  [--adapter ce|native] [--goal <text>] [--recipe <name>]"`
- Batch fanout: `python lib/auto-spawn.py fanout <plan> [<plan>...]
  [--intent "<text>"]` — the spawner owns worktrees/ports/sidecar +
  dispatch; the driver never shells out per sub-run.
- Resume: `bash lib/auto-resume.sh "<continue|abort|retry|skip>
  [<run-id>] [<unit>]"`

Theory + edge cases: `docs/contracts/driver-reference.md` covers
prepare/execute, goal binding, tick/seam/fan-out, exit reasons, and
conversation-context (§11) — load only when not covered inline.