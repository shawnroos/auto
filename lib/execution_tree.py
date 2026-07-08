#!/usr/bin/env python3
"""auto U6: loop/recipe → execution tree with sized parallelism (KTD6 / KTD6b).

`derive_execution_tree(recipe, cap)` turns a validated recipe dict (from
`auto-author-recipe` / `auto-design`) into an EXECUTION TREE: ordered parallel
waves derived from the `depends_on` DAG, fan-out `do_unit` children nested under
their emitter parent, and a substrate ROUTING DECISION. It is PURE and
deterministic — it plans a topology, it never dispatches (`skills/auto-translate`
wraps it; `lib/orchestrator.py::dispatch_batch` is the executor).

Four steps (mirroring KTD6 / KTD6b):

  1. EXPAND emitter-produced units. Recipes like `recipes/a4.json` declare their
     paired builders in `expected_emit_outputs` (materialized at RUN time by a
     phase-boundary emitter), NOT in `units[]`. `orchestrator._is_ready` treats an
     absent dependency as unsatisfied, so a raw frontier walk over a4 yields only
     `{plan}` and `compare` is never ready. We synthesize placeholder nodes for
     those declared ids FIRST so the dependents can become ready.
     `recipes/a2.json`'s parallel units are STATIC (already in `units[]`) — no
     expansion.

  2. FRONTIER WALK the (expanded) DAG, reusing the readiness logic in
     `lib/orchestrator.py` (`_is_ready` / `_dependency_satisfied`). We drive that
     exact predicate over an in-memory unit list: place every ready unit, then
     flip it `pending → verdict-returned` (a satisfied dependency in the
     contract's precise sense) so the next frontier unblocks its dependents. Each
     frontier is one WAVE — units in a wave are parallel — bounded to `cap`; the
     over-cap remainder stays pending and spills to the next wave, mirroring
     `dispatch_batch`'s over-cap behavior.

  3. NEST fan-out `do_unit` children under their emitter parent (the unit whose
     completion triggers their emission — the phase-boundary emitter's source).

  4. SUBSTRATE SELECTION (a routing decision — never execution). A self-contained
     bounded parallel-fan-in loop (single-phase, no per-unit ce-work/review
     adapter dispatch, an engine-enforced bound) routes to `"workflow-script"` —
     an INERT routing label plus a topology preview, NOT a runnable compiled
     script (the parked RFC's `pipeline()`/`parallel()` compiler is unbuilt,
     KTD6b). Everything else routes to `"subagent-tree"`, the default and the ONLY
     executable target this run (`dispatch_batch`). Both routings are supervised
     from OUTSIDE either way (U1's wedge-timeout lives external to the substrate),
     so the label changes the compile target, never the supervision.

Returns a structured dict — see `derive_execution_tree`.
"""

from __future__ import annotations

import os
import sys

# Load sibling lib modules via the ONE shared loader (see lib/_bootstrap). We
# REUSE orchestrator's readiness frontier (KTD6 — no second copy of the predicate)
# and topology-render's card style for the preview (KTD-10 — one renderer family).
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

orchestrator = load_lib_module("orchestrator")
_topology_render = load_lib_module("topology-render")

# The readiness frontier we reuse verbatim (KTD6): a unit is ready iff it is
# `pending`, every direct dependency is satisfied, and no transitive ancestor is
# stalled. We drive it over an in-memory unit list, flipping placed units to
# `verdict-returned` so the exact same predicate advances wave by wave.
_is_ready = orchestrator._is_ready
_units_by_id = orchestrator._units_by_id
_unit_adapter_op = orchestrator._unit_adapter_op

# The per-unit adapter ops that mark a loop as a long-lived ce-work / review
# dispatch — the shape that MUST run on the native subagent-tree (each unit is a
# background agent that self-writes a verdict). Their presence forces
# `"subagent-tree"`; their ABSENCE (plus single-phase + bounded) is what lets a
# self-contained fan-in loop route to the inert `"workflow-script"` label.
_CE_DISPATCH_OPS = frozenset({"do_unit", "review"})


class ExecutionTreeError(Exception):
    """Raised on an underivable recipe (a dependency cycle, or a bad cap)."""


# ──────────────────────────────────────────────────────────────────────────
# Step 1 — expand emitter-produced units.


def _emit_template_for(emit_id: str, recipe: dict):
    """The `emit_templates` entry whose `id_prefix` prefixes ``emit_id``, or None.

    A declared `expected_emit_outputs` id (e.g. a4's ``build-clarity``) is
    materialized by an emitter; the matching emit_template carries its `phase` and
    `invokes.adapter_op` — which tells us the emitted node's phase and whether it
    is a fan-out `do_unit` child (KTD5 nesting). Longest-prefix wins so overlapping
    prefixes resolve deterministically.
    """
    best = None
    best_len = -1
    for tmpl in (recipe.get("emit_templates") or {}).values():
        prefix = tmpl.get("id_prefix")
        if prefix and emit_id.startswith(prefix) and len(prefix) > best_len:
            best, best_len = tmpl, len(prefix)
    return best


