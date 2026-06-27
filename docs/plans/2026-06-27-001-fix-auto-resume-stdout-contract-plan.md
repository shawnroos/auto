---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
created: 2026-06-27
type: fix
---

# fix: document the auto resume/tick stdout=JSON contract and the plan-enumerate-pending handshake

## Summary

The original bug report (`docs/handoff.md`) — `/auto:auto-resume` leaking human
prose onto stdout ahead of the re-arm JSON — is **falsified**. Traced statically
and verified at runtime: every resume/tick success path emits exactly one clean
JSON object on stdout with empty stderr. The whole emit chain has zero stdout
writes. There is no leak to fix.

The real defect is **consumer-contract clarity**, not stream pollution. The field
agent hit the producer-handshake path (`plan-enumerate-pending`), executed the
enumerate prepare op (`set-enumerated-units` succeeded), but read the handshake
intent as "parse noise / ceremony" and skipped re-arming the next tick — jumping
straight to building. The driver-facing docs (`skills/auto/SKILL.md`,
`commands/auto-resume.md`) never state (a) that resume/tick stdout is *always*
exactly one JSON object to parse whole, nor (b) what `plan-enumerate-pending`
obliges the driver to do. This plan closes both gaps and adds a regression guard.

**No production code logic changes** — docs plus one new unit test.

---

## Problem Frame

- **Symptom (as reported):** "the resume printed a non-JSON message (parse noise),
  but set-enumerated-units succeeded" → driver treated the re-arm as ceremony and
  skipped to building.
- **Verified reality:** stdout is always one valid JSON object; stderr is clean on
  success. The "non-JSON noise" the agent perceived was the *PREPARE envelope*
  surfaced inside a valid `plan-enumerate-pending` intent — semantics it didn't
  recognize, not a malformed stream.
- **Root cause:** the driver-facing contract is undocumented on two axes — the
  "stdout = exactly one JSON object" parse guarantee, and the
  `plan-enumerate-pending` handshake obligation (stash units → re-arm → the *next*
  tick flips to work).
- **Why the handoff's proposed guard was insufficient:** its "stdout is one JSON
  object" assertion would have *passed* while the real bug persisted. The guard
  must also assert clean stderr, and the handshake must be documented — the test
  alone cannot fix a comprehension gap.

---

## Scope Boundaries

**In scope**
- Document the stdout=JSON-only parse contract where the driver is told to consume
  resume/tick output.
- Document the `plan-enumerate-pending` producer-handshake obligation.
- Add a regression test asserting one-JSON-object stdout AND clean stderr on the
  resume success paths.

**Out of scope / non-goals**
- Any change to emitter, ledger, tick, or resume *behavior*. Stdout is already
  correct; this plan does not touch the emit chain.
- Routing prose to stderr (the handoff's option (a)) — there is no stdout prose to
  route; that fix targets a non-existent leak.
- A sentinel/last-line extraction scheme — gold-plating against a leak that does
  not exist (user declined this scope).

### Deferred to Follow-Up Work
- None.

---

## Key Technical Decisions

**KTD1 — Fix lands in docs + test, not code.** Empirical verification (both resume
success paths captured with streams separated) shows stdout is exactly one clean
JSON object and stderr is empty. The defect is comprehension, so the durable fix is
the driver-facing contract plus a guard that would catch a *future* regression on
either axis (stdout shape OR stderr cleanliness).

**KTD2 — The guard asserts BOTH stdout-is-one-JSON-object AND stderr-is-clean.**
The handoff's stdout-only assertion passes today and would pass through the real
bug. Clean-stderr is the second axis: it locks in that the success path emits no
prose anywhere, so a later change that starts writing a warning to either stream
fails the test.

**KTD3 — Mirror the existing harness exactly.** The regression test replicates
`tests/unit/auto-resume-advance.test.sh`'s env (importlib module loading,
`CLAUDE_AUTO_REPO`, `CLAUDE_CODE_SESSION_ID`, child-session marker cleared, fresh
a1 run). A hand-rolled ledger would not exercise the real code path
(`feedback_adhoc_probe_must_replicate_test_harness_env`).

---

## Implementation Units

### U1. Document the stdout=JSON contract + plan-enumerate-pending handshake in SKILL.md

**Goal:** Make the driver-facing tick/resume contract explicit so a driving agent
parses the whole stdout as one JSON object and knows what `plan-enumerate-pending`
obliges it to do.

**Dependencies:** none.

**Files:**
- `skills/auto/SKILL.md` (modify) — §2 "Arm the tick chain" (the re-arm intent
  table, ~lines 60-71) and the seam/resume references (~lines 73-83).

**Approach:**
- At §2, state plainly: every tick/resume emits **exactly one JSON object** on
  stdout (parse the entire stdout with `json.loads`; there is no prose to strip);
  all human/diagnostic prose goes to stderr.
- Document the `plan-enumerate-pending` handshake: when the intent's `advanced`
  field is `plan-enumerate-pending`, the driver must run the enumerate prepare op
  and stash units via `set-enumerated-units`, then **re-arm a tick** — the *next*
  tick flips `plan → work`. It is NOT a signal to start building, and the envelope
  it carries is not "ceremony."
- During implementation, verify the exact `action`/`advanced` field pairing that
  accompanies `plan-enumerate-pending` against `lib/tick.py` and
  `lib/tick_advance.py:_maybe_seam` (~line 784) so the doc names the real fields.

**Patterns to follow:** the existing §2 phase-aware dispatch table; keep the same
terse table/prose voice as the surrounding sections.

