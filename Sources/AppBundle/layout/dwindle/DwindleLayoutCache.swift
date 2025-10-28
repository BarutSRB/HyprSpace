import Foundation
import AppKit
import Common

/// Manages the binary tree structure for dwindle layout and handles resize operations.
///
/// This cache provides persistent storage for the dwindle binary tree, maintaining
/// split ratios across layout recalculations. It mirrors Hyprland's approach with
/// `SDwindleNodeData` while integrating with HyprSpace's architecture.
///
/// The cache automatically rebuilds when windows are added/removed and maintains
/// fresh geometry data throughout resize operations using a "layout → resize → layout"
/// pattern to prevent stale cached values.
final class DwindleLayoutCache {
    // MARK: - Properties

    /// Root node of the binary tree
    private(set) var rootNode: DwindleNode?

    /// Cached window IDs for detecting when rebuild is needed
    private var cachedWindowIds: [CGWindowID] = []

    // MARK: - Configuration (Future-Ready)

    /// Enable smart resizing mode (Hyprland's smart_resizing)
    /// When true, uses edge/corner detection for intelligent resizing
    var smartResizing: Bool = true

    /// Split width multiplier for aspect ratio adjustment (Hyprland's dwindle:split_width_multiplier)
    /// Used to bias split orientation towards vertical or horizontal
    var splitWidthMultiplier: CGFloat = 1.0

    /// Enable smart split mode (Hyprland's dwindle:smart_split)
    /// Future enhancement for more intelligent split orientation selection
    var smartSplit: Bool = false

    // MARK: - Cache Management

    /// Checks if cache needs to be rebuilt due to window changes
    /// - Parameter windows: Current list of windows
    /// - Returns: True if window IDs have changed
    func needsRebuild(for windows: [TreeNode]) -> Bool {
        let currentIds = windows.compactMap { node -> CGWindowID? in
            if case .window(let window) = node.nodeCases {
                return window.windowId
            }
            return nil
        }
        return currentIds != cachedWindowIds
    }

    /// Rebuilds the binary tree from scratch
    /// - Parameters:
    ///   - windows: Flat list of windows to arrange
    ///   - availableRect: Available space for the tree
    func rebuild(from windows: [TreeNode], availableRect: CGRect) {
        rootNode = buildBinaryTree(windows, availableRect: availableRect)
        cachedWindowIds = windows.compactMap { node -> CGWindowID? in
            if case .window(let window) = node.nodeCases {
                return window.windowId
            }
            return nil
        }
    }

    /// Recursively builds the binary tree structure
    ///
    /// This mirrors Hyprland's tree construction but with dynamic split orientation
    /// based on available space rather than hardcoded depth alternation.
    ///
    /// - Parameters:
    ///   - windows: Windows to include in this subtree
    ///   - availableRect: Available space for this subtree
    /// - Returns: Root node of the subtree
    private func buildBinaryTree(_ windows: [TreeNode], availableRect: CGRect) -> DwindleNode? {
        guard !windows.isEmpty else { return nil }

        // Leaf node - single window
        if windows.count == 1 {
            return DwindleNode(window: windows[0])
        }

        // Container node - binary split
        let container = DwindleNode()
        container.splitRatio = 1.0  // Default 50/50 split

        // Determine split orientation based on available space
        // Future-ready: can incorporate split_width_multiplier, smart_split, user overrides
        container.splitVertically = determineSplitOrientation(
            availableRect: availableRect,
            windowCount: windows.count,
        )

        // Split children into two groups
        let midIndex = windows.count / 2

        // Calculate rects for children (for recursive split determination)
        let (leftRect, rightRect) = calculateChildRects(
            parentRect: availableRect,
            splitVertically: container.splitVertically,
            ratio: container.splitRatio,
        )

        // Recursively build left and right subtrees
        let leftChild = buildBinaryTree(Array(windows[0 ..< midIndex]), availableRect: leftRect)
        let rightChild = buildBinaryTree(Array(windows[midIndex...]), availableRect: rightRect)

        // Link children to parent
        if let left = leftChild {
            left.parent = container
            container.children.append(left)
        }
        if let right = rightChild {
            right.parent = container
            container.children.append(right)
        }

        return container
    }

