#!/usr/bin/env python3
"""auto v0.6.0 U2: the ce-family recommender (PURE deterministic mapping).

Bare `/auto` after a rich conversation routes through the `conversation-context`
situation (lib/auto-detect.sh, U1). The DRIVER (skills/auto-driver) reflects on
its own live transcript + a ~2-day ce-sessions lookback, classifies the session
into ONE state label, and asks THIS module which ce-family step to run.

This module is a PURE function of (state_label, confidence). It does NOT read the
transcript, the ledger, or the filesystem — the driver supplies the classified
state and a confidence score; the module returns the deterministic recommendation
tuple. Keeping the mapping here (not in skill prose) makes the routing taxonomy
deterministic, testable, and grep-checkable — `feedback_deterministic_over_
probabilistic_v1`. The fuzzy step (classify the conversation) stays in the model;
the crisp step (state -> recommendation) is code.

TAXONOMY (plan KTD-2; v0.6.0):

  state label            ce step        recipe_or_entry    entry      spine?  kind
  ---------------------- -------------- ------------------ ---------- ------- ------
  vague                  ce-brainstorm  pipeline           brainstorm spine   recipe
  clear-intent-no-plan   ce-plan        a1                 plan       spine   recipe
  reviewed-plan          work-only      w                  work       spine   recipe
  code-unreviewed        ce-code-review review (review.json) work       off     recipe
  bug                    ce-debug       /ce-debug          -          off     skill
  what-to-improve        ce-ideate      /ce-ideate         -          n/a     skill
  perf                   ce-optimize    /ce-optimize       -          off     skill

WHY vague dispatches the spine recipe `pipeline` (not a `/ce-brainstorm` skill
rec): the brainstorm-rooted spine (recipes/pipeline.json, U7/U8) ships in THIS
v0.6.0 diff alongside the recommender — Phase A (entry) and Phase B (forward
spine) land together. So vague routes to a real `pipeline` dispatch entering at
the `brainstorm` phase, and the run auto-advances brainstorm→plan→work (the
plan's headline success criterion: "A spine run auto-advances
brainstorm→plan→work" through the smart-entry route). `recipe_or_entry` is the
bare recipe STEM ("pipeline"), not the filename — auto.py resolves it via
`recipes.load_and_validate(name, repo)` → f"{name}.json" (same as a1/w/review).

WHY debug/optimize are SKILL recs (not recipes): the CE adapter exposes only
plan/deepen/review_plan/enumerate_plan_units/do_unit/review (lib/adapter-ce.py),
so a `debug.json`/`optimize.json` recipe would be a non-functional stub. Only
`review.json` (the `review` op exists) is a real off-spine recipe. debug/optimize
follow the `ce-ideate` precedent — recommend the skill, no auto-wrap.

CONFIDENCE / ESCALATE: confidence is an INPUT (the driver's own certainty in its
classification), not something this module computes. Below CONFIDENCE_THRESHOLD,
`escalate` is True regardless of state — the driver then escalates to the operator
BEFORE dispatch (U3) rather than acting on a shaky classification (R-5). An
UNKNOWN state ALSO escalates (the safe default) and never crashes.

Size budget (R-6): this module stays well under the 1000-LOC file / 120-LOC
function lints. Loaded via `_bootstrap.load_lib_module("recommender")`.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bootstrap import coerce_confidence

# Confidence at or above this is "confident enough to dispatch"; below it the
# driver escalates pre-dispatch (U3). A float in [0.0, 1.0]. 0.6 is deliberately
# conservative: the cost of a wrong autonomous dispatch (a run the operator
# didn't intend) is higher than the cost of one extra operator question, and the
# default-for-uncertainty is escalate (R-1 / R-5).
CONFIDENCE_THRESHOLD = 0.6

# The recommendation "kind" — how the driver consumes recipe_or_entry:
#   "recipe" -> dispatch via lib/auto.sh with `--recipe <recipe_or_entry>`,
#               entering at the named phase (the recipe's phase_order[0]).
#   "skill"  -> recommend the ce skill command (recipe_or_entry, e.g.
#               "/ce-brainstorm") — NO auto-wrap, no run created.
KIND_RECIPE = "recipe"
KIND_SKILL = "skill"

# The deterministic taxonomy. Each entry is the recommendation for a known state
# label. Confidence/escalate are layered on top by `recommend()` — these rows are
# the state-INTRINSIC shape (which step, which recipe/skill, on the spine or not).
#
# Field meanings:
# U6 (R9) — legible-alias choice: the taxonomy KEEPS the bare shorthand STEMS
# ("a1"/"w"/"pipeline"/"review") rather than emitting the legible aliases. This is
# the minimal change that makes BOTH forms route: aliasing lives in ONE place
# (lib/recipes.py::_ALIASES, consulted inside resolve() before the file lookup),
# so a stem passed here resolves directly and a legible name passed anywhere
# (e.g. an operator's `--recipe plan-build-review`) resolves to the same recipe.
# Emitting aliases here instead would force `launch-gate.SKIP_ELIGIBLE_RECIPES`
# and the `--check-agrees` stem-equality to switch to the alias form too, for no
# gain — the router's pick is compared as an opaque token either way.
#
#   ce_step         the ce-family step this state maps to (operator-facing label).
#   recipe_or_entry the recipe NAME (kind=recipe) or the skill COMMAND (kind=skill).
#   entry           the entry phase for a recipe dispatch (None for skill recs).
#   is_spine        True iff this is a creative-spine step (brainstorm->plan->work);
#                   off-spine / n/a states are False (KTD-2 — off-spine never
#                   returns a spine recipe or an auto-advance entry).
#   kind            KIND_RECIPE or KIND_SKILL (see above).
_TAXONOMY = {
    "vague": {
        # The brainstorm-rooted spine. `recipe_or_entry` is the BARE recipe STEM
        # ("pipeline"), NOT the filename — auto.py resolves it via
        # `recipes.load_and_validate(name, repo)` → f"{name}.json", so passing
        # "pipeline.json" would resolve to recipes/pipeline.json.json and fail.
        # The recipe's phase_order[0] IS the entry phase ("brainstorm"); the run
        # auto-advances brainstorm→plan→work via the U8 emitter (KTD-2/3).
        "ce_step": "ce-brainstorm",
        "recipe_or_entry": "pipeline",
        "entry": "brainstorm",
        "is_spine": True,
        "kind": KIND_RECIPE,
    },
    "clear-intent-no-plan": {
        "ce_step": "ce-plan",
        "recipe_or_entry": "a1",
        "entry": "plan",
        "is_spine": True,
        "kind": KIND_RECIPE,
    },
    "reviewed-plan": {
        "ce_step": "work-only",
        "recipe_or_entry": "w",
        "entry": "work",
        "is_spine": True,
        "kind": KIND_RECIPE,
    },
    "code-unreviewed": {
        # `recipe_or_entry` is the BARE recipe STEM, not the filename: auto.py
        # feeds it to `recipes.load_and_validate(name, repo)`, which resolves via
        # `os.path.join(<tier>, f"{name}.json")`. So the off-spine review recipe
        # (recipes/review.json, U11) is addressed as "review" — passing
        # "review.json" would resolve to recipes/review.json.json and fail. This
        # matches how every other row addresses its recipe by stem (a1, w).
        "ce_step": "ce-code-review",
        "recipe_or_entry": "review",
        "entry": "work",
        "is_spine": False,
        "kind": KIND_RECIPE,
    },
    "bug": {
        "ce_step": "ce-debug",
        "recipe_or_entry": "/ce-debug",
        "entry": None,
        "is_spine": False,
        "kind": KIND_SKILL,
    },
    "what-to-improve": {
        "ce_step": "ce-ideate",
        "recipe_or_entry": "/ce-ideate",
        "entry": None,
        "is_spine": False,
        "kind": KIND_SKILL,
    },
    "perf": {
        "ce_step": "ce-optimize",
        "recipe_or_entry": "/ce-optimize",
        "entry": None,
        "is_spine": False,
        "kind": KIND_SKILL,
    },
}

# The safe default for an UNKNOWN/ambiguous state: recommend nothing concrete,
# escalate. Never a recipe, never a spine entry — the driver asks the operator.
_UNKNOWN_RECOMMENDATION = {
    "ce_step": None,
    "recipe_or_entry": None,
    "entry": None,
    "is_spine": False,
    "kind": KIND_SKILL,
}


def known_states():
    """Return the set of state labels the taxonomy defines (for tests/callers)."""
    return frozenset(_TAXONOMY)


def recommend(state_label, confidence=1.0):
    """Map a classified state label + confidence to a recommendation dict.

    Returns a dict with keys:
      state, ce_step, recipe_or_entry, entry, is_spine, kind, confidence, escalate

    ``escalate`` is True iff confidence < CONFIDENCE_THRESHOLD OR the state is
    unknown — the driver consumes it as "do NOT dispatch; escalate to the
    operator pre-dispatch" (U3). Pure: no IO, no crash on any input (an unknown
    or non-string state degrades to the safe escalate default).
    """
    # coerce_confidence (shared in _bootstrap) clamps to [0.0, 1.0]; a bad or
    # non-numeric value degrades to the safe direction here: low confidence ->
    # escalate (never a wrong autonomous dispatch on an unparseable classification).
    conf = coerce_confidence(confidence)
    base = _TAXONOMY.get(state_label) if isinstance(state_label, str) else None
    if base is None:
        # Unknown / ambiguous / non-string state -> safe default: escalate.
        rec = dict(_UNKNOWN_RECOMMENDATION)
        rec.update({"state": "unknown", "confidence": conf, "escalate": True})
        return rec
    rec = dict(base)
    rec.update({
        "state": state_label,
        "confidence": conf,
        # Low confidence escalates even for a known state (R-5 — never a wrong
        # autonomous dispatch on a shaky classification).
        "escalate": conf < CONFIDENCE_THRESHOLD,
    })
    return rec


def _cli(argv):
    """Tiny CLI: `recommender.py <state> [confidence]` -> one JSON line.

    Lets a bash test (or the driver, if it ever wants the mapping from a shell)
    read the recommendation deterministically. Confidence parse failure -> 0.0
    via coerce_confidence (so the CLI never crashes on a bad arg either).

    Sub-mode `recommender.py --check-agrees <state> <stem>` -> prints `true` /
    `false` and nothing else. This is the deterministic `router_agrees` primitive
    the launch chooser (skills/auto-launch §4) calls: it folds "classify, run the
    router, compare stems" into ONE shell step so the agent can't substitute its
    own judgment for the cross-check. It is `true` IFF the router's deterministic
    pick for <state> equals <stem> exactly. An unknown/blank state yields a
    `recipe_or_entry` of None, which never string-equals a real stem -> `false`
    (the conservative direction: an unverifiable agreement blocks skip).
    """
    import json
    import sys
    if argv and argv[0] == "--check-agrees":
        # --check-agrees <state> <stem>
        state = argv[1] if len(argv) > 1 else None
        stem = argv[2] if len(argv) > 2 else ""
        pick = recommend(state).get("recipe_or_entry")
        # Agreement gates a SKIP, so the pick must ALSO be skip-eligible: the
        # router legitimately returns non-skip stems (`pipeline` for a vague
        # state, `review` for code-unreviewed), and those must never green-light a
        # skip. The eligible set is single-sourced from launch-gate (the skip
        # decision), never hardcoded here — router policy stays separate from
        # skip policy (round-2 adversarial).
        import os
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from _bootstrap import load_lib_module
        eligible = load_lib_module("launch-gate").SKIP_ELIGIBLE_RECIPES
        agree = pick is not None and pick == stem and pick in eligible
        sys.stdout.write("true\n" if agree else "false\n")
        return 0
    state = argv[0] if argv else None
    confidence = 1.0
    if len(argv) > 1:
        try:
            confidence = float(argv[1])
        except (TypeError, ValueError):
            confidence = -1.0  # forces low -> escalate (coerced to 0.0).
    json.dump(recommend(state, confidence), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv[1:]))
