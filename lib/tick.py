#!/usr/bin/env python3
"""auto U4: one ScheduleWakeup-paced advance of the ledger.

A *tick* is the unit of execution. Each tick does exactly ONE smallest-useful
advance of the loop, then re-arms its own successor via `ScheduleWakeup`. The
tick reads ALL loop state from the disk ledger (the durable source of truth) —
it runs in a subprocess and treats conversation context as irrelevant, so it is
safe under the non-stateless re-injection of a `ScheduleWakeup`-fired tick.

THE RE-ARM BOUNDARY (read this — it is the load-bearing seam):

    `ScheduleWakeup` is a MODEL TOOL, not a CLI. tick.py CANNOT call it.
    Instead, tick.py COMPUTES the re-arm intent and emits it on stdout as a
    JSON object:

        {"action": "rearm",  "delay": 60, "prompt": "/auto-tick <run>", ...}
        {"action": "stop",   "reason": "predicate-met" | "seam-pause", ...}
        {"action": "noop",   "reason": "lock-held-by-live-tick"}

    The shell/driver layer (the model driving the tick) reads this and, when
    action == "rearm", issues the actual `ScheduleWakeup(delay, prompt)` tool
    call. Do NOT look for a ScheduleWakeup binary — there isn't one.

The tick NEVER dispatches (the orchestrator owns `pending → dispatched`) and
NEVER writes verdicts (each background agent self-writes its own `findings[]`).
The tick only:
  * reads the ledger,
  * detects stalled units and halts them + their transitive dependents while
    advancing independent siblings (the parallel-fan-out promise),
  * does ONE advance (plan-loop: the adapter's next_plan_step; work-loop: apply
    ONE fix from a converged verdict) inside a try/except,
  * writes the ledger atomically via ledger.py (I-1 recompute happens inside
    ledger.py's single write chokepoint) and stamps loop.last_beat_at,
  * computes the re-arm intent.

Crash-safety: the atomic ledger write (ledger.py) and the re-arm output are
ordered so that a crash after the write but before the re-arm leaves a
*consistent* ledger whose missing successor is exactly what U7's orphan check
catches (→ manual /auto-resume). We persist BEFORE we signal re-arm (R10).
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import importlib.util
import json
import os
import sys
import time

# ──────────────────────────────────────────────────────────────────────────
# Import the canonical ledger module by file path (no package install). We do
# NOT reimplement any ledger logic — every mutation routes through ledger.py so
# I-1 (atomic predicate freshness) is inherited for free.

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    is_iteration_disabled,
    load_ledger,
    load_lib_module,
    test_hatch_enabled,
)

ledger = load_ledger()
# The ONE phase-decision module (U5). All phase routing reads through it; the
# AST lint forbids the raw "loop_phase" literal here so a divergent comparison
# can't sneak back in.
phase_grammar = load_lib_module("phase-grammar")
# v0.3.0 U1: the ONE iteration-decision module. Every read of the gate unit's
# verdict.decision field routes through `iteration.read_decision` /
# `iteration.evaluate_decision`; the AST lint (tests/unit/iteration-ast-lint
# .test.sh) forbids the raw "decision" string literal anywhere in this file.
iteration = load_lib_module("iteration")
# The emitter registry (U5b/v0.2.0): the seam-handler resolves a recipe's
# declared emitter name through emitters.resolve() and hands the function to
# ledger.transition_and_emit. No hyphen in the module name, so a plain import
# works once _LIB_DIR is on sys.path.
import emitters  # noqa: E402

# Re-arm delay between ticks. ScheduleWakeup clamps to [60, 3600]s; we sit at
# the floor so the smallest-useful advance paces as fast as the substrate
# allows. The driver MAY override via --delay (e.g. coarsen under pressure).
DEFAULT_REARM_DELAY_SECONDS = 60


# ──────────────────────────────────────────────────────────────────────────
# Errors.


class TickError(Exception):
    """Base class for tick errors."""


# ──────────────────────────────────────────────────────────────────────────
# Tick-level double-drive lock (DISTINCT from ledger.py's internal RMW lock).
#
# ledger.py's flock guards individual read-modify-write operations (the
# lost-update guard). THIS lock is the engine's "another live tick is already
# driving this run" guard: held for the WHOLE tick, acquired NON-BLOCKING, so a
# second concurrent tick returns a no-op instead of queueing behind the first.
# It is process-bound — released on exit (clean OR crash), so a cleanly-exited
# seam/predicate-met tick leaves NO stale wedge.


def _tick_lock_path(repo_root: str, run_id: str) -> str:
    # Sibling of the ledger / RMW-lock files; keyed by the same slug.
    lpath = ledger.lock_path(repo_root, run_id)
    return lpath[: -len(".lock")] + ".tick.lock"


class _TickLockHeld(Exception):
    """Raised when another live tick already holds the run's tick lock."""


class _tick_lock:
    """Context manager: non-blocking exclusive flock for the duration of a tick.

    Honors CLAUDE_AUTO_TEST_NO_TICK_LOCK=1 (test-only) to skip acquisition,
    so a deliberate-fail test can prove the double-drive guard is real. The
    hatch is FENCED: only honored when CLAUDE_AUTO_TEST_HARNESS=1 is ALSO set
    (sentinel exported by tests/run.sh — task #31). A stray production export
    of NO_TICK_LOCK alone has no effect.
    """

    def __init__(self, repo_root: str, run_id: str):
        self._path = _tick_lock_path(repo_root, run_id)
        self._fh = None
        self._no_lock = test_hatch_enabled("CLAUDE_AUTO_TEST_NO_TICK_LOCK")

    def __enter__(self):
        os.makedirs(os.path.dirname(self._path) or ".", mode=0o700, exist_ok=True)
        if not os.path.exists(self._path):
            old_umask = os.umask(0o077)
            try:
                open(self._path, "a").close()
            finally:
                os.umask(old_umask)
        self._fh = open(self._path, "a+")
        if not self._no_lock:
            try:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self._fh.close()
                self._fh = None
                raise _TickLockHeld(
                    f"another live tick holds the lock for run {run_id_of(self._path)!r}"
                )
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._fh is not None:
            try:
                if not self._no_lock:
                    fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            self._fh.close()
            self._fh = None
        return False


def run_id_of(tick_lock_path: str) -> str:
    base = os.path.basename(tick_lock_path)
    return base[: -len(".tick.lock")] if base.endswith(".tick.lock") else base


# ──────────────────────────────────────────────────────────────────────────
# Adapter boundary (six-op interface, per the plan / U6a contract).
#
# For U4 the adapter call boundary is STUBBABLE: an adapter is any object
# exposing the ops the tick needs. The tick only ever calls:
#   * next_plan_step(ledger) -> "plan" | "deepen" | "review_plan" | "done"
#   * plan(scope) / deepen(plan) / review_plan(plan)   (the chosen step)
# Work-loop ticks apply a fix as a pure ledger state transition and do NOT need
# an adapter op (the fix's *content* is produced out-of-band; the tick records
# only the state change — verdict-returned → fixed).
#
# U6b ships the real `native` / `ce` adapters. U4 resolves an adapter via
# `resolve_adapter(name)`; a test injects its own object through `adapter=`.

_PLAN_STEP_OPS = ("plan", "deepen", "review_plan")


