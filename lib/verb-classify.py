#!/usr/bin/env python3
# auto v0.7.x U4: deterministic verb classification of a freeform args string.
#
# The auto-driver's pre-v0.7.x argument rule was: if $ARGUMENTS is non-empty and
# does NOT resolve to a plan file, run `/ce-plan <ARGUMENTS>`. It had no notion of
# VERBS, so an imperative about EXISTING work ("execute, review and verify the
# plan, then open a PR") was re-planned instead of executed — the 2026-06 field
# misroute (it bit twice). This classifier is the missing signal.
#
# It answers one question deterministically: does the args string express WORK
# intent, PLAN-creation intent, BOTH, or neither?
#   * work  — carries a work verb (execute/implement/verify/…/open a PR) and no
#             plan-creation intent → route to WORK on the existing plan.
#   * plan  — carries plan-creation intent (plan/design/…, or a creation verb +
#             the noun "plan") and no work verb → route to /ce-plan.
#   * both  — carries BOTH ("develop and implement a plan", "plan and ship X") →
#             plan-then-work (recipe a1).
#   * ambiguous — neither (bare topics, improvement verbs, greetings) → the
#             auto-driver (the model) decides; its safe default stays /ce-plan.
#
# Deterministic-over-probabilistic (the load-bearing mandate): this is a keyword
# taxonomy — the DETERMINISTIC half — mirroring lib/recommender.py. The fuzzy
# residual (`ambiguous`, and work-with-no-plan-to-run) is handed to the model in
# the auto-driver skill, never guessed here. Stdlib-only, no IO, CLI-testable.
#
# The one subtlety: "plan" is both a verb ("plan a feature" → create) and a noun
# ("execute the plan" → an existing artifact). "plan" counts as a plan VERB only
# when it is NOT immediately preceded by an article/possessive — so "execute the
# plan" reads as work, while "plan and implement" reads as plan-creation.

import re
import sys
import json

# Verbs that unambiguously mean "carry out existing work". Kept deliberately
# tight — genuinely dual-use verbs ("build", "develop") are NOT here; they only
# contribute via the creation-verb + "plan" noun rule below.
_WORK = [
    r"execute", r"run", r"implement", r"ship", r"verif(?:y|ies)", r"review",
    r"finish", r"land", r"complete", r"fix(?:es)?", r"deploy", r"merge",
    r"code-review", r"open (?:a|the) pr\b", r"open (?:a|the) pull request",
]
# Verbs that unambiguously mean "create a plan / decide what to build".
_PLAN = [r"design", r"brainstorm", r"architect", r"figure out",
         r"think through", r"scope out"]
# Verbs that mean "produce something" — plan-creation intent ONLY when paired
# with the noun "plan" (so "develop a plan" is plan-creation, "make it faster"
# is not).
_CREATION = [r"develop", r"create", r"draft", r"write", r"produce",
             r"come up with", r"put together"]

_ARTICLES = {"the", "a", "an", "this", "that", "existing", "my", "our",
             "your", "their", "its", "current"}


def _has_any(text, patterns):
    return any(re.search(r"\b" + p + r"\b", text) for p in patterns)


def _has_plan_verb(text):
    """True iff 'plan'/'planning' is used as a VERB (not preceded by an article/
    possessive — 'the plan' is a noun reference to an existing artifact)."""
    for m in re.finditer(r"\bplan(?:ning)?\b", text):
        before = text[:m.start()].split()
        prev = before[-1] if before else ""
        if prev not in _ARTICLES:
            return True
    return False


def classify(args):
    """Return {"class": work|plan|both|ambiguous, "work","plan_intent"} for the
    args string. Case-insensitive; empty/whitespace → ambiguous."""
    text = (args or "").lower().strip()
    if not text:
        return {"class": "ambiguous", "work": False, "plan_intent": False}
    work = _has_any(text, _WORK)
    plan_verb = _has_any(text, _PLAN) or _has_plan_verb(text)
    plan_noun = bool(re.search(r"\bplans?\b", text))
    plan_intent = plan_verb or (_has_any(text, _CREATION) and plan_noun)
    if work and plan_intent:
        cls = "both"
    elif work:
        cls = "work"
    elif plan_intent:
        cls = "plan"
    else:
        cls = "ambiguous"
    return {"class": cls, "work": work, "plan_intent": plan_intent}


def _cli(argv):
    """`verb-classify.py "<args string>"` → one JSON line. Test/driver surface."""
    args = argv[1] if len(argv) > 1 else ""
    json.dump(classify(args), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))
