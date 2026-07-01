#!/usr/bin/env python3
"""auto launch-chooser U2: the launch confidence ladder (PURE deterministic map).

Interactive `/auto` opens with a worked-out loop recommendation. The launch
agent (skills/auto-launch, U3) reasons about which loop shape fits and proposes
typed verification gates — that fuzzy judgment stays in the model. THIS module
is the crisp half: it maps the agent's two self-assessed confidences plus the
structural facts of its recommendation to ONE of `skip` / `confirm` / `two_step`.

This mirrors how lib/recommender.py already splits classification: the model
emits the floats, the code decides the tier. Keeping the load-bearing skip bar
here (not in skill prose) makes it deterministic, unit-testable, and
grep-checkable — `feedback_deterministic_over_probabilistic_v1`.

THE SKIP INPUTS ARE MODEL-SELF-ASSESSED — that is the safety risk. `classify_
launch` is pure and cannot verify `shape_confidence`, `gates_confidence`,
`recipe_kind`, or `gate_types`. LLM self-confidence is uncalibrated and biased
high, so the structural guards (builtin ∧ programmatic-or-no-typed-gates ∧ not
custom) are NECESSARY, NOT SUFFICIENT — they cannot catch a confidently-wrong
shape inside the builtin+programmatic envelope. So `skip` carries a fourth,
DETERMINISTIC precondition: `router_agrees` — the agent's recommended stem must
equal lib/recommender.py's deterministic pick for the classified state. The
caller (U3) precomputes that boolean and passes it in, so this function stays
IO-free.

What `router_agrees` DOES guarantee, deterministically: a shape the router
would never pick can never skip. recommender.py's output space is exactly
{a1, w}, so any `a2`/`a4`/custom recommendation fails the stem-equality check
and falls to the chooser — even if the agent mislabeled its gate as
`programmatic` and self-rated both confidences high (the one path the structural
guards alone could miss). That is its load-bearing job.

What it does NOT and CANNOT do: independently validate the a1-vs-a2 shape
*judgment*. Both operands of the check are model-derived — the recommended stem
AND the state label fed to the router (the caller classifies the state). An
agent that confidently MISJUDGES a2-shaped work as `a1` will self-consistently
label the state `clear-intent-no-plan`, the router returns `a1`, the stems
match, and the launch skips an a1 the operator might have wanted as a2. No
deterministic check can catch a fully self-consistent shape misjudgment; that
residual rests on SKIP_BAR plus the model's shape honesty, and is an accepted
v1 risk. So `router_agrees` is a hard gate against skipping the WRONG-KIND of
shape, not a proof that a1/w was the RIGHT call.

RULES (plan KTD-1), evaluated IN ORDER:
  1. recipe_kind == "custom"                        -> two_step  (R4; never skips)
  2. any gate type in {advisor_judge, human,
     model_judge}                                   -> never skip (may confirm)
  3. skip iff shape >= SKIP_BAR AND gates >= SKIP_BAR
     AND recipe_kind == "builtin" AND gate_types is
     a subset of {programmatic} (empty allowed) AND
     router_agrees                                  -> skip
  4. (not skip) AND builtin AND exactly one dim
     clears SKIP_BAR while the other clears
     CONFIRM_BAR                                    -> confirm
  5. otherwise                                      -> two_step (bias-to-show)

Size budget: this module stays well under the 1000-LOC file / 120-LOC function
lints. Loadable via `_bootstrap.load_lib_module("launch-gate")` or directly.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bootstrap import coerce_confidence

# The skip bar on BOTH dimensions. High and gating-aware: a wrong autonomous
# skip (a loop the operator didn't intend, never shown) costs more than one
# extra operator question, so the bar that lets the chooser be skipped is the
# load-bearing safety property against regressing to the dead-UI problem (R10).
# Same rationale style as recommender.py::CONFIDENCE_THRESHOLD.
SKIP_BAR = 0.85

# The single-confirm floor for the SETTLED dimension when the other dimension is
# fully confident (>= SKIP_BAR). Below this on the soft dimension, the launch
# falls through to the full two-step chooser. 0.70 keeps single-confirm to
# genuinely near-settled launches; anything shakier shows both steps.
CONFIRM_BAR = 0.70

# Tier outcomes (the function's return contract).
TIER_SKIP = "skip"
TIER_CONFIRM = "confirm"
TIER_TWO_STEP = "two_step"

# Recipe-kind facts. A built-in (a1/a2/a4/w) can skip or single-confirm; a
# composed custom loop is always drawn and confirmed (rule 1 / R4). An UNKNOWN
# kind degrades to "custom" — the safe direction (two_step), never skip.
KIND_BUILTIN = "builtin"
KIND_CUSTOM = "custom"

# The ONLY recipe stems a `skip` may land on. The ladder collapses skip to the
# two no-typed-gate built-ins — `a1` (plan-loop) and `w` (work-only); a2/a4 carry
# judge/compare gates (non-programmatic → blocked by rule 3 anyway), and the
# router's other picks (`pipeline` for a vague state, `review` for code-unreviewed)
# are never chooser-recommended shapes. `recommender.py --check-agrees` consults
# THIS set so a router pick outside it can never green-light a skip — skip-
# eligibility policy lives WITH the skip decision, not in the router (round-2
# adversarial: an agent classifying to `vague`/`code-unreviewed` and recommending
# `pipeline`/`review` must not obtain router_agrees=true and skip the chooser).
SKIP_ELIGIBLE_RECIPES = frozenset({"a1", "w"})

# Gate-type taxonomy (v0.7.0). Only `programmatic` is deterministic enough to be
# "obvious"; the judge/human types are non-deterministic (and `human` needs
# interaction), so any of them forbids a skip (rule 2). A sentinel stands in for
# a malformed gate-type entry so the subset check conservatively blocks skip.
GATE_PROGRAMMATIC = "programmatic"
JUDGE_OR_HUMAN_GATES = frozenset({"advisor_judge", "human", "model_judge"})
_UNKNOWN_GATE = "_unknown_"


def _normalize_gate_types(gate_types):
    """Return a list of gate-type strings; malformed input blocks skip safely.

    The launch agent emits `gate_types` as a list of criterion `type` strings.
    Anything that isn't a clean list of strings (None, a non-iterable, a
    non-string element) is coerced so the rule-3 subset check rejects it — a
    skip must never ride on a confidence the inputs can't substantiate. A bare
    string is split on commas (the CLI form), so `"programmatic"` and
    `"a,b"` both normalize sensibly.
    """
    if gate_types is None:
        return []
    if isinstance(gate_types, str):
        # Strip each token so a CSV with spaces ("programmatic, human") still
        # matches rule 2's blocking-gate set on the whitespace-trimmed name —
        # otherwise " human" would miss has_blocking_gate and only block skip via
        # the programmatic_only check (safe, but rule 2 should early-exit).
        return [tok.strip() for tok in gate_types.split(",") if tok.strip()]
    try:
        items = list(gate_types)
    except TypeError:
        return [_UNKNOWN_GATE]
    return [t if isinstance(t, str) else _UNKNOWN_GATE for t in items]


def classify_launch(shape_confidence, gates_confidence, recipe_kind,
                    gate_types, router_agrees):
    """Map two confidences + structural facts to skip / confirm / two_step.

    Pure: no IO, never raises on any input. Bad confidences coerce to 0.0
    (bias-to-show), an unknown `recipe_kind` is treated as custom (two_step),
    and malformed `gate_types` block skip. Rules are evaluated in KTD-1 order;
    the structural guard plus `router_agrees` is the skip safety property (R10).
    """
    # SAFETY (U6): coerce_confidence (shared in _bootstrap) clamps to [0.0, 1.0]
    # and maps bad/non-numeric/bool inputs to 0.0. Here the safe direction is LOW
    # confidence -> bias-to-show (two_step), NEVER an accidental skip — this is
    # the load-bearing skip-safety property; do not let a bad value read as high.
    shape = coerce_confidence(shape_confidence)
    gates = coerce_confidence(gates_confidence)
    kind = recipe_kind if recipe_kind in (KIND_BUILTIN, KIND_CUSTOM) else KIND_CUSTOM
    types = _normalize_gate_types(gate_types)
    # router_agrees is a precomputed boolean; only the literal True counts as
    # agreement. Anything else (None, a truthy non-bool, a parse miss) is
    # uncertain and conservatively blocks skip.
    agrees = router_agrees is True

    # Rule 1: a composed custom loop is always drawn and confirmed.
    if kind == KIND_CUSTOM:
        return TIER_TWO_STEP

    # Rule 2: a non-deterministic gate is by definition not "obvious" — never
    # skip (it may still single-confirm with a settled shape, handled below).
    has_blocking_gate = any(t in JUDGE_OR_HUMAN_GATES for t in types)

    # Rule 3: the skip envelope. gate_types must be a subset of {programmatic}
    # (empty allowed); both dims at/above SKIP_BAR; builtin; router agrees.
    programmatic_only = all(t == GATE_PROGRAMMATIC for t in types)
    both_high = shape >= SKIP_BAR and gates >= SKIP_BAR
    if (not has_blocking_gate and both_high and programmatic_only and agrees):
        return TIER_SKIP

    # Rule 4: single-confirm — exactly one dimension clears SKIP_BAR while the
    # other clears CONFIRM_BAR (i.e. one settled, the other near-settled).
    shape_high = shape >= SKIP_BAR
    gates_high = gates >= SKIP_BAR
    shape_mid = shape >= CONFIRM_BAR
    gates_mid = gates >= CONFIRM_BAR
    exactly_one_high = (
        (shape_high and gates_mid and not gates_high)
        or (gates_high and shape_mid and not shape_high)
    )
    if exactly_one_high:
        return TIER_CONFIRM

    # Rule 5: bias-to-show — any genuine uncertainty shows the full chooser.
    return TIER_TWO_STEP


def _cli(argv):
    """Tiny CLI mirroring recommender.py: one JSON line on stdout.

    Usage: launch-gate.py <shape> <gates> <recipe_kind> <gate_types_csv> <router_agrees>
      gate_types_csv : comma-separated criterion types; "" for an empty list.
      router_agrees  : true|1 -> True; anything else -> False.

    Lets a bash test read the tier deterministically. Bad numeric args coerce to
    a low confidence (via coerce_confidence in classify_launch), so the CLI
    never crashes on a malformed arg.
    """
    import json
    import sys

    def _num(s):
        try:
            return float(s)
        except (TypeError, ValueError):
            return -1.0  # forces low -> bias-to-show (coerced to 0.0).

    shape = _num(argv[0]) if len(argv) > 0 else -1.0
    gates = _num(argv[1]) if len(argv) > 1 else -1.0
    recipe_kind = argv[2] if len(argv) > 2 else KIND_CUSTOM
    gate_types = argv[3] if len(argv) > 3 else ""
    router_raw = argv[4].strip().lower() if len(argv) > 4 else ""
    router_agrees = router_raw in ("true", "1")

    tier = classify_launch(shape, gates, recipe_kind, gate_types, router_agrees)
    # Echo the NORMALIZED kind (the value classify_launch actually classified on),
    # so an unknown kind reads back as "custom" rather than the raw arg — a reader
    # of this line sees the kind that drove the tier, not the unvalidated input.
    recipe_kind_norm = recipe_kind if recipe_kind in (KIND_BUILTIN, KIND_CUSTOM) else KIND_CUSTOM
    json.dump({
        "tier": tier,
        # Echo the SAFETY-clamped confidences (shared coerce_confidence): a bad
        # arg reads back as 0.0 (low), never as a value that could green-light a skip.
        "shape_confidence": coerce_confidence(shape),
        "gates_confidence": coerce_confidence(gates),
        "recipe_kind": recipe_kind_norm,
        "gate_types": _normalize_gate_types(gate_types),
        "router_agrees": router_agrees,
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv[1:]))
