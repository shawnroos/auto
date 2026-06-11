# Spike: advisor-invocation contract (U0 — gates Phase A)

Date: 2026-06-11. Plan: `docs/plans/2026-06-11-001-feat-auto-conversation-entry-plan.md` (KTD-4/5, R-7).

**Question:** can auto consult the `advisor` with a specific decision and get back
something it can deterministically act on (resolve-mechanical vs escalate-design-fork)?

## Findings

### (a) Reachability — CONFIRMED (broad)
`advisor` is reachable both from the **main driving session** (used repeatedly while
authoring + reviewing this plan) AND from **dispatched subagents** (empirically probed: a
`general-purpose` Agent reported `advisor` present in its toolset). Since a `/auto`
self-driven run rides the main session via `ScheduleWakeup` re-invocation, the driving
agent can always call `advisor`. Implication: reachability is NOT a constraint — the
two-seam split (U5) is therefore belt-and-suspenders for *reachability*, but stays correct
because the PreToolUse hook cannot intercept fan-out subagents regardless (different
`session_id`).

### (b) Targetability — WORKABLE (by context-placement, not by parameter)
`advisor` is **parameterless** and auto-forwards the whole transcript. A specific decision
is posed by stating it in the conversation immediately before the call; the advice then
addresses it (observed behavior throughout this session — each call responded to the
most-recent reasoning). There is no question parameter; targeting is by context, not API.

### (c) Branchability — PROSE, NOT A VERDICT (the one clarification)
`advisor` returns **free-form prose**, with no structured `{decision, confidence}` field.
So auto **cannot read a machine verdict** off it. The resolve-vs-escalate decision must be
made by the **driving agent** reading the prose advice — the advisor is an *input* to the
agent's judgment, not an oracle returning a classification.

## Decision on KTD-4: GO, with a wording clarification (no structural reshape)

KTD-4's mechanism stands. Correct the framing from "the advisor classifies the question"
to: **the driving agent consults the advisor (prose advice) and itself classifies** —
resolving mechanical clarifications, escalating substantive design/architecture forks via
the pause seam. No parse-to-struct step and no alternate resolver are needed; the agent
was always going to be the brancher. Escalation-on-uncertainty = the agent escalates when
the advice (or its own read) is not clearly "mechanical." The deterministic destructive
backstop (Bash/Write hook) is unaffected — it never depended on the advisor.

U4/U5 may now build against this clarified contract. Plan KTD-4/U5 wording updated to match.
