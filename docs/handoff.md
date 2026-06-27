# Spinoff: fix /auto resume printing non-JSON parse noise on stdout

## Goal
`/auto:auto-resume continue` (and the seam→work resume path) must emit **only**
the machine-readable re-arm JSON on stdout. Today a resumed agent reports "the
resume printed a non-JSON message (parse noise), but set-enumerated-units
succeeded" — i.e. prose is leaking onto the same stdout stream that carries the
`{"action":"arm-tick", …}` envelope, so the driving agent can't cleanly parse the
re-arm intent and starts rationalizing past the ledger step.

## Why now / context
Field report from an agent driving an `/auto` resume: the ledger op worked
(`set-enumerated-units` succeeded) but the resume's stdout was polluted, so the
agent treated the re-arm as "ceremony" noise and skipped straight to building.
That's a contract break: `lib/tick.sh` documents stdout as "re-arm INTENT as JSON",
and `_emit_rearm` honors it — but something else on the resume path is writing
human prose to stdout in the same invocation, ahead of (or around) the JSON.

## Key decisions / facts already established (verified in the code, 2026-06-27)
- **The JSON emitter is correct.** `lib/auto-resume.py:_emit_rearm` (line 97)
  `json.dump({"action":"arm-tick","run":…,"prompt":"/auto:auto-tick …","note":…},
  sys.stdout)` + a trailing newline. Clean. Don't change this.
- **The obvious suspects are already clean** (so the bug is NOT here):
  - `_rearm_owns_session` (called before `_emit_rearm`) writes **only to stderr**
    on refusal and returns 0 silently on success.
  - `ledger.py set-enumerated-units` returns 0 **silently**; all errors → stderr.
  - The early-return prose lines in `auto-resume.py` (e.g. line 190 "already done")
    go to stdout but only on terminal no-op paths, not the continue→rearm path.
- **Prime suspect: the seam→work path.** `_cmd_continue` (line 181) on
  `phase == "seam"` calls `tick.advance_to_phase(repo_root, run_id, led,
  to_phase="work")` (line 206) BEFORE `_emit_rearm` (line 207). `advance_to_phase`
  is where the recipe's **phase-transition emitter** runs and where
  `set_enumerated_units` is persisted (see `lib/tick_advance.py` ~338-422, the
  "U5b phase-transition emitter" referenced at line 398). Hypothesis: that emitter
  (or a helper it calls) prints a human status line to **stdout**, landing ahead of
  the JSON → exactly the "non-JSON message, but set-enumerated-units succeeded"
  symptom. **Confirm by tracing every print/sys.stdout.write reachable from
  `advance_to_phase`.**
- **Branch base is clean.** `~/projects/auto` local `main` == `origin/main`
  (`05efed9`), in sync — branch off current HEAD.

## Open questions / not yet decided
- **Exact leak site:** which call under `advance_to_phase` writes to stdout? (Could
  also be an adapter/recipe emitter, or a `logging` handler configured to stdout
  rather than stderr.) Pin it before fixing.
- **Fix shape:** enforce a hard "stdout = JSON only, stderr = all human prose"
  discipline across the resume + tick-advance path. Options: (a) route the emitter's
  status prose to stderr; (b) capture/suppress emitter stdout inside
  `advance_to_phase` and re-emit nothing; (c) make the consumer parse only the last
  stdout line. (a) is the cleanest and matches `tick.sh`'s stated contract — confirm.
- **Regression guard:** add a test that runs a seam→work resume and asserts stdout
  is *exactly one* JSON object (json.loads on full stdout succeeds), prose only on
  stderr. This bug is invisible without it (the JSON is still there, just buried).
- **Scope:** is `continue` (non-seam, line 218 path) also affected, or only
  seam→work? The non-seam path skips `advance_to_phase`, so likely seam-only —
  verify rather than assume.

## Starting point (concrete)
- Repo: `~/projects/auto` (origin `shawnroos/auto`), branch from `main` (`05efed9`).
- `lib/auto-resume.py` — `_emit_rearm` (97), `_cmd_continue` (181), the
  `advance_to_phase` call (206). 445 lines, small enough to read whole.
- `lib/tick_advance.py` — `advance_to_phase` + `_persist_enumerated_units` (338) +
  the U5b emitter (~398-422). **Trace stdout writes from here down.**
- `lib/tick.sh` — documents the stdout=JSON re-arm contract (top-of-file comment).
- `lib/ledger.py` set-enumerated-units (163) — already clean, reference only.
- Consumer side: `skills/auto/SKILL.md` (resume step ~80, 126) and
  `commands/auto-resume.md` — how the agent is told to parse resume output; the fix
  may want a one-line contract note here too.
- Other live `auto` worktrees exist (auto-conversation-entry, auto-plugin-fixes,
  loop-planning-opt) but none touch `auto-resume.py` — low collision risk.

## Recommended next step
`/ce-debug` — this is a localized, well-specified bug with a strong hypothesis and a
reproducible symptom; debug-trace the stdout leak from `advance_to_phase`, fix the
channel discipline, add the "stdout is exactly one JSON object" regression test.
If you'd rather plan first it's small enough to go straight to a fix. Validate the
hypothesis against the actual `advance_to_phase` code before changing anything.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
