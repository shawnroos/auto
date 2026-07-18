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
#   6. brace-matching region extractor — 0a's own lint, defeated by a `}` inside a
#      quoted string, so the pipeline's tail went unlinted. (Fixed: markers.)
#   7. `LEGACYNOTE[A-Za-z0-9-]+`        — a SCRUBS token that satisfied every rule 0a-2
#      had (positive class, no `[^…]`, no bare `.`) and still ate `add-unit` whole,
#      laundering a stale identifier at 14/14 green. The old rule policed the token's
#      ALPHABET; the defect was in its LENGTH.
#   8. the 0a classifier's DEFAULT-ALLOW — a line was only checked if it began `raw=`;
#      `IFS= read -r -d '' raw < <(… | grep -vF 'X'; printf '\0')` assigns `raw` without
#      that prefix, so defect #1 came back verbatim, unlinted, green. Same for `mapfile`,
#      `local raw="$(…)"`, `declare`, and every continuation line of the generating grep.
#   9. `supersedes[:,]?[ ]+`?[A-Za-z0-9_./-]+…` — found by RULE, not by review, while
#      fixing #7: the shipped banner scrub meant appending
#      `> supersedes v1_ledger_add_unit_recipe_adapter` to a live contract laundered FOUR
#      terms at 14/14 green, with no table edit at all. Instances #2 and #7 are the same
#      defect as #9; nobody had spotted #9 in four review passes over the same table.
#
# NINE instances. EVERY fix until now was an ENUMERATION — an allowlist of permitted
# forms, or a probe carrying one payload shape — and every enumeration was escaped by a
# variant nobody enumerated. #7 escaped #2's fix; #8 escaped #1's fix, twice. The pattern
# is not bad luck; it is what enumeration DOES.
#
# So the two controls that kept losing are now stated as CLOSED rules over the whole
# input, and neither has a "which lines does this apply to?" step to dodge:
#   * 0a  pins the pipeline's body LINE FOR LINE. Not "no drops" — this exact text.
#         Any added line, of any syntax, mentioning `raw` or not, is a diff.
#   * 0a-2 refuses any SCRUBS token containing `+`, `*` or `{n,}`. Not "no bad classes" —
#         no unbounded length, so a token's reach is decided by the ROW, never the LINE.
# 0b/0c/0d stay as behavioural defence in depth, and they are still enumerations (0d's
# probe glue is a list of three characters someone chose). They are no longer what the
# class rests on. See "WHAT IS AND IS NOT CLOSED" at Scenario 0.
#
# The SHAPE of an exemption is fixed by construction; there are four kinds and no fifth:
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
  # F5: these were ONE row each, built on `[A-Za-z0-9_./-]+` — "the banner, whatever it
  # names". That quantifier is what let `supersedes v1_ledger_add_unit_recipe_adapter`
  # launder four terms out of a live contract. There is no such thing as "whatever it
  # names": there are exactly three retired doc names, and a row per name spells each one.
  # A fourth banner does not silently join them — it fails the audit until someone adds it
  # here, on purpose, in a diff. That is the exemption being EARNED rather than assumed.
  '*%%^docs/contracts/run-record-schema\.md$%%supersedes ledger-schema\.md%%@SUPERSEDES@%%supersedes ledger-schema.md%%KTD-5 contract re-lock banner (the un-backticked spelling, as it really appears at run-record-schema.md:3). F4: this was applied TREE-WIDE, so `This module supersedes ledger.py entirely.` in any doc was exempt — now bound to the one contract whose header carries it.'
  '*%%^docs/contracts/backend-contract\.md$%%supersedes `adapter-contract\.md`%%@SUPERSEDES@%%supersedes `adapter-contract.md`%%same banner, the backend contract (backend-contract.md:4 and :22). `supersedes v0.14.0` on line 3 needs no row: it names no retired term.'
  '*%%^docs/contracts/workflow-format\.md$%%supersedes `recipe-format\.md`%%@SUPERSEDES@%%supersedes `recipe-format.md`%%same banner, the workflow format contract (workflow-format.md:3).'
  # Same story: `\([Ff]ormerly `?[A-Za-z0-9_./-]+`?\)` was "(formerly ANYTHING)". There are
  # two breadcrumbs. Spell them.
  '*%%^skills/auto-author-workflow/SKILL\.md$%%\(formerly auto-author-recipe\)%%@FORMERLY@%%(formerly auto-author-recipe)%%KTD-4 skill breadcrumb, kept so model-side triggering still matches the old phrasing. Lives only in this renamed skill description. The parens are ESCAPED: bare `(…)` is an ERE group, which would match the breadcrumb without its parens.'
  '*%%^skills/auto-backend/SKILL\.md$%%\(formerly auto-adapter\)%%@FORMERLY@%%(formerly auto-adapter)%%same breadcrumb, the other renamed skill.'

  # ── unit: the term entangled with unavoidable non-renamed noise ──
  'unit%%*%%tests\/unit%%@TIER@%%tests/unit%%the tests/unit TEST-TIER path — keyed to the suite layout, not the renamed concept. Appears as the path of a hit AND as a cross-reference in lib/ and docs/ prose, so it is genuinely tree-wide.'
  'unit%%*%%[-_A-Za-z0-9][Uu]nit[ -][Tt]est%% unit %%add-unit test-run%%NORMALIZE-TO-KEEP, not a scrub. An `unit test` ATTACHED to an identifier char is a REAL symbol (`add-unit test-run`, `add_unit test_id`), not prose — turn it back into a bare token so it still HITS. MUST precede the prose row below.'
  'unit%%*%%[Uu]nit[ -][Tt]est%%@UT@%%unit test%%the free-standing prose "unit test" / "unit-testable" (the hyphenated adjective lives in lib/iteration.py, lib/verification.py, lib/goal-route.py). The trailing `[A-Za-z]*` these three rows used to carry was pure decoration: cutting `unit-test` out of `unit-testable` already leaves `@UT@able`, which spells no retired term. It bought nothing and cost the boundedness rule.'
  'unit%%*%%UNIT[ -]TEST%%@UT@%%UNIT TEST%%the shouted prose form of the same.'
  'unit%%*%%plan_step%%@PLANSTEP@%%plan_step%%the plan-phase sub-state — a deliberate do-not-rename carve-out (Key Decisions / CONCEPTS.md). Carries no `unit` token, so it cannot trip the regex; scrubbed defensively so a future `plan_unit`-shaped revival cannot hide behind it.'
  'unit%%*%%PLAN_STEPS%%@PLANSTEP@%%PLAN_STEPS%%same carve-out, shouted.'
  'unit%%*%%next_plan_step%%@PLANSTEP@%%next_plan_step%%same carve-out.'
  'unit%%^tests/run\.sh$%%unit_files%%@TIER@_files%%unit_files%%tests/run.sh is the ONE file where the test-suite TIER name is a code identifier. That `unit` is the tests/unit/ tier, not a workflow step; renaming it would break `bash tests/run.sh unit` for every caller. Scrub the TOKENS — never drop the file, or run.sh becomes the file-level blind spot this branch exists to eliminate.'
  'unit%%^tests/run\.sh$%%unit[|]integration%%@TIER@|integration%%unit|integration%%same: the tier list in the usage string. The pipe is a BRACKET LITERAL `[|]`, not `\|`: `\|` is a literal pipe under this box'"'"'s BSD awk but ALTERNATION under gawk (widening the token to `unit`-OR-`integration`), silently, with the probe none the wiser. `[|]` is a literal in every awk.'
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
  # <<<LEGACY-ROW-EXEMPTION (a human landmark; Scenario 0a pins this region's code verbatim)
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
  # <<<SCRUB-ENGINE (a human landmark; Scenario 0a pins this region's code verbatim)
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
# Scenario 0 — THE CLASS CONTROL.
# ════════════════════════════════════════════════════════════════════════════
# NINE separate exemptions in this file have been unbounded or unanchored (see the block
# comment above). Every one was caught by a HUMAN reading the diff; every one was GREEN
# in CI. Scenario 0 is what makes a tenth go RED.
#
# 0a  pins the audit pipeline's body, LINE FOR LINE, against AUDIT_BODY_EXPECTED. Adding
#     any step to the pipeline is a build failure, not a review finding — regardless of
#     its syntax, and regardless of whether it mentions `raw`.
# 0a-2 refuses any SCRUBS token containing an unbounded quantifier, so a token's reach is
#     decided by the row that declares it and never by the line it lands on.
# 0a-3 pins the set of tree-wide rows.
# 0b/0c/0d probe every DECLARED exemption's BEHAVIOUR, derived from the tables — so entry
#     14 of the whitelist and row 29 of SCRUBS are probed the day they are added, with no
#     second hand-maintained list to forget.
#
# ⚠ WHAT IS AND IS NOT CLOSED — read this before writing "the class is closed" again.
# The previous commit's message said the unbounded-exemption class was CLOSED. It was not:
# two reviewers had working end-to-end bypasses within a day, and a third defect (#9) was
# sitting unnoticed in the shipped table the whole time. So, precisely:
#
#  CLOSED BY CONSTRUCTION (a rule over the whole input, with no classifier to dodge):
#   * No step can be added to the audit pipeline.        0a pins the body verbatim.
#   * No SCRUBS token can have unbounded length.         0a-2 refuses +, *, {n,}.
#   * No exemption can be claimed from a line's CONTENT. Anchoring is asserted on the
#                                                        compiled regexes' VALUES.
#   * No path binding can be a wildcard.                 0a-2 refuses non-literal paths.
#   * The tree-wide set cannot grow silently.            0a-3 pins it.
#
#  NOT CLOSED — bounded, documented, and still real:
#   * A DECLARED LITERAL THAT IS SIMPLY TOO LONG. `add-unit` is a legal token; so is
#     `add-unit_ledger`, which eats a term the row never should have. Nothing static can
#     tell those apart — the row is allowed to name retired text; that is its job. 0d's
#     adjacent-* probes catch the common shapes, and they are an ENUMERATION of three glue
#     characters. Bounded by: it must be TYPED, in the row, in a diff, and it only applies
#     in that row's declared files.
#   * A SUPERSTRING of a scrubbed token (the residual documented at the scrub engine).
#   * A `<!--legacy-->` row's columns 3+ (F3, documented above).
#   * Everything the audit cannot see BY CONSTRUCTION: prose that destroys the old
#     identifier rather than leaking it (the ⚠ at the top of this file).
#
# The honest one-line summary: the class where an exemption's REACH is decided by the LINE
# is closed. The class where a human DECLARES too much, on purpose, in a reviewable diff,
# is not — and cannot be, because that is the same act as a legitimate exemption.

