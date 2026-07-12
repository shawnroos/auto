# Planning Readiness: auto conversation-driven smart entry

Consolidated from a context-gathering pass (2026-06-11) over the auto engine,
recipe/phase system, goal author, the parked v0.5.0 substrate plan, and the
relevant memories. Purpose: tee up `/ce-brainstorm` with the resolvable
questions resolved and the genuinely-open decisions sharpened.

**Planning is blocked on two decisions only (#1, #2 below). Everything else is
resolved.** Those two are exactly what the handoff says `/ce-brainstorm` exists
to lock.

---

## Resolved findings (the spine)

### R1 — Phase auto-advance: the engine is ALREADY multi-phase-capable
`lib/phase-grammar.py` is fully general — `phase_order()`, `next_phase_after_met()`,
`is_terminal_phase()`, `emitter_name_for_arrival()` all handle arbitrary phase
lists. The **only** lock is `lib/recipes.py:201` `_V1_ALLOWED_PHASE_ORDERS`,
hardcoded to two values (default `["plan","seam","work"]` and work-only
`["work"]`). This is the deferred **A3 "Build-First"** work — A3 alone drove ~40%
of v0.2.0's engine surface and was punted to v0.2.1, never built.

Unlocking phase auto-advance is therefore not greenfield, but it's also **not
just relaxing line 201**. Each new phase boundary needs:
- a `{from, to, emitter}` entry in the recipe's `phase_transitions[]` (emitter
  fires on ARRIVAL at `to`), and
- a registered emitter — possibly a *new* one in `lib/emitters.py` (register in
  `REGISTRY` + add the name to `recipes.py:48-59` `V1_EMITTER_NAMES`).

A run bakes ONE recipe at `init_ledger`; resume never reloads. So "chain phases"
= author a single multi-phase recipe, not runtime recipe-chaining.

### R2 — The review→verify→fix-until-only-P3 loop already exists
It IS auto's core exit predicate: `exit_predicate_result.met == true` iff
`blockers==0 AND majors==0 AND all_units_terminal==true`. Recomputed atomically
on every ledger write (I-1); the Stop hook (`lib/on-stop.py`) owns the verdict
and blocks Stop until met (carve-out: `driver=="manual"` for paused seams).
"Fix" = re-dispatch within the work-loop; closure only when no blocker/major
findings remain. **The smart-entry layer doesn't build this loop — it wraps a
chosen ce phase in it.**

### R3 — "Ultracode-style workflow" = the fan-out+verify pattern auto already has (NOT the Workflow tool)
auto's work-loop fan-out (`lib/dispatcher.py`: `ready_units` → `dispatch_batch`
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
- **Track auto's deterministic predicate** (all units terminal, only P3 remain)
  as the primary criterion, to minimize divergence from the Stop hook.
- Native `/goal` is model-judged with **no external predicate seam** — auto can
  neither arm nor clear it (`/goal clear` is the only release). auto uses ONLY
  its own Stop hook. A phase goal here binds to auto's exit predicate, NOT native
  `/goal`'s judgment.

### R5 — Versioning: 0.5.0 is reserved
Current shipped version is **0.4.2** (`plugin.json`). `0.5.0` is reserved for the
**parked** workflow-substrate migration (`docs/plans/2026-05-29-002-rfc-...`,
status `parked`; the live Plan of Record there is a v0.4.x escape-hatch). This
feature is orthogonal infrastructure → **take its own line (0.6.0)**, or
deliberately reframe it AS the substance of 0.5.0 and push substrate to 0.6.0.
Decision for Shawn (see below).

### R6 — Known limitation to carry: auto-advance is forward-only
`feedback_a1_recipe_cant_rebound_to_brainstorm`: a1's state machine has no arrow
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
| Reviewed plan present | work-only (`w` recipe) | yes |
| Code written, unreviewed | `/ce-code-review` | yes |
| Bug/error under discussion | `/ce-debug` | yes |
| "What should I improve?" | `/ce-ideate` | n/a (upstream) |
| Perf concern raised | `/ce-optimize` | yes |

This is a heuristic skeleton — the recommendation engine and confidence
thresholds are brainstorm/plan work.

---

## Where the pieces live (extension seams)
- Orientation: `skills/auto-driver/SKILL.md` (dispatch grammar), `lib/auto-detect.sh`
  (hypothesis former — read-only, must always emit a parseable envelope, all keys
  present even null, exit 0 on any non-fatal path).
- Loop: `skills/auto/SKILL.md` (§1 goal binding, §4.5 pause), `lib/tick.py`,
  `lib/dispatcher.py`, `lib/on-stop.py` (Stop hook owns verdict).
- Phases/recipes: `lib/recipes.py:201` (the lock), `lib/phase-grammar.py`
  (general), `lib/emitters.py` (emitter registry), `recipes/*.json`.
- Goal: `skills/auto-author-goal/SKILL.md`.
- Engine theory: `docs/contracts/driver-reference.md`, `docs/contracts/ledger-schema.md`.

## Suggested first move
`/ce-brainstorm` to lock **D1** (advisor-routing mechanism) and confirm **D2**
(context source) + **R6** (forward-only vs backward-edge) + the version line
(R5). Then `/ce-plan`.
