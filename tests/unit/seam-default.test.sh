#!/usr/bin/env bash
# auto v0.4.0 U3: seam-default flip lint.
#
# v0.4.0 KTD-4: `/auto <plan>` now proceeds past the seam by default;
# `--review-plan` opts in to the pause. The legacy `auto` positional still
# parses (no-op vs the new default) so scripted callers keep working.
#
# Tests pin _parse_args directly so the bound between flag-string and
# resolved {auto: bool} is checked without spawning a full run. The seam-
# default-acknowledged marker test exercises the once-per-host-repo
# stderr notice path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# ── Minimal inline test harness ────────────────────────────────────────────
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

# ── HOME / sandbox isolation ───────────────────────────────────────────────
ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-seam-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-seam-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

# ── Helper: probe _parse_args. ─────────────────────────────────────────────
# parse_arg <auto-arg-tokens...>  — prints the parsed `auto` value as
#   "True"/"False" so the test assertions stay simple strings.
parse_arg() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
argv = sys.argv[2:]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
parsed = m._parse_args(argv)
print(parsed["auto"])
PYEOF
}

# ── Scenario 1: bare `/auto <plan>` → auto=True (the v0.4.0 default). ────
it "v0.4.0 default: /auto <plan> (no token, no flag) → auto=True"
assert_eq "True" "$(parse_arg /tmp/plan.md)"

# ── Scenario 2: --review-plan opts in to the seam pause. ─────────────────
it "/auto <plan> --review-plan → auto=False (opt-in to pause)"
assert_eq "False" "$(parse_arg /tmp/plan.md --review-plan)"

# ── Scenario 3: legacy `auto` positional still parses (no-op vs default). ─
it "legacy /auto <plan> auto → still auto=True (back-compat)"
assert_eq "True" "$(parse_arg /tmp/plan.md auto)"

# ── Scenario 4: --review-plan after legacy `auto` token still wins. ──────
# A scripted caller that drops `auto` but adds --review-plan during the
# upgrade should land on the explicit-pause behavior.
it "--review-plan after legacy auto → auto=False (explicit opt-in wins)"
assert_eq "False" "$(parse_arg /tmp/plan.md auto --review-plan)"

# ── Scenario 5: --review-plan with other flags interleaved. ──────────────
it "--review-plan interleaved with --backend/--recipe → auto=False"
assert_eq "False" "$(parse_arg /tmp/plan.md --backend native --review-plan --recipe a1)"

# ── Scenario 6: back-compat stderr notice fires exactly once. ────────────
# The notice is anchored at `<resolve_shared_dir>/.seam-default-acknowledged`.
# In a hermetic test repo (git init + .claude/auto dir absent), the first
# call should produce a stderr line; the second should be silent.
it "back-compat notice: fires on first run, silent on second"
test_repo="$(mktemp -d -t seam-notice.XXXXXX)"
(
  cd "$test_repo"
  git init -q .
  git config user.email t@t
  git config user.name t
) >/dev/null 2>&1
# Run the notice function twice; capture stderr each time.
first="$(cd "$test_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._seam_default_notice()
PYEOF
)"
second="$(cd "$test_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._seam_default_notice()
PYEOF
)"
if echo "$first" | grep -q "seam-default FLIP" && [ -z "$second" ]; then
  pass
else
  fail "first='$first' second='$second' — expected first non-empty, second empty"
fi
rm -rf "$test_repo"

# ── Scenario 7: notice degrades gracefully outside a git tree. ───────────
# resolve_shared_dir() returns None outside git; the notice should swallow.
it "back-compat notice: silent in a non-git dir (resolve_shared_dir → None)"
nongit="$(mktemp -d -t seam-nongit.XXXXXX)"
out="$(cd "$nongit" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._seam_default_notice()
PYEOF
)"
assert_eq "" "$out"
rm -rf "$nongit"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "seam-default.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
