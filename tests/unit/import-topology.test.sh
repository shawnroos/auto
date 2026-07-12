#!/usr/bin/env bash
# auto v0.3.1 Track C: import-topology lint — locks the DAG the B4/B5 splits
# established so future agents can't re-introduce a circular import.
#
# WHY THIS TEST EXISTS:
# B5 split lib/ledger.py into a 4-file DAG (ledger_core ← ledger_mutators ←
# ledger_emitters ← ledger-facade); B4 split lib/pulse.py into pulse ←
# {pulse_advance, pulse_guidance} with pulse_advance ← pulse_guidance. Those splits
# carefully avoided cycles. But the load_lib_module loader resolves siblings at
# runtime, so a cycle wouldn't surface as an ImportError at parse time — it
# would surface as a subtle runtime failure (a half-initialized module, or a
# duplicate class identity breaking `except ledger.LedgerError`). A future agent
# adding a "convenience import" could re-introduce one silently.
#
# This lint makes the topology grep-checkable — the same deterministic-defense
# shape as tests/unit/wikilink-check.test.sh (G5) and
# tests/unit/doc-fence-ledger-schema.test.sh (H). The DAG edges are the
# contract; this test fails the build if a forbidden edge appears.
#
# THE DAG (allowed edges only):
#   ledger_core   → (nothing; DAG root, stdlib + _bootstrap only)
#   ledger_mutators → ledger_core
#   ledger_emitters → ledger_core, ledger_mutators
#   ledger (facade) → ledger_core, ledger_mutators, ledger_emitters
#   pulse_guidance → ledger (facade), phase-grammar         [leaf]
#   pulse_advance  → ledger, iteration, producers, pulse_guidance
#   pulse          → ledger, iteration, producers, pulse_advance, pulse_guidance
#
# Consumers (auto.py, dispatcher.py, on-stop.py, auto-status.py, etc.) load
# the LEDGER FACADE, never ledger_mutators/ledger_emitters directly — the facade
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

# ─── ledger DAG: forbidden edges ────────────────────────────────────────────
it "ledger_core.py imports NO ledger sibling (DAG root)"
if loads_sibling "ledger_core.py" "ledger_mutators" \
   || loads_sibling "ledger_core.py" "ledger_emitters" \
   || loads_sibling "ledger_core.py" "ledger"; then
  fail "ledger_core.py must not import any ledger sibling — it is the DAG root"
else
  pass
fi

it "ledger_mutators.py imports ledger_core only (no producers, no facade)"
if loads_sibling "ledger_mutators.py" "ledger_emitters" \
   || loads_sibling "ledger_mutators.py" "ledger"; then
  fail "ledger_mutators.py may import ledger_core ONLY — importing producers/facade is a cycle"
else
  pass
fi

it "ledger_emitters.py does NOT import the ledger facade (back-edge)"
if loads_sibling "ledger_emitters.py" "ledger"; then
  fail "ledger_emitters.py must not import the ledger facade — that closes a cycle"
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
# Every lib file EXCEPT the ledger split itself must route through the `ledger`
# facade — none may load ledger_mutators / ledger_emitters directly.
it "no consumer loads ledger_mutators/ledger_emitters directly (facade discipline)"
violators=""
for f in "$LIB"/*.py; do
  base="$(basename "$f")"
  # The split files themselves are allowed to import their DAG siblings.
  # ledger_steering (v0.13.0) is a facade LAYER, not a consumer: it holds the
  # agent-facing steering verbs and imports ledger_mutators for the two graph
  # helpers add_unit/reshape_deps reuse (core ← mutators ← steering ← facade).
  case "$base" in
    ledger.py|ledger_core.py|ledger_mutators.py|ledger_emitters.py|ledger_steering.py) continue ;;
  esac
  if grep -q 'load_lib_module("ledger_mutators")' "$f" \
     || grep -q 'load_lib_module("ledger_emitters")' "$f"; then
    violators+="${base} "
  fi
done
if [ -z "$violators" ]; then
  pass
else
  fail "these consumers bypass the ledger facade: ${violators}— load \"ledger\" instead"
fi

# ─── presets DAG: the validator stays a light leaf (KTD-2) ─────────────────
# lib/presets.py (U1, addressable-step-contents) reuses recipe_validate's
# primitives + the backend_ops leaf, but MUST NOT import dispatcher.py — that
# module pulls in the ledger and the whole dispatch surface. Keeping the preset
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
# file — a botched `adapter_ops`→`backend_ops` / `adapter-*`→`backend-*` rename
# would go green by accident. These positive existence asserts make it go RED.
for _mod in backend_ops.py backend-ce.py backend-native.py; do
  it "lib/${_mod} exists (pinned module — guard against a vacuous negative-grep pass)"
  if [ -f "$LIB/${_mod}" ]; then
    pass
  else
    fail "lib/${_mod} is missing — the U4 backend rename did not land it"
  fi
done

# ─── deliberate-fail: prove the lint isn't vacuous ──────────────────────────
# Write a tmp copy of ledger_mutators.py with a forbidden facade import added;
# the loads_sibling check MUST flag it. (We test the predicate directly against
# a planted-broken copy rather than mutating the real tree.)
it "deliberate-fail: a planted ledger_mutators→ledger facade import trips the lint"
tmpdir="$(mktemp -d -t import-topology-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
cp "$LIB/ledger_mutators.py" "$tmpdir/ledger_mutators.py"
printf '\nledger = load_lib_module("ledger")  # PLANTED forbidden back-edge\n' >> "$tmpdir/ledger_mutators.py"
if grep -q 'load_lib_module("ledger")' "$tmpdir/ledger_mutators.py"; then
  pass
else
  fail "deliberate-fail: planted forbidden import was NOT detected by the grep predicate"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "import-topology.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
