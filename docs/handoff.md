# Spinoff: make /auto's detector goal-aware (stop N-way fanouts when the goal is well-defined)

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

> **Shipped in v0.11.0** — goal-aware plan routing. The driver recovers the
> operative goal (current `/auto` intent or a current-session `/goal` text;
> else a session inference) and weights discovered plans against it via
> `skills/auto-driver/references/goal-plan-relevance-rubric.md`: an explicit
> match suppresses the fanout and preselects (confirm-gated, interactive only),
> an inferred match only re-ranks, no match / no goal is today's freshness path
> unchanged. The deterministic detector is untouched. See
> `docs/plans/2026-07-08-001-feat-goal-aware-detector-plan.md`.

## Goal
Make `/auto`'s entry detector **goal-aware**. When a goal is bound or clearly
expressed, the detector should use it to select/collapse the work it proposes —
not blindly offer an N-way plan fanout. Concretely: kill the failure where the
detector "finds 15 plans when the goal is extremely well defined" and offers a
15-way `multi-plan` fanout instead of routing to the one thing the goal points at.

## Why now / context
Shawn keeps hitting this: he fires `/auto` with a sharp, well-defined goal, and the
detector ignores the goal and surfaces a big `multi-plan` fanout over whatever plan
files happen to sit in `docs/plans/`. The detector treats **plan-file count on
disk** as the signal, when a bound/expressed goal should be the stronger signal
that narrows intent. It should be "goal-pilled": goal first, disk clutter second.

## Key decisions already made / grounding facts (verified in the code)
- **Where the bug lives:** `lib/auto-detect.sh` (~33k). The plan-discovery path is
  goal-blind:
  - `_discover_plans(repo)` globs `docs/plans/*.md`, `plans/*.md`, `*-plan.md` and
    returns **all** of them (sorted, deduped) — no goal filter.
  - `_rank_plans_safe(repo)` ranks those by *freshness only* (via `lib/plan-rank.py`).
  - `_emit_multi_plan(...)` fires the `multi-plan` situation whenever there are **≥2
    fresh plans**, offering a per-plan fanout (`dispatchable` situations are
    `reviewed-plan` / `multi-plan`). This is the highest-blast-radius path (it can
    auto-spawn N worktrees), which is exactly why it shouldn't trigger under a
    well-defined goal.
- **The goal signal already exists but is only half-plumbed:** the detector reads
  `goal_intent` from the run-record and surfaces it for **in-flight / not-met runs**
  (`_scan_runs` ~L313–353, used at L505+, L518, L529, L550). That same goal signal
  is **never consulted** in the plan-discovery / multi-plan path. The fix is
  plumbing goal-awareness into `_discover_plans` / `_rank_plans_safe` /
  `_emit_multi_plan`, not inventing a new goal source.
- **Adjacent machinery to reuse, not rebuild:** `lib/goal-status.py` /
  `goal-status.sh` (goal state), `lib/plan-rank.py` (already the ranking seam —
  natural place to add goal-conditioned scoring), `lib/recommender.py`. The native
  `/goal` is **model-judged, not an externally-settable predicate** — so "is there a
  goal" likely means: a bound native goal, a run-record `goal_intent`, and/or the intent
  in the invoking `/auto` prompt. Decide which sources count.
- **Repo/version:** `/Users/shawnroos/projects/auto`, currently `0.8.0`, published to
  the shrimpshack marketplace (version-gated — bump the plugin version so an install
  actually pulls the change). Branch off fresh `origin/main`.

## Open questions / not yet decided
- **What does "goal-aware" collapse TO?** When a goal is present and one plan clearly
  matches, route straight to `reviewed-plan` (single target)? Or still show a
  goal-*ranked* list but with the matched plan pre-selected and the fanout suppressed?
- **How is goal↔plan match scored?** Freshness is already there; goal-relevance is
  new. Cheap lexical/heuristic match in `plan-rank.py`, or a model-judged step?
  Prefer deterministic first (Shawn won't ship probabilistic v1s).
- **Which goal sources are authoritative** (bound native goal vs run-record `goal_intent`
  vs the invoking prompt), and precedence when they disagree.
- **Fanout guardrail:** should a well-defined goal *hard-suppress* `multi-plan`
  (never auto-spawn N worktrees under a clear goal), or just de-rank it? Given
  multi-plan is the highest-blast-radius path, suppression is the safer default.

## Starting point
- `lib/auto-detect.sh` — `_discover_plans` (~L357), `_rank_plans_safe` (~L365),
  `_emit_multi_plan` (~L397), `_scan_runs` (~L313), and the emit/decision block
  around L505–551. Start by reading these end-to-end.
- `lib/plan-rank.py`, `lib/goal-status.py`, `lib/recommender.py`.
- `skills/auto/` and the `auto-driver` / `auto-launch` skills (they *consume* the
  detector's JSON — `situation`, `multi_plan.paths`, `recommendation`).
- Detector JSON contract is documented in the header comment of `auto-detect.sh`
  (situations list at ~L17–59) — keep that contract intact or update its consumers.
- Tests: `tests/` — the repo's `tests/run.sh` has a quirk (only tallies a file whose
  LAST summary line matches `^<name>.test.sh: N passed, M failed`); mirror the
  existing detector-test pattern and see a new test fail once before it passes.
- Relevant memories: `feedback_auto_should_be_context_aware_smart_entry`,
  `native_goal_is_model_judged_not_externally_settable_predicate`,
  `project_auto_entry_routing_v070_base_shift`, `auto_test_runner_summary_line_tally`,
  `deterministic_over_probabilistic_v1`.

## Recommended next step
`/ce-brainstorm` — the *where* (auto-detect.sh plan path) is nailed down, but the
*shape* of goal-awareness (collapse-to-single vs goal-rank, match scoring, which
goal sources, suppress-vs-derank the fanout) is a real design fork. Brainstorm those
4 open questions into a decision, then `/ce-plan`. Keep the first cut deterministic.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/d7fba74d-4df6-426b-aeea-a7f3c587a64a.jsonl`
Resume:     `cd /Users/shawnroos && claude -r d7fba74d-4df6-426b-aeea-a7f3c587a64a`