# <<<CLASS-LINT
# ─── Scenario 0a: the audit pipeline's body is PINNED, line for line ────────────
# DEFAULT-DENY. Not an allowlist of filter SHAPES — a pin of the WHOLE BODY.
#
# The history of this control is the history of this file's defect class, in miniature:
#
#   v1  BLACKLIST of three syntaxes (`grep -v`, awk `gsub`, awk `next`) outside the fenced
#       regions. Broken in one line: `sed '/X/d'`, `grep --invert-match`, and an awk that
#       inverts the PRINT are none of those three shapes. A blacklist is dodged by any
#       syntax it did not enumerate.
#   v2  ALLOWLIST of four sanctioned `$raw` filter steps — better, and it held for the
#       shapes it CLASSIFIED. But it still decided WHAT TO CLASSIFY with a blacklist: a
#       line was a "filter step" only if it began `raw=` / `raw+=` / `printf …"$raw"`.
#       Anything else was skipped — DEFAULT-ALLOW at the classifier, so the allowlist
#       never ran on it. Two verified escapes:
#         IFS= read -r -d '' raw < <(printf '%s\n' "$raw" | grep -vF 'X'; printf '\0')
#       — an unbounded whole-line drop (defect #1 verbatim) that assigns `raw` without a
#       `raw=` prefix, so it was never classified, never checked, and went GREEN. Same for
#       `local raw="$(…)"`, `mapfile`, `declare`. AND the generating grep's CONTINUATION
#       lines were never classified at all, so `--exclude='evil*'` on line 2 of it
#       narrowed the entire scan unlinted.
#
# The lesson, three times over: any rule that first decides WHICH lines to police is only
# as good as that decision, and that decision has always been the hole. So this version
# does not decide. It policies EVERY line.
#
# THE PIN: the audit pipeline's body — every non-comment, non-blank line between the
# AUDIT-PIPELINE markers, outside the two fenced engine regions, whitespace-normalised —
# must equal AUDIT_BODY_EXPECTED below, EXACTLY. Not "must not contain a drop"; must BE
# this text. A `sed`, a `read -d ''`, a `mapfile`, a `local raw="$(…)"`, an extra
# `--exclude=` on a continuation line, a reordered step, a deleted guard, an inverted awk
# — every one of them is a line that is not in the pin, and every one of them fails HERE,
# regardless of syntax, regardless of whether it mentions `raw` at all.
#
# This is closed by construction in the way the previous two were not: there is no shape
# to enumerate and no classifier to dodge, because the permitted set is finite, literal,
# and complete. The cost is that touching this function means editing the pin in the same
# commit — deliberately, visibly, in a diff a reviewer reads. For the file's security
# kernel that cost is the feature. It is the same doctrine as TREE_WIDE_EXPECTED (0a-3).
#
# The two engine regions (the ONE line drop and the ONE scrub engine) are pinned IN FULL,
# same as the rest — 0a-2/0b/0c/0d bound their DATA (the SCRUBS table, the whitelists),
# but the engine CODE is fixed logic and is pinned here verbatim. Excluding them, as an
# earlier version did, was itself a default-allow hole: a filter dropped inside an engine
# region left the pin unchanged and laundered freely (review r3). Nothing is excluded now.
it "0a: the audit pipeline's body is EXACTLY the pinned text (default-deny)"
# The WHOLE audit pipeline — comments and blank lines aside, EVERY non-comment line
# between the AUDIT-PIPELINE markers, including the two engine bodies. Delimited by the
# AUDIT-PIPELINE markers — NOT by brace-matching, which a `}` in a quoted string silently
# truncates (see the note at the region's head). The engines used to be EXCLUDED from this
# pin (bounded only by 0a-2/0b/0c/0d) — and that exclusion was itself a default-allow hole:
# any filter added inside an engine region left this pin unchanged and laundered freely
# (review r3, the 9th instance of the class). So nothing is excluded now — the engines are
# pinned verbatim like the rest of the body.
AUDIT_BODY_EXPECTED="$(cat <<'PINEOF'
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
raw="$(printf '%s\n' "$raw" | grep -vE "$WHITELIST_RE" || true)"
[ -z "$raw" ] && return 0
raw="$(printf '%s\n' "$raw" | grep -vE "$PREFIX_RE" || true)"
[ -z "$raw" ] && return 0
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
local rows="" SEP='%%'
local row r_term r_path r_tok r_repl rest
for row in "${SCRUBS[@]}"; do
r_term="${row%%$SEP*}";  rest="${row#*$SEP}"
r_path="${rest%%$SEP*}"; rest="${rest#*$SEP}"
r_tok="${rest%%$SEP*}";  rest="${rest#*$SEP}"
r_repl="${rest%%$SEP*}"
[ "$r_term" = "*" ] || [ "$r_term" = "$term" ] || continue
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
[ -z "$raw" ] && return 0
printf '%s\n' "$raw"
}
PINEOF
)"
audit_body="$(awk '
  /# <<<AUDIT-PIPELINE/ { on = 1; next }
  /# AUDIT-PIPELINE>>>/ { on = 0 }
  on { print }
