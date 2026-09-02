---
title: Settings Reference
description: Complete reference for every table, array, key, and default in OmniWM's settings.toml.
sidebar:
  order: 2
---

Complete reference for `settings.toml`, in the file's canonical order. The authoritative schema is [`CanonicalTOMLConfig.swift`](https://github.com/BarutSRB/OmniWM/blob/main/Sources/OmniWM/Core/Config/CanonicalTOMLConfig.swift); defaults come from [`SettingsExport.swift`](https://github.com/BarutSRB/OmniWM/blob/main/Sources/OmniWM/Core/Config/SettingsExport.swift) and [`BuiltInSettingsDefaults.swift`](https://github.com/BarutSRB/OmniWM/blob/main/Sources/OmniWM/Core/Config/BuiltInSettingsDefaults.swift).

:::caution
The current schema is strict — a missing required key in a version 1 file invalidates the whole file, and `hotkeys` must list every assignable action exactly once. Edit values in place; see [Configuration](/config/configuration/).
:::

**Conventions**

- Keys marked *(optional)* may be omitted; every other key is required.
- **Colors** are tables with `red`, `green`, `blue`, `alpha` floats in `0.0`–`1.0`.
- **`singleWindowFit`** values are strings: `"fill"`, a custom size `"WIDTHxHEIGHT"` (e.g. `"1920x1080"`), or — Niri only — `"container_primary_span"`.
- Values listed as enums accept exactly the raw strings shown.

## File schema

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `schemaVersion` | integer | `1` | Version of the complete `settings.toml` schema. This top-level key appears before the first table. |

The canonical file declares:

```toml
schemaVersion = 1
```

