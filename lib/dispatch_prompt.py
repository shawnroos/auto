#!/usr/bin/env python3
"""auto U7 (finding #6, Top-3): the canonical dispatch-prompt template.

``dispatcher.dispatch_batch``'s ``launch_fn`` is an injected no-op recorder — the
engine does the ``pending -> dispatched`` transition, but the DRIVER owns turning
"dispatch step U3" into an actual ``Agent`` spawn. Before this asset the boss
hand-built each agent's prompt, its ``record-verdict`` call, and its attempt tag,
and standard ``/ce-work`` has NO run-record awareness — so the wiring was
reinvented every wave and the gap nearly triggered an abort (field-notes #6).

``build_dispatch_prompt`` renders that whole contract from a small packet so every
driver wires it identically. It carries:

  * the step packet (run id, step id, goal);
  * the R21 register-session SAFETY line (the sub-agent must register its own
    session into the run's ownership set BEFORE any Bash, so the destructive
    backstop + advisor gate are armed for it);
  * finding #2's record-before-yield MANDATE (R8): write the verdict BEFORE any
    long-running background wait, so a slow/flaky verification step can never
    strand the verdict at ``dispatched`` (the field failure: agents ran a >120s
    Karma suite, yielded to the monitor, and ended with no verdict);
  * the verdict-write contract, routed through the interpreter-pinned
    ``run_record.sh`` shim (U3 — NEVER the raw ``run_record.py`` under ``bash``,
    which runs the Python file as shell and corrupts the write); and
  * the attempt tag (Bug #6 generation) so the verdict is stamped with the
    dispatch generation it belongs to.

Pure stdlib leaf (no sibling imports) so it loads standalone and stays off the
heavy-module DAG. The driver fills the packet and passes the rendered string to
its injected ``launch_fn`` (the ``Agent`` ``run_in_background`` spawn).
"""

from __future__ import annotations

# The run-record shim entry (U3): interpreter-pinned, never the raw `.py` under
# bash. Kept as a module constant so the verdict-write contract has ONE spelling.
RUN_RECORD_SHIM = "bash lib/run_record.sh"


def verdict_write_command(run_id: str, step_id: str, attempt: int) -> str:
    """The exact verdict-write command a dispatched agent must run on completion.

    ``bash lib/run_record.sh record-verdict <run> <step> '<json-findings>' <attempt>``
    — the I-1 atomic chokepoint, durable the moment the (separate) agent process
    writes it, independent of the boss turn. ``<json-findings>`` is a placeholder
    the agent fills with its own findings array; run/step/attempt are baked in.
    """
    return (
        f"{RUN_RECORD_SHIM} record-verdict {run_id} {step_id} "
        f"'<json-findings>' {attempt}"
    )


def build_dispatch_prompt(
    run_id: str,
    step_id: str,
    attempt: int,
    *,
    goal: str | None = None,
    skill: str = "/ce-work",
) -> str:
    """Render the canonical dispatch prompt for one step of an auto run.

    ``skill`` is the work skill the agent runs scoped to the step (default
    ``/ce-work``; a driver may pass ``/ce-code-review`` for an off-spine review
    step). ``goal`` is the step's one-line objective (from its
    ``dispatch_context``); omitted when the step packet already carries it.
    Returns a self-contained prompt string — the driver passes it verbatim to the
    spawned ``Agent``.
    """
    goal_line = f"\nObjective: {goal}" if goal else ""
    verdict_cmd = verdict_write_command(run_id, step_id, attempt)
    return f"""\
You are a scoped work agent for auto run `{run_id}`, step `{step_id}` (attempt {attempt}).{goal_line}

FIRST, before any Bash, register your session so the destructive-command backstop
and advisor gate are armed for you (R21 — LOAD-BEARING SAFETY):
    {RUN_RECORD_SHIM} register-session {run_id}

Then do the work for step `{step_id}` by running `{skill}` scoped to this step —
implement and verify ONLY this step's contents. Do not touch other steps.

RECORD YOUR VERDICT BEFORE ANY LONG-RUNNING BACKGROUND WAIT (record-before-yield).
If a check backgrounds (a >120s test suite, a slow build), write your verdict
FIRST and let the check's outcome fold into a later pass — never yield to wait for
background work with the verdict still unwritten, or your work strands the step at
`dispatched` and forces a wasteful full re-run.

On completion, self-write your verdict — durable independent of the boss turn:
    {verdict_cmd}
Replace `<json-findings>` with your findings array (each: severity + note; an
empty array `[]` means a clean pass). The attempt tag `{attempt}` stamps the
verdict with this dispatch generation — do not change it.
"""
