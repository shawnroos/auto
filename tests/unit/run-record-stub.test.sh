#!/usr/bin/env bash
# auto unit test: the U9 KTD-4 forwarding stubs — lib/ledger.py + lib/ledger.sh.
#
# WHY THIS TEST EXISTS (it guards a SILENT failure mode, which is the worst kind):
#
# U9 renamed the run-record module family (`ledger*` → `run_record*`) and left
# `lib/ledger.py` behind as a stub. Every OTHER retired path in this rename got a
# 2-line bash exec forwarder — but `lib/ledger.py` CANNOT be one, because it is not
# only executed, it is IMPORTED BY PATH and then reached for by SYMBOL:
#
#     spec = importlib.util.spec_from_file_location("ledger", ".../lib/ledger.py")
#     L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
#     L.ledger_path(repo, run)          # ← a symbol on the module object
#
# That is exactly what `lib/cmux-socket.sh` did at BOTH of its
# `spec_from_file_location` sites — and every one of those blocks is wrapped in
# `except: sys.exit(0)`. So a CLI-exec-only stub (which defines no `ledger_path`
# under `exec_module`) would raise AttributeError, the bare `except` would SWALLOW
# it, `sys.exit(0)` would return an empty path, and the runaway-spawn sentinel +
# the double-drive guard would FAIL OPEN — silently, with a green suite. No test
# anywhere else in the tree would notice.
#
# U9 fixes that twice over (belt AND suspenders):
#   * SUSPENDERS — cmux-socket.sh is repointed at `run_record.py` / `run_record_path`.
#   * BELT — `lib/ledger.py` stays a module-importable RE-EXPORT shim, so ANY
#     out-of-tree caller with the memorized path still resolves the old symbols.
#
# Both stubs are PATH-WHITELISTED in tests/unit/vocabulary-audit.test.sh, which means
# that audit structurally CANNOT fail on them — so nothing there would notice if they
# broke either. THIS file is the thing that notices. It pins:
#   1. by-path load + OLD symbol access (the exact cmux-socket shape) resolves;
#   2. the error classes are the SAME objects (`except ledger.LedgerError` still
#      catches a raise from the run_record family — the duplicate-class-identity
#      failure mode the import-topology DAG lint documents);
#   3. the legacy CLI still works AND its stdout is BYTE-CLEAN (a legacy
#      `ledger.py read | jq` pipeline must not ingest the deprecation notice);
#   4. lib/ledger.sh forwards to lib/run_record.sh, also byte-clean;
#   5. cmux-socket's spawn-sentinel / pulse-lock path computation resolves a REAL
#      path post-rename instead of silently `sys.exit(0)`-ing to empty.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LEDGER_PY_STUB="${AUTO_ROOT}/lib/ledger.py"
LEDGER_SH_STUB="${AUTO_ROOT}/lib/ledger.sh"

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

# Hermetic repo with one run on disk (written through the NEW module).
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
export CLAUDE_AUTO_REPO="$REPO"
mkdir -p "$REPO/.claude/auto"
"$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF'
import importlib.util, os, sys
auto_root, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
s = importlib.util.spec_from_file_location(
    "run_record", os.path.join(auto_root, "lib", "run_record.py"))
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.init_run_record(repo, "rS", backend="ce",
                  steps=[{"id": "w-1", "phase": "work",
                          "invokes": {"backend_op": "do_step"}}],
                  loop_phase="work")
PYEOF

# ── 1. The cmux-socket load shape: by-path import + OLD symbol access ────────
# Loaded EXACTLY the way cmux-socket.sh used to (module name "ledger", by file
# path) — but WITHOUT the `except: sys.exit(0)` wrapper, so a missing symbol is a
# loud AttributeError here instead of the silent empty-string it is in production.
it "lib/ledger.py loads by path (spec_from_file_location) and still exposes ledger_path/lock_path"
sym_out="$("$PY" - "$LEDGER_PY_STUB" "$REPO" 2>/dev/null <<'PYEOF'
import importlib.util, sys
stub, repo = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ledger", stub)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
print(L.ledger_path(repo, "rS"))
print(L.lock_path(repo, "rS"))
PYEOF
)" || true
if printf '%s' "$sym_out" | grep -q "/.claude/auto/rS.json" \
   && printf '%s' "$sym_out" | grep -q "/.claude/auto/rS.lock"; then
  pass
else
  fail "by-path load did NOT resolve ledger_path/lock_path — the cmux-socket guards would fail OPEN. got: ${sym_out:-<empty>}"
fi

it "the stub re-exports the retired read/init/RMW surface (read_ledger, init_ledger, _with_locked_ledger)"
surf_out="$("$PY" - "$LEDGER_PY_STUB" "$REPO" 2>/dev/null <<'PYEOF'
import importlib.util, sys
stub, repo = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ledger", stub)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
rec = L.read_ledger(repo, "rS")
missing = [n for n in ("read_ledger", "init_ledger", "_with_locked_ledger",
                       "ledger_path", "LedgerError", "LedgerNotFound", "LedgerExists")
           if not hasattr(L, n)]
print("missing=" + (",".join(missing) or "none"))
print("steps=" + str(len(rec["steps"])))
PYEOF
)" || true
if printf '%s' "$surf_out" | grep -q "missing=none" \
   && printf '%s' "$surf_out" | grep -q "steps=1"; then
  pass
else
  fail "the re-export surface is incomplete: ${surf_out:-<empty>}"
fi

