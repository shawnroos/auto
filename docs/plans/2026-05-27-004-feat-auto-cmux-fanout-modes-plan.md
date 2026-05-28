---
title: "auto: project-as-workspace, in-pane tab fanout via cmux layout"
status: active
created: 2026-05-27
type: feat
blocked_by: docs/plans/2026-05-27-002-feat-auto-bare-entry-and-fanout-plan.md
---

# auto: project-as-workspace, in-pane tab fanout via cmux layout

## Summary

Reshape auto's fanout dispatch so multi-plan runs land as **tabs in the
left pane of the current cmux workspace** instead of as new top-level
workspaces. Make `/auto new <project>` create a fresh project workspace
with an opinionated layout (left = agent-session tabs, right =
documents / browsers / other surfaces). The workspace becomes the
durable, visual representation of *what the project IS right now* —
each tab in the left pane is an active sub-run; the right pane is
operator territory.

Anchored on cmux's `new-workspace --layout <json>` primitive — a
single declarative call that creates the split + initial surfaces +
their commands. This is significantly cleaner than the `new-workspace`
+ `new-split` + `new-surface` + `send` chain the original design
would have needed.

This plan is **gated on plan 002 (v0.4.0) merging**: it modifies the
cmux primitive that v0.4.0 just factored out
(`auto::cmux_spawn_workspace`), and reuses the batch sidecar
lifecycle. Worktrees stay as-is per Shawn — fanout still creates one
worktree per plan (git isolation); this plan changes only how the
spawn surface lands (workspace → tab in left pane).

## Problem Frame

1. **Subagents can't fan out further.** The harness's native `Agent`
   tool spawns subagents that can NOT themselves dispatch more
   background subagents — fan-out depth is capped at one layer from a
   live session. cmux dispatch gets around this: each spawned
   workspace runs its own `claude` process, which is itself capable of
   another fan-out. Recursive in-place orchestration via cmux is the
   real mechanism v0.4.0's fanout discovered, but the current shape
   (top-level workspaces only) doesn't take full advantage.

2. **Workspaces today are disposable.** They're "an editor session you
   happened to open." A workspace doesn't represent anything beyond
   "where I was when I started claude." Yet operationally, the
   workspace IS the project — its panes, tabs, and surfaces ARE what's
   in flight. Making this explicit unlocks: durable project state,
   visual fan-out without sidebar spam, queryable status via cmux
   layout inspection.

3. **Multi-plan fanout pollutes the sidebar.** Today's
   `auto::cmux_spawn_workspace` creates one workspace per plan in a
   batch — 3 plans = 3 new sidebar entries adjacent to whatever else
   is in the sidebar. For related work (3 plans of one initiative),
   this fragments the visual organization.

