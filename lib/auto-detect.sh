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
#                | "multi-plan" | "conversation-context" | "raw",
#     "summary":   "one-line operator-facing description",
#     "ambiguity": null | { "kind": "choice"|"open",
#                           "question": "...",
#                           "options": [ {"label":"…", ...payload, "description":"…"}* ] },
#       * "choice" — N-option pick-one. Maps to AskUserQuestion's options array.
#         NOT necessarily 2 — N may be 2..N. Surfaces: ambiguous-runs +
#         stale in-flight (options carry `run_id`); multi-plan (per-plan options
#         carry `path`, plus a null-`path` fan-out-all option). The payload key
#         per option is situation-specific — the driver table says which.
#       * "open"   — freeform text (raw surface). Maps to AskUserQuestion's
#         open-question shape; `options` is the empty array.
#     "single_plan": { "path": "...", "run_id_hint": "..." } | null,
#     "multi_plan":  { "paths": ["..."], "batch_id_hint": "..." } | null,
#     "in_flight":   { "run_id": "...", "run_ids": ["..."] } | null,
#     "recommendation": null  (v0.6.0 U1 — present on EVERY envelope, incl. the
#                       catastrophic-error fallback; the detector has no
#                       transcript access so it always emits null. The DRIVER
#                       computes the real recommendation in U2/U3 — see
#                       skills/auto-driver + lib/recommender.py.)
#   }
#
# Situations:
#   in-flight       — exactly ONE run with exit_predicate_result.met == false.
#                     `in_flight.run_id` carries the run. FRESH run (ledger
#                     touched within CLAUDE_AUTO_INFLIGHT_TTL_SECONDS, default
#                     1 day) → ambiguity null → driver resumes silently. STALE
#                     run (idle past the TTL) → ambiguity is a choice (resume vs
#                     start-fresh) so the driver ASKS rather than silently
#                     auto-resuming an abandoned run (2026-06 misfire fix).
#   ambiguous-runs  — MORE THAN ONE in-flight run; ambiguity carries a binary
#                     options array of run-ids + their goal_intent strings so
#                     AskUserQuestion shows what each run was started for.
#   reviewed-plan   — no in-flight run; exactly one reviewed plan present.
#                     single_plan.path filled; ambiguity null.
#   multi-plan      — no run, MORE THAN ONE plan. multi_plan.paths filled.
#                     v0.4.0 made this a SILENT fanout (ambiguity null, one
#                     worktree per plan via auto-spawn.py). The 2026-06 misfire
#                     showed auto-spawning N worktrees on whatever plans sit in
#                     docs/plans/ is the highest-blast-radius path — so it now
#                     sets `ambiguity` (a choice: run one plan, or fan out all)
#                     and the driver CONFIRMS before spawning. situation stays
#                     multi-plan and paths are preserved for a confirmed fanout.
#   conversation-context (v0.6.0 U1; v0.7.x U3) — no in-flight run and no LIVE
#                     plan (no plan at all, OR every discovered plan is STALE),
#                     but the DRIVER has signalled a rich current conversation
#                     worth routing on (env var CLAUDE_AUTO_CONVERSATION_SIGNAL
#                     set). A stale plan set no longer blocks it — but a FRESH
#                     plan (reviewed-plan) still wins over conversation.
#                     The detector has no transcript access (single-quote
#                     heredoc), so it cannot self-detect the conversation — it
#                     only honours the driver's signal. It emits the situation
#                     with an EMPTY (null) recommendation + ambiguity null; the
#                     driver classifies state + calls lib/recommender.py to fill
#                     in the recommendation, then dispatches or pre-dispatch
#                     escalates (skills/auto-driver, KTD-2/3/7). Without the
#                     signal this branch is skipped entirely and the engine
#                     falls through to `raw` (byte-unchanged from v0.4.x).
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
  # Pass the script's directory via argv[1] so the embedded Python can
  # locate sibling lib files (auto-workspace.py for the workspace probe
  # added in plan 004). The single-quoted heredoc disables shell
  # substitution, so script_dir must come through argv — referencing
  # an undefined `script_dir` inside the heredoc was the P0 bug surfaced
  # by the plan 004 round-1 review.
  local _det_dir
  _det_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" - "$_det_dir" <<'PYEOF'
import sys, os, json, glob, subprocess, time

script_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

