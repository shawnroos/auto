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
# U15 (plan 2026-07-01-001): the ~590-line Python implementation moved out of a
# single-quoted bash heredoc into the sibling `lib/auto-detect.py`, following
# the shipped `backend-ce.sh`/`backend-ce.py` precedent (KTD-3). This file is now
# a thin shim; the JSON-envelope contract below is still authored here.
#
# JSON envelope (one line, machine-parseable):
#   {
#     "situation": "in-flight" | "ambiguous-runs" | "reviewed-plan"
#                | "multi-plan" | "raw",   (conversation-context RETIRED — U4)
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
#     "plans": [ {"path":"...", "freshness":"fresh"|"stale", "sort_ts":N}* ]
#                       (U4 — the full freshness-ranked plan list; the DRIVER
#                       weighs it against the transcript. [] when none / on error.)
#     "git":   { "branch": "..."|null, "dirty": true|false,
#                "diff_summary": "..."|null }   (U4 — raw branch/dirty facts.)
#   }
#
# Situations:
#   in-flight       — exactly ONE run with exit_predicate_result.met == false.
#                     `in_flight.run_id` carries the run. FRESH run (run-record
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
#   conversation-context — RETIRED as a detector situation (U4). The detector has
#                     no transcript access (single-quote heredoc), so it never
#                     could self-detect the conversation — v0.6.0/v0.7.x had it
#                     honour a CLAUDE_AUTO_CONVERSATION_SIGNAL env backchannel the
#                     driver set. U4 removes that backchannel: the detector emits
#                     deterministic FACTS only (see `plans`/`git` below), and the
#                     DRIVER — which HAS the transcript — owns the
#                     conversation-vs-stale-plan decision. When the facts show no
#                     run and only stale/absent plans, the driver may run the
#                     conversation-context flow itself (classify → recommender.py →
#                     author goal → dispatch); a FRESH plan still wins.
#   raw             — no run, no plan (clean OR dirty tree). ambiguity is an
#                     open "what should we work on?" question so the driver
#                     can route to /ce-plan or a freeform handoff. When the
#                     working tree is dirty, summary includes branch + diff
#                     context so the operator sees what they were doing —
#                     but the situation is still raw because there's no
#                     deterministic dispatch from a diff alone.
#
# READ-ONLY: scans the run-record dir + plan dirs + git status; never writes.
# Repo root resolved by the Python (CLAUDE_AUTO_REPO or walk-up).
#
# Hypothesis-shape stability (NO TSV legacy): the previous TSV consumer was
# `skills/auto-driver` only (one consumer, updated lock-step in U4). No
# back-compat wrapper, no shim — the JSON output is the contract.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────────
# DELEGATION (no inline logic). U15 moved the ~590-line detector body out of a
# single-quoted `<<'PYEOF'` heredoc into the sibling `auto-detect.py` — the
# shipped `backend-ce.sh`/`backend-ce.py` precedent (KTD-3). This shim pins the
# interpreter, resolves `script_dir`, and execs the `.py`, forwarding the script
# dir as argv[1]. The `.py` reached back through `_bootstrap` for the three
# formerly-inlined duplications: `_repo_root` → `resolve_repo`; the twice-inlined
# importlib sibling-load (auto-workspace.py + plan-rank.py) → `load_lib_module`;
# `_read_in_flight`'s inline json.load+dict-guard → `load_run_record_safe`.
#
# The `script_dir` argv passing is load-bearing: `auto-detect.py` reads it as
# argv[1] (the P0 fix from the plan 004 round-1 review — a single-quoted heredoc
# disables shell substitution, so the dir had to come through argv). Preserve it.
# All $-bearing logic stays here, never in a command `.md` (memory
# feedback_slash_command_arg_substitution).

auto::detect() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/auto-detect.py" "$script_dir"
}

# Direct invocation for testing / scripting.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::detect "$@"
fi
