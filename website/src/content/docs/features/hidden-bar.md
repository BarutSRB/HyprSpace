---
title: Hidden Bar & Status Menu
description: Conceal menu-bar icons behind a panel, and flip OmniWM's key behaviors from the status-menu toggle tiles.
sidebar:
  order: 5
---

## Hidden Bar

Hidden Bar conceals selected menu-bar icons and lets you reach them from a panel:

- Pick the apps to hide in **Settings → Hidden Bar**.
- Right-click (or Option-click) the OmniWM menu bar icon to open the Hidden Icons Bar; click an icon to reveal and use it.
- Revealed icons re-hide automatically after a configurable interval — 5 seconds by default.
- An optional global hotkey is available and starts unassigned.

:::caution
Concealment requires macOS 27 or later; the rest of OmniWM continues to support macOS 26.
:::

## The status-bar menu

Clicking OmniWM's status bar icon opens a menu of toggle tiles for the behaviors you flip most often:

| Tile | What it does |
|------|--------------|
| **Borders** | Shows a colored outline around the currently focused managed window. On by default; customize its appearance in Settings. |
| **Workspace Bar** | Shows the clickable [workspace bar](/features/workspace-bar/) on each display. |
| **Keep Awake** | Prevents idle display sleep while your user session is active; manual sleep and closing the laptop lid still work. |
| **Focus Mouse** | Focus follows mouse — a managed window gains focus when the pointer enters it, no click needed. |
| **Focus Edge** | At the last window in any direction, focus continues onto the adjacent display in OmniWM's Routing Arrangement. |
| **Mouse to Focused** | Moves the pointer into a window after OmniWM navigation changes focus; it stays put if already inside or if the pointer caused the focus. |
| **Follow Monitor** | After moving a window or column to another workspace, switches there and keeps it focused. |
| **Move Edge** | At a workspace edge, Move Window sends the focused window to the adjacent routed display and follows it. |
| **Mouse Warp** | Moves the pointer across matching display edges using OmniWM's Routing Arrangement. On by default; available only with multiple displays. |
| **Hide Menu Icons** | Hides the menu-bar items selected in Settings (shown only where Hidden Bar concealment is available). |

Hovering a tile shows a help card explaining the toggle, with a live preview of the behavior.

:::tip
When Focus Mouse is on, hold the Focus Lock modifier to move the pointer across windows without changing focus.
:::
