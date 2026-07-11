#!/usr/bin/env bash
# auto U1 unit test: lib/contents.py (content data object loader + validator),
# lib/adapter_ops.py (shared VALID_ADAPTER_OPS leaf), and the two built-in seeds
# (contents/tuned-review.json, contents/scoped-build.json).
#
# A "content" is the pure `invokes` payload of a step — {name, version,
# description, invokes:{adapter_op, prompt_template?}} — carrying NO verification
# gate (R2). This suite locks the loader's resolution (built-in + workspace
# override), the validator's rejections (verification/phase/depends_on keys, bad
# adapter_op, path-traversal prompt_template), the clear not-found error, and the
# shared-leaf symmetry that proves the VALID_ADAPTER_OPS refactor preserved
# orchestrator's dispatch guard.
#
# SELF-CONTAINED inline harness (same style as recipes.test.sh / ledger.test.sh).
#
# Scenarios (U1):
#   1. a valid built-in content (tuned-review) loads and validates
#   2. a content carrying `verification` is rejected, message names the field
#   3. a content whose adapter_op is outside VALID_ADAPTER_OPS is rejected
#   4. a prompt_template with `..` or a leading `/` is rejected
#   5. an unknown content name yields a clear not-found error (not a traceback)
#   6. a workspace .claude/auto/contents/<name>.json overrides a built-in
#   7. adapter_ops.VALID_ADAPTER_OPS equals the set orchestrator.py uses

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

# mktemp sandbox (HOME + a fake repo) so the workspace-override scenario writes
# to an isolated .claude/auto/contents/ dir and nothing leaks into the real tree.
SANDBOX="$(mktemp -d -t contents-test.XXXXXX)"
export HOME="$SANDBOX/home"
REPO="$SANDBOX/repo"
mkdir -p "$HOME" "$REPO"
trap 'rm -rf "$SANDBOX"' EXIT

# Driver: load contents / adapter_ops / orchestrator via _bootstrap, run an op,
# print a stable one-line result. Modules are imported via importlib through the
# _bootstrap loader from an absolute lib/ path (same strategy as recipes.test.sh).
con() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
contents = load_lib_module("contents")
op = sys.argv[2]

def vresult(obj):
    ok, errors = contents.validate_content(obj)
    return "valid" if ok else "rejected:" + " | ".join(errors)

if op == "load-validate":
    # load-validate <name> <repo>: resolve then validate a content by name.
    name, repo = sys.argv[3], sys.argv[4]
    obj = contents.load_content(name, repo)
    print("loaded:" + vresult(obj))
elif op == "validate-json":
    print(vresult(json.loads(sys.argv[3])))
elif op == "load-field":
    # load-field <name> <repo> <field>: resolve + print one top-level field (used
    # to prove workspace override wins).
    name, repo, field = sys.argv[3], sys.argv[4], sys.argv[5]
    obj = contents.load_content(name, repo)
    print(str(obj.get(field)))
elif op == "load-unknown":
    # load-unknown <name> <repo>: an unknown name MUST raise ContentError (a
    # clear operator-facing error), never a bare traceback. Catch ONLY
    # ContentError; any other exception escapes and crashes the driver (which
    # would fail the assertion, proving the not-found path is clean).
    name, repo = sys.argv[3], sys.argv[4]
    try:
        contents.load_content(name, repo)
        print("UNEXPECTED-LOADED")
    except contents.ContentError as e:
        print("notfound:" + str(e))
elif op == "symmetry":
    adapter_ops = load_lib_module("adapter_ops")
    orch = load_lib_module("orchestrator")
    a = adapter_ops.VALID_ADAPTER_OPS
    b = orch.VALID_ADAPTER_OPS
    print("equal" if a == b else ("differ:%r vs %r" % (sorted(a), sorted(b))))
PYEOF
}

echo "contents unit tests"

# ── 1. valid built-in content loads and validates ───────────────────────────
it "tuned-review built-in loads and validates"
assert_eq "loaded:valid" "$(con load-validate tuned-review "$REPO")"

it "scoped-build built-in loads and validates"
assert_eq "loaded:valid" "$(con load-validate scoped-build "$REPO")"

# ── 2. verification field is rejected, message names the field ───────────────
it "content carrying a verification field is rejected, naming the field"
out="$(con validate-json '{"name":"x","version":"1","description":"d","invokes":{"adapter_op":"review"},"verification":[]}')"
case "$out" in rejected:*) : ;; *) fail "expected rejected, got '$out'";; esac
assert_contains "verification" "$out"

# ── 3. adapter_op outside VALID_ADAPTER_OPS is rejected ──────────────────────
it "content with an unknown adapter_op is rejected"
out="$(con validate-json '{"name":"x","version":"1","description":"d","invokes":{"adapter_op":"teleport"}}')"
case "$out" in rejected:*) pass ;; *) fail "expected rejected, got '$out'";; esac

# ── 4. prompt_template traversal / absolute path is rejected ─────────────────
it "prompt_template with '..' is rejected"
out="$(con validate-json '{"name":"x","version":"1","description":"d","invokes":{"adapter_op":"review","prompt_template":"../secret.md"}}')"
case "$out" in rejected:*) pass ;; *) fail "expected rejected, got '$out'";; esac

it "prompt_template with a leading '/' is rejected"
out="$(con validate-json '{"name":"x","version":"1","description":"d","invokes":{"adapter_op":"review","prompt_template":"/etc/passwd"}}')"
case "$out" in rejected:*) pass ;; *) fail "expected rejected, got '$out'";; esac

# ── 5. unknown content name → clear not-found error (not a traceback) ────────
it "unknown content name yields a clear not-found error, not a traceback"
out="$(con load-unknown does-not-exist "$REPO")"
case "$out" in notfound:*) pass ;; *) fail "expected notfound:, got '$out'";; esac
assert_contains "does-not-exist" "$out"

# ── 6. workspace override wins over a same-named built-in ────────────────────
it "workspace .claude/auto/contents/<name>.json overrides a built-in"
mkdir -p "$REPO/.claude/auto/contents"
cat > "$REPO/.claude/auto/contents/tuned-review.json" <<'JSON'
{"name":"tuned-review","version":"99","description":"WORKSPACE-OVERRIDE","invokes":{"adapter_op":"review"}}
JSON
assert_eq "WORKSPACE-OVERRIDE" "$(con load-field tuned-review "$REPO" description)"

# ── 7. shared-leaf symmetry: adapter_ops == orchestrator's dispatch set ──────
it "adapter_ops.VALID_ADAPTER_OPS equals orchestrator.VALID_ADAPTER_OPS"
assert_eq "equal" "$(con symmetry)"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "contents.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
