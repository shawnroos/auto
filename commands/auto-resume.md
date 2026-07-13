---
argument-hint: "[continue|advance|pause|abort|retry|skip] [<run>] [<unit>] | freeform sentence"
allowed-tools: Bash, AskUserQuestion
---

Manually resume an auto run — the F4 floor.

A self-paced `ScheduleWakeup` pulse chain does NOT survive a full session
exit (in-session only; durable cron is denied by cmux). No work is lost —
the ledger is on disk and each background agent self-writes its verdict
atomically — and resume after any suspend is this one cheap command, which
reads the durable ledger fresh. Resume is also the routine long-run
continuation path (a long run's end-state is a context-exhaust that
surfaces as a normal resume), not just the crash path.

## Argument handling (dispatcher routes BEFORE invoking the script)

Inspect the argument string and resolve to one of these four canonical forms,
then invoke the script with exactly that form:

| Canonical                  | Effect                                                              |
| -------------------------- | ------------------------------------------------------------------- |
| `continue [<run>]`         | Re-acquire, arm a fresh pulse chain, flip paused handoff to `work`.     |
| `advance [<run>]`          | Declare the current phase satisfied and move on. In the plan phase: mark the plan done (skip re-planning) and arm a pulse to enumerate work units. At a handoff: same as `continue`. In the work phase: no-op. |
| `pause <run> [why]`        | Blocked on a human/external action — flip to manual, record why, stay resumable. NOT a cancellation. |
| `abort <run>`              | Flip the run to `done` with a cancellation marker. **Destructive.** |
| `retry <run> <unit>`       | Reset stalled unit to pending, clear `last_error`.                  |
| `skip <run> <unit>`        | Mark stalled unit `terminal-skip`, skip its transitive dependents.  |

Routing rules:

1. **Empty** — invoke with no args; the script resolves the resumable run
   and defaults to `continue` (safe). If none is resumable, it prints
   usage and exits cleanly.

2. **Already in canonical form** (starts with a subcommand keyword) —
   pass through verbatim to the script.

3. **Freeform sentence** — interpret intent into one of the four canonical
   forms:
   - "keep going" / "resume" / "pick up where we left off" → `continue`
   - "the plan's done, move on" / "stop re-planning, it's ready" / "skip to the work" → `advance <run>`
   - "stop it" / "kill the run" / "cancel" → `abort <run>` (DESTRUCTIVE — must confirm via AskUserQuestion, see below)
   - "retry the failing one" / "try unit X again" → `retry <run> <unit>`
   - "skip the broken one" / "give up on that unit" → `skip <run> <unit>`

4. **Ambiguous on EITHER axis** — fire `AskUserQuestion`:
   - **Run ambiguous** (multiple resumable / "the auth one" matches two)
     — list candidates with most-recent as Recommended.
   - **Unit ambiguous** (retry/skip with multiple stalled units) — first
     `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh"` to enumerate the
     stalled units, then `AskUserQuestion` with each as an option (include
     each unit's `last_error` in its description so the user can choose
     informed).
   - **Subcommand ambiguous** (e.g. "fix the run" — retry? skip? abort?)
     — list the candidates with descriptions of what each does, no
     recommendation when destructive options are in play.

5. **Destructive ops** (`abort`) — even when intent looks clear, fire
   `AskUserQuestion` confirming the run id before dispatching. "Stop the
   run" with one active run should still surface a yes/cancel prompt.

After routing, the resolved canonical-form string goes verbatim to the
script — the script remains the single source of truth for the actual
state-machine transitions; dispatcher routing is purely a parse-and-pick
layer above it.

## Dispatch

If the argument string is empty or already in canonical form, run the dispatch
line below directly (the harness substitutes the argument string before bash
runs):

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-resume.sh" "$ARGUMENTS"`

On the re-arm paths (`continue` / `advance`), the script writes **exactly one
JSON object** to stdout — the `{"action":"arm-pulse", …}` intent. Parse the whole
of stdout with `json.loads`; there is no prose to strip. All human/diagnostic
text goes to stderr, never to stdout. (Terminal no-op paths — already-done,
work-phase advance, abort/retry/skip — print a human status line to stdout
instead and emit no arm-pulse intent.)

If you resolved a freeform sentence into a different canonical form
(`continue X`, `abort X`, `retry X U`, `skip X U`), invoke the Bash tool
explicitly with that resolved string rather than going through the
substitution path — and for `abort`, confirm via AskUserQuestion first.
