#!/usr/bin/env bash
# auto integration test: format-v1 records/workflows survive the U6 cutover
# END-TO-END, through the REAL engine paths (concept-vocabulary rename, U6).
#
# tests/unit/format-compat.test.sh proves the MAP is correct in isolation. This
# file proves the map is actually WIRED — that a real pre-rename run-record, read
# through the real chokepoints, drives the real engine. Nothing is mocked: the
# only injected input is a sandbox repo seeded with the captured v1 fixtures.
#
# THE TWO READ CHOKEPOINTS (KTD-1) — both must be wired independently:
#   1. run_record_core._read_json     — read_run_record + the locked read-modify-write
#   2. _bootstrap.load_run_record_safe — EVERY hook + scan consumer (on-stop,
#      on-session-start, on-pretooluse-*, auto-detect, auto-resume's scan,
#      auto-status's list-all, launch-mode). This path does NOT go through (1).
# Scenario 6 is the anti-shadowing proof: it drives the hook path directly, and
# its deliberate-fail control comments out THE SECOND CALL SPECIFICALLY — if the
# shim were only wired at chokepoint 1, that control would still pass (green by
# shadowing) and the P0 would ship silently.
#
# Scenarios:
#   1  v1 run-record reads as v2 through read_run_record (chokepoint 1)
#   2  v1 record + ONE real mutation → on-disk file is v2, stamped format:2,
#      predicate recomputed under the new `all_steps_terminal` field
#   3  a v1 WORKFLOW file resolves + validates + projects with backend_op
#   4  the handoff-paused v1 record reads as handoff_paused / loop_phase=handoff
#      and /auto-resume ADVANCES it (the in-flight population the shim protects)
#   5  a producer-name VALUE off a v1 record resolves in the producer REGISTRY
#   6  the HOOK path (_bootstrap.load_run_record_safe) upgrades — chokepoint 2
#   6b DELIBERATE-FAIL: comment out the chokepoint-2 call specifically → RED
#   7  the authoring WRITE gate accepts a v1-keyed draft (validates an upgraded
#      copy, warnings-list signature unchanged)
#   7b an authored file that PERSISTS v1-keyed still resolve()s cleanly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LIB="${AUTO_ROOT}/lib"
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

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

REPO="${SANDBOX}/repo"
mkdir -p "${REPO}/.claude/auto"

# Seed the sandbox with the captured v1 records, under their run ids.
seed() {
  rm -f "${REPO}/.claude/auto/"*.json
  cp "${FIX}/run-record-midwork.json"     "${REPO}/.claude/auto/midwork.json"
  cp "${FIX}/run-record-seam-paused.json" "${REPO}/.claude/auto/parked.json"
}

drive() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$FIX" "$@" <<'PYEOF'
import sys, os, json
auto_root, repo, fixdir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module, load_run_record_safe
op = sys.argv[4]
out = {}

if op == "read-v1":
    run_record = load_lib_module("run_record")
    led = run_record.read_run_record(repo, "midwork")
    out = {
        "steps": [u["id"] for u in led["steps"]],
        "no_units_key": "units" not in led,
        "backend": led.get("backend"),
        "workflow": (led.get("workflow") or {}).get("name"),
        "handoff_paused": led.get("handoff_paused"),
        "all_steps_terminal": led["exit_predicate_result"].get("all_steps_terminal"),
        "backend_op": (led["steps"][0].get("dispatch_context") or {}).get("backend_op"),
    }

elif op == "mutate-v1":
    # ONE real mutation through the locked RMW path, then inspect the BYTES on disk.
    run_record = load_lib_module("run_record")
    run_record.transition(repo, "midwork", "w-2", "dispatched")
    with open(os.path.join(repo, ".claude", "auto", "midwork.json")) as fh:
        raw = json.load(fh)      # RAW read — no shim, so this is the true on-disk shape
    blob = json.dumps(raw)
    out = {
        "format": raw.get("format"),
        "on_disk_steps": "steps" in raw and "units" not in raw,
        "on_disk_backend": "backend" in raw and "adapter" not in raw,
        "on_disk_workflow": "workflow" in raw and "recipe" not in raw,
        "on_disk_handoff": "handoff_paused" in raw and "seam_paused" not in raw,
        "predicate_field": "all_steps_terminal" in raw["exit_predicate_result"],
        "predicate_recomputed": raw["exit_predicate_result"].get("all_steps_terminal"),
        "no_v1_token": not any(t in blob for t in (
            '"units"', '"adapter"', '"seam', '"emitter"', 'adapter_op', 'do_unit',
            'enumerated_units', 'gate_unit', 'all_units_terminal', 'winner_unit_id')),
        "w2_state": [u["state"] for u in raw["steps"] if u["id"] == "w-2"][0],
    }

