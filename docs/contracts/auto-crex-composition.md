# auto ↔ crex composition contract

> **Status:** day-zero contract for crex (the cmux layout-persistence
> plugin) and any other consumer that wants to snapshot or restore
> auto project workspaces.
>
> **Scope:** describes the workspace marker as the auto-side API.
> Nothing in this document mandates crex implementation — it specs
> what crex (or anything else) CAN rely on from auto.

This doc is the v0.4.1 (plan 004 U5) deliverable: auto and crex
already integrate in spirit (both manage cmux state), but until this
contract neither knew what the other guaranteed. Without it, crex
snapshotting a project workspace and restoring it later would either
break auto's tab-fanout routing (if the marker isn't preserved) or
have to manually reverse-engineer auto's mental model.

---

## 1. The handshake surface

Auto's project-workspace lifecycle has exactly ONE persistent
artifact crex needs to know about:

```
<host-repo-root>/.claude/auto/workspace.json
```

This is the **workspace marker** — see
`docs/contracts/workspace-marker-schema.md` for the full schema.
Crex (and any other consumer) reads it via two surfaces:

### 1a. The file directly

```python
import json
marker = json.load(open(f"{repo}/.claude/auto/workspace.json"))
```

Or via the auto CLI:

```bash
python lib/auto-workspace.py detect <host-repo>
```

The CLI form is preferred because it ALSO checks cmux liveness and
reports `marker_stale: true` when the marker references a workspace
cmux no longer has. Direct-read returns whatever's on disk without
that check.

### 1b. The detect() Python API

```python
from auto_workspace import detect
state = detect(host_repo)
# {status: "project"|"non-project"|"unmarked",
#  marker_path, workspace_id, left_pane_id, env_workspace_id,
#  marker_stale}
```

---

## 2. Stability promises

Auto guarantees these properties hold for the marker's lifetime:

| field | stability | meaning |
|---|---|---|
| `workspace_id` | STABLE | cmux UUID; reflects the actual cmux workspace |
| `left_pane_id` | STABLE | cmux pane UUID; the agent-sessions pane |
| `right_pane_id` | STABLE | cmux pane UUID; operator territory |
| `primary_surface_id` | STABLE | initial claude session's surface UUID |
| `layout_version` | STABLE | currently `"v1"`; future migrations bump |
| `created_at` | STABLE | ISO timestamp |
| `tabs[]` | MUTATES | grows as fanouts add sub-runs; shrinks on auto-cleanup (not yet implemented) |

**Stable fields are UUIDs that never change for THIS marker.** If
crex stashes them in a snapshot, restoring later means rewriting the
marker with NEW UUIDs (cmux assigns fresh ones per workspace) — see
§4.

---

## 3. What auto guarantees

1. **Atomic marker writes.** Every marker write uses
   `tempfile.mkstemp` + `os.rename` (the same pattern as run-record
   atomic_write). A reader will never observe a partial JSON.

2. **`tabs[]` mutation is also atomic.** When a fanout adds a new
   tab entry, the whole marker is rewritten atomically. No
   read-modify-write race observable from outside.

3. **`workspace_id` is THE source of truth for "which cmux
   workspace IS this project's."** Crex can use it to:
   - Find the workspace in `cmux list-workspaces`.
   - Walk the workspace's panes via `cmux list-panes --workspace
     <workspace_id>`.
   - Snapshot operator-added surfaces (anything in the panes that
     ISN'T listed in `tabs[]` is operator-added — see §6).

4. **The marker is the ONLY signal** that "this repo has an auto
   project workspace." If the marker doesn't exist, auto treats
   the repo as having no project workspace and falls back to
   workspace-per-plan dispatch (the v0.4.0 behavior).

---

## 4. What auto does NOT guarantee

1. **The marker survives `git clean`.** It lives at
   `.claude/auto/workspace.json`, which is gitignored by
   convention. Crex restoration after a clean wipe gets a fresh
   workspace if it triggers `auto_workspace.create()`.

2. **UUIDs survive cmux restart.** When cmux restarts, workspace +
   pane + surface UUIDs change. The marker becomes stale; auto's
   detect() reports `marker_stale: true`. Crex restoration MUST
   write a new marker with the NEW IDs returned by the restored
   workspace.

3. **Operator-added tabs are tracked.** `tabs[]` records ONLY
   auto-dispatched tabs (primary + fanout). If the operator
   manually opens a tab in the left pane (e.g. another `claude`
   session for an unrelated task), auto doesn't know about it.
   Crex snapshotting MUST enumerate panes via cmux to capture
   operator-added surfaces; relying on `tabs[]` alone will miss
   them.

4. **No backward-compat for `layout_version` jumps.** When v2 of
   the marker schema ships, v1 markers will be either (a) migrated
   on detect or (b) rejected with a clear error. Crex snapshots
   should record `layout_version` so they can refuse to restore
   into a future auto that doesn't understand the old version.

---

## 5. The restore flow (recommended)

When crex restores a project workspace from a snapshot:

1. Read the snapshot — recover the original layout JSON, marker
   content, tab list.
2. Build a new cmux layout JSON FROM the snapshot (the same shape
   auto's `create()` writes, but with whatever operator-added
   surfaces the snapshot captured).
3. Call `cmux new-workspace --layout <restored-json> --focus true`
   → cmux returns a NEW workspace ID.
4. Enumerate new pane + surface IDs via `cmux list-panes` /
   `cmux list-pane-surfaces`.
5. Build a fresh marker dict with the new IDs but preserving:
   - `layout_version`
   - `created_at` (the original — record "restored from snapshot at X" separately if needed)
   - `tabs[]` mapped to new surface IDs in order
6. Write the marker atomically (use `auto_workspace._atomic_write_marker`
   or replicate the mkstemp+rename pattern).

After step 6, auto's `detect()` sees the new workspace as `project`
status and resumes tab-mode dispatch transparently.

---

## 6. Operator-added vs auto-dispatched tabs

Within the project workspace's left pane, there are TWO kinds of
surfaces from auto's perspective:

- **Auto-dispatched**: present in `marker.tabs[]`. Auto created
  them (primary or fanout) and knows their kind, plan, run_id.
- **Operator-added**: present in cmux's `list-pane-surfaces` but
  NOT in `marker.tabs[]`. Auto has no record.

Crex snapshots SHOULD distinguish these:
- Auto-dispatched: snapshot the auto-side metadata (plan path,
  run_id), restore by re-spawning via auto if the work is still
  active OR by recording as "historical reference."
- Operator-added: snapshot the cmux-side metadata (surface
  command, cwd, type), restore as a plain new-surface call.

---

## 7. Versioning

This contract is at v1 (matching `layout_version: v1` in the
marker). Future revisions will:

- Add new optional fields to the marker (forward-compatible — old
  consumers ignore them).
- Bump `layout_version` for breaking changes; auto will refuse to
  read a marker whose version is unknown.

Crex (and other consumers) should record the contract version they
were built against and refuse to restore into an auto whose marker
schema is at a higher major version.
