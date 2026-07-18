---
title: "RFC — auto workflow-substrate migration (superseded)"
status: superseded
superseded_by: docs/plans/2026-07-17-001-feat-agent-native-auto-plan.md
created: 2026-05-29
type: rfc
parent: docs/plans/2026-05-29-001-feat-auto-v0.5.0-workflow-substrate-plan.md
revisit_conditions:
  - "Production run volume rises >=10x (currently 2 ledgers system-wide; trigger is >=20)"
  - ">=3 distinct off-script shapes accumulate AND >=2 are in-process observable (so try/catch in compiled JS can actually catch them — review r4 finding 3)"
  - "Workflow tool ships with a verified primitive surface AND a written API-stability commitment from Claude Code maintainers (review r4 finding 11)"
---

# RFC: auto workflow-substrate migration (parked)

> **Status:** SUPERSEDED by
> [docs/plans/2026-07-17-001-feat-agent-native-auto-plan.md](2026-07-17-001-feat-agent-native-auto-plan.md)
> (agent-native /auto). A live agent holding steering verbs is the fully-general
> form of the generic recovery this RFC's own reasoning converged toward, and the
> substrate's prerequisite (a stable Workflow-tool API) never materialized. Parked
> content preserved below for provenance; the revisit conditions are no longer tracked.
>
> **Status (historical):** PARKED. This RFC is the contract a future migration
> must satisfy. The live, executing plan is the v0.4.x escape-hatch
> at `docs/plans/2026-05-29-001-feat-auto-v0.5.0-workflow-substrate-plan.md`.
> Re-activate this RFC only when ALL three revisit_conditions in
> the frontmatter resolve positively.
>
> Findings from review r4 that re-shape individual sections
> below have been applied in place so this RFC reflects the
> reviewed-final shape of the migration plan, not an earlier
> draft.

> **Plan absorbed review r1, r2, r3, and r4.** Per-finding citations
> inline were extracted to
> `docs/plans/2026-05-29-001-REVIEW-LOG.md` (review r3 finding 20).
> The decisions stand on their own merits, but they are **not
> immune to re-debate when new primary evidence emerges** (review
> r3 finding 10 — loosening the prior no-re-debate fence so the
> depth/scope of U1-U5 can be revisited after U0 returns). See
> the REVIEW-LOG for full provenance.
>
> **HARD ASSERTION (review r3 finding 1; superseded by review r4
> finding 2's document-level inversion):** if U0 returns "no
> Workflow primitive surface" (the prior is strongly toward this —
> see ToolSearch evidence in the NOTE below), the **default action
> is v0.4.x escape-hatch re-scope, NOT "wait for Workflow to
> ship."** Per review r4, the escape-hatch re-scope is now the
> Plan of Record above; this section is preserved as the prior
> conditional. U1-U5 specifications below are **DRAFT ONLY
> pending revisit-conditions**; the intent→primitive mapping
> table (KTD-4), heartbeat cadence enforcement (KTD-7), structural
> validator rule set (U2b), and JS-side ledger client mechanism
> (KTD-3) are **binding only after U0 verifies the primitives
> that produce them.**

> **NOTE on Workflow tool availability (review r2, finding 1):** As
> of plan writing, the Workflow tool is NOT present in this harness's
> deferred-tool inventory (confirmed by ToolSearch across multiple
> queries for `workflow` and `pipeline parallel agent script run` —
> only TeamCreate, Monitor, CronCreate, SendMessage were returned).
> U0 (now split off as its own preflight RFC — see
> `docs/plans/2026-05-29-003-spike-workflow-primitive-surface.md`
> when authored) must therefore either (a) verify Workflow shipped
> under a different name, (b) confirm a future release date, or
> (c) trigger the v0.4.x escape-hatch re-scope. **Path A (full
> cutover) is contingent on (a) or (b) resolving positively; with
> absent-from-inventory as the prior, the live path is the v0.4.x
> escape-hatch re-scope or Path B without ever flipping the
> substrate flag default.**

## auto v0.5.0 — workflow substrate, plain-language recipes (parked draft)

### Summary

Replace auto's engine (~2150 LOC of pure file deletion +
~275 LOC reduction in `auto.py` = **~2425 LOC net Python
removed**, per review r4 finding 13 — the earlier "deleted"
phrasing conflated deletion with reduction). Deleted files:
tick.py, tick_advance.py, tick_guidance.py, orchestrator.py;
`auto.py` is GUT (reduced from ~355 to ~80 LOC), not deleted.
Replace with
Claude Code's Workflow tool as the orchestration substrate (existence
and primitive surface verified in U0 below — load-bearing prerequisite).
Recipes stop being JSON-with-fields and become
**plain-language markdown** at `recipes/<name>.md` — Claude compiles them
to workflow scripts on first invocation (cached at
`.claude/workflows/<recipe>.compiled.js`, mtime-invalidated when the
markdown source changes).

The ledger today already lives across four files (lib/ledger.py 160
LOC facade + ledger_core.py 1032 + ledger_mutators.py 564 +
ledger_emitters.py 294 = ~2050 LOC). v0.5.0 adds **~50 LOC public
API + ~150 LOC of CLI bridge if option (a) wins per KTD-3 — ~200
LOC total** (per review r4 finding 14 — the earlier "~50 LOC"
headline understated work ~3x, and KTD-3's honest figure now
propagates to Summary, Scope, and U1 Goal) on top of the existing
2050 LOC across four files (no substance moves; nothing deletes in
the ledger family). The underlying files KEEP their shape because
their I-1/I-2 grammar enforcement and emitter composition is what
guarantees correctness for compiled workflows.
`/auto-status`, `/auto-resume`, and `on-stop.py` continue to read it.

**Net-complexity table** (review r2, finding 10 — honest framing):

| Bucket | Lines | Properties |
|---|---|---|
| Removed (delete + gut) | ~2150 LOC pure deletion + ~275 LOC reduction in auto.py = ~2425 LOC net (review r4 finding 13) | Fully unit-tested; debuggable with a stack trace; closed state vocabulary |
| Added | Compiler Skill + post-compile validator + stat-and-validate helper + reference docs + off-script fixture harness (v0.5.1) + ~200 LOC of JS-bridge code on `lib/ledger.py` (option a) — review r3 finding 19 | Non-deterministic surface; per-recompile validation gate; trust-via-fixtures |
| Unchanged | ledger family (~2050 LOC across 4 ledger* files + ~336 LOC sibling `lib/emitters.py` = ~2386 LOC total, per review r4 finding 23 — earlier 2186 was an arithmetic typo) + v0.4.0 entry surface | I-1/I-2 grammar preserved; Stop hook contract preserved |

Complexity is RELOCATED, not reduced — from deterministic Python
into a compile step that must be trusted on every recipe edit. The
trade buys the ability to express off-script policy in prose; reader
should evaluate the trade on this actual shape, not on a one-sided
LOC headline.
The v0.4.0 entry-surface CONTRACT is preserved at the user-facing
level for `auto-detect.sh`, `auto-spawn.py`, and `auto-workspace.py`;
**implementation behind it is restructured** (review r4 finding 10 —
the earlier "entry surface stays intact" framing read as no-risk
when the plan's own corrections show it isn't): `commands/auto.md`,
the `auto` loop-driver skill, and the `auto-driver` skill ARE
modified (review r3 finding 14): `commands/auto.md` and `auto`
shrink to dispatch-only; **`auto-driver` gains the warm-compile
responsibility** (Skill-invoked recipe compile before fan-out,
per KTD-2 multi-plan section); `auto-spawn.py` loses compile;
`auto.py` shrinks substantially. User-facing contract is
preserved; implementation surface is meaningfully reshaped.

Pain this addresses: today's engine has a CLOSED state vocabulary
(`pending`/`dispatched`/`verdict-returned`/`fixed`/`failed-with-verdict`/
etc.) and reality keeps producing states it can't represent. Off-script
failures force operator side quests (manual ledger surgery, abort + re-
plan). With recipes as plain-language and compiled to JS, off-script
handling becomes part of the recipe's expressed intent ("on timeout
retry once; on malformed verdict retry with augmented prompt"), and
compiles to `try/catch` inside the workflow script. The recipe author
declares deviations; the runtime handles them as normal program flow.

## Problem Frame

Shawn's diagnosis (this session, 2026-05-29):

1. **"Auto feels extremely rigid."** Any inconvenience or variable that
   isn't right ends up turning into a side quest. The engine handles
   the states it models; it has no shape for everything else.
2. **Concrete side-quest pattern:** "A unit failed in a way the recipe
   didn't anticipate — not 'failed verdict' but 'wrong shape of
   failure' — and I had to manually unstick." The state machine treats
   off-script failure as an unrecoverable stuck state.
3. **Counterfactual cost:** ship nothing → every auto run risks a side
   quest, friction compounds, "I stop using auto and just run things
   by hand." Status quo is actively losing.

**Evidence-base note (review r1, finding 14; review r3, finding 4 —
PATH CORRECTED + EVIDENCE-PULL VERDICT WRITTEN; review r4 finding
3 — PRE-U0 anchor-anecdote classification):** the diagnosis above
rests on one concrete anecdote.

**Pre-U0 classification of the anchor anecdote (review r4 finding
3):** the single concrete shape is "a unit failed in a way the
recipe didn't anticipate and I had to manually unstick." Manual
unsticking is an OPERATOR INTERVENING FROM OUTSIDE the running
session — by definition cross-process. The proposed substrate
mechanism is "off-script policy compiles to try/catch inside the
workflow script." try/catch is in-process-only by definition: it
catches exceptions raised inside the same JS event loop in the
same Workflow invocation. **The single data point the entire
substrate rewrite is justified by is the case the substrate
cannot handle.** This is a known mismatch and is itself the
dispositive reason to re-scope to v0.4.x cross-session-
observability improvements (Plan of Record above), not to wait
for U0 to discover three more shapes that may never arrive at
observed run volume. U0's exit gate item 2 (≥2 in-process
observable shapes) is preserved below as the contract a future
RFC must satisfy, but the prior is now explicitly against the
substrate path.

Before U0/U1 begin, U0 also pulls
the actual off-script incident history from production runs
(`<repo_root>/.claude/auto/<run-id>.json` ledgers per
`lib/ledger_core.py:252-258` — earlier reference to
`~/.local/state/auto/` was wrong). For each, document (a) frequency,
(b) whether a minimal escape-state addition to the existing engine
would have handled it, (c) whether plain-language recipe prose would
have prevented it, (d) **in-process vs cross-process** (per the
classification above — only in-process shapes can be addressed by
the substrate's try/catch mechanism).

**Empirical verdict (live `find ~/projects -path '*/.claude/auto/*.json'`
at planning time, review r3 finding 4):** exactly TWO production
ledger files exist system-wide (both in
`brand-foundry-backend/.claude/auto/`); ZERO in `auto/.claude/auto/`
itself. The kill criterion (≥3 distinct off-script shapes AND ≥2
in-process observable) is empirically unsatisfiable from this
footprint. **The plan's own escape clause is therefore the
PRIMARY PATH, not a contingency:** re-scope to a v0.4.x increment
that adds 2-3 new off-script states to the existing engine for
specific shapes actually observed, and improves cross-session
observability so operators recover via `/auto-resume` rather than
ledger surgery. This plan is parked for re-examination only if
observed run volume increases by an order of magnitude AND new
off-script shapes accumulate. The deep transcript-based pull
(session histories, operator side-quest narratives) is out of
scope for the doc-edit task and is left as a U0 deliverable
should the plan ever re-activate.

Underlying structural diagnosis:

- The engine's `tick_advance.py` + `orchestrator.py` + `iteration.py`
  model a closed state-transition graph. Adding a state means editing
  the engine and shipping a new version.
- Recipes declare WHAT runs (units, dependencies, iteration gate) but
  not HOW failure is handled — that's the engine's hard-coded
  responsibility, with the same handling across every recipe.
- The Workflow tool — **asserted as shipped by Claude Code in this
  same session, BUT the primitive surface is unverified in the
  current harness's deferred-tool inventory** (review r1, findings 1
  & 5; review r2, finding 1 — ToolSearch `select:Workflow` returned
  no matches, plus broader keyword searches turned up only
  TeamCreate, Monitor, CronCreate, SendMessage). The plan ASSUMES
  primitives that subsume most of what the engine does:
  `pipeline()`, `parallel()`, `agent()` with
  `schema`/`isolation`/`model`, `while` loops with `budget`,
  `workflow(name, args)` composition, automatic resume-from-cache by
  run-id. **U0 (preflight spike, now split off as its own RFC) is a
  hard prerequisite that verifies this surface against the actual
  tool available in the targeted Claude Code release.** If U0 fails
  or finds a materially different shape, the plan re-scopes or
  shelves before any LOC moves. The harness would then provide
  natively what the engine carries forward as ~2425 LOC.

What the engine got right and stays:
- The ledger as the disk-persisted source of truth that survives
  rate-limits, session exits, and process death.
- The Stop hook (`on-stop.py`) that holds the session open until the
  ledger's exit predicate is met — auto's deliberate-stop guarantee.
- The v0.4.0 entry surface (bare-/auto hypothesis envelope, multi-plan
  fanout via cmux workspaces, project-as-workspace marker).
- The recipe library as a named, discoverable set of workflows (a1,
  a2, a4, w stay as named recipes; their implementation substrate
  changes).

## Scope

### In scope

- **Plain-language recipe format** at `recipes/<name>.md` with a light
  section structure: Intent / Shape / Iteration / Exit / Off-script
  policy / Adapter. Replaces today's `recipes/<name>.json`.
- **Recipe compiler**: a Claude pass that reads a recipe markdown +
  the ledger-library contract + the Workflow primitive set and emits
  `.claude/workflows/<recipe>.compiled.js`. First invocation triggers
  the compile; subsequent invocations reuse the cached artifact unless
  the source markdown's mtime is newer.
- **Ledger-as-library**: factor `lib/ledger.py` (the parts compiled
  workflows need to call) into a thin import surface — `init_ledger`,
  `record_verdict`, `set_gaps_open`, `recompute_predicate`,
  `record_iteration_step`. **~50 LOC of helpers + ~150 LOC of CLI
  bridge (option (a) per KTD-3) = ~200 LOC total** (review r4
  finding 14 — honest framing propagated from KTD-3). The schema
  doc (`docs/contracts/ledger-schema.md`) becomes the cross-recipe
  contract.
- **Engine deletion**: `lib/tick.py`, `lib/tick_advance.py`,
  `lib/tick_guidance.py`, `lib/orchestrator.py`,
  the recipe-walking parts of `lib/auto.py`. ~2425 LOC removed (see
  the per-file LOC roll-up in U5). NOTE: `lib/iteration.py` is
  RELOCATED, not deleted (load-bearing for the ledger's lazy
  imports). Per the Cutover strategy section below, this deletion
  is staged: canary in v0.5.0, remaining migrations in v0.5.1,
  legacy deletion in v0.5.2 gated on the quantitative criterion.
