#!/usr/bin/env bash
# auto unit test: lib/format_compat.py — the format-v1 → format-v2 read shim
# (concept-vocabulary rename plan, U6 / KTD-1).
#
# WHY THIS TEST EXISTS:
# U6 flips every persisted key/value on disk in one atomic cutover. Records and
# workflow files written by pre-rename code stay v1 on disk forever (a completed
# run never mutates again). `lib/format_compat.py` is the ONE module that speaks
# both vocabularies: every read chokepoint maps v1 -> v2 in memory, so all code
# outside this module speaks only the new keys.
#
# The three properties the whole cutover rests on — this test pins each one:
#   PURE            — the caller's dict is never mutated in place.
#   IDEMPOTENT      — upgrade(upgrade(x)) == upgrade(x). Safe to run on every read.
#   ORDER-INDEPENDENT — the result does not depend on which subset of old keys a
#                     record happens to carry, nor on dict insertion order.
#
# UNCONDITIONAL (never gated on `format`): a `format: 2` record can still be
# MUTATED by an OLD plugin in a mixed fleet, leaving stray v1 keys behind. A
# shim that skipped `format >= 2` records would skip those strays forever and
# silently lose the old plugin's write (the write-skip-forever hole, KTD-1).
# Scenario 5 is that exact corruption class.
#
# Test scenarios:
#   1  v1 run-record -> v2 exact shape (both fixtures, every mapped key/value)
#   2  nested op values: dispatch_context.enumerated_steps[].invokes.backend_op
#   3  idempotence: upgrade(upgrade(v1)) == upgrade(v1)
#   4  purity: the caller's input dict is not mutated
#   5  mixed-fleet: format:2 + stray v1 keys -> strays mapped, twin dropped
#   6  clean format:2 record -> byte-identical passthrough
#   7  mixed old/new twins -> NEW key wins, stale old twin DROPPED
#   8  genuinely-unknown keys pass through untouched
#   9  order-independence (property-style, randomized key subsets)
#   10 phase_transitions[] per-item .emitter / .producer semantics
#   11 downgrade round-trip: downgrade(upgrade(v1)) == v1 (modulo the marker)
#   12 upgrade_workflow over every builtin workflow in v1 form
#   13 downgrade_run_record strips the `format` marker
#   14 upgrade_workflow never stamps `format` (the schema is additionalProperties:false)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
FIX="${AUTO_ROOT}/tests/fixtures/format-v1"

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

