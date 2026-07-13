#!/usr/bin/env bash
# auto v0.3.0 U1 unit test: MECHANICAL single-source-of-truth enforcement for
# the iteration `decision` field — mirrors tests/unit/phase-grammar-ast-lint.test.sh.
#
# Adversarial discipline (matching v0.2.0's KTD-3 lint): it is NOT enough to
# forbid the `step["dispatch_context"]["decision"]` SUBSCRIPT shape — every
# bypass (`_k="decision"; ctx[_k]`, dict iteration, getattr, __getitem__) still
# needs the STRING "decision" to exist somewhere. So this lint forbids the
# string LITERAL "decision" as an ast.Constant anywhere in lib/*.py EXCEPT
# the two allowed files. A new consumer physically cannot re-introduce a
# divergent literal comparison without tripping this.
#
# Exceptions (allowed to contain the literal):
#   - lib/iteration.py        — the sole READER of the iteration-decision field;
#                        this module is the centralized decision point every
#                        caller routes through.
#   - lib/ledger_mutators.py  — the sole WRITER of the iteration-decision field
#                        (via set_verdict_decision). After the B5 split of
#                        ledger.py, set_verdict_decision lives here (the facade
#                        ledger.py only re-exports the NAME, not the literal).
#   - lib/ledger_emitters.py  — clears the iteration-decision field in the
#                        gate-step reset combo (_reset_gate_for_iteration's
#                        dc.pop("decision", None) — round-3 P0-R3-1). After the
#                        B5 split this code lives here, so the literal moved here
#                        with it.
#   - lib/on-stop.py          — uses the literal "decision" for the CLAUDE CODE
#                        HOOK PROTOCOL ({"decision":"block"} in stop-hook output)
#                        — a different "decision" than v0.3.0's iteration
#                        decision. Pre-dates v0.3.0; harness contract, not
#                        internal data.
#
# NOTE: the ledger_mutators.py / ledger_emitters.py allowance is narrow — they
# may CONSTRUCT/WRITE/CLEAR the field, but any decision-comparison logic (e.g.
# recompute_predicate's iteration_pending check in ledger_core.py) must use
# iteration.read_decision(). on-stop.py's allowance covers the harness-protocol
# literal specifically. The facade ledger.py is NOT allowed — its re-exports are
# names, not the string. This test asserts the literal's ABSENCE outside the four
# allowed files; a finer check (write-only vs compare; hook-protocol vs
# iteration-protocol) lives in code review.

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

# The lint, as a reusable python function the deliberate-fail control can re-run.
run_lint() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, ast, glob
auto_root = sys.argv[1]
# Optional extra file path (the deliberate-fail control passes a temp module).
extra = sys.argv[2] if len(sys.argv) > 2 else None

ALLOWED = {"iteration.py", "ledger_mutators.py", "ledger_emitters.py", "on-stop.py"}
LITERAL = "decision"

def offenders_in(path):
    src = open(path).read()
    tree = ast.parse(src, filename=path)
    hits = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and node.value == LITERAL:
            hits.append(node.lineno)
    return hits

files = sorted(glob.glob(os.path.join(auto_root, "lib", "*.py")))
if extra:
    files.append(extra)

bad = []
for path in files:
    base = os.path.basename(path)
    if base in ALLOWED:
        continue
    hits = offenders_in(path)
    if hits:
        bad.append("%s:%s" % (base, ",".join(map(str, hits))))

if bad:
    print("OFFENDERS:" + " ".join(bad))
else:
    print("CLEAN")
PYEOF
}

# ─── Scenario 1: the lint passes on the real tree ───────────────────────────
it "no 'decision' string literal outside iteration.py / ledger_mutators.py / ledger_emitters.py / on-stop.py"
result="$(run_lint)"
if [ "$result" = "CLEAN" ]; then
  pass
else
  fail "$result"
fi

# ─── Scenario 2: deliberate-fail control — a planted literal trips the lint ──
it "deliberate-fail: a planted 'decision' literal in a lib module trips the lint"
tmpmod="${AUTO_ROOT}/lib/__iteration_lint_probe__.py"
# Plant a module containing the forbidden literal in a non-subscript shape
# (proves the lint catches the STRING class, not just dispatch_context["decision"]).
printf '%s\n' '_k = "decision"  # noqa: planted by iteration-ast-lint deliberate-fail' > "$tmpmod"
probe_result="$(run_lint "$tmpmod")"
rm -f "$tmpmod"
case "$probe_result" in
  OFFENDERS:*__iteration_lint_probe__*) pass ;;
  *) fail "planted literal NOT caught: $probe_result" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "iteration-ast-lint.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
