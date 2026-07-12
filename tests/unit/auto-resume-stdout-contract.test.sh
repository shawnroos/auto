#!/usr/bin/env bash
# auto regression test: /auto-resume stdout contract.
#
# The re-arm paths (`continue` seam→work, `advance` plan→enumerate) MUST emit
# exactly ONE JSON object on stdout and NOTHING on stderr. This guards the
# driver-facing contract documented in skills/auto/SKILL.md §2 and
# commands/auto-resume.md: the driver parses the WHOLE of stdout with json.loads,
# so a stray prose line on EITHER stream is a contract break.
#
# Why both axes: a stdout-only "is this valid JSON" assertion would PASS even if a
# warning leaked to stderr (which a merged-stream consumer would see as noise). The
# clean-stderr assertion is what actually locks the contract down. Mirrors the
# harness env of tests/unit/auto-resume-advance.test.sh exactly.

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

run_scenario() {
  scenario="$1"
  "$PY" - "$AUTO_ROOT" "$scenario" <<'PYEOF'
import sys, os, importlib.util, tempfile, glob, json, io, contextlib
auto_root, scenario = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

a = load("auto", os.path.join(auto_root, "lib", "auto.py"))
ledger = load("ledger", os.path.join(auto_root, "lib", "ledger.py"))
resume = load("auto_resume", os.path.join(auto_root, "lib", "auto-resume.py"))
pulse = load("pulse", os.path.join(auto_root, "lib", "pulse.py"))

repo = tempfile.mkdtemp(); os.environ["CLAUDE_AUTO_REPO"] = repo
# Re-arm paths re-record the driving session (advisor-gate ownership) and REFUSE
# without one — provide an interactive session id and clear the child marker, same
# as auto-resume-advance.test.sh / hooks.test.sh.
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-STDOUT-CONTRACT-TEST"
os.environ.pop("CLAUDE_CODE_CHILD_SESSION", None)
os.makedirs(os.path.join(repo, ".claude", "auto"), exist_ok=True)
plan = os.path.join(repo, "plan.md"); open(plan, "w").write("# plan\n")

# Fresh a1 run: starts at loop_phase=plan, plan_step=null.
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    a.run([plan])
run_id = None
for f in glob.glob(os.path.join(repo, ".claude", "auto", "*.json")):
    if not f.endswith(".lock"):
        run_id = os.path.basename(f).rsplit(".json", 1)[0]
        break

if scenario == "continue":
    # seam→work continue.
    ledger.set_loop(repo, run_id, loop_phase="seam", seam_paused=True, driver="manual")
    fn = lambda: resume._cmd_continue(ledger, repo, run_id)
elif scenario == "advance":
    # plan→enumerate advance.
    fn = lambda: resume._cmd_advance(ledger, repo, run_id)

out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    rc = fn()
o, e = out.getvalue(), err.getvalue()

# Discriminators: stdout is exactly one JSON object; stderr is empty; the object
# is the arm-pulse intent (proves we captured the re-arm, not a terminal no-op).
stdout_is_one_json = False
is_arm = False
try:
    obj = json.loads(o.strip())
    stdout_is_one_json = isinstance(obj, dict)
    is_arm = obj.get("action") == "arm-pulse"
except Exception:
    pass
stderr_clean = (e.strip() == "")
print("%s|%s|%s|%s" % (stdout_is_one_json, stderr_clean, is_arm, rc))
PYEOF
}

# ─── continue (seam→work): one JSON object on stdout, clean stderr ──────────────
it "continue(seam→work): stdout is exactly one arm-pulse JSON object, stderr clean"
res="$(run_scenario continue)"
IFS='|' read -r c_json c_err c_arm c_rc <<EOF
$res
EOF
[ "$c_json" = "True" ] && [ "$c_err" = "True" ] && [ "$c_arm" = "True" ] && [ "$c_rc" = "0" ] \
  && pass || fail "expected True|True|True|0, got ${res}"

# ─── advance (plan→enumerate): one JSON object on stdout, clean stderr ──────────
it "advance(plan→enumerate): stdout is exactly one arm-pulse JSON object, stderr clean"
res_a="$(run_scenario advance)"
IFS='|' read -r a_json a_err a_arm a_rc <<EOF
$res_a
EOF
[ "$a_json" = "True" ] && [ "$a_err" = "True" ] && [ "$a_arm" = "True" ] && [ "$a_rc" = "0" ] \
  && pass || fail "expected True|True|True|0, got ${res_a}"

echo ""
echo "auto-resume-stdout-contract.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
