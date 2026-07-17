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
#
# ⚠ THE OTHER RESIDUAL — A `<!--legacy-->` ROW'S COLUMNS 3+ (F3). Name it precisely,
# because "the legacy rows are policed" is only two-thirds true:
#     | <retired name> | <replacement> | <free text> | <free text> | <!--legacy--> |
#       └── 1b checks ─┴───────────────┘ └────────── EXEMPT, UNPOLICED ───────────┘
#   Scenario 1b checks cells 1 and 2 (names a retired term; is not a tautology). It
#   checks NOTHING from cell 3 on, and it CANNOT: a real row's free-text columns
#   legitimately carry retired identifiers — docs/deprecations.md has to be able to say
#   "`.claude/auto/recipes/` tier dirs … read-only legacy tiers in `lib/workflows.py`".
#   There is no predicate that separates that from a stale identifier someone parked in
#   a table row. So the residual is, exactly: *inside a genuine, 1b-verified read-compat
#   row in a scanned .md file, any retired identifier from column 3 onward is invisible
#   to this audit.* It is bounded to that shape (1c proves nothing outside it can claim
#   the exemption) and to those few files. It is a BY-DESIGN residual, not a gap to fix
#   — but when you sweep, EYEBALL those columns too.

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


# ════════════════════════════════════════════════════════════════════════════
# THE EXEMPTION MACHINERY — and the ONE defect class this file keeps re-growing.
# ════════════════════════════════════════════════════════════════════════════
# FOUR TIMES an exemption in this file has turned out to be an UNBOUNDED or
# UNANCHORED opt-out from the permanent guard, each found only by review:
#
#   1. `grep -vF -- '<!--legacy-->'`   — a WHOLE-LINE drop, any file, any shape.
#                                        Append the marker to a stale line → GREEN.
#   2. `\([Ff]ormerly [^)]*\)`         — `[^)]*` runs to the next `)`, arbitrarily
#                                        far, taking real stale identifiers with it.
#   3. `grep -vF "${wl}:"`             — the PATH whitelist as a fixed-string match
#                                        ANYWHERE in the `path:lineno:content` hit.
#                                        So merely CITING a whitelisted path in a
#                                        line's CONTENT exempted the whole line, in
#                                        any scanned file:
#                                          lib/evil.py: led = ledger.read(x)  # see lib/ledger.py: the shim
#                                        → zero hits for `ledger`. Reachable BY
#                                        ACCIDENT — "see `lib/ledger.py`: …" is
#                                        natural prose, and each whitelist entry
#                                        minted a fresh trigger.
#   4. `gsub(/supersedes …/)`          — the KTD-5 re-lock banner scrub applied in
#                                        EVERY scanned file, so
#                                          "This module supersedes ledger.py entirely."
#                                        in any doc was fully exempt.
#
# And a FIFTH, found while fixing 3+4: the `tick` branch's
# `grep -vE '^(three test paths):[0-9]+:.*(auto-tick|tick\.sh)'` was a WHOLE-LINE
# drop too — path- and content-anchored, but still dropping the entire line, so a
# stale `tick` identifier sharing a line with `auto-tick` rode through.
#
# Patching them one at a time has failed five times. So the SHAPE is now fixed by
# construction, and the class is fenced by a control (Scenario 0):
#
#   KIND (1) PATH        — a whole file legitimately speaks the old vocabulary.
#                          Matched ANCHORED against the hit's `path:lineno:` prefix,
#                          with the path REGEX-ESCAPED. It can only ever match a
#                          leading path, never content.
#   KIND (2) PATH-PREFIX — a whole directory. Same anchoring, same escaping.
#   KIND (3) TOKEN SCRUB — a BOUNDED token, declared in the SCRUBS table, bound to
#                          the PATHS where it legitimately lives. NEVER a line drop:
#                          the token is cut out of a COPY of the line, and the line
#                          survives if any stale identifier survives the cut.
#   KIND (4) `<!--legacy-->` MARKDOWN TABLE ROW — the ONLY line drop in this file.
#                          Bound to a shape (a `|`-row in a `.md` file), policed
#                          row-by-row by Scenario 1b, fenced by Scenario 1c.
#
# There is no fifth kind, and adding one is what Scenario 0a fails on.
#
# ⚠ THE RESIDUAL, NAMED PRECISELY (F3 — by design, not an oversight).
# A `<!--legacy-->` row's columns 3+ (its free-text "what it forwards to" / "what
# removing it breaks" prose) are exempt and UNPOLICED. 1b checks only cells 1 and 2
# — the retired name and its replacement — because there is no checkable predicate
# for the rest: a real row's prose LEGITIMATELY carries retired identifiers
# (`docs/deprecations.md` must be able to say "`.claude/auto/recipes/` tier dirs …
# read-only legacy tiers in `lib/workflows.py::_tier_dirs`"). The residual is
# therefore: *inside a genuine, 1b-verified read-compat table row in a scanned .md
# file, any retired identifier from column 3 onward is invisible to this audit.* It
# is bounded to that shape and to those files, and 1c proves nothing outside the
# shape can reach it. When you sweep, EYEBALL those columns.

# ─── SELF (F8: derive the summary probe from this file, never a hand-copy) ───
SELF="${BASH_SOURCE[0]}"

# re_escape <literal> → the same string, safe to paste into an ERE.
# A whitelist entry is a PATH, not a pattern: `lib/ledger.py` used raw as an ERE has
# a `.` that matches ANY character, so `lib/ledgerZpy` would be exempt too. Escape
# everything that is not `[A-Za-z0-9_/-]` (each of which is literal in an ERE), so a
# path can only ever match itself.
re_escape() { printf '%s' "$1" | sed 's|[^A-Za-z0-9_/-]|\\&|g'; }

# Both path filters are compiled ONCE, here, into a single anchored alternation —
# `^(a|b|c):[0-9]+:` and `^(dir/|dir/)`. audit_term_hits is called ~50 times per run;
# escaping and grepping 17 entries separately on each call cost more in process spawns
# than the whole audit does in work.
_wl_alt=""
for _wl in "${GLOBAL_PATH_WHITELIST[@]}"; do
  _wl_alt="${_wl_alt}${_wl_alt:+|}$(re_escape "$_wl")"
done
WHITELIST_RE="^(${_wl_alt}):[0-9]+:"

_pfx_alt=""
for _wl in "${GLOBAL_PATH_PREFIX_WHITELIST[@]}"; do
  _pfx_alt="${_pfx_alt}${_pfx_alt:+|}$(re_escape "$_wl")"
done
PREFIX_RE="^(${_pfx_alt})"

