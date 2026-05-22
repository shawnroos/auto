---
argument-hint: "[continue|abort|retry|skip] [<run>] [<unit>]"
allowed-tools: Bash
---

Manually resume a dispatch run — the F4 floor.

A self-paced `ScheduleWakeup` tick chain does NOT survive a full session
exit (in-session only; durable cron is denied by cmux). No work is lost —
the ledger is on disk and each background agent self-writes its verdict
atomically — and resume after any suspend is this one cheap command, which
reads the durable ledger fresh. Resume is also the routine long-run
continuation path (a long run's end-state is a context-exhaust that
surfaces as a normal resume), not just the crash path.

Subcommands (Claude Code does not dispatch space-separated subcommands, so
the subcommand is parsed from the argument string inside `lib/resume.sh`,
not here):

- **`[<run>]`** — default `continue`: re-acquire the run cleanly off the
  durable ledger and arm a fresh tick chain (also flips a paused seam from
  `seam` -> `work`).
- **`continue <run>`** — explicit continue.
- **`abort <run>`** — flip the run to `done` with a cancellation marker.
- **`retry <run> <unit>`** — reset a `stalled` unit to `pending` and clear
  its `last_error`, re-enabling its advance and its dependents'.
- **`skip <run> <unit>`** — mark a `stalled` unit `terminal-skip` (counts
  as terminal); skip it and its transitive dependents.

Empty args -> `lib/resume.sh` resolves the resumable run and defaults to
`continue`, or prints usage and exits cleanly if none is resumable.

To dispatch, run:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/resume.sh" "$ARGUMENTS"`