# Driver: load lib/format_compat.py via _bootstrap and run one named probe.
fc() {
  "$PY" - "$AUTO_ROOT" "$FIX" "$@" <<'PYEOF'
import sys, os, json, copy, random

auto_root, fixdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
fcm = load_lib_module("format_compat")
probe = sys.argv[3]

def load(name):
    with open(os.path.join(fixdir, name)) as fh:
        return json.load(fh)

MIDWORK = "run-record-midwork.json"
SEAM = "run-record-seam-paused.json"
BUILTINS = ["a1.json", "a2.json", "a4.json", "w.json", "review.json", "pipeline.json"]

def find(rec, uid):
    for u in rec.get("steps", []):
        if u.get("id") == uid:
            return u
    return {}

out = {}

# ── 1: v1 run-record -> v2 exact shape ──────────────────────────────────────
if probe == "shape-midwork":
    v2 = fcm.upgrade_run_record(load(MIDWORK))
    plan1 = find(v2, "plan-1")
    judge = find(v2, "judge")
    out = {
        # top-level key renames
        "has_steps": "steps" in v2,
        "no_units": "units" not in v2,
        "backend": v2.get("backend"),
        "no_adapter": "adapter" not in v2,
        "backend_scale": v2.get("backend_scale"),
        "no_adapter_scale": "adapter_scale" not in v2,
        "workflow_name": (v2.get("workflow") or {}).get("name"),
        "no_recipe": "recipe" not in v2,
        "handoff_paused": v2.get("handoff_paused"),
        "no_seam_paused": "seam_paused" not in v2,
        "format": v2.get("format"),
        # phase VALUES
        "phase_order": v2.get("phase_order"),
        # producer key + producer-name VALUE
        "pt": v2.get("phase_transitions"),
        # iteration.gate_unit -> gate_step
        "gate_step": (v2.get("iteration") or {}).get("gate_step"),
        "no_gate_unit": "gate_unit" not in (v2.get("iteration") or {}),
        # predicate field
        "all_steps_terminal": (v2.get("exit_predicate_result") or {}).get("all_steps_terminal"),
        "no_all_units_terminal": "all_units_terminal" not in (v2.get("exit_predicate_result") or {}),
        # per-step dispatch_context
        "plan1_backend_op": (plan1.get("dispatch_context") or {}).get("backend_op"),
        "plan1_has_enumerated_steps": "enumerated_steps" in (plan1.get("dispatch_context") or {}),
        "plan1_no_enumerated_units": "enumerated_units" not in (plan1.get("dispatch_context") or {}),
        "judge_winner_step_id": (judge.get("dispatch_context") or {}).get("winner_step_id"),
        "judge_no_winner_unit_id": "winner_unit_id" not in (judge.get("dispatch_context") or {}),
        # dropped_depends_on_edges[].unit -> .step
        "dropped": (plan1.get("dispatch_context") or {}).get("dropped_depends_on_edges"),
        # emit_templates nested invokes
        "et_backend_op": ((((v2.get("emit_templates") or {}).get("plan-candidate") or {})
                           .get("invokes")) or {}).get("backend_op"),
    }

elif probe == "shape-seam":
    v2 = fcm.upgrade_run_record(load(SEAM))
    out = {
        "loop_phase": v2.get("loop_phase"),
        "handoff_paused": v2.get("handoff_paused"),
        "no_seam_paused": "seam_paused" not in v2,
        "phase_order": v2.get("phase_order"),
        "producer": (v2.get("phase_transitions") or [{}])[0].get("producer"),
        "no_emitter": "emitter" not in (v2.get("phase_transitions") or [{}])[0],
        "format": v2.get("format"),
        # no lingering "seam" ANYWHERE in the serialized record
        "no_seam_token": "seam" not in json.dumps(v2),
    }

# ── 2: the NESTED op value (enumerated_steps[].invokes.backend_op) ──────────
elif probe == "nested-op":
    v2 = fcm.upgrade_run_record(load(MIDWORK))
    dc = find(v2, "plan-1").get("dispatch_context") or {}
    items = dc.get("enumerated_steps") or []
    out = {
        "ops": [((i.get("invokes") or {}).get("backend_op")) for i in items],
        "no_adapter_op_anywhere": "adapter_op" not in json.dumps(v2),
        "no_do_unit_anywhere": "do_unit" not in json.dumps(v2),
    }

# ── 3: idempotence ──────────────────────────────────────────────────────────
elif probe == "idempotent":
    res = {}
    for name in (MIDWORK, SEAM):
        once = fcm.upgrade_run_record(load(name))
        twice = fcm.upgrade_run_record(copy.deepcopy(once))
        res[name] = once == twice
    for name in BUILTINS:
        once = fcm.upgrade_workflow(load(os.path.join("recipes", name)))
        twice = fcm.upgrade_workflow(copy.deepcopy(once))
        res[name] = once == twice
    out = res

# ── 4: purity — the caller's dict is untouched ──────────────────────────────
elif probe == "pure":
    src = load(MIDWORK)
    before = json.dumps(src, sort_keys=True)
    fcm.upgrade_run_record(src)
    fcm.downgrade_run_record(load(MIDWORK))
    wf = load(os.path.join("recipes", "a2.json"))
    wf_before = json.dumps(wf, sort_keys=True)
    fcm.upgrade_workflow(wf)
    out = {
        "run_record_untouched": json.dumps(src, sort_keys=True) == before,
        "workflow_untouched": json.dumps(wf, sort_keys=True) == wf_before,
    }

# ── 5: MIXED FLEET — format:2 record carrying stray v1 keys ────────────────
# The corruption class an older still-installed plugin produces: it reads a
# format:2 record, writes `seam_paused: true` / `units` back into it. A shim
# gated on `format >= 2` would skip this record FOREVER and silently lose that
# write. The unconditional map catches it.
elif probe == "mixed-fleet":
    rec = {
        "format": 2,
        "run_id": "r1",
        # the old plugin wrote BOTH the v1 twin (stale) and left the v2 key
        "steps": [{"id": "a", "phase": "work"}],
        "units": [{"id": "STALE", "phase": "seam"}],
        "seam_paused": True,           # stray v1 key the old plugin wrote
        "loop_phase": "seam",          # stray v1 VALUE the old plugin wrote
        "adapter": "ce",
    }
    v2 = fcm.upgrade_run_record(rec)
    out = {
        "new_key_wins": [s.get("id") for s in v2.get("steps", [])],
        "twin_dropped": "units" not in v2,
        "stray_key_mapped": v2.get("handoff_paused"),
        "stray_v1_key_gone": "seam_paused" not in v2,
        "stray_value_mapped": v2.get("loop_phase"),
        "adapter_mapped": v2.get("backend"),
        "format": v2.get("format"),
    }

# ── 6: clean format:2 -> byte-identical passthrough ────────────────────────
elif probe == "v2-passthrough":
    v2_in = fcm.upgrade_run_record(load(MIDWORK))
    v2_out = fcm.upgrade_run_record(copy.deepcopy(v2_in))
    out = {"identical": json.dumps(v2_in, sort_keys=True) == json.dumps(v2_out, sort_keys=True)}

# ── 7: mixed old/new twins -> new wins, stale twin dropped ─────────────────
elif probe == "twin-drop":
    rec = {
        "units": [{"id": "OLD"}], "steps": [{"id": "NEW"}],
        "adapter": "ce", "backend": "native",
        "seam_paused": True, "handoff_paused": False,
        "iteration": {"gate_unit": "OLD", "gate_step": "NEW"},
    }
    v2 = fcm.upgrade_run_record(rec)
    out = {
        "steps": [s.get("id") for s in v2.get("steps", [])],
        "backend": v2.get("backend"),
        "handoff_paused": v2.get("handoff_paused"),
        "gate_step": (v2.get("iteration") or {}).get("gate_step"),
        "never_both": not any(k in v2 for k in ("units", "adapter", "seam_paused")),
        "iteration_never_both": "gate_unit" not in (v2.get("iteration") or {}),
    }

# ── 8: genuinely-unknown keys pass through untouched ───────────────────────
elif probe == "unknown-passthrough":
    rec = {
        "units": [{"id": "a", "mystery_field": {"deep": [1, 2, {"adapter_op": "do_unit"}]}}],
        "some_future_key": {"nested": "value"},
        "goal_intent": "rework the seam between plan and work",
    }
    v2 = fcm.upgrade_run_record(rec)
    out = {
        "unknown_kept": v2.get("some_future_key"),
        "unknown_nested_kept": (v2["steps"][0].get("mystery_field") or {}).get("deep"),
        # a `seam` inside a free-text VALUE is prose, not a phase — never rewritten
        "prose_untouched": v2.get("goal_intent"),
    }

# ── 9: ORDER-INDEPENDENCE (property-style, randomized key subsets) ─────────
# Not one hand-built case: build records from randomized SUBSETS of the old-key
# set in randomized insertion order, and assert the upgraded result equals the
# result of upgrading the same subset built in a different order. A map with an
# order-dependent rule (e.g. one that reads a key it has already renamed) fails
# here even when every hand-built fixture passes.
elif probe == "order-independence":
    OLD_KEYS = {
        "units": [{"id": "u1", "phase": "seam",
                   "dispatch_context": {"adapter_op": "do_unit",
                                        "enumerated_units": [{"id": "w1", "invokes": {"adapter_op": "do_unit"}}],
                                        "winner_unit_id": "u0",
                                        "dropped_depends_on_edges": [{"unit": "w9", "dep": "x", "reason": "dangling"}]}}],
        "adapter": "ce",
        "adapter_scale": "three-tier",
        "recipe": {"name": "a2", "source_tier": "built-in"},
        "seam_paused": True,
        "loop_phase": "seam",
        "phase_order": ["plan", "seam", "work"],
        "terminal_phase": "work",
        "phase_transitions": [{"from": "plan", "to": "seam", "emitter": "plan_output_to_work_units"}],
        "iteration": {"gate_unit": "judge", "bound": {"max_attempts": 3}},
        "emit_templates": {"t": {"phase": "seam", "invokes": {"adapter_op": "do_unit"}}},
        "exit_reason": {"kind": "recipe-bug", "error": {"type": "UnknownUnit"}},
        "exit_predicate_result": {"met": False, "all_units_terminal": True},
        "run_id": "r1",
        "unknown_key": "kept",
    }
    keys = list(OLD_KEYS)
    rng = random.Random(20260713)
    mismatches = []
    for trial in range(400):
        k = rng.randint(1, len(keys))
        subset = rng.sample(keys, k)
        a_order = list(subset); rng.shuffle(a_order)
        b_order = list(subset); rng.shuffle(b_order)
        rec_a = {key: copy.deepcopy(OLD_KEYS[key]) for key in a_order}
        rec_b = {key: copy.deepcopy(OLD_KEYS[key]) for key in b_order}
        up_a = fcm.upgrade_run_record(rec_a)
        up_b = fcm.upgrade_run_record(rec_b)
        if json.dumps(up_a, sort_keys=True) != json.dumps(up_b, sort_keys=True):
            mismatches.append(("order", sorted(subset)))
        # idempotence must hold on EVERY subset too, not just the full record
        if json.dumps(fcm.upgrade_run_record(copy.deepcopy(up_a)), sort_keys=True) \
           != json.dumps(up_a, sort_keys=True):
            mismatches.append(("idempotence", sorted(subset)))
        # and no old key may survive in ANY subset
        blob = json.dumps(up_a)
        for stale in ('"units"', '"adapter"', '"adapter_scale"', '"recipe"',
                      '"seam_paused"', '"adapter_op"', '"enumerated_units"',
                      '"gate_unit"', '"emitter"', '"winner_unit_id"',
                      '"all_units_terminal"', '"do_unit"', '"recipe-bug"'):
            if stale in blob:
                mismatches.append(("stale:" + stale, sorted(subset)))
    out = {"trials": 400, "mismatches": mismatches[:5], "clean": not mismatches}

# ── 10: phase_transitions[] per-ITEM emitter/producer semantics ────────────
# An item may carry .emitter and/or .producer — map/drop PER ITEM, not per array.
elif probe == "pt-per-item":
    rec = {"phase_transitions": [
        {"from": "plan", "to": "seam", "emitter": "plan_output_to_work_units"},     # old only
        {"from": "seam", "to": "work", "producer": "judge_winner_to_work_steps"},   # new only
        {"from": "plan", "to": "work", "emitter": "OLD", "producer": "NEW"},        # both -> new wins
        {"from": "plan", "to": "work", "emitter": "plan_output_to_paired_builders"},# unchanged value
    ]}
    v2 = fcm.upgrade_run_record(rec)
    pts = v2["phase_transitions"]
    out = {
        "producers": [p.get("producer") for p in pts],
        "no_emitter_on_any": not any("emitter" in p for p in pts),
        "froms": [p.get("from") for p in pts],
        "tos": [p.get("to") for p in pts],
    }

# ── 11: downgrade round-trip (inverse-map fidelity) ────────────────────────
elif probe == "roundtrip":
    res = {}
    for name in (MIDWORK, SEAM):
        v1 = load(name)
        back = fcm.downgrade_run_record(fcm.upgrade_run_record(load(name)))
        res[name] = json.dumps(back, sort_keys=True) == json.dumps(v1, sort_keys=True)
        if not res[name]:
            res[name + ":diff"] = [k for k in set(back) ^ set(v1)]
    out = res

# ── 12: upgrade_workflow over every builtin workflow in v1 form ────────────
elif probe == "workflows":
    res = {}
    for name in BUILTINS:
        wf = fcm.upgrade_workflow(load(os.path.join("recipes", name)))
        blob = json.dumps(wf)
        res[name] = {
            "steps": "steps" in wf and "units" not in wf,
            "no_stale": not any(s in blob for s in (
                '"adapter_op"', '"emitter"', '"units"', '"default_adapter"',
                '"gate_unit"', '"do_unit"', '"seam"')),
            "backend_ops": sorted({(s.get("invokes") or {}).get("backend_op")
                                   for s in wf.get("steps", [])
                                   if (s.get("invokes") or {}).get("backend_op")}),
        }
        if "default_backend" in wf:
            res[name]["default_backend"] = wf["default_backend"]
        if "phase_order" in wf:
            res[name]["phase_order"] = wf["phase_order"]
    out = res

# ── 15: OPAQUE KEY NAMESPACES — author/agent-chosen keys are DATA, not format ──
# The key map is depth-blind, which is what lets it reach a nested
# `enumerated_steps[].invokes.backend_op`. But three containers are maps whose KEYS
# the author/agent chooses, and renaming one there corrupts a legitimate name:
#   * emit_templates  — a template legally NAMED `units` would be renamed to
#     `steps` while `iteration.emit_template` (a VALUE) still said "units",
#     leaving a valid, fully-v2 workflow PERMANENTLY unloadable (the map is
#     unconditional) with an error naming a key the author never wrote.
#   * judge_verdicts  — ids come from verification[].id; a renamed id silently
#     never matches, so the criterion reads PENDING forever and the gate never
#     resolves.
#   * decision_payload — an agent-supplied bag.
# Their VALUES must still convert (a template's invokes.backend_op / phase ARE
# format keys). This pins both halves.
elif probe == "opaque-namespaces":
    wf = {
        "steps": [{"id": "g", "phase": "work", "invokes": {"backend_op": "do_step"}}],
        "iteration": {"gate_step": "g", "emit_template": "units"},
        # every mapped token, used as a legitimate template NAME
        "emit_templates": {
            "units":     {"phase": "seam", "invokes": {"adapter_op": "do_unit"}},
            "emitter":   {"phase": "work", "invokes": {"adapter_op": "review"}},
            "gate_unit": {"phase": "work", "id_prefix": "g-"},
        },
    }
    up = fcm.upgrade_workflow(wf)
    rec = {
        "units": [{"id": "g", "dispatch_context": {
            "judge_verdicts": {"units": "pass", "emitter": "fail"},
            "decision_payload": {"units": 3, "emit_count": 2},
        }}],
    }
    upr = fcm.upgrade_run_record(rec)
    dc = upr["steps"][0]["dispatch_context"]
    out = {
        # KEYS at the opaque level survive verbatim …
        "template_names": sorted(up["emit_templates"]),
        "verdict_ids": sorted(dc["judge_verdicts"]),
        "payload_keys": sorted(dc["decision_payload"]),
        # … and the emit_template VALUE still points at a real template
        "emit_template_resolves": up["iteration"]["emit_template"] in up["emit_templates"],
        # … while the templates' VALUES are still fully converted
        "inner_op": (up["emit_templates"]["units"].get("invokes") or {}).get("backend_op"),
        "inner_phase": up["emit_templates"]["units"].get("phase"),
    }

# ── 16: PRESETS — the third user-authorable on-disk format ──────────────────
elif probe == "preset":
    v1 = {"name": "my-build", "version": "1", "description": "legacy",
          "invokes": {"adapter_op": "do_unit", "prompt_template": "p.md"}}
    up = fcm.upgrade_preset(v1)
    out = {
        "invokes": up["invokes"],
        "no_format_stamp": "format" not in up,   # validate_preset has a closed key set
        "idempotent": fcm.upgrade_preset(copy.deepcopy(up)) == up,
        "roundtrip": fcm.downgrade_preset(fcm.upgrade_preset(copy.deepcopy(v1))) == v1,
    }

# ── 13/14: the `format` marker ─────────────────────────────────────────────
elif probe == "marker":
    v2 = fcm.upgrade_run_record(load(MIDWORK))
    down = fcm.downgrade_run_record(v2)
    wf = fcm.upgrade_workflow(load(os.path.join("recipes", "a2.json")))
    out = {
        "upgrade_stamps": v2.get("format"),
        "downgrade_strips": "format" not in down,
        # a workflow must NEVER be stamped: workflows/schema.json is
        # additionalProperties:false, so a stray `format` key fails validate().
        "workflow_unstamped": "format" not in wf,
    }

else:
    raise SystemExit(f"unknown probe {probe!r}")

print(json.dumps(out, sort_keys=True))
PYEOF
}

