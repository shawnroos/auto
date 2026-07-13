#!/usr/bin/env python3
"""auto v0.7.0 (U3): typed-verification gate engine.

Two responsibilities, both pure-stdlib (no pip — the plugin ships to arbitrary
repos via a marketplace; a third-party dep would break install-anywhere, same
constraint as lib/workflows.py):

  1. ``evaluate_programmatic(criterion, cwd)`` — RUN a `programmatic` criterion
     (argv + a `check`) and return a structured pass/fail result with bounded,
     binary-safe evidence. This is the only criterion type the engine evaluates
     in-process; model_judge / advisor_judge / human verdicts are supplied by
     the driver/work-agent as data.

  2. ``aggregate(criteria, programmatic_results, judge_verdicts)`` — a PURE
     function (KTD-6) that folds the programmatic results plus any supplied
     judge verdicts into a single gate decision, or reports which judges are
     still pending. Keeping this pure is what makes the advisor-judge path
     unit-testable without a live ``advisor`` (judge verdicts inject as data).

The criterion shape is the one validated in lib/workflows.py::_validate_verification
and documented in skills/auto-design/references/verification-taxonomy.md.
"""

from __future__ import annotations

import subprocess
from typing import Optional

# Bound the evidence captured from a programmatic criterion so a chatty (or
# binary-spewing) command can't bloat the ledger. Bytes, not chars — applied to
# the encoded output before decode.
_EVIDENCE_CAP_BYTES = 8192
# Default per-criterion subprocess timeout when the criterion omits timeout_sec.
_DEFAULT_TIMEOUT_SEC = 30

# The decisions aggregate() may emit (mirrors lib/iteration.DECISIONS minus the
# engine-only "exit", which the bound logic — not criteria — produces).
_ADVANCE = "advance"
_ITERATE = "iterate"


def _truncate_evidence(raw: bytes) -> str:
    """Cap to _EVIDENCE_CAP_BYTES and decode binary-safe (errors='replace')."""
    clipped = raw[:_EVIDENCE_CAP_BYTES]
    text = clipped.decode("utf-8", errors="replace")
    if len(raw) > _EVIDENCE_CAP_BYTES:
        text += f"\n…[truncated {len(raw) - _EVIDENCE_CAP_BYTES} bytes]"
    return text


def _check_passes(check, returncode: int, stdout: str) -> bool:
    """Apply a criterion's `check` to a finished run. `check` is one of:
    "exit_zero" | {"stdout_contains": s} | {"stdout_equals": s}.
    (Shape already validated at workflow-load time; we re-read defensively.)
    """
    if check == "exit_zero":
        return returncode == 0
    if isinstance(check, dict):
        if "stdout_contains" in check:
            return str(check["stdout_contains"]) in stdout
        if "stdout_equals" in check:
            return stdout.strip() == str(check["stdout_equals"]).strip()
    return False


def evaluate_programmatic(criterion: dict, cwd: Optional[str] = None) -> dict:
    """Run a programmatic criterion. NEVER raises — a timeout, a missing binary,
    or any OSError becomes a ``status: "fail"`` result with descriptive evidence,
    so one bad criterion can't crash the gate.

    Returns ``{"criterion_id", "status": "pass"|"fail", "evidence": str}``.
    """
    cid = criterion.get("id")
    argv = criterion.get("argv") or []
    check = criterion.get("check")
    timeout = criterion.get("timeout_sec", _DEFAULT_TIMEOUT_SEC)
    if not argv:
        # Unreachable via a validated workflow (the validator requires a non-empty
        # argv), but keep the "never raises" contract honest for the debug CLI
        # and any unvalidated caller — subprocess.run([]) would raise IndexError.
        return {"criterion_id": cid, "status": "fail", "evidence": "empty argv (nothing to run)"}
    try:
        proc = subprocess.run(
            list(argv),
            cwd=cwd,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {
            "criterion_id": cid,
            "status": "fail",
            "evidence": f"timed out after {timeout}s: {' '.join(map(str, argv))}",
        }
    except (OSError, ValueError) as e:
        return {
            "criterion_id": cid,
            "status": "fail",
            "evidence": f"could not run {argv!r}: {e}",
        }
    combined = (proc.stdout or b"") + (proc.stderr or b"")
    stdout_text = (proc.stdout or b"").decode("utf-8", errors="replace")
    ok = _check_passes(check, proc.returncode, stdout_text)
    return {
        "criterion_id": cid,
        "status": "pass" if ok else "fail",
        "evidence": _truncate_evidence(combined),
    }


def aggregate(criteria, programmatic_results: dict, judge_verdicts: dict) -> dict:
    """Pure fold of criteria results into a gate-advance SIGNAL (KTD-6).

    Emits a ``signal`` (advance/iterate/None), NOT the committed iteration
    ``decision`` field — lib/iteration.py is the sole owner that translates this
    signal into ``dispatch_context``'s decision (that centralization is enforced
    by tests/unit/iteration-ast-lint.test.sh, which is why this module avoids the
    literal "decision").

    Args:
      criteria: the step's ``verification`` list (each ``{id, type, ...}``).
      programmatic_results: ``{criterion_id: "pass"|"fail"}`` for programmatic
        criteria already run by the engine.
      judge_verdicts: ``{criterion_id: "pass"|"fail"}`` for model_judge /
        advisor_judge / human criteria whose verdict the driver has supplied.

    Returns ``{"signal", "pending_judges"}``:
      - ``pending_judges``: ids of non-programmatic criteria with no supplied
        verdict. When non-empty the gate cannot decide yet → ``signal`` is None.
      - else ``signal``: "advance" if every resolved criterion passed,
        "iterate" if any failed. (The engine's bound logic, not this function,
        turns a persistent "iterate" into "exit".)
    """
    pending = []
    statuses = []
    for c in criteria or []:
        cid = c.get("id")
        ctype = c.get("type")
        if ctype == "programmatic":
            st = programmatic_results.get(cid)
            if st is None:
                # An un-run programmatic criterion is a programming error in the
                # caller, not a judge gap; treat as pending so we never silently
                # "advance" on missing data.
                pending.append(cid)
            else:
                statuses.append(st)
        else:  # model_judge / advisor_judge / human
            st = judge_verdicts.get(cid)
            if st is None:
                pending.append(cid)
            else:
                statuses.append(st)
    if pending:
        return {"signal": None, "pending_judges": pending}
    signal = _ADVANCE if all(s == "pass" for s in statuses) else _ITERATE
    return {"signal": signal, "pending_judges": []}


# ── op-dispatch CLI (exercised by tests/unit/verification.test.sh) ───────────
def _cli(argv) -> int:
    import json
    import sys

    if not argv:
        sys.stderr.write("usage: verification.py <op> ...\n")
        return 2
    op = argv[0]
    if op == "eval-programmatic":
        # argv[1] = criterion JSON
        crit = json.loads(argv[1])
        print(json.dumps(evaluate_programmatic(crit)))
        return 0
    if op == "aggregate":
        # argv[1]=criteria JSON, argv[2]=programmatic_results JSON, argv[3]=judge_verdicts JSON
        crits = json.loads(argv[1])
        pres = json.loads(argv[2])
        jver = json.loads(argv[3])
        print(json.dumps(aggregate(crits, pres, jver)))
        return 0
    sys.stderr.write(f"verification.py: unknown op {op!r}\n")
    return 2


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
