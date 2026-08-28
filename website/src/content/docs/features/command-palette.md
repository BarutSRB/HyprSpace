---
title: Command Palette
description: Search windows, app menus, and clipboard history from one keyboard-driven palette.
sidebar:
  order: 2
---

Open the palette with `Control + Option + Space` (configurable with the other [keyboard shortcuts](/guides/keyboard-shortcuts/)) and search windows, app menus, or clipboard history from one shared surface.

## Modes

The palette has three modes:

- **Windows** — `Cmd + 1`
- **Menu** — `Cmd + 2`
- **Clipboard** — `Cmd + 3`

`Tab` / `Shift + Tab` cycle forward or backward through the available modes.

## Navigating results

- `Up` / `Down` move the selection.
- `Enter` activates the selected result.
- `Shift + Enter` summons the selected window to the right of the current one, when available.
- `Escape` dismisses the palette.

Windows from macOS-hidden apps remain searchable and carry a **Hidden** badge; selecting one unhides its app and focuses that exact window. In Menu mode, results always show keyboard shortcuts when available.

## How search ranks results

Window search uses substring matching with tiered ranking: matches in the window title rank first, then matches in the app name, then matches in the workspace name — and typing part of the literal word "hidden" surfaces the windows of hidden apps. Within each tier, matches closer to the start of the text rank higher.

## Clipboard history

Clipboard history is off by default; enable it in Settings. Once enabled, the Clipboard mode searches everything you have copied.

History is deduplicated — copying identical content again updates the existing entry and moves it to the top instead of creating a duplicate — and it is persisted securely: entries are written with owner-only file permissions to OmniWM's state directory (`${XDG_STATE_HOME:-$HOME/.local/state}/omniwm`), outside dotfile-oriented config storage.

## Menu Anywhere

`Control + Option + M` pops the frontmost app's real menu bar at your cursor, so you can reach any application's native menus without traveling to the top of the screen.
