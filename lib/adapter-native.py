#!/usr/bin/env python3
"""claude-dispatch U6b: the native Claude adapter — Python surface.

This is the module tick.py (U4) imports. `resolve_adapter` (tick.py:170-197)
loads `lib/adapter-native.py`, prefers a module-level ``Adapter`` factory, and
calls the six ops on it: ``next_plan_step(ledger) / plan(ledger) /
deepen(ledger) / review_plan(ledger) / do_unit(unit) / review(unit)``.

The pure logic (severity validation + the plan-step state machine) is here so
tick.py can import it; the bash sibling ``adapter-native.sh`` mirrors it as a
CLI for direct testing. An adapter NEVER writes the ledger (contract §1).

══════════════════════════════════════════════════════════════════════════════
RUBRIC PROBE OUTCOME (gates this adapter — contract §3.1, plan U6b "FIRST"):

  A native reviewer is a Claude model judging findings against the
  blocker/major/minor rubric. The probe gave it 5 representative findings:
    1. SQL injection (unsanitized input)            -> blocker  (clear)
    2. Missing await: response before DB commit      -> blocker  (clear)
    3. Off-by-one pagination drops last record       -> major*   (HEDGED)
    4. Redundant local var, could be inlined         -> minor*   (HEDGED)
    5. Comment typo                                  -> minor    (clear)

  OUTCOME: **partial**. The blocker tier is reliable (security/correctness/
  data-loss tag unambiguously); the major/minor boundary HEDGED on 2 of 5
  (bounded correctness bug vs. code smell). Per the contract's partial rule,
  a hedge on even one major/minor finding drops us off "three-tier".

  THEREFORE adapter_scale = "blocker-only". The predicate evaluator applies
  blocker-only logic for native runs: only `blocker` reliably gates the loop.
  R2's "widest gap" rationale is PARTIALLY met — the blocker gate is
  trustworthy, the major gate is best-effort. Native `review` still emits the
  full three-tier scale (it is the single shared scale); the engine treats
  native majors as advisory rather than gating.
══════════════════════════════════════════════════════════════════════════════

CONTRACT GAP (raise-it-don't-guess) — BLOCKS INTEGRATION, not the U6b deliverable:

  `next_plan_step` needs the last plan step ran. The LOCKED ledger schema
  (ledger-schema.md §2.1) exposes NO such field, and tick.py:337-347 calls
  `next_plan_step(ledger)` then `getattr(adapter, step)(ledger)` but never
  PERSISTS the chosen step back. So a fresh-process tick always reads no
  step-state -> always returns "plan" -> the plan-loop LIVELOCKS at integration.
  This is a SEAM break with U3/U4; resolution is upstream (add a `plan_step`
  schema field + persist it, OR pass the prior step as a hint). The state
  machine below is correct against the contract; it has no field to read from.
  We do NOT derive a step from loop_phase/gaps_open (those three plan states
  are indistinguishable from schema fields — guessing is the violation).

DECLARED SEVERITY MAPPING (contract §3.1): native reviewers self-tag directly on
the shared scale (no foreign vocabulary), so the "mapping" is the injected
rubric (``review_rubric``); ``validate_findings`` rejects anything off-scale.
"""

ADAPTER_NAME = "native"
# Set by the rubric probe above (partial -> blocker-only).
ADAPTER_SCALE = "blocker-only"

_SEVERITIES = ("blocker", "major", "minor")

REVIEW_RUBRIC = (
    "Tag each finding with exactly one severity:\n"
    "  blocker - security holes, data loss/corruption, crashes, or incorrect\n"
    "            results that ship to users. GATES the loop.\n"
    "  major   - real defects to fix that do not lose data or ship wrong\n"
    "            results. Best-effort under blocker-only scale.\n"
    "  minor   - style, naming, clarity, comments. Reported at exit; never gates.\n"
    'Emit findings as JSON: [{"severity":"blocker|major|minor","note":"..."}].'
)


def validate_findings(findings):
    """PARSE half of `review`: the native reviewer tags findings against the
    rubric out of band (a model action). Validate the result is on the shared
    scale and pass it through; off-scale severities are a contract violation."""
    out = []
    for f in findings:
        sev = str(f.get("severity", ""))
        if sev not in _SEVERITIES:
            raise ValueError(
                "adapter-native: off-scale severity %r (expected blocker|major|minor)" % sev
            )
        out.append({"severity": sev, "note": f.get("note", "")})
    return out


