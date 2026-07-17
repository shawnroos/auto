#!/usr/bin/env python3
"""auto run-record facade — re-exports the run-record surface from
run_record_core / run_record_mutators / run_record_producers.

This module was split (B5) for maintainability: the implementation now lives in
three sibling modules along an acyclic DAG (core ← mutators ← producers ← this
facade). This file re-exports the WHOLE surface — every public name (the time helpers
``now_iso`` / ``parse_iso`` are public here) PLUS the one private helper
consumers reach through the ``run_record.`` namespace (``_with_locked_run_record``) — so
existing callers that do
``run_record = _bootstrap.load_run_record()`` and reference ``run_record.<name>`` keep
resolving unchanged. See those three modules for the implementation and
docs/contracts/run-record-schema.md for the authoritative spec (if they disagree,
the contract wins and the code is the bug).

  * run_record_core      — constants, errors, paths, time helpers, the atomic-write +
                       flock primitives, and init_run_record / read_run_record.
  * run_record_predicate — the pure predicate logic (recompute_predicate + B7 helpers,
                       gating_severities, step_is_terminal, is_orphaned); imports
                       only run_record_core, reached from core's _atomic_write via a
                       deferred lazy-load (U16).
  * run_record_mutators  — the grammar-checked, flock-serialized scalar mutators
                       (transition, record_verdict, set_loop, set_gaps_open,
                       set_*, accumulate_active_time, increment_iteration_attempts).
  * run_record_steering  — the AGENT-facing steering verbs (force_skip, add_step,
                       reshape_deps, register_session). Imports mutators for two
                       graph helpers; never the reverse.
  * run_record_producers  — phase-transition + iteration emission/composite paths
                       (transition_and_emit, emit_within_phase, reset_for_iteration,
                       atomic_iterate_step, and their pure helpers).

The CLI (``_cli`` + ``__main__`` block) stays here so lib/run_record.sh can keep
routing through ``run_record.py``.
"""

from __future__ import annotations

import json
import os
import sys

# Load the implementation modules via the standard bootstrap loader. The run-record
# surface is loaded from many sites by file path (the test harness uses
# spec_from_file_location, which does NOT add lib/ to sys.path), so a plain
# `from run_record_core import ...` is not guaranteed to resolve. Prepending lib/ +
# routing through _bootstrap.load_lib_module is the one robust load strategy the
# codebase already uses for sibling modules.
_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module, resolve_repo  # noqa: E402

run_record_core = load_lib_module("run_record_core")
run_record_predicate = load_lib_module("run_record_predicate")
run_record_mutators = load_lib_module("run_record_mutators")
run_record_steering = load_lib_module("run_record_steering")
run_record_producers = load_lib_module("run_record_producers")
# U10: the operator `downgrade` command needs the INVERSE map. format_compat is a DAG
# ROOT (imports no sibling), so this edge closes no cycle — same as core's own.
format_compat = load_lib_module("format_compat")

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from run_record_core: constants + errors + pure logic + primitives.
# Every name is listed explicitly (greppable) so the re-export surface is
# auditable and a consumer's `run_record.<name>` keeps resolving after the split.

# Module constants.
GRACE_SECONDS = run_record_core.GRACE_SECONDS
DEFAULT_STALL_THRESHOLD_SECONDS = run_record_core.DEFAULT_STALL_THRESHOLD_SECONDS
DRIVER_SELF_STALE_SECONDS = run_record_core.DRIVER_SELF_STALE_SECONDS
LOOP_PHASES = run_record_core.LOOP_PHASES
PLAN_STEPS = run_record_core.PLAN_STEPS
ExitReason = run_record_core.ExitReason
STEP_STATES = run_record_core.STEP_STATES
SEVERITIES = run_record_core.SEVERITIES
GATING_SEVERITIES = run_record_core.GATING_SEVERITIES
ALLOWED_TRANSITIONS = run_record_core.ALLOWED_TRANSITIONS

# Error hierarchy. Re-bind the SAME classes (not new ones) so callers that
# `except run_record.RunRecordError` catch a raise from any implementation module —
# the modules all raise run_record_core's classes, and the facade re-exports those
# exact objects, so `except` works across the split.
RunRecordError = run_record_core.RunRecordError
RunRecordNotFound = run_record_core.RunRecordNotFound
RunRecordExists = run_record_core.RunRecordExists
InvalidTransition = run_record_core.InvalidTransition
StaleVerdict = run_record_core.StaleVerdict
UnknownStep = run_record_core.UnknownStep

