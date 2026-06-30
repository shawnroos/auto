---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: docs/handoff.md
created: 2026-06-27
type: fix
title: "fix: /auto drive-friction — path-scope destructive backstop + verdict CLI verbs"
---

# fix: /auto drive-friction — path-scope destructive backstop + verdict CLI verbs

## Summary

Two narrow, independent fixes that made `/auto` 0.6.6 high-friction to drive a real feature build (field report in `docs/handoff.md`):

1. **Path-scope the destructive-action backstop.** `rm -rf` currently matches on *any* path, so benign teardown of ephemeral temp dirs (`$TMPDIR`, `/tmp`, `/private/tmp`, macOS `/var/folders/...`, the scratchpad) false-fires the fail-closed backstop — it pauses and latches the run. In one field build it fired 7× on fan-out agents' temp teardown + 1× on the operator's finalize cleanup. Make the `rm` matcher path-aware: exempt deletions whose targets all resolve under a known-ephemeral root, while staying fail-closed for repo-root / `$HOME` / relative-path / unparseable deletes.

2. **Expose `record-verdict` (and `set-verdict-decision`) as CLI verbs.** Both exist as importable mutators (`lib/ledger.py:102`, `:107`) but the `_cli` dispatch only exposes read / path / transition / is-orphaned / set-gaps-open / set-enumerated-units. The work-loop's only ledger-write tool is `lib/ledger.sh`, so without these verbs an operator must hand-drive `ce-work` and keep the ledger honest through the Python API — the same uninvokable-instruction bug class the v0.4.3 feedback verbs already closed.

This is a pure-fix plan; no product behavior changes. The backstop keeps failing closed for every genuinely destructive command — it only stops mis-classifying ephemeral temp cleanup.

---

## Problem Frame

The destructive backstop (`lib/on-pretooluse-action.py`) is a deterministic, fail-closed minimum-set guard: on a confirmed-destructive command for a confirmed live owned run, it pauses the run via the ledger pause seam. Failing closed is correct and intentional. The defect is **precision, not posture**: the `rm -rf` / `rm -fr` patterns (`lib/on-pretooluse-action.py:102-103`) match the verb+flags with zero path awareness, so an ephemeral temp-dir teardown is indistinguishable from `rm -rf ~/important`. Because the pause *latches* (`backstop_latched=True`), a single false-fire leaves the run paused until an operator runs `/auto-resume continue` or `abort` — exactly the "ledger left PAUSED" state the field report describes.

Separately, the ledger CLI is the model/operator's only Bash-reachable write surface (`lib/ledger.sh` shims `ledger.py`). `record_verdict` — the verdict-self-write path the work-loop depends on — and `set_verdict_decision` — the gate advance/iterate/exit decision — are importable but have no CLI verb, so hand-driving the work-loop faithfully requires the Python API. The field operator drove `ce-work` per unit by hand for this reason.

---

## Requirements

- **R1.** `rm -rf` / `rm -fr` of an ephemeral temp path (every target under a known-ephemeral root) on a live owned run → **ALLOW** (no pause, no latch, no audit record).
- **R2.** `rm -rf` / `rm -fr` of a repo-root path, a `$HOME` path, a relative path (resolves under cwd = repo), or any target the matcher cannot confidently classify as ephemeral → **GATE** (pause + deny, unchanged from today). Fail-closed is the default for anything not provably ephemeral.
- **R3.** All other destructive patterns (force-push, `reset --hard`, `checkout/restore .`, `clean -f`, `branch -D`, `npm publish`, `gh` destructive subcommands) are **unaffected** — path-scoping applies only to the `rm` family.
- **R4.** A `record-verdict` CLI verb persists findings onto a unit via `record_verdict`, repo auto-resolved from cwd/`$CLAUDE_AUTO_REPO`, mirroring the `set-gaps-open` / `set-enumerated-units` ergonomics (operator passes only the run-id).
- **R5.** A `set-verdict-decision` CLI verb persists a gate unit's advance/iterate/exit decision via `set_verdict_decision`, same repo-resolution ergonomics.
- **R6.** Both new verbs reject malformed input (bad JSON, non-array findings, decision not in the enum, unknown unit) with a non-zero exit and a stderr message — never a silent partial write.
- **R7.** Regression coverage: `rm -rf $TMPDIR/x` → ALLOW; `rm -rf <repo>/x` and `rm -rf build/` → GATE; `record-verdict` and `set-verdict-decision` round-trip through the CLI into the ledger.

