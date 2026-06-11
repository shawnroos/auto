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

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-detect.sh"
```

Returns one JSON object with `situation`, `summary`, `ambiguity`,
`single_plan`, `multi_plan`, `in_flight`, `workspace`,
`workspace_action`, `recommendation` (driver-filled, U2). Surface
`summary`; act on `situation` + `ambiguity`:

| situation         | ambiguity null → dispatch                                                    | ambiguity non-null → AskUserQuestion |
|-------------------|------------------------------------------------------------------------------|--------------------------------------|
| `in-flight`       | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"`        | (n/a — single run unambiguous)       |
| `ambiguous-runs`  | (n/a — always ambiguous)                                                     | options = the in-flight run-ids; on answer, resume the chosen run |
| `reviewed-plan`   | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<path>"`                          | (n/a — single plan unambiguous)      |
| `multi-plan`      | `python "${CLAUDE_PLUGIN_ROOT}/lib/auto-spawn.py" fanout <plan...>` then surface manifest | (n/a — confirm-only in `summary`)    |
| `conversation-context` | classify state → recommend → author goal → dispatch entry recipe (see below) | (n/a — pre-dispatch escalate if unsure) |
| `raw`             | (n/a — always ambiguous)                                                     | open "what should we work on?"; on answer, route as freeform text. Summary may include dirty-tree context. |

**Argument-aware freeform**: before loading the hypothesis, if
`$ARGUMENTS` is non-empty AND does NOT resolve to a plan file, invoke
`/ce-plan <ARGUMENTS>` via Skill and end the turn (v0.3.x routing).

**Workspace handling** (plan 004): branch on `workspace_action`.
`create`/`recreate`: chain in ONE Bash call so the workspace id
propagates: `WS=$(python lib/auto-workspace.py create <repo> [--force]
--print-id) && CMUX_WORKSPACE_ID="$WS" python lib/auto-spawn.py fanout`.
`use`/`none`: dispatch. `ambiguous`: ask switch/create/one-off.

**Conversation-context** (v0.6.0, full detail in `driver-reference.md`
§11/§13): classify the current transcript + a ~2-day `ce-sessions` lookback
(NOT raw compaction) into one state → `python lib/recommender.py <state>
<confidence>`. `escalate`/ambiguous → one AskUserQuestion BEFORE dispatch,
no run (NOT via the gate). `kind=skill` (bug/what-to-improve/perf) → recommend
the ce command, no wrap. `kind=recipe` (vague→`pipeline`@brainstorm — the spine,
auto-advances brainstorm→plan→work; clear-intent→`a1`@plan; reviewed-plan→`w`@work;
code-unreviewed→`review`@work) → `auto-author-goal` → goal doc (bind auto's OWN
predicate, NEVER native `/goal`) → `bash lib/auto.sh "<goal-doc> --recipe <name>"`.

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