def resolve_adapter(name: str):
    """Resolve a named adapter to a callable object.

    U6b provides real adapters (`lib/adapter-native.py`, `lib/adapter-ce.py`).
    Until then, a missing adapter module raises a clean TickError — the tick's
    try/except converts that into a recorded `last_error` + `stalled` rather
    than crashing the run (so a half-built engine fails legibly, not silently).
    """
    candidates = {
        "native": "adapter-native.py",
        "ce": "adapter-ce.py",
    }
    fname = candidates.get(name)
    if fname is None:
        raise TickError(f"unknown adapter: {name!r}")
    apath = os.path.join(_LIB_DIR, fname)
    if not os.path.exists(apath):
        raise TickError(
            f"adapter {name!r} not yet implemented (expected {fname}; U6b provides it)"
        )
    spec = importlib.util.spec_from_file_location(f"adapter_{name}", apath)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Convention: the adapter module exposes a module-level `Adapter` object or
    # the ops directly. Prefer an `Adapter` factory if present.
    if hasattr(module, "Adapter"):
        return module.Adapter()
    return module


# ──────────────────────────────────────────────────────────────────────────
# Stall detection + transitive halt (the parallel-fan-out promise).


def _seconds_since(iso_value, now) -> float:
    parsed = ledger._parse_iso(iso_value)
    if parsed is None:
        return -1.0
    return (now - parsed).total_seconds()


def _transitive_dependents(units, root_ids):
    """All units (transitively) depending on any id in `root_ids`, plus the roots."""
    halted = set(root_ids)
    changed = True
    while changed:
        changed = False
        for u in units:
            uid = u.get("id")
            if uid in halted:
                continue
            deps = u.get("depends_on") or []
            if any(d in halted for d in deps):
                halted.add(uid)
                changed = True
    return halted


def detect_and_halt_stalled(repo_root, run_id, ledger_dict, now):
    """Mark dispatched-past-threshold units `stalled`; return the halted-id set.

    A unit is stalled if it is `dispatched` and has been so for longer than its
    `stall_threshold_seconds` with no verdict. We mark it via ledger.transition
    (so the write goes through the I-1 chokepoint) with last_error preserved as
    null (a plain timeout; an adapter raise sets last_error elsewhere). The
    stalled unit AND its transitive dependents are halted for this tick;
    independent siblings still advance.
    """
    newly_stalled = []
    for u in ledger_dict.get("units", []):
        if u.get("state") != "dispatched":
            continue
        threshold = int(
            u.get("stall_threshold_seconds")
            or ledger.DEFAULT_STALL_THRESHOLD_SECONDS
        )
        age = _seconds_since(u.get("dispatched_at"), now)
        if age >= 0 and age > threshold:
            newly_stalled.append(u.get("id"))

    for uid in newly_stalled:
        # Plain timeout stall: last_error stays null (vs an adapter-raise stall,
        # which records {call, message, at}). See record_stall_error.
        ledger.transition(repo_root, run_id, uid, "stalled")

    # Compute the full halted set (newly + already-stalled) and their dependents.
    fresh = ledger.read_ledger(repo_root, run_id)
    stalled_ids = [
        u.get("id") for u in fresh.get("units", []) if u.get("state") == "stalled"
    ]
    halted = _transitive_dependents(fresh.get("units", []), stalled_ids)
    return fresh, sorted(halted), newly_stalled


# ──────────────────────────────────────────────────────────────────────────
# Error recording (atomic, via ledger.py).


def record_stall_error(repo_root, run_id, unit_id, call, message, now_iso):
    """On an adapter raise mid-advance: mark the unit `stalled` AND record
    last_error = {call, message, at}, in one grammar-checked atomic write.

    The unit must be `dispatched` for the dispatched → stalled edge to be legal.
    If it is not dispatched (e.g. a plan-step raise with no unit in flight), we
    cannot use the dispatched→stalled edge, so we record the error on the run by
    flipping the loop to manual and surfacing — the caller decides. We return a
    flag indicating whether a unit-level stall was recorded.
    """
    fresh = ledger.read_ledger(repo_root, run_id)
    unit = None
    for u in fresh.get("units", []):
        if u.get("id") == unit_id:
            unit = u
            break
    err = {"call": call, "message": message, "at": now_iso}
    if unit is not None and unit.get("state") == "dispatched":
        ledger.transition(
            repo_root, run_id, unit_id, "stalled", last_error=err
        )
        return True
    return False


# ──────────────────────────────────────────────────────────────────────────
# The advance.


def _ready_fix_unit(ledger_dict, halted_ids):
    """Pick ONE unit whose latest verdict is converged and needs a fix applied.

    A fix-due unit is `verdict-returned` with an open GATING finding and is NOT
    in the halted set. The tick applies the fix as a state transition only
    (verdict-returned → fixed); it does NOT touch findings (R8 — closure only via
    a fresh verdict). Returns the unit id or None.

    SCALE-AWARE (Bug #3): which severities are fix-due is decided by the SINGLE
    helper ``ledger.gating_severities(scale)``, read off this ledger's
    ``adapter_scale``. Hardcoding ``GATING_SEVERITIES`` here would livelock a
    blocker-only run: the tick would forever try to fix a major-only unit that
    re-reviews to the same advisory major, fix→re-enqueue→re-review forever, while
    the predicate already reports met. The fix-class and the terminality class
    MUST share the gating decision so they agree on which units still need work.
    """
    gating = ledger.gating_severities(ledger_dict.get("adapter_scale", "three-tier"))
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "verdict-returned":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in gating:
                return u.get("id")
    return None


def _ready_reenqueue_unit(ledger_dict, halted_ids):
    """Pick ONE `fixed` unit whose STALE verdict still shows a GATING finding.

    After a fix is applied (verdict-returned → fixed) the findings remain stale
    (R8 — only a fresh verdict clears them), so the unit is NOT yet terminal.
    The tick re-enqueues it (fixed → pending) so the orchestrator re-dispatches
    it for a fresh review. Skips halted units. Returns the unit id or None.

    SCALE-AWARE (Bug #3): same single-helper gating decision as ``_ready_fix_unit``
    and ``unit_is_terminal`` — a blocker-only run never re-enqueues a major-only
    fixed unit (majors are advisory), so it cannot churn fix→re-enqueue forever.
    """
    gating = ledger.gating_severities(ledger_dict.get("adapter_scale", "three-tier"))
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "fixed":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in gating:
                return u.get("id")
    return None


