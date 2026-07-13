#!/usr/bin/env python3
"""auto U4: one ScheduleWakeup-paced advance of the ledger.

A *pulse* is the step of execution. Each pulse does exactly ONE smallest-useful
advance of the loop, then re-arms its own successor via `ScheduleWakeup`. The
pulse reads ALL loop state from the disk ledger (the durable source of truth) —
it runs in a subprocess and treats conversation context as irrelevant, so it is
safe under the non-stateless re-injection of a `ScheduleWakeup`-fired pulse.

THE RE-ARM BOUNDARY (read this — it is the load-bearing handoff):

    `ScheduleWakeup` is a MODEL TOOL, not a CLI. pulse.py CANNOT call it.
    Instead, pulse.py COMPUTES the re-arm intent and emits it on stdout as a
    JSON object:

        {"action": "rearm",  "delay": 60, "prompt": "/auto:auto-pulse <run>", ...}
        {"action": "stop",   "reason": "predicate-met" | "handoff-pause", ...}
        {"action": "noop",   "reason": "lock-held-by-live-pulse"}

    The shell/driver layer (the model driving the pulse) reads this and, when
    action == "rearm", issues the actual `ScheduleWakeup(delay, prompt)` tool
    call. Do NOT look for a ScheduleWakeup binary — there isn't one.

The pulse NEVER dispatches (the dispatcher owns `pending → dispatched`) and
NEVER writes verdicts (each background agent self-writes its own `findings[]`).
The pulse only:
  * reads the ledger,
  * detects stalled steps and halts them + their transitive dependents while
    advancing independent siblings (the parallel-fan-out promise),
  * does ONE advance (plan-loop: the backend's next_plan_step; work-loop: apply
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
    build_pulse_prompt,
    load_ledger,
    load_lib_module,
    test_hatch_enabled,
)

ledger = load_ledger()
# The ONE phase-decision module (U5). All phase routing reads through it; the
# AST lint forbids the raw "loop_phase" literal here so a divergent comparison
# can't sneak back in.
phase_grammar = load_lib_module("phase-grammar")
# B4: the advance + stall-detection logic (advance_plan_loop / advance_work_loop
# / advance_iteration_loop / detect_and_halt_stalled / _maybe_handoff / …) and the
# guidance + report builders (_operator_guidance_for / _build_report / …) live
# in sibling modules. pulse.py is the dispatcher that orchestrates them; the
# dependency is one-way (pulse.py → pulse_advance → pulse_guidance; no back-edge).
pulse_advance = load_lib_module("pulse_advance")
pulse_guidance = load_lib_module("pulse_guidance")

# Re-arm delay between pulses. ScheduleWakeup clamps to [60, 3600]s; we sit at
# the floor so the smallest-useful advance paces as fast as the substrate
# allows. The driver MAY override via --delay (e.g. coarsen under pressure).
DEFAULT_REARM_DELAY_SECONDS = 60

# Watchdog-heartbeat wakeup (U1). ScheduleWakeup clamps to [60, 3600]s (same
# bound as above); the dispatch-time fallback heartbeat is clamped to it too.
WATCHDOG_WAKEUP_MIN_SECONDS = 60
WATCHDOG_WAKEUP_MAX_SECONDS = 3600


def watchdog_wakeup_delay(ledger_dict):
    """Fallback-heartbeat delay to arm at dispatch, or None if nothing is dispatched.

    Closes the inverted work-phase carve-out: the driver arms ONE long fallback
    `ScheduleWakeup` at dispatch time so `detect_and_halt_stalled` fires while
    work is in flight (not only "when nothing is in flight"). This helper gives
    that wakeup a deterministic delay: the MINIMUM `stall_threshold_seconds`
    (falling back to the default) across all `dispatched` steps, so the pulse
    fires no later than the soonest in-flight step's stall deadline. The result
    is CLAMPED to `[60, 3600]s` (the ScheduleWakeup bound). When NO step is
    `dispatched`, returns None — a no-op sentinel the driver reads as "arm
    nothing". Pure: no I/O; `ledger_dict` is the ledger dict, not the module.
    """
    delays = [
        int(u.get("stall_threshold_seconds") or ledger.DEFAULT_STALL_THRESHOLD_SECONDS)
        for u in ledger_dict.get("steps", [])
        if u.get("state") == "dispatched"
    ]
    if not delays:
        return None
    return max(
        WATCHDOG_WAKEUP_MIN_SECONDS,
        min(min(delays), WATCHDOG_WAKEUP_MAX_SECONDS),
    )


# ──────────────────────────────────────────────────────────────────────────
# Errors. PulseError is DEFINED in pulse_advance (raised by advance_plan_loop);
# re-exported here so the single class identity is shared — resolve_backend
# below and _cli's catch both reference the same class as advance_plan_loop's
# raises.

PulseError = pulse_advance.PulseError

# PRODUCTION re-exports (U18: the test-only alias block was deleted). The pure
# advance/stall helpers (advance_plan_loop, advance_work_loop,
# advance_brainstorm_loop, advance_iteration_loop, detect_and_halt_stalled,
# _maybe_handoff) live in pulse_advance; internal callers in this file already reach
# them through the qualified module name (pulse_advance.X) so the dependency stays
# grep-visible, and the tests now reach them the same way (t.pulse_advance.X).
# Only two genuine cross-module re-exports survive here:
#   * advance_to_phase — lib/auto-resume.py calls pulse.advance_to_phase on the
#     manual handoff→work resume path (a production dependency).
#   * _iteration_guidance_prefix — the guidance-surface re-export.
advance_to_phase = pulse_advance.advance_to_phase
_iteration_guidance_prefix = pulse_guidance._iteration_guidance_prefix


# ──────────────────────────────────────────────────────────────────────────
# Pulse-level double-drive lock (DISTINCT from ledger.py's internal RMW lock).
#
# ledger.py's flock guards individual read-modify-write operations (the
# lost-update guard). THIS lock is the engine's "another live pulse is already
# driving this run" guard: held for the WHOLE pulse, acquired NON-BLOCKING, so a
# second concurrent pulse returns a no-op instead of queueing behind the first.
# It is process-bound — released on exit (clean OR crash), so a cleanly-exited
# handoff/predicate-met pulse leaves NO stale wedge.


def _pulse_lock_path(repo_root: str, run_id: str) -> str:
    # Sibling of the ledger / RMW-lock files; keyed by the same slug.
    lpath = ledger.lock_path(repo_root, run_id)
    return lpath[: -len(".lock")] + ".pulse.lock"


class _PulseLockHeld(Exception):
    """Raised when another live pulse already holds the run's pulse lock."""