---

## Key Technical Decisions

### KTD-1. Exemption is an allowlist of ephemeral roots, applied only to the `rm` family, fail-closed on any doubt.

The backstop's value is failing closed, so the exemption must be conservative: a delete is exempt **only when every one of its path targets provably resolves under a known-ephemeral root**. If any target is non-ephemeral, relative, contains `..`, or cannot be parsed, the command gates. This keeps the asymmetry the backstop was built on — over-gating a benign temp delete is now fixed, but under-gating a real delete must never be introduced.

**Ephemeral roots (allowlist):** the literal shell tokens `$TMPDIR` / `${TMPDIR}`, and the absolute prefixes `/tmp/`, `/private/tmp/`, `/var/folders/`, `/private/var/folders/`, plus the session scratchpad root when discoverable from the environment (`$CLAUDE_*` scratch var if present). Each prefix requires a trailing separator (or a child component) so that deleting the temp root *itself* (`rm -rf /tmp`) is **not** auto-exempted — only deletions *under* it.

**Why match the literal `$TMPDIR` token, not just resolved paths:** the hook reads `tool_input.command` — the literal string the agent wrote — so `rm -rf "$TMPDIR/foo"` arrives with `$TMPDIR` unexpanded. Both the literal token and the resolved macOS form (`/var/folders/.../T/...`) must be recognized; the field false-positives were `$TMPDIR` teardown.

**Rejected alternative — resolve/normalize every path and compare against repo-root + `$HOME`:** a denylist ("gate iff under repo or home") inverts the fail-closed default — an unparseable or novel path would fall through to ALLOW. The allowlist keeps unknown → GATE.

### KTD-2. Implement the exemption as a dedicated helper invoked at the `rm`-match site, not by weakening the regex.

Add a small pure helper (e.g. `_rm_targets_all_ephemeral(command) -> bool`) that extracts the path arguments from an `rm -rf` / `rm -fr` invocation (stripping the `-rf`/`-fr` flags, an optional `--` end-of-options marker, and surrounding quotes) and returns True only if there is at least one target and all targets are ephemeral. Thread it into `_matched_destructive` so that when an `rm` pattern matches but the helper returns True, that match is skipped (treated as benign). The git/gh/npm patterns never reach the helper. This isolates the path logic, keeps the regex set readable, and makes the exemption independently testable.

### KTD-3. New CLI verbs mirror the v0.4.3 feedback-verb precedent exactly.

`record-verdict` and `set-verdict-decision` follow the `set-gaps-open` / `set-enumerated-units` shape established in `lib/ledger.py:159-174`: positional argv, repo auto-resolved via `resolve_repo()`, JSON payloads parsed with `json.loads` and shape-validated before the mutator call, `LedgerError` → exit 1, `IndexError`/`ValueError` → exit 2. This keeps the CLI internally consistent and `$ARGUMENTS`-safe (all parsing positional, never string-interpolated into shell).

### KTD-4. Coordinate with the adjacent `resume-stdout-json` worktree on `ledger.py`.

`docs/plans/2026-06-27-001-fix-auto-resume-stdout-contract-plan.md` also touches `ledger.py` (CLI / `tick_advance` area). The new verbs are purely additive to the `_cli` dispatch chain, so the merge surface is small, but rebase on `main` before landing and re-run the ledger CLI tests after rebase.

---

## Implementation Units

### U1. Path-scope the `rm` destructive backstop

**Goal:** Make `rm -rf` / `rm -fr` matches exempt ephemeral-temp-only deletions while keeping every other delete fail-closed.

**Requirements:** R1, R2, R3.

**Dependencies:** none.