def advance_work_loop(repo_root, run_id, ledger_dict, halted_ids):
    """Work-loop advance: apply ONE fix, OR re-enqueue ONE fixed-stale unit.

    Returns a dict describing what advanced (for the tick result). The tick
    NEVER dispatches and NEVER writes verdicts here. The TWO smallest-useful
    work-loop advances the tick owns (state grammar §3 / closure loop R8):

      1. verdict-returned + gating finding  → fixed   (apply ONE fix)
      2. fixed + STALE gating finding       → pending (re-enqueue for re-review)

    Fix-due takes PRIORITY over re-enqueue-due so a single tick on a fresh
    verdict-returned+blocker unit applies the fix (one step), and the NEXT tick
    re-enqueues that fixed-with-stale-blocker unit. This MIRRORS the plan_step
    advance: one persisted advance per fresh-process tick. Without step 2 the
    loop livelocks at `fixed` (the stale blocker keeps all_units_terminal false
    forever) — the closure loop is unreachable.

    The fixed→pending re-enqueue honors the test-only
    ``CLAUDE_AUTO_TEST_NO_REENQUEUE`` hatch (a deliberate-fail control: with
    it set the work-loop closure test goes RED — livelocks at `fixed`). The
    hatch is FENCED via ``test_hatch_enabled`` (task #31): only honored
    when ``CLAUDE_AUTO_TEST_HARNESS=1`` is ALSO set, so a stray production
    export of NO_REENQUEUE alone has no effect.
    """
    fix_uid = _ready_fix_unit(ledger_dict, halted_ids)
    if fix_uid is not None:
        ledger.transition(repo_root, run_id, fix_uid, "fixed")
        return {"advanced": "fix-applied", "unit": fix_uid}
    if not test_hatch_enabled("CLAUDE_AUTO_TEST_NO_REENQUEUE"):
        reenq_uid = _ready_reenqueue_unit(ledger_dict, halted_ids)
        if reenq_uid is not None:
            ledger.transition(repo_root, run_id, reenq_uid, "pending")
            return {"advanced": "re-enqueued", "unit": reenq_uid}
    return {"advanced": "none", "reason": "no-fix-due"}


def _persist_enumerated_units(repo_root, run_id, enumerated):
    """Persist the plan's enumerated work units onto the plan unit (U6 producer).

    Targets the plan-phase unit being advanced. For A1 (single plan unit) and the
    per-tick serialized A2 advance, that is the lone plan unit currently at
    plan-done; we resolve it from the fresh ledger (the unit whose phase is
    'plan'). If there are multiple plan units (A2), the active one is the one the
    round-robin advanced this tick — for the V1 testable slice we target the first
    plan-phase unit lacking enumerated_units, which the serialized one-per-tick
    advance makes unambiguous. Idempotent-safe: re-persist overwrites.
    """
    led = ledger.read_ledger(repo_root, run_id)
    plan_units = [u for u in led.get("units", []) if u.get("phase") == "plan"]
    if not plan_units:
        return
    target = next(
        (u for u in plan_units
         if not (u.get("dispatch_context") or {}).get("enumerated_units")),
        plan_units[0],
    )
    ledger.set_enumerated_units(repo_root, run_id, target["id"], enumerated)


def advance_plan_loop(repo_root, run_id, ledger_dict, adapter):
    """Plan-loop advance: ask the adapter for the next step and call that ONE
    step. The ADAPTER owns plan-step sequencing — the engine never picks it.

    Returns (result_dict, raised_call_or_None). On an adapter raise the caller
    records the error; we surface which op raised so last_error.call is precise.

    CRITICAL (anti-livelock — schema §3.1): after the adapter op returns
    SUCCESSFULLY, we PERSIST the executed step to the ledger via
    ``set_loop(plan_step=step)``. ``next_plan_step`` is pure over the ledger and
    each tick is a fresh process reading ALL state from disk; without this write
    the next tick reads ``plan_step == null``, the adapter returns ``"plan"``,
    and the plan-loop re-plans forever. The persist is AFTER ``op(...)`` (and
    thus only on success): a step that raised is recorded as a stall by the
    caller's try/except, never as a completed step.

    PLAN→exit (schema §3.1 / adapter-contract §4.1, §5): when ``next_plan_step``
    returns ``"done"`` the plan sequence is complete (gaps closed). The plan-loop
    must NOT re-arm on ``plan``; the caller (``_maybe_seam``) routes the met plan
    predicate to seam (manual) or work (auto). We surface ``{"advanced":
    "plan-done"}`` so the caller knows the sequence finished this tick.

    GAPS persist (gap-write, adapter-contract §2.2): when the executed step is
    ``review_plan``, its return is the gap-set; the engine reads ONLY its length
    and persists ``gaps_open = len(gap_set)`` via ``ledger.set_gaps_open`` (the
    I-1 atomic write path). The gap-set arrives either as a bare list (a direct
    return) OR inside the live PREPARE envelope (a dict) under the canonical
    ``gap_set`` key (§2.2), which the model fills out-of-band before the engine
    reads. We extract from whichever shape carries the array; a bare envelope
    that has no ``gap_set`` yet leaves ``gaps_open`` untouched (no default-0
    short-circuit). This is what makes plan-met depend on a REAL review having
    reported its gaps, not the default — closing the deepen-refinement loop.
    """
    step = adapter.next_plan_step(ledger_dict)
    if step == "done":
        # PLAN-DONE: the plan sequence finished — enumerate this plan's work units
        # via the v0.2.0 adapter op and PERSIST them onto the plan unit's
        # dispatch_context.enumerated_units, so the phase-transition emitter (U5b)
        # can read them when it emits work units (resolves F4 — the producer).
        # enumerate_plan_units is prepare-only: it may return a bare list (a
        # synchronous/test adapter) OR a PREPARE envelope the model fills with the
        # units under the canonical "units" key. We persist whichever concrete list
        # is available; a freshly-prepared envelope with no "units" key leaves the
        # field untouched (same no-premature-default discipline as gaps_open).
        enum_op = getattr(adapter, "enumerate_plan_units", None)
        if callable(enum_op):
            enum_result = enum_op(ledger_dict)
            enumerated = None
            if isinstance(enum_result, list):
                enumerated = enum_result
            elif isinstance(enum_result, dict) and isinstance(enum_result.get("units"), list):
                enumerated = enum_result["units"]
            if enumerated is not None:
                _persist_enumerated_units(repo_root, run_id, enumerated)
        return {"advanced": "plan-done"}, None
    if step not in _PLAN_STEP_OPS:
        raise TickError(f"adapter returned unknown plan step: {step!r}")
    op = getattr(adapter, step, None)
    if op is None or not callable(op):
        raise TickError(f"adapter missing op {step!r}")
    # The adapter step is the work-bearing call; the caller wraps this in the
    # try/except so a raise becomes a recorded last_error, not a crash.
    result = op(ledger_dict)
    # review_plan returns the gap-set; the engine reads ONLY its length and
    # persists it (adapter-contract §2.2). The gap-set arrives in one of two
    # shapes (Bug #5 — gaps_open was never written from the LIVE adapters, which
    # return a dict envelope, so plan-met fired after a SINGLE review pass and the
    # deepen-refinement loop was unreachable):
    #   * a bare array — direct return (e.g. a test/synchronous adapter); OR
    #   * the live PREPARE envelope (a dict) with the model-filled ``gap_set``
    #     array under the canonical ``gap_set`` key (contract §2.2). The bare
    #     envelope ships WITHOUT ``gap_set``; the model fills it before the engine
    #     reads, so a freshly-prepared envelope with no key leaves gaps_open
    #     untouched (never a default 0 that would short-circuit plan-met).
    gap_set = None
    if isinstance(result, list):
        gap_set = result
    elif isinstance(result, dict) and isinstance(result.get("gap_set"), list):
        gap_set = result["gap_set"]
    if step == "review_plan" and gap_set is not None:
        ledger.set_gaps_open(repo_root, run_id, len(gap_set))
    # Op succeeded — persist the step so the NEXT fresh-process tick advances
    # from it instead of re-reading null and re-planning (the livelock).
    ledger.set_loop(repo_root, run_id, plan_step=step)
    return {"advanced": "plan-step", "step": step}, None


