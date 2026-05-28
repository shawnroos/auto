#!/usr/bin/env bash
# auto v0.4.0 U1: smart-entry hypothesis detector (READ-ONLY).
#
# Bare `/auto` should "gather context and determine where to pick up" (field
# feedback 2026-05-25). The DETECTION is deterministic and lives here
# (deterministic-over-probabilistic for load-bearing infra). The ROUTING — what
# the driver does with the verdict — lives in `skills/auto-driver`.
#
# v0.4.0 (this version): emits a JSON HYPOTHESIS object instead of a TSV
# verdict line. The decision tree itself is unchanged from v0.2.x's tested
# logic; the *output shape* changed so the driver consumes one envelope rather
# than enumerating a verdict-tree case-by-case. KTD-1 of the v0.4.0 plan.
#
# JSON envelope (one line, machine-parseable):
#   {
#     "situation": "in-flight" | "ambiguous-runs" | "reviewed-plan"
#                | "multi-plan" | "raw",
#     "summary":   "one-line operator-facing description",
#     "ambiguity": null | { "kind": "choice"|"open",
#                           "question": "...",
#                           "options": [ {"label":"…","run_id":"…","description":"…"}* ] },
#       * "choice" — N-option pick-one (ambiguous-runs surface). Maps to
#         AskUserQuestion's options array. NOT necessarily 2 — N may be 2..N.
#       * "open"   — freeform text (raw surface). Maps to AskUserQuestion's
#         open-question shape; `options` is the empty array.
#     "single_plan": { "path": "...", "run_id_hint": "..." } | null,
#     "multi_plan":  { "paths": ["..."], "batch_id_hint": "..." } | null,
#     "in_flight":   { "run_id": "...", "run_ids": ["..."] } | null
#   }
#
# Situations:
#   in-flight       — exactly ONE run with exit_predicate_result.met == false.
#                     `single_plan` carries the run via in_flight.run_id;
#                     ambiguity null → driver resumes silently.
#   ambiguous-runs  — MORE THAN ONE in-flight run; ambiguity carries a binary
#                     options array of run-ids + their goal_intent strings so
#                     AskUserQuestion shows what each run was started for.
#   reviewed-plan   — no in-flight run; exactly one reviewed plan present.
#                     single_plan.path filled; ambiguity null.
#   multi-plan      — no run, MORE THAN ONE plan. multi_plan.paths filled;
#                     ambiguity null (the driver fans out via auto-spawn.py).
#                     v0.4.0 RENAME of v0.2.x's `ambiguous-plans` — under the
#                     v0.4.0 fanout model, multiple plans is a fanout signal,
#                     not an ambiguity to resolve. (KTD-1.)
#   raw             — no run, no plan (clean OR dirty tree). ambiguity is an
#                     open "what should we work on?" question so the driver
#                     can route to /ce-plan or a freeform handoff. When the
#                     working tree is dirty, summary includes branch + diff
#                     context so the operator sees what they were doing —
#                     but the situation is still raw because there's no
#                     deterministic dispatch from a diff alone.
#
# READ-ONLY: scans the ledger dir + plan dirs + git status; never writes.
# Repo root resolved by the Python (CLAUDE_AUTO_REPO or walk-up).
#
# Hypothesis-shape stability (NO TSV legacy): the previous TSV consumer was
# `skills/auto-driver` only (one consumer, updated lock-step in U4). No
# back-compat wrapper, no shim — the JSON output is the contract.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::detect() {
  "$CLAUDE_AUTO_PYTHON3" - <<'PYEOF'
import sys, os, json, glob, subprocess


def _repo_root():
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    d = os.getcwd()
    while d and d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, ".claude", "auto")):
            return d
        d = os.path.dirname(d)
    return os.getcwd()


def _emit(hyp):
    """Print the hypothesis envelope as ONE JSON line and exit 0.

    rel-001 parity with v0.2.x: callers expect exit 0 on any non-fatal path.
    """
    json.dump(hyp, sys.stdout)
    sys.stdout.write("\n")
    raise SystemExit(0)


def _safe_envelope(situation, summary, *, ambiguity=None, single_plan=None,
                   multi_plan=None, in_flight=None):
    """Build the canonical hypothesis dict — all slots present, unknowns null.

    Every consumer can rely on the same keys existing, so a Python/jq reader
    that asks for `.in_flight.run_id` never trips on `KeyError: in_flight`.

    v0.4.1 (plan 004 KTD-4): adds the `workspace` block + the derived
    `workspace_action`. `workspace` comes from auto_workspace.detect(repo);
    the action is computed from (workspace.status, situation) so the skill
    has one field to branch on instead of reconstructing the policy itself.
    """
    workspace = _detect_workspace_safe()
    return {
        "situation": situation,
        "summary": summary,
        "ambiguity": ambiguity,
        "single_plan": single_plan,
        "multi_plan": multi_plan,
        "in_flight": in_flight,
        "workspace": workspace,
        "workspace_action": _workspace_action(workspace, situation),
    }


