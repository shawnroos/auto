# Spinoff: /auto entry-routing priors — match real usage

> This handoff is directional — author intent and a starting point, enough to orient and begin, not a spec to execute literally. The code and tests are the source of truth: validate against them and expect to refine.

> **Directional handoff.** The agent report below is high-signal; treat its 6 issues +
> 4 changes as the spine, but validate each against the current `auto-detect.sh` /
> `auto-driver` code before building — some may already be partly addressed.

## Goal
Fix `/auto`'s deterministic entry-routing so its priors match how it's actually used.
The mechanics are sound; the precedence/heuristics are wrong: instruction-style args, a
freshly-built plan, and a cluttered `docs/plans/` all pointed one way while routing went
another. An expert agent had to override the router on every entry.

## Why now / context
Field report from an agent driving `/auto` (v0.6.7) to build + ship a feature. Routing
"worked out" only because the agent overrode it each time. This **reinforces**
(already folded into) memory `auto_should_be_context_aware_smart_entry` — carries
forward, not brand-new.

## The 6 issues (verbatim-faithful)
1. **Freeform/argument rule misroutes imperatives to `/ce-plan`.** Both entries carried
   NL instructions ("develop and implement a plan…", "execute, code-review and verify
   the plan, then open a PR"). Neither is a literal plan-file path, so the driver does
   `/ce-plan <ARGUMENTS>` and ends — wrong both times (#1 wanted plan+implement; #2
   wanted execute, not re-plan a green plan). The rule can't tell "topic to plan" from
   "imperative about existing work." Verbs — execute/implement/review/verify/ship/open
   a PR — are the tell it should key on.
2. **Multi-plan detection is filesystem-blind and outranks live intent.**
   `auto-detect.sh` found 6 plans in `docs/plans/` — 5 stale (Mar/May), 1 co-authored
   to green THIS session. The driver always asks, listing all 6 + a **"Fan out all 6"**
   option — a footgun (6 worktrees on abandoned plans). No recency/git-status ranking,
   no notion of "the plan this conversation is about."
3. **Conversation-context path never fires.** v0.6.0 has a "rich session, act on it"
   branch, but it only triggers if the driver sets `CLAUDE_AUTO_CONVERSATION_SIGNAL`
   before loading the hypothesis — and the multi-plan filesystem result short-circuits
   that. The richest signal (we just designed + adversarially reviewed a plan together)
   lost to stale files. **Precedence is backwards.**
4. **Recipe→capability mapping isn't legible at decision time.** Table says
   reviewed-plan → recipe `w`, but the driver can't tell if `w` opens a PR / runs review
   / verifies — and memory records `a1` exits without a PR. For "execute, review,
   verify, open PR" there was no confident recipe pick, so the agent drove CE skills
   directly. Recipes should advertise capabilities (PRs? review loop? verify gate?).
5. **Single dispatch line is a SPOF.** Everything hinges on one `bash auto.sh …` call;
   when the Bash classifier was momentarily unavailable, the whole entry stalled. No
   graceful fallback. (Env hiccup, not auto's bug — but the design has no resilience.)
6. **Tension: multi-plan ALWAYS asks vs advisor-gate "never ask, infer/advisor."** The
   one place the driver hard-asks is exactly where conversation made the answer obvious.
   Fires in the pre-arm window so it's allowed — but at odds with the stated ethos.

## What to change (the agent's recommendations)
- **Promote conversation-context above the filesystem scan.** A plan created/edited this
  session, or a clear imperative referencing existing work, beats a `docs/plans/` glob.
- **Teach the freeform rule to read verbs.** Imperative + existing plan → route to
  WORK, not `/ce-plan`.
- **Rank multi-plan by recency/git-status**, mark stale/merged plans, suppress "fan out
  all" when most are stale.
- **Make recipe capabilities self-describing** so the right recipe is pickable for a
  multi-step ask.

## Open questions / design forks
- Precedence model: exact ordering of (live-session plan) > (imperative+existing) >
  (single fresh plan) > (multi-plan ask). Where does `CLAUDE_AUTO_CONVERSATION_SIGNAL`
  get set, and how to stop the filesystem branch short-circuiting it?
- Verb taxonomy for the freeform rule — which verbs mean "work on existing" vs "plan
  new"? Edge cases ("plan and implement" wants BOTH).
- Recency/git-status ranking signal — mtime? git log? a `status:` field in plan
  frontmatter? How to detect "the plan this conversation is about."
- Recipe-capability schema — where declared (recipe table / frontmatter) and how the
  driver surfaces it (PRs/review/verify flags).
- Dispatch resilience (#5) — fallback when the one bash line can't run.

## Starting point (concrete)
- Repo `~/projects/auto`. **Branch from `origin/main` (`82ce19c`)** — local `main`
  (`280329e`) is 1 behind.
- `lib/auto-detect.sh` — the hypothesis builder + multi-plan scan +
  `CLAUDE_AUTO_CONVERSATION_SIGNAL` (issues #1/#2/#3).
- `skills/auto-driver/SKILL.md` — the freeform rule, multi-plan ask, recipe table,
  precedence (issues #1/#2/#4/#6).
- `lib/auto.sh` / `lib/auto-spawn.py` — the single dispatch line (issue #5).
- **Heavy worktree overlap — check before building:** `feature/auto-conversation-entry`
  (the ORIGINAL v0.6.0 conversation-entry dev branch — likely already shipped into main;
  read it to see what the conversation-context branch was meant to do), plus in-flight
  `feature/auto-drive-fixes` (backstop/CLI — touches entry) and `feature/loop-planning-opt`.
  All touch the entry surface; coordinate landing order to avoid `auto-detect.sh` /
  driver collisions.
- Memory: `auto_should_be_context_aware_smart_entry` (already updated with this),
  `auto_dx7_algorithm_picker` (recipes), `native_goal_is_model_judged...`.

## Recommended next step
`/ce-plan` — the agent's 4 changes are a ready plan spine; the open work is the
precedence model + verb taxonomy + recipe-capability schema. Phase 0 should diff the
current `auto-detect.sh`/driver against the 6 issues (some may be partly fixed since the
report) AND read `auto-conversation-entry` to avoid re-deriving the conversation branch.
Then `/ce-code-review` (auto's backstop/bash history). Validate against the code first.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
