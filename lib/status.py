#!/usr/bin/env python3
"""claude-dispatch: /dispatch-status logic behind status.sh.

READ-ONLY. Parses an optional run-id, reads the durable ledger(s) via ledger.py,
and prints a human-readable status: loop_phase (+ plan_step), the cached
exit_predicate_result (blockers / majors / minors / gaps_open / met), per-unit
states, the driver, last_beat_at + liveness, and any stalled units with their
last_error cause. It NEVER mutates the ledger or arms a tick.

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
import glob
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger  # noqa: E402 — after _LIB_DIR is on sys.path.


def _resolve_repo() -> str:
    """Repo root: $CLAUDE_DISPATCH_REPO, else walk up from cwd for .claude/dispatch."""
    env = os.environ.get("CLAUDE_DISPATCH_REPO")
    if env:
        return env
    dir_ = os.getcwd()
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "dispatch")):
            return dir_
        dir_ = os.path.dirname(dir_)
    return os.getcwd()


def _all_runs(repo_root: str):
    """(run_id, ledger_dict) for every parseable ledger in the repo, sorted."""
    dispatch_dir = os.path.join(repo_root, ".claude", "dispatch")
    out = []
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        try:
            with open(path, "r") as fh:
                led = json.load(fh)
        except Exception:
            continue
        if not isinstance(led, dict):
            continue
        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
        out.append((run_id, led))
    return out


def _active_runs(repo_root: str):
    """Runs whose loop_phase is not 'done'."""
    return [(r, led) for (r, led) in _all_runs(repo_root) if led.get("loop_phase") != "done"]


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


def _print_run(ledger, run_id: str, led: dict) -> None:
    loop = led.get("loop") or {}
    epr = led.get("exit_predicate_result") or {}
    units = led.get("units") or []

    sys.stdout.write(f"run: {run_id}\n")
    phase = led.get("loop_phase", "?")
    line = f"  loop_phase: {phase}"
    if phase == "plan":
        line += f"  (plan_step={led.get('plan_step')})"
    if led.get("seam_paused"):
        line += "  [seam_paused]"
    sys.stdout.write(line + "\n")

    sys.stdout.write(
        f"  adapter: {led.get('adapter', '?')} "
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
            for f in u.get("findings") or []:
                sys.stdout.write(
                    f"        finding: {f.get('severity')} — {f.get('note', '')}\n"
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
                f"(/dispatch-resume retry {run_id} {u.get('id', '?')} | "
                f"skip {run_id} {u.get('id', '?')})\n"
            )

    # Exit-time minors report (minors never gate; surfaced for promotion).
    if led.get("loop_phase") == "done" and (epr.get("minors") or 0) > 0:
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
    active = _active_runs(repo_root)
    if not active:
        all_runs = _all_runs(repo_root)
        if not all_runs:
            sys.stdout.write("status: no dispatch run found in this repo.\n")
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
            f"  /dispatch-status {run_id}    "
            f"(loop_phase={led.get('loop_phase')}, "
            f"met={(led.get('exit_predicate_result') or {}).get('met')})\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
