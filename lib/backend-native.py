#!/usr/bin/env python3
"""auto U6b: the native Claude backend — Python surface.

This is the module pulse.py (U4) imports. `resolve_backend` (pulse.py:170-197)
loads `lib/backend-native.py`, prefers a module-level ``Backend`` factory, and
calls the six ops on it: ``next_plan_step(run-record) / plan(run-record) /
deepen(run-record) / review_plan(run-record) / do_step(step) / review(step)``.

The pure logic (severity validation + the plan-step state machine) is here so
pulse.py can import it; the bash sibling ``backend-native.sh`` mirrors it as a
CLI for direct testing. A backend NEVER writes the run-record (contract §1).

══════════════════════════════════════════════════════════════════════════════
RUBRIC PROBE OUTCOME (gates this backend — contract §3.1, plan U6b "FIRST"):

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

  THEREFORE backend_scale = "blocker-only". The predicate evaluator applies
  blocker-only logic for native runs: only `blocker` reliably gates the loop.
  R2's "widest gap" rationale is PARTIALLY met — the blocker gate is
  trustworthy, the major gate is best-effort. Native `review` still emits the
  full three-tier scale (it is the single shared scale); the engine treats
  native majors as advisory rather than gating.
══════════════════════════════════════════════════════════════════════════════

PLAN-STEP STATE: `next_plan_step` reads `run_record["plan_step"]` (the plan-phase
sub-state, schema §3.1); the pulse persists the executed step via
`set_loop(plan_step=step)` after each plan-loop advance (pulse_advance.py), so a
fresh-process pulse reads the real sub-state and the loop advances rather than
livelocking. (Native never emits "deepen": plan → review_plan → done.)

DECLARED SEVERITY MAPPING (contract §3.1): native reviewers self-tag directly on
the shared scale (no foreign vocabulary), so the "mapping" is the injected
rubric (``review_rubric``); ``validate_findings`` rejects anything off-scale.
"""

import os as _os
import sys as _sys

_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from _bootstrap import plan_step_sequencer  # noqa: E402  (path-prepend first)

BACKEND_NAME = "native"
# Set by the rubric probe above (partial -> blocker-only).
BACKEND_SCALE = "blocker-only"

_SEVERITIES = ("blocker", "major", "minor")

# The transition sequence handed to the shared sequencer (U10): plan steps
# WITHOUT the terminal "done". Native has NO deepen step, so it NEVER emits
# "deepen": plan -> review_plan, looping back to "review_plan" while gaps remain.
_PLAN_SEQUENCE = ("plan", "review_plan")

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
                "backend-native: off-scale severity %r (expected blocker|major|minor)" % sev
            )
        out.append({"severity": sev, "note": f.get("note", "")})
    return out


def _next_plan_step(run_record):
    """Thin native wrapper over the shared ``plan_step_sequencer`` (U10).

    Native has NO deepen step, so it NEVER emits "deepen": plan -> review_plan
    and, while gaps remain, loops back to "review_plan"; once a review_plan round
    closes the gaps the shared §4.1 coherence guard returns "done". That
    per-backend difference is now the injected ``_PLAN_SEQUENCE``; the guard +
    ``plan_step is None`` first-step logic live once in ``_bootstrap``.
    ``plan_step`` IS a real validated run-record field (``run_record_core.PLAN_STEPS``)
    that the pulse persists — read identically by both backends (there is no
    native-specific schema gap; the sequencer just keeps native's None-tolerance).
    """
    return plan_step_sequencer(run_record, sequence=_PLAN_SEQUENCE)


class Backend:
    """The object pulse.py's ``resolve_backend`` instantiates. Exposes the six
    ops as methods. `next_plan_step` and `deepen` are fully pure; `plan /
    review_plan / do_step / review` are the live-invocation handoff (PREPARE an
    envelope/rubric the model acts on, PARSE the structured result)."""

    name = BACKEND_NAME
    backend_scale = BACKEND_SCALE
    review_rubric = REVIEW_RUBRIC

    # ── plan-loop ops ──────────────────────────────────────────────────────
    def next_plan_step(self, run_record):
        return _next_plan_step(run_record)

    def enumerate_plan_steps(self, run_record):
        """PREPARE the plan→work-steps enumeration (v0.2.0 contract re-lock, KTD-4).

        Native counterpart of the CE op. Prepare-only: the model reads the
        reviewed prose plan and returns a list of step dicts; the engine persists
        them to the plan step's dispatch_context.enumerated_steps (U6) and the
        producers (U5b) shape them into run-record steps. The producer the producers
        read — resolves the F4 gap.

        U14 (KTD-1): each enumerated item carries a depends_on list (sibling step
        ids that must complete first; empty [] when independent) so the readiness
        engine can order the fan-out. Prepare-only, so this invocation string is
        where the model is instructed to originate the edges."""
        return {
            "backend": BACKEND_NAME,
            "op": "enumerate_plan_steps",
            "invocation": (
                "enumerate-plan-work-steps; each item is {id, invokes, "
                "depends_on}, where depends_on lists the sibling step ids that "
                "must complete first (empty [] if independent)"
            ),
        }

    def plan(self, run_record):
        """PREPARE a prose-plan invocation; the model writes the plan."""
        return {"backend": BACKEND_NAME, "op": "plan", "invocation": "write-prose-plan"}

    def deepen(self, plan):
        """No-op: native has no deepen concept (contract §6.2; next_plan_step
        never emits "deepen"). Returns the plan unchanged — never mutates."""
        return plan

    def review_plan(self, plan):
        """PREPARE a review + list-gaps invocation. The model returns a gap-set
        array; the engine reads only its length (contract §2.2)."""
        return {
            "backend": BACKEND_NAME,
            "op": "review_plan",
            "invocation": "review-and-list-gaps",
        }

    # ── work-loop ops ──────────────────────────────────────────────────────
    def do_step(self, step):
        """PREPARE a native edit / Task dispatch. Returns an opaque
        dispatch_handle the dispatcher (U10) correlates the in-flight agent
        with; U10 defines the correlation contract over this shape."""
        step_id = step.get("id") if isinstance(step, dict) else step
        return {
            "backend": BACKEND_NAME,
            "op": "do_step",
            "step_id": step_id,
            "invocation": "native-task %s" % step_id,
        }

    def review(self, step):
        """PARSE half of `review`: the native self-review tags findings against
        the rubric (a model action); this validates the result is on the shared
        scale and passes it through. The engine records it via record_verdict.

        Accepts the tagged findings on ``step["findings"]`` or as a bare list."""
        if isinstance(step, dict):
            findings = step.get("findings", [])
        else:
            findings = step
        return validate_findings(findings)


# ──────────────────────────────────────────────────────────────────────────
# CLI (the .sh shim DELEGATES here — backend-native.sh execs this module). This
# is the SINGLE implementation of the rubric + validate_findings + next_plan_step
# state machine; the .sh no longer re-implements them in an inline Python heredoc
# (the pure logic lived in two places and could drift). Positional argv only; the
# .sh pins the interpreter and word-splits "$ARGUMENTS" before exec'ing us.


def _cli(argv):
    import json
    import sys

    if not argv:
        sys.stderr.write("usage: backend-native.py <subcommand> [args...]\n")
        return 2
    sub, rest = argv[0], argv[1:]
    a = Backend()
    try:
        if sub == "backend-scale":
            sys.stdout.write(BACKEND_SCALE + "\n")
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
        sys.stderr.write("backend-native: unknown subcommand %r\n" % sub)
        return 2
    except (ValueError, IndexError) as exc:
        sys.stderr.write("backend-native: %s\n" % exc)
        return 1


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