def _next_plan_step(ledger):
    """Pure native plan-loop sequencer (contract §4). Native has NO deepen step,
    so it NEVER emits "deepen": plan -> review_plan -> (loop review while gaps
    remain) -> done.

    §4.1 coherence guard FIRST: gaps_open == 0 after a review_plan -> "done".
    See the CONTRACT GAP block: `plan_step` is not yet a schema field.
    """
    epr = ledger.get("exit_predicate_result") or {}
    plan_step = ledger.get("plan_step")
    if plan_step in ("review_plan", "done") and epr.get("gaps_open", 0) == 0:
        return "done"
    if plan_step is None:
        return "plan"
    if plan_step == "plan":
        return "review_plan"
    if plan_step == "review_plan":
        # gaps still open (else the guard fired) -> review again. Never deepens.
        return "review_plan"
    return "done"


class Adapter:
    """The object tick.py's ``resolve_adapter`` instantiates. Exposes the six
    ops as methods. `next_plan_step` and `deepen` are fully pure; `plan /
    review_plan / do_unit / review` are the live-invocation seam (PREPARE an
    envelope/rubric the model acts on, PARSE the structured result)."""

    name = ADAPTER_NAME
    adapter_scale = ADAPTER_SCALE
    review_rubric = REVIEW_RUBRIC

    # ── plan-loop ops ──────────────────────────────────────────────────────
    def next_plan_step(self, ledger):
        return _next_plan_step(ledger)

    def plan(self, ledger):
        """PREPARE a prose-plan invocation; the model writes the plan."""
        return {"adapter": ADAPTER_NAME, "op": "plan", "invocation": "write-prose-plan"}

    def deepen(self, plan):
        """No-op: native has no deepen concept (contract §6.2; next_plan_step
        never emits "deepen"). Returns the plan unchanged — never mutates."""
        return plan

    def review_plan(self, plan):
        """PREPARE a review + list-gaps invocation. The model returns a gap-set
        array; the engine reads only its length (contract §2.2)."""
        return {
            "adapter": ADAPTER_NAME,
            "op": "review_plan",
            "invocation": "review-and-list-gaps",
        }

    # ── work-loop ops ──────────────────────────────────────────────────────
    def do_unit(self, unit):
        """PREPARE a native edit / Task dispatch. Returns an opaque
        dispatch_handle the orchestrator (U10) correlates the in-flight agent
        with; U10 defines the correlation contract over this shape."""
        unit_id = unit.get("id") if isinstance(unit, dict) else unit
        return {
            "adapter": ADAPTER_NAME,
            "op": "do_unit",
            "unit_id": unit_id,
            "invocation": "native-task %s" % unit_id,
        }

    def review(self, unit):
        """PARSE half of `review`: the native self-review tags findings against
        the rubric (a model action); this validates the result is on the shared
        scale and passes it through. The engine records it via record_verdict.

        Accepts the tagged findings on ``unit["findings"]`` or as a bare list."""
        if isinstance(unit, dict):
            findings = unit.get("findings", [])
        else:
            findings = unit
        return validate_findings(findings)


# ──────────────────────────────────────────────────────────────────────────
# CLI (the .sh shim DELEGATES here — adapter-native.sh execs this module). This
# is the SINGLE implementation of the rubric + validate_findings + next_plan_step
# state machine; the .sh no longer re-implements them in an inline Python heredoc
# (the pure logic lived in two places and could drift). Positional argv only; the
# .sh pins the interpreter and word-splits "$ARGUMENTS" before exec'ing us.


def _cli(argv):
    import json
    import sys

    if not argv:
        sys.stderr.write("usage: adapter-native.py <subcommand> [args...]\n")
        return 2
    sub, rest = argv[0], argv[1:]
    a = Adapter()
    try:
        if sub == "adapter-scale":
            sys.stdout.write(ADAPTER_SCALE + "\n")
            return 0
        if sub == "review-rubric":
            sys.stdout.write(REVIEW_RUBRIC + "\n")
            return 0
        if sub == "validate-findings":
            json.dump(validate_findings(json.loads(rest[0])), sys.stdout)
            return 0
        if sub == "next-plan-step":
            sys.stdout.write(_next_plan_step(json.loads(rest[0])) + "\n")
            return 0
        if sub == "deepen":
            # Native deepen is a verbatim no-op; emit the plan unchanged (no
            # trailing newline — mirrors the bash printf '%s' it replaces).
            sys.stdout.write(a.deepen(rest[0] if rest else ""))
            return 0
        if sub == "prepare-plan":
            json.dump(a.plan(rest[0] if rest else None), sys.stdout)
            return 0
        if sub == "prepare-review-plan":
            json.dump(a.review_plan(rest[0] if rest else None), sys.stdout)
            return 0
        if sub == "prepare-do-unit":
            json.dump(a.do_unit(rest[0] if rest else None), sys.stdout)
            return 0
        sys.stderr.write("adapter-native: unknown subcommand %r\n" % sub)
        return 2
    except (ValueError, IndexError) as exc:
        sys.stderr.write("adapter-native: %s\n" % exc)
        return 1


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