echo "── format_compat: v1 -> v2 run-record shape ──"

it "midwork v1 fixture upgrades to the exact v2 shape (every mapped key)"
r="$(fc shape-midwork 2>&1)"
expected='{"all_steps_terminal": false, "backend": "ce", "backend_scale": "three-tier", "dropped": [{"dep": "ghost-unit", "reason": "dangling", "step": "w-3"}], "et_backend_op": "next_plan_step", "format": 2, "gate_step": "judge", "handoff_paused": false, "has_steps": true, "judge_no_winner_unit_id": true, "judge_winner_step_id": "plan-1", "no_adapter": true, "no_adapter_scale": true, "no_all_units_terminal": true, "no_gate_unit": true, "no_recipe": true, "no_seam_paused": true, "no_units": true, "phase_order": ["plan", "handoff", "work"], "plan1_backend_op": "next_plan_step", "plan1_has_enumerated_steps": true, "plan1_no_enumerated_units": true, "pt": [{"from": "plan", "producer": "judge_winner_to_work_steps", "to": "work"}], "workflow_name": "a2"}'
assert_eq "$expected" "$r"

it "seam-paused v1 fixture reads as handoff_paused / loop_phase=handoff, no 'seam' token survives"
r="$(fc shape-seam 2>&1)"
expected='{"format": 2, "handoff_paused": true, "loop_phase": "handoff", "no_emitter": true, "no_seam_paused": true, "no_seam_token": true, "phase_order": ["plan", "handoff", "work"], "producer": "plan_output_to_work_steps"}'
assert_eq "$expected" "$r"

