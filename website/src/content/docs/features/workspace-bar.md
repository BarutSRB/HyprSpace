---
title: Workspace Bar
description: A floating per-display island that shows your workspaces and their windows at a glance.
sidebar:
  order: 4
---

The workspace bar is a centered floating island on each display. It shows a chip per workspace — with the workspace's name, emoji-friendly — and the icons of the apps open there.

## Clicking the bar

- Click a workspace chip to switch to that workspace.
- Click an app icon to focus that window directly.
- When **Deduplicate App Icons** is enabled, multiple windows from one app share a single grouped icon with a count badge; click a grouped icon to open their window list, while a single-window icon focuses that window directly.
- macOS-hidden windows are marked with an eye-slash badge; selecting a hidden window unhides its app and focuses that exact window.
- Non-empty [scratchpad](/features/scratchpads/) slots appear as pills; clicking a pill toggles that scratchpad.

## System Stats

Optionally show a System Stats button that opens a CPU, memory, GPU, disk, and uptime popup. The `Toggle System Stats` hotkey and `omniwmctl command toggle-system-stats` drive the same popup, and both do nothing unless a monitor currently shows that workspace-bar button. See the [CLI reference](/reference/cli/overview/).

## Layout and appearance options

Configure position, height, and appearance in Settings:

- **Notch handling** — `Off`, `Move Below Menu Bar`, or a split layout (`Split — Active Left` / `Split — Active Right`) that flows the bar around the notch with your chosen side for the active workspace.
- **Reveal on modifier hold** — keep the bar hidden until you hold a chosen modifier.
- **Hide empty workspaces** — omit chips for workspaces with no windows.
- **Reserve layout space** — reserve room for the bar so tiled windows never sit underneath it.
- **Hide in Native Fullscreen** — hide the bar on a monitor while that monitor shows a macOS native fullscreen window, and bring it back on exit; reserved tiled layout space is left untouched so windows do not shuffle around the fullscreen session.
- **Custom accent and text colors**.
- **Per-monitor overrides** — change an individual display's bar independently.

## Excluding apps and overriding icons

Exclude individual apps or choose alternate app icons across all monitors in Settings. Icon overrides can also be configured in `settings.toml` (see [Configuration](/config/configuration/)). Quote bundle IDs so TOML treats each dotted identifier as one key:

```toml
[workspaceBar.iconOverrides]
"com.example.App" = "icons/custom.icns"
"com.cmuxterm.app" = "bundle-resource:AppIconDark"
```

`bundle-resource:` loads a named image packaged inside the selected app. The Settings picker discovers likely app-icon resources on demand; runtime-generated or downloaded Dock icons may not be available. Absolute paths are used as written, `~` expands to your home directory, and relative paths are resolved from the directory containing `settings.toml`.

:::note
Overrides affect only the workspace bar. A valid override takes precedence over the app's standard icon; an unavailable or invalid image falls back to the standard icon, then the dashed placeholder when no app icon is available. OmniWM does not watch image files; use Replace to reload a file changed in place.
:::
