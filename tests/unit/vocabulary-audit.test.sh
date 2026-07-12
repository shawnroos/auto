#!/usr/bin/env bash
# auto unit test: VOCABULARY-AUDIT harness (concept-vocabulary rename plan, U1).
#
# WHY THIS TEST EXISTS:
# The concept-vocabulary rename (docs/plans/2026-07-12-001-refactor-concept-
# vocabulary-rename-plan.md) renames 8 historical code identifiers to the
# CONCEPTS.md vocabulary, one term per unit (U2–U9). This test PINS that
# progress and becomes the permanent "no old identifier survives outside an
# explicit whitelist" guard.
#
# HOW IT WORKS:
#   * A per-term status table (below) marks each of the 8 terms `pending` or
#     `done`. Initially ALL are `pending` — the current tree still uses every
#     old term, so the audit checks nothing and passes.
#   * When a rename unit lands, it flips its term to `done`. From then on the
#     audit greps (word-boundary, case-insensitive) for the OLD identifier
#     across the shipped trees and FAILS — naming the offending files — if it
#     appears OUTSIDE the explicit whitelist. `pending` terms are NOT checked.
#   * The whitelist is explicit paths + line patterns (no wildcard-by-default),
#     matching the same grep-checkable deterministic-defense shape as
#     tests/unit/wikilink-check.test.sh and tests/unit/import-topology.test.sh.
#
# This is a DEFENSE, not a migration: it never renames anything. It fails the
# build the moment a stale old identifier leaks back into a renamed subsystem.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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

# ─── PER-TERM STATUS TABLE ──────────────────────────────────────────────────
# Flip a term to `done` in the unit that renames it (U2–U9). For each `done`
# term the old identifier must not survive outside the whitelist. All `pending`
# on the current (un-renamed) tree — so the audit passes today.
#
# term          old identifier   renamed-in
# orchestrator  orchestrator     U2
# emitter       emitter          U3
# adapter       adapter          U4
# tick          tick             U5
# seam          seam             U6
# unit          unit             U7
# recipe        recipe           U8
# ledger        ledger           U9
TERM_STATUS="\
orchestrator=done
emitter=done
adapter=done
tick=done
seam=pending
unit=pending
recipe=pending
ledger=pending"

# ─── SCAN SCOPE ─────────────────────────────────────────────────────────────
# The shipped trees that must speak only the new vocabulary once a term is
# done. Historical docs (docs/plans, docs/brainstorms, docs/research) and the
# top-level CONCEPTS.md are deliberately OUT of scope (never scanned).
SCAN_ROOTS=(lib skills commands docs/contracts tests recipes presets .claude/hooks)

# ─── PERMANENT GLOBAL PATH WHITELIST ────────────────────────────────────────
# Files that legitimately keep an old identifier for EVERY term. Anchored on
# the leading `path:` of each `path:lineno:content` grep hit.
#   * lib/format_compat.py — the one module that legitimately speaks both
#     vocabularies (the read/write shim; created in U6).
#   * The KTD-4 forwarding stubs — 2-line `.sh` forwarders + the `ledger.py`
#     re-export shim, kept one minor version for agents with memorized paths.
#   * commands/auto-tick.md — the kept alias command (persisted in in-flight
#     ScheduleWakeup rearm prompts).
#   * This test file itself — it names every old term in prose/patterns.
GLOBAL_PATH_WHITELIST=(
  'lib/format_compat.py'
  'lib/ledger.py'
  'lib/ledger.sh'
  'lib/tick.sh'
  'lib/orchestrator.sh'
  'lib/adapter-ce.sh'
  'lib/adapter-native.sh'
  'lib/recipes-list.sh'
  'commands/auto-tick.md'
  'tests/unit/vocabulary-audit.test.sh'
)

