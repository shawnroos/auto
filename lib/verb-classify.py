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
#             plan-then-work (workflow a1).
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
import string

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

# Closed class of function-word `'s` contractions ("let's ship" = "let us ship").
# A possessive `'s` attaches to a NOUN; these attach to pronouns/adverbs/"let" and
# are followed by a VERB, so they must NOT read as a noun-marking determiner.
_CONTRACTIONS = {"let's", "here's", "there's", "that's", "what's", "it's",
                 "he's", "she's", "who's", "where's", "when's", "how's",
                 "why's", "let’s", "here’s", "there’s", "that’s", "what’s",
                 "it’s", "he’s", "she’s", "who’s", "where’s", "when’s",
                 "how’s", "why’s"}


def _has_any(text, patterns):
    return any(re.search(r"\b" + p + r"\b", text) for p in patterns)


def _preceded_by_determiner(text, start):
    """True iff the token immediately before position `start` is an article or
    possessive — i.e. the word at `start` is a NOUN object, not a verb.

    Punctuation is stripped from the preceding token first, so "(the plan)" and
    "review the plan." resolve correctly; a possessive ("team's plan") is noun
    context too. This is what lets "execute the plan" read as work (execute is a
    verb; "plan" is the article-preceded noun) while "plan and implement" reads
    as plan-creation (leading "plan" is a verb)."""
    before = text[:start].split()
    if not before:
        return False
    prev = before[-1].strip(string.punctuation + "’")
    if prev in _ARTICLES:
        return True
    if prev in _CONTRACTIONS:
        # "let's"/"here's"/… is "let us"/"here is" — the next word is a verb.
        return False
    # Possessive ("team's", "clients'") makes the following word a noun.
    return prev.endswith("'s") or prev.endswith("’s")


def _used_as_verb(text, pattern):
    """True iff `pattern` matches at least once NOT preceded by an article/
    possessive — used as a verb, not a noun object. Applied to work AND plan
    verbs so a topic noun ("design a review workflow", "plan a run-rate board")
    does not trip the collision word (`review`, `run`) as a work verb."""
    for m in re.finditer(r"\b" + pattern + r"\b", text):
        if not _preceded_by_determiner(text, m.start()):
            return True
    return False


def classify(args):
    """Return {"class": work|plan|both|ambiguous, "work","plan_intent"} for the
    args string. Case-insensitive; empty/whitespace → ambiguous."""
    text = (args or "").lower().strip()
    if not text:
        return {"class": "ambiguous", "work": False, "plan_intent": False}
    work = any(_used_as_verb(text, p) for p in _WORK)
    plan_verb = (any(_used_as_verb(text, p) for p in _PLAN)
                 or _used_as_verb(text, r"plan(?:ning)?"))
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