# ─── THE SCRUBS TABLE — the ONLY place a token exemption may be declared ─────
# `%%`-separated fields. Applied IN ORDER (one row can set up the next).
#
#   term   the audited term this row applies to, or `*` for every term
#   path   an ERE for the hit's PATH. MUST be `^…$`-anchored, or the literal `*`
#          for "any file" — which is legal ONLY for a token that is genuinely
#          tree-wide noise, and whose boundedness Scenario 0b then probes
#   token  an ERE for the BOUNDED token to cut out of a COPY of the line
#   repl   what to leave behind. A placeholder for a scrub; ` unit ` for the one
#          NORMALIZE-TO-KEEP row, which turns a real symbol back INTO a hit
#   probe  a LITERAL example of `token` as it really appears in the tree. Scenario
#          0b plants it — unexempted, beside a stale identifier — and requires the
#          audit to still fire. A row with no honest literal example is a row that
#          should not exist
#   why    one line
#
# The engine never sees a regex it did not get from this table, and the table can
# express nothing but a bounded token cut. That is what "bounded by construction"
# means here — not a comment promising it.
# <<<SCRUBS-TABLE (0a lints CODE; the table itself is validated by 0a-2 + 0b)
SCRUBS=(
  # ── every term ──
  '*%%^(docs/contracts/backend-contract\.md|docs/contracts/run-record-schema\.md|docs/contracts/workflow-format\.md)$%%supersedes[:,]?[ ]+`?[A-Za-z0-9_./-]+`?([ ]+\(?v?[0-9][A-Za-z0-9_.-]*\)?)?%%@SUPERSEDES@%%supersedes `ledger-schema.md`%%KTD-5 contract re-lock banner. F4: this was applied TREE-WIDE, so `This module supersedes ledger.py entirely.` in any doc was exempt. The banners live only in the contract headers — bind it there.'
  '*%%^(skills/auto-author-workflow/SKILL\.md|skills/auto-backend/SKILL\.md)$%%\([Ff]ormerly `?[A-Za-z0-9_./-]+`?\)%%@FORMERLY@%%(formerly auto-adapter)%%KTD-4 skill breadcrumb, kept so model-side triggering still matches the old phrasing. Lives only in the two renamed skills descriptions.'

  # ── unit: the term entangled with unavoidable non-renamed noise ──
  'unit%%*%%tests\/unit%%@TIER@%%tests/unit%%the tests/unit TEST-TIER path — keyed to the suite layout, not the renamed concept. Appears as the path of a hit AND as a cross-reference in lib/ and docs/ prose, so it is genuinely tree-wide.'
  'unit%%*%%[-_A-Za-z0-9][Uu]nit[ -][Tt]est[A-Za-z]*%% unit %%add-unit test-run%%NORMALIZE-TO-KEEP, not a scrub. An `unit test` ATTACHED to an identifier char is a REAL symbol (`add-unit test-run`, `add_unit test_id`), not prose — turn it back into a bare token so it still HITS. MUST precede the prose row below.'
  'unit%%*%%[Uu]nit[ -][Tt]est[A-Za-z]*%%@UT@%%unit test%%the free-standing prose "unit test" / "unit-testable" (the hyphenated adjective lives in lib/iteration.py, lib/verification.py, lib/goal-route.py).'
  'unit%%*%%UNIT[ -]TEST[A-Z]*%%@UT@%%UNIT TEST%%the shouted prose form of the same.'
  'unit%%*%%plan_step%%@PLANSTEP@%%plan_step%%the plan-phase sub-state — a deliberate do-not-rename carve-out (Key Decisions / CONCEPTS.md). Carries no `unit` token, so it cannot trip the regex; scrubbed defensively so a future `plan_unit`-shaped revival cannot hide behind it.'
  'unit%%*%%PLAN_STEPS%%@PLANSTEP@%%PLAN_STEPS%%same carve-out, shouted.'
  'unit%%*%%next_plan_step%%@PLANSTEP@%%next_plan_step%%same carve-out.'
  'unit%%^tests/run\.sh$%%unit_files%%@TIER@_files%%unit_files%%tests/run.sh is the ONE file where the test-suite TIER name is a code identifier. That `unit` is the tests/unit/ tier, not a workflow step; renaming it would break `bash tests/run.sh unit` for every caller. Scrub the TOKENS — never drop the file, or run.sh becomes the file-level blind spot this branch exists to eliminate.'
  'unit%%^tests/run\.sh$%%unit\|integration%%@TIER@|integration%%unit|integration%%same: the tier list in the usage string.'
  'unit%%^tests/run\.sh$%%= "unit"%%= "@TIER@"%%= "unit"%%same: the tier assignment.'
  'unit%%^tests/run\.sh$%%=== UNIT %%=== @TIER@ %%=== UNIT %%same: the section banner.'
  'unit%%^tests/run\.sh$%% unit \+%% @TIER@ +%% unit +%%same: the tier tally.'
  'unit%%^tests/run\.sh$%% unit  %% @TIER@  %% unit  %%same: the tier tally.'
  'unit%%^lib/run_record\.py$%%set-enumerated-units%%@ALIAS@%%set-enumerated-units%%F(B) KTD-4 REVISITED: the retired work-node verbs now have DEPRECATED ALIASES (the `_DEPRECATED_VERBS` map), because pre-rename tick_guidance emitted guidance naming them and an agent mid-run across the upgrade would hit exit 2. The map must SPELL the retired verb. Only the two verb TOKENS are exempt — any other stale `unit` in run_record.py still fails.'
  'unit%%^lib/run_record\.py$%%add-unit%%@ALIAS@%%add-unit%%same map, the other verb.'
  'unit%%^tests/unit/run-record-cli-feedback\.test\.sh$%%set-enumerated-units%%@ALIAS@%%set-enumerated-units%%the test that PINS the alias must NAME the retired verb to invoke it. Only that token, only in that file.'
  'unit%%^tests/unit/run-record-cli-feedback\.test\.sh$%%add-unit%%@ALIAS@%%add-unit%%same.'

  # ── seam ──
  'seam%%^docs/deprecations\.md$%%seam_paused%%@V1KEY@%%seam_paused%%docs/deprecations.md is the retired-surface REGISTRY: the mixed-fleet section has to NAME the v1 pause key to explain what a concurrent old-plugin write loses. Only that one KEY token, only in that one doc — any other stale `seam` there still FAILS, and the token is bounded, so a stale identifier sharing the line cannot ride through.'
  'seam%%^(lib/auto\.py|tests/unit/handoff-default\.test\.sh)$%%\.seam-default-acknowledged%%@LEGACYMARKER@%%.seam-default-acknowledged%%F(C): the pre-rename ACK-MARKER FILENAME. It is USER STATE on disk, not a code identifier — sweeping it silently un-acked every existing user and re-fired the one-time v0.4.0 notice at someone who dismissed it a version ago. lib/auto.py must still READ it (it never writes it), and the test that pins that must NAME it. Only that one filename token; any other stale `seam` in either file still FAILS.'

  # ── adapter ──
  'adapter%%^(lib/auto\.py|tests/unit/flag-aliases\.test\.sh)$%%--adapter%%@ALIAS@%%--adapter%%the KTD-4 flag-alias layer (`_DEPRECATED_FLAGS`) and the test that pins it. Only the retired FLAG token — a stale `adapter` IDENTIFIER in either file (an `adapter_ops` import, an `ExitReason.ADAPTER_BUG`) still FAILS. Drop with the alias next minor.'

  # ── recipe ──
  'recipe%%^(lib/auto\.py|commands/auto\.md|tests/unit/flag-aliases\.test\.sh)$%%--teardown-recipe-after-init%%@ALIAS@%%--teardown-recipe-after-init%%the KTD-4 flag-alias layer, its routing branch in commands/auto.md (which must MATCH the retired spelling or the alias never reaches the parser), and the test that pins it.'
  'recipe%%^(lib/auto\.py|commands/auto\.md|tests/unit/flag-aliases\.test\.sh)$%%--recipe%%@ALIAS@%%--recipe%%same alias layer, the other flag. Listed AFTER the longer spelling so it cannot eat its prefix.'
  'recipe%%^tests/integration/workflow-picker\.test\.sh$%%recipes-list\.sh%%@STUB@%%recipes-list.sh%%the KTD-4 forwarding stub lib/recipes-list.sh is path-whitelisted (so the audit structurally cannot fail ON it, and nothing would notice if it broke); this test pins that it still forwards, and must NAME the retired path to do so.'
  'recipe%%^lib/workflows\.py$%%_LEGACY_TIER_DIRNAME%%@LEGACYDIR@%%_LEGACY_TIER_DIRNAME%%KTD-7 the LEGACY TIER DIR: `_tier_dirs` appends the pre-rename user dirs as READ-ONLY legacy tiers so a users existing files still resolve. A legacy fallback that does not name the legacy dir is not a fallback.'
  'recipe%%^lib/workflows\.py$%%\.claude/auto/recipes%%.claude/auto/@LEGACYDIR@%%.claude/auto/recipes%%same: the retired dir literal.'
  'recipe%%^lib/workflows\.py$%%"recipes"%%"@LEGACYDIR@"%%"recipes"%%same: the constant that holds it.'
  'recipe%%^(lib/upstream-cluster\.py|tests/integration/spine-forward\.test\.sh|docs/planning-readiness\.md)$%%feedback_a1_recipe_cant_rebound_to_brainstorm%%@MEMORY_ID@%%feedback_a1_recipe_cant_rebound_to_brainstorm%%an EXTERNAL artifacts NAME — the memory cited as the provenance of the role-diversity weighting (KTD-6). Rewriting the citation to spell `workflow` would point at nothing. Was tree-wide; now bound to the two files that cite it.'

  # ── tick ──
  'tick%%^(tests/unit/rearm-command-exists\.test\.sh|tests/smoke/scaffold\.test\.sh|tests/integration/pulse-alias-inflight\.test\.sh)$%%auto-tick%%@ALIAS@%%auto-tick%%KTD-4: the kept alias command commands/auto-tick.md is path-whitelisted, but the tests that PIN it must NAME it. Was a WHOLE-LINE grep -v drop (the fifth instance of the unbounded-exemption class); now a bounded token scrub, so any OTHER stale `tick` on those lines still fails.'
  'tick%%^(tests/unit/rearm-command-exists\.test\.sh|tests/smoke/scaffold\.test\.sh|tests/integration/pulse-alias-inflight\.test\.sh)$%%tick\.sh%%@STUB@%%tick.sh%%same, for the kept forwarding stub lib/tick.sh.'
)
# SCRUBS-TABLE>>>
# NB: there is deliberately NO `emitter`, `seam`, `ledger` or `orchestrator` row.
# Every file that legitimately spells those retired surfaces is PATH-whitelisted
# above (the KTD-4 stubs and the tests whose job is to prove they still resolve).
# Nothing else in the tree may name them, so there is no token to scrub. An
# empty-but-present exemption is worse than none: it is a standing invitation.

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
# hides longest. Adding the `_` alternative closes that blind spot for every term.
regex_for_term() { printf '(\\b|_)%s' "$1"; }

