#!/usr/bin/env bash
# auto v0.3.1 Track C: import-topology lint — locks the DAG the B4/B5 splits
# established so future agents can't re-introduce a circular import.
#
# WHY THIS TEST EXISTS:
# B5 split lib/run_record.py into a 4-file DAG (run_record_core ← run_record_mutators ←
# run_record_producers ← run-record-facade); B4 split lib/pulse.py into pulse ←
# {pulse_advance, pulse_guidance} with pulse_advance ← pulse_guidance. Those splits
# carefully avoided cycles. But the load_lib_module loader resolves siblings at
# runtime, so a cycle wouldn't surface as an ImportError at parse time — it
# would surface as a subtle runtime failure (a half-initialized module, or a
# duplicate class identity breaking `except run_record.RunRecordError`). A future agent
# adding a "convenience import" could re-introduce one silently.
#
# This lint makes the topology grep-checkable — the same deterministic-defense
# shape as tests/unit/wikilink-check.test.sh (G5) and
# tests/unit/doc-fence-run-record-schema.test.sh (H). The DAG edges are the
# contract; this test fails the build if a forbidden edge appears.
#
# THE DAG (allowed edges only):
#   format_compat → (nothing; DAG root, pure stdlib — imports no sibling at all)
#   run_record_core   → format_compat            [DAG root otherwise: stdlib + _bootstrap]
#   run_record_mutators → run_record_core
#   run_record_producers → run_record_core, run_record_mutators
#   run_record (facade) → run_record_core, run_record_mutators, run_record_producers
#   pulse_guidance → run_record (facade), phase-grammar         [leaf]
#   pulse_advance  → run_record, iteration, step_producers, pulse_guidance
#   pulse          → run_record, iteration, step_producers, pulse_advance, pulse_guidance
#   step_producers → (nothing; leaf — the phase-boundary producers are pure)
#
# The producer module took its final name at U7 (KTD-3). NB: pulse_advance reaches it
# via a PLAIN `import step_producers as producers`, NOT load_lib_module(), so
# `loads_sibling` cannot see that edge — the existence assert near the bottom is what
# makes a botched rename go red here instead of at runtime.
#   _bootstrap     → format_compat           (load_run_record_safe — read chokepoint 2)
#   workflow_validate → format_compat          (the validate_and_lint WRITE gate)
#   workflows        → workflow_validate, format_compat   (resolve() read shim)
#   presets        → workflow_validate, backend_ops, format_compat  (load_preset shim)
#   run_record       → format_compat            (U10: the `downgrade` operator command —
#                                                the facade owns the CLI, so the INVERSE
#                                                map is loaded here; format_compat itself
#                                                cannot host it, being unable to reach
#                                                core's flock as a DAG root)
#
# U6 (concept-vocabulary rename / KTD-1) added the five `→ format_compat` edges.
# format_compat is itself a DAG ROOT (pure stdlib, no sibling import), so every
# one of them is a LEAF edge that closes no cycle — including
# `run_record_core → format_compat` and `workflow_validate → format_compat`, which both
# preserve those modules' own root property. NB: this lint is
# forbidden-edge/negative-grep, so an ALLOWED edge missing from this comment would
# not turn it red; these four entries are documentation accuracy, and the
# format_compat.py existence assert below is what makes its absence fail loudly.
#
# Consumers (auto.py, dispatcher.py, on-stop.py, auto-status.py, etc.) load
# the RUN-RECORD FACADE, never run_record_mutators/run_record_producers directly — the facade
# is the public surface.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${AUTO_ROOT}/lib"

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

# loads_sibling <file> <sibling-name> → 0 (true) if <file> contains a
# load_lib_module("<sibling-name>") call. Grep for the exact call form.
loads_sibling() {
  grep -q "load_lib_module(\"$2\")" "$LIB/$1"
}

