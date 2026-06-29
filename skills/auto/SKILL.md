---
name: auto
description: >
  Drive an auto run: chain the plan-loop → seam → work-loop using the
  self-pacing tick (lib/tick.py), the agent-managed orchestrator
  (lib/orchestrator.py), and a deliberate-stop /goal binding. Use when
  invoked via /auto, when continuing after a seam, or when resuming a
  run. This skill IS the driving agent: arms the tick chain, decides
  the work-loop fan-out cap per wave (resizable in flight), reads the
  ledger's cached exit predicate to know when the loop is done. NEVER
  re-evaluates the predicate itself.
---

# auto (loop driver)

**Prepare/execute, ledger-anchored.** This skill PREPARES intents; the
model EXECUTES them. Re-ticking without running the prepared
invocation is a no-op. Source of truth is the disk ledger at
`<repo>/.claude/auto/<run>.json`; the conversation is advisory. Full
contract + traps (bash-loop, deepen↔review livelock):
`docs/contracts/driver-reference.md` §1.

## 1. Goal binding

Every `/auto` run is goaled before arming.

- **Default:** the loop's exit predicate — *until only P3 findings
  remain* (`exit_predicate_result.met` becomes true).
- **Compound** (operator-supplied via `--goal`): honor verbatim; bind
  to BOTH the loop's `met` AND the operator's clause.

Auto's deliberate-stop is its OWN Stop hook (`lib/on-stop.py` via
`lib/goal-status.py`), which reads the ledger's `exit_predicate_result`.
This "goal" is the ledger predicate — **not** the native `/goal`
command. Do NOT run native `/goal`: it is model-judged with no external
predicate seam (U9 spike), so auto can neither feed it the verdict nor
clear it — a native `/goal` set alongside a run will re-prompt "Goal not
yet met… continuing" on every turn and auto cannot stop it (only
`/goal clear` can). Binding is automatic: ensure the run's ledger exists
and `loop.driver` reflects state (`"self"` / `"manual"`); the Stop hook
engages off that. Never proceed without a legible ledger predicate. Full
mechanism: `driver-reference.md` §3.

If the operator WANTS a native `/goal` (opt-in, additive to the Stop
hook), the `auto-author-goal` skill turns a plan into a model-judgeable
condition phrased to MIRROR auto's exit predicate (so the two gates
agree) and saves it as a goal doc for the operator to bind by hand —
auto still never runs `/goal` itself.

## 2. Arm the tick chain

Fire the first tick. The command is NAMESPACED (`/auto:auto-tick`) — a plugin
slash command fired programmatically (ScheduleWakeup / loop) only resolves in
its `/<plugin>:<command>` form; the bare `/auto-tick` is "Unknown command":

```
ScheduleWakeup(delay=60, prompt="/auto:auto-tick <run>")
```

`ScheduleWakeup` clamps delay to `[60, 3600]s`. Each tick returns a
re-arm intent dict on stdout; the driver acts on it. Phase-aware
dispatch:

| `action` | phase | what you do |
|----------|-------|-------------|
| `rearm`  | `plan` | `ScheduleWakeup(intent.delay, intent.prompt)` — short delay |
| `rearm`  | `work` | YIELD; harness re-invokes on next verdict. LONG ScheduleWakeup (1200s+) ONLY when no work in flight AND no ready units (genuinely stalled) |
| `stop`   | any   | chain ends; do NOT re-arm. `predicate-met*` → report (§5); `seam-pause` → surface seam (§3) |
| `noop`   | any   | another live tick holds the lock; do nothing |

Never re-arm on `stop` / `noop`. Never short-poll the work-loop.