4. **No project-creation primitive.** Today there's no `/auto new
   <project>` — operators start projects by manually opening a
   terminal, navigating to a repo, then running `claude`. The
   opinionated layout (left = agent sessions as tabs, right =
   documents) has to be reconstructed manually every time.

5. **Auto and cmux are integrated but not composed.** Auto already
   uses cmux for orphan recovery (`lib/cmux-socket.sh`) and fanout
   (`lib/auto-spawn.py`). cmux already has crex for layout
   persistence. But auto doesn't write workspace state in a way
   crex / cmux UX consumers can read meaningfully. The workspace's
   pane / tab structure isn't a first-class artifact yet.

## Scope

### In scope

- **U1 (gated spike):** Empirically verify that `cmux new-workspace
  --layout <json>` reliably creates a left/right split with the left
  pane carrying the project's primary `claude` session, that
  subsequent `cmux new-surface --pane <left-pane-ref>` produces a tab
  in that pane's tab strip, that `--command` on a surface in the
  layout JSON reliably starts the command (including with the
  `sleep 1;` lead-in for shell-init timing), and that recursion works
  (a `claude` inside a tab can fan out into more tabs in the same
  left pane).
- **U2:** New primitive `lib/auto-cmux.py` (or extend
  `lib/cmux-socket.sh`) with `auto::cmux_spawn_tab <pane-ref> <cwd>
  <command>` — the in-pane analog of `auto::cmux_spawn_workspace`.
  Keep the existing workspace primitive for non-project contexts.
- **U3:** Rework `lib/auto-spawn.py::_spawn_via_cmux` to dispatch tabs
  in the current workspace's left pane when invoked inside a project
  workspace, falling back to `new-workspace` only when no project
  workspace context is detected.
- **U4:** Project-workspace creation as a skill behavior, NOT a
  separate command. The `auto-driver` skill detects "I'm not in a
  project workspace yet" as part of its hypothesis funnel and offers
  to create one as the action for the situation. The operator types
  `/auto` (per v0.4.0); the skill — based on detection — either
  dispatches in the existing project workspace or first creates one,
  then dispatches. Detection layer in the hypothesis envelope; the
  decision lives where every other smart-entry decision lives.
- **U5:** Document the contract between auto's workspace state and
  crex. Auto writes pane/tab IDs to the marker; crex can snapshot the
  layout for restore. No code change to crex; just spec the
  read-side.

### Deferred / out of scope

- **Right-pane automation.** Auto does not touch the right pane.
  Surfaces there (editor, plan-doc viewer, browser, mood board) are
  operator territory. A future plan could add `/auto open-doc <path>`
  that opens a markdown viewer in the right pane, but it's not load-
  bearing for the fanout reshape.
- **Depth-aware layout policy.** The single-tab-strip model means
  recursive fanouts add tabs to the same strip regardless of depth.
  Whether deeper layers should collapse into sub-tabs or different
  visual treatment is a UX question deferred to a follow-up plan once
  there's evidence the flat tab strip becomes unmanageable.
- **Cross-workspace operations.** "Move this tab to its own
  workspace" / "merge two project workspaces" — power user moves not
  on the critical path. cmux already has `move-tab-to-new-workspace`
  for manual flow.
- **Replacing `auto::cmux_spawn_workspace` for the
  `/auto-resume` orphan-recovery case.** That path stays at
  workspace-level (an orphaned run is by definition outside any live
  project workspace; restoring it as a fresh workspace is correct).
  This plan adds the tab primitive alongside.
- **Workspace name / appearance customization beyond what's needed
  for /auto new.** No theme system, no per-recipe color coding, no
  icon picker. Keep the layout opinionated and uniform.

## Key Technical Decisions

### KTD-1: Anchor on `cmux new-workspace --layout <json>`

cmux's `new-workspace` accepts a `--layout <json>` arg that creates
the split + initial surfaces + per-surface commands in ONE call. The
schema is the same as `cmux.json` layout definitions (per the
`--help` output). This is the right primitive because:

1. **Atomic.** One process invocation creates the entire workspace
   state. Compared to `new-workspace` → `new-split right` →
   `new-surface --pane left` → `send "sleep 1; claude..."` (four
   subprocesses, three timing-fragile), the single layout JSON eliminates
   intermediate failure modes.
2. **Declarative.** The layout JSON is inspectable, snapshot-able,
   versionable. Crex composition becomes a JSON merge instead of a
   sequence of recorded commands.
3. **Per-surface commands.** Layout JSON lets each surface declare
   its own `command` — so the initial `claude` session in the left
   pane is part of the workspace creation, not a follow-up.

The spike (U1) verifies the exact layout-JSON schema cmux accepts and
the resulting pane/surface ref handling. U2-U5 build on the
verified shape.

### KTD-2: Workspace marker as the project signal

A workspace is an "auto project" iff a marker file exists at
`<repo>/.claude/auto/workspace.json`. The marker records:

```json
{
  "workspace_id": "<cmux-workspace-uuid>",
  "created_at": "<iso>",
  "layout_version": "v1",
  "left_pane_id": "<cmux-pane-uuid>",
  "right_pane_id": "<cmux-pane-uuid>",
  "primary_surface_id": "<cmux-surface-uuid>",
  "tabs": [
    {"surface_id": "<uuid>", "kind": "primary | fanout | manual",
     "plan": "<repo-rel-path|null>", "run_id": "<id|null>"}
  ]
}
```

The marker is the **single source of truth** for whether `/auto`
should dispatch tabs (project workspace present) or fall through to
workspace-level fanout (no project workspace). It also enables crex
to snapshot the project's layout for restore.

`auto-spawn.py` reads `$CMUX_WORKSPACE_ID` (cmux exposes it as env);
if the marker's `workspace_id` matches, this IS the project
workspace and fanout dispatches tabs. Otherwise, fanout creates a
new workspace per plan (the v0.4.0 behavior).

### KTD-3: Worktrees + tabs are orthogonal — keep both

Per Shawn: "it would work alongside the worktree." This plan changes
ONLY the cmux dispatch surface (workspace → tab in left pane).
Worktree allocation (one git worktree per plan) stays as it is in
v0.4.0:

- 3 plans → 3 git worktrees under `<host-repo>/worktrees/<slug>/`
- 3 tabs in the left pane, each with `cwd=<worktree>` and
  `CLAUDE_AUTO_REPO=<worktree>` env
- Visual: one workspace, three sibling tabs running concurrently
- Git: three isolated trees, no stomp risk

The batch sidecar gains one new optional field: `cmux.tab_surface_id`
per plan, recording which tab the sub-run is running in. On-stop
discovery and stop-blocking logic are unchanged (they read the
worktree's per-run ledger).

### KTD-4: Workspace creation is a skill behavior, not a command

Per Shawn: "also want this handled via the skill itself
automatically." Project workspaces are created as part of the normal
`/auto` flow when context dictates, NOT via a separate `/auto new`
command. The skill detects "this should be a project workspace" and
acts.

**The hypothesis envelope (`lib/auto-detect.sh`) gains TWO new
fields:**

```json
{
  "situation": "...",
  ...,
  "workspace": {
    "status": "project | non-project | unmarked",
    "marker_path": "<abs-path>|null",
    "workspace_id": "<cmux-uuid>|null",
    "left_pane_id": "<cmux-uuid>|null",
    "env_workspace_id": "<value-of-$CMUX_WORKSPACE_ID>|null"
  },
  "workspace_action": "none | create | use | recreate"
}
```

- `workspace.status`:
  - `project` — marker exists AND `$CMUX_WORKSPACE_ID` matches → we
    ARE in the project's workspace; dispatch tabs in-place.
  - `non-project` — marker exists BUT `$CMUX_WORKSPACE_ID` doesn't
    match (operator opened claude outside the project workspace) →
    skill surfaces this and offers to switch / create new.
  - `unmarked` — no marker → this repo doesn't have a project
    workspace yet; skill offers to create one.

- `workspace_action`:
  - `none` — situation doesn't warrant workspace work (e.g. resume
    of an in-flight run in the same workspace).
  - `create` — no marker, hypothesis recommends creating one. Skill
    creates the workspace BEFORE dispatching the run.
  - `use` — marker matches; skill dispatches tabs in this workspace.
  - `recreate` — marker exists but stale (cmux says the workspace
    doesn't exist anymore); skill recreates.

**The skill's flow becomes:**

1. Load hypothesis as today (v0.4.0).
2. Check `workspace.status` + `workspace_action`.
3. If `workspace_action == "create"`: build the layout JSON, invoke
   `cmux new-workspace --layout`, capture the returned IDs, write
   the marker. Then proceed to step 4 with `workspace_action` now
   effectively `use`.
4. Dispatch per situation (single plan / multi-plan / etc.) —
   tab-mode if marker matches, fallback to workspace-mode otherwise.

No new slash command. No operator memorization of `/auto new <name>`
or `/auto init`. The skill handles it as part of the same one-line
action contract: surface the summary, act.

**When the skill creates a workspace:**

- The summary line reads "Creating project workspace for `<name>`
  and starting `<plan>`" (or similar — concise, one line, names
  what's happening) so the operator sees both actions.
- The workspace is created via `cmux new-workspace --layout
  <json>` with the opinionated layout (KTD-1 + KTD-2).
- The marker is written atomically. Failure to write the marker
  raises (the workspace would be live without auto knowing it,
  which would break future fanout).

**Edge case — operator inside a non-project workspace.** If
`workspace.status == "non-project"` (e.g. operator opened claude
manually inside an unrelated workspace), the hypothesis surfaces
that ambiguity:

- Option A: "switch to existing project workspace (`<workspace-id>`)"
  → skill outputs the cmux ID; operator clicks to switch; re-invokes.
- Option B: "create a new project workspace in cwd" → KTD-4 create
  path.
- Option C: "dispatch here anyway (one-off run, no workspace)" →
  falls back to v0.4.0 workspace-per-plan behavior.

This is a real ambiguity (the env says one thing, the marker says
another); ask the operator. One question, then act.

### KTD-5: Fanout dispatch is depth-aware in one direction only

A sub-run inside a tab can itself fan out. When it does,
`auto-spawn.py` detects (via `$CMUX_WORKSPACE_ID` matching the
marker's `workspace_id`) that it's running inside a project
workspace, and dispatches NEW tabs into the SAME left pane. This is
recursion — a plan's tab can spawn more tabs as siblings.

There is no "tabs nesting" abstraction. All fanout tabs go to the
same flat strip. If this becomes unmanageable (20+ active tabs),
the operator manually closes idle ones (cmux's `close-surface` or
similar). A future plan can add depth visualization or
auto-collapsing if the flat-strip approach proves insufficient.

The Stop hook (`lib/on-stop.py`) continues to work unchanged: each
tab's sub-run has its own ledger at `<worktree>/.claude/auto/`, the
batch sidecar at `<shared-dir>/batches/` lists all sub-runs, the
hook blocks until every sub-run's predicate is met.

## Implementation Units

### U1. Gated spike — verify cmux layout JSON + recursive tab fanout

**Goal:** Empirically verify the load-bearing primitives work as
described in KTD-1 before building U2-U5 on them. PASS → build U2-U5
as planned. FAIL → revise the dispatch shape.

**Dependencies:** none (gating spike, runs first)

**Files:**
- `docs/research/cmux-layout-fanout-spike.md` (new) — protocol + results
- `tests/spike/cmux-layout/` (new) — fixtures
  - `single-split-layout.json` — minimal layout JSON for verification
  - `with-claude-command.json` — layout that spawns a claude session
- No production code in this unit.

**Approach:** Three test runs against a real cmux instance.

**Run A — Workspace creation via layout JSON.**
- Build a layout JSON declaring a 50/50 left/right split, left pane
  with a `claude` command, right pane empty.
- Invoke `cmux new-workspace --layout <json> --name spike-A`.
- Verify: workspace appears in sidebar; split is visible at expected
  ratio; left pane has a running `claude` process; right pane is
  empty; `cmux new-workspace --help` output (or equivalent
  introspection) returns the pane + surface IDs cleanly.

**Run B — Add a tab to the left pane.**
- After Run A, identify the left pane's ID.
- Invoke `cmux new-surface --pane <left-pane-id>` then `cmux send
  --surface <new-surface-id> "sleep 1; claude '/auto-status'\n"`.
- Verify: a new tab appears in the left pane's tab strip; the
  `claude` command starts and produces output; the existing tab
  (Run A's primary session) is unaffected.

**Run C — Recursion: tab spawns another tab.**
- Inside the Run B tab's `claude` session, dispatch another
  `cmux new-surface --pane <left-pane-id>` (from inside the tab).
- Verify: a third tab appears as a sibling in the left pane;
  `$CMUX_WORKSPACE_ID` is the same across all three.

**Spike doc records:**
- The exact layout JSON shape cmux accepted (the `--help` description
  is "same schema as `cmux.json` layout definitions" — verify what
  that schema actually looks like).
- Whether `cmux new-workspace --layout` returns the created IDs in
  a parseable form on stdout.
- Whether `$CMUX_WORKSPACE_ID` propagates to surfaces created via
  `new-surface`.
- Whether `cmux send` after `new-surface` reliably starts the
  command, including the `sleep 1;` lead-in question.
- Whether tabs in a pane have a visible tab strip in the default
  cmux theme (UX check).

**Decision gate:**
- **A + B + C pass cleanly** → KTD-1 verified. U2-U5 build as planned.
- **A passes, B requires a workaround (e.g. `send` swallows the
  first chars)** → KTD-1 verified with adjustment. U2 documents the
  workaround.
- **A fails (layout JSON doesn't behave as `--help` claims)** → spike
  reshapes the dispatch. Possible fallback: chain
  `new-workspace` + `new-split` + `new-surface` + `send` calls
  manually, accepting the multi-process timing risk.

### U2. New tab-spawn primitive in cmux-socket.sh

**Goal:** Add `auto::cmux_spawn_tab <pane-ref> <cwd> <command>` to
`lib/cmux-socket.sh` alongside the existing
`auto::cmux_spawn_workspace`. Both are factored helpers; both honor
the `sleep 1;` lead-in and `--focus false` discipline.

**Dependencies:** U1 PASS

**Files:**
- `lib/cmux-socket.sh` (modify) — add `auto::cmux_spawn_tab`
- `tests/unit/cmux-spawn-primitives.test.sh` (new) — fixture
  invocations against a stub cmux binary (the same pattern as the
  v0.4.0 fanout test)

**Approach:** `auto::cmux_spawn_tab` runs `cmux new-surface --pane
<pane-ref> --focus false`, captures the new surface ref, then runs
`cmux send --surface <surface-ref> "sleep 1; cd <cwd> &&
<command>\n"`. The `sleep 1;` lead-in matches the workspace-spawn
contract: the shell initializing in the new surface might swallow
the first keystrokes.

