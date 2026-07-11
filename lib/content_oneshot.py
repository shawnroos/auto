#!/usr/bin/env python3
"""auto one-shot content helpers (U2 + U4, addressable-step-contents).

Two THIN, pure/testable pieces the `auto-content` skill calls to run a content
one-shot (KTD-3 — the skill is the orchestrator; this module holds no control
flow, no tick, no `/goal`):

  1. ``synthesize_oneshot_unit(content, ratified_criteria)`` (U2) — turn a loaded
     content + the ratified verification criteria into a SINGLE work-phase ledger
     unit. The content's `invokes` (adapter_op + optional prompt_template) rides on
     the unit's ``dispatch_context`` (the durable home ``orchestrator._unit_adapter_op``
     reads first). NO ``iteration`` block, NO ``phase_transitions`` — the one-shot
     never loops (KTD-3).

  2. ``oneshot_verdict(unit, programmatic_results, judge_verdicts)`` (U4) — the
     TERMINAL verdict: fold the ratified criteria + resolved results into a single
     ``verification.aggregate`` call and re-label the aggregator's advance/iterate
     SIGNAL as a terminal ``pass``/``fail`` (KTD-1). This is READ-ONLY over the
     criteria: it reports a verdict, it does NOT commit an iteration decision.

KTD-1 BOUNDARY (defended in review + import-topology): this module MUST NOT import
`lib/iteration.py` (the iteration-decision-commit module) and MUST NOT write a
`decision` field onto the unit's `dispatch_context`. The one-shot verdict is a
terminal read of the pure evaluator, distinct from the looping recipe's gate. It
reuses ONLY `verification.aggregate` — the same pure primitive
`iteration.resolve_gate_verification` folds through, but reached HERE independently
(pattern reuse, not a call into iteration).

KTD-4: the ratified criteria are baked onto a TOP-LEVEL ``one_shot_verification``
key at synthesis time (a compile-time write — no preconditioned steering mutator,
no lost-update concern). They are read back with a PLAIN dict access, NOT via
`iteration.read_dc`: `one_shot_verification` is not a declared
`ledger_core.DISPATCH_CONTEXT_KEYS` member, so `read_dc` would raise `KeyError` on
it. Keeping the criteria off `dispatch_context` (and off `read_dc`) is what makes
the one-shot path independent of the iteration accessor surface.
"""

from __future__ import annotations

import os
import sys

# Standard bootstrap: prepend lib/ so sibling loads route through _bootstrap
# (the harness loads this file by path via spec_from_file_location, which does
# NOT add lib/ to sys.path). Mirrors lib/contents.py.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

# The synthesized unit's fixed id. A one-shot run has exactly one unit; a stable
# legible id keeps the ledger record + any observability legible.
_ONE_SHOT_UNIT_ID = "one-shot"

# The top-level key the ratified criteria are baked under (KTD-4). Deliberately
# NOT a dispatch_context key — read directly, never via read_dc.
ONE_SHOT_VERIFICATION_KEY = "one_shot_verification"


class OneShotIncomplete(Exception):
    """Raised by ``oneshot_verdict`` when the aggregate still reports
    ``pending_judges`` — the skill (KTD-3) is contracted to resolve EVERY
    ratified criterion inline BEFORE asking for a verdict, so a pending judge at
    verdict time is a caller error, NOT a silent pass. Distinct exception type so
    the caller can tell "incomplete resolution" apart from a real fail verdict."""


