---
argument-hint: "<run> [--auto] [--delay N] [--repo PATH]"
allowed-tools: Bash, Skill
---

DEPRECATED ALIAS of `/auto:auto-pulse` (concept-vocabulary rename U5: tick →
pulse). Kept one minor version and NOT removable yet: in-flight runs have
`/auto:auto-tick <run>` persisted inside a `ScheduleWakeup` prompt and in stale
rearm-intent JSON, so deleting this file would wedge them mid-run. New rearms
are built as `/auto:auto-pulse <run>` (`lib/_bootstrap.py::PULSE_COMMAND`).
Same body as `commands/auto-pulse.md`; it runs the SAME engine (`lib/pulse.sh`).

Advance an auto run by ONE pulse — the self-pacing entry the loop re-arms
into.

This command is fired by a `ScheduleWakeup`-armed prompt (`prompt:
"/auto:auto-pulse <run>"`), emitted as the `rearm` intent by every prior pulse
(`lib/pulse.py`), by `/auto` at arm time (`lib/auto.py`), and by
`/auto-resume continue` (`lib/auto-resume.py`). It is the durable
heartbeat of the loop: one pulse = one smallest-useful advance of the
state machine + one atomic ledger write.

## Dispatch

Run the pulse. The harness substitutes the argument string before bash
runs; all `$`-logic lives in `lib/pulse.sh` / `pulse.py`, never in this
`.md` (memory `feedback_slash_command_arg_substitution`):

`bash "${CLAUDE_PLUGIN_ROOT}/lib/pulse.sh" "$ARGUMENTS"`

## Act on the emitted intent

`pulse.sh` prints a re-arm INTENT dict as JSON on stdout. `pulse.py`
CANNOT call `ScheduleWakeup` (that is a model tool, not a CLI) — so YOU
must act on the intent. If the `auto` skill is not already loaded in this
context, load it via the Skill tool (`auto`) and follow its §2 pulse
dispatch table. The contract in brief:

| `action` | phase | what you do |
|----------|-------|-------------|
| `rearm`  | `plan` | `ScheduleWakeup(intent.delay, intent.prompt)` — short delay; then run the prepared plan-loop invocation and feed results back |
| `rearm`  | `work` | YIELD; the harness re-invokes you when a verdict lands. LONG `ScheduleWakeup` (1200s+) ONLY when no work is in flight AND no ready units |
| `stop`   | any   | the chain ends — do NOT re-arm. `predicate-met*` → report; `handoff-pause` → surface the handoff |
| `noop`   | any   | another live pulse holds the lock — do nothing |

Never re-arm on `stop` / `noop`. Never short-poll the work-loop. The
`prompt` field of a `rearm` intent is itself `/auto:auto-pulse <run>` — that is
how the loop sustains itself (this alias exists only for the prompts armed
BEFORE the rename).
