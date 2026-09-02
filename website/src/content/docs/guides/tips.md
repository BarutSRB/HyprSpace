---
title: Tips
description: Mouse, trackpad, and workspace tricks that make OmniWM faster to drive.
sidebar:
  order: 6
---

## Name your workspaces

Create named workspaces in Settings to organize by project or context — emojis work too 🥳.

## Tame problem apps with rules

Use [App Rules](/features/app-rules/) to exclude problematic apps from tiling or assign them to specific workspaces.

## Swap windows by dragging

Hold the configured mouse-move modifier and drag a tiled window onto another to swap them; this works in both layouts. On Niri, add `Shift` to insert into a column instead. In Dwindle the drag swaps whole tiles, so a tab group moves with all of its members, the drop target is outlined while you hover it, releasing anywhere else changes nothing, and `Shift` has no effect. The modifier defaults to `Option` and can be changed or disabled in **Settings → Mouse & Trackpad**. In [Overview](/features/overview/), `Option + drag` targets a workspace, window position, or Niri column gap.

## Resize with a right-drag

Hold the configured right-mouse resize modifier (`Option` by default) and right-drag a tiled window to resize it in either layout.

## Scroll the strip with a mouse wheel

Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) to scroll along the active Niri primary axis: left/right in horizontal orientation or up/down in vertical orientation.

## Trackpad gestures

Use 2/3/4-finger gestures (configurable) along the active Niri primary axis; direction can be inverted (local hardware validation is limited).

The **Trackpad Scroll Style** picker in **Settings → Mouse & Trackpad** chooses how the strip responds:

- **Snap to Columns** (default) — the scroll snaps to the nearest column.
- **Momentum** — free inertial scrolling with rubber-band edges.

## Workspace swipe (opt-in)

Opt in under **Settings → Mouse & Trackpad**: swipe with a configurable finger count (2/3/4) and axis (horizontal/vertical) to switch to the next/previous workspace on the monitor under the cursor, one switch per swipe. Sharing the column-scroll finger count locks the axis to vertical.

:::caution[Mission Control can intercept vertical swipes]
For vertical swipes with three or four fingers, first turn off Mission Control in System Settings → Trackpad → More Gestures so macOS does not intercept the gesture.
:::
