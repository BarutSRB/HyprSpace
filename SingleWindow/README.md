# Single Window Aspect Ratio Feature

## Overview

The `single_window_aspect_ratio` feature in Hyprland's dwindle layout enforces a specific aspect ratio for windows when only a single window is present on a workspace. This is useful for maintaining optimal viewing dimensions for applications, preventing overly wide or tall windows on large or ultrawide monitors.

## Purpose

When you have a single window on a workspace, it normally fills the entire available screen space. On ultrawide monitors (21:9, 32:9) or vertical monitors, this can create uncomfortably wide or tall windows. This feature adds padding to maintain your preferred aspect ratio while keeping the window centered.

## Configuration Options

### `dwindle:single_window_aspect_ratio`

**Type:** Vector (x, y)
**Default:** `0 0` (disabled)
**Range:** `0-1000` for both x and y values

Specifies the desired aspect ratio as a 2D vector. The feature is disabled when the y-value is 0.

**Common Aspect Ratios:**
- `16 9` - Standard widescreen (1920x1080, 2560x1440)
- `4 3` - Traditional monitor (1024x768, 1600x1200)
- `21 9` - Ultrawide (2560x1080, 3440x1440)
- `16 10` - Common laptop (1920x1200)
- `1 1` - Square window

### `dwindle:single_window_aspect_ratio_tolerance`

**Type:** Float
**Default:** `0.1` (10%)
**Range:** `0.0-1.0`

Defines the minimum padding (as a fraction of the monitor dimension) required before the aspect ratio enforcement activates. This prevents tiny adjustments when the monitor's natural ratio is already close to the requested ratio.

**Example:** With tolerance `0.1`:
- A 1920x1080 monitor (1080px height) won't apply vertical padding less than 108px
- A 2560x1440 monitor (2560px width) won't apply horizontal padding less than 256px

## How It Works

### Activation Conditions

The feature only activates when:
1. **y-value is non-zero**: `single_window_aspect_ratio.y != 0`
2. **Single window present**: The window has no parent node in the tree (`!pNode->pParent`)
3. **Padding exceeds tolerance**: The calculated padding meets the tolerance threshold

### Algorithm Walkthrough

1. **Calculate available space:**
   ```
   availableSize = monitorSize - reservedTopLeft - reservedBottomRight
   ```

2. **Calculate aspect ratios:**
   ```
   requestedRatio = x / y
   monitorRatio = availableWidth / availableHeight
   ```

3. **Determine padding direction:**
   - If `requestedRatio > monitorRatio`: Monitor is taller → add **vertical** padding
   - If `requestedRatio < monitorRatio`: Monitor is wider → add **horizontal** padding
   - If ratios match: No padding needed

4. **Calculate padding amount:**
   - **Vertical padding:** `availableHeight - (availableWidth / requestedRatio)`
   - **Horizontal padding:** `availableWidth - (availableHeight * requestedRatio)`

5. **Apply tolerance check:**
   - Only apply if `padding / 2 > tolerance * dimension`

6. **Center the window:**
   - Position: `originalPosition + (padding / 2)`
   - Size: `originalSize - padding`

### Visual Example

#### Before (No aspect ratio enforcement):
```
┌────────────────────────────────────────────────────┐
│                                                    │
│                                                    │
│                                                    │
│              WINDOW (fills screen)                │
│                                                    │
│                                                    │
│                                                    │
└────────────────────────────────────────────────────┘
Monitor: 2560x1440 (16:9)
Window:  2560x1440 (16:9) - Full screen
```

#### After (4:3 aspect ratio enforced):
```
┌────────────────────────────────────────────────────┐
│                                                    │
│        ┌──────────────────────────────┐           │
│        │                              │           │
│        │    WINDOW (4:3 ratio)        │           │
│        │                              │           │
│        └──────────────────────────────┘           │
│                                                    │
└────────────────────────────────────────────────────┘
Monitor: 2560x1440 (16:9)
Window:  1920x1440 (4:3) - Centered with horizontal padding
```

#### Example: Ultrawide monitor with 16:9 window
```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│            ┌────────────────────────────┐                        │
│            │                            │                        │
│            │   WINDOW (16:9 ratio)      │                        │
│            │                            │                        │
│            └────────────────────────────┘                        │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
Monitor: 3440x1440 (21:9)
Window:  2560x1440 (16:9) - Centered with horizontal padding
```