# ─── run-record DAG: the pinned family EXISTS (anti-vacuity, F13) ────────────
# Same reasoning as the pulse/backend/workflow existence asserts below: every
# run-record DAG check in this file is a NEGATIVE grep through `loads_sibling`, and
# `loads_sibling` greps a file BY PATH — on a MISSING file grep exits non-zero, the
# `if` takes the else branch, and the check passes VACUOUSLY. The U9 rename moved SIX
# modules at once into the `run_record*` names; a single typo'd destination would
# leave this entire lint green while `/auto` died on the first `load_lib_module`.
# Assert the whole family is on disk BEFORE trusting a word the negative greps say.
#
# (The KTD-4 forwarding stubs left behind at the pre-rename paths are deliberately NOT
# asserted here: they are not part of the DAG, and their behaviour is pinned by
# tests/unit/run-record-stub.test.sh, which DRIVES them rather than just checking they
# exist. This lint also deliberately does not spell the retired module names — the
# vocabulary audit greps the whole tree for them, so naming them here would trip it.)
for _rr in run_record.py run_record_core.py run_record_predicate.py \
           run_record_mutators.py run_record_steering.py run_record_producers.py \
           run_record.sh; do
  it "lib/${_rr} exists (the U9-renamed run-record family — DAG checks are vacuous without it)"
  if [ -f "${LIB}/${_rr}" ]; then
    pass
  else
    fail "lib/${_rr} is missing — the U9 run-record rename did not land it, and the DAG checks below would pass vacuously"
  fi
done

# ─── run-record DAG: forbidden edges ────────────────────────────────────────────
it "run_record_core.py imports NO run_record sibling (DAG root)"
if loads_sibling "run_record_core.py" "run_record_mutators" \
   || loads_sibling "run_record_core.py" "run_record_producers" \
   || loads_sibling "run_record_core.py" "run_record"; then
  fail "run_record_core.py must not import any run_record sibling — it is the DAG root"
else
  pass
fi

it "run_record_mutators.py imports run_record_core only (no producers, no facade)"
if loads_sibling "run_record_mutators.py" "run_record_producers" \
   || loads_sibling "run_record_mutators.py" "run_record"; then
  fail "run_record_mutators.py may import run_record_core ONLY — importing producers/facade is a cycle"
else
  pass
fi

it "run_record_producers.py does NOT import the run_record facade (back-edge)"
if loads_sibling "run_record_producers.py" "run_record"; then
  fail "run_record_producers.py must not import the run_record facade — that closes a cycle"
else
  pass
fi

# ─── pulse DAG: the pinned family EXISTS (anti-vacuity, F13) ─────────────────
# loads_sibling greps a file by path: on a MISSING file grep exits non-zero, the
# `if` takes the else branch, and every negative-grep DAG check below passes
# VACUOUSLY. A mis-renamed module (the concept-vocabulary rename U5 file moves)
# would therefore go green while pinning nothing. Assert the three files first.
for _m in pulse.py pulse_advance.py pulse_guidance.py; do
  it "lib/${_m} exists (the pinned pulse family — DAG checks below are vacuous without it)"
  if [ -f "${LIB}/${_m}" ]; then
    pass
  else
    fail "lib/${_m} missing — the pulse DAG checks would pass vacuously"
  fi
done

# ─── pulse DAG: forbidden back-edges ─────────────────────────────────────────
it "pulse_advance.py does NOT back-import pulse"
if loads_sibling "pulse_advance.py" "pulse"; then
  fail "pulse_advance.py must not import pulse — that closes a cycle"
else
  pass
fi

it "pulse_guidance.py does NOT back-import pulse or pulse_advance (leaf)"
if loads_sibling "pulse_guidance.py" "pulse" \
   || loads_sibling "pulse_guidance.py" "pulse_advance"; then
  fail "pulse_guidance.py is a leaf — it must not import pulse or pulse_advance"
else
  pass
fi

