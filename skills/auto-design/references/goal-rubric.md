<!--
Adapted from ksimback/looper (references/goal-rubric.md), MIT License.
Rewritten in auto's vocabulary (workflow / ledger / driver / exit-predicate);
looper's execution + council framing stripped. Original © the looper authors.
-->

# Goal rubric

Use this when shaping the loop's goal — the thing auto's exit predicate and an
optionally-bound `/goal` doc are measured against. A sharp goal is what lets the
ledger's deterministic Stop hook actually mean "done" instead of "ran out of
attempts."

## Good goal shape

- Names the concrete outcome, not only the activity.
- Defines the artifact or end-state that *proves* the loop finished — the thing
  the goal doc points at and the exit predicate can be read against.
- Sets scope boundaries: included work, excluded work, and maximum depth (this
  feeds the workflow's iteration bounds, not just prose).
- Names the context sources the driver should gather (the `auto-detect`
  hypothesis, specific files, a plan doc) instead of assumptions it may invent.
- Identifies who consumes the result — the user, a reviewer, a downstream system.

## Critique prompts

- What would count as done if two competent agents disagreed? (If the answer is
  fuzzy, it can't be a typed verification criterion yet — see the verification
  rubric.)
- Which terms are subjective and need a measurable proxy?
- What context must be read before the driver drafts a workflow + goal doc?
- What is explicitly out of scope for this loop?
- Can the goal be split into plan, delivery, and verification artifacts?

## Anti-patterns

- "Improve the project" without a target artifact.
- "Make it good" without criteria.
- "Research X" without naming the decision the research supports.
- Goals whose success depends on information the loop never gathers.
- Goals that require endless polishing with no stop condition — auto's bounds
  (`max_attempts`, `max_wall_seconds`) will cut these off as a *failure*, not a
  win.

## Better examples

Weak: "Make our onboarding better."

Better: "Produce a 5-step onboarding workflow map for new enterprise users, with
each step assigned to a product surface, email, human owner, or missing
capability, and with no unresolved TBDs." (Now "no unresolved TBDs" is a
checkable verification criterion, not a vibe.)

Weak: "Fix the flaky tests."

Better: "Identify and patch the root cause of the checkout test flake, prove it
with 20 local repeats or a CI rerun, and leave a short note explaining the
failure mode and the verification evidence." (The "20 repeats / CI rerun" is a
programmatic criterion; the note is a deliverable the exit predicate can require.)