**stdout is exactly one JSON object.** Every tick AND every
`/auto-resume` re-arm path writes a single JSON object to stdout and
nothing else — parse the WHOLE of stdout with `json.loads`; there is no
prose to strip and no leading/trailing lines to skip. (The two surfaces
use different `action` values — a tick emits `action: "rearm"`,
`/auto-resume` emits `action: "arm-tick"` — but both are exactly one
JSON object.) All human-readable status, diagnostics, and the prose
`operator_guidance`/`note` text ride *inside* that object (as fields) or
on **stderr**, never as loose stdout lines. If you ever see "non-JSON
noise" on stdout, you are reading stderr merged in — parse stdout alone.

**The `plan-enumerate-pending` handshake is NOT ceremony.** This is a
*tick* intent (not a resume one): when the plan closes, the tick fires a
normal `action: "rearm"` intent whose `advance.advanced ==
"plan-enumerate-pending"` (with a prose `operator_guidance` field
describing the prepare op). (`/auto-resume advance` on a plan-phase run
doesn't emit this itself — it emits its own `arm-tick` to arm the tick
that THEN surfaces the handshake.) The handshake is an instruction, not
noise: run the enumerate prepare op and stash the work units via
`ledger.py set-enumerated-units`, **then re-arm the tick**. The NEXT
tick — once units are stashed — flips `plan → work`. Do NOT read the
envelope as "done planning, start building" and skip the re-arm: skipping
it leaves the run at `plan` with the work-loop never armed.

## 3. Seam

When plan predicate met:

- **Not `auto`** (operator passed `--review-plan`): tick writes
  `loop_phase = "seam"`, `seam_paused = true`, returns `stop`,
  `reason == "seam-pause"`. Surface the plan + parallelism analysis.
  Resume via `/auto-resume continue <run>` (→ work) or
  `/auto-resume abort <run>` (→ done).
- **`auto`** (v0.4.0 default): tick that closes plan predicate flips
  `plan → work` directly and keeps re-arming. No pause.

## 4. Work-loop fan-out (event-driven)

The harness re-invokes you when a background `Agent` finishes — that
IS the wake signal. Per wave:

1. `units = orchestrator.ready_units(repo, run)`.
2. Decide cap for THIS wave (16 idle / 3 grinding / 1 to serialize —
   no fixed constant).
3. `orchestrator.dispatch_batch(repo, run, units, cap, launch_fn=...)`.
   `launch_fn` maps each unit's `invokes.adapter_op` to the skill it
   launches: `do_unit` → `/ce-work <unit-id>` (the default — `a1`/`w`/
   `pipeline`); `review` → `/ce-code-review` (the `review.json`
   off-spine unit, U11). `dispatch_batch` never consults the adapter, so
   THIS mapping is the driver's job — see `driver-reference.md` §7.
   Each agent self-writes its verdict via `ledger.record_verdict` —
   durable independent of this session.
4. YIELD silently — end the turn. Do NOT ScheduleWakeup.
5. On re-invocation: `orchestrator.converge(repo, run)` reads landed
   verdicts. Predicate met → exit (§5); ready_units → next wave;
   work in flight → yield again.
6. Ticks apply fixes (`verdict-returned → fixed → pending`); re-
   dispatch; re-review. Loop terminates only when every unit reaches
   a clean terminal verdict.

Full mechanism + the "when ScheduleWakeup IS right" long-tail
fallback: `driver-reference.md` §7.

### 4.5 Blocked on a human/external action — PAUSE, do not yield

YIELD is for work **you set in motion that will signal back** (a
background `Agent`, a timed external wait). It is NOT for a wall only a
human can clear — auth login, an approval, missing creds. There is no
re-invoke coming, so yielding turn after turn makes zero progress and
lets any other open gate (e.g. an operator-set native `/goal`) keep
re-inviting you into a spam loop.

When you hit such a wall:

1. `bash lib/auto-resume.py pause <run> "<the one thing the human must
   do>"` — flips `driver=manual` so the Stop hook releases (it never
   blocks a manual-driver run) and the run stays resumable.
2. Surface **one** line: the exact action + `/auto-resume continue
   <run>` to resume. If you (or the operator) set a native `/goal`,
   say so — it must be cleared with `/goal clear`; auto cannot.