# Staleness TTL for a SINGLE in-flight run. A run whose ledger has not been
# touched within this window is low-confidence: the detector keeps
# situation=in-flight but sets `ambiguity` so the driver ASKS (resume vs start
# fresh) instead of silently auto-resuming (2026-06 misfire: a 15-day-old,
# unrelated run resumed with no confirmation). Tunable; default 1 day.
try:
    INFLIGHT_TTL_SECONDS = int(os.environ.get("CLAUDE_AUTO_INFLIGHT_TTL_SECONDS", "86400"))
except (TypeError, ValueError):
    INFLIGHT_TTL_SECONDS = 86400
# Floor at 0: a negative TTL would make `age <= TTL` ~never true and force a
# confirm on EVERY single-run resume (gate stuck open). 0 means "always ask".
if INFLIGHT_TTL_SECONDS < 0:
    INFLIGHT_TTL_SECONDS = 0

# Bound for the per-detect `git rev-parse` so a hung filesystem can't wedge the
# read-only detector (degrade-safe contract: never block the hook caller).
try:
    _GIT_TIMEOUT_SECONDS = float(os.environ.get("CLAUDE_AUTO_GIT_TIMEOUT_SECONDS", "5"))
except (TypeError, ValueError):
    _GIT_TIMEOUT_SECONDS = 5.0
if _GIT_TIMEOUT_SECONDS <= 0:
    _GIT_TIMEOUT_SECONDS = 5.0


def _fmt_age(seconds):
    """Coarse human age string for an operator-facing prompt (e.g. '15d')."""
    s = int(seconds)
    if s >= 86400:
        return "%dd" % (s // 86400)
    if s >= 3600:
        return "%dh" % (s // 3600)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


def _git_worktree_root(start):
    """The git worktree top for ``start``, or None when not in a git tree.

    ``git rev-parse --show-toplevel`` returns the WORKTREE's own root (a
    worktree reports itself, not the host repo) — exactly the upper bound we
    want for the per-worktree ledger + plan scan.

    This runs on the hot path of every detect, so it carries a timeout: a hung
    git (sick NFS/autofs mount mid-unmount) must NOT wedge the detector — a hang
    precedes any Python exception, so the outer degrade-safe handler can't fire.
    On timeout/spawn-failure we return None → the caller falls back to cwd.
    """
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False, cwd=start,
            timeout=_GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        # OSError: git absent / cwd gone. SubprocessError covers TimeoutExpired.
        return None
    if r.returncode != 0:
        return None
    top = r.stdout.strip()
    return top or None


def _repo_root():
    # NOTE: logic mirrors lib/_bootstrap.py::resolve_repo() — keep the two in
    # sync. The detector deliberately INLINES its own copy (dependency-free,
    # only os/subprocess) so this load-bearing core resolver can't be broken by
    # a sick _bootstrap import; the embedded heredoc otherwise wraps every
    # _bootstrap-backed call (e.g. _detect_workspace_safe) in a degrade-safe
    # try/except.
    # CLAUDE_AUTO_REPO is the explicit pin (sub-runs set it); honor it verbatim.
    env = os.environ.get("CLAUDE_AUTO_REPO")
    if env:
        return env
    # Walk up for an existing ``.claude/auto``, but NEVER above the git
    # worktree root. A fresh worktree has no ``.claude/auto`` yet — without this
    # bound the walk-up escapes to ``$HOME/.claude/auto`` and the detector
    # scans the user's global junk drawer (the 2026-06 mis-root field bug: a
    # stale 15-day $HOME run surfaced as `in-flight`, $HOME/docs/plans as a
    # `multi-plan` fanout, and the worktree's own plan was never in scope).
    # With no git tree, cwd is the answer — we do not walk up at all.
    start = os.getcwd()
    boundary = _git_worktree_root(start)
    d = start
    while d and d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, ".claude", "auto")):
            return d
        if boundary is None:
            break
        if os.path.abspath(d) == os.path.abspath(boundary):
            break
        d = os.path.dirname(d)
    return boundary or os.getcwd()


def _emit(hyp):
    """Print the hypothesis envelope as ONE JSON line and exit 0.

    rel-001 parity with v0.2.x: callers expect exit 0 on any non-fatal path.
    """
    json.dump(hyp, sys.stdout)
    sys.stdout.write("\n")
    raise SystemExit(0)