# ── 2. Class identity across the shim ───────────────────────────────────────
# The stub must REBIND run_record's classes, never redefine them. If it declared its
# own `class LedgerError(Exception)`, `except ledger.LedgerError` would sail past a
# raise from run_record_core — the exact duplicate-class-identity bug the DAG lint
# in tests/unit/import-topology.test.sh exists to prevent.
it "except ledger.LedgerError CATCHES a raise from the run_record family (same class objects)"
cls_out="$("$PY" - "$LEDGER_PY_STUB" "${AUTO_ROOT}/lib/run_record.py" "$REPO" 2>/dev/null <<'PYEOF'
import importlib.util, sys
stub, real, repo = sys.argv[1], sys.argv[2], sys.argv[3]
def load(name, path):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
L = load("ledger", stub)
R = load("run_record", real)
print("identity=" + str(L.LedgerError is R.RunRecordError
                        and L.LedgerNotFound is R.RunRecordNotFound
                        and L.LedgerExists is R.RunRecordExists))
# and it must actually CATCH: reading an absent run raises from run_record_core.
try:
    L.read_ledger(repo, "no-such-run")
except L.LedgerError:
    print("caught=True")
except Exception as e:
    print("caught=False (" + type(e).__name__ + ")")
PYEOF
)" || true
if printf '%s' "$cls_out" | grep -q "identity=True" \
   && printf '%s' "$cls_out" | grep -q "caught=True"; then
  pass
else
  fail "the stub's error classes are NOT run_record's: ${cls_out:-<empty>}"
fi

# ── 3. Legacy CLI through the stub — works, and stdout is BYTE-CLEAN ─────────
# `python3 lib/ledger.py read <repo> <run> | jq` is the memorized pipeline. If the
# deprecation notice leaked to stdout, jq would choke on it.
it "legacy 'python3 lib/ledger.py read <repo> <run>' still works via the stub"
legacy_out="$("$PY" "$LEDGER_PY_STUB" read "$REPO" rS 2>/dev/null)" || true
if printf '%s' "$legacy_out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["steps"][0]["id"])' 2>/dev/null \
   | grep -qx "w-1"; then
  pass
else
  fail "legacy read through the stub did not emit parseable run-record JSON"
fi

it "the stub's deprecation notice goes to stderr ONLY (stdout stays pipeable)"
so="$("$PY" "$LEDGER_PY_STUB" path "$REPO" rS 2>/dev/null)"
se="$("$PY" "$LEDGER_PY_STUB" path "$REPO" rS 2>&1 >/dev/null)"
if [ "$so" = "${REPO}/.claude/auto/rS.json" ] \
   && printf '%s' "$so" | grep -qv "deprecated" \
   && printf '%s' "$se" | grep -q "deprecated"; then
  pass
else
  fail "stdout/stderr split is wrong — stdout='${so}' stderr='${se}'"
fi

# ── 4. lib/ledger.sh forwards to lib/run_record.sh ───────────────────────────
it "lib/ledger.sh forwards to lib/run_record.sh (byte-clean stdout, notice on stderr)"
sh_so="$(bash "$LEDGER_SH_STUB" path "$REPO" rS 2>/dev/null)"
sh_se="$(bash "$LEDGER_SH_STUB" path "$REPO" rS 2>&1 >/dev/null)"
if [ "$sh_so" = "${REPO}/.claude/auto/rS.json" ] && printf '%s' "$sh_se" | grep -q "deprecated"; then
  pass
else
  fail "lib/ledger.sh did not forward cleanly — stdout='${sh_so}' stderr='${sh_se}'"
fi

# ── 5. cmux-socket's guards resolve a REAL path post-rename (F6) ─────────────
# THE POINT: both guard paths in cmux-socket.sh compute a path by loading the
# run-record module BY PATH and calling a symbol on it, inside `except: sys.exit(0)`.
# A botched rename makes them return EMPTY — and empty means "un-spawnable" /
# "lock free", i.e. the runaway-spawn sentinel and the double-drive guard BOTH fail
# open, spawning competing drivers. Drive the real functions and assert they produce
# real paths.
it "cmux-socket's pulse-lock path resolves post-rename (guard does not silently fail open)"
# shellcheck disable=SC1091
. "${AUTO_ROOT}/lib/cmux-socket.sh"
lock_out="$(auto::pulse_lock_path "$REPO" rS)" || true
if [ "$lock_out" = "${REPO}/.claude/auto/rS.pulse.lock" ]; then
  pass
else
  fail "auto::pulse_lock_path returned '${lock_out:-<empty>}' — an empty path means the double-drive guard fails OPEN"
fi

it "cmux-socket's spawn-attempt sentinel name resolves post-rename (runaway guard holds)"
# Re-run the exact inline python from auto::spawn_resume's sentinel computation.
sentinel="$("$PY" - "$REPO" rS "${AUTO_ROOT}/lib/run_record.py" 2>/dev/null <<'PYEOF'
import importlib.util, os, sys
repo, run, run_record_py = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("run_record", run_record_py)
L = importlib.util.module_from_spec(spec); spec.loader.exec_module(L)
try:
    print(os.path.basename(L.run_record_path(repo, run))[: -len(".json")] + ".spawn.attempt")
except Exception:
    sys.exit(0)
PYEOF
)" || true
if [ "$sentinel" = "rS.spawn.attempt" ]; then
  pass
else
  fail "the spawn sentinel name computed to '${sentinel:-<empty>}' — an empty sentinel means the runaway-spawn guard fails OPEN"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "run-record-stub.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
