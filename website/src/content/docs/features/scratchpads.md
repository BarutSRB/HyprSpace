---
title: Scratchpads
description: Ten slots of floating windows you can summon over any workspace and park off-screen again.
sidebar:
  order: 6
---

A scratchpad is a slot that holds any number of floating windows and overlays them on the workspace you are looking at. There are ten slots, numbered 1 to 10; a slot with no windows in it is inert and invisible.

## Assigning and toggling

Both hotkey families start unassigned — bind them in Settings under Hotkeys (see [keyboard shortcuts](/guides/keyboard-shortcuts/)):

- **Assign Focused Window to Scratchpad N** moves the focused window into slot N, floating it if it was tiled and parking it off-screen. Pressing the same shortcut again on a window already in slot N returns it to the layout.
- **Toggle Scratchpad N** reveals every window in slot N on the monitor you are interacting with, or parks them again if they are already there. Revealing a slot parks whichever slot was showing, so at most one scratchpad is on screen at a time.

A revealed scratchpad follows you across workspace switches and stays up until you toggle it off. If it is showing on another monitor, its shortcut summons it to the one you are on. Parked windows slide off the screen edge, leaving a 1-pixel sliver on-screen.

Revealed windows are ordinary floating windows: whether clicking something underneath pushes them behind it is governed by the usual focus and raise behaviour, including **Raise Window When Focus Follows Mouse**.

## Workspace-bar pills and labels

Each non-empty slot gets a pill in the [workspace bar](/features/workspace-bar/) showing its name and its windows' icons; clicking the pill toggles that scratchpad. Slots are identified by number everywhere, and an optional label replaces the number in the workspace bar and in `omniwmctl` output. Labels live in `settings.toml` (see [Configuration](/config/configuration/)):

```toml
[scratchpads.labels]
1 = "term"
3 = "COMMS"
```

## CLI

Scratchpads are scriptable through the [CLI](/reference/cli/overview/):

```sh
omniwmctl command scratchpad assign 3
omniwmctl command scratchpad toggle 3
omniwmctl query windows --scratchpad
```

`scratchpad assign` and `scratchpad toggle` take a slot number from 1 to 10; the `--scratchpad` flag limits the window query to windows assigned to a scratchpad.

:::note
Scratchpad membership lasts for the lifetime of the OmniWM process; only the labels are persisted.
:::