it "nested op values map at depth (enumerated_steps[].invokes.backend_op); no adapter_op/do_unit survives"
r="$(fc nested-op 2>&1)"
expected='{"no_adapter_op_anywhere": true, "no_do_unit_anywhere": true, "ops": ["do_step", "do_step", "do_step"]}'
assert_eq "$expected" "$r"

echo ""
echo "── the three load-bearing properties: pure / idempotent / order-independent ──"

it "idempotent: upgrade(upgrade(x)) == upgrade(x) for every fixture"
r="$(fc idempotent 2>&1)"
expected='{"a1.json": true, "a2.json": true, "a4.json": true, "pipeline.json": true, "review.json": true, "run-record-midwork.json": true, "run-record-seam-paused.json": true, "w.json": true}'
assert_eq "$expected" "$r"

it "pure: the caller's dict is never mutated in place"
r="$(fc pure 2>&1)"
assert_eq '{"run_record_untouched": true, "workflow_untouched": true}' "$r"

it "order-independent: 400 randomized key-subset trials agree, stay idempotent, leave no stale key"
r="$(fc order-independence 2>&1)"
expected='{"clean": true, "mismatches": [], "trials": 400}'
assert_eq "$expected" "$r"

echo ""
echo "── mixed old/new keys: new wins, stale twin dropped ──"

