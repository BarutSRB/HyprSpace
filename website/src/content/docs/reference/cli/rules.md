---
title: Rules
description: Manage persisted window rules that control layout behavior, workspace placement, and initial Niri container span.
sidebar:
  order: 5
---

Manage persisted window rules that control layout behavior, default workspace placement, and the initial Niri
container primary span for matching windows. Primary span is width in horizontal orientation and height in
vertical orientation.
Rule add, replace, and config reload trigger automatic reevaluation. A valid workspace assignment applies as
the initial default whenever the matching app currently has no tracked windows. Additional windows use the
workspace active when creation began. Automatic reevaluation preserves existing managed windows' workspaces, while
readmission, structural replacements, and unique persisted boot-restore matches
preserve placement continuity. `rule apply` is the explicit path that may move existing managed windows.
Initial container primary span is a one-shot Niri admission hint and never resizes an existing container.

```
omniwmctl rule <action> [arguments...] [options...]
```

## Rule Options

| Option | Value | Description |
|--------|-------|-------------|
| `--bundle-id` | `<bundle-id>` | Application bundle identifier. Optional: omit it to match apps with no runtime bundle ID, but then supply at least one of `--app-name-substring` / `--title-substring` / `--title-regex` |
| `--app-name-substring` | `<text>` | Match app name containing this substring |
| `--title-substring` | `<text>` | Match window title containing this substring |
| `--title-regex` | `<pattern>` | Match window title against this regex |
| `--ax-role` | `<role>` | Match accessibility role |
| `--ax-subrole` | `<subrole>` | Match accessibility subrole |
| `--layout` | `<auto\|tile\|float>` | Layout action (`auto` = default behavior) |
| `--assign-to-workspace` | `<raw-name>` | Use this workspace as the initial default whenever the matching app currently has no tracked windows |
| `--initial-container-primary-span` | `<proportion>` | Initial Niri container primary span for a resizable window, from `0.05` through `1.0` inclusive |
| `--min-width` | `<points>` | Minimum window width in points |
| `--min-height` | `<points>` | Minimum window height in points |

When supplied, bundle IDs must match the pattern: `^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$`. Every rule needs
at least one identifier — a bundle ID, app-name substring, or title (substring/regex). The bundle ID is
the app's *runtime* identifier (`NSRunningApplication.bundleIdentifier`); apps without one (e.g. ad-hoc
or wrapper apps) are matched by app name and/or title. AX role/subrole refine an existing match but cannot
identify a rule on their own. Title substring and title regex are mutually exclusive, and a supplied regex
must compile. Every rule also needs at least one effect: a layout other than `auto`, a workspace assignment,
an initial container primary span, or a minimum width or height. Minimum sizes must be positive and finite.

## Structural Admission

Structural admission runs before ordinary rule matching. Help tags, input-method surfaces, and WindowServer
children of another window stay unmanaged; rules cannot opt them in. At ordinary WindowServer levels, a
closeable, parentless accessory-app `AXWindow` proceeds through normal classification.

Buttonless accessory roots, prohibited-app roots, non-`AXWindow` roles, and otherwise unsupported AX subroles
need a precise inclusion rule: an ordinary app/window identifier, both `--ax-role` and `--ax-subrole`, and
`--layout tile` or `--layout float`. Parentless roots at status-window level or higher use the same precise
shape, but only a user-authored rule can opt them in. A broad bundle/title rule or `--layout auto` does not cross
either precise inclusion gate.

`initialContainerPrimarySpan` is stored and returned over IPC as a proportion. `omniwmctl query rules` renders
it as a percentage in human-readable table or text output. It applies only when a matching resizable window
creates or claims a new Niri container, and the user can resize that container afterward.

Niri's Single Window Fit policy retains precedence for a lone window, so it can visually mask the seeded
primary span. Physical minimum-size constraints can clamp the resolved span in pixels, but they do not rewrite
the stored `initialContainerPrimarySpan` proportion.

## Rule Actions

**Add a rule:**

```bash
omniwmctl rule add [options...]
```

Supply `--bundle-id` and/or at least one matcher (`--app-name-substring`, `--title-substring`, `--title-regex`). Appends a new rule to the end of the rule list. Its placement defaults apply whenever the matching app currently has no tracked windows; already managed windows are not moved.

**Replace a rule:**

```bash
omniwmctl rule replace <rule-id> [options...]
```

Replaces a rule in-place by its UUID (same identifier requirement as `add`). The rule ID is preserved. Already managed windows are not moved until rules are explicitly applied.

**Remove a rule:**

```bash
omniwmctl rule remove <rule-id>
```

Removes a rule by its UUID.

**Move a rule:**

```bash
omniwmctl rule move <rule-id> <position>
```

Moves a rule to a new one-based position in the rule list.

**Apply rules:**

```bash
omniwmctl rule apply [--focused | --window <opaque-id> | --pid <pid>]
```

Re-evaluates the current rule set against the target. Defaults to `--focused` if no target is specified. This is
the explicit path for applying ongoing rule effects to already managed windows; the one-shot initial container
primary-span hint is not reasserted on an existing container. Explicit application may move an existing window
to its valid assigned workspace.

| Target | Description |
|--------|-------------|
| `--focused` | Apply to the currently focused window (default) |
| `--window <id>` | Apply to a specific window by opaque ID |
| `--pid <pid>` | Apply to all managed windows for a process |

**Examples:**

```bash
# Float all Finder windows
omniwmctl rule add --bundle-id com.apple.finder --layout float

# Tile Safari's first newly admitted window on workspace 2 when Safari has no tracked windows
omniwmctl rule add --bundle-id com.apple.Safari --layout tile --assign-to-workspace 2

# Start new Kitty containers at 50% of the primary axis in Niri
omniwmctl rule add --bundle-id net.kovidgoyal.kitty --initial-container-primary-span 0.5

# Float windows with "Preferences" in the title
omniwmctl rule add --bundle-id com.apple.Safari --title-substring Preferences --layout float

# Float an app that has no runtime bundle ID, matched by app name
omniwmctl rule add --app-name-substring VMD --layout float

# Opt a parentless, high-level standard root into ownership and float it
omniwmctl rule add --bundle-id com.example.overlay --ax-role AXWindow --ax-subrole AXStandardWindow --layout float

# Remove a rule
omniwmctl rule remove 550e8400-e29b-41d4-a716-446655440000

# Explicitly reapply rules to all windows of a specific app
omniwmctl rule apply --pid 12345
```
