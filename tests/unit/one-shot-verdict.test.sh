#!/usr/bin/env bash
# auto U4 unit test (addressable-step-contents): oneshot_verdict.
#
# SELF-CONTAINED: minimal inline it/pass/fail/assert_eq harness, python pinned via
# CLAUDE_AUTO_PYTHON3, modules loaded via importlib from an absolute path.
#
# The terminal one-shot verdict (KTD-1): READ-ONLY over the ratified criteria —
# fold them + resolved results through verification.aggregate and re-label the
# advance/iterate SIGNAL to a terminal pass/fail. It must NOT commit an iteration
# decision.
#
# Scenarios (U4 plan):
#   1. all programmatic criteria pass -> verdict `pass`.
#   2. one programmatic criterion fails -> verdict `fail`.
#   3. a model_judge verdict folds into the aggregate (pass AND fail).
#   4. an advisor_judge verdict folds in (pass AND fail).
#   5. a human verdict folds in (accept -> pass contribution; reject -> fail).
#   6. unresolved pending judges at verdict time -> explicit error (not a silent pass).
#   7. no iteration `decision` written (KTD-1 boundary).
#   8. no ratified criteria -> "unverified", never a silent pass (review finding).
#   9. stripped baked criteria (ledger round-trip) -> "unverified", fails loud.
#   7. no iteration decision is written — the unit's dispatch_context has no
#      `decision` field after oneshot_verdict (KTD-1 boundary).

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

echo "one-shot-verdict.test.sh"

probe() {
  "$PY" - "$LIB" <<'PYEOF'
import sys, importlib.util

lib = sys.argv[1]
if lib not in sys.path:
    sys.path.insert(0, lib)

def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{lib}/{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

try:
    co = load("content_oneshot")
    verdict_fn = co.oneshot_verdict
except Exception as e:  # function missing -> RED
    print("IMPORT-FAIL:%s" % e)
    sys.exit(0)


def crit(cid, ctype):
    return {"id": cid, "type": ctype}


def synth(criteria):
    content = {"name": "c", "version": "1", "description": "d",
               "invokes": {"adapter_op": "do_unit"}}
    return co.synthesize_oneshot_unit(content, criteria)


def verdict_of(criteria, prog, judges):
    return verdict_fn(synth(criteria), prog, judges)["verdict"]


out = []

# ── Scenario 1: all programmatic pass -> pass ────────────────────────────────
out.append("s1=%s" % verdict_of(
    [crit("p1", "programmatic"), crit("p2", "programmatic")],
    {"p1": "pass", "p2": "pass"}, {}))

# ── Scenario 2: one programmatic fails -> fail ───────────────────────────────
out.append("s2=%s" % verdict_of(
    [crit("p1", "programmatic"), crit("p2", "programmatic")],
    {"p1": "pass", "p2": "fail"}, {}))

# ── Scenario 3: model_judge folds in (pass AND fail) ─────────────────────────
out.append("s3pass=%s" % verdict_of([crit("m1", "model_judge")], {}, {"m1": "pass"}))
out.append("s3fail=%s" % verdict_of([crit("m1", "model_judge")], {}, {"m1": "fail"}))

# ── Scenario 4: advisor_judge folds in (pass AND fail) ───────────────────────
out.append("s4pass=%s" % verdict_of([crit("a1", "advisor_judge")], {}, {"a1": "pass"}))
out.append("s4fail=%s" % verdict_of([crit("a1", "advisor_judge")], {}, {"a1": "fail"}))

# ── Scenario 5: human folds in (accept -> pass; reject -> fail) ──────────────
# The caller maps a human accept -> "pass", reject -> "fail" in judge_verdicts.
out.append("s5accept=%s" % verdict_of([crit("h1", "human")], {}, {"h1": "pass"}))
out.append("s5reject=%s" % verdict_of([crit("h1", "human")], {}, {"h1": "fail"}))

# ── Scenario 5b: mixed types fold together (programmatic pass + human reject) ─
out.append("s5mix=%s" % verdict_of(
    [crit("p1", "programmatic"), crit("h1", "human")],
    {"p1": "pass"}, {"h1": "fail"}))

# ── Scenario 6: pending judge at verdict time -> explicit error, not a pass ──
try:
    verdict_of([crit("m1", "model_judge")], {}, {})  # no verdict supplied
    out.append("s6=NO-RAISE")
except co.OneShotIncomplete:
    out.append("s6=incomplete")
except Exception as e:  # any other raise is still "not a silent pass", but be precise
    out.append("s6=other:%s" % type(e).__name__)

# ── Scenario 7: no iteration `decision` written on the unit ──────────────────
u = synth([crit("p1", "programmatic")])
_ = verdict_fn(u, {"p1": "pass"}, {})
dc = u.get("dispatch_context") or {}
out.append("s7_has_decision=%s" % ("decision" in dc))
out.append("s7_unit_has_decision=%s" % ("decision" in u))

# ── Scenario 8: NO ratified criteria -> "unverified", never a silent pass ─────
# A one-shot that verified nothing must not report green (review finding).
out.append("s8_empty=%s" % verdict_of([], {}, {}))
out.append("s8_none=%s" % verdict_of(None, {}, {}))

# ── Scenario 9: a unit whose baked criteria were stripped (exactly what a ledger
# round-trip through ledger_core._normalize_unit does — it drops the top-level
# one_shot_verification key) verdicts "unverified", failing LOUD rather than as a
# vacuous pass. This is the guard behind KTD-4's "do not persist the unit". ─────
stripped = synth([crit("p1", "programmatic")])
stripped.pop(co.ONE_SHOT_VERIFICATION_KEY, None)
out.append("s9=%s" % verdict_fn(stripped, {"p1": "pass"}, {})["verdict"])

print(";".join(out))
PYEOF
}

OUT="$(probe)"
get() { printf '%s' "$OUT" | tr ';' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

it "all programmatic criteria pass -> verdict pass"
assert_eq "pass" "$(get s1)"

it "one programmatic criterion fails -> verdict fail"
assert_eq "fail" "$(get s2)"

it "a model_judge verdict folds into the aggregate -> pass"
assert_eq "pass" "$(get s3pass)"

it "a model_judge verdict folds into the aggregate -> fail"
assert_eq "fail" "$(get s3fail)"

it "an advisor_judge verdict folds in -> pass"
assert_eq "pass" "$(get s4pass)"

it "an advisor_judge verdict folds in -> fail"
assert_eq "fail" "$(get s4fail)"

it "a human accept folds in as a pass contribution -> pass"
assert_eq "pass" "$(get s5accept)"

it "a human reject folds in as a fail -> fail"
assert_eq "fail" "$(get s5reject)"

it "mixed types fold together (programmatic pass + human reject -> fail)"
assert_eq "fail" "$(get s5mix)"

it "unresolved pending judge at verdict time -> explicit OneShotIncomplete (not a silent pass)"
assert_eq "incomplete" "$(get s6)"

it "oneshot_verdict writes no iteration decision on dispatch_context (KTD-1 boundary)"
assert_eq "False" "$(get s7_has_decision)"

it "oneshot_verdict writes no top-level decision on the unit (KTD-1 boundary)"
assert_eq "False" "$(get s7_unit_has_decision)"

it "no ratified criteria -> verdict unverified (empty list; not a silent pass)"
assert_eq "unverified" "$(get s8_empty)"

it "no ratified criteria -> verdict unverified (None)"
assert_eq "unverified" "$(get s8_none)"

it "stripped baked criteria (ledger round-trip) -> unverified, not a silent pass"
assert_eq "unverified" "$(get s9)"

echo ""
echo "one-shot-verdict.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