- **`/auto-author-recipe` rewrite**: conversational intake produces a
  markdown recipe instead of JSON.
- **Migration of the 4 existing recipes** (a1, a2, a4, w) from JSON to
  markdown, then compiled to workflow scripts. Side-by-side
  verification: legacy engine + new workflow substrate run the same
  recipe over the same plan; outputs (ledger state, verdicts, exit
  predicate) must match.
- **Stop hook untouched**: `on-stop.py` continues to read
  `exit_predicate_result` from the ledger. The ledger-library helpers
  preserve the I-1 invariant (recompute predicate on every write).
- **Entry surface contract preserved at the user-facing level;
  auto-driver / auto-spawn split is restructured** (review r3
  finding 21 — earlier "dispatch lines updated" framing
  understated the model/Python boundary rearrangement):
  `auto-detect.sh`, `auto-spawn.py`, `auto-workspace.py` keep
  their v0.4.0 shape unchanged. `commands/auto.md`, the
  `auto-driver` skill, and the `auto` loop-driver skill are
  MODIFIED. **Compile responsibility migrates model-side to
  `auto-driver`; `auto-spawn.py` becomes a pure fan-out shell**
  with no compile responsibility (per KTD-2 multi-plan section).
  The dispatch path now acquires a model-side Skill invocation as
  a hard prerequisite to the Python fan-out — if the Skill
  invocation rate-limits or hangs, multi-plan dispatch blocks
  before any workspace spawns; this is enforced via the
  compile-failure contract in KTD-2. The `auto` loop-driver skill
  shrinks because the loop becomes a single `Workflow({name})`
  call. Heartbeat contract for the Stop hook is preserved (see
  KTD-7). Multi-plan fanout (plan 004) interacts with the
  recipe-compile cache — see Open Q4 and KTD-2's pre-fanout
  warm-compile note.

### Deferred / out of scope

- **Goal-as-markdown** (plan 003, gated `blocked_by: 002`). Stays
  separate. Will integrate with v0.5.0 by passing the snapshotted
  goal through to the compiled workflow as an arg; not a structural
  change to either plan.
- **Cmux fanout modes** (plan 004). Already shipped in v0.4.0;
  workflow substrate doesn't change how multi-plan fanout works (it
  still spawns separate cmux workspaces per plan; each runs its own
  `/auto <plan>` which now uses the new substrate).
- **The `a1-with-rebound` recipe** (the upstream-rebound idea from
  this session). v0.5.0 makes this AUTHORABLE as a plain-language
  recipe — but writing it is out of scope here. The substrate work is
  the predecessor.
- **Visual workflow inspection / debugging** beyond `cat`ing the
  compiled artifact. A future plan could add a `/auto-inspect-recipe
  <name>` command; not load-bearing for v0.5.0.
- **Replacing the recipe library with operator-authored workflows
  directly** (the third option from the brainstorm). Recipes stay
  named, discoverable, library-curated. The Workflow primitive set is
  the substrate; recipes are the operator-facing vocabulary.

## Cutover sequencing

**Committed: staged.** The plan ships in three releases (review r2,
findings 8 & 11 — Path A is one-way deletion of ~2425 LOC against
the conjunction of a non-deterministic compiler, an unverified
primitive surface, no automated semantic verification for off-script
handlers, and a codebase that has historically required multiple
post-merge review rounds; offering Path A as co-equal invites it
under time pressure):

- **v0.5.0** — U0 preflight + U1 ledger library + U2 compiler +
  U3 limited to `w` only as the canary + a SECOND canary
  exercising iteration (a2-shape minimal fixture, per review r2
  finding 7 — Path B's default canary `w` is a stub with no
  iteration block and exercises essentially none of the
  deletion-risk surface) + a substrate flag
  (`AUTO_SUBSTRATE=workflow|legacy`, default `legacy`). Both
  engines coexist; the `w` and a2-iteration-fixture recipes run on
  the workflow substrate when the flag is set.
- **v0.5.1** — Migrate a1/a2/a4. Flag default flips to `workflow`
  after the gate below is met. Legacy engine still survives.