elif op == "v1-workflow":
    # THE CRITICAL USER-COMPAT PATH (U8 / KTD-7 — the two shims COMPOSING).
    #
    # A real user upgrading across the concept-vocabulary rename has BOTH legacy
    # facts on disk at once:
    #   (1) their workflow files sit in the pre-rename dir `.claude/auto/recipes/`
    #       — the DIR was renamed to `workflows/` in U8;
    #   (2) those files are keyed in format v1 (`units`, `adapter`, `adapter_op`,
    #       `do_unit`, …) — the KEYS were flipped in U6.
    # Either shim alone is useless if the other doesn't fire: a v1 file the
    # registry can't FIND never reaches the key shim, and a file found in the
    # legacy dir still fails the v2 validator unless it is upgraded on read. So
    # this scenario deliberately exercises them TOGETHER — v1 bytes, legacy dir —
    # and is the one that must never regress.
    #
    # `.claude/auto/recipes` is spelled LITERALLY here (not read off
    # workflows._LEGACY_TIER_DIRNAME) so the test PINS the retired directory name
    # rather than tautologically agreeing with whatever the module now says. This
    # file is path-whitelisted in the vocabulary audit for exactly this reason.
    workflows = load_lib_module("workflows")
    wsdir = os.path.join(repo, ".claude", "auto", "recipes")   # the LEGACY dir
    os.makedirs(wsdir, exist_ok=True)
    with open(os.path.join(fixdir, "recipes", "a2.json")) as fh:
        v1 = json.load(fh)
    v1["name"] = "legacy"
    with open(os.path.join(wsdir, "legacy.json"), "w") as fh:
        json.dump(v1, fh)          # persisted V1-KEYED on disk, deliberately

    # Nothing was written to the NEW dir — the legacy dir is the ONLY source.
    new_dir_absent = not os.path.isdir(os.path.join(repo, ".claude", "auto", "workflows"))

    wf, tier = workflows.resolve("legacy", repo)      # dir fallback + read shim fire here
    workflows.validate(wf)                            # the v2 validator accepts it
    projected = [workflows.step_for(u, wf) for u in wf["steps"]]
    out = {
        "tier": tier,
        "resolved_from_legacy_dir_only": new_dir_absent,
        "steps": [u["id"] for u in wf["steps"]],
        "gate_step": wf["iteration"]["gate_step"],
        "producer": wf["phase_transitions"][0]["producer"],
        "default_backend": wf.get("default_backend"),
        "projected_backend_op": projected[0]["dispatch_context"].get("backend_op"),
        "validates": True,
        # the FILE on disk is still v1 — proving read-compat, not a rewrite
        "file_still_v1": "units" in json.load(open(os.path.join(wsdir, "legacy.json"))),
    }

