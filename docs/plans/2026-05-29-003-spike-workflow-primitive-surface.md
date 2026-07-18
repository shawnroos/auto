---
title: "Spike — Workflow tool primitive surface (superseded)"
status: superseded
superseded_by: docs/plans/2026-07-17-001-feat-agent-native-auto-plan.md
created: 2026-05-29
type: spike
parent: docs/plans/2026-05-29-002-rfc-workflow-substrate-migration.md
revisit_conditions:
  - "Workflow tool appears in the harness deferred-tool inventory (verify via ToolSearch)"
  - "Or maintainers publish a release date for the Workflow tool"
  - "Or the v0.4.x escape-hatch's observability work surfaces enough off-script shapes (>=3 distinct, >=2 in-process) to motivate the substrate path"
---

# Spike: Workflow tool primitive surface (preflight)

> **Status:** SUPERSEDED by
> [docs/plans/2026-07-17-001-feat-agent-native-auto-plan.md](2026-07-17-001-feat-agent-native-auto-plan.md)
> (agent-native /auto), alongside its parent RFC 002. The substrate path it
> preflighted is no longer the direction; parked content preserved for provenance.
>
> **Status (historical):** PARKED stub. This spike is the load-bearing preflight
> for the workflow-substrate migration RFC at
> `docs/plans/2026-05-29-002-rfc-workflow-substrate-migration.md`.
> The full spike specification (U0 in the parked RFC) is preserved
> there until extraction is justified.

## Why this exists

The substrate migration RFC has a single load-bearing prerequisite:
the Claude Code Workflow tool must exist with a verified primitive
surface (parallel-fan-out, structured outputs, resume/retry,
cross-session continuation, heartbeat hook) sufficient to host
auto's engine. At plan-writing time (2026-05-29) the Workflow tool
is NOT present in this harness's deferred-tool inventory (confirmed
via ToolSearch).

Until that changes, this spike cannot run. When it can run, the
detailed scope lives in the parked RFC's U0 section and should be
moved here verbatim.

## Trigger

This stub becomes a live spike plan when ANY of the
revisit_conditions in the frontmatter resolve positively. At that
point:

1. Lift U0's full text from the parked RFC (002) into this file's
   `## Scope` and `## Method` sections.
2. Update this file's `status` from `parked` to `plan_of_record`.
3. Author and run the spike; record findings here.
4. Spike outcome feeds the revisit-conditions decision on RFC 002.

Until then, this file is a discoverability anchor so the parent
RFC's pointer resolves to a real path.
