#!/usr/bin/env python3
"""auto: the ONE ledger-module loader.

Every consumer module (tick.py, orchestrator.py, on-stop.py, on-session-start.py,
goal-status.py, auto-resume.py, auto.py, auto-status.py) loads the canonical ledger
module by FILE PATH rather than `import ledger` — the plugin is not pip-installed
and lib/ is not guaranteed on sys.path. That importlib bootstrap used to be
copy-pasted into all eight modules; it lives here ONCE so a change to the load
strategy (or the Python pin contract) has a single edit site.

Usage from a sibling module in lib/::

    import os, sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from _bootstrap import load_ledger
    ledger = load_ledger()

We do NOT load _bootstrap itself via importlib — that would just move the
duplication. The two-line sys.path prepend + plain import is the dedup.
"""

from __future__ import annotations

import glob
import importlib.util
import json
import os
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))

# Bound for the `git rev-parse` in _git_worktree_root so a hung filesystem
# (sick NFS/autofs mount) can't block repo-root resolution. Mirrors the
# detector's CLAUDE_AUTO_GIT_TIMEOUT_SECONDS knob — keep the two in sync.
try:
    _GIT_TIMEOUT_SECONDS = float(os.environ.get("CLAUDE_AUTO_GIT_TIMEOUT_SECONDS", "5"))
except (TypeError, ValueError):
    _GIT_TIMEOUT_SECONDS = 5.0
if _GIT_TIMEOUT_SECONDS <= 0:
    _GIT_TIMEOUT_SECONDS = 5.0


def load_lib_module(name: str):
    """Load and return a sibling lib/ module by its filename stem, by file path.

    The ONE load strategy for every lib/ module (the plugin is not pip-installed
    and lib/ is not guaranteed on sys.path). ``name`` is the filename stem WITHOUT
    the ``.py`` extension and MAY contain hyphens (e.g. ``"phase-grammar"`` for
    ``lib/phase-grammar.py``) — hyphens are valid in a file path but not in a
    Python module identifier, so the registered spec name sanitizes them to
    underscores (``phase_grammar``). Callers bind the returned module once.

    Added in v0.2.0 (U5) to load the hyphenated ``phase-grammar.py`` (and reusable
    for ``topology-render.py``). Generalizes the former ``load_ledger`` idiom that
    was previously the only loader here.

    Caches the loaded module in ``sys.modules`` under ``spec_name`` so repeat
    calls return the SAME instance — important for classes (e.g.
    ``recipes.RecipeError``): without caching, two callers that both
    ``load_lib_module("recipes")`` would each get a fresh ``RecipeError`` class
    and ``except recipes.RecipeError`` in one wouldn't catch a raise from the
    other. The cache mirrors ordinary Python import semantics; the file-path
    load strategy is unchanged.
    """
    path = os.path.join(_LIB_DIR, f"{name}.py")
    spec_name = name.replace("-", "_")
    cached = sys.modules.get(spec_name)
    if cached is not None:
        # Only re-use if it came from our path (defensive — an unrelated module
        # of the same name shouldn't be returned).
        cached_file = getattr(cached, "__file__", None)
        if cached_file and os.path.abspath(cached_file) == os.path.abspath(path):
            return cached
    spec = importlib.util.spec_from_file_location(spec_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec_name] = module  # register BEFORE exec so cyclic refs resolve.
    try:
        spec.loader.exec_module(module)
    except BaseException:
        # Roll back the registration on a load failure so the next attempt
        # doesn't see a half-initialized module.
        sys.modules.pop(spec_name, None)
        raise
    return module


def _git_worktree_root(start):
    """The git worktree top for ``start``, or None when not in a git tree.

    ``git rev-parse --show-toplevel`` reports the WORKTREE's own root (a
    worktree reports itself, not the host repo) — the upper bound for the
    per-worktree ledger home. Distinct from ``resolve_host_repo_root()``
    (``--git-common-dir``), which deliberately resolves the MAIN repo for
    cross-worktree shared state.

    Carries a timeout so a hung git (sick NFS/autofs mount) can't block the CLI
    callers (``auto.py`` / ``auto-resume.py`` / ``auto-status.py``), which
    invoke ``resolve_repo`` with no try/except of their own. On timeout/spawn
    failure we return None → ``resolve_repo`` falls back to cwd.
    """
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
            cwd=start,
            timeout=_GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        # OSError: git absent / cwd gone. SubprocessError covers TimeoutExpired.
        return None
    if result.returncode != 0:
        return None
    top = result.stdout.strip()
    return top or None


