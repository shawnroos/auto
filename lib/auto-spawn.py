#!/usr/bin/env python3
"""auto v0.4.0 U2: multi-plan fanout orchestrator.

Given a hypothesis envelope's ``multi_plan.paths`` (the v0.4.0 rename of
v0.2.x's ``ambiguous-plans``), this module:

  1. Discovers + sweeps in-use ports under the host-shared batches/ dir.
  2. Computes worktree paths under ``<host-repo-root>/worktrees/<slug>``.
  3. Writes a PROVISIONAL batch sidecar atomically.
  4. Creates one git worktree per plan, rolling back on any failure.
  5. Commits the sidecar (``status: "committed"``) on full success.
  6. Spawns each backgrounded ``/auto <plan>`` via the cmux primitive
     (``lib/cmux-socket.sh::auto::cmux_spawn_workspace``) — the SAME
     shape that ships for /auto-resume orphans, so the sub-run survives
     the parent session's exit.
  7. Returns the manifest (list of dicts) to the driver.

Why a separate lib (not a .sh shim):
  Round-1 finding: Scope F2 — the orchestration involves atomic JSON
  writes, port discovery, partial-failure rollback, and subprocess
  fan-out. Stdlib Python is the right tool; a bash shim would replicate
  the same logic in less-safe text manipulation.

Why the cmux primitive (round-4 R4-001):
  The harness's native Agent tool does NOT expose `cwd` or `env`
  parameters. A naive ``bash -lc "claude '/auto:auto <plan>' &"`` fails: the
  claude CLI defaults to an interactive tty-bound session and ``-p``
  exits after the first response, terminating before a multi-tick
  /auto loop can drive. The cmux app-owned workspace is the ONLY
  working dispatch shape — verified by the U1 cmux spike and by
  v0.3.x's /auto-resume code path in production.

Schema reference: ``docs/contracts/batch-sidecar-schema.md`` is
authoritative for the on-disk shape this module writes.
"""

from __future__ import annotations

import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (
    CMUX_REF_CHARS as _CMUX_REF_CHARS,
    cmux_available as _cmux_available,
    load_ledger,
    load_lib_module,
    resolve_host_repo_root,
    resolve_shared_dir,
)  # noqa: E402

# The ledger facade owns the canonical ISO-Z time stamp (ledger.now_iso). Load
# it via the facade — not ledger_core — to keep facade discipline (U4).
ledger = load_ledger()

# ── Constants ──────────────────────────────────────────────────────────────

# Dev port pool. Single-operator default — atomic claim journal + flock is
# overkill at N≤3 worktrees; "scan existing sidecars, pick lowest free" is
# the right amount of mechanism (KTD's "pool discovery, not pool flock").
PORT_RANGE_LOW = 3001
PORT_RANGE_HIGH = 3099

# Provisional sidecars older than this are dropped on the next port-discovery
# scan (round-4 R4-002 — recovers ports from crashed half-built batches).
# Overridable via env for tests.
_DEFAULT_PROVISIONAL_TTL = 600  # 10 minutes


class SpawnError(Exception):
    """Base for fanout-orchestrator errors."""


class PortPoolExhausted(SpawnError):
    """No free port in [PORT_RANGE_LOW, PORT_RANGE_HIGH]."""


class HostRepoUnavailable(SpawnError):
    """resolve_host_repo_root() returned None (no git tree)."""


class WorktreeAddFailed(SpawnError):
    """git worktree add failed; the spawner has rolled back."""


class CmuxUnavailable(SpawnError):
    """cmux binary is not on PATH — fanout cannot dispatch."""


# ── Slugify (vendored — same logic as ledger_core::_slugify_branch) ────────
#
# We do NOT import from ledger_core because this module needs to run from
# the host-repo cwd before any ledger exists. The duplication is bounded
# (one regex pair) and intentional.


