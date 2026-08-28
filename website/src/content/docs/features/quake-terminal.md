---
title: Quake Terminal
description: A drop-down terminal powered by Ghostty's libghostty, summoned anywhere with a single hotkey.
sidebar:
  order: 1
---

OmniWM ships a true quake/sticky terminal you can summon over any workspace. It is a real embedded terminal built on Ghostty's [libghostty](https://ghostty.org) — not a wrapper around another terminal app — and it supports multiple tabs and splits within tabs.

Toggle it with `` Option + ` `` (backtick) by default; the binding is configurable in Settings under Hotkeys, alongside the rest of the [keyboard shortcuts](/guides/keyboard-shortcuts/).

## Position and size

Configure the terminal in **Settings → Quake Terminal**:

- **Position** — `Top`, `Bottom`, `Left`, `Right`, or `Center`. The default is `Center`, which fades the terminal in place; the four edge positions slide it in from that screen edge.
- **Show On** — which monitor the terminal appears on: `Mouse Cursor's Monitor`, `Focused Window's Monitor` (the default), or `Main Monitor`.
- **Width / Height** — each 10–100% of the screen in 5% steps; both default to 50%.

You can also adjust the terminal directly with the mouse: drag its edges to resize, and hold `Option` and drag to move it. OmniWM remembers the size and position per monitor, and a **Reset to Default Position** button appears in Settings once a custom frame is in use.

## Appearance

- **Background Effect** — choose `Standard Blur`, `Regular Glass`, or `Clear Glass`. `Standard Blur` comes with an adjustable blur radius; the native glass effects do not, but switching effects preserves the saved Standard Blur radius so it becomes active again when you return to it.
- **Quake Background Opacity** — 10–100%.

:::tip
Blur only shows through a translucent terminal — lower the opacity to see it.
:::

## Behavior

- **Animation Duration** — 0 to 1 second, default 0.2s. Ignored while global animations are disabled.
- **Auto-hide on Focus Loss** — optionally hide the terminal whenever it loses focus.

## Inside-terminal shortcuts

| Action | Shortcut |
|--------|----------|
| New Tab | `Cmd + T` |
| Close Tab | `Cmd + W` |
| Next Tab | `Cmd + Shift + ]` |
| Previous Tab | `Cmd + Shift + [` |
| Next Tab (Alt) | `Ctrl + Tab` |
| Previous Tab (Alt) | `Ctrl + Shift + Tab` |
| Select Tab 1-9 | `Cmd + 1-9` |
| Split Pane (Horizontal) | `Cmd + D` |
| Split Pane (Vertical) | `Cmd + Shift + D` |
| Close Pane | `Cmd + Shift + W` |
| Equalize Splits | `Cmd + Shift + =` |
| Navigate Pane | `Cmd + Option + Arrow Keys` |
