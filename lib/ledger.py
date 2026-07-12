#!/usr/bin/env python3
"""auto ledger facade — re-exports the ledger surface from
ledger_core / ledger_mutators / ledger_emitters.

This module was split (B5) for maintainability: the implementation now lives in
three sibling modules along an acyclic DAG (core ← mutators ← producers ← this
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
  * ledger_steering  — the AGENT-facing steering verbs (force_skip, add_unit,
                       reshape_deps, register_session). Imports mutators for two
                       graph helpers; never the reverse.
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
ledger_steering = load_lib_module("ledger_steering")
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
# Re-exports from ledger_steering: the AGENT-facing steering verbs. One contract:
# read freely; every write revalidates its precondition under the flock and can
# reject. Split out of ledger_mutators when that file crossed its size budget.

force_skip = ledger_steering.force_skip              # R3/R20 — reason mandatory
add_unit = ledger_steering.add_unit                  # R3
reshape_deps = ledger_steering.reshape_deps          # R3
register_session = ledger_steering.register_session  # R21 — hook ownership set

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
# Agent orientation surface (R6/R7). `describe` emits ONE JSON object so a
# driving agent reads the stable operating contract on demand instead of
# re-deriving it from ~2000 lines of skill prose every session. Prose home:
# docs/contracts/agent-tool-surface.md.
#
# The `verbs` catalog is NOT hand-maintained here — it is DERIVED from the
# `_VERBS` registry below (the same dict that drives CLI dispatch), so the
# self-description and the dispatch surface cannot drift. Adding a verb to
# `_VERBS` wires BOTH its dispatch and its docs in one place; no completeness
# test is needed to hold two hand-kept copies in lockstep.

_TOOL_SURFACE_PREAMBLE = {
    "contract": (
        "Read freely. Every write commits through a verb that revalidates its "
        "precondition INSIDE the flock and can REJECT. The model never holds the "
        "lock and never does a read-then-write across two invocations — a decision "
        "made against a now-stale snapshot is rejected, not merged. See "
        "docs/contracts/agent-tool-surface.md."
    ),
    "ledger_path": "<repo>/.claude/auto/<run-id>.json — read it, never re-derive.",
    "intent_envelope": {
        "doc": "lib/tick.py emits ONE of these on stdout; the model issues the tool call.",
        "actions": {
            "rearm": '{"action":"rearm","delay":N,"prompt":"/auto:auto-tick <run>",...}',
            "stop": '{"action":"stop","reason":"predicate-met"|"seam-pause",...}',
            "noop": '{"action":"noop","reason":"lock-held-by-live-tick"}',
        },
    },
}


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/ledger.sh routes through this). $ARGUMENTS-safe: all parsing
# is positional here, never string-interpolated into shell.
#
# ONE registry (`_VERBS`) is the single source of truth for the CLI surface: each
# verb binds its handler (dispatch), its argument doc + rejection modes (what
# `describe` emits), and its read/write class. `_cli` dispatches through it and
# `describe` derives its catalog from it, so the two cannot drift.
#
# REPO RESOLUTION splits the verbs into two families:
#   * the READ verbs + `transition` take an explicit `<repo>` argv (the legacy
#     shape auto.sh / tick.py pass);
#   * the FEEDBACK + STEERING write verbs auto-resolve the repo from
#     cwd/$CLAUDE_AUTO_REPO (`resolve_repo`) so the model passes only the run-id
#     it already holds from the tick intent — its ONLY ledger-write tool is this
#     CLI; it cannot call the Python mutators directly.


class _Verb:
    """One CLI verb: its dispatch handler plus its self-description for `describe`.

    ``handler(argv) -> int`` returns the process exit code (0 ok, 2 bad-args); it
    may raise LedgerError / IndexError / ValueError, which ``_cli`` maps to exit
    1 / 2. ``args`` and ``rejects`` are the human-facing docs `describe` emits;
    ``reads`` marks a non-mutating verb.
    """

    __slots__ = ("handler", "args", "reads", "rejects")

    def __init__(self, handler, args, *, reads=False, rejects=None):
        self.handler = handler
        self.args = args
        self.reads = reads
        self.rejects = rejects

    def as_doc(self):
        doc = {"args": self.args}
        if self.reads:
            doc["reads"] = True
        if self.rejects:
            doc["rejects"] = self.rejects
        return doc


def _json_array(raw, what):
    """Parse a JSON-array CLI arg or raise ValueError (→ _cli's exit-2 path).

    The write verbs all take a JSON array and reject a non-array the same way;
    centralizing the parse+guard keeps each handler a straight-line call.
    """
    value = json.loads(raw)
    if not isinstance(value, list):
        raise ValueError(f"{what} must be a JSON array")
    return value


# ── read / inspection handlers (explicit <repo> <run>; no mutation) ──


def _h_describe(argv):
    # R6/R7: the whole stable operating contract as ONE JSON object, so an agent
    # orients without loading the skill corpus. No repo, no mutation.
    json.dump(_describe_surface(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def _h_read(argv):
    repo, run = argv[1], argv[2]
    json.dump(read_ledger(repo, run), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def _h_path(argv):
    print(ledger_path(argv[1], argv[2]))
    return 0


def _h_is_orphaned(argv):
    repo, run = argv[1], argv[2]
    print("true" if is_orphaned(read_ledger(repo, run)) else "false")
    return 0


def _h_transition(argv):
    repo, run, unit, state = argv[1], argv[2], argv[3], argv[4]
    transition(repo, run, unit, state)
    return 0


# ── feedback / verdict handlers (resolve_repo; <run> …) ──


def _h_set_gaps_open(argv):
    run, n = argv[1], argv[2]
    set_gaps_open(resolve_repo(), run, int(n))
    return 0


def _h_set_enumerated_units(argv):
    # set-enumerated-units <run> <plan-unit-id> <json-array>
    # json-array: [{"id": "...", "invokes": {...}, "dispatch_context"?: {...}}, ...]
    run, unit, payload = argv[1], argv[2], argv[3]
    set_enumerated_units(resolve_repo(), run, unit, _json_array(payload, "payload"))
    return 0


def _h_record_verdict(argv):
    # record-verdict <run> <unit> <json-findings> [attempt]
    run, unit, payload = argv[1], argv[2], argv[3]
    findings = _json_array(payload, "findings")
    attempt = int(argv[4]) if len(argv) > 4 else None
    record_verdict(resolve_repo(), run, unit, findings, attempt=attempt)
    return 0


def _h_set_verdict_decision(argv):
    # set-verdict-decision <run> <gate-unit> <decision> [json-payload]
    run, gate_unit, decision = argv[1], argv[2], argv[3]
    payload = json.loads(argv[4]) if len(argv) > 4 else None
    if payload is not None and not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")
    set_verdict_decision(resolve_repo(), run, gate_unit, decision, payload=payload)
    return 0


# ── steering handlers (resolve_repo; the agent's reshape surface) ──


def _h_init(argv):
    # init <run> <units-json> [adapter] [loop-phase]   (R4 — CREATE a run from
    # the tool surface). adapter/loop-phase are validated INSIDE init_ledger
    # against its authoritative sets before any write (invalid → LedgerError, no
    # file), and an existing run-id raises LedgerExists leaving the ledger
    # untouched — so the CLI never re-guesses the allowed set.
    run = argv[1]
    units = _json_array(argv[2], "units") if len(argv) > 2 and argv[2] else None
    adapter = argv[3] if len(argv) > 3 and argv[3] else "ce"
    loop_phase = argv[4] if len(argv) > 4 and argv[4] else "plan"
    init_ledger(resolve_repo(), run, adapter=adapter, units=units, loop_phase=loop_phase)
    return 0


def _h_force_skip(argv):
    # force-skip <run> <unit> <reason>   (R3/R20 — reason mandatory; the mutator
    # rejects a blank one under the lock).
    run, unit, reason = argv[1], argv[2], argv[3]
    force_skip(resolve_repo(), run, unit, reason)
    return 0


def _h_add_unit(argv):
    # add-unit <run> <unit-id> [json-depends-on] [phase]. The `and argv[4]` guard
    # mirrors init: an explicit EMPTY phase reads as absent (→ the run-phase
    # default in _normalize_unit), not phase="" — a "" unit is in neither the
    # current- nor terminal-phase eval set and would silently never dispatch.
    run, unit = argv[1], argv[2]
    depends_on = _json_array(argv[3], "depends_on") if len(argv) > 3 and argv[3] else None
    phase = argv[4] if len(argv) > 4 and argv[4] else None
    add_unit(resolve_repo(), run, unit, depends_on=depends_on, phase=phase)
    return 0


def _h_reshape_deps(argv):
    # reshape-deps <run> <unit-id> <json-depends-on>
    run, unit, payload = argv[1], argv[2], argv[3]
    reshape_deps(resolve_repo(), run, unit, _json_array(payload, "depends_on"))
    return 0


def _h_register_session(argv):
    # register-session <run>   (U8/R21 — a dispatched phase sub-agent joins the
    # ownership set so the fail-closed destructive backstop and the advisor gate
    # reach it). The joined id is the CALLER's OWN session, read from the env —
    # NEVER a positional arg — so a process can only ever register itself, closing
    # the cross-session-capture surface (security review). A missing env id is a
    # hard error (the caller isn't a real session), not a silent no-op.
    run = argv[1]
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        sys.stderr.write(
            "ledger.py: register-session needs CLAUDE_CODE_SESSION_ID in the "
            "environment (a sub-agent registers its OWN session)\n"
        )
        return 2
    register_session(resolve_repo(), run, sid)
    return 0


_VERBS = {
    # read / inspection
    "describe": _Verb(_h_describe, "(none)", reads=True),
    "read": _Verb(_h_read, "<repo> <run>", reads=True),
    "path": _Verb(_h_path, "<repo> <run>", reads=True),
    "is-orphaned": _Verb(_h_is_orphaned, "<repo> <run>", reads=True),
    "transition": _Verb(
        _h_transition,
        "<repo> <run> <unit> <state>",
        rejects="InvalidTransition for any edge not in ALLOWED_TRANSITIONS; "
        "LedgerError if used to write findings (use record-verdict).",
    ),
    # verdict-feedback (engine's own write path)
    "record-verdict": _Verb(
        _h_record_verdict,
        "<run> <unit> <findings-json> [attempt]",
        rejects="StaleVerdict if attempt is older than the unit's current dispatch "
        "generation; InvalidTransition from a non-verdict-writable state.",
    ),
    "set-gaps-open": _Verb(_h_set_gaps_open, "<run> <n>"),
    "set-enumerated-units": _Verb(_h_set_enumerated_units, "<run> <unit> <payload-json>"),
    "set-verdict-decision": _Verb(_h_set_verdict_decision, "<run> <gate-unit> <decision>"),
    # agent steering verbs (the reshape surface)
    "init": _Verb(
        _h_init,
        "<run> <units-json> [adapter] [loop-phase]",
        rejects="LedgerExists if the run-id already exists (existing ledger "
        "untouched); LedgerError on an unknown adapter.",
    ),
    "force-skip": _Verb(
        _h_force_skip,
        "<run> <unit> <reason>",
        rejects="LedgerError on a blank reason (R20); InvalidTransition from a state "
        "with no terminal-skip edge. A skip cannot bury an existing finding.",
    ),
    "add-unit": _Verb(
        _h_add_unit,
        "<run> <unit-id> [depends-on-json] [phase]",
        rejects="LedgerError on a duplicate id or a dependency on an unknown unit.",
    ),
    "reshape-deps": _Verb(
        _h_reshape_deps,
        "<run> <unit-id> <depends-on-json>",
        rejects="LedgerError on a dependency cycle or an edge to an unknown unit.",
    ),
    "register-session": _Verb(
        _h_register_session,
        "<run>  (registers $CLAUDE_CODE_SESSION_ID — the caller's own)",
        rejects="exit 2 if CLAUDE_CODE_SESSION_ID is unset. Idempotent otherwise.",
    ),
}


def _describe_surface():
    """The full `describe` payload: the static preamble + the verb catalog derived
    from `_VERBS`, so dispatch and docs share one source."""
    return {
        **_TOOL_SURFACE_PREAMBLE,
        "verbs": {name: verb.as_doc() for name, verb in _VERBS.items()},
    }


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: ledger.py <subcommand> ...\n")
        return 2
    verb = _VERBS.get(argv[0])
    if verb is None:
        sys.stderr.write(f"ledger.py: unknown subcommand {argv[0]!r}\n")
        return 2
    try:
        return verb.handler(argv)
    except LedgerError as e:
        sys.stderr.write(f"ledger.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"ledger.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
