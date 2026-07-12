#!/usr/bin/env python3
"""auto ledger producers: phase-transition + iteration emission/composite paths.

The emission layer of the ledger surface (see lib/ledger.py for the facade and
docs/contracts/ledger-schema.md for the authoritative spec). Holds the shared
emit/validate/append helper (``_emit_units_core``), the phase-transition primitive
(``transition_and_emit``), the in-phase iteration emit (``emit_within_phase`` +
``_apply_emit``), and the gate-unit re-engagement combo (``reset_for_iteration`` +
``_reset_gate_for_iteration`` + ``atomic_iterate_step``).

Sits ABOVE ledger_core in the acyclic DAG (dependency order:
core ← mutators ← producers ← facade). It imports ONLY ledger_core — NOT
ledger_mutators: the composite paths deliberately inline their sub-step bodies
inside ONE outer locked body (the F3 deadlock guard — calling a public mutator
from inside a locked mutate() would re-acquire the flock on a fresh fd and
deadlock), so there is no reason to hold a ledger_mutators handle here, and
holding one would be an attractive nuisance inviting exactly that deadlock.
"""

from __future__ import annotations

import os
import sys
from typing import Callable

# Import the sibling ledger modules via the standard bootstrap loader (mirrors
# producers.py). The ledger surface is loaded by file path in many sites (the test
# harness uses spec_from_file_location, which does NOT add lib/ to sys.path), so a
# plain `import ledger_core` is not guaranteed to resolve. Prepending lib/ +
# routing through _bootstrap.load_lib_module is the one robust load strategy the
# codebase already uses for sibling modules.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

ledger_core = load_lib_module("ledger_core")


def _emit_units_core(ledger: dict, to_phase: str, producer) -> list:
    """Pure shared helper: emit + validate + append units. NO flock acquire,
    NO loop_phase write, NO counter bump — callers add those.

    Factored out of ``transition_and_emit`` and ``_apply_emit`` (F3 / maint-1)
    so the emit/validate/append loop lives in ONE place. The two callers
    diverge ONLY in:
      - ``transition_and_emit`` additionally advances ``loop_phase``.
      - ``_apply_emit`` additionally bumps ``iteration_emit_count``.

    Keeping that divergence at the call sites means the SHARED contract
    (per-unit id-required, no collision; normalize via ``_normalize_unit``
    with current ``loop_phase``; default to ``to_phase``) lives in one
    place. The two prior copy-paste loops were byte-equivalent on the
    emit-loop body and would have drifted on any future field added to a
    new unit's normalization.

    Returns the list of newly-appended unit ids.
    """
    new_units = producer(ledger, to_phase) or []
    existing_ids = {u["id"] for u in ledger.get("units", [])}
    appended = []
    for nu in new_units:
        if "id" not in nu:
            raise ledger_core.LedgerError("emitted unit missing 'id'")
        if nu["id"] in existing_ids:
            raise ledger_core.LedgerError(f"emitted unit id collides: {nu['id']!r}")
        # Emitted units default to the arriving phase unless they declare one.
        nu = dict(nu)
        nu.setdefault("phase", to_phase)
        ledger.setdefault("units", []).append(
            ledger_core._normalize_unit(nu, loop_phase=ledger.get("loop_phase", "plan"))
        )
        existing_ids.add(nu["id"])
        appended.append(nu["id"])
    return appended


