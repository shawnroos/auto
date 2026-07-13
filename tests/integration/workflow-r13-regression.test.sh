#!/usr/bin/env bash
# auto U4 integration test: R13 — bare `/auto <plan>` (default workflow a1) produces
# a run that BEHAVES identically to v0.1.x.
#
# HONEST framing (build-surfaced 2026-05-25): a1's run-record is NOT literally
# byte-identical to a v0.1.x run-record. v0.1.1 init'd with steps=[] (the plan-loop
# produced steps later, off-run-record at the handoff); a1 declares an explicit `plan`
# step (the representational change that makes the topology a workflow). So R13
# asserts the BEHAVIORAL invariants that actually matter — the things a v0.1.x
# operator would observe identically:
#   1. the run is created in loop_phase "plan" with backend ce
#   2. the plan-phase predicate is NOT met (no premature exit), gaps_open null
#   3. the new additive fields are present as their v0.1.x-equivalent defaults
#      (phase_order = legacy grammar, terminal_phase = work, workflow = a1)
#   4. bare /auto with NO --workflow defaults to a1 (the v0.1.x default workflow)
# Plus the producer-side: a1's single plan step is the plan-loop driver, exactly
# as v0.1.1's plan phase ran (one logical plan stream).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

# Run /auto with the given arg string in a fresh temp repo; print a CSV of the
# resulting run-record's behavioral signals.
run_auto() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
argv = sys.argv[2:]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)

repo = tempfile.mkdtemp()
os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md")
open(plan, "w").write("# plan\n")

# Map argv: first token is the literal "PLAN" placeholder → the temp plan path.
real_argv = [plan if t == "PLAN" else t for t in argv]
# a.run() prints the arm-pulse INTENT to stdout (its real job — the model reads
# it); silence it so only our signal CSV reaches the caller.
with contextlib.redirect_stdout(io.StringIO()):
    rc = a.run(real_argv)

files = glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))
led = json.load(open(files[0]))
pr = led["exit_predicate_result"]
print("%s|%s|%s|%s|%s|%s|%s|%s" % (
    rc,
    led["loop_phase"],
    led["backend"],
    led["workflow"]["name"],
    ",".join(led["phase_order"]),
    led["terminal_phase"],
    pr["met"],
    pr.get("gaps_open"),
))
PYEOF
}

it "R13: bare /auto <plan> (default workflow) → plan phase, ce, workflow a1"
res="$(run_auto PLAN)"
# rc 0 | plan | ce | a1 | legacy grammar | work | not-met | gaps null
assert_eq "0|plan|ce|a1|plan,handoff,work|work|False|None" "$res"

it "R13: explicit --workflow a1 produces the same run_record as the default"
res_explicit="$(run_auto PLAN --workflow a1)"
assert_eq "0|plan|ce|a1|plan,handoff,work|work|False|None" "$res_explicit"

it "R13: a1's single plan step drives the plan-loop (one logical plan stream)"
steps="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan])
led = json.load(open(glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))[0]))
plan_steps = [u["id"] for u in led["steps"] if u["phase"] == "plan"]
print(",".join(plan_steps))
PYEOF
)"
assert_eq "plan" "$steps"

it "R13: --workflow a2 produces 3 plan steps + judge (distinct from a1)"
a2units="$("$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")
with contextlib.redirect_stdout(io.StringIO()):
    a.run([plan, "--workflow", "a2"])
led = json.load(open(glob.glob(os.path.join(repo, ".claude", "auto", "*.json"))[0]))
plan_steps = sorted(u["id"] for u in led["steps"] if u["phase"] == "plan")
work_steps = sorted(u["id"] for u in led["steps"] if u["phase"] == "work")
print("%s|%s" % (",".join(plan_steps), ",".join(work_steps)))
PYEOF
)"
assert_eq "plan-1,plan-2,plan-3|judge" "$a2units"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "workflow-r13-regression.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
