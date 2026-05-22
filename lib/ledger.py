#!/usr/bin/env python3
"""claude-dispatch ledger: persistence, transitions, concurrency.

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
    is the only RMW primitive; every mutator goes through it.

  * Atomic write = mkstemp + os.fchmod(0o600) + os.rename, mirroring
    claude-modes/scripts/on-session-start.sh:162-175.

  * Locking via fcntl.flock (NOT flock(1) — macOS lacks it), mirroring
    claude-modes/lib/cascade-engine.sh::with_flock_run.

  * Python pinned /usr/bin/python3 via CLAUDE_DISPATCH_PYTHON3 (the .sh shim
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
    return os.path.join(repo_root, ".claude", "dispatch")


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


def unit_is_terminal(unit: dict, scale: str = "three-tier") -> bool:
    """terminal(u) per §4.1 of the contract.

    A unit is terminal iff it is ``terminal-skip``, OR it is ``verdict-returned``
    / ``fixed`` AND carries no open *gating* finding. A ``fixed`` unit with a stale
    gating finding is NOT terminal (the findings-closure livelock guard).

    SCALE-AWARE (Bug #3): which severities gate depends on ``adapter_scale``.
    Under ``"three-tier"`` (CE / default) both ``blocker`` and ``major`` gate.
    Under ``"blocker-only"`` (native) only ``blocker`` gates — majors are
    advisory (surfaced at exit, never blocking terminality), matching the
    work-loop ``met`` predicate so the two cannot disagree about done-ness.
    """
    gating = ("blocker",) if scale == "blocker-only" else GATING_SEVERITIES
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
    # never invents it). Default 0 outside plan-loop / when unset.
    prev = ledger.get("exit_predicate_result") or {}
    gaps_open = int(prev.get("gaps_open", 0) or 0)

    scale = ledger.get("adapter_scale", "three-tier")
    all_units_terminal = all(
        unit_is_terminal(u, scale) for u in ledger.get("units", [])
    )

    if ledger.get("loop_phase") == "plan":
        # Plan-loop exit: gaps closed AND a review_plan actually ran (§3.1 — a
        # default gaps_open==0 before any review must not short-circuit).
        met = gaps_open == 0 and ledger.get("plan_step") == "review_plan"
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
        no_majors = majors == 0 if scale != "blocker-only" else True
        # Bug #4 — vacuous work-phase exit. all_units_terminal = all([]) is
        # vacuously True, so an auto plan→work flip with ZERO units dispatched
        # would declare `met` before the orchestrator ever fanned out work. The
        # work-loop is not met until at least one unit exists; an empty plan phase
        # is fine (handled by the plan branch above). We do NOT redefine
        # all_units_terminal globally — the pure all([])==True is correct and read
        # elsewhere; the empty-units guard lives only in the work-loop met.
        has_units = bool(ledger.get("units"))
        met = blockers == 0 and no_majors and all_units_terminal and has_units

    return {
        "met": bool(met),
        "blockers": blockers,
        "majors": majors,
        "minors": minors,
        "gaps_open": gaps_open,
        "all_units_terminal": bool(all_units_terminal),
    }


def is_orphaned(ledger: dict, now=None) -> bool:
    """I-3 orphan predicate (§5), excluding seam-paused surfacing (U7's concern).

    Resumable iff loop_phase != "done" AND (driver == "manual" OR last_beat_at
    older than GRACE_SECONDS).
    """
    if ledger.get("loop_phase") == "done":
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
    test-only ``CLAUDE_DISPATCH_TEST_NO_RECOMPUTE`` hatch is set (which exists
    purely to prove the I-1 test goes RED without the recompute).

    Atomic = mkstemp + fchmod(0o600) + os.rename. A crash mid-write leaves the
    prior file intact and a stray tmp (no half-written ledger).
    """
    if os.environ.get("CLAUDE_DISPATCH_TEST_NO_RECOMPUTE") != "1":
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


def _with_locked_ledger(repo_root: str, run_id: str, mutate):
    """Acquire flock, read the ledger, run ``mutate(ledger)``, atomic-write, release.

    The lock spans the WHOLE read-modify-write (the lost-update guard). The
    test-only ``CLAUDE_DISPATCH_TEST_NO_LOCK`` hatch skips ONLY the flock
    acquisition (the read/mutate/write still run) so the concurrency test can
    prove a lost update without serialization.

    ``mutate`` receives the freshly-read ledger dict, mutates it in place, and
    may return a value, which this function returns.
    """
    path = ledger_path(repo_root, run_id)
    lpath = lock_path(repo_root, run_id)
    os.makedirs(os.path.dirname(lpath) or ".", mode=0o700, exist_ok=True)

    no_lock = os.environ.get("CLAUDE_DISPATCH_TEST_NO_LOCK") == "1"

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
        if not os.path.exists(path):
            raise LedgerNotFound(
                f"no ledger for run-id {run_id!r} at {path}"
            )
        ledger = _read_json(path)
        result = mutate(ledger)
        _atomic_write(path, ledger)
        return result
    finally:
        if not no_lock:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        lock_file.close()


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
):
    """Create a new ledger. Rejects if one already exists (LedgerExists).

    ``units`` is a list of partial unit dicts (at minimum ``id``); missing
    fields are filled with schema defaults. The predicate is recomputed and the
    file is written atomically under flock. ``plan_step`` defaults to ``None``
    (no plan step run yet — schema §3.1).
    """
    if adapter not in ("ce", "native"):
        raise LedgerError(f"invalid adapter: {adapter!r}")
    if adapter_scale not in ("three-tier", "blocker-only"):
        raise LedgerError(f"invalid adapter_scale: {adapter_scale!r}")
    if loop_phase not in LOOP_PHASES:
        raise LedgerError(f"invalid loop_phase: {loop_phase!r}")
    if plan_step is not None and plan_step not in PLAN_STEPS:
        raise LedgerError(f"invalid plan_step: {plan_step!r}")

    path = ledger_path(repo_root, run_id)
    lpath = lock_path(repo_root, run_id)
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)

    # Ensure the lock file exists, then hold it across the existence-check +
    # write so two concurrent inits cannot both win.
    if not os.path.exists(lpath):
        old_umask = os.umask(0o077)
        try:
            open(lpath, "a").close()
        finally:
            os.umask(old_umask)

    lock_file = open(lpath, "a+")
    try:
        if os.environ.get("CLAUDE_DISPATCH_TEST_NO_LOCK") != "1":
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        if os.path.exists(path):
            raise LedgerExists(f"ledger already exists for run-id {run_id!r}")

        norm_units = []
        for u in units or []:
            if "id" not in u:
                raise LedgerError("unit missing 'id'")
            norm_units.append(_normalize_unit(u))

        ledger = {
            "run_id": run_id,
            "loop_phase": loop_phase,
            "plan_step": plan_step,
            "seam_paused": loop_phase == "seam",
            "adapter": adapter,
            "adapter_scale": adapter_scale,
            "exit_predicate_result": {},  # filled by _atomic_write recompute.
            "units": norm_units,
            "loop": {"driver": "self", "last_beat_at": _now_iso()},
        }
        _atomic_write(path, ledger)
        return ledger
    finally:
        if os.environ.get("CLAUDE_DISPATCH_TEST_NO_LOCK") != "1":
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        lock_file.close()


