#!/usr/bin/env python3
"""auto one-shot preset helpers (addressable-step-contents).

THIN, pure/testable pieces the `auto-preset` skill calls to run a preset
one-shot (KTD-3 — the skill is the dispatcher; this module holds no control
flow, no tick, no `/goal`):

  1. ``validate_oneshot_criteria(criteria)`` (U3) — validate a RATIFIED criteria
     list against the verification taxonomy BEFORE dispatch, reusing the recipe
     validator's shape check (KTD-2 reuse).

  2. ``build_oneshot_launch(preset, repo)`` (U5) — build the driver-side launch
     descriptor: the preset's `adapter_op`, plus the `prompt_template` body when
     the preset declares one (KTD-5 — the tuning is folded at the DRIVER launch,
     never via a backend edit).

  3. ``oneshot_verdict(ratified_criteria, programmatic_results, judge_verdicts)``
     (U4) — the TERMINAL verdict: fold the ratified criteria + resolved results
     into a single ``verification.aggregate`` call and re-label the aggregator's
     advance/iterate SIGNAL as a terminal ``pass``/``fail`` (KTD-1). It takes the
     ratified criteria list DIRECTLY (there is no synthesized unit) and is
     READ-ONLY over them: it reports a verdict, it does NOT commit an iteration
     decision.

KTD-1 BOUNDARY (defended in review + import-topology): this module MUST NOT import
`lib/iteration.py` (the iteration-decision-commit module) and MUST NOT write a
`decision` field anywhere. The one-shot verdict is a terminal read of the pure
evaluator, distinct from the looping recipe's gate. It reuses ONLY
`verification.aggregate` — the same pure primitive
`iteration.resolve_gate_verification` folds through, but reached HERE independently
(pattern reuse, not a call into iteration). `verification` is a stdlib-safe leaf
loaded at import; the KTD-1 boundary is about `iteration`, not `verification`.
"""

from __future__ import annotations

import os
import sys

# Standard bootstrap: prepend lib/ so sibling loads route through _bootstrap
# (the harness loads this file by path via spec_from_file_location, which does
# NOT add lib/ to sys.path). Mirrors lib/presets.py.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

# The auto plugin root (lib/'s parent) — where the built-in `presets/` seeds and
# their `prompt_template` files ship. `build_oneshot_launch` resolves a preset's
# relative prompt_template against the workspace repo first, then this built-in root.
_AUTO_ROOT = os.path.dirname(_LIB_DIR)

# `recipe_validate` is the pure-stdlib validation DAG root (imports no heavy
# sibling — same leaf discipline `presets.py` relies on). We reuse TWO primitives:
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

