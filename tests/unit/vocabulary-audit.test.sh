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
#
# ⚠ THE ONE THING THIS AUDIT CANNOT CATCH, BY CONSTRUCTION — read before sweeping.
# It greps for the OLD identifier. So a sweep that DESTROYS the old identifier where it
# was supposed to stay leaves nothing to grep for, and this audit goes green ON THE
# DAMAGE. That is not hypothetical: it has now happened FOUR times on this branch —
# three legacy TABLE columns (`units → steps` rewritten to `steps → steps`, U7/U8/U9)
# and once in PROSE (run-record-schema.md: "can never carry both `steps` and `steps`",
# found in U10 review).
#   * The TABLE form is policed — Scenario 1b checks every `<!--legacy-->` row for
#     "names a retired term" + "is not a tautology", and Scenario 1c makes sure nothing
#     outside such a row can claim the exemption.
#   * The PROSE form is NOT, and cannot be, without a whitelist that would rot. When
#     you sweep, EYEBALL any sentence that describes an old→new mapping. This finds the
#     shape:  grep -rnE '`([a-z_]+)`[^`]{1,20}`\1`' docs/ lib/ README.md CONCEPTS.md

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
ledger=done"

# ─── SCAN SCOPE ─────────────────────────────────────────────────────────────
# Every tree a USER or an AGENT reads. Once a term is `done`, none of them may
# spell the retired identifier outside the whitelist.
#
# U10 WIDENED THIS, AND THAT WAS THE POINT. U1–U9 scanned
# `(lib skills commands docs/contracts tests workflows presets .claude/hooks)` — which
# left the entire FRONT DOOR unpoliced: `README.md`, `CONCEPTS.md`,
# `.claude-plugin/` (the SHIPPED plugin manifest), and all of `docs/` outside
# `contracts/`. Every one of them still carried retired identifiers for terms the
# table already called `done` — the manifest a user installs still advertised
# "Ships named recipes" and "plan-loop -> seam -> work-loop" while the audit reported
# 8/8 green. A guard that is green because it isn't looking is worse than no guard:
# it launders drift as compliance. The audit now polices the whole read surface.
#
# Files (not just dirs) are legal roots — `grep -r` takes both, and README.md /
# CONCEPTS.md are top-level files.
SCAN_ROOTS=(
  lib skills commands tests workflows presets .claude/hooks
  docs                # ALL of docs/, not just contracts/ (see the prefix whitelist)
  README.md           # the front door
  CONCEPTS.md         # the canonical vocabulary statement itself
  .claude-plugin      # the shipped manifest: description + keywords a user installs
)

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
# U9 RE-ADDS `lib/ledger.py` + `lib/ledger.sh`. They were on this list in U6 in
# ANTICIPATION of becoming KTD-4 forwarding stubs, and U7 REMOVED them because that
# had not happened yet: until U9 they were the REAL facade and the REAL bash
# entrypoint, and `lib/ledger.py` owned `_VERBS` — the CLI verb registry U7 renamed
# (`add-unit` → `add-step`). Whitelisting a LIVE file makes the audit structurally
# unable to police the term inside the one file that defines its entire CLI surface.
# As of U9 they ARE the stubs (`lib/run_record.py` / `lib/run_record.sh` are the real
# thing), so the entries are finally EARNED rather than premature. Same story as
# `lib/recipes-list.sh`, which U8 earned the same way.
#
# `lib/ledger.py` is NOT a 2-line exec forwarder like the others — it is a
# module-importable RE-EXPORT shim (KTD-4), because by-path loaders
# (`spec_from_file_location("ledger", …)`) reach for SYMBOLS on it
# (`.ledger_path`) inside an `except: sys.exit(0)`, where a missing name fails
# SILENTLY OPEN. It therefore legitimately spells the whole retired surface.
#
# `tests/unit/run-record-stub.test.sh` is whitelisted for the SAME reason
# `tests/unit/format-compat.test.sh` is: its JOB is to know both vocabularies. It
# pins that the retired surface still resolves — the by-path
# `spec_from_file_location("ledger", …)` load, `.ledger_path` / `.LedgerError`
# symbol access, the byte-clean legacy CLI — and it cannot assert any of that
# without SPELLING every retired name. (A path-whitelisted file can never fail this
# audit, so nothing here would notice if the shims broke — but that is exactly what
# that test is for: it is the thing doing the policing, not a thing needing to be
# policed. If the shim breaks, the test goes red on behaviour, which is stronger
# than a grep.)
GLOBAL_PATH_WHITELIST=(
  'lib/format_compat.py'
  'lib/tick.sh'
  'lib/orchestrator.sh'
  'lib/adapter-ce.sh'
  'lib/adapter-native.sh'
  'lib/recipes-list.sh'
  'lib/ledger.py'
  'lib/ledger.sh'
  'commands/auto-tick.md'
  'tests/unit/format-compat.test.sh'
  'tests/integration/format-v1-compat.test.sh'
  'tests/unit/run-record-stub.test.sh'
  'tests/unit/vocabulary-audit.test.sh'
)