# term_status <term> → prints `pending` or `done` from the table.
term_status() {
  printf '%s\n' "$TERM_STATUS" | sed -n "s/^$1=//p"
}

# audit_term_hits <term> [root] → prints the filtered (non-whitelisted) grep hits
# for the term's OLD identifier, one `path:lineno:content` per line. Empty output
# means the term is clean. Ignores the status table — the caller decides whether to
# run it (so the deliberate-fail controls can force a term).
#
# [root] defaults to the real tree. The controls pass a SYNTHETIC tree instead —
# every filter below is keyed on the RELATIVE `path:lineno:` prefix of a hit, so the
# exact same pipeline applies to either root. That is the point: a control must
# exercise the REAL filters, not a reimplementation of them, or it proves nothing
# about the audit that ships.
# <<<AUDIT-PIPELINE (Scenario 0a lints everything between these two markers)
# The region is delimited by MARKERS, not by brace-matching. That is deliberate: an
# earlier version of 0a extracted this body with awk `on && /^\}/ {exit}` — "stop at the
# first `}` at column 0" — and a skeptic blinded the whole lint with a two-line gadget:
#     local _note='
# }
# '
# The `}` inside a quoted string ended the extraction, so every filter AFTER it was
# unlinted, and a verbatim reintroduction of defect #1 (an unbounded whole-line
# `grep -vF` drop) went GREEN. Nothing about that was a policy failure — the allowlist
# was right; it simply never saw the line. A lint that can be truncated by its own input
# is not a control. Markers cannot be truncated by a brace, and the anti-vacuity check in
# 0a requires the region's LAST filter (the final sink) to be present — so closing the
# marker early, or opening it late, fails loudly instead of silently shrinking the scan.
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

  # ── KIND (1): global path whitelist — ANCHORED, ESCAPED (F1) ──
  # `^(<escaped-path>|…):<lineno>:` — it can match only the leading `path:lineno:` of a
  # hit, never its content. The old `grep -vF "${wl}:"` was a fixed-string match
  # ANYWHERE in the hit, so a line whose CONTENT cited a whitelisted path exempted
  # itself, in any scanned file. Escaping matters too: an unescaped `.` in
  # `lib/ledger.py` is an ERE wildcard that also matches `lib/ledgerZpy`.
  raw="$(printf '%s\n' "$raw" | grep -vE "$WHITELIST_RE" || true)"
  [ -z "$raw" ] && return 0

  # ── KIND (2): global path-PREFIX whitelist — ANCHORED, ESCAPED ──
  # Anchored at the start of the hit so it can only ever exempt a leading directory,
  # never a substring match mid-content.
  raw="$(printf '%s\n' "$raw" | grep -vE "$PREFIX_RE" || true)"
  [ -z "$raw" ] && return 0

  # ── KIND (4): the `<!--legacy-->` markdown TABLE ROW — the ONE line drop ──
  # <<<LEGACY-ROW-EXEMPTION (Scenario 0a fences this region)
  # A read-compat row's job is to name retired keys across its full width, so there
  # is nothing to scrub — the row is dropped WHOLESALE. That is only safe because the
  # exemption is earned by SHAPE (a `|`-row in a `.md` file) and then POLICED: 1b
  # checks every such row still names a retired term and is not a tautology; 1c proves
  # nothing outside the shape can claim it. The marker alone exempts NOTHING — a
  # `<!--legacy-->` on a prose line, a code comment, or anything in a .py/.sh/.json
  # file is audited normally.
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
          if (path ~ /\.md$/ && substr(content, 1, 1) == "|") next
        }
      }
      print
    }' || true)"
  [ -z "$raw" ] && return 0
  # LEGACY-ROW-EXEMPTION>>>

  # ── KIND (3): TOKEN SCRUBS, driven entirely by the SCRUBS table ──
  # <<<SCRUB-ENGINE (Scenario 0a fences this region)
  # ONE awk pass, table-driven. The rows applicable to this term are fed in ahead of
  # the hits (separated by a sentinel) so their `token` / `repl` reach awk as DATA —
  # no shell-quoting of regexes into awk source, and no way to express anything but
  # "cut this bounded token, on these paths".
  #
  # A line SURVIVES the scrub if a stale identifier survives the cut. Nothing here can
  # drop a line: `print $0` prints the RAW line, and the scrubbed copy `p` is used only
  # to decide.
  #
  # NB one awk pass, not a per-line sed|grep loop: a control audits a term whose old
  # identifier is planted across a whole synthetic tree, and spawning two processes per
  # hit took this audit from 1.3s to 19s.
  #
  # `(^|[^a-z0-9])<term>` on a lower-cased copy is exactly `regex_for_term`'s
  # `(\b|_)<term>` -i: `_` is not alphanumeric, so the one class covers both the
  # word-boundary and the leading-underscore alternative.
  #
  # KNOWN RESIDUAL — a SUPERSTRING of a scrubbed token (skeptic-surfaced, and NOT the
  # F1/F4 class). A scrub cuts its token as a SUBSTRING, so a future identifier that has a
  # scrubbed token as a PREFIX loses its term along with the token: `seam_paused_at` →
  # `@V1KEY@_at` no longer contains `seam`; `add-unit-v2` → `@ALIAS@-v2` no longer
  # contains `unit`. Such an identifier would be exempted. This is bounded three ways,
  # which is why it is a documented residual rather than a hole chased with a lookahead
  # this awk has no portable way to spell: (1) it is scoped to each row's few DECLARED
  # files — the same stale superstring anywhere ELSE still fails; (2) it needs a NEW
  # identifier that is a literal extension of a retired v1 token, in the one file whose
  # job is to name that token — an unlikely shape; (3) the scrub is still BOUNDED — it
  # cuts its token and no more, which is the property F1/F4 were actually about. When you
  # add a row, prefer a token that is already a WHOLE identifier (`seam_paused`, not
  # `seam`), which is what keeps this surface as small as it is.
  local rows="" SEP='%%'
  local row r_term r_path r_tok r_repl rest
  for row in "${SCRUBS[@]}"; do
    r_term="${row%%$SEP*}";  rest="${row#*$SEP}"
    r_path="${rest%%$SEP*}"; rest="${rest#*$SEP}"
    r_tok="${rest%%$SEP*}";  rest="${rest#*$SEP}"
    r_repl="${rest%%$SEP*}"
    [ "$r_term" = "*" ] || [ "$r_term" = "$term" ] || continue
    # `*` (any file) becomes the always-true path regex; every other row is ^…$-anchored
    # in the table itself, and Scenario 0a fails the build if one is not.
    [ "$r_path" = "*" ] && r_path='.'
    rows="${rows}${r_path}"$'\t'"${r_tok}"$'\t'"${r_repl}"$'\n'
  done
  if [ -n "$rows" ]; then
    raw="$(printf '%s@@SCRUB-TABLE-ENDS@@\n%s\n' "$rows" "$raw" | awk -v term="$term" '
      !seen_hits && $0 == "@@SCRUB-TABLE-ENDS@@" { seen_hits = 1; next }
      !seen_hits {
        n++
        i = index($0, "\t");            PATHRE[n] = substr($0, 1, i - 1)
        r = substr($0, i + 1)
        j = index(r, "\t");             TOK[n]    = substr(r, 1, j - 1)
        REPL[n] = substr(r, j + 1)
        next
      }
      {
        colon = index($0, ":")
        path  = (colon > 0) ? substr($0, 1, colon - 1) : $0
        p = $0
        for (k = 1; k <= n; k++) {
          if (path ~ PATHRE[k]) gsub(TOK[k], REPL[k], p)
        }
        if (tolower(p) ~ "(^|[^a-z0-9])" tolower(term)) print $0
      }' || true)"
  fi
  # SCRUB-ENGINE>>>

  [ -z "$raw" ] && return 0
  printf '%s\n' "$raw"
}
# AUDIT-PIPELINE>>>

