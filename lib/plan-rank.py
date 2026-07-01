#!/usr/bin/env python3
# auto v0.7.x U1: deterministic plan freshness ranking (READ-ONLY).
#
# The entry detector (lib/auto-detect.sh) discovers plan files under the
# conventional locations and, pre-v0.7.x, treated them as an unordered set:
# exactly one → reviewed-plan, more than one → a multi-plan ask that ALWAYS
# offered a "Fan out all N" option. The 2026-06 field misfire showed the
# footgun: a session with 6 plans in docs/plans/ (5 committed months ago, 1
# authored THIS session) got the fan-out ask over all 6, and the live plan lost
# to stale siblings.
#
# This module adds the missing signal: which plans are FRESH (the one you're
# working on) vs STALE (old clutter). It is a separate importable module — like
# lib/auto-workspace.py and lib/recommender.py — so the fuzzy-free, deterministic
# ranking is directly unit-testable via the CLI, and the detector imports it
# rather than inlining the logic in its single-quoted heredoc.
#
# Deterministic-over-probabilistic (the load-bearing mandate): freshness is
# computed from git + filesystem facts, never inferred. The DRIVER never sees
# this file; only the detector consumes rank().
#
# Freshness rule (KTD-4) — git opinion wins, mtime is the fallback:
#   * git says the plan is uncommitted (untracked `??` or modified ` M`) → FRESH
#     (you are actively working on it — the field case's live plan).
#   * git says the plan is tracked+clean and its last commit is within
#     CLAUDE_AUTO_PLAN_FRESH_SECONDS → FRESH; older → STALE.
#   * git is SILENT (file gitignored / never committed / not a git tree / git
#     failed) → fall back to file mtime within the window → FRESH else STALE.
# Rationale: mtime-only is rejected as the PRIMARY signal because a fresh
# `git clone`/`checkout` restamps every mtime (false freshness). But for TRACKED
# files git decides by commit recency, so the restamp never bites them; mtime is
# consulted only where git has no opinion anyway. This also keeps the detector's
# hermetic tests (which gitignore docs/) working: their just-created plans are
# git-silent → mtime-fresh.
#
# READ-ONLY + degrade-safe: only `git status`/`git log` probes (timeout-guarded,
# mirroring the detector's own git guards); never writes. Any probe failure
# degrades that plan to the mtime fallback, and a missing file degrades to STALE
# (conservative — an unreadable plan is never inferred as the live one).

import os
import sys
import glob
import json
import time
import subprocess


def _git_timeout_seconds():
    """Bound for each git probe — mirrors the detector's CLAUDE_AUTO_GIT_TIMEOUT_SECONDS."""
    try:
        t = float(os.environ.get("CLAUDE_AUTO_GIT_TIMEOUT_SECONDS", "5"))
    except (TypeError, ValueError):
        return 5.0
    return t if t > 0 else 5.0


def fresh_seconds():
    """Freshness window in seconds. Default 86400 (1 day), mirroring the
    in-flight TTL knob. Floored at 0 (0 = only uncommitted/this-instant plans
    count as fresh). Negative/garbage → default."""
    try:
        s = int(os.environ.get("CLAUDE_AUTO_PLAN_FRESH_SECONDS", "86400"))
    except (TypeError, ValueError):
        return 86400
    return s if s >= 0 else 0


def discover(repo):
    """All plan files under the conventional locations, repo-relative, sorted +
    de-duped. Mirrors lib/auto-detect.sh::_discover_plans so the two agree on
    WHICH files are plans; this module only adds the freshness ranking on top."""
    plans = []
    for pat in ("docs/plans/*.md", "plans/*.md", "*-plan.md"):
        plans.extend(glob.glob(os.path.join(repo, pat)))
    rels = sorted({os.path.relpath(p, repo) for p in plans})
    return rels


def _git(repo, args):
    """Run a read-only git probe; return stdout (str) on success, or None on any
    failure/timeout/non-zero. None means 'git had no answer' → caller falls back."""
    try:
        r = subprocess.run(
            ["git", "-C", repo] + args,
            capture_output=True, text=True, check=False,
            timeout=_git_timeout_seconds(),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout


def _mtime(repo, relpath):
    """File mtime, or None if the file is gone (degrade → STALE)."""
    try:
        return os.path.getmtime(os.path.join(repo, relpath))
    except OSError:
        return None


def classify(repo, relpath, window, now):
    """Return (freshness, sort_ts) for one plan.

    freshness ∈ {"fresh","stale"}; sort_ts is the timestamp used to order within
    a freshness tier (commit time when git decided by recency, else mtime).
    """
    # 1. Working-tree status — git's opinion on "am I being edited right now?".
    #    `--porcelain -- <path>` prints a line iff the path is untracked/modified;
    #    empty output = tracked+clean OR gitignored (git can't tell us here).
    status = _git(repo, ["status", "--porcelain", "--", relpath])
    if status is not None and status.strip():
        # Uncommitted (?? or M) → actively worked on → fresh. Order by mtime.
        m = _mtime(repo, relpath)
        return ("fresh", m if m is not None else now)

    # 2. Tracked+clean → decide by last-commit recency.
    if status is not None:
        log = _git(repo, ["log", "-1", "--format=%ct", "--", relpath])
        if log is not None and log.strip():
            try:
                ct = int(log.strip())
            except ValueError:
                ct = None
            if ct is not None:
                return ("fresh" if (now - ct) <= window else "stale", ct)
        # git ran but no commit for this path → gitignored / never committed →
        # fall through to the mtime fallback below.

    # 3. git silent (no git tree, probe failed, or gitignored/uncommitted-untracked
    #    file) → mtime fallback. Missing file → stale (never infer a live plan
    #    from a file we cannot read).
    m = _mtime(repo, relpath)
    if m is None:
        return ("stale", 0.0)
    return ("fresh" if (now - m) <= window else "stale", m)


def rank(repo, window=None, now=None):
    """Discover + classify + order all plans.

    Returns a list of {"path","freshness","sort_ts"} dicts, freshest first:
    fresh before stale, and newest sort_ts first within each tier. Deterministic
    for a given repo state.
    """
    if window is None:
        window = fresh_seconds()
    if now is None:
        now = time.time()
    out = []
    for rel in discover(repo):
        freshness, sort_ts = classify(repo, rel, window, now)
        out.append({"path": rel, "freshness": freshness, "sort_ts": sort_ts})
    # fresh (False sorts before True) then newest first.
    out.sort(key=lambda p: (p["freshness"] == "stale", -p["sort_ts"]))
    return out


def _cli(argv):
    """`plan-rank.py <repo>` → one JSON line: the ranked plan list. Test surface."""
    repo = argv[1] if len(argv) > 1 else os.getcwd()
    json.dump(rank(repo), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))