If U1 surfaced an alternative shape (e.g. cmux gains a `--command`
flag on `new-surface` between this writing and U1's run), U2 uses it
instead — the spike output dictates this unit's body.

**Test scenarios:**
- Stub cmux records argv; `auto::cmux_spawn_tab pane:1 /tmp/wt
  "claude '/auto plan.md'"` invokes `new-surface --pane pane:1
  --focus false` followed by `send --surface <captured-ref> "sleep
  1; cd /tmp/wt && claude '/auto plan.md'\n"`.
- Failure case: `new-surface` returns non-zero → function returns
  non-zero with a clear error (no `send` issued).
- The `--focus false` default is preserved (no operator surprise of
  the fanout stealing focus).

### U3. auto-spawn.py routes to tab vs workspace by context

**Goal:** When invoked inside a project workspace (marker file
exists AND `$CMUX_WORKSPACE_ID` matches), `auto-spawn.py` dispatches
each sub-run as a tab in the left pane. Otherwise (no marker, or
mismatched workspace), it falls back to the v0.4.0 workspace-per-plan
behavior.

**Dependencies:** U1 PASS, U2 (consumes the new helper)

**Files:**
- `lib/auto-spawn.py` (modify) — `_spawn_via_cmux` branches on
  project-workspace detection
- `lib/auto-workspace.py` (new) — read/validate workspace marker;
  resolve left-pane ref
- `docs/contracts/batch-sidecar-schema.md` (modify) — add optional
  `cmux.tab_surface_id` per plan
- `tests/unit/auto-spawn-tab-mode.test.sh` (new)

**Approach:**

1. At dispatch time, `_spawn_via_cmux` resolves the project
   workspace marker via `auto_workspace.read_marker(host_repo)`. If
   None → workspace-level dispatch (current behavior).
2. If marker exists, verify `$CMUX_WORKSPACE_ID` matches
   `marker.workspace_id` (operator's cmux session IS the project).
   Mismatch → log a stderr notice, fall back to workspace dispatch.
3. Match: for each plan in the manifest, call
   `auto::cmux_spawn_tab <marker.left_pane_id> <worktree>
   "claude '/auto <plan-rel>'"`. Capture the returned surface_id;
   record it in the batch sidecar's `plans[i].cmux.tab_surface_id`.
4. Append the surface_id to the marker's `tabs[]` with
   `kind: "fanout"`.

**Test scenarios:**
- No marker → falls back to `new-workspace` dispatch (v0.4.0 parity).
- Marker present, env matches → all sub-runs spawn via
  `cmux_spawn_tab`; batch sidecar carries the surface_ids.
- Marker present, env mismatch → stderr notice + workspace fallback;
  no marker mutation.
- Marker references a pane that no longer exists (operator deleted
  the left pane) → graceful failure (raise `WorkspaceLayoutChanged`
  with a clear message recommending `/auto init --force`).
- Multiple concurrent calls to `auto-spawn.py` against the same
  marker → marker writes are atomic (use the same atomic-write
  primitive as the batch sidecar).

### U4. Hypothesis envelope + skill workspace handling

**Goal:** Project workspaces are created and used by the `auto-driver`
skill automatically based on hypothesis state. No new slash commands.
The operator types `/auto` (per v0.4.0); the skill decides whether to
create a workspace, use one, or skip and fall back.

**Dependencies:** U1 PASS (uses layout JSON), U3 (consumes the
marker — tab-mode dispatch)

**Files:**
- `lib/auto-detect.sh` (modify) — emit `workspace` + `workspace_action`
  fields in the hypothesis envelope
- `lib/auto-workspace.py` (new) — marker read/write/validate + cmux
  state probing + workspace-creation orchestrator (called by the
  skill, not by a slash command)
- `skills/auto-driver/SKILL.md` (modify) — add workspace-handling
  step to the funnel (between "load hypothesis" and "dispatch")
- `docs/contracts/workspace-marker-schema.md` (new) — marker format
- `tests/unit/workspace-detection.test.sh` (new) — hypothesis
  envelope correctly reports workspace status
- `tests/unit/workspace-creation.test.sh` (new) — `auto_workspace.create`
  produces the right layout JSON and writes a valid marker

**Approach (skill flow):**

The skill loads the hypothesis JSON (existing v0.4.0 step). Before
dispatching the situation, it checks `workspace_action`:

- `none` → straight to dispatch (existing behavior).
- `use` → the marker matches the current workspace; dispatch in
  tab-mode (U3's primary path).
- `create` → call `auto_workspace.create(<host_repo>)` which:
  1. Builds the layout JSON (50/50 left/right split; left pane
     with the primary claude session; right empty).
  2. Invokes `cmux new-workspace --layout <json>` with name derived
     from the repo's directory name.
  3. Captures returned IDs.
  4. Writes the marker atomically.
  5. Returns the marker so the skill can dispatch tabs into the
     new workspace's left pane immediately.
- `recreate` → same as create but skips the "refuse if marker
  exists" check (the marker is stale; cmux says the workspace is
  gone).
- non-project ambiguity → AskUserQuestion with three options (switch
  / create here / one-off without workspace), then route per answer.

**Detection logic in `auto_workspace.detect(host_repo)`:**

```
marker_path = host_repo / .claude/auto/workspace.json
env_ws = os.environ.get("CMUX_WORKSPACE_ID")

if not marker_path.exists():
    return {"status": "unmarked", ...}

marker = read(marker_path)
if not cmux_workspace_exists(marker.workspace_id):
    return {"status": "unmarked", "marker_stale": True, ...}

if env_ws == marker.workspace_id:
    return {"status": "project", ...}    # we ARE in it
else:
    return {"status": "non-project", ...}  # marker exists, we're elsewhere
```

`workspace_action` derives from `status` + the rest of the
hypothesis: `unmarked` + situation is `reviewed-plan` or
`multi-plan` → `create`; `project` + same situations → `use`;
`non-project` → leave for the skill to ask.

**Skill body change (auto-driver/SKILL.md):**

Add one paragraph between "Load the hypothesis" and "Dispatch":

```
## Workspace handling

After loading the hypothesis, check `workspace_action`:

- `use`: this IS the project workspace; tab-mode dispatch is automatic
  (U3 reads the same marker).
- `create`: call `bash lib/auto-workspace.sh create <host_repo>` —
  creates the workspace, writes the marker, prints the new
  workspace_id. Surface "Creating project workspace for `<name>`"
  in the summary line.
- `recreate`: same, prefixed "Recreating workspace (previous one
  was closed)".
- ambiguity (non-project): AskUserQuestion with the three options
  from `workspace.ambiguity_options`; on answer, route accordingly.

No separate slash command — the workspace is just part of how `/auto`
starts a project.
```

**Test scenarios:**
- Unmarked repo + reviewed-plan situation → `workspace_action ==
  "create"`; calling `auto_workspace.create` produces a valid
  workspace, writes the marker, returns the IDs.
- Marker present + `$CMUX_WORKSPACE_ID` matches → `workspace_action
  == "use"`.
- Marker present + `$CMUX_WORKSPACE_ID` mismatched → `status ==
  "non-project"`; `workspace_action == "none"` (skill asks).
- Marker present but cmux says workspace doesn't exist → `status ==
  "unmarked"` with `marker_stale: True`; action becomes `recreate`.
- `auto_workspace.create` is atomic: workspace creation + marker
  write succeed together OR fail together (no half-state).
- Cmux unavailable → `auto_workspace.create` raises; hypothesis
  falls back to `workspace_action == "none"` and skill dispatches
  via the v0.4.0 workspace-per-plan path.
- The skill's summary line for a creation case names BOTH actions
  ("Creating project workspace for `<name>` and starting `<plan>`").

### U5. Document the auto / crex composition contract

**Goal:** Spec the workspace marker as the auto-side API that crex
(or other layout-management consumers) can read to snapshot or
restore project workspaces.

**Dependencies:** U4 (marker exists by then)

**Files:**
- `docs/contracts/auto-crex-composition.md` (new) — the contract
  doc. NO code change in this unit.

**Approach:** Document:
- The marker schema (link to U4's schema doc).
- Stability promise: `workspace_id`, `left_pane_id`,
  `right_pane_id`, `primary_surface_id` are STABLE for the workspace's
  lifetime. `tabs[]` mutates as fanouts add/remove sub-runs.
- How a consumer (crex) should snapshot the project: read the
  marker, read cmux's current pane/surface state for those IDs,
  preserve any non-auto surfaces (operator-added) alongside.
- How restoration works: crex re-creates the workspace via
  `cmux new-workspace --layout` with the snapshot JSON; the marker
  is rewritten with the NEW IDs (workspace UUIDs change on restore).
- What auto guarantees: the marker is atomically written on init
  and on every fanout. crex never has to handle a partial write.
- What auto does NOT guarantee: that operator-added tabs in the left
  pane (manually-opened claude sessions) are tracked. Only auto-
  dispatched tabs are in `tabs[]`.

This unit is doc-only; no test fixtures. It's the deliverable that
makes the auto/cmux integration legible to downstream consumers.

## Test Strategy

Stdlib-only bash tests under `tests/unit/`. The U1 spike has its own
fixtures under `tests/spike/cmux-layout/` (ad-hoc, NOT part of
`tests/run.sh all` — they require a live cmux daemon).

Integration test (post-U4):
`tests/integration/project-workspace-end-to-end.test.sh` — creates a
fresh repo, invokes `/auto new <project>`, asserts marker present
with valid IDs, invokes `/auto` (multi-plan fanout), asserts tabs
appear in the left pane and the batch sidecar records their
surface_ids.

The integration test requires a real cmux daemon — if unavailable
(CI environment), the test skips with a clear notice rather than
failing.

## Risks & Open Questions

**R1 — cmux layout-JSON schema is undocumented (load-bearing).** The
`--help` says "same schema as `cmux.json` layout definitions" but
the schema for `cmux.json` layouts isn't immediately obvious from
the CLI surface. U1's spike must reverse-engineer the schema (or find
it in `cmux docs api` or similar) before U4 can build the layout
declaratively. Fallback if schema is genuinely unspecified: chain
imperative `new-workspace` + `new-split` + `new-surface` + `send`
calls, accepting the multi-process timing risk that the layout JSON
was supposed to eliminate.

**R2 — `cmux send` reliability under `sleep 1;` lead-in for tabs.**
The workspace-spawn case uses `sleep 1;` because the new
workspace's login shell can swallow keystrokes during init. Tab
creation via `new-surface` might have the same problem OR might not
(a tab in an existing pane may inherit shell state). U1 verifies
empirically; if reliability is poor, U2 escalates the lead-in to
2-3s or switches to a heartbeat-poll until the surface is ready.

**R3 — Operator manually deletes a pane while fanout is dispatching.**
U3 raises `WorkspaceLayoutChanged` if the marker's `left_pane_id`
no longer exists — but the race window is small (between marker
read and `cmux_spawn_tab` invocation). The plan accepts this race
as a rare edge case; the failure mode is clear (one sub-run fails
to dispatch, operator gets a clear error, can re-invoke).

**R4 — Recursion explosion.** A pane's tab spawns more tabs which
spawn more tabs. A pathological recipe could fill the strip
unboundedly. Mitigation: cap fanout depth at 3 levels by default
(env var `CLAUDE_AUTO_MAX_FANOUT_DEPTH=3`), with the cap enforced
in `auto-spawn.py` by reading the parent run's depth from its
ledger. Depth tracking is a v2 concern if/when recursion becomes a
real usage pattern.

**Open Q1.** Should the skill pre-create `<repo>/worktrees/` when
it creates a workspace, so `wtl` and `auto-spawn` see the expected
layout immediately? Recommend yes — no harm in creating it empty.

**Open Q2.** When the marker is stale (`recreate` action), what
happens to the OLD cmux workspace? It persists in cmux's state but
loses its marker linkage (becomes a normal workspace the operator
can close manually). The new workspace gets a fresh marker. No
auto-close of the old one — the operator is explicitly resetting
but may want to inspect the old workspace before closing it.
Confirm.

**Open Q3.** Should the right pane be entirely empty by default, or
should it get a starter surface like `cmux markdown <plan>` when a
plan exists, or a default `vim .` / terminal otherwise? Recommend
empty default (a single terminal surface at the repo) with a
configurable starter via `~/.claude/auto/project-template.yaml`
deferred to a follow-up.

**Open Q4.** When `workspace_action == "create"` AND the situation
is `raw` (no plan), should the skill still create a workspace?
"Yes" creates an empty project workspace the operator can fill —
matches the "start a new project" intent. "No" only creates when
there's real work to do. Recommend yes for `raw` IF the operator
typed `/auto <freeform-text>` (intent is named); no for bare `/auto`
in a fresh repo (intent is unclear, asking first is better).

## Sequencing

U1 first (gated spike — blocking on the cmux layout-JSON schema
question). U2 after U1. U3 + U4 in parallel after U2 (U3 reads the
marker, U4 writes it; both depend on U2's primitive). U5 last
(documentation, after U4 lands the marker artifact).

**External sequencing:** this plan should land AFTER v0.4.0
(`2026-05-27-002`) merges (`blocked_by` frontmatter declares it).
Both touch `lib/cmux-socket.sh` and `lib/auto-spawn.py`. Lock-step
landing avoids merge conflicts and lets v0.4.0's batch sidecar
already exist for U3 to extend.

The goal plan (`2026-05-27-003`) is independent — both 003 and 004
can land in either order after 002, but 003's intake skill could
eventually invoke `/auto new` as its workspace-creation step, so
003 → 004 sequencing is natural.

## Success Criteria

- The U1 spike doc lands with a defensible PASS / PARTIAL / FAIL
  verdict and a recorded layout JSON schema.
- `/auto <plan>` in a repo with NO workspace marker creates a project
  workspace (50/50 left/right split, claude in left pane, empty
  right pane), writes the marker, AND dispatches the run as a tab
  in the new workspace's left pane — all in one operator action.
- `/auto <plan>` in a repo WITH a marker matching `$CMUX_WORKSPACE_ID`
  dispatches the run as a tab in the existing left pane (no
  workspace creation).
- `/auto <plan>` in a repo WITH a marker that does NOT match
  `$CMUX_WORKSPACE_ID` surfaces a one-question ambiguity (switch /
  create here / one-off) and routes per answer.
- Multi-plan fanout creates N tabs in the same left pane (not N new
  workspaces).
- A sub-run inside a tab can itself fan out — adds more tabs to the
  same left pane.
- Outside a project workspace, fanout falls back to the v0.4.0
  workspace-per-plan behavior.
- All existing `bash tests/run.sh all` tests pass; new unit tests
  pass; integration test passes when cmux daemon is available
  (skips gracefully otherwise).
- The auto/crex contract doc captures the marker schema + the
  stability promise; crex can snapshot a project workspace and
  restore it.