def resolve_repo() -> str:
    """Repo root: $CLAUDE_AUTO_REPO, else the git-worktree-bounded ledger home.

    Used by every CLI module that needs to find the repo's ``.claude/auto``
    directory (``auto.py``, ``auto-resume.py``, ``auto-status.py``). Consolidated
    here from three identical copies (P2-8) so the lookup rule lives in ONE
    place. ``$CLAUDE_AUTO_REPO`` is the explicit override; otherwise we walk up
    from cwd looking for ``.claude/auto`` — but NEVER above the git worktree
    root, and never walking up at all outside a git tree. The fallback is the
    worktree root (or cwd, no git), where ``init_ledger`` will create the dir.

    The bound fixes the 2026-06 mis-root field bug: a fresh worktree has no
    ``.claude/auto`` yet, so the unbounded walk-up escaped to
    ``$HOME/.claude/auto`` and bound the run against ``$HOME`` (a dispatched
    run fell through to an empty terminal ``done``, having looked for its plan
    under ``$HOME/docs/plans``).

    NOTE: ``lib/auto-detect.sh::_repo_root()`` inlines this same logic (its
    single-quoted heredoc keeps a dependency-free copy on purpose) — keep the
    two in sync.
    """
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    start = os.getcwd()
    boundary = _git_worktree_root(start)
    dir_ = start
    while dir_ and dir_ != os.path.dirname(dir_):
        if os.path.isdir(os.path.join(dir_, ".claude", "auto")):
            return dir_
        if boundary is None:
            break
        if os.path.abspath(dir_) == os.path.abspath(boundary):
            break
        dir_ = os.path.dirname(dir_)
    return boundary or os.getcwd()


def resolve_host_repo_root(*, cwd=None):
    """Absolute path of the MAIN repo (the host of any worktrees), or None.

    v0.4.0 KTD-3 (round-3 finding R3-001 — empirically verified): from inside a
    git worktree, ``git rev-parse --show-toplevel`` returns the *worktree's*
    own root, NOT the main repo. For multi-plan fanout we need the host repo
    so spawned worktrees nest under the main checkout's ``worktrees/`` —
    independent of which worktree the parent session is itself running in.

    The mechanism uses ``git rev-parse --git-common-dir``: from a main repo
    this returns ``.git`` (the actual git dir); from a worktree it returns
    the main repo's ``.git`` (NOT the worktree's ``.git/worktrees/<name>/``
    private dir). The parent of the resolved common-dir is the host repo
    root in both cases.

    Returns the absolute host repo path. Returns ``None`` when git is not
    available or cwd is not inside a git tree — callers must handle the
    None case (typically by erroring out: fanout requires a git repo).

    Pass ``cwd`` to run git from a specific directory (review round 1 fix:
    on-stop.py needs to query the host repo from a process whose cwd may
    be elsewhere).
    """
    return _resolve_host_repo_root(cwd=cwd)


def _resolve_host_repo_root(*, cwd=None):
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=False,
            cwd=cwd,
        )
    except (OSError, FileNotFoundError):
        return None
    if result.returncode != 0:
        return None
    common_dir = result.stdout.strip()
    if not common_dir:
        return None
    # git emits a relative path when cwd is inside the main repo (".git") and
    # an absolute path from inside a worktree. Resolve to absolute either way,
    # then return the parent (the main repo root). When cwd is provided,
    # `os.path.abspath` resolves the relative path against the PROCESS cwd
    # rather than the cwd we passed to git — so for relative outputs we must
    # join explicitly against cwd before resolving.
    if not os.path.isabs(common_dir) and cwd is not None:
        common_dir = os.path.join(cwd, common_dir)
    abs_common = os.path.abspath(common_dir)
    return os.path.dirname(abs_common)


def resolve_shared_dir(*, cwd=None):
    """Absolute path to ``<host-repo-root>/.claude/auto/``, or None.

    v0.4.0 KTD-3: shared state — batch sidecars, cross-worktree run discovery,
    the v0.4 default-flip back-compat marker — lives at the HOST repo's
    ``.claude/auto/`` (NOT the cwd worktree's). This helper wraps
    ``resolve_host_repo_root()`` + the ``.claude/auto/`` join so every shared-
    state consumer reads the same path.

    Returns ``None`` when ``resolve_host_repo_root()`` returns None (no git).
    Callers that need a directory MUST handle None — typically by degrading
    to per-worktree state (the legacy ``resolve_repo`` shape) or erroring out
    for features that genuinely require shared state (fanout).

    Distinct from ``resolve_repo()``: that returns the per-worktree ledger
    home (env-pinned via ``CLAUDE_AUTO_REPO`` for sub-runs); this returns the
    main repo's shared state directory. Both are needed: the per-worktree
    helper for "what does THIS worktree own", this helper for "what does the
    parent know across worktrees".
    """
    host = resolve_host_repo_root(cwd=cwd)
    if host is None:
        return None
    return os.path.join(host, ".claude", "auto")


