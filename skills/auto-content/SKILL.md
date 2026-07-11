---
name: auto-content
description: >
  Run one named content one-shot against a target — the Phase-1 headline of
  addressable step contents. Use when the operator wants to fire a single tuned
  step (a tuned review, a scoped build) standalone: "run <content> against
  <target>", "one-shot the tuned-review on this diff", "fire scoped-build on
  <target>". This skill IS the orchestrator (no tick, no /goal, no re-arm): it
  loads the content, PROPOSES context-fit verification the operator accepts or
  edits, synthesizes a single-unit run, launches the content's op ONCE as an
  awaited sub-agent honoring its prompt_template, resolves every criterion
  inline, computes a pass/fail verdict, reports, and terminates. It runs ONE
  step against ONE target — a multi-step plan-then-build is a flow (deferred),
  not a content.
---

# auto-content (the one-shot content orchestrator)

A **content** is the pure payload of a step — one `adapter_op` invocation plus an
optional tuning `prompt_template`, promoted to a first-class named object
(`lib/contents.py`). This skill runs one content **one-shot**: grab it by name,
point it at a target, propose a context-fit check, run it once, get the result
plus a verdict — no flow armed, no loop, no tick.

This skill is the **entire control path** (KTD-3 / A5). It owns the propose→ratify
conversation, the single awaited dispatch, inline criterion resolution, and the
result+verdict presentation. It does **not** enter the engine's tick loop, arm a
`ScheduleWakeup`, or bind a `/goal`. That is what makes "the loop runtime is
unchanged" hold literally.

Read before running — the quality bar, not background:
`skills/auto-content/references/one-shot-verification.md` (how to derive criteria
and the inline-resolution rule for each of the four types) and
`skills/auto-design/references/verification-taxonomy.md` (the exact criterion
shape). The thin lib seams this skill drives live in `lib/contents.py` and
`lib/content_oneshot.py`.

## What stays true throughout

- **Driver-orchestrated, engine untouched.** No tick, no `ScheduleWakeup`, no
  `/goal`, no re-arm. The skill drives synchronously start to finish.
- **One content = one step.** Exactly one `adapter_op` invocation. A multi-step
  reusable sequence is a *flow* of containers (Phase-2, deferred), not a content.
- **Verification is generated, never stored.** The ratified criteria live only on
  this run — they are NEVER written back to the content JSON (R2/A2). A content
  is pure payload; it carries no built-in gate.
- **Every criterion resolves inline.** Because there is no next tick,
  `advisor_judge` and `human` criteria BLOCK (a blocking `advisor` consult / a
  blocking pause) — they do not defer. See the reference doc.

## The one-shot flow (F1)

### 1. Load the content by name

The operator names a content and a target. Resolve + validate it:

```
python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
contents = load_lib_module("contents")
c = contents.load_content(sys.argv[2], sys.argv[3])
ok, errs = contents.validate_content(c)
print("OK" if ok else "INVALID: " + "; ".join(errs))
' "${CLAUDE_PLUGIN_ROOT}/lib" "<content-name>" "$PWD"
```

`load_content` resolves the workspace tier (`<repo>/.claude/auto/contents/`)
first, then the built-in seeds — first-wins. Shipped seeds today:
`tuned-review` (a tuned `review`) and `scoped-build` (a scoped `do_unit`).

**Unknown content name → clear error, then point multi-step reuse at the flow
arc (R-D).** `load_content` raises `ContentError` listing what it searched —
surface that, do NOT dump a traceback. If the operator was reaching for a
multi-step sequence (a "plan then build", a whole pipeline), say plainly: *a
content is one step (one adapter op); a plan-then-build is a **flow** of two
containers, which is the deferred composition arc — not something a single
content can express.* Offer the built-in seeds or `auto-launch` for a real loop.

### 2. Propose context-fit verification — the operator accepts or edits (U3)

**Seed, don't interview.** Read the target and the content's intent, and PROPOSE
a short (1–3) list of criteria that would prove this one step landed — coaching
deterministic-first per `references/one-shot-verification.md`. Show the proposal;
the operator ACCEPTS or EDITS it. **Do not dispatch until the criteria are
accepted (AE1).** An edited criterion is the one that gets baked, not the
proposed original (AE2).

Validate the ratified list against the taxonomy shape BEFORE baking — reject a
malformed criterion (a `programmatic` with a shell string instead of an argv
list, an unknown `type`, >16 criteria) and re-ratify:

```
python3 -c '
import sys, json; sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
co = load_lib_module("content_oneshot")
ok, errs = co.validate_oneshot_criteria(json.loads(sys.argv[2]))
print("OK" if ok else "INVALID: " + "; ".join(errs))
' "${CLAUDE_PLUGIN_ROOT}/lib" '<ratified-criteria-json>'
```

Nothing is written back to the content file — the ratified criteria are
ephemeral (R2/A2).

### 3. Synthesize the single-unit run (U2)