# ──────────────────────────────────────────────────────────────────────────
# Seam handling.


def _is_auto(auto_flag) -> bool:
    """Auto mode: the explicit --auto flag. The tick honors only the flag the
    driver passes; there is no ledger-driven auto marker (the schema has no slot
    for one, and the driver owns the policy). Kept as a named predicate so the
    seam-routing call site reads intentionally."""
    return bool(auto_flag)


# ──────────────────────────────────────────────────────────────────────────
# The tick.


def dispatch_tick(
    repo_root,
    run_id,
    *,
    adapter=None,
    auto=False,
    delay=DEFAULT_REARM_DELAY_SECONDS,
):
    """Perform ONE ScheduleWakeup-paced advance. Returns the re-arm intent dict.

    The returned dict's `action` is one of:
      * "noop"  — another live tick holds the lock (double-drive guard); no
                  ledger mutation happened this tick.
      * "stop"  — the chain ends (predicate met, or a seam pause). The driver
                  does NOT issue a ScheduleWakeup.
      * "rearm" — the driver SHOULD issue ScheduleWakeup(delay, prompt) for the
                  next tick.

    NOTE: this function does NOT call ScheduleWakeup (it is a model tool, not a
    CLI). It only computes the intent; the driver layer issues the tool call.
    """
    try:
        with _tick_lock(repo_root, run_id):
            return _tick_body(
                repo_root, run_id, adapter=adapter, auto=auto, delay=delay
            )
    except _TickLockHeld:
        # Another live tick is driving this run — no-op (the double-drive guard).
        return {"action": "noop", "reason": "lock-held-by-live-tick", "run": run_id}


def _no_emit(ledger_dict, to_phase):
    """v0.3.0 F2: no-op emitter for the iterate path on a recipe that omits
    `iteration.emit_template`. Returns an empty list so `_apply_emit`'s
    `emitter(ledger, to_phase) or []` line treats it as "no new units" —
    `iteration_emit_count` stays unchanged (the counter bumps per emitted
    unit) and `appended` is []. The default `caller_depends_on=None` path in
    `atomic_iterate_step` then computes `gate.depends_on + [] = gate.depends_on`,
    preserving the existing dependency graph; the gate is reset
    (verdict-returned → pending, decision cleared) and `iteration_attempts`
    increments, so the existing siblings re-engage on the next tick.
    """
    return []


def advance_iteration_loop(repo_root, run_id, led):
    """v0.3.0 U4 / KTD §A+§C+§D: the engine-side iteration check.

    Fires in `_tick_body` BEFORE the predicate-met short-circuit at lines
    564-576. Reads the gate unit's effective decision via
    `iteration.evaluate_decision` and routes:

      * No iteration block / no gate_unit / kill-switch enabled → return None.
        Standard flow continues; the predicate-met short-circuit evaluates
        normally.
      * No decision yet (gate hasn't verdicted, or its decision was cleared by
        the most recent reset_for_iteration) → return None. Same path.
      * "advance" → return {"action": "advance"}. The caller falls through; the
        existing predicate-met short-circuit (now suppressed only by
        iteration_pending=True) advances to the terminal "done" state via the
        normal flow.
      * "iterate" under bound → call `ledger.atomic_iterate_step` (one locked
        body: increment + emit + reset). Return {"action": "iterate"}. The
        caller emits a rearm intent so the next tick dispatches the new units.
      * "exit" OR "iterate over bound" → write `bound_override` on the gate
        unit's dispatch_context, then flip the loop to "done" / driver="manual"
        DIRECTLY via set_loop (NOT through advance_to_phase, which would re-
        invoke `judge_winner_to_work_units` and raise on missing winner_unit_id
        — KTD §D / round-2 P0 fix). Return {"action": "stop", "reason":
        "bound-exit", "report": ...}.

    Two safety gates fire BEFORE the decision read (no ledger writes on either
    early-return path — keeps a1/W ticks side-effect-clean):
      1. a1/W early-return: `led.get("iteration")` missing OR `gate_unit` is
         None → return None. No call to `evaluate_decision`.
      2. Kill-switch: `_bootstrap.is_iteration_disabled()` True
         (CLAUDE_AUTO_DISABLE_ITERATION=1) → return None. A REAL operator
         knob, not a test-only hatch: set the env var at runtime to skip the
         iteration check without redeploying — useful for emergency rollback
         of an outcomes-gated recipe. v0.3.0 F5 unfenced this (CRIT-2 + rel-3);
         it used to require the CLAUDE_AUTO_TEST_HARNESS=1 sentinel as well.

    The `new_depends_on` argument to `atomic_iterate_step` is passed as `None`:
    the ledger mutator computes the union of `gate.depends_on + appended` ids
    INSIDE the locked body (lib/ledger.py:1605-1607). Pre-computing here would
    race with the in-locked-body `_apply_emit` counter bump.
    """
    # Gate 1: no iteration declared (a1, W, legacy ledgers). Side-effect-free.
    iter_block = led.get("iteration") or {}
    gate_unit_id = iter_block.get("gate_unit")
    if not gate_unit_id:
        return None
    # Gate 2: kill-switch. Operators can set CLAUDE_AUTO_DISABLE_ITERATION=1
    # to skip the iteration check at runtime — useful for emergency rollback
    # of an outcomes-gated recipe without redeploying. Unfenced in v0.3.0 F5;
    # see _bootstrap.is_iteration_disabled.
    if is_iteration_disabled():
        return None

    eval_result = iteration.evaluate_decision(
        led, gate_unit_id, now_monotonic=time.monotonic()
    )
    effective = eval_result.get("decision_effective")

    if effective is None:
        # Gate hasn't verdicted (or decision was cleared by the most recent
        # reset_for_iteration). Standard flow continues; short-circuit evaluates.
        return None

    if effective == "advance":
        # Caller falls through to standard flow; the predicate-met short-
        # circuit then fires (iteration_pending is now False — the gate said
        # advance, not iterate — so the AND-NOT clause doesn't suppress).
        return {"action": "advance"}

    if effective == "iterate":
        # Under-bound iterate. Drive ONE atomic step (increment + emit +
        # reset) through the composite mutator. new_depends_on=None tells
        # atomic_iterate_step to compute the union of gate.depends_on +
        # appended ids inside its own locked body.
        #
        # v0.3.0 F2 (correctness-emit-template): the recipe validator at
        # lib/recipes.py:380-393 makes `iteration.emit_template` OPTIONAL
        # ("re-engage the gate without spawning new siblings" — e.g. A4's
        # comparator re-comparing the same builders after a clarifying
        # signal). When the recipe omits emit_template, the iterate path
        # must still advance the loop (increment iteration_attempts + reset
        # the gate) WITHOUT emitting new units; the existing units re-
        # engage. We honor that by passing a no-op emitter to
        # atomic_iterate_step: `_apply_emit` calls `emitter(ledger,
        # to_phase) or []`, so returning `[]` cleanly skips emission AND
        # leaves iteration_emit_count unchanged (the counter bumps PER
        # emitted unit). The deps default (`caller_depends_on=None` →
        # `gate.depends_on + [] = gate.depends_on`) preserves the existing
        # dependency graph. Going through atomic_iterate_step (one locked
        # body) preserves the all-or-nothing contract — splitting into two
        # writes (increment then reset) would open a window where a tick
        # could read attempts++ but a still-verdict-returned gate.
        if (led.get("iteration") or {}).get("emit_template"):
            emitter = emitters.iterate_template
        else:
            emitter = _no_emit
        ledger.atomic_iterate_step(
            repo_root,
            run_id,
            gate_unit_id,
            emitter=emitter,
            new_depends_on=None,
        )
        return {"action": "iterate"}

    # effective in ("exit", "iterate"-over-bound). Both shapes: write the
    # bound_override (carries bound_type + original_decision + at) and force
    # the loop to "done" / driver="manual" via set_loop DIRECTLY.
    # advance_to_phase would re-invoke `judge_winner_to_work_units` which
    # raises on missing winner_unit_id (the gate said iterate, not advance, so
    # no winner is set). Skipping advance_to_phase preserves the audit trail
    # in the gate's dispatch_context.bound_override.
    bound_type = eval_result.get("bound_type")
    original = eval_result.get("original_decision") or "iterate"
    if eval_result.get("bound_breached"):
        ledger.set_bound_override(
            repo_root, run_id, gate_unit_id,
            bound_type=bound_type, original_decision=original,
        )
    ledger.set_loop(
        repo_root, run_id, loop_phase="done", driver="manual", beat=True,
    )
    final_led = ledger.read_ledger(repo_root, run_id)
    report = _build_bound_exit_report(final_led, gate_unit_id)
    return {
        "action": "stop",
        "reason": "bound-exit",
        "run": run_id,
        "report": report,
    }


