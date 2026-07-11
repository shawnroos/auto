# Agent Tool Surface

The contract a driving agent operates `/auto` through. It exists to kill the
per-session orientation tax (R6/R7): an agent should read this once, or fetch the
machine-readable mirror on demand, instead of re-deriving how to drive auto from
~2000 lines of skill prose every session.

The machine-readable mirror is `python3 lib/ledger.py describe` — one JSON object
carrying the same contract. `tests/unit/ledger.test.sh` asserts set-equality
between the CLI's actual verbs and what `describe` documents, so the two cannot
drift: a verb added without a `describe` entry fails CI.

## The one rule

**Read freely. Write only through a verb that revalidates under the lock and can
reject.**

- Reads are lock-free (atomic-rename snapshot). Read the ledger at
  `<repo>/.claude/auto/<run-id>.json` as often as you like; never re-derive its
  state from anything else.
- Every write commits through a verb that performs precondition-check + mutate +
  predicate-recompute inside a single `_with_locked_ledger` call
  (`lib/ledger_core.py`). The model never holds the lock, and never does a
  read-then-write split across two invocations.

## Why the write rule is not distrust of the agent

It is compare-and-set for slow deciders. An agent decides against a snapshot it
read a minute ago; by the time its write lands, a concurrent sub-agent may have
moved the same unit. Both agents reasoned correctly — this is a *timing* problem,
not a judgment one, and no amount of agent intelligence prevents it (two people
editing the same doc offline clobber each other the same way).

The verb closes the window: it re-checks the precondition *inside* the flock and
raises (`InvalidTransition`, `StaleVerdict`, `LedgerError`) rather than merging a
decision made against stale state. A superseded verdict is rejected, and the
agent re-reads and retries. That is how the runtime absorbs minutes-latency agent
decisions without lost updates. The steering verbs live in `lib/ledger_steering.py`.

The wall is around one unsafe *mechanism* (raw read-modify-write, or holding the
lock across model thinking time), never around the agent's *access*. The rule
exists to protect the agent's own work from being silently lost.

## Verbs

Run `python3 lib/ledger.py describe` for the authoritative list with argument
shapes and per-verb rejection modes. In brief:

- **Read / inspect** (no mutation): `read`, `path`, `is-orphaned`, `describe`.
- **Verdict feedback**: `record-verdict` (rejects a stale-attempt verdict),
  `set-gaps-open`, `set-enumerated-units`, `set-verdict-decision`.
- **Steering** (reshape a live run): `init` (create a run — rejects an existing
  run-id), `add-unit` (rejects a duplicate id or an unknown dependency),
  `reshape-deps` (rejects a cycle), `force-skip` (requires a reason — R20; cannot
  bury an existing finding — R16), `register-session` (join the PreToolUse
  ownership set — R21).

## What stays deterministic

The agent supplies judgment; the correctness spine stays mechanism. The ledger's
single-lock read-modify-write-recompute (I-1), its state grammar (I-2), attempt
identity, the exit predicate, and the Stop-hook block decision are not agent-
operable and never become so. The agent decides *what* to do; the verbs guarantee
the decision is recorded legally and losslessly.
