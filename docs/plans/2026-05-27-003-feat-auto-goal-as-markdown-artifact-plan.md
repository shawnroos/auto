---
title: "auto: goal as durable markdown artifact, goal-shaped intake skill"
status: active
created: 2026-05-27
deepened: 2026-05-27
type: feat
blocked_by: docs/plans/2026-05-27-002-feat-auto-bare-entry-and-fanout-plan.md
---

# auto: goal as durable markdown artifact, goal-shaped intake skill

## Summary

Promote the goal from an ephemeral CLI text-blob (the current
`--goal "<long string>"` form) to a first-class durable markdown
artifact in `docs/goals/`. Add a `ce-brainstorm`-shaped intake skill
that converges ambiguous intent into a goal.md without robotic
interviewing — the dialogue depth adapts to detection state. Pre-test
the load-bearing hypothesis (the model treats a path-shaped goal
condition as a directive to read and apply the file) before building
on it.

The originating insight: when goals are CLI text blobs they're not
durable, not editable, not version-controlled, not composable, and not
reviewable in a PR. When they're markdown files they get all of that
for free — and the user/agent handoff in the harness becomes "paste a
path" instead of "paste a long quoted string."

**Why not just `--goal "$(cat docs/goals/x.md)"`?** Adversarial round-1
A4: shell substitution delivers most of the durability with zero code
change. The plan-vs-substitution split lives in U3 (intake) and the
resolver behavior (snapshot semantics, divergence notice on resume,
goal-binding string composition per harness condition shape). If those
features turn out to be unwanted, the substitution alternative is a
drop-in fallback and the only code change required is to keep the
existing `--goal "<text>"` flag accepting text as today. **Decision:
U2 must keep `--goal "<text>"` working unchanged for the
shell-substitution alternative; the new file-resolution behavior is
additive, not a replacement.**

**Round-2 A9 — when is the path-form load-bearing vs. shell-sub
sufficient?** The path-form's distinct features are: (1) resume
reads the snapshot, (2) divergence notice when the file edited
mid-run, (3) `goal_source.kind == "path"` lets tools (cleanup,
status) discover the originating file. None of these are essential
for one-off goals (shell-sub fine). They become valuable for
multi-day initiatives where the same goal.md is reused across
multiple `/auto` invocations. Plan accepts that for one-off use
shell-sub is canonical; the path-form is for the durable case.

**Durability premise check (adversarial A1).** This plan stakes on
goal artifacts being more valuable than ephemeral text. A scan of the
existing `--goal` usage in this repo's history shows zero invocations
that exceeded one line — the durability claim is plausible but not
established. The intake skill (U3) is the riskiest unit because it
introduces durable artifacts as the *default* path. **Mitigation:** U3
ships behind a `--no-intake` opt-out so operators who want CLI-only
keep working. If post-ship telemetry shows operators routinely use
`--no-intake`, U3 was wrong and gets pulled. The other units (U1, U2,
U4) deliver value even if U3 is wrong, because they just expose path-
or-text as flexible inputs.

This plan is **gated on a falsifiable spike** in U1 (the goal-as-path
hypothesis test). If the spike fails, U2-U4 either reshape around an
inline-text-only form OR the whole plan defers until the harness
exposes the right primitive.

## Problem Frame

1. **Goals today are CLI args, not artifacts.** `lib/auto.py::_parse_args`
   takes `--goal "<text>"`. The blob lives in argv, gets injected into
   the harness's `/goal` via the first-tick INTENT, and persists only
   in transcript and ledger. Editing requires re-invoking with a new
   CLI string. No `git log` history. No PR review. No links between
   goals or to plans.

2. **User/agent handoff is text-paste-heavy.** When the operator sets
   up a run, they have to compose multi-line goal text in shell quotes
   — error-prone, hard to revise mid-flow, and breaks reasonable
   shell/copy-paste workflows. The friction is largest exactly when
   goals matter most: cross-cutting work where intent is detailed.

3. **No intake process exists.** Bare `/auto` (per the v0.4.0 entry
   plan in `2026-05-27-002`) detects situation and surfaces a
   hypothesis. But there's no step where the engine actually
   *converges with the operator on what done looks like*. The closest
   primitive — `ce-brainstorm` — exists for *requirements* documents,
   not for goals. Auto needs its own intake that produces goals.

4. **Goals can't be re-used or evolved.** A complex initiative
   (e.g., "ship auth refactor reviewed and clean") might span multiple
   `/auto` invocations across days. Today each invocation is a fresh
   text-blob. With goal files, the operator points at the same goal.md
   from each session; the goal text evolves in `git` like any other
   doc.

5. **Recipe selection is detached from intent.** Recipes exist (a1,
   a2, a4) but their selection is via picker prose or the
   v0.4.0 hypothesis funnel. Goals haven't been the signal. With
   goal-as-artifact, the goal's content informs the recipe choice
   (e.g., "explore three caching approaches" → a2; "ship clean" → a1).

## Scope

### In scope

