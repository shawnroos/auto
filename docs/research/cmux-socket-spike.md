# U1 Spike: Can an in-cmux process spawn a fresh terminal running a prompt?

**Date:** 2026-05-22
**Unit:** U1 (feasibility spike for U8 auto-resume)
**Verdict:** **GO**

## Question

Can a process started inside a cmux terminal drive the cmux control socket to
spawn a fresh terminal running a given prompt? If yes, `claude-dispatch` can
auto-resume a loop after a full session exit by spawning a `/dispatch-resume`
terminal (unit U8).

## Answer

Yes. The cmux CLI talks to a local Unix socket and exposes `new-workspace`
(RPC `workspace.create`) with a `--command <text>` flag that "Send[s] text+Enter
to the new workspace after creation." An in-cmux process is authorized to call
it (`access_mode: cmuxOnly`, satisfied because the calling process inherits the
cmux env), and the spawned workspace is owned by the cmux app, so it survives
the parent Claude session exiting — exactly the U8 use case.

## Socket API surface (verified on disk / live)

- **Binary:** `/Applications/cmux.app/Contents/Resources/bin/cmux` (in `$PATH`)
- **Socket:** `$CMUX_SOCKET_PATH` = `/Users/shawnroos/Library/Application Support/cmux/cmux.sock`
- **Access mode:** `cmux capabilities` → `"access_mode": "cmuxOnly"`. The calling
  process is allowed because cmux env vars (`CMUX_BUNDLE_ID`, `CMUX_WORKSPACE_ID`,
  `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH`, etc.) are inherited from the cmux-launched
  shell. `cmux ping` from this process returned `PONG`.
- **Docs:** `cmux docs api` (web: https://cmux.com/docs/api; raw CLI contract:
  `https://raw.githubusercontent.com/manaflow-ai/cmux/main/docs/cli-contract.md`)

### Relevant spawn/control commands (from `cmux --help`)

| CLI command | RPC method | Purpose |
|---|---|---|
| `new-workspace [--name] [--cwd] [--command <text>] [--focus <bool>] [--layout <json>] [--window]` | `workspace.create` | Create a workspace (a tab) and run a command in it |
| `new-window` | `window.create` | New top-level window |
| `new-pane [--type] [--direction] [--url] [--focus]` | `pane.create` | Split a new pane in current workspace |
| `new-surface [--type terminal\|browser] [--pane] [--url] [--focus]` | `surface.create` | New surface (terminal/browser) in a pane |
| `send [--workspace] [--surface] <text>` | `surface.send_text` | Type text into an existing surface |
| `send-key [--workspace] [--surface] <key>` | `surface.send_key` | Send a keystroke (e.g. `enter`) |
| `read-screen [--workspace] [--surface] [--scrollback] [--lines]` | `surface.read_text` | Read terminal output (used to verify) |
| `close-workspace --workspace <id|ref>` | `workspace.close` | Tear down (cleanup) |
| `list-workspaces` | `workspace.list` | Enumerate |

`--layout <json>` also accepts the cmux.json split schema, where each surface can
carry its own `command` — useful if U8 ever needs a multi-pane resume layout.

## Exact command for U8

```sh
cmux new-workspace \
  --name "dispatch-resume" \
  --cwd "<repo path>" \
  --command "sleep 1; claude '/dispatch-resume <args>'" \
  --focus false
```

- `--focus false` keeps Shawn's current pane/layout undisturbed (verified: the
  spawn did not steal focus from the originating workspace).
- Note the `--command` value runs in a fresh login shell, so any wrapping
  needed for the `claude` invocation (the cmux `claude` wrapper at
  `/Applications/cmux.app/Contents/Resources/bin/claude`) is on `$PATH` already.

### Timing caveat (load-bearing — must encode in U8)

`--command` sends `text + Enter` to the new surface immediately after creation.
If the shell is still running its login/init (`Last login...`, prompt theme,
node/version managers) the keystrokes can be **consumed by shell startup and
lost**. In testing, a bare `echo OK > file; exit` sent at creation time was
swallowed (the `exit` even raced ahead and closed the workspace before the
redirect flushed). Prefixing the command with a small `sleep 1;` lead-in let the
shell settle and the command ran reliably (flag file written, confirmed via
`read-screen`). U8 must include this lead-in (or poll `read-screen` for a ready
prompt before `send`-ing) rather than relying on instant `--command` delivery.

## Proof performed (safe, throwaway, cleaned up)

1. `cmux ping` → `PONG` (socket reachable from this in-cmux process).
2. `cmux capabilities` → confirmed `workspace.create`, `surface.send_text`, etc.
   and `access_mode: cmuxOnly`.
3. Spawned `workspace:12` with
   `--command "sleep 1; echo OK > /tmp/u1-spike-clean.flag" --focus false`.
4. Verified `/tmp/u1-spike-clean.flag` contained `OK`, and `read-screen` showed
   the command at a fully-initialized prompt.
5. Confirmed the spawned workspace was app-owned: it persisted in
   `list-workspaces` after the spawning bash command had already returned. (A
   prior throwaway with a trailing `exit` self-closed once its shell exited,
   demonstrating workspace lifetime is tied to its own shell, not the caller.)
6. Cleaned up: `cmux close-workspace --workspace workspace:12`, removed flag
   files, restored focus to Shawn's original `workspace:3`. No layout/panes of
   Shawn's were modified.

## Verdict

**GO** for U8. The mechanism is documented, the socket is reachable from an
in-cmux process, the spawned terminal is app-owned (survives parent exit), and
`--focus false` avoids disrupting the user. Build U8 on
`cmux new-workspace --command` with a `sleep`/ready-poll lead-in to dodge the
shell-startup keystroke race.