it "MIXED FLEET (format:2 + stray v1 keys): strays mapped, twin dropped, new key wins"
r="$(fc mixed-fleet 2>&1)"
expected='{"adapter_mapped": "ce", "format": 2, "new_key_wins": ["a"], "stray_key_mapped": true, "stray_v1_key_gone": true, "stray_value_mapped": "handoff", "twin_dropped": true}'
assert_eq "$expected" "$r"

it "clean format:2 record passes through byte-identical"
r="$(fc v2-passthrough 2>&1)"
assert_eq '{"identical": true}' "$r"

it "old+new twins on one record: NEW value wins and the stale OLD twin is dropped"
r="$(fc twin-drop 2>&1)"
expected='{"backend": "native", "gate_step": "NEW", "handoff_paused": false, "iteration_never_both": true, "never_both": true, "steps": ["NEW"]}'
assert_eq "$expected" "$r"

it "genuinely-unknown keys pass through untouched; prose 'seam' in a value is not rewritten"
r="$(fc unknown-passthrough 2>&1)"
expected='{"prose_untouched": "rework the seam between plan and work", "unknown_kept": {"nested": "value"}, "unknown_nested_kept": [1, 2, {"backend_op": "do_step"}]}'
assert_eq "$expected" "$r"

it "phase_transitions[]: .emitter/.producer mapped PER ITEM (both -> new wins, old dropped)"
r="$(fc pt-per-item 2>&1)"
expected='{"froms": ["plan", "handoff", "plan", "plan"], "no_emitter_on_any": true, "producers": ["plan_output_to_work_steps", "judge_winner_to_work_steps", "NEW", "plan_output_to_paired_builders"], "tos": ["handoff", "work", "work", "work"]}'
assert_eq "$expected" "$r"