def transition_and_emit(
    repo_root, run_id, to_phase, producer: Callable[[dict, str], list]
):
    """Advance ``loop_phase`` to ``to_phase`` AND emit that phase's units, in ONE
    atomic write (v0.2.0 U5b / KTD-6 — the G3/F2 fix).

    This is the phase-transition primitive. The round-1 framing tried to do the
    advance and the emission as SEPARATE locked writes (`set_loop` then an emit),
    which left a torn-state window: a reader between the two writes would see the
    new phase with zero emitted units, and `recompute_predicate` could fire
    ``met`` prematurely (e.g. A2's judge terminal → all_units_terminal with no
    work units yet). Doing both inside one ``_with_locked_ledger`` body closes
    that window: the producer's units are appended BEFORE ``_atomic_write``'s
    mandatory predicate recompute, so ``met`` is always computed against the
    post-emission unit set.

    ``producer`` is a PURE callable ``(ledger, to_phase) -> list[new_unit_dict]``.
    It MUST NOT call any ledger mutator (`transition`, `record_verdict`,
    `set_loop`, …): those re-acquire the flock on a fresh fd and would deadlock
    inside this already-locked body (F3). The producer only READS the passed
    ledger dict and RETURNS new partial unit dicts; this primitive normalizes and
    appends them. New unit ids must not collide with existing ones.

    Returns the list of newly-appended unit ids.

    F3 / maint-1: emit body delegates to ``_emit_units_core``; this path adds
    the ``loop_phase``/``seam_paused`` advance that distinguishes a transition
    from an in-phase emit.
    """
    def mutate(ledger):
        appended = _emit_units_core(ledger, to_phase, producer)
        # Advance the phase AFTER emission (the units belong to to_phase; setting
        # loop_phase first or last is equivalent here since both happen in one
        # snapshot, but advancing last keeps "emit produces units FOR to_phase"
        # readable). seam_paused tracks the phase per the v0.1.x rule.
        ledger["loop_phase"] = to_phase
        ledger["seam_paused"] = to_phase == "seam"
        return appended

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def _apply_emit(ledger: dict, to_phase: str, producer) -> list:
    """Pure helper: run ``producer(ledger, to_phase)``, validate + append units,
    bump ``iteration_emit_count`` per emitted unit. NEVER acquires the flock —
    the caller already holds it (the F3 deadlock guard).

    Used by both ``emit_within_phase`` and ``atomic_iterate_step`` from within
    their respective locked bodies. Returns the list of newly-appended unit
    ids. Mirrors ``transition_and_emit``'s body shape exactly EXCEPT it does
    NOT write ``loop_phase`` — emission stays within the gate unit's current
    phase. Validation parity (missing id; collision) matches transition_and_emit.

    F3 / maint-1: emit body delegates to ``_emit_units_core``; this path adds
    the per-unit ``iteration_emit_count`` bump that distinguishes an iterating
    emit from a phase-transition emit.
    """
    appended = _emit_units_core(ledger, to_phase, producer)
    # KTD §D / OQ4: bump the monotonic emit-id counter PER emitted unit.
    # Drives `iterate_template` (U3)'s id assignment via
    # `id_prefix + (counter+1)`; replaces "recount existing units" which
    # would collide after a partial-emit crash deleted units.
    if appended:
        ledger["iteration_emit_count"] = (
            int(ledger.get("iteration_emit_count", 0)) + len(appended)
        )
    return appended


def emit_within_phase(repo_root, run_id, to_phase: str, producer):
    """Emit new units into ``to_phase`` WITHOUT advancing ``loop_phase``.

    Sibling to ``transition_and_emit``: same atomicity contract (one
    ``_with_locked_ledger`` body wraps emit+normalize+append+recompute), but
    NO ``loop_phase`` write and NO ``seam_paused`` flip. Re-emission stays
    within the gate unit's current phase per KTD §D — the iteration loop adds
    siblings rather than transitioning the run.

    ``producer`` is a PURE callable ``(ledger, to_phase) -> list[new_unit_dict]``.
    Same constraint as ``transition_and_emit``: it MUST NOT call any ledger
    mutator (F3 deadlock — fresh-fd flock re-acquire on a held lock).

    Per emitted unit, ``iteration_emit_count`` is incremented atomically
    (closes round-3 P0-R3-2's "recount on resume after partial-emit crash"
    failure mode). Returns the list of newly-appended unit ids.

    Implementer's OQ-resolved shape (plan "Deferred to Implementation"): a
    NEW PUBLIC FUNCTION rather than a ``transition_and_emit`` parameter
    extension. The bodies share the emit-append-normalize sub-step (factored
    into ``_apply_emit`` for ``atomic_iterate_step`` reuse) but diverge on
    loop_phase/seam_paused/counter — a parameter would muddy both paths and
    leak the counter into transition_and_emit.
    """
    def mutate(ledger):
        return _apply_emit(ledger, to_phase, producer)

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def _reset_gate_for_iteration(ledger: dict, gate_unit_id: str, new_depends_on) -> dict:
    """Pure helper: the atomic gate-unit reset combo (KTD §C). The caller
    already holds the flock — this is the F3 deadlock guard, mirroring
    ``_apply_emit``.

    In ONE pass mutates the gate unit:
      (a) state ``verdict-returned → pending`` (validates the EXISTING edge in
          ``ALLOWED_TRANSITIONS`` — v0.3.0 does NOT add a new edge; the contract
          is the atomic COMBO, not a new grammar move).
      (b) ``depends_on`` is replaced with ``new_depends_on`` (the union of the
          gate's prior deps + newly-emitted sibling ids — the caller computes
          the union; this mutator just writes).
      (c) ``dispatch_context.decision`` and ``dispatch_context.decision_payload``
          CLEARED (closes round-3 P0-R3-1: without the clear, a subsequent
          pulse re-reads the stale ``iterate`` decision and re-fires the
          iteration loop before the gate re-verdicts, double-incrementing
          iteration_attempts until bound trip).
      (d) ``verdict_at`` cleared.
      (e) ``findings`` cleared.

    Grammar-check is INLINE (not via ``transition()``) — same F3 reason. The
    deliberate-fail #2 / #3 controls assert (e) and (c) respectively are
    load-bearing.
    """
    gate = ledger_core._find_unit(ledger, gate_unit_id)
    current = gate.get("state")
    # The verdict-returned → pending edge ALREADY exists in
    # ALLOWED_TRANSITIONS — v0.3.0 does NOT add a new state edge. We replicate
    # the check inline (cannot route through transition() inside a locked body;
    # F3 deadlock).
    if "pending" not in ledger_core.ALLOWED_TRANSITIONS.get(current, set()):
        raise ledger_core.InvalidTransition(
            f"{current!r} -> 'pending' not permitted for unit {gate_unit_id!r} "
            f"(reset_for_iteration requires source state 'verdict-returned')"
        )
    gate["state"] = "pending"
    gate["depends_on"] = list(new_depends_on or [])
    dc = gate.setdefault("dispatch_context", {})
    # Round-3 P0-R3-1: clearing the decision is load-bearing. A surviving
    # `decision: "iterate"` would re-fire the iteration loop on the NEXT
    # pulse before the gate has re-verdicted, double-incrementing
    # iteration_attempts until bound trip. Centralizing the clear here
    # (single owner) is cleaner than a per-read-site guard.
    dc.pop("decision", None)
    dc.pop("decision_payload", None)
    gate["verdict_at"] = None
    gate["findings"] = []
    return gate