# ════════════════════════════════════════════════════════════════════════════
# Scenario 0 — THE CLASS CONTROL. Proves the unbounded-exemption class is CLOSED.
# ════════════════════════════════════════════════════════════════════════════
# Five separate exemptions in this file have been unbounded or unanchored (see the
# block comment above). Every one of them was caught by a HUMAN reading the diff, and
# every one of them was GREEN in CI. Scenario 0 is what makes a sixth go RED.
#
# 0a lints this file's SOURCE: an exemption can only be expressed in the two sanctioned
#    engine regions, or as a row in the SCRUBS table. Adding a fresh ad-hoc filter to
#    the pipeline is a build failure, not a review finding.
# 0b probes every DECLARED exemption's BEHAVIOUR, derived from the tables — so entry 14
#    of the whitelist and row 29 of SCRUBS are probed the day they are added, with no
#    second hand-maintained list to forget.

# <<<CLASS-LINT
# ─── Scenario 0a: audit_term_hits filters `$raw` ONLY through sanctioned steps ──
# This is an ALLOWLIST, not a blacklist — and that distinction is the whole fix.
#
# An earlier version of this control forbade THREE specific syntaxes (`grep -v`, an awk
# `gsub`, an awk `next`) anywhere outside the fenced engine regions. A skeptic broke it
# in one line: a drop expressed as `sed '/X/d'`, or `grep --invert-match`, or an awk
# `{if(index($0,"X")==0)print}` (inverting the PRINT instead of using `next`) is none of
# those three shapes, so it sailed through green while laundering real drift. A blacklist
# of known-bad syntaxes can always be dodged by a syntax it has not enumerated — which is
# exactly how this file grew five unbounded exemptions in the first place.
#
# So the invariant is stated POSITIVELY, on the one thing every filter must do. The
# function's output is `$raw`, threaded through the pipeline: EVERY step that could remove
# or transform a hit must either REASSIGN `raw` or PIPE the final `printf` of it. There
# is no third way to drop a line. So: inside `audit_term_hits`, outside the two fenced
# engine regions, every `raw=`/`raw+=` assignment and every `printf … "$raw"` sink must be
# ONE OF the four sanctioned forms below — the generating grep, the two anchored path
# greps, and the final unfiltered sink. A `sed`, an inverted awk, a `grep --invert-match`,
# a `${raw//…/}` parameter scrub, a filtered final `printf` — each is a `raw=` or sink
# line that is NOT on the list, so each fails HERE regardless of its syntax. The fenced
# regions (the ONE line drop, the ONE scrub engine) are the only exceptions, and they are
# bounded by 0a-2/0b/0c/0d, not by this lint.
it "0a: audit_term_hits filters \$raw only through the sanctioned steps (allowlist)"
# The audit pipeline, minus the two fenced engine regions and comments. Delimited by the
# AUDIT-PIPELINE markers — NOT by brace-matching, which a `}` in a quoted string silently
# truncates (see the note at the region's head).
audit_body="$(awk '
  /# <<<AUDIT-PIPELINE/ { on = 1; next }
  /# AUDIT-PIPELINE>>>/ { on = 0 }
  on {
    if ($0 ~ /# <<<LEGACY-ROW-EXEMPTION/ || $0 ~ /# <<<SCRUB-ENGINE/) { skip = 1 }
    if (!skip) print
    if ($0 ~ /# LEGACY-ROW-EXEMPTION>>>/ || $0 ~ /# SCRUB-ENGINE>>>/)  { skip = 0 }
  }
' "$SELF" | grep -vE '^[[:space:]]*#')"
lint_bad=""
while IFS= read -r l; do
  t="${l#"${l%%[![:space:]]*}"}"          # strip leading whitespace
  [ -z "$t" ] && continue
  # Only ASSIGNMENTS to raw, and the printf SINK of raw, are line-filtering steps.
  # Everything else (guards like `[ -z "$raw" ]`, `local raw`, the scrub-table setup)
  # neither removes nor rewrites a hit.
  is_filter=""
  case "$t" in
    raw=*|raw+=*) is_filter="assign" ;;
    printf*'"$raw"'*) is_filter="sink" ;;
  esac
  [ -z "$is_filter" ] && continue
  case "$t" in
    'raw="$(cd "$root" && grep -rniE "$regex" "${SCAN_ROOTS[@]}" \') ;;   # the generator
    'raw="$(printf '\''%s\n'\'' "$raw" | grep -vE "$WHITELIST_RE" || true)"') ;;
    'raw="$(printf '\''%s\n'\'' "$raw" | grep -vE "$PREFIX_RE" || true)"') ;;
    'printf '\''%s\n'\'' "$raw"') ;;                                       # the final sink
    *) lint_bad="${lint_bad}
    UNSANCTIONED \$raw filter step (${is_filter}) — a drop/scrub that is NOT one of the
      four sanctioned steps and NOT inside a fenced engine region: ${t}" ;;
  esac
