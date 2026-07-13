---
name: auto-launch
description: >
  The loop-design launch agent for interactive `/auto`. Assesses session + repo,
  recommends a fitting built-in shape (a1/a2/a4/w) or composes a custom loop,
  proposes typed verification gates, and drives the skip / confirm / two-step
  chooser before dispatch. Use when the interactive launch path needs a
  worked-out, confirmable loop recommendation instead of a silent mechanical
  dispatch. Distinct from `auto-driver` (which orients and routes BEFORE this
  step) and `auto-design` (the full rubric-driven coach this skill calls to
  compose a custom loop); invoked by the interactive launch path, never bare.
---

# auto-launch (the loop-design launch agent)

Interactive `/auto` opens with a worked-out loop recommendation — a shape, its
proposed typed gates, and a one-line rationale — that the operator confirms,
**skipping the question entirely when both shape and gates are obvious.** This
skill is the agent step between situation-detection and dispatch. It picks (or
composes) the loop the deterministic router can't reach, proposes its gating,
emits two confidences plus the structural facts, and lets `lib/launch-gate.py`
(the crisp half) decide the tier. It never re-implements the ladder and never
re-derives the exit predicate.

Read these before recommending — they are the quality bar for BOTH the shape
pick and the gate proposal, not background:
`skills/auto-design/references/goal-rubric.md`,
`skills/auto-design/references/verification-rubric.md`,
`skills/auto-design/references/control-rubric.md`,
`skills/auto-design/references/verification-taxonomy.md`.

## 0. Interactive-only entry guard (R11 / KTD-5 — do this FIRST)

Before assessing anything, resolve the entry mode with ONE deterministic shell
call — **do not eyeball the `driving_session_id` yourself**:

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/launch-mode.sh"
```

It prints exactly `headless` or `interactive`, folding the
`driving_session_id` ownership check (the same signal the advisor gate in
`commands/auto.md` / `skills/auto/SKILL.md` §4.6 matches on) into one handoff: it is
`headless` when no `CLAUDE_CODE_SESSION_ID` is present, or when this session
already owns a live self-driven run; `interactive` otherwise (a human-typed
`/auto` with no live self-driven run of its own). The chooser is for the
`interactive` case only.

- **`headless`** → **silent-apply by construction.** Compute the recommendation
  exactly as below, then dispatch it with the R9 one-line notice — but it must
  **never call `AskUserQuestion`** on this path. Routing straight to silent-apply
  here is what keeps a self-driven / headless run out of the question path by
  construction (AE6), not a reliance on the PreToolUse hook's mid-question
  denial. Silent-apply means apply-and-dispatch the recommendation, not do
  nothing.
- **`interactive`** → continue to the ladder below; the chooser may show.

If `launch-mode.sh` errors or prints anything other than `interactive`, treat it
as `headless` and silent-apply — the conservative direction never opens a
blocking question on a possibly-headless run. This guard is the deterministic
interactive-only entry: a self-driven or headless launch reaches dispatch without
ever entering `AskUserQuestion`.

## 1. Seed from the session — open auto-shaped, not blank

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/auto-detect.sh"
```