    /// Determines split orientation based on available space and configuration
    ///
    /// FUTURE-READY: This method can be enhanced with:
    /// - split_width_multiplier to bias towards vertical/horizontal
    /// - smart_split for more intelligent decision making
    /// - User overrides per workspace or window
    ///
    /// - Parameters:
    ///   - availableRect: Available space
    ///   - windowCount: Number of windows in this split
    /// - Returns: True for vertical split (left|right), false for horizontal (top/bottom)
    private func determineSplitOrientation(availableRect: CGRect, windowCount: Int) -> Bool {
        // Calculate aspect ratio
        let aspectRatio = availableRect.width / availableRect.height

        // Apply split_width_multiplier (future enhancement)
        let adjustedAspectRatio = aspectRatio / splitWidthMultiplier

        // If smartSplit enabled, could add more complex logic here
        // For now: wider → vertical split, taller → horizontal split
        return adjustedAspectRatio >= 1.0
    }

    /// Calculates child rectangles for a split
    private func calculateChildRects(
        parentRect: CGRect,
        splitVertically: Bool,
        ratio: CGFloat,
    ) -> (CGRect, CGRect) {
        let (leftSize, rightSize) = calculateSplitSizes(
            containerSize: splitVertically ? parentRect.width : parentRect.height,
            ratio: ratio,
        )

        if splitVertically {
            return (
                CGRect(x: parentRect.minX, y: parentRect.minY, width: leftSize, height: parentRect.height),
                CGRect(x: parentRect.minX + leftSize, y: parentRect.minY, width: rightSize, height: parentRect.height),
            )
        } else {
            return (
                CGRect(x: parentRect.minX, y: parentRect.minY, width: parentRect.width, height: leftSize),
                CGRect(x: parentRect.minX, y: parentRect.minY + leftSize, width: parentRect.width, height: rightSize),
            )
        }
    }

    // MARK: - Layout Calculation

    /// Performs layout traversal, applying split ratios and updating window geometry
    ///
    /// This method mirrors Hyprland's `recalcSizePosRecursive` while integrating
    /// with HyprSpace's existing layout system.
    ///
    /// - Parameters:
    ///   - rect: Available space for layout
    ///   - context: Layout context with workspace and gap information
    @MainActor
    func layout(in rect: CGRect, context: LayoutContext) async throws {
        guard let root = rootNode else { return }
        try await layoutRecursive(root, in: rect, context: context)
    }

    /// Recursively lays out the tree
    @MainActor
    private func layoutRecursive(
        _ node: DwindleNode,
        in rect: CGRect,
        context: LayoutContext,
    ) async throws {
        // CRITICAL: Update box with fresh geometry BEFORE any calculations
        // This ensures resize operations always use current sizes
        node.box = rect

        // Leaf node - layout the actual window
        if node.isLeaf, let treeNode = node.window {
            // Get the window from the TreeNode
            guard case .window(let window) = treeNode.nodeCases else { return }

            // Apply layout following the same pattern as layoutRecursive for windows
            // Skip layout if window is currently being manipulated with mouse
            if window.windowId != currentlyManipulatedWithMouseWindowId {
                // Set virtual and physical rects
                let virtual = Rect(
                    topLeftX: rect.minX,
                    topLeftY: rect.minY,
                    width: rect.width,
                    height: rect.height,
                )
                treeNode.lastAppliedLayoutVirtualRect = virtual

                let physicalRect = Rect(
                    topLeftX: rect.minX,
                    topLeftY: rect.minY,
                    width: rect.width,
                    height: rect.height,
                )

                // Apply frame with fullscreen support (matches tiles/accordion behavior)
                if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                    treeNode.lastAppliedLayoutPhysicalRect = nil
                    window.layoutFullscreen(context)
                } else {
                    treeNode.lastAppliedLayoutPhysicalRect = physicalRect
                    window.isFullscreen = false
                    window.setAxFrame(rect.topLeftCorner, CGSize(width: rect.width, height: rect.height))
                }
            }
            return
        }

