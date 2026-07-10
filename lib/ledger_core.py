#!/usr/bin/env python3
"""auto ledger core: constants, errors, paths, pure predicate logic, primitives.

The foundation layer of the ledger surface (see lib/ledger.py for the facade
that re-exports the whole surface, and docs/contracts/ledger-schema.md for the
authoritative spec — if they disagree, the contract wins and this file is the
bug). Contains the data that everything else depends on: module constants, the
error hierarchy, slug/path helpers, time helpers, and the atomic-write + flock
primitives. The PURE predicate logic (``recompute_predicate`` and its helpers,
``unit_is_terminal``, ``is_orphaned``) was extracted to ``lib/ledger_predicate.py``
(U16) to keep this file under the size budget; ``_atomic_write`` reaches it via
the deferred ``_lazy_load`` idiom, so this file still imports NO sibling ledger
module at top level — it is the bottom of the acyclic DAG (core ← mutators ←
emitters ← facade).

Design notes (the load-bearing correctness rules):

  * I-1 (atomic predicate freshness) is enforced STRUCTURALLY: there is exactly
    ONE serialization chokepoint, ``_atomic_write``, which ALWAYS recomputes
    ``exit_predicate_result`` (including ``all_units_terminal``) immediately
    before writing. No public mutator bypasses it. Therefore every writer that
    routes a mutation through this module inherits freshness for free.

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
# v0.3.0 H / API-R3-2 → v0.3.1 B11: canonical exit_reason.kind enum.
# set_exit_reason writes ledger["exit_reason"]["kind"] from one of these; tick.py
# spells intent as `ledger.ExitReason.RECIPE_BUG` rather than a string literal
# (which would create a divergent-literal class the prose claims is a fixed enum
# but the code only enforces by convention). StrEnum: members ARE strings, so
# `ExitReason.RECIPE_BUG == "recipe-bug"` is True and JSON-serialization round-
# trips. Membership check (`kind in ExitReason`) replaces H's manual KINDS tuple
# — one canonical surface instead of three top-level names + a tuple.
#
#   ITERATION_CHECK_FAILED → an unexpected raise from advance_iteration_loop
#     (typically a malformed iteration block or gate verdict).
#   RECIPE_BUG → a LedgerError subclass (UnknownUnit, InvalidTransition,
#     StaleVerdict) escaping the iteration check, which signals the recipe's
#     units[] / phase_transitions are mis-shaped relative to what the engine
#     reached for.
#
# Both reasons drive /auto-status's exit_reason render and the harness
# stop-intent's reason field.
from enum import Enum


# `str, Enum` (the pre-3.11 portable equivalent of StrEnum — Python 3.9 is the
# auto runtime's actual floor, per `#!/usr/bin/env python3` on macOS which
# resolves to 3.9). Members ARE strings via the str mixin:
# `ExitReason.RECIPE_BUG == "recipe-bug"` is True; JSON-serializes as the
# value when `default=str` or via explicit `.value`. The one wrinkle vs
# native StrEnum: `str(ExitReason.RECIPE_BUG)` gives `"ExitReason.RECIPE_BUG"`
# (the repr), so set_exit_reason persists `kind.value` explicitly to keep
# the on-disk shape backwards-compatible with v0.3.0 (where kind was a
# plain string like "recipe-bug").
class ExitReason(str, Enum):
    ITERATION_CHECK_FAILED = "iteration-check-failed"
    RECIPE_BUG = "recipe-bug"
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
#
# The agent-driven force-skip edges (`pending -> terminal-skip`,
# `verdict-returned -> terminal-skip`) are deliberately NOT here — see
# `ledger_mutators._FORCE_SKIP_SOURCE_STATES`. Putting them in this table would
# let the findings-free, reason-free `transition()` reach `terminal-skip`,
# silently bypassing the mandatory skip-reason (R20). Same asymmetry, and for the
# same reason, as `_VERDICT_WRITABLE_STATES`: a wider edge set owned by the one
# mutator that enforces the extra precondition.
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
# THIS module, so ledger_core.py importing _bootstrap would be a cycle. Same
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
# This module defers loading sibling lib/ modules (iteration, phase-grammar) into
# function bodies because the ledger surface is imported from many sites, some
# before sys.path is set up for sibling lib modules. The dedup is one local helper
# that does the deferred load — still no top-level import, but ONE function body
# instead of four.


def _lazy_load(name: str):
    """Load a sibling lib/ module from within a function body.

    Mirrors the sys.path-prepend + `_bootstrap.load_lib_module` idiom that the
    prior call sites each open-coded (RIP `_compute_iteration_pending`,
    `is_orphaned`, `set_verdict_decision`, `set_bound_override`). Keeping the
    load deferred — rather than promoting to a module-top import — preserves
    the load-order discipline the ledger surface needs (it is imported from many
    sites, some before sys.path is set up for sibling lib modules). The dedup is
    purely about killing the per-site boilerplate.

    Cannot live in ``_bootstrap`` itself because ``_bootstrap.load_ledger()``
    loads the ledger facade — importing ``_bootstrap`` at module top would
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