3. **Stop.** Do not re-arm, do not yield again.

### 4.6 Advisor gate — a denied AskUserQuestion (v0.6.0)

While a self-driven run owns this session, a PreToolUse hook
(`lib/on-pretooluse-askuser.py`) **denies** any `AskUserQuestion` you fire
and redirects you here. Do NOT stop to ask the operator. Instead:

1. **Consult the `advisor` tool** with the question's context. It returns
   free-form PROSE advice (not a verdict — `docs/research/advisor-contract-spike.md`);
   the advice is an INPUT to your judgment, not an oracle.
2. **Classify the question yourself** using that advice:
   - **Mechanical clarification** (which file, formatting, an unambiguous
     default) → **resolve autonomously** and proceed.
   - **Substantive design/architecture fork** (which architecture, "is this
     scope right?", a premise/positioning call) → **escalate via the pause
     seam** (§4.5): `bash lib/auto-resume.py pause <run> "<the fork>"`, one
     line, then **stop** — not a yield. This composes with §4.5: pause is the
     ONLY sanctioned human-wall stop.
   - **When unsure between the two, treat it as a fork and escalate** — the
     default for substantive choices is escalate, not auto-resolve.
3. **Audit every cycle.** Append a record via
   `ledger.append_advisor_audit(repo, run, kind="advisor", subject="<the
   question>", classification="<mechanical|design-fork>", resolution="<resolved-
   autonomously|escalated-via-pause>")`. The destructive-action backstop
   (`lib/on-pretooluse-action.py`, §4.5 wall) appends its own `kind="action"`
   record when it pauses the run. Both go through the LOCKED atomic-write
   chokepoint, so concurrent fan-out denials cannot clobber the list. Surface
   the audit list in the exit report next to the P3 findings (§5).

This gate composes with §1: the deterministic Stop-hook predicate stays the
single source of truth — the advisor gate only routes *clarifications*, never
re-derives the exit predicate. The gate fires ONLY for THIS driving session
(matched by `driving_session_id`, recorded at arm time); a concurrent
standalone ce-skill in the same worktree is never intercepted.

**Two-seam split — fan-out units (KTD-5).** Work-loop `do_unit` agents get
their OWN `session_id`, so NEITHER PreToolUse hook (question gate OR
destructive backstop) can reach them. When you construct a fan-out unit prompt
(§4 step 3), bake in BOTH constraints:
  - **(i) question routing:** "Do not call `AskUserQuestion`. For a mechanical
    clarification, consult the advisor and resolve it yourself; for a
    substantive design/architecture fork, pause-escalate via
    `auto-resume.py pause <run> \"<the fork>\"` — do not stop to ask the
    operator directly."
  - **(ii) destructive-action avoidance:** "Do not run irreversible/destructive
    operations (the CLAUDE.md-anchored set: `push --force`/`-f`/`--force-with-lease`
    in ANY flag position, `reset --hard`, `checkout .` / `restore .`,
    `clean -f`/`-fdx`, `branch -D`, `rm -rf`, `npm publish`, `gh release create`,
    `gh repo delete`, `gh release delete`, `gh pr merge --admin`). If one is
    needed, pause-escalate instead." `do_unit` is the MOST likely locus of
    destructive Bash (branch cleanup, file delete, force-push), and the action
    hook cannot gate it — so the constraint MUST ride in the prompt.

### 4.7 Gate advisor-judging — typed verification (v0.7.0, U5)

A recipe gate unit may carry a typed `verification` block (kinds
`programmatic` / `model_judge` / `advisor_judge` / `human` — see
`docs/contracts/recipe-format.md` and
`skills/auto-design/references/verification-taxonomy.md`). At convergence,
resolve such a gate via `lib/iteration.py::resolve_gate_verification`, which runs
the `programmatic` criteria in-process and returns a `{signal, pending_judges}`.

When `pending_judges` is non-empty and contains an `advisor_judge` criterion,
the DRIVER (this session — not the fan-out `do_unit` agent) renders it, reusing
the §4.6 pattern:

1. **Consult the `advisor`** with the deliverable + the criterion's `rubric_ref`
   in context. It returns PROSE, not a verdict (`advisor-contract-spike.md`).
2. **Map the prose to a per-criterion `pass`/`fail`** yourself — the advice is an
   input to your judgment, exactly as in §4.6.
3. **Re-resolve** by calling `resolve_gate_verification(... judge_verdicts={...})`
   with the verdicts you rendered (a `human` criterion routes through the §4.5
   pause seam instead). When no judges remain pending the call yields a
   non-None `signal`.
4. **Commit** the signal as the gate's decision via
   `ledger_mutators.set_verdict_decision(repo, run, gate_unit_id, signal)` — the
   single, centralized decision write. A `None` signal means judges are still
   pending (`pending_judges` non-empty): commit nothing, audit nothing.
5. **Audit — only when a judge verdict resolved the gate.** When the resolved
   gate carries a judge-type criterion (`advisor_judge` / `model_judge` /
   `human`) — i.e. the signal is non-None, so `pending_judges` is empty and every
   judge criterion contributed a verdict — log one record per judge criterion via
   `ledger.append_advisor_audit(repo, run, kind="advisor",
   subject="<gate_unit_id>: <criterion id>",
   classification="<the criterion's `type`>", resolution="<advance|iterate>")`,
   surfaced in the exit report (§5). A **programmatic-only** gate (no judge
   criterion) commits the signal in step 4 with **no** audit record — no judge
   weighed in. `kind` stays `"advisor"` for every judge type: the audit `kind`
   enum is intentionally coarse (only `"advisor"`/`"action"` exist), so judge
   audits reuse `"advisor"` and `classification` carries the specific judge
   `type`. `subject` is required non-empty.

No model registry, no CLI shell-out, no cross-vendor egress — `advisor` is the
whole cross-model surface (R10). This composes with §1: the deterministic exit
predicate stays the single source of truth; the gate signal only steers
advance/iterate, never the run's done-state. The decision math lives in
`lib/verification.py::aggregate` (pure → unit-tested with injected verdicts);
only this live `advisor` consultation is integration-only (the bash+Python test
harness cannot stub the `advisor` tool).

## 5. Exit

Loop exits when tick returns `stop` with `predicate-met` reason and
ledger shows `loop_phase == "done"`. Read `exit_predicate_result.met`
from the ledger; never re-derive. Tick supplies a `report` in its
stop intent; surface it (lists remaining minor findings for operator
promotion). If `exit_reason` is non-null the loop did NOT exit
cleanly — surface kind + error. Full taxonomy:
`driver-reference.md` §8.

**Surface the advisor/action audit (v0.6.0).** Alongside the P3 findings,
list the ledger's `advisor_audit` records — every advisor-resolved question
(`kind=advisor`) AND every destructive-action backstop denial (`kind=action`),
each with its `subject` / `classification` / `resolution` / `at`. A wrong
autonomous call or a fired backstop must be diagnosable at exit (KTD-5
visibility — trust is earned by surfacing the gate's decisions, not hiding
them).

## 6. Multi-plan batches (v0.4.0)

A committed sidecar at `<shared-dir>/batches/<id>.json` carries the
composite goal; `lib/on-stop.py` blocks Stop until every sub-run's
predicate is met (provisional sidecars ignored). Mechanism:
`driver-reference.md` §9.

## Invariants

- **Read, never re-derive.** `exit_predicate_result.met` /
  `all_units_terminal` come straight from the ledger.
- **Re-arm only on `action == "rearm"`.** `stop` and `noop` end the
  chain.
- **Driver owns cap; engine owns advance.** Never hardcode
  concurrency; never dispatch from the tick; never write verdicts
  from the driver.
- **Always goaled.** No run proceeds without an active deliberate-stop
  goal/status.
