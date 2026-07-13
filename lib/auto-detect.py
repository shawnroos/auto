#!/usr/bin/env python3
"""auto: smart-entry hypothesis detector — Python surface (U15 split).

The detection logic that used to live in a single-quoted bash heredoc inside
`lib/auto-detect.sh`. U15 (plan 2026-07-01-001) moved it into this sibling
module following the shipped `backend-ce.sh`/`backend-ce.py` precedent (KTD-3):
`auto-detect.sh` is now a thin shim that pins the interpreter, resolves
`script_dir`, and execs this file with `script_dir` as argv[1].

READ-ONLY: scans the ledger dir + plan dirs + git status; never writes. Repo
root resolved via `_bootstrap.resolve_repo` (CLAUDE_AUTO_REPO or walk-up).

The full JSON-envelope contract (situations, slots, staleness TTL) is documented
in `lib/auto-detect.sh`'s header comment — the shim is still the user-facing
entry point and carries the contract prose.

Three duplications the split killed — each now reaches back through `_bootstrap`
(KTD-3: "reach back for shared logic rather than re-inlining"):
  * `_repo_root()` (a clone of `resolve_repo`) → `_bootstrap.resolve_repo`.
  * the importlib load of a sibling lib module (appeared TWICE — for
    `auto-workspace.py` and for `plan-rank.py`) → `_bootstrap.load_lib_module`.
  * `_read_in_flight`'s inline `open`+`json.load`+`isinstance(dict)` guard →
    `_bootstrap.load_ledger_safe`. NOTE: `iter_worktree_ledgers` (the helper the
    plan named) yields `(run_id, led)` with NO file mtime and NO path — but the
    detector needs each ledger's mtime for BOTH the single-run staleness gate
    and the freshest-first (mtime-desc) ordering of the ambiguous-runs options.
    So the scan keeps its own glob+getmtime skeleton (byte-identical output) and
    swaps only the parse/guard for `load_ledger_safe` (the exact primitive
    `iter_worktree_ledgers` wraps internally).
"""

import sys, os, json, glob, subprocess, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bootstrap import resolve_repo, load_lib_module, load_ledger_safe  # noqa: E402

# script_dir arrives as argv[1] from the shim. The sibling-module loads now go
# through `_bootstrap.load_lib_module` (which resolves against `lib/` directly),
# so script_dir is no longer read here — but the argv passing is preserved
# deliberately: referencing an undefined `script_dir` inside the old
# single-quoted heredoc was the P0 bug the argv fix closed, and the shim still
# forwards `_det_dir`. Keep the contract; do not re-litigate it.
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
        repo = resolve_repo()
        # U15: real load via _bootstrap.load_lib_module (replaces the inlined
        # importlib spec_from_file_location dance). Kept inside the try/except so
        # a sick load still degrades to the action=none block below.
        mod = load_lib_module("auto-workspace")
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
    Malformed ledgers are skipped (parity with v0.2.x).
    """
    # Stat each candidate ONCE behind its own guard, BEFORE sorting. A ledger
    # deleted mid-scan (concurrent run / cleanup sweep) would otherwise raise
    # OSError from the `sorted(key=os.path.getmtime)` callback and degrade the
    # WHOLE detector to `raw` — hiding every in-flight run over a transient
    # race. Skipping the vanished file is the correct, local degrade.
    #
    # U15: the glob+getmtime skeleton stays here (the detector needs the mtime,
    # which _bootstrap.iter_worktree_ledgers does not carry), but the per-file
    # open+json.load+isinstance(dict) guard is now _bootstrap.load_ledger_safe
    # (the exact primitive iter_worktree_ledgers wraps) — killing the inlined
    # parse duplication while keeping the output byte-identical.
    pairs = []
    for path in glob.glob(os.path.join(ledger_dir, "*.json")):
        try:
            pairs.append((path, os.path.getmtime(path)))
        except OSError:
            continue
    pairs.sort(key=lambda pm: pm[1], reverse=True)  # mtime-desc: freshest first

    out = []
    for path, mtime in pairs:
        led = load_ledger_safe(path)
        # load_ledger_safe returns None on ANY read/parse failure OR a non-dict
        # top-level value — folding the old OSError/ValueError + isinstance guard
        # into one call. A None here is a malformed/unreadable ledger: skip it.
        if led is None:
            continue
        if "exit_predicate_result" not in led:
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
        # U15: real load via _bootstrap.load_lib_module (replaces the second
        # inlined importlib spec_from_file_location dance). Kept inside the
        # try/except so a broken plan-rank still degrades to all-fresh below.
        mod = load_lib_module("plan-rank")
        return mod.rank(repo)
    except Exception:
        return [{"path": os.path.relpath(p, repo), "freshness": "fresh",
                 "sort_ts": 0.0} for p in _discover_plans(repo)]


def _emit_reviewed_plan(plan_path):
    """Emit the reviewed-plan envelope for a single unambiguous plan."""
    _emit(_safe_envelope(
        "reviewed-plan",
        "starting `%s` (workflow w, work-only — reviewed plan goes straight "
        "to the work-loop; pass `--workflow a1` to re-plan from scratch)"
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


# The detector's decision tree used to run as one ~200-line module-level block.
# U15 split it into three cohesive routers + a thin `main()` — NOT a behavior
# change (the code moved verbatim; each router still _emit's, which raises
# SystemExit): the module-level block would otherwise be attributed by the
# size-budget lint's `def`→`def` awk to the last helper above (a measurement
# artifact — see the backend-ce.py:_next_plan_step waiver). Keeping each router
# a real `def` under the function budget avoids a fresh waiver on a health split.


def _route_in_flight(in_flight):
    """Emit the in-flight / ambiguous-runs envelope, or return to fall through.

    Runs first. Exactly ONE not-met run → `in-flight` (silent-resume when the
    ledger is fresh; ASK when stale/anomalous). MORE than one → `ambiguous-runs`.
    Both branches _emit (raising SystemExit); an empty `in_flight` list returns
    None so the caller proceeds to plan discovery. The `if`/`if` (not `elif`) +
    _emit's SystemExit keep the branches mutually exclusive, exactly as when this
    lived at module level.
    """
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


def _route_plans_or_raw(repo):
    """Emit the plan / conversation-context / raw envelope. Always emits.

    Reached only when there is no in-flight run. Runs plan discovery + freshness
    ranking (Step 2), the conversation-context preemption (Step 2.5), then the
    raw fall-closed surface (Step 3). Every path _emit's (raising SystemExit),
    so this never returns normally — the trailing `raw` emit is unconditional.
    """
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
    # dispatches the entry workflow or pre-dispatch escalates (U3). When the signal
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


def _emit_error_fallback(exc):
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


def main():
    # CLI-004: on any unexpected error path, emit a safe `raw` envelope (the most
    # conservative — the driver recommends /ce-plan, does not start a run). An
    # empty stdout would leave the driver with no shape to parse; `raw` is the
    # fall-closed surface. rel-001: never break hook callers — always exit 0.
    try:
        repo = resolve_repo()

        # ── Step 1: in-flight scan. ────────────────────────────────────────
        ledger_dir = os.path.join(repo, ".claude", "auto")
        in_flight = _read_in_flight(ledger_dir)
        _route_in_flight(in_flight)

        # No in-flight run → plan discovery / conversation-context / raw. This
        # always emits (the trailing `raw` is unconditional), so control never
        # returns from here.
        _route_plans_or_raw(repo)
    except SystemExit:
        raise
    except BaseException as exc:
        _emit_error_fallback(exc)


if __name__ == "__main__":
    main()
