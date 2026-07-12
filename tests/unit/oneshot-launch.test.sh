#!/usr/bin/env bash
# auto U5 unit test (addressable-step-contents): build_oneshot_launch.
#
# U5 / KTD-5: for the DRIVER-orchestrated one-shot, the preset's optional
# `prompt_template` is folded into the launched sub-agent's prompt by the DRIVER,
# never by a backend edit. build_oneshot_launch is the thin lib seam the
# auto-preset skill calls to build the launch descriptor: it names the op and,
# when the preset declares a prompt_template, folds the template's BODY in.
# Template-less presets produce the plain op invocation (regression-safe).
#
# SELF-CONTAINED harness; python pinned via CLAUDE_AUTO_PYTHON3; module loaded
# via importlib from an absolute path.
#
# Scenarios (U5 plan, KTD-5):
#   1. a preset WITHOUT prompt_template -> plain op invocation (no template
#      key on the descriptor) — the regression case.
#   2. a preset WITH prompt_template -> the template body is folded into the
#      launch descriptor.
#   3. a preset with a valid op -> the descriptor NAMES that op.

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

echo "oneshot-launch.test.sh"

# Probe resolves the built-in `tuned-review` seed (which HAS a prompt_template)
# against AUTO_ROOT as the repo, and a hand-built template-less preset.
probe() {
  "$PY" - "$LIB" "$AUTO_ROOT" <<'PYEOF'
import sys, importlib.util

lib = sys.argv[1]
auto_root = sys.argv[2]
if lib not in sys.path:
    sys.path.insert(0, lib)

def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{lib}/{name}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

try:
    co = load("preset_oneshot")
    presets = load("presets")
    fn = co.build_oneshot_launch
except Exception as e:  # module/function missing -> RED
    print("IMPORT-FAIL:%s" % e)
    sys.exit(0)

results = []

# ── Scenario 1: template-less preset -> plain op invocation (regression) ────
plain = {
    "name": "plain-review",
    "version": "1",
    "description": "a template-less review preset",
    "invokes": {"adapter_op": "review"},
}
d_plain = fn(plain, auto_root)
results.append("plain_op=%s" % d_plain.get("adapter_op"))
results.append("plain_has_tmpl=%s" % ("prompt_template" in d_plain))
results.append("plain_has_body=%s" % ("prompt_template_body" in d_plain))

# ── Scenario 2 + 3: the built-in tuned-review seed HAS a prompt_template ──────
# load_preset resolves the shipped seed; build_oneshot_launch folds its body.
try:
    tuned = presets.load_preset("tuned-review", auto_root)
except Exception as e:
    print("LOAD-FAIL:%s" % e)
    sys.exit(0)
d_tuned = fn(tuned, auto_root)
results.append("tuned_op=%s" % d_tuned.get("adapter_op"))
body = d_tuned.get("prompt_template_body") or ""
results.append("tuned_body_folds=%s" % ("Tuned review prompt" in body))
results.append("tuned_has_tmpl=%s" % ("prompt_template" in d_tuned))

print(";".join(results))
PYEOF
}

OUT="$(probe)"
get() { printf '%s' "$OUT" | tr ';' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

it "a template-less preset yields the plain op invocation naming its op"
assert_eq "review" "$(get plain_op)"

it "a template-less preset carries no prompt_template key (regression-safe)"
assert_eq "False" "$(get plain_has_tmpl)"

it "a template-less preset carries no folded body"
assert_eq "False" "$(get plain_has_body)"

it "a preset with a valid op produces a launch naming that op"
assert_eq "review" "$(get tuned_op)"

it "a preset WITH a prompt_template folds the template body into the descriptor"
assert_eq "True" "$(get tuned_body_folds)"

it "a preset WITH a prompt_template records the template path on the descriptor"
assert_eq "True" "$(get tuned_has_tmpl)"

# ── Scenario 4: workspace template WINS over the built-in (pins workspace-first) ─
# build_oneshot_launch searches (repo, _AUTO_ROOT). A workspace repo carrying the
# SAME relative template path as a shipped seed must fold the WORKSPACE body — a
# regression to built-in-first would silently fold the seed's body instead. (The
# other scenarios pass AUTO_ROOT as the repo, collapsing both bases, so this is
# the only scenario that actually pins the order.)
TMPREPO="$(mktemp -d -t auto-oneshot.XXXXXX)"
mkdir -p "${TMPREPO}/presets"
printf 'WORKSPACE-OVERRIDE-SENTINEL\n' > "${TMPREPO}/presets/tuned-review.prompt.md"
OVERRIDE_BODY="$(
  "$PY" - "$LIB" "$AUTO_ROOT" "$TMPREPO" <<'PYEOF'
import sys, importlib.util
lib, auto_root, tmprepo = sys.argv[1], sys.argv[2], sys.argv[3]
if lib not in sys.path:
    sys.path.insert(0, lib)
def load(name):
    spec = importlib.util.spec_from_file_location(name, f"{lib}/{name}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
co = load("preset_oneshot"); presets = load("presets")
# built-in seed; its prompt_template is the relative 'presets/tuned-review.prompt.md'
tuned = presets.load_preset("tuned-review", auto_root)
d = co.build_oneshot_launch(tuned, tmprepo)  # repo=tmprepo -> workspace searched first
body = d.get("prompt_template_body") or ""
print("sentinel" if "WORKSPACE-OVERRIDE-SENTINEL" in body else "builtin")
PYEOF
)"
case "$TMPREPO" in */auto-oneshot.*) rm -rf "$TMPREPO" ;; esac

it "a workspace template overrides the built-in seed's (workspace-first order)"
assert_eq "sentinel" "$OVERRIDE_BODY"

echo ""
echo "oneshot-launch.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
