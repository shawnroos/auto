#!/usr/bin/env bash
# auto U9 (v0.6.0) unit test: lib/upstream-cluster.py — the PURE, stdlib-only
# upstream-cluster classifier that weights REVIEWER-ROLE DIVERSITY over raw
# finding count (KTD-6 — adversarial + feasibility + security converging on one
# upstream phase beats N same-role hits).
#
# SELF-CONTAINED inline harness (modeled on tests/unit/producers.test.sh): shells
# into Python via _bootstrap.load_lib_module("upstream-cluster").
#
# Scenarios:
#   1. 3 diverse-role findings on ONE upstream phase → detected, names the phase
#   2. many SAME-role local findings → NOT flagged (count alone never triggers)
#   3. malformed metadata (non-dict findings, missing tags, torn order) → safe
#      default (detected=False), never raises
#   4. role diversity is what counts: 10 findings, all one role, on an upstream
#      phase → NOT detected (diversity 1 < threshold)
#   5. attributed phase is the CURRENT phase (not upstream) → NOT detected
#   6. two upstream phases both qualify → pick the MOST-diverse, tie → earliest
#   7. escalation_message names the upstream phase + roles; None when not detected
#   8. classify never reads ledger["loop_phase"] (args-only) — recipe-blind /
#      empty order yields no upstream phases → not detected

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

uc() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
uc = load_lib_module("upstream-cluster")
op = sys.argv[2]

SPINE = ["brainstorm", "plan", "seam", "work"]


def fmt(r):
    # Compact, assertable rendering of the five-key result.
    return "%s|%s|%s|%s" % (
        r["detected"], r["target_phase"],
        ",".join(r["distinct_roles"]), r["finding_count"])


if op == "diverse-upstream":
    # 3 DISTINCT roles, all attributing to the upstream `plan` phase, run is at
    # `work`. Threshold (3) met → detected, names plan, counts 3 findings.
    findings = [
        {"role": "adversarial", "phase": "plan", "note": "premise unproven"},
        {"role": "feasibility", "phase": "plan", "note": "infeasible as scoped"},
        {"role": "security",    "phase": "plan", "note": "threat model gap"},
    ]
    print(fmt(uc.classify(findings, "work", SPINE)))

elif op == "many-same-role-local":
    # Many findings BUT all one role AND attributed to the CURRENT phase (work).
    # Neither diversity nor upstream-ness holds → not flagged.
    findings = [{"role": "correctness", "phase": "work", "note": f"bug {i}"}
                for i in range(12)]
    print(fmt(uc.classify(findings, "work", SPINE)))

elif op == "malformed":
    # A torn verdict: a non-dict entry, a finding with no role, one with no
    # phase, a blank role, a non-string phase. Must NOT raise; safe default.
    findings = [
        "not-a-dict",
        {"phase": "plan"},               # no role
        {"role": "adversarial"},         # no phase
        {"role": "  ", "phase": "plan"}, # blank role
        {"role": "feasibility", "phase": 42},  # non-string phase
        None,
    ]
    try:
        r = uc.classify(findings, "work", SPINE)
        print(fmt(r))
    except Exception as exc:  # noqa: BLE001
        print("RAISED:%s" % type(exc).__name__)

elif op == "diversity-not-count":
    # 10 findings, ALL one role, on the upstream `plan` phase. Count is high but
    # diversity is 1 < 3 → NOT detected. This is the KTD-6 weighting proof.
    findings = [{"role": "correctness", "phase": "plan", "note": f"x{i}"}
                for i in range(10)]
    print(fmt(uc.classify(findings, "work", SPINE)))

elif op == "current-phase-not-upstream":
    # 3 distinct roles BUT attributed to the CURRENT phase (work), not upstream.
    # work is not strictly-upstream of itself → excluded → not detected.
    findings = [
        {"role": "adversarial", "phase": "work"},
        {"role": "feasibility", "phase": "work"},
        {"role": "security",    "phase": "work"},
    ]
    print(fmt(uc.classify(findings, "work", SPINE)))