def _phase_boundary_source(to_phase: str, recipe: dict, units: list):
    """The (from_phase, source_unit_ids) an emitter produces its `to_phase` units
    from — the structural dependency of an emitted node.

    A phase-boundary emitter (`plan_output_to_paired_builders` etc.) fires when the
    run ARRIVES at its `to` phase, so its output waits on the `from` phase's units
    (they must finish before the emission happens). We return those source unit ids
    so a synthesized node `depends_on` them — which is what orders the paired-
    builder wave AFTER `plan` and `compare` after the builders. Falls back to the
    LAST phase in `phase_order` before `to_phase` when no explicit transition
    names it.
    """
    from_phase = None
    for pt in recipe.get("phase_transitions") or []:
        if pt.get("to") == to_phase:
            from_phase = pt.get("from")
            break
    if from_phase is None:
        phase_order = recipe.get("phase_order") or []
        if to_phase in phase_order:
            idx = phase_order.index(to_phase)
            # Nearest declared phase that actually has units, scanning backwards.
            for j in range(idx - 1, -1, -1):
                if any(u.get("phase") == phase_order[j] for u in units):
                    from_phase = phase_order[j]
                    break
    src_ids = [u["id"] for u in units if u.get("phase") == from_phase]
    return from_phase, src_ids


def _expand_emitter_units(recipe: dict):
    """Synthesize placeholder nodes for `expected_emit_outputs` ids not in `units[]`.

    Returns ``(units, emitted_meta)`` where ``units`` is the expanded in-memory
    unit list (static `units[]` copied verbatim, each stamped `state=pending`, plus
    the synthesized emitter-produced nodes) and ``emitted_meta`` maps each
    synthesized id → ``{"parent": <emitter-source-id>, "fanout": bool}`` for the
    nesting step. a2 (no `expected_emit_outputs`) expands to itself unchanged.
    """
    units = []
    for u in recipe.get("units") or []:
        node = {
            "id": u["id"],
            "phase": u.get("phase", "work"),
            "depends_on": list(u.get("depends_on") or []),
            "dispatch_context": dict(u.get("invokes") or u.get("dispatch_context") or {}),
            "state": "pending",
        }
        units.append(node)

    known = {u["id"] for u in units}
    emitted_meta = {}
    for emit_id in recipe.get("expected_emit_outputs") or []:
        if emit_id in known:
            continue  # already a static unit — nothing to synthesize.
        tmpl = _emit_template_for(emit_id, recipe)
        phase = (tmpl or {}).get("phase") or recipe.get("terminal_phase", "work")
        adapter_op = ((tmpl or {}).get("invokes") or {}).get("adapter_op")
        _from_phase, src_ids = _phase_boundary_source(phase, recipe, units)
        # Emitter-produced work units are fan-out children when their template
        # dispatches `do_unit`; the parent is the (single) emitter-source unit.
        parent = src_ids[0] if len(src_ids) == 1 else None
        fanout = adapter_op == "do_unit"
        units.append({
            "id": emit_id,
            "phase": phase,
            "depends_on": list(src_ids),
            "dispatch_context": {"adapter_op": adapter_op} if adapter_op else {},
            "state": "pending",
            "_emitted": True,
        })
        emitted_meta[emit_id] = {"parent": parent, "fanout": fanout}
        known.add(emit_id)
    return units, emitted_meta


# ──────────────────────────────────────────────────────────────────────────
# Step 2 — frontier walk (reusing orchestrator's readiness predicate).


def _frontier_waves(units: list, cap: int):
    """Ordered parallel waves over the expanded DAG, bounded to ``cap`` per wave.

    Drives `orchestrator._is_ready` over the in-memory `units`: each iteration
    collects every ready unit (declaration order → deterministic), takes up to
    ``cap`` of them as one wave, and flips those `pending → verdict-returned` so
    the SAME predicate unblocks their dependents next iteration. The over-cap
    remainder stays `pending` and re-qualifies next wave — mirroring
    `dispatch_batch`'s over-cap spill. Raises `ExecutionTreeError` if the frontier
    empties with units still pending (a dependency cycle / unsatisfiable ref).
    """
    by_id = _units_by_id({"units": units})
    waves = []
    while True:
        ready = [u for u in units if _is_ready(u, by_id)]
        if not ready:
            break
        wave = ready[:cap]
        for u in wave:
            u["state"] = "verdict-returned"  # satisfied for the next frontier.
        waves.append([u["id"] for u in wave])
    pending_left = [u["id"] for u in units if u.get("state") == "pending"]
    if pending_left:
        raise ExecutionTreeError(
            f"underivable recipe: units never became ready (cycle or unknown "
            f"dependency): {sorted(pending_left)}"
        )
    return waves


