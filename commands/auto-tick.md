---
argument-hint: "<run> [--auto] [--delay N] [--repo PATH]"
allowed-tools: Bash, Skill
---

Advance an auto run by ONE tick — the self-pacing entry the loop re-arms
into.

This command is fired by a `ScheduleWakeup`-armed prompt (`prompt:
"/auto:auto-tick <run>"`), emitted as the `rearm` intent by every prior tick
(`lib/tick.py`), by `/auto` at arm time (`lib/auto.py`), and by
`/auto-resume continue` (`lib/auto-resume.py`). It is the durable
heartbeat of the loop: one tick = one smallest-useful advance of the
state machine + one atomic ledger write.

## Dispatch

Run the tick. The harness substitutes the argument string before bash
runs; all `$`-logic lives in `lib/tick.sh` / `tick.py`, never in this
`.md` (memory `feedback_slash_command_arg_substitution`):

`bash "${CLAUDE_PLUGIN_ROOT}/lib/tick.sh" "$ARGUMENTS"`

## Act on the emitted intent

`tick.sh` prints a re-arm INTENT dict as JSON on stdout. `tick.py`
CANNOT call `ScheduleWakeup` (that is a model tool, not a CLI) — so YOU
must act on the intent. If the `auto` skill is not already loaded in this
context, load it via the Skill tool (`auto`) and follow its §2 tick
dispatch table. The contract in brief:

| `action` | phase | what you do |
|----------|-------|-------------|
| `rearm`  | `plan` | `ScheduleWakeup(intent.delay, intent.prompt)` — short delay; then run the prepared plan-loop invocation and feed results back |
| `rearm`  | `work` | YIELD; the harness re-invokes you when a verdict lands. LONG `ScheduleWakeup` (1200s+) ONLY when no work is in flight AND no ready units |
| `stop`   | any   | the chain ends — do NOT re-arm. `predicate-met*` → report; `seam-pause` → surface the seam |
| `noop`   | any   | another live tick holds the lock — do nothing |

Never re-arm on `stop` / `noop`. Never short-poll the work-loop. The
`prompt` field of a `rearm` intent is itself `/auto:auto-tick <run>` — that is
how the loop sustains itself.
