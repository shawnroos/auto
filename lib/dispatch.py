#!/usr/bin/env python3
"""claude-dispatch: /dispatch run-creation logic behind dispatch.sh.

This is the run-creation entry point the engine otherwise lacks: it parses the
/dispatch argument string, creates a fresh ledger via ledger.py (so the
init-time RMW flock + I-1 predicate recompute are inherited — no new flock), and
emits an arm-first-tick INTENT (the model fires the actual ScheduleWakeup +
/goal). It mirrors resume.py's shape: parse argv positionally, route through
ledger.py, emit one JSON intent line, exit 0 on a clean surface.

Argument forms (parsed HERE, never in the .md body — Claude Code does not
dispatch space-separated subcommands, per memory
`feedback_slash_command_arg_substitution`):

    <plan-or-spec>                start a run from a plan/spec file (required).
    ... auto                      append `auto` to skip the plan->work seam
                                  pause (the tick gets --auto).
    ... --adapter ce|native       select the workflow adapter (default ce).
    ... --goal "<text>"           compound deliberate-stop goal text (the
                                  default is the loop's own exit predicate).

A new run starts at loop_phase="plan" with an EMPTY units[] — the plan-loop
(adapter-driven, via the tick) populates the work units later; /dispatch does
NOT parse units from the plan. init_ledger's defaults are exactly this shape.

The plan path, goal text, and `auto` flag have NO ledger field (schema §2 has
no slot for any of them, and ledger.py is the locked contract). They ride in the
EMITTED INTENT as payload the model consumes — the same intent-shape extension
resume.py uses. The model issues `/goal <text>` and `ScheduleWakeup(60,
"/dispatch-tick <run>[ --auto]")`.

DOUBLE-DRIVE: init_ledger holds the per-run init flock across the
existence-check + write; the arm-first-tick path emits intent only — the tick's
own non-blocking process-held _tick_lock is the double-drive guard. No new flock
here. No file sentinel.

rel-001-ish: empty args / a usage surface exits 0 (surfacing, not an error);
only a genuine failure (missing plan file, ledger already exists, bad adapter)
exits non-zero so the operator sees it.
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))

_DEFAULT_ADAPTER = "ce"
_VALID_ADAPTERS = ("ce", "native")


def _load_ledger():
    path = os.path.join(_LIB_DIR, "ledger.py")
    spec = importlib.util.spec_from_file_location("ledger", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _resolve_repo() -> str:
    """Repo root: $CLAUDE_DISPATCH_REPO, else walk up from cwd for .claude/dispatch.

    Parity with resume.py::_resolve_repo. On a fresh run the .claude/dispatch
    dir may not exist yet, so when no walk-up hit is found we fall back to cwd
    (init_ledger creates the dir).
    """
    env = os.environ.get("CLAUDE_DISPATCH_REPO")
    if env:
        return env
    dir_ = os.getcwd()
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "dispatch")):
            return dir_
        dir_ = os.path.dirname(dir_)
    return os.getcwd()


def _parse_args(argv):
    """Split the /dispatch arg string into (plan, auto, adapter, goal).

    Positional: the first non-flag token is the plan/spec path. `auto` is a bare
    positional keyword. Flags: --adapter <ce|native>, --goal <text>. Returns a
    dict; raises ValueError on a malformed flag.
    """
    plan = None
    auto = False
    adapter = _DEFAULT_ADAPTER
    goal = None

    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok == "--adapter":
            if i + 1 >= len(argv):
                raise ValueError("--adapter requires a value (ce|native)")
            adapter = argv[i + 1]
            i += 2
            continue
        if tok == "--goal":
            if i + 1 >= len(argv):
                raise ValueError("--goal requires a value")
            goal = argv[i + 1]
            i += 2
            continue
        if tok == "auto":
            auto = True
            i += 1
            continue
        # First bare positional is the plan/spec.
        if plan is None:
            plan = tok
            i += 1
            continue
        # Extra positionals are ignored (the .md hint is single-plan).
        i += 1

    return {"plan": plan, "auto": auto, "adapter": adapter, "goal": goal}


def _make_run_id(ledger, repo_root: str, plan: str) -> str:
    """Derive a run-id from the plan stem + today's date; uniquify on collision.

    `<plan-stem>-<YYYY-MM-DD>`; if a ledger already exists at that slug, append
    `-<HHMMSS>`. The raw string is handed to init_ledger, which slugifies it
    internally (we never pre-slug).
    """
    stem = os.path.splitext(os.path.basename(plan))[0] or "run"
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    candidate = f"{stem}-{today}"
    try:
        if os.path.exists(ledger.ledger_path(repo_root, candidate)):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%H%M%S")
            candidate = f"{candidate}-{stamp}"
    except ValueError:
        # slugify rejected the derived id (e.g. plan stem was all punctuation);
        # fall back to a date-stamped generic id.
        candidate = f"run-{today}"
    return candidate


def _emit_arm(run_id: str, *, auto: bool, goal, adapter: str, plan: str) -> int:
    """Emit the arm-first-tick INTENT — the model fires /goal + ScheduleWakeup."""
    prompt = f"/dispatch-tick {run_id}"
    if auto:
        prompt += " --auto"
    intent = {
        "action": "arm-tick",
        "run": run_id,
        "prompt": prompt,
        "auto": auto,
        "adapter": adapter,
        "plan": plan,
        "goal": goal,  # null => bind /goal to the loop's own exit predicate.
        "note": (
            "new run created (loop_phase=plan); set the deliberate-stop /goal, "
            "then arm the first tick"
        ),
    }
    json.dump(intent, sys.stdout)
    sys.stdout.write("\n")
    return 0


def run(argv) -> int:
    ledger = _load_ledger()
    repo_root = _resolve_repo()

    try:
        args = _parse_args(list(argv))
    except ValueError as exc:
        sys.stderr.write(f"dispatch: {exc}\n")
        return 2

    plan = args["plan"]
    if not plan:
        # Empty args -> usage surface, exit cleanly (no run created).
        sys.stdout.write(
            "dispatch: usage: /dispatch <plan-or-spec> [auto] "
            "[--adapter ce|native] [--goal \"<text>\"]\n"
        )
        return 0

    adapter = args["adapter"]
    if adapter not in _VALID_ADAPTERS:
        sys.stderr.write(
            f"dispatch: invalid adapter {adapter!r} (expected ce|native)\n"
        )
        return 2

    if not os.path.isfile(plan):
        sys.stderr.write(f"dispatch: plan/spec file not found: {plan}\n")
        return 1

    run_id = _make_run_id(ledger, repo_root, plan)

    try:
        ledger.init_ledger(
            repo_root,
            run_id,
            adapter=adapter,
            units=[],
            loop_phase="plan",
        )
    except ledger.LedgerExists as exc:
        sys.stderr.write(f"dispatch: {exc}\n")
        return 1
    except ledger.LedgerError as exc:
        sys.stderr.write(f"dispatch: {exc}\n")
        return 1

    return _emit_arm(
        run_id,
        auto=args["auto"],
        goal=args["goal"],
        adapter=adapter,
        plan=plan,
    )


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
