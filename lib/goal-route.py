#!/usr/bin/env python3
"""auto v0.11.0: goal-aware plan-routing DECISION (PURE deterministic mapping).

The goal-aware pre-step in the driver (skills/auto-driver) has two halves. The
FUZZY half — "does plan P advance goal G's named outcome?" — stays in the model
(rubric: skills/auto-driver/references/goal-plan-relevance-rubric.md). The CRISP
half — given those match verdicts + the goal authority + whether the run is
interactive, WHICH route fires and may it suppress the fan-out — is this module.

Same split as lib/recommender.py (`feedback_deterministic_over_probabilistic_v1`):
the model classifies, the code decides. Keeping the routing branches here — not in
skill prose — makes them deterministic, unit-testable, and grep-checkable, and it
ENFORCES the guardrails the adversarial review flagged: fan-out suppression is
refused unless the goal is `explicit` AND the run is interactive, so a self-driven
run can never silently bypass the always-ask confirm gate (R12), and an inferred
(guessed) goal can never suppress the fanout (R8). A wrong verdict from the model
only ever mis-orders a confirmable menu; it can never turn into an un-gated
auto-suppress, because this function will not emit one.

INPUT (one JSON object, argv[1] or stdin):
  {
    "authority":   "explicit" | "inferred" | "none",
    "matches":     ["<path>", ...],   # matched plans, model-ranked best-first
    "all_plans":   ["<path>", ...],   # the detector's full multi_plan.paths
    "interactive": true | false       # driving_session_id is null (interactive)
  }

OUTPUT (one JSON object on stdout):
  {
    "action":          "reshape" | "passthrough",
    "reason":          "explicit-suppress" | "inferred-re-rank"
                     | "no-match-unchanged" | "no-goal-unchanged"
                     | "self-driven-unchanged",
    "suppress_fanout": bool,          # true ONLY for explicit-suppress
    "preselect":       "<path>" | null,
    "ranked":          ["<path>", ...] | null   # ask ordering when reshaping
  }

DEGRADE-SAFE (rel-001): malformed input, an unknown authority, or matches that
aren't a list all resolve to `passthrough` (the SAFE default — the detector's
own verdict, fan-out offered per its rules). This function NEVER raises and NEVER
suppresses on bad input; exit is always 0 so it can't wedge the read-side driver.
"""

import json
import sys


_PASS_REASONS = {
    "none": "no-goal-unchanged",
}


def _passthrough(reason):
    return {
        "action": "passthrough",
        "reason": reason,
        "suppress_fanout": False,
        "preselect": None,
        "ranked": None,
    }


def route(payload):
    """Pure (payload dict) -> decision dict. Never raises."""
    if not isinstance(payload, dict):
        return _passthrough("no-goal-unchanged")

    authority = payload.get("authority")
    matches = payload.get("matches")
    all_plans = payload.get("all_plans")
    interactive = payload.get("interactive")

    # Guardrail R12: goal-aware routing is interactive-only. A self-driven /
    # headless run (interactive is not exactly True) can never surface the
    # confirm gate, so it must NEVER reshape — take the detector verdict as-is.
    if interactive is not True:
        return _passthrough("self-driven-unchanged")

    # No goal recovered → the detector's freshness verdict stands (R9).
    if authority not in ("explicit", "inferred"):
        return _passthrough("no-goal-unchanged")

    # Degrade: matches must be a non-empty list of paths.
    if not isinstance(matches, list) or not matches:
        return _passthrough("no-match-unchanged")

    top = matches[0]

    if authority == "explicit":
        # R6/R7: narrow — suppress the fan-out, ask over the matches only,
        # preselect the top, confirm even on a single match.
        return {
            "action": "reshape",
            "reason": "explicit-suppress",
            "suppress_fanout": True,
            "preselect": top,
            "ranked": list(matches),
        }

    # authority == "inferred" — R8: nudge only. Re-rank the FULL plan set with
    # matches on top, preselect the top match, but keep the fan-out offered.
    if isinstance(all_plans, list) and all_plans:
        tail = [p for p in all_plans if p not in matches]
        ranked = list(matches) + tail
    else:
        ranked = list(matches)
    return {
        "action": "reshape",
        "reason": "inferred-re-rank",
        "suppress_fanout": False,   # inferred NEVER suppresses (R8)
        "preselect": top,
        "ranked": ranked,
    }


def _load(argv):
    """Read the JSON payload from argv[1] if present, else stdin."""
    raw = argv[1] if len(argv) > 1 else sys.stdin.read()
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def _cli(argv):
    payload = _load(argv)
    if payload is None:
        # Unparseable input → safe passthrough, still exit 0.
        json.dump(_passthrough("no-goal-unchanged"), sys.stdout)
        sys.stdout.write("\n")
        return 0
    json.dump(route(payload), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))