elif op == "two-upstream-tiebreak":
    # `brainstorm` has 3 roles; `plan` has 3 roles too (tie on diversity) — the
    # EARLIEST phase (brainstorm) wins the tiebreak (deepest root cause).
    findings = [
        {"role": "adversarial", "phase": "brainstorm"},
        {"role": "feasibility", "phase": "brainstorm"},
        {"role": "security",    "phase": "brainstorm"},
        {"role": "adversarial", "phase": "plan"},
        {"role": "feasibility", "phase": "plan"},
        {"role": "security",    "phase": "plan"},
    ]
    r = uc.classify(findings, "work", SPINE)
    print("%s|%s" % (r["detected"], r["target_phase"]))

elif op == "most-diverse-wins":
    # `plan` has 3 roles, `brainstorm` has 2 — `plan` is more diverse and wins
    # despite being later (diversity dominates the order tiebreak).
    findings = [
        {"role": "adversarial", "phase": "brainstorm"},
        {"role": "feasibility", "phase": "brainstorm"},
        {"role": "adversarial", "phase": "plan"},
        {"role": "feasibility", "phase": "plan"},
        {"role": "security",    "phase": "plan"},
    ]
    r = uc.classify(findings, "work", SPINE)
    print("%s|%s" % (r["detected"], r["target_phase"]))

elif op == "message-detected":
    findings = [
        {"role": "adversarial", "phase": "plan"},
        {"role": "feasibility", "phase": "plan"},
        {"role": "security",    "phase": "plan"},
    ]
    r = uc.classify(findings, "work", SPINE)
    msg = uc.escalation_message(r)
    # The message must name the upstream phase + that it's a cluster.
    print("ok" if (msg and "plan" in msg and "upstream" in msg) else "BAD:%r" % msg)

elif op == "message-not-detected":
    r = uc.classify([], "work", SPINE)
    print("none" if uc.escalation_message(r) is None else "UNEXPECTED")

elif op == "recipe-blind-empty-order":
    # No phase_order (recipe-blind / non-spine). 3 diverse roles but there are
    # no upstream phases to attribute to → not detected. Proves the classifier
    # reads its phase context from ARGS, never the loop_phase literal.
    findings = [
        {"role": "adversarial", "phase": "plan"},
        {"role": "feasibility", "phase": "plan"},
        {"role": "security",    "phase": "plan"},
    ]
    r = uc.classify(findings, "work", [])
    print(fmt(r))
PYEOF
}

# ─── Scenario 1: 3 diverse-role findings on one upstream phase → detected ─────
it "3 diverse reviewer roles on upstream 'plan' → detected, names plan, count 3"
assert_eq "True|plan|adversarial,feasibility,security|3" "$(uc diverse-upstream)"

# ─── Scenario 2: many same-role LOCAL findings → not flagged ─────────────────
it "12 same-role findings on the CURRENT phase → not flagged"
assert_eq "False|None||0" "$(uc many-same-role-local)"

# ─── Scenario 3: malformed metadata → safe default, never raises ─────────────
it "torn/malformed finding records → safe default (detected=False), no raise"
assert_eq "False|None||0" "$(uc malformed)"

# ─── Scenario 4: diversity over count (KTD-6) ────────────────────────────────
it "10 same-role findings on an UPSTREAM phase → NOT detected (diversity 1 < 3)"
assert_eq "False|None||0" "$(uc diversity-not-count)"

# ─── Scenario 5: current-phase findings are not upstream ─────────────────────
it "3 diverse roles attributed to the CURRENT phase → not detected"
assert_eq "False|None||0" "$(uc current-phase-not-upstream)"

# ─── Scenario 6a: tie on diversity → earliest phase wins ─────────────────────
it "two upstream phases tie on diversity → earliest (brainstorm) wins"
assert_eq "True|brainstorm" "$(uc two-upstream-tiebreak)"

# ─── Scenario 6b: most-diverse phase wins over an earlier-but-less-diverse ───
it "most-diverse upstream phase (plan, 3 roles) wins over brainstorm (2 roles)"
assert_eq "True|plan" "$(uc most-diverse-wins)"

# ─── Scenario 7: escalation_message ──────────────────────────────────────────
it "escalation_message names the upstream phase + cluster on detection"
assert_eq "ok" "$(uc message-detected)"

it "escalation_message returns None when not detected"
assert_eq "none" "$(uc message-not-detected)"

# ─── Scenario 8: args-only phase context (no loop_phase literal read) ────────
it "recipe-blind / empty phase_order → no upstream phases → not detected"
assert_eq "False|None||0" "$(uc recipe-blind-empty-order)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "upstream-cluster.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
