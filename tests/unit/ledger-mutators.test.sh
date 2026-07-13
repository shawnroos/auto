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
#   6. I-2: 3 steps, U_b/U_c depend on U_a, U_a stalled, U_b/U_c never
#      dispatched -> met==false (all_steps_terminal false)
#   7. I-2 closure: step `fixed` with a stale blocker -> all_steps_terminal==false
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
# init <run> <json-steps>  — create a ledger with given steps list
ledger_init() {
  local run="$1" steps_json="$2" backend="${3:-ce}" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$backend" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, backend, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.init_ledger(repo, run, backend=backend, steps=json.loads(steps_json), loop_phase=phase)
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

# init_scale <run> <json-steps> <backend_scale> [phase]  — like ledger_init but
# threads backend_scale (the ledger_init helper above is fixed at the default
# "three-tier"; the Bug #3 scale-aware scenarios need "blocker-only" too).
ledger_init_scale() {
  local run="$1" steps_json="$2" scale="$3" phase="${4:-work}"
  "$PY" - "$REPO" "$run" "$steps_json" "$scale" "$phase" "$LEDGER_PY" <<'PYEOF'
import json, sys, importlib.util
repo, run, steps_json, scale, phase, ledger_py = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
backend = "native" if scale == "blocker-only" else "ce"
m.init_ledger(repo, run, backend=backend, backend_scale=scale,
              steps=json.loads(steps_json), loop_phase=phase)
PYEOF
}

# ════════════════════════════════════════════════════════════════════════════
echo "ledger-mutators.test.sh"


# ════════════════════════════════════════════════════════════════════════════
# v0.3.0 U2 — iteration mutators + iteration_pending predicate composition.
#
# Six new write paths support outcomes-gated emission (KTD §A-D / plan U2):
#   set_verdict_decision     — writes dispatch_context.decision (the gate
#                              step's verdict-side decision enum; sibling to
#                              set_winner_step_id)
#   set_bound_override       — engine-only audit trail for iterate→exit
#   accumulate_active_time   — atomic add-write of the wall-time bound
#                              accumulator
#   increment_iteration_attempts — atomic ++ of the attempts bound counter
#   reset_for_iteration      — atomic gate-step cycle-back combo
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
# against a fresh ledger seeded with an iteration block + gate step. Each
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
          extra_steps=None):
    """Create a fresh ledger with an optional iteration block and a 'judge'
    gate step. Returns the ledger dict (already on disk via init_ledger then
    a _with_locked_ledger touch to install the iteration block + gate state).
    """
    p = m.ledger_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    steps = [{"id": "judge", "state": "pending", "phase": "work"}]
    if extra_steps:
        steps.extend(extra_steps)
    m.init_ledger(repo, run, backend="ce", loop_phase="work",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=steps)
    # Use _with_locked_ledger to seed iteration block + bump gate to the
    # desired state (the public init API doesn't accept iteration yet — that
    # ships in U5/recipes).
    def seed(L):
        if iteration:
            bound = {"max_attempts": max_attempts}
            if max_wall is not None:
                bound["max_wall_seconds"] = max_wall
            L["iteration"] = {"gate_step": "judge", "bound": bound}
        L["iteration_attempts"] = attempts
        L["active_wall_seconds"] = active_wall
        # Walk the gate step to the requested state via grammar-valid edges.
        u = L["steps"][0]
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


# ─── op: top-level-fields-init ─────────────────────────────────────────────
if op == "top-level-fields-init":
    # New init_ledger creates a ledger with the four new top-level fields
    # at their additive defaults.
    led = fresh("u2-init")
    print(json.dumps({
        "active_wall_seconds": led.get("active_wall_seconds"),
        "last_active_at": led.get("last_active_at"),
        "iteration_attempts": led.get("iteration_attempts"),
        "iteration_emit_count": led.get("iteration_emit_count"),
    }))

