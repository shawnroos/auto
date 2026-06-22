#!/usr/bin/env bash
# v0.6.0 (security-review fix): auto.py arm-time guard on a null driving_session_id.
#
# The advisor-gate destructive-action backstop (lib/on-pretooluse-action.py) owns a
# run by session-id EQUALITY (PreToolUse stdin.session_id == ledger.driving_session_id).
# If the driving session can't be determined at arm (CLAUDE_CODE_SESSION_ID unset —
# a truly headless context), the recorded id is null and the backstop is DARK for the
# whole run (gates fail open with no owning session). The RESUME path refuses on a null
# id; the ARM path PROCEEDS (a hard refuse would break headless contexts) but must
# NEVER be SILENT. v0.6.4 removed the bogus CLAUDE_CODE_CHILD_SESSION guard (the harness
# sets that in every Bash-tool subprocess, where arm runs — it darkened the backstop on
# every run). This test pins: (1) unset id -> loud "DARK" warning + still armed with a
# null id; (2) CHILD_SESSION set WITH a real id (the normal case) -> backstop ARMS;
# (3) a real id -> no warning + the id is persisted.
#
# SELF-CONTAINED harness (inline it/pass/fail), mirroring the run.sh summary-line
# format ("<name>.test.sh: N passed, M failed").
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AUTO_SH="${AUTO_ROOT}/lib/auto.sh"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0; FAIL=0; CURRENT="anon"
it()   { CURRENT="${1:-anon}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n     %s\n" "$CURRENT" "${1:-}"; }

_mkrepo() {
  local repo; repo="$(mktemp -d)"
  mkdir -p "$repo/docs/plans"
  printf '# Plan: arm guard probe\n\n## Summary\nprobe\n\n## Requirements\n- R1\n' \
    > "$repo/docs/plans/p.md"
  printf '%s' "$repo"
}

# Print the single ledger's driving_session_id ("null" for None, "__NO_LEDGER__" if
# nothing was armed, "__ABSENT__" if the field is missing entirely).
_ledger_sid() {
  "$PY" - "$1" <<'PYEOF'
import json, sys, glob, os
repo = sys.argv[1]
files = sorted(glob.glob(os.path.join(repo, ".claude", "auto", "*.json")))
if not files:
    print("__NO_LEDGER__"); raise SystemExit(0)
d = json.load(open(files[0]))
v = d.get("driving_session_id", "__ABSENT__")
print("null" if v is None else v)
PYEOF
}

# Scenario 1 — null driving session (env unset): warns DARK, still arms, records null.
it "null driving session: warns DARK, still arms, records null id"
repo="$(_mkrepo)"
err="$(CLAUDE_AUTO_REPO="$repo" CLAUDE_CODE_SESSION_ID="" CLAUDE_CODE_CHILD_SESSION="" \
  bash "$AUTO_SH" "$repo/docs/plans/p.md" 2>&1 >/dev/null)"
sid="$(_ledger_sid "$repo")"
if echo "$err" | grep -q "DARK" && [ "$sid" = "null" ]; then pass; else fail "err=[$err] sid=[$sid]"; fi
rm -rf "$repo"

# Scenario 2 (v0.6.4) — CHILD_SESSION truthy is the NORMAL case: the harness sets
# it in every Bash-tool subprocess, which is where auto.sh runs. With a real
# session id present, the backstop must ARM (record the id, NO DARK warning), not
# go dark. This is the regression guard for the bug where the old CHILD_SESSION
# guard darkened the backstop on every run.
it "CHILD_SESSION set with a real id: backstop ARMS (no DARK warning, id persisted)"
repo="$(_mkrepo)"
err="$(CLAUDE_AUTO_REPO="$repo" CLAUDE_CODE_SESSION_ID="sess-xyz" CLAUDE_CODE_CHILD_SESSION="1" \
  bash "$AUTO_SH" "$repo/docs/plans/p.md" 2>&1 >/dev/null)"
sid="$(_ledger_sid "$repo")"
if ! echo "$err" | grep -q "DARK" && [ "$sid" = "sess-xyz" ]; then pass; else fail "err=[$err] sid=[$sid]"; fi
rm -rf "$repo"

# Scenario 3 — real driving session: NO warning + the id is persisted on the ledger.
it "real driving session: no DARK warning, id persisted"
repo="$(_mkrepo)"
err="$(CLAUDE_AUTO_REPO="$repo" CLAUDE_CODE_SESSION_ID="sess-abc-123" CLAUDE_CODE_CHILD_SESSION="" \
  bash "$AUTO_SH" "$repo/docs/plans/p.md" 2>&1 >/dev/null)"
sid="$(_ledger_sid "$repo")"
if ! echo "$err" | grep -q "DARK" && [ "$sid" = "sess-abc-123" ]; then pass; else fail "err=[$err] sid=[$sid]"; fi
rm -rf "$repo"

printf "arm-session-guard.test.sh: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
