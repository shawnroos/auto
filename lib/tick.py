#!/usr/bin/env python3
"""claude-dispatch U4: one ScheduleWakeup-paced advance of the ledger.

A *tick* is the unit of execution. Each tick does exactly ONE smallest-useful
advance of the loop, then re-arms its own successor via `ScheduleWakeup`. The
tick reads ALL loop state from the disk ledger (the durable source of truth) —
it runs in a subprocess and treats conversation context as irrelevant, so it is
safe under the non-stateless re-injection of a `ScheduleWakeup`-fired tick.

THE RE-ARM BOUNDARY (read this — it is the load-bearing seam):

    `ScheduleWakeup` is a MODEL TOOL, not a CLI. tick.py CANNOT call it.
    Instead, tick.py COMPUTES the re-arm intent and emits it on stdout as a
    JSON object:

        {"action": "rearm",  "delay": 60, "prompt": "/dispatch-tick <run>", ...}
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
catches (→ manual /dispatch-resume). We persist BEFORE we signal re-arm (R10).
"""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
import sys

# ──────────────────────────────────────────────────────────────────────────
# Import the canonical ledger module by file path (no package install). We do
# NOT reimplement any ledger logic — every mutation routes through ledger.py so
# I-1 (atomic predicate freshness) is inherited for free.

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_ledger():
    path = os.path.join(_LIB_DIR, "ledger.py")
    spec = importlib.util.spec_from_file_location("ledger", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ledger = _load_ledger()

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

    Honors CLAUDE_DISPATCH_TEST_NO_TICK_LOCK=1 (test-only) to skip acquisition,
    so a deliberate-fail test can prove the double-drive guard is real.
    """

    def __init__(self, repo_root: str, run_id: str):
        self._path = _tick_lock_path(repo_root, run_id)
        self._fh = None
        self._no_lock = os.environ.get("CLAUDE_DISPATCH_TEST_NO_TICK_LOCK") == "1"

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

    A fix-due unit is `verdict-returned` with an open blocker/major finding and
    is NOT in the halted set. The tick applies the fix as a state transition
    only (verdict-returned → fixed); it does NOT touch findings (R8 — closure
    only via a fresh verdict). Returns the unit id or None.
    """
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "verdict-returned":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in ledger.GATING_SEVERITIES:
                return u.get("id")
    return None


def _ready_reenqueue_unit(ledger_dict, halted_ids):
    """Pick ONE `fixed` unit whose STALE verdict still shows a gating finding.

    After a fix is applied (verdict-returned → fixed) the findings remain stale
    (R8 — only a fresh verdict clears them), so the unit is NOT yet terminal.
    The tick re-enqueues it (fixed → pending) so the orchestrator re-dispatches
    it for a fresh review. Skips halted units. Returns the unit id or None.
    """
    for u in ledger_dict.get("units", []):
        if u.get("id") in halted_ids:
            continue
        if u.get("state") != "fixed":
            continue
        for f in u.get("findings") or []:
            if f.get("severity") in ledger.GATING_SEVERITIES:
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
    ``CLAUDE_DISPATCH_TEST_NO_REENQUEUE`` hatch (a deliberate-fail control: with
    it set the work-loop closure test goes RED — livelocks at `fixed`).
    """
    fix_uid = _ready_fix_unit(ledger_dict, halted_ids)
    if fix_uid is not None:
        ledger.transition(repo_root, run_id, fix_uid, "fixed")
        return {"advanced": "fix-applied", "unit": fix_uid}
    if os.environ.get("CLAUDE_DISPATCH_TEST_NO_REENQUEUE") != "1":
        reenq_uid = _ready_reenqueue_unit(ledger_dict, halted_ids)
        if reenq_uid is not None:
            ledger.transition(repo_root, run_id, reenq_uid, "pending")
            return {"advanced": "re-enqueued", "unit": reenq_uid}
    return {"advanced": "none", "reason": "no-fix-due"}


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
    I-1 atomic write path). The live adapters PREPARE an envelope (a dict) that
    the model fills out-of-band, so we persist length ONLY when the return is a
    list — a dict envelope leaves ``gaps_open`` untouched (the model writes it
    through the parse path).
    """
    step = adapter.next_plan_step(ledger_dict)
    if step == "done":
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
    # persists it (adapter-contract §2.2). Persist only for an actual array —
    # a live PREPARE-envelope (dict) is filled by the model elsewhere.
    if step == "review_plan" and isinstance(result, list):
        ledger.set_gaps_open(repo_root, run_id, len(result))
    # Op succeeded — persist the step so the NEXT fresh-process tick advances
    # from it instead of re-reading null and re-planning (the livelock).
    ledger.set_loop(repo_root, run_id, plan_step=step)
    return {"advanced": "plan-step", "step": step}, None


# ──────────────────────────────────────────────────────────────────────────
# Seam handling.


def _is_auto(ledger_dict, auto_flag) -> bool:
    """Auto mode: explicit --auto flag, or a ledger marker (driver policy is the
    driver's; the tick honors an explicit flag and falls back to False)."""
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


def _tick_body(repo_root, run_id, *, adapter, auto, delay):
    rearm_prompt = f"/dispatch-tick {run_id}"
    now = ledger._datetime_now() if hasattr(ledger, "_datetime_now") else _now_dt()
    now_iso = ledger._now_iso()

    led = ledger.read_ledger(repo_root, run_id)
    phase = led.get("loop_phase")

    # 1. Predicate met? Route PHASE-AWARELY (gap #4 — the met-check must NOT
    #    preempt the seam). I-3: keep liveness honest by NOT stamping a beat for
    #    the terminal `done` exit but flipping driver to manual so an orphan
    #    check never mistakes a finished run for a live self-paced one.
    #      * WORK-met (or seam) → done (terminal exit, emit report).
    #      * PLAN-met → fall through to the plan branch so `_maybe_seam` routes
    #        it to seam (manual) or work (auto); `done` is NEVER a plan exit.
    #    A seam-phase tick has its own branch below (re-affirm pause).
    pred = led.get("exit_predicate_result") or {}
    if pred.get("met") and phase != "plan" and phase != "seam":
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
    return {
        "action": "rearm",
        "run": run_id,
        "delay": int(delay),
        "prompt": rearm_prompt,
        "advance": advance_result,
        "stalled": newly_stalled,
        "halted": halted_ids,
    }


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
    Auto: flip plan → work directly and keep re-arming.
    """
    pred = led.get("exit_predicate_result") or {}
    plan_done = (
        isinstance(advance_result, dict)
        and advance_result.get("advanced") == "plan-done"
    )
    if not pred.get("met") and not plan_done:
        return advance_result  # gaps still open; keep ticking the plan loop.
    if _is_auto(led, auto):
        ledger.set_loop(repo_root, run_id, loop_phase="work", driver="self", beat=True)
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
        "loop_phase": led.get("loop_phase"),
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
    import datetime

    return datetime.datetime.now(datetime.timezone.utc)


# ──────────────────────────────────────────────────────────────────────────
# CLI (lib/tick.sh routes through this). Positional + flags; never interpolates
# into a shell. Emits the re-arm intent as JSON on stdout.


def _cli(argv):
    parser = argparse.ArgumentParser(prog="tick.py", add_help=True)
    parser.add_argument("run_id", help="the run id to advance")
    parser.add_argument(
        "--repo",
        default=os.environ.get("CLAUDE_DISPATCH_REPO", os.getcwd()),
        help="repo root (defaults to $CLAUDE_DISPATCH_REPO or cwd)",
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
