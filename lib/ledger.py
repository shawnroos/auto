#!/usr/bin/env python3
"""auto ledger facade — re-exports the ledger surface from
ledger_core / ledger_mutators / ledger_emitters.

This module was split (B5) for maintainability: the implementation now lives in
three sibling modules along an acyclic DAG (core ← mutators ← emitters ← this
facade). This file re-exports the WHOLE surface — every public name (the time helpers
``now_iso`` / ``parse_iso`` are public here) PLUS the one private helper
consumers reach through the ``ledger.`` namespace (``_with_locked_ledger``) — so
existing callers that do
``ledger = _bootstrap.load_ledger()`` and reference ``ledger.<name>`` keep
resolving unchanged. See those three modules for the implementation and
docs/contracts/ledger-schema.md for the authoritative spec (if they disagree,
the contract wins and the code is the bug).

  * ledger_core      — constants, errors, paths, time helpers, the atomic-write +
                       flock primitives, and init_ledger / read_ledger.
  * ledger_predicate — the pure predicate logic (recompute_predicate + B7 helpers,
                       gating_severities, unit_is_terminal, is_orphaned); imports
                       only ledger_core, reached from core's _atomic_write via a
                       deferred lazy-load (U16).
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
from _bootstrap import load_lib_module, resolve_repo  # noqa: E402

ledger_core = load_lib_module("ledger_core")
ledger_predicate = load_lib_module("ledger_predicate")
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

# Paths + time helpers (now_iso / parse_iso are the public time surface).
ledger_path = ledger_core.ledger_path
lock_path = ledger_core.lock_path
now_iso = ledger_core.now_iso
parse_iso = ledger_core.parse_iso

# Pure predicate logic (extracted to ledger_predicate.py in U16).
gating_severities = ledger_predicate.gating_severities
unit_is_terminal = ledger_predicate.unit_is_terminal
recompute_predicate = ledger_predicate.recompute_predicate
_compute_iteration_pending = ledger_predicate._compute_iteration_pending
is_orphaned = ledger_predicate.is_orphaned

# Primitives + create/read API (incl. the private RMW primitive consumers reach
# for in tests/integration).
_with_locked_ledger = ledger_core._with_locked_ledger
init_ledger = ledger_core.init_ledger
read_ledger = ledger_core.read_ledger

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from ledger_mutators: grammar-checked scalar write paths.

transition = ledger_mutators.transition
force_skip = ledger_mutators.force_skip  # U2 steering verb (R3/R20)
record_verdict = ledger_mutators.record_verdict
set_loop = ledger_mutators.set_loop
set_gaps_open = ledger_mutators.set_gaps_open
set_enumerated_units = ledger_mutators.set_enumerated_units
set_winner_unit_id = ledger_mutators.set_winner_unit_id
set_verdict_decision = ledger_mutators.set_verdict_decision
set_bound_override = ledger_mutators.set_bound_override
set_driving_session_id = ledger_mutators.set_driving_session_id
append_advisor_audit = ledger_mutators.append_advisor_audit
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
# Composite pause helper (U9). Topology-correct home: it wraps set_loop, so it
# belongs on the ledger surface both pause callers already reach through.


def apply_pause(repo_root, run_id, reason, *, backstop_latched=False):
    """The single pause write both pause paths route through.

    Flip the loop to ``driver="manual"`` and record ``blocked_on=reason``
    WITHOUT marking the loop done — the run stays resumable. The two callers
    differ ONLY by ``backstop_latched``:

      * the destructive-action backstop (on-pretooluse-action.py::_pause_run)
        passes ``True`` — the pause LATCHES the fail-closed gate so it keeps
        firing on a second destructive command in the same autonomous turn
        (no self-disarm);
      * the operator CLI (auto-resume.py::_cmd_pause) uses the default
        ``False`` — the operator now owns the session and runs their own
        cleanup, so the gate must not re-fire on it.

    ``backstop_latched`` rides the SAME atomic set_loop write as
    ``driver="manual"`` (P3-b) => the latch exists iff the backstop pause does.
    Note apply_pause only ever SETS the latch (never clears): the operator path
    (default False) leaves any pre-existing latch UNTOUCHED, because a latch is
    cleared ONLY by a clean `auto-resume continue` (forgiveness). That stickiness
    is the anti-self-disarm door — an agent that hits the backstop cannot run
    `auto-resume pause` to drop the latch and retry the destructive command
    (advisor-gate P3-b). So we pass backstop_latched to set_loop only when
    latching; omitting it leaves set_loop's field unchanged (UNSET sentinel).
    """
    kwargs = {"backstop_latched": True} if backstop_latched else {}
    set_loop(repo_root, run_id, driver="manual", blocked_on=reason, **kwargs)


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
        # v0.4.3: the plan-loop FEEDBACK channel — the surface the model uses to
        # report structured results back through Bash (its only ledger-write tool
        # is this CLI; it cannot call the Python mutators directly). Repo is
        # auto-resolved from cwd/$CLAUDE_AUTO_REPO (resolve_repo) so the model
        # passes only the run-id it already has from the tick intent — matching
        # auto.sh / auto-resume.sh ergonomics. Without these, the plan-loop's
        # set_gaps_open guidance and the v0.4.3 enumerate handshake surface
        # instructions the model literally cannot execute (the run would spin).
        if cmd == "set-gaps-open":
            run, n = argv[1], argv[2]
            set_gaps_open(resolve_repo(), run, int(n))
            return 0
        if cmd == "set-enumerated-units":
            # set-enumerated-units <run> <plan-unit-id> <json-array>
            # json-array: [{"id": "...", "invokes": {...}, "dispatch_context"?: {...}}, ...]
            run, unit, payload = argv[1], argv[2], argv[3]
            units = json.loads(payload)
            if not isinstance(units, list):
                sys.stderr.write(
                    "ledger.py: set-enumerated-units payload must be a JSON array\n"
                )
                return 2
            set_enumerated_units(resolve_repo(), run, unit, units)
            return 0
        # v0.6.8: the work-loop VERDICT channel — the surface the model/operator
        # uses to write a unit's verdict and a gate's advance/iterate/exit
        # decision back through Bash (its only ledger-write tool is this CLI; it
        # cannot call the Python mutators directly). Repo auto-resolved from
        # cwd/$CLAUDE_AUTO_REPO (resolve_repo), matching the set-* feedback verbs
        # above — without these the work-loop is drivable only via the Python API.
        if cmd == "record-verdict":
            # record-verdict <run> <unit> <json-findings> [attempt]
            # json-findings: [{"severity": "...", "note": "..."}, ...]
            run, unit, payload = argv[1], argv[2], argv[3]
            findings = json.loads(payload)
            if not isinstance(findings, list):
                sys.stderr.write(
                    "ledger.py: record-verdict findings must be a JSON array\n"
                )
                return 2
            attempt = int(argv[4]) if len(argv) > 4 else None
            record_verdict(resolve_repo(), run, unit, findings, attempt=attempt)
            return 0
        if cmd == "set-verdict-decision":
            # set-verdict-decision <run> <gate-unit> <decision> [json-payload]
            # decision: one of advance | iterate | exit
            run, gate_unit, decision = argv[1], argv[2], argv[3]
            decision_payload = json.loads(argv[4]) if len(argv) > 4 else None
            if decision_payload is not None and not isinstance(decision_payload, dict):
                sys.stderr.write(
                    "ledger.py: set-verdict-decision payload must be a JSON object\n"
                )
                return 2
            set_verdict_decision(
                resolve_repo(), run, gate_unit, decision, payload=decision_payload
            )
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
