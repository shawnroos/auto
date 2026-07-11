#!/usr/bin/env bash
# auto U2 unit test (addressable-step-contents): synthesize_oneshot_unit.
#
# SELF-CONTAINED: minimal inline it/pass/fail/assert_eq harness, mktemp sandbox,
# python pinned via CLAUDE_AUTO_PYTHON3, modules loaded via importlib from an
# absolute path (matching tests/unit/ledger.test.sh + tests/spike conventions).
#
# Scenarios (U2 plan, KTD-3 / KTD-4):
#   1. synth from a valid content -> ONE work unit whose dispatch_context.adapter_op
#      == the content's op (and prompt_template carried when present).
#   2. the unit has NO `iteration` block and NO `phase_transitions` (KTD-3 — the
#      one-shot never loops).
#   3. ratified criteria are present on the unit AND readable WITHOUT read_dc
#      (KTD-4). We also assert read_dc WOULD KeyError on the criteria key — proving
#      exactly why the one-shot reads it directly rather than through read_dc.
#   4. no criteria supplied -> the unit carries none (not an empty-gate default).

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

echo "content-oneshot-synth.test.sh"

# A single python probe emits a comma-joined token line the bash scenarios assert
# against. On any import/attr failure it prints IMPORT-FAIL so the test goes RED
# (the deliberate-fail-once smoke check before the function exists).
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
    iteration = load("iteration")
except Exception as e:  # module/function missing -> RED
    print("IMPORT-FAIL:%s" % e)
    sys.exit(0)

content = {
    "name": "tuned-review",
    "version": "1",
    "description": "a tuned review",
    "invokes": {"adapter_op": "review", "prompt_template": "contents/tuned-review.prompt.md"},
}
criteria = [
    {"id": "c1", "type": "programmatic", "argv": ["true"], "check": "exit_zero"},
    {"id": "c2", "type": "model_judge", "prompt": "is it good?"},
]

results = []

# ── Scenario 1: one unit, dispatch_context.adapter_op == content op ──────────
u = co.synthesize_oneshot_unit(content, criteria)
dc = u.get("dispatch_context") or {}
results.append("op=%s" % dc.get("adapter_op"))
results.append("tmpl=%s" % dc.get("prompt_template"))

# ── Scenario 2: no iteration block, no phase_transitions ─────────────────────
results.append("has_iter=%s" % ("iteration" in u))
results.append("has_pt=%s" % ("phase_transitions" in u))

# ── Scenario 3: criteria present + readable WITHOUT read_dc (KTD-4) ──────────
# The criteria live on a plain top-level key -> a direct dict read works.
baked = u.get("one_shot_verification")
results.append("baked_ids=%s" % ",".join(c.get("id") for c in (baked or [])))
# And read_dc MUST raise KeyError for that key (it is not a declared
# dispatch_context key) — that is the whole reason the one-shot reads it directly.
try:
    iteration.read_dc(u, "one_shot_verification")
    results.append("readdc=NO-RAISE")
except KeyError:
    results.append("readdc=keyerror")

# ── Scenario 4: no criteria -> unit carries none (not an empty-gate default) ──
u_none = co.synthesize_oneshot_unit(content, None)
results.append("none_has_key=%s" % ("one_shot_verification" in u_none))
u_empty = co.synthesize_oneshot_unit(content, [])
results.append("empty_has_key=%s" % ("one_shot_verification" in u_empty))

print(";".join(results))
PYEOF
}

OUT="$(probe)"

get() { printf '%s' "$OUT" | tr ';' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

it "synth yields one work unit whose dispatch_context.adapter_op == content op"
assert_eq "review" "$(get op)"

it "the content's prompt_template is carried into dispatch_context"
assert_eq "contents/tuned-review.prompt.md" "$(get tmpl)"

it "the synthesized unit has no iteration block (KTD-3)"
assert_eq "False" "$(get has_iter)"

it "the synthesized unit has no phase_transitions (KTD-3)"
assert_eq "False" "$(get has_pt)"

it "ratified criteria are baked on the unit, readable via a plain dict read (KTD-4)"
assert_eq "c1,c2" "$(get baked_ids)"

it "read_dc would KeyError on the criteria key — why the one-shot reads it directly (KTD-4)"
assert_eq "keyerror" "$(get readdc)"

it "no criteria supplied -> the unit carries no one_shot_verification key (not an empty-gate default)"
assert_eq "False" "$(get none_has_key)"

it "empty criteria list -> still no one_shot_verification key (not an empty-gate default)"
assert_eq "False" "$(get empty_has_key)"

echo ""
echo "content-oneshot-synth.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
