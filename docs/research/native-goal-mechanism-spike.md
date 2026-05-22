# U9 Spike: How does native `/goal` register/evaluate its Stop hook, and can an external engine feed it a predicate?

**Date:** 2026-05-22
**Unit:** U9 (investigation that decides U7 — whether auto ships a Stop hook)
**Verdict:** `/goal` is **model-evaluated, not file-evaluated**. An external engine **cannot** feed `/goal` a predicate result via a status file or queryable state. U7 should therefore **not** try to drive `/goal`. auto should ship its **own thin Stop hook** for un-goaled loops; that hook reads engine-written state, and `goal-status.sh` writes that state for *auto's* hook (not for native `/goal`).

## Question

Does native `/goal` register a Stop hook we can interoperate with, and can an external engine make `/goal` block "stop" until the engine's loop is done by writing a predicate result somewhere `/goal` reads? This decides whether auto ships any Stop hook of its own (U7).

## Method

The binary is minified, so the mechanism was read from extracted string/code fragments rather than statically decompiled.

- **Binary path (corrected):** `~/.local/share/claude/versions/2.1.148` is itself the Mach-O arm64 executable (212 MB). The orchestrator brief's path had a trailing `/claude` that does **not** exist — `2.1.148` is a file, not a directory. `file` confirms `Mach-O 64-bit executable arm64`. (`claude` on `$PATH` resolves to `/Applications/cmux.app/Contents/Resources/bin/claude`, a launcher.)
- Extraction recipe that worked: `LC_ALL=C grep -ao '<pattern>' <bin> | LC_ALL=C tr -cd '[:print:]'`. (`strings` reported zero "goal" hits — its default min-length / encoding missed the embedded JS payload; raw `grep -a` found 107 byte-matches.)

## 1. How `/goal` persists state

**It does not persist to a file.** Goal state lives entirely in the **conversation transcript / app state** as an `active_goal` message type, never on disk.

- Searched `~/.claude/settings.json` and `settings.local.json`: the user-level `Stop` hook contains only the SUPERSET notify shim and the cmux `handler.cjs` — **no goal-related Stop hook**. Native `/goal` registers its continuation gate *programmatically inside the binary*, not through settings.json.
- Searched `~/.claude/{state,modes,jobs,tasks,todos,sessions}`: no goal state file anywhere. (`~/.claude/tasks/<uuid>/` holds background-agent TODO snapshots — `.highwatermark`, `.lock`, `N.json` — unrelated to `/goal`.)
- `active_goal` is a first-class transcript message type (alongside `user`/`assistant`/`system`/`tool_use`/`post_turn_summary`). The reducer keeps it in app state:
  ```js
  case "active_goal": this.config.setAppState(vH => vH.activeGoal===MH.value ? vH : {...vH, activeGoal:MH.value}); break;
  ```
  and on the streaming side `if(D.type==="active_goal"){ ... f.activeGoal===D.value?f:{...f,activeGoal:D.value} ...}`.
- Setting a goal injects a meta-message into the conversation rather than writing state: `/goal <condition>` returns `Goal set: ${K}` with `metaMessages:[OX6(K)]` (`OX6` builds the injected prompt). Condition length is capped: `Goal condition is limited to ${wsH} characters`.

## 2. What `/goal`'s Stop hook evaluates

**The model judges its own goal.** The verdict is produced by the model during a continuation loop, not by reading any external signal. The decisive code fragment (the goal continuation gate):

```js
// when the agent tries to stop, with an active goal Q whose condition matches the goal prompt U:
if (U && Q?.condition === U.prompt)
    yield {type:"active_goal", value:{...Q, iterations: Q.iterations+1, lastReason: p.stopReason}},
    yield W9({type:"goal_status", met:!1, condition:U.prompt, reason:p.stopReason});   // not met -> loop continues
else
    u.push(p.blockingError.blockingError);

if (p.preventContinuation)                              // separate, independent gate (user Stop hooks)
    I=!0, C = p.stopReason || "Stop hook prevented continuation",
    yield W9({type:"hook_stopped_continuation", message:C, hookName:"Stop", toolUseID:E, hookEvent:"Stop"});
```

The terminal verdict is also model-driven:

```js
if (p.impossible)
    yield W9({type:"goal_status", met:!1, failed:!0, condition:U.prompt, reason:p.stopReason, iterations:l, durationMs:d, tokens:i}),
    c("tengu_goal_failed", {...}), mH("goal_met", "impossible");
else
    yield W9({type:"goal_status", met:!0, condition:U.prompt, reason:p.stopReason, ...});
```

