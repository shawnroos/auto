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
seam=done
unit=done
recipe=done
ledger=pending"

# ─── SCAN SCOPE ─────────────────────────────────────────────────────────────
# The shipped trees that must speak only the new vocabulary once a term is
# done. Historical docs (docs/plans, docs/brainstorms, docs/research) and the
# top-level CONCEPTS.md are deliberately OUT of scope (never scanned).
SCAN_ROOTS=(lib skills commands docs/contracts tests workflows presets .claude/hooks)

# ─── PERMANENT GLOBAL PATH WHITELIST ────────────────────────────────────────
# Files that legitimately keep an old identifier for EVERY term. Anchored on
# the leading `path:` of each `path:lineno:content` grep hit.
#   * lib/format_compat.py — the one module that legitimately speaks both
#     vocabularies (the read/write shim; created in U6).
#   * The KTD-4 forwarding stubs — 2-line `.sh` forwarders + the `ledger.py`
#     re-export shim, kept one minor version for agents with memorized paths.
#   * commands/auto-tick.md — the kept alias command (persisted in in-flight
#     ScheduleWakeup rearm prompts).
#   * tests/unit/format-compat.test.sh + tests/integration/format-v1-compat.test.sh
#     — the shim's OWN tests. Both necessarily name both vocabularies: they assert
#     that `adapter` maps to `backend`, that `.emitter` becomes `.producer`, and
#     (in the integration test) that NO old key survives on disk — an assertion
#     that has to spell the old key to look for it. Same rationale as
#     lib/format_compat.py: these are the files whose JOB is to know both.
#   * This test file itself — it names every old term in prose/patterns.
#
# U7 REMOVED `lib/ledger.py` + `lib/ledger.sh` from this list. They were added in
# U6 in ANTICIPATION of becoming KTD-4 forwarding stubs — but that only happens at
# U9, when `ledger.py` → `run_record.py` and `ledger.py` is left behind as the
# re-export shim. TODAY they are the REAL facade and the REAL bash entrypoint, and
# `lib/ledger.py` owns `_VERBS` — the CLI verb registry U7 renames (`add-unit` →
# `add-step`, `set-enumerated-units` → `set-enumerated-steps`). Whitelisting it made
# the audit structurally unable to police the `unit` term inside the one file that
# defines the term's entire CLI surface. Both are clean for every currently-`done`
# term, so they scan like any other file. **U9 re-adds `lib/ledger.py`** (and
# `lib/ledger.sh`) here at the moment they actually become stubs.
#
# U8 NOTE — `lib/recipes-list.sh` was on this list from U1 in ANTICIPATION (the same
# mistake U7 found with `lib/ledger.py`): until U8 it was the REAL picker data layer,
# and whitelisting it blinded the audit to a live file. As of U8 it IS the KTD-4
# forwarding stub (2 lines, execs `lib/workflows-list.sh`), so the entry is now
# earned rather than premature. `lib/ledger.py` / `lib/ledger.sh` are still ABSENT
# here — they remain the real facade until U9.
GLOBAL_PATH_WHITELIST=(
  'lib/format_compat.py'
  'lib/tick.sh'
  'lib/orchestrator.sh'
  'lib/adapter-ce.sh'
  'lib/adapter-native.sh'
  'lib/recipes-list.sh'
  'commands/auto-tick.md'
  'tests/unit/format-compat.test.sh'
  'tests/integration/format-v1-compat.test.sh'
  'tests/unit/vocabulary-audit.test.sh'
)

# ─── PERMANENT GLOBAL PATH-PREFIX WHITELIST ─────────────────────────────────
# The ONE directory whose whole contents legitimately speak the OLD vocabulary:
# the format-v1 fixture corpus (U6). These files ARE v1 by definition — captured
# from real pre-rename runs / recipe files — and exist precisely so the shim can
# be proven to upgrade them. Whitelisting the directory (not each file) keeps the
# audit from rotting when a fixture is added. This is the only prefix entry; the
# "explicit paths, no wildcard-by-default" doctrine otherwise stands.
GLOBAL_PATH_PREFIX_WHITELIST=(
  'tests/fixtures/format-v1/'
)