def synthesize_oneshot_unit(content: dict, ratified_criteria) -> dict:
    """Turn a loaded ``content`` + the ``ratified_criteria`` into ONE work-phase
    ledger unit (U2). Pure — builds and returns a fresh dict, mutating nothing.

    The unit:
      - is a single work-phase unit (``phase == "work"``, no dependencies);
      - carries the content's ``invokes`` (``adapter_op`` + optional
        ``prompt_template``) on ``dispatch_context`` — the home
        ``orchestrator._unit_adapter_op`` reads first (``_normalize_unit`` drops
        the raw ``invokes`` bag but preserves ``dispatch_context`` verbatim);
      - bakes ``ratified_criteria`` onto a TOP-LEVEL ``one_shot_verification`` key
        (KTD-4 — readable with a plain dict access, never via ``read_dc``), and
        ONLY when there are criteria: absent → no key at all, so the unit carries
        NO empty-gate default;
      - has NO ``iteration`` block and NO ``phase_transitions`` (KTD-3 — the
        one-shot is single-pass; it never enters the tick loop).

    ``content`` is expected to be a validated content dict (see
    ``lib/contents.py::validate_content``); ``ratified_criteria`` is a list of
    typed verification criteria (possibly empty or None).
    """
    invokes = content.get("invokes") or {}
    dispatch_context = {"adapter_op": invokes.get("adapter_op")}
    # Carry the tuning template ONLY when the content declares one — a template-less
    # content must synthesize a template-less unit (regression-safe launch, U5).
    if "prompt_template" in invokes:
        dispatch_context["prompt_template"] = invokes["prompt_template"]

    unit = {
        "id": _ONE_SHOT_UNIT_ID,
        "state": "pending",
        "phase": "work",
        "depends_on": [],
        "dispatch_context": dispatch_context,
    }

    # Bake criteria only when present — mirrors _normalize_unit's CONDITIONAL
    # `verification` preserve: an unconditional [] would stamp an empty-gate
    # default onto every one-shot unit (the thing the plan says NOT to do).
    if ratified_criteria:
        unit[ONE_SHOT_VERIFICATION_KEY] = list(ratified_criteria)

    return unit


def _read_baked_criteria(unit: dict) -> list:
    """Read the ratified criteria baked onto ``unit`` at synthesis (KTD-4).

    A PLAIN top-level dict read — NOT ``iteration.read_dc`` (which would ``KeyError``
    on a key outside ``DISPATCH_CONTEXT_KEYS``). Absent key → no criteria.
    """
    return unit.get(ONE_SHOT_VERIFICATION_KEY) or []


def oneshot_verdict(unit: dict, programmatic_results: dict, judge_verdicts: dict) -> dict:
    """Terminal one-shot verdict (U4 / KTD-1). READ-ONLY over the criteria.

    Reads the ratified criteria baked on ``unit`` (KTD-4), folds them plus the
    supplied resolved results into a single ``verification.aggregate`` call, and
    maps the aggregator's advance/iterate SIGNAL to a terminal ``pass``/``fail``:
    all resolved criteria pass → ``pass``; any resolved fail → ``fail``. (A run
    with no criteria aggregates to advance → ``pass`` — a vacuous pass, same fold
    the evaluator applies to an empty gate.)

    ``programmatic_results`` / ``judge_verdicts`` are ``{criterion_id: "pass"|"fail"}``
    maps the CALLER resolved inline (KTD-3): programmatic in-process, model_judge
    from the dispatched agent, advisor_judge/human by the skill's blocking
    resolution. Because the skill resolves every type before asking, there should
    be no ``pending_judges`` here — if there are, that is a caller error and we
    raise ``OneShotIncomplete`` rather than silently passing.

    Returns ``{"verdict": "pass"|"fail", "signal": <raw aggregate signal>,
    "criteria_count": int}``. Does NOT mutate ``unit`` and NEVER writes a
    ``decision`` field (KTD-1 boundary — this is verdict reporting, not an
    iteration-decision commit).
    """
    criteria = _read_baked_criteria(unit)
    # Reuse ONLY the pure aggregator (KTD-1). Lazy-load mirrors the
    # iteration.resolve_gate_verification pattern; iteration itself is NEVER
    # imported here (the KTD-1 boundary, enforced by import-topology).
    verification = load_lib_module("verification")
    agg = verification.aggregate(criteria, programmatic_results or {}, judge_verdicts or {})

    pending = agg.get("pending_judges") or []
    if pending:
        raise OneShotIncomplete(
            "oneshot_verdict: criteria still pending resolution "
            f"{pending!r} — the one-shot skill must resolve every ratified "
            "criterion inline before requesting a verdict (KTD-3); a pending "
            "judge at verdict time is a caller error, not a pass."
        )

    signal = agg.get("signal")
    # Re-label the loop's advance/iterate signal as a terminal pass/fail — do NOT
    # leak "iterate" semantics into the one-shot verdict (KTD-1).
    verdict = "pass" if signal == "advance" else "fail"
    return {
        "verdict": verdict,
        "signal": signal,
        "criteria_count": len(criteria),
    }
