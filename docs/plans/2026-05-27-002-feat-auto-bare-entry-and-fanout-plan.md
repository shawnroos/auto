---
title: "auto: bare-entry hypothesis intake, multi-plan fanout, slimmed driver skill"
status: active
created: 2026-05-27
deepened: 2026-05-27
type: feat
---

# auto: bare-entry hypothesis intake, multi-plan fanout, slimmed driver skill

## Summary

Reshape `/auto`'s entry surface so the operator can type `/auto` (or
`/auto <intent>`) and the harness drives the run without verdict-tree
ceremony, picker prose, or per-recipe scaffolding talk. Where the work
shape calls for parallelism (multiple plans), the engine spawns worktrees
+ ports automatically — operator sees one summary line and at most one
confirmation.

**Scope of this plan is intake + parallelism + skill surface area cuts.**
This plan does NOT change the review→fix loop quality, the recipe library,
or the resume/recovery mechanism. Auto's identity ("thorough, reviewed,
refined output — no slop") is the destination; this plan removes friction
at the front door so the operator reaches it more often without nannying.
Review→fix quality work is a separate plan.

The current drift this plan corrects: skill files leak mechanism
(prepare/execute essays, livelock guards, recipe selection prose) into
the operator-facing surface; `auto-detect.sh` emits routing verdicts a
skill enumerates instead of a hypothesis a skill affirms; multi-plan
work requires sequential `/auto <plan>` invocations; worktrees and ports
are operator-managed when they should be auto-allocated under fanout.

## Problem Frame

Shawn's words (paraphrased across the originating session):

1. **"Starting auto sessions is clunky — the agent fumbles."** Bare `/auto`
   reaches a five-verdict decision tree. Reviewed-plan path asks an awkward
   question with a stub-warning. Multi-plan path picks one. Raw recommends
   `/ce-plan` and stops.
2. **"If there's no plan, get a plan done — as per the spirit of auto."**
   Auto should drive planning when none exists, not refuse to start.
3. **"If there are multiple plans, automatically spin up multiple
   backgrounded auto sessions."** Today: not possible.
4. **"Type `/auto` — the harness figures out where we are, resumes or
   starts fresh, ensures it gets enough info to keep working."** The intake
   is a hypothesis former; questions fire only when the hypothesis is
   genuinely ambiguous.
5. **"Use goals — they're useful in the harness."** Goals are how the Stop
   hook stays active until work is satisfied. This plan binds harness
   `/goal` against the existing exit predicate; user-facing goal grammar
   (e.g., `/auto goal: ...`) is **deferred** — out of scope here.

## Scope

### In scope

- **`auto-detect.sh` rewrite** — same Python decision tree, emits a JSON
  hypothesis object (situation + summary + ambiguity) instead of a TSV
  verdict line. Preserves all five existing verdicts including
  `ambiguous-runs`.
- **Batch sidecar artifact** (`<git-common-dir>/.claude/auto/batches/<id>.json`)
  for multi-plan fanout state ONLY: kind, plans[] with worktree paths +
  assigned ports, batch composite goal sentence. Single-plan runs do not
  need this; existing ledger absorbs single-plan state with one schema
  addition (`goal_intent` field).
- **`lib/auto-spawn.py`** — given a batch record with N plans, create a
  worktree per plan (via `git worktree add`), allocate a port per worktree
  from the 3001-3099 range, write the batch sidecar with assignments, and
  return the manifest. The DRIVER (skill) launches the backgrounded
  `/auto <plan>` invocations via the Agent tool; this lib stays
  harness-agnostic. Port "allocation" is the simplest thing that works:
  read in-use ports from any existing batch sidecars under the common
  ledger dir, pick the lowest free port in range. No flock, no
  separate ports.json registry.
- **Default seam behavior flip** — `auto` (skip-seam) becomes the default;
  `--review-plan` flag is opt-in for first-pass plans where the operator
  wants the pause. This directly delivers "operator involved only at
  goal-divergence checkpoints" without the latency / new intent type /
  schema change of a synchronous agent comparison.
- **Bare `/auto` intake funnel** — driver loads hypothesis JSON, surfaces
  the one-line summary, dispatches when ambiguity is null OR asks one
  blocking question when it isn't. No verdict-tree enumeration.
