# Agent Tool Surface

The contract a driving agent operates `/auto` through. It exists to kill the
per-session orientation tax (R6/R7): an agent should read this once, or fetch the
machine-readable mirror on demand, instead of re-deriving how to drive auto from
~2000 lines of skill prose every session.

The machine-readable mirror is `python3 lib/run_record.py describe` — one JSON object
carrying the same contract. `tests/unit/run-record.test.sh` asserts set-equality
between the CLI's actual verbs and what `describe` documents, so the two cannot
drift: a verb added without a `describe` entry fails CI.

## The one rule

**Read freely. Write only through a verb that revalidates under the lock and can
reject.**

- Reads are lock-free (atomic-rename snapshot). Read the run-record at
  `<repo>/.claude/auto/<run-id>.json` as often as you like; never re-derive its
  state from anything else.
- Every write commits through a verb that performs precondition-check + mutate +
  predicate-recompute inside a single `_with_locked_run_record` call
  (`lib/run_record_core.py`). The model never holds the lock, and never does a
  read-then-write split across two invocations.

## Why the write rule is not distrust of the agent

It is compare-and-set for slow deciders. An agent decides against a snapshot it
read a minute ago; by the time its write lands, a concurrent sub-agent may have
moved the same step. Both agents reasoned correctly — this is a *timing* problem,
not a judgment one, and no amount of agent intelligence prevents it (two people
editing the same doc offline clobber each other the same way).

The verb closes the window: it re-checks the precondition *inside* the flock and
raises (`InvalidTransition`, `StaleVerdict`, `RunRecordError`) rather than merging a
decision made against stale state. A superseded verdict is rejected, and the
agent re-reads and retries. That is how the runtime absorbs minutes-latency agent
decisions without lost updates. The steering verbs live in `lib/run_record_steering.py`.

The wall is around one unsafe *mechanism* (raw read-modify-write, or holding the
lock across model thinking time), never around the agent's *access*. The rule
exists to protect the agent's own work from being silently lost.

## Verbs

Run `python3 lib/run_record.py describe` for the authoritative list with argument
shapes and per-verb rejection modes. In brief:

- **Read / inspect** (no mutation): `read`, `path`, `is-orphaned`, `describe`.
- **State change**: `transition` (grammar-checked step state change — rejects any
  edge not in `ALLOWED_TRANSITIONS`; will not write findings, use `record-verdict`).
- **Verdict feedback**: `record-verdict` (rejects a stale-attempt verdict),
  `set-gaps-open`, `set-enumerated-steps`, `set-verdict-decision`.
- **Steering** (reshape a live run): `init` (create a run — rejects an existing
  run-id), `add-step` (rejects a duplicate id or an unknown dependency),
  `reshape-deps` (rejects a cycle), `force-skip` (requires a reason — R20; cannot
  bury an existing finding — R16), `register-session` (join the PreToolUse
  ownership set — R21).

This table is fenced by `tests/unit/doc-fence-agent-tool-surface.test.sh`: it
derives the verb set from `describe` (hence from `_VERBS`) and fails if any verb
is not named here. The set-equality test in `tests/unit/run-record.test.sh` binds
`describe` ↔ `_VERBS`; the fence extends that binding to this prose, so a renamed
or added verb cannot silently leave the contract stale.

**Not in this surface:** `lib/workflows.py migrate` (and its revert) are *operator*
utilities for upgrading a workflow file on disk — deliberately kept out of
`_VERBS`/`describe` so the locked, set-equality-enforced agent verb surface stays
the set of verbs an agent actually drives a run with.

## Phase model

`describe` publishes the loop's phase model so an agent orients to phases without
the skill corpus. Phases run in the workflow's `phase_order`; the default order is
`plan` → `handoff` → `work`, with `work` the terminal phase. The **current** phase
is the run-record's `loop_phase` — never `phase_order[0]`, which is only the start
phase. When a phase's predicate is met and it is not the terminal phase, the engine
advances to the next phase; at the terminal phase the run can exit. For a live run,
`describe <run>` overlays THIS run's `phase_order` and current-phase next-action
onto the static surface above.

## What stays deterministic

The agent supplies judgment; the correctness spine stays mechanism. The run-record's
single-lock read-modify-write-recompute (I-1), its state grammar (I-2), attempt
identity, the exit predicate, and the Stop-hook block decision are not agent-
operable and never become so. The agent decides *what* to do; the verbs guarantee
the decision is recorded legally and losslessly.