## Configuration Examples

### Example 1: Standard 16:9 ratio
```conf
dwindle {
    single_window_aspect_ratio = 16 9
    single_window_aspect_ratio_tolerance = 0.1
}
```
**Use case:** Maintain comfortable window size on ultrawide monitors

### Example 2: Classic 4:3 ratio
```conf
dwindle {
    single_window_aspect_ratio = 4 3
    single_window_aspect_ratio_tolerance = 0.05
}
```
**Use case:** Prefer more square windows for reading or coding

### Example 3: Ultrawide 21:9 ratio (disable on smaller monitors)
```conf
dwindle {
    single_window_aspect_ratio = 21 9
    single_window_aspect_ratio_tolerance = 0.15
}
```
**Use case:** Maximum width on ultrawide, no effect on standard monitors

### Example 4: Square windows (1:1)
```conf
dwindle {
    single_window_aspect_ratio = 1 1
    single_window_aspect_ratio_tolerance = 0.1
}
```
**Use case:** Perfect square for terminal windows or specific applications

### Example 5: Disabled (default)
```conf
dwindle {
    single_window_aspect_ratio = 0 0  # or omit entirely
}
```

## Tolerance Explained

The tolerance prevents the feature from making tiny adjustments that would be barely noticeable but consume computational resources.

### Tolerance Calculation

For vertical padding (monitor is taller):
```
if (padding / 2) > (tolerance * monitorHeight):
    apply padding
```

For horizontal padding (monitor is wider):
```
if (padding / 2) > (tolerance * monitorWidth):
    apply padding
```

### Tolerance Examples

Monitor: 1920x1080 (16:9)
Requested: 16:10
Tolerance: 0.1 (default)

```
Calculated vertical padding: ~108px total (54px per side)
Tolerance threshold: 0.1 * 1080 = 108px
Result: 54px < 108px → NO PADDING APPLIED (too small)
```

Monitor: 3440x1440 (21:9)
Requested: 16:9
Tolerance: 0.1 (default)

```
Calculated horizontal padding: ~880px total (440px per side)
Tolerance threshold: 0.1 * 3440 = 344px
Result: 440px > 344px → PADDING APPLIED
```

## Implementation Details

### Source Files

1. **DwindleLayout.cpp** (`src/layout/DwindleLayout.cpp:206-228`)
   - Contains the main implementation logic
   - Part of `CDwindleLayout::applyNodeDataToWindow()` function
   - See `DwindleLayout.cpp.snippet`

2. **ConfigManager.cpp** (`src/config/ConfigManager.cpp:629-630`)
   - Registers the configuration variables
   - Sets default values
   - See `ConfigManager.cpp.snippet`

3. **ConfigDescriptions.hpp** (`src/config/ConfigDescriptions.hpp:1871-1881`)
   - Provides user documentation
   - Defines validation rules and ranges
   - See `ConfigDescriptions.hpp.snippet`

### Integration Points

The feature integrates cleanly with existing window management:

1. **Gap system:** Padding is applied alongside gaps
   ```cpp
   calcPos  = calcPos + GAPOFFSETTOPLEFT + ratioPadding / 2;
   calcSize = calcSize - GAPOFFSETTOPLEFT - GAPOFFSETBOTTOMRIGHT - ratioPadding;
   ```

2. **Reserved monitor areas:** Respects menu bars, docks, and other reserved space
   ```cpp
   originalSize = PMONITOR->m_size - PMONITOR->m_reservedTopLeft - PMONITOR->m_reservedBottomRight;
   ```

3. **Pseudo-tiled windows:** Works alongside pseudo-tiled mode

4. **Window decorations:** Applied after window decoration updates

### Performance Considerations

- **Minimal overhead:** Only calculates when single window is present
- **Static config access:** Config values cached with `CConfigValue`
- **Early exit:** Returns immediately if y-value is 0 or window has parent
- **Tolerance threshold:** Prevents unnecessary layout updates for small differences

## Use Cases

### Ultrawide Monitor Users
Prevent single windows from becoming uncomfortably wide on 21:9 or 32:9 monitors.

```conf
dwindle {
    single_window_aspect_ratio = 16 9
}
```

### Reading and Documentation
Maintain comfortable reading width for documentation, articles, or code.

```conf
dwindle {
    single_window_aspect_ratio = 4 3
}
```

### Video Editing
Maintain native video aspect ratios in preview windows.

