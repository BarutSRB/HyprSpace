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
omniwmctl subscribe <channels> [--no-send-initial]
omniwmctl subscribe --all [--no-send-initial]
```

Channels are specified as a comma-separated list or with `--all` for all channels.

| Flag | Description |
|------|-------------|
| `--all` | Subscribe to all channels |
| `--no-send-initial` | Skip sending initial state snapshot |

Output is always JSON. Stdout begins with a single pretty-printed `IPCResponse` envelope with `kind: "subscribe"` and `status: "subscribed"`. After that, OmniWM emits a best-effort initial state snapshot for each subscribed channel unless `--no-send-initial` is used, followed by live `IPCEventEnvelope` updates as they occur.

**Examples:**

```bash
# Watch focus changes
omniwmctl subscribe focus

# Watch all events
omniwmctl subscribe --all

# Watch workspace and window changes without initial state
omniwmctl subscribe active-workspace,windows-changed --no-send-initial
```

## watch

Subscribe to events and execute a command for each event received. The event data is passed to the child process on stdin.

```
omniwmctl watch <channels> [--no-send-initial] --exec <command> [args...]
omniwmctl watch --all [--no-send-initial] --exec <command> [args...]
```

The `--exec` flag is required and marks the boundary between watch flags and the child command. Everything after `--exec` is the child command and its arguments.

`watch` consumes the subscribe handshake client-side instead of printing it. It runs one child process per event, waits for that child to finish before handling the next event, writes exactly one NDJSON event line to the child's stdin, and reports non-zero child exits to stderr without terminating the watcher.

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
```