echo ""
echo "── revert safety + the format marker ──"

it "downgrade round-trip: downgrade(upgrade(v1)) == v1 (modulo the format marker)"
r="$(fc roundtrip 2>&1)"
expected='{"run-record-midwork.json": true, "run-record-seam-paused.json": true}'
assert_eq "$expected" "$r"

it "upgrade stamps format:2; downgrade strips it; a workflow is NEVER stamped"
r="$(fc marker 2>&1)"
expected='{"downgrade_strips": true, "upgrade_stamps": 2, "workflow_unstamped": true}'
assert_eq "$expected" "$r"

echo ""
echo "── opaque key namespaces: author/agent-chosen keys are DATA, not format ──"

it "emit_templates / judge_verdicts / decision_payload KEYS survive verbatim; their VALUES still convert"
r="$(fc opaque-namespaces 2>&1)"
expected='{"emit_template_resolves": true, "inner_op": "do_step", "inner_phase": "handoff", "payload_keys": ["emit_count", "units"], "template_names": ["emitter", "gate_unit", "units"], "verdict_ids": ["emitter", "units"]}'
assert_eq "$expected" "$r"

it "a v1 PRESET upgrades (invokes.backend_op/do_step), is never format-stamped, and round-trips"
r="$(fc preset 2>&1)"
expected='{"idempotent": true, "invokes": {"backend_op": "do_step", "prompt_template": "p.md"}, "no_format_stamp": true, "roundtrip": true}'
assert_eq "$expected" "$r"

