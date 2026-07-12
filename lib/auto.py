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
    ... --backend ce|native       select the workflow backend (default ce).
                                  (`--adapter` accepted as a deprecated alias.)
    ... --goal "<text>"           compound deliberate-stop goal text (the
                                  default is the loop's own exit predicate).

A new run starts at loop_phase="plan" with an EMPTY units[] — the plan-loop
(backend-driven, via the tick) populates the work units later; /auto does
NOT parse units from the plan. init_ledger's defaults are exactly this shape.

The plan path, goal text, and `auto` flag have NO ledger field (schema §2 has
no slot for any of them, and ledger.py is the locked contract). They ride in the
EMITTED INTENT as payload the model consumes — the same intent-shape extension
resume.py uses. The model issues `/goal <text>` and `ScheduleWakeup(60,
"/auto:auto-tick <run>[ --auto]")`.

DOUBLE-DRIVE: init_ledger holds the per-run init flock across the
existence-check + write; the arm-first-tick path emits intent only — the tick's
own non-blocking process-held _tick_lock is the double-drive guard. No new flock
here. No file sentinel.

rel-001-ish: empty args / a usage surface exits 0 (surfacing, not an error);
only a genuine failure (missing plan file, ledger already exists, bad backend)
exits non-zero so the operator sees it.
"""

from __future__ import annotations

import datetime
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import build_arm_intent, build_tick_prompt, load_ledger, load_lib_module, resolve_repo, resolve_shared_dir  # noqa: E402 — after _LIB_DIR is on sys.path.

# The ONE driving-session identity helper (KTD-5), shared with the resume
# re-arm path so arm and re-arm record ownership identically (fix-round-6 P1).
driver_session = load_lib_module("driver_session")

_DEFAULT_BACKEND = "ce"
_VALID_BACKENDS = ("ce", "native")


# Repo root resolution is shared with auto-resume.py and auto-status.py; lives
# in _bootstrap.resolve_repo (P2-8 — was three identical copies).
_resolve_repo = resolve_repo


def _parse_args(argv):
    """Split the /auto arg string into (plan, auto, backend, goal, recipe).

    Positional: the first non-flag token is the plan/spec path. `auto` is a bare
    positional keyword (v0.3.x; redundant under v0.4.0's seam-flip default but
    accepted for back-compat). Flags: --backend <ce|native> (deprecated alias
    --adapter), --goal <text>,
    --recipe <name>, --review-plan. Returns a dict; raises ValueError on a
    malformed flag. ``recipe`` defaults to ``"a1"`` (the classic stack —
    v0.1.x-equivalent default, KTD-1) when no --recipe is given, so bare
    ``/auto <plan>`` keeps working unchanged.

    v0.4.0 KTD-4 — seam-default FLIP:
      * v0.3.x: ``auto`` defaulted False; the ``auto`` positional token opted
        IN to skip the plan→work seam pause.
      * v0.4.0: ``auto`` defaults True; the ``--review-plan`` flag opts IN to
        pause at the seam for review. The default-flip delivers the operator-
        facing intent ("involved only at goal-divergence checkpoints, not
        fixed phase boundaries") without latency or a new intent type.
        The ``auto`` positional token still parses to True for scripted
        callers that spell it; it is now a no-op against the default but
        deliberately not rejected.
    """
    plan = None
    # v0.4.0 KTD-4: default flip. The legacy ``auto`` positional still parses
    # to True; ``--review-plan`` opts out of the new default.
    auto = True
    backend = _DEFAULT_BACKEND
    goal = None
    recipe = None
    # Launch-chooser U5 / agent-native Gap 3: when set, delete the run-scoped
    # workspace recipe file once the ledger is initialized (engine is recipe-blind
    # thereafter). Owning teardown HERE makes it atomic with init — the chooser no
    # longer infers "ledger initialized" from this process's stdout.
    teardown_recipe = False

    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok == "--teardown-recipe-after-init":
            teardown_recipe = True
            i += 1
            continue
        if tok == "--backend":
            if i + 1 >= len(argv):
                raise ValueError("--backend requires a value (ce|native)")
            backend = argv[i + 1]
            i += 2
            continue
        if tok == "--adapter":
            # DEPRECATED alias for --backend (concept-vocabulary rename U4).
            # Accepted one minor version; emits a single stderr notice. Removed
            # next minor.
            if i + 1 >= len(argv):
                raise ValueError("--adapter requires a value (ce|native)")
            sys.stderr.write(
                "auto: --adapter is deprecated; use --backend (adapter→backend rename)\n"
            )
            backend = argv[i + 1]
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
        if tok == "--review-plan":
            # v0.4.0 KTD-4: opt in to the seam pause for first-pass plans.
            auto = False
            i += 1
            continue
        if tok == "auto":
            # Legacy v0.3.x positional. Under v0.4.0 default-flip this is a
            # no-op against the new True default — accepted (not rejected) so
            # scripted callers keep working without a forced rewrite.
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
    return {"plan": plan, "auto": auto, "backend": backend, "goal": goal,
            "recipe": recipe or "a1", "teardown_recipe": teardown_recipe}


def _seam_default_notice():
    """v0.4.0 KTD-4: one-time stderr notice for the seam-default flip.

    The seam-pause default flipped from "pause unless `auto`" to "proceed
    unless `--review-plan`". Scripted callers that relied on the pause
    without spelling ``auto`` will now silently skip it. The notice makes
    the change discoverable.

    Marker file at ``<resolve_shared_dir>/.seam-default-acknowledged``;
    first-run-after-upgrade emits the notice and writes the marker; every
    subsequent run is silent. Scoped to the HOST repo (not the worktree)
    so the notice doesn't re-fire per worktree under fanout — KTD-3 (the
    dependency this skill declared on U1).

    Best-effort: any IO failure swallows silently. A missing marker on a
    next run re-fires the notice; not a load-bearing correctness path.
    """
    shared = resolve_shared_dir()
    if shared is None:
        return  # No git → can't anchor the marker; skip the notice.
    marker = os.path.join(shared, ".seam-default-acknowledged")
    if os.path.exists(marker):
        return
    sys.stderr.write(
        "[auto] v0.4.0 seam-default FLIP: `/auto <plan>` now proceeds past "
        "the plan→work seam by default. Pass `--review-plan` to opt in to "
        "the pause for first-pass plans. See "
        "docs/plans/2026-05-27-002-feat-auto-bare-entry-and-fanout-plan.md "
        "KTD-4.\n"
    )
    try:
        os.makedirs(shared, mode=0o700, exist_ok=True)
        # 0600 / touch — anyone-readable would leak via /tmp inspection but
        # we're under the .claude/ tree which is already user-private.
        with open(marker, "w") as fh:
            fh.write("ack")
    except OSError:
        # The notice already fired this run; failing to persist the marker
        # just re-fires next time, which is the correct conservative fallback.
        pass


def _driving_session_id() -> str | None:
    """The interactive driver's session_id, recorded at arm time (v0.6.0 U5 / KTD-5).

    Thin delegate to ``driver_session.driving_session_id`` — the ONE source of
    truth shared with the resume re-arm path (lib/auto-resume.py, fix-round-6
    P1), so arm and re-arm record ownership identically. See that module's
    docstring for the full rationale (session-id EQUALITY is the load-bearing
    fact for both advisor-gate hooks; an unset env returns None and MUST NOT be
    recorded as a cleared field).
    """
    return driver_session.driving_session_id()


def _warn_if_backstop_dark(run_id: str) -> None:
    """Loud stderr warning that the advisor-gate destructive backstop is DARK.

    Emitted at arm time when the driving session id is genuinely unavailable —
    ``CLAUDE_CODE_SESSION_ID`` unset/empty (a truly headless / env-less context).
    v0.6.4: this NO LONGER fires merely because ``CLAUDE_CODE_CHILD_SESSION`` is set
    (the harness sets that in every Bash-tool subprocess, which is exactly where arm
    runs — the old guard mistook it for "spawned sub-agent" and went dark on every
    run). The backstop (lib/on-pretooluse-action.py) owns a run by session-id
    EQUALITY, so a null id can never match. Unlike the resume path (which REFUSES on
    a null id — a paused run staying paused is a safe default), arm PROCEEDS (a hard
    refuse would break headless contexts) but NEVER silently. (security-review fix.)
    """
    sys.stderr.write(
        f"auto: WARNING — CLAUDE_CODE_SESSION_ID is unset for run {run_id!r}, so "
        "the advisor-gate destructive-action backstop will be DARK (it matches a "
        "live run by session-id equality, and there is no owning session to match). "
        "This is normal in a truly headless/env-less context; from an interactive "
        "Claude Code session the id is present and the backstop arms automatically. "
        "Abort with /auto-resume abort if the backstop is required.\n"
    )


def _derive_goal_intent(plan: str) -> str:
    """Derive a one-line goal_intent sentence from the plan file.

    v0.4.0 KTD-2: every /auto <plan> run writes a one-line user-facing intent
    sentence at init time so the bare-/auto hypothesis can surface it when
    disambiguating between in-flight runs. Cheap and deterministic: prefer the
    first ``# H1`` line of the plan markdown, fall back to the file stem.

    Failure modes (unreadable file, no headline, gigantic line): return the
    stem. ``goal_intent`` is advisory operator surface, not a load-bearing
    decision input — a noisy or missing derivation must never block run init.
    """
    try:
        with open(plan, "r", encoding="utf-8", errors="replace") as fh:
            for _ in range(50):  # only scan the head; plans put H1 near the top.
                line = fh.readline()
                if not line:
                    break
                stripped = line.strip()
                if stripped.startswith("# "):
                    # Crop to a sensible one-line length; the ambiguous-runs
                    # surface renders this verbatim.
                    return stripped[2:].strip()[:120]
    except OSError:
        pass
    return os.path.splitext(os.path.basename(plan))[0] or "run"


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


def _bind_presatisfied_plan(presatisfied: bool, init_units: list, plan: str):
    """v0.4.3 KTD-15: wire a plan_presatisfied run's init state. Returns the
    plan_step to pass to init_ledger ("review_plan" when presatisfied, else None).

    A plan_presatisfied recipe (W) declares its plan phase already done. The
    engine inits plan_step="review_plan" (here) and gaps_open=0 (post-init, in
    run()) so the FIRST tick's next_plan_step returns "done" → enumerate_plan_units
    → plan→work, instead of re-running /ce-plan on an already-reviewed plan (the
    "auto re-plans a finished plan" bug). The plan doc path has no top-level
    ledger slot (schema §2), so we bind it to the single plan unit's
    dispatch_context.plan_path — the durable home the backend's
    enumerate_plan_units reads to tell the model WHICH plan to enumerate. The
    validator guarantees exactly one plan unit when presatisfied is true.
    """
    if not presatisfied:
        return None
    for u in init_units:
        if u.get("phase") == "plan":
            u.setdefault("dispatch_context", {})["plan_path"] = plan
            break
    return "review_plan"


def _emit_arm(
    run_id: str, *, auto: bool, goal, backend: str, plan: str, loop_phase: str = "plan"
) -> int:
    """Emit the arm-first-tick INTENT — the model fires /goal + ScheduleWakeup.

    ``loop_phase`` is the run's ENTRY phase (``phase_order[0]``); it surfaces in
    the note so a non-default-entry recipe (e.g. the v0.6.0 ``pipeline`` spine,
    which enters at ``brainstorm``) reports the true starting phase rather than a
    hardcoded ``plan``.
    """
    # The plugin-qualified tick command (see _bootstrap.TICK_COMMAND for the
    # bare-`/auto-tick`-is-"Unknown command" hazard).
    prompt = build_tick_prompt(run_id)
    if auto:
        prompt += " --auto"
    intent = build_arm_intent(
        run_id,
        prompt,
        (
            f"new run created (loop_phase={loop_phase}); set the deliberate-stop "
            "/goal, then arm the first tick"
        ),
        extra={
            "auto": auto,
            "backend": backend,
            "plan": plan,
            "goal": goal,  # null => bind /goal to the loop's own exit predicate.
        },
    )
    json.dump(intent, sys.stdout)
    sys.stdout.write("\n")
    return 0


def _teardown_run_scoped_recipe(recipes, repo_root: str, name: str) -> None:
    """Delete the run-scoped WORKSPACE recipe ``name`` after a successful init.

    Launch-chooser / agent-native Gap 3: with ``--teardown-recipe-after-init`` the
    chooser hands auto.py ownership of teardown, so the delete is atomic with init
    and the chooser never infers "ledger initialized" from this process's stdout.
    The engine is recipe-blind post-init (``recipe-format.md`` §1: tick / dispatch
    / predicate / resume all read the ledger, never the recipe file), so the file
    is dead weight here. Targets ONLY the workspace-tier path for this name (never
    a built-in / global), and is best-effort — ENOENT (a built-in resolved, or the
    file already cleaned) is fine; the chooser keeps its own exit-code-keyed
    cleanup for the case auto.sh fails BEFORE this point.
    """
    try:
        os.remove(recipes.workspace_recipe_path(repo_root, name))
    except OSError:
        pass


def run(argv) -> int:
    ledger = load_ledger()
    recipes = load_lib_module("recipes")
    repo_root = _resolve_repo()

    # v0.4.0 KTD-4: surface the seam-default flip once per host repo, before
    # any flag parsing — so a scripted caller that relied on the v0.3.x pause
    # without spelling `auto` sees the notice on its first post-upgrade run.
    _seam_default_notice()

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
            "[--backend ce|native] [--goal \"<text>\"] "
            "[--recipe <name>]\n"
        )
        return 0

    backend = args["backend"]
    if backend not in _VALID_BACKENDS:
        sys.stderr.write(
            f"auto: invalid backend {backend!r} (expected ce|native)\n"
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
    # default grammar — R13 regression).
    init_units = [recipes.unit_for(u, recipe) for u in recipe.get("units", [])]
    phase_order = recipe.get("phase_order", ["plan", "seam", "work"])
    run_id = _make_run_id(ledger, repo_root, plan)

    # v0.4.3 KTD-15: plan_presatisfied (W) — init the plan phase already-done.
    presatisfied = bool(recipe.get("plan_presatisfied"))
    init_plan_step = _bind_presatisfied_plan(presatisfied, init_units, plan)

    # v0.4.0 KTD-2: derive a one-line goal_intent at init from the plan title.
    # Frozen on the ledger so the bare-/auto hypothesis funnel can render it
    # verbatim when disambiguating among multiple in-flight runs.
    goal_intent = _derive_goal_intent(plan)

    # v0.6.0 U5 (KTD-5): record the driving session at arm time so the advisor-gate
    # PreToolUse hooks can own this run by session_id equality. A null id means the
    # destructive-action backstop is DARK — warn loudly (never silently) and proceed
    # (security-review fix; see _warn_if_backstop_dark + auto-resume._rearm_owns_session).
    driving_sid = _driving_session_id()
    if not driving_sid:
        _warn_if_backstop_dark(run_id)

    try:
        ledger.init_ledger(
            repo_root,
            run_id,
            backend=backend,
            units=init_units,
            loop_phase=phase_order[0],
            recipe={"name": recipe["name"], "source_tier": source_tier},
            phase_order=phase_order,
            terminal_phase=recipe.get("terminal_phase", "work"),
            phase_transitions=recipe.get("phase_transitions", []),
            # v0.3.0 U6: recipe-declared iteration / emit_templates flow to the
            # ledger here. None on v0.2.x recipes; U5's validator has already
            # checked shape if non-None.
            iteration=recipe.get("iteration"),
            emit_templates=recipe.get("emit_templates"),
            goal_intent=goal_intent,
            # v0.6.0 U5 (KTD-5): record the driving session at arm time so the
            # advisor-gate PreToolUse hooks can own this run by session_id equality.
            # Computed + null-warned above (security-review fix).
            driving_session_id=driving_sid,
            # v0.4.3 KTD-15: plan_presatisfied (W) inits the plan phase done.
            plan_step=init_plan_step,
        )
    except ledger.LedgerExists as exc:
        sys.stderr.write(f"auto: {exc}\n")
        return 1
    except ledger.LedgerError as exc:
        sys.stderr.write(f"auto: {exc}\n")
        return 1

    if args["teardown_recipe"]:
        _teardown_run_scoped_recipe(recipes, repo_root, args["recipe"])

    # v0.4.3 KTD-15: finish the pre-satisfied state — plan-met also needs a
    # non-null gaps_open=0 (init_ledger set plan_step; see _bind_presatisfied_plan).
    if presatisfied:
        ledger.set_gaps_open(repo_root, run_id, 0)

    return _emit_arm(
        run_id,
        auto=args["auto"],
        goal=args["goal"],
        backend=backend,
        plan=plan,
        loop_phase=phase_order[0],
    )


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
