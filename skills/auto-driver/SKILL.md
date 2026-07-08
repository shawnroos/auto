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

If the detector yields no parseable envelope (empty/non-zero env hiccup), don't stall — treat as `raw`.

Returns one JSON object with `situation`, `summary`, `ambiguity`,
`single_plan`, `multi_plan`, `in_flight`, `workspace`,
`workspace_action`, `recommendation` (driver-filled, U2). Surface
`summary`; act on `situation` + `ambiguity`:

| situation         | ambiguity null → dispatch                                                    | ambiguity non-null → AskUserQuestion |
|-------------------|------------------------------------------------------------------------------|--------------------------------------|
| `in-flight`       | (FRESH run) `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "continue <run-id>"` | (STALE run) options = resume vs start-fresh; on the resume option (carries `run_id`) → `auto-resume.sh "continue <run-id>"`; on "Start fresh" (`run_id` null) → treat as `raw` (ask what to work on) |
| `ambiguous-runs`  | (n/a — always ambiguous)                                                     | options = the in-flight run-ids; on answer, resume the chosen run |
| `reviewed-plan`   | run the **goal-aware pre-step** below first; if it does not reshape, load `auto-launch` (the launch chooser) via Skill: it gates on `driving_session_id` — self-driven silent-applies, interactive confirms — then dispatches `lib/auto.sh "<path> --recipe w"` | (n/a — single plan unambiguous)      |
| `multi-plan`      | (n/a — always asks; only genuinely-competing plans reach here, §9). Run the **goal-aware pre-step** below first | options = each plan (`path` → `auto.sh "<path>"`); a "Fan out all N" option (`path` null → `auto-spawn.py fanout`) appears ONLY when the set is fresh |
| `conversation-context` | classify state → recommend → author goal → dispatch entry recipe (see below) | (n/a — pre-dispatch escalate if unsure) |
| `raw`             | (n/a — always ambiguous)                                                     | open "what should we work on?"; on answer, route as freeform text. Summary may include dirty-tree context. |

## Goal-aware plan routing (pre-step)

Runs for `reviewed-plan` and `multi-plan` **only**, and **only on interactive
runs** (`driving_session_id` null — self-driven/headless runs skip this whole
step and take the row above unchanged; the confirm gate that makes it safe
cannot fire on them). Full rubric: `references/goal-plan-relevance-rubric.md`.

1. **Recover the goal for THIS invocation** from the context window: the typed
   `/auto` intent, or the text of a `/goal <…>` bound in the current session for
   this invocation (explicit); else infer from the session (advisory). Read
   `/goal` text only — never query/run/bind/clear it. Ignore a `/goal` bound for
   a prior completed run (the ~2-day `ce-sessions` lookback is for session
   classification, not goal recovery). If a bound `/goal`'s text is not reliably
   recoverable, degrade to inferred/no-goal.
2. **Weight the plans** (`multi_plan.paths` / `single_plan.path`) against the
   goal using the rubric's observable match bar: a plan matches when its stated
   Objective/Summary names the goal's target outcome (not filename or freshness).
3. **Route** — pick exactly one branch:
   - `explicit-suppress` — explicit goal + ≥1 match → goal-ranked pick-one
     `AskUserQuestion` (`path` → `auto.sh "<path>"`), top match preselected,
     **fan-out-all suppressed**, confirm even on a single match.
   - `inferred-re-rank` — inferred goal + ≥1 match → same ask, top match
     preselected, but **keep** the fan-out-all option.
   - `no-match-unchanged` — goal present, no plan matches → act on the row above
     unchanged (freshness verdict, fan-out-all offered when the set is fresh).
   - `no-goal-unchanged` — no goal recovered → act on the row above unchanged.

The detector (`lib/auto-detect.py`) is untouched by this — it still emits
`reviewed-plan`/`multi-plan` on freshness; this pre-step reshapes the routing
before dispatch and never changes the detector's verdict.

**Argument-aware freeform** (pre-hypothesis): a plan-file path → load `auto-launch`
→ `auto.sh "<path> --recipe w"`. Else classify with `lib/verb-classify.py`, then hand
to the `auto-launch` chooser (self-driven → silent-apply) for the class's route —
work the freshest plan / `clear-intent-no-plan`→`a1`@plan / `/ce-plan` (§14, §15).

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