def _safe_envelope(situation, summary, *, ambiguity=None, single_plan=None,
                   multi_plan=None, in_flight=None, recommendation=None):
    """Build the canonical hypothesis dict — all slots present, unknowns null.

    Every consumer can rely on the same keys existing, so a Python/jq reader
    that asks for `.in_flight.run_id` never trips on `KeyError: in_flight`.

    v0.4.1 (plan 004 KTD-4): adds the `workspace` block + the derived
    `workspace_action`. `workspace` comes from auto_workspace.detect(repo);
    the action is computed from (workspace.status, situation) so the skill
    has one field to branch on instead of reconstructing the policy itself.

    v0.6.0 (U1): adds the `recommendation` slot. The detector ALWAYS emits null
    here — it has no transcript access (single-quote heredoc), so it cannot
    classify the conversation. The DRIVER (skills/auto-driver) computes the real
    recommendation via lib/recommender.py and consumes it; the key exists on
    every envelope so a reader never trips on its absence (the same shape
    contract the other slots honour).
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
        "recommendation": recommendation,
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
      * status=recreate (marker present but its cmux workspace is gone,
        marker_stale=True), situation is reviewed-plan/multi-plan →
        recreate (skill should overwrite the stale marker with a fresh
        workspace)
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
    # detect() reports "recreate" for a stale marker (its cmux workspace is
    # gone). Tolerate the older "unmarked"+marker_stale shape too, in case an
    # out-of-tree detect() predates the distinct-status fix.
    if status == "recreate" or (status == "unmarked" and workspace.get("marker_stale")):
        return "recreate"
    if status == "unmarked":
        return "create"
    return "none"


def _read_in_flight(ledger_dir):
    """Return [(run_id, goal_intent_str_or_None, mtime)] for not-met runs.

    Mtime-desc so the freshest run comes first — the in-flight branch picks
    [0] when there's exactly one, and the ambiguous-runs branch lists them.
    The mtime rides along so the single-run branch can gate on staleness
    (2026-06 misfire fix) without re-stat-ing the file.
    Malformed ledgers are skipped with a stderr note (parity with v0.2.x).
    """
    # Stat each candidate ONCE behind its own guard, BEFORE sorting. A ledger
    # deleted mid-scan (concurrent run / cleanup sweep) would otherwise raise
    # OSError from the `sorted(key=os.path.getmtime)` callback and degrade the
    # WHOLE detector to `raw` — hiding every in-flight run over a transient
    # race. Skipping the vanished file is the correct, local degrade.
    pairs = []
    for path in glob.glob(os.path.join(ledger_dir, "*.json")):
        try:
            pairs.append((path, os.path.getmtime(path)))
        except OSError:
            continue
    pairs.sort(key=lambda pm: pm[1], reverse=True)  # mtime-desc: freshest first

    out = []
    for path, mtime in pairs:
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
        # run_id. mtime was captured above (single stat, no TOCTOU re-stat).
        out.append((run_id, led.get("goal_intent"), mtime))
    return out


def _discover_plans(repo):
    """All plan files under the conventional locations, sorted + de-duped."""
    plans = []
    for pat in ("docs/plans/*.md", "plans/*.md", "*-plan.md"):
        plans.extend(glob.glob(os.path.join(repo, pat)))
    return sorted(set(plans))


def _rank_plans_safe(repo):
    """Rank discovered plans by freshness via lib/plan-rank.py (U1).

    Returns a list of {"path","freshness","sort_ts"} dicts, freshest first.
    Imported lazily + degrade-safe (rel-001): if the ranking module can't load
    or raises, fall back to treating EVERY plan as `fresh` — that reproduces the
    pre-U2 behavior (a lone plan → reviewed-plan; multiple → a fan-out-capable
    ask), so a broken ranker can never wedge the read-only detector.
    """
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "plan_rank", os.path.join(script_dir, "plan-rank.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.rank(repo)
    except Exception:
        return [{"path": os.path.relpath(p, repo), "freshness": "fresh",
                 "sort_ts": 0.0} for p in _discover_plans(repo)]


def _emit_reviewed_plan(plan_path):
    """Emit the reviewed-plan envelope for a single unambiguous plan."""
    _emit(_safe_envelope(
        "reviewed-plan",
        "starting `%s` (recipe w, work-only — reviewed plan goes straight "
        "to the work-loop; pass `--recipe a1` to re-plan from scratch)"
        % plan_path,
        single_plan={"path": plan_path, "run_id_hint": None},
    ))


def _emit_multi_plan(targets, include_fanout):
    """Emit the multi-plan ask over `targets` (a ranked-plan sublist).

    `include_fanout` adds the null-path "Fan out all N" option — offered only
    when the targets are genuinely live (>=2 fresh plans). For an all-stale set
    the fan-out-all footgun is SUPPRESSED (2026-06 misfire: never offer to spawn
    N worktrees on old docs/plans/ clutter) and each option is staleness-marked.
    """
    rel_paths = [p["path"] for p in targets]
    all_stale = all(p["freshness"] == "stale" for p in targets)
    options = []
    for p in targets:
        if p["freshness"] == "stale":
            desc = "stale plan — run only this one"
        else:
            desc = "run only this plan"
        options.append({"label": os.path.basename(p["path"]),
                        "path": p["path"], "description": desc})
    if include_fanout:
        options.append({
            "label": "Fan out all %d" % len(rel_paths),
            "path": None,  # null path → fan out, using multi_plan.paths
            "description": "create %d worktrees, one per plan" % len(rel_paths),
        })
    if all_stale:
        summary = ("%d plans found, all stale — run one, or start fresh"
                   % len(rel_paths))
        question = ("%d plans found but all look stale — run one anyway, or "
                    "start fresh?" % len(rel_paths))
    else:
        summary = ("%d live plans — confirm fanout to %d worktrees, or run "
                   "just one" % (len(rel_paths), len(rel_paths)))
        question = ("%d live plans found — fan out to %d worktrees, or run "
                    "just one?" % (len(rel_paths), len(rel_paths)))
    _emit(_safe_envelope(
        "multi-plan", summary,
        ambiguity={"kind": "choice", "question": question, "options": options},
        multi_plan={"paths": rel_paths, "batch_id_hint": None},
    ))


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
        run_id, goal_intent, mtime = in_flight[0]
        in_flight_block = {"run_id": run_id, "run_ids": [run_id]}
        # Fresh iff the ledger was last touched within [now-TTL, now]. A delta
        # OUTSIDE that window — too old (stale) OR negative (future mtime: clock
        # skew, restored backup, cross-machine sync) — is low-confidence and
        # must ASK. Treating a future mtime as "fresh" would silently auto-resume
        # on a skewed clock, the exact misfire the gate prevents (fail-safe ⇒
        # ask). `else` makes the branches mutually exclusive independent of
        # _emit's SystemExit so a future refactor can't double-emit.
        delta = time.time() - mtime
        if 0 <= delta <= INFLIGHT_TTL_SECONDS:
            # Fresh, high-confidence: silent resume (unchanged behavior).
            summary = "resuming `%s`" % run_id
            if goal_intent:
                summary = "resuming `%s` — %s" % (run_id, goal_intent)
            _emit(_safe_envelope(
                "in-flight", summary,
                in_flight=in_flight_block,
            ))
        else:
            # Stale/anomalous, low-confidence: keep situation=in-flight but ASK
            # (resume vs start-fresh) instead of silently auto-resuming.
            # ambiguity non-null routes the driver to AskUserQuestion.
            age_str = _fmt_age(max(0.0, delta))
            label_desc = goal_intent if goal_intent else run_id
            _emit(_safe_envelope(
                "in-flight",
                "stale in-flight run `%s` (idle %s) — resume it, or start fresh?"
                % (run_id, age_str),
                ambiguity={
                    "kind": "choice",
                    "question": "Found a stale in-flight run (idle %s) — resume "
                                "it, or start fresh?" % age_str,
                    "options": [
                        {"label": "Resume %s" % run_id, "run_id": run_id,
                         "description": "%s — idle %s" % (label_desc, age_str)},
                        {"label": "Start fresh", "run_id": None,
                         "description": "Ignore the stale run; pick new work"},
                    ],
                },
                in_flight=in_flight_block,
            ))

    if len(in_flight) > 1:
        options = []
        for run_id, goal_intent, _mtime in in_flight:
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
            in_flight={"run_id": None, "run_ids": [r for r, _g, _m in in_flight]},
        ))

    # ── Step 2: plan discovery + freshness ranking (U1/U2). ────────────────
    # Plans are ranked fresh (the one you're working on — uncommitted or a
    # recent commit) vs stale (old docs/plans/ clutter). Routing keys on the
    # FRESH count, not the raw plan count, so a live plan is inferred instead of
    # drowned by stale siblings (the 2026-06 field misfire: 6 plans, 1 authored
    # this session, lost to a fan-out-all ask over all six).
    ranked = _rank_plans_safe(repo)
    fresh = [p for p in ranked if p["freshness"] == "fresh"]

    # Exactly one FRESH plan (among any number of stale siblings) → the detector
    # INFERS it as the reviewed plan (a live plan beats conversation, always).
    # A lone plan with NO fresh signal is reviewed-plan too — UNLESS the driver
    # signalled a rich conversation, in which case a lone STALE plan yields to it
    # (Step 2.5): "every discovered plan is stale" preempts at N=1 just as it does
    # at N>=2, so adding/removing a stale sibling can't flip the outcome. `_emit_*`
    # raise SystemExit, so these guards are mutually exclusive with the block below.
    if len(fresh) == 1:
        _emit_reviewed_plan(fresh[0]["path"])
    if len(ranked) == 1 and not os.environ.get("CLAUDE_AUTO_CONVERSATION_SIGNAL"):
        _emit_reviewed_plan(ranked[0]["path"])

    if len(ranked) > 1:
        # >=2 fresh → multiple genuinely-live plans: ask over the FRESH set with
        # fan-out offered (fanning out over live plans is legitimate). fresh==0
        # (all stale) → [Step 2.5 conversation-context can PREEMPT this when the
        # driver signals a rich session]; absent the signal, ask over the stale
        # set with staleness marked and the fan-out-all footgun suppressed.
        if len(fresh) >= 2:
            _emit_multi_plan(fresh, include_fanout=True)
        elif not os.environ.get("CLAUDE_AUTO_CONVERSATION_SIGNAL"):
            _emit_multi_plan(ranked, include_fanout=False)
        # else: all stale AND the driver signalled a rich conversation → fall
        # through to Step 2.5, where conversation-context preempts the stale ask.

    # ── Step 2.5 (v0.6.0 U1; v0.7.x U3): conversation-context. ─────────────
    # Reached when there is no in-flight run and no LIVE plan to act on — either
    # no plan at all, OR (v0.7.x U3 preemption) every discovered plan is STALE
    # and the driver signalled a rich current conversation. The Step-2 plan
    # branch falls through to here in the all-stale + signal case, so a live
    # session preempts an ask over old docs/plans/ clutter (the reworked
    # precedence: conversation beats stale plans, but a FRESH plan — reviewed-
    # plan, emitted above — still wins over conversation).
    #
    # The detector has NO transcript access (the single-quote heredoc disables
    # shell substitution and carries no conversation), so it cannot self-classify
    # — it only honours the driver's env-var signal, which the auto-driver sets
    # inline before loading the hypothesis (U3). An argv signal would carry
    # unstated invocation-plumbing work (the heredoc forwards only `_det_dir`);
    # an env var is read cleanly inside the heredoc with no plumbing change.
    #
    # The branch emits an EMPTY (null) recommendation + ambiguity null: the
    # driver computes the recommendation via lib/recommender.py (U2) and either
    # dispatches the entry recipe or pre-dispatch escalates (U3). When the signal
    # is UNSET, this branch is skipped and the engine falls through to `raw` (and
    # an all-stale plan set was already emitted as a multi-plan ask above).
    if os.environ.get("CLAUDE_AUTO_CONVERSATION_SIGNAL"):
        _emit(_safe_envelope(
            "conversation-context",
            "no live plan, no in-flight run — recommending a ce-family step "
            "from the current conversation",
            recommendation=None,
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
        # The catastrophic-error fallback bypasses _safe_envelope, so it must
        # hand-carry EVERY envelope key — the nine-key shape contract holds on
        # EVERY path including this one. `workspace`/`workspace_action` use inline
        # safe defaults rather than calling _detect_workspace_safe(): this is the
        # last-resort handler, so it must not risk re-raising from the very
        # subsystem that may have failed. (v0.6.0 U1 added `recommendation`; the
        # workspace keys were the gap this closes.)
        "workspace": {
            "status": "unmarked", "marker_path": None, "workspace_id": None,
            "left_pane_id": None,
            "env_workspace_id": os.environ.get("CMUX_WORKSPACE_ID"),
            "marker_stale": False,
        },
        "workspace_action": "none",
        "recommendation": None,
    }, sys.stdout)
    sys.stdout.write("\n")
    raise SystemExit(0)
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::detect "$@"
fi