class _pulse_lock:
    """Context manager: non-blocking exclusive flock for the duration of a pulse.

    Honors CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1 (test-only) to skip acquisition,
    so a deliberate-fail test can prove the double-drive guard is real. The
    hatch is FENCED: only honored when CLAUDE_AUTO_TEST_HARNESS=1 is ALSO set
    (sentinel exported by tests/run.sh — task #31). A stray production export
    of NO_PULSE_LOCK alone has no effect.
    """

    def __init__(self, repo_root: str, run_id: str):
        self._path = _pulse_lock_path(repo_root, run_id)
        self._fh = None
        self._no_lock = test_hatch_enabled("CLAUDE_AUTO_TEST_NO_PULSE_LOCK")

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
                raise _PulseLockHeld(
                    f"another live pulse holds the lock for run {run_id_of(self._path)!r}"
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


def run_id_of(pulse_lock_path: str) -> str:
    base = os.path.basename(pulse_lock_path)
    return base[: -len(".pulse.lock")] if base.endswith(".pulse.lock") else base


# ──────────────────────────────────────────────────────────────────────────
# Backend boundary (six-op interface, per the plan / U6a contract).
#
# For U4 the backend call boundary is STUBBABLE: a backend is any object
# exposing the ops the pulse needs. The pulse only ever calls:
#   * next_plan_step(ledger) -> "plan" | "deepen" | "review_plan" | "done"
#   * plan(scope) / deepen(plan) / review_plan(plan)   (the chosen step)
# Work-loop pulses apply a fix as a pure ledger state transition and do NOT need
# a backend op (the fix's *content* is produced out-of-band; the pulse records
# only the state change — verdict-returned → fixed).
#
# U6b ships the real `native` / `ce` backends. U4 resolves a backend via
# `resolve_backend(name)`; a test injects its own object through `backend=`.


def resolve_backend(name: str):
    """Resolve a named backend to a callable object.

    U6b provides real backends (`lib/backend-native.py`, `lib/backend-ce.py`).
    Until then, a missing backend module raises a clean PulseError — the pulse's
    try/except converts that into a recorded `last_error` + `stalled` rather
    than crashing the run (so a half-built engine fails legibly, not silently).
    """
    candidates = {
        "native": "backend-native.py",
        "ce": "backend-ce.py",
    }
    fname = candidates.get(name)
    if fname is None:
        raise PulseError(f"unknown backend: {name!r}")
    apath = os.path.join(_LIB_DIR, fname)
    if not os.path.exists(apath):
        raise PulseError(
            f"backend {name!r} not yet implemented (expected {fname}; U6b provides it)"
        )
    spec = importlib.util.spec_from_file_location(f"backend_{name}", apath)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Convention: the backend module exposes a module-level `Backend` object or
    # the ops directly. Prefer an `Backend` factory if present.
    if hasattr(module, "Backend"):
        return module.Backend()
    return module


# ──────────────────────────────────────────────────────────────────────────
# The pulse's public re-arm/stop/noop envelope (the contract at the top of this
# file). ONE constructor per action so every emit site shares the exact key set
# and order the stdout-contract tests assert. NOTE: the iteration channel's
# advance/iterate/stop returns (pulse_advance.advance_iteration_loop) are a
# SEPARATE decision surface — pulse.py consumes them unchanged, never builds them.


def _rearm_intent(run_id, *, delay, prompt, advance, stalled, halted,
                  operator_guidance):
    """The ``rearm`` envelope — "schedule the next pulse after ``delay`` s"."""
    return {
        "action": "rearm",
        "run": run_id,
        "delay": int(delay),
        "prompt": prompt,
        "advance": advance,
        "stalled": stalled,
        "halted": halted,
        "operator_guidance": operator_guidance,
    }


def _stop_intent(run_id, reason, *, error=None, report=None, advance=None):
    """The ``stop`` envelope — the loop is done/paused, no re-arm.

    ``reason`` is required; the optional ``error``/``report``/``advance`` keys
    are appended in that order ONLY when supplied, matching the five hand-built
    stop sites (bare / +error / +report / +advance / +report+advance).
    """
    intent = {"action": "stop", "reason": reason, "run": run_id}
    if error is not None:
        intent["error"] = error
    if report is not None:
        intent["report"] = report
    if advance is not None:
        intent["advance"] = advance
    return intent


def _noop_intent(run_id, reason):
    """The ``noop`` envelope — a live pulse already holds the lock."""
    return {"action": "noop", "reason": reason, "run": run_id}


# ──────────────────────────────────────────────────────────────────────────
# The pulse.


def dispatch_pulse(
    repo_root,
    run_id,
    *,
    backend=None,
    auto=False,
    delay=DEFAULT_REARM_DELAY_SECONDS,
):
    """Perform ONE ScheduleWakeup-paced advance. Returns the re-arm intent dict.

    The returned dict's `action` is one of:
      * "noop"  — another live pulse holds the lock (double-drive guard); no
                  ledger mutation happened this pulse.
      * "stop"  — the chain ends (predicate met, or a handoff pause). The driver
                  does NOT issue a ScheduleWakeup.
      * "rearm" — the driver SHOULD issue ScheduleWakeup(delay, prompt) for the
                  next pulse.

    NOTE: this function does NOT call ScheduleWakeup (it is a model tool, not a
    CLI). It only computes the intent; the driver layer issues the tool call.
    """
    try:
        with _pulse_lock(repo_root, run_id):
            return _pulse_body(
                repo_root, run_id, backend=backend, auto=auto, delay=delay
            )
    except _PulseLockHeld:
        # Another live pulse is driving this run — no-op (the double-drive guard).
        return _noop_intent(run_id, "lock-held-by-live-pulse")


def _pulse_body(repo_root, run_id, *, backend, auto, delay):
    # The plugin-qualified re-arm command (see _bootstrap.PULSE_COMMAND for the
    # "must be `/auto:auto-pulse`, not bare `/auto-pulse`" hazard).
    rearm_prompt = build_pulse_prompt(run_id)
    now = _now_dt()
    now_iso = ledger.now_iso()
    # v0.3.0 / KTD §D (R5 finally): start the active-time clock at the top of
    # _pulse_body so the `finally` clause below can accumulate the delta on
    # EVERY return path INCLUDING the except path (crashed-pulse deltas land in
    # the ledger). The finally wraps the whole body; release happens inside
    # the pulse lock (dispatch_pulse owns the lock, _pulse_body runs inside).
    t_start = time.monotonic()
    try:
        return _pulse_body_inner(
            repo_root, run_id, backend=backend, auto=auto, delay=delay,
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


def _pulse_body_inner(
    repo_root, run_id, *, backend, auto, delay, rearm_prompt, now, now_iso
):
    """Flat dispatcher over short-circuit helpers (B6 decomposition).

    Each `_try_*` helper returns either a terminal intent dict (short-circuit:
    return it) or None (fall through). The ORDER the short-circuits fire is
    load-bearing and unchanged from the pre-B6 inline body:

      0. iteration check  (KTD §A: BEFORE the predicate-met short-circuit)
      1. predicate-met short-circuit  (work/handoff → done)
      2. detect + halt stalls         (always; computes halted/newly-stalled)
      3. the ONE advance              (plan/work/handoff dispatch, try/except)
         + handoff-pause short-circuit
      4. predicate-met-after-advance  (work → done)
      5. build the rearm intent

    Each helper extracts its branch VERBATIM from the pre-B6 body; no logic
    changed. Locals each branch needs (now_iso, pred, phase, …) are passed
    explicitly — no state smuggled via mutation.
    """
    led = ledger.read_ledger(repo_root, run_id)
    phase = phase_grammar.current_phase(led)

    intent, led = _try_iteration_check(
        repo_root, run_id, led, phase=phase, delay=delay,
        rearm_prompt=rearm_prompt, now_iso=now_iso,
    )
    if intent is not None:
        return intent

    if (intent := _try_predicate_met_shortcircuit(
            repo_root, run_id, led, phase=phase)) is not None:
        return intent

    led, halted_ids, newly_stalled = pulse_advance.detect_and_halt_stalled(
        repo_root, run_id, led, now
    )

    advance_result, advance_intent = _dispatch_phase_advance(
        repo_root, run_id, led, backend, halted_ids, phase=phase,
        auto=auto, now_iso=now_iso,
    )
    if advance_intent is not None:
        return advance_intent

    if (intent := _try_handoff_pause(advance_result, run_id)) is not None:
        return intent

    # Persist the beat (liveness) BEFORE signalling re-arm (R10). The advance
    # itself already wrote the ledger atomically (predicate recomputed inside
    # ledger.py per I-1); here we only stamp last_beat_at + reaffirm driver.
    ledger.set_loop(repo_root, run_id, driver="self", beat=True)

    if (intent := _try_post_advance_predicate_met(
            repo_root, run_id, advance_result, phase=phase)) is not None:
        return intent

    return _build_rearm_intent(
        repo_root, run_id, advance_result, halted_ids, newly_stalled,
        phase=phase, delay=delay, rearm_prompt=rearm_prompt,
    )


def _wedge_done_stop(repo_root, run_id, exc, *, exit_reason, reason_value,
                     message, now_iso):
    """Mark a crashed iteration check done+manual and build its stop intent.

    The shared body of ``_try_iteration_check``'s two crash branches (workflow-bug
    and iteration-check-failed): persist ``exit_reason`` FIRST (so /auto-status
    can tell a wedge-marked-done from a clean exit), then flip
    ``loop_phase=done`` + ``driver=manual`` (so liveness checks don't treat the
    wedged run as orphaned), then return a stop intent carrying the diagnostic.
    Both ledger writes are individually guarded — never bury the original crash.
    The caller keeps the except-clause ORDER (the subclass branches before the
    bare ``LedgerError`` re-raise); this helper holds NO catch logic, only the
    wedge-and-report body the two branches share verbatim modulo two values.
    """
    try:
        ledger.set_exit_reason(
            repo_root, run_id, exit_reason,
            {"type": exc.__class__.__name__, "message": str(exc),
             "call": "advance_iteration_loop"},
        )
    except Exception:  # noqa: BLE001 — never bury the original.
        pass
    try:
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True,
        )
    except Exception:  # noqa: BLE001 — never bury the original.
        pass
    return _stop_intent(
        run_id,
        reason_value,
        error={
            "call": "advance_iteration_loop",
            "message": message,
            "at": now_iso,
        },
    )


def _try_iteration_check(
    repo_root, run_id, led, *, phase, delay, rearm_prompt, now_iso
):
    """Step 0 — the iteration check (KTD §A). Returns (intent_or_None, led).

    The `led` return is load-bearing: on the "iterate" and "advance" branches
    the body re-reads the ledger so the downstream predicate-met short-circuit
    sees the recomputed exit_predicate_result. Returning the refreshed `led`
    keeps that re-read honest instead of letting a stale snapshot leak through.

    v0.3.0 U4 / KTD §A: iteration check fires BEFORE the predicate-met
    short-circuit below. Without this, A2's judge writing verdict-returned
    makes the work-loop's all_steps_terminal=True (with iteration_pending
    not yet composed), and the short-circuit would exit as "done" before
    any iteration logic runs. The check is side-effect-free on a1/W
    ledgers (early-return at step 1). When iteration drives the run, this
    helper writes its own ledger mutations (atomic_iterate_step on
    iterate; set_bound_override + set_loop on bound-exit) which the next
    block's `pred` re-reads via the recomputed exit_predicate_result.

    v0.3.0 F2 (rel-1): wrap the iteration check in try/except so a raise
    inside iteration.evaluate_decision / atomic_iterate_step (ValueError on a
    malformed gate decision, KeyError on a missing gate step, WorkflowError on
    a misshapen emit_template) DOES NOT propagate to _cli — which catches
    only (PulseError, LedgerError) and exits with no JSON intent (the harness
    never sees a rearm and the run wedges). Instead, we mark the loop done +
    manual (so an orphan check never mistakes a wedged run for a live one)
    AND emit a stop intent carrying the diagnostic. LedgerError is re-raised
    so the existing handler still catches it (LedgerError indicates the
    ledger itself is in an inconsistent state — we should NOT mark such a
    run done with a clean signal). Per memory
    feedback_polling_inside_vs_outside_agentic_loop: the natural harness
    signal is the rearm/stop intent; the iteration-check crash path must
    produce one, not silently exit.
    """
    try:
        iteration_result = pulse_advance.advance_iteration_loop(repo_root, run_id, led)
    except (ledger.UnknownStep, ledger.InvalidTransition, ledger.StaleVerdict) as exc:
        # v0.3.0 G2 / rel-r2-2: workflow-bug LedgerError subclasses signal a
        # mis-built caller (unknown gate step id, illegal transition, stale
        # verdict), NOT a torn ledger. Convert to a stop intent — same shape
        # as the generic-Exception branch below — so the operator gets a rearm
        # signal with reason="workflow-bug" rather than _cli swallowing the
        # raise with no JSON. ORDER MATTERS: this branch MUST precede the
        # bare LedgerError catch below (these classes are subclasses of
        # LedgerError; Python matches the first parent in source order).
        return _wedge_done_stop(
            repo_root, run_id, exc,
            exit_reason=ledger.ExitReason.WORKFLOW_BUG,
            reason_value=ledger.ExitReason.WORKFLOW_BUG.value,
            message=f"workflow-bug: {type(exc).__name__}: {exc}",
            now_iso=now_iso,
        ), led
    except ledger.LedgerError:
        # Ledger-level failures are NOT recoverable here — the inconsistent-
        # ledger signal must propagate to _cli (which records the error and
        # exits 1, leaving the run for /auto-resume).
        raise
    except Exception as exc:  # noqa: BLE001 — convert ANY non-Ledger raise.
        # Mark the loop finished + manual so liveness checks don't treat the
        # wedged run as orphaned, then surface the crash in a stop intent so
        # the harness gets the natural signal (rather than _cli exiting with
        # no JSON on stdout). v0.3.0 G2 / AN-W1: the helper persists the
        # exit_reason FIRST so /auto-status of the crashed run can distinguish
        # wedge-marked-done from a clean exit.
        return _wedge_done_stop(
            repo_root, run_id, exc,
            exit_reason=ledger.ExitReason.ITERATION_CHECK_FAILED,
            reason_value=ledger.ExitReason.ITERATION_CHECK_FAILED.value,
            message=f"iteration check failed: {type(exc).__name__}: {exc}",
            now_iso=now_iso,
        ), led
    if iteration_result is not None:
        action = iteration_result.get("action")
        if action == "stop":
            # Bound-exit: the loop is "done" already; the finally still fires
            # to accumulate the active-time delta for this pulse.
            return iteration_result, led
        if action == "iterate":
            # New steps emitted + gate reset to pending; the next pulse will
            # see fresh pending steps for the dispatcher to dispatch. Re-
            # read the ledger to surface the iteration in the rearm intent
            # (operator-diagnostics + so /auto-status sees the new steps).
            led = ledger.read_ledger(repo_root, run_id)
            ledger.set_loop(repo_root, run_id, driver="self", beat=True)
            led_now = ledger.read_ledger(repo_root, run_id)
            return _rearm_intent(
                run_id,
                delay=delay,
                prompt=rearm_prompt,
                advance={
                    "advanced": "iterate-step",
                    "gate": (led_now.get("iteration") or {}).get("gate_step"),
                },
                stalled=[],
                halted=[],
                operator_guidance=pulse_guidance._operator_guidance_for(phase, None, led_now),
            ), led
        # action == "advance": fall through to the standard flow. The gate
        # said "advance"; the existing predicate-met short-circuit (now
        # suppressed only by iteration_pending=True) will fire normally
        # because iteration_pending is False (decision != iterate).
        # Re-read so subsequent code sees any predicate recompute.
        led = ledger.read_ledger(repo_root, run_id)

    return None, led


def _try_predicate_met_shortcircuit(repo_root, run_id, led, *, phase):
    """Step 1 — predicate-met short-circuit. Returns intent or None.

    Predicate met? Route PHASE-AWARELY (gap #4 — the met-check must NOT
    preempt the handoff). I-3: keep liveness honest by NOT stamping a beat for
    the terminal `done` exit but flipping driver to manual so an orphan
    check never mistakes a finished run for a live self-paced one.
      * WORK-met (or handoff) → done (terminal exit, emit report).
      * PLAN-met → fall through to the plan branch so `_maybe_handoff` routes
        it to handoff (manual) or work (auto); `done` is NEVER a plan exit.
    A handoff-phase pulse has its own branch below (re-affirm pause).

    v0.3.0 / KTD §A: the short-circuit is BOTH composed at the predicate
    layer (`recompute_predicate` AND-NOTs iteration_pending into `met` at
    ledger.py:441-442) AND defensively re-checked here. The redundant guard
    is belt-and-braces: if U2's composition ever drifts (or a future caller
    bypasses recompute_predicate), this guard still protects the iteration
    loop from being short-circuited as "predicate-met" before
    advance_iteration_loop can write the bound-exit / iterate-step.

    The downstream short-circuit at the "predicate-met-after-advance" path
    below is untouched — by the time it fires, advance_iteration_loop has
    ALREADY run at the top of this body and either stopped (bound-exit),
    iterated (returned a rearm), or signalled "no iteration" (effective is
    None or "advance"). Guarding both would risk dropping a real terminal
    exit on the advance branch; deliberate-fail #2 proves this guard +
    the iteration check are jointly load-bearing.
    """
    pred = led.get("exit_predicate_result") or {}
    if pred.get("met") and not pred.get("iteration_pending", False) \
            and phase_grammar.is_terminal_phase(led, phase):
        # Terminal-phase predicate met: mark the run done + manual; finished, not
        # orphaned. Route the phase decision through phase_grammar (KTD-3) so a
        # non-work-terminal workflow stops at ITS terminal phase — the old denylist
        # (`phase != "plan" and phase != "handoff"`) over-fired at any non-plan/handoff
        # phase, which only matched the terminal for work-terminal workflows.
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True
        )
        report = pulse_guidance._build_report(led)
        return _stop_intent(run_id, "predicate-met", report=report)
    return None