# ─── PERMANENT GLOBAL PATH-PREFIX WHITELIST ─────────────────────────────────
# The directories whose whole contents legitimately speak the OLD vocabulary.
# Whitelisting the directory (not each file) keeps the audit from rotting when a
# file is added to one of them. These are the only prefix entries; the "explicit
# paths, no wildcard-by-default" doctrine otherwise stands.
#
#   * tests/fixtures/format-v1/ — the format-v1 fixture corpus (U6). These files
#     ARE v1 by definition (captured from real pre-rename runs / workflow files)
#     and exist precisely so the shim can be proven to upgrade them.
#
#   * docs/plans/, docs/brainstorms/, docs/research/ — HISTORICAL DOCS. This is a
#     DELIBERATE U10 DECISION, not an oversight, and it is the one judgment call
#     the widening forces:
#       They are DATED ARTIFACTS, not live surface. A plan dated 2026-05-23
#       records what was decided and what the code was called ON THAT DAY. Sweeping
#       them would (a) falsify the record — the v0.2.0 plan really did ship a thing
#       called a `recipe`, and a reader tracing that decision needs the word it was
#       decided under; (b) make the rename plan itself (which names all 8 retired
#       terms hundreds of times, as its subject matter) unwritable; and (c) buy
#       nothing — nobody orients off a closed plan, and every one of them is
#       superseded by the contracts, which ARE scanned.
#       The line is LIVE-vs-DATED, not docs-vs-code: `docs/contracts/`,
#       `docs/handoff.md`, `docs/planning-readiness.md`, `docs/deprecations.md` are
#       all things an agent reads TO ACT, so they are all IN scope (and U10 swept
#       them). Only the three write-once archives are out.
#       This matches the plan's Key Decisions ("Historical docs are not rewritten")
#       and the canonical permanent whitelist in U1/U10/Verification-Contract-item-2.
#     If a FOURTH archive dir is ever added under docs/, it is IN scope until
#     someone adds it here on purpose — which is the correct default.
GLOBAL_PATH_PREFIX_WHITELIST=(
  'tests/fixtures/format-v1/'
  'docs/plans/'
  'docs/brainstorms/'
  'docs/research/'
)

# ─── PERMANENT GLOBAL CONTENT EXEMPTIONS ────────────────────────────────────
# Line CONTENT that legitimately references an old term, for any term. There are
# exactly three, and each is applied INSIDE audit_term_hits (see the scrubs there) —
# there is deliberately no `GLOBAL_CONTENT_WHITELIST_RE` variable any more. U10 removed
# it: it had been dead code since the token-scrub rewrite (defined, never referenced),
# while its comment still described it as the live mechanism. A stale name for a
# defense, sitting next to the real defense, is how the next reader mis-models what is
# actually enforced.
#
#   * "supersedes <name> <version>" — the KTD-5 re-lock banner. Scrubbed as a bounded
#     TOKEN (name + optional version), not to end-of-line.
#   * "(formerly <name>)" — the KTD-4 skill breadcrumbs that keep model-side triggering
#     matching the old phrasing. Scrubbed as ONE parenthesised name, not `[^)]*`.
#   * `<!--legacy-->` on a markdown TABLE ROW — the read-compat appendix rows (KTD-5
#     step 3), whose entire purpose is to name the retired key. Exempt by SHAPE, and
#     Scenario 1b then polices every such row's content; Scenario 1c proves nothing
#     outside that shape can claim it.

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

