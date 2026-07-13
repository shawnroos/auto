#!/usr/bin/env python3
"""auto U9 (v0.6.0): the pure upstream-cluster classifier.

Given a review verdict's findings + their reviewer-role/lens metadata, decide
whether they CLUSTER on a single UPSTREAM phase — i.e. the flaw is inherited
from an earlier creative-spine stage (brainstorm/plan) rather than being a
local issue in the current phase. The engine (lib/pulse_advance.py) calls this
during a spine run and, on a positive detection, ESCALATES the cluster to the
operator via the existing pause handoff (driver=manual + blocked_on). No backward
loop_phase move, no new persisted field, no rebound machinery — that autonomous
backward edge is deferred to v0.7.0 (KTD-6). v0.6.0 ships the detection half.

THE WEIGHTING (KTD-6 — `feedback_a1_recipe_cant_rebound_to_brainstorm`):
REVIEWER-ROLE DIVERSITY is weighted ABOVE raw finding count. Three findings
from three DISTINCT roles (adversarial + feasibility + security) all attributing
to the SAME upstream phase is a far stronger signal than N findings from ONE
role on local issues — independent lenses converging on the same root cause is
what makes an upstream flaw credible. So the trigger is "≥ MIN_DISTINCT_ROLES
distinct reviewer roles attribute to ONE upstream phase", NOT a count threshold.
The "many same-role local findings" negative case falls out for free: one role
contributes distinct-role-count == 1 to any phase, below the threshold.

WHERE THE METADATA LIVES (the `decision` / `winner_step_id` precedent —
lib/iteration.py, lib/ledger_mutators.set_winner_step_id): `record_verdict`
NORMALIZES findings to ``{severity, note}`` only (lib/ledger_mutators.py:150),
so any reviewer-role / target-phase tag on a finding is STRIPPED on the
canonical write path. Role-tagged findings therefore survive on the step's
``dispatch_context`` (preserved by ``transition`` / the verdict-write path with
no normalize step), exactly as the iteration ``decision`` does. This classifier
reads a list of finding-records of the shape::

    {"role": <reviewer-role str>, "phase": <attributed-phase str>, ...}

The PRODUCER that tags review findings with role + attributed-phase (a review-op
enrichment writing them onto ``dispatch_context``) is OUT OF SCOPE for U9 — U9
is the detector + the escalation wiring, not the enrichment. Until a producer
populates these tags the classifier simply returns "no cluster" (degrade-safe).

PURE + STDLIB-ONLY (import-topology / pure-leaf discipline): this module imports
NO lib siblings — it takes the current phase + phase order as ARGS (never reads
``ledger["loop_phase"]``, which would trip the phase-grammar AST lint) and never
writes the ledger. That makes it a trivially-testable leaf and adds only the one
edge ``pulse_advance → upstream_cluster`` to the import DAG.

DEGRADE-SAFE (never crash a ledger write path): every accessor tolerates a
malformed/partial finding record (non-dict entries, missing/blank role or phase,
a non-list ``findings`` arg, a non-list ``phase_order``). On ANY malformed shape
the classifier collapses to the safe default — ``detected=False`` — so a torn
verdict can never raise out of the work-loop and get mis-recorded as a stall.

Loaded via ``_bootstrap.load_lib_module("upstream-cluster")`` (hyphenated file
name per repo convention; the registered module name is ``upstream_cluster``).
"""

from __future__ import annotations

# The role-diversity trigger: how many DISTINCT reviewer roles must attribute to
# the SAME upstream phase before we call it a cluster. Three is the KTD-6 figure
# (adversarial + feasibility + security converging). Below this, a same-role pile
# of findings — however large — does NOT trigger: count alone is not the signal.
MIN_DISTINCT_ROLES = 3


def _norm_str(value):
    """Return a stripped non-empty str, or None for any other shape.

    Tolerates ints/None/whitespace — a malformed tag degrades to "absent"
    rather than raising. Used for both the role and the attributed phase so a
    torn finding record can never crash the classifier.
    """
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def upstream_phases(current_phase, ordered_phases):
    """The phases STRICTLY UPSTREAM of ``current_phase`` in ``ordered_phases``.

    "Upstream" = earlier in the creative spine (brainstorm is upstream of plan,
    which is upstream of work). Returns the prefix of ``ordered_phases`` before
    ``current_phase``. Degrade-safe: a non-list order, a missing/blank current
    phase, or a current phase not present in the order all yield an EMPTY set
    (no phase can be upstream → no cluster can form).

    ``current_phase`` + ``ordered_phases`` are passed IN by the caller (which
    reads them via ``phase_grammar.current_phase`` / ``phase_grammar.phase_order``)
    so this module never touches the ``loop_phase`` literal itself.
    """
    cur = _norm_str(current_phase)
    if cur is None or not isinstance(ordered_phases, (list, tuple)):
        return set()
    order = [_norm_str(p) for p in ordered_phases]
    try:
        idx = order.index(cur)
    except ValueError:
        return set()
    return {p for p in order[:idx] if p is not None}