The same hypothesis `auto-driver` and `auto-design` read. Use its `situation` /
`summary` (and any `single_plan` / `recommendation` slots) to draft a *proposed*
shape and a *proposed* first cut of gates from what the session already shows.
Do NOT run a blank interview (seed, don't interview). If the envelope is thin or
degraded, open auto-shaped from whatever signal exists (the prompt, the dirty
tree, the most recent plan doc) and say what you inferred — never fall back to a
blank questionnaire.

## 2. Recommend a shape across ALL four built-ins — or compose a custom

Reason over the four built-in shapes — this is the model judgment
`lib/recommender.py` cannot express (it only ever reaches `a1`/`w`):

Each shape has a legible name; the shorthand still works as an alias
(`lib/recipes.py::_ALIASES` resolves either form to the same recipe):

- **`plan-build-review`** (alias `a1`) — plan-loop. Clear single-track intent
  that needs planning then work.
- **`work-only`** (alias `w`) — work-only. A reviewed plan that goes straight to
  the work-loop.
- **`parallel-theories`** (alias `a2`) — Parallel Theories + Judge.
  High-uncertainty design space worth running N competing plans and judging the
  winner (declares a `judge` gate step).
- **`adversarial-pair`** (alias `a4`) — Adversarial Pair + Comparator. One plan,
  two biased builders, a comparator picks/merges (declares a `compare` gate step).

Ground the pick in the `auto-design` rubrics (above). When **no built-in fits**
(the work needs a gate point no built-in expresses — e.g. a spike-before-build
gate), compose a custom loop **up front** via the `auto-design` →
`auto-author-recipe` / `auto-author-goal` backends, and present it as the
recommended option drawn like the built-ins (R4). A composed recipe must pass
recipe validation before it is offered. The custom-compose path and the "design
new" escape hatch both hand off to `auto-design` for the coaching.

## 3. Propose typed gates per gate point (R2) — deterministic-first

For the recommended shape's gate point, propose a `verification` array per the
taxonomy (`verification-taxonomy.md`). Coach **deterministic-first**: a claim
that *can* be a `programmatic` command + check must be one; reach for
`model_judge` / `advisor_judge` / `human` only for what a command genuinely can't
decide. Keep one claim per criterion; the array is capped at ≤ 16.

**Gate attachment is shape-specific (KTD-4):**

- **`a1` / `w` have no iteration gate point.** They emit work steps at runtime
  with dynamic ids, so they carry **no `verification` block**. What the
  chooser/notice surfaces for them is a *description of the inherent
  review-to-P3 exit predicate* (`blockers == 0 AND majors == 0 AND
  all_steps_terminal` — "only P3 findings remain"), for visibility only — not a
  new typed gate. R2's "at each gate point" is vacuously satisfied (a1/w have no
  iteration gate point).