# Round-3 P3: cmux ref token character class — shared across every
# Python module that grep/regex-matches cmux IDs (workspace/pane/surface).
# auto-workspace.py originally lifted this internally; auto-spawn.py
# still inlined the literal, so the round-2 consolidation was incomplete.
# Lifting here makes both consumers import from the same source of
# truth. cmux-socket.sh (bash) inlines independently — Python constants
# don't cross to bash; a one-line comment in that file points at this
# constant as the source of truth so future cmux-alphabet changes get
# a coordinated edit.
CMUX_REF_CHARS = r"[0-9a-zA-Z_.-]+"


# The ledger key holding the DRIVING interactive session's id (v0.6.0 U5 / KTD-5).
# ONE definition shared by the advisor-gate WRITER and the READERS so they can
# never drift: the arm-time setter (lib/ledger_mutators.py::set_driving_session_id)
# writes it, and BOTH PreToolUse hooks (lib/on-pretooluse-action.py,
# lib/on-pretooluse-askuser.py) match a live run to a session by reading it and
# comparing session-id EQUALITY. lib/ledger_core.py::init_ledger also emits this
# key as its schema default, but it CANNOT import _bootstrap (that would be a
# circular import — _bootstrap.load_ledger loads ledger_core; see the note at
# ledger_core.py's deferred-loader) so it inlines the literal on purpose — keep
# that one string in sync with this constant.
DRIVING_SESSION_KEY = "driving_session_id"

# U8 (R21/KTD-7) — the OWNERSHIP SET. The loop's phase work runs in background
# sub-agents, which carry their own CLAUDE_CODE_SESSION_ID; a scalar
# `driving_session_id` therefore matched none of them and BOTH PreToolUse hooks
# went dark inside the tree. A dispatched sub-agent registers its session id here
# (via `ledger.register_session`) and the hooks test MEMBERSHIP of
# {driving_session_id} ∪ agent_session_ids.
#
# Membership is opt-IN by registration, never by mere co-location: an unrelated
# Claude session in the same worktree is not in the set and is never gated. The
# same "keep the literal in sync" caveat as DRIVING_SESSION_KEY applies to
# ledger_core.py.
AGENT_SESSIONS_KEY = "agent_session_ids"


# The plugin-qualified tick command — the ONE copy of the string AND its hazard
# note (v0.6.5). A programmatically fired plugin slash command must resolve as
# `/<plugin>:<command>`: the bare `/auto-tick` is "Unknown command" under
# ScheduleWakeup / loop re-injection, so every re-arm hit that and the loop never
# self-paced. The plugin name is `auto`. tick.py / auto.py / auto-resume.py all
# build their re-arm prompt through build_tick_prompt() so this hazard lives once.
TICK_COMMAND = "/auto:auto-tick"


def build_tick_prompt(run_id) -> str:
    """The re-arm prompt: the plugin-qualified tick command + the run id.

    The ONE builder of the `/auto:auto-tick <run>` string (was three hand-built
    copies in tick.py / auto.py / auto-resume.py, each re-explaining the
    plugin-qualification hazard — see TICK_COMMAND).
    """
    return f"{TICK_COMMAND} {run_id}"


def build_arm_intent(run_id, prompt, note, extra=None):
    """The `arm-tick` INTENT envelope emitted by the non-tick arm sites.

    Both auto.py (new run) and auto-resume.py (re-arm) emit an ``arm-tick``
    intent — "schedule the next tick" — with the same ``action``/``run``/
    ``prompt`` core and a trailing ``note``. auto.py carries extra keys
    (``auto``/``adapter``/``plan``/``goal``) between ``prompt`` and ``note``;
    pass them via ``extra`` (an ordered dict) so the emitted key order stays
    byte-identical to the hand-built envelopes the stdout-contract tests assert.
    """
    intent = {"action": "arm-tick", "run": run_id, "prompt": prompt}
    if extra:
        intent.update(extra)
    intent["note"] = note
    return intent