def _build_bound_exit_report(led, gate_unit_id):
    """Build the bound-exit report from the gate unit's dispatch_context.

    Mirrors `_build_report`'s shape but adds the bound_override block + best-
    so-far state per OQ2. The best-so-far is the gate's last
    decision_payload (the payload that accompanied either the last iterate or
    the last advance) — surfaced for operator diagnostics so the
    operator-guidance branch in R9 can name what we tried before bound trip.
    """
    base = _build_report(led)
    gate = next(
        (u for u in led.get("units", []) if u.get("id") == gate_unit_id), None
    )
    dc = (gate or {}).get("dispatch_context") or {}
    base["bound_override"] = dc.get("bound_override")
    base["best_so_far"] = dc.get("decision_payload")
    return base


def _tick_body(repo_root, run_id, *, adapter, auto, delay):
    rearm_prompt = f"/auto-tick {run_id}"
    now = _now_dt()
    now_iso = ledger._now_iso()
    # v0.3.0 / KTD §D (R5 finally): start the active-time clock at the top of
    # _tick_body so the `finally` clause below can accumulate the delta on
    # EVERY return path INCLUDING the except path (crashed-tick deltas land in
    # the ledger). The finally wraps the whole body; release happens inside
    # the tick lock (dispatch_tick owns the lock, _tick_body runs inside).
    t_start = time.monotonic()
    try:
        return _tick_body_inner(
            repo_root, run_id, adapter=adapter, auto=auto, delay=delay,
            rearm_prompt=rearm_prompt, now=now, now_iso=now_iso,
        )
    finally:
        # accumulate_active_time is best-effort: an exception inside it must
        # never bury the real exception/return value. (E.g. a torn ledger
        # during a stalled-write recovery would otherwise mask the original.)
        try:
            ledger.accumulate_active_time(
                repo_root, run_id, time.monotonic() - t_start
            )
        except Exception:  # noqa: BLE001
            pass


