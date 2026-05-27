#!/usr/bin/env python3
"""auto ledger: persistence, transitions, concurrency.

Canonical implementation of docs/contracts/ledger-schema.md. That document
is the authoritative spec; this module implements it. If they ever disagree,
the contract wins and this file is the bug.

Design notes (the load-bearing correctness rules):

  * I-1 (atomic predicate freshness) is enforced STRUCTURALLY: there is exactly
    ONE serialization chokepoint, ``_atomic_write``, which ALWAYS recomputes
    ``exit_predicate_result`` (including ``all_units_terminal``) immediately
    before writing. No public mutator bypasses it. Therefore every writer that
    routes a mutation through this module inherits freshness for free — that is
    what "generalized to ALL writers" means for U10's callers.

  * The flock spans the WHOLE read-modify-write, not just the rename. Holding
    only across the rename would permit a lost update. ``_with_locked_ledger``
    is the only RMW primitive; every mutator goes through it. Lock ACQUISITION
    itself lives in one place — ``_flock_run`` — which both ``_with_locked_ledger``
    and ``init_ledger`` route through. (``init_ledger`` is a create, not an RMW:
    it must succeed only when the ledger is ABSENT, the inverse of the RMW
    primitive's read-existing-first shape, so it shares the lock but not the body.)

  * Atomic write = mkstemp + os.fchmod(0o600) + os.rename, mirroring
    claude-modes/scripts/on-session-start.sh:162-175.

  * Locking via fcntl.flock (NOT flock(1) — macOS lacks it), mirroring
    claude-modes/lib/cascade-engine.sh::with_flock_run.

  * Python pinned /usr/bin/python3 via CLAUDE_AUTO_PYTHON3 (the .sh shim
    pins the interpreter; this file documents the contract).

  * slugify_branch is VENDORED here (``_slugify_branch``) — not cross-imported
    from claude-modes — to avoid cross-plugin coupling. Logic parity with
    claude-modes/lib/validate-mode-name.sh:104-136.
"""

from __future__ import annotations

import datetime
import fcntl
import json
import os
import re
import sys
import tempfile
from typing import Callable

# ──────────────────────────────────────────────────────────────────────────
# Module constants (importable; consumers MUST read these, not hardcode copies).

GRACE_SECONDS = 4200  # I-3: > 3600s ScheduleWakeup clamp ceiling + slack.
DEFAULT_STALL_THRESHOLD_SECONDS = 600  # per-unit stall timeout default.
# Bug #9: a `driver=="self"` chain whose last beat is older than THIS is treated
# as a DEAD chain by the Stop hook (it no longer blocks stop). It sits ABOVE the
# 3600s ScheduleWakeup max-tick-delay + slack (so a healthy slow chain is never
# false-flagged as dead and prematurely un-blocked) yet BELOW GRACE_SECONDS (so a
# dead chain stops blocking stop BEFORE is_orphaned would surface it for resume —
# the two purposes are reconciled by this ordering: 600 stall < 3900 stop-stale <
# 4200 orphan-grace). See on-stop.py's module docstring.
DRIVER_SELF_STALE_SECONDS = 3900

LOOP_PHASES = ("plan", "seam", "work", "done")
# Valid non-null plan_step values (the plan-phase sub-state — schema §3.1). The
# adapter reads plan_step to compute the NEXT step; the tick persists the step it
# ran. `null` (no step yet) is ALSO valid and is the initial value.
PLAN_STEPS = ("plan", "deepen", "review_plan")
UNIT_STATES = (
    "pending",
    "dispatched",
    "verdict-returned",
    "fixed",
    "stalled",
    "terminal-skip",
)
SEVERITIES = ("blocker", "major", "minor")
GATING_SEVERITIES = ("blocker", "major")  # severities that block terminality/done.

# State grammar (§3 of the contract). A unit may move ONLY along these edges.
ALLOWED_TRANSITIONS = {
    "pending": {"dispatched"},
    "dispatched": {"verdict-returned", "stalled"},
    "verdict-returned": {"fixed", "pending"},
    "fixed": {"pending"},
    "stalled": {"pending", "terminal-skip"},
    "terminal-skip": set(),  # terminal sink.
}

# ──────────────────────────────────────────────────────────────────────────
# Test-hatch fence (task #31).
#
# Five test-only hatches live in this module: FORCE_THREETIER_GATING,
# NO_RECOMPUTE, NO_LOCK, NO_ATTEMPT_CHECK, NO_STALLED_RECOVERY. Each is named
# CLAUDE_AUTO_TEST_* and documented test-only, but a stray production export
# would silently disable a guard. The fence requires the test harness to ALSO
# export CLAUDE_AUTO_TEST_HARNESS=1 (sentinel set by tests/run.sh) — a
# production user who exports a specific hatch by accident won't have the
# sentinel too, so the hatch stays inert. Local helper (not imported from
# _bootstrap) to avoid a circular import: _bootstrap.load_ledger() loads
# THIS module, so ledger.py importing _bootstrap would be a cycle. Same
# semantic as _bootstrap.test_hatch_enabled; the duplication is one-line and
# deliberate — composes with feedback_deterministic_over_probabilistic_v1
# (mechanism is grep-checkable across both files).


def _test_hatch_enabled(hatch_var: str) -> bool:
    return (
        os.environ.get("CLAUDE_AUTO_TEST_HARNESS") == "1"
        and os.environ.get(hatch_var) == "1"
    )


# ──────────────────────────────────────────────────────────────────────────
# Lazy-load helper (F3 / kieran-1 — dedup of 4 copy-paste sites).
#
# ledger.py defers loading sibling lib/ modules (iteration, phase-grammar) into
# function bodies because ledger.py is imported from many sites, some before
# sys.path is set up for sibling lib modules. The four prior sites each
# repeated a 6-line bootstrap (sys.path prepend + `from _bootstrap import
# load_lib_module`). That repetition is exactly the copy-paste the
# ``_bootstrap.load_lib_module`` helper was meant to kill — but ledger.py
# cannot import _bootstrap at module top because _bootstrap.load_ledger()
# loads THIS module, creating a cycle. The dedup is one local helper that
# does the deferred load — still no top-level import, but ONE function body
# instead of four.