done <<< "$audit_body"
# The two COMPILED path regexes are anchored AT BOTH ENDS — the exact F1 property,
# asserted on the VALUE (the allowlist above pins the CALL; this pins what it calls with):
# the path whitelist must consume the `:<lineno>:` separator, so it cannot match a line's
# CONTENT; the prefix whitelist must be `^`-rooted, so it can only exempt a leading dir.
case "$WHITELIST_RE" in
  '^('*'):[0-9]+:') ;;
  *) lint_bad="${lint_bad}
    WHITELIST_RE does not anchor to a leading \`path:lineno:\` — a whitelisted path
    could be claimed from a line's CONTENT (F1). got: ${WHITELIST_RE}" ;;
esac
case "$PREFIX_RE" in
  '^('*')') ;;
  *) lint_bad="${lint_bad}
    PREFIX_RE is not \`^\`-rooted — it could match mid-content. got: ${PREFIX_RE}" ;;
esac
# ANTI-VACUITY — and this is the part that has to be RIGHT, not just present.
# The allowlist proves nothing about lines it never saw, so the scan's COVERAGE is itself
# an assertion. The previous version required four tokens that ALL live in the first ~20
# lines of the region — so truncating the scan just after the PREFIX step satisfied every
# one of them while hiding the entire rest of the pipeline. An anti-vacuity check that
# only looks at the top of what it is measuring measures nothing.
#
# So the checks are anchored at BOTH ENDS and at the fences: the region must contain its
# FIRST step (the generating grep), its LAST step (the final sink + the closing brace),
# and BOTH engine fences must be intact (opened AND closed). Truncation anywhere — a `}`
# gadget, an early `# AUDIT-PIPELINE>>>`, a dropped fence — removes one of these and
# fails HERE.
for _need in 'grep -rniE' 'WHITELIST_RE' 'PREFIX_RE'; do
  printf '%s\n' "$audit_body" | grep -qF "$_need" \
    || lint_bad="${lint_bad}
    the audit pipeline did not yield its '${_need}' step — the allowlist scan is vacuous"