# Paths + time helpers (now_iso / parse_iso are the public time surface).
run_record_path = run_record_core.run_record_path
lock_path = run_record_core.lock_path
now_iso = run_record_core.now_iso
parse_iso = run_record_core.parse_iso

# Pure predicate logic (extracted to run_record_predicate.py in U16).
gating_severities = run_record_predicate.gating_severities
step_is_terminal = run_record_predicate.step_is_terminal
recompute_predicate = run_record_predicate.recompute_predicate
_compute_iteration_pending = run_record_predicate._compute_iteration_pending
is_orphaned = run_record_predicate.is_orphaned

# Primitives + create/read API (incl. the private RMW primitive consumers reach
# for in tests/integration).
_with_locked_run_record = run_record_core._with_locked_run_record
init_run_record = run_record_core.init_run_record
read_run_record = run_record_core.read_run_record

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from run_record_mutators: grammar-checked scalar write paths.

transition = run_record_mutators.transition
record_verdict = run_record_mutators.record_verdict
set_loop = run_record_mutators.set_loop
set_gaps_open = run_record_mutators.set_gaps_open
set_enumerated_steps = run_record_mutators.set_enumerated_steps
set_winner_step_id = run_record_mutators.set_winner_step_id
set_verdict_decision = run_record_mutators.set_verdict_decision
set_bound_override = run_record_mutators.set_bound_override
set_driving_session_id = run_record_mutators.set_driving_session_id
append_advisor_audit = run_record_mutators.append_advisor_audit
set_exit_reason = run_record_mutators.set_exit_reason
accumulate_active_time = run_record_mutators.accumulate_active_time
increment_iteration_attempts = run_record_mutators.increment_iteration_attempts

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from run_record_steering: the AGENT-facing steering verbs. One contract:
# read freely; every write revalidates its precondition under the flock and can
# reject. Split out of run_record_mutators when that file crossed its size budget.

force_skip = run_record_steering.force_skip              # R3/R20 — reason mandatory
add_step = run_record_steering.add_step                  # R3
reshape_deps = run_record_steering.reshape_deps          # R3
register_session = run_record_steering.register_session  # R21 — hook ownership set

# ──────────────────────────────────────────────────────────────────────────
# Re-exports from run_record_producers: phase-transition + iteration emission paths.

transition_and_emit = run_record_producers.transition_and_emit
emit_within_phase = run_record_producers.emit_within_phase
reset_for_iteration = run_record_producers.reset_for_iteration
atomic_iterate_step = run_record_producers.atomic_iterate_step


# ──────────────────────────────────────────────────────────────────────────
# Composite pause helper (U9). Topology-correct home: it wraps set_loop, so it
# belongs on the run-record surface both pause callers already reach through.


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
    "run_record_path": "<repo>/.claude/auto/<run-id>.json — read it, never re-derive.",
    "intent_envelope": {
        "doc": "lib/pulse.py emits ONE of these on stdout; the model issues the tool call.",
        "actions": {
            "rearm": '{"action":"rearm","delay":N,"prompt":"/auto:auto-pulse <run>",...}',
            "stop": '{"action":"stop","reason":"predicate-met"|"handoff-pause",...}',
            "noop": '{"action":"noop","reason":"lock-held-by-live-pulse"}',
        },
    },
    "phase_model": {
        "doc": (
            "Phases run in the workflow's phase_order. The CURRENT phase is the "
            "run-record's loop_phase — never phase_order[0], which is only the "
            "START phase. When a phase's predicate is met and it is not the "
            "terminal_phase, the engine advances to the next phase; at the "
            "terminal_phase the run can exit. Run `describe <run>` for THIS run's "
            "phase_order and current-phase next-action."
        ),
        "default_phase_order": ["plan", "handoff", "work"],
        "default_terminal_phase": "work",
        "current_phase_key": "loop_phase",
    },
}


# ──────────────────────────────────────────────────────────────────────────
# CLI (thin; lib/run_record.sh routes through this). $ARGUMENTS-safe: all parsing
# is positional here, never string-interpolated into shell.
#
# ONE registry (`_VERBS`) is the single source of truth for the CLI surface: each
# verb binds its handler (dispatch), its argument doc + rejection modes (what
# `describe` emits), and its read/write class. `_cli` dispatches through it and
# `describe` derives its catalog from it, so the two cannot drift.
#
# REPO RESOLUTION splits the verbs into two families:
#   * the READ verbs + `transition` take an explicit `<repo>` argv (the legacy
#     shape auto.sh / pulse.py pass);
#   * the FEEDBACK + STEERING write verbs auto-resolve the repo from
#     cwd/$CLAUDE_AUTO_REPO (`resolve_repo`) so the model passes only the run-id
#     it already holds from the pulse intent — its ONLY run-record-write tool is this
#     CLI; it cannot call the Python mutators directly.


