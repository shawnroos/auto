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

Returns one JSON object: `{ situation, summary, ambiguity, single_plan,
multi_plan, in_flight }`. Surface `summary` (one line). Then act on
`situation` + `ambiguity`:

| situation         | ambiguity null → dispatch                                                    | ambiguity non-null → AskUserQuestion |
|-------------------|------------------------------------------------------------------------------|--------------------------------------|
| `in-flight`       | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"`        | (n/a — single run unambiguous)       |
| `ambiguous-runs`  | (n/a — always ambiguous)                                                     | options = the in-flight run-ids; on answer, resume the chosen run |
| `reviewed-plan`   | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<path>"`                          | (n/a — single plan unambiguous)      |
| `multi-plan`      | `python "${CLAUDE_PLUGIN_ROOT}/lib/auto-spawn.py" fanout <plan...>` then surface manifest | (n/a — confirm-only in `summary`)    |
| `dirty-tree`      | `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<derived-args>"`                  | (n/a — summary is the confirm)       |
| `raw`             | (no signal — always ambiguous)                                               | open question; on answer, route as freeform text |

**Freeform text** (operator typed `/auto <text>` with no resolvable
plan): invoke `/ce-plan <text>` via the Skill tool and end the turn.
The operator re-invokes `/auto` after the plan lands. `/ce-plan` is a
multi-turn skill — there is no in-session return to this driver.

**Unknown situation** (defensive guard): treat as `raw`. Recommend
`/ce-plan` and stop.

## Dispatch grammar (reference)

- Single plan: `bash lib/auto.sh "<plan-path> [auto] [--review-plan]
  [--adapter ce|native] [--goal <text>] [--recipe <name>]"`
- Batch fanout: `python lib/auto-spawn.py fanout <plan> [<plan>...]
  [--intent "<text>"]` — spawner creates worktrees + ports + sidecar
  AND dispatches each backgrounded `/auto <plan>` via cmux. The
  driver does NOT shell out per sub-run; the spawner owns dispatch.
- Resume: `bash lib/auto-resume.sh "<continue|abort|retry|skip>
  [<run-id>] [<unit>]"`

## Theory + edge cases

`docs/contracts/driver-reference.md` — sections on prepare/execute,
goal binding, tick intents, seam semantics, work-loop fan-out, exit
reasons, batch fanout. Load only when you hit something this skill
doesn't cover inline.