# audit_term_hits <term> [root] → prints the filtered (non-whitelisted) grep hits
# for the term's OLD identifier, one `path:lineno:content` per line. Empty output
# means the term is clean. Ignores the status table — the caller decides
# whether to run it (so the deliberate-fail control can force a term).
#
# [root] defaults to the real tree. Scenario 2 (the deliberate-fail control) passes
# a SYNTHETIC tree instead — every whitelist below is keyed on the RELATIVE
# `path:lineno:` prefix of a hit, so the exact same filter pipeline applies to
# either root. That is the point: the control must exercise the REAL filters, not a
# reimplementation of them, or it proves nothing about the audit that ships.
audit_term_hits() {
  local term="$1"
  local root="${2:-$AUTO_ROOT}"
  local regex; regex="$(regex_for_term "$term")"

  local raw
  raw="$(cd "$root" && grep -rniE "$regex" "${SCAN_ROOTS[@]}" \
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
  #
  # U10 — THE `<!--legacy-->` EXEMPTION IS NOW SHAPE-BOUND (this was a P0 hole).
  # The old form was a bare `grep -vF -- '<!--legacy-->'`: a WHOLE-LINE drop, in ANY
  # file, of ANY shape. That made the marker a silent, invisible opt-out from the
  # permanent guard — append it to any line, anywhere, and the audit looks away:
  #
  #     README.md:  Run `ledger.py add-unit` on the recipe adapter. <!--legacy-->   → GREEN
  #     lib/auto.py: _recipe = load_lib_module("recipes")  # <!--legacy-->          → GREEN
  #
  # The file's own comment claimed this was safe because "Scenario 1b independently
  # proves every such row still names a retired term". 1b does no such thing for those
  # lines: it inspects ONLY lines whose content starts with `|` (table rows) in .md
  # files, and skips everything else. So the drop exempted a strictly LARGER set than
  # 1b polices — and widening SCAN_ROOTS handed that hole four more trees.
  #
  # Fix: exempt EXACTLY what 1b polices, and nothing else — a markdown TABLE ROW. The
  # exemption is earned by SHAPE (a `|`-row in a `.md` file, which 1b then checks row by
  # row for "names a retired term" + "not a tautology"), never by the marker alone. A
  # `<!--legacy-->` on a prose line, a comment, or anything in a .py/.sh/.json file no
  # longer exempts anything. Scenario 1c is the control.
  raw="$(printf '%s\n' "$raw" | awk '
    {
      if (index($0, "<!--legacy-->") > 0) {
        colon = index($0, ":")
        if (colon > 0) {
          path = substr($0, 1, colon - 1)
          rest = substr($0, colon + 1)          # "<lineno>:<content>"
          c2 = index(rest, ":")
          content = (c2 > 0) ? substr(rest, c2 + 1) : ""
          sub(/^[ \t]+/, "", content)
          # A read-compat TABLE ROW in a markdown file: the one shape whose job is to
          # name retired identifiers across its full width, and the one shape 1b polices.
          if (path ~ /\.md$/ && substr(content, 1, 1) == "|") next
        }
      }
      print
    }' || true)"
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
  #   * `formerly` exempts only ONE NAME inside the parens.
  #
  # U10 — the `formerly` scrub was NOT actually bounded (P1). It read
  # `\([Ff]ormerly [^)]*\)`, and `[^)]*` is exactly the unbounded form the comment
  # above says it fixed: it runs to the next `)`, which on a prose line is arbitrarily
  # far. `(formerly auto-adapter, and the ledger.py add-unit verb)` scrubbed the stale
  # identifiers along with the breadcrumb and rode through GREEN. The real breadcrumbs
  # in the tree are a single name — `(formerly auto-adapter)`,
  # `(formerly auto-author-recipe)` — so the pattern now matches exactly that: ONE
  # name-shaped token. Anything else on the line is still audited.
  raw="$(printf '%s\n' "$raw" | awk -v term="$term" '
    {
      p = $0
      gsub(/supersedes[:,]?[ ]+`?[A-Za-z0-9_.\/-]+`?([ ]+\(?v?[0-9][A-Za-z0-9_.-]*\)?)?/, "@SUPERSEDES@", p)
      gsub(/\([Ff]ormerly `?[A-Za-z0-9_.\/-]+`?\)/, "@FORMERLY@", p)
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
          if ($0 ~ /^tests\/unit\/run-record-cli-feedback\.test\.sh:/) {
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
    # NB: there is deliberately NO `emitter` branch any more. U1–U8 carried one to
    # exempt the two-term MODULE FAMILIES (KTD-3) whose final name lands in the unit
    # that owns their FAMILY, not their first term:
    #   * lib/unit_emitters.py  → lib/step_producers.py        — landed U7 (`unit`)
    #   * lib/ledger_emitters.py → lib/run_record_producers.py — landed U9 (`ledger`)
    # Both have now moved, so NO file in the tree spells `[_-]emitters` and the
    # exemption has nothing left to exempt. An empty-but-present branch is worse than
    # no branch: it is a standing invitation for a future stale `emitter` to be waved
    # through. Deleted at U9, as U1 said it would be.
    # NB: there is deliberately NO `ledger` branch. Every file that legitimately
    # spells the retired run-record surface is PATH-whitelisted above — the two KTD-4
    # stubs (`lib/ledger.py`, `lib/ledger.sh`) and the one test whose job is to prove
    # they still resolve (`tests/unit/run-record-stub.test.sh`). Nothing else in the
    # tree may name the term, so there is no token to scrub and no branch to write.
    # The contract's retired-identifier map earns the `<!--legacy-->` exemption
    # instead — and Scenario 1b POLICES that exemption row by row.
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
#
# U10 WIDENED WHAT THIS POLICES, IN LOCKSTEP WITH THE SCAN. Hardcoding `docs/contracts`
# here was correct only while `docs/contracts` was the only scanned tree that could
# HOLD such a row. The moment SCAN_ROOTS grew to README.md / CONCEPTS.md / all of
# docs/, those files could claim the `<!--legacy-->` exemption too — and an exemption
# no one polices is exactly the hole that ate the contracts' v1 column THREE separate
# times (U7, U8, U9 each flattened a historical column into `run-record → run_record`
# via a blind sweep). So 1b now scans every markdown file the AUDIT scans, minus the
# archives (a dated plan's tables are not live exemptions and are prefix-whitelisted
# out of the audit anyway). Derived from SCAN_ROOTS + GLOBAL_PATH_PREFIX_WHITELIST —
# never a second hand-maintained list that can drift from the first.
legacy_rows() {
  local raw wl
  raw="$(cd "$AUTO_ROOT" && grep -rn -- '<!--legacy-->' "${SCAN_ROOTS[@]}" \
          --include='*.md' --exclude-dir='__pycache__' 2>/dev/null || true)"
  for wl in "${GLOBAL_PATH_PREFIX_WHITELIST[@]}"; do
    raw="$(printf '%s\n' "$raw" | grep -v "^${wl}" || true)"
  done
  # This test file names the marker in prose; it is not a table row (and is .sh, so
  # --include already excludes it). Belt and braces for a future .md rename.
  printf '%s\n' "$raw" | grep -v '^tests/unit/vocabulary-audit' || true
}
it "every <!--legacy--> read-compat row still names the RETIRED key (not a tautology)"
legacy_bad=""
# (Scenario 1c, below, proves the other half: that nothing OUTSIDE a table row can
# claim the exemption in the first place. 1b polices what is exempt; 1c polices what
# is exemptible. Neither is sufficient alone.)
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
  # heads the U8 tier-dir map; `identifier` heads the U9 code map (the run-record
  # rename touched no persisted key, so its legacy table maps SYMBOLS, not keys —
  # but it claims the same `<!--legacy-->` exemption, so it gets the same policing).
  # U10 adds the two tables the WIDENED scan brought in scope: `retired identifier`
  # heads the historical-mapping tables in CONCEPTS.md + README.md, and
  # `deprecated surface` heads the removal ledger in docs/deprecations.md.
  case "$n1" in
    "legacy (v1) key"|"legacy (v1) location"|"legacy (v1) identifier") continue ;;
    "retired identifier"|"deprecated surface") continue ;;
  esac
  # (a) the v1 cell must name a retired identifier.
  #
  # NB the set here is the 8 AUDITED terms PLUS `content` — and the difference is the
  # point. `content` → `preset` is a genuine retired identifier (it shipped, and a
  # historical-mapping table owes the reader the row), but it is deliberately NOT an
  # audited TERM: "content" is ordinary English (`content-type`, "the content of the
  # plan"), so policing it word-boundary-wide across lib/ + docs/ would false-positive
  # everywhere and the whitelist needed to silence that would swallow the tree. So it
  # is documented but not swept — and a row naming it is legitimately legacy.
  # This list is about which rows may CLAIM the exemption; it can never weaken the
  # main audit, which is driven by TERM_STATUS alone.
  if ! printf '%s' "$n1" \
       | grep -qiE '(\b|_)(orchestrator|emitter|adapter|tick|seam|unit|recipe|ledger|content)'; then
    legacy_bad="${legacy_bad}
    ${file}:${lineno}: legacy row's v1 cell names NO retired term: '${n1}'"
  fi
  # (b) a legacy row that maps a name to ITSELF has lost the old spelling
  if [ "$n1" = "$n2" ]; then
    legacy_bad="${legacy_bad}
    ${file}:${lineno}: legacy row is a TAUTOLOGY ('${n1}' → '${n2}') — the v1 column was overwritten with the v2 name"
  fi
done <<< "$(legacy_rows)"
if [ -z "$legacy_bad" ]; then
  pass
else
  fail "the <!--legacy--> exemption is being claimed by rows that are not legacy:${legacy_bad}"
fi

# ─── Scenario 1c: `<!--legacy-->` cannot be smuggled onto a NON-ROW line ────
# The exemption is the audit's ONLY invisible opt-out — the marker renders as nothing,
# so a line carrying it looks clean to a human reviewer. Before U10 it was a whole-line
# drop in any file of any shape, which made it a silent kill switch: append it to a
# stale line and the permanent guard looks away. That is the single most dangerous thing
# in this file, and it must be pinned by a control, not by a comment.
#
# Four plants, each a REAL smuggling attempt with a genuinely stale identifier:
#   1. prose (not a table row) in a scanned .md          → must FAIL the audit
#   2. a Python comment in lib/                          → must FAIL
#   3. a table-shaped row in a .py file (shape alone is not enough) → must FAIL
#   4. a real markdown table row                         → must be EXEMPT (the one
#      legitimate shape — and Scenario 1b then polices its content, row by row)
sm_tmp="$(mktemp -d)"
trap 'rm -rf "$sm_tmp"' EXIT
mkdir -p "$sm_tmp/lib" "$sm_tmp/docs"

printf 'Run `ledger.py add-unit` on the recipe adapter at the seam. <!--legacy-->\n' \
  > "$sm_tmp/docs/smuggle-prose.md"
printf '_recipe = load_lib_module("recipes")  # <!--legacy-->\n' \
  > "$sm_tmp/lib/smuggle_comment.py"
printf '# | `units` | `steps` | <!--legacy--> |\n' \
  > "$sm_tmp/lib/smuggle_fakerow.py"
printf '| `units` | `steps` | run-record top-level | <!--legacy--> |\n' \
  > "$sm_tmp/docs/legit-table.md"

it "a <!--legacy--> marker on a NON-ROW line does NOT exempt it (prose, code comment, fake row)"
smuggle_bad=""
for _probe in docs/smuggle-prose.md lib/smuggle_comment.py lib/smuggle_fakerow.py; do
  _caught=""
  for _t in recipe unit ledger adapter seam; do
    if printf '%s\n' "$(audit_term_hits "$_t" "$sm_tmp")" | grep -F "${_probe}:" >/dev/null; then
      _caught="yes"
      break
    fi
  done
  [ -n "$_caught" ] || smuggle_bad="${smuggle_bad}
    ${_probe}: SMUGGLED THROUGH — a stale identifier hid behind <!--legacy-->"
done
# …while the legitimate markdown table row IS still exempt (or every contract's
# read-compat appendix fails the audit for doing its job).
for _t in unit; do
  if printf '%s\n' "$(audit_term_hits "$_t" "$sm_tmp")" | grep -F 'docs/legit-table.md:' >/dev/null; then
    smuggle_bad="${smuggle_bad}
    docs/legit-table.md: a REAL read-compat table row lost its exemption"
  fi
done
if [ -z "$smuggle_bad" ]; then
  pass
else
  fail "the <!--legacy--> exemption is a smuggling channel:${smuggle_bad}"
fi

rm -rf "$sm_tmp"; trap - EXIT

# ─── Scenario 2: deliberate-fail control — a PLANTED stale identifier trips the audit ──
# U9 RE-GROUNDED THIS CONTROL. Every term is now `done` (`ledger` was the last), so the
# old shape — "audit a term that is still PENDING and watch its old identifier light up
# the tree" — has no term left to point at. That is precisely the moment a green
# Scenario 1 becomes worthless: a broken grep, a regex that stopped matching, a
# whitelist that swallowed the whole tree, a typo'd SCAN_ROOTS — every one of those
# failure modes reports "no stale identifiers found" and looks EXACTLY like success.
# An audit with nothing left to catch must prove it can still catch.
#
# So the control moves from a pending TERM to a synthetic TREE. For each of the 8
# retired terms we PLANT a file that reintroduces that term's old identifier, then run
# the REAL audit pipeline over it — same regex_for_term, same whitelists, same awk
# scrubs (audit_term_hits takes the root as a parameter precisely so the control cannot
# drift into testing a reimplementation). Each term MUST produce hits that NAME the
# planted file. Runs on every invocation; proves the harness is live for all 8 terms,
# not just whichever one happened to be pending.
#
# Scenario 2b then proves the filter DISCRIMINATES: the same stale content, planted at
# a WHITELISTED path, must produce NO hits. Without 2b, an audit that simply failed on
# everything would sail through 2a.
df_tmp="$(mktemp -d)"
trap 'rm -rf "$df_tmp"' EXIT
mkdir -p "$df_tmp/lib"

# One plant per retired term, shaped like real CODE (a symbol, not prose) — a stale
# identifier is how a term actually comes back. Includes the leading-underscore form,
# the class regex_for_term's `_` alternative exists to catch (U6 hardening).
# Deliberately placed in lib/ under a name no whitelist entry is a substring of.
DF_PLANTS=(
  'orchestrator:orch = load_lib_module("orchestrator")  # _orchestrator_for'
  'emitter:_maybe_emitter = rec["phase_transitions"][0]["emitter"]'
  'adapter:from adapter_ops import VALID_ADAPTER_OPS  # adapter_scale'
  'tick:TICK_COMMAND = "/auto:auto-tick"  # tick_advance'
  'seam:_try_seam_pause(run, seam_paused=True)  # phase == "seam"'
  'unit:add_unit(run, unit_id, enumerated_units=[])'
  'recipe:raise RecipeError("bad recipe")  # recipe_validate'
  'ledger:led = ledger.read_ledger(repo, run)  # _with_locked_ledger'
)
for _plant in "${DF_PLANTS[@]}"; do
  _term="${_plant%%:*}"
  printf '%s\n' "${_plant#*:}" > "$df_tmp/lib/df_probe_${_term}.py"
done

df_bad=""
for _plant in "${DF_PLANTS[@]}"; do
  _term="${_plant%%:*}"
  _hits="$(audit_term_hits "$_term" "$df_tmp")"
  # Must NAME the planted file in `path:lineno:content` shape — not merely be
  # non-empty. NB no `grep -q`: an early exit SIGPIPEs the upstream `printf`, which
  # `set -o pipefail` reports as a pipeline failure. Read all input.
  if ! printf '%s\n' "$_hits" \
       | grep -E "^lib/df_probe_${_term}\.py:[0-9]+:" >/dev/null; then
    df_bad="${df_bad}
    [${_term}] the audit did NOT catch a planted stale identifier (hits: ${_hits:-<none>})"
  fi
done

it "deliberate-fail: a planted stale identifier trips the audit for EVERY retired term"
if [ -z "$df_bad" ]; then
  pass
else
  fail "the audit is VACUOUS — it no longer catches a reintroduced old identifier:${df_bad}"
fi

# ─── Scenario 2b: the whitelist still DISCRIMINATES (2a is not "everything fails") ──
# Plant the SAME stale `ledger` content at two WHITELISTED paths — `lib/format_compat.py`
# (the permanent both-vocabularies module) and `lib/ledger.py` (the KTD-4 re-export
# shim). The audit must report NOTHING for them while STILL reporting the unwhitelisted
# probe from 2a. If this ever fails, the path whitelist has stopped applying — and every
# stub/shim in the tree is about to fail the audit for doing its job.
printf 'led = ledger.read_ledger(repo, run)  # _with_locked_ledger\n' \
  > "$df_tmp/lib/format_compat.py"
printf 'ledger_path = _rr.run_record_path  # LedgerError = _rr.RunRecordError\n' \
  > "$df_tmp/lib/ledger.py"

it "the path whitelist still exempts the shim/stub paths (the audit discriminates)"
wl_hits="$(audit_term_hits ledger "$df_tmp")"
wl_bad=""
printf '%s\n' "$wl_hits" | grep -E '^lib/(format_compat|ledger)\.py:' >/dev/null \
  && wl_bad="the whitelist did NOT exempt lib/format_compat.py / lib/ledger.py"
printf '%s\n' "$wl_hits" | grep -E '^lib/df_probe_ledger\.py:' >/dev/null \
  || wl_bad="${wl_bad:+$wl_bad; }the un-whitelisted probe stopped being reported"
if [ -z "$wl_bad" ]; then
  pass
else
  fail "$wl_bad (hits: ${wl_hits:-<none>})"
fi

# ─── Scenario 2c: the WIDENED scan actually BITES (U10) ─────────────────────
# Scenarios 2a/2b prove the audit still catches a stale identifier IN lib/ — the tree
# it has policed since U1. They say NOTHING about the trees U10 added, and a one-token
# typo in SCAN_ROOTS (`README.MD`, a dropped `.claude-plugin`, `doc` for `docs`) would
# silently un-police exactly the surface the widening exists to cover — reporting
# 8/8 green, indistinguishable from success. That is the failure mode that let the
# SHIPPED PLUGIN MANIFEST advertise "Ships named recipes" through nine green units.
#
# So: plant a stale identifier in EACH newly-in-scope surface and require the real
# audit pipeline (same audit_term_hits, same whitelists) to name the planted file.
#
# And the INVERSE, which is the other half of a deliberate decision: a plant in
# `docs/plans/` must NOT be reported. The archive exclusion is a CHOICE (see the
# prefix whitelist), so it gets a test — otherwise "we meant to exclude it" and "we
# forgot to include it" look identical from the outside.
mkdir -p "$df_tmp/docs" "$df_tmp/docs/plans" "$df_tmp/.claude-plugin"

# term:relpath:content — one per newly-in-scope root.
DF_WIDE=(
  'adapter:README.md:The engine is workflow-blind: it drives any workflow through a thin adapter.'
  'tick:CONCEPTS.md:| one advance of the loop | **pulse** | each tick advances the run one beat. |'
  'recipe:.claude-plugin/plugin.json:  "description": "Ships named recipes (A1, A2, A4, W)",'
  'seam:docs/handoff.md:The plan-loop pauses at the seam before the work-loop starts.'
  'emitter:docs/planning-readiness.md:Register a new emitter in `lib/emitters.py` (`V1_EMITTER_NAMES`).'
)
for _p in "${DF_WIDE[@]}"; do
  _t="${_p%%:*}"; _rest="${_p#*:}"
  _rel="${_rest%%:*}"; _body="${_rest#*:}"
  printf '%s\n' "$_body" > "$df_tmp/$_rel"
done

wide_bad=""
for _p in "${DF_WIDE[@]}"; do
  _t="${_p%%:*}"; _rest="${_p#*:}"; _rel="${_rest%%:*}"
  _h="$(audit_term_hits "$_t" "$df_tmp")"
  # NB fgrep on the literal path prefix: `.claude-plugin/plugin.json` and `README.md`
  # carry regex metacharacters.
  if ! printf '%s\n' "$_h" | grep -F "${_rel}:" >/dev/null; then
    wide_bad="${wide_bad}
    [${_t}] SCAN_ROOTS does not reach ${_rel} — a stale identifier there is invisible"
  fi
done

it "the WIDENED scan bites: a stale identifier in README/CONCEPTS/.claude-plugin/docs is caught"
if [ -z "$wide_bad" ]; then
  pass
else
  fail "the audit is BLIND to a surface it claims to police:${wide_bad}"
fi

# The archive exclusion, asserted as a decision rather than assumed as a side effect.
printf 'The a1 recipe emits work units at the seam; the ledger is the source of truth.\n' \
  > "$df_tmp/docs/plans/2026-01-01-001-historical-plan.md"
it "historical docs/plans/ are DELIBERATELY exempt (dated artifacts, not live surface)"
plans_bad=""
for _t in recipe unit seam ledger; do
  if printf '%s\n' "$(audit_term_hits "$_t" "$df_tmp")" \
     | grep -F 'docs/plans/2026-01-01-001-historical-plan.md:' >/dev/null; then
    plans_bad="${plans_bad} ${_t}"
  fi
done
if [ -z "$plans_bad" ]; then
  pass
else
  fail "docs/plans/ is being audited — the historical-archive exemption broke (terms:${plans_bad})"
fi

rm -rf "$df_tmp"; trap - EXIT

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
