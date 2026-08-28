---
title: Queries
description: Query OmniWM windows, workspaces, displays, and registries with selectors and field projection.
sidebar:
  order: 3
---

```
omniwmctl query <name> [selectors...] [--fields <field1,field2,...>] [--format json|table|tsv|text]
```

Default output format for queries is `json`.

## Query Selectors

Selectors filter query results. Value selectors take an argument; boolean selectors are flags.

**Value selectors:**

| Selector | Description |
|----------|-------------|
| `--window <id>` | Filter by session-scoped opaque window ID |
| `--workspace <name>` | Filter by workspace raw name, display name, or ID |
| `--display <name>` | Filter by display name or display ID |
| `--app <name>` | Filter by application display name |
| `--bundle-id <id>` | Filter by application bundle identifier |

**Boolean selectors:**

| Selector | Description |
|----------|-------------|
| `--focused` | Only the focused item |
| `--visible` | Only visible items; windows also require a visible workspace, no window hidden state, and an app that is not hidden |
| `--floating` | Only floating windows |
| `--scratchpad` | Only windows assigned to a scratchpad |
| `--current` | Only the current/interaction item |
| `--main` | Only the main display |

## Query Fields

Use `--fields` with a comma-separated list to limit returned fields.

Field tokens are part of the CLI contract. Returned JSON still uses the payload schema's field names, so the selected token may not be byte-for-byte identical to the JSON key. For example, `window-counts` selects the workspace payload's `counts` field.

**Window fields:** `id`, `pid`, `workspace`, `display`, `app`, `title`, `frame`, `mode`, `layout-reason`, `manual-override`, `is-focused`, `is-visible`, `is-app-hidden`, `is-scratchpad`, `scratchpad-index`, `hidden-reason`

For windows, `is-visible` is true only when the workspace is visible, the window has no `hidden-reason`, and its macOS application is not hidden. `is-app-hidden` exposes the PID-scoped macOS hide state independently of `layout-reason` and `hidden-reason`; selecting `is-app-hidden` returns the JSON field `isAppHidden`.

**Workspace fields:** `id`, `raw-name`, `display-name`, `number`, `layout`, `display`, `is-focused`, `is-visible`, `is-current`, `window-counts`, `focused-window-id`

**Display fields:** `id`, `name`, `is-main`, `is-current`, `frame`, `visible-frame`, `has-notch`, `orientation`, `inner-gap`, `outer-gap-left`, `outer-gap-right`, `outer-gap-top`, `outer-gap-bottom`, `fullscreen-uses-outer-gaps`, `active-workspace`

`fullscreen-uses-outer-gaps` reports the resolved per-display policy used by OmniWM Full Screen, Niri maximized, and the Single Window “Full Screen” fit. It does not affect native macOS Full Screen.

## Query Reference

| Query | Selectors | Fields | Description |
|-------|-----------|--------|-------------|
| `workspace-bar` | — | — | Workspace bar projection for every monitor |
| `active-workspace` | — | — | Current interaction monitor and active workspace |
| `focused-monitor` | — | — | Current interaction monitor and its active workspace |
| `apps` | — | — | Managed app summary |
| `focused-window` | — | — | Focused managed window snapshot |
| `windows` | `--window`, `--workspace`, `--display`, `--focused`, `--visible`, `--floating`, `--scratchpad`, `--app`, `--bundle-id` | window fields | Managed windows |
| `workspaces` | `--workspace`, `--display`, `--current`, `--visible`, `--focused` | workspace fields | Configured workspaces with occupancy |
| `displays` | `--display`, `--main`, `--current` | display fields | Connected displays with geometry |
| `rules` | — | — | Persisted user window rules |
| `rule-actions` | — | — | Rule action registry |
| `queries` | — | — | Query registry |
| `commands` | — | — | Automation action registry for `command`, `workspace`, and `window` surfaces |
| `subscriptions` | — | — | Subscription registry |
| `capabilities` | — | — | Full protocol capabilities |

**Examples:**

```bash
# List all windows on workspace 1
omniwmctl query windows --workspace 1

# Get focused window in table format
omniwmctl query focused-window --format table

# List visible floating windows, only return id and title
omniwmctl query windows --visible --floating --fields id,title

# Get the active workspace on the current interaction monitor
omniwmctl query workspaces --current

# Check server capabilities
omniwmctl query capabilities
```