class _Verb:
    """One CLI verb: its dispatch handler plus its self-description for `describe`.

    ``handler(argv) -> int`` returns the process exit code (0 ok, 2 bad-args); it
    may raise RunRecordError / IndexError / ValueError, which ``_cli`` maps to exit
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
    json.dump(read_run_record(repo, run), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def _h_path(argv):
    print(run_record_path(argv[1], argv[2]))
    return 0


def _h_is_orphaned(argv):
    repo, run = argv[1], argv[2]
    print("true" if is_orphaned(read_run_record(repo, run)) else "false")
    return 0


def _h_transition(argv):
    repo, run, step, state = argv[1], argv[2], argv[3], argv[4]
    transition(repo, run, step, state)
    return 0


# ── feedback / verdict handlers (resolve_repo; <run> …) ──


def _h_set_gaps_open(argv):
    run, n = argv[1], argv[2]
    set_gaps_open(resolve_repo(), run, int(n))
    return 0


def _h_set_enumerated_steps(argv):
    # set-enumerated-steps <run> <plan-step-id> <json-array>
    # json-array: [{"id": "...", "invokes": {...}, "dispatch_context"?: {...}}, ...]
    run, step, payload = argv[1], argv[2], argv[3]
    set_enumerated_steps(resolve_repo(), run, step, _json_array(payload, "payload"))
    return 0


def _h_record_verdict(argv):
    # record-verdict <run> <step> <json-findings> [attempt]
    run, step, payload = argv[1], argv[2], argv[3]
    findings = _json_array(payload, "findings")
    attempt = int(argv[4]) if len(argv) > 4 else None
    record_verdict(resolve_repo(), run, step, findings, attempt=attempt)
    return 0


def _h_set_verdict_decision(argv):
    # set-verdict-decision <run> <gate-step> <decision> [json-payload]
    run, gate_step, decision = argv[1], argv[2], argv[3]
    payload = json.loads(argv[4]) if len(argv) > 4 else None
    if payload is not None and not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")
    set_verdict_decision(resolve_repo(), run, gate_step, decision, payload=payload)
    return 0


# ── steering handlers (resolve_repo; the agent's reshape surface) ──


def _h_init(argv):
    # init <run> <steps-json> [backend] [loop-phase]   (R4 — CREATE a run from
    # the tool surface). backend/loop-phase are validated INSIDE init_run_record
    # against its authoritative sets before any write (invalid → RunRecordError, no
    # file), and an existing run-id raises RunRecordExists leaving the run-record
    # untouched — so the CLI never re-guesses the allowed set.
    run = argv[1]
    steps = _json_array(argv[2], "steps") if len(argv) > 2 and argv[2] else None
    backend = argv[3] if len(argv) > 3 and argv[3] else "ce"
    loop_phase = argv[4] if len(argv) > 4 and argv[4] else "plan"
    init_run_record(resolve_repo(), run, backend=backend, steps=steps, loop_phase=loop_phase)
    return 0


def _h_force_skip(argv):
    # force-skip <run> <step> <reason>   (R3/R20 — reason mandatory; the mutator
    # rejects a blank one under the lock).
    run, step, reason = argv[1], argv[2], argv[3]
    force_skip(resolve_repo(), run, step, reason)
    return 0


def _h_add_step(argv):
    # add-step <run> <step-id> [json-depends-on] [phase]. The `and argv[4]` guard
    # mirrors init: an explicit EMPTY phase reads as absent (→ the run-phase
    # default in _normalize_step), not phase="" — a "" step is in neither the
    # current- nor terminal-phase eval set and would silently never dispatch.
    run, step = argv[1], argv[2]
    depends_on = _json_array(argv[3], "depends_on") if len(argv) > 3 and argv[3] else None
    phase = argv[4] if len(argv) > 4 and argv[4] else None
    add_step(resolve_repo(), run, step, depends_on=depends_on, phase=phase)
    return 0


def _h_reshape_deps(argv):
    # reshape-deps <run> <step-id> <json-depends-on>
    run, step, payload = argv[1], argv[2], argv[3]
    reshape_deps(resolve_repo(), run, step, _json_array(payload, "depends_on"))
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
            "run_record.py: register-session needs CLAUDE_CODE_SESSION_ID in the "
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
        "<repo> <run> <step> <state>",
        rejects="InvalidTransition for any edge not in ALLOWED_TRANSITIONS; "
        "RunRecordError if used to write findings (use record-verdict).",
    ),
    # verdict-feedback (engine's own write path)
    "record-verdict": _Verb(
        _h_record_verdict,
        "<run> <step> <findings-json> [attempt]",
        rejects="StaleVerdict if attempt is older than the step's current dispatch "
        "generation; InvalidTransition from a non-verdict-writable state.",
    ),
    "set-gaps-open": _Verb(_h_set_gaps_open, "<run> <n>"),
    "set-enumerated-steps": _Verb(_h_set_enumerated_steps, "<run> <step> <payload-json>"),
    "set-verdict-decision": _Verb(_h_set_verdict_decision, "<run> <gate-step> <decision>"),
    # agent steering verbs (the reshape surface)
    "init": _Verb(
        _h_init,
        "<run> <steps-json> [backend] [loop-phase]",
        rejects="RunRecordExists if the run-id already exists (existing run_record "
        "untouched); RunRecordError on an unknown backend.",
    ),
    "force-skip": _Verb(
        _h_force_skip,
        "<run> <step> <reason>",
        rejects="RunRecordError on a blank reason (R20); InvalidTransition from a state "
        "with no terminal-skip edge. A skip cannot bury an existing finding.",
    ),
    "add-step": _Verb(
        _h_add_step,
        "<run> <step-id> [depends-on-json] [phase]",
        rejects="RunRecordError on a duplicate id or a dependency on an unknown step.",
    ),
    "reshape-deps": _Verb(
        _h_reshape_deps,
        "<run> <step-id> <depends-on-json>",
        rejects="RunRecordError on a dependency cycle or an edge to an unknown step.",
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


# ─── the OPERATOR revert command (U10 / KTD-1) ──────────────────────────────
# `downgrade` is deliberately NOT a `_VERBS` entry. That registry is the AGENT tool
# surface: `describe` publishes it, docs/contracts/agent-tool-surface.md fences it,
# and a driving agent is told to orient by it. An offline, data-destructive, revert-
# only operator action has no business in the set an agent is told it may call — so
# it is dispatched here, ahead of the registry, and `describe`/`_VERBS` are untouched.
# (Same division as `workflows.py migrate`: the maintenance command lives beside the
# format it maintains, not on the agent's surface.)
#
# It lives on THIS module — not on lib/format_compat.py, which owns the maps — for one
# hard reason: format_compat is a DAG ROOT that imports no sibling, so it cannot reach
# the run-record flock, and KTD-1 requires the downgrade to write UNDER THAT LOCK
# ("the same lock every mutation holds, so it never races a concurrent in-process
# write"). This module already loads run_record_core, so the real lock is one call away.
#
# It CANNOT go through core's normal read/write helpers, and that is not an oversight:
#   * `_read_json` UPGRADES on read (chokepoint 1) — it would hand back a v2 dict.
#   * `_atomic_write` re-stamps `format: 2` and recomputes the predicate — it would
#     undo the downgrade in the same breath.
# The whole point of a downgrade is to bypass the shim, so this does a RAW read and a
# RAW atomic write, and borrows ONLY the lock.


def _record_lock_path(path: str) -> str:
    """The flock file for the run-record at ``path``.

    Derived from the record path because the revert procedure addresses STRANDED
    records by path, not by (repo, run). This mirrors run_record_core exactly —
    `run_record_path()` is `<dir>/<slug>.json` and `lock_path()` is `<dir>/<slug>.lock`,
    same directory, same stem — and tests/unit/format-compat.test.sh PINS that
    equivalence against the real helpers, so a change to the lock convention in core
    turns this red instead of silently unlocking the downgrade.
    """
    return os.path.splitext(os.path.abspath(path))[0] + ".lock"


def downgrade_record_file(path: str) -> bool:
    """Rewrite the format-v2 run-record at ``path`` back to v1, in place, under the
    run-record flock (KTD-1). Returns True if the file changed, False if it was
    already v1 (the inverse map is idempotent, so a second run is a safe no-op).

    Atomic = mkstemp + os.replace in the record's own directory: a crash mid-write
    leaves the original intact, never a half-written record.

    OFFLINE / QUIESCED ONLY. The flock stops a CONCURRENT writer from being lost; it
    does NOT stop a LATER one from re-upgrading. A downgraded record lazy-migrates
    straight back to v2 on its next write by new code, so the state dir must be
    quiesced (no live sessions, no hooks) between this and the reinstall of pre-rename
    code. There is no online-downgrade guarantee — see KTD-1.
    """
    import tempfile

    def body():
        with open(path) as fh:
            before = json.load(fh)          # RAW read: never _read_json (it upgrades)
        after = format_compat.downgrade_run_record(before)
        if after == before:
            return False
        target_dir = os.path.dirname(os.path.abspath(path)) or "."
        fd, tmp = tempfile.mkstemp(prefix=".downgrade.", suffix=".json", dir=target_dir)
        try:
            with os.fdopen(fd, "w") as fh:  # RAW write: never _atomic_write (it re-stamps)
                json.dump(after, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True

    return run_record_core._flock_run(_record_lock_path(path), body)


def _h_downgrade(argv):
    if len(argv) != 2:
        sys.stderr.write(
            "usage: run_record.py downgrade <path-to-run-record.json>\n"
            "  OFFLINE REVERT ONLY: maps a format-v2 record back to v1 and strips the\n"
            "  format marker, so pre-rename code can read it. Quiesce the state dir first.\n"
        )
        return 2
    path = argv[1]
    try:
        changed = downgrade_record_file(path)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"run_record.py: downgrade failed for {path!r}: {e}\n")
        return 1
    sys.stdout.write(
        f"{path}: downgraded to format-v1\n" if changed
        else f"{path}: already format-v1 (no change)\n"
    )
    return 0


# KTD-4 REVISITED — the retired work-node verbs get DEPRECATED ALIASES.
#
# U7 hard-cut `add-unit` / `set-enumerated-units` to their `step` spelling with NO
# alias, on the reasoning that "verbs are never persisted, so nothing in flight can
# hold one". That reasoning is wrong, and it is the ONE place the rename decided this
# question inconsistently:
#
#   The pre-rename guidance module (what is now `lib/pulse_guidance.py`) EMITS
#   GUIDANCE naming these verbs — it hands the driving agent a literal
#   `… set-enumerated-units <args>` line to run. The verb is not persisted, but the
#   INSTRUCTION TO RUN IT is: it sits in an agent's context (and in a persisted rearm
#   prompt) across the upgrade. An agent mid-run then executes a verb that exits 2 and
#   the run stalls — the exact in-flight scenario the deprecated flag aliases and the
#   kept alias command exist for. Same problem; it was decided the other way here.
#
# Same mechanism as `_DEPRECATED_FLAGS` in lib/auto.py: rewrite the retired spelling
# to its canonical one, emit exactly ONE stderr notice (stdout stays byte-clean, so
# `… read | jq` keeps working), and fall through to the canonical handler — which owns
# arity and validation. There is no second implementation to drift.
#
# NOT in `_VERBS`, and so NOT in `describe` or the agent-tool-surface contract: an
# alias is a bridge for an agent that already holds the old name, not a verb we
# advertise. Same posture as `downgrade`. Removed in v0.15.0 (docs/deprecations.md).
_DEPRECATED_VERBS = {
    "add-unit": "add-step",
    "set-enumerated-units": "set-enumerated-steps",
}


def _cli(argv):
    if not argv:
        sys.stderr.write("usage: run_record.py <subcommand> ...\n")
        return 2
    if argv[0] == "downgrade":
        return _h_downgrade(argv)
    canon = _DEPRECATED_VERBS.get(argv[0])
    if canon is not None:
        sys.stderr.write(
            f"run_record.py: {argv[0]} is deprecated; use {canon}\n"
        )
        argv = [canon] + list(argv[1:])
    verb = _VERBS.get(argv[0])
    if verb is None:
        # An agent holding a verb name we do not know must not be left guessing —
        # point it at `describe`, the machine-readable mirror of `_VERBS` that
        # docs/contracts/agent-tool-surface.md contractually tells it to orient by.
        # Exit 2 (bad args), never a silent no-op.
        sys.stderr.write(
            f"run_record.py: unknown subcommand {argv[0]!r}\n"
            "  run `python3 lib/run_record.py describe` for the authoritative verb set.\n"
        )
        return 2
    try:
        return verb.handler(argv)
    except RunRecordError as e:
        sys.stderr.write(f"run_record.py: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"run_record.py: bad arguments: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