elif op == "legacy-dir-arms-run":
    # The same legacy pair (v1 keys + legacy dir) must ARM A RUN, not merely
    # resolve: `auto.py` -> load_and_validate -> step_for -> init_run_record. A shim
    # that satisfies the registry but produces a topology the engine can't init
    # is not compat. This drives the REAL init path end-to-end and reads the
    # resulting run-record back off disk.
    workflows = load_lib_module("workflows")
    wsdir = os.path.join(repo, ".claude", "auto", "recipes")   # the LEGACY dir
    os.makedirs(wsdir, exist_ok=True)
    with open(os.path.join(fixdir, "recipes", "a2.json")) as fh:
        v1 = json.load(fh)
    v1["name"] = "legacy"
    with open(os.path.join(wsdir, "legacy.json"), "w") as fh:
        json.dump(v1, fh)

    wf, tier = workflows.load_and_validate("legacy", repo)     # both shims fire
    run_record = load_lib_module("run_record")
    init_steps = [workflows.step_for(u, wf) for u in wf.get("steps", [])]
    phase_order = wf.get("phase_order", ["plan", "handoff", "work"])
    run_record.init_run_record(
        repo, "legacy-run",
        backend=wf.get("default_backend", "ce"),
        steps=init_steps,
        loop_phase=phase_order[0],
        workflow={"name": wf["name"], "source_tier": tier},
        phase_order=phase_order,
        terminal_phase=wf.get("terminal_phase", "work"),
        phase_transitions=wf.get("phase_transitions", []),
        iteration=wf.get("iteration"),
        emit_templates=wf.get("emit_templates"),
    )
    # Read the run-record back off DISK (not the returned dict) — the bytes are
    # the claim: the engine must persist v2 even when the source file was v1.
    with open(run_record.run_record_path(repo, "legacy-run")) as fh:
        rec = json.load(fh)
    out = {
        "tier": tier,
        "armed": True,
        "record_format": rec.get("format"),
        # the run-record is written in V2 (the engine only ever writes new keys)
        "record_v2_keys": "steps" in rec and "units" not in rec,
        "record_workflow_name": (rec.get("workflow") or {}).get("name"),
        "record_no_v1_workflow_key": "recipe" not in rec,
        "step_ids": [u["id"] for u in rec["steps"]],
        # and the source file is STILL v1 in the STILL-legacy dir — untouched
        "source_file_still_v1": "units" in json.load(open(os.path.join(wsdir, "legacy.json"))),
    }

elif op == "producer-registry":
    # The producer-name VALUE carried by the v1 record must resolve in the REGISTRY
    # after upgrade (the value renamed with the key).
    run_record = load_lib_module("run_record")
    producers = load_lib_module("step_producers")
    led = run_record.read_run_record(repo, "parked")
    name = led["phase_transitions"][0]["producer"]
    out = {
        "producer_name": name,
        "resolves_in_registry": name in producers.REGISTRY,
        "callable": callable(producers.REGISTRY.get(name)),
    }

elif op == "hook-path":
    # CHOKEPOINT 2 — the path every hook takes. NOT via run_record_core._read_json.
    led = load_run_record_safe(os.path.join(repo, ".claude", "auto", "parked.json"))
    out = {
        "loop_phase": led.get("loop_phase"),
        "handoff_paused": led.get("handoff_paused"),
        "no_seam_paused": "seam_paused" not in led,
        "steps_present": "steps" in led,
        "format": led.get("format"),
    }

elif op == "write-gate":
    # The authoring WRITE path: a model following not-yet-renamed skill prose hands
    # validate_and_lint a V1-KEYED draft. It must be ACCEPTED (validated as an
    # upgraded COPY), the caller's draft must NOT be mutated, and the return value
    # must still be the warnings LIST.
    workflows = load_lib_module("workflows")
    with open(os.path.join(fixdir, "recipes", "a2.json")) as fh:
        draft = json.load(fh)
    draft["name"] = "authored"
    draft["description"] = "An operator-authored variant with a typed judge gate."
    before = json.dumps(draft, sort_keys=True)
    warnings = workflows.validate_and_lint(draft, filename="authored.json")
    out = {
        "accepted": True,
        "returns_list": isinstance(warnings, list),
        "blocking_warnings": len(warnings),
        "draft_not_mutated": json.dumps(draft, sort_keys=True) == before,
        "draft_still_v1": "units" in draft and "steps" not in draft,
    }

elif op == "authored-file-resolves":
    # 7b — what the authoring flow PERSISTS may be v1-keyed; it must still resolve.
    # NB the authoring flow writes to the NEW workspace dir (workspace_workflow_path).
    workflows = load_lib_module("workflows")
    wsdir = os.path.join(repo, ".claude", "auto", "workflows")
    os.makedirs(wsdir, exist_ok=True)
    with open(os.path.join(fixdir, "recipes", "a2.json")) as fh:
        draft = json.load(fh)
    draft["name"] = "authored"
    workflows.validate_and_lint(draft, filename="authored.json")
    with open(os.path.join(wsdir, "authored.json"), "w") as fh:
        json.dump(draft, fh)       # persists V1-KEYED (the shim never rewrites it)
    wf, tier = workflows.resolve("authored", repo)
    workflows.validate(wf)
    out = {
        "persisted_v1": "units" in json.load(open(os.path.join(wsdir, "authored.json"))),
        "resolves_v2": "steps" in wf and "units" not in wf,
        "gate_step": wf["iteration"]["gate_step"],
        "tier": tier,
    }

