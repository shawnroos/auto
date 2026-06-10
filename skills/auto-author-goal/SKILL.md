---
name: auto-author-goal
description: >
  Turn a plan into a model-judgeable goal doc the user binds with
  `/goal <doc-path.md>`. Use when the user says "generate a goal for this
  plan", "make a goal doc", "write a /goal for <plan>", "goal this run", or
  wants auto to phrase an exit predicate from a plan. This skill AUTHORS the
  goal doc and writes it to disk; it does NOT run `/goal` — binding is the
  user's action (auto can neither arm nor clear a native goal). The doc is
  written to TRACK auto's own exit predicate so the model-judged goal and
  auto's deterministic Stop hook are as aligned as possible.
---

# auto-author-goal (the goal compiler)

A **goal doc** is a saved, model-judgeable exit predicate derived from a plan.
The user binds it with `/goal <doc-path.md>` (a file-referenced goal — the
model judges the file's whole content as the "done" condition). This skill
writes that doc; it never runs `/goal`.

## The binding model (read first)

The user runs `/goal .claude/auto/goals/<slug>.md` themselves. The model then
judges the **entire doc** as the goal at each stop attempt. Two consequences
drive how the doc is written:

1. **The doc IS the condition.** Everything in it is read as the predicate, so
   write it AS a judgeable spec — observable "done" criteria, not rationale
   prose or human meta-commentary the judge would have to interpret. Keep
   asides to a single clearly-marked footer line.
2. **It's an independent, model-judged gate.** Auto's own deliberate-stop is a
   deterministic ledger read (`lib/on-stop.py`); a native `/goal` is
   model-judged and shares NO verdict with it. They can DIVERGE — a goal judged
   stricter than the ledger keeps re-prompting "Goal not yet met… continuing"
   even after auto reaches `done` (the spam class the Stop-hook fix addressed,
   now self-inflicted via the goal). We can't guarantee agreement; we write the
   doc to TRACK auto's predicate to minimize divergence. `/goal clear` is the
   escape — name it in the doc. Auto never arms or clears this goal; the user
   does. See `skills/auto/SKILL.md` §1.

## Phrasing rules — a model-judgeable exit predicate

The criteria the model judges should each be:

1. **Binary & terminal.** Describe the DONE state, not the process. "every unit
   in the plan is implemented and reviewed clean" — not "work through the plan."
2. **Observable.** Verifiable from repo state or the transcript: tests pass,
   files exist, no open review findings, a command exits 0. Nothing only an
   external system knows.
3. **Scoped to THIS plan.** Reference the plan and its acceptance criteria so
   the judge isn't guessing the boundary. A criterion may point at the plan
   ("all acceptance examples AE1–AE4 in `<plan>` are satisfied") — the judging
   model can open it.
4. **No vague adjectives unless operationalized.** Not "clean / good / done
   well" — instead "no P0/P1/P2 review findings remain" or "the suite is green."
5. **Track auto's exit predicate.** Auto exits when *all units are terminal AND
   only P3 findings remain*. Make that an explicit criterion so the model is
   most likely to judge the goal achieved when auto's loop does (minimizes, does
   NOT eliminate, the divergence above).
6. **Tight.** A focused checklist, not an essay. Exclude deferred/out-of-scope
   items explicitly so the judge doesn't hold the goal open on them.

## Procedure

1. **Locate the plan.** Take the plan path from the user (or the most recent
   `docs/plans/*.md`). Read it. Pull: the requirements trace (R1…), acceptance
   examples (AE1…), scope boundaries, deferrals, and any explicit success /
   "done when" criteria.
2. **Compose the criteria** per the rules above — each observable and grounded
   in a requirement / acceptance example / explicit success line. Include the
   auto-predicate criterion and an explicit "out of scope" line for deferrals.
3. **Write the goal doc** to `<repo>/.claude/auto/goals/<plan-slug>.md` using
   the template below (create `goals/` if absent). `.claude/auto/` is gitignored
   runtime state — the doc is a local artifact, not a committed file.
4. **Surface the bind command** — the path plus:
   - `/goal .claude/auto/goals/<slug>.md` ← run this to bind
   - `/goal clear` ← run this to release it

## Goal-doc template

The whole file is the condition — keep it criteria-focused.

~~~markdown
# Goal: <plan title>

Source plan: `<relative/path/to/plan.md>`

This goal is met when ALL of the following are true:

- <criterion 1 — observable, from the plan's acceptance examples>
- <criterion 2 — e.g. `tests/run.sh` exits 0>
- <criterion 3 — every unit in the plan is implemented and reviewed>
- No P0/P1/P2 review findings remain (P3 findings are acceptable) — auto's own
  exit predicate (all units terminal, only P3 remain).

Out of scope (do NOT hold this goal open on these): <deferred items, or "none">.

<!-- note: model-judged goal, independent of auto's Stop hook; release with `/goal clear`. -->
~~~

## Invariants

- **Never run `/goal`.** Author and surface only; the user binds.
- **The doc is the condition.** Write judgeable criteria, not rationale prose —
  the model reads the whole file.
- **Ground in the plan.** Every criterion traces to a requirement / acceptance
  example / explicit success line — no invented scope. State deferrals as
  out-of-scope so the goal doesn't hang on them.
- **Track auto's predicate** to minimize (not eliminate) divergence; the goal is
  an independent model-judged gate, `/goal clear` is the escape.
