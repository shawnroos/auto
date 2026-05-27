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
# / advance_iteration_loop / detect_and_halt_stalled / _maybe_seam / …) and the
# guidance + report builders (_operator_guidance_for / _build_report / …) live
# in sibling modules. tick.py is the dispatcher that orchestrates them; the
# dependency is one-way (tick.py → tick_advance → tick_guidance; no back-edge).
tick_advance = load_lib_module("tick_advance")
tick_guidance = load_lib_module("tick_guidance")

# Re-arm delay between ticks. ScheduleWakeup clamps to [60, 3600]s; we sit at
# the floor so the smallest-useful advance paces as fast as the substrate
# allows. The driver MAY override via --delay (e.g. coarsen under pressure).
DEFAULT_REARM_DELAY_SECONDS = 60


# ──────────────────────────────────────────────────────────────────────────
# Errors. TickError is DEFINED in tick_advance (raised by advance_plan_loop);
# re-exported here so the single class identity is shared — resolve_adapter
# below and _cli's catch both reference the same class as advance_plan_loop's
# raises.

TickError = tick_advance.TickError

# B4 re-exports: tests load tick.py via spec_from_file_location("tick", …) and
# access these as attributes on the tick module (t.advance_plan_loop,
# tick._maybe_seam, …). The functions now live in the sibling modules; binding
# them here keeps the test surface byte-identical. Internal callers in this
# file reach through the qualified module name (tick_advance.X / tick_guidance.X)
# so the dependency stays grep-visible; these aliases exist ONLY for the tests.
advance_iteration_loop = tick_advance.advance_iteration_loop
advance_plan_loop = tick_advance.advance_plan_loop
advance_work_loop = tick_advance.advance_work_loop
detect_and_halt_stalled = tick_advance.detect_and_halt_stalled
_maybe_seam = tick_advance._maybe_seam
# advance_to_phase is a PRODUCTION re-export: lib/auto-resume.py calls
# tick.advance_to_phase on the manual seam→work resume path.
advance_to_phase = tick_advance.advance_to_phase
_iteration_guidance_prefix = tick_guidance._iteration_guidance_prefix


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
    """Flat dispatcher over short-circuit helpers (B6 decomposition).

    Each `_try_*` helper returns either a terminal intent dict (short-circuit:
    return it) or None (fall through). The ORDER the short-circuits fire is
    load-bearing and unchanged from the pre-B6 inline body:

      0. iteration check  (KTD §A: BEFORE the predicate-met short-circuit)
      1. predicate-met short-circuit  (work/seam → done)
      2. detect + halt stalls         (always; computes halted/newly-stalled)
      3. the ONE advance              (plan/work/seam dispatch, try/except)
         + seam-pause short-circuit
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

    led, halted_ids, newly_stalled = tick_advance.detect_and_halt_stalled(
        repo_root, run_id, led, now
    )

    advance_result, advance_intent, led = _dispatch_phase_advance(
        repo_root, run_id, led, adapter, halted_ids, phase=phase,
        auto=auto, now_iso=now_iso,
    )
    if advance_intent is not None:
        return advance_intent

    if (intent := _try_seam_pause(advance_result, run_id)) is not None:
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
    makes the work-loop's all_units_terminal=True (with iteration_pending
    not yet composed), and the short-circuit would exit as "done" before
    any iteration logic runs. The check is side-effect-free on a1/W
    ledgers (early-return at step 1). When iteration drives the run, this
    helper writes its own ledger mutations (atomic_iterate_step on
    iterate; set_bound_override + set_loop on bound-exit) which the next
    block's `pred` re-reads via the recomputed exit_predicate_result.

    v0.3.0 F2 (rel-1): wrap the iteration check in try/except so a raise
    inside iteration.evaluate_decision / atomic_iterate_step (ValueError on a
    malformed gate decision, KeyError on a missing gate unit, RecipeError on
    a misshapen emit_template) DOES NOT propagate to _cli — which catches
    only (TickError, LedgerError) and exits with no JSON intent (the harness
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
        iteration_result = tick_advance.advance_iteration_loop(repo_root, run_id, led)
    except (ledger.UnknownUnit, ledger.InvalidTransition, ledger.StaleVerdict) as exc:
        # v0.3.0 G2 / rel-r2-2: recipe-bug LedgerError subclasses signal a
        # mis-built caller (unknown gate unit id, illegal transition, stale
        # verdict), NOT a torn ledger. Convert to a stop intent — same shape
        # as the generic-Exception branch below — so the operator gets a rearm
        # signal with reason="recipe-bug" rather than _cli swallowing the
        # raise with no JSON. ORDER MATTERS: this branch MUST precede the
        # bare LedgerError catch below (these classes are subclasses of
        # LedgerError; Python matches the first parent in source order).
        try:
            ledger.set_exit_reason(
                repo_root, run_id, ledger.ExitReason.RECIPE_BUG,
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
        return {
            "action": "stop",
            "reason": ledger.ExitReason.RECIPE_BUG.value,
            "run": run_id,
            "error": {
                "call": "advance_iteration_loop",
                "message": f"recipe-bug: {type(exc).__name__}: {exc}",
                "at": now_iso,
            },
        }, led
    except ledger.LedgerError:
        # Ledger-level failures are NOT recoverable here — the inconsistent-
        # ledger signal must propagate to _cli (which records the error and
        # exits 1, leaving the run for /auto-resume).
        raise
    except Exception as exc:  # noqa: BLE001 — convert ANY non-Ledger raise.
        # Mark the loop finished + manual so liveness checks don't treat the
        # wedged run as orphaned, then surface the crash in a stop intent so
        # the harness gets the natural signal (rather than _cli exiting with
        # no JSON on stdout). v0.3.0 G2 / AN-W1: persist the exit_reason FIRST
        # so /auto-status of the crashed run can distinguish wedge-marked-done
        # from a clean exit.
        try:
            ledger.set_exit_reason(
                repo_root, run_id, ledger.ExitReason.ITERATION_CHECK_FAILED,
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
        return {
            "action": "stop",
            "reason": ledger.ExitReason.ITERATION_CHECK_FAILED.value,
            "run": run_id,
            "error": {
                "call": "advance_iteration_loop",
                "message": f"iteration check failed: {type(exc).__name__}: {exc}",
                "at": now_iso,
            },
        }, led
    if iteration_result is not None:
        action = iteration_result.get("action")
        if action == "stop":
            # Bound-exit: the loop is "done" already; the finally still fires
            # to accumulate the active-time delta for this tick.
            return iteration_result, led
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
                "operator_guidance": tick_guidance._operator_guidance_for(phase, None, led_now),
            }, led
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
    preempt the seam). I-3: keep liveness honest by NOT stamping a beat for
    the terminal `done` exit but flipping driver to manual so an orphan
    check never mistakes a finished run for a live self-paced one.
      * WORK-met (or seam) → done (terminal exit, emit report).
      * PLAN-met → fall through to the plan branch so `_maybe_seam` routes
        it to seam (manual) or work (auto); `done` is NEVER a plan exit.
    A seam-phase tick has its own branch below (re-affirm pause).

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
            and phase != "plan" and phase != "seam":
        # Work predicate met: mark the run done + manual; finished, not orphaned.
        ledger.set_loop(
            repo_root, run_id, loop_phase="done", driver="manual", beat=True
        )
        report = tick_guidance._build_report(led)
        return {
            "action": "stop",
            "reason": "predicate-met",
            "run": run_id,
            "report": report,
        }
    return None


def _dispatch_phase_advance(
    repo_root, run_id, led, adapter, halted_ids, *, phase, auto, now_iso
):
    """Step 3 — the ONE advance, inside try/except.

    Returns (advance_result, terminal_intent_or_None, led). A seam-phase tick
    short-circuits with a terminal intent; every other phase returns an
    advance_result for the dispatcher to carry forward. The `led` return
    captures the re-read after the plan-loop advance (the plan predicate just
    recomputed on the prior write).

    On a raise: atomically record last_error + mark stalled; the ledger is
    never half-written (each ledger.py mutation is its own atomic RMW).
    """
    advance_result = None
    try:
        if phase == "plan":
            if adapter is None:
                adapter = resolve_adapter(led.get("adapter"))
            advance_result, _ = tick_advance.advance_plan_loop(
                repo_root, run_id, led, adapter
            )
            # Plan predicate just (re)computed on the prior write; re-read to see
            # whether the plan step closed the gaps.
            led = ledger.read_ledger(repo_root, run_id)
            advance_result = tick_advance._maybe_seam(
                repo_root, run_id, led, auto=auto, advance_result=advance_result
            )
        elif phase == "work":
            advance_result = tick_advance.advance_work_loop(
                repo_root, run_id, led, halted_ids
            )
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
            return advance_result, {
                "action": "stop",
                "reason": "seam-pause",
                "run": run_id,
            }, led
        else:
            advance_result = {"advanced": "none", "reason": f"phase={phase}"}
    except Exception as exc:  # noqa: BLE001 — convert ANY raise into a recorded stall.
        call = phase or "advance"
        message = f"{type(exc).__name__}: {exc}"
        # Find the unit that was in flight (best-effort: the most recently
        # dispatched unit). For a plan-step raise with no unit dispatched, we
        # still record the error on the run via the seam/manual path.
        in_flight = tick_guidance._most_recently_dispatched(led)
        recorded = False
        if in_flight is not None:
            recorded = tick_advance.record_stall_error(
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
    return advance_result, None, led


def _try_seam_pause(advance_result, run_id):
    """Step 3b — seam-pause short-circuit. Returns intent or None.

    If a seam pause was decided, _maybe_seam already wrote the ledger and
    signalled it; surface as a stop (no re-arm).
    """
    if isinstance(advance_result, dict) and advance_result.get("seam_pause"):
        return {
            "action": "stop",
            "reason": "seam-pause",
            "run": run_id,
            "advance": advance_result,
        }
    return None


def _try_post_advance_predicate_met(repo_root, run_id, advance_result, *, phase):
    """Step 4 — predicate-met-after-advance short-circuit. Returns intent or None.

    Re-read to decide the stop-check from the freshly-cached predicate
    (memory feedback_loop_monitor_terminal_state_field — read the cached
    field, never re-derive). PHASE-AWARE (gap #4): only a WORK predicate
    routes to `done`. A plan tick already routed through `_maybe_seam`
    (seam/auto-flip); never let the post-advance met-check turn a met PLAN
    predicate into `done` (that would skip the seam). After an auto-flip the
    ledger phase is now "work", but this tick STARTED in plan, so we gate on
    the start-of-tick `phase` to leave the just-flipped work loop to its own
    first work tick.
    """
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
            "report": tick_guidance._build_report(led),
            "advance": advance_result,
        }
    return None


def _build_rearm_intent(
    repo_root, run_id, advance_result, halted_ids, newly_stalled,
    *, phase, delay, rearm_prompt,
):
    """Step 5 — re-arm the successor. The driver issues ScheduleWakeup(delay, prompt).

    v0.2.0 fix-pass H: attach a loud operator-guidance block so an agent
    reading the INTENT can't miss the prepare/execute contract. The plan-loop
    is the most common operator trap (field bug 2026-05-25, second report:
    agent ticked 5 times expecting units to materialize; ledger stayed at
    units=[] because they never ran the prepared /ce-plan invocation). The
    guidance is phase-aware: plan-loop names the invocation + the gaps_open
    guard; work-loop reinforces the yield-to-harness pattern from fix-pass G.
    """
    led_now = ledger.read_ledger(repo_root, run_id)
    intent = {
        "action": "rearm",
        "run": run_id,
        "delay": int(delay),
        "prompt": rearm_prompt,
        "advance": advance_result,
        "stalled": newly_stalled,
        "halted": halted_ids,
        "operator_guidance": tick_guidance._operator_guidance_for(
            phase, advance_result, led_now
        ),
    }
    gap_guard = tick_guidance._gaps_open_guard(phase, led_now)
    if gap_guard is not None:
        intent["gaps_open_guard"] = gap_guard
    return intent


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