Turn the loaded content + the ratified criteria into ONE work-phase unit
(`co.synthesize_oneshot_unit(content, ratified)`): the content's `invokes` rides
on `dispatch_context`; the criteria bake onto a top-level `one_shot_verification`
key; there is NO `iteration` block and NO `phase_transitions` — the one-shot
never loops (KTD-3/KTD-4).

### 4. Launch the content's op ONCE, honoring `prompt_template` (U5 / KTD-5)

Build the launch descriptor — the DRIVER folds the content's tuning in (the
orchestrator never consults the adapter, driver-reference §7):

```
python3 -c '
import sys, json; sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
contents = load_lib_module("contents"); co = load_lib_module("content_oneshot")
c = contents.load_content(sys.argv[2], sys.argv[3])
print(json.dumps(co.build_oneshot_launch(c, sys.argv[3])))
' "${CLAUDE_PLUGIN_ROOT}/lib" "<content-name>" "$PWD"
```

The descriptor always names `adapter_op`. When the content declares a
`prompt_template`, the descriptor carries `prompt_template_body` (the template
text) — **fold that body into the launched sub-agent's prompt** so the tuning
travels with the content. When there is no `prompt_template`, the descriptor is
the plain op invocation — launch it exactly as a normal op (regression-safe).

Map `adapter_op` → the skill/agent you launch the same way the driver launch map
does (`skills/auto/SKILL.md` §4): a `review` op launches the review agent against
the target; a `do_unit` op launches the build agent. **Launch it ONCE as an
awaited sub-agent** and wait for its result. If any ratified criterion is a
`model_judge`, instruct the sub-agent to self-grade against it and return a
pass/fail alongside its output.

### 5. Resolve every ratified criterion inline (U4 / KTD-3)

With the sub-agent's result in hand, resolve each criterion — **all in this one
synchronous pass**, per `references/one-shot-verification.md`:

- **`programmatic`** → run in-process via `verification.evaluate_programmatic`;
  record `{criterion_id: status}` into `programmatic_results`.
- **`model_judge`** → read the dispatched sub-agent's own pass/fail.
- **`advisor_judge`** → consult the `advisor` (blocking), map its prose to
  pass/fail (§4.6/§4.7 pattern).
- **`human`** → ask the operator (blocking pause), record their answer.

Collect the judge results into `judge_verdicts` (`{criterion_id: status}`).

### 6. Verdict, report, terminate

Fold everything into the terminal verdict:

```
python3 -c '
import sys, json; sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
co = load_lib_module("content_oneshot")
unit = json.loads(sys.argv[2])
v = co.oneshot_verdict(unit, json.loads(sys.argv[3]), json.loads(sys.argv[4]))
print(json.dumps(v))
' "${CLAUDE_PLUGIN_ROOT}/lib" '<unit-json>' '<programmatic_results-json>' '<judge_verdicts-json>'
```

`oneshot_verdict` maps **all-resolved-pass → `pass`; any-resolved-fail → `fail`**
(KTD-1 — a read-only terminal aggregate, never an iteration decision). Because
every type was resolved in step 5, no judges are pending; if any were, it raises
`OneShotIncomplete` rather than passing silently.

Then **surface the content's output and the verdict distinctly** — the review /
build result the sub-agent produced, and the `pass`/`fail` with which criteria
drove it. The run is terminal: **no tick is armed, no `/goal` is bound, nothing
to resume.** Report and stop.

## What this skill does NOT do

- It does not arm a loop, a tick, a `ScheduleWakeup`, or a `/goal` — that is
  `/auto` (`skills/auto`). The one-shot is single-pass and driver-driven.
- It does not write the ratified criteria back to the content (R2/A2), and it
  does not edit the content JSON.
- It does not compose contents into a flow or swap a container's content — that
  is the deferred Phase-2 composition arc (R6/R7/R8).
- It does not touch the adapter (KTD-5): the `prompt_template` is folded at the
  DRIVER launch, never via an `adapter.do_unit` / `adapter.review` edit.
- It does not run a multi-step sequence. One content is one step; point
  multi-step reuse at the deferred flow arc (step 1).

## Invariants

- **Driver-orchestrated, engine untouched.** No tick, no `/goal`, no re-arm.
- **Propose, don't interview.** Seed the criteria from the target; the operator
  accepts or edits; nothing dispatches until they do (AE1); the edited form is
  baked (AE2).
- **Deterministic-first verification.** A claim that can be a command + check is
  `programmatic`; judges are for what a command genuinely can't decide.
- **Ephemeral criteria.** Ratified criteria live only on the run; never persisted
  to the content (R2/A2).
- **Inline resolution.** Every criterion — including `advisor_judge` and `human`
  — resolves in one synchronous pass; they BLOCK, they never defer (KTD-3).
- **The verdict is a terminal read.** `oneshot_verdict` reports pass/fail; it
  never commits an iteration decision (KTD-1 boundary).
