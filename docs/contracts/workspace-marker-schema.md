# Workspace Marker Schema (v0.4.1 — plan 004)

> **Status:** day-zero contract for project workspaces (plan 004).
> `lib/auto-workspace.py` writes; `lib/auto-spawn.py` and the
> `auto-driver` skill read.
>
> A "project workspace" is a cmux workspace dedicated to one auto
> project — its left pane carries agent sessions as tabs, its right
> pane is operator territory. The marker is the durable signal that
> "this repo HAS a project workspace at cmux ID X" so subsequent
> `/auto` invocations dispatch as tabs in the existing workspace
> rather than as new top-level workspaces.

---

## 1. Location

```
<host-repo-root>/.claude/auto/workspace.json
```

- `<host-repo-root>` is the MAIN repo (resolved via
  `_bootstrap.resolve_host_repo_root()`). The marker lives at the
  host's `.claude/auto/`, NOT per-worktree.
- File mode: `0600`. Directory: `0700`.

---

## 2. Concrete schema

```json
{
  "workspace_id": "workspace:abc12345-uuid",
  "created_at": "2026-05-27T14:30:00Z",
  "layout_version": "v1",
  "left_pane_id": "pane:def56789-uuid",
  "right_pane_id": "pane:ghi01234-uuid",
  "primary_surface_id": "surface:jkl56789-uuid",
  "tabs": [
    {
      "surface_id": "surface:jkl56789-uuid",
      "kind": "primary",
      "plan": null,
      "run_id": null
    },
    {
      "surface_id": "surface:abc12345-uuid",
      "kind": "fanout",
      "plan": "docs/plans/B11-foo.md",
      "run_id": "B11-foo-2026-05-27"
    }
  ]
}
```

### 2.1 Top-level fields

| field | type | meaning |
|-------|------|---------|
| `workspace_id` | string | cmux workspace UUID (`workspace:...`). The single source of truth for "which workspace IS this project's." |
| `created_at` | iso8601 string | UTC timestamp at marker creation |
| `layout_version` | string | schema version (currently `"v1"`); future migrations bump this |
| `left_pane_id` | string | cmux pane UUID for the agent-sessions pane |
| `right_pane_id` | string | cmux pane UUID for the operator-territory pane |
| `primary_surface_id` | string | the initial claude surface in the left pane (created by `auto_workspace.create`) |
| `tabs` | array | per-surface record of every auto-dispatched tab; see §2.2 |

### 2.2 `tabs[]` entry

| field | type | meaning |
|-------|------|---------|
| `surface_id` | string | cmux surface UUID |
| `kind` | enum | `"primary"` (initial claude session) \| `"fanout"` (auto-dispatched sub-run tab) \| `"manual"` (operator-opened, NOT tracked by auto today — included for future extensibility) |
| `plan` | string \| null | for `fanout` kind: the plan path the sub-run is driving |
| `run_id` | string \| null | for `fanout` kind: the sub-run's run-id (matches the ledger's `run_id` at `<worktree>/.claude/auto/<run-id>.json`) |

---

## 3. Detection (`auto_workspace.detect`)

The auto-driver skill reads the marker via `detect(host_repo)` to
classify the workspace state. Output:

```json
{
  "status": "project | non-project | unmarked",
  "marker_path": "<abs-path>|null",
  "workspace_id": "<cmux-uuid>|null",
  "left_pane_id": "<cmux-uuid>|null",
  "env_workspace_id": "<value-of-$CMUX_WORKSPACE_ID>|null",
  "marker_stale": false
}
```

Status semantics:

| status | meaning |
|---|---|
| `unmarked` | no marker exists at `<repo>/.claude/auto/workspace.json` |
| `unmarked` + `marker_stale: true` | marker exists BUT cmux says the referenced workspace no longer exists (operator closed it). Treated as unmarked for routing; the create path overwrites. |
| `project` | marker exists AND `$CMUX_WORKSPACE_ID` matches AND cmux confirms the workspace is live → in-pane tab dispatch is correct |
| `non-project` | marker exists AND cmux confirms it's live BUT `$CMUX_WORKSPACE_ID` doesn't match → operator opened claude in a different workspace; skill should ask whether to switch / create / one-off |

---

## 4. Lifecycle

### 4.1 Creation (`auto_workspace.create` — lands in U4)

1. Build the workspace via the cmux imperative chain (per the U1
   spike outcome at `docs/research/cmux-layout-fanout-spike.md`):
   `new-workspace` → `list-panes` → `new-split right` → `send` the
   primary claude session into the left pane.
2. Capture the returned workspace + pane + surface UUIDs.
3. Write the marker atomically via mkstemp + `os.rename`.

### 4.2 Fanout dispatch updates `tabs[]` (lands when U3 spawn-side wires it)

When `lib/auto-spawn.py` dispatches a sub-run as a tab:
1. The cmux surface ID returned by `cmux new-surface` is captured.
2. An entry with `kind: "fanout"`, `plan`, `run_id`, `surface_id` is
   appended to `tabs[]`.
3. The marker is re-written atomically.

(U3's spawn-side test fixtures don't exercise the marker write-back
yet; that lands alongside U4's create path.)

### 4.3 Stability

These fields are STABLE for the workspace's lifetime:

- `workspace_id`, `left_pane_id`, `right_pane_id`, `primary_surface_id`,
  `layout_version`

These fields MUTATE as fanouts add/remove sub-runs:

- `tabs[]` (entries appended on fanout dispatch; removed when an
  `auto-cleanup` command runs — out of scope for v0.4.1)

---

## 5. Failure modes

- **Marker missing.** Common case for a new repo; `status: unmarked`.
- **Marker present, JSON malformed.** Reading returns `None` (rel-001
  parity); detection reports `unmarked`. Operator must delete the
  file manually to re-create.
- **Marker present, cmux dead.** `cmux list-workspaces` fails or
  doesn't include the ID; detection reports `unmarked` +
  `marker_stale: true`. The create path overwrites with a fresh
  workspace.
- **Marker present, env mismatch.** `non-project`; skill asks the
  operator (switch / create / one-off).
- **Concurrent fanouts mutating `tabs[]`.** Atomic-write semantics
  prevent torn writes, but two concurrent fanouts could lose one
  set of entries (last writer wins). Mitigation: read-modify-write
  with optimistic retry. Deferred to U4 when the write-side lands.