- **v0.5.2** — Delete the legacy engine. **Gate (review r2 finding
  11; review r3 finding 5; REPLACED per review r4 finding 12 —
  the 60-day time-box was unfalsifiable at observed run volume
  because <10 runs in 60 days is a coin flip, not statistical
  signal):** the gate is a RUN-VOLUME criterion, not calendar
  elapsed. Cutover requires:
  - **N≥20 successful production runs** on
    `AUTO_SUBSTRATE=workflow` with no compiler-mistranslation
    side quest, AND
  - **≥3 distinct off-script handlers having fired in
    production** (the substrate's central new capability must
    have been exercised on real shapes).

  If N<20 at any 60-day checkpoint, either EXTEND the box (with
  a hard ceiling of 180 days before forced re-evaluation) OR
  exit the substrate path entirely and route back to the
  Plan-of-Record escape-hatch increment. Do NOT cutover on
  unproven mechanism just because calendar time elapsed.

  **Rollback removed (review r4 finding 5):** the prior "honest
  rollback" branch presumed a working legacy fallback; the
  fallback-liveness invariant established below shows legacy
  bitrots during the box at observed run volume. Once entered,
  v0.5.2 is a one-way door — cutover or extend. The decision
  to enter v0.5.2 at all is therefore load-bearing and
  paired with the Plan-of-Record inversion.

  Absence of data MUST NOT masquerade as evidence of
  reliability. The run-volume gate ensures the cutover decision
  is made on observed behavior, not on the absence of
  observations.

  **Permanent dual-engine maintenance is acknowledged as a
  COMPLEXITY LINE ITEM, not an implicit "free option":** every
  change to either engine must preserve cross-substrate parity
  for as long as both exist. The 60-day box prevents that cost
  from compounding silently.

  **Fallback-liveness invariant (review r4 finding 5 — chose
  option (c)):** the rollback option is REMOVED from v0.5.2's
  gate. The 60-day box is a one-way door and is called that
  explicitly. Rationale: at the observed run volume (Problem
  Frame's 2-ledger empirical verdict) the legacy engine receives
  effectively zero production runs across the 60 days while U1
  (ledger library API), U4 (auto-driver / auto-spawn split,
  phase_advance.py split), and U5a (test porting) all modify
  surrounding code. An engine that has not executed in 60+ days
  against changed surrounding code is NOT a working fallback —
  it is a snapshot of code that may have silently broken.
  Shadow-routing 10% of runs to legacy (option a) is
  unaffordable at 2-ledger volume (the shadow set would be
  essentially zero); a weekly parity-suite CI run against legacy
  (option b) is achievable but doesn't exercise real ledger
  shapes. Option (c) — name the one-way door — is the honest
  choice. The v0.5.2 gate becomes: cutover or extend the box
  with explicit re-evaluation. The "honest rollback" branch in
  U5 and the R1c on-call playbook are REMOVED.

  **Consequence (pairs with the document-level inversion in the
  preamble):** because the one-way door is explicit, the
  decision to enter v0.5.2's box at all becomes load-bearing.
  The Plan-of-Record inversion (escape-hatch first; substrate
  RFC parked until revisit conditions hold) keeps Shawn out of
  the one-way door until the empirical case for it is real.

Staged is NOT "defer the compiler" — the compiler IS the plan's
thesis. Staging defers only the wholesale cutover. Operator-authored
workflows directly remains out of scope per the Scope section.

> **Path A escape hatch (one paragraph, review r2 finding 8;
> review r3 finding 11 — the harness moves to v0.5.1 so the
> collapse condition is rewritten):** If U0 + the canary parity
> tests come back trivially clean AND the Workflow primitive
> surface verifies exactly as assumed AND a1/a2/a4 migration
> SHIPS WITH `## Off-script Fixtures` sections AND the
> off-script fixture harness (KTD-4 below) — which itself only
> lands in v0.5.1 — covers all catalogued rigidity shapes
> against those recipes, U5 can collapse to v0.5.1 (not v0.5.0)
> by including a1/a2/a4 migration. The earlier "collapse to
> v0.5.0" framing was inconsistent with the harness deferral.
> Default plan assumes staged; the collapse is a conscious
> decision Shawn makes with eyes-open acknowledgement of which
> P0/P1 findings he's accepting.

## Key Technical Decisions

### KTD-1: Recipe format — plain-language markdown with section structure

A recipe is `recipes/<name>.md` with YAML frontmatter for metadata and
six known sections. The structure is light enough that Claude can
reliably compile it; not so loose that recipe authors invent
unparseable shapes.

```markdown
---
name: a1
version: 1
description: Classic plan-build-review until only minor findings remain
default_adapter: ce
---

## Intent

Ship a plan from start to clean — plan it, build it, review the build,
fix what review found, repeat until only P3 findings remain.

## Shape

Sequential. One plan unit. After plan, one build unit per work item
the plan produced. After each build, a review unit. Reviews can fan
out in parallel by file when the diff touches more than 3 files.

## Iteration

The exit predicate (below) is the loop. Repeat the build-review-fix
cycle until the predicate is met. No explicit iteration bound —
predicate-driven.

## Exit

Done when every unit's most recent verdict has zero P0/P1/P2
findings. P3 findings ship.

## Off-script policy

- Unit returns malformed verdict: retry once with the prompt augmented
  by "previous attempt returned malformed verdict; return clean JSON
  this time."
- Unit times out (no verdict written in 600s): halt and surface to
  operator; do not retry automatically.
- Unit dispatches but never starts (cmux spawn failure): retry once
  after 30s.
- Iteration cap reached without exit: halt; emit `exit_reason:
  iteration-bound-breached`.

## Adapter

Plan units invoke `/ce-plan`. Build units invoke `/ce-work`. Review
units invoke `/ce-code-review` at high effort.
```

Why this shape:
- **Frontmatter is minimal**: name, version, description, adapter
  default. Everything else is in prose.
- **Six sections** cover what the compiler needs: what the recipe is
  for, how units relate, when to loop, when to stop, what to do when
  reality deviates, which workflow tools to call.
- **Prose-in-sections** lets the author express subtle policy ("fan
  out by file when the diff touches more than 3 files") that JSON
  would force into rigid fields.
- **The compiler reads all six sections + the ledger library contract
  + the Workflow primitive set + the adapter docs**, and emits a
  workflow script that satisfies all of them.

Round-1 review note: the compiler is the load-bearing risk. If it
mistranslates, the recipe runs wrong. Mitigation: every compile emits
a structured diff between the input markdown and the output script's
behavior summary (also AI-generated, in the compiled file's header
comment) so an operator can `cat` the compiled artifact and verify it
matches intent before invoking.

### KTD-2: Compile-on-first-invocation, mtime-invalidated cache

`/auto <recipe>` (or any of the v0.4.0 entry forms) resolves the
recipe by name to `recipes/<name>.md`. **The compile cannot be a
direct Python function call from a non-Claude process** (review r1,
finding 4) — the Skill tool is a model-side primitive. So the
compile invocation lives in the model-side dispatch path:

1. `commands/auto.md` body resolves the recipe name, stats
   `recipes/<name>.md` → records mtime, and checks for
   `.claude/workflows/<name>.compiled.js`.
2. **Cache freshness uses a QUADRUPLE key** (review r2 finding 9;
   expanded to quadruple per review r3 finding 16; see KTD-3
   "Cache invalidation quadruple"): the compiled file is fresh iff
   (compiled-source mtime ≥ source mtime) AND (compiled file's
   `workflow_primitive_version` header == current
   `docs/contracts/workflow-primitive-set.md` content hash) AND
   (compiled file's `ledger_library_version` header == current
   `docs/contracts/ledger-library-api.md` content hash) AND
   (compiled file's `compiler_skill_version` header == current
   `skills/recipe-compiler/SKILL.md` content hash + active claude
   model id). If all four match → the model immediately invokes
   `Workflow({scriptPath, args})`.
3. If ANY of the four is stale or missing → the model invokes the
   `recipe-compiler` Skill tool BEFORE bash dispatch. The compiler
   writes the compiled JS atomically (mkstemp + rename) to
   `.claude/workflows/<name>.compiled.js`, embedding the four
   version markers in the header comment. Then the model invokes
   `Workflow({scriptPath, args})`.
4. `lib/recipe-compile.py` is reduced to a stat-and-validate helper
   (NOT a synchronous compiler entry point): it inspects all four
   key components (source mtime, primitive-set hash, library-API
   hash, compiler-skill-version+model-id) against the cached
   artifact's header, and tells the model whether a recompile is
   needed. The actual compile is Skill-invoked.

**Multi-plan fanout interaction (plan 004):** when N parallel
`/auto <plan>` invocations land in separate cmux workspaces and the
recipe has just been edited, all N workspaces would race the same
compile target. The compile cannot live in `auto-spawn.py` (Python,
non-Claude process; Skill tool unavailable there) — review r2,
finding 3 surfaced this incoherence. Resolved flow:

1. `auto-driver` (model-side, has Skill access) detects multi-plan
   dispatch is needed (via `auto-detect`'s hypothesis envelope).
2. `auto-driver` invokes the `recipe-compiler` Skill ONCE if the
   recipe is stale per `lib/recipe-compile.py`'s stat-and-validate
   check (KTD-2's quadruple cache key).
3. ONLY THEN does `auto-driver` shell to `lib/auto-spawn.py`, which
   dispatches the N workspaces. Cache is guaranteed warm; every
   workspace reads the same compiled artifact.

**Compile-failure contract** (review r3 finding 8 — the
"unchanged entry surface" framing understates this; multi-plan
fanout in v0.4.0 fails synchronously on a shell error, but the new
flow introduces a model-side Skill invocation between detection
and dispatch with its own failure modes): **If the Skill-invoked
compile fails, `auto-driver` MUST NOT shell to `auto-spawn.py`.**
It surfaces the compile error to the operator and exits. The
failure is recorded in the ledger init
(`substrate: workflow, compile_status: failed`) so
`/auto-status` reflects it. The failure is NEVER silently
proceeded around — N workspaces racing a stale recipe is a worse
outcome than a clean abort. **Rate-limit handling:** if the
Skill invocation rate-limits, the operator gets a typed error
("recipe compile rate-limited; retry") and the dispatch aborts
cleanly; the dispatch never hangs waiting for the Skill.

`auto-spawn.py` therefore has NO compile responsibility — it
neither stat-checks nor invokes the compiler. It is purely a
workspace fan-out shell. Open Q4's earlier alternatives (file-lock
serialized first-compile, content-hash dedup post-write) are dead
— all required a Python-callable compiler, which the Skill-tool
constraint forbids.

`.claude/workflows/` is gitignored. The compiled artifact is a
runtime cache, not a build product. The markdown recipe in `recipes/`
is the source of truth; the compiled JS is regenerable from it.

**One role only for the compiled file** (review r1, finding 30):
it is a DERIVED ARTIFACT. Operator edits to it are UNSUPPORTED and
will be silently overwritten on the next source edit. Operators can
`cat` to inspect what'll run; they MUST NOT edit. Power users who
want to bypass the compiler use `--workflow <path-to-js>` (Open Q3
flag) pointing at a hand-written JS file under their own control.
Open Q2 (detect-and-warn on hand-edits) is resolved as "no" — the
file is regenerable and edits are unsupported.

The compiler is a dedicated Skill (`recipe-compiler`) with a tight
system prompt that constrains output to a known-good shape.
**Per-recompile validation:** every recompile (not just U3's
migration parity tests) runs against a recipe-owned `## Sanity
Fixture` section declaring at least one input → expected
ledger-shape, before the new artifact replaces the old. If the
sanity fixture fails, the recompile is rejected and the old artifact
stays. This is the per-edit safety net for the compiler's
non-determinism (review r1, finding 12). **`## Sanity Fixture` is
MANDATORY in the v0.5.0 recipe-format spec** (review r2 finding 17;
elevated from the earlier "optional with warning"); a recipe
missing one fails compile with a clear authoring error.

### KTD-3: Ledger gains a thin library API on top of the existing four-file split

**Current state (correction from review r1 findings 2/6/10/15;
LOC-accounting reconciliation from review r2 finding 23):**
`lib/ledger.py` is already a **160 LOC facade**; the substance lives
in `lib/ledger_core.py` (1032) + `lib/ledger_mutators.py` (564) +
`lib/ledger_emitters.py` (294) — **four ledger* files totaling
~2050 LOC** — plus the sibling `lib/emitters.py` (336 LOC, decided
in U1). Together the ledger neighborhood is ~2386 LOC; the
"~2050 LOC across four files" figure used in the Summary, Scope,
and U1 refers strictly to the four ledger* files and does NOT
include `lib/emitters.py` (which is listed as a separately-decided
fifth file in the verdict table below). The grammar/atomic-write/
predicate-recompute split exists already (factored in B5 per
ledger.py docstring). `ledger_core.recompute_predicate` alone is
~200 LOC of carefully-documented invariant logic (B7 helpers,
scale-aware gating, iteration_pending composition, the I-1
chokepoint).

**v0.5.0's job is to ADD an API, not rewrite the substance.** The
five helpers compiled workflows call (`init_ledger`,
`record_verdict`, `set_gaps_open`, `record_iteration_step`,
`recompute_predicate`) are all THERE already as primitives inside
ledger_core / ledger_mutators / ledger_emitters. The work is:
(a) exposing the right import surface as a thin API,
(b) adding `record_iteration_step` as a composed wrapper around
today's `atomic_iterate_step` + `set_loop` + emit_within_phase
(currently composed by tick.py),
(c) adding `heartbeat()` as a 6th helper (see KTD-7) for the Stop
hook's freshness contract.

**U1 entry gate — `record_iteration_step` signature walk** (review
r3 finding 9; CORRECTED per review r4 finding 1 — the prior
split-into-two recommendation contradicted KTD-3 cross-runtime
section's atomicity requirement and is REMOVED): tick.py's
composition of `atomic_iterate_step` + `set_loop` +
`emit_within_phase` is NOT a simple call chain — it is interleaved
with the tick's exit-predicate check, the iteration-bound
enforcement in `lib/iteration.py:G2`, and the auto-flip-to-work
path that decides whether to emit at all. Before U1 begins,
produce the actual signature of `record_iteration_step` by
walking the current tick.py composition. Identify: (i) which
inputs come from the recipe (bound, gate_unit, emit_template),
(ii) which come from runtime state (current_attempts,
current_phase, verdict_decision), (iii) which decisions stay
inside the helper vs. are exposed to the caller (auto-flip vs.
iterate, bound-breached classification, gate-unit reset).

**Single fat transactional verb (review r4 finding 1):** the
iteration verb MUST be ONE atomic Python call running
decide+act inside a single `_with_locked_ledger` invocation —
e.g. `python lib/ledger.py iterate_step --if-state=verdict-returned
--gate-unit=X --emit-template-name=<name|none> --bound=N
--on-over-bound=stop|error`. The split-into-two recommendation
(`record_iteration_step` + `decide_iteration_continuation`,
compiler emits both calls) is REMOVED: a JS-side decide() that
returns a decision followed by a JS-side act() write opens the
lost-update window `_with_locked_ledger` (lib/ledger_core.py:
718-721) exists to eliminate (the fcntl lock releases between
subprocess calls), and tick_advance.py:454-457 explicitly says
splitting the iterate step into two writes would open exactly
this window. Also: the emitter parameter today is a Python
callable (`emitters.iterate_template` / `emitters.no_emit`
selected from `recipe.iteration.emit_template` at
tick_advance.py:458-461); callables cannot cross subprocess
boundaries. **The emitter callable stays Python-side; the verb
takes the emit-template NAME, not the callable; resolution to
the callable happens inside the locked verb.**

**Atomicity ceiling exemption (review r4 finding 1):** KTD-3
acknowledges the iteration verb is the most-parameterized of the
transactional verbs and WILL exceed the 5+2 args ceiling stated
elsewhere in U1's entry gate. The ceiling rule does NOT apply to
atomic transitions where splitting would break atomicity. The
iteration verb is the canonical exception. Without this single
fat verb, the compiler is asked to get a wide-flag composition
right on every recipe edit — but splitting it would be strictly
worse (lost-update window) than tolerating the wide signature.

**File-by-file verdict (per-file decisions, finding 10):**
| File | Current LOC | Verdict |
|---|---|---|
| `lib/ledger.py` | 160 | KEEP — facade re-exports the new public API alongside today's surface |
| `lib/ledger_core.py` | 1032 | KEEP — I-1, recompute_predicate, B7 helpers, _atomic_write all load-bearing for compiled workflows |
| `lib/ledger_mutators.py` | 564 | KEEP — I-2 grammar enforcement; compiled workflows still need this |
| `lib/ledger_emitters.py` | 294 | KEEP — phase-transition emitter composition; auto-resume seam→work depends on this |
| `lib/emitters.py` | 336 | **KEEP** (review r2 finding 15) — load-bearing for both auto-resume and the compiled JS workflow's auto-flip path. `advance_to_phase` (split into `lib/phase_advance.py`) imports `emitters.resolve(emitter_name)` and `phase_grammar.emitter_name_for_arrival`; the single-chokepoint contract for phase advancement is preserved by routing both the JS auto-flip and Python auto-resume through `phase_advance.advance_to_phase`. |
| `lib/iteration.py` | 314 | RELOCATE to `lib/ledger/iteration.py` (lazy-loaded by ledger_core line 606; not engine-only — see finding 23) |
| `lib/phase-grammar.py` | (existing) | RELOCATE / KEEP (lazy-loaded by ledger_core line 625 — load-bearing for the ledger's purity guarantees) |

**The new library API surface** lives in `lib/ledger/__init__.py`
(~50 LOC of new wrappers) and `docs/contracts/ledger-library-api.md`
(new doc). The five helpers + `heartbeat` are documented signatures;
their implementations delegate to the existing four files.

**Net LOC for U1** (review r3 finding 19 — honest framing of the
JS-bridge addition cost): ~50 LOC of library wrappers; PLUS ~150
LOC of CLI verb handlers in `lib/ledger.py` if JS bridge option
(a) wins (the default per the cross-runtime section); final
number deferred-pending-U0 choice of bridge mechanism (option a
vs. b). Sidecar option (b) shifts the bridge LOC out of
`ledger.py` but adds daemon-lifecycle code instead. Either way,
U1's "added" total is ~200 LOC, NOT ~50 — the earlier "~50 LOC of
new wrappers" headline understated the work ~3x. ZERO LOC deleted
in the ledger family. The honest framing is "expose existing
logic through a stable API + add the cross-runtime bridge it
needs," not "factor 1200 → 330."

**The ledger schema doc** (`docs/contracts/ledger-schema.md`) gets
expanded with the library API surface as the cross-recipe contract.

**The state-transition grammar (I-2)** stays in `ledger_mutators.py`.
Compiled workflows that violate it get a clear error at the
helper-call site, not silent corruption.

**JS-side ledger client — cross-runtime access (MIGRATION-
CONTINGENT, per review r4 finding 17)** (review r2,
finding 2; review r3, finding 2 — atomicity correctness override):
**This entire section exists only because recipes compile to JS —
it is migration-contingent scope, not v0.5.0 baseline.** Per the
document-level inversion (preamble) the v0.5.0 Plan of Record is
the escape-hatch increment; the JS bridge specified below only
activates if the migration RFC re-opens. Under the escape-hatch
path U1 in v0.5.0 becomes the ~50 LOC library-wrapper addition
only (useful under either path because it cleans up the ledger's
public API regardless of substrate); the JS bridge lands in the
release that actually compiles a recipe to JS, not before.

The library API is Python; compiled workflows run in JS. The
JS-side bridge is specified as ONE of (decision made by U0 spike
based on Workflow's JS-runtime hosting):

- **(a) Extend `lib/ledger.py` _cli with TRANSACTIONAL verbs ONLY.**
  Naive per-helper CLI exposure violates I-1 — each subprocess
  acquires its own flock, so a JS-side `read predicate → decide →
  write verdict` sequence opens the lost-update window
  `_with_locked_ledger` (lib/ledger_core.py:718-721) was designed
  to eliminate ("The lock spans the WHOLE read-modify-write — the
  lost-update guard"). **JS MUST NEVER read-then-write across two
  subprocess boundaries.** Instead, ledger CLI verbs take a
  JSON-encoded transition spec where the precondition and the
  write happen inside the SAME `_with_locked_ledger` call.
  Concretely: `python lib/ledger.py record_verdict
  --if-state=dispatched --unit-id=X --verdict-json=...` — the
  precondition check and the write are one atomic Python call;
  the closed-over `mutate` callback never crosses a subprocess
  boundary. Each JS-callable verb is a single
  read-decide-write-recompute Python invocation. **Default
  choice** — preserves I-1; minimal new code; reuses the proven
  Python ledger; same fcntl lock path.
- **(b) Sidecar daemon with JSON-RPC.** Lower per-call overhead;
  preserves I-1 via a persistent connection holding the lock for
  the full RMW. More moving parts. Deferred unless (a) shows
  latency problems in the U0 smoke tests.
- **(c) Reimplement ledger atomic-write + grammar in TypeScript.**
  ~1900 LOC re-port matching ledger_core's invariants. **REJECTED**
  — fatal scope addition; abandons the "expose existing logic
  through a stable API" framing.

U0 must include an exit-gate item: **the JS-side ledger-call
mechanism is specified AND a CONCURRENT-WRITER smoke test passes
(two JS processes each doing a read-decide-write transition,
verify no lost updates — not just a single heartbeat round-trip
which would miss the lost-update class entirely).** Until this
passes, U1's "~50 LOC of new wrappers" estimate is incomplete —
option (a) adds ~150 LOC of CLI verb handlers to `lib/ledger.py`
on top of the library wrappers, plus the precondition-encoding
grammar for every transactional verb.

**I-1 risk localization (review r4 finding 16):** I-1 risk in
this plan is FULLY LOCALIZED to the new transactional verbs in
`lib/ledger.py`; `ledger_core` / `ledger_mutators` /
`ledger_emitters` remain unchanged so their I-1 contribution is
preserved by construction. The KEEP-AS-IS verdict for those
files means the only place I-1 can break is a new verb
forgetting to wrap its read+write in a single
`_with_locked_ledger` call. U0's concurrent-writer smoke test
covers two-JS-process lost updates but does NOT cover the more
common case of a single verb implementation accidentally
splitting the lock. **U1 adds an AST-level test scenario: every
new transactional CLI verb has an AST test asserting it routes
through `_with_locked_ledger` exactly once and performs no
ledger reads or writes outside that closure.**

**Cache invalidation quadruple** (review r2 finding 9; expanded to
QUADRUPLE per review r3 finding 16 — the recipe-compiler Skill is
non-deterministic and version-dependent; if a future Claude release
fixes a compiler bug, every existing cache entry is stale-by-bug
unless the compiler version is itself part of the cache key): the
cache key is the **quadruple** of (source mtime,
Workflow-primitive-set version-hash from
`docs/contracts/workflow-primitive-set.md`'s content hash,
ledger-library API version-hash from
`docs/contracts/ledger-library-api.md`'s content hash, and
compiler-skill-version = `skills/recipe-compiler/SKILL.md` content
hash + active claude model id). Any change to any of the four
forces recompile. Compiled-file header comment records
`workflow_primitive_version`, `ledger_library_version`,
`compiler_skill_version`, and `model_id` alongside source mtime.
`lib/recipe-compile.py`'s stat-and-validate check inspects all
four. U2b tests this: flipping the primitive-set doc's content
hash invalidates every cache entry; bumping the compiler-skill
content hash also invalidates every cache entry (catches
compiler-drift case).

**Substrate binding on the ledger** (review r2, finding 16): when
`AUTO_SUBSTRATE` is set, `init_ledger` writes a
`substrate: workflow|legacy` field. Both engines refuse to act on a
ledger whose substrate doesn't match (raise `SubstrateMismatch`).
`auto-resume` reads the field to route correctly; `/auto-status`
renders it. This unblocks "two engines coexist" as a real claim,
not an aspiration.

### KTD-4: Off-script policy compiles to try/catch + structured retry; vocabulary is a closed, versioned contract

The "Off-script policy" section of a recipe declares deviation
handling in prose. The compiler emits the corresponding control flow.

**The recognized vocabulary is a CLOSED SET, version-bumped per
release** (review r1, findings 8 & 29). The v0.5.0 vocabulary:

`{ timeout-N, retry-once-augmented, retry-N-with-backoff,
halt-and-surface, halt-and-emit-reason, escalate-to-operator,
dispatch-rebound-unit, verdict-contradiction-reject,
unit-id-cross-talk-reject, emit-id-collision-rename,
non-dag-emit-reject, manual-ledger-edit-detected-resync }`

This vocabulary is derived from the rigidity-case catalog (U0's
side-quest history pull, see Problem Frame). The simple cases
(timeout, retry, halt, escalate) are the obvious surface; the
harder rigidity cases that actually cause side quests are the
verdict-contradiction, cross-talk, emit-id-collision (already
mitigated by ledger_core lines 864-885's F0 fix),
non-DAG-emit, and manual-edit ones.

**Intent → required-primitive mapping** (review r2 finding 18 —
concrete JS examples moved to a "pending U0 verification" appendix
since specifying compiled-output shapes before verifying the
primitives that produce them is premature commitment):

| Recipe prose intent | Workflow primitives required to express it |
|---|---|
| "retry once with prompt augmented" | `agent()` with retry-on-exception OR caller-side try/catch |
| "timeout N: halt and surface" | `Promise.race` OR Workflow runtime timeout |
| "spawn failure: retry after delay" | exception model for `spawn` OR `pipeline` retry |
| "iteration cap: halt; emit exit_reason" | exit-from-while OR throw-with-classification |
| "verdict contradiction: reject and re-prompt" | post-agent validation hook OR caller-side check |
| "verdict-for-wrong-unit: reject" | same as above |
| "emit-id collision: rename" | handled by `ledger_core` F0 fix path; recipe just opts in |
| "manual ledger edit detected: resnapshot" | re-init / read-after-write primitive on ledger |

Concrete JS translations live in `docs/contracts/recipe-off-script-
policy.md` and are FINALIZED only after U0 verifies which primitives
are actually available. Earlier review iterations included literal
JS one-liners here; they were correct under the assumed primitive
set but premature given finding 1.

**Application-level term verification gate** (review r3 finding
17): four of the 12 vocabulary terms map not to Workflow primitives
but to application-level patterns:
`verdict-contradiction-reject`, `unit-id-cross-talk-reject`,
`non-dag-emit-reject`, `manual-ledger-edit-detected-resync`. These
require either a Workflow hook surface that may not exist OR JS
that manually re-implements F0/I-2/I-3 checks that today live
inside `ledger_mutators.py` at the helper-call site. BEFORE U2b
begins, write the actual compiled-JS pattern for each of these
four terms in `docs/contracts/recipe-off-script-policy.md`. **If
the JS is >20 lines for any single term, RECLASSIFY that term as
"requires RawJS" and remove it from the closed vocabulary.** The
30% RawJS-share gate (U0 exit gate item 3) then becomes a real
falsifiable test rather than a self-referential one.

The mapping is documented in `docs/contracts/recipe-off-script-policy.md`
so recipe authors know which prose patterns the compiler recognizes
and what they translate to. Unknown patterns surface a compile-time
error naming the unrecognized phrase + the full recognized
vocabulary, so the recipe author can revise.

**RawJS section** (review r1 finding 8; review r2 finding 6 —
renamed from `## Escape` to remove the "rare safety valve"
connotation; for the cases that motivated this rewrite, RawJS may
be a primary surface, not an escape): a recipe can declare a
`## RawJS` section containing explicit JS the operator vouches for.
The compiler embeds it verbatim with a `// OPERATOR-VOUCHED: this
block bypasses the recognized vocabulary` header warning. The
closed vocabulary still aspires to cover common rigidity cases,
but RawJS is the legitimate authoring surface when a side-quest
shape falls outside.

**U0 vocabulary-classification exit gate** (review r2, finding 6):
For each catalogued side-quest shape from U0's history pull,
classify as:
- **(a)** Expressible in the 12-term vocabulary
- **(b)** Requires `## RawJS` raw-JS block
- **(c)** Needs new vocabulary term added BEFORE v0.5.0 ships

If >30% land in (b), reconsider the closed-vocabulary design —
perhaps an OPEN vocabulary with a typed-schema constraint instead
of a fixed enumeration. If any land in (c), bump the vocabulary
BEFORE v0.5.0 ships, not after. U0 produces this classification
table as a deliverable.

This is the **central response to the rigidity pain**. Today's engine
has one off-script policy (the closed state machine); v0.5.0 lets
every recipe declare its own from the closed vocabulary, with the
RawJS section for the genuinely novel cases.

**Honest framing note — iteration-gate recipes (review r4 finding
6):** for the highest-value recipes (a2 / a4 iteration), the
off-script policy section translates to FIXED PARAMETER SLOTS on
the transactional `iterate_step` verb, NOT to bespoke
compiler-emitted control flow. `atomic_iterate_step` takes an
emitter callable selected from `recipe.iteration.emit_template`
(tick_advance.py:458-466); `iteration.evaluate_decision` (lib/
iteration.py imported at tick_advance.py:419) implements the
advance/iterate/exit branching with kill-switch handling. A
compiled JS workflow cannot pass Python callables across the
bridge, and the decide+emit+reset MUST stay atomic. So the JS
side can only forward `(bound, gate_unit, emit_template_name)`
to the Python verb — semantically what the JSON recipe encodes
today. The recipe author's prose "iteration cap reached without
exit: halt; emit `exit_reason: iteration-bound-breached`"
translates to a verb-parameter selection, NOT to compiler-emitted
try/catch. The mechanism still works for these recipes; it just
delivers far less of the marketed expressiveness on the recipes
that motivated outcomes-gated work in the first place.

**Vocabulary classification (added to U0's exit gate per finding
6):** each iteration-related vocabulary phrase MUST be classified
as "compiler-emitted JS" vs "verb-parameter" so the reader can
see what fraction of the expressive surface is genuinely new.
The "recipe author declares deviations" claim holds for
timeout/retry/halt cases that map cleanly to JS try/catch — but
NOT for the iteration decision tree.

**Off-script fixture harness — fourth safety net** (review r2,
finding 5; review r3 finding 11 — previously DEFERRED to v0.5.1;
REVERSED per review r4 finding 4 — semantic off-script
verification is now a v0.5.0 SHIPPING gate, not a v0.5.1
deferral, because the central new capability cannot ship
unverified in the release that ships it. v0.5.0 includes ≥1
canary with a real off-script policy + adversarial fixture
generated by an independent skill per review r3 finding 12's
preferred path; the harness ships alongside U2b. Alternative
(b) — defer ALL of v0.5.0 until the revisit conditions are met —
is the path Plan of Record above takes; this appendix assumes
the substrate path is live.):
U2b's structural validator, KTD-2's per-recompile sanity fixture,
and U3's parity tests all FAIL to verify the new off-script
handling — the structural check doesn't verify branch semantics,
the sanity fixture is happy-path, and U3 parities against a
legacy engine that has no off-script handling so there's no
baseline. To close this gap, EVERY recipe migrated in v0.5.1
(a1/a2/a4) declares a **`## Off-script Fixtures`** section
listing, for each off-script vocabulary phrase the recipe uses:

| Column | Content |
|---|---|
| `phrase` | The off-script vocabulary phrase invoked (e.g., "on timeout retry once with augmented prompt") |
| `injection` | The injected failure (mock agent timeout, mock schema-violation, mock spawn fail, mock ledger mutation, etc.) |
| `expected_end_state` | Ledger end-state after the handler fires |
| `expected_retry_count` | Number of retries before the handler resolves |

**v0.5.0 (REVERSED per review r4 finding 4):** ## Off-script
Fixtures is MANDATORY for the v0.5.0 canary set, which now
includes ≥1 recipe exercising a real off-script policy (e.g. "on
timeout retry once"). The fixture harness ships with v0.5.0
alongside U2b. **v0.5.1:** mandatory continues alongside a1/a2/a4
migration. Off-script semantic checks live in U2b (where
injection is controllable), NOT in U3 parity (where they have no
baseline). Shipping the substrate-rewrite apparatus without
in-release semantic verification of its central new capability is
the antipattern review r4 finding 4 calls out ("unverified
rewrites accumulate trust by momentum"); the v0.5.0 gate is
where that pattern gets broken.

**Epistemic limit of author-written fixtures** (review r3 finding
12): fixture entries are AUTHOR-WRITTEN per recipe; the author's
mental model of what off-script shapes occur in production is the
exact thing finding 4's empirical verdict shows is unvalidated. The
cycle is "author imagines a shape → author writes a fixture for it
→ compiler emits JS for the prose → fixture passes." This loop
NEVER touches a real production off-script incident. The plan's
claim for KTD-4 is therefore lowered: KTD-4 verifies "recipe
author can express intent in the closed vocabulary," NOT "the
compiled workflow handles off-script cases as expressed in
production." For the stronger claim, one of:
- **Adversarial fixture generation:** every off-script vocabulary
  phrase gets a fixture generated by an INDEPENDENT process (a
  separate skill that reads the prose and constructs a falsifying
  input from scratch WITHOUT seeing the compiler's output), then
  run against the compiled artifact. — preferred, but deferred
  until U0's evidence pull surfaces real shapes to model.
- **Wait on real production data:** defer the off-script capability
  CLAIM entirely until U0's evidence pull (finding 4) produces ≥3
  real shapes with verifiable expected behaviors. — the
  empirically-honest path given the 2-ledger footprint.

v0.5.0 makes the syntactic claim only. v0.5.1's stronger
semantic claim is contingent on one of the two paths above.

### KTD-5: Migration is staged (per Cutover sequencing section)

The four legacy recipes (a1, a2, a4, w) migrate from JSON to
markdown across three releases per the Cutover sequencing section:

- **v0.5.0:** `w` (smallest stub canary) + an a2-shape minimal
  iteration fixture (review r2 finding 7 — `w` alone has no
  iteration block and exercises essentially none of the
  deletion-risk surface; the iteration canary closes that gap).
  Both engines coexist behind `AUTO_SUBSTRATE=workflow|legacy`
  (default `legacy`).
- **v0.5.1:** a1, a2, a4 migrate. Flag default flips to `workflow`
  after the gate criterion below is met. Legacy engine still
  survives.
- **v0.5.2:** Legacy engine deletes OR workflow substrate
  rolls back. Gated on time-box per Cutover sequencing (review r3
  finding 5): `AUTO_SUBSTRATE=workflow` default for **60 days**;
  at boundary, EITHER cutover (zero compiler-mistranslation side
  quests AND ≥1 off-script handler fired) OR honest rollback
  (delete the workflow substrate, re-bless legacy). Permanent
  dual-engine maintenance is NOT permitted past the 60-day box.

Side-by-side verification (per recipe):

1. Run the legacy recipe on a fixture plan via today's engine.
   Snapshot ledger state + verdicts + exit predicate.
2. Compile the markdown version. Run via Workflow on the same
   fixture.
3. Compare outputs against the **closed set of allowed divergences**
   (review r1, finding 24):
   - Timestamps (legacy + workflow runs at different wall times)
   - Run-ids (each run gets a fresh id)
   - New fields added by the workflow substrate (explicitly: any
     `workflow_run_id`, `workflow_resume_cursor` — enumerate
     exhaustively in U3)
   - Ordering of independent parallel emit results (when both
     engines parallelize, completion order isn't guaranteed)
   Any divergence OUTSIDE this enumerated set is a P0 parity
   failure. "Explainable" alone is NOT sufficient — the
   divergence must match an enumerated category.
4. Recipe passes when behavior matches over the fixture set.

Once each release's migrated set passes, engine deletion (U5)
becomes eligible for v0.5.2 per the quantitative gate above.

A2 and A4 (the iteration-gate recipes) stress the compiler's
handling of the iteration block + emit templates — the highest-risk
compiles, deferred to v0.5.1 with v0.5.0 carrying only the minimal
a2-shape fixture for substrate-coverage purposes.

### KTD-6: Loop-driver skill shrinks to ≤40 lines (review r4 finding 19 — single contract; ~30 aspirational target removed to eliminate drift between "target" and "hard gate")

Today's `skills/auto/SKILL.md` is 120 lines: tick-chain arming, work-
loop fan-out policy, exit reporting, batch-aware Stop hook. With
Workflow as the substrate, the loop driver becomes:

```
1. Resolve the recipe name → recipes/<name>.md
2. Compile if needed → .claude/workflows/<name>.compiled.js
3. Invoke Workflow({scriptPath: <path>, args: {plan_path, run_id, ...}})
4. Surface the result; on completion, emit the minors report from the
   ledger (unchanged from v0.4.0)
```

The driver doesn't arm ticks, doesn't dispatch units, doesn't poll
for verdicts. Workflow does all of that. The skill's body shrinks
to **≤40 lines** (frontmatter + four-step contract + citation to
`docs/contracts/driver-reference.md` for the legacy theory, which
becomes a historical document). Per review r4 finding 19 the
prior "~30 lines" target was removed — the gate is what is
testable; the target was aesthetic and created drift.

**Honest framing (review r4 finding 10; review r5 finding 19):** the loop driver
SKILL.md shrinks to ≤40 lines of prose; operational complexity
does NOT disappear, it RELOCATES into (a) auto-driver's expanded
responsibilities (model-side warm-compile invocation), (b) the
recipe-compiler Skill (non-deterministic compile step with
rate-limit + validation-failure + race failure modes), (c) the
Workflow runtime's resume/retry semantics. The line-count gate
measures only file size, not net system complexity. **Parallel
gate:** total LOC across {commands/auto.md body, skills/auto-
driver/SKILL.md, lib/auto-spawn.py, skills/recipe-compiler/
SKILL.md} MUST be tracked and reported in U4's PR description
alongside the ≤40-line gate. KTD-6's "deterministic
simplification" framing is wrong as stated — the change is
deterministic-Python LOC out, non-deterministic-Skill LOC in.
The trade may still be worthwhile, but it should be evaluated on
its actual shape.

`docs/contracts/driver-reference.md` gets a v0.5.0 addendum noting
which sections are historical (prepare/execute essay, livelock
guards) vs current (goal binding, batch fanout via cmux).

### KTD-7: Workflow heartbeat contract preserves the Stop hook's deliberate-stop guarantee

Today the Stop hook (`on-stop.py`) holds a session open by reading
`met == false AND loop_phase != done AND driver == 'self' AND
last_beat_at fresh` (on-stop.py:107-118). The "last_beat_at fresh"
check distinguishes a live tick chain from a dead one (Bug #9
carve-out). These fields are written by tick.py's heartbeat loop;
deleting tick.py without a replacement would either over-block
(Stop never sees driver flip to manual) or under-block (driver is
'self' but stale, stop happens mid-Workflow). Review r1, findings 3
and 22.

**Contract** (mandatory for the workflow substrate):

- The compiled workflow MUST call `ledger.heartbeat(repo, run_id)`
  at least every 60s. This writes `loop.last_beat_at = now`,
  `loop.driver = 'self'`.
- The compiler emits heartbeat calls at intervals the Workflow
  runtime permits; **exact emission shape finalized after U0**
  (review r2 finding 18). The default expectation is "inside every
  while-loop body and around any long `agent()` call," but the
  precise mechanism is one of the two cadence-enforcement options
  below.
- The library API gains `heartbeat()` as a 6th helper.
- On workflow completion or hard halt, the workflow writes
  `loop.driver = 'manual'` to release the Stop block.

**Cadence enforcement** (review r2 finding 21 — presence checks
alone don't verify 60s cadence). Pick ONE of:
- **(a) Compiler wraps long agent() calls.** Any `agent()` call
  whose declared budget exceeds 60s gets emitted as
  `await heartbeatingAgent(...)`, a wrapper that pings
  `heartbeat()` every 60s while the agent runs. U2b's validator
  enforces this structurally — `bare await agent(...)` calls with
  declared budgets >60s are rejected at compile time. **Default
  choice** — pure compile-time enforcement; no runtime contract
  changes.
- **(b) Runtime hook in Workflow itself.** If Workflow exposes a
  runtime hook to fire `ledger.heartbeat()` at fixed intervals
  (U0 spike answers this), use it; emitted code only needs to
  ensure the hook is wired at workflow start.

Add a parity test (`parity-heartbeat-cadence` in U3) that asserts
`last_beat_at` advances at least every 90s during a 300s mid-run
pause.

**Resume / phase-advance integration** (review r1 finding 3;
resolved per review r2 finding 15; review r3 finding 6 — split
cleanliness entry gate added; review r4 finding 15 — file path
corrected): `lib/auto-resume.py` today calls
`tick.advance_to_phase(...)` via re-export — but the DEFINITION
lives in `lib/tick_advance.py:529`, not `tick.py`. **Resolved:
split `advance_to_phase` out of `lib/tick_advance.py` into
`lib/phase_advance.py`** (small surviving module).
**Closure verified clean (review r4 finding 15):** the function
at tick_advance.py:529-575 calls only
`phase_grammar.emitter_name_for_arrival`, `emitters.resolve`,
`ledger.set_loop`, `ledger.transition_and_emit`, and
`ledger.LedgerError` — no `tick_guidance` helpers, no
`tick_advance` internals beyond the function itself. The U4.5
escalation condition (closure pulls in `tick_guidance`) is NOT
triggered; the split is genuinely ~47 lines. The `auto-resume.py`
import edit is `import phase_advance` + call-site rewrite,
because `auto-resume.py` today does `import tick` (tick.py
re-exposes advance_to_phase). `lib/emitters.py` is KEEP (load-bearing for both
auto-resume and the compiled JS workflow's auto-flip path). The
single-chokepoint contract is preserved by routing both the JS
auto-flip and Python auto-resume through
`phase_advance.advance_to_phase`, which is the only function that
resolves an emitter for a `{to_phase}` arrival. The seam→work
emitter MUST fire exactly once per resume. The earlier
"OR auto-resume calls the emitter directly" alternative is
rejected: it scatters phase-advancement logic across two files,
breaking the single-chokepoint contract documented in
`tick_advance.py:533`.

**U4 entry gate — split-dependency enumeration** (review r3
finding 6): `tick_advance.advance_to_phase` (lib/tick_advance.py:529)
calls into helpers that live inside `tick_advance.py` itself
(`set_loop DIRECTLY` at 386, `judge_winner_to_work_units` at 474,
recursive `advance_to_phase` call at 609). Before U4 begins, a
read-only walk of `advance_to_phase` MUST enumerate every symbol
it calls and classify each as (a) stays in tick_advance.py — to be
deleted in U5, (b) moves with the split to phase_advance.py, (c)
pulls in `tick_guidance.py` helpers and therefore expands the
split's blast radius. Emit a net-LOC estimate for the new
`phase_advance.py` file. **If the dependency closure exceeds 150
LOC OR pulls in `tick_guidance.py` helpers, escalate to a
separate U4.5 "tick_advance refactor for split" that lands
BEFORE the engine deletion in U5.** Without this enumeration,
the "small surviving module" claim is unverified and U5's
atomic-deletion-commit framing is wrong (the deletion bucket
either still references tick_advance internals or quietly
absorbs a larger refactor).

**Test scenario** (added to U3): a Workflow that hangs in
`agent()` for 70s and is then killed — the Stop hook on the next
session should classify the run as stale-chain (driver='self',
last_beat_at > 3900s) and decline to block, matching the legacy
engine's Bug #9 behavior.

## Implementation Units

### U0. Preflight spike — verify Workflow primitive surface + pull side-quest evidence base

> **STRUCTURAL NOTE (review r2 findings 4 & 22; review r3 finding
> 10 — the contradiction between this note and U1-U5's depth is
> acknowledged but NOT resolved by collapsing U1-U5 to stubs, per
> the task's structure-preservation instruction; instead U1-U5
> retain their detail with explicit "subject to U0 verification"
> caveats and the preamble's no-re-debate fence has been loosened
> so the depth can be revisited once U0 returns):** U0 should NOT
> live inside this plan as one of five sequenced units. The reason:
> a 5-unit, fully-specified plan with file-list precision creates
> approval momentum that works against U0's kill-gate being honestly
> exercised. Once a reviewer has approved a plan with this much
> downstream detail, "no, U0 failed, throw it out" becomes the
> harder conversation. **Action: split U0 off as a standalone
> preflight RFC at
> `docs/plans/2026-05-29-003-spike-workflow-primitive-surface.md`.
> U1-U5's file-list-precision content below is DRAFT pending U0;
> the intent→primitive mapping (KTD-4), heartbeat cadence enforcement
> (KTD-7), structural validator rule set (U2b), and JS-side ledger
> client mechanism (KTD-3) are explicitly labeled as binding only
> after U0 verifies the primitives that produce them — see HARD
> ASSERTION at the top of this plan.** The U0 description below is
> preserved here as the contract the standalone RFC must satisfy,
> and includes the first deliverable: a ToolSearch dump confirming
> Workflow's tool schema (or its absence).

**Workflow tool presence: UNCONFIRMED at planning time.** ToolSearch
`select:Workflow` returned no match in the harness used to author
and review this plan; broader keyword searches surfaced only
TeamCreate, Monitor, CronCreate, SendMessage. U0 must produce
PRIMARY EVIDENCE (tool schema dump from a live ToolSearch result,
included in `docs/contracts/workflow-primitive-set.md`) before U1
begins.

**Goal:** Confirm the Workflow tool exists in the targeted Claude
Code release and exposes the primitive surface the rest of the plan
depends on. AND: enumerate the actual off-script incident history
from production runs to validate the rigidity diagnosis (review r1,
findings 1, 5, 14).

**Files:**
- `docs/contracts/workflow-primitive-set.md` (new) — captures the
  actual Workflow tool surface available: (a) tool name and input
  schema, (b) the list of in-script primitives (`pipeline`,
  `parallel`, `agent`+schema/isolation/model, `while`+`budget`,
  `workflow(name, args)` composition), (c) what
  resume-from-cache-by-run-id actually does and whether it survives
  process death the way the ledger does, (d) which JS runtime hosts
  the compiled script, (e) source citation (changelog entry,
  internal doc, or the tool schema from a `ToolSearch` query)
- `skills/recipe-compiler/references/workflow-primitives.md` (new
  in U2; STUBBED here so the compiler skill's reference set is
  scoped to verified primitives, not assumed ones)
- `docs/contracts/auto-side-quest-history.md` (new) — enumerated
  off-script incidents from `<repo_root>/.claude/auto/<run-id>.json`
  ledgers (path per `lib/ledger_core.py:252-258`; review r3 finding 4
  — earlier `~/.local/state/auto/` reference was wrong AND the live
  footprint at planning time is 2 ledgers system-wide so this
  deliverable cannot satisfy the kill criterion; see Problem Frame
  empirical verdict): for each,
  (a) frequency, (b) whether a minimal escape-state addition to the
  existing engine would have caught it, (c) whether plain-language
  recipe prose would have prevented it, (d) **in-process observable
  from inside a single Workflow invocation (try/catch can catch it)
  vs. cross-process (only a fresh session or operator inspection
  surfaces it)** — review r2 finding 12. The plan's compile-to-
  try/catch fix only works for (d) = in-process. If most catalogued
  side quests are cross-process, try/catch in compiled JS is the
  wrong mechanism — re-scope to v0.4.x escape-hatch (better
  cross-session observability via Stop hook + ledger) is the
  cheaper fix.
- **Vocabulary-classification table** (per KTD-4 / review r2
  finding 6): for each catalogued shape, classify as (a) expressible
  in the 12-term vocabulary, (b) requires `## RawJS`, (c) needs new
  vocabulary term before v0.5.0 ships.
- **JS-side ledger client smoke** (per KTD-3 cross-runtime section /
  review r2 finding 2): smoke-test one round-trip — heartbeat write
  from JS, observed by Python `read` on the same ledger file, with
  fcntl lock acquired correctly across runtimes.
- `tests/spike/workflow-primitives-smoke.test.sh` (new) — runnable
  minimal examples invoking each of the five named primitives;
  measured behavior on resume-from-cache and rate-limit interaction.

**Dependencies:** none

**Approach:** Run minimal smoke examples against each primitive in
the live Claude Code session. Document every gap between assumed
and actual surface. For each missing or differently-shaped
primitive, state how the compiler synthesizes it (or, if it can't,
what that means for the migration — e.g. "no `while`+budget" forces
iteration loops into the compiled JS at module level, changing how
KTD-4's iteration-cap and KTD-3's I-1 invariant compose).

Parallel track: walk `<repo_root>/.claude/auto/<run-id>.json` ledgers
across all projects (path per `lib/ledger_core.py:252-258`) from the
last N runs; categorize off-script incidents. **Note (review r3
finding 4):** at planning time only 2 production ledgers exist
system-wide, so this walk cannot satisfy the (3) exit gate from the
deliverable side; if the count holds the plan re-scopes per Problem
Frame's empirical verdict.

**Exit gate (BLOCKING for U1-U5):**

1. Workflow primitive surface document exists AND every primitive
   the plan relies on either (a) exists with the assumed shape, or
   (b) has a documented compiler-synthesized workaround. **The
   document includes a primary-evidence ToolSearch dump showing
   Workflow's tool schema; the absence-from-inventory observation
   noted at planning time is either confirmed-resolved or
   re-classified as a permanent gap.**
1a. **Parity-injection mechanism specifications** (review r3
   finding 3 — moved here from U3 so the parity tests have
   specified injection mechanisms BEFORE U3 begins, not asserted
   as scenarios). Produce `docs/contracts/parity-injection.md`
   defining the injection mechanism for each `parity-*` test
   (rate-limit, resume-seam, stop-block, heartbeat-stale). If
   any cannot be specified, the corresponding `parity-*` test is
   downgraded from a test to a CLAIM and dropped from the v0.5.2
   gate criteria (the time-box gate adjusts accordingly).
1b. **Test-triage table** (review r3 finding 7 — moved from "inside
   U5's PR description" to a U0 deliverable so substrate-design
   feedback lands BEFORE U1 spec work commits to assumptions).
   Enumerate every named `tests/unit/tick*.test.sh`,
   `tests/unit/orchestrator.test.sh`, `tests/unit/iteration*.test.sh`
   into one of three categories: (a) parity-coverable (end-state
   ledger comparison or process-property scenario in U3), (b)
   requires compiled-JS direct test (port the observable to a
   substrate-agnostic test against the compiled JS), (c) requires
   a substrate primitive that the verified Workflow surface does
   NOT offer. **Category (c) findings are P0 design feedback that
   MUST resolve BEFORE U1 starts spec work, not at U5.**
   Specifically classify: double-drive-guard (requires fcntl flock
   at the orchestration layer, not just the ledger),
   phantom-dispatch-reaper (requires periodic reconciliation
   independent of agent completion), gaps_open_guard (requires
   predicate recompute interleaved with verdict landing). If any
   land in (c), the substrate design must accommodate or the plan
   re-scopes BEFORE U1 begins.
2. Side-quest history shows **≥3 distinct off-script shapes that
   plain-language recipe prose would have prevented AND ≥2 of those
   shapes must be in-process observable (try/catch in compiled JS
   can catch them)** — review r2 finding 12. If <3 distinct or <2
   in-process, **re-scope to a v0.4.x escape-hatch increment**
   instead of substrate replacement (the cheaper fix is better
   cross-session observability via the existing Stop hook +
   ledger).
3. **Vocabulary classification** (review r2 finding 6): if >30% of
   catalogued shapes land in `## RawJS`, reconsider the
   closed-vocabulary design (open vocabulary with typed-schema
   constraint may be better). If any land in "needs new vocabulary
   term before v0.5.0," bump the vocabulary BEFORE v0.5.0 ships.
4. **JS-side ledger client mechanism is specified and one round-trip
   is smoke-tested** (review r2 finding 2): heartbeat write from JS,
   observed by Python read on the same ledger file, with fcntl
   lock acquired correctly across runtimes.
5. If U0 fails on (1): plan status flips to
   `blocked_on_workflow_tool_availability` — DO NOT proceed to U1.

**Test scenarios:**
- Smoke test invokes `pipeline(parallel(agent(...), agent(...)))` end-to-end
- Smoke test invokes `while ({ budget: 10 }, async () => { ... })`
- Smoke test invokes `workflow('child', args)` composition
- Smoke test kills the host process mid-Workflow and verifies
  resume-from-cache picks up where it left off
- **JS-side ledger client round-trip:** heartbeat write from JS
  (via the chosen mechanism — default option (a) subprocess to
  `python lib/ledger.py heartbeat ...`), Python read observes the
  update on the same ledger file with fcntl lock honored
- Side-quest history enumeration has ≥3 distinct shapes AND ≥2 are
  in-process observable (or plan re-scopes)
- Vocabulary classification: ≤30% of shapes land in `## RawJS`
  (or design reconsidered); none land in "needs new vocabulary"
  unmet

### U1. Ledger library API on top of existing four-file split

**Goal:** Add a thin import-library API on top of the existing
ledger split (lib/ledger.py 160 LOC facade + ledger_core.py 1032 +
ledger_mutators.py 564 + ledger_emitters.py 294 = ~2050 LOC). The
existing files KEEP their shape; v0.5.0 only ADDS the public API
surface compiled workflows use. Library API: 6 helpers
(`init_ledger`, `record_verdict`, `set_gaps_open`,
`record_iteration_step`, `recompute_predicate`, `heartbeat` — the
last per KTD-7). **Net added LOC: ~50 (library wrappers) + ~150
(CLI bridge verbs per KTD-3 option (a)) = ~200 LOC total** (per
review r4 finding 14 — propagated from KTD-3's honest figure;
conditional on bridge mechanism choice in U0). Preserve I-1 + I-2
+ Bug-#9 freshness semantics.

**Files:**
- `lib/ledger/__init__.py` (new, ~50 LOC) — the six-helper API,
  delegating to existing modules
- `lib/ledger.py` (extend `_cli` with ~150 LOC of TRANSACTIONAL
  CLI verbs IF JS bridge option (a) wins per KTD-3; conditional
  on U0 — review r3 finding 19; if option (b) sidecar daemon wins,
  this LOC moves to a new file, not into `ledger.py`)
- `lib/ledger.py` (modify) — re-exports the new public API alongside
  today's facade surface (zero deletions)
- `lib/ledger_core.py` — KEEP-AS-IS (load-bearing: recompute_predicate,
  B7 helpers, _atomic_write, I-1 chokepoint, scale-aware gating)
- `lib/ledger_mutators.py` — KEEP-AS-IS (I-2 grammar enforcement)
- `lib/ledger_emitters.py` — KEEP-AS-IS (phase-transition emitters
  including the seam→work emitter that /auto-resume depends on)
- `lib/iteration.py` → RELOCATE to `lib/ledger/iteration.py`
  (load-bearing: lazy-loaded by ledger_core line 606 for the I-1
  recompute path; survives engine deletion). Update the lazy-load
  import path in `ledger_core.py`. See finding 23.
- `lib/phase-grammar.py` → DECIDE: relocate to
  `lib/ledger/phase_grammar.py` OR inline into `ledger_core.py`.
  Either way, the lazy-load at ledger_core line 625 must continue
  to resolve after engine deletion.
- `docs/contracts/ledger-library-api.md` (new) — the six-helper API
  signatures + the I-2 grammar constraints + the heartbeat contract
- `docs/contracts/ledger-schema.md` (modify) — cross-reference the
  new library API doc
- `tests/unit/ledger-library-api.test.sh` (new) — exercise each of
  the 6 helpers; verify I-1 + I-2 invariants intact
- All existing `tests/unit/ledger*.test.sh` — must stay green with
  zero modification (the facade re-exports preserve today's surface)

**Dependencies:** U0 (the library API surface must match what U0's
verified Workflow primitive set can actually call)

**Approach:** ADD an API, don't refactor the substance. The five
write helpers + heartbeat are composed wrappers around primitives
that exist today. `record_iteration_step` specifically wraps
today's `atomic_iterate_step` + `set_loop` + emit_within_phase
(currently composed by tick.py — moving this composition into the
library is what lets tick.py delete cleanly). `heartbeat` writes
`loop.last_beat_at = now` and `loop.driver = 'self'` (KTD-7).

**Test scenarios:**
- All existing ledger tests pass with zero modification (no
  regression in `lib/ledger.py` facade behavior)
- `init_ledger` writes the canonical run shape; predicate recompute
  fires
- `record_verdict` updates the unit; predicate recompute fires;
  blockers/majors counters update correctly
- `set_gaps_open` flips the plan-loop exit gate
- `record_iteration_step` atomically increments
  `iteration_attempts`, resets the gate unit, emits N sibling units,
  preserves emit-id-collision F0 fix from ledger_core lines 864-885
- `heartbeat` writes loop.last_beat_at and loop.driver; on-stop.py's
  freshness check observes the update
- All 6 helpers preserve atomic-write semantics under concurrent
  invocation (fcntl probe)
- **AST-level lock-discipline test (review r4 finding 16):** every
  new transactional CLI verb in `lib/ledger.py` has an AST test
  asserting it routes through `_with_locked_ledger` exactly once
  and performs no ledger reads or writes outside that closure
  (catches the single-verb-splits-the-lock failure mode that the
  two-process concurrent-writer smoke test cannot see)
- The state-transition grammar (I-2) rejects invalid transitions
  with `InvalidTransition` rather than silently corrupting state
- After relocating `lib/iteration.py` → `lib/ledger/iteration.py`,
  the lazy-load at `ledger_core._compute_iteration_pending` still
  resolves; recompute_predicate doesn't raise ImportError
- After deciding `phase-grammar.py` relocation/inline, the lazy
  load at `ledger_core` line 625 still resolves

### U2a. Recipe markdown format spec + reference docs

> **Compression note (review r4 finding 18):** the U2a/U2b detail
> below is preserved verbatim for the audit trail, but the
> compiler design commits ramify into KTD-4's vocabulary, KTD-7's
> cadence, U3's parity, and U5a's test-porting triage —
> specifying downstream against an unverified upstream costs
> review effort proportionate to the whole stack. **Intent
> compression:** a future migration RFC may shrink U2a+U2b in the
> top-level document to "compiler skill that reads recipe markdown
> + verified primitive surface from U0 and emits workflow JS;
> per-recompile sanity fixture; structural validator;
> non-determinism mitigated by validator + fixture gate." The
> detailed file lists, validator check categories, and
> adversarial verifier remain available below as the contract
> the future RFC must satisfy when U0's outcome resolves.


**Goal:** Define the recipe-markdown format (frontmatter + six
sections + MANDATORY `## Sanity Fixture` for v0.5.0;
`## Off-script Fixtures` defined here, enforcement mandatory in
v0.5.1 per Cutover sequencing + review r3 findings 11+13; optional
`## RawJS`). Produce the reference docs the compiler skill (U2b)
must compose from. (Reconciliation note: review r3 finding 13
required these spec corrections, and finding 11 deferred the
Off-script Fixtures harness to v0.5.1 — both satisfied by
DEFINING the section in the spec now while gating enforcement to
v0.5.1.)

**Files:**
- `docs/contracts/recipe-format-v2.md` (new) — the markdown format
  spec (replaces the JSON format in `recipe-format.md`, which
  becomes legacy)
- `docs/contracts/recipe-off-script-policy.md` (new) — the closed
  vocabulary from KTD-4 + prose-pattern → compiled-JS translations
- `skills/recipe-compiler/references/workflow-primitives.md`
  (modify — initially stubbed in U0; finalized here) — the Workflow
  API surface the compiler must use correctly
- `skills/recipe-compiler/references/ledger-library-api.md` (new) —
  the 6 helper signatures (including `heartbeat`) + the I-2 grammar
  constraints
- `skills/recipe-compiler/references/adapter-contract.md` (new) —
  the existing adapter contract, restated for the compiler

**Dependencies:** U0 (the workflow-primitives reference must reflect
the verified surface), U1 (the ledger-library-api reference targets
U1's actual API)

**Approach:** The compiler's safety isn't in the system prompt — it
lives in (a) the precision of the reference docs and (b) the
post-compile validator (U2b). U2a invests in tight references.

### U2b. Recipe-compiler skill + entry point + output validator

**Goal:** Build the `recipe-compiler` skill that reads a recipe +
the U2a references and emits a workflow script. Add the entry-point
helper and the **post-compile validator** that rejects emitted JS
violating any contract.

**Files:**
- `skills/recipe-compiler/SKILL.md` (new) — the compiler skill body
  (tight system prompt composing only from references)
- `lib/recipe-compile.py` (new) — a STAT-AND-VALIDATE helper, NOT
  a synchronous compiler entry point (see KTD-2; the compile is
  Skill-invoked from `commands/auto.md` / `auto-driver`). This file
  stats source vs cache, validates the cached artifact's signature,
  and reports "fresh" / "stale" / "needs compile" to the model.
- `lib/recipe-compile-validate.py` (new) — the **post-compile
  validator**. Rejects emitted JS that (a) imports anything outside
  the ledger-library API, (b) calls Workflow primitives not in the
  references, (c) calls grammar-checked ledger mutators with
  unit/phase identifiers NOT declared in the recipe frontmatter or
  sections (review r2 finding 17 — static I-2 enforcement requires
  symbolic execution or fixture coverage; this is the syntactic
  defense-in-depth surface. Runtime I-2 violations are caught at
  the helper-call site by `ledger_mutators` as they are today; the
  validator is belt-and-suspenders, not the enforcer), (d) emits
  `bare await agent(...)` calls with declared budgets >60s
  instead of `await heartbeatingAgent(...)` — review r2 finding 21,
  default cadence enforcement option (a), (e) **fails any
  `## Off-script Fixtures` entry** when the fixtures are replayed
  against the freshly-compiled artifact (review r2 finding 5 —
  the off-script semantic check; review r3 finding 11 — both
  this harness and the differential check below DEFER to v0.5.1
  alongside a1/a2/a4 migration; v0.5.0 ships the structural
  validator and sanity fixture only), (f) **fifth check —
  ADVERSARIAL-DIRECTION verification (DEFERRED to v0.5.1 per
  review r3 finding 11; reframed from "differential prompting" per
  review r3 finding 18 — Claude grading Claude with the same
  prompt is operationally weak; the reframed check is adversarial,
  reverse-direction)** (review r2 finding 20): after compile, an
  INDEPENDENT verifier (separate Skill, NOT the compiler) is given
  ONLY the compiled JS and is asked to extract the prose intent
  from it (reverse direction). The extracted intent is then
  diffed against the markdown source. Mismatches flag wire-to-
  wrong-branch bugs. The verifier shares no prompt structure with
  the compiler; if both share the same systematic blindspot under
  the same model, the check is acknowledged to provide no signal —
  so this check is treated as defense-in-depth, NOT as the primary
  semantic-correctness gate. The off-script fixture harness (KTD-4)
  remains the actual falsifiability surface. On any failure the
  new artifact is rejected and the old one stays.
- `lib/recipes.py`, `lib/recipes-list.sh` (modify in U2b per
  review r3 finding 15 — earlier the modify was attributed to
  U3 in U3's Files list but not listed under U2b's, causing a
  three-story discrepancy) — load both `.md` and `.json`;
  resolution order per `AUTO_SUBSTRATE` env (KTD-3
  substrate-binding section). U5 later strips the JSON-load
  branches; U2b adds dual-format support so U3's parity tests
  can resolve both at all.
- `tests/unit/recipe-compile.test.sh` (new) — stubbed compiler tests:
  given a known markdown input, the compiled output contains the
  expected structural elements
- `tests/unit/recipe-compile-validate.test.sh` (new) — fuzz the
  validator with deliberately-broken compiled JS samples; assert
  each violation category is caught

**Dependencies:** U0, U1, U2a

**Approach:** The compiler is a Claude Skill, not a deterministic
parser. It runs once per recipe edit; the cost is amortized.
**Per-recompile sanity gate** (KTD-2): every recompile validates
against the recipe's `## Sanity Fixture` section before replacing
the old artifact. If sanity fails, the recompile is rejected.

**Determinism stance** (review r1, finding 12): the compiler is
non-deterministic by nature (Claude Skill). Plan does NOT claim
byte-identical recompiles. Drift is caught by (a) the validator,
(b) the sanity-fixture gate per recompile, (c) U3's parity tests at
migration time.

**Test scenarios:**
- A trivial recipe (one unit, no iteration, no off-script policy)
  compiles to a workflow script with the expected structure
- The six sections from a fully-specified recipe each map to the
  expected output element (Intent → script docstring; Shape →
  pipeline/parallel structure; Iteration → while loop with bound;
  Exit → predicate check; Off-script → try/catch; Adapter → agent
  options)
- The compiled output includes `heartbeat()` calls inside every
  while-loop body (KTD-7 contract; validator enforces)
- An unknown off-script-policy phrase ("if it gets weird, do
  something") produces a compile-time error naming the unrecognized
  phrase and listing the full closed vocabulary from KTD-4
- The validator rejects compiled JS that imports outside the ledger
  library API
- The validator rejects compiled JS that calls a primitive not in
  the U2a references
- The validator rejects compiled JS that violates I-2 (e.g.,
  records a verdict on a non-dispatched unit)
- A recipe with a `## Sanity Fixture` section: a recompile that
  fails the fixture is rejected; the old artifact stays in place
- The Skill invocation flow works end-to-end from
  `commands/auto.md` body (verified by the U4 integration tests)

### U3. Migrate canary recipe(s) to markdown + side-by-side verify

**Goal:** Re-author the v0.5.0 canary recipes (`w` + the a2-shape
minimal iteration fixture) as markdown. Verify each behaves
identically to its JSON predecessor on a fixture plan **across both
end-state ledger AND load-bearing process properties** (review r1,
finding 7).

**Files:**
- `recipes/w.md` (new) — re-authored from `recipes/w.json`
- `recipes/a2-fixture.md` (new) — minimal a2-shape iteration
  fixture closing the deletion-risk surface gap (review r2
  finding 7); NOT a full a2 migration (deferred to v0.5.1).
- `recipes/*.json` — **KEPT until v0.5.2** (U5 owns the atomic
  deletion per finding 33; U3 only adds `.md` versions and runs
  parity)
- `lib/recipes.py`, `lib/recipes-list.sh` — coexistence loader
  added in U2b (review r3 finding 15 — moved to U2b's Files list
  so the modification has ONE clear owner); further stripped in
  U5. Loads both JSON and markdown during the transition
  window. Resolution rule for coexistence (review r2 finding 16
  — substrate binding on the ledger): introduce
  `AUTO_SUBSTRATE=workflow|legacy` env (defaults `legacy` for
  safety). When `workflow`, prefer `<name>.md`; when `legacy`,
  prefer `<name>.json`. Parity tests exercise both paths
  side-by-side with the env explicitly set. `init_ledger` writes a
  `substrate: workflow|legacy` field; engines refuse to act on a
  ledger whose substrate doesn't match (raise `SubstrateMismatch`).
- `tests/integration/recipe-parity.test.sh` (new) — for each
  migrated recipe, run the legacy engine + the workflow substrate on
  the same fixture plan; assert ledger end-state AND process
  properties match within the closed divergence set (KTD-5)
- `tests/integration/recipe-parity-process.test.sh` (new) — the
  load-bearing process-property scenarios listed below
- `tests/fixtures/recipe-parity/` (new) — minimal fixture plans
  exercising each migrated recipe shape

**Dependencies:** U0, U1, U2a, U2b

**Approach:** Migrate in order of risk: `w` first (smallest stub),
then the a2-shape iteration fixture (closes substrate iteration
coverage). After each, BOTH the end-state parity test AND the
process-property parity test must pass before moving to the next.
The end-state test runs both engines headlessly on a fixture,
snapshots each ledger, compares structurally against the closed
divergence set in KTD-5 (timestamps, run-ids, enumerated workflow
substrate fields, parallel completion ordering). Full a1/a2/a4
migration deferred to v0.5.1 per Cutover sequencing.

**Test scenarios (end-state):**
- `w` parity: legacy + workflow produce identical terminal ledger
  state on a fixture single-unit plan
- `a2-fixture` parity: legacy + workflow produce identical terminal
  ledger state on a minimal iteration-gate plan with bound
  enforced (substrate-coverage test for iteration handling)

**Test scenarios (process properties — load-bearing, finding 7;
review r3 finding 3 — INJECTION MECHANISMS MUST BE SPECIFIED
BEFORE U3 BEGINS, not asserted as scenarios):**

**Injection-mechanism specification gate** (review r3 finding 3):
each `parity-*` scenario below MUST have its injection mechanism
specified in `docs/contracts/parity-injection.md` BEFORE U3 begins
(this specification is a deliverable of U0's expanded exit gate).
A parity scenario without a specified injection mechanism is a
CLAIM, not a test, and v0.5.2's deletion gate does NOT count it.
Specifically required:
- **`parity-rate-limit` injection:** how is rate-limit simulated
  inside a compiled JS workflow? The legacy engine's
  rate-limit-safe re-arm emerges from the tick chain's
  `ScheduleWakeup` pattern; the Workflow substrate may have no
  equivalent. Spec must define: the injection point (mock the
  `agent()` call to raise a typed rate-limit exception), the
  expected legacy-engine response (deferred re-arm via Stop
  hook + ledger), the expected workflow response (substrate-
  native retry or escape to ledger-driven re-arm), and the
  parity oracle (operator-visible state shapes match within the
  KTD-5 closed divergence set).
- **`parity-resume-seam` injection:** Workflow's
  resume-from-cache may not align with the ledger-driven resume
  the legacy engine uses. Spec must define: how a seam-pause is
  forced (kill the host process mid-`seam` phase), how the
  second session is launched (fresh `/auto-resume <run_id>`),
  and how parity is asserted when one engine resumes via
  `resumeFromRunId` and the other via `phase_advance.advance_to_phase`.
- **`parity-stop-block` injection:** both engines must be
  invocable under the same Stop hook. Spec must define: how the
  workflow-substrate Stop-hook integration is exercised when
  KTD-7's heartbeat contract presupposes a Workflow runtime that
  hasn't been verified to expose the hooks needed (finding 1). If
  the Workflow runtime cannot register with the existing Stop
  hook, parity-stop-block is unsimulatable and the test reduces
  to a CLAIM.
- **`parity-heartbeat-stale` injection:** spec must define how a
  70s `agent()` hang is mocked across both engines, and what the
  cross-engine equivalent of "session killed" looks like for the
  workflow substrate.

If any of these injection mechanisms cannot be specified at U0
exit-gate time, the corresponding `parity-*` test is dropped from
the v0.5.2 deletion-gate criteria and the deletion gate's
quantitative criteria are adjusted accordingly (see Cutover
sequencing).

Scenarios (each requires its injection spec to land first):
- `parity-stop-block`: simulate a session Stop mid-run; assert both
  engines BLOCK the stop with the same JSON shape from on-stop.py
- `parity-resume-seam`: pause at the plan→work seam, run
  `/auto-resume`, assert both engines advance loop_phase to work
  AND fire the seam→work emitter (verifiable by checking the
  emitted units)
- `parity-rate-limit`: simulate a rate-limit error mid-iteration;
  assert both engines surface the same recoverable state to the
  operator
- `parity-double-invoke`: invoke `/auto <plan>` twice rapidly;
  assert one wins, the other emits `LedgerExists`
- `parity-heartbeat-stale`: KTD-7 contract — Workflow hangs in
  `agent()` 70s then killed; next session's on-stop classifies the
  run as stale-chain (driver='self', last_beat_at > 3900s) and
  declines to block, matching legacy Bug #9 behavior
- `parity-heartbeat-cadence` (review r2 finding 21): assert
  `last_beat_at` advances at least every 90s during a 300s mid-run
  pause
- `parity-substrate-binding` (review r2 finding 16): a workflow-
  substrate run cannot be tick-advanced by the legacy engine and
  vice-versa; `SubstrateMismatch` raised on cross-substrate
  invocation
- A deliberately-broken recipe markdown (missing Off-script
  section OR missing the now-mandatory Sanity Fixture section)
  produces a clear compile error, not a silent skip

### U4. Loop-driver skill shrink + entry surface integration

**Goal:** Shrink `skills/auto/SKILL.md` from 120 lines to **≤40
lines** (per KTD-6 — single contract; review r4 finding 19
removed the ~30 target to eliminate drift). The loop driver
becomes "resolve recipe → compile if stale → invoke Workflow →
surface result." Update the v0.4.0 entry surface dispatch lines.
Implement the phase-advance / heartbeat path required by KTD-7.

**Dispatch ownership** (review r1, finding 34): ONE source of truth.
`commands/auto.md` changes only the entry line to delegate to
`auto-driver`. **`auto-driver` owns the full path:** recipe
resolution → compile-if-stale (via Skill invocation, per KTD-2) →
`Workflow({scriptPath, args})` invocation. `lib/recipe-compile.py`
is the stat-and-validate helper auto-driver shells out to; the
actual compile is Skill-invoked from inside auto-driver's body.

**Files:**
- `skills/auto/SKILL.md` (rewrite) — ≤40 lines (single contract per KTD-6 + review r4 finding 19)
- `docs/contracts/driver-reference.md` (modify) — add v0.5.0
  addendum; mark legacy sections as historical (prepare/execute
  essay, livelock guards) vs current (goal binding, batch fanout)
- `commands/auto.md` (modify, dispatch line only) — delegate to
  auto-driver; do NOT duplicate compile/Workflow invocation logic
- `skills/auto-driver/SKILL.md` (modify) — owns recipe resolution
  → Skill-based compile (per KTD-2) → Workflow invocation. Recipe
  selection now returns a `recipes/<name>.md` path
- `lib/auto-spawn.py` (modify) — purely a workspace fan-out shell;
  per review r2 finding 3 it has NO compile responsibility. The
  Skill-based warm-compile runs in `auto-driver` BEFORE
  auto-spawn.py is invoked (KTD-2 multi-plan section), so every
  workspace reads a guaranteed-warm cache.
- `lib/phase_advance.py` (new, per review r2 finding 15; path
  corrected per review r4 finding 15) — split `advance_to_phase`
  out of **`lib/tick_advance.py` (definition at line 529)**, NOT
  tick.py (tick.py only re-exports it). Imports
  `emitters.resolve` and `phase_grammar.emitter_name_for_arrival`;
  remains the single chokepoint for phase advancement (both
  Python auto-resume and the compiled JS workflow's auto-flip
  path route through here). Closure verified clean (review r4
  finding 15) — no `tick_guidance` pull-in; the split is
  genuinely ~47 lines and U4.5 escalation is NOT triggered.
- `lib/auto-resume.py` (modify) — replace `import tick` and
  `tick.advance_to_phase(...)` with `phase_advance.advance_to_phase(...)`.
- `lib/on-stop.py` (verify, no edits expected) — KTD-7 heartbeat
  contract means driver/last_beat_at freshness checks behave
  identically; verified by the parity-heartbeat-stale test in U3
- `tests/smoke/loop-driver-shape.test.sh` (modify) — assert the new
  budget (≤40 lines)

**Substrate flag (always present in v0.5.0/v0.5.1):** introduce
`AUTO_SUBSTRATE=workflow|legacy` env, defaults `legacy` in v0.5.0.
auto-driver routes by this flag. v0.5.1 flips the default to
`workflow` to start the v0.5.2 time-box clock (review r3 finding
5 — replaces the original N≥30 quantitative gate, unreachable at
observed run frequency). At the 60-day boundary v0.5.2 EITHER
deletes the legacy engine (cutover) OR deletes the workflow
substrate (honest rollback); the flag is removed with whichever
side wins.

**Dependencies:** U0, U1, U2a, U2b, U3 (the substrate has to work
before the driver invokes it)

**Approach:** Last-step replacement. The driver's responsibility
shrinks to four steps; everything else moves to Workflow's runtime.
The skill body cites the deleted-engine theory as `historical (pre-
v0.5.0)` in the reference doc so future maintainers know why those
sections are present.

**Test scenarios:**
- `wc -l skills/auto/SKILL.md` ≤ 40
- `grep -q 'historical' docs/contracts/driver-reference.md`
  succeeds (legacy sections explicitly marked)
- A bare `/auto <recipe>` invocation triggers compile-if-stale →
  Workflow invocation; ledger initializes; exit predicate fires
  correctly
- `commands/auto.md` does NOT duplicate compile/Workflow invocation
  logic (single source of truth)
- Multi-plan warm-compile: an N-plan dispatch with a stale recipe
  triggers ONE Skill-based compile in `auto-driver` BEFORE
  `auto-spawn.py` is invoked; all N workspaces read the warm cache
  and use the same compiled artifact (no race)
- **Multi-plan compile-failure (review r3 finding 8):** N-plan
  dispatch with a recipe that fails sanity-fixture validation —
  assert `auto-spawn.py` is NOT invoked, NO workspaces spawn, the
  operator sees a clear typed error, and the ledger init records
  `compile_status: failed` for the surfaced run-id
- **Multi-plan compile rate-limit (review r3 finding 8):** the
  Skill invocation rate-limits during multi-plan dispatch — assert
  the dispatch aborts cleanly with a typed "compile rate-limited"
  error rather than hanging; `auto-spawn.py` is NOT invoked
- `/auto-resume` on a paused-seam run fires the seam→work emitter
  exactly once via `phase_advance.advance_to_phase`; loop_phase
  advances to work
- The v0.4.0 entry surface (bare /auto on a reviewed plan,
  multi-plan fanout, project-as-workspace) all still work — they
  invoke the new substrate via the same auto-driver hypothesis
  funnel
- `AUTO_SUBSTRATE=legacy` routes to the legacy engine;
  `AUTO_SUBSTRATE=workflow` routes to the workflow substrate; both
  coexist without interfering; substrate-binding field on the
  ledger prevents cross-substrate operations

### U5a. Test-porting from tick/orchestrator/iteration into substrate-agnostic tests

**Goal (review r3 finding 22 — split out as its own unit because
the porting work is on the order of U2b+U3 combined, not a PR
triage exercise; depends on U2b's compiled-JS test harness
existing and U3's recipe-parity being green):** Triage and port
~93 named tick/orchestrator/iteration tests into substrate-
agnostic tests that exercise the same regression guarantees
against the compiled JS (e.g., double-drive-guard becomes:
invoke the same workflow twice concurrently; assert the second
raises `LedgerExists` / lock-held). The triage table classifies
each named test as:

- (a) parity-coverable (end-state ledger or process-property
  scenario in U3)
- (b) requires compiled-JS direct test (port to a new substrate-
  agnostic test)
- (c) requires a substrate primitive the verified Workflow surface
  does not offer (this is P0 design feedback that must close
  BEFORE U5 lands; some category (c) findings may have already
  surfaced in U0's exit gate item 1a per finding 7)

**Effort estimate (review r3 finding 22):** even at 30 minutes per
test, ~93 tests is 45+ hours. This is NOT a PR triage exercise.
The triage table is a U5a deliverable, NOT inside U5's PR
description.

**Files:**
- New substrate-agnostic test files under
  `tests/integration/substrate-guards/` — one per category-(b)
  port (double-drive, phantom-dispatch reaper, gaps_open_guard,
  scale-aware gating, fix-pass H gaps_open_guard, Bug #5
  null-path, task #31 GREEN double-drive guard, etc.)
- Triage table at `docs/contracts/test-porting-triage.md` —
  enumerates every named test in the deletion candidate list with
  its category and the new test location (if (b)) or design
  resolution (if (c)).

**Dependencies:** U2b (compiled-JS test harness must exist), U3
(recipe-parity must be green before porting begins so the parity
oracle is established).

**Hard exit gate:** zero tests remain in category (c) — every
guarantee either ports to a substrate-agnostic test or has
explicit design closure. Without this gate, U5 cannot land.

### U5. Delete the legacy engine OR roll back the workflow substrate (v0.5.2; time-box gated)

**Goal:** At the 60-day time-box boundary on
`AUTO_SUBSTRATE=workflow` default, take ONE of two actions per
Cutover sequencing (review r3 finding 5 — the original N≥30
quantitative gate was unreachable at observed run frequency, so
it has been replaced with a time-box + pre-committed rollback to
prevent permanent dual-engine drift):

- **Cutover (delete legacy):** if zero compiler-mistranslation
  side quests AND ≥1 off-script handler fired in production AND
  parity tests are green across the migrated recipe set, delete
  the legacy engine layers below.
- **Honest rollback (delete workflow substrate):** if EITHER a
  compiler-mistranslation side quest occurred OR no off-script
  handler has fired (the substrate's central new capability is
  unproven), DELETE the workflow substrate, re-bless the legacy
  engine, and ship a post-mortem documenting which assumption
  broke. The legacy engine remains the disaster-recovery
  fallback (see R1c amendment).

Permanent dual-engine maintenance past the 60-day box is NOT an
option — the complexity cost compounds silently and would
strictly worsen the project's footprint vs. either decisive
outcome.

**Files:**
- `lib/tick.py` (delete, 742 LOC)
- `lib/tick_advance.py` (delete, 624 LOC)
- `lib/tick_guidance.py` (delete, 230 LOC)
- `lib/orchestrator.py` (delete, 554 LOC)
- `lib/auto.py` (gut to ~80 LOC: recipe resolution, ledger init,
  Workflow invocation. Down from ~355.)
- `lib/tick.sh`, `lib/orchestrator.sh`, etc. shell shims (delete —
  per finding 32; `tick_advance.py` is already listed above as the
  Python module, not a shim)
- All `tests/unit/tick*.test.sh`, `tests/unit/orchestrator.test.sh`,
  `tests/unit/iteration*.test.sh` — **CONDITIONAL DELETION**
  (review r2 finding 7). The porting work is its own unit
  (**U5a — Test-porting from tick/orchestrator/iteration**;
  review r3 finding 22): each named test is triaged into (a)
  parity-coverable, (b) requires compiled-JS direct test, (c)
  requires a substrate primitive the verified Workflow surface
  does not offer. Category (c) is P0 design feedback that closes
  BEFORE U5 lands (some may already have closed at U0 exit gate
  item 1a per finding 7). Triage table is a U5a deliverable at
  `docs/contracts/test-porting-triage.md`, NOT inside U5's PR
  description. Tests are deleted in U5 ONLY after U5a's
  hard-gate is satisfied (zero category-c tests outstanding).
  NOTE: `lib/iteration.py` is NOT in this delete list because U1
  relocated it to `lib/ledger/iteration.py` (load-bearing for the
  ledger's lazy imports per finding 23). The tests for iteration
  logic survive under the new path.
- `recipes/*.json` (delete — superseded by `.md` versions; U3 keeps
  them in place, U5 atomically deletes per finding 33)
- `lib/recipes.py`, `lib/recipes-list.sh` — **MODIFIED in U5**
  (review r2 finding 24 — earlier "NO modification… may strip"
  was internally contradictory). Strip the now-unused JSON-load
  branches as part of the atomic deletion. This is a small,
  bounded modify; Sequencing allows it within the
  otherwise-deletion-only U5 because the JSON path is dead the
  moment `recipes/*.json` are removed.
- `docs/contracts/recipe-format.md` → renamed to
  `recipe-format-legacy.md`, header note pointing at v2

**LOC roll-up** (replaces the prior `~2200` figure, per finding 17):
tick (742) + tick_advance (624) + tick_guidance (230) +
orchestrator (554) + auto.py reduction (~275) = **~2425 LOC
deleted**. `lib/iteration.py` (314) is RELOCATED, not deleted, so
not counted. Total expected reduction in `wc -l lib/*.py` is
~2425 LOC.

**Dependencies:** U0, U1, U2a, U2b, U3, U4 (all must be green;
parity must be proven across the migrated recipe set in v0.5.1
which adds a1/a2/a4; additionally the v0.5.2 time-box gate above
must resolve — 60 days at substrate=workflow default with the
cutover-vs-rollback decision made at the boundary per Cutover
sequencing; permanent dual-engine maintenance is not an option)

**Approach:** **Single bounded PR with deletion + gut + strip +
rename** (review r4 finding 21 — stopped calling it "atomic"
when its own text says it isn't): deletes the legacy engine
modules, guts `lib/auto.py` to ~80 LOC, strips JSON-load
branches from `lib/recipes.py`/`recipes-list.sh`, deletes
`recipes/*.json`, and renames `recipe-format.md` to
`recipe-format-legacy.md`. Reviewers MUST read the gut and
strip sections explicitly — they are not pure deletion. Each
deleted file gets removed because a specific replacement now
covers it; no orphan deletions. **Optional split:** if
reviewers want them separated, U5 splits into U5b (deletions
only) + U5c (auto.py gut + JSON-strip + rename).

**Test scenarios:**
- `bash tests/run.sh all` passes with the legacy modules deleted
- `git grep tick_advance` returns zero matches outside of historical
  documentation
- `git grep orchestrator.dispatch_batch` returns zero matches
- Each migrated recipe still works end-to-end (recipe-parity tests,
  now run against the workflow substrate only since the legacy
  engine no longer exists)
- `wc -l lib/*.py` shows the expected reduction (~2425 LOC removed)
- A recipe with an iteration block whose ledger is recomputed after
  engine deletion — assert no `ImportError` from the relocated
  `lib/ledger/iteration.py` lazy-load (finding 23 regression check)

## Test Strategy

Three layers of test:

1. **Unit tests** for the ledger library (U1), the recipe compiler
   (U2), the loop driver (U4). These exercise each component's
   contract in isolation.
2. **Parity tests** (U3) for each recipe: legacy engine vs workflow
   substrate, same fixture, ledger structurally identical at exit.
   These are the load-bearing safety net for the migration.
3. **End-to-end** (U4, U5) for the v0.4.0 entry surface: bare /auto
   on a reviewed plan, multi-plan fanout, project-as-workspace —
   these should all still work because the substrate change is
   beneath the entry-surface layer.

`bash tests/run.sh all` must pass green at the end of every unit.
Parity tests are part of the suite from U3 onward.

## Risks & Open Questions

**R1 — Compiler + Workflow runtime non-determinism** (consolidates
former R1, R2, R6, R7 per review r2 finding 19 — all four are
facets of the same load-bearing risk: the substitute substrate is
non-deterministic where the engine was deterministic). Three
specific sub-risks within this single bucket:
- **R1a (compiler mistranslation)**: the compiler is a Claude
  Skill, output is non-deterministic. Mitigations active in
  v0.5.0: structured-diff header in the compiled file (KTD-1) for
  operator inspection; per-recompile sanity-fixture gate (KTD-2);
  structural validator (U2b); cache-key **quadruple** invalidation
  on source mtime / primitive-surface / library-API /
  compiler-skill-version drift (KTD-3 per review r3 finding 16).
  Mitigations DEFERRED to v0.5.1 (per review r3 finding 11):
  off-script fixture harness (KTD-4) and adversarial-direction
  verifier (U2b's fifth check) — both have no v0.5.0 work because
  the canaries (`w` + a2-fixture) exercise no substantive
  off-script policy.
- **R1b (Workflow runtime drift)**: double-drive guards,
  rate-limit-safe re-arm, seam pause semantics may not be
  preserved. Mitigation: U3 parity tests include these edge cases;
  v0.5.2 deletion is gated on real-use trust accumulating.
- **R1c (primitive surface drift after release; SEVERITY-RAISED
  per review r4 finding 11)**: Workflow tool's API may shift
  between Claude Code releases. **Pre-U0 prerequisite (review r4
  finding 11):** before U0 begins, obtain a WRITTEN STATEMENT
  from Claude Code maintainers about the Workflow tool's API
  stability commitments — semver? deprecation window? changelog
  discipline? Without such a commitment, R1c rises from P2 to
  P0 BLOCKER: building a substrate on an explicitly-unstable
  upstream is a different decision than building on a stable
  one. Pair this with the document-level inversion in the
  preamble: until Workflow has the stability story of, say, the
  Skill tool or the Stop hook (both of which are now stable
  substrates the plan correctly relies on), the v0.4.x
  escape-hatch (Plan of Record) is the live path and the
  substrate plan stays parked.

  Mitigation (only meaningful AFTER stability commitment lands):
  cache key includes primitive-set content hash (KTD-3); any
  change forces recompile against the new surface.
  **Upstream coupling sub-risk** (review r3 finding 23): a
  Workflow API change forces wholesale recompile + revalidation
  of every recipe; ALL fixture suites run simultaneously and any
  fixture gap allows broken JS through silently. Mitigation:
  subscribe to Workflow-tool changelog as a release-blocker
  check; before any Claude Code release with Workflow changes,
  run the full fixture+parity suite against the new tool surface
  in a staging worktree, gate adoption. **On-call playbook
  REMOVED per review r4 finding 5:** the legacy-flip-back fallback
  presumed a working fallback engine; per the fallback-liveness
  invariant, legacy bitrots during the 60-day box at observed run
  volume so the flip-back is unavailable. The R1c response when
  upstream drift occurs is now: pause the substrate path, route
  back to the Plan-of-Record escape-hatch increment if needed.

**R2 — `/auto-author-recipe` rewrite is larger than scoped.** Today
it generates JSON from conversation; rewriting to generate markdown
is the easy half. The harder half is teaching the conversational
intake the recognized off-script-policy vocabulary AND the now-
mandatory `## Sanity Fixture` and `## Off-script Fixtures`
sections so the produced recipes compile cleanly. May need its own
follow-up plan.

**R3 — The recipe library's identity changes.** Today recipes are
operator-discoverable named things (a1, a2, a4, w). After v0.5.0
they're still named, but their substrate is a Claude-compiled
artifact. Power users who fork the plugin to add recipes need to
trust the compiler. If trust is low, they fall back to hand-writing
the compiled JS via `--workflow <path>` — which works (the compiled
file IS a workflow script) but bypasses the recipe-as-markdown
surface. Mitigation: make the compiler output high-quality, well-
commented JS; make the recognized off-script-policy vocabulary
documentation excellent.

**R4 — Resume semantics change.** Today's `/auto-resume <run>` reads
the ledger and re-arms the tick chain. With Workflow, resume is
`Workflow({scriptPath, resumeFromRunId})` which replays the
unchanged prefix from cache. Behavioral parity needs explicit
verification (parity-resume-seam in U3). The phase-advance path
routes through `lib/phase_advance.py` (split from
`lib/tick_advance.py:529`, NOT tick.py — per review r4 finding
15) per KTD-7.

**Open Q3** (reframed per review r2 finding 25 — keeps the
`independent_of: [003]` claim coherent). v0.5.0 ships a
`--workflow <path-to-js>` flag for power users who want to bypass
the compiler and reference a pre-existing workflow script
directly. Its shape is decided INDEPENDENTLY of plan 003. **Forward-
compatibility check:** v0.5.0's flag must be designed to NOT collide
with 003's anticipated `--no-intake` flag namespace. This is a
forward-compatibility check, not a dependency; if 003 ships first
v0.5.0 inherits the namespace constraint, if 003 ships second it
inherits v0.5.0's. Confirm flag shape before U4 lands.

<!-- Open Q4 resolved by review r2 finding 3: warm-compile moved
out of auto-spawn.py into auto-driver (model-side, has Skill
access). See KTD-2 multi-plan section. -->

### Resolved Questions (kept for audit, review r4 finding 20)

- **Q1 — compile invocation model:** resolved as **Skill-invoked
  compile from auto-driver** (NOT a synchronous Python call from
  a non-Claude process). See KTD-2; the resolution lives in the
  compile-failure contract paragraph. The Skill tool is a
  model-side primitive, so the compile cannot be a direct
  function call from `auto-spawn.py`.
- **Q2 — operator edits to compiled file:** resolved as **no
  detect-and-warn**. The compiled file is a derived runtime
  cache; operator edits are unsupported and will be silently
  overwritten on the next source edit. Power users who want to
  hand-write the JS use the `--workflow <path>` flag pointing
  at a file under their own control.

(Q1 and Q2 deliberation narratives were removed per review r2
finding 19 because they were unhelpful documentation accretion;
the resolutions are surfaced here in the rendered doc so
readers don't have to inspect HTML comments to confirm
old-question disposition.)

## Sequencing

U0 first — **BLOCKING preflight, split off as a standalone RFC**
(Workflow primitive surface verification + side-quest history pull
+ vocabulary classification + JS-side ledger client smoke). Until
U0's exit gate passes in its own merged PR, U1-U5 do NOT start.
Plan status is `blocked_on_workflow_tool_availability`.

U1 second (ledger library API on top of existing four-file split;
adds the public surface compiled workflows call; zero deletions in
the ledger family).

U2a third (recipe format spec + reference docs); U2b fourth
(compiler skill + entry helper + post-compile validator). U2a → U2b
in sequence because the validator targets the surfaces U2a defines.

U3 fifth (canary recipe migration — `w` + a2-shape iteration
fixture; needs U0+U1+U2a+U2b; runs end-state parity AND process-
property parity).

U4 sixth (driver shrink + entry surface dispatch updates; introduces
the always-present `AUTO_SUBSTRATE` flag at default `legacy`;
implements phase-advance path per KTD-7).

U5a sixth-half (test-porting from tick/orchestrator/iteration into
substrate-agnostic tests; review r3 finding 22 — split out as its
own unit; depends on U2b + U3; hard gate of zero category-(c)
tests outstanding before U5).

U5 last (engine deletion + `auto.py` gut + JSON-format strip —
**single bounded PR with deletion + gut + strip + rename — the
reviewer reads the gut and strip sections explicitly** (review
r4 finding 21 — the earlier "atomically-reviewable" framing was
load-bearing on what its own text said it wasn't; the diff is
mixed, so the framing is honest now). Legacy modules removed,
`lib/auto.py` reduced to ~80 LOC, `lib/recipes.py`/`recipes-list.sh`
strip JSON-load branches, `recipes/*.json` deleted,
`recipe-format.md` renamed legacy; **lands in v0.5.2, not
v0.5.0**, gated on the run-volume criterion in the Cutover
sequencing section per review r4 finding 12. Optional future
split if reviewers need them separated: U5b (deletions) + U5c
(auto.py gut + JSON-strip + rename).

**External sequencing — independent of plan 003** (review r1,
findings 9/21/28/31, matching the intent context Shawn supplied):
v0.5.0 ships independent of plan 003 (goal-as-markdown). Both
plans write to the ledger via the library API (U1); 003 adds a
`goal_source` field that the library carries through unchanged
(forward-compatible by design). If 003 lands first, v0.5.0 inherits
it; if 003 lands second, the library API gets a backward-compatible
add. Neither blocks the other. Frontmatter carries
`independent_of: [003]` so the orchestrator doesn't gate.

## Success Criteria

**v0.5.0 (parked migration RFC — success criteria the future RFC must satisfy):**
- U0 completes: Workflow primitive surface verified and documented;
  side-quest evidence base shows ≥3 distinct rigidity shapes (≥2
  in-process observable); vocabulary classification table produced;
  JS-side ledger client smoke passes.
- `.claude/workflows/<recipe>.compiled.js` artifacts are produced
  correctly on first invocation; cache key (quadruple per review
  r3 finding 16: source mtime + primitive-set hash + library-API
  hash + compiler-skill-version) invalidates correctly; per-
  recompile sanity-fixture gate enforced. Off-script fixture
  harness AND differential-prompting verification DEFER to v0.5.1
  (review r3 finding 11 — no v0.5.0 canary exercises off-script
  policy substantially enough to make these load-bearing).
- The ledger library API (6 helpers including `heartbeat`) is the
  only entry point compiled workflows use for ledger writes; I-1 +
  I-2 invariants preserved; existing ledger files keep their shape;
  substrate-binding field present on every initialized ledger.
- KTD-7 heartbeat contract verified end-to-end: a hung Workflow
  classifies as stale-chain on the next session's Stop hook;
  cadence parity test passes (last_beat_at advances ≤90s in a
  300s pause).
- `skills/auto/SKILL.md` ≤ 40 lines; the loop driver becomes a four-
  step contract. (Per review r4 finding 19 — single contract;
  prior ~30 aspirational target removed.)
- `/auto-author-recipe` generates markdown, not JSON; produced
  recipes include the now-mandatory `## Sanity Fixture` section
  (v0.5.0). `## Off-script Fixtures` is OPTIONAL in v0.5.0,
  MANDATORY in v0.5.1 alongside a1/a2/a4 migration (review r3
  finding 11).
- A recipe author can declare an off-script policy in prose drawn
  from KTD-4's closed vocabulary ("on timeout retry once; on
  malformed verdict retry with augmented prompt") and the compiled
  workflow handles those cases SYNTACTICALLY. Semantic verification
  of off-script handling DEFERS to v0.5.1 (review r3 findings 11
  + 12 — the off-script fixture harness is the only real
  falsifiability surface and lands with a1/a2/a4 migration).
- The v0.4.0 entry surface (bare /auto, multi-plan fanout,
  project-as-workspace) works end-to-end with the new substrate.
  Multi-plan fanout uses auto-driver-side warm-compile (no race on
  the compiled artifact across N workspaces; compile happens
  Skill-side before auto-spawn fans out).
- `recipes/w.md` and `recipes/a2-fixture.md` migrated; end-state +
  process-property parity tests pass for both.
- `AUTO_SUBSTRATE=workflow|legacy` flag works (default `legacy`);
  both engines coexist; substrate-binding prevents cross-substrate
  operations.
- v0.5.0 ships **without engine deletion** (legacy survives).
- `bash tests/run.sh all` passes green.

**v0.5.1 (parked migration RFC — deferred follow-up):**
- a1, a2, a4 migrated as full recipes (not minimal fixtures);
  parity tests green.
- Flag default flips to `workflow` once antecedent production
  runs accumulate.

**v0.5.2 (parked migration RFC — deferred follow-up):**
- AT THE 60-DAY TIME-BOX boundary on
  `AUTO_SUBSTRATE=workflow` default (review r3 finding 5), EITHER:
  - **Cutover:** if zero compiler-mistranslation side quests AND
    ≥1 off-script handler fired, delete legacy engine layers
    (`lib/tick.py`, `lib/tick_advance.py`, `lib/tick_guidance.py`,
    `lib/orchestrator.py`, plus shell shims); `lib/auto.py` is
    ~80 LOC. Total reduction ~2425 LOC.
  - **Honest rollback:** if a compiler-mistranslation side quest
    occurred OR no off-script handler fired, DELETE the workflow
    substrate, re-bless the legacy engine, post-mortem.
  Permanent dual-engine maintenance is NOT an outcome.