def reset_for_iteration(repo_root, run_id, gate_unit_id, new_depends_on):
    """Atomic gate-unit reset combo per KTD §C. The engine-only caller for the
    atomic re-engagement combination over the EXISTING
    ``verdict-returned → pending`` edge in ``ALLOWED_TRANSITIONS``.

    The full combo is implemented in ``_reset_gate_for_iteration`` (callable
    from inside a held lock — ``atomic_iterate_step`` reuses it). This public
    mutator wraps that helper in its own locked body for callers that just
    need the reset standalone.
    """
    def mutate(ledger):
        _reset_gate_for_iteration(ledger, gate_unit_id, new_depends_on)
        return "pending"

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)


def atomic_iterate_step(
    repo_root, run_id, gate_unit_id, producer, new_depends_on
):
    """The composite mutator that runs ONE full iteration step atomically
    (round-3 P1-R3-1 / KTD §C+D). Wraps THREE writes into ONE
    ``_with_locked_ledger`` body:

      1. ``iteration_attempts`` increments (KTD §D bound counter).
      2. ``producer`` runs; new units are validated, normalized, appended; per
         unit ``iteration_emit_count`` increments (KTD §D monotonic id).
      3. Gate unit reset (state ``verdict-returned → pending``, depends_on
         replaced, dispatch_context.decision / decision_payload cleared,
         verdict_at cleared, findings cleared — KTD §C).

    All-or-nothing: if any sub-step raises (e.g. a producer that returns a
    colliding id, or the gate not in ``verdict-returned``), the ledger is NOT
    written (``_with_locked_ledger`` only calls ``_atomic_write`` on
    successful mutate). The deliberate-fail #8 control proves this by passing
    a bad producer — in the atomic version iteration_attempts stays at 0; in a
    split version it would increment before the emit fails.

    Engine-only caller (U4's ``advance_iteration_loop``).
    """
    # Capture the caller-supplied depends_on for closure use (avoids the
    # UnboundLocalError trap where assigning new_depends_on inside mutate()
    # makes Python rebind it as a local before its first read).
    caller_depends_on = new_depends_on

    def mutate(ledger):
        # Validate gate exists up front so we don't half-increment then fail
        # later (a typo'd gate_unit_id would otherwise let increment land
        # before _reset_gate_for_iteration's lookup raised; lookup-first
        # keeps the all-or-nothing contract intact).
        ledger_core._find_unit(ledger, gate_unit_id)
        # Step 1: increment iteration_attempts (bound counter).
        ledger["iteration_attempts"] = int(ledger.get("iteration_attempts", 0)) + 1
        # Step 2: emit new units inline (gate unit's current phase).
        gate = ledger_core._find_unit(ledger, gate_unit_id)
        to_phase = gate.get("phase") or ledger.get("loop_phase", "plan")
        appended = _apply_emit(ledger, to_phase, producer)
        # Step 3: reset the gate unit atomically with the emit. The caller
        # supplies the new depends_on (union of gate's prior deps + newly-
        # emitted ids); we honor it verbatim. If the caller passed `None`
        # we compute the union here as a defensive default.
        deps = caller_depends_on
        if deps is None:
            deps = list(gate.get("depends_on") or []) + list(appended)
        _reset_gate_for_iteration(ledger, gate_unit_id, deps)
        return appended

    return ledger_core._with_locked_ledger(repo_root, run_id, mutate)
