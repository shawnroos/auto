#!/usr/bin/env bash
# auto U2 (finding #9): the Stop hook fired an IDENTICAL blocking message on every
# turn-end (~10x across a run) even while the boss was correctly yielding for live
# work. U2 de-duplicates that nag: the FIRST block for a given blocking state
# emits the full guidance; subsequent turns with the SAME state emit a terse
# one-liner. The block itself is ALWAYS preserved (deliberate-stop is not
# silenced — there is no per-agent liveness signal to safely downgrade the block;
# that is deferred to future work). When the blocking state clears or changes,
# the full guidance re-emits.
#
# Institutional anchors:
#   - field-notes-2026-07-21 finding #9 (identical blocking re-prompt ~10x)
#   - KTD2: dedup ≠ silence — a fresh run-level beat does not prove agent liveness

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }

# Plant a single blocking run (driver=self, fresh beat → not stale, met=false).
plant_block() {
  local repo="$1" run="$2" blockers="$3"
  mkdir -p "${repo}/.claude/auto"
  "$PY" - "$repo" "$run" "$blockers" <<'PYEOF'
import json, sys, os
repo, run, blockers = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = {
  "run_id": run, "loop_phase": "work",
  "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
  "exit_predicate_result": {"met": False, "blockers": blockers, "majors": 0,
                            "all_steps_terminal": False},
}
with open(os.path.join(repo, ".claude", "auto", run + ".json"), "w") as f:
  json.dump(data, f)
PYEOF
}

decide() { ( cd "$1" && "$PY" "$ON_STOP" "$1" </dev/null 2>/dev/null ) || true; }
is_block() { printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; }
is_full() { printf '%s' "$1" | grep -q 'YIELD silently'; }   # full-guidance marker

echo "stop-nag-dedup.test.sh"

REPO="$(mktemp -d -t auto-test.XXXXXX)"
plant_block "$REPO" "run-x" 1

it "#9: first block emits the FULL guidance and blocks"
OUT1="$(decide "$REPO")"
if is_block "$OUT1" && is_full "$OUT1"; then pass; else fail "expected full block, got: $OUT1"; fi

it "#9: second block on the SAME state is DEDUPED (terse) but STILL blocks"
OUT2="$(decide "$REPO")"
if is_block "$OUT2" && ! is_full "$OUT2"; then pass; else fail "expected deduped block, got: $OUT2"; fi

it "#9: a CHANGED blocking state re-emits the full guidance"
plant_block "$REPO" "run-x" 3   # blockers 1 → 3 : signature changes
OUT3="$(decide "$REPO")"
if is_block "$OUT3" && is_full "$OUT3"; then pass; else fail "expected full block after change, got: $OUT3"; fi

it "#9: when blocking clears, the nag state resets (allow stop, no message)"
rm -f "${REPO}/.claude/auto/run-x.json"
OUT4="$(decide "$REPO")"
if [ -z "$(printf '%s' "$OUT4" | tr -d '[:space:]')" ]; then pass; else fail "expected silent allow, got: $OUT4"; fi

it "#9: after a clear, a NEW block emits full guidance again (state was reset)"
plant_block "$REPO" "run-x" 1
OUT5="$(decide "$REPO")"
if is_block "$OUT5" && is_full "$OUT5"; then pass; else fail "expected full block after reset, got: $OUT5"; fi

rm -rf "$REPO"

echo ""
echo "stop-nag-dedup.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