# ─── PERMANENT GLOBAL CONTENT WHITELIST ─────────────────────────────────────
# Line CONTENT that legitimately references an old term for any term:
#   * CHANGELOG-style "supersedes <old> <version>" re-lock banner lines (KTD-5).
#   * The renamed skills' "(formerly auto-adapter)" / "(formerly
#     auto-author-recipe)" description breadcrumbs that keep model-side
#     triggering matching old phrasing (KTD-4).
GLOBAL_CONTENT_WHITELIST_RE='(supersedes|[Ff]ormerly )'

# regex_for_term <term> → the OLD-identifier grep pattern (ERE, used with -i).
# Leading word boundary, case-insensitive at call site: catches `ledger`,
# `Ledger`, `LEDGER_`, `ledger_core`; NOT `myledger` (no boundary) — see the
# task's "case-aware: catch Ledger, LEDGER_, ledger" requirement. For all 8
# terms the term name IS the old identifier.
regex_for_term() { printf '\\b%s' "$1"; }

# term_status <term> → prints `pending` or `done` from the table.
term_status() {
  printf '%s\n' "$TERM_STATUS" | sed -n "s/^$1=//p"
}

# audit_term_hits <term> → prints the filtered (non-whitelisted) grep hits for
# the term's OLD identifier, one `path:lineno:content` per line. Empty output
# means the term is clean. Ignores the status table — the caller decides
# whether to run it (so the deliberate-fail control can force a term).
audit_term_hits() {
  local term="$1"
  local regex; regex="$(regex_for_term "$term")"

  local raw
  raw="$(cd "$AUTO_ROOT" && grep -rniE "$regex" "${SCAN_ROOTS[@]}" \
          --include='*.py' --include='*.sh' --include='*.md' --include='*.json' \
          --exclude-dir='__pycache__' \
          --exclude='*.pyc' \
          2>/dev/null || true)"
  [ -z "$raw" ] && return 0

  # ── global path whitelist ──
  local wl
  for wl in "${GLOBAL_PATH_WHITELIST[@]}"; do
    raw="$(printf '%s\n' "$raw" | grep -vF "${wl}:" || true)"
    [ -z "$raw" ] && return 0
  done

  # ── global content whitelist ──
  raw="$(printf '%s\n' "$raw" | grep -vE "$GLOBAL_CONTENT_WHITELIST_RE" || true)"
  [ -z "$raw" ] && return 0

  # ── term-specific whitelist ──
  case "$term" in
    unit)
      # The `unit` term is entangled with unavoidable non-renamed noise:
      #   * the tests/unit/ directory PATH (keyed to the test suite layout,
      #     not the renamed concept);
      #   * the literal prose "unit test" / "unit tests";
      #   * plan_step / PLAN_STEPS / next_plan_step — the plan-phase sub-state,
      #     a deliberate "don't rename" carve-out (Key Decisions / CONCEPTS.md).
      raw="$(printf '%s\n' "$raw" | grep -vE '^tests/unit/' || true)"
      raw="$(printf '%s\n' "$raw" | grep -viE 'unit tests?' || true)"
      raw="$(printf '%s\n' "$raw" | grep -vE 'plan_step|PLAN_STEPS|next_plan_step' || true)"
      ;;
    adapter)
      # PERMANENT: the KTD-4 flag-alias branch in lib/auto.py::_parse_args keeps
      # `--adapter` as a deprecated alias plus its one-line deprecation string.
      raw="$(printf '%s\n' "$raw" \
             | grep -vE '^lib/auto\.py:[0-9]+:.*(--adapter|[Dd]eprecat)' || true)"
      # TEMP: until U6. U4 renamed the adapter CONCEPT (symbols + prose + files
      # + the backend-contract) to `backend`, but the on-disk KEY cutover is
      # deferred to U6 (KTD-6 — all persisted key/value literals flip in one
      # unit). So the persisted keys `adapter` / `adapter_scale` / `adapter_op`
      # (and the workflow `default_adapter`) legitimately survive, in their
      # persisted form, wherever code READS/WRITES them, in recipe/schema files,
      # in doc examples, and in test fixtures. The compound tokens `adapter_op`
      # / `adapter_scale` / `default_adapter` are UNIQUELY persisted-key names
      # (nothing else is spelled that way), so filtering them bare is safe; the
      # bare `adapter` CONCEPT is narrowed to the quoted/backticked key token so
      # any un-renamed adapter concept prose or symbol still fails the audit.
      # Remove this whole branch at U6.
      raw="$(printf '%s\n' "$raw" | grep -vE 'adapter_op|adapter_scale|default_adapter' || true)"
      raw="$(printf '%s\n' "$raw" | grep -vE "[\"'\`]adapter[\"'\`]" || true)"
      # recipes/schema.json's `default_adapter` property carries a bare
      # "Adapter used when --adapter is not passed." description string; the
      # schema is a persisted-format file left untouched until U6 (KTD-6).
      raw="$(printf '%s\n' "$raw" | grep -vE '^recipes/schema\.json:' || true)"
      ;;
    recipe)
      # The KTD-4 flag-alias branches in lib/auto.py::_parse_args keep the old
      # spellings (--recipe / --teardown-recipe-after-init) as deprecated aliases
      # plus their one-line deprecation strings.
      raw="$(printf '%s\n' "$raw" \
             | grep -vE '^lib/auto\.py:[0-9]+:.*(--recipe|--teardown-recipe-after-init|[Dd]eprecat)' \
             || true)"
      ;;
    tick)
      # PERMANENT (KTD-4, one minor version): the kept forwarding stub `lib/tick.sh`
      # and the kept alias command `commands/auto-tick.md` are whitelisted BY PATH
      # above — but the tests that PIN their existence/behavior have to NAME them,
      # and those test files are NOT whitelisted (any other stale `tick` in them
      # must still fail). So the exemption is anchored to path AND content: only the
      # alias-command token `auto-tick` / the stub path `tick.sh` are exempt, only in
      # the three tests that assert the old surface still resolves. Drop this branch
      # when the alias + stub are removed next minor.
      raw="$(printf '%s\n' "$raw" \
             | grep -vE '^(tests/unit/rearm-command-exists\.test\.sh|tests/smoke/scaffold\.test\.sh|tests/integration/pulse-alias-inflight\.test\.sh):[0-9]+:.*(auto-tick|tick\.sh)' \
             || true)"
      ;;
    emitter)
      # TEMP: until U6. U3 renamed the emitter ROLE vocabulary (symbols + prose)
      # to `producer`, but the on-disk KEY cutover is deferred to U6 (KTD-6 — all
      # persisted key/value literals flip in one unit). So the literal JSON key
      # `emitter` (phase_transitions[].emitter) legitimately survives, in its
      # persisted form, in exactly these places:
      #   * recipes/*.json + recipes/schema.json — the recipe files that carry
      #     `"emitter": "<producer-name>"` and the schema's `required`/property key;
      #   * lib/recipe_validate.py, lib/phase-grammar.py, lib/topology-render.py —
      #     the code that READS phase_transitions[].emitter (pt["emitter"] /
      #     pt.get("emitter")) plus lib/recipes.py's docstring example;
      #   * docs/contracts/recipe-format.md — the normative JSON example + the
      #     `emitter` key identifier in §4 (key tables wait for U6, KTD-5);
      #   * tests/**/*.sh — recipe/transition fixtures exercising the key.
      # The producer-name VALUES (`plan_output_to_work_units`, …) also rename in
      # U6 — they contain no `emitter` token, so no entry is needed for them.
      # Narrow to the QUOTED/BACKTICKED key token so any un-renamed emitter ROLE
      # prose or symbol still fails the audit. Remove this whole branch at U6.
      raw="$(printf '%s\n' "$raw" | grep -vE "[\"'\`]emitter[\"'\`]" || true)"
      # Two-term test files whose module family renames later (KTD-3): the module
      # names lib/unit_emitters.py / lib/ledger_emitters.py use `_` (no \b before
      # `emitter`, never matched here), but their sibling test files use a hyphen
      # (unit-emitters.test.sh renames at U7 with the `unit` family;
      # ledger-emitters.test.sh at U9 with the `ledger` family). Their summary
      # lines MUST equal the on-disk filename for tests/run.sh to tally them, so
      # the `-emitters` token legitimately survives until those units. TEMP-ish:
      # these two drop out of this branch when their file is renamed (U7/U9).
      raw="$(printf '%s\n' "$raw" | grep -vE 'unit-emitters\.test\.sh|ledger-emitters\.test\.sh' || true)"
      ;;
  esac

  [ -z "$raw" ] && return 0
  printf '%s\n' "$raw"
}

