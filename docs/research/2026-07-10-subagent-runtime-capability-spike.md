---
title: "Spike — background sub-agent runtime capabilities"
type: spike
date: 2026-07-10
status: complete
verdict: green-with-constraint
feeds: docs/plans/2026-07-10-001-feat-auto-agent-native-runtime-plan.md
---

# Spike: can a background sub-agent host auto's durable, self-paced, stop-gated loop?

Binary question for the agent-native runtime: can the loop runtime be pushed *down* into a background sub-agent, or do the harness's session-scoped mechanisms refuse to cross into the tree?

**Method.** A live introspection probe — a real background sub-agent launched via the `Agent` tool — tested its own capabilities and reported verbatim results. Cross-checked against what the repo already encodes about sub-agent hook/session behavior.

## Findings

| Probe | Result | Evidence |
|---|---|---|
| Self-pacing | **NO** | `ScheduleWakeup` and `CronCreate` are absent from a sub-agent's tool registry (`ToolSearch select:...` → "No matching deferred tools found"). Only `Monitor` (within-session) exists. A sub-agent runs once to completion; it cannot re-arm a successor. |
| Context / hooks | **Context yes, session-scoped hooks no** | SessionStart-style injection propagates (CLAUDE.md, `MEMORY.md`). But the sub-agent has its own `CLAUDE_CODE_SESSION_ID` + `CLAUDE_CODE_CHILD_SESSION=1`, and auto's PreToolUse gates match `session_id == ledger.driving_session_id`, so they do not reach it — consistent with `skills/auto/SKILL.md:248-271`. |
| Ledger RMW | **YES** | Round-trip via `lib/ledger.py` CLI verbs confirmed: `transition u1 dispatched` (exit 0) → `read` returned `u1 state = ['dispatched']`. Constraint: `init_ledger` is Python-API-only — no CLI `init` verb. |
| Nesting | **YES** | The `Agent` tool is in a sub-agent's tool set; the tree can go deeper than one level. |

## Verdict — green, with a constraint that sharpens the design

A background sub-agent is a viable host for ledger-driven work that can nest and inherits context — but it has **no native self-pacing primitive**. So the durable, self-paced cadence and the Stop-hook keep-alive must live in the **main session**, not in the tree.

That is the intended shape, not a compromise: the fable main session stays the thin, self-paced, stop-gated anchor (goal doc + digests), and its tick chain becomes a *dispatcher* — each loop phase is delegated to a sub-agent that self-writes its verdict to the shared ledger. The heavy, context-consuming work lives in disposable sub-agents; the main session's context stays clean.

Caveat: this probe proved context injection propagates, not that the plugin Stop hook *fires* for a sub-agent's Stop event. The no-self-pace finding settles the architecture regardless. Reviewed by the stronger advisor model: no (advisor tool was unavailable this session).
