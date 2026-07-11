#!/usr/bin/env bash
# auto unit test (addressable-step-contents): the module CLIs.
#
# The house convention is a module `_cli`/`__main__` (see lib/verification.py::_cli,
# exercised by tests/unit/verification.test.sh) rather than multi-line `python3 -c`
# heredocs in the skill. This suite exercises the two content CLIs the auto-content
# skill drives as one-liners:
#
#   lib/contents.py         load-validate <name> <repo>
#   lib/content_oneshot.py  validate-criteria <criteria-json>
#   lib/content_oneshot.py  launch <name> <repo>
#   lib/content_oneshot.py  verdict <criteria-json> <prog-json> <judges-json>
#
# SELF-CONTAINED inline harness; python pinned via CLAUDE_AUTO_PYTHON3; the module
# files are invoked directly as CLIs (their __main__ bootstraps lib/ onto sys.path).
#
# Scenarios:
#   1. contents load-validate: a built-in content -> OK.
#   2. contents load-validate: a shape-invalid workspace content -> INVALID (names it).
#   3. content_oneshot validate-criteria: a well-formed list -> OK.
#   4. content_oneshot validate-criteria: a malformed criterion -> INVALID.
#   5. content_oneshot launch: names the built-in content's op + folds its template.
#   6. content_oneshot verdict: all-pass -> pass; any-fail -> fail; empty -> unverified.

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
assert_contains() {
  case "$2" in
    *"$1"*) pass ;;
    *) fail "expected to contain '$1', got '$2'" ;;
  esac
}

# mktemp sandbox for the workspace-override / shape-invalid scenario.
SANDBOX="$(mktemp -d -t content-cli-test.XXXXXX)"
REPO="$SANDBOX/repo"
mkdir -p "$REPO/.claude/auto/contents"
trap 'rm -rf "$SANDBOX"' EXIT

echo "content-cli.test.sh"

# ── 1. contents load-validate: built-in content -> OK ────────────────────────
it "contents CLI load-validate: a built-in content prints OK"
assert_eq "OK" "$("$PY" "$LIB/contents.py" load-validate tuned-review "$REPO")"

# ── 2. contents load-validate: shape-invalid workspace content -> INVALID ─────
cat > "$REPO/.claude/auto/contents/bad.json" <<'JSON'
{"name":"bad","version":"1","description":"d","invokes":{"adapter_op":"review"},"verification":[]}
JSON
it "contents CLI load-validate: a shape-invalid content prints INVALID naming the field"
out="$("$PY" "$LIB/contents.py" load-validate bad "$REPO")"
case "$out" in INVALID:*) : ;; *) fail "expected INVALID:, got '$out'";; esac
assert_contains "verification" "$out"

# ── 3. content_oneshot validate-criteria: well-formed -> OK ──────────────────
it "content_oneshot CLI validate-criteria: a well-formed list prints OK"
assert_eq "OK" "$("$PY" "$LIB/content_oneshot.py" validate-criteria \
  '[{"id":"t","type":"programmatic","argv":["true"],"check":"exit_zero"},{"id":"m","type":"model_judge"}]')"

# ── 4. content_oneshot validate-criteria: malformed -> INVALID ───────────────
it "content_oneshot CLI validate-criteria: a malformed criterion prints INVALID"
out="$("$PY" "$LIB/content_oneshot.py" validate-criteria '[{"id":"c","type":"vibe_check"}]')"
case "$out" in INVALID:*) pass ;; *) fail "expected INVALID:, got '$out'";; esac

# ── 5. content_oneshot launch: names the op + folds the template body ────────
it "content_oneshot CLI launch: names the built-in content's op"
out="$("$PY" "$LIB/content_oneshot.py" launch tuned-review "$AUTO_ROOT")"
assert_contains '"adapter_op": "review"' "$out"

it "content_oneshot CLI launch: folds the content's prompt_template body"
assert_contains "Tuned review prompt" "$out"

# ── 6. content_oneshot verdict: pass / fail / unverified ─────────────────────
it "content_oneshot CLI verdict: all resolved pass -> pass"
assert_contains '"verdict": "pass"' \
  "$("$PY" "$LIB/content_oneshot.py" verdict '[{"id":"p","type":"programmatic"}]' '{"p":"pass"}' '{}')"

it "content_oneshot CLI verdict: any resolved fail -> fail"
assert_contains '"verdict": "fail"' \
  "$("$PY" "$LIB/content_oneshot.py" verdict '[{"id":"p","type":"programmatic"}]' '{"p":"fail"}' '{}')"

it "content_oneshot CLI verdict: no ratified criteria -> unverified (not a silent pass)"
assert_contains '"verdict": "unverified"' \
  "$("$PY" "$LIB/content_oneshot.py" verdict '[]' '{}' '{}')"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "content-cli.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
