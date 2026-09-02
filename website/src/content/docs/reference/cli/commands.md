---
title: Command Reference
description: omniwmctl top-level commands, global flags, exit codes, the full command action surface, and capture control.
sidebar:
  order: 2
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
| `capture` | remote | Start, stop, or inspect a diagnostics trace or performance capture |
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
| `command focus-window-or-workspace-down` | — | niri | Focus down using the active Niri orientation; if no target exists, switch without wrapping to the workspace below |
| `command focus-window-or-workspace-up` | — | niri | Focus up using the active Niri orientation; if no target exists, switch without wrapping to the workspace above |
| `command focus previous` | — | shared | Focus the previously focused window |
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
| `command expel-window-from-column` | — | niri | Expel the bottom window from the focused Niri column into a new following column |

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
| `command center-visible-columns` | — | niri | Center the current block of fully visible Niri columns in the viewport |
| `command move-column` | `<left\|right\|up\|down>` | shared left/right; dwindle up/down | Move a Niri column horizontally or swap a complete Dwindle tile/group without monitor fallback |
| `command move-column-to-first` | — | niri | Move the focused Niri column to the first position |
| `command move-column-to-last` | — | niri | Move the focused Niri column to the last position |
| `command move-column-to-index` | `<number>` | niri | Move the focused Niri column to a one-based index |
| `command move-column-to-workspace` | `<number>` | niri | Move the focused Niri column to a Niri workspace by workspace ID |
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
| `command cycle-size forward` | — | shared | Cycle layout sizing presets forward (in Dwindle the focused window takes 30, 50, or 70 % of its split) |
| `command cycle-size backward` | — | shared | Cycle layout sizing presets backward (in Dwindle the focused window takes 70, 50, or 30 % of its split) |
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
| `command scratchpad assign <number>` | — | shared | Assign the focused window to scratchpad 1-10, or remove it when already there |
| `command scratchpad toggle <number>` | — | shared | Show or hide the windows in scratchpad 1-10 |

### UI Toggles

| Command | Arguments | Layout | Description |
|---------|-----------|--------|-------------|
| `command open-command-palette` | — | shared | Toggle the command palette |
| `command open-menu-anywhere` | — | shared | Open the menu surface |
| `command toggle-workspace-bar` | — | shared | Toggle workspace bar visibility |
| `command hidden-bar panel` | — | shared | Toggle the panel containing configured hidden menu-bar items |
| `command toggle-quake-terminal` | — | shared | Toggle the configured Quake terminal |
| `command toggle-overview` | — | shared | Open Overview when it is closed, or dismiss it onto the current selection when it is open |
| `command toggle-system-stats` | — | shared | Toggle the system stats popup when a workspace-bar System Stats button is available |

For example, run `omniwmctl command hidden-bar panel` to show or dismiss the Hidden Bar panel.

Overview is modal with respect to external commands. While it is open every IPC/external command except `toggle-overview` returns `ignored_overview`; `omniwmctl command toggle-overview` closes it onto the current selection, exactly like Escape, Enter, backdrop dismissal, or the configured physical Overview toggle.

**Layout compatibility:**
- `shared` — works with any active layout
- `niri` — only works when the active workspace uses the Niri layout
- `dwindle` — only works when the active workspace uses the Dwindle layout

Commands sent to an incompatible layout return `layout_mismatch`.

---

## Capture

Capture control is independent of the window-manager enabled state, active layout, and Overview. IPC must still be enabled and the request must be authenticated.

```bash
omniwmctl capture start trace
omniwmctl capture start performance
omniwmctl capture stop
omniwmctl capture status
```

Only one capture can be active. `capture stop` stops whichever profile is recording and waits for finalization before returning. Starting while a capture is active, or stopping while the coordinator is idle, starting, or finalizing, returns `capture_state_conflict` with the current capture snapshot.

A trace capture writes an atomic partial immediately, refreshes it periodically, and replaces it with the final trace on stop or automatic finalization. A performance capture writes only its final artifact. Both profiles automatically finalize after 10 minutes and keep their existing size and retention limits.

`capture status` returns `phase`, the active `profile` and `startedAt` when present, and the coordinator's nullable `lastArtifact`. Timestamps are RFC 3339 strings. Artifact paths are absolute. A write failure returns `internal_error` with a UTF-8-safe, 4 KiB-bounded `failureReason`.

```json
{
  "phase": "idle",
  "profile": null,
  "startedAt": null,
  "lastArtifact": {
    "profile": "trace",
    "path": "/Users/example/.local/state/omniwm/diagnostics/omniwm-trace-....log",
    "startedAt": "2026-08-25T21:00:00Z",
    "endedAt": "2026-08-25T21:01:00Z"
  },
  "failureReason": null
}
```

`lastArtifact` is one process-local, best-effort slot rather than per-profile history. Its profile can differ from the active profile. A successful new trace start clears a prior trace artifact after the replacement partial is safely written; a performance start does not clear the slot. Successful finalization replaces it, while finalization failure leaves the prior value unchanged. During `finalizing`, it can still refer to the preceding capture.

If a successful stop response is lost, status can discover the result before another successful finalization or successful new trace start clears or replaces it. Wait for `phase` to become `idle` and compare the artifact metadata before starting another capture. Status does not recover failed responses, persist across app restarts, or provide capture history.

Disconnecting the client or disabling and restarting IPC while OmniWM remains alive does not stop an armed capture or roll back an accepted finalization, although the response can be lost. App termination does not finalize an active capture: a trace retains its latest completed partial, while an unfinished performance capture produces no artifact.