def now_iso() -> str:
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def parse_iso(value):
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
# Pure predicate logic (I-2 / §4) — extracted to lib/ledger_predicate.py (U16).
#
# The predicate evaluator (``recompute_predicate`` + its B7 helpers,
# ``gating_severities``, ``unit_is_terminal``, ``is_orphaned``) moved out of this
# file to keep it under the size budget. This module reaches back to it ONLY via
# ``_lazy_load("ledger_predicate")`` inside ``_atomic_write`` (the deferred,
# cycle-safe edge — the same idiom used for ``iteration`` / ``phase-grammar``);
# there is NO top-level import of ledger_predicate here, so the core stays the
# acyclic DAG root. The facade ``lib/ledger.py`` re-exports the predicate names.


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
        # Predicate evaluator lives in lib/ledger_predicate.py (U16). Reach it via
        # the deferred, cycle-safe lazy-load (same idiom as iteration /
        # phase-grammar) so this file keeps NO top-level ledger sibling import and
        # stays the acyclic DAG root.
        ledger_predicate = _lazy_load("ledger_predicate")
        ledger["exit_predicate_result"] = ledger_predicate.recompute_predicate(ledger)

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
# Public API (ledger create / read).


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
    goal_intent=None,
    driving_session_id=None,
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

    # v0.4.0 goal_intent (KTD-2): one-line user-facing intent sentence, frozen
    # at init time. Acceptable shapes: None (legacy / unknown), or a string
    # (typically derived from plan title for /auto <plan>, from hypothesis for
    # bare /auto, from input for freeform). We do NOT trim or normalize — the
    # caller owns the wording — but we reject non-string non-None to keep the
    # on-disk shape clean.
    if goal_intent is not None and not isinstance(goal_intent, str):
        raise LedgerError(f"goal_intent must be a string or None: {goal_intent!r}")

    # v0.6.0 U5 (KTD-5, additive): the DRIVING session_id, recorded at arm time so
    # the advisor-gate hooks match a question/action to this run by session-id
    # equality. None on legacy/non-conversation init (gate reads absent → fail-open).
    if driving_session_id is not None and not isinstance(driving_session_id, str):
        raise LedgerError(
            f"driving_session_id must be a string or None: {driving_session_id!r}"
        )

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
        # iterate_template (lib/unit_emitters.py) computes the next id as
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
            # v0.4.0 KTD-2 (additive): the one-line user-facing intent sentence
            # frozen at init time. Derived by the caller — plan title for
            # /auto <plan>, hypothesis summary for bare /auto, the input for
            # freeform. None on a legacy or recipe-unaware init. The
            # ambiguous-runs hypothesis surfaces this verbatim when listing
            # in-flight runs so an operator picking between two runs sees what
            # each was started for, not just a slug.
            "goal_intent": goal_intent,
            # v0.6.0 U5 (KTD-5): driving session_id (lib/auto.py reads
            # CLAUDE_CODE_SESSION_ID, not-a-child asserted). Hooks read it
            # top-level (run-identity, not liveness) + match on equality. Always
            # present at init (None included); the mutator's clear path pops it.
            "driving_session_id": driving_session_id,
            "exit_predicate_result": {},  # filled by _atomic_write recompute.
            "units": norm_units,
            "loop": {"driver": "self", "last_beat_at": now_iso()},
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
    nu = {
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
        # R20: why this unit was force-skipped. None for every unit that was not
        # skipped by an agent. Additive / backward-compatible: an old ledger
        # without the key normalizes to None.
        "skip_reason": u.get("skip_reason"),
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
    # v0.7.0 (verification-gate-hardening, KTD-1): preserve a recipe gate unit's
    # `verification` block — CONDITIONALLY, only when the source carries it. NOT
    # defaulted like `dispatch_context`/`attempt`: an unconditional copy would
    # stamp `[]` onto every legacy unit and change their on-disk shape. This is
    # the only unit-rebuild point, so preserving here is what lets the runtime
    # gate (resolve_gate_verification) see the criteria on a real run.
    if u.get("verification"):
        nu["verification"] = list(u["verification"])
    return nu


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
