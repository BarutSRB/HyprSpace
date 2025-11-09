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
    @MainActor
    func needsRebuild(for windows: [TreeNode]) -> Bool {
        // Don't rebuild during active mouse manipulation - ratios are being updated
        // and rebuild would destroy them by resetting to defaults
        if currentlyManipulatedWithMouseWindowId != nil {
            return false
        }

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
    @MainActor
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
    @MainActor
    private func buildBinaryTree(_ windows: [TreeNode], availableRect: CGRect) -> DwindleNode? {
        guard !windows.isEmpty else { return nil }

        // Leaf node - single window
        if windows.count == 1 {
            return DwindleNode(window: windows[0])
        }

        // Container node - binary split
        let container = DwindleNode()
        container.splitRatio = config.dwindleDefaultSplitRatio  // Use configured default split ratio

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
        // Update box with fresh geometry BEFORE any calculations
        // CRITICAL: During manipulation, preserve snapshots to prevent geometry feedback loops
        if currentlyManipulatedWithMouseWindowId == nil {
            // Not manipulating - update box and clear any stale snapshots
            node.box = rect
            node.boxSnapshot = nil
        } else if node.boxSnapshot == nil {
            // First layout during manipulation - snapshot current box before updating
            node.boxSnapshot = node.box
            node.box = rect
        } else {
            // Subsequent layouts during manipulation - update box but keep snapshot frozen
            node.box = rect
        }

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

    // MARK: - Navigation

    /// Syncs node geometry from macOS accessibility APIs
    ///
    /// Refreshes all window positions in the dwindle tree by querying actual window
    /// positions from macOS. This prevents stale geometry issues when windows are
    /// manually moved outside the layout system (e.g., via third-party tools or
    /// manual dragging while AeroSpace isn't managing).
    ///
    /// Call this before navigation operations to ensure accurate neighbor detection.
    @MainActor
    func syncGeometryFromMacOS() async throws {
        guard let root = rootNode else { return }
        try await syncGeometryRecursive(root)
    }

    @MainActor
    private func syncGeometryRecursive(_ node: DwindleNode) async throws {
        // Leaf node - sync from actual window position
        if node.isLeaf, let treeNode = node.window {
            guard case .window(let window) = treeNode.nodeCases else { return }

            // Get fresh geometry from macOS
            if let axRect = try await window.getAxRect() {
                // Update node.box with fresh coordinates
                node.box = CGRect(
                    x: axRect.topLeftX,
                    y: axRect.topLeftY,
                    width: axRect.width,
                    height: axRect.height
                )
            }
            return
        }

        // Container node - recurse to children
        for child in node.children {
            try await syncGeometryRecursive(child)
        }
    }

    /// Finds the neighboring window in the specified direction using geometric analysis
    ///
    /// This method implements geometry-based navigation similar to Hyprland's approach,
    /// analyzing window positions and edge adjacency rather than tree structure.
    ///
    /// Algorithm:
    /// 1. Find current window's DwindleNode and geometry
    /// 2. Collect all candidate leaf windows in the binary tree
    /// 3. Filter candidates by:
    ///    - Edge adjacency (e.g., for "up": candidate's bottom edge touches current's top edge)
    ///    - Perpendicular overlap (at least 10% overlap on the perpendicular axis)
    /// 4. Sort by overlap length (prefer maximum overlap)
    /// 5. Return the window with the longest overlap
    ///
    /// - Parameters:
    ///   - window: Current window to navigate from
    ///   - direction: Cardinal direction to navigate (up/down/left/right)
    ///   - gaps: Resolved gap configuration for accurate edge detection
    /// - Returns: The neighboring window, or nil if no valid neighbor exists
    func findNeighbor(from window: TreeNode, direction: CardinalDirection, gaps: ResolvedGaps) -> Window? {
        #if DEBUG
        print("[Dwindle Navigation] Finding neighbor from window \(window) in direction \(direction)")
        print("[Dwindle Navigation] Gap sizes: H=\(gaps.inner.horizontal)px V=\(gaps.inner.vertical)px")
        #endif

        // Find the DwindleNode for the current window
        guard let currentNode = findNode(for: window) else {
            #if DEBUG
            print("[Dwindle Navigation] ❌ Could not find DwindleNode for window")
            #endif
            return nil
        }
        let currentBox = currentNode.box

        #if DEBUG
        print("[Dwindle Navigation] Current window box: \(currentBox)")
        #endif

        // Collect all candidate windows with their overlap measurements
        var candidates: [(window: Window, overlap: CGFloat)] = []
        collectNavigationCandidates(
            from: rootNode,
            current: currentNode,
            currentBox: currentBox,
            direction: direction,
            gaps: gaps,
            candidates: &candidates
        )

        // No candidates found - we're at workspace boundary
        guard !candidates.isEmpty else {
            #if DEBUG
            print("[Dwindle Navigation] ❌ No candidates found - at workspace boundary")
            #endif
            return nil
        }

        #if DEBUG
        print("[Dwindle Navigation] Found \(candidates.count) candidate(s):")
        for (i, candidate) in candidates.enumerated() {
            print("  [\(i + 1)] Window \(candidate.window.windowId) - overlap: \(String(format: "%.1f", candidate.overlap))px")
        }
        #endif

        // Sort by overlap length (descending) - prefer windows with maximum overlap
        let sorted = candidates.sorted { $0.overlap > $1.overlap }

        // Return the window with the longest overlap
        let selected = sorted.first?.window
        #if DEBUG
        if let selected = selected {
            print("[Dwindle Navigation] ✅ Selected window \(selected.windowId) with max overlap")
        }
        #endif
        return selected
    }

    /// Recursively collects candidate windows for navigation
    ///
    /// Traverses the binary tree to find all leaf windows that are valid navigation targets
    /// in the specified direction from the current window.
    private func collectNavigationCandidates(
        from node: DwindleNode?,
        current: DwindleNode,
        currentBox: CGRect,
        direction: CardinalDirection,
        gaps: ResolvedGaps,
        candidates: inout [(window: Window, overlap: CGFloat)]
    ) {
        guard let node else { return }

        // Skip the current node itself
        if node === current {
            // Still recurse to children in case they're candidates
            for child in node.children {
                collectNavigationCandidates(
                    from: child,
                    current: current,
                    currentBox: currentBox,
                    direction: direction,
                    gaps: gaps,
                    candidates: &candidates
                )
            }
            return
        }

        // Leaf node - check if it's a valid candidate
        if node.isLeaf, let candidateTreeNode = node.window {
            let candidateBox = node.box

            // Check if this window is in the correct direction with sufficient overlap
            if let overlap = calculateDirectionalOverlap(
                from: currentBox,
                to: candidateBox,
                direction: direction,
                gaps: gaps
            ) {
                // Extract Window from TreeNode
                if case .window(let window) = candidateTreeNode.nodeCases {
                    candidates.append((window, overlap))
                }
            }
            return
        }

        // Container node - recurse to children
        for child in node.children {
            collectNavigationCandidates(
                from: child,
                current: current,
                currentBox: currentBox,
                direction: direction,
                gaps: gaps,
                candidates: &candidates
            )
        }
    }

    /// Calculates the perpendicular overlap between two windows if they're adjacent in the specified direction
    ///
    /// Returns the overlap length if windows are adjacent, or nil if they're not valid neighbors.
    /// "Adjacent" means edges touch within the gap size plus a small tolerance.
    /// "Overlap" is the shared length on the perpendicular axis.
    ///
    /// Example for "up" navigation:
    /// - Checks if candidate's bottom edge touches current's top edge (within gap size + tolerance)
    /// - Calculates horizontal overlap (how much the windows align horizontally)
    ///
    /// - Parameters:
    ///   - source: Current window's bounding box
    ///   - target: Candidate window's bounding box
    ///   - direction: Navigation direction
    ///   - gaps: Resolved gap configuration for accurate edge detection
    /// - Returns: Overlap length if windows are adjacent, nil otherwise
    private func calculateDirectionalOverlap(
        from source: CGRect,
        to target: CGRect,
        direction: CardinalDirection,
        gaps: ResolvedGaps
    ) -> CGFloat? {
        // Calculate gap-aware edge threshold based on direction
        // Add small tolerance (5px) for floating point precision
        let edgeThreshold: CGFloat = switch direction {
            case .up, .down: CGFloat(gaps.inner.vertical) + 5.0
            case .left, .right: CGFloat(gaps.inner.horizontal) + 5.0
        }
        let minOverlapRatio: CGFloat = 0.1  // Require at least 10% overlap

        switch direction {
        case .up:
            // Target must be above: candidate's bottom edge touches current's top edge
            // macOS coordinates: Y increases downward, so "up" means smaller Y values
            let edgeDistance = abs(source.minY - target.maxY)
            let edgesTouch = edgeDistance < edgeThreshold
            #if DEBUG
            if !edgesTouch {
                print("[Dwindle Navigation]   Skip: edge distance \(String(format: "%.1f", edgeDistance))px > threshold \(String(format: "%.1f", edgeThreshold))px")
            }
            #endif
            guard edgesTouch else { return nil }

            // Calculate horizontal overlap
            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            // Require minimum overlap (avoid diagonal neighbors)
            let minRequiredOverlap = min(source.width, target.width) * minOverlapRatio
            let hasValidOverlap = overlap >= minRequiredOverlap
            #if DEBUG
            if hasValidOverlap {
                print("[Dwindle Navigation]   ✓ Valid candidate: overlap \(String(format: "%.1f", overlap))px >= min \(String(format: "%.1f", minRequiredOverlap))px")
            } else if overlap > 0 {
                print("[Dwindle Navigation]   Skip: overlap \(String(format: "%.1f", overlap))px < min \(String(format: "%.1f", minRequiredOverlap))px")
            }
            #endif
            return hasValidOverlap ? overlap : nil

        case .down:
            // Target must be below: candidate's top edge touches current's bottom edge
            let edgesTouch = abs(source.maxY - target.minY) < edgeThreshold
            guard edgesTouch else { return nil }

            // Calculate horizontal overlap
            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequiredOverlap = min(source.width, target.width) * minOverlapRatio
            return overlap >= minRequiredOverlap ? overlap : nil

        case .left:
            // Target must be to the left: candidate's right edge touches current's left edge
            let edgesTouch = abs(source.minX - target.maxX) < edgeThreshold
            guard edgesTouch else { return nil }

            // Calculate vertical overlap
            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequiredOverlap = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequiredOverlap ? overlap : nil

        case .right:
            // Target must be to the right: candidate's left edge touches current's right edge
            let edgesTouch = abs(source.maxX - target.minX) < edgeThreshold
            guard edgesTouch else { return nil }

            // Calculate vertical overlap
            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequiredOverlap = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequiredOverlap ? overlap : nil
        }
    }

    // MARK: - Reset

    /// Resets all split ratios to configured default
    ///
    /// Used by the balance-sizes command to restore default layout
    @MainActor
    func resetAllRatios() {
        resetRatiosRecursive(rootNode)
    }

    @MainActor
    private func resetRatiosRecursive(_ node: DwindleNode?) {
        guard let node else { return }

        if node.isContainer {
            node.splitRatio = config.dwindleDefaultSplitRatio
            for child in node.children {
                resetRatiosRecursive(child)
            }
        }
    }

    /// Clears all box snapshots after mouse manipulation completes
    ///
    /// This should be called when `currentlyManipulatedWithMouseWindowId` is cleared
    /// to ensure clean state for the next manipulation session.
    @MainActor
    func clearBoxSnapshots() {
        clearBoxSnapshotsRecursive(rootNode)
    }

    @MainActor
    private func clearBoxSnapshotsRecursive(_ node: DwindleNode?) {
        guard let node else { return }
        node.boxSnapshot = nil
        for child in node.children {
            clearBoxSnapshotsRecursive(child)
        }
    }

    // MARK: - Resize Operations

    /// Resizes a window by applying delta to its containing nodes' split ratios
    ///
    /// This method uses the current window size for accurate ratio calculations
    /// instead of relying on potentially stale node.box values.
    ///
    /// - Parameters:
    ///   - window: Window to resize
    ///   - delta: Pixel delta (positive = grow, negative = shrink)
    ///   - shouldGrow: true for growth operations, false for shrink operations
    ///   - windowSize: Current window size (from getAxRect) for accurate ratio calculations
    ///   - edges: Which edges were manipulated for each axis
    func resize(window: TreeNode, delta: Vector2D, shouldGrow: Bool, windowSize: CGSize, edges: ManipulatedEdges, monitorSize: CGSize, sensitivity: CGFloat) {
        guard let node = findNode(for: window) else { return }

        if smartResizing {
            resizeSmart(node: node, delta: delta, shouldGrow: shouldGrow, windowSize: windowSize, edges: edges, monitorSize: monitorSize, sensitivity: sensitivity)
        } else {
            resizeStandard(node: node, delta: delta, shouldGrow: shouldGrow, windowSize: windowSize, edges: edges, monitorSize: monitorSize, sensitivity: sensitivity)
        }
    }

    /// Smart resize mode (mirrors Hyprland's DwindleLayout.cpp:725-782)
    ///
    /// Uses corner/edge detection to intelligently resize multiple nodes,
    /// compensating inner nodes when outer nodes grow.
    private func resizeSmart(node: DwindleNode, delta: Vector2D, shouldGrow: Bool, windowSize: CGSize, edges: ManipulatedEdges, monitorSize: CGSize, sensitivity: CGFloat) {
        // 1. Detect edge constraints
        let constraints = detectEdgeConstraints(node)
        var allowedDelta = delta

        // Windows constrained by edges can't resize in those directions
        if constraints.left && constraints.right { allowedDelta.x = 0 }
        if constraints.top && constraints.bottom { allowedDelta.y = 0 }

        // Ignore axes that weren't part of this drag
        if edges.horizontal == nil { allowedDelta.x = 0 }
        if edges.vertical == nil { allowedDelta.y = 0 }

        guard allowedDelta.x != 0 || allowedDelta.y != 0 else { return }

        // 2. Find resize targets (outer/inner nodes for compensation)
        let targets = findSmartResizeTargets(node: node, edges: edges)

        // 3. Apply ratio changes to outer targets
        // Horizontal axis
        if let hOuter = targets.horizontalOuter {
            applyRatioDelta(
                target: hOuter,
                axis: .horizontal,
                pixels: allowedDelta.x,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }

        // Vertical axis
        if let vOuter = targets.verticalOuter {
            applyRatioDelta(
                target: vOuter,
                axis: .vertical,
                pixels: allowedDelta.y,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }

        // 4. Compensate inner nodes (shrink opposite side)
        if let hInner = targets.horizontalInner {
            applyRatioDelta(
                target: hInner,
                axis: .horizontal,
                pixels: allowedDelta.x,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }

        if let vInner = targets.verticalInner {
            applyRatioDelta(
                target: vInner,
                axis: .vertical,
                pixels: allowedDelta.y,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }
    }

    /// Standard resize mode (mirrors Hyprland's DwindleLayout.cpp:784-840)
    ///
    /// Finds the parent controlling each axis and adjusts its split ratio.
    /// Simpler than smart resize but less intuitive for complex layouts.
    private func resizeStandard(node: DwindleNode, delta: Vector2D, shouldGrow: Bool, windowSize: CGSize, edges: ManipulatedEdges, monitorSize: CGSize, sensitivity: CGFloat) {
        if let horizontalEdge = edges.horizontal,
           delta.x != 0,
           let hTarget = findParentControlling(node, axis: .horizontal, edgeIsPositive: horizontalEdge == .positive) {
            applyRatioDelta(
                target: hTarget,
                axis: .horizontal,
                pixels: delta.x,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }

        if let verticalEdge = edges.vertical,
           delta.y != 0,
           let vTarget = findParentControlling(node, axis: .vertical, edgeIsPositive: verticalEdge == .positive) {
            applyRatioDelta(
                target: vTarget,
                axis: .vertical,
                pixels: delta.y,
                shouldGrow: shouldGrow,
                monitorSize: monitorSize,
                sensitivity: sensitivity
            )
        }
    }

    // MARK: - Smart Resize Helpers

    /// Finds nodes to resize for smart resizing mode
    private func findSmartResizeTargets(node: DwindleNode, edges: ManipulatedEdges) -> ResizeTargets {
        var targets = ResizeTargets()

        if let horizontalEdge = edges.horizontal {
            let isPositive = horizontalEdge == .positive
            targets.horizontalOuter = findParentControlling(node, axis: .horizontal, edgeIsPositive: isPositive)
            targets.horizontalInner = findParentControlling(node, axis: .horizontal, edgeIsPositive: !isPositive)
        }

        if let verticalEdge = edges.vertical {
            let isPositive = verticalEdge == .positive
            targets.verticalOuter = findParentControlling(node, axis: .vertical, edgeIsPositive: isPositive)
            targets.verticalInner = findParentControlling(node, axis: .vertical, edgeIsPositive: !isPositive)
        }

        return targets
    }

    /// Finds parent node controlling resize in a specific direction
    ///
    /// Walks up the tree to find a parent whose split orientation matches the axis
    /// and whose child position matches the growth direction.
    private func findParentControlling(_ node: DwindleNode, axis: Axis, edgeIsPositive: Bool) -> ControllingSplit? {
        let targetSplitVertically = (axis == .horizontal)

        var current: DwindleNode? = node
        while let parent = current?.parent {
            if parent.splitVertically == targetSplitVertically {
                let isFirstChild = parent.children.first === current
                let isLastChild = parent.children.last === current
                if edgeIsPositive {
                    // Need a neighbor on the positive side (i.e., not the last child at this level)
                    if !isLastChild {
                        return ControllingSplit(parent: parent, childIsFirst: isFirstChild)
                    }
                } else {
                    // Need a neighbor on the negative side (i.e., not the first child at this level)
                    if !isFirstChild {
                        return ControllingSplit(parent: parent, childIsFirst: isFirstChild)
                    }
                }
            }
            current = parent
        }
        return nil
    }

    /// Detects if node is constrained by workspace edges
    ///
    /// Checks if a window's edges are flush with the workspace boundaries.
    /// Uses a tolerance threshold to account for floating point precision and
    /// minor positioning variations.
    ///
    /// Note: This checks workspace boundaries, not window-to-window adjacency,
    /// so gap sizes are not applicable here (workspace rect is already padded by outer gaps).
    private func detectEdgeConstraints(_ node: DwindleNode) -> EdgeConstraints {
        guard let rootBox = rootNode?.box else { return EdgeConstraints() }

        // Tolerance for floating point precision and minor variations
        // Increased from 5px for better robustness
        let threshold: CGFloat = 10.0
        var edges = EdgeConstraints()

        edges.left = abs(node.box.minX - rootBox.minX) < threshold
        edges.right = abs(node.box.maxX - rootBox.maxX) < threshold
        edges.top = abs(node.box.minY - rootBox.minY) < threshold
        edges.bottom = abs(node.box.maxY - rootBox.maxY) < threshold

        return edges
    }

    // MARK: - Resize Math Helpers

    /// Applies a ratio delta to the target split using parent container dimensions
    ///
    /// Uses target.parent.box dimensions (the container being split) as the denominator
    /// for ratio calculations. This ensures correct proportional adjustments.
    private func applyRatioDelta(
        target: ControllingSplit,
        axis: Axis,
        pixels: CGFloat,
        shouldGrow: Bool,
        monitorSize: CGSize,
        sensitivity: CGFloat
    ) {
        let magnitude = abs(pixels)
        guard magnitude > 0 else { return }

        // CRITICAL: Use snapshot if available (during manipulation) to prevent feedback loops
        // The snapshot freezes parent geometry at manipulation start, ensuring consistent
        // ratio calculations across multiple mouse events. Falls back to current box when
        // not manipulating.
        let parentBox = target.parent.boxSnapshot ?? target.parent.box
        let containerSize = axis == .horizontal
            ? parentBox.width
            : parentBox.height
        guard containerSize > 0 else { return }

        // Apply orientation and growth direction
        let orientationSign: CGFloat = target.childIsFirst ? 1 : -1
        let growthSign: CGFloat = shouldGrow ? 1 : -1

        // Calculate ratio delta using container size for normalization
        // This provides consistent behavior regardless of container size
        // Sensitivity parameter allows user to adjust mouse responsiveness
        let scaledMagnitude = magnitude * sensitivity
        let ratioDelta = orientationSign * growthSign * (scaledMagnitude / containerSize)
        guard ratioDelta != 0 else { return }

        target.parent.splitRatio = clampRatio(target.parent.splitRatio + ratioDelta)
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

/// Direction of manipulated edge along an axis
enum EdgeDirection {
    case negative
    case positive
}

/// Edge metadata for current resize operation
struct ManipulatedEdges {
    var horizontal: EdgeDirection?
    var vertical: EdgeDirection?
}

/// Parent split plus orientation metadata
struct ControllingSplit {
    var parent: DwindleNode
    var childIsFirst: Bool
}

/// Resize targets for smart resizing
struct ResizeTargets {
    var horizontalOuter: ControllingSplit?
    var horizontalInner: ControllingSplit?
    var verticalOuter: ControllingSplit?
    var verticalInner: ControllingSplit?
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
