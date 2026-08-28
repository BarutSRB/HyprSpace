---
title: App Rules
description: Match windows by app, title, or role and control how OmniWM tiles, places, and sizes them.
sidebar:
  order: 7
---

Open **App Rules** from OmniWM's status-bar menu to configure window-matching behavior. Rules can match by bundle ID, app-name substring, title substring or regex, and AX role/subrole. More-specific matches win; ties follow list order.

## Rule actions

- **Layout (Automatic / Tile / Float)** — leave classification automatic, or force matching windows to tile or float.
- **Assign to Workspace** — use a valid workspace assignment as the initial default whenever the matching app currently has no tracked windows. Additional windows open on the workspace active when creation began. Automatic rule reevaluation leaves managed windows in place, while explicit rule application can move them. Readmission, structural replacements, tracked transient children, and unique persisted boot-restore matches preserve their existing placement continuity.
- **Initial Container Primary Span (Niri)** — start matching resizable windows at 5–100% when they create or claim a new container; the container remains freely resizable afterward.
- **Minimum Size** — prevent the layout engine from sizing windows below a threshold.

:::note
Initial container primary span is a one-time seed. It controls width in horizontal orientation and height in vertical orientation. Niri's Single Window Fit still takes visual precedence for a lone window, and physical minimum-size constraints can clamp the resolved pixel size without changing the stored initial proportion.
:::

## TOML

Rules can also be written in `settings.toml` (see [Configuration](/config/configuration/)). The equivalent TOML rule uses a proportion:

```toml
[[appRules]]
bundleId = "net.kovidgoyal.kitty"
initialContainerPrimarySpan = 0.5
```

## Default rules

OmniWM ships 13 default rules — minimum-size rules for apps whose windows misbehave when squeezed too small — covering browsers (Chrome, Safari, Zen, Firefox, Dia), Ghostty, Spotify, Discord, Outlook, Messages, and more. Edit or remove them freely in the App Rules window.