# ─── op: backward-compat-defaults ──────────────────────────────────────────
elif op == "backward-compat-defaults":
    # A hand-written v0.2.x-shaped ledger (no new iteration fields) must
    # read via .get() defaults — no migration. Reads of the four new fields
    # via .get(<field>, <default>) return the documented defaults.
    import tempfile
    sandbox = tempfile.mkdtemp()
    run = "v02x"
    legacy = {
        "run_id": run, "loop_phase": "work", "plan_step": None,
        "handoff_paused": False, "backend": "ce", "backend_scale": "three-tier",
        "exit_predicate_result": {}, "loop": {"driver": "self", "last_beat_at": "x"},
        "steps": [{"id": "U1", "state": "verdict-returned", "depends_on": [],
                   "dispatched_at": None, "verdict_at": None,
                   "stall_threshold_seconds": 600, "last_error": None,
                   "attempt": 0, "findings": []}],
    }
    path = m.ledger_path(sandbox, run)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w") as f:
        json.dump(legacy, f)
    L = m.read_ledger(sandbox, run)
    print(json.dumps({
        "active_wall_seconds": L.get("active_wall_seconds", 0),
        "last_active_at": L.get("last_active_at", None),
        "iteration_attempts": L.get("iteration_attempts", 0),
        "iteration_emit_count": L.get("iteration_emit_count", 0),
    }))

# ─── op: set_verdict_decision-happy ────────────────────────────────────────
elif op == "set_verdict_decision-happy":
    led = fresh("u2-svd-happy")
    m.set_verdict_decision(repo, "u2-svd-happy", "judge", "iterate",
                            payload={"emit_count": 2})
    after = m.read_ledger(repo, "u2-svd-happy")
    judge = after["steps"][0]
    print(json.dumps({
        "decision": judge["dispatch_context"].get("decision"),
        "payload": judge["dispatch_context"].get("decision_payload"),
        "iteration_pending": after["exit_predicate_result"].get("iteration_pending"),
        "met": after["exit_predicate_result"].get("met"),
    }))

# ─── op: set_verdict_decision-rejects-garbage ──────────────────────────────
elif op == "set_verdict_decision-rejects-garbage":
    led = fresh("u2-svd-garbage")
    try:
        m.set_verdict_decision(repo, "u2-svd-garbage", "judge", "garbage")
        print("ACCEPTED")
    except m.LedgerError:
        print("rejected")

# ─── op: set_verdict_decision-unknown-step ─────────────────────────────────
elif op == "set_verdict_decision-unknown-step":
    led = fresh("u2-svd-noghost")
    try:
        m.set_verdict_decision(repo, "u2-svd-noghost", "ghost", "iterate")
        print("ACCEPTED")
    except m.UnknownStep:
        print("rejected-unknown")
    except m.LedgerError:
        print("rejected-ledger")

# ─── op: set_bound_override-happy ──────────────────────────────────────────
elif op == "set_bound_override-happy":
    led = fresh("u2-sbo-happy")
    m.set_bound_override(repo, "u2-sbo-happy", "judge", "max_attempts", "iterate")
    after = m.read_ledger(repo, "u2-sbo-happy")
    bo = after["steps"][0]["dispatch_context"].get("bound_override") or {}
    print(json.dumps({
        "bound": bo.get("bound"),
        "original_decision": bo.get("original_decision"),
        "has_at": bool(bo.get("at")),  # timestamp present (deliberate-fail #5 target)
    }))

# ─── op: accumulate_active_time-two-calls ──────────────────────────────────
elif op == "accumulate_active_time-two-calls":
    # Two calls (5.0 + 7.5) sum to 12.5 — proves the contract is ADD, not
    # OVERWRITE. This is the deliberate-fail #1 control's GREEN side.
    led = fresh("u2-aat-two")
    m.accumulate_active_time(repo, "u2-aat-two", 5.0)
    m.accumulate_active_time(repo, "u2-aat-two", 7.5)
    after = m.read_ledger(repo, "u2-aat-two")
    print(json.dumps({
        "active_wall_seconds": after.get("active_wall_seconds"),
        "has_last_active_at": bool(after.get("last_active_at")),
    }))

# ─── op: increment_iteration_attempts-two ──────────────────────────────────
elif op == "increment_iteration_attempts-two":
    # Two calls bring count to 2 (started at 0). Deliberate-fail #6's GREEN.
    led = fresh("u2-iia-two")
    m.increment_iteration_attempts(repo, "u2-iia-two", "judge")
    m.increment_iteration_attempts(repo, "u2-iia-two", "judge")
    after = m.read_ledger(repo, "u2-iia-two")
    print(str(after.get("iteration_attempts")))