' "$SELF" | grep -vE '^[[:space:]]*#')"
# Normalise: drop blank lines, strip leading indentation. Indentation is not a security
# property; the SET OF LINES is.
audit_body_norm="$(
  while IFS= read -r l; do
    t="${l#"${l%%[![:space:]]*}"}"
    [ -z "$t" ] && continue
    printf '%s\n' "$t"
  done <<< "$audit_body"
)"
lint_bad=""
if [ "$audit_body_norm" != "$AUDIT_BODY_EXPECTED" ]; then
  lint_bad="${lint_bad}
    the audit pipeline's body is NOT the pinned text. Every line that survives into the
      pipeline must be in AUDIT_BODY_EXPECTED — a step that drops, rewrites, narrows or
      reorders hits is a line that is not in the pin. diff (expected → actual):
$(diff <(printf '%s\n' "$AUDIT_BODY_EXPECTED") <(printf '%s\n' "$audit_body_norm") | sed 's/^/      /')"
fi
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
# ANTI-VACUITY is STRUCTURAL, not a separate check. The previous version listed tokens
# the region had to contain ('grep -rniE', the final sink, the closing brace) because the
# allowlist proved nothing about lines it never saw — so a truncated scan had to be caught
# separately, and the first attempt at that only looked at the top of what it was measuring.
# The pin subsumes all of it: the body must EQUAL the expected text, so a truncation (a `}`
# gadget, an early `# AUDIT-PIPELINE>>>`) removes lines and diffs. There is no vacuous-scan
# state left to check for — a scan that saw nothing does not match a 66-line pin.
#
# The two engine regions are NO LONGER excluded from the pin (that exclusion was the r3
# hole), so the LEGACY-ROW-EXEMPTION / SCRUB-ENGINE markers no longer gate extraction — a
# missing or duplicated one changes nothing, because the body is pinned in full regardless.
# They survive only as human landmarks, and this cheap check keeps them balanced so the
# landmarks stay honest. It is documentation hygiene now, not a security control.
# ANCHORED at the start of a comment line: the awk extractor above necessarily SPELLS
# these markers inside its own match patterns, and a bare `grep -cF` counts those too
# (open=2 close=2 — the lint accusing itself). A real fence line is a comment that STARTS
# with the marker; a reference to one is not.
for _f in 'LEGACY-ROW-EXEMPTION' 'SCRUB-ENGINE'; do
  _o="$(grep -cE "^[[:space:]]*# <<<${_f}" "$SELF" || true)"
  _c="$(grep -cE "^[[:space:]]*# ${_f}>>>" "$SELF" || true)"
  { [ "$_o" = "1" ] && [ "$_c" = "1" ]; } || lint_bad="${lint_bad}
    engine landmark '${_f}' is not exactly one open + one close (open=${_o} close=${_c}) —
    the region markers drifted; keep them balanced so the code stays readable."
