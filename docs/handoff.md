# Spinoff: auto — reliability fixes from the Stop-hook bug + a hand-driven `w` run debrief

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
Land a batch of concrete `/auto` enhancements + fixes drawn from two debriefs: (1) a
proven Stop-hook bug that false-blocks on auto's own `rules.json`, and (2) ten
findings from driving a real `w` (work-only) run largely by hand. Target the
highest-impact, real-regardless-of-drive-path `[engine]` bugs first.

## Why now / context
Shawn just (a) hit the Stop-hook block on a session that never started a run, run to
ground as a real bug, and (b) drove a 7-step `w` run by hand end-to-end and wrote a
field-notes debrief. Both produced specific, fixable defects in the live engine.

## Key decisions already made
- **Target the canonical dev repo `~/projects/auto`** (github.com/shawnroos/auto),
  base fresh `origin/main`. Per the publish workflow: edit/PR here, then re-vendor the
  published snapshot into shrimpshack — do NOT edit the shrimpshack vendored copy.
- **Both source docs are OUTSIDE a fresh origin/main worktree** — their substance is
  embedded below, but read the originals too (absolute paths):
  - `~/projects/auto/docs/research/2026-07-21-stop-hook-blocks-on-rules-json.md`
    (untracked in main — the Stop-hook `rules.json` bug, full diagnosis + proposed fix)
  - `~/projects/shrimpshack/plugins/auto/docs/field-notes-2026-07-21-w-run-debrief.md`
    (the `w`-run debrief). It's field notes ON auto but lives only in the shrimpshack
    copy — consider bringing it into `~/projects/auto/docs/` as part of this work.
- **This is a multi-fix batch, not one change** — each finding is discrete. Plan it as
  steps, land the `[engine]` P1s first, defer `[manual-tax]` and the bigger redesigns.
- Engine version at debrief: auto **0.14.0** (local main may lag — it was v0.12.0
  `10529ba`; `git fetch && merge --ff-only origin/main` or archive from origin/main).

## The findings to fix (embedded — the source docs won't be in the worktree)

### A. Stop-hook false-blocks on `rules.json` (PROVEN — my diagnosis)
`iter_worktree_run_records` (`lib/_bootstrap.py`, the `.claude/auto/*.json` glob)
treats EVERY parseable JSON as a run-record — including `rules.json`, auto's own
persona-rules config in the same dir. It has no `loop_phase` → `current_phase`
defaults to `"plan"` (non-terminal), no `loop` (no carve-out applies), no met
predicate → `on-stop.py`'s `_is_blocking` blocks stop **forever**, from any session
under `~` (home resolves repo_root to `~`). Proven by execution: the glob yields
`run_id='rules' phase='plan' met=None keys=['format','rules']`.
**Fix the CLASS, not the name:** require a run-record *shape* — skip a loaded dict
lacking `loop`/`loop_phase`/`run_id`. Shared enumerator, so it fixes on-stop,
auto-status, auto-resume, on-pretooluse-action, launch-mode at once. Add a fixture:
a `.claude/auto/` with only `rules.json` yields zero runs + doesn't block. Fail once first.