echo ""
echo "── upgrade_workflow over the builtin workflows in v1 form ──"

it "every builtin v1 workflow upgrades: steps/backend_op/producer/handoff, no stale key"
r="$(fc workflows 2>&1)"
expected='{"a1.json": {"backend_ops": ["next_plan_step"], "default_backend": "ce", "no_stale": true, "phase_order": ["plan", "handoff", "work"], "steps": true}, "a2.json": {"backend_ops": ["next_plan_step", "review"], "default_backend": "ce", "no_stale": true, "phase_order": ["plan", "handoff", "work"], "steps": true}, "a4.json": {"backend_ops": ["next_plan_step", "review"], "default_backend": "ce", "no_stale": true, "phase_order": ["plan", "handoff", "work"], "steps": true}, "pipeline.json": {"backend_ops": ["brainstorm"], "default_backend": "ce", "no_stale": true, "phase_order": ["brainstorm", "plan", "handoff", "work"], "steps": true}, "review.json": {"backend_ops": ["review"], "default_backend": "ce", "no_stale": true, "phase_order": ["work"], "steps": true}, "w.json": {"backend_ops": ["next_plan_step"], "default_backend": "ce", "no_stale": true, "phase_order": ["plan", "handoff", "work"], "steps": true}}'
assert_eq "$expected" "$r"

# NB: no builtin workflow DECLARES a `do_unit`/`do_step` step — work steps are
# materialized at runtime by the phase-boundary producers (lib/step_producers.py),
# which is why the op appears in the run-record fixtures (scenario 2) but in no
# workflow file. `w`/`pipeline` each declare a single plan/brainstorm step.

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "format-compat.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
