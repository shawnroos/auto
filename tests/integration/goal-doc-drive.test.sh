#!/usr/bin/env bash
# auto U6 integration test: the boss goal-doc drive contract (R13-R17).
#
# The boss drives from one editable goal doc. The fuzzy "is the next step clear?"
# judgment stays in the model; the CRISP outcome is one of two ledger writes, and
# THAT is what this test pins down — never the judgment:
#   - next step clear   -> materialize a unit via a steering verb, keep driving
#                          (driver stays self, Stop hook keeps blocking)
#   - next step unclear -> hand back via auto-resume pause (driver -> manual),
#                          Stop hook's SEAM/MANUAL carve-out allows the stop
#
# Exercises the REAL on-stop.py + ledger + auto-resume, wired as the plugin wires
# them. The goal doc's PROSE cannot fake completion: `met` is computed from real
# verdicts, so AE2 holds regardless of what the doc says.
#
# Scenarios:
#   1. AE2: prose says "done" but a blocker verdict stands -> Stop hook BLOCKS
#   2. AE2 companion: same run, blocker resolved -> Stop hook ALLOWS (the floor is
#      the predicate, and it moves with real verdicts — not with the doc)
#   3. AE4: next step unclear -> auto-resume pause writes driver=manual, and the
#      Stop hook then ALLOWS the stop (clean hand-back)
#   4. R15: a "next step" is materialized as a ledger unit via add-unit (the clear
#      branch), and while it is pending+driver=self the Stop hook BLOCKS
#   5. R17: a human edit between pulses is observable — re-reading the ledger sees
#      the operator's pause (the human's steering channel)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
ON_STOP_PY="${AUTO_ROOT}/lib/on-stop.py"
RESUME_PY="${AUTO_ROOT}/lib/auto-resume.py"
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
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in */auto-test.*) rm -rf "$SANDBOX" ;; esac
}
trap cleanup EXIT

mkrepo() { local repo="${SANDBOX}/repo-${1}"; mkdir -p "${repo}/.claude/auto"; printf '%s' "$repo"; }

jget() {
  "$PY" -c "import json,sys
try: print(json.loads(sys.argv[1]).get(sys.argv[2],''))
except Exception: print('')" "$1" "$2"
}

rd_loop() {
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$1','$2');print(l['loop'].get('$3'))"
}
rd_met() {
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$1','$2');print(l['exit_predicate_result'].get('met'))"
}

# init a work-phase run with the given units json
mk_run() {  # <name> <run> <units-json>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$3" "$LEDGER_PY" <<'PYEOF'
import sys, json, importlib.util
repo, run, units_json, ledger_py = sys.argv[1:5]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_ledger(repo, run, backend="ce", loop_phase="work", units=json.loads(units_json))
PYEOF
  printf '%s' "$repo"
}

# ════════════════════════════════════════════════════════════════════════════
echo "goal-doc-drive.test.sh"

# ─── 1. AE2: prose can't fake done — a blocker verdict blocks the stop ────────
it "AE2: an open blocker verdict blocks the Stop hook (prose is irrelevant)"
REPO="$(mk_run gd-block goaldoc '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"real"}]}]')"
# The boss "rewrote the goal doc to done" — but the goal doc is prose on disk the
# hook never reads; met is computed from the ledger. Confirm the floor holds.
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "block" "$(jget "$out" decision)"
it "AE2: met is false while the blocker stands (the real floor)"
assert_eq "False" "$(rd_met "$REPO" goaldoc)"

# ─── 2. AE2 companion: resolve the blocker -> the floor moves, stop allowed ───
it "AE2 companion: resolving the blocker lets the Stop hook ALLOW (floor tracks verdicts)"
"$PY" - "$REPO" "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
repo, ledger_py = sys.argv[1], sys.argv[2]
s=importlib.util.spec_from_file_location("ledger",ledger_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
# a clean re-verdict (no gating findings) — the real work landing, not a doc edit
L.record_verdict(repo, "goaldoc", "U1", [])
PYEOF
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_empty "$(jget "$out" decision)"

# ─── 3. AE4: next step unclear -> hand back via pause -> Stop hook allows ─────
it "AE4: an unclear next step hands back — auto-resume pause writes driver=manual"
REPO="$(mk_run gd-pause goaldoc '[{"id":"U1","state":"verdict-returned","findings":[{"severity":"blocker","note":"stuck"}]}]')"
# driver=self + unmet would normally BLOCK; the boss cannot resolve the next step,
# so it hands back rather than guessing.
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "block" "$(jget "$out" decision)"   # still self-driven here -> blocks
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RESUME_PY" pause goaldoc "next step is ambiguous — handing back" >/dev/null 2>&1
assert_eq "manual" "$(rd_loop "$REPO" goaldoc driver)"
it "AE4: after hand-back the Stop hook ALLOWS the stop (SEAM/MANUAL carve-out)"
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_empty "$(jget "$out" decision)"

# ─── 4. R15: the clear branch — a next step becomes a ledger unit ─────────────
it "R15: a 'next step' materializes as a pending unit via add-unit"
REPO="$(mk_run gd-add goaldoc '[{"id":"U1","state":"verdict-returned","findings":[]}]')"
export CLAUDE_AUTO_REPO="$REPO"
"$PY" "$LEDGER_PY" add-unit goaldoc U2 >/dev/null
unset CLAUDE_AUTO_REPO
state="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$REPO','goaldoc');print(next(x['state'] for x in l['units'] if x['id']=='U2'))")"
assert_eq "pending" "$state"
it "R15: while the new unit is pending+driver=self, the Stop hook BLOCKS (keep driving)"
out="$(printf '{}' | "$PY" "$ON_STOP_PY" "$REPO")"
assert_eq "block" "$(jget "$out" decision)"

# ─── 5. R17: the human steers by editing — the pause is observable next pulse ─
REPO="$(mk_run gd-human goaldoc '[{"id":"U1","state":"pending"}]')"
it "R17: a fresh run starts self-driven"
assert_eq "self" "$(rd_loop "$REPO" goaldoc driver)"
it "R17: the operator's steer (a pause) is observable on the next ledger read"
CLAUDE_AUTO_REPO="$REPO" "$PY" "$RESUME_PY" pause goaldoc "operator: pivot to the other approach" >/dev/null 2>&1
assert_eq "manual" "$(rd_loop "$REPO" goaldoc driver)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "goal-doc-drive.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