done
# The LAST filter in the region. If this is absent the scan was truncated, and every
# `case` above silently stopped policing at the cut.
printf '%s\n' "$audit_body" | grep -qF "printf '%s\n' \"\$raw\"" \
  || lint_bad="${lint_bad}
    the audit pipeline did not yield its FINAL SINK — the scan was TRUNCATED, so every
    filter after the cut is unpoliced (a \`}\` inside a quoted string does exactly this)."
printf '%s\n' "$audit_body" | grep -qE '^\}$' \
  || lint_bad="${lint_bad}
    the audit pipeline did not reach the function's closing brace — the scan was truncated."
# Both engine fences must be intact: opened AND closed, exactly once each. A fence left
# open swallows the rest of the pipeline into an unlinted 'skip' region.
# ANCHORED at the start of a comment line: the awk extractor above necessarily SPELLS
# these markers inside its own match patterns, and a bare `grep -cF` counts those too
# (open=2 close=2 — the lint accusing itself). A real fence line is a comment that STARTS
# with the marker; a reference to one is not.
for _f in 'LEGACY-ROW-EXEMPTION' 'SCRUB-ENGINE'; do
  _o="$(grep -cE "^[[:space:]]*# <<<${_f}" "$SELF" || true)"
  _c="$(grep -cE "^[[:space:]]*# ${_f}>>>" "$SELF" || true)"
  { [ "$_o" = "1" ] && [ "$_c" = "1" ]; } || lint_bad="${lint_bad}
    engine fence '${_f}' is not exactly one open + one close (open=${_o} close=${_c}) —
    a duplicated or unbalanced fence hides pipeline code from this lint."
done
if [ -z "$lint_bad" ]; then
  pass
else
  fail "an exemption bypasses the sanctioned filter steps:${lint_bad}
      Declare it as a SCRUBS row (bounded token + anchored path + a literal probe),
      or as the ONE legacy-row drop — never as a fresh filter in the pipeline."
fi
# CLASS-LINT>>>

# ─── Scenario 0a-2: every SCRUBS row is shape-bound BY CONSTRUCTION ──────────
# A row must carry all six fields, its path must be `^…$`-anchored (or the explicit
# `*` for tree-wide noise), and it must name a LITERAL probe — the thing Scenario 0b
# plants. A row with no honest literal example of what it exempts is a row that
# cannot be tested, which is how an unbounded exemption gets in.
it "0a: every SCRUBS row is well-formed (6 fields, anchored path, a literal probe)"
row_bad=""
_SEP='%%'
for _row in "${SCRUBS[@]}"; do
  _n=0
  _r="$_row"
  while :; do
    _n=$((_n + 1))
    case "$_r" in *"$_SEP"*) _r="${_r#*$_SEP}" ;; *) break ;; esac
  done
  if [ "$_n" -ne 6 ]; then
    row_bad="${row_bad}
    ${_n} fields (want 6): ${_row}"
    continue
  fi
  _t="${_row%%$_SEP*}"; _rest="${_row#*$_SEP}"
  _p="${_rest%%$_SEP*}"; _rest="${_rest#*$_SEP}"
  _tok="${_rest%%$_SEP*}"; _rest="${_rest#*$_SEP}"
  _repl="${_rest%%$_SEP*}"; _rest="${_rest#*$_SEP}"
  _probe="${_rest%%$_SEP*}"; _why="${_rest#*$_SEP}"
  # A path binding must ENUMERATE LITERAL PATHS — `^(a/b\.py|c/d\.sh)$` — never a
  # wildcard pattern. This is what makes a widening IMPOSSIBLE TO DO QUIETLY, and it is
  # the last hole the F4 class had: pinning the tree-wide (`*`) rows stops
  # `^docs/contracts/…$` → `*`, but NOT `^docs/contracts/[^/]+\.md$` → `^docs/.+\.md$`,
  # which re-widens the scrub across every doc while still "having a path binding". No
  # behavioural probe can catch that — a probe tests the scrub against its DECLARED
  # scope, and the declaration is what moved. So the declaration is constrained instead:
  # a wildcard cannot be spelled here at all, and adding a file to an exemption means
  # typing that file's name.
  #
  # Legal: ^ $ ( ) | \. and [A-Za-z0-9_/-]. Everything else (`.` `+` `*` `[` `]` `?`)
  # is a wildcard and is refused.
  case "$_p" in
    '*') ;;                                  # tree-wide noise: legal, pinned by 0a-3
    '^'*'$')
      _bare="${_p#^}"; _bare="${_bare%$}"
      _bare="${_bare//\\./D}"                # ESCAPED dot → placeholder (a legal literal).
                                             # An UNESCAPED `.` survives as `.` and is
                                             # caught below — it is a wildcard.
      _bare="${_bare//(/}"; _bare="${_bare//)/}"; _bare="${_bare//|/}"
      case "$_bare" in
        *[!A-Za-z0-9_/-]*) row_bad="${row_bad}
    path is a WILDCARD, not an enumeration of literal paths ('${_p}'): ${_row}
      Spell each file out: ^(dir/one\\.py|dir/two\\.sh)\$ — a wildcard can silently widen
      an exemption across a whole tree, which is exactly the F4 defect." ;;
      esac
      ;;
    *) row_bad="${row_bad}
    path is neither \`*\` nor ^…\$-anchored ('${_p}'): ${_row}" ;;
  esac
  # The TOKEN must be BOUNDED — no unbounded quantifier, so it can never run off the end
  # of the thing it is meant to exempt and swallow a real stale identifier sharing the
  # line. This is the F4/`(formerly …)` defect stated as a rule instead of a promise:
  #   `supersedes.*$`        ran to end-of-line
  #   `\([Ff]ormerly [^)]*\)` ran to the next `)`, arbitrarily far
  # Both are structurally impossible to spell now. A POSITIVE class (`[A-Za-z0-9_./-]+`,
  # `[ ]+`) is fine — it is bounded to the characters a name is made of. A NEGATED class
  # (`[^)]`) or a `.` wildcard is not: those are "anything at all", which is the bug.
  case "$_tok" in
    *'[^'*) row_bad="${row_bad}
    token uses a NEGATED character class ('${_tok}'): ${_row}
      \`[^x]*\` means 'anything until x' — it runs past the token and eats real stale
      identifiers on the same line. Spell what the token IS, not what it is not." ;;
  esac
  # drop bracket classes (a `.` inside one is a literal), then drop ESCAPED dots; any
  # `.` still standing is a wildcard.
  _tok_bare="$(printf '%s' "$_tok" | sed 's/\[[^]]*\]//g')"
  _tok_bare="${_tok_bare//\\./}"
  case "$_tok_bare" in
    *'.'*) row_bad="${row_bad}
    token contains an UNESCAPED \`.\` wildcard ('${_tok}'): ${_row}
      Escape it (\\.) if you meant a literal dot; a wildcard quantifier here is how an
      exemption grows to swallow the rest of the line." ;;
  esac
  [ -n "$_t" ]     || row_bad="${row_bad}
    empty term: ${_row}"
  [ -n "$_tok" ]   || row_bad="${row_bad}
    empty token: ${_row}"
  [ -n "$_probe" ] || row_bad="${row_bad}
    empty probe literal (Scenario 0b cannot test this row): ${_row}"
  [ -n "$_why" ]   || row_bad="${row_bad}
    empty rationale: ${_row}"
done
if [ -z "$row_bad" ]; then
  pass
else
  fail "malformed SCRUBS row(s):${row_bad}"
fi

# ─── Scenario 0a-3: the TREE-WIDE rows are a PINNED set ──────────────────────
# `path = *` is the one legal way to make an exemption apply everywhere, so it is also
# the one-token way to RE-OPEN the F4 hole: widen a path-bound row to `*` and its scrub
# is tree-wide again. Scenario 0b's boundedness probe cannot see that (the row is still
# a bounded token — it is just applied in too many files), so the SET is pinned here.
#
# A row belongs on this list only if its token is genuinely unavoidable noise across the
# tree: a test-tier path, an English phrase, a do-not-rename carve-out. Adding one is a
# real decision. Making that decision requires editing this list, in the same commit,
# on purpose — which is the entire point.
it "0a: the tree-wide (path=\`*\`) SCRUBS rows are exactly the pinned set"
TREE_WIDE_EXPECTED="PLAN_STEPS
UNIT TEST
add-unit test-run
next_plan_step
plan_step
tests/unit
unit test"
tree_wide_actual="$(
  for _row in "${SCRUBS[@]}"; do
    _rest="${_row#*$_SEP}"
    [ "${_rest%%$_SEP*}" = "*" ] || continue
    _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"
    printf '%s\n' "${_rest%%$_SEP*}"
  done | LC_ALL=C sort
)"
if [ "$tree_wide_actual" = "$TREE_WIDE_EXPECTED" ]; then
  pass
else
  fail "the set of TREE-WIDE exemptions changed. A row was widened to \`*\` (which makes its
      scrub apply in every scanned file — the F4 hole), or a tree-wide row was added.
      expected:
$(printf '%s\n' "$TREE_WIDE_EXPECTED" | sed 's/^/        /')
      actual:
$(printf '%s\n' "$tree_wide_actual" | sed 's/^/        /')
      If the widening is deliberate, say so by editing TREE_WIDE_EXPECTED in this commit."
fi

# ─── Scenario 0b: NO exemption can be claimed by CONTENT ─────────────────────
# The generalisation of F1 and F4. Every exemption in this file has a TRIGGER — the
# whitelisted path, the prefix, the scrubbed token. The class defect is that the
# trigger, appearing in a line's CONTENT at an ORDINARY path, exempted that line:
#
#   lib/evil.py:  led = ledger.read(x)  # see lib/ledger.py: the shim   → was GREEN (F1)
#   docs/evil.md: This module supersedes ledger.py entirely.            → was GREEN (F4)
#
# So: for EVERY trigger the tables declare, plant it at an ORDINARY path beside a
# payload that spells all 8 retired identifiers, and require the audit to fire for
# every term. Derived from GLOBAL_PATH_WHITELIST + GLOBAL_PATH_PREFIX_WHITELIST +
# SCRUBS, so a new entry is probed automatically — there is no second list to update.
#
# This is what proves the exemptions are BOUNDED: a path exemption may only exempt its
# own path, a token scrub may only cut its own token, and neither may ever be summoned
# by prose.
cls_tmp="$(mktemp -d)"
trap 'rm -rf "$cls_tmp"' EXIT
mkdir -p "$cls_tmp/lib" "$cls_tmp/docs"

# One payload, all 8 retired identifiers. `add_unit` carries `unit` via the leading
# underscore (the class regex_for_term's `_` alternative exists for).
CLS_PAYLOAD='STALE = ledger.add_unit(recipe, adapter, seam, tick, emitter, orchestrator)'

CLS_TRIGGERS=()
for _e in "${GLOBAL_PATH_WHITELIST[@]}";        do CLS_TRIGGERS+=("$_e"); done
for _e in "${GLOBAL_PATH_PREFIX_WHITELIST[@]}"; do CLS_TRIGGERS+=("$_e"); done
for _row in "${SCRUBS[@]}"; do
  _rest="${_row#*$_SEP}"; _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"
  CLS_TRIGGERS+=("${_rest%%$_SEP*}")
done
CLS_TRIGGERS+=('<!--legacy-->')   # the one structural exemption: it too is shape-bound

# The plants reproduce the REVIEWED EXPLOIT SHAPE verbatim — `# see <trigger>: the shim`
# — trailing colon included. That colon is not decoration: F1's filter was
# `grep -vF "<path>:"`, so the exploit needed the path to be FOLLOWED BY A COLON in the
# content, which is exactly how a path gets cited in English ("see `lib/ledger.py`: the
# shim"). A probe without it would miss the very defect it is named for.
_i=0
for _trig in "${CLS_TRIGGERS[@]}"; do
  _i=$((_i + 1))
  printf '%s  # see %s: the shim\n' "$CLS_PAYLOAD" "$_trig" > "$cls_tmp/lib/df_class_${_i}.py"
  printf 'Note — see %s: %s\n'      "$_trig" "$CLS_PAYLOAD" > "$cls_tmp/docs/df_class_${_i}.md"