### B. Field-notes `[engine]` bugs (real regardless of drive path)
1. **`bash run_record.py` mis-executes** — `run_record.py` has a `python3` shebang;
   the emitted `operator_guidance` + persist examples say `bash`, so Python is run as
   shell → silently corrupts the **verdict write** (the loop's spine). Fix: emit
   `python3 …`, or a `run_record.sh` that `exec`s the python. **(Top-3 #1.)**
2. **Agents die mid-verification without a verdict** — two agents ran the slow (>120s)
   Karma suite, yielded to the monitor, got the completion notification, ended at
   `dispatched` with no verdict → death-path re-runs a ~350k-token step. Fix: dispatch
   template mandates "record your verdict BEFORE any long-running background wait";
   better, **split implement from verify** so a flaky verifier can't strand the impl
   verdict. **(Top-3 #2.)**
3. **`ready_steps` returns the `plan` step during `work` phase** — after `plan→work`,
   `dispatcher.ready_steps` returned `['plan','U1']`; a naive driver dispatches
   `/ce-work plan`. Fix: filter steps whose `phase != current_phase`, or terminalize
   the plan step at the phase flip.
4. **`all_steps_terminal:false` next to `met:true`** in the exit report — because the
   plan step never terminalizes; looks like a livelock contradiction. Fix: terminalize
   the plan step, or scope `all_steps_terminal` to the eval phase.
5. **No clean way to fire the pulse** — `arm-pulse` returns `prompt:"/auto:auto-pulse
   <run>"` but that command isn't in the skill list, and re-invoking `auto:auto` is
   circular; the runnable (`lib/pulse.sh`) had to be reverse-engineered. Fix: `arm-pulse`
   result should name the exact runnable (`bash lib/pulse.sh "<run> --auto"`) in a field.
6. **`dispatch_batch`'s `launch_fn` is a no-op** — docs read as "launch_fn maps do_step →
   /ce-work <step-id>," but it's a no-op recorder; the boss hand-builds every agent
   prompt + `record-verdict` + attempt tag. No wrapper turns "dispatch U3" into "spawn a
   ce-work agent scoped to U3 that self-writes its verdict." Nearly triggered an abort.
   Fix: ship a canonical dispatch-prompt template (step packet + verdict-write contract +
   attempt) as a library asset. **(Top-3 #3.)**
7. **`dispatcher.sh digest <run>` errors** — `bad arguments: list index out of range`;
   the whole flat-context-via-digest design depends on it; fell back to full JSON reads.
   Fix: broken for the `w`/work-phase shape — needs a regression test.

### C. Ergonomics / [manual-tax] (lower priority, but #9 overlaps A)
8. Zombie sub-agents re-notify + are invisible to the run-record → hand `TaskStop`.
   Fix: document reap (TaskStop → SIGTERM) in the death-path; record spawned agent-ids
   on the run-record.
9. **Stop hook can't tell "correctly yielding for in-flight work" from "wrongly
   stopping"** — fired an identical blocking message ~10× across the run, even while
   correctly yielding for a live Agent. Fix: when the run-record shows an in-flight
   `dispatched` step with a live watchdog, downgrade to a silent pass. **This is the
   same Stop-hook surface as finding A — fix them together.**
10. Driving required reverse-engineering ~12 internal files (prepare/execute split puts
    a lot on the model). Mostly hidden by the intended armed-chain flow; 1–7 remain.

### D. Environmental (not the engine, but it compounded — worth an engine guard)
- Local Karma flaky in the target repo fed the mid-verification deaths (#2); an engine
  notion of "verification deferred to CI" would help.
- The target worktree's `typecheck` was baseline-RED (ungenerated env file), so every
  "typecheck passes" gate was meaningless until fixed by hand. **No baseline-health
  precheck before a run** — one would catch it before U1, not in U1's verdict.

## Open questions / not yet decided
- **Scope of this batch.** All of A–D, or just the `[engine]` set (A + 1–7)? #2's
  "split implement from verify" and #6's canonical dispatch primitive are the biggest
  changes and may deserve their own steps/plan; the rest are small + surgical.
- **Sequencing.** Suggested P1 first wave: A (stop-hook shape guard), #1 (bash→python3),
  #3/#4 (terminalize plan step — one fix likely resolves both), #7 (digest). Then #6
  (dispatch template), #2 (record-before-yield + maybe the impl/verify split), #5, #9.
- **Publish.** Bump `plugin.json` + marketplace entry, then re-vendor to shrimpshack.
- **Does #3/#4 have one root fix?** Both stem from the plan step never terminalizing at
  the phase flip — likely a single change resolves both. Confirm.

## Starting point
- `lib/_bootstrap.py` (`iter_worktree_run_records` glob — finding A), `lib/on-stop.py`
  (`_is_blocking`, finding A + #9), `lib/dispatcher.py` (`ready_steps`, `dispatch_batch`,
  `launch_fn` — #3/#6), `lib/run_record.py` + its `operator_guidance`/persist strings
  (#1), `lib/pulse.sh` + `arm-pulse` (#5), `dispatcher.sh digest` (#7),
  `phase_grammar.py` (terminalization — #3/#4).
- `docs/contracts/driver-reference.md` (§7/§17), `skills/auto/SKILL.md` (§2/§4),
  `backend-ce.sh`, `workflows.py`.
- Tests: `tests/` — run.sh only tallies a file whose LAST line matches
  `^<name>.test.sh: N passed, M failed` (memory `auto_test_runner_summary_line_tally`);
  see each new test fail once (`new_tests_need_deliberate_fail_smoke_check`).
- Memories: `project_auto_stop_hook_false_blocks_on_rules_json`,
  `project_auto_work_phase_watchdog_gap` (the watchdog #2/#9 relate to),
  `feedback_fix_the_class_not_the_cited_instance`, `feedback_deterministic_over_probabilistic_v1`,
  `feedback_stop_background_agents_taskstop_then_sigterm` (#8 reap), the auto publish
  workflow memory.

## Recommended next step
`/ce-plan` — the findings are concrete and enumerated; this is a fix-batch, not an
open design problem. Plan it as steps grouped by the sequencing above, `[engine]` P1s
first. The two genuine design calls (impl/verify split for #2, canonical dispatch
template for #6) can be their own steps or a follow-on plan. Reproduce each bug before
fixing (finding A already has an execution repro to mirror).

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/d7fba74d-4df6-426b-aeea-a7f3c587a64a.jsonl`
Resume:     `cd /Users/shawnroos && claude -r d7fba74d-4df6-426b-aeea-a7f3c587a64a`
