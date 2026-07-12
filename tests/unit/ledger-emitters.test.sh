#!/usr/bin/env bash
# auto U3 unit test: lib/ledger.py persistence, transitions,
# concurrency, and the three hard invariants (I-1 / I-2 / I-3).
#
# SELF-CONTAINED: this test defines its own minimal it/pass/fail/assert helpers
# and HOME isolation inline. It does NOT source claude-modes' test-helpers
# (cross-plugin coupling forbidden) nor auto's own shared helpers
# (those are tests/helpers/test-helpers.sh, owned by U2 — not yet present).
# When U2 lands shared helpers, this file may migrate to them.
#
# Scenarios (mapped to the U3 plan):
#   1. round-trip write/read; transition dispatched -> verdict-returned
#   2. empty / unknown run-id -> clean error, no partial file
#   3. write-interruption -> atomic rename holds (no half file)
#   4. concurrent writers serialize via flock; NO_LOCK deliberate-fail hatch
#      proves the test goes RED without locking
#   5. I-1: met==true ledger + new blocker -> same snapshot has met==false;
#      NO_RECOMPUTE hatch proves the I-1 test goes RED without recompute
#   6. I-2: 3 units, U_b/U_c depend on U_a, U_a stalled, U_b/U_c never
#      dispatched -> met==false (all_units_terminal false)
#   7. I-2 closure: unit `fixed` with a stale blocker -> all_units_terminal==false
#   8. I-3: liveness/orphan predicate (manual / stale-beat / healthy-slow)
#   9. state grammar: every documented transition holds; undocumented rejected
#  10. fence: no production file enables a TEST_NO_* hatch

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LEDGER_PY="${AUTO_ROOT}/lib/ledger.py"
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
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in
    */auto-test.*) rm -rf "$SANDBOX" ;;
  esac
}
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "$REPO"

# ── tiny python helpers run against the module ─────────────────────────────
# init <run> <json-units>  — create a ledger with given units list
ledger_init() {
  local run="$1" units_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$units_json" "$backend" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, units_json, backend, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, backend=backend, units=json.loads(units_json), loop_phase=phase)
PYEOF
}

# field <run> <python-expr-on-ledger-named-L>  — print a value from the ledger
ledger_field() {
  local run="$1" expr="$2"
  "$PY" - "$REPO" "$run" "$expr" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, expr, ledger_py = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
L = m.read_ledger(repo, run)
print(eval(expr))
PYEOF
}

