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

from _bootstrap import resolve_host_repo_root  # noqa: E402


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


def _atomic_write_marker(host_repo: str, marker: dict) -> None:
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


def _cmux_available() -> bool:
    """Probe whether the cmux binary is on PATH."""
    name = os.environ.get("CLAUDE_AUTO_CMUX", "cmux")
    try:
        result = subprocess.run(
            ["sh", "-c", f"command -v {name} >/dev/null 2>&1"],
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def _cmux_workspace_exists(workspace_id: str) -> bool:
    """Ask cmux whether a workspace with the given ID is still live."""
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
    return workspace_id in result.stdout


def detect(host_repo: str) -> dict:
    """Return the workspace block for the hypothesis envelope.

    Output shape (matches plan 004 KTD-4):

    .. code-block:: json

       {
         "status": "project | non-project | unmarked",
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
    if ws_id and not _cmux_workspace_exists(ws_id):
        return {
            "status": "unmarked",
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


def create(host_repo: str, *, name: str | None = None) -> dict:
    """Create a project workspace via the imperative cmux chain.

    Per the U1 spike outcome (docs/research/cmux-layout-fanout-spike.md),
    cmux's --layout JSON is opaque; we use the imperative chain:

      1. cmux new-workspace --name <name> --cwd <repo> --focus true
      2. capture workspace_id from stdout
      3. cmux list-panes → capture primary pane id (left)
      4. cmux new-split right --panel <left> → creates the right pane
      5. cmux send --surface <left-primary> "claude\\n" → starts the
         primary claude session in the left pane

    Writes the marker atomically and returns it. Raises WorkspaceError
    on any cmux failure.
    """
    raise NotImplementedError(
        "auto_workspace.create() lands in U4. For U3, only detect()/read_marker() "
        "are required (the spawn-side branch consumes the existing marker, "
        "doesn't create one)."
    )


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
    sys.stderr.write(f"auto-workspace.py: unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
