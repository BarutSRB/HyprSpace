---
title: Quick Start
description: Get OmniWM tiling your windows in five minutes.
sidebar:
  order: 1
---

## Install

The fastest path is Homebrew:

```bash
brew install --cask omniwm
```

Prefer Nix or a plain zip? The [installation guide](/guides/install/) covers every method plus the full requirements (macOS 26+ Tahoe on Apple Silicon).

## First launch

1. Launch OmniWM from your Applications folder.
2. In **System Settings > Desktop & Dock > Mission Control**, turn **ON** `Displays have separate Spaces`, then log out of macOS and back in for the change to take effect (skip the logout if it was already on). OmniWM pauses window management until this setting is enabled.
3. Grant **Accessibility** and **Input Monitoring** in the launch permissions window.
4. Optionally grant **Screen Recording** for capture-derived visuals such as Overview thumbnails.

Your windows now tile automatically in orientation-aware Niri containers: monitors using horizontal orientation show columns that scroll left and right, while vertical orientation shows rows that scroll up and down.

:::note[One Space per display]
Keep one macOS Space per display and navigate with OmniWM workspaces instead. Extra native Spaces are tolerated — their windows are left to macOS, not tiled.
:::

## First hotkeys to try

| Shortcut | What it does |
|----------|--------------|
| `Option + 1-9` | Switch to workspace 1-9 |
| `Option + Arrow Keys` | Focus the window to the left / right / up / down |
| `Option + Shift + Arrow Keys` | Move the focused window |
| `` Option + ` `` | Toggle the [Quake Terminal](/features/quake-terminal/) |
| `Control + Option + Space` | Toggle the [Command Palette](/features/command-palette/) |
| `Option + Shift + O` | Toggle [Overview](/features/overview/) |

Every shortcut is customizable in **Settings > Hotkeys**; the complete list lives in [Keyboard Shortcuts](/guides/keyboard-shortcuts/).

## Where Settings lives

OmniWM is a menu-bar-only app: click its menu bar icon to open **Settings** or **App Rules**.

- Enable `Start at Login` under **Settings > General > Startup** to launch OmniWM automatically when you log in.
- Update behavior lives under **Settings > General > Updates**; run a manual check any time with `Check for Updates...` in the status bar menu.

## The config file

Everything you set in the GUI is stored at `~/.config/omniwm/settings.toml`. The file is live-reloaded when saved from an editor, so you can manage OmniWM from your dotfiles too. See [Configuration](/config/configuration/).

## Next steps

- Pick a layout engine per workspace: [Layout Modes](/guides/layouts/)
- Using more than one display? [Multi-Monitor Setup](/guides/multi-monitor/)
- Mouse, trackpad, and workspace tricks: [Tips](/guides/tips/)
