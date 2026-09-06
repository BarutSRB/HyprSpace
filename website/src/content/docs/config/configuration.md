---
title: Configuration
description: Where OmniWM stores its settings, how live reload and recovery work, and how to edit the TOML safely.
sidebar:
  order: 1
---

OmniWM stores its editable configuration at `${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/settings.toml`. That file is the canonical settings source: it is live-reloaded whenever you save it from an editor, and every change made in the Settings window is written back to it. Current files include the top-level key `schemaVersion = 3`.

:::caution[The schema is strict]
After version upgrades, `settings.toml` is validated as a whole. In a version 3 file, a missing required key invalidates the **entire file**, and the `hotkeys` array must contain every assignable action **exactly once** — an unknown, duplicate, or missing action id rejects the file. Enumerated string keys must use one of their listed values; an unknown value rejects the whole file too. The safest way to edit is to change values in place (or use the Settings window) rather than deleting keys. See the [Settings Reference](/config/settings-reference/) for every key and its default.
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
- If the file cannot be parsed, OmniWM leaves it untouched and reports the problem in Diagnostics: at startup it runs with defaults, and a malformed live edit leaves the active settings unchanged. If you later save from the Settings window, OmniWM first secures the exact rejected bytes as `settings.toml.corrupt` (then `settings.toml.corrupt.1`) next to the config file — two write-once slots — before replacing the file.
- Unrecognized keys are preserved on save and reported by the built-in diagnostics rather than deleted. If an unrecognized key belongs to an array element that cannot be matched unambiguously after an edit, OmniWM leaves the file untouched and blocks writes instead of attaching the key to the wrong element.

### Automatic version upgrades

A file without `schemaVersion` is a legacy version 0 file; OmniWM v0.6.4 emitted version 1 files. OmniWM guarantees automatic upgrades for settings emitted by v0.6.2 through v0.6.4 and upgrades valid version 2 files as well. Version 0 files pass through the version 1, version 2, and version 3 migrations in memory. Version 1 and version 2 files start at their next step without rerunning earlier migrations. Only the final strict version 3 file is written:

- Missing settings introduced since version 0 receive their compatibility defaults. In particular, `focus.raiseOnMouseFocus` becomes `true` to preserve the old behavior; `gaps.fullscreenUsesOuterGaps` and `workspaceBar.hideInNativeFullscreen` become `false`; and `scratchpads.labels` starts empty.
- The version 0 hotkey step adds the required scratchpad slot entries. The old `assignFocusedWindowToScratchpad` and `toggleScratchpadWindow` ids become their slot 1 equivalents while preserving the configured triggers; an explicitly configured slot 1 id wins if both forms are present.
- The retired `consumeOrExpelWindowLeft` and `consumeOrExpelWindowRight` actions are removed. Diagnostics suggest the current replacement commands.
- The version 1 to version 2 step adds the 18 `switchWorkspaceSlot.N` and `moveToWorkspaceSlot.N` entries plus `closeFocusedWindow`, all unassigned unless already present. Final validation still rejects any unrelated unknown, duplicate, or missing hotkey id.
- The version 2 to version 3 step moves a nonempty `monitorRoutingOverrides` array into one `routing.arrangements` entry with a stable UUID. An empty array becomes no arrangements. All original monitor rows and their unrecognized fields remain intact, including rows for disconnected displays; the migration does not query displays. Custom routing can inherit that arrangement for a connected subset. A missing, non-array, or malformed old routing field rejects the configuration without rewriting it.

Before rewriting version 0, 1, or 2, OmniWM copies its exact original bytes to the write-once backup `settings.toml.pre-v3`, using `settings.toml.pre-v3.1` if the first slot already contains different data. An existing byte-for-byte identical backup is reused. If neither slot is safe to use or the backup cannot be written, OmniWM leaves the original file untouched, applies the upgraded settings only in memory, and blocks subsequent settings writes so the original cannot be overwritten.

After a successful backup, OmniWM atomically rewrites the file once as canonical version 3 TOML. The rewrite preserves unrecognized keys, the target of a symlink, and file permissions, but it can reorder the document and does not preserve comments. The pre-v3 backup retains the exact original text. If the rewrite fails, the original file remains intact and subsequent configuration writes are blocked. A valid release migration never creates a `.corrupt` backup; those recovery slots are reserved for a genuinely rejected file that is later replaced by an explicit settings save.

Config logs and the built-in Diagnostics report every defaulted path, mapped or retired hotkey, and the backup location. Paths shown there use the resolved XDG config directory, including a custom `XDG_CONFIG_HOME`.

Older schema-less files are attempted through the same migration, but are outside the guaranteed compatibility range. OmniWM v0.6.0 used direction-specific resize action ids: for both `resizeGrow` and `resizeShrink`, replace the `.left`/`.right` pair with one `.horizontal` entry and the `.up`/`.down` pair with one `.vertical` entry, choosing which binding to keep if the pair differed. If a version 0, 1, or 2 file contains structures that cannot satisfy strict post-migration validation, startup leaves the file untouched and runs with defaults, and a live edit is rejected without changing the active settings. A file with a newer, unsupported `schemaVersion` is not treated as corrupt: OmniWM leaves it untouched, blocks configuration writes, and reports that this OmniWM version cannot safely edit it.

## Runtime state lives elsewhere

Volatile runtime state is kept out of the config file so `settings.toml` stays clean for dotfile management. Clipboard history, update-check timestamps, the persisted window restore catalog (including Niri column and Dwindle tree placements), the Quake terminal's custom frame, and the last palette mode live in `${XDG_STATE_HOME:-$HOME/.local/state}/omniwm`.

## What's in the file

The full schema is documented key by key in the [Settings Reference](/config/settings-reference/). At the top level:

| Table / array | Covers |
| --- | --- |
| [`[general]`](/config/settings-reference/#general) | Hotkeys master switch, Hyper key, default layout, updates, IPC, animations |
| [`[focus]`](/config/settings-reference/#focus) | Focus-follows-mouse and monitor-edge focus behavior |
| [`[mouseWarp]`](/config/settings-reference/#mousewarp) | Cursor warping between monitors |
| [`[routing]`](/config/settings-reference/#routing) | macOS vs. custom routing and saved arrangements per connected display set |
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
| [`[[monitor*Overrides]]`](/config/settings-reference/#per-monitor-overrides) | Per-monitor bar, orientation, Niri, Dwindle, and gap overrides |
