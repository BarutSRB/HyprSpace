---
title: Configuration
description: Where OmniWM stores its settings, how live reload and recovery work, and how to edit the TOML safely.
sidebar:
  order: 1
---

OmniWM stores its editable configuration at `${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/settings.toml`. That file is the canonical settings source: it is live-reloaded whenever you save it from an editor, and every change made in the Settings window is written back to it. Current files include the top-level key `schemaVersion = 1`.

:::caution[The schema is strict]
After version upgrades, `settings.toml` is validated as a whole. In a version 1 file, a missing required key invalidates the **entire file**, and the `hotkeys` array must contain every assignable action **exactly once** — an unknown, duplicate, or missing action id rejects the file. The safest way to edit is to change values in place (or use the Settings window) rather than deleting keys. See the [Settings Reference](/config/settings-reference/) for every key and its default.
:::

## Opening the file

Click OmniWM's status bar icon and use:

- **Reveal Settings File** — shows `settings.toml` in Finder.
- **Edit Settings File** — opens it in your editor.

Both commands recreate the file from the running settings if it was deleted, so you always land on a complete, valid file.

## Settings window

Every setting is also editable in the SwiftUI Settings window, organized into 14 sections (General, Troubleshooting, Niri Layout, Dwindle Layout, Monitors, Workspaces, Overview, Borders, Workspace Bar, Hidden Bar, Hotkeys, Mouse & Trackpad, Quake Terminal, Report an Issue). **App Rules** opens as its own window from the status menu. The window is a front end for the TOML — `settings.toml` remains the source of truth either way.

**Settings > General** also carries a **System-wide Window Corners** control (macOS 26.4+). It writes the system-wide preference, so it changes standard Mac app windows everywhere — including windows OmniWM does not manage — and apps that draw their own window chrome may ignore it. Affected apps must be fully quit and reopened before the new radius applies.

## Live reload and recovery

- Saving `settings.toml` from an editor applies the changes immediately; no restart needed.
- If the file cannot be parsed at startup, OmniWM preserves the unparseable data as `settings.toml.corrupt` (then `settings.toml.corrupt.1`) next to the config file — two write-once slots — and continues with defaults. A malformed live edit is initially left untouched while the active settings remain unchanged; if you later save from the Settings window, OmniWM first secures those exact rejected bytes in a recovery slot before replacing the file.
- Unrecognized keys are preserved on save and reported by the built-in diagnostics rather than deleted. If an unrecognized key belongs to an array element that cannot be matched unambiguously after an edit, OmniWM leaves the file untouched and blocks writes instead of attaching the key to the wrong element.

### Automatic version upgrades

A file without `schemaVersion` is a legacy version 0 file. OmniWM guarantees automatic upgrades for settings emitted by OmniWM v0.6.1 through v0.6.3, then applies the strict current schema:

- Missing settings introduced since version 0 receive their compatibility defaults. In particular, `focus.raiseOnMouseFocus` becomes `true` to preserve the old behavior; `gaps.fullscreenUsesOuterGaps` and `workspaceBar.hideInNativeFullscreen` become `false`; and `scratchpads.labels` starts empty.
- Missing current hotkey entries receive their current defaults. The old `assignFocusedWindowToScratchpad` and `toggleScratchpadWindow` ids become their slot 1 equivalents while preserving the configured triggers; an explicitly configured slot 1 id wins if both forms are present.
- The retired `consumeOrExpelWindowLeft` and `consumeOrExpelWindowRight` actions are removed. Diagnostics suggest the current replacement commands.

Before rewriting the file, OmniWM copies its exact original bytes to the write-once backup `settings.toml.pre-v1`, using `settings.toml.pre-v1.1` if the first slot already contains different data. An existing byte-for-byte identical backup is reused. If neither slot is safe to use or the backup cannot be written, OmniWM leaves the original file untouched, applies the upgraded settings only in memory, and blocks subsequent settings writes so the original cannot be overwritten.

