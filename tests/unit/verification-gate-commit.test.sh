#!/usr/bin/env bash
# auto U4 (verification-gate-hardening) e2e: the advisor-judge COMMIT/AUDIT path
# on a REAL on-disk ledger.
#
# The pure-aggregate signal math is covered by tests/integration/verification-
# gate.test.sh's in-memory `led_from` harness. That harness NEVER touches the
# mutators, so it cannot cover the write leg. This test drives the actual §4.7
# plumbing on a real sandbox ledger:
#
#   init_ledger (verification carried through by U3's feeder)
#     -> read_ledger -> resolve_gate_verification(dict, gate, judge_verdicts=...)
#     -> on a non-None signal: set_verdict_decision(repo, run, gate, signal)
#     -> ONLY when a judge criterion resolved the gate: append_advisor_audit(...)
#
# Assertions read back via read_ledger + iteration.read_decision.
#
# The advisor verdict is INJECTED as data (no live `advisor`) — exactly the
# fake-verdict seam (resolve_gate_verification's judge_verdicts arg + persisted
# dispatch_context.judge_verdicts). The live advisor consult stays session-
# verified by nature (KTD-5); this covers the deterministic write leg only.
#
# Scenarios (U4 plan):
#   1. injected advisor pass + programmatic pass -> decision "advance",
#      ONE audit record (classification="advisor_judge", resolution="advance",
#      subject non-empty).
#   2. injected advisor fail -> decision "iterate", audit resolution="iterate".
#   3. persisted dispatch_context.judge_verdicts (no caller arg) -> still
#      resolves + audits (the merge path).
#   4. programmatic-only gate (no judge criterion) -> commits the signal, NO
#      audit record.
#   5. judge criterion, no verdict supplied -> resolve returns pending_judges,
#      NOTHING committed, no audit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "${REPO}/.claude/auto"

echo "verification-gate-commit.test.sh"

# ════════════════════════════════════════════════════════════════════════════
# One Python driver runs all scenarios against the REAL ledger facade, each on
# its own run_id. `drive()` mirrors skills/auto/SKILL.md §4.7 steps 3-5:
# resolve -> (signal non-None) commit -> (judge resolved) audit-per-judge-crit.
# Emits a "tag=value" line per assertion; bash asserts on each.
# ════════════════════════════════════════════════════════════════════════════
out="$("$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF'
import sys, os
auto_root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_ledger, load_lib_module
ledger = load_ledger()
iteration = load_lib_module("iteration")

def emit(tag, val):
    print(f"{tag}={val}")

JUDGE_TYPES = ("advisor_judge", "model_judge", "human")

def init(run, verification, dispatch_context=None):
    """Arm a real on-disk ledger with a verification gate unit (carried through
    by U3's feeder) + a minimal iteration block naming it the gate."""
    unit = {"id": "gate", "state": "verdict-returned", "verification": verification}
    if dispatch_context is not None:
        unit["dispatch_context"] = dispatch_context
    ledger.init_ledger(repo, run, adapter="ce", loop_phase="work",
                       units=[unit], iteration={"gate_unit": "gate"})

def drive(run, caller_verdicts=None):
    """Mirror §4.7 steps 3-5 against the on-disk ledger. Returns the signal."""
    L = ledger.read_ledger(repo, run)                       # real on-disk read
    res = iteration.resolve_gate_verification(
        L, "gate", judge_verdicts=caller_verdicts)
    signal = res["signal"]
    if signal is None:                                      # judges pending
        return res                                          # commit/audit nothing
    # step 4: the single, centralized decision write.
    ledger.set_verdict_decision(repo, run, "gate", signal)
    # step 5: audit ONLY when a judge criterion resolved the gate. signal is
    # non-None => pending_judges empty => every judge crit contributed a verdict.
    gate = next(u for u in L["units"] if u["id"] == "gate")
    for c in (gate.get("verification") or []):
        if c.get("type") in JUDGE_TYPES:
            ledger.append_advisor_audit(
                repo, run, kind="advisor",
                subject=f"gate: {c['id']}",
                classification=c["type"],
                resolution=signal)
    return res

def decision_of(run):
    gate = next(u for u in ledger.read_ledger(repo, run)["units"] if u["id"] == "gate")
    return iteration.read_decision(gate)

def audits(run):
    return ledger.read_ledger(repo, run).get("advisor_audit", [])

PROG_PASS = {"id": "tests", "type": "programmatic", "argv": ["true"], "check": "exit_zero"}
PROG_FAIL = {"id": "tests", "type": "programmatic", "argv": ["false"], "check": "exit_zero"}
ADVISOR   = {"id": "sound", "type": "advisor_judge", "rubric_ref": "design-sound"}