done

it "0b: NO declared exemption can be claimed by a line's CONTENT (F1 + F4, generalised)"
cls_bad=""
for _t in orchestrator emitter adapter tick seam unit recipe ledger; do
  _h="$(audit_term_hits "$_t" "$cls_tmp")"
  _j=0
  for _trig in "${CLS_TRIGGERS[@]}"; do
    _j=$((_j + 1))
    for _f in "lib/df_class_${_j}.py" "docs/df_class_${_j}.md"; do
      printf '%s\n' "$_h" | grep -F "${_f}:" >/dev/null \
        || cls_bad="${cls_bad}
    [${_t}] ${_f} EXEMPTED ITSELF by citing '${_trig}' in its content"
    done
  done
done
if [ -z "$cls_bad" ]; then
  pass
else
  fail "an exemption is claimable by CONTENT — the F1/F4 class is OPEN again:${cls_bad}"
fi

# ─── Scenario 0c: a PATH-BOUND scrub does not apply OFF its path ─────────────
# 0b proves each exemption is BOUNDED (it cuts its own token and nothing else). It does
# NOT prove each exemption is SCOPED — and F4 was a scope defect, not a boundedness one:
# the `supersedes` scrub cut exactly the right token, in every file in the tree.
#
# 0b cannot see that, because its payload survives the over-broad cut and the line is
# reported anyway. So scope gets its own probe: plant each row's probe literal ALONE —
# no payload to mask the result — at an ORDINARY path, and require the retired term
# INSIDE THE LITERAL to be reported. If the row is correctly path-bound, the scrub does
# not run here and the term is caught. Widen the row (to `*`, or to a looser path ERE)
# and the scrub eats the literal, the file goes quiet, and this goes RED.
#
# Rows whose probe literal contains no retired term at all (`_LEGACY_TIER_DIRNAME`,
# `plan_step`) are skipped: there is nothing for the audit to catch in them, which is
# also why they cannot exempt anything. Tree-wide (`path = *`) rows are skipped by
# definition — their scope is pinned by Scenario 0a-3 instead.
# One ordinary path per scanned tree, so a scrub that leaks into ANY of them is caught —
# not just one that leaks into lib/. (A row that legitimately DECLARES one of these paths
# has that candidate skipped: the scrub is supposed to apply there.)
mkdir -p "$cls_tmp/lib" "$cls_tmp/docs" "$cls_tmp/docs/contracts" "$cls_tmp/tests/unit" \
         "$cls_tmp/commands" "$cls_tmp/skills/df-scope"
SCOPE_CANDIDATES=(
  'lib/df_scope.py'
  'docs/df_scope.md'
  'docs/contracts/df_scope.md'
  'tests/unit/df_scope.test.sh'
  'commands/df_scope.md'
  'skills/df-scope/SKILL.md'
)
scope_bad=""
for _row in "${SCRUBS[@]}"; do
  _rest="${_row#*$_SEP}"
  _rpath="${_rest%%$_SEP*}"
  [ "$_rpath" = "*" ] && continue              # tree-wide by design → Scenario 0a-3
  _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"
  _rprobe="${_rest%%$_SEP*}"
  for _f in "${SCOPE_CANDIDATES[@]}"; do
    # skip a candidate the row legitimately covers — there the scrub SHOULD apply.
    printf '%s\n' "$_f" | grep -qE "$_rpath" && continue
    printf '%s\n' "$_rprobe" > "$cls_tmp/$_f"
    for _t in orchestrator emitter adapter tick seam unit recipe ledger; do
      # does the literal itself name a retired term? if not, there is nothing to catch
      # in it — and nothing it could exempt either.
      printf '%s\n' "$_rprobe" | grep -qiE "$(regex_for_term "$_t")" || continue
      printf '%s\n' "$(audit_term_hits "$_t" "$cls_tmp")" | grep -F "${_f}:" >/dev/null && continue
      scope_bad="${scope_bad}
    [${_t}] '${_rprobe}' was SCRUBBED at ${_f} — but that row is bound to '${_rpath}'.
      The exemption is applying OFF its declared path (the F4 shape)."
    done
    rm -f "$cls_tmp/$_f"
  done
done
it "0c: a PATH-BOUND scrub does NOT apply outside its declared path (F4, generalised)"
if [ -z "$scope_bad" ]; then
  pass
else
  fail "an exemption escaped its path binding:${scope_bad}"
fi