- **`a2` / `a4` / custom have a declared gate step** (`judge` / `compare` /
  the custom's own), so typed `verification` attaches via the existing
  `iteration.gate_step` mechanism.

## 4. Compute `router_agrees`, then call the ladder (KTD-1 / KTD-5)

The skip inputs are model-self-assessed, so a skip carries a fourth
**deterministic** precondition: the agent's recommended stem must equal the
in-tree router's pick. Compute it:

1. Classify the launch into a recommender **state label** (`reviewed-plan`, or
   `clear-intent-no-plan` for a freeform intent that needs planning) — the same
   label KTD-5 keys the interception on.
2. Compute `router_agrees` with ONE deterministic shell call — **do not eyeball
   it or substitute your own judgment for the router**:

   ```
   python "${CLAUDE_PLUGIN_ROOT}/lib/recommender.py" --check-agrees <state> <your-recommended-stem>
   ```

   It prints exactly `true` or `false` and nothing else: `true` IFF the router's
   deterministic pick for `<state>` equals your stem (`reviewed-plan`→`w`,
   `clear-intent-no-plan`→`a1`; any `a2`/`a4`/custom stem can never match, so it
   returns `false`). Pass that literal `true`/`false` straight through as the
   gate's `router_agrees` argument. Folding the classify-run-compare into one
   primitive is deliberate: the cross-check must be computed BY the router, not
   asserted by the agent (`feedback_deterministic_over_probabilistic_v1`).

   If the call exits non-zero or prints anything other than `true`/`false`, treat
   `router_agrees` as `false` — never assume agreement when the cross-check
   cannot run (the conservative direction: show the chooser, never skip).

This is a real discriminator: because skip already collapses to `a1`/`w`, the
router is exactly authoritative there, and a non-default shape can never match —
an agent recommending `a2`/`a4`/custom on a `reviewed-plan` state disagrees with
the router's `w`, so `router_agrees` is `False` and the chooser fires instead of
skipping. It corroborates a self-assessed `shape_confidence` with deterministic
code for the only shapes that can skip.

Then hand the fuzzy floats + structural facts to the crisp half:

```
python "${CLAUDE_PLUGIN_ROOT}/lib/launch-gate.py" <shape_confidence> <gates_confidence> <recipe_kind> <gate_types_csv> <router_agrees>
```

- `shape_confidence` / `gates_confidence` — your own `[0,1]` certainty in the
  shape pick and the gate proposal.
- `recipe_kind` — `builtin` or `custom`.
- `gate_types_csv` — the proposed criterion `type`s, comma-separated (empty for
  a1/w's no-typed-gate case).
- `router_agrees` — `true` / `false` from the `--check-agrees` call (step 2).

`launch-gate.py` owns the ladder rules and the load-bearing skip bar — **do not
restate or re-derive them here.** Read the returned `tier` and branch.

## 5. Branch on the tier

### `skip`

Print the R9 one-line non-blocking notice and dispatch — no question.

```
-> <recipe> · gate: <summary>
```

`<summary>` for **a1/w** names the inherent review-to-P3 exit predicate, e.g.
`-> a1 · gate: review-clean to P3` — **not** a literal programmatic check (per
KTD-4, the exit predicate is what gates the run; a "tests green" phrasing would
misrepresent it). For a2/a4 with a default gate, name the gate step's check.

### `confirm`

Print the contrast block to stdout/transcript, then fire exactly **one**
`AskUserQuestion` showing the drawing + pick + gates; on confirm, dispatch.

```
bash "${CLAUDE_PLUGIN_ROOT}/lib/recipes-list.sh" --compare <candidates> --highlight <recommended>
```

(The U1 contrast surface — `render_comparison` via the one renderer. The cards
are far too large for an option label, so they print above the question; the
options stay terse with the rationale + gate summary in each `description`, per
KTD-3.)

### `two_step`

The full chooser:

- **Step 1 — shape.** Print the contrast block (`recipes-list.sh --compare …
  --highlight <recommended>`), then one `AskUserQuestion` over the drawn
  candidates with the recommendation highlighted. **A "design new" option is
  always present** as the escape hatch into `auto-design` coaching (R6).
- **On a shape override**, re-derive the proposed gates for the chosen shape
  (R7) — a2's gates are not a4's — before step 2.
- **Step 2 — gates.** One `AskUserQuestion` to confirm-or-edit the proposed
  gates for the (possibly overridden) shape. Then dispatch.

## 6. Dispatch — attach gates per KTD-4

- **a1 / w, or a built-in's default gates** → the **no-compile branch (KTD-4)**.
  Dispatch the built-in directly via the standard grammar, e.g.
  `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<spec> --recipe <name>"`. The exit predicate is surfaced in
  the notice only; **no workspace recipe is written**. a1/w have no declared
  `iteration.gate_step`, so there is nothing for a typed `verification` array to
  ride on — compiling a variant would be a no-op file that only risks shadowing.
- **a2 / a4 / custom with non-default (operator-edited) gates** → the **inline
  gate-compilation step (§6.1)**. The operator's confirmed `verification` array
  must reach the engine, and the only mechanism that carries it is a recipe whose
  `iteration.gate_step` names the declared gate (`judge` / `compare` / the
  custom's own). So compile a validated run-scoped recipe, dispatch it, then tear
  it down once the ledger is initialized.

The discriminated-union option-payload shape for any `AskUserQuestion` follows
`docs/contracts/driver-reference.md` §9 (branch on the situation before reading a
payload key; a null payload value is the action sentinel, not missing data).

## 6.1 Inline gate compilation (run-scoped recipe, then tear down) — KTD-4 / KTD-6

Reached only from §6's second bullet (a2/a4/custom carrying operator-edited or
custom gates). **Never hand-write the recipe JSON** — go through
`auto-author-recipe`'s write gate, exactly as `auto-design` §6 compiles via its
backends. The mechanics:

1. **Build the draft.** Start from the chosen shape's built-in topology (or the
   composed custom from `auto-design`). Attach the confirmed `verification` array
   to the step named by the recipe's existing `iteration.gate_step`
   (`a2`→`judge`, `a4`→`compare`, custom→its declared gate). Do not add a new
   gate point or producer — the typed array rides on the *existing* mechanism
   (`recipe-format.md` §11 + §6).
2. **Name it run-scoped: `<builtin>-<run-slug>`** (e.g. `a2-fix-checkout`). This
   **distinct stem** is the anti-shadow guard (KTD-6): it never collides with the
   canonical built-in `a2`/`a4`, so `resolve("a2", repo)` still returns the
   built-in unshadowed while `resolve("a2-fix-checkout", repo)` returns the
   run-scoped variant at the **workspace** tier (`<repo>/.claude/auto/recipes/`),
   which wins first via the three-tier resolver (`lib/recipes.py::resolve`). Set
   the draft's `name` field to that same run-scoped stem so it matches the file
   stem (else `validate_and_lint` warns on a name/stem mismatch). Give it a
   **distinct provenance description** — never copy the built-in's verbatim.
3. **Compile through `auto-author-recipe`'s write gate** to the workspace tier:
   `lib/recipes.py::validate_and_lint` before write, atomic mkstemp+rename,
   read-back verification. Treat **two** outcomes as blocking, not just hard
   errors:
   - any `validate()` hard error (raised) — surface and fix, never work around it;
   - the **verbatim-description lint *warning*** (`validate_and_lint` only
     *appends* a warning when a workspace recipe's description matches a built-in
     verbatim — it does not raise; KTD-6). Treat that warning as blocking: it
     means the distinct-description rule in step 2 was violated. Re-author with a
     distinct description rather than ship a description-spoofing variant.
4. **Dispatch the run-scoped recipe WITH self-teardown:**
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/auto.sh" "<spec> --recipe <builtin>-<run-slug> --teardown-recipe-after-init"`.
   The `--teardown-recipe-after-init` flag makes `auto.py` delete the run-scoped
   workspace recipe **itself, atomically once `init_ledger` returns** — the engine
   is recipe-blind thereafter (`recipe-format.md` §1: pulse, dispatch, predicate,
   and *resume* all operate off the ledger; phase_order / phase_transitions /
   iteration / emit_templates are persisted onto it, never the recipe file). So on
   the success path you do **not** delete it yourself and you do **not** infer
   "ledger initialized" from this command's output — `auto.py` owns it.
5. **Failure-path cleanup (only when step 4 fails before init).** If `auto.sh`
   exits **non-zero** — it crashed *before* `init_ledger`, so its own teardown
   never ran — best-effort delete
   `<repo>/.claude/auto/recipes/<builtin>-<run-slug>.json` yourself (ignore "file
   not found"). This is keyed on the exit code, not a stdout-timing guess. Between
   `auto.py`'s post-init teardown (success) and this exit-code cleanup (failure),
   nothing accumulates in the workspace tier across runs, and a subsequent resume
   of a successful run still drives from the ledger alone. (This is the "inline
   compile-and-run" scope boundary — the run-scoped variant is never a persisted,
   reusable recipe; that is `auto-author-recipe`'s separate save flow.)

## Invariants

- **Interactive-only by construction.** The `driving_session_id` guard (§0)
  routes self-driven / headless runs to silent-apply; they never call `AskUserQuestion` (R11 / AE6).
  This same guard scopes the driver's **goal-aware plan routing** (auto-driver
  `SKILL.md` → `references/goal-plan-relevance-rubric.md`): goal-conditioned
  fanout suppression, match preselect, and the single-match confirm apply on
  interactive runs only. A self-driven / headless launch that reaches this
  chooser silent-applies today's route unchanged — goal-aware suppression never
  engages here, because its safety is the confirm this path deliberately skips.
  The chooser itself needs no rubric logic; the driver has already reshaped the
  route (or left it unchanged) before handing off a single confirmed path.
- **Seed, don't interview.** Always open from the `auto-detect` hypothesis (or a
  degraded fallback drawn from real session signal). Never a blank questionnaire.
- **Rubric-grounded.** Both the shape pick and the gate proposal are grounded in
  the four `auto-design` rubrics by path (above). No live looper dependency.
- **Deterministic-first gating.** A claim that can be a command + check is
  `programmatic`; judges are for what a command genuinely can't decide.
- **The router cross-check gates skip.** A skip is permitted only when
  `router_agrees` — the agent's stem matches `lib/recommender.py`'s pick for the
  classified state. The float remains the discriminator; the router corroborates.
- **The ladder is crisp and elsewhere.** `lib/launch-gate.py` owns skip / confirm
  / two_step; this skill emits the inputs and reads the tier, never re-derives it.
- **The predicate is the spine.** Typed criteria gate; they never become a second
  exit judge. For a1/w the inherent review-to-P3 predicate IS the surfaced gate.
- **No new topology, no hand-written JSON.** The four built-ins plus
  agent-composed customs are the set; every recipe write goes through
  `auto-author-recipe`'s validation gate (via U5 / `auto-design`), never by hand.
