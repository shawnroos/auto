#!/usr/bin/env bash
# auto unit test: goal-route.py — the deterministic goal-aware routing DECISION.
#
# The fuzzy match verdict stays in the model; THIS truth table locks the crisp
# routing branches (R6/R7/R8/R9/R12) and the load-bearing guardrail: fan-out
# suppression is emitted ONLY for an explicit goal on an interactive run. A
# self-driven run, or an inferred goal, can never produce suppress_fanout=true —
# that is the mechanical enforcement of the always-ask safety gate the
# adversarial doc-review flagged (prose alone could be misread; code cannot).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ROUTE="${AUTO_ROOT}/lib/goal-route.py"

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

# Pull one top-level field out of goal-route.py's JSON output.
field() { printf '%s' "$1" | "$PY" -c 'import json,sys; v=json.loads(sys.stdin.read())[sys.argv[1]]; print("null" if v is None else v)' "$2"; }

# Assert reason + suppress_fanout (+ optional preselect) for one payload.
assert_route() {
  local desc="$1" payload="$2" want_reason="$3" want_suppress="$4" want_preselect="${5:-}"
  it "$desc"
  local out; out="$("$PY" "$ROUTE" "$payload" 2>/dev/null)"
  local reason suppress preselect
  reason="$(field "$out" reason)"
  suppress="$(field "$out" suppress_fanout)"
  if [ "$reason" != "$want_reason" ]; then fail "reason: got '$reason' want '$want_reason' (out: $out)"; return; fi
  if [ "$suppress" != "$want_suppress" ]; then fail "suppress_fanout: got '$suppress' want '$want_suppress' (out: $out)"; return; fi
  if [ -n "$want_preselect" ]; then
    preselect="$(field "$out" preselect)"
    if [ "$preselect" != "$want_preselect" ]; then fail "preselect: got '$preselect' want '$want_preselect'"; return; fi
  fi
  pass
}

# ── Interactive + explicit → narrow (suppress) ──────────────────────────────
assert_route "explicit + 2 matches + interactive → explicit-suppress, suppress, preselect top" \
  '{"authority":"explicit","matches":["p2","p1"],"all_plans":["p1","p2"],"interactive":true}' \
  explicit-suppress True p2
assert_route "explicit + single match + interactive → explicit-suppress, suppress (confirm still fires)" \
  '{"authority":"explicit","matches":["p1"],"all_plans":["p1","p2"],"interactive":true}' \
  explicit-suppress True p1

# ── Interactive + inferred → nudge (re-rank, NEVER suppress) ─────────────────
assert_route "inferred + match + interactive → inferred-re-rank, NO suppress, preselect top" \
  '{"authority":"inferred","matches":["p2"],"all_plans":["p1","p2","p3"],"interactive":true}' \
  inferred-re-rank False p2

it "inferred re-rank orders matches first, keeps the rest"
out="$("$PY" "$ROUTE" '{"authority":"inferred","matches":["p2"],"all_plans":["p1","p2","p3"],"interactive":true}')"
ranked="$(printf '%s' "$out" | "$PY" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["ranked"]))')"
if [ "$ranked" = "p2,p1,p3" ]; then pass; else fail "ranked: got '$ranked' want 'p2,p1,p3'"; fi

# ── Passthrough branches ────────────────────────────────────────────────────
assert_route "explicit + no match + interactive → no-match-unchanged, no suppress" \
  '{"authority":"explicit","matches":[],"all_plans":["p1","p2"],"interactive":true}' \
  no-match-unchanged False
assert_route "no goal + interactive → no-goal-unchanged, no suppress" \
  '{"authority":"none","matches":[],"all_plans":["p1","p2"],"interactive":true}' \
  no-goal-unchanged False

# ── R12 ENFORCEMENT (the guardrail control) ─────────────────────────────────
# A self-driven run with an explicit goal AND a match must STILL passthrough and
# NOT suppress. This is the mechanical proof that the safety gate cannot be
# bypassed off the interactive path — prose could be misread; this cannot.
assert_route "self-driven + explicit + match → self-driven-unchanged, NEVER suppress (R12)" \
  '{"authority":"explicit","matches":["p1"],"all_plans":["p1"],"interactive":false}' \
  self-driven-unchanged False
assert_route "self-driven + inferred + match → self-driven-unchanged, no suppress" \
  '{"authority":"inferred","matches":["p1"],"all_plans":["p1"],"interactive":false}' \
  self-driven-unchanged False

# ── Degrade-safe: bad input never suppresses ────────────────────────────────
assert_route "malformed JSON → passthrough, no suppress" \
  'not json at all' \
  no-goal-unchanged False
assert_route "explicit but matches is null → no-match-unchanged, no suppress" \
  '{"authority":"explicit","matches":null,"interactive":true}' \
  no-match-unchanged False

# ── Global invariant sweep: suppress=True implies explicit AND interactive ──
# Deliberate-fail control at the invariant level: probe the whole cross product
# and assert NO combination outside (explicit × interactive) ever suppresses.
it "invariant: suppress_fanout=True only for explicit × interactive"
bad=""
for auth in explicit inferred none; do
  for inter in true false; do
    out="$("$PY" "$ROUTE" "{\"authority\":\"$auth\",\"matches\":[\"p1\"],\"all_plans\":[\"p1\"],\"interactive\":$inter}")"
    s="$(field "$out" suppress_fanout)"
    if [ "$s" = "True" ] && ! { [ "$auth" = "explicit" ] && [ "$inter" = "true" ]; }; then
      bad="${bad} ${auth}/${inter}"
    fi
  done
done
if [ -z "$bad" ]; then pass; else fail "suppress leaked on:${bad}"; fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "goal-route.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
