---
title: Overview Mode
description: See every window on every workspace at once as live, searchable thumbnails.
sidebar:
  order: 3
---

Press `Option + Shift + O` and all of your workspaces' windows fly into a scrollable overview of thumbnails. Workspaces with no windows are hidden. Configure the 50–150% baseline zoom plus backdrop and window-border colors in **Settings → Overview**.

## Finding and focusing windows

- Type to filter windows live; `Backspace` deletes search text.
- `Arrow Keys` navigate spatially; `Left` / `Right` stay within the current workspace. `Tab` / `Shift + Tab` cycle forward or backward through matching windows, and keyboard navigation automatically scrolls the selected thumbnail into view.
- `Enter` or a click focuses the selected window. `Escape`, the configured Overview shortcut, and clicking the backdrop also dismiss Overview and focus the current selection; `Escape` does not clear search first.
- Mouse and trackpad scrolling follow the system Natural Scrolling setting.
- `Alt (Option) + Shift + Mouse Scroll` temporarily zooms the current overview; the next opening starts from the configured baseline.
- If another application takes focus, Overview dismisses without stealing focus back.

## Managing windows from Overview

- `Command + W` closes the selected window once per press and keeps Overview open; selection advances only after the window has closed.
- `Option + drag` a thumbnail onto a workspace, an exact window position, or a Niri column gap; layouts without an exact placement equivalent fall back to moving the window to the destination workspace.
- Your assigned structural move, reorder, consume/expel, and workspace-transfer [shortcuts](/guides/keyboard-shortcuts/) operate on the selected thumbnail while Overview is open. In Niri workspaces you can reorder windows and columns, consume or expel windows, move windows into or out of columns, move windows across workspaces and monitors, and move whole columns between Niri workspaces. In Dwindle workspaces, Overview supports moving windows across workspaces and closing them.
- A successful move keeps the moved window selected and activates its destination workspace and monitor behind Overview.

:::note
Thumbnails require the optional Screen Recording permission. Without it, Overview still works — the cards simply render without window pictures.
:::