def cmux_available() -> bool:
    """Probe whether the cmux binary (or its override) is on PATH.

    Plan-004 round-1 review P3 #7: previously duplicated in
    lib/auto-spawn.py and lib/auto-workspace.py. Lifted here so both
    callers share one definition (and one place to evolve, e.g. to
    add a timeout if cmux gets slow).

    Round-2 P1 — the original `sh -c "command -v {name}"` form had
    a shell-injection surface: an operator with CLAUDE_AUTO_CMUX
    containing shell metachars (typo, copy-paste, malicious dotfile)
    would execute arbitrary code under `sh -c`. shutil.which does
    the same PATH-resolution job with NO shell — safe by default.
    """
    import shutil
    name = os.environ.get("CLAUDE_AUTO_CMUX", "cmux")
    return shutil.which(name) is not None


def load_ledger():
    """Load and return the canonical ledger module (lib/ledger.py).

    Thin wrapper over ``load_lib_module("ledger")`` — kept as a named entry point
    because eight consumers already call it; the load strategy lives in one place.
    """
    return load_lib_module("ledger")


def load_ledger_safe(path: str):
    """Read a ledger JSON file; return its dict, or None on ANY read/parse
    failure OR a non-dict top-level value (rel-001). Never raises, so a caller
    scanning siblings keeps going and a fail-closed hook stays fail-closed.

    The dict guard is folded in here: returning None on a non-dict value means a
    list/scalar ledger skips instead of raising AttributeError at the caller's
    ``led.get(...)`` — strictly safer than the bare ``json.load`` it replaced.
    """
    try:
        with open(path, "r") as fh:
            led = json.load(fh)
    except Exception:
        return None
    return led if isinstance(led, dict) else None


def iter_worktree_ledgers(repo_root: str):
    """Yield ``(run_id, ledger_dict)`` for each parseable ledger under
    ``<repo_root>/.claude/auto/*.json``, sorted by path. ``run_id`` is
    ``led["run_id"]`` when present, else the filename stem.

    Per-worktree glob ONLY — fan-out sub-runs carry their own session_id/shared
    dir and are out of scope by design (KTD-5); this does NOT walk batch
    sidecars. A consumer needing the sidecar walk (on-stop.py) keeps its own loop
    over ``load_ledger_safe``. Never raises: a missing dir yields nothing.
    """
    dispatch_dir = os.path.join(repo_root, ".claude", "auto")
    for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
        led = load_ledger_safe(path)
        if led is None:
            continue
        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
        yield run_id, led


def iter_active_runs(repo_root: str):
    """Yield ``(run_id, ledger_dict)`` for each NON-``done`` run under
    ``<repo_root>/.claude/auto/*.json``, in ``iter_worktree_ledgers``' sorted order.

    The shared active-run scan (U7): consolidates two divergent ``_active_runs``
    copies that both wrapped ``iter_worktree_ledgers`` + ``phase_grammar.current_phase``
    to drop ``"done"`` runs — ``auto-status.py`` yielded the richer ``(run_id, led)``
    tuples, while ``auto-resume.py`` yielded bare run_id strings AND carried a dead
    ``ledger`` param. The two filter polarities (``== "done"`` skip vs
    ``!= "done"`` keep) were equivalent; this yields the richer tuple shape and
    ``auto-resume`` adapts via ``run_id for run_id, _ in iter_active_runs(...)``.

    Loads phase-grammar lazily via ``load_lib_module`` (cached) so the "is this
    run done" decision stays in the ONE phase-grammar module (U5) rather than a
    raw ``loop_phase`` compare here, and phase-grammar stays off ``_bootstrap``'s
    import-time surface. Never raises: a missing dispatch dir yields nothing.
    """
    phase_grammar = load_lib_module("phase-grammar")
    for run_id, led in iter_worktree_ledgers(repo_root):
        if phase_grammar.current_phase(led) != "done":
            yield run_id, led


def test_hatch_enabled(hatch_var: str) -> bool:
    """Return True iff BOTH the test-harness sentinel AND ``hatch_var`` are set.

    Task #31 (extended to the class per feedback_fix_the_class_not_the_cited_instance):
    every CLAUDE_AUTO_TEST_* deliberate-fail hatch in the codebase routes through
    this one helper. A production user who exports a specific hatch by accident
    will NOT also have ``CLAUDE_AUTO_TEST_HARNESS=1`` exported, so the hatch
    stays inert. tests/run.sh exports the sentinel once at the top of every test
    invocation, so the existing hatches (NO_TICK_LOCK, NO_REENQUEUE,
    NO_STALENESS_CHECK, FORCE_THREETIER_GATING, NO_RECOMPUTE, NO_LOCK,
    NO_ATTEMPT_CHECK, NO_STALLED_RECOVERY) and any future hatches inherit the
    fence for free. Deterministic, grep-checkable mechanism — composes with
    feedback_deterministic_over_probabilistic_v1.
    """
    return (
        os.environ.get("CLAUDE_AUTO_TEST_HARNESS") == "1"
        and os.environ.get(hatch_var) == "1"
    )


