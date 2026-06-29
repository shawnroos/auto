# Spinoff: /auto drive-friction fixes — backstop false-positives + verdict CLI

> This handoff is directional — author intent and a starting point, enough to orient and begin, not a spec to execute literally. The code and tests are the source of truth: validate against them and expect to refine.

> **Directional handoff.** Verified diagnosis + intent, not a spec. Validate against
> the auto code before changing; the fix shapes below are starting hypotheses.

## Goal
Fix the two things that made `/auto` 0.6.6 high-friction to drive a real feature build:
1. **Destructive-action backstop false-positives** on benign `rm -rf` (temp/test
   cleanup) — it pauses & latches the run on non-destructive ops.
2. **Missing CLI surface** for driving the work-loop — no `record-verdict` CLI, and
   dispatch is Python-API-only — so an operator must hand-drive and keep the ledger
   honest by hand.

## Why now / context (field report)
An agent used `/auto` 0.6.6 to build a significant feature and hit both walls:
- Drove `ce-work` per unit by hand because the plumbing was hard to drive faithfully
  (no verdict CLI; dispatch harness is a Python API), keeping the ledger honest
  manually. Serialized the build in dependency order (units shared files / tight
  interfaces — each agent built on the last's real output), not parallel.
- The **destructive backstop false-fired 7×** on `rm -rf` in test cleanup (fan-out
  agents' `$TMPDIR` teardown) **+ once** on the operator's own finalize command — none
  were real destructive ops. **The ledger is consequently left PAUSED (backstop
  latched).**
This reinforces existing memory `auto_v066_drive_gotchas` (backstop pauses on
incidental rm -rf; record_verdict not in CLI; /auto-resume pause for human walls).
Treat that memory as corroborating field data.

## Key facts established (verified in code 2026-06-27)
- **Backstop matches `rm -rf` on ANY path.** `lib/on-pretooluse-action.py:102`:
  `("rm -rf", re.compile(r"\brm\s+-rf\b"))`. The matcher has no path awareness — it
  fires on `rm -rf "$TMPDIR/foo"`, scratch teardown, and finalize cleanup exactly the
  same as `rm -rf ~/important`. It IS driver-gated (driver=="self" → gated;
  "manual" → allow) and fail-closed on confirmed-destructive + confirmed-live-run, but
  path scope is the gap.
- **`record_verdict` exists but isn't a CLI verb.** `lib/ledger.py:102`
  `record_verdict = ledger_mutators.record_verdict` (importable), but the `_cli`
  dispatch only exposes read / path / transition / is-orphaned / set-gaps-open /
  set-enumerated-units (lines ~135-174). No `record-verdict`, no dispatch verb. Hence
  "drove ce-work by hand / kept the ledger honest manually."
- **Branch base:** `~/projects/auto` `main` in sync with origin (`280329e`) — branch
  off current HEAD.

## Open questions / not yet decided
- **Backstop path-scoping — what's exempt?** Candidates: `$TMPDIR`, `/tmp`,
  `/private/tmp`, an agent/scratch dir, and any path OUTSIDE the repo root + `$HOME`
  dotfiles. A `rm -rf` of an ephemeral temp dir is not the irreversible op the backstop
  exists to catch. Decide the exemption rule precisely — fail-closed must remain for
  real repo/home deletes (don't over-open the backstop). Consider: only gate `rm -rf`
  when the target resolves under the repo root or a protected set; allow ephemeral.
- **Distinguish fan-out-agent cleanup from operator commands?** The 7 false-positives
  were sub-agent `$TMPDIR` teardown; the 1 was the operator's finalize. Both are
  benign temp ops — path-scoping likely covers both, but confirm the finalize case.
- **Verdict CLI shape.** Add `record-verdict <run> <unit> <decision> [json]` (and
  maybe a dispatch verb) to `ledger.py` `_cli`, mirroring the existing set-* verbs, so
  the work-loop is drivable without the Python API. What's the minimal verb set to
  make hand-driving faithful? (record-verdict at least; possibly set-verdict-decision,
  which also exists as a mutator at `ledger.py:107`.)
- **Unlatch the currently-paused ledger.** The field run's ledger is paused/latched —
  is that this workstream's concern (provide a clean unlatch/resume path) or just the
  operator's `/auto-resume`? At minimum, verify resume works once the backstop is fixed.
- **Regression tests.** Add cases: `rm -rf $TMPDIR/x` → ALLOW; `rm -rf <repo>/x` →
  GATE; `record-verdict` CLI round-trips into the ledger.

## Starting point (concrete)
- Repo `~/projects/auto` (branch from `main` `280329e`).
- Backstop: `lib/on-pretooluse-action.py` — the `_DESTRUCTIVE` regex list (~line 102),
  `_matched_destructive()` (~120), and the driver-gating logic (~168-193). The fix is
  path-aware exemption inside/around `_matched_destructive`.
- CLI: `lib/ledger.py` `_cli` dispatch (~135-174) + the imported mutators
  `record_verdict` (102) / `set_verdict_decision` (107). Add verb(s) mirroring
  `set-enumerated-units`.
- Tests: the repo's `tests/` (there are existing `hooks.test.sh`, `advisor-gate`,
  backstop-related integration tests) — extend them.
- **Adjacent in-flight auto worktrees:** `resume-stdout-json` (touches
  `auto-resume.py`/`tick_advance`/**`ledger.py`** — likely CLI-area overlap, coordinate)
  and `auto-looper-forks`. Rebase on main before landing.

## Recommended next step
`/ce-plan` — two concrete, well-scoped fixes (path-scope the backstop; add the verdict
CLI) plus tests; the only real design call is the exemption rule. A short plan that
keeps fail-closed for real deletes, then `/ce-code-review`. Could split the backstop
fix to `/ce-debug` if you want to repro the false-positive first. Validate the
exemption rule against `on-pretooluse-action.py` before writing.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