# ─── op: reset_for_iteration-happy ─────────────────────────────────────────
elif op == "reset_for_iteration-happy":
    # Gate is verdict-returned with a stale decision="iterate" + findings.
    # reset_for_iteration must flip state, replace depends_on, clear decision,
    # decision_payload, verdict_at, findings — all in one atomic write.
    led = fresh("u2-r4i-happy")
    # Add a finding + payload + decision via the production write paths.
    m.record_verdict(repo, "u2-r4i-happy", "judge",
                     [{"severity": "minor", "note": "from-prior"}])
    m.set_verdict_decision(repo, "u2-r4i-happy", "judge", "iterate",
                            payload={"emit_count": 2})
    m.reset_for_iteration(repo, "u2-r4i-happy", "judge",
                          ["plan-1", "plan-2", "plan-3"])
    after = m.read_ledger(repo, "u2-r4i-happy")
    judge = after["steps"][0]
    dc = judge.get("dispatch_context") or {}
    print(json.dumps({
        "state": judge["state"],
        "depends_on": judge["depends_on"],
        "findings_len": len(judge["findings"]),
        "verdict_at": judge["verdict_at"],
        "decision_cleared": "decision" not in dc,
        "decision_payload_cleared": "decision_payload" not in dc,
    }))

# ─── op: reset_for_iteration-bad-state ─────────────────────────────────────
elif op == "reset_for_iteration-bad-state":
    # Gate is still 'dispatched' (not 'verdict-returned'). The grammar
    # check must raise InvalidTransition.
    led = fresh("u2-r4i-bad", gate_state="dispatched")
    try:
        m.reset_for_iteration(repo, "u2-r4i-bad", "judge", [])
        print("ACCEPTED")
    except m.InvalidTransition:
        print("rejected-invalid-transition")

# ─── op: predicate-composition ─────────────────────────────────────────────
elif op == "predicate-composition":
    # Full predicate composition (KTD §B):
    #   Step A: gate verdict-returned + clean + decision="iterate" + attempts<max
    #     → iteration_pending=true, met=false (suppressed)
    #   Step B: bump iteration_attempts to max → iteration_pending=false,
    #     met=true (the work-loop's clean terminal predicate fires)
    led = fresh("u2-pred", max_attempts=2)
    m.record_verdict(repo, "u2-pred", "judge", [])  # clean verdict
    m.set_verdict_decision(repo, "u2-pred", "judge", "iterate")
    after_a = m.read_ledger(repo, "u2-pred")
    pa = after_a["exit_predicate_result"]
    # Bump iteration_attempts to bound max via two increments.
    m.increment_iteration_attempts(repo, "u2-pred", "judge")
    m.increment_iteration_attempts(repo, "u2-pred", "judge")
    after_b = m.read_ledger(repo, "u2-pred")
    pb = after_b["exit_predicate_result"]
    print(json.dumps({
        "a_iteration_pending": pa.get("iteration_pending"),
        "a_met": pa.get("met"),
        "b_iteration_pending": pb.get("iteration_pending"),
        "b_met": pb.get("met"),
    }))

# ─── op: legacy-predicate-no-iteration-key ─────────────────────────────────
elif op == "legacy-predicate-no-iteration-key":
    # A ledger with NO iteration block returns iteration_pending=False, and
    # the existing met logic is unchanged.
    led = fresh("u2-noiter", iteration=False)
    m.record_verdict(repo, "u2-noiter", "judge", [])  # clean → met=True
    after = m.read_ledger(repo, "u2-noiter")
    pr = after["exit_predicate_result"]
    print(json.dumps({
        "iteration_pending": pr.get("iteration_pending"),
        "met": pr.get("met"),
    }))

