#!/usr/bin/env bash
# auto U7 integration test (addressable-step-contents): the one-shot LIB wiring
# the `auto-content` skill orchestrates, end to end, WITHOUT a live agent.
#
# F1 (the Phase-1 headline) is: load a named content -> propose/ratify criteria
# -> launch the op ONCE -> resolve criteria inline -> oneshot_verdict on the
# ratified criteria -> report + terminate. The live sub-agent launch and
# the propose/ratify CONVERSATION are agent-driven (verified by the skill prose +
# code review). What is DETERMINISTIC — and what this test pins — is the lib seam
# the skill drives:
#
#   load_content -> validate_oneshot_criteria -> build_oneshot_launch ->
#   (stub the dispatch: evaluate_programmatic in-process + a supplied model_judge
#   verdict) -> oneshot_verdict(ratified_criteria, ...).
#
# SELF-CONTAINED harness; python pinned via CLAUDE_AUTO_PYTHON3; modules loaded
# via importlib from an absolute path. Deterministic (no network, no live agent):
# the stubbed dispatch uses `true`/`false` for the programmatic criterion and
# injects the model_judge verdict as data.
#
# Scenarios (U7 plan / F1):
#   1. a built-in content loads, its ratified criteria validate, and with all
#      criteria resolved PASS -> verdict `pass`.
#   2. the same wiring with one programmatic criterion FAILING -> verdict `fail`.
#   3. the launch descriptor for the built-in content names its op and folds its
#      prompt_template body (U5 in the F1 chain).
#   4. no `pending_judges` survive to verdict time (all types resolved inline).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${AUTO_ROOT}/lib"
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

echo "auto-content-oneshot.test.sh"

probe() {
  "$PY" - "$LIB" "$AUTO_ROOT" <<'PYEOF'
import sys, importlib.util, tempfile

lib = sys.argv[1]
auto_root = sys.argv[2]
if lib not in sys.path:
    sys.path.insert(0, lib)

def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{lib}/{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

try:
    contents = load("contents")
    co = load("content_oneshot")
    verification = load("verification")
except Exception as e:
    print("IMPORT-FAIL:%s" % e)
    sys.exit(0)

results = []

# ── Step 1: load a built-in content (the `auto-content` skill's first move) ──
# Load against an EMPTY temp repo so a workspace override can never shadow the
# built-in seed (test hermeticity); auto_root stays the target workspace below.
empty_repo = tempfile.mkdtemp(prefix="oneshot-empty-repo-")
content = contents.load_content("tuned-review", empty_repo)
ok_c, errs_c = contents.validate_content(content)
results.append("content_valid=%s" % ok_c)

# ── Step 2: propose/ratify -> validate the ratified criteria (U3) ────────────
# A programmatic criterion the skill would run in-process, plus a model_judge
# the dispatched agent self-verdicts. Both are deterministic here.
ratified = [
    {"id": "op-ran", "type": "programmatic", "argv": ["true"], "check": "exit_zero"},
    {"id": "reads-clean", "type": "model_judge"},
]
ok_v, errs_v = co.validate_oneshot_criteria(ratified)
results.append("criteria_valid=%s" % ok_v)

# ── Step 3: build the launch descriptor (U5) — names op, folds template ──────
launch = co.build_oneshot_launch(content, auto_root)
results.append("launch_op=%s" % launch.get("adapter_op"))
results.append("launch_body_folds=%s" % ("Tuned review prompt" in (launch.get("prompt_template_body") or "")))

# ── Step 4: STUB the dispatch — resolve every criterion inline (KTD-3) ────────
# programmatic: run it in-process exactly as the skill would.
prog = verification.evaluate_programmatic(
    {"id": "op-ran", "argv": ["true"], "check": "exit_zero"}
)
programmatic_results = {prog["criterion_id"]: prog["status"]}
# model_judge: the dispatched agent returned a pass self-verdict.
judge_verdicts = {"reads-clean": "pass"}

# ── Step 5: terminal verdict (U4) — the ratified criteria fold in directly ────
# all resolved PASS -> pass.
v_pass = co.oneshot_verdict(ratified, programmatic_results, judge_verdicts)
results.append("verdict_all_pass=%s" % v_pass.get("verdict"))
results.append("signal_all_pass=%s" % v_pass.get("aggregate_signal"))

# ── Scenario 2: one programmatic criterion FAILS -> verdict `fail` ───────────
ratified_fail = [
    {"id": "op-ran", "type": "programmatic", "argv": ["false"], "check": "exit_zero"},
    {"id": "reads-clean", "type": "model_judge"},
]
prog_fail = verification.evaluate_programmatic(
    {"id": "op-ran", "argv": ["false"], "check": "exit_zero"}
)
v_fail = co.oneshot_verdict(
    ratified_fail, {prog_fail["criterion_id"]: prog_fail["status"]}, {"reads-clean": "pass"}
)
results.append("verdict_one_fail=%s" % v_fail.get("verdict"))

# ── Scenario 4: no pending_judges survive (a raw aggregate view) ─────────────
agg = verification.aggregate(ratified, programmatic_results, judge_verdicts)
results.append("pending=%s" % len(agg.get("pending_judges") or []))

print(";".join(results))
PYEOF
}

OUT="$(probe)"
get() { printf '%s' "$OUT" | tr ';' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

it "the built-in content loads and validates"
assert_eq "True" "$(get content_valid)"

it "the ratified criteria validate against the taxonomy (U3)"
assert_eq "True" "$(get criteria_valid)"

it "the launch descriptor names the content's op (U5)"
assert_eq "review" "$(get launch_op)"

it "the launch descriptor folds the content's prompt_template body (U5)"
assert_eq "True" "$(get launch_body_folds)"

it "all criteria resolved PASS -> verdict pass (F1 / KTD-1)"
assert_eq "pass" "$(get verdict_all_pass)"

it "the passing verdict re-labels the aggregate advance signal"
assert_eq "advance" "$(get signal_all_pass)"

it "one programmatic criterion failing -> verdict fail (F1 / KTD-1)"
assert_eq "fail" "$(get verdict_one_fail)"

it "no pending_judges survive to verdict time — all types resolved inline (KTD-3)"
assert_eq "0" "$(get pending)"

echo ""
echo "auto-content-oneshot.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
