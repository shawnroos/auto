#!/usr/bin/env bash
# auto v0.4.0 U3: handoff-default flip lint.
#
# v0.4.0 KTD-4: `/auto <plan>` now proceeds past the handoff by default;
# `--review-plan` opts in to the pause. The legacy `auto` positional still
# parses (no-op vs the new default) so scripted callers keep working.
#
# Tests pin _parse_args directly so the bound between flag-string and
# resolved {auto: bool} is checked without spawning a full run. The handoff-
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
SANDBOX="$(mktemp -d -t auto-handoff-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-handoff-test.*) rm -rf "$SANDBOX" ;;
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

# ── Scenario 2: --review-plan opts in to the handoff pause. ─────────────────
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
it "--review-plan interleaved with --backend/--workflow → auto=False"
assert_eq "False" "$(parse_arg /tmp/plan.md --backend native --review-plan --workflow a1)"

# ── Scenario 6: back-compat stderr notice fires exactly once. ────────────
# The notice is anchored at `<resolve_shared_dir>/.handoff-default-acknowledged`.
# In a hermetic test repo (git init + .claude/auto dir absent), the first
# call should produce a stderr line; the second should be silent.
it "back-compat notice: fires on first run, silent on second"
test_repo="$(mktemp -d -t handoff-notice.XXXXXX)"
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
m._handoff_default_notice()
PYEOF
)"
second="$(cd "$test_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._handoff_default_notice()
PYEOF
)"
if echo "$first" | grep -q "handoff-default FLIP" && [ -z "$second" ]; then
  pass
else
  fail "first='$first' second='$second' — expected first non-empty, second empty"
fi
rm -rf "$test_repo"

# ── Scenario 6b: an ack made under the PRE-RENAME marker still counts. ───
# F(C): the rename swept the marker filename `.seam-default-acknowledged` →
# `.handoff-default-acknowledged`. But that file is not a code identifier — it is
# USER STATE on disk, written by the previous version. Renaming it silently un-acks
# every existing user, and the one-time "this default changed" notice fires a second
# time at someone who dismissed it a version ago. So the OLD marker is still honoured.
#
# The setup plants ONLY the legacy marker (exactly what an upgrading user's repo has)
# and asserts the notice stays silent.
it "back-compat notice: an existing .seam-default-acknowledged ack is still honoured"
up_repo="$(mktemp -d -t handoff-upgrade.XXXXXX)"
(
  cd "$up_repo"
  git init -q .
  git config user.email t@t
  git config user.name t
) >/dev/null 2>&1
# Plant the PRE-RENAME marker where the previous version wrote it, and nothing else.
up_shared="$(cd "$up_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF'
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.resolve_shared_dir())
PYEOF
)"
mkdir -p "$up_shared"
printf 'ack' > "${up_shared}/.seam-default-acknowledged"
upgraded="$(cd "$up_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._handoff_default_notice()
PYEOF
)"
if [ -z "$upgraded" ]; then
  pass
else
  fail "the notice RE-FIRED at a user who had already acknowledged it under the pre-rename marker: '${upgraded}'"
fi

# ── Scenario 6a-2: the legacy ack MIGRATES FORWARD (what makes the read droppable) ──
# Honouring the old marker keeps THIS version quiet, but on its own it is a dead end:
# a legacy-ack user would never grow a `.handoff-default-acknowledged`, so dropping the
# legacy read at v0.15.0 (docs/deprecations.md step 6) would re-fire the notice at EVERY
# one of them — the same paper-cut, deferred one minor. So the notice MIGRATES ON READ:
# finding only the old marker, it writes the new one. This asserts the run above (which
# saw only the legacy marker) left the new marker behind.
it "back-compat notice: a legacy-only ack MIGRATES to the new marker (so the v0.15.0 read-drop stays silent)"
if [ -f "${up_shared}/.handoff-default-acknowledged" ]; then
  pass
else
  fail "a legacy-only ack did NOT migrate forward — ${up_shared}/.handoff-default-acknowledged
      was not written, so dropping the legacy read at v0.15.0 re-fires the v0.4.0 notice
      at every user who acked under the old filename. got: $(ls -a "$up_shared" 2>/dev/null | tr '\n' ' ')"
fi

# …and the anti-vacuity floor: the same repo with NO marker at all MUST fire, or the
# assertion above passes for the wrong reason (e.g. resolve_shared_dir returning None).
it "back-compat notice: the same hermetic repo with NO marker DOES fire (anti-vacuity)"
rm -f "${up_shared}/.seam-default-acknowledged" "${up_shared}/.handoff-default-acknowledged"
novac="$(cd "$up_repo" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._handoff_default_notice()
PYEOF
)"
if printf '%s' "$novac" | grep -q "handoff-default FLIP"; then
  pass
else
  fail "the notice did NOT fire in a marker-less repo — Scenario 6b proves nothing. got: '${novac}'"
fi
rm -rf "$up_repo"

# ── Scenario 7: notice degrades gracefully outside a git tree. ───────────
# resolve_shared_dir() returns None outside git; the notice should swallow.
it "back-compat notice: silent in a non-git dir (resolve_shared_dir → None)"
nongit="$(mktemp -d -t handoff-nongit.XXXXXX)"
out="$(cd "$nongit" && "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1 1>/dev/null
import sys, os, importlib.util
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
spec = importlib.util.spec_from_file_location("auto", os.path.join(auto_root, "lib", "auto.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._handoff_default_notice()
PYEOF
)"
assert_eq "" "$out"
rm -rf "$nongit"

# ── summary ────────────────────────────────────────────────────────────────
echo ""
echo "handoff-default.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