The `goal_status` payload carries `met`, `failed`, `condition`, `reason`, `iterations`, `tokens`, `durationMs`, `sentinel` and drives the UI: `met:!0` → "Goal achieved"; `failed` → "Goal could not be achieved"; otherwise → "Goal not yet met… continuing".

So the answer to "(a) re-ask the model / (b) read engine-written state / (c) other" is **(a)**: the engine intercepts the agent's stop, re-injects the goal condition (`active_goal` with incremented `iterations`), and the **model** decides `met`/`impossible`. There is no file or queryable predicate consulted. The blocking message a user sees (e.g. "review and fix phases incomplete") is the **model's** stop-reason, not an external check.

**Corroborating strings (all from the 2.1.148 binary):** `goal_set`, `goal_met`, `goal_status`, `active_goal`/`activeGoal`/`onActiveGoal`, `tengu_goal_achieved`, `tengu_goal_failed`, `Goal active`, `Goal achieved`, `Goal could not be achieved`, `Goal not yet met… continuing`, `No goal set. Usage: \`/goal <condition>\``, `/goal clear to stop early`, `Goal cleared:`, `/goal can't run while hooks are disabled (disableAllHooks or allowManagedHooksOnly ...)`, `/goal is only available in trusted workspaces.`

Note: `/goal` requires hooks to be *enabled* to run, but that is because it operates **as** the binary's internal Stop/continuation machinery — not because it reads a user hook in settings.json.

## 3. Can an external engine feed `/goal` a predicate?

**No — not via state.** `/goal` consults only the model's judgement; there is no file, env var, or socket predicate it reads. That option is closed.

**Partial caveat (injection, not predicate):** the binary has a `goalNonInteractive` code path clustered with `stopHandler`, `spawnBgSession`, `withStdinPositional`, `respawnHandler` — i.e. a goal *can* be set programmatically in a headless/background session. So an engine could **inject the goal condition** at session start, but it still cannot supply the *verdict*; the model evaluates the injected condition. An engine that wants its loop status to be authoritative cannot express that through `/goal`.

## 4. U7 recommendation

1. **Do not build U7 on top of native `/goal`.** `/goal` is a closed, model-judged continuation loop with no external predicate input. There is no interop seam: auto cannot make `/goal` block until *auto's* loop is done.
2. **Ship a thin auto Stop hook** (settings.json `Stop` entry or plugin hook) for **un-goaled runs**. It is the binary's `p.preventContinuation` path (exit code 2 / `decision:"block"`), which the code shows is **independent** of the native goal loop — both gates coexist, so an auto Stop hook composes cleanly with `/goal` if a user also sets one.
3. **The hook reads engine-written state**, and **`goal-status.sh` is needed** — but its consumer is **auto's own Stop hook, not native `/goal`**. Recommended shape:
   - `goal-status.sh` writes a small JSON status file the auto Stop hook reads, e.g. `~/.claude/state/auto/<session-id>.json` (or under the auto run dir):
     ```json
     { "active": true, "loop": "review-fix", "done": false, "reason": "P1 findings remain", "iterations": 3 }
     ```
   - Auto Stop hook logic: if no status file or `active:false` → allow stop (exit 0). If `active:true && done:false` → block (exit 2) and surface `reason` to the agent. If `done:true` → allow stop. This mirrors the native shape (`met`/`reason`/`iterations`) so behavior is familiar, but the verdict is **deterministic and engine-owned** rather than model-judged — consistent with Shawn's "deterministic over probabilistic for load-bearing infrastructure" preference.
4. **When the user sets a native `/goal`,** auto's hook should defer (allow stop / no-op) and let the native loop own continuation, to avoid double-blocking. The two gates are independent, so the auto hook only needs to gate when its own status file says `active:true`.

## Confidence & limits

- High confidence on the *mechanism* (model-judged loop, transcript-resident `active_goal`, no on-disk goal state, independent `preventContinuation` gate) — read directly from binary code fragments, not inferred.
- Did not decompile `OX6`'s exact injected prompt text (minified token collides with a base64 blob); not load-bearing — the `goal_status met:true` success branch already proves the verdict is model-produced.
- Did not set a live `/goal` (would interfere with this session); relied on artifact/binary inspection per brief.
