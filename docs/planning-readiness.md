# Planning Readiness: auto conversation-driven smart entry

Consolidated from a context-gathering pass (2026-06-11) over the auto engine,
workflow/phase system, goal author, the parked v0.5.0 substrate plan, and the
relevant memories. Purpose: tee up `/ce-brainstorm` with the resolvable
questions resolved and the genuinely-open decisions sharpened.

> **Dated snapshot — read the code, not this, for current fact.** This was written
> on 2026-06-11 and several of its findings have since SHIPPED (goal-aware plan
> routing in v0.11.0; the launch chooser in v0.9.0; the multi-phase spine that R1
> called locked). Symbol names were refreshed against the current tree during the
> concept-vocabulary rename, and the claims below that are now false are corrected
> in place and marked. It is kept for the decision RECORD (D1/D2, R6), not as an
> orientation doc.

**Planning is blocked on two decisions only (#1, #2 below). Everything else is
resolved.** Those two are exactly what the handoff says `/ce-brainstorm` exists
to lock.

---

## Resolved findings (the spine)

### R1 — Phase auto-advance: the engine is ALREADY multi-phase-capable
> **SUPERSEDED (shipped).** The lock this finding names is GONE, and the
> multi-phase spine it proposes now ships as `workflows/pipeline.json`
> (`brainstorm → plan → handoff → work`). Kept for the reasoning, which still
> holds for any NEW phase boundary.

`lib/phase-grammar.py` is fully general — `phase_order()`, `next_phase_after_met()`,
`is_terminal_phase()`, `producer_name_for_arrival()` all handle arbitrary phase
lists. The lock this doc found — a literal phase-order allow-list in the workflow
validator, hardcoded to the default and work-only orders — was **dropped in
v0.6.0**: `lib/workflow_validate.py` now validates `phase_order` **structurally**
(every element a non-empty string, members cross-checked downstream), so an
arbitrary spine like `["brainstorm","plan","handoff","work"]` validates. Only
`_DEFAULT_PHASE_ORDER` (`["plan","handoff","work"]`) and `_WORK_ONLY_PHASE_ORDER`
survive, as the default and the empty-steps guard.

Adding a phase boundary is therefore config, not engine work — but it is still
**not free**. Each new boundary needs:
- a `{from, to, producer}` entry in the workflow's `phase_transitions[]` (the
  producer fires on ARRIVAL at `to`), and
- a registered producer — possibly a *new* one in `lib/step_producers.py` (register
  it in `REGISTRY` **and** add the name to `V1_PRODUCER_NAMES` in
  `lib/workflow_validate.py`; a symmetry test pins `set(REGISTRY) ==
  V1_PRODUCER_NAMES`, so the two land together or the suite goes red).

A run bakes ONE workflow at `init_run_record` (`lib/run_record_core.py`); resume
never reloads. So "chain phases" = author a single multi-phase workflow, not runtime
workflow-chaining.

### R2 — The review→verify→fix-until-only-P3 loop already exists
It IS auto's core exit predicate: `exit_predicate_result.met == true` iff
`blockers==0 AND majors==0 AND all_steps_terminal==true` (plus a non-empty `steps`
conjunct, so an empty record blocks rather than exits). Recomputed atomically
on every run-record write (I-1); the Stop hook (`lib/on-stop.py`) owns the verdict
and blocks Stop until met (carve-out: `driver=="manual"`, which a handoff pause
emits). "Fix" = re-dispatch within the work-loop; closure only when no blocker/major
findings remain. **The smart-entry layer doesn't build this loop — it wraps a
chosen ce phase in it.**

### R3 — "Ultracode-style workflow" = the fan-out+verify pattern auto already has (NOT the Workflow tool)
auto's work-loop fan-out (`lib/dispatcher.py`: `ready_steps` → `dispatch_batch`
→ converge, each agent self-writes its verdict atomically) already implements
the fan-out + adversarial-verify shape "ultracode" describes. The locked
`deterministic-over-probabilistic` / engine-owns-the-verdict decisions cut
*against* delegating orchestration to the harness `Workflow` tool.