# init_scale <run> <json-units> <adapter_scale> [phase]  — like ledger_init but
# threads adapter_scale (the ledger_init helper above is fixed at the default
# "three-tier"; the Bug #3 scale-aware scenarios need "blocker-only" too).
ledger_init_scale() {
  local run="$1" units_json="$2" scale="$3" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$units_json" "$scale" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, units_json, scale, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
backend = "native" if scale == "blocker-only" else "ce"
m.init_ledger(repo, run, backend=backend, backend_scale=scale,
              units=json.loads(units_json), loop_phase=phase)
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "ledger-emitters.test.sh"


# ════════════════════════════════════════════════════════════════════════════
# v0.3.0 U2 — iteration mutators + iteration_pending predicate composition.
#
# Six new write paths support outcomes-gated emission (KTD §A-D / plan U2):
#   set_verdict_decision     — writes dispatch_context.decision (the gate
#                              unit's verdict-side decision enum; sibling to
#                              set_winner_unit_id)
#   set_bound_override       — engine-only audit trail for iterate→exit
#   accumulate_active_time   — atomic add-write of the wall-time bound
#                              accumulator
#   increment_iteration_attempts — atomic ++ of the attempts bound counter
#   reset_for_iteration      — atomic gate-unit cycle-back combo
#   emit_within_phase        — sibling to transition_and_emit, no loop_phase
#                              write, bumps iteration_emit_count
#   atomic_iterate_step      — composite of increment + emit + reset in ONE
#                              locked body (round-3 P1-R3-1 / KTD §C+D)
#
# Plus four new top-level ledger fields:
#   active_wall_seconds      — accumulator
#   last_active_at           — diagnostic ISO timestamp
#   iteration_attempts       — KTD §D bound counter
#   iteration_emit_count     — KTD §D / OQ4 monotonic emit-id counter
#
# Predicate composition (KTD §B):
#   recompute_predicate adds `iteration_pending: bool` and ANDs `met` against
#   `NOT iteration_pending`.

# A tiny Python driver that loads ledger.py and applies a sequence of writes
# against a fresh ledger seeded with an iteration block + gate unit. Each
# scenario writes JSON to stdout and the bash assertions check exact strings.
iter_driver() {
  "$PY" - "$REPO" "$LEDGER_PY" "$@" <<'PYEOF'
import json, sys, importlib.util, os
repo, ledger_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
op = sys.argv[3]


def fresh(run, *, iteration=True, gate_state="verdict-returned",
          attempts=0, active_wall=0, max_attempts=5, max_wall=None,
          extra_units=None):
    """Create a fresh ledger with an optional iteration block and a 'judge'
    gate unit. Returns the ledger dict (already on disk via init_ledger then
    a _with_locked_ledger touch to install the iteration block + gate state).
    """
    p = m.ledger_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    units = [{"id": "judge", "state": "pending", "phase": "work"}]
    if extra_units:
        units.extend(extra_units)
    m.init_ledger(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan", "seam", "work"], terminal_phase="work",
                  units=units)
    # Use _with_locked_ledger to seed iteration block + bump gate to the
    # desired state (the public init API doesn't accept iteration yet — that
    # ships in U5/recipes).
    def seed(L):
        if iteration:
            bound = {"max_attempts": max_attempts}
            if max_wall is not None:
                bound["max_wall_seconds"] = max_wall
            L["iteration"] = {"gate_unit": "judge", "bound": bound}
        L["iteration_attempts"] = attempts
        L["active_wall_seconds"] = active_wall
        # Walk the gate unit to the requested state via grammar-valid edges.
        u = L["units"][0]
        if gate_state == "verdict-returned":
            u["state"] = "dispatched"  # then record_verdict will edge it.
    m._with_locked_ledger(repo, run, seed)
    if gate_state == "verdict-returned":
        # Use record_verdict to legitimately reach verdict-returned (the
        # mutator path the production engine uses).
        m.record_verdict(repo, run, "judge", [])
    elif gate_state == "dispatched":
        m.transition(repo, run, "judge", "dispatched")
    elif gate_state == "pending":
        pass  # init seeded as pending
    return m.read_ledger(repo, run)


# ─── op: emit_within_phase-emit ────────────────────────────────────────────
if op == "emit_within_phase-emit":
    # The producer returns 2 partial units; emit_within_phase appends them
    # WITHOUT advancing loop_phase, and bumps iteration_emit_count per unit.
    led = fresh("u2-ewp-emit",
                extra_units=[{"id": "plan-1", "state": "verdict-returned",
                              "phase": "plan"}])
    def emit(L, to_phase):
        return [
            {"id": "plan-2", "state": "pending", "phase": to_phase},
            {"id": "plan-3", "state": "pending", "phase": to_phase},
        ]
    appended = m.emit_within_phase(repo, "u2-ewp-emit", "plan", emit)
    after = m.read_ledger(repo, "u2-ewp-emit")
    ids = sorted(u["id"] for u in after["units"])
    print(json.dumps({
        "appended": appended,
        "all_ids": ids,
        "loop_phase": after["loop_phase"],
        "iteration_emit_count": after.get("iteration_emit_count"),
    }))

# ─── op: emit_within_phase-collision ───────────────────────────────────────
elif op == "emit_within_phase-collision":
    led = fresh("u2-ewp-coll")
    def bad(L, to_phase):
        # Collides with the existing 'judge' unit.
        return [{"id": "judge", "state": "pending", "phase": to_phase}]
    try:
        m.emit_within_phase(repo, "u2-ewp-coll", "work", bad)
        print("ACCEPTED-COLLISION")
    except m.LedgerError:
        print("rejected")

# ─── op: atomic_iterate_step-happy ─────────────────────────────────────────
elif op == "atomic_iterate_step-happy":
    # The full composite: increment + emit + reset all land in ONE write.
    led = fresh("u2-ais-happy",
                extra_units=[{"id": "plan-1", "state": "verdict-returned",
                              "phase": "plan"}])
    m.record_verdict(repo, "u2-ais-happy", "judge", [])
    m.set_verdict_decision(repo, "u2-ais-happy", "judge", "iterate")
    def emit2(L, to_phase):
        return [
            {"id": "plan-2", "state": "pending", "phase": "plan"},
            {"id": "plan-3", "state": "pending", "phase": "plan"},
        ]
    # Gate phase = "work" (KTD: emission stays in gate's phase). Force phase
    # = "plan" by walking depends_on to the new plan units (the production
    # path; the gate is the judge, plan-1/2/3 are its deps).
    appended = m.atomic_iterate_step(
        repo, "u2-ais-happy", "judge", emit2, ["plan-1", "plan-2", "plan-3"],
    )
    after = m.read_ledger(repo, "u2-ais-happy")
    judge = next(u for u in after["units"] if u["id"] == "judge")
    print(json.dumps({
        "appended": appended,
        "iteration_attempts": after["iteration_attempts"],
        "iteration_emit_count": after["iteration_emit_count"],
        "gate_state": judge["state"],
        "gate_depends_on": judge["depends_on"],
        "decision_cleared": "decision" not in (judge.get("dispatch_context") or {}),
        "unit_count": len(after["units"]),
    }))

# ─── op: atomic_iterate_step-bad-producer-keeps-counter ─────────────────────
elif op == "atomic_iterate_step-bad-producer-keeps-counter":
    # A producer that returns a colliding id MUST roll back the entire
    # composite — iteration_attempts stays 0 after the failed call (the
    # all-or-nothing contract / deliberate-fail #8 control's GREEN side).
    led = fresh("u2-ais-bad")
    attempts_before = led.get("iteration_attempts", 0)
    def bad(L, to_phase):
        return [{"id": "judge", "state": "pending"}]  # collides with gate
    raised = "NO"
    try:
        m.atomic_iterate_step(repo, "u2-ais-bad", "judge", bad, [])
    except m.LedgerError:
        raised = "yes"
    after = m.read_ledger(repo, "u2-ais-bad")
    print(json.dumps({
        "raised": raised,
        "iteration_attempts": after["iteration_attempts"],
        "iteration_emit_count": after.get("iteration_emit_count"),
        "unit_count": len(after["units"]),
    }))


else:
    sys.stderr.write(f"unknown op {op!r}\n")
    sys.exit(2)
PYEOF
}

echo ""
echo "── v0.3.0 U2: iteration producers (emit path) ──"

# ─── U2.9: emit_within_phase appends + bumps counter, no loop_phase write ───
it "U2: emit_within_phase appends 2 units, leaves loop_phase, bumps emit_count"
assert_eq \
  '{"appended": ["plan-2", "plan-3"], "all_ids": ["judge", "plan-1", "plan-2", "plan-3"], "loop_phase": "work", "iteration_emit_count": 2}' \
  "$(iter_driver emit_within_phase-emit)"

# ─── U2.10: emit_within_phase collision check ───────────────────────────────
it "U2: emit_within_phase rejects a unit id that collides with an existing one"
assert_eq "rejected" "$(iter_driver emit_within_phase-collision)"

# ─── U2.15: atomic_iterate_step happy path — full composite ─────────────────
it "U2: atomic_iterate_step lands increment+emit+reset in ONE atomic write"
assert_eq \
  '{"appended": ["plan-2", "plan-3"], "iteration_attempts": 1, "iteration_emit_count": 2, "gate_state": "pending", "gate_depends_on": ["plan-1", "plan-2", "plan-3"], "decision_cleared": true, "unit_count": 4}' \
  "$(iter_driver atomic_iterate_step-happy)"

# ─── U2.16: atomic_iterate_step is all-or-nothing on failure ────────────────
it "U2: atomic_iterate_step with a bad producer keeps iteration_attempts at 0 (all-or-nothing)"
assert_eq \
  '{"raised": "yes", "iteration_attempts": 0, "iteration_emit_count": 0, "unit_count": 1}' \
  "$(iter_driver atomic_iterate_step-bad-producer-keeps-counter)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "ledger-emitters.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