- **U1 (spike, GATED): test the goal-as-path hypothesis** before
  building on it. Concrete protocol below. PASS → build U2-U4 as
  described. FAIL → revise U2-U4 to "path resolves to inline text via
  auto-side read, never given to `/goal` as a path." Either way the
  feature is still useful; the spike determines mechanism.
- **U2: goal-file format and resolver.** Define
  `docs/goals/<slug>-goal.md` with YAML `type: goal`. Goal sourcing
  via `--goal <path-or-text>` (KTD-3 revised); `_parse_args` stays
  pure (no disk I/O); existence-on-disk decides path-vs-text in
  `run()`.
- **U3: goal-shaped intake skill.** New skill
  `skills/auto-goal-intake/SKILL.md` that runs a brainstorm-style
  dialogue when no goal exists, adapts depth to detection state, and
  produces a goal.md as its durable output. Modeled on
  `ce-brainstorm` (one-question-per-turn, scope-aware depth, synthesis
  before write) — NOT a fixed-template interview. Ships behind
  `--no-intake` opt-out (round-1 A1).
- **U4: ledger + harness wiring.** Snapshot goal-file content into the
  ledger at run start via the new `goal_source` envelope (extends
  v0.4.0's `goal_intent`; KTD-5). Pass the resolved text (NOT the
  path) to harness `/goal` per the U1 spike outcome — `_emit_arm` is
  the composition site (round-1 F4). Composite-goal rendering reads
  from `goal_source.content`.

### Deferred / out of scope

- **Goal-aware recipe selection.** A separate plan: read goal phrasing
  ("explore N approaches" / "ship clean" / "experimentally tune X")
  and bias recipe choice. Adds value but not load-bearing for
  goal-as-artifact.
- **Goal composition / `@include`.** Multi-file goal hierarchies.
  v1 is single-file; composition deferred until usage shows it's
  needed.
- **Live-read goals.** Re-reading the goal file on every tick (so the
  operator can edit mid-run and the agent adapts). v1 snapshots at
  run start to avoid mid-run drift surprises. The memory
  `idea_goal_as_markdown_file_reference` recommends snapshot default;
  live-read is a separate plan.
- **Goal expiration / status lifecycle.** Goals stay until manually
  archived. Auto-cleanup of "completed" goals is a separate plan.
- **Replacing the v0.4.0 hypothesis funnel.** This plan ADDS goal
  intake as a step the hypothesis funnel routes through when no goal
  exists; it does NOT replace the funnel.
- **`/ce-brainstorm` replacement.** Auto's intake is goal-shaped, not
  requirements-shaped. `/ce-brainstorm` continues to own requirements
  documents; auto-goal-intake owns goal documents. Some primitives
  shared (dialogue patterns); some content distinct (goal has
  "Done when" criteria, requirements has "Acceptance examples").

## Key Technical Decisions

### KTD-1: Spike first — test path-as-goal-condition before building on it

The harness's `/goal` takes a text condition with a length cap (per
the U9 spike — `Goal condition is limited to ${wsH} characters`). The
question this plan stakes on is: **does the model, given a goal
condition that contains a file path, read that file and judge
completion against its contents?**

The U9 spike answered an adjacent question (no external predicate
seam — the model judges) but did NOT test the path-following behavior.
We need empirical data because the plan's shape changes based on the
answer.

**Scope of what U1 actually decides (adversarial A2 clarification).**
Per U9, the harness's judgment is *always* the model reading the
condition text at stop-attempt time. Whether the condition is a path
or content, the model is doing the judging. So the spike does NOT
choose between fundamentally different mechanisms — it chooses the
**condition-string composition shape** that the model judges most
reliably against. The three scenarios test *empirical reliability of
the model's path-following behavior under known length-cap pressure*,
not three architectures. The reversal cost between PASS / PARTIAL /
FAIL is low because all three end up extracting/citing file content
via the model — the variable is only how much content lives in the
condition string vs. what the model has to read on demand. The spike
is still worth running (we don't want to commit to PASS-shape code
paths if the model is flaky on path-following) but it is **not a
mechanism gate** — it's a composition-shape gate.

**Three scenarios this lets us pick between:**

- **PASS (model reads paths reliably)** — auto invokes `/goal docs/goals/<slug>-goal.md`
  directly. Goal content lives only in the file; harness reads it on
  judgment. Minimal length-cap risk because the goal *condition* is
  short (the path).
- **PARTIAL (model treats path as text)** — auto formats the goal as
  `"until the criteria in <path> are met"` and the model is prompted
  to read the file. Same effect, slightly more text in the condition,
  still within cap.
