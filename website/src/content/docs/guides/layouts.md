---
title: Layout Modes
description: OmniWM's Niri scrolling and Dwindle BSP layout engines, floating windows, and the two fullscreen modes.
sidebar:
  order: 3
---

## Two engines, chosen per workspace

OmniWM offers two layout engines, and each workspace picks its own. Switch the active workspace's layout with `Toggle Workspace Layout` (`Option + Shift + L` by default) or configure layouts per workspace in the GUI settings.

## Niri (orientation-aware scrolling containers)

On monitors using horizontal orientation, windows form vertical columns that scroll left and right; in vertical orientation, they form horizontal rows that scroll up and down. Each container can hold multiple windows or be "tabbed" — multiple windows with one visible at a time.

## Hyprland Dwindle (BSP)

A binary space partition layout that recursively divides screen space. Each new window splits the space in half, and a tile can group multiple windows as tabs. Best for traditional tiling with predictable layouts.

## Floating windows

Windows can also float above the tiled layout in either engine:

- `Toggle Focused Window Floating` (unassigned by default) floats or re-tiles the focused window.
- [App Rules](/features/app-rules/) can force matching windows to float — or to tile — instead of the automatic classification.
- `Raise All Floating Windows` (`Option + Shift + R`) brings every floating window to the front, and `Rescue Off-Screen Floating Windows` (unassigned) recovers strays.
- [Scratchpads](/features/scratchpads/) hold floating windows in ten toggleable slots.

## Fullscreen: OmniWM vs native

- **`Toggle Fullscreen`** (`Option + Return`) is OmniWM's own fullscreen: the focused window fills the monitor while staying on its workspace, under OmniWM's management. Press it again to drop back into the layout.
- **`Toggle Native Fullscreen`** (unassigned by default) uses macOS's built-in fullscreen, which moves the window into its own native fullscreen Space outside the tiled layout.

:::tip
The [Workspace Bar](/features/workspace-bar/) can optionally hide itself on a monitor while that monitor shows a macOS native fullscreen window (`Hide in Native Fullscreen`), and comes back on exit.
:::

The full list of layout-related shortcuts — sizing, balancing, Dwindle splits and preselection, Niri spans and columns — lives in [Keyboard Shortcuts](/guides/keyboard-shortcuts/).