# ─── PERMANENT GLOBAL CONTENT WHITELIST ─────────────────────────────────────
# Line CONTENT that legitimately references an old term for any term:
#   * CHANGELOG-style "supersedes <old> <version>" re-lock banner lines (KTD-5).
#   * The renamed skills' "(formerly auto-adapter)" / "(formerly
#     auto-author-recipe)" description breadcrumbs that keep model-side
#     triggering matching old phrasing (KTD-4).
#   * `<!--legacy-->` — the explicit marker on the "Legacy keys (read-compat)"
#     appendix rows of the three schema-bearing contracts (KTD-5 step 3). Such a
#     row MUST name the old key — that is the entire point of a read-compat
#     table. The marker is an HTML comment (invisible when rendered) and is
#     tagged PER LINE, so it exempts exactly the legacy rows and never a
#     normative key table elsewhere in the same file.
GLOBAL_CONTENT_WHITELIST_RE='(supersedes|[Ff]ormerly |<!--legacy-->)'

# regex_for_term <term> → the OLD-identifier grep pattern (ERE, used with -i).
# Leading word boundary OR a leading underscore, case-insensitive at call site:
# catches `ledger`, `Ledger`, `LEDGER_`, `ledger_core`, AND `_read_ledger` /
# `_maybe_ledger`; NOT `myledger`. For all 8 terms the term name IS the old
# identifier.
#
# U6 HARDENING — why the `_` alternative exists. A bare `\bseam` has NO word
# boundary between `_` and `s` (both are word characters), so it silently missed
# the whole leading-underscore SYMBOL class: `_maybe_seam`, `_try_seam_pause`,
# `_seam_default_notice` would all have survived U6 audit-GREEN while the term
# was supposedly retired. Private helpers are exactly where a renamed concept
# hides longest. Adding the `_` alternative closes that blind spot for every
# term, not just this one.
regex_for_term() { printf '(\\b|_)%s' "$1"; }

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

  # ── global path-PREFIX whitelist (the format-v1 fixture corpus) ──
  # Anchored at the start of the `path:lineno:content` hit so it can only ever
  # exempt a leading directory, never a substring match mid-content.
  for wl in "${GLOBAL_PATH_PREFIX_WHITELIST[@]}"; do
    raw="$(printf '%s\n' "$raw" | grep -v "^${wl}" || true)"
    [ -z "$raw" ] && return 0
  done

  # ── global content whitelist ──
  # TOKEN-SCRUBBED, not line-dropped. The whole-line `grep -vE` this replaces was the
  # SAME defect class that let U7's sweep silently corrupt the read-compat tables: an
  # exemption meant for a breadcrumb ("supersedes …", "(formerly auto-adapter)") also
  # swallowed any real stale identifier that happened to share the line. Probed and
  # confirmed: `formerly the add_unit verb lived here` sailed through GREEN.
  #
  #   * `<!--legacy-->` rows are still dropped WHOLESALE — a read-compat row's job is
  #     to name retired keys across its full width, so there is nothing to scrub. That
  #     exemption is now EARNED rather than assumed: Scenario 1b independently proves
  #     every such row still names a retired term and is not a tautology.
  #   * `supersedes …` / `(formerly …)` — only the trailing breadcrumb CLAUSE is
  #     scrubbed. Anything before it on the line is still audited.
  # NB one awk pass, not a per-line sed|grep loop: the deliberate-fail control audits
  # a still-PENDING term whose old identifier is still everywhere (thousands of hits),
  # and spawning two processes per hit took the audit from 1.3s to 19s.
  #
  # `(^|[^a-z0-9])<term>` on a lower-cased copy is exactly `regex_for_term`'s
  # `(\b|_)<term>` -i: `_` is not alphanumeric, so the one class covers both the
  # word-boundary and the leading-underscore alternative.
  raw="$(printf '%s\n' "$raw" | grep -vF -- '<!--legacy-->' || true)"
  [ -z "$raw" ] && return 0
  #
  # Both scrubs are BOUNDED to the real breadcrumb shape. An unbounded
  # `supersedes.*$` / `[Ff]ormerly [^)]*` runs to end-of-line, so a line reading
  # `supersedes: add_unit is still callable` is scrubbed to nothing and rides
  # through GREEN — the very hole this rewrite closes. What the tree actually
  # contains is a re-lock banner (`supersedes <name> <version>`, KTD-5) and a
  # parenthesised skill breadcrumb (`(formerly auto-adapter)`, KTD-4), so:
  #   * `supersedes` exempts only the NEXT one or two tokens (a name, then an
  #     optional version) — not the rest of the line;
  #   * `formerly` exempts only the PARENTHESISED form.
  raw="$(printf '%s\n' "$raw" | awk -v term="$term" '
    {
      p = $0
      gsub(/supersedes[:,]?[ ]+`?[A-Za-z0-9_.\/-]+`?([ ]+\(?v?[0-9][A-Za-z0-9_.-]*\)?)?/, "@SUPERSEDES@", p)
      gsub(/\([Ff]ormerly [^)]*\)/, "@FORMERLY@", p)
      if (tolower(p) ~ "(^|[^a-z0-9])" tolower(term)) print $0
    }' || true)"
  [ -z "$raw" ] && return 0

  # ── term-specific whitelist ──
  case "$term" in
    unit)
      # The `unit` term is entangled with unavoidable non-renamed noise. U7 makes
      # the exemption TOKEN-SCRUBBING, not line-dropping — see the block comment.
      #
      # PERMANENT noise (the U7 whitelist):
      #   * the `tests/unit` directory PATH — keyed to the test-suite layout, not
      #     the renamed concept. It appears BOTH as the path of a hit
      #     (`tests/unit/foo.test.sh:12:…`) AND as a cross-reference inside lib/
      #     and docs/ prose (`see tests/unit/recipes.test.sh`).
      #   * the prose "unit test" / "unit tests" / "unit-test" / "unit-testable"
      #     (the hyphenated adjective form lives in lib/iteration.py,
      #     lib/verification.py, lib/goal-route.py — a bare `unit tests?` misses it).
      #   * plan_step / PLAN_STEPS / next_plan_step — the plan-phase sub-state, a
      #     deliberate "don't rename" carve-out (Key Decisions / CONCEPTS.md).
      #     These carry no `unit` token so they cannot trip the regex; scrubbed
      #     defensively so a future `plan_unit`-shaped revival can't hide behind them.
      #   * tests/run.sh — the ONE file where the test-suite TIER name is a code
      #     identifier (`unit_files`, `[unit|integration|smoke|all]`, `=== UNIT ===`).
      #     That `unit` is the tests/unit/ tier, not a workflow step; renaming it
      #     would break `bash tests/run.sh unit` for every caller.
      #
      # WHY SCRUBBING, NOT DROPPING (U7 hardening — this was a real hole):
      # U1 wrote this as `grep -vE '^tests/unit/'`, which DROPS EVERY HIT IN EVERY
      # FILE UNDER tests/unit/ — all 61 unit-test files. The `unit` term's biggest
      # code surface is exactly those files' symbols and asserts, so the audit was
      # structurally blind to the bulk of what U7 had to rename: a stale `add_unit`
      # in a unit test could never fail it. Likewise `grep -viE 'unit tests?'`
      # dropped the WHOLE LINE, so any real `unit` symbol sharing a line with the
      # words "unit test" vanished too.
      # Now: strip the whitelisted TOKENS from a copy of each line, then keep the
      # line only if a `unit` identifier SURVIVES the strip. The whitelist exempts
      # the noise token, never the line and never the file.
      # One awk pass (see the perf note on the global-content scrub above).
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          gsub(/tests\/unit/, "@TIER@", p)

          # LEFT-BOUNDARY matters. A bare `[Uu]nit[ -][Tt]est` scrub also eats the
          # TAIL of a real identifier whose next token starts with "test" —
          # `add-unit test-run`, `add_unit test_id` — and the line sails through
          # GREEN. That is exactly the retired-verb-plus-a-test-arg shape a doc
          # example or a new test would reintroduce. So: an `unit test` ATTACHED to
          # an identifier char is a REAL symbol — normalize it to a bare token so it
          # still HITS. Only the free-standing prose form is scrubbed.
          gsub(/[-_A-Za-z0-9][Uu]nit[ -][Tt]est[A-Za-z]*/, " unit ", p)   # real symbol → keep
          gsub(/[Uu]nit[ -][Tt]est[A-Za-z]*/, "@UT@", p)                  # prose → scrub
          gsub(/UNIT[ -]TEST[A-Z]*/, "@UT@", p)

          gsub(/plan_step|PLAN_STEPS|next_plan_step/, "@PLANSTEP@", p)

          # tests/run.sh: the test-suite TIER name is a real identifier there
          # (`unit_files`, `[unit|integration|smoke|all]`, `=== UNIT (`). Scrub those
          # TOKENS — do NOT drop the whole file, or run.sh becomes the very kind of
          # file-level blind spot this branch was rewritten to eliminate.
          if ($0 ~ /^tests\/run\.sh:/) {
            gsub(/unit_files/,        "@TIER@_files",      p)
            gsub(/unit\|integration/, "@TIER@|integration", p)
            gsub(/= "unit"/,          "= \"@TIER@\"",      p)
            gsub(/=== UNIT /,         "=== @TIER@ ",       p)
            gsub(/ unit \+/,          " @TIER@ +",         p)
            gsub(/ unit  /,           " @TIER@  ",         p)
          }

          # PERMANENT (KTD-4 hard-cut): the retired CLI verbs have NO aliases, and the
          # regression test that PINS that they now exit 2 has to NAME them to invoke
          # them. Same path+content anchoring as the `tick` branch below: only those
          # two tokens, only in the one test that asserts they are gone — any OTHER
          # stale `unit` in that file still fails the audit. (Matched on $0, the RAW
          # line: `p` has already had tests/unit scrubbed to @TIER@.)
          if ($0 ~ /^tests\/unit\/ledger-cli-feedback\.test\.sh:/) {
            gsub(/add-unit|set-enumerated-units/, "@RETIRED@", p)
          }

          if (tolower(p) ~ /(^|[^a-z0-9])unit/) print $0
        }' || true)"
      ;;
    adapter)
      # PERMANENT: the KTD-4 flag-alias layer in lib/auto.py keeps `--adapter` as a
      # deprecated alias (the `_DEPRECATED_FLAGS` map entry + its comment block).
      # TOKEN-SCRUBBED in BOTH homes: the `_DEPRECATED_FLAGS` map in lib/auto.py, and
      # the test that PINS the alias (which must NAME the retired flag to invoke it).
      # Only the `--adapter` TOKEN is exempt — a stale `adapter` IDENTIFIER in either
      # file (an `adapter_ops` import, an `ExitReason.ADAPTER_BUG`) still FAILS.
      #
      # The old form here was `grep -vE '^lib/auto\.py:.*(--adapter|[Dd]eprecat)'` — a
      # WHOLE-LINE drop keyed on the word "deprecat", sitting in the one file where a
      # deprecation comment is most likely to sit beside a stale identifier. Same U7
      # lesson as every other branch in this case block. Drop both scrubs when the
      # alias is removed next minor.
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          if ($0 ~ /^(lib\/auto\.py|tests\/unit\/flag-aliases\.test\.sh):/) {
            gsub(/--adapter/, "@ALIAS@", p)
          }
          if (tolower(p) ~ /(^|[^a-z0-9])adapter/) print $0
        }' || true)"
      # (U6 REMOVED the TEMP persisted-key exemptions here — `adapter`,
      # `adapter_scale`, `adapter_op`, `default_adapter` are now flipped ON DISK
      # to backend/backend_scale/backend_op/default_backend. The only module that
      # may still spell them is lib/format_compat.py, which is path-whitelisted.)
      ;;
    recipe)
      # The KTD-4 flag-alias layer in lib/auto.py::_parse_args keeps the old
      # spellings (--recipe / --teardown-recipe-after-init) as deprecated aliases
      # (the `_DEPRECATED_FLAGS` map entries + their comment block).
      # TOKEN-SCRUBBED in all three homes: the `_DEPRECATED_FLAGS` map in lib/auto.py,
      # the routing branch in commands/auto.md (which must match the retired spelling
      # or the alias never reaches the parser), and the test that PINS the aliases.
      # Only the two retired FLAG spellings are exempt — a stale `recipe` IDENTIFIER in
      # any of them (a `recipes.py` import, a `RecipeError`) still FAILS the audit.
      # Whole-line drops were the previous form; see the `adapter` branch above for why
      # they are the wrong shape. Drop these when the aliases are removed next minor.
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          if ($0 ~ /^(lib\/auto\.py|commands\/auto\.md|tests\/unit\/flag-aliases\.test\.sh):/) {
            gsub(/--teardown-recipe-after-init|--recipe/, "@ALIAS@", p)
          }
          if (tolower(p) ~ /(^|[^a-z0-9])recipe/) print $0
        }' || true)"

      # PERMANENT (one minor version): the KTD-4 forwarding stub `lib/recipes-list.sh`
      # is globally path-whitelisted above — which means the audit structurally CANNOT
      # fail on it, so nothing would notice if it broke. workflow-picker.test.sh pins
      # that it still forwards; to do so it must NAME the retired path. Only the
      # `recipes-list.sh` TOKEN is scrubbed, and only in that test: a stale `recipe`
      # IDENTIFIER there still fails. (Same shape as the `tick` branch, which exempts
      # the tests that pin `tick.sh` / `auto-tick`.) Drop with the stub next minor.
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          if ($0 ~ /^tests\/integration\/workflow-picker\.test\.sh:/) {
            gsub(/recipes-list\.sh/, "@STUB@", p)
          }
          if (tolower(p) ~ /(^|[^a-z0-9])recipe/) print $0
        }' || true)"

      # PERMANENT (KTD-7 — the LEGACY TIER DIR). `lib/workflows.py::_tier_dirs`
      # appends the pre-rename user dirs as READ-ONLY legacy tiers so a user's
      # existing files still resolve after the rename. That code MUST literally
      # spell the old dir name — a legacy fallback that doesn't name the legacy dir
      # is not a fallback.
      #
      # TOKEN-SCRUBBED, NOT LINE-DROPPED (and NOT file-dropped). An earlier draft of
      # this exemption anchored on the WORD "legacy" and dropped the whole line — which
      # meant any stale identifier that happened to share a line with the word "legacy"
      # (`from recipes import resolve  # legacy`) rode through GREEN. That is the exact
      # defect class U7 documented two branches down and this file keeps re-learning.
      # So: strip the retired dir LITERAL and the constant that holds it, then keep the
      # line if any `recipe` identifier SURVIVES the strip.
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          if ($0 ~ /^lib\/workflows\.py:/) {
            gsub(/_LEGACY_TIER_DIRNAME/,   "@LEGACYDIR@", p)
            gsub(/\.claude\/auto\/recipes/, ".claude/auto/@LEGACYDIR@", p)
            gsub(/"recipes"/,              "\"@LEGACYDIR@\"", p)
          }
          if (tolower(p) ~ /(^|[^a-z0-9])recipe/) print $0
        }' || true)"

      # PERMANENT: an EXTERNAL artifact's NAME. `lib/upstream-cluster.py` and
      # `tests/integration/spine-forward.test.sh` both cite the memory
      # `feedback_a1_recipe_cant_rebound_to_brainstorm` as the provenance of the
      # role-diversity weighting (KTD-6). That is a real file in a system this repo
      # does not own; rewriting the citation to spell `workflow` would point at
      # nothing. Same class as the "(formerly auto-author-recipe)" skill breadcrumb:
      # a retired name that must stay spelled to remain useful. Scoped to that ONE
      # exact token — any other stale `recipe` on the line, or in those files, still
      # fails. NB scrubbed (not line-dropped), so a stale identifier sharing the line
      # with the citation cannot ride through on its coat-tails (the U7 lesson).
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          gsub(/feedback_a1_recipe_cant_rebound_to_brainstorm/, "@MEMORY_ID@", p)
          if (tolower(p) ~ /(^|[^a-z0-9])recipe/) print $0
        }' || true)"
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
      # (U6 REMOVED the TEMP persisted-key exemption here — the JSON key
      # `phase_transitions[].emitter` is now flipped ON DISK to `.producer`. The
      # only module that may still spell it is lib/format_compat.py, which is
      # path-whitelisted.)
      #
      # Two-term MODULE FAMILIES whose final name lands in a later unit (KTD-3):
      # each gets ONE file move, in the unit that owns its FAMILY, not two.
      #   * lib/unit_emitters.py → lib/step_producers.py — LANDED IN U7 (the `unit`
      #     family). Its sibling test moved with it (unit-emitters.test.sh →
      #     step-producers.test.sh, summary line updated so tests/run.sh still
      #     tallies it), and every `load_lib_module("unit_emitters")` call site was
      #     repointed. The `unit_emitters` token no longer exists in the tree.
      #   * lib/ledger_emitters.py → lib/run_record_producers.py — STILL PENDING
      #     (U9, the `ledger` family). Until then the module name, its sibling test
      #     (ledger-emitters.test.sh), and every `load_lib_module("ledger_emitters")`
      #     call site legitimately carry the `emitters` token.
      #
      # NB (U6): the `_`-prefixed forms became VISIBLE to this audit only when
      # regex_for_term gained its `_` alternative — a bare `\bemitter` never
      # matched `ledger_emitters` at all. So this exemption is load-bearing; it is
      # scoped to the `[_-]emitters` token so any un-renamed emitter ROLE prose or
      # symbol still fails. This branch drops out entirely at U9.
      #
      # TOKEN-SCRUBBED + PATH-ANCHORED (U8 hardening). The old form was an UNANCHORED
      # whole-line `grep -vE '[_-]emitters'` — it dropped ANY line ANYWHERE in the tree
      # that merely contained the substring `_emitters`, so a stale `emitter` symbol
      # sharing a line with `ledger_emitters` was invisible. Now: only the two-term
      # module-family TOKENS are scrubbed, only in the files that legitimately carry
      # them, and any surviving `emitter` still fails. This branch disappears at U9.
      raw="$(printf '%s\n' "$raw" | awk '
        {
          p = $0
          gsub(/ledger_emitters|ledger-emitters/, "@FAMILY@", p)
          if (tolower(p) ~ /(^|[^a-z0-9])emitter/) print $0
        }' || true)"
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