def _dispatch_phase_advance(
    repo_root, run_id, led, backend, halted_ids, *, phase, auto, now_iso
):
    """Step 3 — the ONE advance, inside try/except.

    Returns (advance_result, terminal_intent_or_None). A handoff-phase pulse
    short-circuits with a terminal intent; every other phase returns an
    advance_result for the dispatcher to carry forward. No refreshed `led` is
    returned: the caller's downstream steps (beat re-stamp, post-advance
    predicate, rearm intent) all re-read the ledger by (repo_root, run_id)
    themselves, so a passed-out snapshot was never consumed. The plan branch
    still re-reads `led` for its OWN `_maybe_handoff` call below.

    On a raise: atomically record last_error + mark stalled; the ledger is
    never half-written (each ledger.py mutation is its own atomic RMW).
    """
    advance_result = None
    try:
        if phase == "plan":
            if backend is None:
                backend = resolve_backend(led.get("backend"))
            advance_result = pulse_advance.advance_plan_loop(
                repo_root, run_id, led, backend
            )
            # Plan predicate just (re)computed on the prior write; re-read to see
            # whether the plan step closed the gaps.
            led = ledger.read_ledger(repo_root, run_id)
            advance_result = pulse_advance._maybe_handoff(
                repo_root, run_id, led, auto=auto, advance_result=advance_result
            )
        elif phase == "brainstorm":
            # Spine forward trigger (v0.6.0 / U7): the brainstorm phase has no
            # predicate-met exit (KTD-3); it advances to plan ONLY via the U8
            # producer. advance_brainstorm_loop fires that producer when the
            # brainstorm step is complete + has its requirements-doc, else
            # returns {"advanced":"none"} so this pulse re-arms (the model is
            # still working the brainstorm step). Mirrors the plan→work flip.
            advance_result = pulse_advance.advance_brainstorm_loop(
                repo_root, run_id, led
            )
            # The producer (re)wrote loop_phase + plan step; the caller's
            # downstream beat re-stamp + rearm intent re-read by (repo, run),
            # so no led refresh is needed here.
        elif phase == "work":
            advance_result = pulse_advance.advance_work_loop(
                repo_root, run_id, led, halted_ids
            )
        elif phase == "handoff":
            # A handoff pulse should not normally fire (the handoff does not re-arm),
            # but if one does, re-affirm the pause and stop.
            ledger.set_loop(
                repo_root,
                run_id,
                loop_phase="handoff",
                handoff_paused=True,
                driver="manual",
                beat=True,
            )
            return advance_result, _stop_intent(run_id, "handoff-pause")
        else:
            advance_result = {"advanced": "none", "reason": f"phase={phase}"}
    except Exception as exc:  # noqa: BLE001 — convert ANY raise into a recorded stall.
        call = phase or "advance"
        message = f"{type(exc).__name__}: {exc}"
        # Find the step that was in flight (best-effort: the most recently
        # dispatched step). For a plan-step raise with no step dispatched, we
        # still record the error on the run via the handoff/manual path.
        in_flight = pulse_guidance._most_recently_dispatched(led)
        recorded = False
        if in_flight is not None:
            recorded = pulse_advance.record_stall_error(
                repo_root, run_id, in_flight, call, message, now_iso
            )
        advance_error = {
            "call": call,
            "message": message,
            "at": now_iso,
            "step": in_flight,
            "recorded_step_stall": recorded,
        }
        advance_result = {"advanced": "error", "error": advance_error}
    return advance_result, None


