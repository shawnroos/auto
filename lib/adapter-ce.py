#!/usr/bin/env python3
"""claude-dispatch U6b: the Compound Engineering (CE) adapter — Python surface.

This is the module tick.py (U4) imports. `resolve_adapter` (tick.py:170-197)
loads `lib/adapter-ce.py`, prefers a module-level ``Adapter`` factory if present,
and calls the six ops on it: ``next_plan_step(ledger) / plan(ledger) /
deepen(ledger) / review_plan(ledger) / do_unit(unit) / review(unit)``.

The pure, contract-load-bearing logic (severity mapping + the plan-step state
machine) is implemented HERE in Python so tick.py can import it directly. The
bash sibling ``adapter-ce.sh`` exposes the same logic as a CLI for direct
testing / scripting; the two are intentional mirrors.

An adapter is a PURE PROVIDER OF OPERATIONS — it NEVER writes the ledger
(contract §1). Ops return data; the engine persists it through ledger.py.

══════════════════════════════════════════════════════════════════════════════
CONTRACT GAP (raise-it-don't-guess, per adapter-contract.md header) — BLOCKS
INTEGRATION, does NOT block the U6b pure deliverable.

  `next_plan_step` needs to know which plan step last ran (plan -> deepen ->
  review_plan). The LOCKED ledger schema (ledger-schema.md §2.1) exposes NO
  field carrying this: its top-level fields are run_id, loop_phase, seam_paused,
  adapter, adapter_scale, exit_predicate_result, units, loop. And tick.py:337
  calls `adapter.next_plan_step(ledger)` then `getattr(adapter, step)(ledger)`
  (tick.py:342-347) but NEVER persists the chosen step back to the ledger.

  Consequence: a fresh-process tick always reads no step-state -> the state
  machine below always returns "plan" -> the plan-loop LIVELOCKS at integration.

  This is a SEAM break between U6b and U3/U4, not a bug in the logic below. The
  state machine + coherence guard are correct against the contract; they just
  have no schema field to read from. Resolution is UPSTREAM — U3/U4 must either:
    (a) add a `plan_step` field to the ledger schema (re-lock), and have tick.py
        persist the executed step after each plan-loop advance, OR
    (b) change the calling convention so tick.py passes the prior step as a hint.

  We read a tolerated `ledger["plan_step"]` IF a future schema adds it (so this
  adapter is correct the moment the gap closes), and degrade safely otherwise.
  We do NOT invent a derivation from loop_phase/gaps_open — those three states
  (not-yet-planned / planned-awaiting-deepen / deepened-awaiting-review) are
  indistinguishable from schema fields, so guessing would be the contract
  violation the header forbids.
══════════════════════════════════════════════════════════════════════════════

DECLARED SEVERITY MAPPING (contract §3.1, fixed property):
    P0 -> blocker;  P1 -> major;  P2 -> major;  P3 -> minor
DECLARED adapter_scale: "three-tier"
    CE's /ce-code-review emits stable P0/P1/P2/P3 that map cleanly onto all
    three shared severities, so CE skips the rubric probe (SKILL.md §"command-
    driven reviewer") and declares three-tier directly.
"""

ADAPTER_NAME = "ce"
ADAPTER_SCALE = "three-tier"

# The static CE -> shared-scale table (contract §3.1).
_SEVERITY_TABLE = {"P0": "blocker", "P1": "major", "P2": "major", "P3": "minor"}

_PLAN_STEPS = ("plan", "deepen", "review_plan", "done")


def map_level(ce_level):
    """One CE level -> one shared severity. Unknown levels are a contract
    violation (the engine only ever sees the three shared values)."""
    key = str(ce_level).upper()
    if key not in _SEVERITY_TABLE:
        raise ValueError("adapter-ce: unknown CE level %r (expected P0|P1|P2|P3)" % ce_level)
    return _SEVERITY_TABLE[key]


def map_findings(ce_findings):
    """PARSE half of `review`: a list of CE findings
    ``[{"level": "P0".."P3", "note": str}]`` -> the contract's findings[] shape
    ``[{"severity": "blocker|major|minor", "note": str}]``. Deterministic."""
    return [
        {"severity": map_level(f.get("level", "")), "note": f.get("note", "")}
        for f in ce_findings
    ]