def _detect_workspace_safe():
    """Run auto_workspace.detect with rel-001-style safe degrade.

    The detector subprocess-calls cmux to check workspace liveness; that
    can fail or hang on a sick cmux. We DON'T want a sick cmux breaking
    the hypothesis envelope — so on any failure, return a degraded
    workspace block that routes to action=none (skill falls back to
    v0.4.0 workspace-per-plan dispatch).
    """
    try:
        repo = _repo_root()
        # Import lazily to avoid the import cost on every detect call.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "auto_workspace",
            os.path.join(script_dir, "auto-workspace.py"),
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.detect(repo)
    except Exception:
        return {
            "status": "unmarked",
            "marker_path": None,
            "workspace_id": None,
            "left_pane_id": None,
            "env_workspace_id": os.environ.get("CMUX_WORKSPACE_ID"),
            "marker_stale": False,
        }


def _workspace_action(workspace, situation):
    """Compute the action the skill should take re: workspace handling.

    Returns one of: none, use, create, recreate, ambiguous.

    Routing rules (KTD-4):
      * status=project, situation routes to dispatch (reviewed-plan,
        multi-plan, in-flight) → use (skill dispatches tabs in this
        workspace; v0.4.1 spawn-side path)
      * status=unmarked + marker_stale=True, situation is
        reviewed-plan/multi-plan → recreate (skill should overwrite
        the stale marker with a fresh workspace)
      * status=unmarked (no marker yet), situation is reviewed-plan
        or multi-plan → create (skill creates first, then dispatches)
      * status=non-project, situation is reviewed-plan/multi-plan →
        ambiguous (skill asks: switch / create / one-off)
      * other situations (raw, in-flight, ambiguous-runs) → none
        (workspace setup isn't relevant; skill dispatches per
        v0.4.0 behavior)
    """
    status = workspace.get("status")
    dispatchable = situation in ("reviewed-plan", "multi-plan")
    if not dispatchable:
        return "none"
    if status == "project":
        return "use"
    if status == "non-project":
        return "ambiguous"
    if status == "unmarked" and workspace.get("marker_stale"):
        return "recreate"
    if status == "unmarked":
        return "create"
    return "none"


def _read_in_flight(ledger_dir):
    """Return [(run_id, goal_intent_str_or_None)] for not-met runs.

    Mtime-desc so the freshest run comes first — the in-flight branch picks
    [0] when there's exactly one, and the ambiguous-runs branch lists them.
    Malformed ledgers are skipped with a stderr note (parity with v0.2.x).
    """
    out = []
    for path in sorted(glob.glob(os.path.join(ledger_dir, "*.json")),
                       key=os.path.getmtime, reverse=True):
        try:
            with open(path) as f:
                led = json.load(f)
        except (OSError, ValueError) as exc:
            sys.stderr.write(
                "auto: skipping malformed ledger %s: %s\n" % (path, exc)
            )
            continue
        if not isinstance(led, dict) or "exit_predicate_result" not in led:
            continue
        if led["exit_predicate_result"].get("met", False):
            continue
        run_id = led.get("run_id") or os.path.splitext(os.path.basename(path))[0]
        # v0.4.0 KTD-2: surface goal_intent so the ambiguous-runs options
        # carry "what was this started for" rather than just a slug. None on
        # legacy ledgers (pre-v0.4.0) is fine — the renderer falls back to
        # run_id.
        out.append((run_id, led.get("goal_intent")))
    return out


def _discover_plans(repo):
    """All plan files under the conventional locations, sorted + de-duped."""
    plans = []
    for pat in ("docs/plans/*.md", "plans/*.md", "*-plan.md"):
        plans.extend(glob.glob(os.path.join(repo, pat)))
    return sorted(set(plans))


def _has_uncommitted_diff(repo):
    """True iff git status reports a non-empty working tree.

    Falls back to False on any git failure (no git, not in a repo, etc.) —
    the worst case is we route to `raw` instead of `dirty-tree`, which is
    the SAFER surface (recommends /ce-plan rather than acting on a tree we
    couldn't inspect).
    """
    try:
        result = subprocess.run(
            ["git", "-C", repo, "status", "--porcelain"],
            capture_output=True, text=True, check=False,
        )
    except (OSError, FileNotFoundError):
        return False
    if result.returncode != 0:
        return False
    return bool(result.stdout.strip())


