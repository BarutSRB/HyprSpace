---
title: Window & Workspace Actions
description: Operate on specific windows by opaque ID and manage workspaces by name, including cross-monitor moves.
sidebar:
  order: 4
---

## Window Actions

Operate on specific windows by their session-scoped opaque ID.

```
omniwmctl window <action> <opaque-id>
omniwmctl window move-to-workspace <opaque-id> <workspace>
```

| Action | Description |
|--------|-------------|
| `focus` | Focus a managed window by opaque ID |
| `navigate` | Navigate to a managed window (switches workspace if needed) |
| `summon-right` | Summon a window to the right of the currently focused window |
| `close` | Close a managed window through its close button; returns `window_action_failed` when the window has no close button or refuses the press. The window leaves the managed set only when macOS reports it destroyed |
| `move-to-workspace` | Move a window to a workspace by raw workspace ID or unambiguous display name. Focus stays where it is; if the window is the focused one, the configured follow-focus behavior applies. A window already on the target returns `no_change`; an ambiguous display name returns `invalid_arguments` |

Window IDs are session-scoped. They become stale after OmniWM restarts. Obtain IDs from query results (e.g., `omniwmctl query windows`).

---

## Workspace Actions

```
omniwmctl workspace focus-name <name>
omniwmctl workspace move-to-monitor <workspace> <left|right|up|down> [--force]
omniwmctl workspace rename <workspace> <display-name>
```

| Action | Arguments | Description |
|--------|-----------|-------------|
| `focus-name` | `<name>` | Focus a workspace by raw workspace ID or unambiguous configured display name |
| `move-to-monitor` | `<workspace> <left\|right\|up\|down> [--force]` | Move a workspace to an adjacent monitor |
| `rename` | `<workspace> <display-name>` | Set or clear the workspace display name; an empty name restores the raw workspace ID. Returns `no_change` when the label already matches |

Numeric inputs are resolved as raw workspace IDs first. Display-name lookup is a convenience path and fails when multiple workspaces share the same display name. A display name containing a newline is rejected with `invalid_arguments`, and a name starting with `--` cannot be set from the CLI.

Monitor direction is resolved relative to the named workspace's current monitor. Moving a visible workspace transfers its visibility to the destination monitor, and the source monitor selects another eligible workspace. Moving an inactive workspace normally makes it visible on the destination while leaving the source monitor's visible workspace unchanged. If the destination's visible workspace is the current interaction workspace, the moved workspace is assigned there but remains inactive, preserving that interaction instead of replacing it. This action does not swap the two visible workspaces.

If the moved workspace owns the exact focused managed-window token and no incompatible focus transition is pending, that token follows the workspace without a new AX focus request. Otherwise, OmniWM preserves the interaction monitor and any non-managed focus. OmniWM rejects the move when native-fullscreen, macOS-hidden app, scratchpad, or pending focus state cannot be transferred safely.

Configured monitor assignment remains enforced unless `--force` is present. A forced move changes runtime placement without rewriting the workspace's persisted monitor configuration. The override lasts for the current OmniWM process and survives a transient disconnect and reconnect of the same output ID. It clears when the workspace returns to its configured home monitor, when configuration is reapplied, or when OmniWM restarts. If native fullscreen, a macOS-hidden app, a visible scratchpad, or an in-flight managed-focus transition makes rehoming unsafe, configuration reapply defers the clear until that state resolves. Configured workspace restore snapshots continue to prefer the Home Monitor. The flag may appear anywhere after `move-to-monitor`, although help and completion render the canonical trailing form.
