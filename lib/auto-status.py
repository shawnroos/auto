#!/usr/bin/env python3
"""auto: /auto-status logic behind status.sh.

READ-ONLY. Parses an optional run-id, reads the durable ledger(s) via ledger.py,
and prints a human-readable status: loop_phase (+ plan_step), the cached
exit_predicate_result (blockers / majors / minors / gaps_open / met), per-unit
states, the driver, last_beat_at + liveness, and any stalled units with their
last_error cause. It NEVER mutates the ledger or arms a pulse.

Argument forms (parsed HERE, never in the .md body, per memory
`feedback_slash_command_arg_substitution`):

    (no args)        report the only active run; if >1 active, LIST them.
    <run>            report that specific run.

Mirrors resume.py's shape: parse argv positionally, route through ledger.py,
exit 0 on a clean surface; only a genuine failure (unknown run-id) exits
non-zero so the operator sees it.

Reads the CACHED exit_predicate_result field directly and NEVER re-derives it
(memory `feedback_loop_monitor_terminal_state_field` — the engine recomputes it
atomically on every write; consumers read, they do not recompute).
"""

from __future__ import annotations

import datetime
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import (  # noqa: E402 — after _LIB_DIR is on sys.path.
    is_iteration_disabled,
    iter_active_runs,
    iter_worktree_ledgers,
    load_ledger,
    load_lib_module,
    resolve_repo,
)

# The ONE phase-decision module (U5): all phase routing reads through it so the
# AST lint can forbid a divergent raw "loop_phase" literal anywhere else in lib/.
phase_grammar = load_lib_module("phase-grammar")
# U12: typed dispatch_context accessor for the bound_override render (iteration
# is a `_bootstrap`-only leaf — no cycle).
iteration = load_lib_module("iteration")


# Repo root resolution is shared with auto.py and auto-resume.py; lives in
# _bootstrap.resolve_repo (P2-8 — was three identical copies).
_resolve_repo = resolve_repo


def _should_render_iteration(led: dict) -> bool:
    """v0.3.0 F1 — render the Iteration section iff the ledger shows ANY
    iteration signal.

    Per F1 task: render WHEN any of:
      • ``iteration`` block is non-null (recipe declared a gate),
      • ``iteration_attempts`` > 0 (the loop has actually iterated),
      • ``active_wall_seconds`` > 0 (the wall-time accumulator has pulsed),
      • any unit carries a ``dispatch_context.bound_override`` (a bound was
        breached at exit).

    Otherwise the section is OMITTED — non-iteration recipes (a1, W, legacy
    v0.2.x a2/a4) stay quiet. ``init_ledger`` always sets ``iteration``=None
    by default, so the check is ``bool(ledger.get("iteration"))``, NOT
    ``"iteration" in ledger`` — the key is always present.

    G7 (ADV-R2-2) — SHAPE-DEFENSIVE on the READ chokepoint. A corrupt
    ``iteration`` (non-dict, non-None) or stringified ``iteration_attempts``
    / ``active_wall_seconds`` must still trigger rendering so the operator
    SEES the corruption — denying visibility during the exact incident that
    needs diagnosis would be the worst possible failure mode.
    """
    # G7: corrupt iteration value (non-dict, non-None) → still render so the
    # operator sees the shape error in the rendered section.
    iter_val = led.get("iteration")
    if iter_val is not None and not isinstance(iter_val, dict):
        return True
    if iter_val:
        return True
    try:
        attempts_int = int(led.get("iteration_attempts", 0) or 0)
    except (TypeError, ValueError):
        # G7: stringified attempts → still render so operator sees it.
        return True
    if attempts_int > 0:
        return True
    try:
        wall_f = float(led.get("active_wall_seconds", 0) or 0)
    except (TypeError, ValueError):
        # G7: stringified wall seconds → still render so operator sees it.
        return True
    if wall_f > 0:
        return True
    units = led.get("units")
    if not isinstance(units, list):
        units = []
    for u in units:
        if not isinstance(u, dict):
            continue
        dc = u.get("dispatch_context")
        if not isinstance(dc, dict):
            continue
        if dc.get("bound_override"):
            return True
    return False