elif op == "predicate-survives-corrupt-iteration-attempts":
    # F3 / rel-2: _compute_iteration_pending is called from _atomic_write on
    # EVERY write. A corrupt numeric ledger field (here: iteration_attempts
    # forced to a non-numeric string by direct disk patch) MUST NOT raise
    # from recompute — that would lock out every subsequent write, including
    # the ones needed to overwrite the corruption itself.
    led = fresh("u3-corrupt-attempts", max_attempts=5)
    m.record_verdict(repo, "u3-corrupt-attempts", "judge", [])
    m.set_verdict_decision(repo, "u3-corrupt-attempts", "judge", "iterate")
    # Corrupt the on-disk ledger directly. The next _with_locked_ledger write
    # will hit _atomic_write -> recompute_predicate -> _compute_iteration_pending
    # which must degrade gracefully on the bad input.
    p = m.ledger_path(repo, "u3-corrupt-attempts")
    raw = json.load(open(p))
    raw["iteration_attempts"] = "garbage-not-a-number"
    open(p, "w").write(json.dumps(raw))
    # Now drive ANY write. If recompute raises, this call propagates the raise
    # and the ledger is unrecoverable. The brittleness fix makes it succeed.
    raised = "no"
    try:
        m.accumulate_active_time(repo, "u3-corrupt-attempts", 1.0)
    except Exception as e:
        raised = f"raised:{type(e).__name__}"
    after = m.read_ledger(repo, "u3-corrupt-attempts")
    print(json.dumps({
        "raised": raised,
        "iteration_pending": after["exit_predicate_result"].get("iteration_pending"),
        "active_wall_seconds_written": after.get("active_wall_seconds"),
    }))

else:
    sys.stderr.write(f"unknown op {op!r}\n")
    sys.exit(2)
PYEOF
}

echo ""
echo "── v0.3.0 U2: iteration mutators (mutator path) ──"

# ─── U2.1: init defaults ────────────────────────────────────────────────────
it "U2: init_ledger seeds the four new top-level fields at their defaults"
assert_eq \
  '{"active_wall_seconds": 0, "last_active_at": null, "iteration_attempts": 0, "iteration_emit_count": 0}' \
  "$(iter_driver top-level-fields-init)"

# ─── U2.2: backward compat ──────────────────────────────────────────────────
it "U2: legacy v0.2.x ledger (no new keys) reads new fields via .get() defaults"
assert_eq \
  '{"active_wall_seconds": 0, "last_active_at": null, "iteration_attempts": 0, "iteration_emit_count": 0}' \
  "$(iter_driver backward-compat-defaults)"

# ─── U2.3: set_verdict_decision happy + payload ─────────────────────────────
it "U2: set_verdict_decision writes dispatch_context.decision + payload; iteration_pending fires"
assert_eq \
  '{"decision": "iterate", "payload": {"emit_count": 2}, "iteration_pending": true, "met": false}' \
  "$(iter_driver set_verdict_decision-happy)"

# ─── U2.4: set_verdict_decision rejects garbage ─────────────────────────────
it "U2: set_verdict_decision rejects a decision not in iteration.DECISIONS"
assert_eq "rejected" "$(iter_driver set_verdict_decision-rejects-garbage)"

# ─── U2.5: set_verdict_decision rejects unknown step ────────────────────────
it "U2: set_verdict_decision rejects an unknown gate_step_id"
result="$(iter_driver set_verdict_decision-unknown-step)"
case "$result" in
  rejected-*) pass ;;
  *) fail "expected a rejection, got '$result'" ;;
esac

# ─── U2.6: set_bound_override writes the audit payload + timestamp ──────────
it "U2: set_bound_override writes {bound, original_decision, at} on dispatch_context"
assert_eq \
  '{"bound": "max_attempts", "original_decision": "iterate", "has_at": true}' \
  "$(iter_driver set_bound_override-happy)"

# ─── U2.7: accumulate_active_time is ADD, not OVERWRITE ─────────────────────
it "U2: accumulate_active_time(5.0) then (7.5) sums to 12.5 (add, not overwrite)"
assert_eq \
  '{"active_wall_seconds": 12.5, "has_last_active_at": true}' \
  "$(iter_driver accumulate_active_time-two-calls)"

# ─── U2.8: increment_iteration_attempts increments ──────────────────────────
it "U2: increment_iteration_attempts called twice → iteration_attempts == 2"
assert_eq "2" "$(iter_driver increment_iteration_attempts-two)"

