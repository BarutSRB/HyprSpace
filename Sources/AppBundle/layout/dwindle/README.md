# Dwindle Layout Resize Implementation

This directory contains the implementation of resizing for HyprSpace's dwindle layout, inspired by Hyprland's dwindle resize mechanism.

## Architecture Overview

The dwindle resize system uses a **persistent binary tree cache** that mirrors Hyprland's `SDwindleNodeData` structure. This approach provides:

- **Clean separation**: Layout-specific state lives in `DwindleLayoutCache`, not polluted into `TreeNode`
- **Persistent structure**: Split ratios survive across layout recalculations
- **Fresh geometry**: The "layout → resize → layout" pattern prevents stale cached values
- **Minimal changes**: Integration requires only small modifications to existing commands

## Files

### DwindleNode.swift
Defines the binary tree node structure with:
- `parent`/`children` pointers for tree traversal
- `splitRatio` (default 1.0 for 50/50 split)
- `splitVertically` flag (orientation determined by aspect ratio)
- `box` (current geometry, updated during layout passes)

### DwindleLayoutCache.swift
Main cache implementation providing:
- **Cache management**: Automatic rebuild detection when windows change
- **Layout calculation**: Traverses binary tree applying split ratios
- **Resize operations**: Smart and standard resize modes
- **Split orientation**: Dynamic determination based on available space (future-ready for `split_width_multiplier`)

## How It Works

### 1. Cache Lifecycle

The cache is created on-demand and stored in `TilingContainer.userData`:

```swift
var dwindleCache: DwindleLayoutCache {
    // Gets or creates cache
}
```

Cache rebuilds when:
- Window count changes (add/remove)
- Window IDs change (detected via comparison)

Cache invalidates when:
- Switching away from dwindle layout
- Calling `normalizeContainers()`

### 2. Layout Pass

When `layoutDwindle()` is called:

```swift
1. Get or create cache
2. Check if rebuild needed (compare window IDs)
3. If needed: rebuild binary tree from flat children list
4. Traverse tree applying split ratios to calculate geometry
5. Update each node's box with fresh rect
6. Apply geometry to actual windows via setAxFrame
```

**Key insight:** The layout pass updates all `node.box` values with current geometry, ensuring resize operations always use fresh sizes.

### 3. Resize Operation

When resize is triggered (keyboard or mouse):

```swift
1. Find DwindleNode for target window
2. Detect edge constraints (can't resize if touching workspace edge)
3. Find controlling parents for horizontal/vertical axes
4. Calculate ratio delta: 2.0 * pixels / containerSize
5. Update split ratios (clamped to [0.1, 1.9])
6. Trigger layout recalculation (via refreshModel)
```

**Key pattern:** Always use `node.box.width/height` which were just updated in the last layout pass.

### 4. Resize Modes

#### Smart Resizing (default, `smartResizing = true`)
Mirrors Hyprland's DwindleLayout.cpp:725-782:
- Detects which corner/edge is being resized
- Finds "outer" nodes to grow/shrink
- Finds "inner" nodes for compensation
- Applies proportional changes to maintain layout balance

#### Standard Resizing (`smartResizing = false`)
Mirrors Hyprland's DwindleLayout.cpp:784-840:
- Finds parent controlling horizontal direction
- Finds parent controlling vertical direction
- Adjusts their split ratios directly

## Integration Points

### Commands

**ResizeCommand** (`Sources/AppBundle/command/impl/ResizeCommand.swift`):
```swift
if parent.layout == .dwindle {
    cache.resize(window: node, delta: delta)
    // Layout refreshed automatically
    return true
}
```

**resizeWithMouse** (`Sources/AppBundle/mouse/resizeWithMouse.swift`):
```swift
if parent.layout == .dwindle {
    let delta = Vector2D(x: orientation == .h ? diff : 0, y: orientation == .v ? diff : 0)
    cache.resize(window: window, delta: delta)
    continue
}
```

**BalanceSizesCommand** (`Sources/AppBundle/command/impl/BalanceSizesCommand.swift`):
```swift
if parent.layout == .dwindle {
    parent.dwindleCache.resetAllRatios()  // Resets to 50/50
}
```