def _roles_by_phase(findings, allowed_phases):
    """Map each allowed (upstream) phase -> the set of DISTINCT roles attributing
    to it. Skips any malformed finding record, any finding whose attributed phase
    is blank / not in ``allowed_phases``, and any finding with a blank role.

    DIVERSITY, NOT COUNT (KTD-6): we collect roles into a SET per phase, so ten
    findings from one role contribute a single role to that phase's set. The set
    size IS the diversity signal the trigger reads.
    """
    by_phase = {}
    if not isinstance(findings, (list, tuple)):
        return by_phase
    for f in findings:
        if not isinstance(f, dict):
            continue
        phase = _norm_str(f.get("phase"))
        if phase is None or phase not in allowed_phases:
            continue
        role = _norm_str(f.get("role"))
        if role is None:
            continue
        by_phase.setdefault(phase, set()).add(role)
    return by_phase


def classify(findings, current_phase, ordered_phases, *, min_distinct_roles=MIN_DISTINCT_ROLES):
    """Classify whether ``findings`` cluster on a single upstream phase.

    Returns a dict, ALWAYS the same five keys (so the caller can branch without
    a presence check):

        detected:        bool — True iff a single upstream phase reaches the
                         role-diversity threshold.
        target_phase:    str | None — the upstream phase the cluster attributes
                         to (None when not detected).
        distinct_roles:  sorted list[str] — the distinct roles converging on
                         ``target_phase`` (empty when not detected).
        finding_count:   int — how many findings attribute to ``target_phase``
                         (0 when not detected) — surfaced for the operator
                         message, NOT used as the trigger.
        reason:          str — a short human-readable why (for the escalation
                         message / diagnostics).

    THE TRIGGER (role diversity over raw count): a cluster is detected iff some
    upstream phase has ``>= min_distinct_roles`` DISTINCT roles attributing to
    it. When more than one upstream phase qualifies (rare), we pick the one with
    the MOST distinct roles, tie-broken by the EARLIEST phase in ``ordered_phases``
    (the deepest root cause). Many same-role findings on local/current-phase
    issues never qualify: a single role is diversity == 1 < threshold, and
    current-phase / downstream findings are excluded from ``allowed_phases``.

    DEGRADE-SAFE: any malformed input collapses to ``detected=False`` via the
    helpers above; this function itself raises nothing.
    """
    allowed = upstream_phases(current_phase, ordered_phases)
    if not allowed:
        return _result(False, None, set(), 0, "no upstream phases in this run")

    by_phase = _roles_by_phase(findings, allowed)
    if not by_phase:
        return _result(False, None, set(), 0, "no role-tagged upstream findings")

    # Phase-order index for the earliest-phase tiebreak. allowed ⊆ ordered_phases,
    # so every key resolves; the .index lookup is safe.
    order = [_norm_str(p) for p in ordered_phases]

    def _rank(phase):
        # Sort key: (-#roles, phase-order-index). Most diverse first; on a tie,
        # the earliest (deepest-upstream) phase wins.
        try:
            order_idx = order.index(phase)
        except ValueError:
            order_idx = len(order)
        return (-len(by_phase[phase]), order_idx)

    target = sorted(by_phase, key=_rank)[0]
    roles = by_phase[target]
    if len(roles) < int(min_distinct_roles):
        return _result(
            False, None, set(), 0,
            f"strongest upstream phase {target!r} has only {len(roles)} "
            f"distinct reviewer role(s); need {int(min_distinct_roles)}",
        )

    count = _count_for_phase(findings, target)
    return _result(
        True, target, roles, count,
        f"{len(roles)} distinct reviewer roles ({', '.join(sorted(roles))}) "
        f"converge on upstream phase {target!r}",
    )


def _count_for_phase(findings, target_phase):
    """How many findings attribute to ``target_phase`` (degrade-safe count)."""
    if not isinstance(findings, (list, tuple)):
        return 0
    n = 0
    for f in findings:
        if isinstance(f, dict) and _norm_str(f.get("phase")) == target_phase:
            n += 1
    return n


def _result(detected, target_phase, roles, finding_count, reason):
    """Build the canonical five-key result dict (roles -> sorted list)."""
    return {
        "detected": bool(detected),
        "target_phase": target_phase,
        "distinct_roles": sorted(roles),
        "finding_count": int(finding_count),
        "reason": reason,
    }


def escalation_message(result):
    """A one-line operator message for the pause handoff's ``blocked_on`` field.

    Names the upstream phase + the converging findings so the operator can see
    WHY the run halted without opening the ledger. Returns None when the result
    is not a detection (the caller should only escalate on ``detected``).
    """
    if not isinstance(result, dict) or not result.get("detected"):
        return None
    target = result.get("target_phase")
    roles = result.get("distinct_roles") or []
    count = int(result.get("finding_count", 0) or 0)
    return (
        f"upstream-cluster: {count} review finding(s) across "
        f"{len(roles)} reviewer role(s) ({', '.join(roles)}) cluster on the "
        f"upstream {target!r} phase. The flaw looks inherited from {target!r}, "
        f"not local to the current phase. Operator: revisit the {target!r} "
        f"artifact, then `/auto-resume abort <run>` and re-enter fresh — "
        f"autonomous rebound lands in v0.7.0. NOTE: `/auto-resume continue <run>` "
        f"will re-detect this same cluster and re-pause (the upstream flaw is "
        f"unchanged), so it does NOT get past the cluster on its own."
    )