After a successful backup, OmniWM atomically rewrites the file as canonical version 1 TOML. The rewrite preserves unrecognized keys, the target of a symlink, and file permissions, but it can reorder the document and does not preserve comments. The pre-v1 backup retains the exact original text. A successful upgrade does not create a `.corrupt` backup.

Config logs and the built-in Diagnostics report every defaulted path, mapped or retired hotkey, and the backup location. Paths shown there use the resolved XDG config directory, including a custom `XDG_CONFIG_HOME`.

Older schema-less files are attempted through the same migration, but are outside the guaranteed compatibility range. OmniWM v0.6.0 used direction-specific resize action ids: for both `resizeGrow` and `resizeShrink`, replace the `.left`/`.right` pair with one `.horizontal` entry and the `.up`/`.down` pair with one `.vertical` entry, choosing which binding to keep if the pair differed. If older files contain retired structures that cannot satisfy strict post-migration validation, startup uses the normal `.corrupt` recovery and a live edit is rejected without changing the active settings. Version 1 files continue to use strict validation and the same recovery behavior. A file with a newer, unsupported `schemaVersion` is not treated as corrupt: OmniWM leaves it untouched, blocks configuration writes, and reports that this OmniWM version cannot safely edit it.

## Runtime state lives elsewhere

Volatile runtime state is kept out of the config file so `settings.toml` stays clean for dotfile management. Clipboard history, update-check timestamps, the persisted window restore catalog, the Quake terminal's custom frame, and the last palette mode live in `${XDG_STATE_HOME:-$HOME/.local/state}/omniwm`.

## What's in the file

The full schema is documented key by key in the [Settings Reference](/config/settings-reference/). At the top level:

| Table / array | Covers |
| --- | --- |
| [`[general]`](/config/settings-reference/#general) | Hotkeys master switch, Hyper key, default layout, updates, IPC, animations |
| [`[focus]`](/config/settings-reference/#focus) | Focus-follows-mouse and monitor-edge focus behavior |
| [`[mouseWarp]`](/config/settings-reference/#mousewarp) | Cursor warping between monitors |
| [`[routing]`](/config/settings-reference/#routing) | macOS vs. custom monitor arrangement |
| [`[gaps]`](/config/settings-reference/#gaps) | Inner and outer gaps |
| [`[niri]`](/config/settings-reference/#niri) | Scrolling (Niri) layout options |
| [`[dwindle]`](/config/settings-reference/#dwindle) | Dwindle (BSP) layout options |
| [`[borders]`](/config/settings-reference/#borders) | Focused-window border |
| [`[overview]`](/config/settings-reference/#overview) | Overview zoom and colors |
| [`[workspaceBar]`](/config/settings-reference/#workspacebar) | Workspace bar appearance and behavior |
| [`[gestures]`](/config/settings-reference/#gestures) | Mouse and trackpad gestures |
| [`[statusBar]`](/config/settings-reference/#statusbar) | Menu bar icon extras |
| [`[hiddenBar]`](/config/settings-reference/#hiddenbar) | Menu bar icon concealment |
| [`[clipboard]`](/config/settings-reference/#clipboard) | Clipboard history limits |
| [`[quakeTerminal]`](/config/settings-reference/#quaketerminal) | Drop-down terminal |
| [`[scratchpads]`](/config/settings-reference/#scratchpads) | Scratchpad slot labels |
| [`[appearance]`](/config/settings-reference/#appearance) | Light/dark appearance of OmniWM's own UI |
| [`[[hotkeys]]`](/config/settings-reference/#hotkeys) | One entry per assignable action |
| [`[[workspaces]]`](/config/settings-reference/#workspaces) | Workspace definitions |
| [`[[appRules]]`](/config/settings-reference/#apprules) | Per-app window rules |
| [`[[monitor*Overrides]]`](/config/settings-reference/#per-monitor-overrides) | Per-monitor bar, orientation, Niri, Dwindle, gap, and routing overrides |
