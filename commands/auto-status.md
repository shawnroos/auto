---
argument-hint: "[<run>]"
allowed-tools: Bash
---

Show the ledger and health of an auto run.

`/auto-status [<run>]` reads the durable ledger at
`<repo>/.claude/auto/<run-slug>.json` and reports the loop phase, the
cached exit-predicate result (blockers / majors / minors / gaps_open and
whether it is met), per-unit states, the driver (`self` while a tick chain
is self-pacing, `manual` when paused awaiting resume), and liveness
(`last_beat_at` vs the orphan GRACE). It surfaces stalled units with their
`last_error` cause and, at exit, the remaining minors report for operator
promotion.

It is read-only — it never mutates the ledger or arms a tick.

Argument forms (parsed inside `lib/auto-status.sh`, not here):

- **No args**: report the most recent / only active run in this repo.
- **Run id**: `/auto-status feat-foo-2026-05-21` — report that run.

Empty args -> `lib/auto-status.sh` resolves the active run, or prints usage and
exits cleanly if none exists.

To dispatch, run:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-status.sh" "$ARGUMENTS"`
