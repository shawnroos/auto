#!/usr/bin/env bash
# auto launch-chooser: lib/launch-mode.{py,sh} — the deterministic
# interactive-vs-headless handoff (R11 / AE6 / KTD-5).
#
# The chooser silent-applies (never enters AskUserQuestion) for a self-driven /
# headless run, and shows for an interactive operator. This pins that decision
# at the shell boundary so a future SKILL edit can't silently drop the guard.
#
# Rule under test:
#   - no CLAUDE_CODE_SESSION_ID            -> headless (no operator present)
#   - session owns a LIVE self-driven run  -> headless (autonomous launch)
#   - otherwise (operator, no owned live self-driven run) -> interactive

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MODE_SH="${AUTO_ROOT}/lib/launch-mode.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n      %s\n" "$CURRENT" "${1:-}"; return 0; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

# ── sandbox repo: a .claude/auto/ ledger dir we point CLAUDE_AUTO_REPO at ─────
SANDBOX="$(mktemp -d -t auto-launch-mode.XXXXXX)"
LEDGERS="${SANDBOX}/.claude/auto"
mkdir -p "$LEDGERS"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

ME="sess-OWNER-1111"
OTHER="sess-OTHER-9999"

# write_ledger <file> <driver> <phase> <driving_session_id>
write_ledger() {
  cat > "${LEDGERS}/$1" <<JSON
{"loop_phase": "$3", "loop": {"driver": "$2"}, "driving_session_id": "$4",
 "phase_order": ["plan","handoff","work"], "steps": []}
JSON
}

# mode runs launch-mode.sh against the sandbox repo with a given session id.
# arg1 = session id ("" => unset/headless env).
mode() {
  if [ -z "$1" ]; then
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO="$SANDBOX" bash "$MODE_SH"
  else
    CLAUDE_CODE_SESSION_ID="$1" CLAUDE_AUTO_REPO="$SANDBOX" bash "$MODE_SH"
  fi
}

reset_ledgers() { rm -f "${LEDGERS}"/*.json 2>/dev/null || true; }

# ── 1. no session id => headless (no operator present) ───────────────────────
reset_ledgers
it "no CLAUDE_CODE_SESSION_ID -> headless (no operator)"
assert_eq "headless" "$(mode "")"

# ── 2. operator, no ledgers (the fresh interactive launch) => interactive ────
reset_ledgers
it "operator + no ledgers -> interactive (fresh /auto, chooser may show)"
assert_eq "interactive" "$(mode "$ME")"

# ── 3. operator owns a LIVE self-driven run => headless ──────────────────────
reset_ledgers
write_ledger "owned-live.json" self work "$ME"
it "operator owns a live self-driven run -> headless (silent-apply)"
assert_eq "headless" "$(mode "$ME")"

# ── 4. a live self-driven run owned by ANOTHER session => interactive ────────
reset_ledgers
write_ledger "other-live.json" self work "$OTHER"
it "live self-driven run owned by another session -> interactive"
assert_eq "interactive" "$(mode "$ME")"

# ── 5. my self-driven run is DONE => interactive (not live) ──────────────────
reset_ledgers
write_ledger "owned-done.json" self done "$ME"
it "my self-driven run is done -> interactive (a finished run is not live)"
assert_eq "interactive" "$(mode "$ME")"

# ── 6. my run is driver=manual => interactive (not autonomous) ───────────────
reset_ledgers
write_ledger "owned-manual.json" manual work "$ME"
it "my run is driver=manual -> interactive (manual is not autonomous)"
assert_eq "interactive" "$(mode "$ME")"

# ── 7. malformed ledger is skipped, a valid owned-live one still wins ─────────
reset_ledgers
printf '{ this is not json ' > "${LEDGERS}/torn.json"
write_ledger "owned-live.json" self plan "$ME"
it "malformed ledger skipped; owned live run still -> headless"
assert_eq "headless" "$(mode "$ME")"

# ── 8. mix: another-session-live + my-done => interactive (none of mine live) ─
reset_ledgers
write_ledger "other-live.json" self work "$OTHER"
write_ledger "owned-done.json" self done "$ME"
it "other-live + my-done -> interactive (no live run owned by me)"
assert_eq "interactive" "$(mode "$ME")"

# ── 9. non-dict `loop` field is skipped, never an AttributeError crash ────────
# A corrupt ledger whose `loop` is a truthy non-dict (a string) must be treated
# as not-an-owner, not crash the scan (the `loop.get(...)` would raise).
reset_ledgers
printf '{"loop_phase":"work","loop":"running","driving_session_id":"%s"}\n' "$ME" > "${LEDGERS}/nondict-loop.json"
it "non-dict loop field owned by me -> interactive (skipped, no crash)"
assert_eq "interactive" "$(mode "$ME")"

# ── 10. a non-dict-loop ledger doesn't abort the scan; a valid owned-live wins ─
reset_ledgers
printf '{"loop_phase":"work","loop":"running","driving_session_id":"%s"}\n' "$ME" > "${LEDGERS}/nondict-loop.json"
write_ledger "owned-live.json" self work "$ME"
it "non-dict loop skipped, valid owned-live run still -> headless"
assert_eq "headless" "$(mode "$ME")"

# ── 11. empty-string session id (SET but empty, not unset) -> headless ────────
# driver_session treats "" as no operator; assert even with an owned-live ledger
# present the empty id short-circuits to headless.
reset_ledgers
write_ledger "owned-live.json" self work "$ME"
it "CLAUDE_CODE_SESSION_ID='' (empty, not unset) -> headless"
assert_eq "headless" "$(CLAUDE_CODE_SESSION_ID="" CLAUDE_AUTO_REPO="$SANDBOX" bash "$MODE_SH")"

echo ""
echo "launch-mode.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
