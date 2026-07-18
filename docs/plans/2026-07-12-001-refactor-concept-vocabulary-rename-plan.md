---
title: "Concept-vocabulary rename: adopt CONCEPTS.md terms as code identifiers"
type: refactor
date: 2026-07-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Concept-Vocabulary Rename Plan

## Goal Capsule

Rename `auto`'s historical code identifiers to the canonical vocabulary in
`CONCEPTS.md` — as actual identifiers (files, symbols, JSON keys, CLI verbs,
flags, phase strings, command/skill names, docs), not a glossary overlay:

| old (code) | new | measured refs (py/sh/md/json, case-insensitive) |
|---|---|---|
| `recipe` | `workflow` | 2388 |
| `ledger` | `run_record` (identifier) / "run-record" (prose) | 4276 |
| `unit` | `step` | 4313 (incl. "unit test" noise — see whitelist) |
| `tick` | `pulse` | 1481 |
| `adapter` | `backend` | 1051 |
| `emitter` | `producer` | 715 |
| `seam` (phase) | `handoff` | 646 |
| `orchestrator` | `dispatcher` | 279 |

**Not renamed:** `driver`, `goal`, `phase`, `gate`, `verdict`,
`verification`/`criteria`, the `preset` **term** (already renamed from
`content`) — do not rename `presets.py`, `preset_oneshot.py`, `presets/`,
`preset-format.md`, `auto-preset`; the backend-op *set* semantics, the
`a1`/`a2`/`a4`/`w` stems, `A1_BUILTIN`, and the legible aliases
(`plan-build-review` etc.).

**Preset surface caveat (not a carve-out from the rename):** the preset *term*
stays, but the preset surface is *entangled* with the shared vocabulary it
consumes — its imports and shared-key usage DO update alongside the terms they
consume. Specifically: `presets.py` imports the shared `VALID_ADAPTER_OPS`
(from `adapter_ops`, renamed `VALID_BACKEND_OPS`/`backend_ops` in U4) and
re-exports it, AND imports `recipe_validate`'s primitives
(`_check_prompt_template`, `_validate_recipe_name`, `RecipeError` — `presets.py:56,59-61`,
renamed `workflow_validate`/`WorkflowError` in U8); `preset_oneshot.py` also
imports `recipe_validate`/`RecipeError` (renamed U8); `presets/scoped-build.json`
and `preset-format.md` persist the
shared key/value `invokes.adapter_op: do_unit` (flipped to `backend_op: do_step`
in U6, since the op-set value `do_unit` flips there and `presets.py:196`
validates against it); `tests/unit/presets.test.sh` exercises the shared op-set
symmetry. These follow their source terms into U4/U6/U8 — they are NOT
whitelisted (see U1). Only the preset TERM is left alone.

Done means: full suite green after **every** unit; a vocabulary-audit test
proves no old identifier survives outside an explicit whitelist (compat shim,
alias files, historical plan docs); persisted old-format run-records and
user-authored recipe files still load.

## Problem Frame

`CONCEPTS.md` fixed the public vocabulary but its depth policy deliberately
left code identifiers alone. This plan supersedes that policy (and amends
CONCEPTS.md accordingly): the doc/code split has become its own orientation
tax — every new reader maps two vocabularies.

What makes this risky rather than a sed sweep:

1. **Persisted state speaks the old keys.** Run-records at
   `.claude/auto/<slug>.json` (`units`, `adapter`, `adapter_scale`, `recipe`,
   `seam_paused`, phase string `"seam"`, `phase_transitions[].emitter`,
   `dispatch_context.adapter_op`, producer-name values like
   `plan_output_to_work_units`, exit-reason value `"recipe-bug"`,
   `exit_predicate_result.all_units_terminal`,
   `dispatch_context.winner_unit_id`). User-authored recipe
   files at `<repo>/.claude/auto/recipes/` and `~/.claude/auto/recipes/`
   (`units`, `default_adapter`, `invokes.adapter_op`, `iteration.gate_unit`,
   `phase_transitions[].emitter`, `phase_order` containing `"seam"`).
   In-flight runs also persist the rearm prompt `/auto:auto-tick <run>` inside
   ScheduleWakeup — built solely by `lib/_bootstrap.py::TICK_COMMAND`.
2. **Four contracts are grep-verified LOCKED:** `docs/contracts/adapter-contract.md`,
   `recipe-format.md` (v0.3.0), `ledger-schema.md`, `verification-contract.md`
   (v0.7.0). `preset-format.md` is PROVISIONAL (untouched).
   `agent-tool-surface.md` and `driver-reference.md` are not marked LOCKED.
   The only *runtime-test-enforced* binding here is the **verb registry**:
   `tests/unit/ledger.test.sh` asserts set-equality between `ledger.py describe`
   and `_VERBS` — it binds `describe`↔`_VERBS`, NOT the `agent-tool-surface.md`
   prose (grep `agent-tool-surface` in `tests/` = 0 hits). So the forcing
   function that keeps `agent-tool-surface.md`'s verb table honest is the
   **vocabulary-audit** (docs/contracts are not whitelisted), plus a doc-fence
   added over its verb table in U7. Doc-enforcing tests:
   `tests/unit/doc-fence-ledger-schema.test.sh`, `tests/unit/wikilink-check.test.sh`.
3. **The module DAG is linted.** `tests/unit/import-topology.test.sh` pins
   `ledger_core ← ledger_mutators ← ledger_emitters ← ledger(facade)` and
   `tick ← tick_advance ← tick_guidance` by grepping exact
   `load_lib_module("<name>")` strings. File renames must land with the lint.
4. **~87 test files** (60 unit, 25 integration, 2 smoke) reference everything.
   The runner (`tests/run.sh`) tallies only a file whose last summary line
   matches `^<name>.test.sh(:| results:) N passed, M failed` — a renamed test
   file that still prints its old name is silently mis-tallied.
5. **User-facing surface:** flags `--recipe`/`--adapter` (hand-rolled parser in
   `lib/auto.py::_parse_args`), commands `/auto-tick`, skills `auto-adapter`,
   `auto-author-recipe`, the `lib/ledger.py` CLI verb set (`add-unit`,
   `set-enumerated-units`, …), `.sh` shims agents invoke by path.

## Key Decisions

- **This plan supersedes CONCEPTS.md's "code keeps its identifier" depth
  policy.** CONCEPTS.md is amended in the final unit: the `(code / was)`
  column becomes historical, the depth-policy section is rewritten.
- **Rename the 8 mapped terms only — no derived-term creep.** Verb forms and
  compounds not in the map stay: `emit_templates`, `iteration_emit_count`,
  `expected_emit_outputs`, `emit_within_phase`, `iterate_template` keep "emit"
  (the *producer emits*; "emit" itself was never mapped). `plan_step` /
  `PLAN_STEPS` stay (the plan-phase sub-state — `plan`/`deepen`/`review_plan` —
  is not a workflow step; the collision with the new `step` term is documented
  in CONCEPTS.md rather than renamed away, because renaming it invents
  vocabulary this plan has no mandate for).
- **Stems and aliases stay.** `a1`/`a2`/`a4`/`w`, `A1_BUILTIN`, `_ALIASES`
  legible names, and reserved-alias enforcement are untouched (already pinned
  by `lib/recipes.py` KTD-6).
- **`.claude/auto/` stays.** It is keyed to the plugin name, not a renamed
  concept. Plugin name `auto`, hooks, and `/auto` / `/auto-resume` /
  `/auto-status` commands are unchanged.
- **Historical docs are not rewritten.** `docs/plans/*`, `docs/brainstorms/*`,
  `docs/research/*` keep old vocabulary (whitelisted in the audit). Living
  docs (contracts, skills, commands, README, handoff) are rewritten.

## Key Technical Decisions

### KTD-1 — Persisted-state strategy: read-shim + lazy migration (run-records), read-shim + opt-in migrate verb (workflow files)

**Decision:** No hard cutover. A single new DAG-root module
`lib/format_compat.py` (pure stdlib, imports no sibling) holds two pure,
idempotent upgrade functions:

- `upgrade_run_record(d) -> dict` — wired into **both** run-record read
  chokepoints (skeptic-review verified; there are two, not one):
  `ledger_core._read_json` (shared by `read_ledger` and
  `_with_locked_ledger`) **and** `_bootstrap.load_ledger_safe`
  (`lib/_bootstrap.py:375`, which `iter_worktree_ledgers` wraps — the path
  every hook and scan consumer uses: `on-stop.py` including its batch-sidecar
  sub-run reads, `on-session-start.py`, `on-pretooluse-action.py`,
  `on-pretooluse-askuser.py`, `auto-detect.py`, `auto-resume.py`'s run scan,
  `auto-status.py`'s list-all, `launch-mode.py`). Missing the second wiring
  would break exactly the in-flight population the shim protects — e.g. the
  Stop hook's seam-paused carve-out comparing new `"handoff"` against a
  persisted `"seam"`. Maps old keys/values to new **in memory**. Because
  every mutation already funnels through `_atomic_write` (writes new shape,
  `sort_keys=True`), any old-format record is **lazily migrated on its first
  post-upgrade mutation** — no migration command needed for run-records, and
  read-only consumers see the new shape at both chokepoints, so all code
  outside the shim speaks only new keys.
- `upgrade_workflow(d) -> dict` — wired into `recipes.resolve()` (renamed
  `workflows.resolve()`) immediately after `json.load`, before `validate()`.
  auto never writes user recipe files back, so acceptance of old-key workflow
  files is **indefinite** (cheap: one pure function). An opt-in
  `python3 lib/workflows.py migrate <path>` verb rewrites a file in place
  (atomic write) for users who want their files modernized.

**Key/value map (the complete persisted surface, from recon of
`ledger_core.init_ledger`/`_normalize_unit`, `recipes/schema.json`,
`lib/unit_emitters.py::REGISTRY`, `lib/adapter_ops.py`):**

| old (persisted) | new | lives in |
|---|---|---|
| `units` | `steps` | run-record top-level, workflow top-level |
| `adapter` | `backend` | run-record |
| `adapter_scale` | `backend_scale` | run-record |
| `recipe` (`{name, source_tier}`) | `workflow` | run-record |
| `seam_paused` | `handoff_paused` | run-record |
| `"seam"` (value) | `"handoff"` | `phase_order`, `loop_phase`, `phase_transitions[].from/to`, step `phase` — both artifacts |
| `phase_transitions[].emitter` | `.producer` | both artifacts |
| `plan_output_to_work_units` (value) | `plan_output_to_work_steps` | both (producer names; likewise `judge_winner_to_work_steps`, `brainstorm_output_to_plan_step`; `plan_output_to_paired_builders` unchanged) |
| `dispatch_context.adapter_op` / `invokes.adapter_op` | `backend_op` | run-record / workflow |
| `do_unit` (value) | `do_step` | backend-op value (`brainstorm`, `next_plan_step`, `review` unchanged) |
| `dispatch_context.enumerated_units` | `enumerated_steps` | run-record |
| `default_adapter` | `default_backend` | workflow |
| `iteration.gate_unit` | `gate_step` | both |
| `exit_reason.kind` `"recipe-bug"` | `"workflow-bug"` | run-record |
| `exit_predicate_result.all_units_terminal` | `all_steps_terminal` | run-record (the persisted predicate dict is `{met, blockers, majors, minors, gaps_open, all_units_terminal, iteration_pending}` — `lib/ledger_predicate.py:344`; recomputed on first mutation anyway; mapped for read-only consumers of stale records) |
| `dispatch_context.winner_unit_id` | `winner_step_id` | run-record (A2 judge pick — `lib/ledger_mutators.py:497`) |
| `dispatch_context.dropped_depends_on_edges[].unit` | `.step` | run-record (forensic record — `lib/ledger_mutators.py:481`) |

New-written run-records additionally carry `"format": 2` as a version marker.
**The v1→v2 key/value map is applied UNCONDITIONALLY on every read — never
gated on `format`.** The map is pure, idempotent, and order-independent, so
running it over an already-v2 record is a no-op by construction (no old key is
present to map). The `format` marker gates ONLY hypothetical FUTURE (v3+)
migrations — it must never be used to *skip* the v1→v2 map.

**Why unconditional, not `format>=2` skip (mixed-fleet corruption trap):** if
the map were skipped on `format:2`, a mixed fleet corrupts silently. A renamed
worktree writes a `format:2` record; the still-installed OLD plugin's hooks
fire on the same repo (near-certain when dogfooding on the auto repo itself)
and read the v2 record via `.get("units", [])` → see it empty. Note the exit
predicate does NOT then falsely exit: `lib/ledger_predicate.py:223-225` gates
`met` on a non-empty `units` conjunct (`all_units_terminal AND units`), so an
empty `units` **blocks conservatively** rather than advancing past a `handoff`
pause. The real hazard is on the WRITE side: any old-key write the old code
makes (e.g. `seam_paused: true`) lands in the `format:2` record, and a
`format>=2`-skipping shim would then SKIP that record forever on later reads →
the write is silently lost (the write-skip-forever hole). Applying the map
unconditionally closes that hole — writers may lag readers safely. (The
unconditional-upgrade rationale stands regardless of the block-vs-exit
correction: the write-skip hole alone justifies it.)

**Mixed-fleet cutover step (required):** before any dogfood/smoke on a repo
whose `.claude/auto/` is shared with an installed older plugin, update the
installed plugin to this rename (or explicitly note the window during which the
old plugin must not run against the shared state). This step is **owned by U6**
(a requirement + verification precondition there) and by **Verification
Contract item 6** (a preflight assert that the installed plugin is post-rename
before resuming a pre-rename run on shared state). It is also called out again
in the Risks table.

**Revert safety — `downgrade_run_record(d)`:** `lib/format_compat.py` also
carries the inverse map `downgrade_run_record(d) -> dict` (cheap, pure). If the
rename is reverted to pre-rename code while a `format:2` record is stranded on
disk, the old code's `.get("units", [])` reads empty and misbehaves silently;
the documented revert procedure is to run `downgrade_run_record` over the
stranded records (an opt-in `python3 lib/run_record.py downgrade <path>` verb,
mirrored on the workflow side) BEFORE reinstalling pre-rename code. This makes
U6 a reversible door, not a one-way one (see the Risks row "U6 one-way
door / revert").

**Revert requires quiescence.** Ordering (downgrade → reinstall) is necessary
but not sufficient: the downgrade must run against a **quiesced** state dir — no
live sessions or hooks firing against `.claude/auto/` between the downgrade and
the reinstall. Because run-records lazy-migrate to v2 on their first post-upgrade
mutation, any new-code hook that fires in that window re-upgrades a just-downgraded
record back to v2, silently undoing the downgrade. `downgrade_run_record` writes
under the **run-record flock** (the same lock every mutation holds), so it never
races a concurrent in-process write — but a quiesced state dir is still required
so nothing re-upgrades behind it. The downgrade **removes the `format` marker**
(so reinstalled old code never sees an unknown version field). Consequently
`downgrade` is an **offline / quiesced operation**: driving it against a live
flocked run is the same race class this plan rejects for one-shot migration
(see KTD-1 "Why not one-shot migration"), so it is deliberately not an
online tool.

**Map semantics — stale-twin drop + per-item producer/emitter:** after mapping
an old key to its new key, the stale old twin is **dropped** (not passed
through), so a mapped record can never carry both `units` and `steps`
(reconciles the "new key wins" of scenario 7 with the "pass unknown keys
through untouched" data-loss mitigation: genuinely-unknown keys still pass
through; only a *mapped* old twin is removed). Where both twins are present on
input (partial hand-edit), the **new** key's value wins and the old twin is
dropped. `phase_transitions[]` is handled per item: an item may carry
`.emitter` and/or `.producer` — map/drop per item, not per array.

**Agent-facing (raw-file) reads route through the shim.** The file-level shim
covers code paths, but a model told to `Read .claude/auto/<run>.json` directly
(e.g. `auto-author-workflow`'s reverse-derive) bypasses it — and
completed/abandoned runs never mutate, so they stay v1 on disk forever. Agent
prose that reads a run-record for its own inspection routes through
`python3 lib/run_record.py read <repo> <run>` (which returns shim-upgraded v2
JSON) instead of the raw Read tool; the reverse-derive skill prose is updated
to say so (U8). This is the model-side read surface the file-level shim does
not otherwise reach.

**Why not hard cutover:** in-flight runs (ledger + persisted ScheduleWakeup
rearm prompts) would wedge mid-run, and user-authored recipe files would break
silently at next `/auto`. **Why not one-shot migration tool as the primary
mechanism:** run-records are written under flock by many entry points (hooks,
tick, CLI); a migration that races a live run is exactly the corruption class
`_with_locked_ledger` exists to prevent. The read-shim upgrades under the same
flock the mutation holds — no new race.

### KTD-2 — Identifier form: `run_record`

`run_record` (snake_case) for Python modules, symbols, and any JSON: it
matches the existing underscore module family (`ledger_core`,
`ledger_mutators`, …), Python modules cannot contain hyphens, and it greps
cleanly. `run-record` (hyphen) for prose, doc filenames
(`run-record-schema.md`), and human-facing text. `runrecord` rejected: loses
greppability and reads worse. The `.sh` shim follows its module:
`lib/run_record.sh` (the repo already mixes `ledger.sh` and `adapter-ce.sh`;
module-mirroring wins for the facade family).

### KTD-3 — Filenames rename (git mv), not keep

Half-renamed trees (new symbols in old files) are a permanent comprehension
tax — the opposite of this plan's point. `load_lib_module("<name>")` loads by
string, so renames are mechanical and the import-topology lint pins the new
names in the same commit. Full file map:

| old | new | unit |
|---|---|---|
| `lib/orchestrator.py` / `.sh` | `lib/dispatcher.py` / `.sh` | U2 |
| `lib/adapter-ce.py`/`.sh`, `lib/adapter-native.py`/`.sh`, `lib/adapter_ops.py` | `backend-ce.*`, `backend-native.*`, `backend_ops.py` | U4 |
| `lib/tick.py`/`.sh`, `tick_advance.py`, `tick_guidance.py` | `pulse.py`/`.sh`, `pulse_advance.py`, `pulse_guidance.py` | U5 |
| `lib/unit_emitters.py` | `lib/step_producers.py` | U7 (carries two mapped terms; final name lands once, at the step unit) |
| `lib/recipes.py`, `lib/recipe_validate.py`, `lib/recipes-list.sh`, `recipes/` (builtin dir) | `workflows.py`, `workflow_validate.py`, `workflows-list.sh`, `workflows/` | U8 |
| `lib/ledger.py`/`.sh`, `ledger_core.py`, `ledger_mutators.py`, `ledger_emitters.py`, `ledger_predicate.py`, `ledger_steering.py` | `run_record.py`/`.sh`, `run_record_core.py`, `run_record_mutators.py`, `run_record_producers.py`, `run_record_predicate.py`, `run_record_steering.py` | U9 (`ledger_emitters` carries two terms; final name lands at the run-record unit) |
| `docs/contracts/adapter-contract.md`, `recipe-format.md`, `ledger-schema.md` | `backend-contract.md`, `workflow-format.md`, `run-record-schema.md` | U4 / U8 / U9 |
| skills `auto-adapter/`, `auto-author-recipe/` | `auto-backend/`, `auto-author-workflow/` | U4 / U8 |
| `commands/auto-tick.md` | `commands/auto-pulse.md` (+ alias, KTD-4) | U5 |
| test files carrying a term (e.g. `orchestrator.test.sh`, `tick*.test.sh`, `recipe-*.test.sh`, `ledger*.test.sh`, `unit-emitters.test.sh`, `seam-default.test.sh`, `adapter-severity.test.sh`) | renamed with their unit | each unit |

Two-term filenames (`unit_emitters.py`, `ledger_emitters.py`) get their final
name in the unit that owns their *family* (step, run-record) — one rename per
file, documented in that unit, rather than two moves.

### KTD-4 — Flag/command/verb aliasing: alias what is persisted or muscle-memory; hard-cut what is not

- **Flags (`lib/auto.py::_parse_args`, hand-rolled):** canonical `--workflow`,
  `--backend`, `--teardown-workflow-after-init`; old spellings (`--recipe`,
  `--adapter`, `--teardown-recipe-after-init`) accepted as deprecated aliases
  emitting one stderr notice. Cheap (three `if tok ==` branches), removed next
  minor. The legacy `auto` positional and `--review-plan` are untouched.
- **Commands:** `commands/auto-pulse.md` is canonical;
  `_bootstrap.TICK_COMMAND` becomes `PULSE_COMMAND = "/auto:auto-pulse"` (the
  single builder of rearm prompts — recon-verified sole constructor).
  `commands/auto-tick.md` is **kept as a thin alias** (same body, invokes
  `lib/pulse.sh`) because in-flight runs have `/auto:auto-tick <run>` persisted
  inside ScheduleWakeup and in stale rearm-intent JSON. Removal deferred one
  minor version.
- **Skills:** directories renamed (`auto-backend`, `auto-author-workflow`); no
  alias dirs (the marketplace would ship duplicates). Each renamed skill's
  description gains "(formerly auto-adapter)" so model-side triggering keeps
  matching old phrasing.
- **`run_record.py` CLI verbs:** `add-unit` → `add-step`,
  `set-enumerated-units` → `set-enumerated-steps`; **no aliases**. Verbs are
  never persisted (recon: only the pulse command string is persisted); callers
  are this repo's skills (updated atomically) and driving agents, which the
  agent-tool-surface contract explicitly instructs to orient via
  `describe` — whose payload is regenerated from the `_VERBS` registry, so the
  set-equality test forces docs and dispatch to move together.
- **Entry-point shims:** `lib/ledger.py`, `lib/ledger.sh`, `lib/tick.sh`,
  `lib/orchestrator.sh`, `lib/adapter-ce.sh`, `lib/adapter-native.sh`,
  `lib/recipes-list.sh` are paths agents may have memorized from older skill
  prose. The `.sh` shims keep 2-line forwarding stubs (exec the new file +
  stderr deprecation note) for one minor version, whitelisted in the audit.
  **`lib/ledger.py` is different — it must be a module-importable re-export
  shim, NOT a bare CLI-exec stub.** `lib/cmux-socket.sh` (~:77 and ~:265) does
  `importlib.util.spec_from_file_location("ledger", .../ledger.py)` then calls
  `L.ledger_path(...)`, all wrapped in `except: sys.exit(0)`. A CLI-exec-only
  stub never defines `ledger_path` under `exec_module`, so the exception is
  swallowed and the runaway-spawn sentinel / double-drive guard silently fails
  open. The `ledger.py` stub therefore re-exports the public surface of
  `run_record.py` (`ledger_path`, the CLI entry, etc.) so
  `spec_from_file_location` + symbol access still resolve. (U9 also repoints
  cmux-socket's two `spec_from_file_location` sites + symbol calls to
  `run_record.py` — the stub is the belt, the repoint is the suspenders.)
  `.py` module stubs beyond `ledger.py` are not kept — the remaining
  `load_lib_module` callers are all in-repo and updated atomically.

### KTD-5 — Re-lock protocol for LOCKED contracts

Of the four grep-verified LOCKED contracts, only **three are schema-bearing
and rename**: `adapter-contract.md`→`backend-contract.md` (U4),
`recipe-format.md`→`workflow-format.md` (U8), `ledger-schema.md`→
`run-record-schema.md` (U9). These three own a renamed term, get a new
filename, and are re-locked per the protocol below.

The fourth, `verification-contract.md` (v0.7.0), is **LOCKED-but-untouched**:
its own terms (`verification`/`criteria`) are in the "Not renamed" set, no unit
(U2–U10) owns it, and it gets no new name or version bump. It DOES contain
incidental cross-references to renamed terms (e.g. "recipe gate unit" in its
prose); those get prose updates at first touch (KTD's free-prose rule below),
with **no re-lock, no rename, no version bump** — a prose cross-reference edit
does not disturb its LOCKED state.

A schema-bearing LOCKED contract is never left un-LOCKED across a unit
boundary. Each of the three renaming contracts is re-locked exactly once,
inside the unit that owns its term, in one commit that contains all of:

1. Prose + pinned-identifier rewrite, `git mv` to the new filename.
2. Version bump in the status banner: `LOCKED v0.14.0 — vocabulary rename;
   supersedes <old name> <old version>`, plus a short changelog line.
3. A **"Legacy keys (read-compat)" appendix**: the old→new table from KTD-1
   scoped to that contract, stating the shim guarantee ("old keys accepted on
   read indefinitely / until <version>; always written new").
4. The enforcing tests updated in the same commit: doc-fence
   (`doc-fence-ledger-schema.test.sh` → `doc-fence-run-record-schema.test.sh`,
   fences re-pointed), `wikilink-check.test.sh` (all inbound `[[links]]` and
   relative links to the renamed file), and the `describe` set-equality test
   where the contract mirrors a CLI surface.
5. Re-assert LOCKED at the top (same commit — the "unlock" never exists in
   history as a standalone state).

Cross-term references inside a not-yet-renamed contract (e.g.
`workflow-format.md` mentioning "ledger" before U9) are updated to the new
*prose* terms at first touch — prose is free; only key/identifier tables must
match the code at that boundary.

### KTD-6 — On-disk key cutover is one atomic unit (U6), decoupled from code-symbol renames

Persisted keys entangle three contracts and every term at once
(`invokes.adapter_op` alone touches adapter/backend, unit/step via `do_unit`,
and the recipe/workflow file format). Renaming keys per-term would mean four
partial shim states, four fixture matrices, and thrice re-locked contracts.
Instead: **U6 flips every persisted key/value literal in one unit** — the
KTD-1 map, the shim, the fixtures, and the schema tables of all three
schema-bearing contracts land together. Code-symbol renames (function names,
module files, flags, prose) are per-term units around it and never change
bytes on disk. Consequence: a contract's *file rename* may land in a later
unit than its *key table* update; the full re-lock ceremony (KTD-5 — filename
`git mv` + banner supersedes-line) happens once, at the file-rename unit, with
the key table already current.

**Version-label integrity across the U6→U8/U9 gap:** U6 rewrites the normative
key tables of `recipe-format.md` and `ledger-schema.md`, but their file rename
+ full re-lock don't land until U8/U9. To avoid one version label denoting two
different normative texts, **each of these two contracts gets a version bump at
U6** (the content re-lock — new key table = new normative content = new
version, with a changelog line), and the U8/U9 file-rename carries a second,
trivial version bump (rename-only). `backend-contract.md` re-locks fully in U4
(its owning unit) but its key *appendix* is completed in U6 — so it too takes a
content bump at U6. Every intermediate banner therefore names a version whose
normative text actually matches the bytes in the file at that boundary.

### KTD-7 — Workspace/global tier dir: `recipes/` → `workflows/` with legacy fallback

`_tier_dirs` (both the workflows registry and its callers) returns the new
dirs first with the old ones appended as legacy tiers:
`workspace-workflows → workspace-recipes(legacy) → global-workflows →
global-recipes(legacy) → built-in`. First-wins semantics preserved;
`workspace_workflow_path()` (writes) targets only the new dir. The builtin
repo dir `recipes/` is `git mv`'d to `workflows/`
(`recipe_validate._BUILTIN_DIR` updated). `presets/` tiers untouched.

## High-Level Technical Design

Rename-execution sequence — cheap, unlocked, code-only terms first to prove
the mechanics; the single persisted-format cutover in the middle; the deeply
locked, high-footprint families last, operating on already-new keys:

```
U1  audit harness            vocabulary-audit test (all terms "pending")
 │
U2  orchestrator→dispatcher  code-only, no locks        [pattern validation]
U3  emitter→producer         code symbols only
 │
U4  adapter→backend          code + flags + skill + backend-contract re-lock
U5  tick→pulse               code + command alias + PULSE_COMMAND
 │
U6  FORMAT v2 CUTOVER        format_compat shim + every persisted key/value
 │                           + seam→handoff literals + fixtures
 │                           + key tables in 3 contracts
 │
U7  unit→step                code symbols + CLI verbs + agent-tool-surface
U8  recipe→workflow          modules + dirs + skill + workflow-format re-lock
U9  ledger→run_record        module family + facade + CLI + run-record-schema
 │                           re-lock + doc-fence + DAG lint family
 │
U10 prose sweep + CONCEPTS.md + audit all-green + alias-removal follow-up note
```

Dependencies: U2–U5 depend only on U1 and are mutually independent (run
sequentially anyway — each ends with a full-suite gate). U6 depends on U4/U5
only for vocabulary hygiene (its code literals reference backend/pulse
symbols); U7–U9 depend on U6 (their test-fixture rewrites assume new keys —
avoids rewriting fixtures twice). U10 depends on all.

Invariant at every unit boundary: `bash tests/run.sh` fully green, total test
count accounted for (renames tracked, none silently dropped by the
summary-line tally), and the vocabulary-audit table updated (the unit's term
flipped from `pending` to `done`).

## Implementation Units

Common **Execution note for all units:** these are mechanical,
characterization-first renames. Before touching a unit's subsystem, run the
full suite and record the pass count; after, the suite must be green with the
same count (plus tests the unit deliberately adds). Renamed test files must
print their **own new filename** in the summary line (`<new>.test.sh: N
passed, M failed`) or the runner mis-tallies — verify each renamed file solo
(`bash tests/unit/<new>.test.sh`) before the suite run. New guard tests get
the deliberate-fail smoke check (break via Edit, watch red, revert via Edit).
Commits use `refactor:`; one unit = one commit (or a small stack), suite green
at each.

### U1 — Vocabulary-audit harness

- **Goal:** a deterministic, whitelisting grep-audit that pins rename progress
  and becomes the permanent "no old identifier survives" guard.
- **Requirements:** `tests/unit/vocabulary-audit.test.sh` with a per-term
  status table (`orchestrator=pending`, …). For a `done` term, the test fails
  if the old identifier appears outside the whitelist. `pending` terms are not
  checked. Word-boundary grep, case-aware (catch `Ledger`, `LEDGER_`,
  `ledger`).

  **Canonical permanent whitelist** (U1, U10, and Verification-Contract item 2
  MUST all state this same list):
  1. `lib/format_compat.py` (the one module that legitimately speaks both
     vocabularies).
  2. ALL forwarding stubs (KTD-4): `lib/ledger.py`, `lib/ledger.sh`,
     `lib/tick.sh`, `lib/orchestrator.sh`, `lib/adapter-ce.sh`,
     `lib/adapter-native.sh`, `lib/recipes-list.sh`.
  3. `commands/auto-tick.md` (the kept alias command).
  4. `docs/plans/`, `docs/brainstorms/`, `docs/research/` (historical docs).
  5. CONCEPTS.md's historical `(code / was)` column.
  6. `tests/unit/` **path** + the prose "unit test(s)" (the `unit`-term noise).
  7. CHANGELOG-style notes (the "supersedes … / formerly …" changelog lines).
  8. The KTD-4 flag-alias branches in `lib/auto.py::_parse_args` — the
     `--recipe` / `--adapter` / `--teardown-recipe-after-init` token literals +
     their one-line deprecation strings.
  9. The renamed skills' `"(formerly auto-adapter)"` /
     `"(formerly auto-author-recipe)"` description breadcrumbs.

  **`plan_step`/`PLAN_STEPS`/`next_plan_step` are NOT whitelist entries.** They
  contain no *old* renamed identifier (`plan` isn't renamed; `step` is the
  *new* term; neither contains `unit`), so they cannot trip the old-term audit
  and need no whitelist. They are recorded only as a "don't rename" carve-out
  in Key Decisions / CONCEPTS.md (F15a).

  **The preset surface is NOT whitelisted.** Do not blanket-whitelist
  `presets.py` / `presets/` — that would blind the audit to the genuinely
  shared `adapter_op` / op-set that the preset surface consumes and that MUST
  flip in U4/U6. Only the preset *term* is out of scope; the shared keys inside
  the preset files are audited like any other consumer.

  **Term-specific TEMPORARY whitelists** (removed as their owning unit lands):
  before U6, persisted old keys/values (`adapter`, `emitter`, `unit`, `recipe`,
  `seam`) still live on disk and in fixtures — each term carries a documented
  temporary entry (e.g. `unit` → `units-json` CLI arg help until U7; the
  persisted registry values until U6) that its unit removes.
- **Dependencies:** none.
- **Files:** `tests/unit/vocabulary-audit.test.sh` (new).
- **Approach:** same shape as `wikilink-check.test.sh` (grep-checkable
  deterministic defense). Whitelist is explicit paths + patterns, no
  wildcard-by-default.
- **Test scenarios:** (1) all terms pending → passes on current tree;
  (2) flip `orchestrator=done` before U2 → fails, names offending files
  (deliberate-fail smoke); (3) summary line matches the runner tally regex.
- **Verification:** full suite green; audit file itself tallied by
  `tests/run.sh unit`.

### U2 — `orchestrator` → `dispatcher` (pattern validation)

- **Goal:** first end-to-end module rename on the cheapest term (279 refs,
  no persisted keys — recon: no `"orchestrator"` JSON key exists; no locked
  contract owns it).
- **Requirements:** `git mv lib/orchestrator.py lib/dispatcher.py` (+ `.sh`);
  rename internal symbols and CLI `prog`; keep `lib/orchestrator.sh` as a
  forwarding stub (KTD-4). Update every `load_lib_module("orchestrator")`
  call site; rename `tests/unit/orchestrator.test.sh` →
  `dispatcher.test.sh`; update skill prose
  (`skills/auto/SKILL.md` cites `orchestrator.should_escalate`), commands,
  `driver-reference.md` mentions, `plugin.json` description sentence.
  `VALID_ADAPTER_OPS` re-export keeps its (old) name until U4 — terms stay in
  their own unit.
- **Dependencies:** U1.
- **Files:** `lib/orchestrator.py→lib/dispatcher.py`, `lib/orchestrator.sh`
  (stub) + `lib/dispatcher.sh`, `lib/execution_tree.py` (the sole functional
  `load_lib_module("orchestrator")` call site, `:61` + symbol bindings `:67-69`;
  `lib/auto.py`/`lib/tick*.py` carry comment mentions only — but the grep sweep,
  not this list, is the coverage authority),
  `skills/auto/SKILL.md`, `skills/auto-driver/SKILL.md`,
  `docs/contracts/driver-reference.md`, `docs/contracts/agent-tool-surface.md`
  (prose), `docs/contracts/preset-format.md` (its `:92,96` prose "must not
  import `lib/orchestrator.py`" → `dispatcher.py`),
  `tests/unit/dispatcher.test.sh`, `tests/unit/import-topology.test.sh` —
  **not just the consumer-list comment: re-point the FUNCTIONAL forbidden-edge
  check** `loads_sibling "presets.py" "orchestrator"` (`:129`, the KTD-2 leaf
  boundary) to `"dispatcher"`. Left un-repointed, that negative grep passes
  *vacuously* forever after the rename (nothing named `orchestrator` exists),
  silently un-enforcing the boundary — the same vacuous-negative-grep class F13
  fixes. `.claude-plugin/plugin.json`. **Also the live test
  references** (would go red if missed): `tests/unit/presets.test.sh:100`
  (`load_lib_module("orchestrator")` + symmetry-test naming),
  `tests/unit/ledger.test.sh`, `tests/unit/tick*.test.sh`, and integration
  `auto-chain`, `tree-dispatch`, `recipe-picker`, `review-recipe` — KTD-4
  keeps no `.py` module stubs, so every loader string flips here.
- **Approach:** mechanical; grep-driven sweep of `orchestrator` under
  `lib/ skills/ commands/ docs/contracts/ tests/` excluding whitelist — the
  grep sweep, not the file list above, is the authority on coverage.
- **Test scenarios:** (1) `python3 lib/dispatcher.py <subcommand>` verb
  surface unchanged vs old (capture before/after `usage` + one
  `should_escalate` path); (2) forwarding stub execs and prints deprecation
  to stderr, exit code passthrough; (3) renamed test file solo-run prints
  `dispatcher.test.sh: N passed, 0 failed`; (4) audit flipped
  `orchestrator=done` passes; (5) **file-existence assertion** — add to
  `import-topology.test.sh` a positive `[ -f "$LIB/dispatcher.py" ]` check for
  the pinned module. Its DAG greps are all NEGATIVE (forbidden-edge) and pass
  *vacuously* on a nonexistent (mis-renamed) file, so a forgotten lockstep lint
  update would go green by accident; the existence assert makes it go red;
  (6) **re-pointed forbidden edge fires** — deliberate-fail smoke: add a
  `load_lib_module("dispatcher")` line to `presets.py` via Edit, watch the
  re-pointed `loads_sibling "presets.py" "dispatcher"` check go red, revert.
  (Proves the boundary is still enforced against the NEW module name, not
  vacuously green against the vanished `orchestrator`.)
- **Verification:** full suite green, same pass total; audit green.

### U3 — `emitter` → `producer` (code symbols only)

- **Goal:** rename the emitter *role* vocabulary in code; persisted
  `phase_transitions[].emitter` key and producer-name values wait for U6.
- **Requirements:** in `lib/unit_emitters.py` (file rename deferred to U7,
  KTD-3): module docstring, `REGISTRY` comment prose, `resolve()` error text;
  `recipe_validate.V1_EMITTER_NAMES` → `V1_PRODUCER_NAMES` (with re-export in
  `recipes.py` updated + its symmetry test); `ledger_emitters.py` docstring/
  symbol prose where "emitter" names the role; skills/contract prose. The
  registry **keys** (`plan_output_to_work_units`, …) and the JSON key
  `emitter` are untouched here (U6). `emit_*` names stay permanently (Key
  Decisions).
- **Dependencies:** U2 (sequence only).
- **Files:** `lib/unit_emitters.py`, `lib/recipe_validate.py`,
  `lib/recipes.py`, `lib/ledger_emitters.py`, `lib/tick_advance.py`,
  `recipes/schema.json` description strings only (the `emitter` property name
  stays until U6), `docs/contracts/recipe-format.md` prose (term first-touch,
  KTD-5 note), `tests/unit/unit-emitters.test.sh`,
  `tests/unit/recipes.test.sh` (symmetry assertion symbol).
- **Approach:** symbol/prose sweep; leave a `V1_EMITTER_NAMES =
  V1_PRODUCER_NAMES` module alias out — update the two consumer sites instead
  (both in-repo).
- **Test scenarios:** (1) symmetry test now asserts
  `workflows.V1_PRODUCER_NAMES == step-producer REGISTRY keys` and stays
  green; (2) `resolve("nope")` error message says "unknown producer";
  (3) audit `emitter=done` (whitelist: the persisted key + registry values
  until U6, then narrowed).
- **Verification:** full suite green; audit green with the documented
  temporary whitelist entries.

### U4 — `adapter` → `backend` (code + flags + skill + contract re-lock)

- **Goal:** rename the pluggable-toolchain term everywhere except persisted
  bytes.
- **Requirements:** `git mv` `adapter-ce.*`, `adapter-native.*`,
  `adapter_ops.py` → `backend-*`, `backend_ops.py`; forwarding stubs for the
  two `.sh` entry points; `VALID_ADAPTER_OPS` → `VALID_BACKEND_OPS` — this is
  **three** sites, not two: the `backend_ops.py` (was `adapter_ops.py`)
  definition, the `dispatcher.py` re-export, AND the `presets.py:62` re-export
  (the preset surface imports the shared op-set and re-exports it), plus the
  op-set symmetry test in `tests/unit/presets.test.sh`; `init_ledger(adapter=…,
  adapter_scale=…)` kwargs → `backend=`/`backend_scale=` (in-repo callers
  only; the *persisted* `adapter`/`adapter_scale` keys and
  `dispatch_context.adapter_op` reads stay old-key until U6 — the code writes
  old keys from new kwargs in the interim); `--backend` flag + `--adapter`
  alias (KTD-4); skill `auto-adapter` → `auto-backend` (description notes
  former name); `adapter-contract.md` → `backend-contract.md` re-locked per
  KTD-5 with an explicit banner note "JSON keys rename lands with format v2
  (U6); key table below shows current-on-disk (v1) names" — the appendix is
  completed in U6; `default_adapter` in `recipes/schema.json` untouched
  (U6); tests `adapter-severity.test.sh` → `backend-severity.test.sh`.
- **Dependencies:** U3 (sequence only — U2–U5 are mutually independent per the
  HTD; each ends with a full-suite gate).
- **Files:** `lib/adapter-ce.py→backend-ce.py` (+native, +ops, + `.sh` pairs
  and stubs), `lib/auto.py` (`_DEFAULT_ADAPTER`→`_DEFAULT_BACKEND`,
  `_parse_args`), `lib/orchestrator→dispatcher.py` consumer line,
  `lib/ledger_core.py` kwargs + validation-message text,
  `skills/auto-adapter/→skills/auto-backend/`, `skills/auto/SKILL.md`,
  `docs/contracts/backend-contract.md`, `lib/presets.py` (the `:62` re-export
  of `VALID_BACKEND_OPS` — its import moves from `adapter_ops` to `backend_ops`;
  the preset TERM is untouched), `tests/unit/backend-severity.test.sh`,
  `tests/unit/presets.test.sh`, `tests/unit/import-topology.test.sh`.
- **Approach:** the interim "new kwargs, old on-disk keys" seam is exactly two
  literals in `init_ledger`'s dict build + `_normalize_unit` reads —
  annotated `# format-v1 key; flips in U6` so U6 is a grep for that marker.
- **Test scenarios:** (1) `--adapter native` and `--backend native` produce
  identical ledger, alias prints deprecation to stderr; (2) unknown backend
  value error text updated; (3) symmetry test `backend_ops.VALID_BACKEND_OPS
  == dispatcher.VALID_BACKEND_OPS` green; (4) contract doc-links pass
  wikilink-check after the `git mv`; (5) audit `adapter=done` with U6
  whitelist for persisted keys; (6) **file-existence assertion** in
  `import-topology.test.sh` for each pinned renamed module
  (`backend-ce.py`/`backend-native.py`/`backend_ops.py`) so the negative-grep
  DAG checks can't pass vacuously on a mis-renamed file (F13).
- **Verification:** full suite green; re-lock commit contains all KTD-5
  items.

### U5 — `tick` → `pulse` (code + command surface)

- **Goal:** rename the loop-advance term including the user-facing command,
  without breaking persisted rearm prompts.
- **Requirements:** `git mv` `tick.py→pulse.py`, `tick_advance.py→
  pulse_advance.py`, `tick_guidance.py→pulse_guidance.py`, `tick.sh→pulse.sh`
  (+ forwarding stub `tick.sh`); import-topology lint: pulse family edges
  (`pulse ← pulse_advance ← pulse_guidance` mirrors the pinned tick DAG);
  `_bootstrap.TICK_COMMAND` → `PULSE_COMMAND` = `/auto:auto-pulse` (sole rearm
  builder — recon-verified); `commands/auto-pulse.md` canonical +
  `commands/auto-tick.md` alias (KTD-4); `/auto-status`, skills, and
  `agent-tool-surface`/`driver-reference` prose (`rearm` intent examples);
  `--auto` tick flag et al. unchanged in meaning; rename `tick*.test.sh`
  → `pulse*.test.sh` and `seam-default.test.sh` content references later
  (U6). Ledger keys touched by tick (`active_wall_seconds`, `loop.last_beat_at`)
  carry no renamed term — verified, no format impact.
- **Dependencies:** U4 (sequence only — U2–U5 are mutually independent per the
  HTD; each ends with a full-suite gate).
- **Files:** `lib/tick*.py→pulse*.py`, `lib/tick.sh` (stub) + `pulse.sh`,
  `lib/_bootstrap.py`, `lib/auto-resume.py`, `lib/ledger.py`
  (`_TOOL_SURFACE_PREAMBLE` rearm string), `commands/auto-pulse.md`,
  `commands/auto-tick.md` (alias), `skills/auto/SKILL.md`,
  `skills/auto-driver/SKILL.md`, `docs/contracts/agent-tool-surface.md`,
  `docs/contracts/driver-reference.md`, `tests/unit/pulse*.test.sh`,
  `tests/unit/import-topology.test.sh`, **plus the two tests hardcoding the
  old surface**: `tests/integration/hooks.test.sh:403` (asserts the literal
  prompt `/auto:auto-tick contrun` — flips to the pulse prompt) and
  `tests/smoke/scaffold.test.sh:115` (asserts `auto-tick.md` invokes
  `tick.sh` — flips to assert both command files hit `pulse.sh`).
- **Test scenarios:** (1) a rearm intent emitted by `pulse.py` carries
  `/auto:auto-pulse <run>`; (2) `commands/auto-tick.md` alias body invokes
  `lib/pulse.sh` (grep-assert, mirroring `rearm-command-exists.test.sh` which
  must now check both command files); (3) DAG lint red if `pulse_guidance`
  gains a `pulse_advance` import (deliberate-fail smoke on the new lint
  lines); (4) renamed tests solo-run tally correctly; (5) audit `tick=done`
  (whitelist: alias command file); (6) **file-existence assertion** in
  `import-topology.test.sh` for the pinned pulse family (`pulse.py`,
  `pulse_advance.py`, `pulse_guidance.py`) so the negative-grep DAG checks can't
  pass vacuously on a mis-renamed file (F13); (7) **automated** fixture test
  (not just manual smoke): the `auto-tick.md` alias command driving an in-flight
  run record end-to-end still advances — at U5 the record is still v1; once U6's
  shim lands this same test also exercises the alias-command + pre-U6 v1 record
  path (the additional-testing gap this closes).
- **Verification:** full suite green; the automated in-flight-run test above
  (init a run, emit rearm, invoke the OLD command path) advances — no longer a
  manual-only smoke.

### U6 — Format v2 cutover: persisted keys/values + `seam` → `handoff` + compat shim

- **Goal:** the single on-disk vocabulary flip (KTD-1/KTD-6), with
  backward-compat proven by fixtures.
- **Requirements:**
  - `lib/format_compat.py` (new, DAG root): `upgrade_run_record`,
    `upgrade_workflow`, plus the inverse `downgrade_run_record` /
    `downgrade_workflow` (KTD-1 revert-safety), the KTD-1 map, idempotent,
    pure, order-independent. The upgrade map is applied **unconditionally on
    every read** (never gated on `format`) per KTD-1. Import-topology lint
    gains the allowed edges `ledger_core → format_compat`,
    `_bootstrap → format_compat` (for `load_ledger_safe` — KTD-1's second
    chokepoint), `workflows → format_compat` at resolve (until U8 that
    module is `recipes.py`), and `recipe_validate → format_compat` (the F5
    write-gate shim wired inside `validate_and_lint`). The DAG lint is
    forbidden-edge/negative-grep, so a missing allowed-edge note won't turn it
    red — this fourth edge is a doc-accuracy entry so the documented DAG matches
    the actual wiring.
  - **Stamping-order is no longer a corruption hazard.** Because the upgrade is
    unconditional and pure, a writer that stamps `"format": 2` before/after a
    reader runs the map is harmless — writers may lag readers safely. (This
    retires the red-green stamping-order concern: there is no window in which a
    stamped-but-unmapped record is skipped.)
  - Wire the shim into **both** read chokepoints: `ledger_core._read_json`
    and `_bootstrap.load_ledger_safe` — the latter covers the hook/scan
    family (on-stop incl. sidecar sub-run reads, on-session-start,
    on-pretooluse-*, auto-detect, auto-resume scan, auto-status list,
    launch-mode).
  - Flip every key/value literal per the KTD-1 table across `lib/` (including
    the `# format-v1 key` markers from U4), `recipes/*.json` builtins
    (`phase_order` `"seam"`→`"handoff"`, `units`→`steps`,
    `adapter_op`→`backend_op`, `default_adapter`→`default_backend`,
    `emitter`→`producer`, producer-name values), `recipes/schema.json`
    (property names + `$defs.unit`→`$defs.step`), `A1_BUILTIN`,
    `LOOP_PHASES`/`_DEFAULT_PHASE_ORDER` (`"handoff"`), `seam_paused`
    handling in `tick→pulse.py`, `ExitReason.RECIPE_BUG` **value** →
    `"workflow-bug"` (symbol renames in U8), predicate field names in
    `ledger_predicate.py`, `ledger.py` `describe` payload text, hooks
    (`on-stop.py`, `on-session-start.py`) reads.
  - **Preset persisted surface (F1).** The shared op-set value `do_unit`→
    `do_step` flips here (the op-set the preset surface consumes and that
    `presets.py:196` validates against). So the persisted preset keys/values
    flip with it: `presets/scoped-build.json` (`invokes.adapter_op`→`backend_op`,
    value `do_unit`→`do_step`, and the `do_unit` mention in its `description`);
    `docs/contracts/preset-format.md`'s key table + its `do_unit` pin in the
    closed-set line. The preset *term* stays; only the shared key/value it
    carries flips. (`preset-format.md` is PROVISIONAL, not one of the three
    re-locked contracts — a plain prose/table edit, no re-lock.)
  - `resolve()` → `upgrade_workflow`; `_atomic_write` stamps `"format": 2`.
  - **Authoring / WRITE-path shim (F5).** The read chokepoints protect
    `resolve()`, but the *write* gate does not go through them: a model
    following authoring-skill prose (`auto-author-recipe` etc., not renamed
    until U8) hands `recipe_validate.validate_and_lint` a v1-keyed draft
    (`iteration.gate_unit`), which — after this unit flips the validator to
    expect `gate_step` — rejects it. Fix by wiring `upgrade_workflow` into the
    write gate `validate_and_lint` so it validates an **internally-upgraded
    copy** of the draft. This does **NOT** change `validate_and_lint`'s return
    signature — it still returns the warnings **list** (`recipe_validate.py:835`),
    consistent with KTD-1's "upgrade functions are pure, no in-place mutation of
    the caller's draft." Consequence: a skill-authored workflow file may persist
    **v1-keyed on disk** (the shim never rewrites the caller's draft), which is
    SAFE because `upgrade_workflow` read-compat via `resolve()` is indefinite
    (KTD-1) — the file upgrades in-memory every time it is later resolved. This
    is one seam (the shim) rather than chasing every authoring-skill prose
    example across `auto-author-recipe`/`auto-design`/`auto-launch`, and it
    composes with the U8 skill-prose flip. (NB: the earlier plan's `skills/auto-launch/SKILL.md:281`
    citation was wrong — that line is failure-path cleanup that *deletes* a
    run-scoped recipe file, with no embedded JSON shape to flip; there is no
    embedded-shape authoring surface in auto-launch. The write-gate shim is the
    correct fix.)
  - `workflows migrate <path>` CLI verb (on `recipes.py` for now; renamed
    with U8).
  - Fixtures (all under `tests/fixtures/format-v1/`): **two** v1 ledger
    fixtures — (a) mid-work (findings present, no pause) and (b) **seam-paused**
    (carries the v1 key `seam_paused: true`, phase `"seam"` — a real pre-rename
    record speaks v1 keys, so the fixture is `seam_paused`, NOT
    `handoff_paused`) — plus each builtin recipe in v1 form. Additionally a
    **mixed-fleet fixture**: a `format: 2` record carrying stray v1 keys (the
    corruption class an older still-installed plugin produces), with asserted
    upgrade semantics (stray v1 twin mapped-and-dropped, new key wins).
  - Contracts: key tables + "Legacy keys (read-compat)" appendix in
    `backend-contract.md`, `recipe-format.md`, `ledger-schema.md`. Each takes a
    **content version bump at U6** (new key table = new normative text = new
    version + changelog line, per KTD-6) so no version label denotes two
    different normative texts across the U6→U8/U9 gap. `recipe-format.md` and
    `ledger-schema.md` are renamed/full-re-locked later (U8/U9), which carries a
    second, trivial rename-only bump; the KTD-6 banner note is added to both in
    this unit. `doc-fence-ledger-schema.test.sh` fences updated to the new keys.
  - Rename `seam-default.test.sh` → `handoff-default.test.sh` and update all
    `"seam"` literals in tests to fixtures/new keys.
  - **Mixed-fleet cutover (this unit owns it — KTD-1).** Before any smoke or
    `/auto-resume` on a repo whose `.claude/auto/` state dir is **shared** with
    an installed older (pre-rename) plugin, update the installed plugin to ≥ this
    rename **or** run the smoke on an isolated state dir. This is the execution
    of the KTD-1 "mixed-fleet cutover step (required)" and the Risks-table
    "Mixed-fleet corruption" row — both name the hazard; this line makes U6 the
    unit that carries it out, and Verification Contract item 6 asserts it as a
    preflight before the live-upgrade resume.
- **Dependencies:** U4, U5.
- **Files:** `lib/format_compat.py` (new), `lib/_bootstrap.py`
  (`load_ledger_safe` shim wiring), `lib/recipe_validate.py` (the
  `validate_and_lint` write-gate shim wiring — F5; the earlier
  `skills/auto-launch/SKILL.md:281` embedded-shape claim was a mis-citation,
  removed), `lib/ledger_core.py`,
  `lib/ledger_predicate.py`, `lib/ledger_mutators.py`, `lib/ledger_emitters.py`,
  `lib/unit_emitters.py` (registry keys), `lib/pulse*.py`, `lib/dispatcher.py`,
  `lib/backend-*.py`, `lib/recipes.py`, `lib/recipe_validate.py`,
  `lib/auto.py`, `lib/auto-status.py`, `lib/auto-resume.py`, `lib/on-stop.py`,
  `lib/phase-grammar.py`, **the key-reading consumer modules a list-driven
  executor would otherwise leave reading dead keys**: `lib/watch_tree.py`,
  `lib/execution_tree.py`, `lib/iteration.py`, `lib/goal-status.py`,
  `lib/ledger_steering.py`, `lib/topology-render.py`, `lib/recommender.py`,
  `lib/on-session-start.py`, `lib/cmux-socket.sh` (its `resumable_orphans`
  seam-paused exclusion at `:136` reads `loop_phase=="seam"` / `seam_paused` via
  the shimmed chokepoint — must flip to `handoff`/`handoff_paused` or a
  handoff-paused run is silently un-excluded from resume); the **preset
  persisted surface**:
  `presets/scoped-build.json`, `docs/contracts/preset-format.md`, and
  `lib/presets.py:196` (validates against the flipped op-set value);
  `recipes/*.json`, `recipes/schema.json`, `tests/fixtures/format-v1/*` (new),
  `tests/unit/format-compat.test.sh` (new),
  `tests/unit/handoff-default.test.sh`, broad test-assertion sweep
  (`jq '.units'` → `.steps`, etc.), the three contracts,
  `tests/unit/doc-fence-ledger-schema.test.sh`,
  `tests/unit/import-topology.test.sh`. **The grep sweep, not this file list,
  is the authority on coverage** (as in U2) — every `units`/`adapter`/`seam`/
  `emitter`/`do_unit` key-read site must flip, list or not. **The sweep scope
  explicitly includes skill/command PROSE value-mentions of the flipped values,
  not just lib key-read sites** — `skills/*` and `commands/*` prose that names a
  persisted *value* (`do_unit`, `adapter_op`, `plan_output_to_work_units`,
  `seam`) must flip in U6 with the value, even where the surrounding *symbol*
  rename (`unit`→`step`, `adapter`→`backend`) waits for a later unit. Concretely:
  `skills/auto/SKILL.md:161-162`'s dispatch map (`do_unit` → `/ce-work`) flips to
  `do_step` **here** — otherwise it stays audit-green through the U6→U7 window
  while records already carry `backend_op: do_step`, and a driver following that
  stale prose mid-branch dispatches a dead value. (The `do_unit`→`do_step` prose
  flips at U6 with the value even though the `unit`→`step` symbol rename around it
  lands at U7.)
- **Approach — explicit commit stack** (U6 is the biggest-blast-radius unit,
  so its stack is defined, not left to the executor):
  - **Commit A** — `lib/format_compat.py` (upgrade + downgrade fns), the v1 +
    mixed-fleet fixtures, and direct unit tests of the upgrade/downgrade
    functions (`format-compat.test.sh`). This lands **green but UNWIRED**: the
    functions are pure and inert until called, so nothing else moves. This is
    the red-green step — write the fixture-upgrade assertions, watch them fail
    before the functions exist, then make them pass.
  - **Commit B** — the irreducible atomic cutover, **one non-decomposable
    commit**: wire the shim into both chokepoints (`_read_json` +
    `load_ledger_safe`) AND the write gate (`validate_and_lint`), flip every
    old-key read/write site + producer-name values + `seam`→`handoff` literals
    + the preset persisted surface, rewrite the key tables of all three
    schema-bearing contracts (with the U6 content-version bump per KTD-6), and
    run the test-assertion sweep — all together. Splitting B leaves the tree in
    a half-flipped state where some code reads new keys off records other code
    still writes old (KTD-6's "one atomic on-disk flip" reasoning — sound, kept).
  - Deliberate-fail smoke (post-B): Edit-comment the `upgrade_run_record` call
    in `_read_json`, watch the fixture-load test and an end-to-end
    old-ledger-mutation test go red, revert via Edit.
- **Test scenarios:** (1) v1 ledger fixture: `read_ledger` returns v2 shape;
  (2) v1 fixture + one mutation (`transition`) → file on disk is v2 with
  `format: 2`, predicate recomputed with `all_steps_terminal`;
  (3) v1 recipe file in workspace tier resolves, validates, and
  `unit_for`-projects with `backend_op`; (4) `migrate` verb rewrites a v1
  recipe file atomically; running it twice is a no-op (idempotence);
  (5) seam-paused v1 ledger reads as `handoff_paused: true`, `loop_phase:
  "handoff"`, and `/auto-resume` advances it; (6) producer-name value
  `plan_output_to_work_units` in a v1 ledger's `phase_transitions` resolves
  in the producer registry post-upgrade; (7) mixed old/new keys in one file
  (partial hand-edit) → **new key wins and the stale old twin is dropped** (the
  result carries `steps`, never both `units` and `steps`); genuinely-unknown
  keys pass through untouched; (8) a `format: 2` record with **no** stray v1
  keys passes through `upgrade_run_record` byte-identical; (9) the
  **hook-path** read: a v1 seam-paused fixture read via
  `_bootstrap.load_ledger_safe` (as the Stop hook does) yields
  `handoff_paused`/`"handoff"` — deliberate-fail by Edit-commenting the
  `load_ledger_safe` shim call specifically (proves the second chokepoint is
  independently wired, not shadowed by the first); (10) **mixed-fleet fixture**
  (`format: 2` + stray v1 keys, the older-plugin corruption class): asserts the
  stray v1 twin is mapped-and-dropped and the new key wins — the exact case the
  unconditional (non-`format>=2`-gated) upgrade exists to catch; (11)
  **property / order-independence idempotence**: `upgrade_run_record` over
  randomized subsets of the key set (not just one hand-built fixture) yields the
  same v2 shape, and a second application is a no-op — proves the map is pure
  and order-independent; (12) **authoring / WRITE-path** (F5):
  `validate_and_lint` **ACCEPTS** a v1-keyed draft (`iteration.gate_unit`) —
  it validates an internally-upgraded copy and still returns the warnings
  **list** (return signature unchanged) — the write path a model following
  not-yet-renamed authoring-skill prose exercises; (12a) **authored file
  persists v1-keyed and still resolves**: the draft the authoring flow writes to
  disk may remain v1-keyed (the write-gate shim never rewrites the caller's
  draft), and that on-disk file later `resolve()`s cleanly via the read-shim
  (`upgrade_workflow`) — asserts what the authoring flow persists (v1) and that
  it round-trips through resolution to a v2 shape;
  (13) **downgrade round-trip / inverse-map fidelity**:
  `downgrade_run_record(upgrade_run_record(v1)) == v1` (modulo the `format`
  marker `upgrade` adds and `downgrade` strips) over the v1 fixtures — a lossy
  inverse map would otherwise ship undetected until an actual revert;
  (14) **downgrade is offline/quiesced (non-goal for live runs)**: assert (or
  state as an explicit non-goal) that `downgrade_run_record` writes under the
  run-record flock and is documented as an offline operation — driving it
  against a live flocked run is the same race class the plan rejects for
  one-shot migration (KTD-1), so there is no online-downgrade guarantee.
- **Verification:** full suite green; the v1-fixture end-to-end pulse
  (init-from-fixture → pulse → verdict → gate) completes; doc-fence green;
  audit `seam=done`, whitelists for `emitter`/`adapter`/`unit` persisted keys
  removed (now only `format_compat.py` carries them).

### U7 — `unit` → `step` (code symbols + CLI verbs + agent-tool-surface)

- **Goal:** rename the work-node term in all code/test/doc identifiers (keys
  already flipped in U6).
- **Requirements:** symbols: `UNIT_STATES→STEP_STATES`, `UnknownUnit→
  UnknownStep`, `_normalize_unit→_normalize_step`, `unit_for→step_for`,
  `unit_is_terminal→step_is_terminal`, `add-unit→add-step` +
  `set-enumerated-units→set-enumerated-steps` CLI verbs (no aliases, KTD-4)
  with `describe` payload + `agent-tool-surface.md` updated in lockstep (the
  set-equality test enforces). **Operational verbs stay OUT of the `_VERBS` /
  `describe` / `agent-tool-surface` registry (F16):** the `migrate` and
  `downgrade` utility verbs are deliberately excluded from the CLI mirror so
  they don't enlarge the locked, set-equality-enforced verb surface (they are
  operator tools, not agent-driving verbs). Also add a **doc-fence over the
  `agent-tool-surface.md` verb table** in this unit (F12) — the set-equality
  test binds `describe`↔`_VERBS` but not that prose table, so the fence + the
  vocabulary-audit are its forcing functions. `git mv lib/unit_emitters.py
  lib/step_producers.py` (KTD-3 two-term file) + DAG lint + registry module
  references; `units-json` CLI arg help → `steps-json`; skills/commands prose
  ("U-IDs" become step ids; the shipped step id *values* like `"plan"`,
  `"build-1"` are data, unchanged); tests: `unit-emitters.test.sh` →
  `step-producers.test.sh`, sweep `unit` in test names/asserts. **Permanent
  `unit`-noise whitelist:** `tests/unit/` directory name, "unit test(s)" prose,
  CONCEPTS.md historical column. (`plan_step`/`PLAN_STEPS`/`next_plan_step` are
  NOT whitelist entries — they contain no `unit` token so cannot trip the audit;
  they are the Key-Decisions "don't rename" carve-out only — F15a.)
- **Dependencies:** U6.
- **Files:** `lib/ledger_core.py`, `lib/ledger_predicate.py`,
  `lib/ledger_mutators.py`, `lib/ledger_steering.py`, `lib/ledger.py`
  (`_VERBS`, describe), `lib/unit_emitters.py→lib/step_producers.py`,
  `lib/dispatcher.py`, `lib/pulse*.py`, `lib/recipes.py`,
  `lib/recipe_validate.py`, `skills/*`, `commands/*`,
  `docs/contracts/agent-tool-surface.md`, `docs/contracts/driver-reference.md`,
  `tests/unit/step-producers.test.sh` + assertion sweep across ~40 test
  files, `tests/unit/import-topology.test.sh`.
- **Approach:** grep-driven with the U1 audit's `unit` noise-whitelist as the
  guide; land the CLI-verb + describe + contract + set-equality change as one
  inner commit so the enforcing test never straddles.
- **Test scenarios:** (1) `describe` verbs set == `_VERBS` keys with the new
  names (existing set-equality test, updated expectations); (2) `add-step`
  round-trip: add, reshape-deps, transition; (3) old verb `add-unit` exits 2
  with "unknown subcommand"; (4) producer registry resolves all four names
  post module-rename; (5) audit `unit=done`; (6) **file-existence assertion** in
  `import-topology.test.sh` for `step_producers.py` so the negative-grep DAG
  checks can't pass vacuously on a mis-renamed file (F13).
- **Verification:** full suite green; `python3 lib/ledger.py describe | jq`
  shows no `unit` outside whitelisted prose.

### U8 — `recipe` → `workflow` (modules + dirs + skill + re-lock)

- **Goal:** rename the topology term: registry, validator, dirs, flags
  already aliased (U4 pattern), authoring skill, contract.
- **Requirements:** `git mv` `recipes.py→workflows.py`,
  `recipe_validate.py→workflow_validate.py`, `recipes-list.sh→
  workflows-list.sh` (+stub), builtin dir `recipes/→workflows/`
  (`_BUILTIN_DIR`); tier fallback per KTD-7 (workspace/global `workflows/`
  first, legacy `recipes/` read-only); `RecipeError→WorkflowError`,
  `ExitReason.RECIPE_BUG→WORKFLOW_BUG` (value already flipped U6),
  `A1_BUILTIN` **stays** `A1_BUILTIN`; `--workflow` flag canonical +
  `--recipe` alias (KTD-4) and `--teardown-workflow-after-init`;
  `workspace_recipe_path→workspace_workflow_path`; skill
  `auto-author-recipe→auto-author-workflow` (+former-name description),
  `auto-launch`/`auto-design`/`auto-driver`/`auto-translate` prose; commands
  `auto.md` prose. **Reverse-derive read routing (F7):**
  `auto-author-workflow`'s Entry-B "reverse-derive from a completed run" prose
  (currently `Read .claude/auto/<run-id>.json` directly) is updated to read via
  `python3 lib/run_record.py read <repo> <run>` — the raw Read tool bypasses the
  file-level shim, and completed/abandoned runs stay v1 on disk forever, so the
  CLI read (which returns shim-upgraded v2 JSON) is the model-side read surface
  the shim otherwise misses; `recipe-format.md → workflow-format.md` re-locked
  per KTD-5 (key appendix from U6 carried over); rename the ~12 `recipe-*`
  test files (`recipe-aliases`, `recipes`, `launch-recipe-compile`,
  `auto-teardown-recipe`, `pipeline-recipe`, integration `recipe-*`,
  `review-recipe`, `a2/a4-recipe-iteration`) → `workflow-*`.
- **Dependencies:** U6 (U7 sequence-only).
- **Files:** as above plus `lib/auto.py`, `lib/auto-detect.py`,
  `lib/recommender.py`, `lib/launch-gate.py` (`SKIP_ELIGIBLE_RECIPES→
  SKIP_ELIGIBLE_WORKFLOWS`), `lib/launch-mode.py`, `lib/preset_oneshot.py`
  (its `_recipe_validate = load_lib_module("recipe_validate")` import +
  `RecipeError` reference move to `workflow_validate`/`WorkflowError` — the
  preset TERM is untouched, but this shared import follows `recipe_validate`
  into U8), **`lib/presets.py`** (its `_recipe_validate =
  load_lib_module("recipe_validate")` at `:56` + the `_check_prompt_template`/
  `_validate_recipe_name`/`RecipeError` bindings at `:59-61` move to
  `workflow_validate`/`WorkflowError` — same shared-import entanglement; the
  preset TERM stays. Its `adapter_ops`/op-set import already flipped in U4),
  `lib/format_compat.py` (module docstring only),
  `workflows/schema.json` (`title`, `$id`),
  `tests/unit/import-topology.test.sh`, `tests/unit/wikilink-check` targets.
- **Approach:** module renames first (loader-string sweep), dirs second
  (KTD-7 fallback + tests for legacy-tier resolution), flag alias third,
  contract re-lock last-in-unit.
- **Test scenarios:** (1) a v1-keyed recipe file sitting in the **legacy**
  `.claude/auto/recipes/` workspace dir resolves and runs (shim + dir
  fallback composing — the critical user-compat path); (2) same name in both
  `workflows/` and legacy `recipes/` → `workflows/` wins (first-wins
  preserved); (3) `--recipe a1` == `--workflow a1` + stderr notice;
  (4) reserved-alias rejection (`work-only` authored name) still fires from
  `workflow_validate`; (5) `A1_BUILTIN` fallback drift test still green
  against `workflows/a1.json`; (6) audit `recipe=done`; (7) **file-existence
  assertion** in `import-topology.test.sh` for `workflows.py` /
  `workflow_validate.py` so the negative-grep DAG checks can't pass vacuously on
  a mis-renamed file (F13).
- **Verification:** full suite green; re-lock commit complete per KTD-5;
  `wikilink-check` green.

### U9 — `ledger` → `run_record` (module family + facade + CLI + re-lock)

- **Goal:** the highest-footprint rename, last, when the pattern is proven
  and all on-disk keys are already v2.
- **Requirements:** `git mv` the six modules per KTD-3
  (`ledger_emitters.py→run_record_producers.py` final two-term name);
  facade `lib/ledger.py→lib/run_record.py` + forwarding stubs
  `lib/ledger.py`/`lib/ledger.sh` (KTD-4 — the one memorized CLI path);
  symbols: `LedgerError→RunRecordError` family (`LedgerNotFound→
  RunRecordNotFound`, `LedgerExists`, …), `ledger_path→run_record_path`,
  `read_ledger→read_run_record`, `init_ledger→init_run_record`,
  `_with_locked_ledger→_with_locked_run_record`,
  `_bootstrap.load_ledger→load_run_record`; DAG lint: full family rename
  (`run_record_core ← run_record_mutators ← run_record_producers ← run_record`)
  + consumers list; `ledger-schema.md → run-record-schema.md` re-locked per
  KTD-5; `doc-fence-ledger-schema.test.sh → doc-fence-run-record-schema.test.sh`;
  `agent-tool-surface.md` machine-mirror line → `python3 lib/run_record.py
  describe`; skills/commands prose ("the ledger" → "the run-record").
  **`lib/cmux-socket.sh` (F6):** repoint both
  `importlib.util.spec_from_file_location("ledger", .../ledger.py)` sites
  (~:80 and ~:268) and their `L.ledger_path(...)` symbol calls to
  `run_record.py`/`run_record_path`. This runs the runaway-spawn sentinel /
  double-drive guard, wrapped in `except: sys.exit(0)` — if the module load or
  symbol call fails post-rename, the exception is swallowed and the guard
  silently fails open. The KTD-4 module-importable `ledger.py` re-export stub is
  the belt; this repoint is the suspenders. Rename `ledger*.test.sh` and sweep
  ~45 test files' helper calls; on-disk filename `<slug>.json` under
  `.claude/auto/` is **unchanged** (it never carried the term).
- **Dependencies:** U6 (U7/U8 sequence-only).
- **Files:** `lib/ledger*.py→run_record*.py` (+ stubs), `lib/_bootstrap.py`,
  `lib/cmux-socket.sh` (both `spec_from_file_location` sites + symbol calls),
  every consumer in `lib/` (auto, auto-status, auto-resume, dispatcher,
  pulse*, hooks, watch_tree, execution_tree, driver_session, iteration,
  verification, steering), `skills/*`, `commands/*`,
  `docs/contracts/run-record-schema.md`, `agent-tool-surface.md`,
  `driver-reference.md`, `tests/unit/run-record*.test.sh`,
  `doc-fence-run-record-schema.test.sh`, `import-topology.test.sh`,
  `tests/helpers/*`.
- **Approach:** rename the family bottom-up (core → predicate → mutators →
  producers → steering → facade) in one commit so `load_lib_module` strings
  never dangle; then the consumer sweep; then contract + fence + stubs.
- **Test scenarios:** (1) `python3 lib/run_record.py describe` emits the
  contract JSON and the set-equality test passes; (2) legacy invocation
  `python3 lib/ledger.py read <repo> <run>` still works via stub + stderr
  notice, **and its stdout is byte-clean** — a legacy `ledger.py read | jq`
  pipeline must not have the deprecation notice leak into stdout (notice goes to
  stderr only); (3) `except run_record.RunRecordError` catches across the facade
  (class-identity test — the historical duplicate-class-identity failure mode
  the DAG lint documents); (4) doc-fence green against renamed contract;
  (5) the **I-1 atomic-predicate-freshness** scenario in
  `tests/unit/ledger.test.sh`→`run-record.test.sh` (Scenario 5, `NO_RECOMPUTE`
  hatch) and the flock/lock tests in `tests/unit/tick-locks.test.sh`→
  `pulse-locks.test.sh` stay green under the new module names (they exercise
  hatches via `CLAUDE_AUTO_TEST_*`, env names unchanged); (6) audit
  `ledger=done`; (7) **cmux-socket spawn-sentinel path** (F6): drive
  `cmux-socket.sh`'s spawn-attempt-name computation post-rename and assert it
  resolves the run-record path (not silently `sys.exit(0)`) — proves the
  `spec_from_file_location` repoint + the importable stub both hold; (8)
  **file-existence assertion** in `import-topology.test.sh` for the renamed
  run_record family modules so the negative-grep DAG checks can't pass vacuously
  on a mis-renamed file (F13).
- **Verification:** full suite green; grep `load_lib_module("ledger` returns
  only stubs/whitelist.

### U10 — Prose sweep, CONCEPTS.md, plugin manifest, audit closure

- **Goal:** finish the living-doc surface and lock the end state.
- **Requirements:** CONCEPTS.md: `(code / was)` column marked historical,
  depth-policy section rewritten ("code identifiers now match; legacy keys
  accepted on read via `lib/format_compat.py`"), the `plan_step` collision
  note added, `orchestrator → dispatcher` bullet marked done;
  `plugin.json` description rewritten in new vocabulary (recipes→workflows,
  ledger→run-record, adapter→backend, tick/pulse); `README`/`docs/handoff.md`
  updated; `docs/planning-readiness.md` if it names terms; all audit terms
  `done`, temporary whitelist entries removed. The remaining **permanent
  whitelist is the canonical list from U1** (stated identically in U1, here, and
  Verification-Contract item 2): `lib/format_compat.py`; all forwarding stubs
  (`lib/ledger.py`, `lib/ledger.sh`, `lib/tick.sh`, `lib/orchestrator.sh`,
  `lib/adapter-ce.sh`, `lib/adapter-native.sh`, `lib/recipes-list.sh`);
  `commands/auto-tick.md`; `docs/plans|brainstorms|research/`; CONCEPTS.md
  historical column; `tests/unit/` path + "unit test(s)" prose; CHANGELOG-style
  notes; the `_parse_args` flag-alias branches (`--recipe`/`--adapter`/
  `--teardown-recipe-after-init` + deprecation strings); the "(formerly
  auto-adapter)"/"(formerly auto-author-recipe)" skill breadcrumbs.
  (`plan_step`/`next_plan_step` are NOT whitelist entries — no old token,
  can't trip the audit; Key-Decisions carve-out only, F15a.) A follow-up note
  lists what the next minor removes (stubs, flag aliases, `auto-tick.md`
  alias — see Deferred).
- **Dependencies:** U2–U9.
- **Files:** `CONCEPTS.md`, `.claude-plugin/plugin.json`, `docs/handoff.md`,
  `README.md` (if present), `tests/unit/vocabulary-audit.test.sh`.
- **Test scenarios:** (1) audit green with final whitelist; (2) deliberate-
  fail: reintroduce `recipe` in a `lib/` comment via Edit → audit red →
  revert; (3) `bash tests/run.sh all` total == pre-plan total + tests added
  (format-compat incl. property/order-independence + mixed-fleet + write-gate +
  downgrade round-trip, audit, migrate-verb, downgrade-verb, alias/in-flight,
  cmux-socket spawn-sentinel) — reconcile the count explicitly.
- **Verification:** full suite green; manual smoke: `/auto` on a toy repo
  end-to-end (arm → pulse → handoff → work step → done) using only new
  vocabulary.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| **Persisted run-record breakage** (in-flight runs wedge, old records unreadable) | KTD-1 read-shim at **both** read chokepoints (`ledger_core._read_json` + `_bootstrap.load_ledger_safe`) **plus the write gate** (`validate_and_lint`), under the existing flock; the map is applied **unconditionally on every read** (never `format`-gated); committed v1 fixtures exercised end-to-end (U6 scenarios 1–14, incl. the downgrade inverse-map round-trip); lazy migration on first mutation means no racing bulk rewrite. |
| **In-flight rearm prompts invoke a dead command** | `/auto:auto-tick` kept as alias command file (U5); removal deferred a minor version. |
| **Locked-contract drift** (contract says X, code does Y mid-refactor) | KTD-5 one-commit re-lock; KTD-6 banner notes for the U6→U8/U9 gap; doc-fence + describe set-equality + wikilink tests updated in the same commit as their surface. |
| **Partial-rename half-state** (some files renamed, session dies) | Per-unit atomic commits, suite green at each boundary; the U1 audit table makes "how far did we get" deterministic for any resuming session. |
| **JSON migration data-loss** (upgrade drops an unknown key) | `upgrade_*` functions map known old keys (dropping only the **mapped stale twin** so a record never carries both `units` and `steps`) and **pass genuinely-unknown keys through untouched**; fixture scenario 7 (mixed keys, twin-drop), 8 (byte-identical clean-v2 pass-through), 10 (mixed-fleet); `_atomic_write` semantics unchanged. |
| **Mixed-fleet corruption** (renamed worktree writes `format:2`; an older still-installed plugin's hooks read the same repo and see empty `units` — which *blocks* conservatively rather than falsely exiting, since `ledger_predicate.py:223-225` gates `met` on non-empty `units`; the real hazard is the old code's old-key WRITE landing in the `format:2` record, which a `format`-gated shim would then skip forever) | The v1→v2 map is applied **unconditionally**, never skipped on `format:2`, so a lagging writer's record is still read/mapped and the write-skip-forever hole is closed; **mixed-fleet cutover step** (KTD-1, owned by U6) — update the installed plugin before any dogfood/smoke on a repo whose `.claude/auto/` is shared with an older plugin, or explicitly note the no-old-plugin window; U6 scenario 10 asserts the corruption class. |
| **U6 one-way door / revert** (reverting to pre-rename code on a stranded `format:2` record → old `.get("units", [])` reads empty, silently misbehaves) | `lib/format_compat.py` carries the inverse `downgrade_run_record`/`downgrade_workflow` + `run_record.py downgrade <path>` verb; documented revert procedure runs the downgrade over stranded records BEFORE reinstalling pre-rename code — U6 is a reversible door. |
| **Flag/command breakage for existing users** | KTD-4 aliases with stderr deprecation; scripted callers (`auto` positional) untouched; skill descriptions carry former names for model-trigger continuity. |
| **In-flight driving agent uses old CLI verbs post-U7** (`add-unit` in its transcript → exit 2) | Accepted: recoverable in-session via `describe` (the contract-mandated orientation path); the error message for an unknown verb should name `describe`. Unlike the rearm prompt, verbs are never persisted, so no alias is kept. |
| **Runner mis-tally on renamed tests** (silent test loss) | Every renamed test solo-run verified to print its new name in the summary line before the suite gate; U10 reconciles total counts. |
| **DAG cycle sneaks in during module renames** | import-topology lint updated in the same commit as each `git mv`; deliberate-fail smoke on new lint lines (U5, U9). |
| **`unit` term noise** (`tests/unit`, "unit test") causes over-rename or audit false-positives | Explicit permanent `unit`-noise whitelist in the audit (U1/U7). `plan_step`/`next_plan_step` are a separate concern — they contain no `unit` token and cannot trip the audit; the "don't rename" decision is recorded in Key Decisions + CONCEPTS.md, not as an audit whitelist entry (F15a). |
| **Two concurrent sessions on this branch** | Known failure mode (memory: concurrent same-branch pushes); rename units are highly conflict-prone — run this plan single-session, re-fetch before push. |

## Verification Contract

1. `bash tests/run.sh` (all) green after **every** implementation unit — no
   unit merges red or partially renamed.
2. `tests/unit/vocabulary-audit.test.sh`: after U10, every old identifier
   (`recipe`, `ledger`, `unit`, `tick`, `adapter`, `emitter`, `seam`,
   `orchestrator`, word-boundary, case-aware) appears **only** in the canonical
   permanent whitelist (identical to U1 and U10): `lib/format_compat.py`; all
   forwarding stubs (`lib/ledger.py`, `lib/ledger.sh`, `lib/tick.sh`,
   `lib/orchestrator.sh`, `lib/adapter-ce.sh`, `lib/adapter-native.sh`,
   `lib/recipes-list.sh`); `commands/auto-tick.md`;
   `docs/plans|brainstorms|research/`; CONCEPTS.md's historical column;
   `tests/unit/` path + "unit test(s)" prose; CHANGELOG-style notes; the
   `_parse_args` flag-alias branches (`--recipe`/`--adapter`/
   `--teardown-recipe-after-init` + deprecation strings); the "(formerly …)"
   skill breadcrumbs. (`plan_step`/`next_plan_step` are not listed — they carry
   no old token and cannot trip the audit; F15a.)
3. Compat proof: the committed fixtures — **two v1 ledger fixtures** (mid-work;
   **seam-paused**, carrying the v1 key `seam_paused`), the mixed-fleet
   `format:2`+stray-v1-keys fixture, and each builtin recipe in v1 form — load,
   validate, mutate, and complete a pulse cycle; a v1 recipe in the legacy
   `recipes/` workspace dir resolves and arms a run.
4. Contract enforcement green: doc-fence (run-record-schema), describe
   set-equality, wikilink-check, import-topology (new DAG names).
5. Total test count reconciled: pre-plan tally + {format-compat (incl.
   property/order-independence, mixed-fleet, write-gate, downgrade round-trip),
   audit, migrate-verb, downgrade-verb, alias/in-flight, cmux-socket
   spawn-sentinel} additions, zero silently-dropped files.
6. Manual smoke on a toy repo: `/auto <plan>` → pulse → handoff → work steps
   → done, plus `/auto-resume` of a run armed **before** the rename (the
   live-upgrade path). **Preflight (mixed-fleet cutover, G1/KTD-1):** before
   resuming a pre-rename run on a `.claude/auto/` state dir **shared** with an
   installed plugin, assert the installed plugin is **post-rename** (or run the
   resume on an isolated state dir). This precondition is owned by U6 and
   prevents an older still-installed plugin's hooks from writing old keys into
   the `format:2` record mid-resume.

## Definition of Done

- All 8 terms renamed as code identifiers per the map; non-renamed terms and
  stems verifiably untouched.
- The **three schema-bearing LOCKED contracts** (`backend-contract.md`,
  `workflow-format.md`, `run-record-schema.md`) re-locked at new names/versions
  with legacy-key appendices. The fourth LOCKED contract,
  `verification-contract.md`, is **LOCKED-but-untouched** (its `verification`/
  `criteria` terms don't rename; only incidental cross-references to renamed
  terms get prose updates at first touch — no re-lock, rename, or version bump).
  PROVISIONAL `preset-format.md` gets only the shared-key flip (U6), no re-lock.
- Old-format run-records and workflow files load via the shim (applied
  unconditionally on read); new writes are format 2; `workflows migrate` verb
  and the `downgrade` revert verb available.
- Flag/command/entry-point aliases in place with deprecation notices; alias
  removal listed as follow-up.
- CONCEPTS.md, plugin.json, skills, commands speak only the new vocabulary.
- Verification Contract items 1–6 all pass; branch pushed, PR opened with the
  old→new table in the body.

## Deferred to Follow-Up Work

- **Alias/stub removal** (next minor): `--recipe`/`--adapter`/
  `--teardown-recipe-after-init` flags, `commands/auto-tick.md`, the
  `lib/*.sh`/`lib/ledger.py` forwarding stubs. Workflow-file read-compat
  (`upgrade_workflow`) stays indefinitely (KTD-1).
- **U9 (`ledger`→`run_record`) is the designated stop-after-U8 fallback line.**
  It is the largest-risk unit (~4300 refs) for arguably the least-disorienting
  term. If U9 stalls, stopping after U8 is a legitimate exit: the 7-term subset
  (U2–U8) already captures most of the two-vocabulary orientation tax, and every
  unit boundary is independently green. Resume U9 as its own pass later.
- **`plan_step` vocabulary** — if the plan-sub-state/step collision proves
  confusing in practice, rename in its own deliberate pass (needs its own
  CONCEPTS.md entry first; no mandate here).
- **`emit_*` derived names** (`emit_templates`, `iteration_emit_count`,
  `expected_emit_outputs`) — kept per Key Decisions; revisit only if the
  producer vocabulary makes "emit" read wrong in the workflow-format contract.
- **Native lore runtime** (compounding best-practice + in-process worker
  self-heal) — separate spinoff direction per CONCEPTS.md §Deferred and
  memory `auto_native_lore_compounding_self_heal`; explicitly out of scope.