def _tick_body_inner(
    repo_root, run_id, *, adapter, auto, delay, rearm_prompt, now, now_iso
):
    led = ledger.read_ledger(repo_root, run_id)
    phase = phase_grammar.current_phase(led)

    # 0. v0.3.0 U4 / KTD §A: iteration check fires BEFORE the predicate-met
    #    short-circuit below. Without this, A2's judge writing verdict-returned
    #    makes the work-loop's all_units_terminal=True (with iteration_pending
    #    not yet composed), and the short-circuit would exit as "done" before
    #    any iteration logic runs. The check is side-effect-free on a1/W
    #    ledgers (early-return at step 1). When iteration drives the run, this
    #    helper writes its own ledger mutations (atomic_iterate_step on
    #    iterate; set_bound_override + set_loop on bound-exit) which the next
    #    block's `pred` re-reads via the recomputed exit_predicate_result.
    #
    # v0.3.0 F2 (rel-1): wrap the iteration check in try/except so a raise
    # inside iteration.evaluate_decision / atomic_iterate_step (ValueError on a
    # malformed gate decision, KeyError on a missing gate unit, RecipeError on
    # a misshapen emit_template) DOES NOT propagate to _cli — which catches
    # only (TickError, LedgerError) and exits with no JSON intent (the harness
    # never sees a rearm and the run wedges). Instead, we mark the loop done +
    # manual (so an orphan check never mistakes a wedged run for a live one)
    # AND emit a stop intent carrying the diagnostic. LedgerError is re-raised
    # so the existing handler still catches it (LedgerError indicates the
    # ledger itself is in an inconsistent state — we should NOT mark such a
    # run done with a clean signal). Per memory
    # feedback_polling_inside_vs_outside_agentic_loop: the natural harness
    # signal is the rearm/stop intent; the iteration-check crash path must
    # produce one, not silently exit.
    try:
        iteration_result = advance_iteration_loop(repo_root, run_id, led)
    except ledger.LedgerError:
        # Ledger-level failures are NOT recoverable here — the inconsistent-
        # ledger signal must propagate to _cli (which records the error and
        # exits 1, leaving the run for /auto-resume).
        raise
    except Exception as exc:  # noqa: BLE001 — convert ANY non-Ledger raise.
        # Mark the loop finished + manual so liveness checks don't treat the
        # wedged run as orphaned, then surface the crash in a stop intent so
        # the harness gets the natural signal (rather than _cli exiting with
        # no JSON on stdout).
        try:
            ledger.set_loop(
                repo_root, run_id, loop_phase="done", driver="manual", beat=True,
            )
        except Exception:  # noqa: BLE001 — never bury the original.
            pass
        return {
            "action": "stop",
            "reason": "iteration-check-failed",
            "run": run_id,
            "error": {
                "call": "advance_iteration_loop",
                "message": f"iteration check failed: {type(exc).__name__}: {exc}",
                "at": now_iso,
            },
        }
    if iteration_result is not None:
        action = iteration_result.get("action")
        if action == "stop":
            # Bound-exit: the loop is "done" already; the finally still fires
            # to accumulate the active-time delta for this tick.
            return iteration_result
        if action == "iterate":
            # New units emitted + gate reset to pending; the next tick will
            # see fresh pending units for the orchestrator to dispatch. Re-
            # read the ledger to surface the iteration in the rearm intent
            # (operator-diagnostics + so /auto-status sees the new units).
            led = ledger.read_ledger(repo_root, run_id)
            ledger.set_loop(repo_root, run_id, driver="self", beat=True)
            led_now = ledger.read_ledger(repo_root, run_id)
            return {
                "action": "rearm",
                "run": run_id,
                "delay": int(delay),
                "prompt": rearm_prompt,
                "advance": {
                    "advanced": "iterate-step",
                    "gate": (led_now.get("iteration") or {}).get("gate_unit"),
                },
                "stalled": [],
                "halted": [],
                "operator_guidance": _operator_guidance_for(phase, None, led_now),
            }
        # action == "advance": fall through to the standard flow. The gate
        # said "advance"; the existing predicate-met short-circuit (now
        # suppressed only by iteration_pending=True) will fire normally
        # because iteration_pending is False (decision != iterate).
        # Re-read so subsequent code sees any predicate recompute.
        led = ledger.read_ledger(repo_root, run_id)

    # 1. Predicate met? Route PHASE-AWARELY (gap #4 — the met-check must NOT
    #    preempt the seam). I-3: keep liveness honest by NOT stamping a beat for
    #    the terminal `done` exit but flipping driver to manual so an orphan
    #    check never mistakes a finished run for a live self-paced one.
    #      * WORK-met (or seam) → done (terminal exit, emit report).
    #      * PLAN-met → fall through to the plan branch so `_maybe_seam` routes
    #        it to seam (manual) or work (auto); `done` is NEVER a plan exit.
    #    A seam-phase tick has its own branch below (re-affirm pause).
    #
    # v0.3.0 / KTD §A: the short-circuit is BOTH composed at the predicate
    # layer (`recompute_predicate` AND-NOTs iteration_pending into `met` at
    # ledger.py:441-442) AND defensively re-checked here. The redundant guard
    # is belt-and-braces: if U2's composition ever drifts (or a future caller
    # bypasses recompute_predicate), this guard still protects the iteration
    # loop from being short-circuited as "predicate-met" before
    # advance_iteration_loop can write the bound-exit / iterate-step.
    #
    # The downstream short-circuit at the "predicate-met-after-advance" path
    # below is untouched — by the time it fires, advance_iteration_loop has
    # ALREADY run at the top of this body and either stopped (bound-exit),
    # iterated (returned a rearm), or signalled "no iteration" (effective is
    # None or "advance"). Guarding both would risk dropping a real terminal
    # exit on the advance branch; deliberate-fail #2 proves this guard +
    # the iteration check are jointly load-bearing.
    pred = led.get("exit_predicate_result") or {}
    if pred.get("met") and not pred.get("iteration_pending", False) \
            and phase != "plan" and phase != "seam":
        # Work predicate met: mark the run done + manual; finished, not orphaned.
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True
        )
        report = _build_report(led)
        return {
            "action": "stop",
            "reason": "predicate-met",
            "run": run_id,
            "report": report,
        }

    # 2. Detect stalled units; halt them + transitive dependents; advance
    #    independent siblings (the parallel-fan-out promise).
    led, halted_ids, newly_stalled = detect_and_halt_stalled(
        repo_root, run_id, led, now
    )

    # 3. The ONE advance, inside try/except. On a raise: atomically record
    #    last_error + mark stalled; the ledger is never half-written (each
    #    ledger.py mutation is its own atomic RMW).
    advance_result = None
    advance_error = None
    try:
        if phase == "plan":
            if adapter is None:
                adapter = resolve_adapter(led.get("adapter"))
            advance_result, _ = advance_plan_loop(repo_root, run_id, led, adapter)
            # Plan predicate just (re)computed on the prior write; re-read to see
            # whether the plan step closed the gaps.
            led = ledger.read_ledger(repo_root, run_id)
            advance_result = _maybe_seam(
                repo_root, run_id, led, auto=auto, advance_result=advance_result
            )
        elif phase == "work":
            advance_result = advance_work_loop(repo_root, run_id, led, halted_ids)
        elif phase == "seam":
            # A seam tick should not normally fire (the seam does not re-arm),
            # but if one does, re-affirm the pause and stop.
            ledger.set_loop(
                repo_root,
                run_id,
                loop_phase="seam",
                seam_paused=True,
                driver="manual",
                beat=True,
            )
            return {
                "action": "stop",
                "reason": "seam-pause",
                "run": run_id,
            }
        else:
            advance_result = {"advanced": "none", "reason": f"phase={phase}"}
    except Exception as exc:  # noqa: BLE001 — convert ANY raise into a recorded stall.
        call = phase or "advance"
        message = f"{type(exc).__name__}: {exc}"
        # Find the unit that was in flight (best-effort: the most recently
        # dispatched unit). For a plan-step raise with no unit dispatched, we
        # still record the error on the run via the seam/manual path.
        in_flight = _most_recently_dispatched(led)
        recorded = False
        if in_flight is not None:
            recorded = record_stall_error(
                repo_root, run_id, in_flight, call, message, now_iso
            )
        advance_error = {
            "call": call,
            "message": message,
            "at": now_iso,
            "unit": in_flight,
            "recorded_unit_stall": recorded,
        }
        advance_result = {"advanced": "error", "error": advance_error}

    # If a seam pause was decided, _maybe_seam already wrote the ledger and
    # signalled it; surface as a stop (no re-arm).
    if isinstance(advance_result, dict) and advance_result.get("seam_pause"):
        return {
            "action": "stop",
            "reason": "seam-pause",
            "run": run_id,
            "advance": advance_result,
        }

    # 4. Persist the beat (liveness) BEFORE signalling re-arm (R10). The advance
    #    itself already wrote the ledger atomically (predicate recomputed inside
    #    ledger.py per I-1); here we only stamp last_beat_at + reaffirm driver.
    ledger.set_loop(repo_root, run_id, driver="self", beat=True)

    # 5. Re-read to decide the stop-check from the freshly-cached predicate
    #    (memory feedback_loop_monitor_terminal_state_field — read the cached
    #    field, never re-derive). PHASE-AWARE (gap #4): only a WORK predicate
    #    routes to `done`. A plan tick already routed through `_maybe_seam`
    #    (seam/auto-flip); never let the post-advance met-check turn a met PLAN
    #    predicate into `done` (that would skip the seam). After an auto-flip the
    #    ledger phase is now "work", but this tick STARTED in plan, so we gate on
    #    the start-of-tick `phase` to leave the just-flipped work loop to its own
    #    first work tick.
    led = ledger.read_ledger(repo_root, run_id)
    pred = led.get("exit_predicate_result") or {}
    if pred.get("met") and phase == "work":
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True
        )
        return {
            "action": "stop",
            "reason": "predicate-met-after-advance",
            "run": run_id,
            "report": _build_report(led),
            "advance": advance_result,
        }

    # 6. Re-arm the successor. The driver issues ScheduleWakeup(delay, prompt).
    # v0.2.0 fix-pass H: attach a loud operator-guidance block so an agent
    # reading the INTENT can't miss the prepare/execute contract. The plan-loop
    # is the most common operator trap (field bug 2026-05-25, second report:
    # agent ticked 5 times expecting units to materialize; ledger stayed at
    # units=[] because they never ran the prepared /ce-plan invocation). The
    # guidance is phase-aware: plan-loop names the invocation + the gaps_open
    # guard; work-loop reinforces the yield-to-harness pattern from fix-pass G.
    led_now = ledger.read_ledger(repo_root, run_id)
    intent = {
        "action": "rearm",
        "run": run_id,
        "delay": int(delay),
        "prompt": rearm_prompt,
        "advance": advance_result,
        "stalled": newly_stalled,
        "halted": halted_ids,
        "operator_guidance": _operator_guidance_for(phase, advance_result, led_now),
    }
    gap_guard = _gaps_open_guard(phase, led_now)
    if gap_guard is not None:
        intent["gaps_open_guard"] = gap_guard
    return intent


