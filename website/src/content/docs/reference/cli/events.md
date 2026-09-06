---
title: Subscriptions & Events
description: Subscribe to real-time OmniWM state changes and run a command per event with watch.
sidebar:
  order: 6
---

Subscribe to real-time state change events from OmniWM.

## Delivery Pipeline

`IPCServer.start()` attaches `IPCApplicationBridge` to `WMController`. Controller state changes publish channel snapshots through the bridge, and `IPCConnection` expands the requested channels for each client, sends the initial `subscribe` response, starts per-channel stream tasks, and emits initial snapshots unless `--no-send-initial` is set.

Initial snapshots are best-effort seed state, not a strict ordering barrier. If state changes during subscription setup, a live update can race with the initial snapshot.

Subscription channels are coalesced state streams, not a lossless event log. Slow consumers may only observe the newest buffered update for a channel.

Workspace-bar and IPC projection work is only produced when the UI or IPC currently has active consumers;
core window relayout is not consumer-gated.

## Channels

| Channel | Result Type | Description |
|---------|-------------|-------------|
| `focus` | focused-window | Focused window snapshot updates |
| `workspace-bar` | workspace-bar | Workspace bar projection updates; each app pill carries `id`, `appName`, `bundleId` (omitted when unknown), `isFocused`, `windowCount`, and `allWindows` |
| `active-workspace` | active-workspace | Interaction monitor and active workspace updates |
| `focused-monitor` | focused-monitor | Focused monitor updates |
| `windows-changed` | windows | Managed window inventory updates |
| `display-changed` | displays | Full display snapshot after any adopted display add, remove, or reconfigure, after a gap-setting change, or when the interaction monitor changes; identical consecutive snapshots are not repeated |
| `layout-changed` | workspaces | Workspace layout updates |

## subscribe

Stream the subscribe response and subsequent events to stdout as JSON.

```
omniwmctl subscribe <channels> [--no-send-initial] [--reconnect] [--format json|ndjson]
omniwmctl subscribe --all [--no-send-initial] [--reconnect] [--format json|ndjson]
```

Channels are specified as a comma-separated list or with `--all` for all channels.

| Flag | Description |
|------|-------------|
| `--all` | Subscribe to all channels |
| `--no-send-initial` | Skip sending initial state snapshot |
| `--reconnect` | Reconnect and resubscribe after the connection to OmniWM is lost (see below) |
| `--format json\|ndjson` | `json` (default) pretty-prints every envelope; `ndjson` writes one compact envelope per line. `table`, `tsv`, and `text` are rejected for subscriptions |

Stdout begins with a single `IPCResponse` envelope with `kind: "subscribe"` and `status: "subscribed"`. After that, OmniWM emits a best-effort initial state snapshot for each subscribed channel unless `--no-send-initial` is used, followed by live `IPCEventEnvelope` updates as they occur. With `--format ndjson` every envelope, including the first response, is exactly one line, which is the shape `watch --exec` children already receive.

When OmniWM closes the connection, for example because it quit or relaunched, `subscribe` exits with code 2 (`transportFailure`), the same as `watch`.

### Reconnecting

With `--reconnect`, `subscribe` and `watch` survive an OmniWM relaunch. After the first successful subscribe handshake, a lost connection is reported on stderr and the client retries with a delay that starts at 0.5 s and doubles up to 5 s until OmniWM accepts the connection again. Every resubscribe requests initial snapshots, even with `--no-send-initial`, so the client catches up on the state it missed; the resynchronization is marked by `omniwmctl: reconnected` on stderr. Only the first handshake response is printed. A handshake that OmniWM rejects (for example `unauthorized` or `protocol_mismatch`) ends the stream with exit code 1, a failed initial connection exits 2 without retrying, and one-shot commands never retry.

**Examples:**

```bash
# Watch focus changes
omniwmctl subscribe focus

# Keep streaming across OmniWM relaunches, one JSON line per event
omniwmctl subscribe --all --reconnect --format ndjson

# Watch all events
omniwmctl subscribe --all

# Watch workspace and window changes without initial state
omniwmctl subscribe active-workspace,windows-changed --no-send-initial
```

## watch

Subscribe to events and execute a command for each event received. The event data is passed to the child process on stdin.

```
omniwmctl watch <channels> [--no-send-initial] [--reconnect] --exec <command> [args...]
omniwmctl watch --all [--no-send-initial] [--reconnect] --exec <command> [args...]
```

The `--exec` flag is required and marks the boundary between watch flags and the child command. Everything after `--exec` is the child command and its arguments.

`watch` consumes the subscribe handshake client-side instead of printing it. It runs one child process per event, waits for that child to finish before handling the next event, writes exactly one NDJSON event line to the child's stdin, and reports non-zero child exits to stderr without terminating the watcher. `--reconnect` behaves exactly as for `subscribe`; a `--reconnect` placed after `--exec` belongs to the child command.

**Environment variables passed to child process:**

| Variable | Description |
|----------|-------------|
| `OMNIWM_EVENT_CHANNEL` | Subscription channel name (e.g., `focus`) |
| `OMNIWM_EVENT_KIND` | Event result kind |
| `OMNIWM_EVENT_ID` | Event ID |

The child process inherits the parent's stdout, stderr, and environment. Bare executable names are resolved through `PATH`; use an absolute executable path when you want a fixed command target. The event JSON is written to the child's stdin.

If you persist event streams, prefer a per-user directory such as `~/Library/Logs/OmniWM/` and restrictive permissions such as `umask 077`.

**Examples:**

```bash
# Log focus changes to a file
mkdir -p ~/Library/Logs/OmniWM
umask 077 && omniwmctl watch focus --exec tee -a ~/Library/Logs/OmniWM/focus.ndjson

# Run a script on workspace changes
omniwmctl watch active-workspace --exec ./on-workspace-change.sh

# Process all events with jq
omniwmctl watch --all --exec jq '.result'

# Badge workspaces whose window titles match a pattern
omniwmctl watch workspace-bar --reconnect --exec ./badge.sh
```

### Badging workspaces from events

`badge.sh` prefixes 🚨 to the label of any workspace holding a window whose title matches `PATTERN` and strips the prefix otherwise. It reads one `workspace-bar` envelope on stdin and calls `omniwmctl workspace rename` only for labels that differ from the computed state:

```bash
#!/bin/bash
export PATH="/opt/homebrew/bin:$PATH"
pattern="${PATTERN:-incoming call}"
jq -j --arg re "$pattern" '
  .result.payload.monitors[]?.workspaces[]?
  | .rawName as $raw
  | (.displayName | sub("^🚨 "; "")) as $base
  | (any(.windows[]?.allWindows[]?.title; test($re; "i"))) as $hit
  | (if $hit then "🚨 " + $base elif $base == $raw then "" else $base end) as $want
  | select($want != .displayName and ($want != "" or .displayName != $raw))
  | ([0] | implode) as $nul
  | $raw + $nul + $want + $nul
' | while IFS= read -r -d '' raw && IFS= read -r -d '' want; do
  omniwmctl workspace rename "$raw" "$want"
done
```

Address workspaces by raw ID: a badged label changes what `focus-name` matches. Rename activity stops once labels match the computed state, because the script renames only on a difference and OmniWM publishes `workspace-bar` only when the bar changed; how many times the script runs per change is not guaranteed. `watch` logs a non-zero child exit and keeps running, so a no-op rename (exit 1, `no_change`) is harmless. With `hideEmptyWorkspaces` enabled, an emptied workspace leaves the snapshot, so its badge is cleared the next time it appears. Fields are NUL-framed, so labels containing backslashes, tabs, or spaces survive unchanged.