- **`/auto <freeform text>` handoff** — driver invokes `/ce-plan <text>`
  via the Skill tool and ends its turn. `/ce-plan` is a multi-turn skill
  (it runs its own dialogue, deepen, review) and there is no
  call/return semantics that brings control back to auto-driver
  in-session. The operator re-invokes `/auto` after the plan lands; the
  hypothesis funnel then sees the new plan and dispatches.
  (Round-2 finding: Feasibility R2-002 — the originally-proposed
  same-session trampoline is not implementable; matching the existing
  `raw`-case behavior is the honest fix. Auto-re-entry on plan-file
  write is a separate plan that would require a SessionStart or
  PostToolUse hook.)
- **Skill surface cuts.** `skills/auto-driver/SKILL.md`: budget ≤60 lines
  (currently 164). `skills/auto/SKILL.md`: budget ≤120 lines (currently
  366). Move mechanism (prepare/execute theory, plan-loop livelock guard,
  state grammar, full work-loop policy) to
  `docs/contracts/driver-reference.md`. The active skills cite by path;
  the reference doc loads only on edge cases.

### Deferred / out of scope

- **User-facing goal grammar** (`/auto goal: ...`, `--goal "<text>"`).
  The harness `/goal` continues to bind against the existing exit
  predicate ("until only P3 remain"). Operator-expressed goals are a
  separate UX decision.
- **Goal-divergence comparison agent at the seam.** Replaced by the
  simpler default-flip. Synchronous agent comparison adds latency and
  requires a new intent type + ledger field; deferred until evidence
  shows the default-flip is insufficient.
- **Persistent port-pool registry with atomic claim.** Replaced by the
  simpler "scan batch sidecars, pick lowest free." Atomic flock + claim
  journal is right for multi-user infra, overkill for single-operator
  fanout where N typically ≤ 3.
- **Charter as a first-class durable artifact.** Single-plan run state
  stays on the existing ledger (+ `goal_intent` field); batch sidecar
  covers only multi-plan state.
- **Worktree cleanup on completion.** Worktrees stay until manual `wtc`.
  A follow-up `auto-cleanup` command is a separate plan.
- **Review→fix loop quality.** This plan's identity is intake + parallel
  + skill cuts. Quality work belongs in a separate plan.
- **v0.3.1 backlog items (B1, B2, B3, B9)** are not blocked by this plan
  but are also not advanced. Sequencing them before this plan is a
  legitimate alternative the operator should consider.

## Key Technical Decisions

### KTD-1: `auto-detect.sh` evolves; no separate hypothesis wrapper

The detection logic in `auto-detect.sh` is correct (round-1 finding:
Scope F5, Adversarial ADV-3). The bug is that it emits a TSV verdict the
skill then enumerates. Fix: rewrite the same Python decision tree to emit
JSON directly:

```json
{
  "situation": "in-flight | ambiguous-runs | reviewed-plan | multi-plan | dirty-tree | raw",
  "summary": "one-line operator-facing description",
  "ambiguity": null | { "kind": "binary | open", "question": "...", "options": [...] },
  "single_plan": { "path": "...", "run_id_hint": "..." } | null,
  "multi_plan": { "paths": [...], "batch_id_hint": "..." } | null,
  "in_flight": { "run_id": "...", "run_ids": ["..."] } | null
}
```

The TSV legacy contract is dropped. Callers are `skills/auto-driver` (the
new shape) and `lib/auto.sh` (already calls auto.py directly, not
auto-detect.sh). No back-compat wrapper needed — auto-detect.sh has
exactly one consumer today (the skill) and we're updating that consumer
in U4.

The `ambiguous-runs` verdict is preserved as a first-class situation;
its `ambiguity` field carries an `AskUserQuestion`-shaped options array
listing the in-flight run-ids. (Round-1 finding: Feasibility F4 closed.)

### KTD-2: Ledger gets `goal_intent`; batch sidecar handles multi-plan state

Add one field to the existing per-run ledger schema:
- `goal_intent: string | null` — the user-facing intent sentence
  (one line). For `/auto <plan>` runs, derived from plan title.
  For bare `/auto`, derived from hypothesis. For freeform, derived
  from the input text.

No charter file for single-run state. The ledger already holds adapter,
recipe, plan path, exit predicate — duplicating these in a charter is the
"and don't replace" pattern that produces drift (round-1 finding:
Adversarial ADV-3).

For multi-plan fanout (and ONLY for that case), write a batch sidecar
at `<git-common-dir>/.claude/auto/batches/<id>.json`:

```json
{
  "id": "2026-05-27-1430-batch",
  "created": "2026-05-27T14:30:00Z",
  "composite_intent": "drive plans B11, B12, B13 to clean",
  "plans": [
    { "path": "docs/plans/B11-...md", "run_id": "...", "worktree": "/abs/path", "port": 3001 }
  ]
}
```