def _current_branch(repo):
    """Return the current branch name, or None if detached/git-unavailable."""
    try:
        result = subprocess.run(
            ["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, check=False,
        )
    except (OSError, FileNotFoundError):
        return None
    if result.returncode != 0:
        return None
    name = result.stdout.strip()
    return name if name and name != "HEAD" else None


def _diff_summary(repo):
    """Short text summary of the uncommitted diff for the dirty-tree case.

    Format: "<N> file(s) changed" — keeps the summary one line; the driver
    surfaces the full diff via the operator's normal git inspection.
    """
    try:
        result = subprocess.run(
            ["git", "-C", repo, "status", "--porcelain"],
            capture_output=True, text=True, check=False,
        )
    except (OSError, FileNotFoundError):
        return "uncommitted changes"
    if result.returncode != 0:
        return "uncommitted changes"
    lines = [ln for ln in result.stdout.splitlines() if ln.strip()]
    n = len(lines)
    return "%d file%s changed" % (n, "" if n == 1 else "s")


# CLI-004: on any unexpected error path, emit a safe `raw` envelope (the most
# conservative — the driver recommends /ce-plan, does not start a run). An
# empty stdout would leave the driver with no shape to parse; `raw` is the
# fall-closed surface. rel-001: never break hook callers — always exit 0.
try:
    repo = _repo_root()

    # ── Step 1: in-flight scan. ────────────────────────────────────────────
    ledger_dir = os.path.join(repo, ".claude", "auto")
    in_flight = _read_in_flight(ledger_dir)

    if len(in_flight) == 1:
        run_id, goal_intent = in_flight[0]
        summary = "resuming `%s`" % run_id
        if goal_intent:
            summary = "resuming `%s` — %s" % (run_id, goal_intent)
        _emit(_safe_envelope(
            "in-flight", summary,
            in_flight={"run_id": run_id, "run_ids": [run_id]},
        ))

    if len(in_flight) > 1:
        options = []
        for run_id, goal_intent in in_flight:
            description = goal_intent if goal_intent else run_id
            options.append({
                "label": run_id,
                "run_id": run_id,
                "description": description,
            })
        _emit(_safe_envelope(
            "ambiguous-runs",
            "%d in-flight runs — pick one to resume" % len(in_flight),
            ambiguity={
                "kind": "choice",  # N-option pick-one → AskUserQuestion options
                "question": "Multiple in-flight runs — which do you want to resume?",
                "options": options,
            },
            in_flight={"run_id": None, "run_ids": [r for r, _ in in_flight]},
        ))

    # ── Step 2: plan discovery. ────────────────────────────────────────────
    plans = _discover_plans(repo)

    if len(plans) == 1:
        plan_path = os.path.relpath(plans[0], repo)
        # Operator-facing summary names the recipe + seam policy explicitly
        # (review round 1 finding C-5: v0.4.0 silently runs full a1 on
        # already-reviewed plans where v0.3.x required a confirm. Surface
        # the action in the one-line summary so the operator can interrupt
        # if the inference is wrong, rather than discovering it after the
        # plan-loop has already begun deepening).
        _emit(_safe_envelope(
            "reviewed-plan",
            "starting `%s` (recipe a1, auto-through seam — pass `--review-plan` to pause)"
            % plan_path,
            single_plan={"path": plan_path, "run_id_hint": None},
        ))

    if len(plans) > 1:
        # v0.4.0 RENAME of v0.2.x's `ambiguous-plans` → `multi-plan`. Multiple
        # plans is a fanout SIGNAL (the v0.4.0 driver dispatches one run per
        # plan via auto-spawn.py), not an ambiguity for the operator to
        # resolve. `ambiguity` stays null.
        rel_paths = [os.path.relpath(p, repo) for p in plans]
        _emit(_safe_envelope(
            "multi-plan",
            "%d plans — fanning out to %d worktrees" % (len(plans), len(plans)),
            multi_plan={"paths": rel_paths, "batch_id_hint": None},
        ))

    # ── Step 3: raw — no run, no plan. ────────────────────────────────────
    # Includes both clean and dirty trees: review round 1 finding C-2/C-3
    # surfaced that a separate `dirty-tree` situation had no actionable
    # dispatch (the skill's `<derived-args>` were never specifiable from a
    # diff alone) AND that the dirty detection depended on downstream repos
    # gitignoring `.claude/` — an unfixable assumption for a shipped plugin.
    # The fix is to drop `dirty-tree` as a situation and inform `raw`'s
    # summary with whatever git context we have. The operator still answers
    # one open question; the engine doesn't pretend it can dispatch a run
    # without a plan or explicit intent.
    summary = "no plan, no in-flight run — what should we work on?"
    if _has_uncommitted_diff(repo):
        branch = _current_branch(repo) or "(detached)"
        diff = _diff_summary(repo)
        summary = (
            "no plan; working on branch `%s` (%s) — what should we work on?"
            % (branch, diff)
        )
    _emit(_safe_envelope(
        "raw",
        summary,
        ambiguity={
            "kind": "open",
            "question": "What should we work on?",
            "options": [],
        },
    ))
except SystemExit:
    raise
except BaseException as exc:
    # CLI-004: emit the safe `raw` fallback on any unexpected error so the
    # driver has an envelope to consume (rather than empty stdout). Surface
    # the cause on stderr for diagnosis.
    sys.stderr.write("auto: detector hit unexpected error: %s\n" % exc)
    json.dump({
        "situation": "raw",
        "summary": "detector error — recommend /ce-plan",
        "ambiguity": {
            "kind": "open",
            "question": "What should we work on?",
            "options": [],
        },
        "single_plan": None,
        "multi_plan": None,
        "in_flight": None,
    }, sys.stdout)
    sys.stdout.write("\n")
    raise SystemExit(0)
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::detect "$@"
fi
