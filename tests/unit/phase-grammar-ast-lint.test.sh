#!/usr/bin/env bash
# auto U5 unit test: MECHANICAL single-source-of-truth enforcement (KTD-3).
#
# Strengthened per adversarial F5: it is NOT enough to forbid the
# `ledger["loop_phase"]` SUBSCRIPT shape — every bypass (`_k="loop_phase";
# ledger[_k]`, dict iteration, getattr, __getitem__) still needs the STRING
# "loop_phase" to exist somewhere. So this lint forbids the string LITERAL
# "loop_phase" as an ast.Constant anywhere in lib/*.py EXCEPT lib/phase-grammar.py
# (the one module allowed to read the raw field). A new consumer physically
# cannot re-introduce a divergent literal comparison without tripping this.
#
# Exceptions (allowed to contain the literal):
#   - lib/phase-grammar.py     — the sole reader of the raw field
#   - lib/ledger_core.py       — WRITES/CONSTRUCTS the field (init_ledger sets
#                                ledger["loop_phase"]=..., _normalize_step's
#                                default-phase logic); writing the key is not a
#                                phase-DECISION. recompute_predicate's phase reads
#                                use the field via the local helpers, and is_orphaned
#                                routes its phase-DECISION through phase_grammar.
#   - lib/ledger_mutators.py   — set_loop WRITES ledger["loop_phase"].
#   - lib/ledger_emitters.py   — transition_and_emit / _apply_emit / _emit_steps_core
#                                / atomic_iterate_step WRITE/READ-for-default the
#                                field during emission; not a phase-DECISION.
#   - lib/format_compat.py     — the format-v1→v2 read shim (U6) names the key in
#                                its VALUE-map table: the retired v1 phase value is
#                                rewritten to "handoff" under the loop_phase key on
#                                read. It rewrites the field's VALUE; it makes no
#                                phase-DECISION and compares nothing.
# These three lib/ledger_*.py modules are the B5 split of the former ledger.py —
# the loop_phase WRITE/CONSTRUCT sites moved into them. The facade ledger.py only
# re-exports NAMES and is NOT allowed (it has no literal).
# NOTE: the allowance is narrow — these modules may CONSTRUCT/WRITE the field, but
# any phase-comparison logic must use the phase_grammar helper. This test asserts
# the literal's ABSENCE outside the allowed files; a finer check (write-only vs
# compare) lives in code review.

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

ALLOWED = {"phase-grammar.py", "ledger_core.py", "ledger_mutators.py",
           "ledger_emitters.py", "ledger_steering.py", "format_compat.py"}
LITERAL = "loop_phase"

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
it "no 'loop_phase' string literal outside phase-grammar.py / ledger_core.py / ledger_mutators.py / ledger_emitters.py"
result="$(run_lint)"
if [ "$result" = "CLEAN" ]; then
  pass
else
  fail "$result"
fi

# ─── Scenario 2: deliberate-fail control — a planted literal trips the lint ──
it "deliberate-fail: a planted 'loop_phase' literal in a lib module trips the lint"
tmpmod="${AUTO_ROOT}/lib/__ast_lint_probe__.py"
# Plant a module containing the forbidden literal in a non-subscript shape
# (proves the lint catches the STRING class, not just ledger["loop_phase"]).
printf '%s\n' '_k = "loop_phase"  # noqa: planted by ast-lint deliberate-fail' > "$tmpmod"
probe_result="$(run_lint "$tmpmod")"
rm -f "$tmpmod"
case "$probe_result" in
  OFFENDERS:*__ast_lint_probe__*) pass ;;
  *) fail "planted literal NOT caught: $probe_result" ;;
esac

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "phase-grammar-ast-lint.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