# ── 1. advisor pass + programmatic pass -> advance + one judge audit ─────────
init("s1", [PROG_PASS, ADVISOR])
drive("s1", caller_verdicts={"sound": "pass"})
emit("s1_decision", decision_of("s1"))
a = audits("s1")
emit("s1_audit_len", len(a))
emit("s1_audit_kind", a[0]["kind"] if a else "MISSING")
emit("s1_audit_class", a[0]["classification"] if a else "MISSING")
emit("s1_audit_res", a[0]["resolution"] if a else "MISSING")
emit("s1_audit_subject_nonempty", bool(a and a[0]["subject"]))

# ── 2. advisor fail -> iterate + audit resolution=iterate ───────────────────
init("s2", [PROG_PASS, ADVISOR])
drive("s2", caller_verdicts={"sound": "fail"})
emit("s2_decision", decision_of("s2"))
a = audits("s2")
emit("s2_audit_len", len(a))
emit("s2_audit_res", a[0]["resolution"] if a else "MISSING")

# ── 3. persisted dispatch_context.judge_verdicts, NO caller arg (merge path) ─
init("s3", [PROG_PASS, ADVISOR],
     dispatch_context={"judge_verdicts": {"sound": "pass"}})
drive("s3", caller_verdicts=None)           # caller passes nothing; resolve folds persisted
emit("s3_decision", decision_of("s3"))
a = audits("s3")
emit("s3_audit_len", len(a))
emit("s3_audit_class", a[0]["classification"] if a else "MISSING")

# ── 4. programmatic-only gate -> commits signal, NO audit ───────────────────
init("s4", [PROG_PASS])
drive("s4")
emit("s4_decision", decision_of("s4"))
emit("s4_audit_len", len(audits("s4")))

# ── 5. judge criterion, no verdict -> pending, nothing committed, no audit ───
init("s5", [PROG_PASS, ADVISOR])
res = drive("s5", caller_verdicts=None)
emit("s5_signal", res["signal"])
emit("s5_pending", ",".join(res["pending_judges"]))
emit("s5_decision", decision_of("s5"))       # never committed -> None
emit("s5_audit_len", len(audits("s5")))
PYEOF
)"

# Pull a tag's value out of the driver output.
g() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2-; }

# ── Scenario 1 ──────────────────────────────────────────────────────────────
it "advisor pass + programmatic pass commits decision=advance"
assert_eq "advance" "$(g s1_decision)"
it "advisor pass writes exactly one audit record"
assert_eq "1" "$(g s1_audit_len)"
it "judge audit reuses kind=advisor"
assert_eq "advisor" "$(g s1_audit_kind)"
it "audit classification is derived from the judge type (advisor_judge)"
assert_eq "advisor_judge" "$(g s1_audit_class)"
it "audit resolution mirrors the committed signal (advance)"
assert_eq "advance" "$(g s1_audit_res)"
it "audit subject is non-empty"
assert_eq "True" "$(g s1_audit_subject_nonempty)"

# ── Scenario 2 ──────────────────────────────────────────────────────────────
it "advisor fail commits decision=iterate"
assert_eq "iterate" "$(g s2_decision)"
it "advisor fail audit resolution=iterate"
assert_eq "iterate" "$(g s2_audit_res)"
it "advisor fail still writes one audit"
assert_eq "1" "$(g s2_audit_len)"

# ── Scenario 3 (merge path) ─────────────────────────────────────────────────
it "persisted judge verdict (no caller arg) still commits advance"
assert_eq "advance" "$(g s3_decision)"
it "persisted judge verdict still writes the judge audit"
assert_eq "1" "$(g s3_audit_len)"
it "persisted-verdict audit classification is advisor_judge"
assert_eq "advisor_judge" "$(g s3_audit_class)"

# ── Scenario 4 (programmatic-only -> no audit) ──────────────────────────────
it "programmatic-only gate commits the signal (advance)"
assert_eq "advance" "$(g s4_decision)"
it "programmatic-only gate writes NO audit record"
assert_eq "0" "$(g s4_audit_len)"

# ── Scenario 5 (pending -> nothing committed) ───────────────────────────────
it "judge criterion with no verdict -> signal None"
assert_eq "None" "$(g s5_signal)"
it "judge criterion with no verdict -> pending_judges names it"
assert_eq "sound" "$(g s5_pending)"
it "pending gate commits no decision (read_decision is None)"
assert_eq "None" "$(g s5_decision)"
it "pending gate writes no audit record"
assert_eq "0" "$(g s5_audit_len)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "verification-gate-commit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