**Files:**
- `lib/on-pretooluse-action.py` — add `_rm_targets_all_ephemeral(command)` helper + the ephemeral-root allowlist; thread the exemption into `_matched_destructive` at the `rm`-match site. Update the BYPASS RESIDUALS / pattern-set docstring (~lines 33-44, 69-117) to document the new path-scoping behavior and that it applies to the `rm` family only.

**Approach:**
- Define the ephemeral-root allowlist as a module constant near `_DESTRUCTIVE_PATTERNS`.
- The helper: tokenize the command's `rm ...` arguments (a light split is sufficient — quotes stripped, `-rf`/`-fr` and a leading `--` dropped, flag-leading tokens ignored); for each remaining target, strip surrounding quotes; reject (→ not-ephemeral) any target that is relative, contains `..`, or does not start with an allowlist prefix (with separator). Return True only if there is ≥1 target and all are ephemeral.
- Mark the two `rm` entries in `_DESTRUCTIVE_PATTERNS` (third tuple element flag, or a label set) so `_matched_destructive` knows which matches are path-exemptible; when such a match fires, call the helper and `continue` (skip) if it returns True.
- Preserve the existing return contract: `_matched_destructive` still returns the human label or None; an exempted `rm` returns None (benign → allow) unless a *different* pattern also matches.

**Patterns to follow:** the existing `_matched_destructive` / `_DESTRUCTIVE_PATTERNS` structure (`lib/on-pretooluse-action.py:77-127`); keep the comment density and the "documented minimum-set, residuals out of scope" framing.

**Execution note:** characterization-first — before changing `_matched_destructive`, add the U2 ALLOW/GATE test cases (they will fail against current behavior for the ephemeral case), then implement until green. Keep the existing `rm -rf build/` → GATE case passing throughout.

**Test scenarios:** covered by U2 (tests live alongside the existing backstop suite).

**Verification:** `rm -rf $TMPDIR/x`, `rm -rf "$TMPDIR/x"`, `rm -rf /tmp/x`, `rm -rf /private/var/folders/ab/cd/T/x` on a live owned run no longer pause the run; `rm -rf build/`, `rm -rf /tmp` (root itself), `rm -rf <repo>/sub`, `rm -rf ~/x`, `rm -rf /tmp/../etc` still pause + deny; force-push / `reset --hard` / etc. unchanged.

---

### U2. Backstop regression tests (ALLOW ephemeral / GATE real)

**Goal:** Lock the U1 exemption behavior against regression in the canonical backstop integration suite.

**Requirements:** R1, R2, R3, R7.

**Dependencies:** U1.

**Files:**
- `tests/integration/advisor-gate.test.sh` — extend the existing action-backstop section (~lines 263-361) with ephemeral-ALLOW and real-GATE cases using the existing `EVENT` helper and `permissionDecision` extraction.

**Approach:**
- **ALLOW cases** (assert: no `permissionDecision: deny`, driver stays `self`, no `blocked_on`, no `advisor_audit` record appended): `rm -rf $TMPDIR/scratch`, `rm -rf "$TMPDIR/scratch"`, `rm -rf /tmp/auto-test.XXXX`, `rm -rf /private/var/folders/xx/yy/T/auto.XXXX`.
- **GATE cases** (assert: `deny` + run PAUSED + `blocked_on` recorded, unchanged from today): keep the existing `rm -rf build/`; add `rm -rf /tmp` (temp root itself), `rm -rf "$HOME/important"`, `rm -rf ../sibling`, `rm -rf /tmp/../etc`.
- **Scope-unchanged guard:** an ephemeral `rm -rf $TMPDIR/x` with a *mismatched* session_id still ALLOWs and leaves the ledger untouched (no behavior change vs. existing mismatched-session case).
- Add one deliberate-fail smoke check (per repo convention) confirming the ALLOW assertion fails if the exemption is reverted.

**Patterns to follow:** the `EVENT` helper, `permissionDecision` extraction (`tests/integration/advisor-gate.test.sh:121-125`), and the `for cmd in ...` destructive-loop structure (~lines 290-307).