**LayoutCommand** (`Sources/AppBundle/command/impl/LayoutCommand.swift`):
```swift
if parent.layout == .dwindle && targetLayout != .dwindle {
    parent.invalidateDwindleCache()  // Clean up when switching away
}
```

## Split Ratio Math

### Hyprland's Formula
```cpp
splitRatio ∈ [0.1, 1.9]  // default 1.0
childA_size = container_size * (splitRatio / (splitRatio + 1))
childB_size = container_size * (1 / (splitRatio + 1))
```

### Pixel Delta Conversion
```swift
ratio_delta = 2.0 * pixel_delta / container_size
```

### Example
```
Container width: 1000px
Current splitRatio: 1.0 (50/50)
Resize +50px:
  New ratio: 1.0 + (2.0 * 50 / 1000) = 1.1
  Child A: 1000 * (1.1 / 2.1) ≈ 524px
  Child B: 1000 * (1.0 / 2.1) ≈ 476px
```

## Future Enhancements

The architecture is **future-ready** for Hyprland's advanced features:

1. **split_width_multiplier**: Bias split orientation towards vertical/horizontal
   - Implemented in `determineSplitOrientation()`
   - Currently uses aspect ratio, can add multiplier easily

2. **smart_split**: More intelligent split direction selection
   - Hook exists in `determineSplitOrientation()`
   - Can add heuristics based on window count, user preference, etc.

3. **User overrides**: Per-workspace or per-window split preferences
   - Can extend `DwindleNode` with override flags
   - Can store in `TreeNode.userData`

4. **Pseudotile support**: Windows with fixed size within tile
   - Not implemented (dwindle is tiling-only for now)
   - Could extend with `m_pseudoSize` like Hyprland

## Testing

### Manual Testing
```bash
# Build and run
./build-debug.sh && ./run-debug.sh

# Test keyboard resize
aerospace resize width +50   # Should grow window right
aerospace resize width -50   # Should shrink window right
aerospace resize height +50  # Should grow window down

# Test mouse resize
# Drag window edges with mouse - should resize smoothly

# Test balance
aerospace balance-sizes      # Should reset all splits to 50/50
```

### Expected Behavior
- ✅ Keyboard resize works in all 4 directions
- ✅ Mouse resize works with drag
- ✅ Edge-constrained windows don't resize in constrained axes
- ✅ Split ratios persist across layout recalculations
- ✅ Balance-sizes resets ratios to 1.0
- ✅ Existing layouts remain 50/50 until manually resized

## Troubleshooting

### Ratios not persisting
- Check cache isn't being invalidated unexpectedly
- Verify `needsRebuild()` isn't triggering on every layout

### Resize feels unresponsive
- Check scale factor in `ResizeCommand.swift` (currently `diff * 10`)
- Adjust for more/less sensitivity

### Geometry drift over time
- Ensure `node.box` is always updated in `layoutRecursive()`
- Verify no stale cached sizes are being used

## References

- Hyprland's DwindleLayout.cpp: [GitHub Link](https://github.com/hyprwm/Hyprland/blob/main/src/layout/DwindleLayout.cpp)
- `/Dwindle/RESIZE_MECHANISM.md`: Detailed algorithm documentation
- AeroSpace fork documentation: Main README.md

## Design Decisions

### Why a separate binary tree?
The existing `TreeNode` structure is flat (children array) and shared across all layout types. Dwindle needs:
- Explicit parent/child pointers for tree walking
- Per-split ratios (not per-window)
- Split orientation per container

A dedicated cache avoids polluting TreeNode with dwindle-specific state.

### Why not use adaptiveWeight?
The existing weight system is orientation-specific and works well for tiles layout. Dwindle:
- Alternates orientation per level
- Needs binary splits (not flat distribution)
- Uses different ratio formula (Hyprland's vs HyprSpace's weights)

Using a separate `splitRatio` keeps the implementations independent.

### Why rebuild the tree on window changes?
Alternative approaches (incremental updates) are complex and error-prone. Full rebuild:
- Simple and reliable
- Fast enough (O(n) where n = window count)
- Only happens when windows added/removed (rare)
