#!/usr/bin/env python3
"""auto: /auto run-creation logic behind dispatch.sh.

This is the run-creation entry point the engine otherwise lacks: it parses the
/auto argument string, creates a fresh ledger via ledger.py (so the
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
(adapter-driven, via the tick) populates the work units later; /auto does
NOT parse units from the plan. init_ledger's defaults are exactly this shape.

The plan path, goal text, and `auto` flag have NO ledger field (schema §2 has
no slot for any of them, and ledger.py is the locked contract). They ride in the
EMITTED INTENT as payload the model consumes — the same intent-shape extension
resume.py uses. The model issues `/goal <text>` and `ScheduleWakeup(60,
"/auto-tick <run>[ --auto]")`.

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
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_ledger, load_lib_module  # noqa: E402 — after _LIB_DIR is on sys.path.

_DEFAULT_ADAPTER = "ce"
_VALID_ADAPTERS = ("ce", "native")


def _resolve_repo() -> str:
    """Repo root: $CLAUDE_AUTO_REPO, else walk up from cwd for .claude/auto.

    Parity with resume.py::_resolve_repo. On a fresh run the .claude/auto
    dir may not exist yet, so when no walk-up hit is found we fall back to cwd
    (init_ledger creates the dir).
    """
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    dir_ = os.getcwd()
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "auto")):
            return dir_
        dir_ = os.path.dirname(dir_)
    return os.getcwd()


def _parse_args(argv):
    """Split the /auto arg string into (plan, auto, adapter, goal, recipe).

    Positional: the first non-flag token is the plan/spec path. `auto` is a bare
    positional keyword. Flags: --adapter <ce|native>, --goal <text>, --recipe
    <name>. Returns a dict; raises ValueError on a malformed flag. ``recipe``
    defaults to ``"a1"`` (the classic stack — v0.1.x-equivalent default, KTD-1)
    when no --recipe is given, so bare `/auto <plan>` keeps working unchanged.
    """
    plan = None
    auto = False
    adapter = _DEFAULT_ADAPTER
    goal = None
    recipe = None

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
        if tok == "--recipe":
            if i + 1 >= len(argv):
                raise ValueError("--recipe requires a value (recipe name)")
            recipe = argv[i + 1]
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

    # Default recipe is a1 (classic) — bare /auto <plan> is byte-identical to
    # v0.1.x because a1 IS the encoding of the v0.1.x topology (KTD-1).
    return {"plan": plan, "auto": auto, "adapter": adapter, "goal": goal,
            "recipe": recipe or "a1"}


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
    prompt = f"/auto-tick {run_id}"
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
    ledger = load_ledger()
    recipes = load_lib_module("recipes")
    repo_root = _resolve_repo()

    try:
        args = _parse_args(list(argv))
    except ValueError as exc:
        sys.stderr.write(f"auto: {exc}\n")
        return 2

    plan = args["plan"]
    if not plan:
        # Empty args -> usage surface, exit cleanly (no run created).
        sys.stdout.write(
            "auto: usage: /auto <plan-or-spec> [auto] "
            "[--adapter ce|native] [--goal \"<text>\"]\n"
        )
        return 0

    adapter = args["adapter"]
    if adapter not in _VALID_ADAPTERS:
        sys.stderr.write(
            f"auto: invalid adapter {adapter!r} (expected ce|native)\n"
        )
        return 2

    if not os.path.isfile(plan):
        sys.stderr.write(f"auto: plan/spec file not found: {plan}\n")
        return 1

    # Resolve the recipe (KTD-1: a1 falls back to the A1_BUILTIN constant if no
    # a1.json resolves anywhere, so bare /auto can't be broken by a corrupt
    # built-in). load_and_validate raises RecipeError on an unknown/invalid name.
    try:
        recipe, source_tier = recipes.load_and_validate(args["recipe"], repo_root)
    except recipes.RecipeError as exc:
        sys.stderr.write(f"auto: {exc}\n")
        return 1
    # Surface a non-built-in tier to stderr (KTD-13 — supply-chain visibility: a
    # workspace recipe shadowing a built-in shouldn't load silently).
    if source_tier != "built-in":
        sys.stderr.write(
            f"[auto] resolving recipe {recipe['name']!r} from {source_tier}\n"
        )

    # Build the initial ledger topology FROM the recipe (KTD-4). The recipe's
    # declared units become the initial ledger units; phase_order / terminal_phase
    # drive phase routing. For a1 this is byte-identical to v0.1.x (one plan unit,
    # default grammar — R13 regression). For work-only (W) the recipe declares no
    # units and phase_order ["work"]; init-time enumeration is a v0.2.0 follow-on
    # (KTD-15) — for now W starts in the work phase with whatever units it carries.
    init_units = [recipes.unit_for(u, recipe) for u in recipe.get("units", [])]
    phase_order = recipe.get("phase_order", ["plan", "seam", "work"])
    run_id = _make_run_id(ledger, repo_root, plan)

    try:
        ledger.init_ledger(
            repo_root,
            run_id,
            adapter=adapter,
            units=init_units,
            loop_phase=phase_order[0],
            recipe={"name": recipe["name"], "source_tier": source_tier},
            phase_order=phase_order,
            terminal_phase=recipe.get("terminal_phase", "work"),
        )
    except ledger.LedgerExists as exc:
        sys.stderr.write(f"auto: {exc}\n")
        return 1
    except ledger.LedgerError as exc:
        sys.stderr.write(f"auto: {exc}\n")
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