elif op == "v1-preset":
    # PRESETS are the third user-authorable on-disk format, and they carry two
    # renamed tokens (invokes.adapter_op + the do_unit VALUE). validate_preset's
    # known-key set is now `backend_op` only, so WITHOUT a read shim a user's
    # pre-rename workspace preset does not degrade — it HARD-FAILS and aborts
    # `/auto --preset <name>`. This is the fifth read surface; the four run-record/
    # workflow chokepoints do not cover it.
    presets = load_lib_module("presets")
    pdir = os.path.join(repo, ".claude", "auto", "presets")
    os.makedirs(pdir, exist_ok=True)
    with open(os.path.join(pdir, "legacy-build.json"), "w") as fh:
        json.dump({"name": "legacy-build", "version": "1",
                   "description": "A pre-rename preset a user authored.",
                   "invokes": {"adapter_op": "do_unit", "prompt_template": "p.md"}}, fh)
    loaded = presets.load_and_validate_preset("legacy-build", repo)
    preset = loaded[0] if isinstance(loaded, tuple) else loaded
    with open(os.path.join(pdir, "legacy-build.json")) as fh:
        on_disk = json.load(fh)
    out = {
        "loads": True,
        "backend_op": preset["invokes"].get("backend_op"),
        "no_adapter_op": "adapter_op" not in preset["invokes"],
        # read-compat, NOT a rewrite: the user's file is untouched on disk
        "file_still_v1": "adapter_op" in on_disk["invokes"],
    }

else:
    raise SystemExit(f"unknown op {op!r}")

print(json.dumps(out, sort_keys=True))
PYEOF
}

echo "── chokepoint 1: run_record_core._read_json (read_run_record + locked RMW) ──"

seed
it "a format-v1 run-record reads as v2 through read_run_record"
r="$(drive read-v1 2>&1)"
expected='{"all_steps_terminal": false, "backend": "ce", "backend_op": "next_plan_step", "handoff_paused": false, "no_units_key": true, "steps": ["plan-1", "plan-2", "plan-3", "judge", "w-1", "w-2", "w-3"], "workflow": "a2"}'
assert_eq "$expected" "$r"

seed
it "v1 record + ONE real mutation → the BYTES on disk are v2, stamped format:2, predicate recomputed"
r="$(drive mutate-v1 2>&1)"
expected='{"format": 2, "no_v1_token": true, "on_disk_backend": true, "on_disk_handoff": true, "on_disk_steps": true, "on_disk_workflow": true, "predicate_field": true, "predicate_recomputed": false, "w2_state": "dispatched"}'
assert_eq "$expected" "$r"

echo ""
echo "── the workflow read path: resolve() → upgrade_workflow → validate() ──"

seed
it "U8 KTD-7: a v1-keyed file in the LEGACY .claude/auto/recipes/ dir resolves, validates, projects (both shims composing)"
r="$(drive v1-workflow 2>&1)"
expected='{"default_backend": "ce", "file_still_v1": true, "gate_step": "judge", "producer": "judge_winner_to_work_steps", "projected_backend_op": "next_plan_step", "resolved_from_legacy_dir_only": true, "steps": ["plan-1", "plan-2", "plan-3", "judge"], "tier": "workspace", "validates": true}'
assert_eq "$expected" "$r"

seed
it "U8 KTD-7: that same legacy pair ARMS A RUN — init_run_record writes a v2 run-record, source file untouched"
r="$(drive legacy-dir-arms-run 2>&1)"
expected='{"armed": true, "record_format": 2, "record_no_v1_workflow_key": true, "record_v2_keys": true, "record_workflow_name": "legacy", "source_file_still_v1": true, "step_ids": ["plan-1", "plan-2", "plan-3", "judge"], "tier": "workspace"}'
assert_eq "$expected" "$r"

seed
it "a producer-name VALUE off a v1 record resolves in the producer registry post-upgrade"
r="$(drive producer-registry 2>&1)"
expected='{"callable": true, "producer_name": "plan_output_to_work_steps", "resolves_in_registry": true}'
assert_eq "$expected" "$r"

echo ""
echo "── chokepoint 2: _bootstrap.load_run_record_safe — the HOOK/scan path ──"

seed
it "the handoff-paused v1 record reads as handoff_paused/loop_phase=handoff via the HOOK path"
r="$(drive hook-path 2>&1)"
expected='{"format": 2, "handoff_paused": true, "loop_phase": "handoff", "no_seam_paused": true, "steps_present": true}'
assert_eq "$expected" "$r"

