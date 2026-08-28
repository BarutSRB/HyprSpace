---
title: Keyboard Shortcuts
description: Every default OmniWM hotkey, the Shared/Niri/Dwindle layout legend, and how the Hyper modifier works.
sidebar:
  order: 5
---

## Customization and the Hyper modifier

All shortcuts are customizable in **Settings > Hotkeys**. `Hyper` is the literal `Control + Option + Shift + Command` chord by default; which modifiers make up `Hyper` is configurable in Settings > Hotkeys (for example, exclude `Shift` to keep `Hyper + Shift + …` free for extra bindings). Changing the combination retargets every shortcut that currently resolves to `Hyper` onto the new one, so the shortcut list updates in place as you toggle the modifiers.

Optionally pick a **System Hyper Trigger** — a single key (Caps Lock, F13–F20, or a left- or right-side modifier) or an extra mouse button that acts as `Hyper` while held (this needs the Input Monitoring permission). Leave the trigger as `None` if you already produce `Hyper` another way, such as a Karabiner Elements remap.

Settings hides advanced actions from the shortcut list by default. Turn on `Include Advanced Commands` in Settings > Hotkeys to see and bind them; the tables below include both standard and advanced actions.

## Layout legend

- `Shared` works in any active layout.
- `Niri` works only when the active workspace uses the Niri layout.
- `Dwindle` works only when the active workspace uses the Dwindle layout.

## Workspace

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Switch to Workspace 1-9 | `Option + 1-9` | `Shared` |
| Move Window to Workspace 1-9 | `Option + Shift + 1-9` | `Shared` |
| Switch to Last Active Workspace (Back and Forth) | `Control + Option + Tab` | `Shared` |
| Switch to Next Workspace | `Unassigned` | `Shared` |
| Switch to Previous Workspace (Sequential) | `Unassigned` | `Shared` |
| Move Window to Workspace Up | `Control + Option + Shift + Up Arrow` | `Shared` |
| Move Window to Workspace Down | `Control + Option + Shift + Down Arrow` | `Shared` |
| Move Column to Workspace 1-9 | `Unassigned` | `Niri` |
| Move Column to Workspace Up | `Control + Option + Shift + Page Up` | `Niri` |
| Move Column to Workspace Down | `Control + Option + Shift + Page Down` | `Niri` |

## Focus

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Focus Left / Right / Up / Down | `Option + Arrow Keys` | `Shared` |
| Focus Down or Top / Up or Bottom | `Unassigned` | `Shared` |
| Focus Top Window / Bottom Window | `Unassigned` | `Niri` |
| Focus Window or Workspace Down / Up | `Unassigned` | `Niri` |
| Focus Previous Window | `Option + Tab` | `Shared` |
| Traverse Backward | `Unassigned` | `Niri` |
| Traverse Forward | `Unassigned` | `Niri` |
| Focus First Column | `Option + Home` | `Niri` |
| Focus Last Column | `Option + End` | `Niri` |
| Focus Column 1-9 | `Control + Option + 1-9` | `Niri` |
| Focus Window 1-9 in Column | `Unassigned` | `Niri` |
| Toggle Command Palette | `Control + Option + Space` | `Shared` |
| Open Menu Anywhere | `Control + Option + M` | `Shared` |
| Toggle Workspace Bar | `Unassigned` | `Shared` |
| Toggle Hidden Icons Bar | `Unassigned` | `Shared` |
| Toggle Quake Terminal | `` Option + ` `` | `Shared` |
| Toggle Overview | `Option + Shift + O` | `Shared` |
| Toggle System Stats | `Unassigned` | `Shared` |

## Move Window

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Move Left / Right / Up / Down | `Option + Shift + Arrow Keys` | `Shared` |
| Reorder Window Up / Down | `Unassigned` | `Shared` |
| Move Window Down or to Workspace Down / Up or to Workspace Up | `Unassigned` | `Niri` |
| Consume Window into Column / Expel Window from Column | `Unassigned` | `Niri` |

## Monitor

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Focus Next Monitor | `Control + Command + Tab` | `Shared` |
| Focus Previous Monitor | `Unassigned` | `Shared` |
| Focus Last Monitor | `` Control + Command + ` `` | `Shared` |
| Move Workspace to Left / Right / Up / Down Monitor | `Unassigned` | `Shared` |
| Move Window to Left / Right / Up / Down Monitor | `Unassigned` | `Shared` |

The workspace-to-monitor actions target the active workspace and intentionally use the same temporary runtime override as `omniwmctl workspace move-to-monitor --force`. They do not rewrite the workspace's Home Monitor or swap workspaces, and unsafe fullscreen, hidden-app, scratchpad, or focus states still block the move.

The window-to-monitor actions send the focused window directly to the current workspace on the adjacent routed display, independently of **Move Window Across Monitor at Edge**. They do not wrap when no monitor exists in that direction. **Follow Window to Monitor** controls whether focus follows the window; when it is off, you remain in the source workspace.