def _render_iteration_section(led: dict) -> None:
    """Render the F1 Iteration section. Caller has already gated visibility
    via ``_should_render_iteration``.

    Fields (per F1 task):
      • gate_unit — ledger["iteration"]["gate_unit"]
      • attempts  — iteration_attempts / iteration["bound"]["max_attempts"]
      • wall_time — active_wall_seconds / iteration["bound"].get("max_wall_seconds", "—")
      • emit_count — iteration_emit_count (monotonic counter)
      • last_active — last_active_at (only if non-null)
      • iteration_pending — exit_predicate_result.iteration_pending (if present)
      • kill_switch — "DISABLED via CLAUDE_AUTO_DISABLE_ITERATION" when the
        operator env var is set (post-F5 unfence — no harness sentinel
        required), else omitted

    Read-only. Reads CACHED iteration_pending from the predicate result, never
    recomputes (memory `feedback_loop_monitor_terminal_state_field`).

    G7 (ADV-R2-2) — Defense-in-depth at the render boundary. The function
    body is wrapped in a top-level try/except: any corruption that slipped
    past the WRITE-side gates (G2 in lib/iteration.py) still produces a
    single operator-visible line ("iteration: <shape error: ...>") rather
    than crashing /auto-status. Denying visibility during the exact incident
    that needs diagnosis is the worst possible failure mode.
    """
    try:
        iteration_block = led.get("iteration") or {}
        if not isinstance(iteration_block, dict):
            # Corrupt iteration value (string, list, etc.) — render the
            # shape error explicitly via the except branch below.
            raise TypeError(
                f"iteration must be dict or None, got {type(iteration_block).__name__}"
            )
        bound = iteration_block.get("bound") or {}
        if not isinstance(bound, dict):
            raise TypeError(
                f"iteration.bound must be dict or None, got {type(bound).__name__}"
            )
        epr = led.get("exit_predicate_result") or {}
        if not isinstance(epr, dict):
            epr = {}

        sys.stdout.write("  iteration:\n")

        gate_unit = iteration_block.get("gate_unit") or "—"
        sys.stdout.write(f"    gate_unit: {gate_unit}\n")

        attempts = led.get("iteration_attempts", 0)
        max_attempts = bound.get("max_attempts", "—")
        sys.stdout.write(f"    attempts: {attempts} / {max_attempts}\n")

        active_wall = led.get("active_wall_seconds", 0)
        max_wall = bound.get("max_wall_seconds", "—")
        # Render integer seconds for compactness; the field is float on disk.
        try:
            active_wall_s = f"{int(active_wall)}s"
        except (TypeError, ValueError):
            active_wall_s = f"{active_wall}s"
        if isinstance(max_wall, (int, float)):
            max_wall_s = f"{int(max_wall)}s"
        else:
            max_wall_s = str(max_wall)
        sys.stdout.write(f"    wall_time: {active_wall_s} / {max_wall_s}\n")

        sys.stdout.write(
            f"    emit_count: {led.get('iteration_emit_count', 0)}\n"
        )

        last_active = led.get("last_active_at")
        if last_active:
            sys.stdout.write(f"    last_active: {last_active}\n")

        if "iteration_pending" in epr:
            sys.stdout.write(
                f"    iteration_pending: {epr.get('iteration_pending')}\n"
            )

        # Kill-switch: render when the operator has set the env var. Routed
        # through is_iteration_disabled (F5 unfence) — the SAME helper pulse.py
        # uses, so /auto-status and the actual iteration check can never disagree.
        if is_iteration_disabled():
            sys.stdout.write(
                "    kill_switch: DISABLED via CLAUDE_AUTO_DISABLE_ITERATION\n"
            )
    except Exception as exc:  # noqa: BLE001 — render boundary, must not crash
        # G7 (ADV-R2-2): defense-in-depth at the render boundary. A corrupt
        # iteration block, bound dict, or stringified counter must produce
        # operator-visible output rather than crashing the status surface
        # during the exact incident that needs diagnosis.
        sys.stdout.write(
            f"  iteration: <shape error: {exc.__class__.__name__}: {str(exc)[:100]}>\n"
        )