done
if [ -z "$lint_bad" ]; then
  pass
else
  fail "the audit pipeline is not what it is pinned to be:${lint_bad}
      Declare an exemption as a SCRUBS row (bounded token + anchored path + a literal
      probe), or as the ONE legacy-row drop — never as a fresh step in the pipeline.
      If you changed this function ON PURPOSE, update AUDIT_BODY_EXPECTED in the same
      commit, and say why in the message."
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
  # ── THE TOKEN MUST HAVE A BOUNDED MAXIMUM LENGTH ─────────────────────────────
  # THE rule. One line of policy that closes the whole class, stated on the only property
  # that ever mattered: *the token's match length must be decided by the ROW, not by the
  # LINE.*  A regex built from literals, escaped literals, bracket classes, alternation
  # and `?` has a maximum match length fixed by its own text. Add `+`, `*` or `{n,}` and
  # that ceiling is gone — how far the token reaches is now a property of whatever it is
  # pointed at, which is the definition of an unbounded exemption.
  #
  # THIS RULE IS WHY THE PREVIOUS ONES FAILED. Every earlier version of this check was a
  # BLACKLIST of shapes someone had already been burned by:
  #   `supersedes.*$`         → banned the bare `.` wildcard
  #   `\([Ff]ormerly [^)]*\)` → banned the NEGATED class
  # …and both bans were satisfied, in full, by `LEGACYNOTE[A-Za-z0-9-]+` — a POSITIVE,
  # non-negated, dot-free class that a reviewer verified eats `add-unit` whole and laundered
  # a stale identifier at 14/14 green. The old comment here even blessed that shape by name
  # ("A POSITIVE class … is fine — it is bounded to the characters a name is made of").
  # It is not fine. `[A-Za-z0-9-]+` is bounded in its ALPHABET and unbounded in its LENGTH,
  # and length is the axis the defect lives on. Enumerating bad alphabets was never going to
  # terminate; there is always one more class nobody listed.
  #
  # So: no unbounded quantifier, at all, anywhere in a token — not just at its right edge.
  # It is a stronger rule than the defect strictly requires, and that is deliberate: "does
  # this `+` reach past its own token?" needs a regex parser and a case-by-case argument,
  # while "is there a `+`?" is decidable by looking. A rule you can check by looking is a
  # rule that still holds in five commits' time.
  #
  # This is not hypothetical tightening — it FOUND A LIVE ONE. The shipped `supersedes`
  # row's `[A-Za-z0-9_./-]+` meant that appending
  #     > supersedes v1_ledger_add_unit_recipe_adapter
  # to docs/contracts/run-record-schema.md laundered FOUR retired terms at 14/14 green, with
  # no table edit at all — a worse exploit than the reviewed one, in shipped code, invisible
  # to 0b/0c/0d because their probes end in a backtick. Every row that tripped this rule was
  # rewritten to a literal below; none of them needed the quantifier.
  #
  # (The two checks below are now strictly redundant — a `.` or a `[^…]` with no quantifier
  # matches one character and cannot run anywhere. They are kept because they name the two
  # historical defects precisely, and a row that trips them is still a row worth rejecting.)
  _tok_lit="$(printf '%s' "$_tok" | sed 's/\\.//g')"      # drop ESCAPED pairs (\. \+ \| \( \))
  _tok_lit="$(printf '%s' "$_tok_lit" | sed 's/\[[^]]*\]//g')"  # drop bracket classes
  case "$_tok_lit" in
    *'+'*|*'*'*|*'{'*) row_bad="${row_bad}
    token contains an UNBOUNDED QUANTIFIER ('${_tok}'): ${_row}
      \`+\`, \`*\` and \`{n,}\` let the LINE decide how far this exemption reaches. Spell the
      token out as a literal — if you cannot, the thing you are exempting is not a token.
      (Escape it — \\+ \\* — if you meant the literal character.)" ;;
  esac
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
# AND THE GLUE IS ITSELF ENUMERATED, WHICH IS THE PART TO BE HONEST ABOUT.
# `CLS_RUN` leads with `_`, and separates its terms with only `_`, `.` and `/`. A token
# ending in a greedy class that EXCLUDES those three characters — `[A-Za-z0-9-]+` — stops
# dead at the run's first character and sails through BOTH shapes above, while inside its
# declared file it eats hyphen-joined stale identifiers (`add-unit`, `set-enumerated-units`,
# `--recipe`, `auto-tick` — the retired vocabulary is heavily hyphenated). A reviewer built
# exactly that row and laundered a stale `add-unit` at 14/14 green. The 'spaced' shape could
# not catch it either: CLS_PAYLOAD's first term sits behind `= `.
#
# So the runs below vary the GLUE — `_`-led, `-`-led, and space-led — and each run's terms
# are separated by that same character. THIS IS STILL AN ENUMERATION, and it is the reason
# it is no longer the load-bearing control: a probe can only ever test the glue somebody
# thought of. The actual fix for that defect is STATIC — 0a-2 now refuses any token
# carrying `+`, `*` or `{n,}` at all, so the shape these runs hunt for cannot be spelled in
# the table in the first place. These shapes are defence in depth, and they still earn
# their keep against the one thing the static rule permits: a DECLARED literal that
# over-spans its own name (a row whose token is typed as `add-unit_ledger`).
#
# Each run's leading character is load-bearing in the same way `_` was. Glued straight on,
# `tick.sh` + `ledger…` spells `shledger` — no word boundary, so `ledger` is genuinely not
# an identifier there and the audit is RIGHT not to report it; the probe would be accusing
# correct code. `_`, `-` and ` ` are each simultaneously (a) a character a greedy name class
# plausibly contains, and (b) a boundary `regex_for_term` honours — so every term in every
# run is a real hit.
CLS_RUN='_ledger.add_unit/recipe_adapter_seam_tick_emitter_orchestrator'
CLS_RUN_HYPHEN='-ledger-add_unit-recipe-adapter-seam-tick-emitter-orchestrator'
CLS_RUN_SPACED=' ledger add_unit recipe adapter seam tick emitter orchestrator'
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
  for _shape in spaced adjacent adjacent-hyphen adjacent-spaced; do
    case "$_shape" in
      spaced)          printf '%s  %s\n' "$_rprobe" "$CLS_PAYLOAD"    > "$cls_tmp/$_lit" ;;
      adjacent)        printf '%s%s\n'   "$_rprobe" "$CLS_RUN"        > "$cls_tmp/$_lit" ;;
      adjacent-hyphen) printf '%s%s\n'   "$_rprobe" "$CLS_RUN_HYPHEN" > "$cls_tmp/$_lit" ;;
      adjacent-spaced) printf '%s%s\n'   "$_rprobe" "$CLS_RUN_SPACED" > "$cls_tmp/$_lit" ;;
    esac
    for _t in orchestrator emitter adapter tick seam unit recipe ledger; do
      printf '%s\n' "$(audit_term_hits "$_t" "$cls_tmp")" | grep -F "${_lit}:" >/dev/null && continue
      bnd_bad="${bnd_bad}
    [${_t}/${_shape}] at ${_lit}, the scrub for '${_rprobe}' ATE a stale identifier on its line.
      A token must stop at its own name. On an 'adjacent-*' shape this means the token
      reaches rightward past its own probe, across the ${_shape#adjacent-} glue, into the
      identifier run behind it — so it is cutting text the row never declared.
      0a-2 already refuses any token with a \`+\`/\`*\`/\`{n,}\`, so this is the case it
      cannot see: a BOUNDED literal that was simply typed too long."
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
  #
  # The delimiter must be a REAL one: at least two cells, each `:?-{3,}:?`. The old
  # character-only check (`only |, -, :, and spaces`) accepted `| |` and `|-|` — an EMPTY
  # or one-dash "delimiter" — so a data row could fake the delimiter after all: pair a
  # first cell that spells a known header (`retired identifier`) with a `| |` on the next
  # line and the row skipped policing, laundering a stale term in cell 2 (review r3). All
  # real delimiter rows in this tree use `---`+ cells, so `{3,}` costs nothing and shuts
  # the empty/short forms out.
  next_line="$(sed -n "$((lineno + 1))p" "${AUTO_ROOT}/${file}")"
  is_header=""
  if printf '%s\n' "$next_line" | grep -qE \
      '^[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*\|[[:space:]]*:?-{3,}:?[[:space:]]*(\|[[:space:]]*:?-{3,}:?[[:space:]]*)*\|?[[:space:]]*$'; then
    is_header="yes"
  fi
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
