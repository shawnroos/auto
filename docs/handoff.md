# Spinoff: auto conversation-driven smart entry

## Goal

Make `/auto` runnable from **nothing but a conversation** — no pre-written plan or
issue. The agent assesses the current session's context (including recent
compacted logs, ~2 days back), recommends a next ce-family step (brainstorm /
ideate / verify / optimize / work / review …), spins up an ultracode-style
workflow for that phase that **always** ends in review→verify→fix-until-only-P3,
drafts a phase goal, and then offers to auto-advance through subsequent phases.
Net: automate the review/verify/fix loops Shawn currently types by hand every
time.

## Why now / context

This is the unifying ask behind every `/auto` smart-entry piece of feedback (see
memory `feedback_auto_should_be_context_aware_smart_entry`): bare `/auto` should
GATHER CONTEXT and DETERMINE WHERE TO PICK UP, not force the operator to pick the
right verb. The conversation we just had is itself the trigger case — a rich
discussion with enough context to start automated work, but no plan doc to point
`/auto` at.

It also lands right after a session that (a) fixed the blocked-loop "Goal not yet
met… continuing" spam, and (b) shipped the `auto-author-goal` skill (auto 0.4.2)
that drafts model-judgeable goal docs from plans. This feature reuses that skill
for its "draft a phase goal" step — and inherits its hard-won constraints.

## Key decisions already made

- **auto is PREPARE/EXECUTE, not self-driving** (`feedback_auto_prepare_execute_operator_traps`).
  The smart-entry layer prepares intents the model executes; it must not assume a
  bash-loop tick drives itself. Respect this or re-derive finished work.
- **Reuse `auto-author-goal` for "draft a phase goal"** — don't build a second
  goal author. It's at `skills/auto-author-goal/SKILL.md` (shipped 0.4.2).
- **Goals must be AGENT-COMPLETABLE, and auto's own Stop hook owns the verdict —
  NOT native `/goal`.** Native `/goal` is a bystander auto can neither arm nor
  clear (only `/goal clear` stops it); a goal whose criteria the agent can't
  reach loops forever ("never-met loop"). The phase goal here should bind to
  auto's deterministic exit predicate (all units terminal, only P3 remain), which
  is exactly the "fix-until-only-low-priority" the spec wants. See memories
  `project_auto_blocked_loop_goal_spam_fix`, `reference_native_goal_is_model_judged_not_externally_settable_predicate`.
- **The "fix-until-only-P3" loop already exists** — it's auto's core exit
  predicate. The smart-entry just needs to wrap a chosen ce phase in it.
- **There's already a `W` work-only recipe** (`phase_order: ['work']`) and the
  DX7-style recipe picker (U8). Phase auto-advance (plan→work→review…) likely
  extends recipe `phase_order` / composes recipes rather than inventing a new
  engine. A3 (build-first feedback, two work-phases) was deferred to v0.2.1 and is
  the closest prior art for multi-phase chaining.
- **Orientation already has a home:** `skills/auto-driver/SKILL.md` +
  `lib/auto-detect.sh` (hypothesis former) + `commands/auto.md` (NL routing). The
  conversation-context-aware recommendation is an extension of auto-driver, not a
  new surface.

## Open questions / not yet decided

- **"Route questions to advisor, not the user."** Mechanism is undecided: when
  auto initializes, the system prompt should make the agent present options to
  the `advisor` tool instead of firing `AskUserQuestion`. Is this an output-style
  switch, a UserPromptSubmit/SessionStart hook that injects guidance, or a
  per-run flag? (Note tension: ce skills use AskUserQuestion heavily; ce-doc-review
  even pre-loads it. Need a clean override that doesn't break those.)
- **Reading "recent compacted logs ~2 days back."** What's the source — the
  `ce-sessions` skill, raw transcript files, or compaction summaries? Define the
  context-gathering input precisely before building the recommender.
- **Phase auto-advance UX + mechanism.** After a phase's review/fix converges,
  auto offers the next phase automatically (debug→fix/review, work→review/fix,
  plan/review/fix→work/review/fix). Is this a new recipe family, a `phase_order`
  extension, or recipe chaining? How does the user opt in per-transition vs.
  fully autonomous?
- **"ultracode-style workflow"** — does this drive the `Workflow` tool, or auto's
  existing ledger fan-out, or both? Reconcile auto's loop with ultracode
  fan-out/verify patterns.
- **Versioning / cycle fit.** Does this belong in the in-flight v0.5.0
  workflow-substrate cycle (`docs/plans/2026-05-29-*`)? Check before picking a
  version line — 0.5.0 is reserved for that work.
- **ce-family routing taxonomy.** Which ce skills map to which detected context
  states, and what's the recommendation heuristic?

## Starting point

In `~/projects/auto` (this is the auto plugin repo; HEAD carries the 0.4.2 work):
- `skills/auto-driver/SKILL.md` — orientation layer to extend.
- `lib/auto-detect.sh` — hypothesis former (the "assess context" seam).
- `commands/auto.md` — bare-`/auto` NL routing.
- `skills/auto/SKILL.md` — the loop driver (§1 goal binding, §4.5 pause).
- `skills/auto-author-goal/SKILL.md` — reuse for phase-goal drafting.
- `lib/recipes.py`, `lib/phase-grammar.py`, recipe defs — for phase_order / auto-advance.
- `docs/contracts/driver-reference.md` — engine theory.
- `docs/plans/2026-05-29-*` — in-flight v0.5.0 workflow-substrate plan (check overlap).

Memories to read first: `feedback_auto_should_be_context_aware_smart_entry`,
`feedback_auto_prepare_execute_operator_traps`,
`project_auto_blocked_loop_goal_spam_fix`,
`reference_native_goal_is_model_judged_not_externally_settable_predicate`,
`project_auto_dx7_algorithm_picker`.

Suggested first move: this is exploratory and multi-surface — start with
`/ce-brainstorm` to lock scope (especially the advisor-routing mechanism and the
context-source question) before `/ce-plan`.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos-projects-auto/492b2799-c5c4-4983-abd3-6eaf12c25f1a.jsonl`
Resume:     `cd /Users/shawnroos/projects/auto && claude -r 492b2799-c5c4-4983-abd3-6eaf12c25f1a`
