#!/usr/bin/env python3
"""auto U6b: the Compound Engineering (CE) backend — Python surface.

This is the module pulse.py (U4) imports. `resolve_backend` (pulse.py:170-197)
loads `lib/backend-ce.py`, prefers a module-level ``Backend`` factory if present,
and calls the six ops on it: ``next_plan_step(ledger) / plan(ledger) /
deepen(ledger) / review_plan(ledger) / do_unit(unit) / review(unit)``.

The pure, contract-load-bearing logic (severity mapping + the plan-step state
machine) is implemented HERE in Python so pulse.py can import it directly. The
bash sibling ``backend-ce.sh`` exposes the same logic as a CLI for direct
testing / scripting; the two are intentional mirrors.

A backend is a PURE PROVIDER OF OPERATIONS — it NEVER writes the ledger
(contract §1). Ops return data; the engine persists it through ledger.py.

PLAN-STEP STATE: `next_plan_step` reads `ledger["plan_step"]` (the plan-phase
sub-state, schema §3.1) to compute the next step. The pulse persists the executed
step via `set_loop(plan_step=step)` after each plan-loop advance
(pulse_advance.py), so a fresh-process pulse reads the real sub-state — the loop
advances plan → deepen → review_plan → done and does not livelock. (Historical
note: an earlier U6b/U3 seam had no schema field for this; the gap was closed
when `plan_step` became a validated field — see ledger_core.py's PLAN_STEPS.)

DECLARED SEVERITY MAPPING (contract §3.1, fixed property):
    P0 -> blocker;  P1 -> major;  P2 -> major;  P3 -> minor
DECLARED backend_scale: "three-tier"
    CE's /ce-code-review emits stable P0/P1/P2/P3 that map cleanly onto all
    three shared severities, so CE skips the rubric probe (SKILL.md §"command-
    driven reviewer") and declares three-tier directly.
"""

import os as _os
import sys as _sys

_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from _bootstrap import load_lib_module, plan_step_sequencer  # noqa: E402  (path-prepend first)

# U12: typed dispatch_context accessor for the plan_path read (iteration is a
# `_bootstrap`-only leaf — no import cycle).
iteration = load_lib_module("iteration")

BACKEND_NAME = "ce"
BACKEND_SCALE = "three-tier"

# The static CE -> shared-scale table (contract §3.1).
_SEVERITY_TABLE = {"P0": "blocker", "P1": "major", "P2": "major", "P3": "minor"}

_PLAN_STEPS = ("plan", "deepen", "review_plan", "done")
# The transition sequence handed to the shared sequencer (U10): the plan steps
# WITHOUT the terminal "done". CE loops plan -> deepen -> review_plan and, while
# gaps remain, loops back to "deepen".
_PLAN_SEQUENCE = _PLAN_STEPS[:-1]


def map_level(ce_level):
    """One CE level -> one shared severity. Unknown levels are a contract
    violation (the engine only ever sees the three shared values)."""
    key = str(ce_level).upper()
    if key not in _SEVERITY_TABLE:
        raise ValueError("backend-ce: unknown CE level %r (expected P0|P1|P2|P3)" % ce_level)
    return _SEVERITY_TABLE[key]


def map_findings(ce_findings):
    """PARSE half of `review`: a list of CE findings
    ``[{"level": "P0".."P3", "note": str}]`` -> the contract's findings[] shape
    ``[{"severity": "blocker|major|minor", "note": str}]``. Deterministic."""
    return [
        {"severity": map_level(f.get("level", "")), "note": f.get("note", "")}
        for f in ce_findings
    ]


def _bound_plan_path(ledger):
    """The plan doc path bound to the run's plan unit (plan_presatisfied / W).

    lib/auto.py binds the reviewed plan's path to the single plan-phase unit's
    dispatch_context.plan_path at init (the schema has no top-level slot for it).
    Returns it, or None for a1-style runs where the plan was produced in-session.
    """
    for u in ledger.get("units", []):
        if u.get("phase") == "plan":
            return iteration.read_plan_path(u)
    return None


def _next_plan_step(ledger):
    """Thin CE wrapper over the shared ``plan_step_sequencer`` (U10).

    CE's plan loop runs plan -> deepen -> review_plan and, while gaps remain,
    loops back to "deepen"; once a review_plan round closes the gaps the shared
    §4.1 coherence guard returns "done" (else livelock). All that per-backend
    logic is now the injected ``_PLAN_SEQUENCE``; the guard + ``plan_step is
    None`` first-step logic live once in ``_bootstrap``. ``plan_step`` is a real
    validated ledger field (``ledger_core.PLAN_STEPS``) the pulse persists.
    """
    return plan_step_sequencer(ledger, sequence=_PLAN_SEQUENCE)