**Test scenarios:**
- Happy path: every ALLOW case above passes the tool call through untouched. Covers R1.
- Boundary: temp root itself (`/tmp`) and trailing-separator handling gate, not exempt. Covers R2.
- Error/evasion: `..`-containing and relative paths gate (no allowlist escape). Covers R2.
- Integration: ephemeral exemption does not append an `advisor_audit` action record (the pause path is never entered). Covers R1.
- Regression: all pre-existing GATE cases (`rm -rf build/`, force-push, etc.) still deny + pause. Covers R3.

**Verification:** `bash tests/integration/advisor-gate.test.sh` passes; reverting U1 turns the ALLOW cases red.

---

### U3. Add `record-verdict` + `set-verdict-decision` CLI verbs

**Goal:** Make the work-loop's verdict + gate-decision writes drivable through `lib/ledger.sh` without the Python API.

**Requirements:** R4, R5, R6.

**Dependencies:** none (independent of U1/U2).

**Files:**
- `lib/ledger.py` — add `record-verdict` and `set-verdict-decision` branches to `_cli` (~lines 134-176), mirroring `set-enumerated-units`.
- `lib/ledger.sh` — extend the CLI-verb doc comment block (~lines 21-28) to list the two new verbs.
- `docs/contracts/driver-reference.md` — document the new verbs in the ledger-CLI surface section (locate the existing feedback-verb / ledger-CLI reference and add parallel entries).

**Approach:**
- `record-verdict <run> <unit> <json-findings> [attempt]`: `json.loads` the findings (must be a JSON array; non-array → stderr + exit 2), optional positional `attempt` parsed as int, call `record_verdict(resolve_repo(), run, unit, findings, attempt=...)`. `StaleVerdict`/`UnknownUnit` are `LedgerError` subclasses → existing `except LedgerError` → exit 1.
- `set-verdict-decision <run> <gate-unit> <decision> [json-payload]`: optional `payload` parsed via `json.loads` (must be a dict or absent), call `set_verdict_decision(resolve_repo(), run, gate_unit, decision, payload=...)`. Invalid decision (not in `iteration.DECISIONS`) raises `LedgerError` → exit 1.
- Keep all parsing positional; do not interpolate into shell (repo `$ARGUMENTS`-safety convention).

**Patterns to follow:** `set-gaps-open` / `set-enumerated-units` branches (`lib/ledger.py:159-174`) — repo via `resolve_repo()`, JSON shape-validated before the mutator, the existing `except LedgerError` / `except (IndexError, ValueError)` ladder.

**Test scenarios:** covered by U4.

**Verification:** `bash lib/ledger.sh record-verdict <run> <unit> '[{"severity":"P1","note":"x"}]'` persists `findings[]` and `verdict_at`; `set-verdict-decision <run> <gate> advance` persists `dispatch_context.decision`; malformed inputs exit non-zero.

---

### U4. CLI verb round-trip tests

**Goal:** Assert both new verbs persist correctly through the CLI, auto-resolve the repo, and reject malformed input.

**Requirements:** R4, R5, R6, R7.

**Dependencies:** U3.

**Files:**
- `tests/unit/ledger-cli-feedback.test.sh` — add `record-verdict` and `set-verdict-decision` round-trip + malformed-input cases alongside the existing `set-gaps-open` / `set-enumerated-units` tests.

**Approach:**
- Reuse the hermetic-repo + `read_field` helper already in the file. The seed ledger has one `plan` unit; add (or transition to) a unit in a verdict-writable state so `record_verdict` succeeds, and a gate unit for `set-verdict-decision`. Use the existing `CLAUDE_AUTO_TEST_NO_ATTEMPT_CHECK` hatch if attempt-tracking complicates the fixture.
- **record-verdict:** CLI call with a valid findings array → assert `findings[]` persisted and `verdict_at` set (run-id only, repo auto-resolved from `$CLAUDE_AUTO_REPO`).
- **set-verdict-decision:** CLI call with `advance` → assert `dispatch_context.decision == "advance"`; with a payload → assert `decision_payload` persisted.
- **Malformed (deliberate-fail / rc != 0):** non-array findings; invalid severity; decision not in the enum; unknown unit.