def _next_plan_step(ledger):
    """Pure CE plan-loop sequencer (contract §4): plan -> deepen -> review_plan
    -> (loop deepen/review while gaps remain) -> done.

    §4.1 coherence guard FIRST: once a review_plan round has closed the gaps
    (gaps_open == 0), the next call MUST return "done" (else livelock). Keyed on
    plan_step == "review_plan" specifically — gaps_open is 0 by default before
    any review has run, so the guard must only fire AFTER a real review pass.

    See the CONTRACT GAP block: `plan_step` is not yet a schema field.
    """
    epr = ledger.get("exit_predicate_result") or {}
    plan_step = ledger.get("plan_step")
    if plan_step in ("review_plan", "done") and epr.get("gaps_open", 0) == 0:
        return "done"
    if plan_step is None:
        return "plan"
    if plan_step == "plan":
        return "deepen"
    if plan_step == "deepen":
        return "review_plan"
    if plan_step == "review_plan":
        # gaps still open here (else the guard fired) -> another deepen round.
        return "deepen"
    return "done"


class Adapter:
    """The object tick.py's ``resolve_adapter`` instantiates (it prefers a
    module-level ``Adapter`` factory). Exposes the six ops as methods.

    The four plan-loop ops receive the ledger dict (tick.py:347 calls
    ``op(ledger_dict)``). `next_plan_step` is fully pure. `plan / deepen /
    review_plan` and the work-loop `do_unit / review` are the live-invocation
    seam: a CLI/model cannot *run* /ce-plan etc., so each prepares an invocation
    envelope the model executes and parses the structured result back onto the
    contract shape. The PARSE halves (map_findings, gap-set passthrough) are
    pure; what is NOT faked is a live command result.
    """

    name = ADAPTER_NAME
    adapter_scale = ADAPTER_SCALE

    # ── plan-loop ops ──────────────────────────────────────────────────────
    def next_plan_step(self, ledger):
        return _next_plan_step(ledger)

    def plan(self, ledger):
        """PREPARE /ce-plan. Returns an opaque invocation envelope the engine
        round-trips into deepen/review_plan; the model runs the command."""
        return {"adapter": ADAPTER_NAME, "op": "plan", "invocation": "/ce-plan"}

    def deepen(self, plan):
        """PREPARE a CE deepen pass over the prior plan."""
        return {"adapter": ADAPTER_NAME, "op": "deepen", "invocation": "deepen-pass"}

    def review_plan(self, plan):
        """PREPARE /ce-doc-review. The model returns a gap-set array; the engine
        reads only its length (contract §2.2)."""
        return {"adapter": ADAPTER_NAME, "op": "review_plan", "invocation": "/ce-doc-review"}

    # ── work-loop ops ──────────────────────────────────────────────────────
    def do_unit(self, unit):
        """PREPARE /ce-work for a unit. Returns an opaque dispatch_handle the
        orchestrator (U10) uses to correlate the in-flight agent; U10 defines
        the correlation contract over this shape."""
        unit_id = unit.get("id") if isinstance(unit, dict) else unit
        return {
            "adapter": ADAPTER_NAME,
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
        these via record_verdict; this adapter does NOT write them (§3.2)."""
        if isinstance(unit, dict):
            ce_findings = unit.get("ce_findings", [])
        else:
            ce_findings = unit
        return map_findings(ce_findings)


# ──────────────────────────────────────────────────────────────────────────
# CLI (the .sh shim DELEGATES here — adapter-ce.sh execs this module). This is
# the SINGLE implementation of the severity table + next_plan_step state machine;
# the .sh no longer re-implements them in an inline Python heredoc (the pure
# logic lived in two places and could drift). Positional argv only; the .sh pins
# the interpreter and word-splits "$ARGUMENTS" before exec'ing us.


def _cli(argv):
    import json
    import sys

    if not argv:
        sys.stderr.write("usage: adapter-ce.py <subcommand> [args...]\n")
        return 2
    sub, rest = argv[0], argv[1:]
    a = Adapter()
    try:
        if sub == "adapter-scale":
            sys.stdout.write(ADAPTER_SCALE + "\n")
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
        if sub == "prepare-plan":
            json.dump(a.plan(rest[0] if rest else None), sys.stdout)
            return 0
        if sub == "prepare-deepen":
            json.dump(a.deepen(rest[0] if rest else None), sys.stdout)
            return 0
        if sub == "prepare-review-plan":
            json.dump(a.review_plan(rest[0] if rest else None), sys.stdout)
            return 0
        if sub == "prepare-do-unit":
            json.dump(a.do_unit(rest[0] if rest else None), sys.stdout)
            return 0
        sys.stderr.write("adapter-ce: unknown subcommand %r\n" % sub)
        return 2
    except (ValueError, IndexError) as exc:
        sys.stderr.write("adapter-ce: %s\n" % exc)
        return 1


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
