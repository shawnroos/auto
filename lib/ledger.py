#!/usr/bin/env python3
"""auto ledger facade — re-exports the ledger surface from
ledger_core / ledger_mutators / ledger_emitters.

This module was split (B5) for maintainability: the implementation now lives in
three sibling modules along an acyclic DAG (core ← mutators ← emitters ← this
facade). This file re-exports the WHOLE surface — every public name PLUS the
private helpers consumers reach through the ``ledger.`` namespace (``_now_iso``,
``_parse_iso``, ``_with_locked_ledger``) — so existing callers that do
``ledger = _bootstrap.load_ledger()`` and reference ``ledger.<name>`` keep
resolving unchanged. See those three modules for the implementation and
docs/contracts/ledger-schema.md for the authoritative spec (if they disagree,
the contract wins and the code is the bug).

  * ledger_core      — constants, errors, paths, time helpers, the pure predicate
                       logic (recompute_predicate + B7 helpers, unit_is_terminal,
                       is_orphaned), the atomic-write + flock primitives, and
                       init_ledger / read_ledger.
  * ledger_mutators  — the grammar-checked, flock-serialized scalar mutators
                       (transition, record_verdict, set_loop, set_gaps_open,
                       set_*, accumulate_active_time, increment_iteration_attempts).
  * ledger_emitters  — phase-transition + iteration emission/composite paths
                       (transition_and_emit, emit_within_phase, reset_for_iteration,
                       atomic_iterate_step, and their pure helpers).

The CLI (``_cli`` + ``__main__`` block) stays here so lib/ledger.sh can keep
routing through ``ledger.py``.
"""

from __future__ import annotations

import json
import os
import sys

# Load the implementation modules via the standard bootstrap loader. The ledger
# surface is loaded from many sites by file path (the test harness uses
# spec_from_file_location, which does NOT add lib/ to sys.path), so a plain
# `from ledger_core import ...` is not guaranteed to resolve. Prepending lib/ +
# routing through _bootstrap.load_lib_module is the one robust load strategy the
# codebase already uses for sibling modules.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

ledger_core = load_lib_module("ledger_core")
ledger_mutators = load_lib_module("ledger_mutators")
ledger_emitters = load_lib_module("ledger_emitters")

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from ledger_core: constants + errors + pure logic + primitives.
# Every name is listed explicitly (greppable) so the re-export surface is
# auditable and a consumer's `ledger.<name>` keeps resolving after the split.

# Module constants.
GRACE_SECONDS = ledger_core.GRACE_SECONDS
DEFAULT_STALL_THRESHOLD_SECONDS = ledger_core.DEFAULT_STALL_THRESHOLD_SECONDS
DRIVER_SELF_STALE_SECONDS = ledger_core.DRIVER_SELF_STALE_SECONDS
LOOP_PHASES = ledger_core.LOOP_PHASES
PLAN_STEPS = ledger_core.PLAN_STEPS
ExitReason = ledger_core.ExitReason
UNIT_STATES = ledger_core.UNIT_STATES
SEVERITIES = ledger_core.SEVERITIES
GATING_SEVERITIES = ledger_core.GATING_SEVERITIES
ALLOWED_TRANSITIONS = ledger_core.ALLOWED_TRANSITIONS

# Error hierarchy. Re-bind the SAME classes (not new ones) so callers that
# `except ledger.LedgerError` catch a raise from any implementation module —
# the modules all raise ledger_core's classes, and the facade re-exports those
# exact objects, so `except` works across the split.
LedgerError = ledger_core.LedgerError
LedgerNotFound = ledger_core.LedgerNotFound
LedgerExists = ledger_core.LedgerExists
InvalidTransition = ledger_core.InvalidTransition
StaleVerdict = ledger_core.StaleVerdict
UnknownUnit = ledger_core.UnknownUnit

# Paths + time helpers (incl. the private time helpers consumers reach for).
ledger_path = ledger_core.ledger_path
lock_path = ledger_core.lock_path
_now_iso = ledger_core._now_iso
_parse_iso = ledger_core._parse_iso

# Pure predicate logic.
gating_severities = ledger_core.gating_severities
unit_is_terminal = ledger_core.unit_is_terminal
recompute_predicate = ledger_core.recompute_predicate
_compute_iteration_pending = ledger_core._compute_iteration_pending
is_orphaned = ledger_core.is_orphaned

# Primitives + create/read API (incl. the private RMW primitive consumers reach
# for in tests/integration).
_with_locked_ledger = ledger_core._with_locked_ledger
init_ledger = ledger_core.init_ledger
read_ledger = ledger_core.read_ledger

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from ledger_mutators: grammar-checked scalar write paths.

transition = ledger_mutators.transition
record_verdict = ledger_mutators.record_verdict
set_loop = ledger_mutators.set_loop
set_gaps_open = ledger_mutators.set_gaps_open
set_enumerated_units = ledger_mutators.set_enumerated_units
set_winner_unit_id = ledger_mutators.set_winner_unit_id
set_verdict_decision = ledger_mutators.set_verdict_decision
set_bound_override = ledger_mutators.set_bound_override
set_exit_reason = ledger_mutators.set_exit_reason
accumulate_active_time = ledger_mutators.accumulate_active_time
increment_iteration_attempts = ledger_mutators.increment_iteration_attempts

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from ledger_emitters: phase-transition + iteration emission paths.

transition_and_emit = ledger_emitters.transition_and_emit
emit_within_phase = ledger_emitters.emit_within_phase
reset_for_iteration = ledger_emitters.reset_for_iteration
atomic_iterate_step = ledger_emitters.atomic_iterate_step


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/ledger.sh routes through this). $ARGUMENTS-safe: all parsing
# is positional here, never string-interpolated into shell.


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: ledger.py <subcommand> ...\n")
        return 2
    cmd = argv[0]
    try:
        if cmd == "read":
            repo, run = argv[1], argv[2]
            json.dump(read_ledger(repo, run), sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        if cmd == "path":
            print(ledger_path(argv[1], argv[2]))
            return 0
        if cmd == "transition":
            repo, run, unit, state = argv[1], argv[2], argv[3], argv[4]
            transition(repo, run, unit, state)
            return 0
        if cmd == "is-orphaned":
            repo, run = argv[1], argv[2]
            print("true" if is_orphaned(read_ledger(repo, run)) else "false")
            return 0
        sys.stderr.write(f"ledger.py: unknown subcommand {cmd!r}\n")
        return 2
    except LedgerError as e:
        sys.stderr.write(f"ledger.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"ledger.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