**Patterns to follow:** the `it`/`pass`/`fail` harness, hermetic `mktemp -d` repo, `read_field` eval helper, and the malformed-payload `if bash ...; then fail` pattern in `tests/unit/ledger-cli-feedback.test.sh`.

**Test scenarios:**
- Happy path: valid `record-verdict` and `set-verdict-decision` round-trip into the ledger via the CLI. Covers R4, R5.
- Repo resolution: both succeed with run-id only (repo from `$CLAUDE_AUTO_REPO`). Covers R4, R5.
- Error: non-array findings → exit 2; invalid severity → exit 1; bad decision enum → exit 1; unknown unit → exit 1. Covers R6.

**Verification:** `bash tests/unit/ledger-cli-feedback.test.sh` passes; reverting U3 turns the new cases red.

---

### U5. Version bump + changelog/docstring sweep

**Goal:** Publish the fix as a version increment with an honest changelog line, consistent with recent release commits.

**Requirements:** none (release hygiene).

**Dependencies:** U1, U3 (the behavior being published).

**Files:**
- `.claude-plugin/plugin.json` — bump `version` `0.6.7` → `0.6.8`.
- `CHANGELOG.md` if present (else skip) — add a `0.6.8` entry: path-scoped destructive backstop (ephemeral-temp exemption) + `record-verdict` / `set-verdict-decision` CLI verbs.

**Approach:** Mirror the recent bump commit (`280329e chore: bump auto 0.6.6 -> 0.6.7`). Keep the changelog line plain — name the two fixes and the user-visible effect (no more false pauses on temp cleanup; work-loop drivable from the CLI).

**Test scenarios:** `Test expectation: none — version/doc metadata only.`

**Verification:** `.claude-plugin/plugin.json` shows `0.6.8`; no test references the old version string.

---

## Scope Boundaries

**In scope:** path-scoping the `rm -rf`/`rm -fr` backstop matcher; two additive ledger CLI verbs; regression tests for both; version bump.

**Out of scope (unchanged by design):**
- The documented backstop residuals (flag-reorder `rm -vrf`, long-form `rm --recursive --force`, compound `a; rm -rf b`, eval/obfuscation, MCP write tools) — `lib/on-pretooluse-action.py` docstring §BYPASS RESIDUALS. Path-scoping does not widen or narrow this set; it only refines the `rm -rf`/`rm -fr` matches the classifier already catches.
- Path-scoping any non-`rm` destructive pattern (force-push, `reset --hard`, etc.) — no path-exemption concept applies.

### Deferred to Follow-Up Work
- **Unlatching the currently-paused field ledger.** The field run's ledger is paused/latched; that is the operator's `/auto-resume continue`/`abort` action, not this workstream. This plan only ensures the false-fire that latched it won't recur and that resume still works once the backstop is fixed.
- A `dispatch` CLI verb (the field report's "dispatch is Python-API-only" friction). Out of scope here; `record-verdict` is the verb that unblocks faithful hand-driving.

---

## Verification Contract

- `bash tests/integration/advisor-gate.test.sh` — backstop ALLOW/GATE behavior (U2).
- `bash tests/unit/ledger-cli-feedback.test.sh` — CLI verb round-trips (U4).
- `bash tests/run.sh` (or the repo's full-suite entrypoint) — no regression across the suite.
- Each new test, when its corresponding fix is reverted, goes red (deliberate-fail smoke check).

---

## Definition of Done

- `rm -rf`/`rm -fr` of an ephemeral-temp-only target on a live owned run no longer pauses the run; all other deletes still fail closed (R1, R2, R3).
- `record-verdict` and `set-verdict-decision` are CLI verbs that round-trip into the ledger with run-id-only ergonomics and reject malformed input (R4, R5, R6).
- Regression tests cover both fixes and fail when reverted (R7).
- Version bumped; changelog/docstrings reflect the change.
- Rebased on `main`; ledger CLI tests re-run green after rebase (KTD-4 coordination with `resume-stdout-json`).