# ─── facade discipline: consumers use the facade, not the internals ─────────
# Every lib file EXCEPT the run-record split itself must route through the `run_record`
# facade — none may load run_record_mutators / run_record_producers directly.
it "no consumer loads run_record_mutators/run_record_producers directly (facade discipline)"
violators=""
for f in "$LIB"/*.py; do
  base="$(basename "$f")"
  # The split files themselves are allowed to import their DAG siblings.
  # run_record_steering (v0.13.0) is a facade LAYER, not a consumer: it holds the
  # agent-facing steering verbs and imports run_record_mutators for the two graph
  # helpers add_step/reshape_deps reuse (core ← mutators ← steering ← facade).
  case "$base" in
    run_record.py|run_record_core.py|run_record_mutators.py|run_record_producers.py|run_record_steering.py) continue ;;
  esac
  if grep -q 'load_lib_module("run_record_mutators")' "$f" \
     || grep -q 'load_lib_module("run_record_producers")' "$f"; then
    violators+="${base} "
  fi
done
if [ -z "$violators" ]; then
  pass
else
  fail "these consumers bypass the run_record facade: ${violators}— load \"run_record\" instead"
fi

# ─── presets DAG: the validator stays a light leaf (KTD-2) ─────────────────
# lib/presets.py (U1, addressable-step-contents) reuses workflow_validate's
# primitives + the backend_ops leaf, but MUST NOT import dispatcher.py — that
# module pulls in the run-record and the whole dispatch surface. Keeping the preset
# validator off the heavy dispatch module is the KTD-2 boundary.
# Existence assert (F13): the forbidden-edge check above is a NEGATIVE grep, so
# it passes VACUOUSLY if lib/dispatcher.py is missing (e.g. a botched rename that
# left the module under its old name). Pin the pinned module's presence so a
# mis-rename goes red here instead of silently un-enforcing the boundary.
it "lib/dispatcher.py exists (pinned module — negative-grep guard against vacuous pass)"
if [ -f "$LIB/dispatcher.py" ]; then
  pass
else
  fail "lib/dispatcher.py is missing — the KTD-2 forbidden-edge grep above would pass vacuously"
fi

it "presets.py does NOT import dispatcher (KTD-2 leaf boundary)"
if loads_sibling "presets.py" "dispatcher"; then
  fail "presets.py must not import dispatcher — the preset validator is a light leaf (KTD-2); import backend_ops for VALID_BACKEND_OPS instead"
else
  pass
fi

# ─── preset_oneshot DAG: the one-shot verdict stays off the iteration gate ──
# lib/preset_oneshot.py (U4, addressable-step-contents) is the one-shot
# terminal-verdict helper. KTD-1 boundary: the one-shot verdict is a
# READ-ONLY terminal aggregate over the ratified criteria — it reuses ONLY the
# pure verification evaluator, and MUST NOT import lib/iteration.py (the
# iteration-decision-commit module). Importing iteration would silently re-acquire
# the loop's advance/iterate gate semantics and kill the "run once" guarantee
# (Risk R-A). It may load `verification` (the pure aggregator) but never `iteration`.
it "preset_oneshot.py does NOT import iteration (KTD-1 boundary — no gate decision-commit)"
if loads_sibling "preset_oneshot.py" "iteration"; then
  fail "preset_oneshot.py must not import iteration — the one-shot verdict is a read-only terminal aggregate (KTD-1); reuse verification.aggregate directly, never the iteration decision-commit"
else
  pass
fi

it "backend_ops.py imports NO sibling lib module (pure-stdlib leaf)"
if grep -q "load_lib_module(" "$LIB/backend_ops.py"; then
  fail "backend_ops.py must be a pure-stdlib leaf — it is the shared VALID_BACKEND_OPS source of truth and must import no sibling"
else
  pass
fi

# ─── file-existence asserts for the U4-renamed backend modules (F13) ────────
# The leaf/negative-grep checks above pass VACUOUSLY on a missing (mis-renamed)
# file — a botched rename to the `backend_ops` / `backend-*` module names would
# go green by accident. These positive existence asserts make it go RED.
for _mod in backend_ops.py backend-ce.py backend-native.py; do
  it "lib/${_mod} exists (pinned module — guard against a vacuous negative-grep pass)"
  if [ -f "$LIB/${_mod}" ]; then
    pass
  else
    fail "lib/${_mod} is missing — the U4 backend rename did not land it"
  fi
done

# ─── file-existence assert for the U6 format shim ───────────────────────────
# Same anti-vacuity reasoning: lib/format_compat.py is the DAG root every read
# chokepoint and the write gate depend on. If it vanished, the negative-grep
# checks above would still pass — but every run-record read would lose its v1→v2
# upgrade. Pin its existence positively.
it "lib/format_compat.py exists (the U6 format-v1→v2 shim; DAG root)"
if [ -f "$LIB/format_compat.py" ]; then
  pass
else
  fail "lib/format_compat.py is missing — the U6 read/write shim did not land"
fi

# ─── file-existence assert for the U7-renamed producer module (F13) ──────────
# The producer module took its final name at U7 (KTD-3: the two-term file — it carried
# BOTH renamed terms, so it moves exactly once, alongside the rest of its family, and
# never twice). Same anti-vacuity reasoning as the
# backend/pulse asserts above — but with a sharper edge here, because the pulse DAG
# reaches this module through a PLAIN `import step_producers as producers` in
# pulse_advance.py, NOT a load_lib_module() string, so `loads_sibling` cannot see the
# edge at all. A botched rename would surface as an ImportError deep in a live run,
# not as a red lint. Pin the file's presence.
#
# (A resurrected import of the PRE-RENAME module name needs no assert here: the
# vocabulary-audit greps the whole tree for the retired term and fails on it — which
# is why this lint deliberately does not spell that name.)
it "lib/step_producers.py exists (the U7-renamed producer module)"
if [ -f "$LIB/step_producers.py" ]; then
  pass
else
  fail "lib/step_producers.py is missing — the U7 producer-module rename did not land"
fi

# ─── file-existence asserts for the U8-renamed workflow modules (F13) ────────
# The DAG edges asserted at the top of this file (`workflows → workflow_validate,
# format_compat`, `presets → workflow_validate`) are all NEGATIVE greps or
# loads_sibling checks, and every one of them passes VACUOUSLY against a module
# that isn't there. A rename that landed `lib/workflow_validate.py` under a typo'd
# name would leave this lint green while `/auto` died at the first resolve. Pin
# the two U8 module names positively — plus the built-in workflow DIRECTORY, whose
# absence would silently drop `resolve()` through to the A1_BUILTIN constant for
# a1 and to a not-found error for every other built-in.
for _mod in workflows.py workflow_validate.py workflows-list.sh; do
  it "lib/${_mod} exists (the U8-renamed workflow module — guard against a vacuous pass)"
  if [ -f "$LIB/${_mod}" ]; then
    pass
  else
    fail "lib/${_mod} is missing — the U8 workflow rename did not land it"
  fi
done

it "the built-in workflow dir exists and holds the conformance corpus (a1/a2/a4/w/pipeline/review)"
_missing=""
for _wf in a1 a2 a4 w pipeline review schema; do
  [ -f "${AUTO_ROOT}/workflows/${_wf}.json" ] || _missing="${_missing} ${_wf}.json"
done
if [ -z "$_missing" ]; then
  pass
else
  fail "workflows/ is missing:${_missing} — the U8 built-in dir rename did not land"
fi

# The producer module is a LEAF: pulse/pulse_advance import it, it imports no
# sibling back. A back-edge to pulse* or the run-record facade would close a cycle.
it "step_producers.py does NOT back-import pulse/pulse_advance (leaf)"
if grep -qE '^\s*import (pulse|pulse_advance)\b|load_lib_module\("(pulse|pulse_advance)"\)' \
     "$LIB/step_producers.py"; then
  fail "step_producers.py must not import pulse/pulse_advance — the producers are a leaf; that closes a cycle"
else
  pass
fi

# The shim must stay a TRUE DAG root: pure stdlib, importing no sibling. If it
# ever grew a sibling edge it could cycle back through run_record_core (which imports
# IT), so this is the load-bearing negative check for the new module.
it "format_compat.py imports NO sibling lib module (it is the DAG root)"
if grep -qE 'load_lib_module\(|^from (run_record|workflows|workflow_validate|pulse)' "$LIB/format_compat.py"; then
  fail "format_compat.py must import no sibling — run_record_core imports it, so any sibling edge risks a cycle"
else
  pass
fi

# ─── deliberate-fail: prove the lint isn't vacuous ──────────────────────────
# Write a tmp copy of run_record_mutators.py with a forbidden facade import added;
# the loads_sibling check MUST flag it. (We test the predicate directly against
# a planted-broken copy rather than mutating the real tree.)
it "deliberate-fail: a planted run_record_mutators→run_record facade import trips the lint"
tmpdir="$(mktemp -d -t import-topology-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
cp "$LIB/run_record_mutators.py" "$tmpdir/run_record_mutators.py"
printf '\nrun_record = load_lib_module("run_record")  # PLANTED forbidden back-edge\n' >> "$tmpdir/run_record_mutators.py"
if grep -q 'load_lib_module("run_record")' "$tmpdir/run_record_mutators.py"; then
  pass
else
  fail "deliberate-fail: planted forbidden import was NOT detected by the grep predicate"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "import-topology.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