# The pure verification evaluator — a stdlib-safe leaf (subprocess + typing only).
# `oneshot_verdict` reuses ONLY `verification.aggregate` (KTD-1); `iteration` is
# still never imported (the boundary is about iteration, not verification).
_verification = load_lib_module("verification")


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
    EDITED — AE2) are checked BEFORE the op is launched. It REUSES
    ``recipe_validate._validate_verification`` (KTD-2 reuse discipline) — the SAME
    shape check the recipe validator applies at both write time and engine-load
    time — by wrapping the list in a synthetic unit. So a malformed proposed
    criterion (a `programmatic` with a shell string instead of an argv list, an
    unknown `type`, >16 criteria, a per-type unknown field) is rejected here with
    the exact same rules the engine would enforce.

    ``criteria`` may be ``None`` or ``[]`` — a one-shot with no criteria is a
    valid (vacuous-pass) run, so an empty/None list validates ``ok``.
    """
    # `_validate_verification` reads `u["id"]` + `u.get("verification")` and
    # RAISES RecipeError on the first violation. A synthetic unit adapts the
    # raise-on-first-error contract to the collect-and-return one this gate wants.
    synthetic_unit = {"id": "one-shot", "verification": criteria}
    try:
        _validate_verification(synthetic_unit)
    except RecipeError as e:
        return False, [str(e)]
    return True, []


def build_oneshot_launch(preset: dict, repo: str) -> dict:
    """Build the launch descriptor for a one-shot preset (U5 / KTD-5).

    DRIVER-SIDE ONLY. The one-shot is driver-orchestrated (KTD-3), so the load-
    bearing site for "a preset's tuning reaches the dispatched agent" is the
    DRIVER launch, NOT a backend edit — ``dispatcher.dispatch_batch`` never
    consults the backend (driver-reference §7). This helper is what the
    ``auto-preset`` skill calls to assemble that launch:

      - it always names the preset's ``adapter_op``;
      - when the preset declares a ``prompt_template``, it folds the template's
        BODY into the descriptor (``prompt_template`` = the path, ``prompt_template_body``
        = the file text) so the skill can splice the tuning into the sub-agent's
        prompt;
      - when the preset declares NO ``prompt_template``, the descriptor is the
        plain op invocation — no template keys at all (regression-safe: a
        template-less preset launches exactly as before).

    ``preset`` is a VALIDATED preset dict (see ``lib/presets.py::validate_preset``
    / ``load_and_validate_preset``), so ``invokes`` and ``invokes.adapter_op`` are
    accessed directly — the validator guarantees them.

    The relative ``prompt_template`` path is re-path-bounded (defensively — same
    ``_check_prompt_template`` the recipe/preset validators use) and resolved
    against the workspace ``repo`` first (a workspace override wins, matching
    ``load_preset``'s tier order), then the auto plugin root (where built-in seeds
    ship). A declared-but-unreadable template FAILS CLOSED with a ``RecipeError``
    rather than launching a half-tuned agent.

    Returns ``{"adapter_op": <op>[, "prompt_template": <path>,
    "prompt_template_body": <text>]}``. Pure w.r.t. ``preset`` — mutates nothing.
    """
    invokes = preset["invokes"]
    descriptor = {"adapter_op": invokes["adapter_op"]}  # format-v1 keys; flip in U6

    pt = invokes.get("prompt_template")
    if pt:
        # Re-bound defensively before touching the filesystem (the load path does
        # not run validate_preset, so this helper cannot assume it was checked).
        _check_prompt_template(pt, "invokes")
        body = None
        for base in (repo, _AUTO_ROOT):
            candidate = os.path.join(base, pt)
            # Open directly (one syscall, no TOCTOU): a miss falls through to the
            # next base; a present-but-unreadable file is a hard error.
            try:
                with open(candidate, encoding="utf-8") as f:
                    body = f.read()
                break
            except FileNotFoundError:
                continue
            except (OSError, UnicodeError) as e:
                # Unreadable OR not valid UTF-8 — a present-but-bad template is a
                # hard error, not a silent fall-through to the next base.
                raise RecipeError(
                    f"prompt_template {pt!r} at {candidate} could not be read: {e}"
                ) from None
        if body is None:
            raise RecipeError(
                f"prompt_template {pt!r} not found; searched: "
                + ", ".join(os.path.join(b, pt) for b in (repo, _AUTO_ROOT))
            )
        descriptor["prompt_template"] = pt
        descriptor["prompt_template_body"] = body

    return descriptor


def oneshot_verdict(ratified_criteria, programmatic_results: dict, judge_verdicts: dict) -> dict:
    """Terminal one-shot verdict (U4 / KTD-1). READ-ONLY over the criteria.

    Takes the RATIFIED criteria list directly (a list, possibly empty or ``None``),
    folds them plus the supplied resolved results into a single
    ``verification.aggregate`` call, and maps the aggregator's advance/iterate
    SIGNAL to a terminal ``pass``/``fail``: all resolved criteria pass → ``pass``;
    any resolved fail → ``fail``. A run with NO ratified criteria verified nothing,
    so it is reported as ``unverified`` — never ``pass``. A gating verdict that
    greens with nothing checked is a silent pass, so an empty check is honestly
    labelled rather than folded (with the evaluator's empty-gate ``advance``) into
    a green.

    ``programmatic_results`` / ``judge_verdicts`` are ``{criterion_id: "pass"|"fail"}``
    maps the CALLER resolved inline (KTD-3): programmatic in-process, model_judge
    from the dispatched agent, advisor_judge/human by the skill's blocking
    resolution. Because the skill resolves every type before asking, there should
    be no ``pending_judges`` here — if there are, that is a caller error and we
    raise ``OneShotIncomplete`` rather than silently passing.

    Returns ``{"verdict": "pass"|"fail"|"unverified", "aggregate_signal": <raw
    aggregate signal, diagnostic>, "criteria_count": int}``. NEVER writes a
    ``decision`` field (KTD-1 boundary — this is verdict reporting, not an
    iteration-decision commit).
    """
    criteria = ratified_criteria or []
    # Reuse ONLY the pure aggregator (KTD-1); iteration itself is NEVER imported
    # here (the KTD-1 boundary, enforced by import-topology).
    agg = _verification.aggregate(criteria, programmatic_results or {}, judge_verdicts or {})

    pending = agg.get("pending_judges") or []
    if pending:
        raise OneShotIncomplete(
            "oneshot_verdict: criteria still pending resolution "
            f"{pending!r} — the one-shot skill must resolve every ratified "
            "criterion inline before requesting a verdict (KTD-3); a pending "
            "judge at verdict time is a caller error, not a pass."
        )

    signal = agg.get("signal")
    # An empty ratified-criteria list verified nothing: report "unverified", never
    # "pass". aggregate([], ...) folds to advance (empty-gate) — mapping that to a
    # green would be a silent pass in a gating mechanism (review finding).
    if not criteria:
        verdict = "unverified"
    else:
        # Re-label the loop's advance/iterate signal as a terminal pass/fail — do
        # NOT leak "iterate" semantics into the one-shot verdict (KTD-1).
        verdict = "pass" if signal == "advance" else "fail"
    return {
        "verdict": verdict,
        "aggregate_signal": signal,
        "criteria_count": len(criteria),
    }


# ── op-dispatch CLI (exercised by tests/unit/preset-cli.test.sh) ─────────────
def _cli(argv) -> int:
    import json

    if not argv:
        sys.stderr.write("usage: preset_oneshot.py <op> ...\n")
        return 2
    op = argv[0]
    if op == "validate-criteria":
        # argv[1] = ratified criteria JSON
        if len(argv) != 2:
            sys.stderr.write("usage: preset_oneshot.py validate-criteria <criteria-json>\n")
            return 2
        ok, errs = validate_oneshot_criteria(json.loads(argv[1]))
        print("OK" if ok else "INVALID: " + "; ".join(errs))
        return 0
    if op == "launch":
        # argv[1] = preset name, argv[2] = repo. Loads + validates the preset
        # (fail closed) before folding its tuning into the launch descriptor.
        if len(argv) != 3:
            sys.stderr.write("usage: preset_oneshot.py launch <name> <repo>\n")
            return 2
        presets = load_lib_module("presets")
        # A shape-valid preset can still declare a real-but-missing/unreadable
        # template that only build_oneshot_launch touches — surface either as the
        # operator-facing INVALID line, never a bare traceback.
        try:
            preset = presets.load_and_validate_preset(argv[1], argv[2])
            print(json.dumps(build_oneshot_launch(preset, argv[2])))
        except (presets.PresetError, RecipeError) as e:
            print("INVALID: " + str(e))
        return 0
    if op == "verdict":
        # argv[1]=criteria JSON, argv[2]=programmatic_results JSON, argv[3]=judge_verdicts JSON
        if len(argv) != 4:
            sys.stderr.write(
                "usage: preset_oneshot.py verdict <criteria-json> <prog-json> <judges-json>\n"
            )
            return 2
        print(json.dumps(oneshot_verdict(json.loads(argv[1]), json.loads(argv[2]), json.loads(argv[3]))))
        return 0
    sys.stderr.write(f"preset_oneshot.py: unknown op {op!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