## Layout

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Toggle Fullscreen | `Option + Return` | `Shared` |
| Toggle Native Fullscreen | `Unassigned` | `Shared` |
| Balance Sizes | `Option + Shift + B` | `Shared` |
| Cycle Size Forward | `Option + .` | `Shared` |
| Cycle Size Backward | `Option + ,` | `Shared` |
| Move to Root | `Unassigned` | `Dwindle` |
| Toggle Split | `Unassigned` | `Dwindle` |
| Swap Split | `Unassigned` | `Dwindle` |
| Grow Horizontally / Vertically | `Unassigned` | `Dwindle` |
| Shrink Horizontally / Vertically | `Unassigned` | `Dwindle` |
| Grow / Shrink Focused Window | `Unassigned` | `Dwindle` |
| Preselect Left / Right / Up / Down | `Unassigned` | `Dwindle` |
| Clear Preselection | `Unassigned` | `Dwindle` |
| Raise All Floating Windows | `Option + Shift + R` | `Shared` |
| Rescue Off-Screen Floating Windows | `Unassigned` | `Shared` |
| Toggle Focused Window Floating | `Unassigned` | `Shared` |
| Assign Focused Window to Scratchpad 1-10 | `Unassigned` | `Shared` |
| Toggle Scratchpad 1-10 | `Unassigned` | `Shared` |
| Toggle Workspace Layout | `Option + Shift + L` | `Shared` |

## Container and Column

| Action | Default Shortcut | Layout |
|--------|------------------|--------|
| Move Container Left / Right | `Control + Option + Shift + Left / Right Arrow` | `Shared` |
| Move Container Up / Down | `Unassigned` | `Dwindle` |
| Toggle Column Tabbed | `Option + T` | `Niri` |
| Toggle Container Full Primary Span | `Option + Shift + F` | `Niri` |
| Expand Container to Available Primary Span | `Control + Option + F` | `Niri` |
| Move Column to First / Last | `Control + Option + Home / End` | `Niri` |
| Move Column to Index 1-9 | `Unassigned` | `Niri` |
| Set Container Primary Span -10% / +10% | `Option + -` / `Option + =` | `Niri` |
| Set Window Secondary Span -10% / +10% | `Option + Shift + -` / `Option + Shift + =` | `Niri` |
| Set Window Primary Span -10% / +10% | `Unassigned` | `Niri` |
| Reset Window Secondary Span | `Control + Option + R` | `Niri` |
| Cycle Window Primary Span Forward / Backward | `Unassigned` | `Niri` |
| Cycle Window Secondary Span Forward / Backward | `Unassigned` | `Niri` |
| Center Column | `Unassigned` | `Niri` |
| Center Visible Columns | `Unassigned` | `Niri` |

`Consume or Expel Window Left / Right` exist as automation-only actions. They are reachable from `omniwmctl` but never appear in Settings > Hotkeys, because they intentionally cannot be bound to a shortcut.

The daily `Focus` and `Move` shortcuts adapt to the active layout and Niri orientation. In horizontal Niri orientation, `Move Left / Right` consumes or expels across columns while `Move Up / Down` reorders within a column. Vertical orientation rotates those roles: `Move Up / Down` consumes or expels across rows while `Move Left / Right` reorders within a row.

## Dwindle Groups

Dwindle groups use the existing Focus and Move bindings, so there are no separate group shortcuts to memorize. Only the active member occupies the tile; the other members stay hidden and the clickable tab rail shows their order.

| Goal | Default Shortcut | Behavior |
|------|------------------|----------|
| Focus another tile | `Option + Arrow Keys` | Left / Right are always spatial. Up / Down are spatial for a singleton tile. |
| Select the next / previous tab | `Option + Down / Up Arrow` | Within a group, Down advances and Up goes back. At the group edge OmniWM tries a spatial tile, then the configured monitor transition, and wraps locally only when neither exit succeeds. |
| Join a singleton into a tile or group | `Option + Shift + Arrow Keys` | Joins the focused singleton with the touching tile in that direction. |
| Extract the active tab | `Option + Shift + Arrow Keys` | When the focused tile is grouped, extracts only its active tab onto the requested side. |
| Move the complete tile or group | `Control + Option + Shift + Left / Right Arrow` | `Move Container` swaps the whole structure. Up / Down are advanced, unassigned Dwindle actions. |
| Select an exact tab | Click its tab rail item | Reveals and focuses that member without changing the group order. |

Moving a tab directly from one existing group into another is intentionally a two-step operation: extract it first, then move the resulting singleton toward the destination group. A singleton at a genuine workspace edge can still use the normal cross-monitor Move behavior; a rejected group mutation does not fall through to tile swapping or monitor movement.

The unassigned advanced actions are available in Settings > Hotkeys. `Focus Down or Top / Up or Bottom` always wraps within the active Niri column or Dwindle group. `Reorder Window Up / Down` changes the active member's position by one without wrapping. `Move Container` is the whole-structure escape hatch and never transfers to another monitor at a workspace edge. Dwindle join/extract and Move Container operations are intentionally unavailable while Overview is open; leave Overview before changing a Dwindle tree.

## Quake Terminal (Inside Terminal)

These shortcuts work inside the [Quake Terminal](/features/quake-terminal/) itself:

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
