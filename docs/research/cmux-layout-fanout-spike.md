# U1 spike: cmux new-workspace --layout JSON shape

**Date:** 2026-05-28
**Unit:** plan 004 U1 (gated spike — decides U2-U5's dispatch shape)
**Status:** in progress

## Question

Does `cmux new-workspace --layout <json>` reliably create a
declarative split + per-surface commands in one call, and what is
the actual JSON shape it accepts?

## Method

Run-A, Run-B, Run-C scripts under `tests/spike/cmux-layout/`,
invoked against a real cmux daemon. Capture each shape's verdict.


## Run A — layout JSON candidates

**Time:** 2026-05-28T15:30:52Z

Trying 4 candidate JSON shapes against `cmux new-workspace --layout`.

### Shape 1

```json
{"split":"horizontal","ratio":0.5,"left":{"surfaces":[{"command":"echo LEFT-OK"}]},"right":{"surfaces":[{"command":"echo RIGHT-OK"}]}}
```

**Verdict:** FAIL (rc=1)

```
Error: invalid_params: Invalid layout: The data couldn’t be read because it isn’t in the correct format.
```

### Shape 2

```json
{"direction":"horizontal","panes":[{"command":"echo LEFT-OK"},{"command":"echo RIGHT-OK"}]}
```

**Verdict:** FAIL (rc=1)

```
Error: invalid_params: Invalid layout: The data couldn’t be read because it is missing.
```

### Shape 3

```json
{"type":"split","direction":"horizontal","children":[{"type":"surface","command":"echo LEFT-OK"},{"type":"surface","command":"echo RIGHT-OK"}]}
```

**Verdict:** FAIL (rc=1)

```
Error: invalid_params: Invalid layout: The data couldn’t be read because it isn’t in the correct format.
```

### Shape 4

```json
{"surfaces":[{"command":"echo LEFT-OK"},{"command":"echo RIGHT-OK"}]}
```

**Verdict:** FAIL (rc=1)

```
Error: invalid_params: Invalid layout: The data couldn’t be read because it isn’t in the correct format.
```


## OVERALL VERDICT: FAIL

None of the candidate shapes were accepted by cmux. Plan 004
must reshape U2 to use the imperative chain
(new-workspace + new-split + new-surface + send) instead of
declarative layout JSON.

## Conclusion (2026-05-27)

**`--layout` JSON shape is opaque without cmux source access.** Four
plausible candidates rejected; no public schema documents the shape;
cmux's two published schemas (`cmux.schema.json`,
`cmux-settings.schema.json`) declare `commands[]` items as
`additionalProperties: true` (deliberately loose). The error messages
(`The data couldn't be read because it isn't in the correct format`)
suggest a strict Codable type but give no shape hint beyond "missing"
on shape 2 (which lacked the implicit top-level required keys).

**Decision: plan 004 U2 builds on the imperative chain.** Per the
plan's own R1 fallback:

> Fallback if schema is genuinely unspecified: chain imperative
> `new-workspace` + `new-split` + `new-surface` + `send` calls,
> accepting the multi-process timing risk that the layout JSON was
> supposed to eliminate.

The chain is:

1. `cmux new-workspace --name "$name" --cwd "$cwd" --focus true`
2. Capture returned workspace_id; `cmux list-panes --workspace
   "$workspace_id"` → capture the primary pane (right-split target).
3. `cmux new-split right --panel "$primary_pane" --focus false` →
   creates the right pane.
4. Each pane already has one default surface; `cmux send --surface
   "$primary_surface_left" "sleep 1; claude\n"` to start the
   primary claude session in the left pane.
5. Multi-tab fanout uses `cmux new-surface --pane "$left_pane"
   --focus false` then `cmux send --surface "$surface" "sleep 1;
   ... claude '/auto <plan>'\n"`.

The `sleep 1;` lead-in is load-bearing (per cmux-socket.sh's
existing spawn-resume mechanism). Each shell-out is small enough to
chain reliably.

**Future:** if cmux publishes a layout schema (or if the source
shape becomes inferrable), U2 can swap to the declarative form
without changing higher-level units.


## Addendum (2026-05-27, U4 prep)

**The layout JSON schema IS documented — just buried in `--help`.**
`cmux new-workspace --help`'s final example shows the canonical shape:

```json
{
  "direction": "horizontal",
  "split": 0.5,
  "children": [
    {"pane": {"surfaces": [{"type": "terminal", "command": "vim"}]}},
    {"pane": {"surfaces": [{"type": "terminal", "command": "npm run start"}]}}
  ]
}
```

Key differences from my round-1 candidates:
- `split` is a NUMBER (ratio 0.0-1.0), not a string
- `children[]` wraps each pane in `{"pane": {"surfaces": [...]}}` —
  the extra `pane` key was missing in shape 3 and shape 4
- `surfaces[]` items need `type: "terminal"` (or presumably `"browser"`)

**Verified working** against a real cmux daemon:

```bash
cmux new-workspace --name "spike-verify" --layout '...' --focus false
# → OK workspace:17
# tree confirms 2 panes, each with its terminal surface, commands ran
```

**Plan 004 U4 reverts to the declarative path.** This eliminates
the `new-workspace` + `list-panes` + `new-split right` + `send`
imperative chain. One subprocess call creates the full layout.

The marker still has to capture the workspace + pane + surface
IDs after creation — they're not returned by `new-workspace`
(only `OK <workspace-id>` comes back). U4 follows up with
`cmux list-panes` and `cmux list-pane-surfaces` to enumerate
the IDs, then writes the marker atomically.
