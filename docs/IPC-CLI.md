---
title: OmniWM IPC & CLI Reference
---

# OmniWM IPC & CLI Reference

This document covers the OmniWM automation surface. For the docs hub, see [Documentation Home](index.md). For internal architecture, see [ARCHITECTURE.md](ARCHITECTURE.md). For contribution process, see the [Contribution Guide](CONTRIBUTING.md).

## Table of Contents

- [Architecture](#architecture)
- [Installation](#installation)
- [IPC Protocol](#ipc-protocol)
  - [Socket & Authorization](#socket--authorization)
  - [Wire Format](#wire-format)
  - [Security Model](#security-model)
- [CLI Reference](#cli-reference)
  - [Top-Level Commands](#top-level-commands)
  - [Global Flags](#global-flags)
  - [Exit Codes](#exit-codes)
- [Commands](#commands)
  - [Focus](#focus)
  - [Move](#move)
  - [Workspace Switching](#workspace-switching)
  - [Move to Workspace](#move-to-workspace)
  - [Monitor Focus](#monitor-focus)
  - [Container and Column Operations](#container-and-column-operations)
  - [Dwindle Operations](#dwindle-operations)
  - [Layout & Sizing](#layout--sizing)
  - [Window Management](#window-management)
  - [UI Toggles](#ui-toggles)
- [Queries](#queries)
  - [Query Selectors](#query-selectors)
  - [Query Fields](#query-fields)
  - [Query Reference](#query-reference)
- [Window Actions](#window-actions)
- [Workspace Actions](#workspace-actions)
- [Rules](#rules)
  - [Rule Options](#rule-options)
  - [Rule Actions](#rule-actions)
- [Subscriptions](#subscriptions)
  - [Delivery Pipeline](#delivery-pipeline)
  - [Channels](#channels)
  - [subscribe](#subscribe)
  - [watch](#watch)
- [Shell Completion](#shell-completion)
- [Wire Protocol Details](#wire-protocol-details)
  - [Request Format](#request-format)
  - [Response Format](#response-format)
  - [Event Envelope Format](#event-envelope-format)
  - [CLI-Local JSON Errors](#cli-local-json-errors)
- [Error Codes](#error-codes)
- [Output Formats](#output-formats)
- [Environment Variables](#environment-variables)
- [Aliases](#aliases)

---

## Architecture

OmniWM's IPC system is split across three Swift modules:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  OmniWMCtl (CLI binary)                                                  │
│  CLIEntry → CLIRuntime → CLIParser → IPCClient                           │
│  CLIRenderer, CLICompletionGenerator                                     │
│  Depends on: OmniWMIPC only                                             │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ Unix domain socket (NDJSON)
┌────────────────────────────┴─────────────────────────────────────────────┐
│  OmniWMIPC (shared library)                                              │
│  IPCModels, IPCWire, IPCSocketPath, IPCAutomationManifest                │
│  IPCRuleValidator                                                        │
│  No dependencies                                                         │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
┌────────────────────────────┴─────────────────────────────────────────────┐
│  OmniWM (app)                                                            │
│  IPCServer → IPCConnection → IPCApplicationBridge                        │
│  IPCCommandRouter, IPCQueryRouter, IPCRuleRouter, IPCEventBroker         │
│  Depends on: OmniWMIPC, AppKit, SkyLight, etc.                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Request flow:**

```
omniwmctl command focus left
    │
    ▼
CLIEntry.main()
    │
    ▼
CLIRuntime.run()
    ├─ local commands: help / completion
    ▼
CLIParser.parse()  ──▶  IPCRequest model
    │
    ▼
IPCClientConnection.send()
    │
    ▼
IPCWire.encodeRequestLine()  ──▶  Unix socket  ──▶  IPCServer
                                           │
                                           ▼
                                   IPCConnection (actor)
                                           │
                                           ▼
                                   IPCApplicationBridge
                                     ├─ auth check
                                     ├─ version check
                                     └─ route to IPCCommandRouter
                                           │
                                           ▼
                                   WMController.commandHandler
                                     (semantic command path only;
                                      no physical trigger metadata)
                                           │
                                           ▼
                                   ExternalCommandResult
                                           │
                                           ▼
IPCWire.decodeResponse()  ◀──  IPCResponse (JSON)
    │
    ▼
CLIRenderer  ──▶  stdout
```

Local commands such as `help`, `--help`, `-h`, and `completion` never open the IPC socket. `watch` uses the same subscribe request path, then stays client-side to launch one child process per received event.

---

## Installation

### CLI Binary Location

The `omniwmctl` binary is bundled inside the OmniWM app at:

```
OmniWM.app/Contents/MacOS/omniwmctl
```

### Installing to PATH

Use the OmniWM status bar menu: **Install CLI to PATH**. OmniWM chooses the first writable directory already on `PATH` inside your home directory. If none is available, it falls back to `~/.local/bin`, then `~/bin`.

The menu also shows current CLI status:
- **Homebrew-managed** — CLI is already available from a Homebrew path, and OmniWM leaves it alone
- **App-managed** — symlink created by OmniWM, removable via menu
- **Not installed** — no OmniWM-managed CLI link is present yet
- **Conflict** — another file exists at the target path

### Enabling IPC

IPC is disabled by default. Enable it via:
- Status bar menu: **Enable IPC**
- The setting persists across sessions

Turning **Enable IPC** on starts the server immediately and creates the Unix socket plus the authorization secret file. Turning it off stops the server and removes both files.

---

## IPC Protocol

**Protocol version:** 11

### Socket & Authorization

| Item | Path |
|------|------|
| Socket | `~/Library/Caches/com.barut.OmniWM/ipc.sock` |
| Secret | `~/Library/Caches/com.barut.OmniWM/ipc.sock.secret` |

The socket path can be overridden with the `OMNIWM_SOCKET` environment variable. The secret file path is always `<socket-path>.secret`. For custom socket paths, prefer a private same-user directory such as `$TMPDIR/omniwm/ipc.sock` after creating the parent directory with mode `0700`. Avoid shared directories such as `/tmp`.

The authorization token is a random UUID generated each time the IPC server starts. Clients must include this token in every request. The CLI reads it automatically from the secret file.

### Wire Format

The protocol uses **newline-delimited JSON (NDJSON)** — one JSON object per line, terminated by `0x0A`.

- Maximum request size: **64 KB**
- Encoding: UTF-8
- JSON keys: sorted, `camelCase`

Examples in this document are pretty-printed for readability. The actual wire format is compact single-line JSON with the same field names.

### Security Model

1. **Socket permissions:** `0600` (owner-only read/write)
2. **Socket directory permissions:** newly created socket directories are created with `0700`
3. **Secret file permissions:** `0600` (owner-only read/write)
4. **Peer UID check:** server verifies connecting client is the same user via `getpeereid()`
5. **Authorization token:** every request must carry the authorization token stored in plaintext at `<socket-path>.secret`
6. **Session-scoped window IDs:** opaque IDs embed a separate internal session token and are invalidated across restarts — format: `ow_` + base64url(`sessionToken:pid:windowId`)
7. **FD_CLOEXEC:** server-side listening and accepted socket file descriptors are not inherited by child processes
8. **SO_NOSIGPIPE:** prevents SIGPIPE crashes on broken connections
9. **Stale socket cleanup:** server checks existing sockets before overwriting

The trust boundary is the local macOS user account, not individual client processes. Any process running as the same user can read the secret file and use the IPC API once IPC is enabled.

If `OMNIWM_SOCKET` points into an existing directory, OmniWM reuses that directory as-is instead of re-permissioning it. For custom socket paths, prefer a private directory owned by the same user and avoid shared locations such as `/tmp`.

---

## CLI Reference

```
omniwmctl <command> [arguments...] [--format json|table|tsv|text] [--json]
```

### Top-Level Commands

| Command | Type | Description |
|---------|------|-------------|
| `ping` | remote | Verify IPC reachability and return `pong` |
| `version` | remote | Return the OmniWM app version and IPC protocol version |
| `command` | remote | Execute window manager commands through the IPC command surface |
| `query` | remote | Query OmniWM state, registries, and protocol capabilities |
| `rule` | remote | Manage persisted window rules and reapply them to windows |
| `workspace` | remote | Perform workspace actions such as focusing by workspace name |
| `window` | remote | Perform window actions using session-scoped opaque window IDs |
| `subscribe` | remote | Stream the subscribe handshake plus live event envelopes as JSON |
| `watch` | remote | Consume subscription events and run a child command once per event |
| `help`, `--help`, `-h` | local | Print CLI usage text without connecting to IPC |
| `completion <zsh\|bash\|fish>` | local | Emit a shell completion script without connecting to IPC |

Remote commands require IPC to be enabled. Local commands work even when the IPC server is disabled.

### Global Flags

| Flag | Description |
|------|-------------|
| `--format <format>` | Output format: `json`, `table`, `tsv`, `text` |
| `--json` | Alias for `--format json` |

Global flags must appear before `--exec` in watch commands.

### Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | success | Command completed successfully |
| 1 | rejected | Server rejected the request |
| 2 | transportFailure | Could not connect to IPC socket |
| 3 | invalidArguments | CLI argument parsing failed |
| 4 | internalError | Unexpected internal error |

---

## Commands

Execute window manager commands. While Overview is closed, these use the same semantic command path as hotkey-bound commands, without `PhysicalHotkeyTrigger` metadata.

```
omniwmctl command <command-path> [arguments...]
```

### Focus

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command focus` | `<left\|right\|up\|down>` | shared | Focus spatially; Dwindle Up/Down traverse grouped tabs before edge fallback |
| `command focus-window-in-column` | `<number>` | niri | Focus a window in the focused Niri column by one-based index |
| `command focus-window top` | — | niri | Focus the top window in the focused Niri column |
| `command focus-window bottom` | — | niri | Focus the bottom window in the focused Niri column |
| `command focus-window down-or-top` | — | shared | Focus the next window in the active Niri column or Dwindle group, wrapping locally |
| `command focus-window up-or-bottom` | — | shared | Focus the previous window in the active Niri column or Dwindle group, wrapping locally |
| `command focus-window-or-workspace-down` | — | niri | Focus down in the focused Niri column, or switch to the workspace below at the column edge |
| `command focus-window-or-workspace-up` | — | niri | Focus up in the focused Niri column, or switch to the workspace above at the column edge |
| `command focus previous` | — | niri | Focus the previously focused window |
| `command focus down-or-left` | — | niri | Traverse backward through the active Niri workspace |
| `command focus up-or-right` | — | niri | Traverse forward through the active Niri workspace |
| `command focus-column` | `<number>` | niri | Focus a Niri column by one-based index |
| `command focus-column first` | — | niri | Focus the first Niri column |
| `command focus-column last` | — | niri | Focus the last Niri column |

### Move

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command move` | `<left\|right\|up\|down>` | shared | Move with layout-aware consume/expel or Dwindle join/extract behavior |
| `command move-window-down` | — | shared | Reorder the focused window down by one without wrapping within its Niri column or Dwindle group |
| `command move-window-up` | — | shared | Reorder the focused window up by one without wrapping within its Niri column or Dwindle group |
| `command move-window-down-or-to-workspace-down` | — | niri | Move the focused Niri window down, or to the workspace below at the column edge |
| `command move-window-up-or-to-workspace-up` | — | niri | Move the focused Niri window up, or to the workspace above at the column edge |
| `command consume-or-expel-window-left` | — | niri | Consume or expel using the previous Niri column without wrapping or crossing monitors |
| `command consume-or-expel-window-right` | — | niri | Consume or expel using the next Niri column without wrapping or crossing monitors |
| `command consume-window-into-column` | — | niri | Consume the top window from the next Niri column into the focused column |
| `command expel-window-from-column` | — | niri | Expel the bottom window from the focused Niri column into a new column to the right |

`command move <direction>` follows the active layout's orientation and configured edge behavior, including optional monitor crossing. The explicit consume-or-expel commands use fixed Niri column order, never wrap or cross monitors, and cannot be assigned as shortcuts.

In Dwindle, `focus left/right` remains spatial. `focus up/down` traverses a group's eligible tabs; at the group edge it tries a spatial neighbor, then the configured monitor transition, and wraps locally only when neither exit succeeds. `move <direction>` joins a singleton with the touching tile or extracts only the active member from a group onto that side. Moving between two existing groups is a two-step extract-then-join operation. Use `move-column <direction>` when the complete tile or group should move instead.

### Workspace Switching

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command switch-workspace` | `<number>` | shared | Switch to a workspace by numeric workspace ID on the current monitor |
| `command switch-workspace next` | — | shared | Switch to the next workspace |
| `command switch-workspace prev` | — | shared | Switch to the previous workspace |
| `command switch-workspace back-and-forth` | — | shared | Switch to the previously active workspace |
| `command switch-workspace anywhere` | `<number>` | shared | Focus a workspace by numeric workspace ID across all monitors |

### Move to Workspace

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command move-to-workspace` | `<number>` | shared | Move focused window to a workspace by numeric workspace ID |
| `command move-to-workspace up` | — | shared | Move focused window to the adjacent workspace above |
| `command move-to-workspace down` | — | shared | Move focused window to the adjacent workspace below |
| `command move-to-workspace on-monitor` | `<number> <left\|right\|up\|down>` | shared | Move focused window to a workspace already assigned to the requested adjacent monitor |

Workspace IDs are positive numeric strings. Direct hotkeys stay limited to `1-9`, but the workspace UI and IPC/CLI both support `10+`.

### Monitor Focus

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command focus-monitor prev` | — | shared | Move focus to the previous monitor |
| `command focus-monitor next` | — | shared | Move focus to the next monitor |
| `command focus-monitor last` | — | shared | Move focus back to the previous monitor |
| `command move-to-monitor` | `<left\|right\|up\|down>` | shared | Move the focused window to the active workspace on an adjacent monitor |
| `command swap-workspace-with-monitor` | `<left\|right\|up\|down>` | shared | Swap active workspace with the workspace on an adjacent monitor |

`command move-to-monitor` does not wrap when no monitor exists in the requested direction. It honors **Follow Window to Monitor** and operates independently of **Move Window Across Monitor at Edge**.

### Container and Column Operations

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command center-column` | — | niri | Center the focused Niri column without changing focus |
| `command center-visible-columns` | — | niri | Center the fully visible Niri columns around the active column |
| `command move-column` | `<left\|right\|up\|down>` | shared left/right; dwindle up/down | Move a Niri column horizontally or swap a complete Dwindle tile/group without monitor fallback |
| `command move-column-to-first` | — | niri | Move the focused Niri column to the first position |
| `command move-column-to-last` | — | niri | Move the focused Niri column to the last position |
| `command move-column-to-index` | `<number>` | niri | Move the focused Niri column to a one-based index |
| `command move-column-to-workspace` | `<number>` | niri | Move the focused Niri column to a workspace by workspace ID |
| `command move-column-to-workspace up` | — | niri | Move focused column to the adjacent workspace above |
| `command move-column-to-workspace down` | — | niri | Move focused column to the adjacent workspace below |
| `command toggle-column-tabbed` | — | niri | Toggle tabbed mode for the focused column |
| `command toggle-container-full-primary-span` | — | niri | Toggle full-primary-span mode for the focused container |
| `command expand-container-to-available-primary-span` | — | niri | Expand the focused container into available primary-axis space |
| `command cycle-window-primary-span forward` | — | niri | Cycle window primary-span presets forward |
| `command cycle-window-primary-span backward` | — | niri | Cycle window primary-span presets backward |
| `command cycle-window-secondary-span forward` | — | niri | Cycle window secondary-span presets forward |
| `command cycle-window-secondary-span backward` | — | niri | Cycle window secondary-span presets backward |
| `command reset-window-secondary-span` | — | niri | Reset the focused window secondary span |
| `command set-container-primary-span` | `<size-change>` | niri | Set or adjust the focused container primary span |
| `command set-window-primary-span` | `<size-change>` | niri | Set or adjust the focused window primary span |
| `command set-window-secondary-span` | `<size-change>` | niri | Set or adjust the focused window secondary span |

`<size-change>` accepts fixed pixels (`100`), proportions (`50%`), fixed deltas (`+10`), or proportional deltas (`-10%`).

### Dwindle Operations

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command move-to-root` | — | dwindle | Move the selected window to the root split |
| `command toggle-split` | — | dwindle | Toggle the active split orientation |
| `command swap-split` | — | dwindle | Swap the active split |
| `command resize` | `<horizontal\|vertical> <grow\|shrink>` | dwindle | Grow or shrink the selected window along an axis |
| `command resize-focused` | `<grow\|shrink>` | dwindle | Grow or shrink the focused window |
| `command preselect` | `<left\|right\|up\|down>` | dwindle | Set the preselection direction |
| `command preselect clear` | — | dwindle | Clear the preselection |

### Layout & Sizing

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command balance-sizes` | — | shared | Balance layout sizes in the active workspace |
| `command cycle-size forward` | — | shared | Cycle layout sizing presets forward |
| `command cycle-size backward` | — | shared | Cycle layout sizing presets backward |
| `command toggle-workspace-layout` | — | shared | Toggle the workspace between Niri and Dwindle |
| `command set-workspace-layout` | `<default\|niri\|dwindle>` | shared | Set the workspace layout explicitly |
| `command toggle-fullscreen` | — | shared | Toggle OmniWM-managed fullscreen |
| `command toggle-native-fullscreen` | — | shared | Toggle native macOS fullscreen |

### Window Management

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command toggle-focused-window-floating` | — | shared | Toggle focused window between tiled and floating |
| `command raise-all-floating-windows` | — | shared | Raise all visible floating windows |
| `command rescue-offscreen-windows` | — | shared | Clamp tracked floating windows back onto their visible monitors |
| `command scratchpad assign` | — | shared | Assign the focused window to the scratchpad |
| `command scratchpad toggle` | — | shared | Show or hide the scratchpad window |

### UI Toggles

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command open-command-palette` | — | shared | Toggle the command palette |
| `command open-menu-anywhere` | — | shared | Open the menu surface |
| `command toggle-workspace-bar` | — | shared | Toggle workspace bar visibility |
| `command hidden-bar panel` | — | shared | Toggle the panel containing configured hidden menu-bar items |
| `command toggle-quake-terminal` | — | shared | Toggle the configured Quake terminal |
| `command toggle-overview` | — | shared | Open Overview when it is closed; see the modal-routing note below |
| `command toggle-system-stats` | — | shared | Toggle the system stats popup |

For example, run `omniwmctl command hidden-bar panel` to show or dismiss the Hidden Bar panel.

Overview is modal with respect to external commands. `omniwmctl command toggle-overview` opens it while it is closed, but while Overview is open every IPC/external command—including another `toggle-overview`—returns `ignored_overview`. Dismissal remains local: Escape, Enter, backdrop dismissal, or the configured physical Overview toggle closes onto the current selection.

**Layout compatibility:**
- `shared` — works with any active layout
- `niri` — only works when the active workspace uses the Niri layout
- `dwindle` — only works when the active workspace uses the Dwindle layout

Commands sent to an incompatible layout return `layout_mismatch`.

---

## Queries

```
omniwmctl query <name> [selectors...] [--fields <field1,field2,...>] [--format json|table|tsv|text]
```

Default output format for queries is `json`.

### Query Selectors

Selectors filter query results. Value selectors take an argument; boolean selectors are flags.

**Value selectors:**

| Selector | Description |
|----------|-------------|
| `--window <id>` | Filter by session-scoped opaque window ID |
| `--workspace <name>` | Filter by workspace raw name, display name, or ID |
| `--display <name>` | Filter by display name or display ID |
| `--app <name>` | Filter by application display name |
| `--bundle-id <id>` | Filter by application bundle identifier |

**Boolean selectors:**

| Selector | Description |
|----------|-------------|
| `--focused` | Only the focused item |
| `--visible` | Only visible items; windows also require a visible workspace, no window hidden state, and an app that is not hidden |
| `--floating` | Only floating windows |
| `--scratchpad` | Only the scratchpad window |
| `--current` | Only the current/interaction item |
| `--main` | Only the main display |

### Query Fields

Use `--fields` with a comma-separated list to limit returned fields.

Field tokens are part of the CLI contract. Returned JSON still uses the payload schema's field names, so the selected token may not be byte-for-byte identical to the JSON key. For example, `window-counts` selects the workspace payload's `counts` field.

**Window fields:** `id`, `pid`, `workspace`, `display`, `app`, `title`, `frame`, `mode`, `layout-reason`, `manual-override`, `is-focused`, `is-visible`, `is-app-hidden`, `is-scratchpad`, `hidden-reason`

For windows, `is-visible` is true only when the workspace is visible, the window has no `hidden-reason`, and its macOS application is not hidden. `is-app-hidden` exposes the PID-scoped macOS hide state independently of `layout-reason` and `hidden-reason`; selecting `is-app-hidden` returns the JSON field `isAppHidden`.

**Workspace fields:** `id`, `raw-name`, `display-name`, `number`, `layout`, `display`, `is-focused`, `is-visible`, `is-current`, `window-counts`, `focused-window-id`

**Display fields:** `id`, `name`, `is-main`, `is-current`, `frame`, `visible-frame`, `has-notch`, `orientation`, `inner-gap`, `outer-gap-left`, `outer-gap-right`, `outer-gap-top`, `outer-gap-bottom`, `active-workspace`

### Query Reference

| Query | Selectors | Fields | Description |
|-------|-----------|--------|-------------|
| `workspace-bar` | — | — | Workspace bar projection for every monitor |
| `active-workspace` | — | — | Current interaction monitor and active workspace |
| `focused-monitor` | — | — | Current interaction monitor and its active workspace |
| `apps` | — | — | Managed app summary |
| `focused-window` | — | — | Focused managed window snapshot |
| `windows` | `--window`, `--workspace`, `--display`, `--focused`, `--visible`, `--floating`, `--scratchpad`, `--app`, `--bundle-id` | window fields | Managed windows |
| `workspaces` | `--workspace`, `--display`, `--current`, `--visible`, `--focused` | workspace fields | Configured workspaces with occupancy |
| `displays` | `--display`, `--main`, `--current` | display fields | Connected displays with geometry |
| `rules` | — | — | Persisted user window rules |
| `rule-actions` | — | — | Rule action registry |
| `queries` | — | — | Query registry |
| `commands` | — | — | Automation action registry for `command`, `workspace`, and `window` surfaces |
| `subscriptions` | — | — | Subscription registry |
| `capabilities` | — | — | Full protocol capabilities |

**Examples:**

```bash
# List all windows on workspace "main"
omniwmctl query windows --workspace main

# Get focused window in table format
omniwmctl query focused-window --format table

# List visible floating windows, only return id and title
omniwmctl query windows --visible --floating --fields id,title

# Get the active workspace on the current interaction monitor
omniwmctl query workspaces --current

# Check server capabilities
omniwmctl query capabilities
```

---

## Window Actions

Operate on specific windows by their session-scoped opaque ID.

```
omniwmctl window <action> <opaque-id>
```

| Action | Description |
|--------|-------------|
| `focus` | Focus a managed window by opaque ID |
| `navigate` | Navigate to a managed window (switches workspace if needed) |
| `summon-right` | Summon a window to the right of the currently focused window |

Window IDs are session-scoped. They become stale after OmniWM restarts. Obtain IDs from query results (e.g., `omniwmctl query windows`).

---

## Workspace Actions

```
omniwmctl workspace focus-name <name>
omniwmctl workspace move-to-monitor <workspace> <left|right|up|down> [--force]
```

| Action | Arguments | Description |
|--------|-----------|-------------|
| `focus-name` | `<name>` | Focus a workspace by raw workspace ID or unambiguous configured display name |
| `move-to-monitor` | `<workspace> <left\|right\|up\|down> [--force]` | Move a workspace to an adjacent monitor |

Numeric inputs are resolved as raw workspace IDs first. Display-name lookup is a convenience path and fails when multiple workspaces share the same display name.

Monitor direction is resolved relative to the named workspace's current monitor. Moving a visible workspace transfers its visibility to the destination monitor, and the source monitor selects another eligible workspace. Moving an inactive workspace normally makes it visible on the destination while leaving the source monitor's visible workspace unchanged. If the destination's visible workspace is the current interaction workspace, the moved workspace is assigned there but remains inactive, preserving that interaction instead of replacing it. This action does not swap the two visible workspaces.

If the moved workspace owns the exact focused managed-window token and no incompatible focus transition is pending, that token follows the workspace without a new AX focus request. Otherwise, OmniWM preserves the interaction monitor and any non-managed focus. OmniWM rejects the move when native-fullscreen, macOS-hidden app, scratchpad, or pending focus state cannot be transferred safely.

Configured monitor assignment remains enforced unless `--force` is present. A forced move changes runtime placement without rewriting the workspace's persisted monitor configuration. The override lasts for the current OmniWM process and survives a transient disconnect and reconnect of the same output ID. It clears when the workspace returns to its configured home monitor, when configuration is reapplied, or when OmniWM restarts. If native fullscreen, a macOS-hidden app, a visible scratchpad, or an in-flight managed-focus transition makes rehoming unsafe, configuration reapply defers the clear until that state resolves. Configured workspace restore snapshots continue to prefer the Home Monitor. The flag may appear anywhere after `move-to-monitor`, although help and completion render the canonical trailing form.

---

## Rules

Manage persisted window rules that control layout behavior, default workspace placement, and the initial Niri
container primary span for matching windows. Primary span is width in horizontal orientation and height in
vertical orientation.
Rule add, replace, and config reload trigger automatic reevaluation. A valid workspace assignment applies as
the initial default whenever the matching app currently has no tracked windows. Additional windows use the
workspace active when creation began. Automatic reevaluation preserves existing managed windows' workspaces, while
readmission, structural replacements, tracked transient children, and unique persisted boot-restore matches
preserve placement continuity. `rule apply` is the explicit path that may move existing managed windows.
Initial container primary span is a one-shot Niri admission hint and never resizes an existing container.

```
omniwmctl rule <action> [arguments...] [options...]
```

### Rule Options

| Option | Value | Description |
|--------|-------|-------------|
| `--bundle-id` | `<bundle-id>` | Application bundle identifier. Optional: omit it to match apps with no runtime bundle ID, but then supply at least one of `--app-name-substring` / `--title-substring` / `--title-regex` |
| `--app-name-substring` | `<text>` | Match app name containing this substring |
| `--title-substring` | `<text>` | Match window title containing this substring |
| `--title-regex` | `<pattern>` | Match window title against this regex |
| `--ax-role` | `<role>` | Match accessibility role |
| `--ax-subrole` | `<subrole>` | Match accessibility subrole |
| `--layout` | `<auto\|tile\|float>` | Layout action (`auto` = default behavior) |
| `--assign-to-workspace` | `<raw-name>` | Use this workspace as the initial default whenever the matching app currently has no tracked windows |
| `--initial-container-primary-span` | `<proportion>` | Initial Niri container primary span for a resizable window, from `0.05` through `1.0` inclusive |
| `--min-width` | `<points>` | Minimum window width in points |
| `--min-height` | `<points>` | Minimum window height in points |

When supplied, bundle IDs must match the pattern: `^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$`. Every rule needs
at least one identifier — a bundle ID, app-name substring, or title (substring/regex). The bundle ID is
the app's *runtime* identifier (`NSRunningApplication.bundleIdentifier`); apps without one (e.g. ad-hoc
or wrapper apps) are matched by app name and/or title. AX role/subrole refine an existing match but cannot
identify a rule on their own.

`initialContainerPrimarySpan` is stored and returned over IPC as a proportion. `omniwmctl query rules` renders
it as a percentage in human-readable table or text output. It applies only when a matching resizable window
creates or claims a new Niri container, and the user can resize that container afterward.

Niri's Single Window Fit policy retains precedence for a lone window, so it can visually mask the seeded
primary span. Physical minimum-size constraints can clamp the resolved span in pixels, but they do not rewrite
the stored `initialContainerPrimarySpan` proportion.

### Rule Actions

**Add a rule:**

```bash
omniwmctl rule add [options...]
```

Supply `--bundle-id` and/or at least one matcher (`--app-name-substring`, `--title-substring`, `--title-regex`). Appends a new rule to the end of the rule list. Its placement defaults apply whenever the matching app currently has no tracked windows; already managed windows are not moved.

**Replace a rule:**

```bash
omniwmctl rule replace <rule-id> [options...]
```

Replaces a rule in-place by its UUID (same identifier requirement as `add`). The rule ID is preserved. Already managed windows are not moved until rules are explicitly applied.

**Remove a rule:**

```bash
omniwmctl rule remove <rule-id>
```

Removes a rule by its UUID.

**Move a rule:**

```bash
omniwmctl rule move <rule-id> <position>
```

Moves a rule to a new one-based position in the rule list.

**Apply rules:**

```bash
omniwmctl rule apply [--focused | --window <opaque-id> | --pid <pid>]
```

Re-evaluates the current rule set against the target. Defaults to `--focused` if no target is specified. This is
the explicit path for applying ongoing rule effects to already managed windows; the one-shot initial container
primary-span hint is not reasserted on an existing container. Explicit application may move an existing window
to its valid assigned workspace.

| Target | Description |
|--------|-------------|
| `--focused` | Apply to the currently focused window (default) |
| `--window <id>` | Apply to a specific window by opaque ID |
| `--pid <pid>` | Apply to all managed windows for a process |

**Examples:**

```bash
# Float all Finder windows
omniwmctl rule add --bundle-id com.apple.finder --layout float

# Tile Safari's first currently tracked window on workspace 2
omniwmctl rule add --bundle-id com.apple.Safari --layout tile --assign-to-workspace 2

# Start new Kitty containers at 50% of the primary axis in Niri
omniwmctl rule add --bundle-id net.kovidgoyal.kitty --initial-container-primary-span 0.5

# Float windows with "Preferences" in the title
omniwmctl rule add --bundle-id com.apple.Safari --title-substring Preferences --layout float

# Float an app that has no runtime bundle ID, matched by app name
omniwmctl rule add --app-name-substring VMD --layout float

# Remove a rule
omniwmctl rule remove 550e8400-e29b-41d4-a716-446655440000

# Explicitly reapply rules to all windows of a specific app
omniwmctl rule apply --pid 12345
```

---

## Subscriptions

Subscribe to real-time state change events from OmniWM.

### Delivery Pipeline

`IPCServer.start()` attaches `IPCApplicationBridge` to `WMController`. Controller state changes publish channel snapshots through the bridge, and `IPCConnection` expands the requested channels for each client, sends the initial `subscribe` response, starts per-channel stream tasks, and emits initial snapshots unless `--no-send-initial` is set.

Initial snapshots are best-effort seed state, not a strict ordering barrier. If state changes during subscription setup, a live update can race with the initial snapshot.

Subscription channels are coalesced state streams, not a lossless event log. Slow consumers may only observe the newest buffered update for a channel.

Workspace bar and layout refresh work is only produced when the UI or IPC currently has active consumers.

### Channels

| Channel | Result Type | Description |
|---------|-------------|-------------|
| `focus` | focused-window | Focused window snapshot updates |
| `workspace-bar` | workspace-bar | Workspace bar projection updates |
| `active-workspace` | active-workspace | Interaction monitor and active workspace updates |
| `focused-monitor` | focused-monitor | Focused monitor updates |
| `windows-changed` | windows | Managed window inventory updates |
| `display-changed` | displays | Display state updates |
| `layout-changed` | workspaces | Workspace layout updates |

### subscribe

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

### watch

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

---

## Shell Completion

Generate shell completion scripts for `omniwmctl`.

```
omniwmctl completion <zsh|bash|fish>
```

**Setup:**

```bash
# Zsh — add to ~/.zshrc
eval "$(omniwmctl completion zsh)"

# Bash — add to ~/.bashrc
eval "$(omniwmctl completion bash)"

# Fish — add to ~/.config/fish/config.fish
omniwmctl completion fish | source
```

Completions are context-aware: query names, selectors, field names, command paths, channel names, rule actions, and argument values are all completed dynamically based on the automation manifest.

---

## Wire Protocol Details

### Request Format

```json
{
  "version": 11,
  "id": "<uuid>",
  "kind": "<ping|version|command|query|rule|workspace|window|subscribe>",
  "authorizationToken": "<token>",
  "payload": { ... }
}
```

**Payload varies by kind:**

**Command:**
```json
{
  "name": "focus",
  "arguments": {
    "direction": "left"
  }
}
```

**Dwindle axis resize:**
```json
{
  "name": "resize",
  "arguments": {
    "axis": "vertical",
    "operation": "shrink"
  }
}
```

**Query:**
```json
{
  "name": "windows",
  "selectors": {
    "workspace": "main",
    "visible": true
  },
  "fields": ["id", "title", "app"]
}
```

**Rule (add):**
```json
{
  "name": "add",
  "arguments": {
    "rule": {
      "bundleId": "com.apple.finder",
      "layout": "float"
    }
  }
}
```

**Subscribe:**
```json
{
  "channels": ["focus", "active-workspace"],
  "allChannels": false,
  "sendInitial": true
}
```

**Workspace focus:**
```json
{
  "name": "focus-name",
  "workspaceTarget": {
    "kind": "display-name",
    "value": "S"
  }
}
```

**Workspace move:**
```json
{
  "name": "move-to-monitor",
  "workspaceTarget": {
    "kind": "raw-id",
    "value": "12"
  },
  "direction": "right",
  "force": true
}
```

Workspace requests use this flat wire shape. For `move-to-monitor`, `force` is optional while decoding; omitting it is equivalent to `false`.

**Window:**
```json
{
  "name": "focus",
  "windowId": "ow_..."
}
```

### Response Format

```json
{
  "version": 11,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|query|rule|workspace|window|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "code": null,
  "result": {
    "kind": "<pong|version|workspace-bar|active-workspace|focused-monitor|apps|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|subscribed>",
    "payload": { ... }
  }
}
```

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 11,
  "id": "<request-id>",
  "ok": false,
  "kind": "query",
  "status": "error",
  "code": "unauthorized"
}
```

Malformed or oversized request lines fail before routing and are reported as `kind: "error"` with `code: "invalid_request"` and an empty request id.

### Event Envelope Format

Events are sent on subscription connections after the initial response.

```json
{
  "version": 11,
  "id": "<event-id>",
  "kind": "event",
  "channel": "focus",
  "ok": true,
  "status": "success",
  "result": {
    "kind": "focused-window",
    "payload": { ... }
  }
}
```

The `result` type corresponds to the channel's result kind (see [Channels](#channels)).

### CLI-Local JSON Errors

When JSON output is active and `omniwmctl` fails before or outside the IPC request/response path, it emits a client-side failure envelope instead of an `IPCResponse`. This is used for argument parsing failures, transport failures, and unexpected internal CLI errors. `query` and `subscribe` default to JSON output even without an explicit `--json` flag.

```json
{
  "ok": false,
  "source": "cli",
  "status": "error",
  "code": "<invalid_arguments|transport_failure|internal_error>",
  "message": "<human-readable error>",
  "exitCode": 3
}
```

This envelope is produced locally by the CLI, so it does not include IPC fields like `version`, `id`, `kind`, or `result`. The `exitCode` matches the CLI-local failure class: `2` for transport failures, `3` for invalid arguments, and `4` for internal errors.

---

## Error Codes

| Code | Meaning |
|------|---------|
| `invalid_request` | Malformed, oversized, or unparseable request |
| `invalid_arguments` | Bad arguments for the command/rule |
| `protocol_mismatch` | Client/server protocol version mismatch |
| `ignored_disabled` | Window manager is disabled |
| `ignored_overview` | Overview is open, so `CommandHandler` rejects external/IPC commands before normal execution |
| `layout_mismatch` | Command incompatible with the active workspace layout |
| `unauthorized` | Missing or invalid authorization token |
| `stale_window_id` | Window ID is from a previous session or no longer valid |
| `not_found` | Target window, workspace, or rule not found |
| `workspace_assignment_conflict` | Configured monitor assignment prevents the requested workspace move |
| `workspace_state_conflict` | Current fullscreen, scratchpad, or pending focus state prevents the requested workspace move |
| `internal_error` | Unexpected server-side error |

---

## Output Formats

| Format | Description | Default for |
|--------|-------------|-------------|
| `json` | Pretty-printed JSON | queries, subscribe |
| `table` | Aligned columns with headers | — |
| `tsv` | Tab-separated values | — |
| `text` | Simple human-readable text | commands, ping, version |

**Table output example (windows):**

```
ID    PID    APP       TITLE         WORKSPACE  DISPLAY   MODE     FOCUSED  VISIBLE  SCRATCHPAD
ow_…  1234   Terminal  ~             main       Built-in  tiling   yes      yes      no
ow_…  5678   Safari    GitHub        web        Built-in  tiling   no       yes      no
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `OMNIWM_SOCKET` | Override the default IPC socket path |
| `OMNIWM_EVENT_CHANNEL` | (watch child) Subscription channel name |
| `OMNIWM_EVENT_KIND` | (watch child) Event result kind |
| `OMNIWM_EVENT_ID` | (watch child) Event ID |

---

## Aliases

The CLI accepts these aliases transparently:

| Alias | Resolves to |
|-------|-------------|
| `query monitors` | `query displays` |
| `query --monitor` | `query --display` |
| `command focus-monitor previous` | `command focus-monitor prev` |
| `command switch-workspace previous` | `command switch-workspace prev` |
| `command switch-workspace back` | `command switch-workspace back-and-forth` |