- **FAIL (model doesn't follow paths reliably)** — auto reads the file
  itself and passes the *content* to `/goal`. Length-cap becomes a
  real constraint; goal docs would need a "Condition" section at the
  top that fits within the cap, with longer context kept in the body
  for *the work-loop* to read (not the harness).

All three modes leave goal-as-artifact useful. The spike determines
which one we build.

### KTD-2: Goal file format — minimal YAML, semantic markdown

```markdown
---
type: goal
created: 2026-05-27
status: active
---

# Ship the auth refactor reviewed and clean

## Done when
- No P0 or P1 findings remain across the touched modules
- One green integration test against staging
- Session middleware passes the new compliance check

## Scope
- src/auth/**
- src/middleware/session.ts

## Out of scope
- Token-format migration (separate initiative)

## Notes
<free-form prose: links to related plans, prior decisions, etc.>
```

YAML carries minimal schema (`type: goal` is the discriminator; other
fields are optional). The markdown body is *semantic* in that
`## Done when` carries the actual completion criteria — useful both
for `/goal` text composition and for the work-loop's awareness of
scope/criteria — but the format is not enforced beyond the
discriminator. If the operator writes free-form prose, that works too;
the intake skill produces the structured form, but humans can edit
freely.

### KTD-3: Goal sourcing via `--goal <path-or-text>` (scope-narrowed)

**Round-1 revision (scope-guardian S2 + feasibility F8).** Earlier
draft proposed a four-step positional-arg classifier that read disk
inside `_parse_args` to discriminate goal-file from plan-file from
ambiguity-error. That overshot the stated goal (durable goal
artifacts) and stranded existing plain-text plan files without
frontmatter. The simpler shape:

1. **Positional remains plan-only.** `/auto <arg>` continues to treat
   the first bare positional as a plan/spec path, byte-identical to
   today's `_parse_args` (lib/auto.py:102-106). No disk read in arg
   parsing.
2. **`--goal <path-or-text>` is the sole goal-sourcing surface.**
   Resolution rule: existence-on-disk decides. If `os.path.isfile(arg)`
   is True → treat as goal-file path (read at run-creation time, NOT
   in `_parse_args`). If False → treat as inline text. Frontmatter is
   advisory (used by U3 to identify auto-authored goals); it is not a
   classifier.
3. **`--plan <path>` is added for symmetry.** Same shape as `--goal`:
   path or text. Force-flag form for the unusual case where existence
   detection misclassifies.

Disk I/O moves to `run()` (lib/auto.py:160), AFTER `_parse_args`
returns and BEFORE `init_ledger`. This preserves the current
`_parse_args` purity (string-only, no I/O) — a load-bearing
contract per the existing test surface.

**Hand-edited goal files without frontmatter still work** because
KTD-3 step #2 is existence-only. The intake skill (U3) writes
frontmatter so auto-authored files are recognizable, but humans
editing free-form prose with no frontmatter are not stranded —
`--goal <path>` reads the content and binds it.

### KTD-4: Intake skill outputs a goal.md, never a transient string

`skills/auto-goal-intake/SKILL.md` is invoked by the v0.4.0
hypothesis funnel when:
- situation is `raw` (no plan, no diff) AND no goal file matches,
- OR situation is `dirty-tree` AND the operator wants to set explicit
  goal context, OR
- the operator types `/auto goal` with no arg (explicit invocation).

The intake skill is a brainstorm-style dialogue (one question per
turn, blocking question tool, scope-aware depth — patterns inspired
by `ce-brainstorm/SKILL.md`, cited in spirit; see the section below
for the citation-discipline note). Its durable output is a
`docs/goals/<slug>-goal.md` file. After write, control returns to
the hypothesis funnel which now sees the goal and dispatches.

**Why a new skill, not extend `ce-brainstorm`:** different artifact
(goal.md vs requirements.md), different prompts (focused on "done
when" criteria rather than "acceptance examples"), different exit
(hands back to auto-driver, not to operator-as-next-step). The two
skills can share primitives (one-question-per-turn, scope assessment,
synthesis) without forcing one to absorb the other's output shape.

**`ce-brainstorm` is cited in spirit, not by section** (round-2 C7).
Earlier drafts cited multiple section labels ("Phase 1.3",
"Interaction Rules", "Phase 2.5") which may have drifted in the
current `ce-brainstorm/SKILL.md`. The patterns this skill mirrors —
one-question-per-turn enforcement, synthesize-before-write,
confirmation-as-stopping-signal — are stable. Implementation should
re-read current `ce-brainstorm/SKILL.md` at U3-build time and adopt
the patterns by behavior, not by section-label cross-reference.

**Why a new skill, not an inline routine in `auto-driver`** (round-1
S1 + A5). v0.4.0 explicitly slims `auto-driver` to ≤60 lines; the
dialogue-runner is a multi-turn flow (1-4 question rounds + a
synthesis write) that does not fit in the driver's already-tight
budget. The patterns it carries (depth detection, one-question-per-
turn enforcement, blocking-tool preload, synthesis-before-write) are
non-trivial — folding them into auto-driver re-inflates the same
surface v0.4.0 just cut. A separate skill keeps the driver as a thin
router and the intake as a substantive sub-flow.

**U3 is the riskiest unit.** Per the durability premise check in the
Summary (A1), the intake skill ships behind a `--no-intake` opt-out.
Operators who prefer CLI-only stay on `/auto <plan>` and
`--goal <path-or-text>`. The skill is invoked ONLY by the v0.4.0
hypothesis funnel under raw/dirty-tree situations OR explicit
`/auto goal`. It is NOT in the default `/auto <plan>` path.

**`--no-intake` cross-plan wire** (round-2 F10 + round-3 C11+F12+S10
revised). This plan adds the flag to `_parse_args`. The flag rides in
the run-creation INTENT payload (NOT a new ledger field — keeping
the ledger schema additions to `goal_source` only, per round-3
scope discipline). v0.4.0's hypothesis funnel reads
`intent.no_intake` before invoking `auto-goal-intake` and
short-circuits when set. Implementation site is a single line in
`skills/auto-driver/SKILL.md` (per the v0.4.0 slimmed version):
"if intent.no_intake, skip intake." No ledger schema change for
this flag; the durable signal is the INTENT envelope. v0.4.0 does
NOT need a code change to consume this — it already reads the
intent payload; the new key is additive.

### KTD-5: Ledger snapshots goal content at run start (extends v0.4.0's `goal_intent`)

**Round-1 reconciliation (F3 + C3 + S5).** v0.4.0 (plan 002 KTD-2)
already adds `goal_intent: string | null` to the per-run ledger as the
one-line user-facing intent. This plan **extends** that field rather
than introducing a parallel `goal_intent_snapshot`. Concrete shape:

```json
{
  "goal_intent": "ship the auth refactor reviewed and clean",
  "goal_source": {
    "kind": "path | text | none",
    "path": "docs/goals/auth-refactor-goal.md",   // null when kind != path
    "content": "<full goal text snapshotted at run start>",
    "read_at": "2026-05-27T14:03:00Z"
  }
}
```

- `goal_intent` (already in v0.4.0) stays as the one-line summary —
  derived from goal-file's H1 title when path, from the inline text
  when text, from plan title when none.
- `goal_source` (this plan adds) carries the snapshot envelope.
  Sentinel value when there's no goal source: `{ "kind": "none",
  "path": null, "content": null, "read_at": null }`. A run with no
  goal has `goal_intent == null` AND `goal_source.kind == "none"`.

**`sha256` was dropped** (round-1 S5 — wider than need). The
divergence-detection feature can compare `goal_source.content` to a
fresh `path` read at resume time without a stored hash. Hash adds no
behavior, only diagnostic noise.

This addresses two concerns:
- **Mid-run drift.** Operator edits goal.md mid-run; engine doesn't
  silently change its judgment criteria. Snapshot freezes content
  at run start; the operator can revise on the next invocation.
- **Resume parity.** A run that resumed reads `goal_source.content`,
  not the current file. If the file's text has diverged from
  `content` at resume time, a stderr notice fires.

**Where the field is written.** U4 introduces a new mutator
`record_goal_source(repo_root, run_id, source)` that routes through
the existing `_with_locked_ledger` RMW chokepoint (the lib/
ledger_core.py:646 atomic-write path). It is NOT a new `init_ledger`
parameter — that signature is already at ~12 params and adding more
risks the schema becoming initialization-heavy. Call site: `run()`
in lib/auto.py, AFTER `init_ledger` returns and BEFORE `_emit_arm`.

For multi-plan fanout (per the v0.4.0 batch sidecar), the composite
goal is a derived field from the batch's umbrella goal text — same
snapshot pattern at batch level.

## Implementation Units

### U1. Goal-as-path hypothesis spike (BLOCKING — must pass before U2-U4)

**Goal:** Empirically test whether the harness's `/goal` mechanism
treats a path-shaped condition as a directive to read and apply the
referenced file.

**Dependencies:** none (must run first; U2-U4 may reshape based on
the outcome)

**Files:**
- `docs/research/goal-as-path-spike.md` (new) — protocol + results
- `tests/spike/goal-as-path/` (new) — fixtures
  - `path-fixture.md` (a small goal file with crisp Done-When criteria)
  - `equivalent-inline.txt` (the same criteria as raw text)
- No production code in this unit. Output is the spike doc.

**Approach:**

Three test runs in a fresh disposable workspace (NOT this repo, to
avoid cross-contamination with auto's own goal-status mechanism).
**The spike is human-in-the-loop** (round-1 F1): each scenario
requires a live Claude Code session because `/goal` lives entirely
in the conversation transcript (per the U9 spike). The operator
runs three discrete sessions, captures the goal-status messages and
verdict from each, and records them in the spike doc. Fixtures live
in this repo (`tests/spike/goal-as-path/`) but the runs themselves
happen in fresh sessions targeting a scratch working directory the
operator creates. Each run uses a trivial "work-loop" — e.g.,
create three files named `done-A`, `done-B`, `done-C` — and a goal
whose criteria are "all three files exist." After the work is done,
the operator attempts `/stop` and observes whether the harness
blocks with "goal not met" or releases. Vary the goal-condition
shape across the three runs:

**Run A — Pure path:**
- `/goal docs/goals/test-fixture.md` where the file's `## Done when`
  lists the three files
- Do the work
- Try `/stop` — does the harness's model judgment recognize completion?

**Run B — Path + directive:**
- `/goal "until the criteria in docs/goals/test-fixture.md are
  satisfied"`
- Do the work
- Try `/stop`

**Run C — Inline control:**
- `/goal "until files done-A, done-B, and done-C all exist"`
- Do the work
- Try `/stop`

For each run, capture: the goal status messages on stop attempts;
whether the harness's "Goal not yet met / Goal achieved" verdict
seems calibrated against the file's content vs against the literal
condition text; iteration count; any explicit file-read activity in
the transcript.

**Test scenarios (the spike IS the test):**

- A passes if: the model's judgment correlates with the file's
  content. Multi-criteria goal works (model only releases when all
  three Done-when bullets are met). **Verdict-change after file
  edit, NOT re-read activity, is the observable** (round-1 F5):
  the model's tool-call traces are not reliably observable from an
  operator-facing surface; what is observable is the goal_status
  verdict change. Test: edit the file to add a 4th "Done when"
  bullet after the run is already releasing, attempt `/stop` again,
  observe whether verdict re-evaluates. If verdict changes, the
  model re-read on judgment.
- B passes if: A's behavior reproduces with the explicit directive
  framing. Useful as a fallback if A's behavior is unreliable.
- C is the control. If A and B produce different verdicts than C
  given equivalent semantic criteria, the path-form has different
  judgment characteristics worth knowing about.

**Decision gate:**
- **A passes** → KTD-1 PASS scenario. U2-U4 build "pass path to
  `/goal`" directly. U4 ledger snapshot is `goal_source.content` +
  `path` (KTD-5 — no sha256; divergence detected via content
  comparison on resume).
- **A fails, B passes** → KTD-1 PARTIAL scenario. U2-U4 use the
  directive framing. Same ledger shape.
- **Both A and B fail (model doesn't read paths reliably)** →
  KTD-1 FAIL scenario. U2-U4 reshape: auto reads the goal file
  itself, passes content to `/goal`. KTD-2's "Done when" section
  must fit in the harness condition length cap (≈ first 1-2 KB of
  the file). The body becomes work-loop context, not harness-judgment
  context.

This spike is **gated**: U2-U4 do not start until the spike doc lands
with a recorded decision. If the spike is inconclusive, repeat with
adjusted protocol until a defensible verdict is on disk.

### U2. Goal-file format, resolver, and arg disambiguation

**Goal:** Define the goal file format. Add resolver + arg
disambiguation in `lib/auto.py`. Tests cover all paths.

**Dependencies:** U1 PASS (the file format is independent of U1's
outcome, but the wiring to `/goal` depends on which scenario U1
landed on)

**Files:**
- `docs/contracts/goal-file-format.md` (new) — schema doc
- `lib/auto.py` (modify) — `--goal <path-or-text>` flag stays as
  string; `--plan <path-or-text>` and `--no-intake` flags added;
  goal resolution moves to `run()` (KTD-3 revision)
- `lib/goal_file.py` (new) — read/snapshot goal files (no schema
  validation beyond optional frontmatter)
- `tests/unit/goal-file-parsing.test.sh` (new)
- `tests/unit/goal-flag-resolution.test.sh` (new — verifies
  `--goal <path>` vs `--goal "<text>"` routing in `run()`)
- `docs/plans/2026-05-27-002-feat-auto-bare-entry-and-fanout-plan.md`
  (reference only — this plan's resolver writes the `goal_intent`
  field that v0.4.0's `auto-detect.sh` reads when listing in-flight
  runs; round-2 C8 — the relationship is "this plan writes the
  ledger field v0.4.0 reads," not "feeds the hypothesis funnel
  directly")

**Approach:**

`lib/goal_file.py` exposes:
- `read_goal(path) -> GoalDoc` — parse YAML frontmatter, return
  structured doc.
- `snapshot_for_ledger(source) -> goal_source-envelope` — build
  the `{kind, path, content, read_at}` envelope from a path OR
  inline-text source (KTD-5 shape, sha256 dropped).

`_parse_args` (round-1 F2 + S2): **stays pure (no disk I/O)**.
Concrete edits:
- `--plan <path-or-text>` flag added for symmetry with `--goal`.
- `--no-intake` flag added (round-1 A1 — opt-out of intake skill).
- `--goal <path-or-text>` stays unchanged in arg-parsing; the
  path-vs-text decision moves to `run()` (lib/auto.py:160), where
  `os.path.isfile(goal_arg)` decides. This preserves the existing
  `_parse_args` contract (string parsing only) — a load-bearing
  property of the current implementation.

`run()` adds (between arg parsing and `init_ledger`):
- Goal resolution: `goal_source = goal_file.snapshot_for_ledger(args["goal"])`
  if `args["goal"]` is set; else `None`.
- Existence-on-disk decides `kind`: `os.path.isfile(args["goal"])`
  → `kind: "path"`; else → `kind: "text"`.

**Test scenarios** (revised for round-1 S2 — positional stays
plan-only; goal sourcing is `--goal <path-or-text>` only):

- `docs/goals/foo-goal.md` with valid frontmatter parses cleanly
  via `goal_file.read_goal()`
- `goal_file.read_goal()` on a missing-frontmatter file: still
  parses (frontmatter is advisory, NOT a hard schema); the doc's
  `kind` field is `"unknown"` instead of `"goal"`. Hand-edited
  goals (round-1 F8) work this way.
- `/auto docs/plans/bar-plan.md` → positional is plan; goal is null
- `/auto docs/plans/bar-plan.md --goal docs/goals/foo-goal.md`
  → goal is path-resolved; `goal_source.kind == "path"`
- `/auto docs/plans/bar-plan.md --goal "ship X clean"` → goal is
  inline; `goal_source.kind == "text"`
- `/auto docs/plans/bar-plan.md --goal nonexistent-path.md` →
  `os.path.isfile` False → treated as inline text "nonexistent-
  path.md" (the failing case is non-obvious; documented in
  `--help` and the resulting goal binding is the literal string)
- `--plan <path-or-text>` flag works as positional alternative
- `--no-intake` flag suppresses intake skill invocation downstream
  (verified at U3-integration boundary)
- Snapshot's `content` field captures the file body deterministically
  for unchanged file; content differs if the file is edited (the
  divergence signal U4 uses)

### U3. `auto-goal-intake` skill — brainstorm-style dialogue

**Goal:** New skill that runs an adaptive dialogue and outputs a
goal.md, modeled on `ce-brainstorm` patterns but specific to goal
artifacts.

**Dependencies:** U2 (uses `goal_file.py` for write)

**Files:**
- `skills/auto-goal-intake/SKILL.md` (new)
- `skills/auto-goal-intake/references/dialogue-patterns.md` (new) —
  one-question-per-turn rules, scope assessment, synthesis form
- (Round-1 S4: `references/goal-templates.md` dropped — three
  templates were configuration ahead of need. Goal-shape variations
  follow from recipe selection, not from intake-side templates. If
  specific shapes prove valuable, add them under
  `docs/contracts/goal-shapes.md` in a follow-up plan.)
- `tests/unit/goal-intake-writer.test.sh` (new) — tests the
  *writer* surface (round-1 F7): given a synthesized goal-paragraph
  + a slug, verify the resulting `docs/goals/<slug>-goal.md` parses
  via `goal_file.read_goal()` and contains the expected sections.
  Does NOT test the dialogue (AskUserQuestion is harness-level and
  not deterministically replayable from bash); the dialogue
  patterns are verified by manual dogfooding per Success Criteria.

**Approach:**

The skill loads when invoked by the v0.4.0 hypothesis funnel (raw
situation OR explicit `/auto goal`). Depth adapts to context via
**confirmation-as-stopping-signal** (round-1 S3 — earlier draft
specified three discrete tiers; that was configuration ahead of
need). Concrete behavior:

1. **Read what's already given.** If the operator typed `/auto fix
   the login bug`, that text is the seed. If `/auto` (bare) with a
   `raw` hypothesis, there's no seed.
2. **Synthesize what we know.** Build a one-paragraph candidate
   goal (title + done-when bullets if any could be inferred + out-of-
   scope if any). If nothing can be inferred, the candidate is "what
   should we work on?" and the first question is operator-supplied.
3. **Surface the candidate; ask for confirm-or-revise.** If the
   operator confirms, write. If they revise, integrate the revision
   and re-synthesize. Loop until confirm.
4. **Each turn asks at most one question.** Blocking question tool
   (AskUserQuestion); never combine multiple probes into a single
   turn. (This is `ce-brainstorm`'s one-question-per-turn rule.)

The dialogue ends naturally when the operator confirms — that's the
depth signal. A seeded intake usually ends in one turn; a bare
intake usually 2-4. Genuinely ambiguous intent loops longer until
the operator's confirm fires. No pre-classified "Lightweight /
Standard / Deep" tiers.

Synthesis before write: one short paragraph stating what the goal
will be, confirm or revise, then write to `docs/goals/<slug>-goal.md`.
Slug derived from a kebab of the goal title; collision → append
`-2`.

(Round-1 C6 + round-2 C7: the synthesis-before-write pattern is
adapted from `ce-brainstorm`, cited in spirit per KTD-4's
citation-discipline note. The implementer reads the current
ce-brainstorm SKILL at build time and adapts the behavior, not the
section labels.)

**Test scenarios:**
- Seeded case (test the writer): synthesized paragraph "fix the
  login bug" + slug "fix-the-login-bug" → goal.md written with
  title "fix the login bug", minimal frontmatter, parses via
  `goal_file.read_goal()`
- Multi-criteria writer case: synthesized paragraph with three
  done-when bullets → goal.md has `## Done when` section with the
  three bullets, parses cleanly
- Slug collision case: existing `docs/goals/fix-login-2026-05-27.md`
  + new run with same slug → output is `fix-login-2026-05-27-2.md`,
  not overwrite
- Output file always passes `goal_file.read_goal()` validation
- (Dialogue patterns — one-question-per-turn, depth adapts to
  confirmation — verified by manual dogfooding per Success Criteria,
  not by automated tests; round-1 F7 + A7)

### U4. Ledger snapshot + harness `/goal` wiring

**Goal:** Snapshot goal content into the ledger at run start. Pass
the resolved goal to the harness per the U1 spike outcome.

**Dependencies:** U1 (which scenario), U2 (snapshot helper), U3
(produces the files)

**Files:**
- `lib/ledger.py` + `lib/ledger_core.py` (modify) — add `goal_source`
  envelope field (KTD-5 reconciled with v0.4.0's `goal_intent`);
  introduce `record_goal_source` mutator routing through
  `_with_locked_ledger`
- `lib/auto.py` (modify) — `run()` resolves goal source after
  `init_ledger`; `_emit_arm` is the composition site for the
  `/goal <X>` string per the U1-selected outcome (round-1 F4)
- `lib/on-stop.py` (modify) — read `goal_source.content` for any
  composite-goal rendering (no behavior change for single-run;
  relevant for batch per v0.4.0)
- `docs/contracts/ledger-schema.md` (modify) — document
  `goal_source` envelope and its relationship to v0.4.0's
  `goal_intent`
- `tests/unit/goal-snapshot-roundtrip.test.sh` (new)
- `tests/unit/harness-goal-invocation.test.sh` (new) — captures
  what string auto passes to `/goal` per **the U1-selected outcome
  only** (round-1 S6 — earlier draft tested all three branches; the
  unselected branches are dead test code, written AFTER the spike
  lands so we test only what shipped)

**Approach:**

At run start, after arg resolution and recipe selection but before
the first tick arms:

1. If a goal source exists (path OR inline text), call
   `goal_file.snapshot_for_ledger(source)` to build the
   `goal_source` envelope (KTD-5 shape).
2. Persist `goal_source` (and derive `goal_intent` from
   `goal_source.content`'s H1 title) on the ledger via the new
   `record_goal_source` mutator (KTD-5), which routes through the
   existing `_with_locked_ledger` RMW path.
3. **`_emit_arm` (lib/auto.py:137) is the composition site** for the
   harness `/goal` string (round-1 F4 — pin this responsibility).
   `_emit_arm` receives the resolved `goal_source` and the U1-outcome
   constant; it builds the literal `/goal <X>` text and includes it
   in the emitted intent payload. The model does NOT re-compose the
   condition string — it issues the `/goal <X>` slash command with
   the exact text auto.py produced. Composition rules per U1 outcome:
   - PASS: `/goal <repo-relative-path>` (a short condition)
   - PARTIAL: `/goal "until the criteria in <path> are met"`
   - FAIL: `/goal "<extracted Done-when bullets as text, capped to
     condition length>"`
4. Emit the goal-binding INTENT to the harness alongside the existing
   first-tick INTENT.

On resume: read `goal_source.content` from the ledger, NOT the
file. If `goal_source.kind == "path"` and the file's current content
differs from `goal_source.content`, emit a stderr notice ("goal file
has changed since this run started; using the snapshot — re-invoke
/auto to pick up edits"). No behavior change otherwise.

**Test scenarios:**
- Snapshot persists across resume — second-session reads same
  `goal_source.content`
- File edited mid-run → resume uses `goal_source.content`, emits
  divergence notice
- Goal-binding string matches the **U1-selected outcome's** shape
  (round-1 S6 — only the chosen branch is tested; the other two
  shapes are not implemented)
- Inline text source → `goal_source.kind == "text"`,
  `goal_source.path` is null
- No goal source → `goal_source.kind == "none"`,
  `goal_intent == null` (parity with v0.4.0's `goal_intent` default)
- `record_goal_source` mutator is atomic — partial writes are
  invisible to readers (round-trips through `_with_locked_ledger`)

## Test Strategy

Stdlib-only bash tests under `tests/unit/`, consistent with the
existing project convention. `bash tests/run.sh all` must pass green.

The U1 spike has its own surface under `tests/spike/` — these are
ad-hoc empirical tests, not regression tests; they record the protocol
+ results in the spike doc and don't run in CI.

Integration test (post-U4):
`tests/integration/goal-as-artifact-end-to-end.test.sh` — invokes
`/auto <fixture-plan> --goal docs/goals/test.md` against a fixture
and verifies the ledger captures `goal_source.content`, the
first-tick INTENT carries the correct `/goal` shape per the
U1-selected outcome, and resume reads `goal_source.content` not the
current file.

## Risks & Open Questions

**R1 — U1 spike protocol depends on the harness's model behavior.**
The model's path-following behavior may vary across sessions
(prompt-sensitive, context-sensitive). Mitigation: run each scenario
3x with fresh sessions; require consistent verdicts across the runs.
If verdicts are inconsistent, that itself is the FAIL signal — we
don't ship on a flaky primitive.

**R2 — Length cap on `/goal` conditions.** Spike scenario FAIL
forces a content-extract-to-condition path. Goal docs can be long;
the operator might write a "Done when" section that doesn't fit.
Mitigation: U4 truncates with a stderr notice and a recommendation
to tighten the criteria. Truncation never silently changes judgment.

**R3 — Goal-file frontmatter discoverability.** Frontmatter is
advisory (round-1 revision of KTD-3 + F8). A hand-edited goal file
without `type: goal` frontmatter is still readable via `--goal
<path>` — the resolver does existence-on-disk, not frontmatter
classification. The intake skill (U3) writes frontmatter so
auto-authored files are identifiable, but hand-edited files are
not stranded.

**R4 — Cross-plan effect (round-1 A3 hardened to a blocking gate).**
This plan modifies `_parse_args`, `_emit_arm`, and the ledger
schema. The v0.4.0 entry plan (2026-05-27-002) also modifies all
three. Sequencing is now enforced via this plan's frontmatter
`blocked_by: docs/plans/2026-05-27-002-...` — implementation MUST
NOT start until v0.4.0 merges. Concrete merge surface enumerated
in the Sequencing section.

**Resolved Q1 (was Open Q1, round-1 C5).** `docs/goals/` is the
default location, committed to git, parallel to `docs/plans/`. Each
worktree sees the goal via the normal project path;
`resolve_shared_dir` is NOT used for goal files (it's for engine
state, not durable artifacts). Operators who want ephemeral intent
without a commit use shell substitution (`--goal "<text>"`) — that's
the canonical ephemeral path per round-2 A9.

**Open Q2.** Should the intake skill be invocable directly (`/auto-
goal-intake`) or only through the funnel? Direct invocation lets
the operator say "I want to write a goal for later" without starting
a run. Recommend yes — slash command `/auto goal` invokes the skill
directly; if a goal exists at exit, optionally proceed to a run.

## Sequencing

U1 first (spike — blocking gate). U2 second (defines `goal_file.py`
which U3 imports for write). U3 third (consumes U2's writer, no
external dependency on U4). U4 last (its resume-divergence tests
need U3-produced fixtures; round-2 C10 + F9 — earlier draft
claimed U3+U4 parallel, but U4's Dependencies line correctly lists
U3 as a prerequisite. Linear sequencing: U1 → U2 → U3 → U4.) The
round-1 fix flipped U2+U3 to sequential; the round-2 fix flips
U3+U4 to sequential too. Each unit can dispatch a sub-agent in
parallel for *internal* subtasks (e.g. doc + tests), but the four
units themselves run linearly.

**External sequencing (frontmatter `blocked_by`):** this plan is
blocked on v0.4.0 (`2026-05-27-002`) merging first. The
`blocked_by` field in this plan's frontmatter is the durable gate
(adversarial A3 — "Recommend" was too soft for a load-bearing
sequencing constraint). Concrete merge surface this plan touches
that v0.4.0 also touches:

- `lib/auto.py::_parse_args` — v0.4.0 flips the `auto` token
  default and adds `--review-plan`; this plan adds `--plan` flag.
  Same function, additive edits → trivial merge if v0.4.0 lands
  first. If they land in opposite order, conflict resolution
  requires re-deriving the combined arg-grammar.
- `lib/auto.py::_emit_arm` — v0.4.0 may extend the intent shape;
  this plan adds goal-source resolution. Same function.
- `lib/ledger.py` schema — v0.4.0 adds `goal_intent` field; this
  plan adds `goal_source` envelope (KTD-5 reconciliation). Same
  schema. Different fields → no field-name collision, but the
  `goal_intent` derivation logic this plan adds must coexist with
  v0.4.0's hypothesis-funnel derivation.
- `lib/_bootstrap.py` — v0.4.0 adds `resolve_shared_dir()` and
  `resolve_host_repo_root()`; this plan does not edit
  `_bootstrap.py`. No conflict.
- `lib/on-stop.py` — v0.4.0 extends batch-aware Stop; this plan
  extends composite-goal rendering. Same module, different
  sections → low conflict risk if v0.4.0 lands first.

Concrete v0.4.0-blocked behavior: this plan's U4 reads
`goal_source.content` to derive `goal_intent`. If v0.4.0 hasn't
shipped `goal_intent`, U4 would need to add the field too —
duplicating v0.4.0's work and creating a real conflict. Hence
`blocked_by` rather than "recommend."

## Success Criteria

- The U1 spike doc lands on disk with a defensible PASS / PARTIAL /
  FAIL verdict and a chosen U4 wiring path.
- `/auto <plan> --goal docs/goals/my-goal.md` runs end-to-end with
  the goal text bound to the harness `/goal` per the spike outcome.
  (Positional is plan-only — KTD-3 revision; goal sourcing is via
  flag.)
- `/auto` (bare, no `--no-intake`) on a fresh repo invokes the
  intake skill, which converges on a goal.md when the operator
  confirms — typically 1 turn for seeded intakes, 2-4 for bare.
- `/auto --no-intake` skips the intake skill entirely (opt-out
  per round-1 A1).
- The intake skill never asks more than one question per turn and
  never reads as a fixed interview template.
- `/auto goal` (explicit invocation) runs the intake skill and
  produces a goal.md without starting a run.
- Goal file content is snapshotted into the ledger at run start as
  `goal_source.content`; resume uses the snapshot; file edits emit
  a divergence notice.
- All existing `bash tests/run.sh all` pass; new unit + integration
  tests pass.
- The plan's intake dialogue reads as natural conversation, not as
  an interview. (Tested by: dogfood the skill on a real /auto
  invocation; operator confirms the dialogue felt human. Adversarial
  A7 notes this is subjective; the dogfood test is the planned
  evidence, not a guarantee.)