The batch sidecar is the ONLY new persistent artifact. It exists because
N sub-runs need a single record the parent session can read to compose
their status. Single-run flow is unaffected.

### KTD-3: Shared state lives at `git rev-parse --git-common-dir`/.., sub-runs scoped by `CLAUDE_AUTO_REPO`

`.claude/auto/` is per-working-tree, not shared via git's common-dir
(round-1 finding: Feasibility F1+F5, Adversarial ADV-1 — the load-bearing
structural issue).

**Resolution part A — shared state and host repo lookup.** Two new
helpers in `lib/_bootstrap.py`:

`resolve_host_repo_root()`:
1. Runs `git rev-parse --git-common-dir` from cwd.
2. Resolves to absolute path.
3. Returns its parent (the main worktree root).

`resolve_shared_dir()`:
1. Calls `resolve_host_repo_root()`.
2. Joins `.claude/auto/`.
3. Returns absolute path.

Both return None if git is unavailable. The split helper is required
because `git rev-parse --show-toplevel` from inside a worktree returns
the *worktree's* path, not the main repo (round-3 finding: R3-001 —
empirically verified). The common-dir trick is the only reliable
resolver that gives the main repo from any worktree.

All shared state (batch sidecars, port discovery, cross-worktree run
discovery) goes through `resolve_shared_dir()`. Worktree spawn paths
use `resolve_host_repo_root()` directly. The parent session's Stop
hook discovers active batches via the `batches/` glob and checks each
sub-run's terminal state by reading the sub-run's ledger at the path
recorded in the batch sidecar.

**Resolution part B — per-worktree ledger isolation (round-2 finding:
Feasibility R2-001).** The existing `_resolve_repo()` helper walks up
from cwd looking for `.claude/auto/`. Because `.claude/auto/` is
gitignored, freshly-created worktrees do not have it, and the walk-up
escapes the worktree, escapes the main repo, and lands at
`~/.claude/auto/` (the user-global recipes shelf). Spawned sub-runs
would therefore collide on a single user-global ledger dir — not the
desired per-worktree isolation.

Fix: `lib/auto-spawn.py` spawns each backgrounded `/auto <plan>` with
`CLAUDE_AUTO_REPO=<worktree-abs-path>` in the dispatched Agent's
environment. The existing `_resolve_repo()` already honors this env
override (documented in its docstring) and short-circuits before the
walk-up. Each sub-run's ledger writes go to
`<worktree-abs-path>/.claude/auto/<run>.json` deterministically. No
change to `_resolve_repo()` itself is required.

The two helpers cover the two distinct needs: `_resolve_repo()`
(env-pinned per sub-run) — "what does THIS worktree own"; and
`resolve_shared_dir()` (git-common-dir) — "what does the parent know
across worktrees."

### KTD-4: Default seam flip — no synchronous comparison agent

The operator-facing intent is "involved only at goal-divergence
checkpoints, not fixed phase boundaries." A synchronous comparison agent
at the seam (the originally-proposed approach) adds latency at every
plan→work transition, requires a new intent type, requires a ledger
schema field, requires an adapter-contract addition, and gets its signal
from an inferred goal sentence that may itself be wrong (round-1
findings: Scope F4, Adversarial ADV-5, Feasibility F3).

Simpler fix that delivers the intent: flip the seam default.

- **Before:** `/auto <plan>` pauses at the seam; `auto` token is opt-in
  to skip.
- **After:** `/auto <plan>` proceeds through the seam; `--review-plan`
  flag is opt-in to pause for first-pass plans.

The operator stops being pinged at fixed phase boundaries; the pause is
available when the operator explicitly asks for it. Goal-divergence
detection at the seam can be added later if the default-flip turns out
to be too aggressive — but it shouldn't ship before there's evidence the
simpler fix doesn't suffice.

**Back-compat:** existing scripted callers that rely on the seam pause
without `auto`-token will silently skip it. Mitigation: stderr notice
on the first run after upgrade (one-line, references the new
`--review-plan` flag and a doc link). This is the only operator-visible
behavior change in the plan; the notice makes it discoverable. (Round-1
finding: Feasibility F6 closed.)

### KTD-5: Skill surface cuts as budgets, not exact targets