def _lazy_load(name: str):
    """Load a sibling lib/ module from within a function body.

    Mirrors the sys.path-prepend + `_bootstrap.load_lib_module` idiom that the
    four prior call sites each open-coded (RIP `_compute_iteration_pending`,
    `is_orphaned`, `set_verdict_decision`, `set_bound_override`). Keeping the
    load deferred — rather than promoting to a module-top import — preserves
    the load-order discipline ledger.py needs (it is imported from many sites,
    some before sys.path is set up for sibling lib modules). The dedup is
    purely about killing the per-site boilerplate.

    Cannot live in ``_bootstrap`` itself because ``_bootstrap.load_ledger()``
    loads THIS module — importing ``_bootstrap`` at ledger.py module top would
    be a cycle. The local-helper shape mirrors ``_test_hatch_enabled``'s same
    cycle-avoidance pattern.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    from _bootstrap import load_lib_module
    return load_lib_module(name)


# ──────────────────────────────────────────────────────────────────────────
# Errors.


class LedgerError(Exception):
    """Base class for ledger errors."""


class LedgerNotFound(LedgerError):
    """Raised when a ledger for the given run-id does not exist."""


class LedgerExists(LedgerError):
    """Raised when init would clobber an existing ledger."""


class InvalidTransition(LedgerError):
    """Raised when a state transition is not in the grammar."""


class StaleVerdict(LedgerError):
    """Raised when ``record_verdict`` carries an ``attempt`` older than the unit's
    current ``attempt`` (Bug #6 — a verdict from a SUPERSEDED dispatch attempt).

    Distinct from ``InvalidTransition`` so a caller can tell "rejected because the
    verdict is stale" (a slow agent from a retried-past attempt) apart from
    "rejected because the grammar forbids it". The ledger is NOT written.
    """


class UnknownUnit(LedgerError):
    """Raised when a unit id is not present in the ledger."""


# Sentinel for "argument not supplied" where ``None`` is itself a valid value
# (e.g. ``set_loop(plan_step=...)`` — ``null`` is a legitimate stored plan_step,
# so we cannot use ``None`` to mean "leave unchanged").
_UNSET = object()


# ──────────────────────────────────────────────────────────────────────────
# Slugify (vendored — parity with claude-modes/lib/validate-mode-name.sh:104-136).


def _slugify_branch(branch: str) -> str:
    """Render an arbitrary run-id / branch name as a filesystem-safe slug.

    Characters outside [A-Za-z0-9_-] -> '-'; runs of '-' collapse; leading and
    trailing '-' stripped. Rejects empty, '.', '..', and any '..'-containing
    result (path-traversal guard). Raises ValueError on rejection.
    """
    if branch is None or branch == "":
        raise ValueError("slugify: empty branch/run-id")
    # Byte-oriented replacement (LC_ALL=C tr -c parity): anything not in the
    # allowed class becomes '-'.
    slug = re.sub(r"[^A-Za-z0-9_-]", "-", branch)
    slug = re.sub(r"-+", "-", slug)  # collapse runs.
    slug = slug.strip("-")  # strip leading/trailing.
    if not slug or slug in (".", "..") or ".." in slug:
        raise ValueError(f"slugify: rejected slug for run-id {branch!r}")
    return slug


# ──────────────────────────────────────────────────────────────────────────
# Paths.


def _dispatch_dir(repo_root: str) -> str:
    return os.path.join(repo_root, ".claude", "auto")


def ledger_path(repo_root: str, run_id: str) -> str:
    """Absolute path to the ledger JSON for ``run_id`` (slugified)."""
    return os.path.join(_dispatch_dir(repo_root), f"{_slugify_branch(run_id)}.json")


def lock_path(repo_root: str, run_id: str) -> str:
    """Absolute path to the flock file for ``run_id`` (slugified)."""
    return os.path.join(_dispatch_dir(repo_root), f"{_slugify_branch(run_id)}.lock")


# ──────────────────────────────────────────────────────────────────────────
# Time helpers.


def _now_iso() -> str:
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def _parse_iso(value):
    if not value:
        return None
    try:
        # Accept the trailing 'Z' (UTC) we always emit.
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (ValueError, TypeError):
        return None


# ──────────────────────────────────────────────────────────────────────────
# Pure predicate logic (I-2 / §4).


def gating_severities(scale: str = "three-tier") -> tuple:
    """The SINGLE source of truth for which severities GATE the loop, scale-aware.

    This is the one place that maps ``adapter_scale`` -> the gating-severity tuple.
    EVERY consumer that asks "does this finding block terminality / done /
    dependency-satisfaction?" MUST route through here rather than hardcoding
    ``GATING_SEVERITIES`` or a ``("blocker", "major")`` literal — that hardcoding
    was the Bug #3 livelock class (a ``blocker-only`` run with a major finding
    would gate forever at six different call sites). Centralizing the decision
    means a new caller cannot reintroduce the bug at a seventh site: there is
    nothing to copy.

      * ``"three-tier"`` (CE; the default for any missing / unknown value) — both
        ``blocker`` and ``major`` gate.
      * ``"blocker-only"`` (native) — only ``blocker`` gates; majors are advisory
        (surfaced at exit, never blocking). Unknown -> three-tier is the safe
        default (gates more, never under-blocks).

    The corresponding ``ledger`` field is ``adapter_scale``; read it once per call
    site (e.g. ``ledger.get("adapter_scale", "three-tier")``) and pass it in.

    Test-only deliberate-fail hatch ``CLAUDE_AUTO_TEST_FORCE_THREETIER_GATING``:
    when set to ``"1"`` this helper IGNORES ``scale`` and always returns the
    hardcoded three-tier ``GATING_SEVERITIES``. That simulates a regression where a
    call site bypasses the scale-aware decision (the Bug #3 class). The class-1
    blocker-only test runs the same scenario with this hatch set and asserts the
    run LIVELOCKS — proving the helper, not a hardcoded copy, is what unblocks the
    run. Because EVERY gating consumer routes through this one function, the single
    hatch reverts ALL sites at once, so the test proves the CLASS is closed (no
    site bypasses scale), not merely one instance.
    """
    if _test_hatch_enabled("CLAUDE_AUTO_TEST_FORCE_THREETIER_GATING"):
        return GATING_SEVERITIES
    return ("blocker",) if scale == "blocker-only" else GATING_SEVERITIES


def unit_is_terminal(unit: dict, scale: str = "three-tier") -> bool:
    """terminal(u) per §4.1 of the contract.

    A unit is terminal iff it is ``terminal-skip``, OR it is ``verdict-returned``
    / ``fixed`` AND carries no open *gating* finding. A ``fixed`` unit with a stale
    gating finding is NOT terminal (the findings-closure livelock guard).

    SCALE-AWARE (Bug #3): which severities gate is decided by the SINGLE helper
    ``gating_severities(scale)`` (the one source of truth). Under ``"three-tier"``
    (CE / default) both ``blocker`` and ``major`` gate; under ``"blocker-only"``
    (native) only ``blocker`` gates — majors are advisory (surfaced at exit, never
    blocking terminality), matching the work-loop ``met`` predicate so the two
    cannot disagree about done-ness.
    """
    gating = gating_severities(scale)
    state = unit.get("state")
    if state == "terminal-skip":
        return True
    if state in ("verdict-returned", "fixed"):
        for finding in unit.get("findings") or []:
            if finding.get("severity") in gating:
                return False
        return True
    return False


def recompute_predicate(ledger: dict) -> dict:
    """Compute ``exit_predicate_result`` purely from the ledger's current state.

    Counts findings across all units, computes ``all_units_terminal``, and sets
    ``met`` PHASE-AWARELY (I-2, contract §5):

      * ``loop_phase == "plan"`` — plan-loop exit is ``gaps_open == 0 AND
        plan_step == "review_plan"`` (adapter-contract §5 + schema §3.1). There
        are no work units yet, so ``all_units_terminal`` is NOT a requirement in
        the plan phase. The ``plan_step == "review_plan"`` conjunct mirrors the
        adapter coherence guard one-to-one: a DEFAULT ``gaps_open == 0`` BEFORE
        any review has run (at ``plan`` / ``deepen`` / ``null``) must NOT
        short-circuit the loop to met (schema §3.1) — only a completed
        ``review_plan`` whose gap-set is empty closes the plan loop.
      * otherwise (``"work"`` / ``"seam"`` / ``"done"``) — the work-loop exit,
        SCALE-AWARE on ``adapter_scale`` (§2.2 ``met`` row):
          - ``"three-tier"`` (CE; the default for any missing/unknown value):
            ``blockers == 0 AND majors == 0 AND all_units_terminal AND units``.
          - ``"blocker-only"`` (native): majors are advisory (surfaced at exit,
            not gating), so ``blockers == 0 AND all_units_terminal AND units``.
        The ``units`` (non-empty) conjunct closes the vacuous-exit hole: a work
        phase with ZERO dispatched units must NOT declare done (``all([]) ==
        True`` would otherwise short-circuit it before any fan-out). A *plan*
        phase with no units is fine — it never reaches this branch.

    v0.3.0 (U2 / KTD §B): the returned dict gains an ``iteration_pending: bool``
    field, and the new met rule is ``met = (existing met conditions) AND NOT
    iteration_pending``. ``iteration_pending`` is True iff the run declares an
    ``iteration`` block AND the gate unit's verdict.decision is ``"iterate"``
    AND the bound is unbreached (``iteration_attempts < max_attempts`` AND
    ``active_wall_seconds < max_wall_seconds``). Without the AND-NOT clause, a
    recipe that emits new plan-N units while ``loop_phase == "work"`` would see
    work-met fire spuriously (the work-loop branch above scopes terminality to
    current-phase units; pending plan-N units are phase=plan, invisible) — see
    KTD §A. The gate-decision read routes through ``iteration.read_decision`` to
    keep ledger.py off the AST-lint's allowlist for that semantic — the lint
    permits the literal here (writer site) but the convention is to consume via
    the centralized reader (mirrors how ``is_orphaned`` reads ``loop_phase`` via
    ``phase_grammar.current_phase`` rather than raw subscript).

    Returns the new dict (does NOT mutate ``ledger``; the caller assigns it).
    """
    blockers = majors = minors = 0
    for unit in ledger.get("units", []):
        for finding in unit.get("findings") or []:
            sev = finding.get("severity")
            if sev == "blocker":
                blockers += 1
            elif sev == "major":
                majors += 1
            elif sev == "minor":
                minors += 1

    # gaps_open is adapter-supplied; preserve any existing value (the engine
    # never invents it). It is genuinely NULLABLE (Bug #5): `null`/unknown means
    # "no real review has reported its gap count yet" and is DISTINCT from `0`
    # ("a review ran and found zero gaps"). Only `set_gaps_open` (driven by a real
    # review_plan return) ever writes a non-null value. We do NOT coerce to 0 here
    # — that coercion was the bug: a freshly-PREPARED-but-unfilled review envelope
    # left gaps_open at the default and plan-met fired after one un-reviewed pass.
    prev = ledger.get("exit_predicate_result") or {}
    gaps_open = prev.get("gaps_open")
    if gaps_open is not None:
        gaps_open = int(gaps_open)

    scale = ledger.get("adapter_scale", "three-tier")
    # v0.2.0 fix-pass A.1 (correctness P0 #3 / api-contract AC-2): the work-loop
    # exit predicate's terminal check is scoped to the units in the CURRENT phase,
    # not the global unit set. Pre-v0.2.0 (units=[] in the plan phase, the seam
    # synthesized work units), the global all() was equivalent. v0.2.0 declares
    # plan units explicitly in the recipe (a1's "plan", a2's "plan-1/2/3"); those
    # plan units stay `pending` after plan-done is reached (the plan-loop's
    # advance is recorded in plan_step, not via a unit state transition). A global
    # all_units_terminal would block work-met forever. Scoping by phase makes each
    # phase have its own terminality. terminal_phase from the recipe gates which
    # phase's units count for run-exit (AC-2 — the doc promised this but the code
    # didn't honor it). Global all_units_terminal is retained for the
    # exit_predicate_result reporting field (downstream consumers may want it).
    current_phase = ledger.get("loop_phase") or "plan"
    terminal_phase = ledger.get("terminal_phase") or "work"
    all_units_terminal_global = all(
        unit_is_terminal(u, scale) for u in ledger.get("units", [])
    )
    current_phase_units = [
        u for u in ledger.get("units", []) if u.get("phase") == current_phase
    ]

    if current_phase == "plan":
        # Plan-loop exit: a REAL review reported zero gaps AND a review_plan
        # actually ran (§3.1). Bug #5: gaps_open must be NON-NULL — a null/unknown
        # gap count means no review has filled it yet, so plan-met cannot fire. The
        # live CE/native adapters return a PREPARE envelope WITHOUT a gap_set (the
        # model fills gaps out-of-band), so set_gaps_open is not called and
        # gaps_open stays null; without the `is not None` guard a default 0 would
        # short-circuit plan-met after a SINGLE un-reviewed pass and the deepen-
        # refinement loop would be unreachable. The plan_step conjunct is kept
        # belt-and-braces; the load-bearing new conjunct is `gaps_open is not None`.
        met = (
            gaps_open is not None
            and gaps_open == 0
            and ledger.get("plan_step") == "review_plan"
        )
    else:
        # Work-loop exit, SCALE-AWARE (Bug #3 — adapter_scale was stored but never
        # read). The native adapter declares adapter_scale="blocker-only": its
        # majors are advisory (surfaced at exit) and do NOT gate the loop, so a
        # native run with majors>0 / blockers==0 must still be able to exit.
        # CE (or any missing/unknown value) defaults to the three-tier gate where
        # majors DO gate. Unknown → three-tier is the safe default (gates more,
        # never under-blocks). I-2: all_units_terminal stays required either way.
        # `scale` is read once above and also drives unit_is_terminal so the
        # terminality check and the met predicate agree on whether majors gate.
        # Whether majors gate is decided by the SINGLE helper (the one source of
        # truth) — never a hardcoded scale comparison here.
        no_majors = "major" not in gating_severities(scale) or majors == 0
        # Bug #4 — vacuous work-phase exit. all([]) is vacuously True, so a
        # phase flip with ZERO units dispatched would declare met before the
        # orchestrator fans out work. The phase-scoped check
        # (all_terminal_in_eval_phase + has_units_in_phase) addresses both this AND
        # the v0.2.0 fix-pass A.1 (plan units in declared recipes shouldn't gate
        # the work-loop's terminal check).
        # AC-2 fix: `met` requires loop_phase == terminal_phase (the run doesn't
        # exit until the terminal phase is reached AND its own units are terminal).
        # Post-terminal: "done" is the exit sentinel set BY a met-triggered tick
        # (the LAST member of LOOP_PHASES, never a member of any recipe's
        # phase_order). At "done", phase-scoped units would be empty (no unit
        # declares phase=done), so we'd vacuously flip met→false on the recompute
        # that fires when set_loop writes "done". Treat "done" as
        # terminal-equivalent for predicate purposes: the run already exited at
        # terminal_phase; "done" preserves that state. Any FUTURE post-terminal
        # sentinel (aborted/error/…) added to LOOP_PHASES would need the same
        # treatment here; today "done" is the only post-terminal value.
        # For v0.2.0's recipes terminal_phase is always "work"; v0.2.1's A3 will
        # have non-work terminal phases and this gate becomes load-bearing.
        eval_phase = terminal_phase if current_phase == "done" else current_phase
        eval_phase_units = (
            current_phase_units
            if current_phase != "done"
            else [u for u in ledger.get("units", []) if u.get("phase") == terminal_phase]
        )
        all_terminal_in_eval_phase = all(
            unit_is_terminal(u, scale) for u in eval_phase_units
        )
        has_units_in_phase = bool(eval_phase_units)
        met = (
            eval_phase == terminal_phase
            and blockers == 0
            and no_majors
            and all_terminal_in_eval_phase
            and has_units_in_phase
        )

    # v0.3.0 KTD §B — iteration_pending composition. Compute BEFORE finalizing
    # `met` so the AND-NOT clause can suppress a work-loop met that would
    # otherwise short-circuit the iteration loop (see KTD §A: the tick's
    # predicate-met short-circuit yields when iteration_pending is True).
    iteration_pending = _compute_iteration_pending(ledger)
    met = bool(met) and not iteration_pending

    return {
        "met": bool(met),
        "blockers": blockers,
        "majors": majors,
        "minors": minors,
        "gaps_open": gaps_open,
        "all_units_terminal": bool(all_units_terminal_global),
        "iteration_pending": iteration_pending,
    }


def _compute_iteration_pending(ledger: dict) -> bool:
    """Compute KTD §B's iteration_pending bool for ``recompute_predicate``.

    Thin delegating wrapper over ``iteration.compute_pending_state`` — the
    bound-check logic itself lives in ``lib/iteration.py`` (the ONE
    iteration-decision module per the AST lint). This file keeps the wrapper
    purely so ``recompute_predicate`` has a single in-file callable and the
    lazy-load idiom stays localized.

    Previously this function open-coded the bound check, byte-equivalent to
    ``iteration.evaluate_decision``'s lines 130-152. That was the NEXT
    dimension of the recurring "one rule lives in two places" class — the AST
    lint catches the literal ``"decision"`` but not duplicated bound math
    (close a dimension, not a sibling). Centralizing the math in
    ``iteration.compute_pending_state`` closes that dimension.

    Brittleness contract (rel-2): ``compute_pending_state`` swallows
    coercion errors on the numeric bound fields and returns ``False`` on
    bad input — a corrupted ``iteration_attempts`` MUST NOT raise from
    ``_atomic_write`` and lock every subsequent ledger write, including the
    one needed to recover.
    """
    iteration = _lazy_load("iteration")
    return iteration.compute_pending_state(ledger)


def is_orphaned(ledger: dict, now=None) -> bool:
    """I-3 orphan predicate (§5), excluding seam-paused surfacing (U7's concern).

    Resumable iff current phase != "done" AND (driver == "manual" OR last_beat_at
    older than GRACE_SECONDS).

    P2-10: routes the current-phase read through ``phase_grammar.current_phase``
    for consistency with the rest of the codebase (the AST lint allows the raw
    literal in ledger.py, but the convention is to read the field through the
    one phase-decision module). Lazy import to avoid module-load ordering
    surprises (ledger.py is loaded from many sites, sometimes before sys.path
    is set up for sibling modules).
    """
    # Lazy load: phase-grammar.py is a sibling lib module; loading it at
    # module import time would create a load-order dependency, so we defer.
    phase_grammar = _lazy_load("phase-grammar")

    if phase_grammar.current_phase(ledger) == "done":
        return False
    loop = ledger.get("loop") or {}
    if loop.get("driver") == "manual":
        return True
    last_beat = _parse_iso(loop.get("last_beat_at"))
    if last_beat is None:
        # No beat ever recorded on a non-done run => treat as resumable.
        return True
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    age = (now - last_beat).total_seconds()
    return age > GRACE_SECONDS


# ──────────────────────────────────────────────────────────────────────────
# Atomic write — the I-1 chokepoint. EVERY write goes through here.


def _atomic_write(path: str, ledger: dict) -> None:
    """Recompute the predicate, then atomically persist the ledger.

    This is the ONLY serialization path. It ALWAYS recomputes
    ``exit_predicate_result`` immediately before writing (I-1), unless the
    test-only ``CLAUDE_AUTO_TEST_NO_RECOMPUTE`` hatch is set (which exists
    purely to prove the I-1 test goes RED without the recompute).

    Atomic = mkstemp + fchmod(0o600) + os.rename. A crash mid-write leaves the
    prior file intact and a stray tmp (no half-written ledger).
    """
    if not _test_hatch_enabled("CLAUDE_AUTO_TEST_NO_RECOMPUTE"):
        ledger["exit_predicate_result"] = recompute_predicate(ledger)

    target_dir = os.path.dirname(path) or "."
    os.makedirs(target_dir, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ledger.", suffix=".json", dir=target_dir)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(ledger, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.rename(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _read_json(path: str) -> dict:
    with open(path, "r") as fh:
        return json.load(fh)


def _flock_run(lpath: str, body):
    """Hold the per-run exclusive flock for the duration of ``body()`` and return
    its result. The SINGLE lock-acquisition primitive — both the RMW path
    (``_with_locked_ledger``) and the create path (``init_ledger``) route their
    flock through here so the flock boilerplate (ensure-lockfile-exists, acquire,
    release-in-finally) lives in exactly one place.

    The test-only ``CLAUDE_AUTO_TEST_NO_LOCK`` hatch skips ONLY the flock
    acquisition (``body`` still runs) so the concurrency test can prove a lost
    update without serialization.
    """
    os.makedirs(os.path.dirname(lpath) or ".", mode=0o700, exist_ok=True)
    no_lock = _test_hatch_enabled("CLAUDE_AUTO_TEST_NO_LOCK")

    # Ensure the lock file exists (0600).
    if not os.path.exists(lpath):
        old_umask = os.umask(0o077)
        try:
            open(lpath, "a").close()
        finally:
            os.umask(old_umask)

    lock_file = open(lpath, "a+")
    try:
        if not no_lock:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        return body()
    finally:
        if not no_lock:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        lock_file.close()


def _with_locked_ledger(repo_root: str, run_id: str, mutate):
    """Acquire flock, read the ledger, run ``mutate(ledger)``, atomic-write, release.

    The lock spans the WHOLE read-modify-write (the lost-update guard). The
    test-only ``CLAUDE_AUTO_TEST_NO_LOCK`` hatch skips ONLY the flock
    acquisition (the read/mutate/write still run) so the concurrency test can
    prove a lost update without serialization.

    ``mutate`` receives the freshly-read ledger dict, mutates it in place, and
    may return a value, which this function returns.
    """
    path = ledger_path(repo_root, run_id)
    lpath = lock_path(repo_root, run_id)

    def body():
        if not os.path.exists(path):
            raise LedgerNotFound(f"no ledger for run-id {run_id!r} at {path}")
        ledger = _read_json(path)
        result = mutate(ledger)
        _atomic_write(path, ledger)
        return result

    return _flock_run(lpath, body)


# ──────────────────────────────────────────────────────────────────────────
# Public API.


def init_ledger(
    repo_root: str,
    run_id: str,
    *,
    adapter: str,
    adapter_scale: str = "three-tier",
    units=None,
    loop_phase: str = "plan",
    plan_step=None,
    recipe=None,
    phase_order=None,
    terminal_phase=None,
    phase_transitions=None,
    iteration=None,
    emit_templates=None,
):
    """Create a new ledger. Rejects if one already exists (LedgerExists).

    ``units`` is a list of partial unit dicts (at minimum ``id``); missing
    fields are filled with schema defaults. The predicate is recomputed and the
    file is written atomically under flock. ``plan_step`` defaults to ``None``
    (no plan step run yet — schema §3.1).

    v0.2.0 recipe fields (all additive / backward-compatible — a v0.1.x ledger
    with none of them reads identically; see _normalize_unit and §2 of the
    ledger-schema contract):
      ``recipe``         — optional dict {name, source_tier}; the recipe this run
                           was built from. None on a recipe-blind (v0.1.x) ledger.
      ``phase_order``    — optional list; the run's phase sequence. Defaults to
                           ["plan", "seam", "work"] (the v0.1.x grammar).
      ``terminal_phase`` — optional str; the phase whose completion ends the run.
                           Defaults to "work". MUST be a member of phase_order.
      ``phase_transitions`` — optional list of {from, to, emitter} dicts; the
                           recipe's emitter declarations. Persisted on the ledger
                           so seam-handlers can resolve the emitter for a given
                           arrival phase without re-loading the recipe file
                           (which could drift mid-run). Defaults to [] (no
                           emitters declared — legacy v0.1.x behavior, the run
                           emits nothing at phase boundaries).
    """
    if adapter not in ("ce", "native"):
        raise LedgerError(f"invalid adapter: {adapter!r}")
    if adapter_scale not in ("three-tier", "blocker-only"):
        raise LedgerError(f"invalid adapter_scale: {adapter_scale!r}")

    # phase_order / terminal_phase default to the v0.1.x grammar so a call with
    # neither produces a ledger that behaves exactly as before.
    if phase_order is None:
        phase_order = ["plan", "seam", "work"]
    elif not isinstance(phase_order, list) or not phase_order:
        raise LedgerError(f"phase_order must be a non-empty list: {phase_order!r}")
    if terminal_phase is None:
        terminal_phase = "work"
    if terminal_phase not in phase_order:
        raise LedgerError(
            f"terminal_phase {terminal_phase!r} not in phase_order {phase_order!r}"
        )
    # loop_phase must be a member of the run's phase_order (which, for the
    # default grammar, is exactly the legacy LOOP_PHASES minus the terminal
    # "done" sentinel — "done" is a post-terminal marker, never a start phase).
    if loop_phase != "done" and loop_phase not in phase_order:
        raise LedgerError(
            f"invalid loop_phase {loop_phase!r} for phase_order {phase_order!r}"
        )
    if plan_step is not None and plan_step not in PLAN_STEPS:
        raise LedgerError(f"invalid plan_step: {plan_step!r}")

    # phase_transitions defaults to []; basic shape check (the recipe validator
    # does the full check, but we don't trust that the caller already validated).
    if phase_transitions is None:
        phase_transitions = []
    elif not isinstance(phase_transitions, list):
        raise LedgerError(
            f"phase_transitions must be a list: {phase_transitions!r}"
        )

    path = ledger_path(repo_root, run_id)
    lpath = lock_path(repo_root, run_id)
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)

    # Hold the per-run flock across the existence-check + write (via the shared
    # _flock_run primitive) so two concurrent inits cannot both win. NOTE: init
    # cannot route through _with_locked_ledger — that primitive's RMW shape
    # REQUIRES the ledger to already exist (it reads it before calling mutate and
    # raises LedgerNotFound otherwise). init is the inverse: it must succeed only
    # when the file is ABSENT and create it. Both share the lock primitive
    # (_flock_run); only the body inside the lock differs (check-absent-then-write
    # here vs read-mutate-write there).
    def body():
        if os.path.exists(path):
            raise LedgerExists(f"ledger already exists for run-id {run_id!r}")

        norm_units = []
        for u in units or []:
            if "id" not in u:
                raise LedgerError("unit missing 'id'")
            norm_units.append(_normalize_unit(u, loop_phase=loop_phase))

        # v0.3.0 fix-pass F0: seed iteration_emit_count from max numeric
        # suffix of unit ids that already match any emit_templates[*].id_prefix.
        # iterate_template (lib/emitters.py) computes the next id as
        # `f"{id_prefix}{seed + i + 1}"`. If a recipe declares both
        # `units: [plan-1, plan-2, plan-3]` AND `emit_templates.<x>.id_prefix =
        # "plan-"`, seeding to 0 makes the first iterate emit `plan-1` — which
        # collides with the recipe-declared unit and livelocks the run until
        # max_wall_seconds. Pre-seeding to max-existing-suffix produces
        # `plan-4` on the first iterate, matching what the integration test
        # always asserted. Cross-reviewer P0 (ADV-1 + testing + correctness).
        seed_count = 0
        if emit_templates:
            for tmpl in emit_templates.values():
                prefix = (tmpl or {}).get("id_prefix")
                if not prefix:
                    continue
                for unit in norm_units:
                    uid = unit.get("id", "")
                    if not uid.startswith(prefix):
                        continue
                    suffix = uid[len(prefix):]
                    # G1 / ADV-R2-3: use ``isdecimal()`` not ``isdigit()`` —
                    # ``'²'.isdigit()`` is True but ``int('²')`` raises
                    # ValueError. ``isdecimal()`` returns True ONLY for the
                    # base-10 digits ``int()`` actually accepts, so a
                    # Unicode superscript suffix on a recipe-declared id is
                    # treated as "not iterate-shaped" and falls through —
                    # the original isdigit-guard intent, hardened against
                    # the Unicode class-int() mismatch.
                    if suffix.isdecimal():
                        seed_count = max(seed_count, int(suffix))

        ledger = {
            "run_id": run_id,
            "loop_phase": loop_phase,
            "plan_step": plan_step,
            "seam_paused": loop_phase == "seam",
            "adapter": adapter,
            "adapter_scale": adapter_scale,
            # v0.2.0 recipe fields (additive). recipe is None on a recipe-blind
            # v0.1.x ledger; phase_order/terminal_phase default to the legacy
            # grammar so the predicate + phase routing behave identically.
            "recipe": recipe,
            "phase_order": phase_order,
            "terminal_phase": terminal_phase,
            "phase_transitions": phase_transitions,
            # v0.3.0 iteration fields (additive — defaults preserve v0.2.x
            # behavior). A legacy ledger missing any of them reads via
            # `ledger.get(<field>, <default>)` at every consumer site (NEVER raw
            # subscript). KTD §D: top-level counters/accumulators, not unit-
            # scoped, so the bound check + predicate composition agree on a
            # single storage location.
            #   active_wall_seconds   — accumulator of monotonic-clock deltas
            #                           per tick (the wall-time bound denominator).
            #                           Round-3 P1-R3-3: counted from a finally
            #                           clause in tick.py to cover crashed paths.
            #   last_active_at        — ISO timestamp of the most recent
            #                           accumulate_active_time call. Diagnostic
            #                           only; the bound math reads
            #                           active_wall_seconds.
            #   iteration_attempts    — count of HONORED iterate decisions
            #                           (incremented by atomic_iterate_step). The
            #                           bound check fires PRE-increment via the
            #                           value here.
            #   iteration_emit_count  — monotonic emit-id counter (KTD §D / OQ4).
            #                           Replaces "recount existing units" which
            #                           would collide after a partial-emit crash.
            #                           Incremented by emit_within_phase per
            #                           emitted unit.
            "active_wall_seconds": 0,
            "last_active_at": None,
            "iteration_attempts": 0,
            "iteration_emit_count": seed_count,
            # v0.3.0 G2 / AN-W1: persisted record of a non-clean run exit. None
            # on a healthy run; populated by ``set_exit_reason`` when F2's
            # try/except (lib/tick.py) catches an iteration-check raise or a
            # recipe-bug LedgerError subclass. ``/auto-status`` renders it
            # alongside loop_phase=done so the operator can distinguish a clean
            # finish from a wedge that was force-marked done.
            "exit_reason": None,
            # v0.3.0 U6: recipe-declared iteration + emit_templates land on the
            # ledger at init so the engine's iteration check (advance_iteration_loop)
            # and the iterate_template emitter find them at every tick. None on a
            # legacy or non-iteration recipe (a1, W, v0.2.x a2/a4); the validators
            # at U5 ensure shape is OK if non-None. Routed through here (not seeded
            # post-init) so the recipe→ledger flow is the production path — the
            # plumbing gap U1-U5 left for U6 to close.
            "iteration": iteration,
            "emit_templates": emit_templates,
            "exit_predicate_result": {},  # filled by _atomic_write recompute.
            "units": norm_units,
            "loop": {"driver": "self", "last_beat_at": _now_iso()},
        }
        _atomic_write(path, ledger)
        return ledger

    return _flock_run(lpath, body)


def _normalize_unit(u: dict, *, loop_phase: str = "plan") -> dict:
    state = u.get("state", "pending")
    if state not in UNIT_STATES:
        raise LedgerError(f"invalid unit state: {state!r}")
    # v0.2.0 per-unit `phase` (additive). A unit with no explicit phase inherits
    # the run's start phase when that is a plan phase, else defaults to "work" —
    # matching the v0.1.x reality where plan-phase runs have no work units yet and
    # any pre-declared unit is a work unit. Recipes set `phase` explicitly.
    default_phase = "plan" if loop_phase == "plan" else "work"
    phase = u.get("phase", default_phase)
    return {
        "id": u["id"],
        "state": state,
        "phase": phase,
        "depends_on": list(u.get("depends_on") or []),
        "dispatched_at": u.get("dispatched_at"),
        "verdict_at": u.get("verdict_at"),
        "stall_threshold_seconds": int(
            u.get("stall_threshold_seconds", DEFAULT_STALL_THRESHOLD_SECONDS)
        ),
        "last_error": u.get("last_error"),
        # Bug #6 (attempt-identity): the dispatch generation counter. Each
        # pending->dispatched bump increments it; record_verdict carries the
        # attempt it is writing for and a verdict whose attempt is OLDER than this
        # is rejected (a stale verdict from a superseded attempt — e.g. a slow
        # agent that was retried). Defaults to 0 — additive / backward-compatible:
        # an old ledger with no `attempt` field reads as 0 and behaves identically
        # when record_verdict is called without an explicit attempt.
        "attempt": int(u.get("attempt", 0) or 0),
        "findings": list(u.get("findings") or []),
        # v0.2.0 per-unit additive fields (all backward-compatible — an old
        # ledger with none of these reads as the documented defaults below and
        # behaves identically; same discipline as `attempt` above):
        #   plan_step       — per-unit plan-step for N>1 parallel plan-loops (R11);
        #                     A1's single plan-loop keeps using the top-level
        #                     scalar, so this stays None there. None = no step yet.
        #   gaps_open       — per-unit open-gap count for N>1 plan-loops. None until
        #                     a review feeds one back.
        #   dispatch_context— recipe-side metadata merged from `invokes` (e.g.
        #                     prompt_template, bias) + engine-written keys like
        #                     enumerated_units. {} when absent.
        #   last_advanced_at— round-robin tiebreaker for serialized N>1 plan
        #                     advance (null sorts oldest → picked first).
        "plan_step": u.get("plan_step"),
        "gaps_open": u.get("gaps_open"),
        "dispatch_context": dict(u.get("dispatch_context") or {}),
        "last_advanced_at": u.get("last_advanced_at"),
    }


def read_ledger(repo_root: str, run_id: str) -> dict:
    """Return the ledger dict. Raises LedgerNotFound on unknown run-id.

    A read-only operation; takes NO lock. The atomic-write chokepoint
    (``_atomic_write`` = mkstemp + os.rename) makes a torn read impossible — a
    reader either sees the whole prior file or the whole new one, never a
    half-written one — so no lock is needed to read a consistent snapshot. This
    is why the engine's hot read paths (the Stop hook, status, converge) read
    lock-free: they cannot contend with a slow writer.
    """
    path = ledger_path(repo_root, run_id)
    if not os.path.exists(path):
        raise LedgerNotFound(f"no ledger for run-id {run_id!r} at {path}")
    return _read_json(path)


def _find_unit(ledger: dict, unit_id: str) -> dict:
    for u in ledger.get("units", []):
        if u.get("id") == unit_id:
            return u
    raise UnknownUnit(f"no unit {unit_id!r} in ledger")


def transition(repo_root, run_id, unit_id, new_state, **fields):
    """Grammar-checked unit state change under flock.

    Rejects any transition not in ALLOWED_TRANSITIONS (raises InvalidTransition;
    the ledger is NOT written). Optional ``fields`` update unit attributes in the
    same write (e.g. dispatched_at, last_error). Predicate recomputed + atomic.

    NOTE: ``record_verdict`` is the dedicated path for dispatched -> verdict-returned
    (it owns findings semantics). ``transition`` can also perform it but does NOT
    touch findings; callers writing findings should use ``record_verdict``.
    """
    if new_state not in UNIT_STATES:
        raise InvalidTransition(f"unknown target state {new_state!r}")

    def mutate(ledger):
        unit = _find_unit(ledger, unit_id)
        current = unit.get("state")
        if new_state not in ALLOWED_TRANSITIONS.get(current, set()):
            raise InvalidTransition(
                f"{current!r} -> {new_state!r} not permitted for unit {unit_id!r}"
            )
        unit["state"] = new_state
        # stalled -> pending (retry) clears last_error per the contract.
        if current == "stalled" and new_state == "pending":
            unit["last_error"] = None
        # Capture the dispatch-generation counter BEFORE the fields loop (which may
        # itself carry an explicit attempt=) so the mechanical bump below reconciles
        # against the PRE-transition value, not a value the loop just wrote.
        prev_attempt = int(unit.get("attempt", 0) or 0)
        for key, value in fields.items():
            if key == "findings":
                raise LedgerError(
                    "use record_verdict() to write findings, not transition()"
                )
            unit[key] = value
        # Bug #6 (attempt-identity), made MECHANICAL (P2): the dispatch generation
        # counter MUST advance on every pending -> dispatched edge, in the SAME
        # atomic snapshot as the state change. We bump it HERE — at the transition
        # itself — rather than relying on the caller (dispatch_batch) to pass the
        # right ``attempt=`` value by convention. That convention was a latent
        # stale-verdict-clobber hole: any future re-dispatch path that forgot to
        # bump would let a superseded attempt's verdict overwrite the live one. By
        # enforcing the increment at the only edge that creates a new dispatch
        # generation, no caller can re-open Bug #6. We reconcile against an explicit
        # attempt= the caller may have passed: the counter becomes max(prev+1,
        # passed) so the dispatch_batch path (which passes prev+1) stays exactly
        # consistent, a caller that passes nothing still advances by one, and a
        # stale/lower explicit value can never lower the counter. Crucially we use
        # the PRE-loop ``prev_attempt`` — the fields loop above may have written the
        # passed value into ``unit["attempt"]`` already, so reading it back would
        # double-count.
        if current == "pending" and new_state == "dispatched":
            passed = fields.get("attempt")
            unit["attempt"] = max(
                prev_attempt + 1,
                int(passed) if passed is not None else 0,
            )
        return unit["state"]

    return _with_locked_ledger(repo_root, run_id, mutate)


def _emit_units_core(ledger: dict, to_phase: str, emitter) -> list:
    """Pure shared helper: emit + validate + append units. NO flock acquire,
    NO loop_phase write, NO counter bump — callers add those.

    Factored out of ``transition_and_emit`` and ``_apply_emit`` (F3 / maint-1)
    so the emit/validate/append loop lives in ONE place. The two callers
    diverge ONLY in:
      - ``transition_and_emit`` additionally advances ``loop_phase``.
      - ``_apply_emit`` additionally bumps ``iteration_emit_count``.

    Keeping that divergence at the call sites means the SHARED contract
    (per-unit id-required, no collision; normalize via ``_normalize_unit``
    with current ``loop_phase``; default to ``to_phase``) lives in one
    place. The two prior copy-paste loops were byte-equivalent on the
    emit-loop body and would have drifted on any future field added to a
    new unit's normalization.

    Returns the list of newly-appended unit ids.
    """
    new_units = emitter(ledger, to_phase) or []
    existing_ids = {u["id"] for u in ledger.get("units", [])}
    appended = []
    for nu in new_units:
        if "id" not in nu:
            raise LedgerError("emitted unit missing 'id'")
        if nu["id"] in existing_ids:
            raise LedgerError(f"emitted unit id collides: {nu['id']!r}")
        # Emitted units default to the arriving phase unless they declare one.
        nu = dict(nu)
        nu.setdefault("phase", to_phase)
        ledger.setdefault("units", []).append(
            _normalize_unit(nu, loop_phase=ledger.get("loop_phase", "plan"))
        )
        existing_ids.add(nu["id"])
        appended.append(nu["id"])
    return appended


def transition_and_emit(
    repo_root, run_id, to_phase, emitter: Callable[[dict, str], list]
):
    """Advance ``loop_phase`` to ``to_phase`` AND emit that phase's units, in ONE
    atomic write (v0.2.0 U5b / KTD-6 — the G3/F2 fix).

    This is the phase-transition primitive. The round-1 framing tried to do the
    advance and the emission as SEPARATE locked writes (`set_loop` then an emit),
    which left a torn-state window: a reader between the two writes would see the
    new phase with zero emitted units, and `recompute_predicate` could fire
    ``met`` prematurely (e.g. A2's judge terminal → all_units_terminal with no
    work units yet). Doing both inside one ``_with_locked_ledger`` body closes
    that window: the emitter's units are appended BEFORE ``_atomic_write``'s
    mandatory predicate recompute, so ``met`` is always computed against the
    post-emission unit set.

    ``emitter`` is a PURE callable ``(ledger, to_phase) -> list[new_unit_dict]``.
    It MUST NOT call any ledger mutator (`transition`, `record_verdict`,
    `set_loop`, …): those re-acquire the flock on a fresh fd and would deadlock
    inside this already-locked body (F3). The emitter only READS the passed
    ledger dict and RETURNS new partial unit dicts; this primitive normalizes and
    appends them. New unit ids must not collide with existing ones.

    Returns the list of newly-appended unit ids.

    F3 / maint-1: emit body delegates to ``_emit_units_core``; this path adds
    the ``loop_phase``/``seam_paused`` advance that distinguishes a transition
    from an in-phase emit.
    """
    def mutate(ledger):
        appended = _emit_units_core(ledger, to_phase, emitter)
        # Advance the phase AFTER emission (the units belong to to_phase; setting
        # loop_phase first or last is equivalent here since both happen in one
        # snapshot, but advancing last keeps "emit produces units FOR to_phase"
        # readable). seam_paused tracks the phase per the v0.1.x rule.
        ledger["loop_phase"] = to_phase
        ledger["seam_paused"] = to_phase == "seam"
        return appended

    return _with_locked_ledger(repo_root, run_id, mutate)


# States from which record_verdict may write a verdict. This is a record_verdict
# -ONLY transition set, deliberately WIDER than ALLOWED_TRANSITIONS (which governs
# the findings-free `transition()` path). It is NOT added to ALLOWED_TRANSITIONS
# because doing so would let `transition()` move state without findings — exactly
# what the "use record_verdict() to write findings" guard blocks.
#
#   * dispatched        — the normal first verdict self-write (§3 grammar edge).
#   * verdict-returned   — a re-verdict (the re-review path; latest-only findings).
#   * stalled            — Bug #7 RECOVERY: a healthy-but-slow review that was
#                          marked `stalled` past stall_threshold_seconds finishes
#                          and self-writes a GENUINE verdict. That is real work;
#                          throwing it away (InvalidTransition, silently) loses a
#                          completed verdict AND leaves last_error null so it looks
#                          identical to a true timeout. We RECOVER it instead. The
#                          attempt-identity check (Bug #6) still rejects a recovery
#                          from a SUPERSEDED attempt (an operator retried, a fresh
#                          agent already verdicted), so a stale late verdict from a
#                          retried-past attempt is NOT recovered.
_VERDICT_WRITABLE_STATES = frozenset({"dispatched", "verdict-returned", "stalled"})


def record_verdict(repo_root, run_id, unit_id, findings, attempt=None):
    """{dispatched, verdict-returned, stalled} -> verdict-returned: OVERWRITE
    findings + set verdict_at.

    This is the background-agent verdict-self-write path (U10). It is the ONLY
    writer of ``findings[]`` (§4.2). ``findings`` fully REPLACES the prior array.
    Predicate recomputed in the same atomic snapshot (I-1).

    ``attempt`` (Bug #6 — attempt-identity): the dispatch generation the verdict is
    written FOR. The orchestrator increments a unit's ``attempt`` on each
    pending->dispatched dispatch; a background agent launched for attempt N carries
    N here. A verdict whose ``attempt`` is OLDER than the unit's current ``attempt``
    is REJECTED (``StaleVerdict``) — it is a stale verdict from a SUPERSEDED attempt
    (e.g. a slow agent A stalled, the operator retried, agent B was dispatched as a
    fresh attempt and verdicted; A then finishes and tries to clobber B's verdict
    with stale findings). ``attempt=None`` skips the check (back-compat: callers /
    tests that do not track attempts behave exactly as before). Equal-attempt is
    ACCEPTED (the legitimate re-review / recovery path).

    Bug #7 (late-verdict recovery): a genuine verdict arriving from a unit currently
    in ``stalled`` is RECOVERED to verdict-returned (it is real work — see
    ``_VERDICT_WRITABLE_STATES``), UNLESS Bug #6's attempt check rejects it as
    stale. The two interact: recovery is only for the CURRENT attempt; a late
    verdict from a superseded attempt is still rejected, never recovered.
    """
    norm = []
    for f in findings or []:
        sev = f.get("severity")
        if sev not in SEVERITIES:
            raise LedgerError(f"invalid finding severity: {sev!r}")
        norm.append({"severity": sev, "note": f.get("note", "")})

    skip_attempt = _test_hatch_enabled("CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK")
    skip_recovery = _test_hatch_enabled("CLAUDE_AUTO_TEST_NO_STALLED_RECOVERY")

    def mutate(ledger):
        unit = _find_unit(ledger, unit_id)
        current = unit.get("state")

        # Bug #6: reject a verdict from a superseded attempt BEFORE any write. This
        # is checked first so a stale late verdict is never recovered (it interacts
        # with Bug #7's recovery: only a current-attempt late verdict recovers).
        if not skip_attempt and attempt is not None:
            cur_attempt = int(unit.get("attempt", 0) or 0)
            if int(attempt) < cur_attempt:
                raise StaleVerdict(
                    f"verdict for unit {unit_id!r} carries attempt {attempt} "
                    f"but current attempt is {cur_attempt} — superseded; rejected"
                )

        # Bug #7: a stalled unit's GENUINE late verdict is recoverable. The
        # deliberate-fail hatch forces the old (pre-fix) check that ONLY permitted
        # dispatched/verdict-returned, so a late verdict from a stalled unit is
        # lost to InvalidTransition.
        writable = (
            {"dispatched", "verdict-returned"}
            if skip_recovery
            else _VERDICT_WRITABLE_STATES
        )
        if current not in writable:
            raise InvalidTransition(
                f"{current!r} -> 'verdict-returned' not permitted for unit {unit_id!r}"
            )

        unit["state"] = "verdict-returned"
        unit["findings"] = norm
        unit["verdict_at"] = _now_iso()
        # A recovered late verdict is real work — clear any stale last_error so the
        # unit no longer looks like an unresolved timeout/raise.
        unit["last_error"] = None
        return norm

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_loop(
    repo_root,
    run_id,
    *,
    loop_phase=None,
    seam_paused=None,
    driver=None,
    beat=False,
    plan_step=_UNSET,
):
    """Update loop-level phase / liveness / plan-step fields (U4's tick uses this).

    ``beat=True`` stamps ``loop.last_beat_at`` to now. Predicate recomputed +
    atomic (a phase change can flip ``met`` via the plan-loop gaps clause).

    ``plan_step`` uses an UNSET sentinel default (NOT ``None``) because ``null``
    is itself a valid stored plan_step (the initial "no step yet"). Omit it to
    leave the field unchanged; pass ``plan_step=None`` to clear it, or a step
    name (``"plan"`` / ``"deepen"`` / ``"review_plan"``) to record it. The tick
    calls this with the step it just ran so the NEXT (fresh-process) tick is not
    amnesiac — the anti-livelock persist (schema §3.1). In the plan phase
    ``plan_step`` feeds the predicate (plan-met requires ``plan_step ==
    "review_plan"``), so persisting it can flip ``met`` — the recompute on this
    write reflects that.
    """
    if loop_phase is not None and loop_phase not in LOOP_PHASES:
        raise LedgerError(f"invalid loop_phase: {loop_phase!r}")
    if driver is not None and driver not in ("self", "manual"):
        raise LedgerError(f"invalid driver: {driver!r}")
    if plan_step is not _UNSET and plan_step is not None and plan_step not in PLAN_STEPS:
        raise LedgerError(f"invalid plan_step: {plan_step!r}")

    def mutate(ledger):
        if loop_phase is not None:
            ledger["loop_phase"] = loop_phase
        if seam_paused is not None:
            ledger["seam_paused"] = bool(seam_paused)
        if plan_step is not _UNSET:
            ledger["plan_step"] = plan_step
        loop = ledger.setdefault("loop", {})
        if driver is not None:
            loop["driver"] = driver
        if beat:
            loop["last_beat_at"] = _now_iso()
        return ledger["loop_phase"]

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_gaps_open(repo_root, run_id, gaps_open: int):
    """Persist the plan-loop open-gap count from ``review_plan``'s return (U4's
    tick uses this). The engine reads ONLY the gap-set length and writes it here
    (adapter-contract §2.2 / §5).

    The value is written into ``exit_predicate_result.gaps_open`` BEFORE the
    atomic-write recompute reads it back, so the freshly-recomputed predicate
    reflects the new gap count in the SAME snapshot (I-1). ``recompute_predicate``
    preserves the prior cached ``gaps_open`` precisely so this mutator can seed
    it; this is the ONLY writer of a non-null value. Until it runs, gaps_open is
    null (Bug #5 — null means "no real review reported gaps yet" and is distinct
    from 0; plan-met requires a non-null zero, so a freshly-prepared-but-unfilled
    review can never satisfy it).
    """
    n = int(gaps_open)
    if n < 0:
        raise LedgerError(f"gaps_open must be >= 0, got {n}")

    def mutate(ledger):
        epr = ledger.setdefault("exit_predicate_result", {})
        epr["gaps_open"] = n
        return n

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_enumerated_units(repo_root, run_id, unit_id, enumerated):
    """Persist a plan unit's ``enumerate_plan_units`` output onto its
    ``dispatch_context.enumerated_units`` (v0.2.0 U6, the producer-persist).

    Called at plan-done with the adapter's enumerated work-unit list. The
    phase-transition emitter (U5b) reads it from here when emitting work units —
    so this is the on-ledger bridge between "the plan finished" and "here are its
    work units," resolving F4 (v0.1.x had no in-code producer). ``enumerated`` is
    a list of partial unit dicts (each at least an ``id``). Raises if the named
    unit doesn't exist. Atomic (predicate recompute is a no-op here — the plan
    unit's own state is unchanged — but the write stays on the I-1 path).
    """
    if not isinstance(enumerated, list):
        raise LedgerError("enumerated units must be a list")

    def mutate(ledger):
        unit = _find_unit(ledger, unit_id)
        dc = unit.setdefault("dispatch_context", {})
        dc["enumerated_units"] = list(enumerated)
        return len(enumerated)

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_winner_unit_id(repo_root, run_id, judge_unit_id, winner_id):
    """Persist an A2 judge's winner pick onto its ``dispatch_context.winner_unit_id``
    (v0.2.0 round-2 P0 fix — fix-pass I).

    A2's ``judge_winner_to_work_units`` emitter needs to know which plan unit won.
    The original design read it from ``findings[].winner_unit_id``, but
    ``record_verdict`` normalizes findings to ``{severity, note}`` only —
    stripping the winner before the emitter ever runs. Production A2 was
    unrunnable end-to-end. dispatch_context is the right home: same channel as
    ``enumerated_units``, preserved by ``transition()`` and the verdict-write
    path, and findings stay narrow.

    The judge agent (or its launcher) calls THIS mutator alongside
    ``record_verdict`` to declare the winner. ``winner_id`` must be a non-empty
    string AND must reference an existing unit id in the ledger (defensive — a
    typo'd winner would surface as a hard error here rather than a confusing
    emitter raise later). Raises if the judge unit doesn't exist or the winner
    is invalid. Atomic (predicate recompute is a no-op here — the judge's own
    state is unchanged — but the write stays on the I-1 path).
    """
    if not isinstance(winner_id, str) or not winner_id:
        raise LedgerError(f"winner_id must be a non-empty string, got {winner_id!r}")

    def mutate(ledger):
        judge = _find_unit(ledger, judge_unit_id)
        # The eligible-winner set is "every unit except the judge itself"
        # (round-3 P3 promotion — fix-pass J). The previous check accepted
        # the judge naming itself as winner, which would pass the guard, the
        # emitter would call _enumerated_units(judge) which returns [] (judges
        # don't carry enumerated_units), and the run would silently emit no
        # work units — exactly the failure mode the design was trying to
        # prevent ("malformed judge verdict is a hard error, not silent empty
        # emission"). Excluding judge_unit_id from existing_ids tightens the
        # contract to "winner must be SOME OTHER unit" and surfaces the
        # malformed case as the LedgerError it deserves.
        existing_ids = {
            u.get("id") for u in ledger.get("units", [])
        } - {judge_unit_id}
        if winner_id not in existing_ids:
            raise LedgerError(
                f"winner_id {winner_id!r} does not name an eligible unit "
                f"(must differ from judge {judge_unit_id!r}); "
                f"known: {sorted(i for i in existing_ids if i)!r}"
            )
        dc = judge.setdefault("dispatch_context", {})
        dc["winner_unit_id"] = winner_id
        return winner_id

    return _with_locked_ledger(repo_root, run_id, mutate)


# ──────────────────────────────────────────────────────────────────────────
# v0.3.0 (U2): iteration mutators.
#
# Six new write paths support outcomes-gated emission (KTD §A-D + U2 plan
# section). All share the same atomicity contract as the v0.2.0 mutators:
# each routes through ``_with_locked_ledger``, which recomputes the predicate
# (now including ``iteration_pending``) in the SAME atomic snapshot as the
# write (I-1).
#
# Why the surface is wider than round-1 priced: the round-2 doc-review pinned
# three architectural locks (KTD §A control-flow placement, §B predicate
# composition, §C gate-unit re-engagement) that require dedicated mutators
# rather than letting the tick stitch raw writes — see plan U2 §Approach.
#
# DEADLOCK GUARD (the F3 trap from v0.2.0): `_with_locked_ledger` cannot be
# nested. Any composite path (atomic_iterate_step) MUST inline its sub-step
# bodies inside ONE outer locked body — calling a public mutator from inside a
# locked mutate() would re-acquire the flock on a fresh fd and deadlock. The
# pure helper ``_apply_emit`` below is shared between `emit_within_phase` (one
# locked body) and `atomic_iterate_step` (one locked body) for this reason.


def _apply_emit(ledger: dict, to_phase: str, emitter) -> list:
    """Pure helper: run ``emitter(ledger, to_phase)``, validate + append units,
    bump ``iteration_emit_count`` per emitted unit. NEVER acquires the flock —
    the caller already holds it (the F3 deadlock guard).

    Used by both ``emit_within_phase`` and ``atomic_iterate_step`` from within
    their respective locked bodies. Returns the list of newly-appended unit
    ids. Mirrors ``transition_and_emit``'s body shape exactly EXCEPT it does
    NOT write ``loop_phase`` — emission stays within the gate unit's current
    phase. Validation parity (missing id; collision) matches transition_and_emit.

    F3 / maint-1: emit body delegates to ``_emit_units_core``; this path adds
    the per-unit ``iteration_emit_count`` bump that distinguishes an iterating
    emit from a phase-transition emit.
    """
    appended = _emit_units_core(ledger, to_phase, emitter)
    # KTD §D / OQ4: bump the monotonic emit-id counter PER emitted unit.
    # Drives `iterate_template` (U3)'s id assignment via
    # `id_prefix + (counter+1)`; replaces "recount existing units" which
    # would collide after a partial-emit crash deleted units.
    if appended:
        ledger["iteration_emit_count"] = (
            int(ledger.get("iteration_emit_count", 0)) + len(appended)
        )
    return appended


def emit_within_phase(repo_root, run_id, to_phase: str, emitter):
    """Emit new units into ``to_phase`` WITHOUT advancing ``loop_phase``.

    Sibling to ``transition_and_emit``: same atomicity contract (one
    ``_with_locked_ledger`` body wraps emit+normalize+append+recompute), but
    NO ``loop_phase`` write and NO ``seam_paused`` flip. Re-emission stays
    within the gate unit's current phase per KTD §D — the iteration loop adds
    siblings rather than transitioning the run.

    ``emitter`` is a PURE callable ``(ledger, to_phase) -> list[new_unit_dict]``.
    Same constraint as ``transition_and_emit``: it MUST NOT call any ledger
    mutator (F3 deadlock — fresh-fd flock re-acquire on a held lock).

    Per emitted unit, ``iteration_emit_count`` is incremented atomically
    (closes round-3 P0-R3-2's "recount on resume after partial-emit crash"
    failure mode). Returns the list of newly-appended unit ids.

    Implementer's OQ-resolved shape (plan "Deferred to Implementation"): a
    NEW PUBLIC FUNCTION rather than a ``transition_and_emit`` parameter
    extension. The bodies share the emit-append-normalize sub-step (factored
    into ``_apply_emit`` for ``atomic_iterate_step`` reuse) but diverge on
    loop_phase/seam_paused/counter — a parameter would muddy both paths and
    leak the counter into transition_and_emit.
    """
    def mutate(ledger):
        return _apply_emit(ledger, to_phase, emitter)

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_verdict_decision(
    repo_root, run_id, gate_unit_id, decision: str, payload=None
):
    """Persist the gate unit's verdict.decision onto its dispatch_context
    (KTD §D / U2). Mirrors the ``set_winner_unit_id`` precedent (v0.2.0 round-2
    P0 fix — fix-pass I): the decision lives on ``dispatch_context.decision``,
    NOT on ``findings[]``, because ``record_verdict`` normalizes findings to
    ``{severity, note}`` only and would strip the decision before any reader
    sees it.

    ``decision`` MUST be a member of ``iteration.DECISIONS`` —
    ``("advance", "iterate", "exit")``. The validation is the contract the
    engine relies on; a garbage decision is the dominant build-bug class this
    centralization closes (the "plan documents a behavior the code never
    wires" class).
    Optional ``payload`` (dict) is persisted alongside on
    ``dispatch_context.decision_payload`` — used by ``iterate_template`` to
    read e.g. ``emit_count`` (U3).

    Raises ``LedgerError`` if the gate unit is missing OR the decision is not
    in the enum.
    """
    # Lazy load (same load-order discipline as recompute_predicate above).
    iteration = _lazy_load("iteration")

    if decision not in iteration.DECISIONS:
        raise LedgerError(
            f"decision must be one of {iteration.DECISIONS!r}; got {decision!r}"
        )
    if payload is not None and not isinstance(payload, dict):
        raise LedgerError(
            f"decision_payload must be a dict or None; got {type(payload).__name__}"
        )

    def mutate(ledger):
        gate = _find_unit(ledger, gate_unit_id)
        dc = gate.setdefault("dispatch_context", {})
        dc["decision"] = decision
        if payload is not None:
            dc["decision_payload"] = dict(payload)
        return decision

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_bound_override(
    repo_root, run_id, gate_unit_id, bound_type: str, original_decision: str
):
    """Record that the engine overrode an ``iterate`` decision to ``exit``
    because the iteration bound was breached (KTD §D / U2).

    Writes ``dispatch_context.bound_override = {bound: <bound_type>,
    original_decision: <original>, at: <iso>}`` on the gate unit. Mirrors the
    ``winner_unit_id`` precedent — operator-diagnostic data lives on
    ``dispatch_context``, not on findings or a top-level field. The operator
    on ``/auto-status`` reads from here (R9 surface).

    ``bound_type`` must be ``"max_attempts"`` or ``"max_wall_seconds"``;
    ``original_decision`` must be a member of ``iteration.DECISIONS``. The
    ``at`` timestamp is load-bearing for operator provenance (the deliberate-
    fail #5 test asserts overrides without a timestamp are caught).
    """
    if bound_type not in ("max_attempts", "max_wall_seconds"):
        raise LedgerError(
            f"bound_type must be 'max_attempts' or 'max_wall_seconds'; "
            f"got {bound_type!r}"
        )

    iteration = _lazy_load("iteration")

    if original_decision not in iteration.DECISIONS:
        raise LedgerError(
            f"original_decision must be one of {iteration.DECISIONS!r}; "
            f"got {original_decision!r}"
        )

    def mutate(ledger):
        gate = _find_unit(ledger, gate_unit_id)
        dc = gate.setdefault("dispatch_context", {})
        dc["bound_override"] = {
            "bound": bound_type,
            "original_decision": original_decision,
            "at": _now_iso(),
        }
        return bound_type

    return _with_locked_ledger(repo_root, run_id, mutate)


def set_exit_reason(repo_root, run_id, kind: str, error: dict):
    """Record a non-clean exit on the ledger (v0.3.0 G2 / AN-W1).

    Writes ``ledger["exit_reason"] = {"kind": kind, "error": error, "at": iso}``
    via the standard locked-RMW path. Called by F2's try/except in
    ``lib/tick.py`` BEFORE force-marking the loop done, so ``/auto-status`` of
    a crashed run can distinguish a wedge-marked-done from a clean exit. ``kind``
    is a short tag (e.g. ``"iteration-check-failed"``, ``"recipe-bug"``);
    ``error`` is a dict carrying at minimum ``{"type": ..., "message": ...}``
    so the operator surface can render the original exception type.

    Mirrors ``set_bound_override``'s shape — operator-diagnostic data lives on
    the ledger via a single timestamped envelope, NOT on findings.
    """
    def mutate(ledger):
        ledger["exit_reason"] = {
            "kind": kind,
            "error": error,
            "at": _now_iso(),
        }
        return kind

    return _with_locked_ledger(repo_root, run_id, mutate)


def accumulate_active_time(repo_root, run_id, delta_seconds: float):
    """Add ``delta_seconds`` to ``active_wall_seconds`` and stamp
    ``last_active_at`` (R5 / KTD §D).

    The FIRST sum-of-deltas accumulator on the ledger — every prior time field
    is overwrite-on-write. The contract is ADD, not OVERWRITE: each call adds
    its delta to the existing total, so two ticks of 5.0 + 7.5 sum to 12.5.
    The deliberate-fail #1 test asserts this is real addition, not the trap
    where a future refactor accidentally writes ``= round(delta, 3)``.

    Rounded to 3 decimal places to cap on-disk precision (a tick that runs for
    0.0000001 s is not interesting; the bound check tolerates millisecond
    granularity). Negative deltas are clamped to 0 — wall time only flows
    forward; a clock anomaly should not subtract from the bound budget.

    ``last_active_at`` is the ISO timestamp of THIS call, diagnostic only.
    The bound math reads ``active_wall_seconds``.

    Called from U4's ``finally``-clause around ``_tick_body`` (per round-2
    doc-review P1) so the crashed-tick delta still lands.
    """
    delta = float(delta_seconds)
    if delta < 0:
        delta = 0.0
    delta = round(delta, 3)

    def mutate(ledger):
        cur = float(ledger.get("active_wall_seconds", 0))
        ledger["active_wall_seconds"] = round(cur + delta, 3)
        ledger["last_active_at"] = _now_iso()
        return ledger["active_wall_seconds"]

    return _with_locked_ledger(repo_root, run_id, mutate)


def increment_iteration_attempts(repo_root, run_id, gate_unit_id):
    """Atomic ``iteration_attempts += 1``. KTD §D / U2.

    Called by U4's ``advance_iteration_loop`` when honoring an iterate decision
    (NOT when the bound-override path forces exit — overrides do not count as
    honored attempts). The pre-increment value drives the bound check in
    ``iteration.evaluate_decision`` so the Nth attempt is checked BEFORE its
    decision is honored: if a tick reads iteration_attempts==max, the override
    fires; the counter only crosses max via this call when the prior tick
    honored the (max-1)-th iterate.

    Composite path (``atomic_iterate_step``) inlines this increment instead of
    calling here — the F3 deadlock guard. The standalone mutator exists for
    completeness (tests, future paths) and for the deliberate-fail #6 control.

    ``gate_unit_id`` is required (and validated) so the increment can NEVER be
    silently called against a missing/typo'd gate — defensive. The value is
    the new count; the return is the new count for caller convenience.
    """
    def mutate(ledger):
        # Validate the gate unit exists; raises UnknownUnit on typo.
        _find_unit(ledger, gate_unit_id)
        cur = int(ledger.get("iteration_attempts", 0))
        ledger["iteration_attempts"] = cur + 1
        return ledger["iteration_attempts"]

    return _with_locked_ledger(repo_root, run_id, mutate)


def _reset_gate_for_iteration(ledger: dict, gate_unit_id: str, new_depends_on) -> dict:
    """Pure helper: the atomic gate-unit reset combo (KTD §C). The caller
    already holds the flock — this is the F3 deadlock guard, mirroring
    ``_apply_emit``.

    In ONE pass mutates the gate unit:
      (a) state ``verdict-returned → pending`` (validates the EXISTING edge in
          ``ALLOWED_TRANSITIONS[lib/ledger.py:84]`` — v0.3.0 does NOT add a
          new edge; the contract is the atomic COMBO, not a new grammar move).
      (b) ``depends_on`` is replaced with ``new_depends_on`` (the union of the
          gate's prior deps + newly-emitted sibling ids — the caller computes
          the union; this mutator just writes).
      (c) ``dispatch_context.decision`` and ``dispatch_context.decision_payload``
          CLEARED (closes round-3 P0-R3-1: without the clear, a subsequent
          tick re-reads the stale ``iterate`` decision and re-fires the
          iteration loop before the gate re-verdicts, double-incrementing
          iteration_attempts until bound trip).
      (d) ``verdict_at`` cleared.
      (e) ``findings`` cleared.

    Grammar-check is INLINE (not via ``transition()``) — same F3 reason. The
    deliberate-fail #2 / #3 controls assert (e) and (c) respectively are
    load-bearing.
    """
    gate = _find_unit(ledger, gate_unit_id)
    current = gate.get("state")
    # The verdict-returned → pending edge ALREADY exists in
    # ALLOWED_TRANSITIONS at lib/ledger.py:84 — v0.3.0 does NOT add a new
    # state edge. We replicate the check inline (cannot route through
    # transition() inside a locked body; F3 deadlock).
    if "pending" not in ALLOWED_TRANSITIONS.get(current, set()):
        raise InvalidTransition(
            f"{current!r} -> 'pending' not permitted for unit {gate_unit_id!r} "
            f"(reset_for_iteration requires source state 'verdict-returned')"
        )
    gate["state"] = "pending"
    gate["depends_on"] = list(new_depends_on or [])
    dc = gate.setdefault("dispatch_context", {})
    # Round-3 P0-R3-1: clearing the decision is load-bearing. A surviving
    # `decision: "iterate"` would re-fire the iteration loop on the NEXT
    # tick before the gate has re-verdicted, double-incrementing
    # iteration_attempts until bound trip. Centralizing the clear here
    # (single owner) is cleaner than a per-read-site guard.
    dc.pop("decision", None)
    dc.pop("decision_payload", None)
    gate["verdict_at"] = None
    gate["findings"] = []
    return gate


def reset_for_iteration(repo_root, run_id, gate_unit_id, new_depends_on):
    """Atomic gate-unit reset combo per KTD §C. The engine-only caller for the
    atomic re-engagement combination over the EXISTING
    ``verdict-returned → pending`` edge in ``ALLOWED_TRANSITIONS``.

    The full combo is implemented in ``_reset_gate_for_iteration`` (callable
    from inside a held lock — ``atomic_iterate_step`` reuses it). This public
    mutator wraps that helper in its own locked body for callers that just
    need the reset standalone.
    """
    def mutate(ledger):
        _reset_gate_for_iteration(ledger, gate_unit_id, new_depends_on)
        return "pending"

    return _with_locked_ledger(repo_root, run_id, mutate)


def atomic_iterate_step(
    repo_root, run_id, gate_unit_id, emitter, new_depends_on
):
    """The composite mutator that runs ONE full iteration step atomically
    (round-3 P1-R3-1 / KTD §C+D). Wraps THREE writes into ONE
    ``_with_locked_ledger`` body:

      1. ``iteration_attempts`` increments (KTD §D bound counter).
      2. ``emitter`` runs; new units are validated, normalized, appended; per
         unit ``iteration_emit_count`` increments (KTD §D monotonic id).
      3. Gate unit reset (state ``verdict-returned → pending``, depends_on
         replaced, dispatch_context.decision / decision_payload cleared,
         verdict_at cleared, findings cleared — KTD §C).

    All-or-nothing: if any sub-step raises (e.g. an emitter that returns a
    colliding id, or the gate not in ``verdict-returned``), the ledger is NOT
    written (``_with_locked_ledger`` only calls ``_atomic_write`` on
    successful mutate). The deliberate-fail #8 control proves this by passing
    a bad emitter — in the atomic version iteration_attempts stays at 0; in a
    split version it would increment before the emit fails.

    Engine-only caller (U4's ``advance_iteration_loop``).
    """
    # Capture the caller-supplied depends_on for closure use (avoids the
    # UnboundLocalError trap where assigning new_depends_on inside mutate()
    # makes Python rebind it as a local before its first read).
    caller_depends_on = new_depends_on

    def mutate(ledger):
        # Validate gate exists up front so we don't half-increment then fail
        # later (a typo'd gate_unit_id would otherwise let increment land
        # before _reset_gate_for_iteration's lookup raised; lookup-first
        # keeps the all-or-nothing contract intact).
        _find_unit(ledger, gate_unit_id)
        # Step 1: increment iteration_attempts (bound counter).
        ledger["iteration_attempts"] = int(ledger.get("iteration_attempts", 0)) + 1
        # Step 2: emit new units inline (gate unit's current phase).
        gate = _find_unit(ledger, gate_unit_id)
        to_phase = gate.get("phase") or ledger.get("loop_phase", "plan")
        appended = _apply_emit(ledger, to_phase, emitter)
        # Step 3: reset the gate unit atomically with the emit. The caller
        # supplies the new depends_on (union of gate's prior deps + newly-
        # emitted ids); we honor it verbatim. If the caller passed `None`
        # we compute the union here as a defensive default.
        deps = caller_depends_on
        if deps is None:
            deps = list(gate.get("depends_on") or []) + list(appended)
        _reset_gate_for_iteration(ledger, gate_unit_id, deps)
        return appended

    return _with_locked_ledger(repo_root, run_id, mutate)


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/ledger.sh routes through this). $ARGUMENTS-safe: all parsing
# is positional here, never string-interpolated into shell.


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: ledger.py <subcommand> ...\n")
        return 2
    cmd = argv[0]
    try:
        if cmd == "read":
            repo, run = argv[1], argv[2]
            json.dump(read_ledger(repo, run), sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        if cmd == "path":
            print(ledger_path(argv[1], argv[2]))
            return 0
        if cmd == "transition":
            repo, run, unit, state = argv[1], argv[2], argv[3], argv[4]
            transition(repo, run, unit, state)
            return 0
        if cmd == "is-orphaned":
            repo, run = argv[1], argv[2]
            print("true" if is_orphaned(read_ledger(repo, run)) else "false")
            return 0
        sys.stderr.write(f"ledger.py: unknown subcommand {cmd!r}\n")
        return 2
    except LedgerError as e:
        sys.stderr.write(f"ledger.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"ledger.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
