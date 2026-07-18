#!/usr/bin/env python3
"""auto U6: loop/workflow → execution tree with sized parallelism (KTD6 / KTD6b).

`derive_execution_tree(workflow, cap)` turns a validated workflow dict (from
`auto-author-workflow` / `auto-design`) into an EXECUTION TREE: ordered parallel
waves derived from the `depends_on` DAG, fan-out `do_step` children nested under
their producer parent, and a substrate ROUTING DECISION. It is PURE and
deterministic — it plans a topology, it never dispatches (`skills/auto-translate`
wraps it; `lib/dispatcher.py::dispatch_batch` is the executor).

Four steps (mirroring KTD6 / KTD6b):

  1. EXPAND producer-produced steps. Workflows like `workflows/a4.json` declare their
     paired builders in `expected_emit_outputs` (materialized at RUN time by a
     phase-boundary producer), NOT in `steps[]`. `dispatcher._is_ready` treats an
     absent dependency as unsatisfied, so a raw frontier walk over a4 yields only
     `{plan}` and `compare` is never ready. We synthesize placeholder nodes for
     those declared ids FIRST so the dependents can become ready.
     `workflows/a2.json`'s parallel steps are STATIC (already in `steps[]`) — no
     expansion.

  2. FRONTIER WALK the (expanded) DAG, reusing the readiness logic in
     `lib/dispatcher.py` (`_is_ready` / `_dependency_satisfied`). We drive that
     exact predicate over an in-memory step list: place every ready step, then
     flip it `pending → verdict-returned` (a satisfied dependency in the
     contract's precise sense) so the next frontier unblocks its dependents. Each
     frontier is one WAVE — steps in a wave are parallel — bounded to `cap`; the
     over-cap remainder stays pending and spills to the next wave, mirroring
     `dispatch_batch`'s over-cap behavior.

  3. NEST fan-out `do_step` children under their producer parent (the step whose
     completion triggers their emission — the phase-boundary producer's source).

  4. SUBSTRATE SELECTION (a routing decision — never execution). A self-contained
     bounded parallel-fan-in loop (single-phase, no per-step ce-work/review
     backend dispatch, an engine-enforced bound) routes to `"workflow-script"` —
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
# REUSE dispatcher's readiness frontier (KTD6 — no second copy of the predicate).
# The preview mirrors topology-render's card idiom by hand (KTD-10 — one renderer
# family) rather than importing it, so no topology-render load is needed here.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

dispatcher = load_lib_module("dispatcher")

# The readiness frontier we reuse verbatim (KTD6): a step is ready iff it is
# `pending`, every direct dependency is satisfied, and no transitive ancestor is
# stalled. We drive it over an in-memory step list, flipping placed steps to
# `verdict-returned` so the exact same predicate advances wave by wave.
_is_ready = dispatcher._is_ready
_steps_by_id = dispatcher._steps_by_id
_step_backend_op = dispatcher._step_backend_op

# The per-step backend ops that mark a loop as a long-lived ce-work / review
# dispatch — the shape that MUST run on the native subagent-tree (each step is a
# background agent that self-writes a verdict). Their presence forces
# `"subagent-tree"`; their ABSENCE (plus single-phase + bounded) is what lets a
# self-contained fan-in loop route to the inert `"workflow-script"` label.
_CE_DISPATCH_OPS = frozenset({"do_step", "review"})


class ExecutionTreeError(Exception):
    """Raised on an underivable workflow (a dependency cycle, or a bad cap)."""


# ──────────────────────────────────────────────────────────────────────────
# Step 1 — expand producer-produced steps.


def _emit_template_for(emit_id: str, workflow: dict):
    """The `emit_templates` entry whose `id_prefix` prefixes ``emit_id``, or None.

    A declared `expected_emit_outputs` id (e.g. a4's ``build-clarity``) is
    materialized by a producer; the matching emit_template carries its `phase` and
    `invokes.backend_op` — which tells us the emitted node's phase and whether it
    is a fan-out `do_step` child (KTD5 nesting). Longest-prefix wins so overlapping
    prefixes resolve deterministically.
    """
    best = None
    best_len = -1
    for tmpl in (workflow.get("emit_templates") or {}).values():
        prefix = tmpl.get("id_prefix")
        if prefix and emit_id.startswith(prefix) and len(prefix) > best_len:
            best, best_len = tmpl, len(prefix)
    return best


def _phase_boundary_source(to_phase: str, workflow: dict, steps: list):
    """The (from_phase, source_step_ids) a producer produces its `to_phase` steps
    from — the structural dependency of an emitted node.

    A phase-boundary producer (`plan_output_to_paired_builders` etc.) fires when the
    run ARRIVES at its `to` phase, so its output waits on the `from` phase's steps
    (they must finish before the emission happens). We return those source step ids
    so a synthesized node `depends_on` them — which is what orders the paired-
    builder wave AFTER `plan` and `compare` after the builders. Falls back to the
    LAST phase in `phase_order` before `to_phase` when no explicit transition
    names it.
    """
    from_phase = None
    for pt in workflow.get("phase_transitions") or []:
        if pt.get("to") == to_phase:
            from_phase = pt.get("from")
            break
    if from_phase is None:
        phase_order = workflow.get("phase_order") or []
        if to_phase in phase_order:
            idx = phase_order.index(to_phase)
            # Nearest declared phase that actually has steps, scanning backwards.
            for j in range(idx - 1, -1, -1):
                if any(u.get("phase") == phase_order[j] for u in steps):
                    from_phase = phase_order[j]
                    break
    src_ids = [u["id"] for u in steps if u.get("phase") == from_phase]
    return from_phase, src_ids


def _expand_producer_steps(workflow: dict):
    """Synthesize placeholder nodes for `expected_emit_outputs` ids not in `steps[]`.

    Returns ``(steps, emitted_meta)`` where ``steps`` is the expanded in-memory
    step list (static `steps[]` copied verbatim, each stamped `state=pending`, plus
    the synthesized producer-produced nodes) and ``emitted_meta`` maps each
    synthesized id → ``{"parent": <producer-source-id>, "fanout": bool}`` for the
    nesting step. a2 (no `expected_emit_outputs`) expands to itself unchanged.
    """
    steps = []
    for u in workflow.get("steps") or []:
        node = {
            "id": u["id"],
            "phase": u.get("phase", "work"),
            "depends_on": list(u.get("depends_on") or []),
            "dispatch_context": dict(u.get("invokes") or u.get("dispatch_context") or {}),
            "state": "pending",
        }
        steps.append(node)

    known = {u["id"] for u in steps}
    emitted_meta = {}
    for emit_id in workflow.get("expected_emit_outputs") or []:
        if emit_id in known:
            continue  # already a static step — nothing to synthesize.
        tmpl = _emit_template_for(emit_id, workflow)
        phase = (tmpl or {}).get("phase") or workflow.get("terminal_phase", "work")
        backend_op = ((tmpl or {}).get("invokes") or {}).get("backend_op")
        _from_phase, src_ids = _phase_boundary_source(phase, workflow, steps)
        # Producer-produced work steps are fan-out children when their template
        # dispatches `do_step`; the parent is the (single) producer-source step.
        parent = src_ids[0] if len(src_ids) == 1 else None
        fanout = backend_op == "do_step"
        steps.append({
            "id": emit_id,
            "phase": phase,
            "depends_on": list(src_ids),
            "dispatch_context": {"backend_op": backend_op} if backend_op else {},
            "state": "pending",
            "_emitted": True,
        })
        emitted_meta[emit_id] = {"parent": parent, "fanout": fanout}
        known.add(emit_id)
    return steps, emitted_meta


# ──────────────────────────────────────────────────────────────────────────
# Step 2 — frontier walk (reusing dispatcher's readiness predicate).


def _frontier_waves(steps: list, cap: int):
    """Ordered parallel waves over the expanded DAG, bounded to ``cap`` per wave.

    Drives `dispatcher._is_ready` over the in-memory `steps`: each iteration
    collects every ready step (declaration order → deterministic), takes up to
    ``cap`` of them as one wave, and flips those `pending → verdict-returned` so
    the SAME predicate unblocks their dependents next iteration. The over-cap
    remainder stays `pending` and re-qualifies next wave — mirroring
    `dispatch_batch`'s over-cap spill. Raises `ExecutionTreeError` if the frontier
    empties with steps still pending (a dependency cycle / unsatisfiable ref).
    """
    by_id = _steps_by_id({"steps": steps})
    waves = []
    while True:
        ready = [u for u in steps if _is_ready(u, by_id)]
        if not ready:
            break
        wave = ready[:cap]
        for u in wave:
            u["state"] = "verdict-returned"  # satisfied for the next frontier.
        waves.append([u["id"] for u in wave])
    pending_left = [u["id"] for u in steps if u.get("state") == "pending"]
    if pending_left:
        raise ExecutionTreeError(
            f"underivable workflow: steps never became ready (cycle or unknown "
            f"dependency): {sorted(pending_left)}"
        )
    return waves


# ──────────────────────────────────────────────────────────────────────────
# Step 3 — nest fan-out do_step children under their producer parent.


def _build_nesting(emitted_meta: dict) -> dict:
    """`{parent_id: [child_id, ...]}` for the producer-produced fan-out children.

    Only `do_step` fan-out children are nested (a comparator/judge fan-in stays a
    top-level wave node). Children are sorted for a deterministic structure.
    """
    nesting = {}
    for child, meta in emitted_meta.items():
        if meta.get("fanout") and meta.get("parent"):
            nesting.setdefault(meta["parent"], []).append(child)
    return {p: sorted(kids) for p, kids in nesting.items()}


# ──────────────────────────────────────────────────────────────────────────
# Step 4 — substrate routing decision (KTD6b — a label, not a compile).


def _select_substrate(workflow: dict, steps: list) -> str:
    """`"workflow-script"` (inert routing label) or `"subagent-tree"` (executable).

    A CONCRETE predicate (testable, not vague):

      * single-phase — every step shares one phase (a self-contained fan-in, no
        plan→handoff→work spine to sequence), AND
      * no ce-work/review backend op — no step dispatches `do_step`/`review`
        (those are long-lived background agents that self-write verdicts and MUST
        run on the native subagent-tree), AND
      * bounded — an engine-enforced `iteration.bound` caps the fan-in loop.

    All three ⇒ `"workflow-script"` (the parked RFC's target; inert this run — a
    routing label + preview, no runnable compiled script, KTD6b). Otherwise
    `"subagent-tree"` (today's `dispatch_batch`, the default + only executable
    target). a2/a4 both carry a `review` (and a4 a `do_step`) op → subagent-tree.
    """
    phases = {u.get("phase") for u in steps}
    single_phase = len(phases) <= 1
    has_ce_dispatch = any(
        _step_backend_op(u) in _CE_DISPATCH_OPS for u in steps
    )
    bounded = bool((workflow.get("iteration") or {}).get("bound"))
    if single_phase and not has_ce_dispatch and bounded:
        return "workflow-script"
    return "subagent-tree"


# ──────────────────────────────────────────────────────────────────────────
# Preview — a topology-render-style card over the derived waves.


def _render_preview(workflow: dict, waves: list, nesting: dict, substrate: str) -> str:
    """A deterministic ASCII card of the derived execution tree.

    Mirrors `lib/topology-render.py`'s card idiom (KTD-10 — the same visual family
    the picker / authoring skill use), but renders the DERIVED tree: each wave as a
    numbered parallel row, fan-out children indented under their parent, and the
    substrate routing footer. Pure/stable so tests can assert byte-identity.
    """
    name = workflow.get("name", "?")
    lines = [f"execution-tree: {name}", f"  substrate: {substrate}", ""]
    for i, wave in enumerate(waves, start=1):
        lines.append(f"  ┌─ wave {i}  (parallel ≤ cap)")
        for uid in wave:
            lines.append(f"  │   • {uid}")
            for child in nesting.get(uid, []):
                lines.append(f"  │       ↳ {child}  (do_step fan-out)")
        lines.append("  └─")
        if i < len(waves):
            lines.append("      ▼")
    return "\n".join(lines)


# ──────────────────────────────────────────────────────────────────────────
# Public entry point.


def derive_execution_tree(workflow: dict, cap: int) -> dict:
    """Derive an execution tree from a validated ``workflow`` dict, bounded by ``cap``.

    ``workflow`` — a validated workflow dict (the shape `workflows.load_and_validate`
    returns / `auto-author-workflow` writes). ``cap`` — the fan-out cap bounding each
    parallel wave (a positive int; the active work-loop cap).

    Returns a structured, deterministic dict::

        {
          "workflow":    <workflow name>,
          "cap":       <int cap>,
          "waves":     [[step_id, ...], ...],   # ordered; within a wave = parallel
          "nesting":   {parent_id: [child_id]}, # fan-out do_step children
          "substrate": "subagent-tree" | "workflow-script",
          "emitted":   [synthesized producer-produced ids],
          "preview":   "<topology-render-style card string>",
        }

    Pure: no run-record, no dispatch, no filesystem. Raises `ExecutionTreeError` on a
    non-positive cap or an underivable DAG (cycle / unsatisfiable dependency).
    """
    if cap is None or int(cap) < 1:
        raise ExecutionTreeError(f"cap must be a positive int, got {cap!r}")
    cap = int(cap)

    steps, emitted_meta = _expand_producer_steps(workflow)
    waves = _frontier_waves(steps, cap)
    nesting = _build_nesting(emitted_meta)
    substrate = _select_substrate(workflow, steps)
    preview = _render_preview(workflow, waves, nesting, substrate)

    return {
        "workflow": workflow.get("name", "?"),
        "cap": cap,
        "waves": waves,
        "nesting": nesting,
        "substrate": substrate,
        "emitted": sorted(emitted_meta.keys()),
        "preview": preview,
    }