def _slugify(name: str) -> str:
    if not name:
        raise ValueError("empty name for slug")
    slug = re.sub(r"[^A-Za-z0-9_-]", "-", name)
    slug = re.sub(r"-+", "-", slug)
    slug = slug.strip("-")
    if not slug or slug in (".", "..") or ".." in slug:
        raise ValueError(f"slug rejected for {name!r}")
    return slug


# ── Time helpers ───────────────────────────────────────────────────────────


def _now_stamp() -> str:
    """Human-readable timestamp for batch ids — second precision UTC."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d-%H%M%S")


# ── Sidecar IO (atomic write parity with ledger_core::_atomic_write) ───────


def _batches_dir(shared: str) -> str:
    """``<shared>/batches/``; created on demand at mode 0700."""
    path = os.path.join(shared, "batches")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def _atomic_write_sidecar(path: str, payload: dict) -> None:
    """mkstemp + fchmod 0o600 + os.rename. Crash leaves prior file intact."""
    target_dir = os.path.dirname(path) or "."
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".batch.", suffix=".json", dir=target_dir)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.rename(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _read_sidecar(path: str):
    """Parse a sidecar; return None on any read/parse failure."""
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ── Port discovery + crash-recovery sweep ──────────────────────────────────


def _provisional_ttl() -> int:
    raw = os.environ.get("CLAUDE_AUTO_PROVISIONAL_TTL")
    if not raw:
        return _DEFAULT_PROVISIONAL_TTL
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return _DEFAULT_PROVISIONAL_TTL


def _scan_in_use_ports(shared: str):
    """Return (in_use_set, swept_paths) reading every sidecar in batches/.

    Treats BOTH ``provisional`` and ``committed`` sidecars as in-use so
    concurrent spawns serialize on port selection (round-2 SG-R2-001).

    Crash-recovery sweep (round-4 R4-002): provisional sidecars whose mtime
    is older than CLAUDE_AUTO_PROVISIONAL_TTL (default 600s) are removed
    inline so their ports become available again. This is discovery-time
    cleanup; no separate GC pass needed.

    Malformed sidecars are skipped (parity with the Stop hook's tolerance
    of bad ledgers — never let one corrupt file break the orchestrator).
    """
    in_use = set()
    swept = []
    bdir = _batches_dir(shared)
    ttl = _provisional_ttl()
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    for path in sorted(glob.glob(os.path.join(bdir, "*.json"))):
        side = _read_sidecar(path)
        if not isinstance(side, dict):
            continue
        # Provisional + stale → sweep and skip (ports become available).
        if side.get("status") == "provisional":
            try:
                age = now - os.path.getmtime(path)
            except OSError:
                age = 0
            if age > ttl:
                try:
                    os.unlink(path)
                    swept.append(path)
                except OSError:
                    pass
                continue
        for plan in side.get("plans", []):
            port = plan.get("port")
            if isinstance(port, int):
                in_use.add(port)
    return in_use, swept


def _pick_port(in_use):
    """Lowest free integer in [PORT_RANGE_LOW, PORT_RANGE_HIGH]."""
    for candidate in range(PORT_RANGE_LOW, PORT_RANGE_HIGH + 1):
        if candidate not in in_use:
            return candidate
    raise PortPoolExhausted(
        f"no free port in [{PORT_RANGE_LOW}, {PORT_RANGE_HIGH}] — "
        f"{len(in_use)} ports in use across active batches"
    )


# ── Worktree slug derivation with collision avoidance ──────────────────────


def _existing_worktree_slugs(host_repo: str):
    """Slugs already registered as git worktrees under <host-repo>/worktrees/.

    A spawn that picks the same slug as an EXISTING git worktree (from a prior
    batch that wasn't cleaned up) would collide on `git worktree add`. We
    proactively suffix `-2`, `-3`, … to avoid the failure path.

    Reads `git worktree list --porcelain` instead of listing the directory:
    a foreign `worktrees/<name>/` dir that isn't a registered worktree should
    NOT auto-bump the slug. The right behavior in that case is to let
    `git worktree add` fail with its own clear error, which the rollback path
    handles. (Bumping the slug silently would mask user error and re-introduce
    the round-3-style "everything looks fine but actually broken" class of bug.)
    """
    wroot = os.path.join(host_repo, "worktrees")
    try:
        out = subprocess.check_output(
            ["git", "-C", host_repo, "worktree", "list", "--porcelain"],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", errors="replace")
    except (subprocess.CalledProcessError, OSError):
        return set()
    slugs = set()
    for line in out.splitlines():
        if not line.startswith("worktree "):
            continue
        path = line[len("worktree "):].strip()
        # Only count worktrees living under host_repo/worktrees/.
        try:
            rel = os.path.relpath(path, wroot)
        except ValueError:
            continue
        if rel == "." or rel.startswith(".."):
            continue
        # First path component is the slug; nested cases shouldn't exist
        # under the current spawn shape but defensively take the head.
        slugs.add(rel.split(os.sep, 1)[0])
    return slugs


def _derive_slug(plan_path: str, taken):
    """Plan file stem → unique slug. Mutates `taken` (set) — appends suffixes."""
    base = _slugify(os.path.splitext(os.path.basename(plan_path))[0] or "plan")
    if base not in taken:
        taken.add(base)
        return base
    n = 2
    while True:
        candidate = f"{base}-{n}"
        if candidate not in taken:
            taken.add(candidate)
            return candidate
        n += 1


def _derive_run_id_hint(slug: str) -> str:
    """Mirror auto.py::_make_run_id's `<stem>-<date>` shape."""
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    return f"{slug}-{today}"


# ── git worktree + cmux ────────────────────────────────────────────────────


def _git_worktree_add(host_repo: str, worktree: str, branch: str):
    """Run `git worktree add <worktree> -b <branch>` from the host repo.

    Raises WorktreeAddFailed on non-zero exit. Caller is responsible for
    teardown (the orchestrator's rollback path).
    """
    result = subprocess.run(
        ["git", "-C", host_repo, "worktree", "add", worktree, "-b", branch],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise WorktreeAddFailed(
            f"git worktree add failed for {worktree!r}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )


def _git_worktree_remove(host_repo: str, worktree: str):
    """Best-effort `git worktree remove`. Swallow errors — rollback may
    target a worktree that never landed."""
    try:
        subprocess.run(
            ["git", "-C", host_repo, "worktree", "remove", "-f", worktree],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        pass


def _spawn_via_cmux(worktree: str, plan_rel: str, slug: str, *,
                    host_repo: str | None = None,
                    ws_state: dict | None = None) -> dict:
    """Spawn a sub-run via cmux. Branches on project-workspace presence.

    v0.4.0 KTD-2 mechanism (workspace-per-plan fallback):
      cmux new-workspace
        --name "auto-fanout-<slug>"
        --cwd  "<worktree>"
        --command "sleep 1; CLAUDE_AUTO_REPO=<worktree> claude '/auto:auto <plan>'"
        --focus false

    v0.4.1 (plan 004) KTD-4 mechanism (project workspace present):
      cmux new-surface --pane <marker.left_pane_id> --focus false
      cmux send --surface <captured> "sleep 1; cd <worktree> &&
        CLAUDE_AUTO_REPO=<worktree> claude '/auto:auto <plan>'"

    The CLAUDE_AUTO_REPO env-pin (round-2 R2-001) ensures the sub-run's
    ledger writes land at <worktree>/.claude/auto/.

    Returns a dict with the captured cmux state for the batch sidecar:
        {"mode": "workspace"|"tab", "tab_surface_id": "<surface-uuid>"|None}
    """
    plan_esc = plan_rel.replace("'", "'\\''")
    # NAMESPACED (v0.6.5): a plugin slash command fired as a `claude` startup-arg
    # (like ScheduleWakeup/loop re-injection) only resolves as `/<plugin>:<command>`
    # — the bare `/auto` is "Unknown command" (empirically confirmed: `claude -p
    # '/auto-status'` → Unknown, `/auto:auto-status` → runs). Plugin name is `auto`.
    inner_cmd = (
        f"CLAUDE_AUTO_REPO='{worktree}' "
        f"claude '/auto:auto {plan_esc}'"
    )
    script = os.path.join(_LIB_DIR, "cmux-socket.sh")

    # Decide dispatch mode via the full detect() check. detect() returns
    # one of four statuses — "unmarked", "project", "non-project", and
    # "recreate" (marker present but its cmux workspace is gone, i.e.
    # marker_stale=True) — so we route to tab-mode ONLY when
    # status == "project" (marker matches env AND cmux says the workspace is
    # live). Every other status, including "recreate", safe-degrades to the
    # workspace-per-plan fallback rather than spawning into a dead pane.
    #
    # Round-1 plan-004 review P3 #6: ws_state can be precomputed once
    # per fanout by _spawn_all_via_cmux and passed in via kwarg to avoid
    # N redundant `cmux list-workspaces` subprocess calls. When not
    # supplied, we still detect locally (back-compat for any other caller).
    use_tab = False
    left_pane_id = None
    if ws_state is None and host_repo is not None:
        try:
            wsmod = _load_workspace_module()
            ws_state = wsmod.detect(host_repo)
        except Exception:
            # rel-001 parity: detection problems never break the spawn.
            ws_state = None
    if ws_state is not None and ws_state.get("status") == "project":
        left_pane_id = ws_state.get("left_pane_id")
        use_tab = bool(left_pane_id)

    if use_tab and left_pane_id:
        # spawn-tab branch: new-surface then send. The spawn-tab helper
        # in cmux-socket.sh handles the explicit `cd <cwd>` because
        # new-surface doesn't accept --cwd.
        result = subprocess.run(
            ["bash", script, "spawn-tab", left_pane_id, worktree, inner_cmd],
            capture_output=True, text=True, check=False,
        )
        if result.returncode != 0:
            raise SpawnError(
                f"cmux spawn-tab failed for {slug!r}: "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        # The helper echoes the new surface ID on stdout. Use regex
        # extraction (not last-line) so any cmux stdout that leaks
        # through the helper's redirect doesn't poison the parse
        # (round-2 P2 #5 — defense-in-depth alongside the helper's
        # `cmux send ... >&2` fix).
        m = re.search(rf"surface:{_CMUX_REF_CHARS}", result.stdout or "")
        surface_id = m.group(0) if m else None
        return {"mode": "tab", "tab_surface_id": surface_id}

    # Workspace-per-plan fallback (v0.4.0 default behavior).
    name = f"auto-fanout-{slug}"
    command = f"sleep 1; {inner_cmd}"
    result = subprocess.run(
        ["bash", script, "spawn-workspace", name, worktree, command],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise SpawnError(
            f"cmux spawn-workspace failed for {slug!r}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return {"mode": "workspace", "tab_surface_id": None}


def _load_workspace_module():
    """Lazy-load lib/auto-workspace.py via _bootstrap (filename has a hyphen)."""
    return load_lib_module("auto-workspace")


# ── Public API ─────────────────────────────────────────────────────────────


def fanout(plan_paths, *, composite_intent=None):
    """Create worktrees + ports + batch sidecar for a multi-plan fanout.

    Args:
      plan_paths: list of plan file paths (relative to host-repo-root OR
        absolute). Order is preserved in the resulting manifest.
      composite_intent: one-line operator-facing batch goal sentence.
        Defaults to a generic "ship N plans clean" string.

    Returns: list of dicts (the manifest), one per plan:
      {plan_path, slug, worktree, branch, port, suggested_run_id}

    Raises:
      HostRepoUnavailable — resolve_host_repo_root() returned None.
      PortPoolExhausted — no free port in [3001, 3099].
      WorktreeAddFailed — a git worktree add failed; rollback complete.
      CmuxUnavailable — cmux is not on PATH (spawn step would fail).
      SpawnError — a cmux spawn failed AFTER worktrees + sidecar committed.
        Worktrees are NOT rolled back in this path (a sub-run may already
        have written to them); the operator can re-spawn manually.
    """
    if not plan_paths:
        raise SpawnError("fanout requires at least one plan path")

    host_repo = resolve_host_repo_root()
    if host_repo is None:
        raise HostRepoUnavailable(
            "fanout requires a git repo — resolve_host_repo_root() returned None"
        )
    shared = resolve_shared_dir()
    if shared is None:
        # If host_repo resolved, shared should too — defensive.
        raise HostRepoUnavailable("resolve_shared_dir() returned None")

    if not _cmux_available():
        raise CmuxUnavailable(
            "cmux required for multi-plan fanout — install or run plans "
            "sequentially with /auto <plan> per plan"
        )

    # ── Port discovery + crash-recovery sweep ─────────────────────────────
    in_use, _swept = _scan_in_use_ports(shared)

    # ── Compute slugs (existing worktrees + within-batch dedup) ───────────
    taken = _existing_worktree_slugs(host_repo)
    plans = []
    for plan_path in plan_paths:
        # Convert to a relpath from host_repo if it's currently absolute.
        if os.path.isabs(plan_path):
            try:
                plan_rel = os.path.relpath(plan_path, host_repo)
            except ValueError:
                plan_rel = plan_path  # different drive, keep as-is
        else:
            plan_rel = plan_path
        slug = _derive_slug(plan_rel, taken)
        worktree = os.path.join(host_repo, "worktrees", slug)
        port = _pick_port(in_use)
        in_use.add(port)
        branch = f"auto/{slug}"
        plans.append({
            "path": plan_rel,
            "slug": slug,
            "worktree": worktree,
            "branch": branch,
            "port": port,
            "suggested_run_id": _derive_run_id_hint(slug),
        })

    # ── Write provisional sidecar (the claim record) ──────────────────────
    batch_id = _make_batch_id(shared)
    sidecar_path = os.path.join(_batches_dir(shared), f"{batch_id}.json")
    sidecar = {
        "id": batch_id,
        "created_at": ledger.now_iso(),
        "status": "provisional",
        "composite_intent": composite_intent or _default_intent(plans),
        "plans": plans,
    }
    _atomic_write_sidecar(sidecar_path, sidecar)

    # ── Create worktrees (rollback on any failure) ────────────────────────
    created = []
    try:
        for entry in plans:
            _git_worktree_add(host_repo, entry["worktree"], entry["branch"])
            created.append(entry)
    except WorktreeAddFailed:
        # Roll back: remove successfully-created worktrees + delete
        # the provisional sidecar. Re-raise so the driver reports.
        for entry in created:
            _git_worktree_remove(host_repo, entry["worktree"])
        try:
            os.unlink(sidecar_path)
        except OSError:
            pass
        raise

    # ── COMMIT the sidecar (every worktree landed) ────────────────────────
    sidecar["status"] = "committed"
    _atomic_write_sidecar(sidecar_path, sidecar)

    _spawn_all_via_cmux(plans, host_repo=host_repo)
    # Re-write the sidecar with the captured cmux state (each plan now
    # carries a "cmux" sub-dict if it dispatched as a tab).
    _atomic_write_sidecar(sidecar_path, sidecar)
    return plans


def _spawn_all_via_cmux(plans, *, host_repo: str | None = None):
    """Spawn each backgrounded /auto <plan> via cmux.

    Failures here do NOT roll back worktrees — a sub-run may already be
    live in another workspace. Collect every failure, then raise once
    with the aggregated message so the driver can report.

    Mutates each plan entry: adds ``plan["cmux"] = {"mode": ..., "tab_surface_id": ...}``
    so the batch sidecar carries the dispatch state (plan 004 KTD-3).

    Round-1 plan-004 review P1 #2: when any spawn dispatched as `tab`,
    append the surface to the workspace marker's tabs[] as well — the
    auto-crex contract (docs/contracts/auto-crex-composition.md §3.2)
    promises crex et al. that tabs[] is the source of truth for which
    surfaces auto dispatched.
    """
    # P3 #6 fix: detect workspace state ONCE per fanout (was N times
    # before — one cmux list-workspaces subprocess per plan).
    ws_state = None
    if host_repo is not None:
        try:
            wsmod = _load_workspace_module()
            ws_state = wsmod.detect(host_repo)
        except Exception:
            ws_state = None

    spawn_errors = []
    tab_appends = []
    for entry in plans:
        try:
            cmux_state = _spawn_via_cmux(
                worktree=entry["worktree"],
                plan_rel=entry["path"],
                slug=entry["slug"],
                host_repo=host_repo,
                ws_state=ws_state,
            )
            entry["cmux"] = cmux_state
            if cmux_state.get("mode") == "tab" and cmux_state.get("tab_surface_id"):
                tab_appends.append({
                    "surface_id": cmux_state["tab_surface_id"],
                    "kind": "fanout",
                    "plan": entry["path"],
                    "run_id": entry.get("suggested_run_id"),
                })
        except SpawnError as exc:
            spawn_errors.append((entry["slug"], str(exc)))
    # Write back to the marker once per fanout (batched). Failures here
    # are non-fatal — the sub-runs are live; we surface a stderr notice.
    if tab_appends and host_repo is not None:
        try:
            wsmod = _load_workspace_module()
            marker = wsmod.read_marker(host_repo)
            if marker is not None:
                marker.setdefault("tabs", []).extend(tab_appends)
                wsmod.write_marker(host_repo, marker)
        except Exception as exc:
            sys.stderr.write(
                f"auto-spawn: warning — failed to update workspace marker tabs[]: {exc}\n"
            )
    if spawn_errors:
        msgs = "; ".join(f"{s}: {m}" for s, m in spawn_errors)
        raise SpawnError(f"cmux spawn failed for: {msgs}")


def _default_intent(plans):
    """Best-effort composite intent string when caller didn't supply one."""
    names = [p["slug"] for p in plans]
    if len(names) == 1:
        return f"ship plan {names[0]} reviewed and clean"
    return f"ship plans {', '.join(names)} reviewed and clean"


def _make_batch_id(shared: str) -> str:
    """Stamp-based id with collision suffix (rare under per-second precision)."""
    bdir = _batches_dir(shared)
    base = f"{_now_stamp()}-batch"
    candidate = base
    n = 2
    while os.path.exists(os.path.join(bdir, f"{candidate}.json")):
        candidate = f"{base}-{n}"
        n += 1
    return candidate


# ── CLI (for testing + direct invocation) ──────────────────────────────────
#
# Usage:
#   python lib/auto-spawn.py fanout <plan1> [<plan2> ...] [--intent "<text>"]
#
# Prints the manifest as JSON to stdout. Exit codes:
#   0 — success
#   2 — usage / bad args
#   3 — fanout error (sidecar / worktree / port / cmux)


def _cli(argv) -> int:
    if not argv or argv[0] != "fanout":
        sys.stderr.write("usage: auto-spawn.py fanout <plan> [<plan> ...] "
                         "[--intent <text>]\n")
        return 2
    plans = []
    intent = None
    i = 1
    while i < len(argv):
        tok = argv[i]
        if tok == "--intent":
            if i + 1 >= len(argv):
                sys.stderr.write("auto-spawn: --intent requires a value\n")
                return 2
            intent = argv[i + 1]
            i += 2
            continue
        plans.append(tok)
        i += 1

    if not plans:
        sys.stderr.write("auto-spawn: at least one plan path required\n")
        return 2

    try:
        manifest = fanout(plans, composite_intent=intent)
    except SpawnError as exc:
        sys.stderr.write(f"auto-spawn: {exc}\n")
        return 3

    json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
