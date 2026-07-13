#!/usr/bin/env python3
"""auto U4: the deterministic agent-tree renderer (the watch-the-tree view).

`render_agent_tree(ledger, now)` turns a live ledger into a compact ASCII tree
of the driver → work step → `do_step` fan-out agent, annotating each dispatched
node with its age against the stall threshold + its attempt count, and nesting
`do_step` fan-out children under their producer parent. It mirrors
lib/topology-render.py's deterministic-string idioms — declaration-order
traversal, stable formatting, pure stdlib — so tests can pin exact output.

STRUCTURE comes from the ledger (the `depends_on` DAG + the `do_step` backend-op
marker); LIVE-agent status is overlaid model-side by the skill (skills/auto-watch)
from the harness TaskList/Monitor tools. This module owns only the structural,
deterministic half (KTD5).

PURE + deterministic: `now` is passed in as an ISO-8601 string (NEVER
datetime.now()), so a fixed ledger + a fixed `now` render byte-identically —
the property the watch view's determinism test pins.

Loaded via `_bootstrap.load_lib_module("watch_tree")`. Imports NO sibling lib
module: the ISO parse is replicated locally (two lines) rather than reaching into
lib/ledger_core's private surface.
"""

from __future__ import annotations

import datetime

# Mirror ledger_core.DEFAULT_STALL_THRESHOLD_SECONDS (600). Replicated, not
# imported, to keep this renderer dependency-free — the same discipline the
# module docstring names for the ISO parse.
_DEFAULT_STALL_THRESHOLD_SECONDS = 600

_HEADER_PREFIX = "agent-tree"
_EMPTY_SENTINEL = "(no dispatched steps)"
_INDENT = "  "


def _parse_iso(value):
    """Parse the trailing-'Z' UTC ISO-8601 stamp the ledger always emits.

    Replicates lib/ledger_core.parse_iso's tiny parse (deliberately NOT imported
    — U4 keeps no private cross-module dependency). Returns a tz-aware datetime,
    or None on any missing/malformed value.
    """
    if not value:
        return None
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (ValueError, TypeError):
        return None


def _seconds_between(start_iso, now_dt) -> int:
    """Whole seconds from `start_iso` to `now_dt`; -1 when start is unparseable.

    Mirrors pulse_advance._seconds_since (parse-then-diff), but takes an already-
    parsed `now` so the render pass parses `now` exactly once.
    """
    started = _parse_iso(start_iso)
    if started is None or now_dt is None:
        return -1
    return int((now_dt - started).total_seconds())


def _backend_op(step) -> str:
    """The step's backend_op — read from `dispatch_context` (the materialized
    on-disk shape, where recipes.step_for merged `invokes`) or from a raw
    `invokes` (a recipe-shaped step). '' when neither carries one."""
    for holder_key in ("dispatch_context", "invokes"):
        holder = step.get(holder_key)
        if isinstance(holder, dict) and holder.get("backend_op"):
            return holder["backend_op"]
    return ""


def _is_fanout_child(step) -> bool:
    """True for a `do_step` fan-out agent — the node that nests under the producer
    parent it depends on. The `do_step` marker on the CHILD is the reliable,
    ledger-visible signal that its parent is the fan-out step (KTD5)."""
    return _backend_op(step) == "do_step"


def _threshold(step) -> int:
    return int(step.get("stall_threshold_seconds") or _DEFAULT_STALL_THRESHOLD_SECONDS)


def _annotation(step, now_dt) -> str:
    """The bracketed status suffix for one node. A `dispatched` node carries its
    age against threshold, an OVER-AGE flag when age > threshold, and its attempt;
    every other state shows just the state name (`[pending]`, `[stalled]`, …)."""
    state = step.get("state", "pending")
    if state != "dispatched":
        return f"[{state}]"
    threshold = _threshold(step)
    age = _seconds_between(step.get("dispatched_at"), now_dt)
    attempt = int(step.get("attempt", 0) or 0)
    parts = [f"dispatched age={age}s/{threshold}s"]
    if age >= 0 and age > threshold:
        parts.append("OVER-AGE")
    parts.append(f"attempt={attempt}")
    return "[" + " ".join(parts) + "]"


def render_agent_tree(ledger: dict, now: str) -> str:
    """Return a deterministic multi-line agent-tree string for `ledger`.

    `now` is an ISO-8601 string (passed in — the function never reads the clock,
    so it stays pure and byte-deterministic for a fixed ledger + `now`).

    Layout: an `agent-tree: <run_id>` header, a blank line, then each root step as
    a `• <id>  [<status>]` bullet in DECLARATION order, with `do_step` fan-out
    children nested one indent deeper under the producer parent they depend on
    (recursively; also declaration order). A dispatched node's status is annotated
    with age-vs-threshold, an OVER-AGE flag past threshold, and its attempt; other
    states show their state name.

    When NOTHING is dispatched there is no live agent to watch, so the whole tree
    collapses to the header + an empty-tree sentinel (`(no dispatched steps)`).
    """
    steps = ledger.get("steps") or []
    run_id = ledger.get("run_id") or "?"
    header = f"{_HEADER_PREFIX}: {run_id}"

    # Empty-tree sentinel: no dispatched step ⇒ nothing live to watch.
    if not any(u.get("state") == "dispatched" for u in steps):
        return f"{header}\n\n{_INDENT}{_EMPTY_SENTINEL}"

    now_dt = _parse_iso(now)

    # Fan-out nesting from the depends_on DAG: a do_step child nests under the
    # first EXISTING step it depends on (its producer parent). Every other step —
    # empty depends_on, a fan-in judge, a non-do_step dependent — is a root.
    by_id = {u.get("id"): u for u in steps}
    children_of: dict = {}
    child_ids: set = set()
    for u in steps:
        if not _is_fanout_child(u):
            continue
        parent_id = next(
            (d for d in (u.get("depends_on") or [])
             if d in by_id and d != u.get("id")),
            None,
        )
        if parent_id is None:
            continue
        children_of.setdefault(parent_id, []).append(u)
        child_ids.add(u.get("id"))

    lines = [header, ""]
    seen: set = set()

    def render_node(step, depth):
        uid = step.get("id")
        if uid in seen:  # cycle guard (ledgers are DAGs; cheap insurance).
            return
        seen.add(uid)
        indent = _INDENT * (depth + 1)
        lines.append(f"{indent}• {uid}  {_annotation(step, now_dt)}")
        for child in children_of.get(uid, []):
            render_node(child, depth + 1)

    for u in steps:
        if u.get("id") in child_ids:
            continue  # rendered under its parent via recursion.
        render_node(u, 0)

    return "\n".join(lines)