*Bounded note:* the `Workflow` tool IS now present in this session's inventory
(it wasn't when the substrate RFC was parked). That clears only one of three
gated revisit conditions for substrate (the others: ≥10x run volume; ≥3
off-script shapes; an **API-stability commitment**, not mere existence). This
feature was explicitly decided to **not depend on substrate**. Keep substrate
parked; do not let the tool's availability pull the design toward it.

### R4 — Goal authoring: reuse `auto-author-goal`, bind to auto's predicate
`skills/auto-author-goal/SKILL.md` (shipped 0.4.2) authors a model-judgeable goal
doc to `.claude/auto/goals/<slug>.md`; the user binds it with `/goal <path>`.
Hard constraints inherited:
- **Agent-completable** — every criterion must name a state the agent can REACH
  + verify, or the model-judged goal never flips to met (never-met loop). Manual
  steps go out-of-scope.
- **Track auto's deterministic predicate** (all steps terminal, only P3 remain)
  as the primary criterion, to minimize divergence from the Stop hook.
- Native `/goal` is model-judged with **no external predicate hook** — auto can
  neither arm nor clear it (`/goal clear` is the only release). auto uses ONLY
  its own Stop hook. A phase goal here binds to auto's exit predicate, NOT native
  `/goal`'s judgment.

### R5 — Versioning: 0.5.0 is reserved
> **SUPERSEDED (dated).** Version numbers below were true on 2026-06-11. The
> shipped version has moved on many times since (see `.claude-plugin/plugin.json`
> for the current one). The reasoning — substrate keeps its reserved line, this
> feature takes its own — is what's kept.

`0.5.0` is reserved for the **parked** workflow-substrate migration
(`docs/plans/2026-05-29-002-rfc-...`, status `parked`; the live Plan of Record
there is a v0.4.x escape-hatch). This feature is orthogonal infrastructure → it
takes its own line. Decision for Shawn (see below).

### R6 — Known limitation to carry: auto-advance is forward-only
`feedback_a1_recipe_cant_rebound_to_brainstorm` (a memory ID — the retired
spelling is part of its name): a1's state machine has no arrow
pointing upstream. When a review phase surfaces a flaw *inherited from* an
upstream phase (brainstorm/plan), the engine treats `gaps_open=N` as a flat
count — it can't distinguish "local gap" from "inherited gap" and can only ratchet
more deepen passes against a gap it can't close. **"Auto-advance through
subsequent phases" must decide its stance: forward-only (and detect+halt on
upstream-clustered findings), or add a backward edge.** This is a brainstorm-time
design decision, not an afterthought.

---

## Live decisions — planning is blocked on these two

### D1 — Advisor-routing mechanism (handoff open-Q #1) — GENUINELY OPEN
"Route questions to advisor, not the user." In-session evidence: the `advisor`
tool in THIS session is a **harness-native review aid** gated by
`~/.claude/settings.json` (`advisorModel: opus`) — you *call* it; it does **not**
auto-replace `AskUserQuestion`. So this is NOT a reference implementation of the
feature's want. The feature still needs a mechanism, and the tension is real: ce
skills lean on `AskUserQuestion` heavily (ce-doc-review pre-loads it; ce-sessions
mandates a blocking question tool). Candidate mechanisms to weigh in brainstorm:
output-style switch, a `SessionStart`/`UserPromptSubmit` hook that injects
routing guidance, or a per-run flag — each needs a clean override that doesn't
break the ce skills.

### D2 — Context source (handoff open-Q #2) — RESOLVABLE; recommend this split
The "assess context" input decomposes into two distinct sources:
1. **Current conversation** (the primary trigger — "the discussion we just had"):
   `ce-sessions` explicitly **refuses to analyze the current session** ("already
   available to the caller"). So current-session assessment = the auto-driver
   agent reflecting on its own live transcript — free, no file read, no new probe.
2. **Recent prior sessions (~2 days back)**: this is exactly what `ce-sessions`
   is built for — `discover-sessions.sh <repo> <days>` globs JSONL session files
   by repo + window, then `extract-metadata/skeleton/errors` filter before any
   reasoning (never whole files, never thinking blocks).

**Constraint:** `feedback_compaction_summary_may_hallucinate_apis_verify_against_git`
— do NOT use raw compaction-summary text as the context source; prefer
ce-sessions' structured extraction (and verify any API/code claim against git).
This argues against the handoff's "compacted logs" phrasing.

Recommendation: current-session reflection + `ce-sessions` for the ~2-day
lookback, not a new probe in `auto-detect.sh`. Confirm in brainstorm.

---

## ce-family routing taxonomy (handoff open-Q #6) — first cut for brainstorm

| Detected conversation state | Recommended ce next step | Wrapped in review/fix loop? |
|---|---|---|
| Vague/exploratory, scope unclear | `/ce-brainstorm` | n/a (upstream) |
| Clear intent, no plan | `/ce-plan` | plan-loop → exit predicate |
| Reviewed plan present | work-only (`w` workflow) | yes |
| Code written, unreviewed | `/ce-code-review` | yes |
| Bug/error under discussion | `/ce-debug` | yes |
| "What should I improve?" | `/ce-ideate` | n/a (upstream) |
| Perf concern raised | `/ce-optimize` | yes |

This is a heuristic skeleton — the recommendation engine and confidence
thresholds are brainstorm/plan work.

---

## Where the pieces live (extension points)
- Orientation: `skills/auto-driver/SKILL.md` (dispatch grammar), `lib/auto-detect.sh`
  (hypothesis former — read-only, must always emit a parseable envelope, all keys
  present even null, exit 0 on any non-fatal path).
- Loop: `skills/auto/SKILL.md` (§1 goal binding, §4.5 pause), `lib/pulse.py`,
  `lib/dispatcher.py`, `lib/on-stop.py` (Stop hook owns verdict).
- Phases/workflows: `lib/workflow_validate.py` (validation + `V1_PRODUCER_NAMES`),
  `lib/phase-grammar.py` (general), `lib/step_producers.py` (the producer
  `REGISTRY`), `workflows/*.json`.
- Goal: `skills/auto-author-goal/SKILL.md`.
- Engine theory: `docs/contracts/driver-reference.md`, `docs/contracts/run-record-schema.md`.

## Suggested first move
`/ce-brainstorm` to lock **D1** (advisor-routing mechanism) and confirm **D2**
(context source) + **R6** (forward-only vs backward-edge) + the version line
(R5). Then `/ce-plan`.
