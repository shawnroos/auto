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

# The auto plugin root (lib/'s parent) — where the built-in `contents/` seeds and
# their `prompt_template` files ship. `build_oneshot_launch` resolves a content's
# relative prompt_template against this first (built-in), then the workspace repo.
_AUTO_ROOT = os.path.dirname(_LIB_DIR)

# `recipe_validate` is the pure-stdlib validation DAG root (imports no heavy
# sibling — same leaf discipline `contents.py` relies on). We reuse TWO primitives:
#   - `_validate_verification` — the SAME taxonomy-shape check a recipe's
#     `verification` block passes, so U3's ratify gate rejects a malformed
#     proposed criterion with the exact rules the engine enforces (KTD-2 reuse).
#   - `_check_prompt_template` — the SAME path-bounding a recipe's prompt_template
#     passes, re-applied defensively before U5 reads a template off disk.
# NOTE the KTD-1 boundary is unaffected: `iteration` is STILL never imported here
# (import-topology enforces it); `recipe_validate` is a different, gate-free leaf.
_recipe_validate = load_lib_module("recipe_validate")
_validate_verification = _recipe_validate._validate_verification
_check_prompt_template = _recipe_validate._check_prompt_template
RecipeError = _recipe_validate.RecipeError

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


def validate_oneshot_criteria(criteria) -> tuple:
    """Validate a RATIFIED one-shot criteria list against the verification
    taxonomy (U3 / R5). Returns ``(ok: bool, errors: list[str])`` — it COLLECTS
    rather than raises so the skill can surface the problem and re-ratify.

    This is the pre-dispatch gate: the criteria the operator accepted (possibly
    EDITED — AE2) are checked BEFORE they are baked into the one-shot unit
    (``synthesize_oneshot_unit``). It REUSES ``recipe_validate._validate_verification``
    (KTD-2 reuse discipline) — the SAME shape check the recipe validator applies
    at both write time and engine-load time — by wrapping the list in a synthetic
    unit. So a malformed proposed criterion (a `programmatic` with a shell string
    instead of an argv list, an unknown `type`, >16 criteria, a per-type unknown
    field) is rejected here with the exact same rules the engine would enforce.

    ``criteria`` may be ``None`` or ``[]`` — a one-shot with no criteria is a
    valid (vacuous-pass) run, so an empty/None list validates ``ok``.
    """
    # `_validate_verification` reads `u["id"]` + `u.get("verification")` and
    # RAISES RecipeError on the first violation. A synthetic unit adapts the
    # raise-on-first-error contract to the collect-and-return one this gate wants.
    synthetic_unit = {"id": _ONE_SHOT_UNIT_ID, "verification": criteria}
    try:
        _validate_verification(synthetic_unit)
    except RecipeError as e:
        return False, [str(e)]
    return True, []


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


def build_oneshot_launch(content: dict, repo: str) -> dict:
    """Build the launch descriptor for a one-shot content (U5 / KTD-5).

    DRIVER-SIDE ONLY. The one-shot is driver-orchestrated (KTD-3), so the load-
    bearing site for "a content's tuning reaches the dispatched agent" is the
    DRIVER launch, NOT an adapter edit — ``orchestrator.dispatch_batch`` never
    consults the adapter (driver-reference §7). This helper is what the
    ``auto-content`` skill calls to assemble that launch:

      - it always names the content's ``adapter_op``;
      - when the content declares a ``prompt_template``, it folds the template's
        BODY into the descriptor (``prompt_template`` = the path, ``prompt_template_body``
        = the file text) so the skill can splice the tuning into the sub-agent's
        prompt;
      - when the content declares NO ``prompt_template``, the descriptor is the
        plain op invocation — no template keys at all (regression-safe: a
        template-less content launches exactly as before).

    The relative ``prompt_template`` path is re-path-bounded (defensively — same
    ``_check_prompt_template`` the recipe/content validators use) and resolved
    against the auto plugin root first (where built-in seeds ship), then the
    workspace ``repo``. A declared-but-unreadable template FAILS CLOSED with a
    ``RecipeError`` rather than launching a half-tuned agent.

    Returns ``{"adapter_op": <op>[, "prompt_template": <path>,
    "prompt_template_body": <text>]}``. Pure w.r.t. ``content`` — mutates nothing.
    """
    invokes = content.get("invokes") or {}
    descriptor = {"adapter_op": invokes.get("adapter_op")}

    pt = invokes.get("prompt_template")
    if pt:
        # Re-bound defensively before touching the filesystem (the load path does
        # not run validate_content, so this helper cannot assume it was checked).
        _check_prompt_template(pt, "invokes")
        body = None
        for base in (_AUTO_ROOT, repo):
            candidate = os.path.join(base, pt)
            if os.path.isfile(candidate):
                try:
                    with open(candidate) as f:
                        body = f.read()
                except OSError as e:
                    raise RecipeError(
                        f"prompt_template {pt!r} at {candidate} could not be read: {e}"
                    ) from None
                break
        if body is None:
            raise RecipeError(
                f"prompt_template {pt!r} not found; searched: "
                + ", ".join(os.path.join(b, pt) for b in (_AUTO_ROOT, repo))
            )
        descriptor["prompt_template"] = pt
        descriptor["prompt_template_body"] = body

    return descriptor


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