An absent version identifies a legacy version 0 file. OmniWM guarantees automatic migration for settings emitted by v0.6.1 through v0.6.3 before strict validation; older schema-less files are attempted but are left untouched (with defaults active) if retired structures cannot validate. A successful upgrade creates an exact write-once `settings.toml.pre-v1` or `settings.toml.pre-v1.1` backup, then rewrites canonical TOML; this can reorder keys and removes comments, while preserving unrecognized keys when their owner can be matched safely. Files declaring a newer unsupported version remain untouched and configuration writes are blocked. See [Automatic version upgrades](/config/configuration/#automatic-version-upgrades) for the migration rules and recovery behavior.

## general

Global switches: hotkeys, Hyper key, default layout, sleep, updates, IPC, animations.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `hotkeysEnabled` | boolean | `true` | Master switch for all global hotkeys. |
| `systemHyperTrigger` | string | `"None"` | Physical trigger for Hyper: `None`, a key name (`CapsLock`, `F13`–`F20`, `Control`/`RightControl`, `Option`/`RightOption`, `Shift`/`RightShift`, `Command`/`RightCommand`), or `MouseButton3`/`MouseButton4`/`MouseButton5`. |
| `hyperKeyModifiers` | string | `"Control+Option+Shift+Command"` | Modifier set Hyper expands to: `+`-joined names, at least two of Control/Option/Shift/Command. |
| `defaultLayoutType` | string | `"niri"` | Layout used by workspaces whose own `layoutType` is `default`: `niri` or `dwindle`. |
| `preventSleepEnabled` | boolean | `false` | Prevents idle display sleep while your user session is active. |
| `updateChecksEnabled` | boolean | `true` | Automatic update checks. |
| `ipcEnabled` | boolean | `false` | Enables the IPC server used by `omniwmctl`. |
| `animationsEnabled` | boolean | `true` | Animates window layout changes. |

## focus

Pointer-driven focus and monitor-edge focus/move behavior.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `followsMouse` | boolean | `false` | Focuses a managed window when the pointer enters it, no click needed. |
| `raiseOnMouseFocus` | boolean | `false` | Also raises the window when focus-follows-mouse focuses it. |
| `lockModifier` | string | `"off"` | Modifier that holds focus in place while pressed: `off`, `option`, `leftOption`, `rightOption`, `command`, `leftCommand`, `rightCommand`, `control`, `leftControl`, `rightControl`, `shift`, `leftShift`, `rightShift`. |
| `moveMouseToFocusedWindow` | boolean | `false` | Moves the pointer to the window that gains focus. |
| `followsWindowToMonitor` | boolean | `false` | Keeps focus on a window when it moves to another monitor. |
| `crossesMonitorAtEdge` | boolean | `false` | Directional focus continues onto the neighboring monitor at the screen edge. |
| `moveCrossesMonitorAtEdge` | boolean | `false` | Directional window move continues onto the neighboring monitor at the screen edge. |

## mouseWarp

Cursor warping across the monitor arrangement (used with `routing.mode = "custom"`).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `margin` | integer | `1` | Edge margin in pixels used when warping the cursor between monitors. |
| `enabled` | boolean | `true` | Enables cursor warping between monitors. |
| `constrainToArrangement` | boolean | `false` | Constrains the cursor to the configured monitor arrangement. |

## routing

How monitors are arranged for cross-monitor focus, move, and warp.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | string | `"macOS"` | `macOS` follows the system display arrangement; `custom` uses the grid defined in [`monitorRoutingOverrides`](#per-monitor-overrides). |

## gaps

Gaps between tiled windows and screen edges (points).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `size` | float | `16.0` | Stored inner gap between tiled windows. An enabled focus border may raise the runtime-effective gap without rewriting this value. |
| `fullscreenUsesOuterGaps` | boolean | `false` | Fullscreen layout frames keep the outer gaps. |
| `outer.left` | float | `0.0` | Outer gap at the left screen edge. |
| `outer.right` | float | `0.0` | Outer gap at the right screen edge. |
| `outer.top` | float | `0.0` | Outer gap at the top screen edge. |
| `outer.bottom` | float | `0.0` | Outer gap at the bottom screen edge. |

## niri

Options for the scrolling (Niri) layout.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `visibleContainerCount` | integer | `2` | How many containers (columns) share the viewport side by side. |
| `infiniteLoop` | boolean | `false` | Treats the column strip as a loop instead of a bounded row. |
| `centerFocusedColumn` | string | `"never"` | When to center the focused column: `never`, `always`, `onOverflow`. |
| `alwaysCenterSingleColumn` | boolean | `false` | Centers the column when a workspace holds only one. |
| `singleWindowFit` | string | `"fill"` | Size of a lone window: border-safe `fill`, `container_primary_span`, or `WIDTHxHEIGHT`. |
| `containerPrimarySpanPresets` *(optional)* | float array | `[1/3, 1/2, 2/3]` | Span fractions the span-cycling actions step through. |
| `defaultContainerPrimarySpan` *(optional)* | float | `0.5` | Primary-axis span fraction for new containers. |

## dwindle

Options for the Dwindle (BSP) layout.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `smartSplit` | boolean | `false` | Automatically chooses the split direction based on cursor position. |
| `defaultSplitRatio` | float | `1.0` | `1.0` = equal split, `<1.0` = first window smaller, `>1.0` = first window larger. |
| `splitWidthMultiplier` | float | `1.0` | Biases when vertical vs. horizontal splits are preferred. |
| `singleWindowFit` | string | `"fill"` | Size of a lone window: border-safe `fill` or `WIDTHxHEIGHT` (no span mode in Dwindle). |
| `useGlobalGaps` | boolean | `true` | Uses the [`gaps`](#gaps) values; when `false`, the inner gap comes from a per-monitor `innerGap` override (falling back to `gaps.size`). |
| `moveToRootStable` | boolean | `true` | Keeps a window on the same screen side when moving it to the root. |

## borders

Border drawn around the focused window.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Draws the focused-window border. |
| `width` | float | `5.0` | Exterior border width in points. Managed layout frames use its physical-pixel ceiling as the minimum runtime inner and outer clearance while borders are enabled; stored gap values are unchanged. |
| `color` | color table | red ≈ `0.0846`, green `1.0`, blue ≈ `0.9793`, alpha `1.0` | Border color (default is a cyan accent). |

## overview

Zoom and colors for the Overview.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `zoom` | float | `1.0` | Overview zoom factor. |
| `backdrop` | color table | `0.05, 0.05, 0.08, 1.0` | Backdrop behind the zoomed-out workspaces. |
| `windowBorders.normal` | color table | `0.3, 0.3, 0.35, 0.5` | Border for windows at rest. |
| `windowBorders.hovered` | color table | `0.4, 0.6, 1.0, 1.0` | Border for the hovered window. |
| `windowBorders.selected` | color table | `0.3, 0.8, 0.4, 1.0` | Border for the selected window. |

## workspaceBar

The per-monitor workspace bar. Per-monitor exceptions live in [`monitorBarOverrides`](#per-monitor-overrides).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Shows the workspace bar. |
| `showLabels` | boolean | `true` | Shows workspace names next to their numbers. |
| `showFloatingWindows` | boolean | `false` | Includes floating windows' icons in workspace pills. |
| `windowLevel` | string | `"popup"` | Bar window level: `normal`, `floating`, `status`, `popup`, `screensaver`. |
| `position` | string | `"overlappingMenuBar"` | `overlappingMenuBar` or `belowMenuBar`. |
| `notchMode` | string | `"moveBelowMenuBar"` | Behavior on notched displays: `off`, `moveBelowMenuBar`, `splitActiveLeft`, `splitActiveRight`. |
| `notchActiveZoneWidth` | float | `180.0` | Width in points of the active zone around the notch. |
| `systemStatsButton` | boolean | `false` | Adds a system stats button to the bar. |
| `deduplicateAppIcons` | boolean | `false` | Collapses repeated icons of the same app within a pill. |
| `hideEmptyWorkspaces` | boolean | `false` | Hides pills for workspaces with no windows. |
| `excludedBundleIDs` | string array | `[]` | Bundle IDs whose windows never contribute icons to the bar. |
| `iconOverrides` | table | `{}` | Bundle ID → custom icon source (see below). |
| `reserveLayoutSpace` | boolean | `false` | Reserves tiled layout space using the configured bar height. |
| `revealModifier` | string | `"off"` | Reveal the bar by holding a modifier: `off`, `option`, `control`, `command`, `shift`, `controlOption`, `optionCommand`, `optionShift`, `controlCommand`, `controlShift`, `commandShift`, `controlOptionCommand`, `controlOptionShift`, `optionCommandShift`, `controlCommandShift`, `controlOptionCommandShift`. |
| `revealHoldMilliseconds` | float | `200.0` | How long the modifier must be held before the bar reveals. |
| `hideInNativeFullscreen` | boolean | `false` | Hides the bar while a native-fullscreen space is active. |
| `height` | float | `24.0` | Bar height in points. |
| `backgroundOpacity` | float | `0.1` | Bar background opacity (`0.0`–`1.0`). |
| `xOffset` | float | `0.0` | Horizontal offset in points. |
| `yOffset` | float | `0.0` | Vertical offset in points. |
| `accentColor` *(optional)* | color table | unset | Accent color override; unset uses the built-in accent. |
| `textColor` *(optional)* | color table | unset | Text color override; unset uses the built-in text color. |

`iconOverrides` maps a bundle ID to either an image file path — absolute, `~/`-relative, or relative to the `omniwm` config directory — or `bundle-resource:NAME` for an image resource inside that app's own bundle:

```toml
[workspaceBar.iconOverrides]
"com.apple.Safari" = "~/Pictures/safari-alt.png"
"com.mitchellh.ghostty" = "bundle-resource:AppIcon"
```

## gestures

Mouse and trackpad gestures.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `scrollEnabled` | boolean | `true` | Modifier + mouse scroll wheel scrolls along the Niri primary axis. |
| `scrollSensitivity` | float | `5.0` | Scroll gesture sensitivity. |
| `scrollModifierKey` | string | `"optionShift"` | Modifier for wheel scrolling: `optionShift` or `controlShift`. |
| `mouseMoveModifierKey` | string | `"option"` | Modifier for drag-to-swap of tiled windows: `off`, `option`, `control`, `command`, `controlOption`, `optionCommand`, `controlCommand`, `controlOptionCommand`. |
| `mouseResizeModifierKey` | string | `"option"` | Modifier for right-drag resize: `option`, `control`, `command`, `shift`, `controlOption`, `optionCommand`, `optionShift`, `controlCommand`, `controlShift`, `commandShift`, `controlOptionCommand`, `controlOptionShift`, `optionCommandShift`, `controlCommandShift`, `controlOptionCommandShift`. |
| `fingerCount` | integer | `3` | Trackpad column-scroll finger count: `2`, `3`, or `4`. |
| `invertDirection` | boolean | `true` | Inverts trackpad gesture direction. |
| `trackpadScrollStyle` | string | `"snap"` | `snap` (snap to columns) or `momentum`. |
| `workspaceSwipeEnabled` | boolean | `false` | Trackpad swipe switches to the next/previous workspace. |
| `workspaceSwipeFingerCount` | integer | `3` | Workspace-swipe finger count: `2`, `3`, or `4`. |
| `workspaceSwipeAxis` | string | `"vertical"` | Workspace-swipe axis: `horizontal` or `vertical`. |

## statusBar

Extra readouts beside the menu bar icon.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `showWorkspaceName` | boolean | `false` | Shows the active workspace beside the menu bar icon. |
| `showAppNames` | boolean | `false` | Also shows the focused app's name. |
| `useWorkspaceId` | boolean | `false` | Shows the workspace number instead of its name. |

## hiddenBar

Menu-bar icon concealment (concealment requires macOS 27+).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enables the Hidden Bar feature. |
| `hiddenBundleIDs` | string array | `[]` | Bundle IDs of menu-bar apps whose icons are concealed. |
| `rehideIntervalSeconds` | float | `5.0` | Seconds before revealed icons re-hide automatically. |

## clipboard

Clipboard history limits. History content itself is stored in the state directory, not in the config file.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `historyEnabled` | boolean | `false` | Enables clipboard history capture. |
| `maxItems` | integer | `200` | Maximum number of history entries. |
| `maxItemBytes` | integer | `8388608` | Maximum size of a single entry (8 MiB). |
| `maxTotalBytes` | integer | `67108864` | Maximum total history size (64 MiB). |

## quakeTerminal

The drop-down (Quake) terminal.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enables the Quake terminal. |
| `position` | string | `"center"` | Slide-in position: `top`, `bottom`, `left`, `right`, `center`. |
| `widthPercent` | float | `50.0` | Width as a percentage of the screen. |
| `heightPercent` | float | `50.0` | Height as a percentage of the screen. |
| `animationDuration` | float | `0.2` | Show/hide animation duration in seconds. |
| `autoHide` | boolean | `false` | Hides the terminal when it loses focus. |
| `opacity` *(optional)* | float | `1.0` | Terminal window opacity (`0.0`–`1.0`). |
| `backgroundEffect` | string | `"standardBlur"` | Background material: `standardBlur`, `glassRegular`, `glassClear`. |
| `backgroundBlurRadius` *(optional)* | integer | `0` | Background blur radius; `0` disables the extra blur. |
| `monitorMode` *(optional)* | string | `"focusedWindow"` | Which monitor it appears on: `mouseCursor`, `focusedWindow`, `mainMonitor`. |

## scratchpads

Optional labels for the ten scratchpad slots. A label replaces the slot number in the workspace bar and in `omniwmctl` output.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `labels` | table | `{}` | Slot number (`1`–`10`) → label string. |

```toml
[scratchpads.labels]
1 = "term"
2 = "notes"
```

## appearance

Appearance of OmniWM's own UI.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | string | `"dark"` | `automatic`, `light`, or `dark`. |

## hotkeys

Array of tables — one entry per assignable action, each with an `id` (the action identifier) and a `binding`:

```toml
[[hotkeys]]
binding = "Option+1"
id = "switchWorkspace.1"

[[hotkeys]]
binding = "Unassigned"
id = "toggleScratchpad.1"
```

- `binding` is a human-readable chord: `+`-joined modifiers (`Control`, `Option`, `Shift`, `Command`, or the `Hyper` shorthand for the full [`hyperKeyModifiers`](#general) set) followed by a key name — or `"Unassigned"`. A `Left `/`Right ` prefix pins a modifier to one side (e.g. `"Left Option+H"`).
- The array is validated strictly: every assignable action must appear **exactly once**. An unknown, unassignable, duplicate, or missing action id rejects the whole file, so rebind by editing `binding` values in place — never add or remove entries.

The default bindings are listed in the [keyboard shortcuts guide](/guides/keyboard-shortcuts/); the full action list is visible in **Settings > Hotkeys** and via `omniwmctl query commands`.

## workspaces

Array of workspace definitions.

| Key | Type | Description |
| --- | --- | --- |
| `id` | string (UUID) | Stable identity; keep it unchanged when editing. |
| `name` | string | Workspace name; numeric names define the ordering and number-key targets. |
| `displayName` *(optional)* | string | Label shown in the bar instead of `name` (emoji welcome). |
| `monitorAssignment` | table | `type` = `main`, `secondary`, or `specificDisplay` (the latter carries an `output` value identifying the display). |
| `layoutType` | string | `default` (follow `general.defaultLayoutType`), `niri`, or `dwindle`. |

Default: seven workspaces named `1`–`7`, all Niri — `1`–`5` on the main monitor, `6` (shown as ❤️) and `7` (shown as 🚀) on the secondary.

```toml
[[workspaces]]
displayName = "❤️"
id = "5953F2BF-A378-4266-91B2-287174C4FA4D"
layoutType = "niri"
name = "6"

[workspaces.monitorAssignment]
type = "secondary"
```

## appRules

Array of per-app window rules, editable in the **App Rules** window. Matchers select windows; the remaining fields say what to do with them.

| Key | Type | Description |
| --- | --- | --- |
| `id` | string (UUID) | Stable rule identity. |
| `bundleId` | string | App bundle ID to match (may be empty when an advanced matcher is used). |
| `appNameSubstring` *(optional)* | string | Matches on the app name. |
| `titleSubstring` *(optional)* | string | Matches on the window title. |
| `titleRegex` *(optional)* | string | Regex match on the window title; when both title matchers are set, the regex wins. |
| `axRole` *(optional)* | string | Matches the accessibility role. |
| `axSubrole` *(optional)* | string | Matches the accessibility subrole. |
| `layout` *(optional)* | string | `auto` (default), `tile`, or `float`. |
| `assignToWorkspace` *(optional)* | string | Workspace name the window is routed to. |
| `initialContainerPrimarySpan` *(optional)* | float | Initial Niri span for the window's container (`0.05`–`1.0`). |
| `minWidth` *(optional)* | float | Minimum layout width in points. |
| `minHeight` *(optional)* | float | Minimum layout height in points. |

The defaults ship 13 rules that set minimum sizes for apps with known resize floors (Codex, Commander One, Chrome, Zed, Safari, Zen, Firefox, Dia, Spotify, Discord, Ghostty, Outlook, Messages).

```toml
[[appRules]]
bundleId = "com.apple.Safari"
id = "81426D13-C1A5-475E-AFBC-00BBA05042D0"
minHeight = 220.0
minWidth = 574.0
```

## Per-monitor overrides

Six arrays hold per-monitor exceptions to the global tables. Every entry identifies its monitor with `monitorName` (required) plus optional `monitorDisplayUUID` and `monitorDisplayId`; all entries except orientation and routing also carry an `id` UUID. Override keys are all optional — an omitted key falls back to the corresponding global setting. All six arrays default to empty.

| Array | Overridable keys |
| --- | --- |
| `monitorBarOverrides` | `enabled`, `showLabels`, `showFloatingWindows`, `deduplicateAppIcons`, `hideEmptyWorkspaces`, `reserveLayoutSpace`, `notchMode`, `notchActiveZoneWidth`, `position`, `windowLevel`, `height`, `backgroundOpacity`, `xOffset`, `yOffset` — see [`workspaceBar`](#workspacebar) |
| `monitorOrientationOverrides` | `orientation`: `horizontal` or `vertical` layout orientation for that monitor |
| `monitorNiriOverrides` | `visibleContainerCount`, `centerFocusedColumn`, `alwaysCenterSingleColumn`, `singleWindowFit`, `infiniteLoop` — see [`niri`](#niri) |
| `monitorDwindleOverrides` | `smartSplit`, `defaultSplitRatio`, `splitWidthMultiplier`, `singleWindowFit`, `useGlobalGaps`, `innerGap` — see [`dwindle`](#dwindle) |
| `monitorGapOverrides` | `innerGap`, `outerGapLeft`, `outerGapRight`, `outerGapTop`, `outerGapBottom`, `fullscreenUsesOuterGaps` — see [`gaps`](#gaps) |
| `monitorRoutingOverrides` | `gridColumn`, `gridRow` (both required integers): the monitor's cell in the custom routing grid used when [`routing.mode`](#routing) is `custom` |

```toml
[[monitorGapOverrides]]
id = "0B54A3C1-6E1B-4D5B-9A64-2F0D8A11C001"
innerGap = 8.0
monitorName = "DELL U2720Q"
outerGapTop = 4.0

[[monitorRoutingOverrides]]
gridColumn = 1
gridRow = 0
monitorName = "DELL U2720Q"
```

These are most easily managed from **Settings > Monitors** and the per-layout tabs, which record the display's UUID automatically so the override survives display reconnects.