# ─── U2.11: reset_for_iteration full combo ──────────────────────────────────
it "U2: reset_for_iteration cycles gate to pending + clears decision/findings/verdict_at/payload"
assert_eq \
  '{"state": "pending", "depends_on": ["plan-1", "plan-2", "plan-3"], "findings_len": 0, "verdict_at": null, "decision_cleared": true, "decision_payload_cleared": true}' \
  "$(iter_driver reset_for_iteration-happy)"

# ─── U2.12: reset_for_iteration rejects bad source state ────────────────────
it "U2: reset_for_iteration on a non-verdict-returned step raises InvalidTransition"
assert_eq "rejected-invalid-transition" "$(iter_driver reset_for_iteration-bad-state)"

# ─── U2.13: predicate composition — iteration_pending suppresses met ────────
it "U2: predicate composition — iteration_pending=true suppresses met; bound breach lifts it"
assert_eq \
  '{"a_iteration_pending": true, "a_met": false, "b_iteration_pending": false, "b_met": true}' \
  "$(iter_driver predicate-composition)"

# ─── U2.14: legacy ledger (no iteration block) — iteration_pending=false ────
it "U2: a ledger with no iteration block → iteration_pending=false, met unaffected"
assert_eq \
  '{"iteration_pending": false, "met": true}' \
  "$(iter_driver legacy-predicate-no-iteration-key)"

# ─── F3 / rel-2: predicate recompute survives corrupt iteration_attempts ────
# A corrupt numeric ledger field MUST NOT lock out every subsequent write at
# the _atomic_write chokepoint. The recompute degrades gracefully: the bad
# input collapses iteration_pending to false, and the write completes so the
# next caller can overwrite the corruption.
it "F3: corrupt iteration_attempts on disk → _atomic_write still completes (no raise)"
assert_eq \
  '{"raised": "no", "iteration_pending": false, "active_wall_seconds_written": 1.0}' \
  "$(iter_driver predicate-survives-corrupt-iteration-attempts)"

# ════════════════════════════════════════════════════════════════════════════
# U14 P2 anti-livelock — set_enumerated_steps sanitizes model-emitted depends_on.
#
# A dangling id, a self-edge, or a cycle in the model's per-item depends_on
# would leave the materialized work step permanently un-_is_ready → a SILENT
# full-run livelock (never ready, never dispatched, dispatch-timeout never
# fires, all_steps_terminal false forever). set_enumerated_steps is the single
# chokepoint where runtime model output enters the ledger; it DROPS invalid
# edges (recording dispatch_context.dropped_depends_on_edges) rather than
# raising (a raise would materialize zero work steps — also a stall). Valid
# edges, including forward-refs to sibling enumerated steps, are preserved.
#
# These assert the CLEANED edges + marker; dispatcher.test.sh asserts the
# sanitized shape actually becomes ready (the real anti-hang claim).
enum_driver() {
  "$PY" - "$REPO" "$LEDGER_PY" "$@" <<'PYEOF'
import json, sys, importlib.util, os
repo, ledger_py = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("ledger", ledger_py)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
op = sys.argv[3]


def setup(run):
    p = m.ledger_path(repo, run)
    if os.path.exists(p):
        os.unlink(p)
    m.init_ledger(repo, run, backend="ce", loop_phase="plan",
                  phase_order=["plan", "handoff", "work"], terminal_phase="work",
                  steps=[{"id": "plan", "state": "pending", "phase": "plan"}])


def report(run, enumerated):
    setup(run)
    m.set_enumerated_steps(repo, run, "plan", enumerated)
    L = m.read_ledger(repo, run)
    plan = next(u for u in L["steps"] if u["id"] == "plan")
    dc = plan["dispatch_context"]
    deps = {it["id"]: it.get("depends_on", []) for it in dc["enumerated_steps"]}
    dropped = [[x["step"], x["dep"], x["reason"]]
               for x in dc.get("dropped_depends_on_edges", [])]
    print(json.dumps({"deps": deps, "dropped": dropped}, sort_keys=True))


if op == "dangling":
    report("g-dangling",
           [{"id": "w1", "invokes": {}, "depends_on": ["ghost"]}])
elif op == "self":
    report("g-self",
           [{"id": "w1", "invokes": {}, "depends_on": ["w1"]}])
elif op == "two-cycle":
    report("g-2cyc",
           [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
            {"id": "w2", "invokes": {}, "depends_on": ["w1"]}])
elif op == "three-cycle":
    report("g-3cyc",
           [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
            {"id": "w2", "invokes": {}, "depends_on": ["w3"]},
            {"id": "w3", "invokes": {}, "depends_on": ["w1"]}])
elif op == "forward-ref":
    report("g-fwd",
           [{"id": "w1", "invokes": {}, "depends_on": []},
            {"id": "w2", "invokes": {}, "depends_on": ["w1"]}])
elif op == "mixed":
    # cycle w1<->w2 PLUS a legitimate forward-ref w3->w1; break the cycle,
    # keep w3's edge (no over-drop).
    report("g-mixed",
           [{"id": "w1", "invokes": {}, "depends_on": ["w2"]},
            {"id": "w2", "invokes": {}, "depends_on": ["w1"]},
            {"id": "w3", "invokes": {}, "depends_on": ["w1"]}])
elif op == "existing-ref":
    # depending on an EXISTING ledger step ("plan") is valid — preserved.
    report("g-exist",
           [{"id": "w1", "invokes": {}, "depends_on": ["plan"]}])
elif op == "leaf-dep":
    # dep points at a batch item that has NO depends_on key (not an adj node) —
    # exercises the back-edge finder's leaf guard (no KeyError).
    report("g-leaf",
           [{"id": "w1", "invokes": {}},
            {"id": "w2", "invokes": {}, "depends_on": ["w1"]}])
elif op == "unhashable":
    # malformed model output: an unhashable (list) element where a string id
    # belongs — must be DROPPED, not raise TypeError on the `in set` test (which
    # would abort the persist → zero steps → the same stall class, just loud).
    report("g-unhashable",
           [{"id": "w1", "invokes": {}, "depends_on": [["nested"]]}])
PYEOF
}