def _try_handoff_pause(advance_result, run_id):
    """Step 3b — handoff-pause short-circuit. Returns intent or None.

    If a handoff pause was decided, _maybe_handoff already wrote the ledger and
    signalled it; surface as a stop (no re-arm).
    """
    if isinstance(advance_result, dict) and advance_result.get("handoff_pause"):
        return _stop_intent(run_id, "handoff-pause", advance=advance_result)
    return None


def _try_post_advance_predicate_met(repo_root, run_id, advance_result, *, phase):
    """Step 4 — predicate-met-after-advance short-circuit. Returns intent or None.

    Re-read to decide the stop-check from the freshly-cached predicate
    (memory feedback_loop_monitor_terminal_state_field — read the cached
    field, never re-derive). PHASE-AWARE (gap #4): only a TERMINAL-phase
    predicate routes to `done`, decided by phase_grammar.is_terminal_phase
    (KTD-3) so a non-work-terminal workflow stops at ITS terminal phase (the old
    `phase == "work"` allowlist never stopped a non-work terminal). A plan pulse
    already routed through `_maybe_handoff` (handoff/auto-flip); never let the
    post-advance met-check turn a met PLAN predicate into `done` (that would
    skip the handoff). After an auto-flip the ledger phase is now "work", but this
    pulse STARTED in plan, so we gate on the start-of-pulse `phase` to leave the
    just-flipped work loop to its own first work pulse.
    """
    led = ledger.read_ledger(repo_root, run_id)
    pred = led.get("exit_predicate_result") or {}
    if pred.get("met") and phase_grammar.is_terminal_phase(led, phase):
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True
        )
        return _stop_intent(
            run_id,
            "predicate-met-after-advance",
            report=pulse_guidance._build_report(led),
            advance=advance_result,
        )
    return None


