"""auto v0.4.1 (plan 004) U3+U4: workspace marker read/write + detection.

A "project workspace" is a cmux workspace dedicated to one auto project.
Its layout is opinionated: left pane carries agent sessions as tabs (the
primary claude session + any fanout sub-runs); right pane is operator
territory (docs, browsers, anything not driven by auto).

The marker at ``<repo>/.claude/auto/workspace.json`` is the durable
record of which cmux workspace IS the project's. The auto-driver skill
reads it via :func:`detect` to decide between:

* **use** — we ARE in the project workspace; fanout should spawn tabs.
* **create** — no marker; fanout should first create a workspace.
* **non-project** — marker exists but ``$CMUX_WORKSPACE_ID`` doesn't
  match; the operator opened claude in a different workspace.
* **recreate** — marker exists but the cmux workspace it points at no
  longer exists (operator closed it without removing the marker).

This module is pure path/JSON/subprocess; no Python deps. It's
importable from auto-spawn.py and from the skill via a thin bash
wrapper.

Atomic writes use the same mkstemp+fchmod+rename pattern as ledger_core
(parity with the batch sidecar lifecycle).
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)

from _bootstrap import (
    CMUX_REF_CHARS as _CMUX_REF_CHARS,
    cmux_available as _cmux_available,
    resolve_host_repo_root,
)  # noqa: E402


# ── Public API surface ─────────────────────────────────────────────────────


class WorkspaceError(Exception):
    """Base for workspace-related failures (read/write/parse)."""


class MarkerInvalid(WorkspaceError):
    """The marker file exists but doesn't parse or lacks required fields."""


def marker_path(host_repo: str) -> str:
    """Return the absolute marker path for a host repo."""
    return os.path.join(host_repo, ".claude", "auto", "workspace.json")