def _liveness(ledger, led: dict) -> str:
    """Human note on last_beat_at vs the orphan GRACE."""
    loop = led.get("loop") or {}
    last_beat = loop.get("last_beat_at")
    if not last_beat:
        return "no beat recorded"
    parsed = None
    try:
        parsed = datetime.datetime.strptime(last_beat, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except (ValueError, TypeError):
        return f"{last_beat} (unparseable)"
    now = datetime.datetime.now(datetime.timezone.utc)
    age = int((now - parsed).total_seconds())
    grace = getattr(ledger, "GRACE_SECONDS", 4200)
    flag = " — STALE (> GRACE)" if age > grace else ""
    return f"{last_beat} ({age}s ago, GRACE={grace}s){flag}"


def _print_skip_reason(unit: dict, state: str) -> None:
    """R20: render a force-skipped unit's reason as a sub-bullet under the unit.

    A skip is auditable in the operator's face, never silent (mirrors the finding
    / bound_exit sub-bullet shape). Only `terminal-skip` units carry a
    `skip_reason`; a legacy ledger or a never-skipped unit reads None and prints
    nothing. Extracted from `_print_run` to keep it inside the function budget.
    """
    if state != "terminal-skip":
        return
    reason = unit.get("skip_reason")
    if reason:
        sys.stdout.write(f"        skip_reason: {reason}\n")


def _print_run(ledger, run_id: str, led: dict) -> None:
    loop = led.get("loop") or {}
    epr = led.get("exit_predicate_result") or {}
    units = led.get("units") or []

    sys.stdout.write(f"run: {run_id}\n")
    phase = phase_grammar.current_phase(led)
    line = f"  loop_phase: {phase}"
    if phase == "plan":
        line += f"  (plan_step={led.get('plan_step')})"
    if led.get("seam_paused"):
        line += "  [seam_paused]"
    sys.stdout.write(line + "\n")

    # v0.3.0 G2 / AN-W1: surface exit_reason on a done run so the operator can
    # tell a clean exit from a wedge that F2 force-marked done after an
    # iteration-check crash or a recipe-bug raise. Quiet when the run is live
    # or finished cleanly (exit_reason==None).
    er = led.get("exit_reason")
    if phase == "done" and isinstance(er, dict):
        err = er.get("error") or {}
        sys.stdout.write(
            f"  exit_reason: {er.get('kind', '?')}: "
            f"{err.get('type', '?')}: {err.get('message', '')}\n"
        )

    sys.stdout.write(
        f"  backend: {led.get('adapter', '?')} "
        f"(scale={led.get('adapter_scale', '?')})\n"
    )
    sys.stdout.write(
        f"  driver: {loop.get('driver', '?')}    "
        f"last_beat_at: {_liveness(ledger, led)}\n"
    )

    # Cached exit predicate — READ, never re-derive.
    sys.stdout.write(
        "  exit_predicate: met={met}  blockers={b}  majors={m}  "
        "minors={n}  gaps_open={g}  all_units_terminal={t}\n".format(
            met=epr.get("met"),
            b=epr.get("blockers"),
            m=epr.get("majors"),
            n=epr.get("minors"),
            g=epr.get("gaps_open"),
            t=epr.get("all_units_terminal"),
        )
    )

    # v0.3.0 F1: iteration-awareness. Rendered between the predicate line and
    # the units block so iteration_pending sits next to its predicate-modifier
    # context. Omitted entirely when the run has no iteration signal at all
    # (legacy a1 / W / v0.2.x a2/a4) — keeps non-iteration recipes quiet.
    if _should_render_iteration(led):
        _render_iteration_section(led)

    # Per-unit states.
    if not units:
        sys.stdout.write("  units: (none yet — plan-loop has not populated work units)\n")
    else:
        sys.stdout.write(f"  units ({len(units)}):\n")
        # Scale-aware terminality (Bug #3): the [terminal] marker must match the
        # cached predicate's gating decision, so read this run's adapter_scale and
        # pass it through — a blocker-only run's major-only unit shows [terminal],
        # consistent with met. Scale-blind here would mislabel it [active].
        scale = led.get("adapter_scale", "three-tier")
        for u in units:
            try:
                terminal = ledger.unit_is_terminal(u, scale)
            except Exception:
                terminal = False
            mark = "terminal" if terminal else "active"
            uid = u.get("id", "?")
            state = u.get("state", "?")
            deps = u.get("depends_on") or []
            dep_note = f"  depends_on={deps}" if deps else ""
            sys.stdout.write(f"    - {uid}: {state}  [{mark}]{dep_note}\n")
            _print_skip_reason(u, state)
            for f in u.get("findings") or []:
                sys.stdout.write(
                    f"        finding: {f.get('severity')} — {f.get('note', '')}\n"
                )
            # v0.3.0 F1: bound_exit sub-bullet — surfaces a forced exit driven
            # by an iteration-bound breach (KTD §D / ledger.set_bound_override
            # writes `dispatch_context.bound_override = {bound, original_decision,
            # at}`). Includes original_decision so the rendered surface matches
            # the stored payload exactly (fix-the-class — no asymmetry between
            # what we persist and what we show).
            bo = iteration.read_bound_override(u)
            if isinstance(bo, dict):
                sys.stdout.write(
                    f"        bound_exit: bound={bo.get('bound', '?')} "
                    f"original_decision={bo.get('original_decision', '?')} "
                    f"at={bo.get('at', '?')}\n"
                )

    # Stalled units with their last_error cause.
    stalled = [u for u in units if u.get("state") == "stalled"]
    if stalled:
        sys.stdout.write("  stalled units:\n")
        for u in stalled:
            err = u.get("last_error")
            if isinstance(err, dict):
                cause = (
                    f"{err.get('call', '?')}: {err.get('message', '')} "
                    f"@ {err.get('at', '?')}"
                )
            elif err:
                cause = str(err)
            else:
                cause = "(timeout — no last_error)"
            sys.stdout.write(
                f"    - {u.get('id', '?')}: {cause}    "
                f"(/auto-resume retry {run_id} {u.get('id', '?')} | "
                f"skip {run_id} {u.get('id', '?')})\n"
            )

    # Exit-time minors report (minors never gate; surfaced for promotion).
    if phase_grammar.current_phase(led) == "done" and (epr.get("minors") or 0) > 0:
        sys.stdout.write("  remaining minors (operator may promote):\n")
        for u in units:
            for f in u.get("findings") or []:
                if f.get("severity") == "minor":
                    sys.stdout.write(
                        f"    - {u.get('id', '?')}: {f.get('note', '')}\n"
                    )


def run(argv) -> int:
    ledger = load_ledger()
    repo_root = _resolve_repo()

    rest = list(argv)
    run_arg = rest[0] if rest else None

    if run_arg:
        try:
            led = ledger.read_ledger(repo_root, run_arg)
        except ledger.LedgerNotFound as exc:
            sys.stderr.write(f"status: {exc}\n")
            return 1
        run_id = led.get("run_id") or run_arg
        _print_run(ledger, run_id, led)
        return 0

    # No run-id: resolve the active run, or list if ambiguous / report none.
    active = list(iter_active_runs(repo_root))
    if not active:
        all_runs = list(iter_worktree_ledgers(repo_root))
        if not all_runs:
            sys.stdout.write("status: no auto run found in this repo.\n")
            return 0
        # All runs are done — show the most recent one (last by sorted slug).
        run_id, led = all_runs[-1]
        sys.stdout.write("status: no active run; showing the most recent (done):\n")
        _print_run(ledger, run_id, led)
        return 0

    if len(active) == 1:
        run_id, led = active[0]
        _print_run(ledger, run_id, led)
        return 0

    sys.stdout.write("status: multiple active runs — specify one:\n")
    for run_id, led in active:
        sys.stdout.write(
            f"  /auto-status {run_id}    "
            f"(loop_phase={phase_grammar.current_phase(led)}, "
            f"met={(led.get('exit_predicate_result') or {}).get('met')})\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