# ─── Scenario 1: audit the real status table (all `pending` today → green) ───
it "no old identifier survives outside the whitelist for any DONE term"
any_offender=""
report=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  term="${line%%=*}"
  status="${line#*=}"
  [ "$status" = "done" ] || continue
  hits="$(audit_term_hits "$term")"
  if [ -n "$hits" ]; then
    any_offender="yes"
    report="${report}
  [${term}] old identifier found outside whitelist:
$(printf '%s\n' "$hits" | sed 's/^/    /')"
  fi
done <<< "$TERM_STATUS"
if [ -z "$any_offender" ]; then
  pass
else
  fail "vocabulary audit found stale identifiers:${report}"
fi

# ─── Scenario 2: deliberate-fail control — force a still-PENDING term `done` ──
# Probe a term that has NOT yet been renamed (its old identifier still lives all
# over the tree): auditing it as `done` MUST produce hits that name offending
# files. This runs on EVERY invocation and proves the audit is not vacuous — a
# 0-assertion test or a never-firing grep would report green while checking
# nothing. It does NOT touch the real status table above.
#
# NB: this MUST track a term whose real status is still `pending`. Once a term is
# renamed it no longer produces non-whitelisted hits, so the control would go
# vacuous itself; each rename unit re-points this to the next still-pending term.
# U2 moved it orchestrator→emitter; U3 renamed `emitter`; U4 renamed `adapter`;
# U5 renamed `tick`, so it now probes `seam` (pending until U6).
DF_TERM="seam"
it "deliberate-fail: auditing a pending term ('${DF_TERM}') as done names offending files"
df_hits="$(audit_term_hits "$DF_TERM")"
if [ -n "$df_hits" ]; then
  # Confirm the output actually NAMES files (path:lineno:… shape), not just
  # non-empty noise. NB: no `grep -q` here — a large hit set (e.g. `adapter`,
  # >64KB) would make grep early-exit and SIGPIPE the upstream `printf`, which
  # `set -o pipefail` then reports as a pipeline failure (a false negative that
  # only shows up once the probed term is populous enough to exceed the pipe
  # buffer). Reading all input with a plain `grep … >/dev/null` avoids it.
  if printf '%s\n' "$df_hits" | grep -E '^[^:]+:[0-9]+:' >/dev/null; then
    pass
  else
    fail "audit fired but did not name files: ${df_hits}"
  fi
else
  fail "audit of '${DF_TERM}' found NO hits — the harness is vacuous"
fi

# ─── Scenario 3: the summary line matches the runner's tally regex ──────────
# tests/run.sh tallies on: ^<name>.test.sh(:| results:) N passed, M failed
it "summary line matches the runner tally regex"
probe="vocabulary-audit.test.sh: 0 passed, 0 failed"
if printf '%s\n' "$probe" \
   | grep -qE '^[^[:space:]]+\.test\.sh(:| results:) [0-9]+ passed, [0-9]+ failed'; then
  pass
else
  fail "summary line format would NOT be tallied by tests/run.sh"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "vocabulary-audit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
