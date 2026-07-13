<!--
One-shot verification reference for the auto-preset skill.
Extends skills/auto-design/references/verification-taxonomy.md (the authoritative
criterion-shape contract) to the RUN-TIME, STEP-LEVEL, driver-orchestrated
one-shot. The criterion SHAPES are identical; what changes is WHO resolves each
type and WHEN — inline, in one synchronous pass, with no pulse and no gate.
-->

# One-shot verification — deriving and resolving criteria

A one-shot preset run has no flow, no loop, and no pulse. The `auto-preset`
skill is the whole control path: it PROPOSES a small set of context-fit
verification criteria, the operator ACCEPTS or EDITS them, the ratified set is
baked into the single run, and the skill RESOLVES every criterion **inline**
before reporting a verdict. This file is the quality bar for that propose step
and the exact resolution rule for each of the four criterion types.

Read `skills/auto-design/references/verification-taxonomy.md` first — it pins the
exact field shape of each criterion (`programmatic` / `model_judge` /
`advisor_judge` / `human`). Nothing here changes those shapes; the ratified list
is validated against that same taxonomy (via `preset_oneshot.validate_oneshot_criteria`,
which reuses the recipe validator) before anything is baked.

## Deriving criteria from the target — seed, don't interview

Extend `auto-design`'s **"Seed, don't interview"** invariant to the step level.
Do NOT open a blank questionnaire. Read the target the operator named (the diff,
the branch, the file, the change to build) and the preset's own intent (its
`description` and `backend_op`), and PROPOSE a short list — usually 1–3 criteria —
that would actually prove this one step landed. Then let the operator accept or
edit.

Coach **deterministic-first**, exactly as `auto-design` does: if a claim *can* be
a command + check, it must be a `programmatic` criterion — do not reach for a
judge to dodge writing the check. Reach for a judge only for semantic quality a
command genuinely cannot decide. Keep one claim per criterion; the list is capped
at 16 (the taxonomy cap, enforced by the validator).

Worked seeds:

- A `review` preset fired at a diff → propose `programmatic` `{argv: ["bash",
  "tests/run.sh"], check: exit_zero}` when the repo has a test command, plus a
  `model_judge` "the review's findings are grounded in the diff, not generic."
- A `do_step` preset fired at a scoped build → propose `programmatic` that the
  build's own test/typecheck passes, plus (only if the change is taste-sensitive)
  a `human` sign-off.

## The INLINE-resolution rule — every type resolves in one pass (KTD-3)

Because the skill drives synchronously and there is **no next pulse**, every
ratified criterion must resolve *before* the verdict is computed. There is no
"pending across pulses" state — a criterion that cannot resolve inline has no
later chance to. That constrains how each type is satisfied:

- **`programmatic`** — the skill runs it **in-process** via
  `lib/verification.py::evaluate_programmatic(criterion, cwd)` and records
  `{criterion_id: "pass"|"fail"}`. No model in the loop.
- **`model_judge`** — resolved from the **dispatched sub-agent's own verdict**.
  The one-shot launch instructs the sub-agent to self-grade against the
  criterion and return a pass/fail with its result; the skill reads that back as
  the verdict. No separate call.
- **`advisor_judge`** — resolved by a **blocking `advisor` consult** the driving
  session makes itself (reusing `skills/auto/SKILL.md` §4.6 / §4.7: `advisor`
  returns prose, the driver maps it to a per-criterion pass/fail). **This
  BLOCKS** — the skill waits for the consult and maps its result before moving
  on. It does not defer to a later pulse, because there is none.
- **`human`** — resolved by a **blocking pause**: the skill asks the operator and
  waits. **This BLOCKS** — a `human` criterion on a one-shot is a synchronous
  checkpoint the run stops at, not a deferred pause that a future pulse clears.

State this plainly to anyone proposing criteria: on a one-shot, an
`advisor_judge` or `human` criterion **stops the run until it is answered**.
That is a feature (the operator asked for a real check), but propose them only
when the second read or the human judgment is worth blocking for — otherwise a
`programmatic` or `model_judge` criterion keeps the run moving.

## Handing the resolved criteria to the verdict

Once all criteria are resolved, the skill folds them into a single terminal
verdict via `preset_oneshot.oneshot_verdict(ratified_criteria,
programmatic_results, judge_verdicts)` — the ratified criteria list goes in
directly (there is no synthesized unit):

- `programmatic_results` — `{criterion_id: status}` from `evaluate_programmatic`.
- `judge_verdicts` — `{criterion_id: status}` for `model_judge` /
  `advisor_judge` / `human`, each resolved as above.

`oneshot_verdict` aggregates once (reusing `verification.aggregate`) and
re-labels the result **all-resolved-pass → `pass`; any-resolved-fail → `fail`**.
Because the skill resolves every type inline, there are **no `pending_judges`**
at verdict time — if any remain, `oneshot_verdict` raises `OneShotIncomplete`
(a caller error: a criterion was left unresolved), never a silent pass.

## What stays true

- **The ratified criteria are ephemeral.** They live only on this run. They are
  NEVER written back onto the preset JSON (R2/A2) — a preset is pure payload,
  never payload-plus-gate. Do not "save this check for next time" (that is a
  deferred Phase-2 opt-in).
- **An edited criterion is what's baked.** If the operator changes a proposed
  criterion, the EDITED form is validated and baked — the proposed original is
  discarded (AE2).
- **Nothing dispatches until the criteria are accepted** (AE1). Propose → the
  operator accepts or edits → validate → only then launch.