`skills/auto-driver/SKILL.md`: **budget ≤60 lines** (currently 164).
Content shape:
- YAML frontmatter (~10 lines, not compressible)
- One-paragraph contract ("Load the hypothesis. Surface its summary one
  line. Dispatch when ambiguity is null; AskUserQuestion when not. End
  turn.")
- Hypothesis-shape reference (6 situations × 1 action line each)
- Dispatch grammar (3 lines: single-plan, multi-plan, freeform)
- Citation to `docs/contracts/driver-reference.md` for theory

`skills/auto/SKILL.md`: **budget ≤120 lines** (currently 366). Content
shape:
- YAML frontmatter
- Contract (3 lines): "drive work-loop to clean against the binding
  goal; the tick prepares, you execute, the harness wakes you on
  background completion."
- Goal binding (10 lines)
- Tick chain arming (15 lines)
- Work-loop fan-out policy (40 lines — this is the load-bearing skill
  body and stays inline)
- Exit + report (15 lines)
- Citations to `docs/contracts/driver-reference.md` for: prepare/execute
  theory, plan-loop livelock guard, state grammar table, outcomes-gated
  iteration mechanics.

Budgets — not exact targets — so the implementation finds its natural
shape. If the driver skill comes in at 48 lines or 58, both are fine;
≤60 is the bar. (Round-1 findings: Coherence C001+C003, Adversarial
ADV-7 — committing to ~30 was aspirational against actual responsibility
surface.)

New `docs/contracts/driver-reference.md` absorbs the moved content
(prepare/execute theory, livelock guard, state grammar table). Target
length: whatever it needs to be (~200-300 lines is the rough expectation
based on what's moving from the two skill files).

## Implementation Units

### U1. `auto-detect.sh` JSON rewrite + ledger `goal_intent` field

**Goal:** Replace TSV verdict output with the hypothesis JSON shape from
KTD-1. Add `goal_intent` to the ledger schema (KTD-2). Add
`resolve_host_repo_root()` + `resolve_shared_dir()` helpers (KTD-3).

**Dependencies:** none

**Files:**
- `lib/auto-detect.sh` (modify) — Python body emits JSON object directly
- `lib/_bootstrap.py` (modify) — add `resolve_shared_dir()`
- `lib/ledger.py` (modify) — add `goal_intent` field; recompute path
  preserves existing predicate logic
- `lib/auto.py` (modify) — write `goal_intent` at init from plan title
  or hypothesis
- `docs/contracts/ledger-schema.md` (modify) — document `goal_intent`
- `tests/unit/hypothesis-shape.test.sh` (new)
- `tests/unit/shared-dir-resolution.test.sh` (new)

**Approach:** The decision tree inside `auto-detect.sh` stays. Output
format changes from TSV to JSON. Add slots for the JSON envelope's
discriminated unions (`single_plan`, `multi_plan`, `in_flight`). When
hypothesis is `ambiguous-runs`, surface run-ids + descriptions (read
each ledger's `goal_intent` if present, fall back to run-id alone).

`resolve_shared_dir()` runs `git rev-parse --git-common-dir`, resolves
parent, joins `.claude/auto/`. Returns None if git is unavailable
(degrades gracefully to `_resolve_repo()` behavior).

**Test scenarios:**
- In-flight single run, plan present → hypothesis is `in-flight`,
  ambiguity null, dispatches without question
- In-flight 2 runs → hypothesis is `ambiguous-runs`, ambiguity has
  options array with both run-ids
- No run, 3 plans → hypothesis is `multi-plan`, `multi_plan.paths` has
  all three
- No run, no plan, clean tree → hypothesis is `raw`, ambiguity is open
  question ("what should we work on?")
- No run, no plan, uncommitted diff → hypothesis is `dirty-tree`,
  ambiguity null, summary derived from branch + diff
- Malformed ledger → skipped with stderr (parity with existing behavior)
- `goal_intent` round-trips through init_ledger and atomic_write
- `resolve_shared_dir()` inside a worktree resolves to the main repo's
  `.claude/auto/`; outside any git tree returns None

### U2. `lib/auto-spawn.py` — batch sidecar + worktree allocation

**Goal:** Given a multi-plan hypothesis, create worktrees + assign ports
+ write the batch sidecar. The DRIVER launches the backgrounded
invocations; this lib returns the manifest.

**Dependencies:** U1 (consumes `resolve_shared_dir`, hypothesis JSON shape)

**Files:**
- `lib/auto-spawn.py` (new) — orchestrator
- `docs/contracts/batch-sidecar-schema.md` (new) — sidecar schema
- `tests/unit/auto-spawn.test.sh` (new)
- `tests/unit/port-discovery.test.sh` (new)

**Approach (no `.sh` shim — round-1 finding: Scope F2 closed):**

1. Read the hypothesis's `multi_plan.paths`.
2. For each plan: derive slug from full filename stem
   (`docs/plans/B11-exit-reason-constants.md` →
   `B11-exit-reason-constants`). Collision check: append `-2`, `-3` if
   the worktree path already exists.
3. **Port discovery + sweep:** scan
   `resolve_shared_dir()/batches/*.json` for in-use ports across active
   batches; pick the lowest free integer in `[3001, 3099]`. If none
   free, raise `PortPoolExhausted` with a clear message. As part of the
   same scan, drop any sidecar still `provisional` with mtime older
   than `CLAUDE_AUTO_PROVISIONAL_TTL` (default 600s / 10 min) — this
   recovers ports from sidecars left behind by a process crash between
   step 6 (worktrees created) and step 7 (commit). The sweep is
   discovery-time cleanup; no separate GC pass needed. (Round-1: Scope
   F3 — port pool simplified. Round-4: R4-002 — crash-recovery sweep
   added.)
4. **Compute worktree root from the host repo.** Worktree paths are
   deterministic from the slug:
   `<host-repo-root>/worktrees/<slug>` where `<host-repo-root>` =
   `resolve_host_repo_root()` (NOT `git rev-parse --show-toplevel`,
   which returns the worktree's own path when called from inside a
   worktree — round-3 finding: R3-001).
5. **Write the batch sidecar as PROVISIONAL.** Sidecar carries ports
   + computed worktree paths, with `status: "provisional"`, written
   atomically to `resolve_shared_dir()/batches/<batch-id>.json`. This
   is the claim record other concurrent spawn invocations read from.
   Port discovery in step 3 reads BOTH provisional and committed
   sidecars as in-use (so concurrent spawns serialize on port
   selection), but the Stop hook in `on-stop.py` ignores provisional
   sidecars (so a half-built batch doesn't gate session exit).
   (Round-2: SG-R2-001 — step order. Round-3: R3-003 — provisional
   flag added to handle partial-failure rollback.)
6. Run `git worktree add <host-repo-root>/worktrees/<slug>
   -b auto/<slug>` for each plan.
7. **Commit the sidecar.** On full success, rewrite the sidecar with
   `status: "committed"`. On any `git worktree add` failure, tear down
   successfully-created worktrees from this batch (`git worktree
   remove` per slug) and delete the provisional sidecar; raise to the
   driver so it can report the failure.
8. Return the manifest (list of dicts: plan_path, worktree, port,
   suggested_run_id) for the driver to iterate.

The batch sidecar's `worktree` field carries an absolute path; this is
intentional so a future `auto-cleanup` command can iterate completed
batches and call `git worktree remove` without re-discovering paths.
(Round-2 finding: Coherence — cleanup-readiness made explicit; sidecar
schema should not be narrowed in a way that breaks this.)

**Sub-run dispatch contract — reuse the cmux spawn primitive proven by
`lib/cmux-socket.sh`.** The harness's native Agent/Task tool does not
expose `cwd` or `env` parameters (round-3 finding R3-002), AND naive
`bash -lc "claude '/auto <plan>' &"` does not work either: `claude`
defaults to an interactive tty-bound session and `-p` exits after the
first response, terminating before a multi-tick /auto loop can drive.
(Round-4 finding: R4-001 — verified against the actual CLI.)

`lib/cmux-socket.sh` already implements the working shape for this
exact case (backgrounded `/auto-resume <run>` invocations that survive
the parent session) and ships in this repo. The spawn shape is:

```
cmux new-workspace \
  --name "auto-fanout-<slug>" \
  --cwd "<worktree>" \
  --command "sleep 1; CLAUDE_AUTO_REPO=<worktree> claude '/auto <plan>'" \
  --focus false
```

Why this works (per cmux-socket.sh's documented mechanism): the
workspace is app-owned so it survives the parent exit; `--focus false`
preserves layout; the `sleep 1;` lead-in is load-bearing because
`--command` keystrokes can be swallowed by a still-initializing login
shell.

U2 implementation: factor a reusable bash function
`auto::cmux_spawn_workspace <name> <cwd> <command>` out of
`lib/cmux-socket.sh` — the actual `cmux new-workspace` invocation
from `auto::spawn_resume`, minus the double-drive guard and runaway
sentinel (neither applies at fanout-start). `auto::spawn_resume`
keeps its existing guards and now calls the factored helper for
the cmux invocation. `lib/auto-spawn.py` shells out to the same bash
function per worktree (cmux-socket.sh becomes a sourceable library
for the helper). `auto::build_spawn_command` (the string-echo used
by tests) stays untouched. Round-5 clarification: the helper's
signature is bash, three args; both Python and bash callers shell
out to the same surface.

Fallback when cmux isn't available: surface a clear error from
`auto-spawn.py` ("cmux required for multi-plan fanout — install or
run plans sequentially with /auto <plan> per plan"). A non-cmux
fallback path is deferred to a separate plan.

**Test scenarios:**
- 3 plans → 3 worktrees, 3 distinct ports in 3001-3099, sidecar
  written as `committed` after all worktrees succeed
- Re-spawn same plan in same session → slug collision → appended `-2`
- Port range exhausted (mock 99 pre-claimed across both provisional
  and committed sidecars) → raises with clear message
- Two concurrent calls to `auto-spawn.py` on the same shared dir → both
  read each other's provisional sidecar and pick distinct ports
- Worktree path is `<resolve_host_repo_root>/worktrees/<slug>` —
  verified by spawning from inside a worktree of the host repo; the
  new worktree lands under the MAIN repo's `worktrees/`, not nested
  under the calling worktree (round-3 R3-001 regression test)
- Partial-failure rollback: 3 plans where plan #2's `git worktree
  add` is mocked to fail → plan #1's worktree is removed, the
  provisional sidecar is deleted, the error is raised to the driver,
  no orphaned port claims remain
- Crash-recovery sweep: a provisional sidecar older than the TTL is
  silently dropped on the next port-discovery scan; its ports become
  available again
- cmux dispatch: spawn primitive matches `cmux new-workspace --command
  "sleep 1; CLAUDE_AUTO_REPO=<worktree> claude '/auto <plan>'" --focus
  false` (the shape proven by `lib/cmux-socket.sh`)
- cmux unavailable: `auto-spawn.py` raises with a clear error
  ("cmux required for multi-plan fanout") — does not silently fall
  back to a broken dispatch shape
- Stop hook sees a provisional sidecar → does NOT gate session exit
  on the (partial) batch
- Backgrounded sub-run's ledger writes land at
  `<worktree>/.claude/auto/<run>.json` (NOT at `~/.claude/auto/`),
  verified by spawning a sub-run under a fixture with no `.claude/auto/`
  pre-created and confirming the ledger file location post-run

### U3. Default seam flip + back-compat notice

**Goal:** Flip `lib/auto.py`'s default for the `auto` token; surface a
one-time stderr notice on the first run after upgrade for users who
relied on the seam pause.

**Dependencies:** U1 (uses `resolve_shared_dir()` for the marker file
path so the notice fires once per host repo, not once per worktree —
round-2 finding: Scope SG-R2-002 — dependency declared).

**Files:**
- `lib/auto.py` (modify) — default for `auto` flips to True; `--review-plan`
  flag added (sets `auto` False)
- `commands/auto.md` (modify) — argument grammar updated
- `tests/unit/seam-default.test.sh` (new)

**Approach:** Minimal change. In `_parse_args`, the `auto` positional
default becomes True; a new `--review-plan` flag (when present) sets it
False. Update argument-hint in `commands/auto.md` to reflect the new
default. On first run after upgrade (detected by absence of a
`<resolve_shared_dir>/.seam-default-acknowledged` marker), emit a stderr
notice with the new flag and a one-line summary of what changed, then
write the marker.

(Round-1 finding: Adversarial ADV-5 / inferred-goal-mistrust — the
default-flip avoids this problem entirely because there's no
divergence-comparison step. The trade-off is the operator never gets
auto-divergence-detection; they opt in to a pause when they want one.
That's the right trade today.)

**Test scenarios:**
- `/auto <plan>` (no `auto` token, no `--review-plan`) → arg parsing
  produces `auto: True`, run proceeds past the seam
- `/auto <plan> --review-plan` → arg parsing produces `auto: False`,
  run pauses at the seam
- First run after upgrade emits the stderr notice exactly once; the
  marker file appears; subsequent runs are silent

### U4. Skill rewrites + driver-reference doc

**Goal:** Cut `auto-driver/SKILL.md` to ≤60 lines and `auto/SKILL.md` to
≤120 lines. Move theory to `docs/contracts/driver-reference.md`.

**Dependencies:** U1, U2, U3 (the new shapes must exist before the skills
narrate them). Note: U5 was originally proposed; merged into U4 below.

**Files (skill rewrites + new reference doc):**
- `skills/auto-driver/SKILL.md` (rewrite)
- `skills/auto/SKILL.md` (rewrite)
- `docs/contracts/driver-reference.md` (new)
- `commands/auto.md` (modify — drop verdict-routing prose, point at the
  new skill)

**Files (batch-aware Stop hook + composite status, formerly U5):**
- `lib/on-stop.py` (modify) — discover active batches via
  `resolve_shared_dir`, check sub-run terminal states
- `lib/goal-status.py` (modify) — render composite status string from
  batch sidecar
- `tests/unit/batch-stop-discovery.test.sh` (new)
- `tests/unit/composite-goal-string.test.sh` (new)

**Approach:** Driver skill is a four-step funnel (the line count claim
in the previous draft was aspirational; the budget is now ≤60):

1. Run `lib/auto-detect.sh`, parse the JSON.
2. Surface `summary` (one line).
3. If `ambiguity` is null → dispatch:
   - `single_plan` → `bash lib/auto.sh "<path>"`
   - `multi_plan` → call `python lib/auto-spawn.py`. The spawner does
     everything: creates worktrees, assigns ports, AND spawns each
     backgrounded `/auto <plan>` via the cmux primitive (see U2's
     dispatch contract — the reusable helper factored out of
     `lib/cmux-socket.sh`). Returns the manifest for the driver to
     surface ("3 plans dispatched: B11 (port 3001), B12 (port 3002),
     B13 (port 3003)"). The driver does NOT shell out itself; the
     dispatch lives in the spawner so the lib stays the source of
     truth for the spawn shape.
   - `raw` (no signal) → AskUserQuestion "what should we work on?"; on
     answer, treat as freeform
   - freeform text → invoke `/ce-plan <text>` via Skill tool and END
     THE TURN. After `/ce-plan`'s multi-turn flow lands a plan file
     (turns later, possibly after operator AskUserQuestion answers),
     the operator re-invokes `/auto`. The hypothesis funnel then
     re-enters, sees the new plan, and dispatches.
4. If `ambiguity` is non-null → AskUserQuestion with the options array;
   on answer, branch as if the ambiguity were resolved at hypothesis
   time. End turn.

The freeform branch is NOT a same-session trampoline. `/ce-plan` is a
multi-turn skill and the harness does not return control to auto-driver
after it completes. Matching the existing `raw`-case behavior
(recommend, stop, operator re-invokes) is the honest fix. An automatic
plan→auto re-entry would need a SessionStart or PostToolUse hook and
is deferred to a separate plan. (Round-2 finding: Feasibility R2-002 —
the originally-proposed trampoline is removed.)

The loop skill (`auto/SKILL.md`) keeps the goal-binding + tick-arming +
work-loop fan-out sections. Drops: the OUTPUT VOICE preamble, the
prepare/execute essay, the deepen↔review livelock warning, the state
grammar table. Those move to `driver-reference.md` and are cited inline
by section anchor.

**Composite goal for batches** (formerly U5, now absorbed): when the
driver dispatches multiple sub-runs in step 3 above, it composes one
goal string from the batch sidecar's `composite_intent` ("ship plans
B11, B12, B13 reviewed and clean") and activates harness `/goal` against
it. The Stop hook (existing `on-stop.py`) already scans all ledgers
under the worktree's `.claude/auto/`; for batch awareness, on-stop.py is
extended to also scan the parent's `<resolve_shared_dir>/batches/` for
active batches with `status: "committed"` and check each recorded
sub-run's terminal state. Provisional sidecars are ignored (round-3
R3-003 — they may belong to a failed half-built batch). Stop fires
when every committed batch's sub-runs all have predicate met. (Round-1
findings: Scope F6 — `on-stop.py` change clarified; Coherence C002 —
U4 now owns the batch narration too, no separate U5.)

**Test scenarios:**
- `wc -l skills/auto-driver/SKILL.md` ≤ 60; `wc -l skills/auto/SKILL.md`
  ≤ 120
- `grep -l "OUTPUT VOICE" skills/auto*` returns nothing
- `driver-reference.md` contains the moved sections; each skill has at
  least one citation back to it
- Batch of 3 sub-runs, all clean → composite predicate met, on-stop
  fires
- Batch of 3 sub-runs, 1 in-flight → composite not met
- Composite string format: "ship plans B11, B12, B13 clean (2/3 done)"
- Freeform `/auto fix the login bug` → `/ce-plan` is invoked with
  "fix the login bug"; on `/ce-plan` completion, driver re-enters and
  the new plan is picked up

## Test Strategy

Stdlib-only bash tests under `tests/unit/`, consistent with the existing
project convention. `bash tests/run.sh all` must pass at green.

Integration test: `tests/integration/bare-auto-fanout.test.sh` runs the
bare-`/auto` funnel against a fixture repo with three plans, verifies
that three worktrees are created, three ports are assigned from the
3001-3099 range, three backgrounded runs launch, and the batch sidecar
records all three.

## Risks & Open Questions

**R1 — Agent tool cwd contract (load-bearing).** U2 dispatches background
runs with explicit cwd=worktree. If the harness Agent tool does not
support cwd, the spawn primitive falls back to shelling out a fresh
`claude` CLI with `--cwd`. Verify the contract in U2 before merging;
document the fallback path explicitly so an implementer doesn't have to
re-derive it.

**R2 — Port-pick race under truly concurrent fanout.** Two `auto-spawn.py`
processes running simultaneously could both read the same in-use set
before either writes its sidecar. The plan mitigates by writing the
sidecar atomically BEFORE issuing `git worktree add`. For single-operator
flow (the actual use case), genuine concurrency is unlikely. If it
becomes a real problem, add flock at that point — not preemptively.

**R3 — Worktree accumulation.** Worktrees stay until manual `wtc`. Listed
as out-of-scope, but the batch sidecar records worktree paths so a
follow-up cleanup command can iterate completed batches and call
`wt remove`.

**R4 — Inferred goal for `dirty-tree`.** The hypothesis derives a goal
sentence from branch + diff when no plan exists. If the inference is
wrong, the operator sees the wrong summary line. Mitigation: the summary
IS the operator's confirm — if it's wrong, they say so and the driver
asks. This is acceptable because the goal_intent is one line and visibly
surfaced; the operator sees it before any work happens. Not a load-
bearing problem.

**Open Q1.** For `multi-plan` fanout, the batch uses a single recipe
across all sub-runs (a1 by default). If different plans want different
recipes, the operator can dispatch them separately. Per-plan recipe
detection is deferred. Confirm this is the right default before U2
merges.

**Open Q2.** `goal_intent` on the per-run ledger is currently
derived-and-frozen at init time. If the operator wants to revise it
mid-run, no surface exists today. Deferred — not a load-bearing problem
for v0.4.0.

## Sequencing

U1 first (foundation: hypothesis JSON, ledger field, shared-dir helper).
U2 and U3 in parallel after U1 (both independent of each other). U4 last
among the lib + skill changes (the skills narrate the new shape, so the
shape must exist first). Integration test is U4-adjacent.

## Success Criteria

- `/auto` (bare, no args) in a repo with one reviewed plan dispatches the
  plan with zero questions and one summary line.
- `/auto` in a repo with three plans creates three worktrees, assigns
  three distinct ports from `[3001, 3099]`, launches three backgrounded
  runs, and writes the batch sidecar — with one confirmation.
- `/auto <freeform text>` invokes `/ce-plan <text>` and ends the
  driver turn. After the plan lands, the operator re-invokes `/auto`
  and the hypothesis picks up the new plan with no further question.
  (Same-session trampoline was originally proposed; not implementable
  given Skill semantics — see KTD note in U4 and round-2 finding
  R2-002.)
- `/auto` in a fresh repo (no plan, no diff) asks one question
  ("what should we work on?") and proceeds.
- `/auto` over a resumable run resumes silently with one summary line.
- `wc -l skills/auto-driver/SKILL.md` ≤ 60; `wc -l skills/auto/SKILL.md`
  ≤ 120.
- `/auto <plan>` proceeds past the seam by default; `/auto <plan>
  --review-plan` pauses for review.
- The back-compat stderr notice fires exactly once after upgrade.
- All existing `bash tests/run.sh all` pass; new unit + integration
  tests pass.

## Sequencing-decision note

This plan is being prepared while the v0.3.1 backlog (B1, B2, B3, B9 in
`docs/plans/2026-05-27-001-feat-auto-v0.3.1-backlog.md`) is partially
unfinished. The backlog items address concrete defects identified by
prior review rounds; this plan addresses operator-friction signal from
the current session. Both are legitimate; sequencing is the operator's
call. Surfaced explicitly so the trade-off is visible. (Round-1
finding: Product 007.)