```conf
dwindle {
    single_window_aspect_ratio = 16 9  # or 21 9 for cinematic
}
```

### Terminal Work
Square or near-square windows for terminal multiplexers.

```conf
dwindle {
    single_window_aspect_ratio = 1 1
}
```

## Limitations

1. **Dwindle layout only:** Feature only works with the dwindle layout, not master or other layouts
2. **Single window only:** Deactivates as soon as a second window appears
3. **No per-workspace configuration:** Same ratio applies to all workspaces
4. **Static setting:** Cannot be changed per-application or dynamically

## Troubleshooting

### Feature not working?

**Check these conditions:**

1. **Is y-value non-zero?**
   ```conf
   single_window_aspect_ratio = 16 9  # ✓ Will work
   single_window_aspect_ratio = 16 0  # ✗ Will not work (y=0)
   single_window_aspect_ratio = 0 0   # ✗ Disabled
   ```

2. **Is there only one window?**
   - Feature deactivates with multiple windows
   - Check if hidden windows exist on the workspace

3. **Does padding exceed tolerance?**
   - Lower tolerance to be more aggressive: `0.05` or `0.01`
   - Default `0.1` may prevent activation on similar ratios

4. **Is the layout set to dwindle?**
   ```conf
   default-root-container-layout = 'dwindle'
   ```
   or use:
   ```
   hyprctl keyword general:layout dwindle
   ```

### Monitor already has the requested ratio?

If your monitor's native ratio matches the requested ratio, no padding will be applied. This is expected behavior.

Example:
- Monitor: 1920x1080 (16:9)
- Requested: 16:9
- Result: No padding (ratios already match)

### Padding seems wrong?

The feature respects reserved monitor areas (menu bars, docks). If you have large reserved areas, the effective ratio may differ from the monitor's physical ratio.

## Testing the Feature

1. **Set a dramatic ratio difference:**
   ```conf
   dwindle {
       single_window_aspect_ratio = 1 1  # Square
       single_window_aspect_ratio_tolerance = 0.01
   }
   ```

2. **Reload configuration:**
   ```bash
   hyprctl reload
   ```

3. **Open a single window on an empty workspace**

4. **Observe padding** - Window should be centered with equal padding on opposite sides

5. **Open a second window** - Padding should disappear and normal tiling should resume

## Related Configuration

This feature works well with other dwindle options:

```conf
dwindle {
    # Aspect ratio enforcement
    single_window_aspect_ratio = 16 9
    single_window_aspect_ratio_tolerance = 0.1

    # Other dwindle settings
    preserve_split = true
    smart_split = false
    smart_resizing = true

    # Gaps (applied in addition to aspect ratio padding)
    # Note: Set via general:gaps_in and general:gaps_out
}

general {
    gaps_in = 5
    gaps_out = 10
}
```

## Mathematical Formula

For those interested in the exact calculations:

```
Given:
  R_requested = x / y
  R_monitor = width / height

If R_requested > R_monitor (monitor is relatively taller):
  padding_vertical = height - (width / R_requested)
  if (padding_vertical / 2) > (tolerance * height):
    apply vertical padding

If R_requested < R_monitor (monitor is relatively wider):
  padding_horizontal = width - (height * R_requested)
  if (padding_horizontal / 2) > (tolerance * width):
    apply horizontal padding

Final window dimensions:
  x_position = original_x + gaps_left + (padding_horizontal / 2)
  y_position = original_y + gaps_top + (padding_vertical / 2)
  width = original_width - gaps_left - gaps_right - padding_horizontal
  height = original_height - gaps_top - gaps_bottom - padding_vertical
```

## Contributing

If you find issues or have suggestions for this feature:

1. Check if the issue exists in the latest version
2. Verify your configuration is correct
3. Report issues to the Hyprland repository with:
   - Your configuration
   - Monitor dimensions
   - Expected vs actual behavior
   - Screenshots if applicable

## Version Information

This feature was added to Hyprland in the dwindle layout implementation.

**Configuration variables:**
- `dwindle:single_window_aspect_ratio` - Vector (x, y)
- `dwindle:single_window_aspect_ratio_tolerance` - Float

**Source files:**
- Implementation: `src/layout/DwindleLayout.cpp`
- Configuration: `src/config/ConfigManager.cpp`
- Documentation: `src/config/ConfigDescriptions.hpp`