# ─── Scenario 1b: the `<!--legacy-->` exemption is EARNED, not assumed ───────
# THE BUG THIS EXISTS TO PREVENT (found in U7 review, after it had already bitten):
# `GLOBAL_CONTENT_WHITELIST_RE` drops any line tagged `<!--legacy-->` — the
# read-compat appendix rows of the three schema-bearing contracts (KTD-5 step 3).
# It has to: a read-compat row's whole PURPOSE is to name the retired key.
#
# But an exemption that is never verified is a blind spot, and U7's rename sweep
# walked straight through it — rewriting the LEGACY (v1) column of 12 rows into the
# NEW spelling, so `units → steps` became `steps → steps`. Every row still had its
# `<!--legacy-->` tag, so the audit dropped them all and stayed green while the
# normative compat table said the v1 on-disk key for the step array *is* `steps`.
# Exactly backwards — and U9 will read these tables to reason about the shim.
#
# So: whatever the audit EXEMPTS here, it must also POLICE. Two properties, both
# cheap and deterministic:
#   (a) a legacy row's v1 column must actually NAME a retired term (else it isn't a
#       legacy row and has no business claiming the exemption);
#   (b) a legacy row must not be a TAUTOLOGY (v1 column == v2 column) — that is the
#       precise signature of a rename sweep having eaten the old spelling.
# `lib/format_compat.py` is the runtime authority for these names; this check keeps
# the DOCS honest against the same retired vocabulary the shim maps.
it "every <!--legacy--> read-compat row still names the RETIRED key (not a tautology)"
legacy_bad=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  row="${rest#*:}"
  # table rows only.
  case "$row" in
    \|*) ;;
    *) continue ;;
  esac
  # `| <v1> | <v2> | …` → strip the leading pipe, take the first two cells.
  body="${row#|}"
  c1="${body%%|*}"
  c2_rest="${body#*|}"
  c2="${c2_rest%%|*}"
  # normalize: drop backticks, quotes, "(value)", and surrounding space
  norm() {
    printf '%s' "$1" | sed -E 's/`//g; s/"//g; s/\(value\)//g; s/^ +//; s/ +$//'
  }
  n1="$(norm "$c1")"
  n2="$(norm "$c2")"
  [ -z "$n1" ] && continue
  # Skip the HEADER row — identified by its FIRST CELL, not by a substring anywhere
  # on the line (a data row must never be able to opt out of this check by quoting
  # the header's wording in a later column). `key` heads the key map; `location`
  # heads the U8 tier-dir map.
  case "$n1" in "legacy (v1) key"|"legacy (v1) location") continue ;; esac
  # (a) the v1 cell must name one of the 8 retired terms
  if ! printf '%s' "$n1" \
       | grep -qiE '(\b|_)(orchestrator|emitter|adapter|tick|seam|unit|recipe|ledger)'; then
    legacy_bad="${legacy_bad}
    ${file}:${lineno}: legacy row's v1 cell names NO retired term: '${n1}'"
  fi
  # (b) a legacy row that maps a name to ITSELF has lost the old spelling
  if [ "$n1" = "$n2" ]; then
    legacy_bad="${legacy_bad}
    ${file}:${lineno}: legacy row is a TAUTOLOGY ('${n1}' → '${n2}') — the v1 column was overwritten with the v2 name"
  fi
done <<< "$(cd "$AUTO_ROOT" && grep -rn -- '<!--legacy-->' docs/contracts --include='*.md' 2>/dev/null || true)"
if [ -z "$legacy_bad" ]; then
  pass
else
  fail "the <!--legacy--> exemption is being claimed by rows that are not legacy:${legacy_bad}"
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
# U5 renamed `tick`; U6 renamed `seam`; U7 renamed `unit`; U8 renamed `recipe`, so
# it now probes `ledger` — the LAST pending term (U9). When U9 lands there is no
# pending term left to probe: the control must then be re-pointed at a synthetic
# probe (or the file's anti-vacuity proof re-grounded), NOT silently deleted.
DF_TERM="ledger"
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
