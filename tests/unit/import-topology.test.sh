#!/usr/bin/env bash
# auto v0.3.1 Track C: import-topology lint — locks the DAG the B4/B5 splits
# established so future agents can't re-introduce a circular import.
#
# WHY THIS TEST EXISTS:
# B5 split lib/ledger.py into a 4-file DAG (ledger_core ← ledger_mutators ←
# ledger_emitters ← ledger-facade); B4 split lib/tick.py into tick ←
# {tick_advance, tick_guidance} with tick_advance ← tick_guidance. Those splits
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
#   tick_guidance → ledger (facade), phase-grammar         [leaf]
#   tick_advance  → ledger, iteration, emitters, tick_guidance
#   tick          → ledger, iteration, emitters, tick_advance, tick_guidance
#
# Consumers (auto.py, orchestrator.py, on-stop.py, auto-status.py, etc.) load
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

it "ledger_mutators.py imports ledger_core only (no emitters, no facade)"
if loads_sibling "ledger_mutators.py" "ledger_emitters" \
   || loads_sibling "ledger_mutators.py" "ledger"; then
  fail "ledger_mutators.py may import ledger_core ONLY — importing emitters/facade is a cycle"
else
  pass
fi

it "ledger_emitters.py does NOT import the ledger facade (back-edge)"
if loads_sibling "ledger_emitters.py" "ledger"; then
  fail "ledger_emitters.py must not import the ledger facade — that closes a cycle"
else
  pass
fi

# ─── tick DAG: forbidden back-edges ─────────────────────────────────────────
it "tick_advance.py does NOT back-import tick"
if loads_sibling "tick_advance.py" "tick"; then
  fail "tick_advance.py must not import tick — that closes a cycle"
else
  pass
fi

it "tick_guidance.py does NOT back-import tick or tick_advance (leaf)"
if loads_sibling "tick_guidance.py" "tick" \
   || loads_sibling "tick_guidance.py" "tick_advance"; then
  fail "tick_guidance.py is a leaf — it must not import tick or tick_advance"
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
# primitives + the adapter_ops leaf, but MUST NOT import orchestrator.py — that
# module pulls in the ledger and the whole dispatch surface. Keeping the preset
# validator off the heavy dispatch module is the KTD-2 boundary.
it "presets.py does NOT import orchestrator (KTD-2 leaf boundary)"
if loads_sibling "presets.py" "orchestrator"; then
  fail "presets.py must not import orchestrator — the preset validator is a light leaf (KTD-2); import adapter_ops for VALID_ADAPTER_OPS instead"
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

it "adapter_ops.py imports NO sibling lib module (pure-stdlib leaf)"
if grep -q "load_lib_module(" "$LIB/adapter_ops.py"; then
  fail "adapter_ops.py must be a pure-stdlib leaf — it is the shared VALID_ADAPTER_OPS source of truth and must import no sibling"
else
  pass
fi

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