def _operator_guidance_for(phase, advance_result, led):
    """Build the prepare/execute reminder block that rides every rearm intent.

    v0.2.0 fix-pass H (memory feedback_auto_prepare_execute_operator_traps):
    field bug where an agent ticked 5 times expecting units to populate. Root
    cause was invisible contract: the tick prepares invocations; the model
    EXECUTES them; if the model doesn't, the ledger doesn't progress. The
    rearm intent now carries this reminder explicitly. Phase-aware so plan-
    loop and work-loop get the right framing.

    v0.3.0 R9 (KTD §D operator-diagnostics):
      * If the gate unit just had `bound_override` written on this tick →
        prepend a notice naming which bound tripped + the best-so-far state
        from the gate's last decision_payload (OQ2). Operators see WHY the
        loop exited and WHAT we tried before bound.
      * Else if iteration is active AND `iteration_attempts == max_attempts`
        → prepend a "last attempt before bound" warning. Operators know the
        NEXT iterate decision will trip the bound (the engine overrides
        when `attempts_made >= max_attempts` per lib/iteration.py:136).
    """
    iteration_prefix = _iteration_guidance_prefix(led)

    if phase == "plan":
        step = None
        if isinstance(advance_result, dict):
            step = advance_result.get("step")
        invocation = _PLAN_STEP_INVOCATION.get(step, "(see adapter contract)")
        body = (
            "prepare/execute contract: I PREPARED a plan-loop invocation; "
            "YOU must run it. I do NOT dispatch the work — my role is to "
            "advance the state machine AFTER you feed structured results back "
            "(set_gaps_open for review_plan, etc.). Re-ticking without running "
            f"the invocation is a NO-OP — units will stay []. Just-prepared "
            f"step: {step!r}; expected invocation: {invocation}."
        )
        return iteration_prefix + body if iteration_prefix else body
    if phase == "work":
        # In the work-loop, the trap is different: the driver dispatches background
        # Agents via the orchestrator and then YIELDS for harness re-invocation
        # (fix-pass G). Don't ScheduleWakeup-poll waiting for verdicts.
        body = (
            "prepare/execute contract: in the work-loop YOU drive the "
            "orchestrator fan-out (orchestrator.ready_units + dispatch_batch); "
            "after dispatching, YIELD silently — the harness re-invokes you "
            "when a verdict lands (fix-pass G). Re-ticking without running "
            "dispatch is a no-op."
        )
        return iteration_prefix + body if iteration_prefix else body
    body = (
        "prepare/execute contract: I prepare; YOU execute. Re-ticking without "
        "running the prepared invocation does not advance the ledger."
    )
    return iteration_prefix + body if iteration_prefix else body


def _iteration_guidance_prefix(led):
    """Build the iteration-aware operator-guidance prefix (R9 / KTD §D).

    Returns an empty string when no iteration is declared, or when neither
    R9 condition fires. Otherwise returns a one-sentence prefix that names
    either the bound-override (operator sees WHY the loop exited) or the
    last-attempt warning (operator sees that the NEXT iterate trips bound).

    The bound-override read goes through `dispatch_context.bound_override` —
    the field key (`"bound_override"`) is NOT the literal `"decision"` so
    the AST lint allows it. The bound type is read from the same dict.

    The "best-so-far" payload (OQ2) is the gate's `decision_payload` — the
    payload that rode the LAST advance/iterate decision. On a bound-exit
    tick, that payload was the iterate that the engine overrode to exit.
    """
    iter_block = led.get("iteration") or {}
    gate_id = iter_block.get("gate_unit")
    if not gate_id:
        return ""
    gate = next(
        (u for u in led.get("units", []) if u.get("id") == gate_id), None
    )
    if gate is None:
        return ""
    dc = gate.get("dispatch_context") or {}

    # Branch 1 (higher priority): bound_override was written. Surface bound
    # type + best-so-far so the operator sees what we tried before bound.
    override = dc.get("bound_override")
    if override:
        btype = override.get("bound") or "unknown"
        payload = dc.get("decision_payload")
        payload_repr = (
            json.dumps(payload, sort_keys=True) if payload is not None else "null"
        )
        return (
            f"iteration bound tripped: {btype}. "
            f"Best-so-far (last gate payload): {payload_repr}. "
            "The engine overrode the gate's iterate to exit; the run is done. "
        )

    # Branch 2: under bound, but the next iterate decision the engine sees
    # will trip the bound. Surface a warning so the operator knows.
    #
    # v0.3.0 F2 (ADV-3 off-by-one): the warning fires when the NEXT iterate
    # decision will be overridden to exit by `iteration.evaluate_decision`.
    # That override fires when `attempts_made >= max_attempts` (lib/iteration
    # .py:136). `iteration_attempts` increments per HONORED iterate (in
    # atomic_iterate_step, pre-check). So the next iterate trips bound EXACTLY
    # when `attempts == max_attempts` — i.e., max_attempts iterates have been
    # honored and the (max+1)-th would trip. The prior code compared `attempts
    # == max - 1`, which fires ONE tick early (with max=3, that warns at
    # attempts=2 even though attempts=2 still has TWO more iterates to honor
    # before bound trip: the iterate at attempts=2 becomes attempts=3, and the
    # iterate read at attempts=3 is the one that trips).
    bound = iter_block.get("bound") or {}
    max_attempts = bound.get("max_attempts")
    attempts = int(led.get("iteration_attempts", 0))
    if max_attempts is not None and attempts == int(max_attempts):
        return (
            f"iteration: last attempt before bound (attempts={attempts}, "
            f"max_attempts={max_attempts}). The next iterate decision will "
            "trip the bound and force exit. "
        )

    return ""


def _gaps_open_guard(phase, led):
    """Warn the operator when they are in the deepen↔review livelock state.

    This is Trap 2 from feedback_auto_prepare_execute_operator_traps: the
    plan-loop cycles `plan → deepen → review_plan → deepen → review_plan → …`
    forever unless the operator runs a real review and feeds back
    ``set_gaps_open(N)``. Without that, gaps_open stays null, plan-met never
    fires, and units never materialize.

    The livelock signature is: ``plan_step ∈ {"deepen", "review_plan"}`` AND
    ``gaps_open is None``. We do NOT key only on review_plan because the tick
    PERSISTS plan_step AFTER the step runs (anti-livelock §3.1 fix), so by the
    time this guard reads the ledger the just-completed review_plan has been
    succeeded by a deepen → plan_step="deepen", gaps_open still null. Both
    states are diagnostically equivalent: the operator hasn't fed back gaps yet.
    """
    if phase != "plan":
        return None
    plan_step = led.get("plan_step") or ""
    if plan_step not in ("deepen", "review_plan"):
        return None
    pred = led.get("exit_predicate_result") or {}
    if pred.get("gaps_open") is not None:
        return None
    return (
        "gaps_open is NULL — plan-met cannot fire until a real review_plan "
        "step has run and you call ledger.set_gaps_open(<N>) with the gap "
        "count from /ce-doc-review's output. Without this the plan-loop will "
        "deepen↔review_plan forever and units will never materialize. "
        "Feeding back gaps_open=0 closes the loop and starts the work-loop."
    )


