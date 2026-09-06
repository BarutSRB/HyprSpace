---
title: Compatibility, Requirements & Limitations
description: Hardware, macOS, permissions, Spaces, conflicts, private APIs, and current OmniWM limitations.
sidebar:
  order: 1
---

_Verified against OmniWM v0.6.7 on September 6, 2026._

OmniWM is designed for a specific modern Mac configuration. Check the requirements and tradeoffs below before
installing so you can decide whether it fits your system and workflow.

## Supported Macs and macOS

- **Apple Silicon only** — Intel Macs are not supported.
- **macOS 26 Tahoe or later** — most features work on macOS 26. Hidden Bar concealment requires macOS 27 or later.
- **System Integrity Protection stays enabled** — official releases do not require disabling SIP.

## Required macOS permissions

- **Accessibility** is required to discover, focus, move, and resize application windows.
- **Input Monitoring** is required for global hotkeys and optional System Hyper Trigger keys or mouse buttons.
- **Screen Recording is optional.** Without it, OmniWM still tiles windows. Overview thumbnails, drag previews, and
  captured Hidden Bar glyphs are unavailable.

See the [installation guide](/guides/install/) for the exact setup sequence.

## Spaces configuration

`Displays have separate Spaces` must be enabled in **System Settings → Desktop & Dock → Mission Control**. OmniWM
keeps running but pauses window management while that setting is disabled.

For the clearest behavior, keep one native macOS Space per display and navigate with OmniWM workspaces. Extra native
Spaces are tolerated, but windows on inactive native Spaces are left to macOS and are not tiled until their Space is
active.

## Other window managers

Do not run another resident window manager alongside OmniWM. At launch, OmniWM checks for a second OmniWM instance
and for AeroSpace, Amethyst, bobrwm, Glide, komorebi, Nehir, Paneru, parket, Rift, Tangrid, TrimWM, yabai, and
Yashiki. When a conflict is found, window management does not start until the other manager exits.

## Private Apple frameworks

OmniWM uses public macOS frameworks and selected private Apple APIs. This enables capabilities that public APIs do
not expose, but private interfaces can change in a future macOS release. OmniWM therefore pins a strict supported
macOS baseline and validates new releases against that baseline.

Hidden Bar concealment dynamically loads the private MenuBarClientCore framework and is available only on macOS 27
or later. The rest of OmniWM continues to support macOS 26.

## Current functional limitations

- **Dwindle restore scope** — After a restart OmniWM rebuilds each Dwindle workspace from the persisted placements: split orientation and ratio, tab-group membership, tab order, and the active tab. Fullscreen state and the selected window are not restored, and once a window without a persisted placement is present, later windows insert normally instead of being placed from the catalog.
- **Scratchpad membership** — Window membership lasts for the current OmniWM process. Scratchpad labels persist, but memberships do not.
- **Inactive native Spaces** — Windows on inactive native Spaces remain under macOS control until their Space becomes active.
- **Concurrent window managers** — OmniWM intentionally refuses to start window management when another resident manager could issue competing frame or focus changes.

## Release integrity

Official GitHub release builds are Developer ID signed and Apple-notarized. Downloads and release notes are published
through the [OmniWM GitHub releases page](https://github.com/BarutSRB/OmniWM/releases/latest). OmniWM is free and open
source under the [GPL-2.0-only license](https://spdx.org/licenses/GPL-2.0-only.html).

:::note
Hit something that does not look intentional, or see a statement here that needs correction? See
[Community & Support](/help/community/) for the in-app report flow and project contact routes.
:::