# ─── Scenario 0d: a scrub cuts ONLY its token, WHERE IT ACTUALLY RUNS ────────
# 0b and 0c both probe from OUTSIDE a row's declared path, where its scrub does not run
# at all. So neither can see the defect that only manifests INSIDE it: a token regex that
# cuts more than its token, taking a real stale identifier that shares the line with it.
# That is the `(formerly …)` bug — `[^)]*` reached past the breadcrumb — and it was
# invisible to every probe until this one.
#
# So: plant, AT the row's own declared path (the first literal in its enumeration), the
# probe literal FOLLOWED BY the all-8-terms payload. The scrub runs. It must cut its
# token and stop — leaving every stale identifier in the payload to be caught.
#
# TWO payload SHAPES, and the second is the whole point (skeptic-found).
# The original probe planted `<probe>  <payload>` — separated by SPACES. That can only
# catch a token that runs ACROSS WHITESPACE, so it handed a false "bounded" verdict to any
# token ending in a greedy identifier class. A skeptic weaponised exactly that: the row
#     '*%%^(lib/iteration\.py)$%%LEGACYNOTE[A-Za-z0-9_./-]+%%@LEGACYNOTE@%%…'
# is a legal, innocent-looking row that passed 0a, 0a-2, 0a-3, 0b, 0c AND 0d, while its
# `+` ate an unbroken run of identifier characters —
# `LEGACYNOTE_ledger.add_unit/recipe_…` — swallowing all 8 retired terms at once. The
# token IS "bounded" in the only sense 0a-2 can statically check (a positive class, no
# `[^…]`, no bare `.`); it is not bounded in the sense that matters. The PROBE's shape was
# the lie, not the row — so the probe is what gets fixed.
#
# The ADJACENT payload is an unbroken run of the very characters a name class is built
# from, glued onto the probe with NO separator. A token that stops at its own name leaves
# the run intact and passes; a token that runs rightward eats it and FAILS. Legit rows are
# unaffected: each stops at a delimiter its own regex names (a backtick, a `)`, a `/`, a
# space), so the run survives them.
#
# The run LEADS with `_`, and that is load-bearing. Glued straight on, `tick.sh` + `ledger…`
# spells `shledger` — no word boundary, so `ledger` is genuinely not an identifier there
# and the audit is RIGHT not to report it. The probe would have been accusing correct code.
# A leading `_` is simultaneously (a) inside the `[A-Za-z0-9_./-]` class, so a greedy token
# still eats straight through it, and (b) `regex_for_term`'s own `(\b|_)` alternative, so
# every term in the run is a real hit. Each term below is likewise separated by a class
# char that is also a boundary (`_`, `.`, `/`) — never by a letter.
CLS_RUN='_ledger.add_unit/recipe_adapter_seam_tick_emitter_orchestrator'
bnd_bad=""
for _row in "${SCRUBS[@]}"; do
  _rest="${_row#*$_SEP}"
  _rpath="${_rest%%$_SEP*}"
  [ "$_rpath" = "*" ] && continue
  _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"; _rest="${_rest#*$_SEP}"
  _rprobe="${_rest%%$_SEP*}"
  # first literal path out of `^(a|b|c)$` (paths are literal enumerations — 0a-2 pins it)
  _lit="${_rpath#^}"; _lit="${_lit%$}"; _lit="${_lit#(}"; _lit="${_lit%)}"
  _lit="${_lit%%|*}"; _lit="${_lit//\\./.}"
  mkdir -p "$cls_tmp/$(dirname "$_lit")"
  for _shape in spaced adjacent; do
    case "$_shape" in
      spaced)   printf '%s  %s\n' "$_rprobe" "$CLS_PAYLOAD" > "$cls_tmp/$_lit" ;;
      adjacent) printf '%s%s\n'   "$_rprobe" "$CLS_RUN"     > "$cls_tmp/$_lit" ;;
    esac
    for _t in orchestrator emitter adapter tick seam unit recipe ledger; do
      printf '%s\n' "$(audit_term_hits "$_t" "$cls_tmp")" | grep -F "${_lit}:" >/dev/null && continue
      bnd_bad="${bnd_bad}
    [${_t}/${_shape}] at ${_lit}, the scrub for '${_rprobe}' ATE a stale identifier on its line.
      A token must stop at its own name. On the 'adjacent' shape this means the token ends
      in a greedy class that runs rightward across a whole identifier run — bounded to
      0a-2's eye, unbounded in fact."
    done
    rm -f "$cls_tmp/$_lit"
  done
done
it "0d: a scrub cuts ONLY its own token, inside the path where it RUNS (bounded)"
if [ -z "$bnd_bad" ]; then
  pass
else
  fail "a token exemption is UNBOUNDED — it swallows real stale identifiers:${bnd_bad}"
fi

rm -rf "$cls_tmp"; trap - EXIT

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
  # Skip the HEADER row — and ONLY a real header row.
  #
  # F3: matching the header by its first cell's TEXT is not enough. A DATA row whose
  # first cell happens to be the literal string `retired identifier` or `deprecated
  # surface` — easy to write by accident in a table that is ABOUT retired identifiers —
  # skipped both checks entirely and claimed the `<!--legacy-->` exemption unpoliced.
  # A header is not a string; it is a POSITION: in markdown, the header is the row
  # immediately followed by the `|---|---|` delimiter row. So check the STRUCTURE, and
  # require the text to match as well. A data row can fake the text; it cannot fake
  # being followed by the delimiter.
  next_line="$(sed -n "$((lineno + 1))p" "${AUTO_ROOT}/${file}")"
  is_header=""
  case "$next_line" in
    \|[-\ :]*)
      # the delimiter row: only |, -, :, and spaces
      case "$next_line" in
        *[!-\ :\|]*) ;;
        *) is_header="yes" ;;
      esac
      ;;
  esac
  if [ -n "$is_header" ]; then
    # `key` heads the key map; `location` heads the U8 tier-dir map; `identifier` heads
    # the U9 code map (the run-record rename touched no persisted key, so its legacy
    # table maps SYMBOLS, not keys — but it claims the same `<!--legacy-->` exemption,
    # so it gets the same policing). U10 added the two tables the WIDENED scan brought
    # in scope: `retired identifier` heads the historical-mapping tables in CONCEPTS.md
    # + README.md, and `deprecated surface` heads the removal ledger in
    # docs/deprecations.md. A row that is structurally a header but spells NONE of
    # these is a new table claiming the exemption — say so rather than waving it past.
    case "$n1" in
      "legacy (v1) key"|"legacy (v1) location"|"legacy (v1) identifier") continue ;;
      "retired identifier"|"deprecated surface") continue ;;
      *)
        legacy_bad="${legacy_bad}
    ${file}:${lineno}: a NEW <!--legacy--> table appeared, headed '${n1}' — add it to the
      known-headers list here on purpose, so its rows get policed like every other."
        continue
        ;;
    esac
  fi
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

# ─── Scenario 3: THIS file's summary line is tallied by THE RUNNER'S regex ──
# F8: both sides are now DERIVED, neither is hand-copied.
#
# The old shape checked a hardcoded probe string ("vocabulary-audit.test.sh: 0 passed,
# 0 failed") against a hand-copied duplicate of run.sh's regex. It read NEITHER real
# source. So it stayed green if run.sh tightened its regex, and it stayed green if this
# file's own final `echo` drifted — the two exact drifts it exists to catch. It only
# ever proved that one constant matches another constant.
#
# Now: the regex is read out of tests/run.sh, and the probe is rendered from THIS file's
# own final `echo` line (with ${PASS}/${FAIL} substituted). If either side moves, this
# fails.
it "this file's summary line is matched by tests/run.sh's ACTUAL tally regex"
tally_bad=""

# The runner's regex, from the runner.
runner_re="$(sed -n "/summary_line=\$(grep -E/ s/^[^']*'\([^']*\)'.*/\1/p" \
             "${AUTO_ROOT}/tests/run.sh" | head -1)"

# This file's summary line, from this file: take the last `echo "...test.sh: ..."` and
# expand the two counter placeholders. Parameter expansion only — nothing is eval'd.
summary_fmt="$(grep -E '^echo "[^"]*\.test\.sh: \$\{PASS\} passed, \$\{FAIL\} failed"$' \
               "$SELF" | tail -1)"
probe="${summary_fmt#echo \"}"
probe="${probe%\"}"
probe="${probe//\$\{PASS\}/7}"
probe="${probe//\$\{FAIL\}/0}"

# Anti-vacuity on BOTH derivations — an empty regex or an empty probe would make the
# match below meaningless (and `grep -qE ''` matches everything).
[ -n "$runner_re" ] || tally_bad="could not read the tally regex out of tests/run.sh — the check below is vacuous"
[ -n "$probe" ]     || tally_bad="${tally_bad:+$tally_bad; }could not render this file's summary line from its own final echo"
case "$probe" in
  vocabulary-audit.test.sh:*) ;;
  *) tally_bad="${tally_bad:+$tally_bad; }the rendered summary line does not start with this file's own basename: '${probe}'" ;;
esac
if [ -z "$tally_bad" ] && ! printf '%s\n' "$probe" | grep -qE "$runner_re"; then
  tally_bad="tests/run.sh would NOT tally this file: '${probe}' does not match its regex '${runner_re}'"
fi
if [ -z "$tally_bad" ]; then
  pass
else
  fail "$tally_bad"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "vocabulary-audit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
