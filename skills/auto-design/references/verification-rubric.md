<!--
Adapted from ksimback/looper (references/verification-rubric.md), MIT License.
Rewritten in auto's vocabulary (recipe / ledger / gate / exit-predicate);
looper's "judge" type split into model_judge / advisor_judge, and its
structured-judge runner contract dropped (advisor returns prose, not a verdict).
Original © the looper authors.
-->

# Verification rubric

Use this when turning the goal's definition of done into **typed verification
criteria** — the `verification` array auto attaches to a gate step. These
criteria steer the gate's iterate / advance / exit decision; they never replace
auto's deterministic exit predicate (the predicate stays the single source of
truth for when the *run* is done — see the control rubric).

## The four criterion types

`programmatic`
: A command runs and a deterministic `check` decides pass/fail. Reach for this
  first, always. Examples: a test suite, a build, a linter, schema validation, a
  diff/snapshot comparison, or a small extraction script that asserts a required
  heading or "no unresolved TBDs." The engine runs it in-process with no model
  call (`lib/verification.py`), so the verdict is reproducible and cheap.

`model_judge`
: The dispatched work agent grades its own output against a rubric. Use only for
  semantic quality a command genuinely can't check, and be aware you're asking
  the host model to grade itself — keep the rubric observable against a concrete
  artifact so the verdict isn't a vibe.

`advisor_judge`
: The **driving session** consults the `advisor` tool (a stronger, full-context
  reviewer), reads its prose, and maps that prose to a per-criterion pass/fail.
  Use this for the high-leverage semantic calls where a second, independent read
  earns its cost. `advisor` returns prose, not a structured verdict — the driver
  does the mapping, the same input-to-judgment pattern auto's §4.6 advisor gate
  uses. This is auto's replacement for looper's cross-vendor council.

`human`
: A person signs off at a checkpoint. Use for taste, business judgment, private
  knowledge, legal risk, or anywhere the user is the true authority.

## Deterministic-first

The ordering is a rule, not a preference: a gate should resolve as much as it can
from `programmatic` criteria before any judge is consulted. Programmatic verdicts
are free and reproducible; judge verdicts cost a model call and can drift. If a
criterion *can* be expressed as a command + check, it must be — don't reach for
`model_judge` / `advisor_judge` to dodge writing the check.

## Strong criteria

- Check one thing at a time. One criterion, one claim.
- Say what failure means — the `check` (or the rubric) is the failure definition.
- Express programmatic checks as an `argv` list, never a shell string.
- Make judge criteria observable against an artifact the judge actually receives;
  a rubric that needs hidden context the judge never sees can't be applied.
- Don't lean on `model_judge` to grade work the same model just produced when a
  `programmatic` check or `advisor_judge` would be more trustworthy.

## Anti-patterns

- Everything is `model_judge` / `advisor_judge` / `human` when a test, build, or
  schema check was available.
- "No errors thrown" as the only criterion.
- A rubric like "high quality" or "comprehensive" with no named dimensions.
- A programmatic `check` written as a shell string instead of an `argv` list.
- A judge criterion that depends on context never sent to the judge.
- More criteria than the gate needs — the array is capped (≤ 16); spend the slots
  on the claims that actually gate the work.

For the exact field shape each type validates against, see
`verification-taxonomy.md`. For how the per-criterion verdicts combine into a
single gate decision, see the `aggregate` contract in that taxonomy.
