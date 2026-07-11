#!/usr/bin/env bash
# auto U7 spike regression guard: the harness/runtime assumptions the agent-native
# runtime is built on. See docs/research/2026-07-10-subagent-runtime-capability-spike.md.
#
# These are not behavior tests of new code — they PIN the load-bearing facts the
# v0.13.0 runtime assumes about the ledger + hooks, so a future refactor (or a
# harness change) that quietly breaks one fails loudly HERE with a pointer to the
# spike, rather than silently darkening the tree runtime or the destructive
# backstop in production.
#
# Asserted (all from the local ledger CLI + hook predicates — no live sub-agent):
#   1. A run + units can be created from the CLI (init) — the spike's closed gap.
#   2. A separate process can RMW the ledger (transition round-trips across a
#      fresh python invocation) — the property the tree runtime rests on.
#   3. force_skip's edges are OUTSIDE ALLOWED_TRANSITIONS (reason cannot be
#      bypassed via transition()).
#   4. terminal-skip is terminal in the predicate BUT does not bury findings.
#   5. The ledger carries the ownership set the hooks gate on (agent_session_ids),
#      and register-session joins it.
#   6. describe lists every CLI verb (the orientation surface stays complete).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
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

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in */auto-test.*) rm -rf "$SANDBOX" ;; esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "${REPO}/.claude/auto"
export CLAUDE_AUTO_REPO="$REPO"

echo "subagent-capability.test.sh"

# ─── 1. init from the CLI (R4 — the spike's closed gap) ──────────────────────
it "a run + units can be created from the CLI (init)"
"$PY" "$LEDGER_PY" init spike '[{"id":"U1"}]' ce work >/dev/null 2>&1
created="$("$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$LEDGER_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_ledger('$REPO','spike');print(l['units'][0]['id'])" 2>/dev/null)"
assert_eq "U1" "$created"

# ─── 2. cross-process RMW (the tree-runtime foundation) ──────────────────────
it "a SEPARATE process can read-modify-write the ledger (transition round-trip)"
"$PY" "$LEDGER_PY" transition "$REPO" spike U1 dispatched >/dev/null 2>&1
state="$("$PY" "$LEDGER_PY" read "$REPO" spike | "$PY" -c "import json,sys;print(json.load(sys.stdin)['units'][0]['state'])")"
assert_eq "dispatched" "$state"

# ─── 3. force_skip edges are outside ALLOWED_TRANSITIONS ─────────────────────
it "force_skip's terminal-skip edges are NOT in ALLOWED_TRANSITIONS (reason can't be bypassed)"
guard="$("$PY" - "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
s=importlib.util.spec_from_file_location("l",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
at = m.ledger_core.ALLOWED_TRANSITIONS
leaked = "terminal-skip" in at.get("pending", set()) or "terminal-skip" in at.get("verdict-returned", set())
print("bypassable" if leaked else "guarded")
PYEOF
)"
assert_eq "guarded" "$guard"

# ─── 4. terminal-skip is terminal but does not bury findings ─────────────────
it "terminal-skip is terminal in the predicate, but a skipped blocker still counts"
verdict="$("$PY" - "$LEDGER_PY" <<'PYEOF'
import sys, importlib.util
s=importlib.util.spec_from_file_location("l",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
pred = m.ledger_predicate
skipped_clean = {"state": "terminal-skip", "findings": []}
skipped_blocker = {"state": "terminal-skip", "findings": [{"severity": "blocker"}]}
b, *_ = pred._count_severities_by_unit({"units": [skipped_blocker]})
print(f"{pred.unit_is_terminal(skipped_clean)}|{pred.unit_is_terminal(skipped_blocker)}|{b}")
PYEOF
)"
# terminal(clean)=True, terminal(blocker)=True, but the blocker is still COUNTED (=1)
assert_eq "True|True|1" "$verdict"

# ─── 5. the ownership set exists + register-session joins it ─────────────────
it "register-session joins the agent_session_ids ownership set the hooks gate on"
"$PY" "$LEDGER_PY" register-session spike sess-KID >/dev/null 2>&1
owners="$("$PY" "$LEDGER_PY" read "$REPO" spike | "$PY" -c "import json,sys;print(json.load(sys.stdin).get('agent_session_ids'))")"
assert_eq "['sess-KID']" "$owners"

# ─── 6. describe stays complete (orientation surface) ────────────────────────
it "describe documents every CLI verb (no undocumented surface)"
diff="$("$PY" - "$LEDGER_PY" <<'PYEOF'
import sys, re, json, subprocess
ledger_py = sys.argv[1]
src = open(ledger_py).read()
cli = set(re.findall(r'cmd == "([a-z-]+)"', src))
out = subprocess.run([sys.executable, ledger_py, "describe"], capture_output=True, text=True).stdout
described = set(json.loads(out).get("verbs", {}).keys())
print(json.dumps({"missing": sorted(cli - described), "extra": sorted(described - cli)}))
PYEOF
)"
assert_eq '{"missing": [], "extra": []}' "$diff"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "subagent-capability.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