**Test scenarios:** Test expectation: none — documentation only, no behavioral
change. Coverage for the contract it documents lives in U3.

**Verification:** §2 states the one-JSON-object parse guarantee and the
`plan-enumerate-pending` obligation; field names match the code.

---

### U2. Add the stdout=JSON-only contract note to the resume command doc

**Goal:** Where the resume command tells the driver how to consume resume output,
state the parse contract so it is not inferred.

**Dependencies:** none (independent of U1 — different file).

**Files:**
- `commands/auto-resume.md` (modify) — the Dispatch section (~lines 68-79), where
  the script's stdout is what the driver reads.

**Approach:** Add one line near Dispatch: resume stdout on the re-arm paths is
exactly one JSON object (`action: arm-tick`); parse it whole, all prose is on
stderr. Keep it to a sentence — the command doc stays a routing/parse layer, the
handshake detail lives in SKILL.md (U1).

**Patterns to follow:** the existing note voice in `commands/auto-resume.md`; the
script-as-SSOT framing already in the doc.

**Test scenarios:** Test expectation: none — documentation only.

**Verification:** the Dispatch section names the one-JSON-object parse contract.

---

### U3. Regression test: resume success paths emit one JSON object on stdout + clean stderr

**Goal:** Lock in that `continue` (seam→work) and `advance` (plan) emit exactly one
JSON object on stdout AND nothing on stderr, so a future change that pollutes either
stream fails.

**Dependencies:** none (tests current behavior, which already passes).

**Files:**
- `tests/unit/auto-resume-stdout-contract.test.sh` (create).

**Approach:**
- Mirror `tests/unit/auto-resume-advance.test.sh` exactly: importlib-load `auto`,
  `ledger`, `auto-resume`, `tick`; set `CLAUDE_AUTO_REPO`,
  `CLAUDE_CODE_SESSION_ID`, pop `CLAUDE_CODE_CHILD_SESSION`; create a fresh a1 run.
- Capture stdout and stderr **separately** (`redirect_stdout` + `redirect_stderr`
  into distinct buffers), then assert: `json.loads(stdout.strip())` succeeds AND
  `stderr.strip() == ""`.
- Register the test in the runner the way sibling unit tests are
  (`tests/run.sh` — confirm the registration mechanism during implementation).

**Patterns to follow:** `tests/unit/auto-resume-advance.test.sh` (harness env,
`it`/`pass`/`fail` helpers, `run_scenario` PYEOF block, pipe-delimited result
parsing).

**Execution note:** this guards already-correct behavior, so it passes on first
run. To prove it actually guards: temporarily add a `sys.stdout.write("noise\n")`
before `_emit_rearm` (or a `sys.stderr.write`) and confirm the test FAILS, then
revert via the Edit tool — `feedback_new_tests_need_deliberate_fail_smoke_check`
and `feedback_deliberate_fail_revert_via_edit_not_inscript`.

**Test scenarios:**
- `continue` at a paused seam (`loop_phase=seam`, `seam_paused=true`): stdout is
  exactly one JSON object; stderr is empty. (Drives `_cmd_continue` seam→work.)
- `advance` at the plan phase (fresh a1, `plan_step=null`): stdout is exactly one
  JSON object; stderr is empty. (Drives `_cmd_advance` plan→enumerate.)
- Both emitted objects carry `"action": "arm-tick"` (sanity that we captured the
  re-arm intent, not an empty/terminal path).

**Verification:** the new test passes in `tests/run.sh`; the deliberate-fail smoke
check fails when prose is injected on either stream and passes again after revert.

---

## System-Wide Impact

- Driver-facing contract only — affects how a driving agent (this session, or a
  resumed one) interprets resume/tick stdout. No runtime behavior change, so no
  impact on in-flight runs, ledgers, or the emit chain.
- The new test adds one file under `tests/unit/`; it exercises existing code paths
  with no new fixtures beyond the shared harness pattern.

---

## Parallelism Analysis

All three units are **independent and parallel-safe** — disjoint files, no shared
edit surface, no ordering dependency:

| Unit | File | Depends on |
|------|------|------------|
| U1 | `skills/auto/SKILL.md` | — |
| U2 | `commands/auto-resume.md` | — |
| U3 | `tests/unit/auto-resume-stdout-contract.test.sh` | — |

U1 and U2 express the same contract on two surfaces but touch different files, so
they can land concurrently. U3 tests current behavior and does not depend on the
doc edits. Given the small surface, a single implementer can also land all three
in one pass; the lack of dependencies just means no required ordering.

---

## Definition of Done

- `skills/auto/SKILL.md` documents the stdout=one-JSON-object parse contract and
  the `plan-enumerate-pending` handshake obligation, with field names verified
  against the code.
- `commands/auto-resume.md` carries the one-line stdout=JSON-only parse note.
- `tests/unit/auto-resume-stdout-contract.test.sh` exists, asserts one-JSON-object
  stdout AND clean stderr on both resume success paths, passes in `tests/run.sh`,
  and was smoke-checked to fail on injected prose.
- No production code logic changed.
- `/ce-code-review` run and driven to green (no remaining P0/P1/P2).
- PR opened.

---

## Verification Contract

- `bash tests/unit/auto-resume-stdout-contract.test.sh` passes.
- `bash tests/run.sh` (or the unit subset) passes with the new test registered.
- `git diff` shows changes only in `skills/auto/SKILL.md`,
  `commands/auto-resume.md`, `tests/unit/auto-resume-stdout-contract.test.sh`
  (and the runner registration line) — no `lib/` logic changes.