# Map a plan_step name to the invocation an operator should run. Authoritative
# source for the operator-guidance string; if a new plan-step ships, add it here.
_PLAN_STEP_INVOCATION = {
    "plan": "/ce-plan <issue>",
    "deepen": "/ce-plan deepen",
    "review_plan": "/ce-doc-review",
}


def advance_to_phase(repo_root, run_id, led, *, to_phase):
    """Advance loop_phase to ``to_phase``, emitting that phase's units if the
    recipe declares an emitter for arrival there.

    v0.2.0 fix-pass A.2 — the single chokepoint for phase advancement. Resolves
    the recipe's {to: to_phase} emitter via phase_grammar.emitter_name_for_arrival
    and calls ledger.transition_and_emit (atomic advance+emit+recompute). When
    no emitter is declared we still need to fall back to a raw set_loop:

    * Legacy ledger (recipe is None, e.g. a v0.1.x run resumed under v0.2.0) —
      no recipe means no phase_transitions; use set_loop to preserve byte-
      identical R13 behavior.
    * v0.2.0 ledger with no matching transition — the recipe declares no
      emitter for arrival at to_phase; this is a RECIPE BUG (the validator
      should have rejected it earlier, but defense in depth: raise here so a
      misconfigured workspace recipe can't silently no-op).

    `feedback_plan_documents_transition_code_doesnt_wire_it`: this helper IS
    the wire — every phase advance that crosses a transition boundary goes
    through here.
    """
    emitter_name = phase_grammar.emitter_name_for_arrival(led, to_phase)
    legacy_ledger = led.get("recipe") is None
    if emitter_name is None:
        if not legacy_ledger:
            raise ledger.LedgerError(
                f"recipe {led.get('recipe',{}).get('name')!r} declares no emitter "
                f"for arrival at {to_phase!r}; either add a phase_transitions entry "
                f"or fix the recipe"
            )
        # legacy: no recipe declared, behave like v0.1.x — raw advance.
        # transition_and_emit's v0.2.0 path writes seam_paused=(to_phase=="seam");
        # we mirror that here so manual seam→work via auto-resume clears the
        # pause flag on legacy ledgers too. The auto-flip path (called with
        # to_phase="work") clears it; future helpers that arrive at "seam"
        # would set it. Either way, both writes happen in one set_loop.
        ledger.set_loop(
            repo_root,
            run_id,
            loop_phase=to_phase,
            seam_paused=(to_phase == "seam"),
            driver="self",
            beat=True,
        )
        return
    emitter_fn = emitters.resolve(emitter_name)
    ledger.transition_and_emit(repo_root, run_id, to_phase, emitter_fn)


def _maybe_seam(repo_root, run_id, led, *, auto, advance_result):
    """If the plan-loop is complete, transition out of plan (gap #5).

    The plan sequence is complete when EITHER the cached predicate is met
    (plan-phase: gaps_open == 0) OR the adapter signalled the sequence finished
    this tick (``next_plan_step`` returned "done" → advance "plan-done"). The two
    MUST agree (adapter-contract §4.1 coherence guard); we trigger on either so a
    `next_plan_step=="done"` always transitions loop_phase, never re-arming on
    `plan`.

    Manual (not auto): write loop_phase="seam", seam_paused=true,
    loop.driver="manual"; do NOT re-arm (signal seam_pause to the caller).
    Auto: flip plan → work directly via the recipe's emitter (v0.2.0; P0 #1
    fix-pass A.2 — the load-bearing rewire). Reads the recipe's
    phase_transitions for the {to: work} emitter, resolves it, and calls
    ledger.transition_and_emit atomically (advance + emit + recompute in ONE
    locked snapshot — the G3/F2 invariant). Legacy ledgers (no recipe) fall
    back to the raw set_loop path so v0.1.x runs resumed under v0.2.0 keep
    working. A v0.2.0 ledger missing the {to: work} declaration is a recipe
    bug; we raise rather than silently no-op (per
    feedback_plan_documents_transition_code_doesnt_wire_it — silent fallback
    on configured recipes IS the build-bug class).
    """
    pred = led.get("exit_predicate_result") or {}
    plan_done = (
        isinstance(advance_result, dict)
        and advance_result.get("advanced") == "plan-done"
    )
    if not pred.get("met") and not plan_done:
        return advance_result  # gaps still open; keep ticking the plan loop.
    if _is_auto(auto):
        advance_to_phase(repo_root, run_id, led, to_phase="work")
        out = dict(advance_result or {})
        out["seam"] = "auto-flip-to-work"
        return out
    ledger.set_loop(
        repo_root,
        run_id,
        loop_phase="seam",
        seam_paused=True,
        driver="manual",
        beat=True,
    )
    out = dict(advance_result or {})
    out["seam_pause"] = True
    out["seam"] = "paused"
    return out


def _build_report(led):
    """Exit report — emit the minors list for a work-loop (R6)."""
    pred = led.get("exit_predicate_result") or {}
    minors = []
    for u in led.get("units", []):
        for f in u.get("findings") or []:
            if f.get("severity") == "minor":
                minors.append({"unit": u.get("id"), "note": f.get("note", "")})
    return {
        phase_grammar.LOOP_PHASE_KEY: phase_grammar.current_phase(led),
        "blockers": pred.get("blockers", 0),
        "majors": pred.get("majors", 0),
        "minors": pred.get("minors", 0),
        "minor_findings": minors,
        "all_units_terminal": pred.get("all_units_terminal", False),
    }


def _most_recently_dispatched(led):
    best_id = None
    best_at = None
    for u in led.get("units", []):
        if u.get("state") != "dispatched":
            continue
        at = ledger._parse_iso(u.get("dispatched_at"))
        if at is None:
            continue
        if best_at is None or at > best_at:
            best_at = at
            best_id = u.get("id")
    return best_id


def _now_dt():
    return datetime.datetime.now(datetime.timezone.utc)


# ──────────────────────────────────────────────────────────────────────────
# CLI (lib/tick.sh routes through this). Positional + flags; never interpolates
# into a shell. Emits the re-arm intent as JSON on stdout.


def _cli(argv):
    parser = argparse.ArgumentParser(prog="tick.py", add_help=True)
    parser.add_argument("run_id", help="the run id to advance")
    parser.add_argument(
        "--repo",
        default=os.environ.get("CLAUDE_AUTO_REPO", os.getcwd()),
        help="repo root (defaults to $CLAUDE_AUTO_REPO or cwd)",
    )
    parser.add_argument("--auto", action="store_true", help="auto-skip the seam")
    parser.add_argument(
        "--delay",
        type=int,
        default=DEFAULT_REARM_DELAY_SECONDS,
        help="re-arm delay seconds (ScheduleWakeup clamps to [60,3600])",
    )
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code or 2)

    try:
        result = dispatch_tick(
            args.repo,
            args.run_id,
            auto=args.auto,
            delay=args.delay,
        )
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"tick.py: {exc}\n")
        return 1
    except (TickError, ledger.LedgerError) as exc:
        sys.stderr.write(f"tick.py: {exc}\n")
        return 1

    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