def read_marker(host_repo: str) -> dict | None:
    """Return the parsed marker dict, or None if missing/unreadable.

    Returns None on read errors (rel-001 parity with the ledger): a
    corrupted marker should NEVER break callers; the worst case
    degrades to "no project workspace" and the skill falls back to
    workspace-per-plan dispatch.
    """
    path = marker_path(host_repo)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def write_marker(host_repo: str, marker: dict) -> None:
    """Atomically write the marker via mkstemp+fchmod+rename."""
    dst = marker_path(host_repo)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".marker.", suffix=".json", dir=os.path.dirname(dst))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(marker, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.rename(tmp, dst)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _cmux_workspace_exists(workspace_id: str) -> bool:
    """Ask cmux whether a workspace with the given ID is still live.

    Round-1 plan-004 review P2 #4: previously did a naive
    `workspace_id in result.stdout` substring match, which:
      (a) gave false positives when a short ID was a prefix of a
          live one (marker `workspace:abc` matched live
          `workspace:abc12345`),
      (b) gave false positives when the ID happened to appear inside
          a workspace NAME (cmux includes names in list output),
      (c) gave false negatives when cmux truncated the line.

    Fix: regex-extract every `workspace:<id>` token on its own and
    check for exact membership.
    """
    if not workspace_id or not _cmux_available():
        return False
    name = os.environ.get("CLAUDE_AUTO_CMUX", "cmux")
    try:
        result = subprocess.run(
            [name, "list-workspaces"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return False
    if result.returncode != 0:
        return False
    import re
    live_ids = set(re.findall(rf"workspace:{_CMUX_REF_CHARS}", result.stdout))
    return workspace_id in live_ids


def detect(host_repo: str) -> dict:
    """Return the workspace block for the hypothesis envelope.

    Output shape (matches plan 004 KTD-4):

    .. code-block:: json

       {
         "status": "project | non-project | unmarked | recreate",
         "marker_path": "<abs-path>|null",
         "workspace_id": "<cmux-uuid>|null",
         "left_pane_id": "<cmux-uuid>|null",
         "env_workspace_id": "<value-of-$CMUX_WORKSPACE_ID>|null",
         "marker_stale": false  # true when marker existed but cmux says workspace gone
       }
    """
    env_ws = os.environ.get("CMUX_WORKSPACE_ID") or None
    marker = read_marker(host_repo)
    mpath = marker_path(host_repo)
    if marker is None:
        return {
            "status": "unmarked",
            "marker_path": None,
            "workspace_id": None,
            "left_pane_id": None,
            "env_workspace_id": env_ws,
            "marker_stale": False,
        }
    ws_id = marker.get("workspace_id")
    left_pane_id = marker.get("left_pane_id")
    # Marker exists. Check whether the referenced workspace is still live.
    # If the marker's cmux workspace is gone, report "recreate" (NOT
    # "unmarked"): the marker file is still on disk, so a caller that read
    # "unmarked" and then invoked create() would hit the marker-exists guard
    # and fail silently. "recreate" tells the caller the stale marker is
    # overwrite-eligible; create() honors that by treating a stale marker as
    # force-eligible.
    if ws_id and not _cmux_workspace_exists(ws_id):
        return {
            "status": "recreate",
            "marker_path": mpath,
            "workspace_id": ws_id,
            "left_pane_id": left_pane_id,
            "env_workspace_id": env_ws,
            "marker_stale": True,
        }
    if env_ws and ws_id == env_ws:
        status = "project"
    else:
        status = "non-project"
    return {
        "status": status,
        "marker_path": mpath,
        "workspace_id": ws_id,
        "left_pane_id": left_pane_id,
        "env_workspace_id": env_ws,
        "marker_stale": False,
    }


# ── Workspace creation (called by the skill in U4 — stub for U3) ──────────


def create(host_repo: str, *, name: str | None = None, force: bool = False) -> dict:
    """Create a project workspace and write the marker atomically.

    Per the spike addendum (docs/research/cmux-layout-fanout-spike.md),
    cmux DOES accept declarative layout JSON — the shape was hiding in
    new-workspace's --help example. Single subprocess creates the
    50/50 left/right split with the primary claude session in the
    left pane.

    Steps:
      1. `cmux new-workspace --name <name> --cwd <repo> --layout <json>`
         where the layout declares two panes (left runs `claude`,
         right is an empty terminal). Returns `OK <workspace-id>`.
      2. `cmux list-panes --workspace <ws>` → enumerate the two panes.
         Left = first listed (focused by cmux convention); right = second.
      3. `cmux list-pane-surfaces --pane <left>` → primary surface
         (the running claude session).
      4. Build the marker dict, write atomically.
      5. Return the marker.

    Args:
        host_repo: absolute path to the project's main repo. Used as
          the workspace cwd AND the marker's location.
        name: workspace name. Defaults to the repo's basename.
        force: when True, overwrite an existing marker unconditionally.
          Without force, an existing marker is refused UNLESS it is stale
          (detect()=="recreate"), which is overwrite-eligible.

    Raises:
        WorkspaceError: a live (non-stale) marker already exists and
          force=False, cmux is unavailable, any cmux subprocess fails,
          or pane enumeration returns unexpected output.
    """
    if not os.path.isdir(host_repo):
        raise WorkspaceError(f"host_repo does not exist: {host_repo}")
    mpath = marker_path(host_repo)
    if os.path.isfile(mpath) and not force and not _marker_is_stale(host_repo):
        raise WorkspaceError(
            f"marker already exists at {mpath} — pass force=True to overwrite"
        )
    if not _cmux_available():
        raise WorkspaceError(
            "cmux required for workspace creation — install or invoke "
            "/auto without project-workspace setup"
        )
    if name is None:
        name = os.path.basename(host_repo.rstrip("/")) or "auto-project"

    # Step 1: create the workspace with the layout.
    layout = {
        "direction": "horizontal",
        "split": 0.5,
        "children": [
            {"pane": {"surfaces": [{"type": "terminal", "command": "claude"}]}},
            {"pane": {"surfaces": [{"type": "terminal"}]}},
        ],
    }
    cmux = os.environ.get("CLAUDE_AUTO_CMUX", "cmux")
    try:
        result = subprocess.run(
            [cmux, "new-workspace",
             "--name", name,
             "--cwd", host_repo,
             "--layout", json.dumps(layout),
             "--focus", "true"],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(f"cmux new-workspace failed to start: {exc}") from exc
    if result.returncode != 0:
        raise WorkspaceError(
            f"cmux new-workspace failed: {result.stderr.strip() or result.stdout.strip()}"
        )
    workspace_id = _extract_ref(result.stdout, "workspace")
    if not workspace_id:
        raise WorkspaceError(
            f"cmux new-workspace returned no workspace id: {result.stdout!r}"
        )

    # Step 2: enumerate panes.
    panes = _list_refs(cmux, ["list-panes", "--workspace", workspace_id], "pane")
    if len(panes) < 2:
        raise WorkspaceError(
            f"workspace {workspace_id} has {len(panes)} panes (expected ≥2): {panes!r}"
        )
    left_pane_id, right_pane_id = panes[0], panes[1]

    # Step 3: enumerate surfaces in the left pane to find the primary one.
    surfaces = _list_refs(
        cmux,
        ["list-pane-surfaces", "--pane", left_pane_id],
        "surface",
    )
    if not surfaces:
        raise WorkspaceError(
            f"left pane {left_pane_id} has no surfaces"
        )
    primary_surface_id = surfaces[0]

    # Step 4: build + write the marker.
    marker = {
        "workspace_id": workspace_id,
        "created_at": _now_iso(),
        "layout_version": "v1",
        "left_pane_id": left_pane_id,
        "right_pane_id": right_pane_id,
        "primary_surface_id": primary_surface_id,
        "tabs": [
            {
                "surface_id": primary_surface_id,
                "kind": "primary",
                "plan": None,
                "run_id": None,
            }
        ],
    }
    write_marker(host_repo, marker)
    return marker


def _marker_is_stale(host_repo: str) -> bool:
    """True when a marker exists but its cmux workspace is gone.

    This is the detect()=="recreate" case. A stale marker is
    overwrite-eligible in create() so the stale→recreate path doesn't fail
    silently. We treat the marker as NON-stale (block overwrite) when it can't
    be parsed or lacks a workspace_id — err on the safe side rather than
    clobbering a marker we can't reason about.
    """
    marker = read_marker(host_repo)
    ws_id = marker.get("workspace_id") if marker else None
    return bool(ws_id) and not _cmux_workspace_exists(ws_id)


def _now_iso() -> str:
    """UTC ISO-8601 with trailing Z (parity with ledger_core._now_iso)."""
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def _extract_ref(text: str, kind: str) -> str | None:
    """Grep the first `<kind>:<id>` token from text. None if not present."""
    import re
    m = re.search(rf"{kind}:{_CMUX_REF_CHARS}", text)
    return m.group(0) if m else None


def _list_refs(cmux: str, argv: list[str], kind: str) -> list[str]:
    """Run `cmux <argv>` and return all `<kind>:<id>` refs in stdout, in order."""
    import re
    try:
        result = subprocess.run(
            [cmux, *argv], capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise WorkspaceError(f"cmux {argv[0]} failed to start: {exc}") from exc
    if result.returncode != 0:
        raise WorkspaceError(
            f"cmux {argv[0]} failed: {result.stderr.strip() or result.stdout.strip()}"
        )
    return re.findall(rf"{kind}:{_CMUX_REF_CHARS}", result.stdout)


# ── CLI entry point ────────────────────────────────────────────────────────
#
# Used by the skill via:
#   python lib/auto-workspace.py detect <host-repo>
#   python lib/auto-workspace.py marker-path <host-repo>


def _cli(argv) -> int:
    if not argv:
        sys.stderr.write("usage: auto-workspace.py <detect|marker-path> <host-repo>\n")
        return 2
    cmd = argv[0]
    args = argv[1:]
    if cmd == "detect":
        if len(args) != 1:
            sys.stderr.write("usage: auto-workspace.py detect <host-repo>\n")
            return 2
        result = detect(args[0])
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if cmd == "marker-path":
        if len(args) != 1:
            sys.stderr.write("usage: auto-workspace.py marker-path <host-repo>\n")
            return 2
        sys.stdout.write(marker_path(args[0]) + "\n")
        return 0
    if cmd == "create":
        # auto-workspace.py create <host-repo> [--name <name>] [--force] [--print-id]
        if not args:
            sys.stderr.write(
                "usage: auto-workspace.py create <host-repo> "
                "[--name <name>] [--force] [--print-id]\n"
            )
            return 2
        host_repo = args[0]
        kwargs = {}
        print_id_only = False
        i = 1
        while i < len(args):
            tok = args[i]
            if tok == "--name" and i + 1 < len(args):
                kwargs["name"] = args[i + 1]
                i += 2
                continue
            if tok == "--force":
                kwargs["force"] = True
                i += 1
                continue
            if tok == "--print-id":
                # Round-2 P1 fix: skills run via the Bash tool, each
                # invocation is a fresh shell — `export CMUX_WORKSPACE_ID`
                # doesn't persist to the next Bash call. The skill needs
                # to capture the new workspace_id in ONE bash call and
                # prefix it onto the dispatch command. --print-id makes
                # the CLI emit JUST the id (parseable without JSON tools).
                print_id_only = True
                i += 1
                continue
            sys.stderr.write(f"auto-workspace.py create: unknown arg {tok!r}\n")
            return 2
        try:
            marker = create(host_repo, **kwargs)
        except WorkspaceError as exc:
            sys.stderr.write(f"auto-workspace: {exc}\n")
            return 1
        if print_id_only:
            sys.stdout.write(marker["workspace_id"] + "\n")
        else:
            json.dump(marker, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        return 0
    sys.stderr.write(f"auto-workspace.py: unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