class Backend:
    """The object pulse.py's ``resolve_backend`` instantiates (it prefers a
    module-level ``Backend`` factory). Exposes the six ops as methods.

    The four plan-loop ops receive the ledger dict (pulse.py:347 calls
    ``op(ledger_dict)``). `next_plan_step` is fully pure. `plan / deepen /
    review_plan` and the work-loop `do_unit / review` are the live-invocation
    seam: a CLI/model cannot *run* /ce-plan etc., so each prepares an invocation
    envelope the model executes and parses the structured result back onto the
    contract shape. The PARSE halves (map_findings, gap-set passthrough) are
    pure; what is NOT faked is a live command result.
    """

    name = BACKEND_NAME
    backend_scale = BACKEND_SCALE

    # ── plan-loop ops ──────────────────────────────────────────────────────
    def next_plan_step(self, ledger):
        return _next_plan_step(ledger)

    def enumerate_plan_units(self, ledger):
        """PREPARE the plan→work-units enumeration (v0.2.0 re-lock, KTD-4).

        The producer the producers read. At plan-done the engine calls this to turn
        the reviewed plan into a work-unit list. Prepare-only: returns an envelope
        the MODEL executes (reads the plan, returns `[{id, invokes, ...}]`); the
        engine persists it onto the plan unit's `dispatch_context.enumerated_units`
        (U6) and the producers (U5b) shape it into ledger units. v0.4.3 (KTD-15):
        for a plan_presatisfied run (W), the bound plan path (`_bound_plan_path`)
        is surfaced so the envelope names WHICH plan; omitted for a1.

        U14 (KTD-1): each enumerated item must carry a `depends_on` list naming
        the sibling unit ids it depends on (empty when independent) so the
        readiness engine (`dispatcher.ready_units`) can order the fan-out. The
        op is prepare-only, so the invocation string is the ONLY place the model
        is told to originate those edges — without it, passthrough carries []."""
        edge_clause = (
            " — each item is {id, invokes, depends_on}, where depends_on lists "
            "the sibling unit ids that must complete first (empty [] if the unit "
            "is independent)"
        )
        envelope = {
            "backend": BACKEND_NAME,
            "op": "enumerate_plan_units",
            "invocation": "enumerate the reviewed plan's work units" + edge_clause,
        }
        plan_path = _bound_plan_path(ledger)
        if plan_path:
            envelope["plan_path"] = plan_path
            envelope["invocation"] = (
                f"enumerate the reviewed plan's work units from {plan_path}"
                + edge_clause
            )
        return envelope

    def plan(self, ledger):
        """PREPARE /ce-plan. Returns an opaque invocation envelope the engine
        round-trips into deepen/review_plan; the model runs the command."""
        return {"backend": BACKEND_NAME, "op": "plan", "invocation": "/ce-plan"}

    def deepen(self, plan):
        """PREPARE a CE deepen pass over the prior plan."""
        return {"backend": BACKEND_NAME, "op": "deepen", "invocation": "deepen-pass"}

    def review_plan(self, plan):
        """PREPARE /ce-doc-review. The model returns a gap-set array; the engine
        reads only its length (contract §2.2)."""
        return {"backend": BACKEND_NAME, "op": "review_plan", "invocation": "/ce-doc-review"}

    # ── spine entry op (v0.6.0 / U7) ─────────────────────────────────────────
    def brainstorm(self, unit):
        """PREPARE /ce-brainstorm for the spine's brainstorm-entry unit
        (recipes/pipeline.json declares ``invokes.adapter_op: "brainstorm"``).

        Prepare-only, mirroring ``do_unit``: the model runs /ce-brainstorm,
        records the requirements-doc path on the unit's
        ``dispatch_context.requirements_doc``, and self-writes verdict-returned;
        the engine then fires the U8 ``brainstorm_output_to_plan_unit`` producer
        on advance to plan. Without this op the spine's brainstorm unit resolved
        to nothing and could never be worked to terminal (round-1 P1)."""
        unit_id = unit.get("id") if isinstance(unit, dict) else unit
        return {
            "backend": BACKEND_NAME,
            "op": "brainstorm",
            "unit_id": unit_id,
            "invocation": "/ce-brainstorm",
        }

    # ── work-loop ops ──────────────────────────────────────────────────────
    def do_unit(self, unit):
        """PREPARE /ce-work for a unit. Returns an opaque dispatch_handle the
        dispatcher (U10) uses to correlate the in-flight agent; U10 defines
        the correlation contract over this shape."""
        unit_id = unit.get("id") if isinstance(unit, dict) else unit
        return {
            "backend": BACKEND_NAME,
            "op": "do_unit",
            "unit_id": unit_id,
            "invocation": "/ce-work %s" % unit_id,
        }

    def review(self, unit):
        """PARSE half of `review`: translate /ce-code-review's structured output
        (CE findings with level P0..P3) onto the shared severity scale. The
        live /ce-code-review run is the model's; this maps its result.

        Accepts the CE findings either on ``unit["ce_findings"]`` or as a bare
        list, and returns the contract findings[] shape. The engine records
        these via record_verdict; this backend does NOT write them (§3.2)."""
        if isinstance(unit, dict):
            ce_findings = unit.get("ce_findings", [])
        else:
            ce_findings = unit
        return map_findings(ce_findings)


# ──────────────────────────────────────────────────────────────────────────
# CLI (the .sh shim DELEGATES here — backend-ce.sh execs this module). This is
# the SINGLE implementation of the severity table + next_plan_step state machine;
# the .sh no longer re-implements them in an inline Python heredoc (the pure
# logic lived in two places and could drift). Positional argv only; the .sh pins
# the interpreter and word-splits "$ARGUMENTS" before exec'ing us.


def _cli(argv):
    import json
    import sys

    if not argv:
        sys.stderr.write("usage: backend-ce.py <subcommand> [args...]\n")
        return 2
    sub, rest = argv[0], argv[1:]
    try:
        if sub == "backend-scale":
            sys.stdout.write(BACKEND_SCALE + "\n")
            return 0
        if sub == "map-level":
            sys.stdout.write(map_level(rest[0]) + "\n")
            return 0
        if sub == "map-findings":
            json.dump(map_findings(json.loads(rest[0])), sys.stdout)
            return 0
        if sub == "next-plan-step":
            sys.stdout.write(_next_plan_step(json.loads(rest[0])) + "\n")
            return 0
        sys.stderr.write("backend-ce: unknown subcommand %r\n" % sub)
        return 2
    except (ValueError, IndexError) as exc:
        sys.stderr.write("backend-ce: %s\n" % exc)
        return 1


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