it "U14 guard: dangling dep id → dropped, step left with depends_on:[] (no dangling stall)"
assert_eq \
  '{"deps": {"w1": []}, "dropped": [["w1", "ghost", "dangling"]]}' \
  "$(enum_driver dangling)"

it "U14 guard: self-edge → dropped (a step can never satisfy itself)"
assert_eq \
  '{"deps": {"w1": []}, "dropped": [["w1", "w1", "self"]]}' \
  "$(enum_driver self)"

it "U14 guard: unhashable (list) dep element → dropped, no TypeError/persist-abort"
assert_eq \
  '{"deps": {"w1": []}, "dropped": [["w1", ["nested"], "dangling"]]}' \
  "$(enum_driver unhashable)"

it "U14 guard: 2-cycle → one edge dropped, graph made acyclic"
assert_eq \
  '{"deps": {"w1": ["w2"], "w2": []}, "dropped": [["w2", "w1", "cycle"]]}' \
  "$(enum_driver two-cycle)"

it "U14 guard: 3-cycle (w1→w2→w3→w1) → back edge dropped, acyclic (generalizes past pairwise)"
assert_eq \
  '{"deps": {"w1": ["w2"], "w2": ["w3"], "w3": []}, "dropped": [["w3", "w1", "cycle"]]}' \
  "$(enum_driver three-cycle)"

it "U14 guard: valid sibling forward-ref preserved verbatim (behavior-preserving happy path)"
assert_eq \
  '{"deps": {"w1": [], "w2": ["w1"]}, "dropped": []}' \
  "$(enum_driver forward-ref)"

it "U14 guard: cycle + legitimate forward-ref in one batch → break cycle, do NOT over-drop the valid edge"
assert_eq \
  '{"deps": {"w1": ["w2"], "w2": [], "w3": ["w1"]}, "dropped": [["w2", "w1", "cycle"]]}' \
  "$(enum_driver mixed)"

it "U14 guard: dep on an existing ledger step is valid → preserved"
assert_eq \
  '{"deps": {"w1": ["plan"]}, "dropped": []}' \
  "$(enum_driver existing-ref)"

it "U14 guard: dep points at a batch leaf (no depends_on key) → kept, no KeyError in back-edge finder"
assert_eq \
  '{"deps": {"w1": [], "w2": ["w1"]}, "dropped": []}' \
  "$(enum_driver leaf-dep)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "ledger-mutators.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
