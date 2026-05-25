#!/usr/bin/env bash
# auto U12: smart-entry situation detector (READ-ONLY).
#
# Bare `/auto` should "gather context and determine where to pick up" (field
# feedback 2026-05-25). The ROUTING is orchestrator prose in commands/auto.md,
# but the DETECTION is deterministic and lives here (deterministic-over-
# probabilistic for load-bearing infra). Prints ONE situation verdict line the
# prose branches on:
#
#   in-flight\t<run-id>           — a run exists whose exit_predicate_result.met
#                                   is False (the I-1-fresh "not done" signal) →
#                                   the prose resumes it (auto-chosen continue).
#   ambiguous-runs\t<n>           — MORE THAN ONE in-flight run → prose lists them,
#                                   asks which to resume (don't guess).
#   reviewed-plan\t<path>         — no in-flight run, but exactly one reviewed
#                                   plan present → prose offers work-only (W).
#   ambiguous-plans\t<n>          — no run, multiple plans → prose shows the picker.
#   raw                           — no run, no plan → prose recommends /ce-plan
#                                   (plan-production is upstream of /auto's work).
#
# Reviewed-plan heuristic: a *.md under docs/plans/ (or plans/, or *-plan.md at
# repo root). We do NOT try to judge "reviewed" semantically — presence in the
# plans dir is the signal; the operator confirms via the work-only offer.
#
# READ-ONLY: scans the ledger dir + plan dirs; never writes. Repo root resolved
# by the Python (CLAUDE_AUTO_REPO or walk-up), parity with the other shims.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::detect() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" - "$script_dir" <<'PYEOF'
import sys, os, json, glob
script_dir = sys.argv[1]


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


repo = _repo_root()

# In-flight runs: ledgers whose exit_predicate_result.met is False.
in_flight = []
ledger_dir = os.path.join(repo, ".claude", "auto")
for path in sorted(glob.glob(os.path.join(ledger_dir, "*.json")), key=os.path.getmtime, reverse=True):
    try:
        with open(path) as f:
            led = json.load(f)
    except (OSError, ValueError):
        continue
    if not isinstance(led, dict) or "exit_predicate_result" not in led:
        continue
    if not led["exit_predicate_result"].get("met", False):
        in_flight.append(led.get("run_id") or os.path.splitext(os.path.basename(path))[0])

if len(in_flight) == 1:
    print("in-flight\t%s" % in_flight[0]); raise SystemExit(0)
if len(in_flight) > 1:
    print("ambiguous-runs\t%d" % len(in_flight)); raise SystemExit(0)

# No in-flight run → look for reviewed plans.
plans = []
for pat in ("docs/plans/*.md", "plans/*.md", "*-plan.md"):
    plans.extend(glob.glob(os.path.join(repo, pat)))
plans = sorted(set(plans))
if len(plans) == 1:
    print("reviewed-plan\t%s" % os.path.relpath(plans[0], repo)); raise SystemExit(0)
if len(plans) > 1:
    print("ambiguous-plans\t%d" % len(plans)); raise SystemExit(0)

print("raw")
PYEOF
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::detect "$@"
fi
