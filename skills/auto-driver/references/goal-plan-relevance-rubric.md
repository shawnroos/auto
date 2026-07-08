<!--
Companion to skills/auto-design/references/goal-rubric.md (the "sharp goal"
rubric). That rubric shapes a goal at design time; this one judges, at /auto
entry time, WHICH discovered plan a recovered goal points at. Same vocabulary
(recipe / ledger / driver), same deterministic-envelope stance.
-->

# Goal ↔ plan relevance rubric

Use this in the driver's goal-aware pre-routing step (auto-driver `SKILL.md`)
to decide which plan(s) in `multi_plan.paths` / `single_plan.path` a recovered
goal points at — so a well-defined goal collapses plan selection instead of
firing a blind N-way fanout.

This is **agent-judged, not a deterministic score.** The safety does not come
from a stable number; it comes from the always-ask gate (an explicit match only
ever *preselects* a menu the operator confirms) and the interactive-only scope.
Judge against the bar below and route.

## Goal sources and authority

Recover the operative goal for the **current `/auto` invocation** from the
context window, in this precedence:

1. **Explicit — typed `/auto` intent.** The imperative the operator typed with
   this `/auto`. Full authority.
2. **Explicit — bound native `/goal` text.** The text of a `/goal <…>`
   invocation the operator made *in the current session for this invocation*.
   Full authority. Read the text only — never query the `/goal` predicate,
   never run/bind/clear `/goal`.
3. **Inferred — session context.** When neither explicit source is present,
   infer a goal from the session. **Advisory only.**

Authority sets what a match may do:

- **Explicit + match** → narrow: goal-ranked pick-one ask, top match
  preselected, fan-out-all **suppressed**, confirm even on a single match.
- **Inferred + match** → nudge: re-rank the ask to preselect the top match, but
  **keep** fan-out-all offered.
- **No match, or no goal** → change nothing: act on the detector's freshness
  verdict as today.

### Recovery scoping (do not skip)

- Scope recovery to the **current invocation**. A `/goal` line still visible in
  the window but bound for an *earlier, completed run* is NOT the operative
  goal — ignore it, or a later bare `/auto` would suppress its fanout under a
  stale intent.
- The driver's ~2-day `ce-sessions` lookback is for **session classification**
  (conversation-context), not goal recovery.
- Recovery is best-effort. If a bound `/goal`'s text cannot be reliably located
  in-context (it may render as an opaque expansion rather than literal text),
  **degrade to inferred/no-goal handling (keep fanout)** rather than asserting an
  explicit goal that then silently narrows.

## The relevance judgment

For each discovered plan, ask: **does this plan advance the goal's named
outcome?** Judge against the plan's stated Objective / Summary and its
Requirements — the outcome the plan says it produces — not its filename or
freshness.

## The match bar (observable, not "two agents agree")

A plan **matches** when its stated Objective or Summary **names the goal's
target artifact or named outcome** — the same thing the goal points at.

This is deliberately an *observable* predicate. Do NOT lower the bar to "would
two competent agents agree this is roughly related" — that agreement heuristic
is exactly what the companion `goal-rubric.md` flags as too fuzzy to be a
checkable criterion, and a fuzzy bar makes fanout suppression flip between runs
on identical inputs. If you cannot point at the plan's Objective/Summary naming
the goal's outcome, it is a **no-match**.

- **Zero plans clear the bar** → no match. Fall back to freshness behavior.
- **Exactly one clears it** → the match (still an ask under explicit authority —
  goal presence confirms, never auto-dispatches).
- **Two or more clear it** → goal-ranked; preselect the top-ranked match, order
  the rest below it.

## Interactive-only

Goal-aware suppression/preselect/confirm applies only to **interactive** runs
(the launch chooser's `driving_session_id` is null). Self-driven and headless
runs silent-apply by construction and cannot surface the confirm, so they skip
this rubric entirely and take today's unchanged path. The confirm gate is the
safety; where it cannot fire, goal-aware routing does not engage.

## Anti-patterns

- Treating a prior run's `/goal` as the current goal.
- Letting an inferred goal suppress fan-out-all (inferred only re-ranks).
- Matching on filename/freshness instead of the plan's named outcome.
- Silent-dispatching a single explicit match instead of confirming.
- Applying suppression on a self-driven/headless run (no confirm can fire).