        // Container node - split and recurse
        guard node.children.count == 2 else { return }

        let left = node.children[0]
        let right = node.children[1]

        // Get gap size for this split direction
        let gapSize = CGFloat(node.splitVertically
            ? context.resolvedGaps.inner.horizontal
            : context.resolvedGaps.inner.vertical)

        // Calculate split sizes using ratio
        let availableSize = (node.splitVertically ? rect.width : rect.height) - gapSize
        let (leftSize, rightSize) = calculateSplitSizes(
            containerSize: availableSize,
            ratio: node.splitRatio,
        )

        let (leftRect, rightRect) = if node.splitVertically {
            // Vertical split: left | gap | right
            (
                CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: leftSize,
                    height: rect.height,
                ),
                CGRect(
                    x: rect.minX + leftSize + gapSize,
                    y: rect.minY,
                    width: rightSize,
                    height: rect.height,
                ),
            )
        } else {
            // Horizontal split: top / gap / bottom
            (
                CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: leftSize,
                ),
                CGRect(
                    x: rect.minX,
                    y: rect.minY + leftSize + gapSize,
                    width: rect.width,
                    height: rightSize,
                ),
            )
        }

        try await layoutRecursive(left, in: leftRect, context: context)
        try await layoutRecursive(right, in: rightRect, context: context)
    }

    /// Calculates split sizes using Hyprland's formula
    ///
    /// Formula:
    /// - childA_size = container_size * (ratio / (ratio + 1))
    /// - childB_size = container_size * (1 / (ratio + 1))
    ///
    /// - Parameters:
    ///   - containerSize: Total available size
    ///   - ratio: Split ratio (default 1.0 for 50/50)
    /// - Returns: Tuple of (leftSize, rightSize)
    private func calculateSplitSizes(containerSize: CGFloat, ratio: CGFloat) -> (CGFloat, CGFloat) {
        let leftSize = containerSize * (ratio / (ratio + 1.0))
        let rightSize = containerSize * (1.0 / (ratio + 1.0))
        return (leftSize, rightSize)
    }

    // MARK: - Node Lookup

    /// Finds the DwindleNode corresponding to a TreeNode window
    /// - Parameter window: Window to search for
    /// - Returns: Corresponding DwindleNode, or nil if not found
    func findNode(for window: TreeNode) -> DwindleNode? {
        return findNodeRecursive(rootNode, target: window)
    }

    private func findNodeRecursive(_ node: DwindleNode?, target: TreeNode) -> DwindleNode? {
        guard let node else { return nil }

        if node.window === target {
            return node
        }

        for child in node.children {
            if let found = findNodeRecursive(child, target: target) {
                return found
            }
        }

        return nil
    }

    // MARK: - Reset

    /// Resets all split ratios to 1.0 (50/50)
    ///
    /// Used by the balance-sizes command to restore default layout
    func resetAllRatios() {
        resetRatiosRecursive(rootNode)
    }

    private func resetRatiosRecursive(_ node: DwindleNode?) {
        guard let node else { return }

        if node.isContainer {
            node.splitRatio = 1.0
            for child in node.children {
                resetRatiosRecursive(child)
            }
        }
    }

    // MARK: - Resize Operations

    /// Resizes a window by applying delta to its containing nodes' split ratios
    ///
    /// This method implements the "layout → resize → layout" pattern:
    /// 1. Assumes boxes have fresh geometry from the last layout pass
    /// 2. Applies resize using current node.box sizes
    /// 3. Caller triggers another layout pass to apply new ratios
    ///
    /// - Parameters:
    ///   - window: Window to resize
    ///   - delta: Pixel delta (positive = grow, negative = shrink)
    ///   - shouldGrow: true for growth operations, false for shrink operations
    func resize(window: TreeNode, delta: Vector2D, shouldGrow: Bool) {
        guard let node = findNode(for: window) else { return }

        if smartResizing {
            resizeSmart(node: node, delta: delta, shouldGrow: shouldGrow)
        } else {
            resizeStandard(node: node, delta: delta)
        }
    }

    /// Smart resize mode (mirrors Hyprland's DwindleLayout.cpp:725-782)
    ///
    /// Uses corner/edge detection to intelligently resize multiple nodes,
    /// compensating inner nodes when outer nodes grow.
    private func resizeSmart(node: DwindleNode, delta: Vector2D, shouldGrow: Bool) {
        // 1. Detect edge constraints
        let edges = detectEdgeConstraints(node)
        var allowedDelta = delta

        // Windows constrained by edges can't resize in those directions
        if edges.left && edges.right { allowedDelta.x = 0 }
        if edges.top && edges.bottom { allowedDelta.y = 0 }

        guard allowedDelta.x != 0 || allowedDelta.y != 0 else { return }

        // 2. Find resize targets (outer/inner nodes for compensation)
        let targets = findSmartResizeTargets(node: node, delta: allowedDelta, shouldGrow: shouldGrow)

        // 3. Apply ratio changes using FRESH box sizes
        // Horizontal axis
        if let hOuter = targets.horizontalOuter, allowedDelta.x != 0 {
            // CRITICAL: Use hOuter.box.width which was updated in last layout pass
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: allowedDelta.x,
                containerSize: hOuter.box.width,
            )
            hOuter.splitRatio = clampRatio(hOuter.splitRatio + ratioDelta)
        }

        // Vertical axis
        if let vOuter = targets.verticalOuter, allowedDelta.y != 0 {
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: allowedDelta.y,
                containerSize: vOuter.box.height,
            )
            vOuter.splitRatio = clampRatio(vOuter.splitRatio + ratioDelta)
        }

        // 4. Compensate inner nodes (shrink opposite side)
        if let hInner = targets.horizontalInner, allowedDelta.x != 0 {
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: -allowedDelta.x,  // Negative to shrink
                containerSize: hInner.box.width,
            )
            hInner.splitRatio = clampRatio(hInner.splitRatio + ratioDelta)
        }

        if let vInner = targets.verticalInner, allowedDelta.y != 0 {
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: -allowedDelta.y,
                containerSize: vInner.box.height,
            )
            vInner.splitRatio = clampRatio(vInner.splitRatio + ratioDelta)
        }
    }

    /// Standard resize mode (mirrors Hyprland's DwindleLayout.cpp:784-840)
    ///
    /// Finds the parent controlling each axis and adjusts its split ratio.
    /// Simpler than smart resize but less intuitive for complex layouts.
    private func resizeStandard(node: DwindleNode, delta: Vector2D) {
        // Find parent controlling horizontal direction
        if delta.x != 0, let hParent = findControllingParent(node, splitVertically: true) {
            // Use FRESH box size from last layout
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: delta.x,
                containerSize: hParent.box.width,
            )
            hParent.splitRatio = clampRatio(hParent.splitRatio + ratioDelta)
        }

        // Find parent controlling vertical direction
        if delta.y != 0, let vParent = findControllingParent(node, splitVertically: false) {
            // Use FRESH box size from last layout
            let ratioDelta = pixelDeltaToRatioDelta(
                pixels: delta.y,
                containerSize: vParent.box.height,
            )
            vParent.splitRatio = clampRatio(vParent.splitRatio + ratioDelta)
        }
    }

    // MARK: - Smart Resize Helpers

    /// Finds nodes to resize for smart resizing mode
    private func findSmartResizeTargets(node: DwindleNode, delta: Vector2D, shouldGrow: Bool) -> ResizeTargets {
        var targets = ResizeTargets()

        // Horizontal axis
        if delta.x > 0 {
            // Growing right: find right-controlling parent (outer) and left-controlling (inner)
            targets.horizontalOuter = findParentControlling(node, axis: .horizontal, growingPositive: true, shouldGrow: shouldGrow)
            targets.horizontalInner = findParentControlling(node, axis: .horizontal, growingPositive: false, shouldGrow: shouldGrow)
        } else if delta.x < 0 {
            // Growing left: opposite
            targets.horizontalOuter = findParentControlling(node, axis: .horizontal, growingPositive: false, shouldGrow: shouldGrow)
            targets.horizontalInner = findParentControlling(node, axis: .horizontal, growingPositive: true, shouldGrow: shouldGrow)
        }

        // Vertical axis
        if delta.y > 0 {
            // Growing down: find bottom-controlling parent (outer) and top-controlling (inner)
            targets.verticalOuter = findParentControlling(node, axis: .vertical, growingPositive: true, shouldGrow: shouldGrow)
            targets.verticalInner = findParentControlling(node, axis: .vertical, growingPositive: false, shouldGrow: shouldGrow)
        } else if delta.y < 0 {
            // Growing up: opposite
            targets.verticalOuter = findParentControlling(node, axis: .vertical, growingPositive: false, shouldGrow: shouldGrow)
            targets.verticalInner = findParentControlling(node, axis: .vertical, growingPositive: true, shouldGrow: shouldGrow)
        }

        return targets
    }

    /// Finds parent node controlling resize in a specific direction
    ///
    /// Walks up the tree to find a parent whose split orientation matches the axis
    /// and whose child position matches the growth direction.
    private func findParentControlling(_ node: DwindleNode, axis: Axis, growingPositive: Bool, shouldGrow: Bool) -> DwindleNode? {
        let targetSplitVertically = (axis == .horizontal)

        var current = node
        while let parent = current.parent {
            if parent.splitVertically == targetSplitVertically {
                // Check if this split controls the direction we want
                let isLeftOrTop = parent.children.first === current
                // Dual-path logic: choose based on operation type
                // For grow: use !growingPositive (Path A)
                // For shrink: use growingPositive (Path B)
                let shouldBeLeftOrTop = shouldGrow ? !growingPositive : growingPositive

                if isLeftOrTop == shouldBeLeftOrTop {
                    return parent
                }
            }
            current = parent
        }
        return nil
    }

    /// Finds parent controlling a specific split orientation (for standard resize)
    private func findControllingParent(_ node: DwindleNode, splitVertically: Bool) -> DwindleNode? {
        var current = node.parent
        while let parent = current {
            if parent.splitVertically == splitVertically {
                return parent
            }
            current = parent.parent
        }
        return nil
    }

    /// Detects if node is constrained by workspace edges
    private func detectEdgeConstraints(_ node: DwindleNode) -> EdgeConstraints {
        guard let rootBox = rootNode?.box else { return EdgeConstraints() }

        let threshold: CGFloat = 5.0  // Pixels
        var edges = EdgeConstraints()

        edges.left = abs(node.box.minX - rootBox.minX) < threshold
        edges.right = abs(node.box.maxX - rootBox.maxX) < threshold
        edges.top = abs(node.box.minY - rootBox.minY) < threshold
        edges.bottom = abs(node.box.maxY - rootBox.maxY) < threshold

        return edges
    }

    // MARK: - Resize Math Helpers

    /// Converts pixel delta to split ratio delta (50% reduced sensitivity)
    ///
    /// Formula: ratio_delta = 1.0 * pixels / containerSize
    private func pixelDeltaToRatioDelta(pixels: CGFloat, containerSize: CGFloat) -> CGFloat {
        guard containerSize > 0 else { return 0 }
        return 1.0 * pixels / containerSize
    }

    /// Clamps split ratio to valid range [0.1, 1.9]
    private func clampRatio(_ ratio: CGFloat) -> CGFloat {
        return max(0.1, min(1.9, ratio))
    }
}

// MARK: - Helper Types

/// 2D vector for resize deltas
struct Vector2D {
    var x: CGFloat
    var y: CGFloat
}

/// Axis enumeration for split orientation
enum Axis {
    case horizontal
    case vertical
}

/// Resize targets for smart resizing
struct ResizeTargets {
    var horizontalOuter: DwindleNode?
    var horizontalInner: DwindleNode?
    var verticalOuter: DwindleNode?
    var verticalInner: DwindleNode?
}

/// Edge constraints for a node
struct EdgeConstraints {
    var left: Bool = false
    var right: Bool = false
    var top: Bool = false
    var bottom: Bool = false
}

/// Rectangle extension for convenient access
extension CGRect {
    var topLeftCorner: CGPoint {
        CGPoint(x: minX, y: minY)
    }
}
