---
title: Multi-Monitor Setup
description: Configure display placement, OmniWM routing, workspace homes, and mouse warp for a multi-monitor desk.
sidebar:
  order: 4
---

## Two display maps for two jobs

OmniWM uses two display maps that do different work — the macOS arrangement handles technical window placement, while the OmniWM routing map decides where directional actions go.

1. Open **System Settings > Displays > Arrange**. Put the physically largest or widest display at the bottom. Place the next smaller display above and to its right so its bottom-left corner touches the lower display's top-right corner. Continue the same staircase for every additional display. This macOS map is a technical arrangement used for actual window placement; it does not need to look like your desk.
2. Open **OmniWM Settings > Monitors** and arrange the OmniWM routing map to match where the displays really sit on your desk. Tiles can be separated by empty grid cells, but every display must remain connected through a chain of shared rows or columns. A diagonal-only tile is disconnected and cannot exchange directional focus, window moves, or mouse warp.
3. Assign at least one workspace to every connected display. Window moves between displays need a destination workspace, so the setup assistant will not finish while a display is uncovered. You can reassign an existing workspace or explicitly add one for that display.
4. Leave **Mouse Warp** turned on for the recommended experience. It lets the pointer cross between displays according to the real-desk OmniWM map even though macOS uses the staircase.

## The Monitor Setup assistant

The setup assistant opens automatically when OmniWM first sees multiple displays. To review or redo it later, choose **Run Monitor Setup…** in **Settings > Monitors**. The assistant's **Show Numbers on Screens** action helps match each physical display to its tile. Routing, workspace-home, and Mouse Warp changes remain drafts until you finish the assistant.

## Remembered arrangements

With **Custom Arrangement** selected, OmniWM remembers a routing grid for each set of connected displays. Your laptop can sit below an external display at home and beside another display at work; reconnecting either set restores its saved grid. Display resolution and macOS placement do not choose a different arrangement.

An exact saved set takes priority. Otherwise, OmniWM inherits the smallest saved arrangement that includes every connected display, using only the connected displays' positions. The first saved arrangement wins a tie. If no arrangement covers the set, or the selected grid is invalid for the remaining displays, routing follows macOS.

Editing or resetting the grid, or finishing the setup assistant, saves an arrangement for exactly the connected displays. Editing an inherited grid creates a separate arrangement for that subset and leaves its larger source unchanged. Connecting or disconnecting displays and opening Settings never save an arrangement. Explicitly selecting **Custom Arrangement** creates an initial arrangement only when no saved arrangement covers the connected set.

Workspace homes and other per-monitor settings are separate from these saved routing arrangements. See [`routing` in the Settings Reference](/config/settings-reference/#routing) for the configuration format.

## Per-monitor behavior

Layout behavior follows each display rather than one global setting: monitors using horizontal orientation show Niri columns that scroll left and right, while vertical orientation shows rows that scroll up and down. See [Layout Modes](/guides/layouts/).

Two settings shape how windows travel between displays:

- **Move Window Across Monitor at Edge** governs whether moving a window past a workspace edge carries it to the adjacent display. The dedicated `Move Window to Left / Right / Up / Down Monitor` actions work independently of it: they send the focused window directly to the current workspace on the adjacent routed display and do not wrap when no monitor exists in that direction.
- **Follow Window to Monitor** controls whether focus follows a window sent to another monitor; when it is off, you remain in the source workspace.

## Workspaces and their home monitor

Every workspace has a **Home Monitor**, and every connected display needs at least one workspace assigned to it for cross-display window moves to have a destination. The `Move Workspace to Left / Right / Up / Down Monitor` actions target the active workspace and intentionally use the same temporary runtime override as `omniwmctl workspace move-to-monitor --force` — they do not rewrite the workspace's Home Monitor or swap workspaces, and unsafe fullscreen, hidden-app, scratchpad, or focus states still block the move. See the [CLI reference](/reference/cli/overview/) for the scripted equivalent.

:::note
The monitor-related shortcuts (`Focus Next Monitor`, `Focus Last Monitor`, and the move actions above) are listed with their defaults in [Keyboard Shortcuts](/guides/keyboard-shortcuts/).
:::