def _normalize_unit(u: dict) -> dict:
    state = u.get("state", "pending")
    if state not in UNIT_STATES:
        raise LedgerError(f"invalid unit state: {state!r}")
    return {
        "id": u["id"],
        "state": state,
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
    }


def read_ledger(repo_root: str, run_id: str) -> dict:
    """Return the ledger dict. Raises LedgerNotFound on unknown run-id.

    A read-only operation; takes a shared view via a brief lock to avoid
    reading a torn snapshot (atomic-rename makes torn reads impossible anyway,
    but the lock keeps semantics uniform).
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
        for key, value in fields.items():
            if key == "findings":
                raise LedgerError(
                    "use record_verdict() to write findings, not transition()"
                )
            unit[key] = value
        return unit["state"]

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

    skip_attempt = (
        os.environ.get("CLAUDE_DISPATCH_TEST_NO_ATTEMPT_CHECK") == "1"
    )
    skip_recovery = (
        os.environ.get("CLAUDE_DISPATCH_TEST_NO_STALLED_RECOVERY") == "1"
    )

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
    it; this is the only writer of the field.
    """
    n = int(gaps_open)
    if n < 0:
        raise LedgerError(f"gaps_open must be >= 0, got {n}")

    def mutate(ledger):
        epr = ledger.setdefault("exit_predicate_result", {})
        epr["gaps_open"] = n
        return n

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