def _build_rearm_intent(
    repo_root, run_id, advance_result, halted_ids, newly_stalled,
    *, phase, delay, rearm_prompt,
):
    """Step 5 — re-arm the successor. The driver issues ScheduleWakeup(delay, prompt).

    v0.2.0 fix-pass H: attach a loud operator-guidance block so an agent
    reading the INTENT can't miss the prepare/execute contract. The plan-loop
    is the most common operator trap (field bug 2026-05-25, second report:
    agent pulsed 5 times expecting steps to materialize; ledger stayed at
    steps=[] because they never ran the prepared /ce-plan invocation). The
    guidance is phase-aware: plan-loop names the invocation + the gaps_open
    guard; work-loop reinforces the yield-to-harness pattern from fix-pass G.
    """
    led_now = ledger.read_ledger(repo_root, run_id)
    intent = _rearm_intent(
        run_id,
        delay=delay,
        prompt=rearm_prompt,
        advance=advance_result,
        stalled=newly_stalled,
        halted=halted_ids,
        operator_guidance=pulse_guidance._operator_guidance_for(
            phase, advance_result, led_now
        ),
    )
    gap_guard = pulse_guidance._gaps_open_guard(phase, led_now)
    if gap_guard is not None:
        intent["gaps_open_guard"] = gap_guard
    return intent


def _now_dt():
    return datetime.datetime.now(datetime.timezone.utc)


# ──────────────────────────────────────────────────────────────────────────
# CLI (lib/pulse.sh routes through this). Positional + flags; never interpolates
# into a shell. Emits the re-arm intent as JSON on stdout.


def _cli(argv):
    parser = argparse.ArgumentParser(prog="pulse.py", add_help=True)
    parser.add_argument("run_id", help="the run id to advance")
    parser.add_argument(
        "--repo",
        default=os.environ.get("CLAUDE_AUTO_REPO", os.getcwd()),
        help="repo root (defaults to $CLAUDE_AUTO_REPO or cwd)",
    )
    parser.add_argument("--auto", action="store_true", help="auto-skip the handoff")
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
        result = dispatch_pulse(
            args.repo,
            args.run_id,
            auto=args.auto,
            delay=args.delay,
        )
    except ledger.LedgerNotFound as exc:
        sys.stderr.write(f"pulse.py: {exc}\n")
        return 1
    except (PulseError, ledger.LedgerError) as exc:
        sys.stderr.write(f"pulse.py: {exc}\n")
        return 1

    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
