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
  parameters. A naive ``bash -lc "claude '/auto <plan>' &"`` fails: the
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
from _bootstrap import resolve_host_repo_root, resolve_shared_dir  # noqa: E402

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


# ── Time helpers (parity with ledger_core::_now_iso) ───────────────────────


def _now_iso() -> str:
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


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


def _cmux_available() -> bool:
    """Probe whether the cmux binary (or its override) is on PATH."""
    name = os.environ.get("CLAUDE_AUTO_CMUX", "cmux")
    # `command -v` parity; subprocess to avoid shell quoting subtleties.
    try:
        result = subprocess.run(
            ["sh", "-c", f"command -v {name} >/dev/null 2>&1"],
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def _spawn_via_cmux(worktree: str, plan_rel: str, slug: str):
    """Shell out to cmux-socket.sh::auto::cmux_spawn_workspace.

    The dispatch contract per the v0.4.0 plan (KTD-2):
      cmux new-workspace
        --name "auto-fanout-<slug>"
        --cwd  "<worktree>"
        --command "sleep 1; CLAUDE_AUTO_REPO=<worktree> claude '/auto <plan>'"
        --focus false

    The CLAUDE_AUTO_REPO env-pin (KTD-3 part B / round-2 R2-001) ensures
    the sub-run's ledger writes land at <worktree>/.claude/auto/ rather
    than escaping to ~/.claude/auto/ via the walk-up in
    _bootstrap.resolve_repo().
    """
    name = f"auto-fanout-{slug}"
    # Quote the plan path for the inner shell so paths with spaces work.
    # The single-quote-escape pattern: replace `'` with `'\''`.
    plan_esc = plan_rel.replace("'", "'\\''")
    command = (
        f"sleep 1; CLAUDE_AUTO_REPO='{worktree}' "
        f"claude '/auto {plan_esc}'"
    )
    script = os.path.join(_LIB_DIR, "cmux-socket.sh")
    result = subprocess.run(
        ["bash", script, "spawn-workspace", name, worktree, command],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        # The spawn failed AFTER the worktree was created. We do NOT roll
        # back the worktree here — the batch sidecar is already committed
        # at this point and an operator can re-spawn manually. Surface
        # the error so the driver reports it.
        raise SpawnError(
            f"cmux spawn-workspace failed for {slug!r}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )


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
        "created_at": _now_iso(),
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

    _spawn_all_via_cmux(plans)
    return plans


def _spawn_all_via_cmux(plans):
    """Spawn each backgrounded /auto <plan> via cmux.

    Failures here do NOT roll back worktrees — a sub-run may already be
    live in another workspace. Collect every failure, then raise once
    with the aggregated message so the driver can report.
    """
    spawn_errors = []
    for entry in plans:
        try:
            _spawn_via_cmux(
                worktree=entry["worktree"],
                plan_rel=entry["path"],
                slug=entry["slug"],
            )
        except SpawnError as exc:
            spawn_errors.append((entry["slug"], str(exc)))
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
