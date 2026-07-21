---
title: "bug: the Stop hook treats rules.json as a run-record and blocks stop forever"
created: 2026-07-21
type: bug
severity: high
status: diagnosed — fix proposed, not yet applied
affects: auto ≥ the version that shipped `.claude/auto/rules.json` (confirmed live on
  local main v0.12.0 `10529ba` and cache v0.14.0 — same glob)
found: a plain Claude session running from ~ that never started an auto run
---

# The Stop hook blocks on `rules.json`

## Symptom

Every attempt to end a turn is blocked by:

```
auto: loop exit condition not met — rules (steps not yet terminal)
```

…in a session that **never started an auto run**. There is no run to resume, no
`/auto-resume abort <run>` target that makes sense (the "run" is called `rules`),
and the block never clears. It fires from any session whose cwd is under `~`.

## Root cause

`iter_worktree_run_records` (`lib/_bootstrap.py`, the `*.json` glob) enumerates
run-records as **every parseable JSON dict** under `<repo>/.claude/auto/`:

```python
for path in sorted(glob.glob(os.path.join(dispatch_dir, "*.json"))):
    led = load_run_record_safe(path)
    if led is None:
        continue
    ...
    yield run_id, led
```

`.claude/auto/rules.json` — auto's **own** persona-rules config — lives in that
same directory. It is a config file, not a run-record, but it is a valid JSON dict,
so it survives `load_run_record_safe` and gets yielded as a run whose `run_id` is
the filename stem, `"rules"`.

The Stop guard (`lib/on-stop.py` → `_is_blocking`) then evaluates it as a run:

- `phase_grammar.current_phase(rules.json)` → **`"plan"`** — there is no
  `loop_phase` field, so it falls to the default first phase, which is not `"done"`.
- No `loop` key → neither the `driver == "manual"` carve-out nor the
  `driver == "self"` staleness carve-out applies.
- No `exit_predicate_result` → `predicate.get("met")` is falsy.

So `_is_blocking` returns a (empty) predicate → **blocked, forever.**

### Proven by execution

Running the real glob against `~` yields exactly one "record", and it is the config:

```
run_id='rules'  phase='plan'  met=None  keys=['format', 'rules']
```

That is the whole bug: a config file shaped enough like a run-record to be swept
up, and empty enough to look permanently unfinished.

## Why it triggers from anywhere under `~`

The Stop hook presence-gates by walking up from cwd for `<repo>/.claude/auto`. Home
is not a git repo, so `repo_root` resolves to `~`, and `~/.claude/auto/` exists (it
holds `rules.json`, `recipes/`, and stale lockfiles). So **any** session started
under `~` — not just an auto-driven one — walks up, finds `~/.claude/auto/`, sweeps
`rules.json`, and blocks. The blocking is a function of *where the session runs*,
not of any run existing.

## The fix — the shape, not the filename

Don't special-case `rules.json` by name; other non-run-record files can land in
`.claude/auto/` later (`recipes/` already does, as a dir). Make
`iter_worktree_run_records` require a **run-record shape** and skip anything that
isn't one — e.g. skip a loaded dict that has none of `loop` / `loop_phase` /
`run_id` (a real run-record always carries the loop/phase machinery; a config never
does). That fixes the class:

```python
led = load_run_record_safe(path)
if led is None:
    continue
if not ({"loop", "loop_phase", "run_id"} & led.keys()):
    continue  # config/sidecar that isn't a run-record (e.g. rules.json)
```

`iter_worktree_run_records` is the shared enumerator, so fixing it here also fixes
every other consumer that trusted it (`on-stop.py`, `auto-status.py`,
`auto-resume.py`, `on-pretooluse-action.py`, `launch-mode.py`) — none of which
should ever have seen `rules.json` as a run either. Add a test fixture: a
`.claude/auto/` containing only a `rules.json` must yield **zero** runs and must
**not** block stop. See it fail once against the current glob first.

## Interim workaround (ugly — prefer the code fix)

There is no clean keep-the-rule-and-stop-the-block option without the code change:

- Moving/renaming `rules.json` out of `.claude/auto/` stops the false block, but
  auto **reads its rules from that same path**, so it also disables the live rule
  (`honest`, which excludes the `team-review` workflow for `slate-devs`).
- The `driver == "self"` staleness carve-out doesn't apply — `rules.json` has no
  `loop`, so it never looks like a stale chain, only like a fresh unfinished one.

So the honest move is the code fix, not a workaround.

## Blast radius

Anyone who has `~/.claude/auto/rules.json` and runs a Claude session from under `~`
gets Stop blocked on every turn with no real run in flight. It's cosmetic in that
work still proceeds, but it defeats the deliberate-stop guard's whole purpose
(signal a real unmet predicate) by crying wolf on a config file — and it trained at
least one session to misread it as a phantom before it was run to ground.