def is_iteration_disabled() -> bool:
    """Return True iff the operator has set ``CLAUDE_AUTO_DISABLE_ITERATION=1``.

    The iteration kill-switch — a REAL operator escape hatch, not a test-only
    hatch. When set, ``tick.advance_iteration_loop`` short-circuits and the
    standard predicate-met flow takes over (the run exits as if no iteration
    block existed on the ledger). Useful for emergency rollback of an
    outcomes-gated recipe without redeploying.

    Originally (v0.3.0 U4) this routed through ``test_hatch_enabled`` and
    therefore ALSO required ``CLAUDE_AUTO_TEST_HARNESS=1`` — making it inert
    in production. v0.3.0 F5 unfences it: the var is now a runtime-tunable
    operator knob (CRIT-2 + rel-3). Composes with
    feedback_deterministic_over_probabilistic_v1: env-var presence is a
    deterministic, grep-checkable mechanism.
    """
    return os.environ.get("CLAUDE_AUTO_DISABLE_ITERATION") == "1"


def coerce_confidence(confidence):
    """Clamp a confidence to [0.0, 1.0]; non-numeric/bool -> 0.0 (treated as low).

    The ONE confidence clamp for the launch classifiers. Consolidated (U6) from
    two byte-identical private copies that each carried a load-bearing SAFETY
    contract: ``lib/launch-gate.py::_coerce_confidence`` (a SAFETY gate — a bad
    value must bias to LOW so the launch shows the chooser rather than skipping
    it) and ``lib/recommender.py::_coerce_confidence`` (low confidence ->
    escalate). The clamp semantics are identical, so this shared helper is safe;
    each caller keeps its own intent comment because the *direction* the safe
    degrade protects differs.

    A bad value must never crash and must degrade toward LOW confidence. ``bool``
    is rejected explicitly because ``isinstance(True, int)`` is True in Python and
    True/False are not meaningful confidences. An out-of-range value clamps
    (``>1.0 -> 1.0`` = max confidence; ``<0.0 -> 0.0`` = no confidence).
    """
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        return 0.0
    if confidence < 0.0:
        return 0.0
    if confidence > 1.0:
        return 1.0
    return float(confidence)


def plan_step_sequencer(ledger, *, sequence):
    """Pure plan-loop sequencer shared by both adapters (U10).

    Collapses the byte-identical ``_next_plan_step`` skeleton that lived in
    ``adapter-ce.py`` and ``adapter-native.py``. The ONLY thing that differed
    between the two was the transition ``sequence``; the coherence guard and the
    ``plan_step is None`` first-step logic were identical, so they live here once.

    ``sequence`` is the per-adapter ordered plan steps EXCLUDING the terminal
    ``done`` — CE passes ``("plan", "deepen", "review_plan")`` and native passes
    ``("plan", "review_plan")`` (native has no deepen step). ``plan_step`` is a
    real validated ledger field (``ledger_core.PLAN_STEPS``) that the tick persists
    via ``set_loop(plan_step=step)``; both adapters read it identically and this
    sequencer keeps the ``None``-tolerance native already relied on. No IO — the
    engine persists the returned step; the adapter never writes the ledger (§1).

    §4.1 coherence guard runs FIRST (livelock hazard): once a ``review_plan``
    round has closed the gaps (``gaps_open == 0``) the next call MUST return
    ``"done"``. It is keyed on ``plan_step in ("review_plan", "done")`` specifically
    because ``gaps_open`` is 0 by default before any review has run — the guard
    must only fire AFTER a real review pass, else the loop would never start.
    """
    epr = ledger.get("exit_predicate_result") or {}
    plan_step = ledger.get("plan_step")
    if plan_step in ("review_plan", "done") and epr.get("gaps_open", 0) == 0:
        return "done"
    if plan_step is None:
        return sequence[0]
    if plan_step in sequence:
        idx = sequence.index(plan_step)
        if idx + 1 < len(sequence):
            return sequence[idx + 1]
        # Last step (review_plan) reached with gaps STILL open (else the guard
        # above fired) -> loop back to the first POST-plan step: sequence[1].
        # This is deliberately NOT sequence[-2]: for native (["plan",
        # "review_plan"]) that would be "plan" and wrongly re-plan from scratch;
        # sequence[1] loops CE back to "deepen" and native back to "review_plan".
        return sequence[1]
    return "done"