# ──────────────────────────────────────────────────────────────────────────
# Step 3 — nest fan-out do_unit children under their emitter parent.


def _build_nesting(emitted_meta: dict) -> dict:
    """`{parent_id: [child_id, ...]}` for the emitter-produced fan-out children.

    Only `do_unit` fan-out children are nested (a comparator/judge fan-in stays a
    top-level wave node). Children are sorted for a deterministic structure.
    """
    nesting = {}
    for child, meta in emitted_meta.items():
        if meta.get("fanout") and meta.get("parent"):
            nesting.setdefault(meta["parent"], []).append(child)
    return {p: sorted(kids) for p, kids in nesting.items()}


# ──────────────────────────────────────────────────────────────────────────
# Step 4 — substrate routing decision (KTD6b — a label, not a compile).


def _select_substrate(recipe: dict, units: list) -> str:
    """`"workflow-script"` (inert routing label) or `"subagent-tree"` (executable).

    A CONCRETE predicate (testable, not vague):

      * single-phase — every unit shares one phase (a self-contained fan-in, no
        plan→seam→work spine to sequence), AND
      * no ce-work/review adapter op — no unit dispatches `do_unit`/`review`
        (those are long-lived background agents that self-write verdicts and MUST
        run on the native subagent-tree), AND
      * bounded — an engine-enforced `iteration.bound` caps the fan-in loop.

    All three ⇒ `"workflow-script"` (the parked RFC's target; inert this run — a
    routing label + preview, no runnable compiled script, KTD6b). Otherwise
    `"subagent-tree"` (today's `dispatch_batch`, the default + only executable
    target). a2/a4 both carry a `review` (and a4 a `do_unit`) op → subagent-tree.
    """
    phases = {u.get("phase") for u in units}
    single_phase = len(phases) <= 1
    has_ce_dispatch = any(
        _unit_adapter_op(u) in _CE_DISPATCH_OPS for u in units
    )
    bounded = bool((recipe.get("iteration") or {}).get("bound"))
    if single_phase and not has_ce_dispatch and bounded:
        return "workflow-script"
    return "subagent-tree"


# ──────────────────────────────────────────────────────────────────────────
# Preview — a topology-render-style card over the derived waves.


def _render_preview(recipe: dict, waves: list, nesting: dict, substrate: str) -> str:
    """A deterministic ASCII card of the derived execution tree.

    Mirrors `lib/topology-render.py`'s card idiom (KTD-10 — the same visual family
    the picker / authoring skill use), but renders the DERIVED tree: each wave as a
    numbered parallel row, fan-out children indented under their parent, and the
    substrate routing footer. Pure/stable so tests can assert byte-identity.
    """
    name = recipe.get("name", "?")
    lines = [f"execution-tree: {name}", f"  substrate: {substrate}", ""]
    for i, wave in enumerate(waves, start=1):
        lines.append(f"  ┌─ wave {i}  (parallel ≤ cap)")
        for uid in wave:
            lines.append(f"  │   • {uid}")
            for child in nesting.get(uid, []):
                lines.append(f"  │       ↳ {child}  (do_unit fan-out)")
        lines.append("  └─")
        if i < len(waves):
            lines.append("      ▼")
    return "\n".join(lines)


# ──────────────────────────────────────────────────────────────────────────
# Public entry point.


def derive_execution_tree(recipe: dict, cap: int) -> dict:
    """Derive an execution tree from a validated ``recipe`` dict, bounded by ``cap``.

    ``recipe`` — a validated recipe dict (the shape `recipes.load_and_validate`
    returns / `auto-author-recipe` writes). ``cap`` — the fan-out cap bounding each
    parallel wave (a positive int; the active work-loop cap).

    Returns a structured, deterministic dict::

        {
          "recipe":    <recipe name>,
          "cap":       <int cap>,
          "waves":     [[unit_id, ...], ...],   # ordered; within a wave = parallel
          "nesting":   {parent_id: [child_id]}, # fan-out do_unit children
          "substrate": "subagent-tree" | "workflow-script",
          "emitted":   [synthesized emitter-produced ids],
          "preview":   "<topology-render-style card string>",
        }

    Pure: no ledger, no dispatch, no filesystem. Raises `ExecutionTreeError` on a
    non-positive cap or an underivable DAG (cycle / unsatisfiable dependency).
    """
    if cap is None or int(cap) < 1:
        raise ExecutionTreeError(f"cap must be a positive int, got {cap!r}")
    cap = int(cap)

    units, emitted_meta = _expand_emitter_units(recipe)
    waves = _frontier_waves(units, cap)
    nesting = _build_nesting(emitted_meta)
    substrate = _select_substrate(recipe, units)
    preview = _render_preview(recipe, waves, nesting, substrate)

    return {
        "recipe": recipe.get("name", "?"),
        "cap": cap,
        "waves": waves,
        "nesting": nesting,
        "substrate": substrate,
        "emitted": sorted(emitted_meta.keys()),
        "preview": preview,
    }
