# Batch Sidecar Schema (v0.4.0 — multi-plan fanout)

> **Status:** v0.4.0 day-zero contract for multi-plan fanout (the sole new
> persistent artifact added by the v0.4.0 plan; KTD-2). `lib/auto-spawn.py`
> writes; `lib/on-stop.py` reads.
>
> The sidecar exists because N sub-runs need a single record the parent
> session can read to compose their status. Single-run flow is unaffected
> by this contract — it lives only on the existing per-run ledger.

---

## 1. Location

```
<host-repo-root>/.claude/auto/batches/<batch-id>.json
```

- `<host-repo-root>` is the MAIN repo (NOT the cwd worktree). Resolved by
  `_bootstrap.resolve_host_repo_root()` (KTD-3) — uses
  `git rev-parse --git-common-dir`, which works from main + worktree.
- `<batch-id>` is `YYYY-MM-DD-HHMMSS-batch` (UTC, second-precision). The
  spawner uniquifies on collision by appending `-2`, `-3`, …
- Directory + file are created with mode `0700` / `0600`.

The `batches/` sub-directory is intentionally separate from per-run
ledger files (`<run>.json`) so a glob over `.claude/auto/*.json` keeps
scanning runs only; the Stop hook globs `batches/*.json` separately.

---

## 2. Concrete schema

```json
{
  "id": "2026-05-27-143000-batch",
  "created_at": "2026-05-27T14:30:00Z",
  "status": "provisional",
  "composite_intent": "ship plans B11, B12, B13 reviewed and clean",
  "plans": [
    {
      "path": "docs/plans/B11-exit-reason-constants.md",
      "slug": "B11-exit-reason-constants",
      "worktree": "/abs/path/to/host-repo/worktrees/B11-exit-reason-constants",
      "branch": "auto/B11-exit-reason-constants",
      "port": 3001,
      "suggested_run_id": "B11-exit-reason-constants-2026-05-27"
    }
  ]
}
```

### 2.1 Top-level fields

| field | type | meaning |
|-------|------|---------|
| `id` | string | batch identifier; matches the filename stem |
| `created_at` | `<iso>` | UTC timestamp at sidecar creation |
| `status` | enum | `"provisional"` (worktrees being created) \| `"committed"` (all worktrees succeeded, sub-runs may now spawn) |
| `composite_intent` | string | one-line operator-facing description of the batch — driver uses this when binding harness `/goal` |
| `plans` | array | per-plan record; see §2.2 |

### 2.2 `plans[]` entry

| field | type | meaning |
|-------|------|---------|
| `path` | string | relpath to the plan file from `<host-repo-root>` |
| `slug` | string | filesystem-safe slug derived from the plan stem; uniquified on collision (suffix `-2`, `-3`, …) |
| `worktree` | string | ABSOLUTE path to the worktree (`<host-repo-root>/worktrees/<slug>`). Absolute because a future `auto-cleanup` command needs to iterate this list and call `git worktree remove` without re-deriving |
| `branch` | string | branch name git worktree was created on (typically `auto/<slug>`) |
| `port` | int | dev port assigned to this sub-run, in `[3001, 3099]` |
| `suggested_run_id` | string | preferred run-id when the sub-run is dispatched — `lib/auto.py` may uniquify on date collision but should respect this as the stem |

---

## 3. Lifecycle (KTD-2 + round-3 R3-003 + round-4 R4-002)

### 3.1 Provisional → Committed

A spawn proceeds in this order:

1. **Discover ports.** Scan `<host-shared>/batches/*.json` for in-use
   ports (across both `provisional` AND `committed` sidecars). Pick the
   lowest free integer in `[3001, 3099]`.
2. **Sweep stale provisional sidecars.** As part of the same scan, drop
   any sidecar still `provisional` whose mtime is older than
   `CLAUDE_AUTO_PROVISIONAL_TTL` (default 600s / 10 min). This recovers
   ports from sidecars left behind by a process crash between worktree
   creation and the commit step. The sweep is discovery-time cleanup —
   no separate GC pass needed.
3. **Compute worktree paths.** `<host-repo-root>/worktrees/<slug>` per
   plan, where `<host-repo-root>` = `resolve_host_repo_root()` (round-3
   R3-001 — NOT `git rev-parse --show-toplevel` which returns the
   worktree's own root from inside a worktree).
4. **Write the sidecar as PROVISIONAL.** Atomic write (mkstemp +
   `os.rename`) to `<host-shared>/batches/<batch-id>.json`. This is the
   claim record concurrent spawn invocations read from — both
   provisional + committed are treated as in-use for port discovery.
5. **Create the worktrees.** `git worktree add <worktree> -b <branch>`
   per plan. On the FIRST failure: tear down successfully-created
   worktrees from this batch (`git worktree remove`), delete the
   provisional sidecar, raise to the caller.
6. **COMMIT the sidecar.** Atomic write with `status: "committed"`. The
   Stop hook gates session exit only on committed sidecars (provisional
   ones are ignored — round-3 R3-003).

### 3.2 Stop hook consumption

`lib/on-stop.py` (extended in U4):
- Scans `<host-shared>/batches/*.json` for `status: "committed"` sidecars.
- For each, reads each plan's recorded sub-run ledger (located via the
  sub-run's worktree, NOT the host repo's `.claude/auto/`).
- Composite predicate: every sub-run's `exit_predicate_result.met`
  must be true.
- Provisional sidecars are SKIPPED — they may belong to a failed
  half-built batch.

---

## 4. Cleanup

Worktrees stay until manual `wtc` (round-3 R3-discussion). The sidecar's
`worktree` field carries an ABSOLUTE path so a future `auto-cleanup`
command can iterate committed batches and call `git worktree remove`
without re-discovery. Do not narrow the schema in a way that breaks
this — the absolute path is intentional.

Provisional sidecars older than `CLAUDE_AUTO_PROVISIONAL_TTL` are swept
on the next spawn's port-discovery scan (§3.1 step 2).

---

## 5. Cross-references

- Plan: `docs/plans/2026-05-27-002-feat-auto-bare-entry-and-fanout-plan.md`
  (U2 + KTD-2 + KTD-3).
- Ledger schema: `docs/contracts/ledger-schema.md` (the existing per-run
  contract — additive `goal_intent` field in v0.4.0 U1).
- Cmux dispatch shape: `lib/cmux-socket.sh::auto::cmux_spawn_workspace`
  (the v0.4.0 U2 reusable helper factored out of `auto::spawn_resume`).