# ── /auto-resume advances the handoff-paused v1 run (the in-flight population) ──
seed
it "/auto-resume ADVANCES the handoff-paused v1 run (loop_phase handoff → work)"
resume_out="$(CLAUDE_AUTO_REPO="$REPO" "$PY" "${LIB}/auto-resume.py" continue parked 2>&1)"
phase="$("$PY" - "$AUTO_ROOT" "$REPO" <<'PYEOF' 2>&1
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
led = load_lib_module("run_record").read_run_record(sys.argv[2], "parked")
print(led["loop_phase"])
PYEOF
)"
if [ "$phase" = "work" ]; then
  pass
else
  fail "expected loop_phase 'work' after resume, got '$phase' (resume said: ${resume_out})"
fi

# ── DELIBERATE-FAIL: prove chokepoint 2 is INDEPENDENTLY wired ───────────────
# If the shim were wired ONLY at run_record_core._read_json, the hook-path assertion
# above could still pass by SHADOWING (a consumer reaching the run-record facade). So
# comment out the upgrade call in load_run_record_safe SPECIFICALLY and re-run the
# hook-path probe: it MUST go red. This is what makes the second wiring a proven
# claim rather than an assumed one — the plan calls missing it a P0.
echo ""
echo "── deliberate-fail: chokepoint 2 is independently wired (not shadowed by 1) ──"

BOOT="${LIB}/_bootstrap.py"
BACKUP="${SANDBOX}/_bootstrap.py.bak"
cp "$BOOT" "$BACKUP"
restore_bootstrap() { cp "$BACKUP" "$BOOT"; }
trap 'restore_bootstrap; cleanup' EXIT

# Neutralize ONLY load_run_record_safe's upgrade call (chokepoint 2). Chokepoint 1 is
# untouched, so anything that still reports `handoff` must be reading through it.
"$PY" - "$BOOT" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
target = '        return load_lib_module("format_compat").upgrade_run_record(led)'
assert target in src, "deliberate-fail probe could not find the chokepoint-2 call"
open(p, "w").write(src.replace(target, "        return led  # DELIBERATE-FAIL PROBE"))
PYEOF

seed
it "deliberate-fail: with load_run_record_safe's upgrade commented out, the hook path reads V1 (goes RED)"
r="$(drive hook-path 2>&1)"
# It must now report the RAW v1 shape: no handoff_paused, seam_paused still present.
if printf '%s' "$r" | grep -q '"handoff_paused": null' \
   && printf '%s' "$r" | grep -q '"no_seam_paused": false' \
   && printf '%s' "$r" | grep -q '"steps_present": false'; then
  pass
else
  fail "chokepoint 2 appears SHADOWED — disabling it still yielded v2: ${r}"
fi

restore_bootstrap
trap cleanup EXIT

seed
it "post-revert: the hook path upgrades again (the probe left no residue)"
r="$(drive hook-path 2>&1)"
expected='{"format": 2, "handoff_paused": true, "loop_phase": "handoff", "no_seam_paused": true, "steps_present": true}'
assert_eq "$expected" "$r"

echo ""
echo "── the authoring WRITE gate (validate_and_lint validates an upgraded COPY) ──"

seed
it "the write gate ACCEPTS a v1-keyed draft; returns the warnings LIST; does not mutate the draft"
r="$(drive write-gate 2>&1)"
expected='{"accepted": true, "blocking_warnings": 0, "draft_not_mutated": true, "draft_still_v1": true, "returns_list": true}'
assert_eq "$expected" "$r"

seed
it "an authored file that PERSISTS v1-keyed still resolves cleanly (read-compat is indefinite)"
r="$(drive authored-file-resolves 2>&1)"
expected='{"gate_step": "judge", "persisted_v1": true, "resolves_v2": true, "tier": "workspace"}'
assert_eq "$expected" "$r"

echo ""
echo "── the PRESET read path (the fifth persisted surface) ──"

seed
it "a user's pre-rename workspace PRESET still loads (would HARD-FAIL /auto --preset without the shim)"
r="$(drive v1-preset 2>&1)"
expected='{"backend_op": "do_step", "file_still_v1": true, "loads": true, "no_adapter_op": true}'
assert_eq "$expected" "$r"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "format-v1-compat.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
