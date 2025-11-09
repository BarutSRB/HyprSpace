import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

// Event debouncing state
@MainActor
private var lastResizeEventTime: Date? = nil
@MainActor
private let resizeThrottleInterval: TimeInterval = 0.016  // 60fps (~16ms between frames)

func resizedObs(_ obs: AXObserver, ax: AXUIElement, notif: CFString, data: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task { @MainActor in
        // Debounce: Skip events that arrive too frequently to prevent event flood
        // This limits resize processing to ~60fps, preventing exponential amplification
        let now = Date()
        if let lastTime = lastResizeEventTime {
            let timeSinceLastEvent = now.timeIntervalSince(lastTime)
            if timeSinceLastEvent < resizeThrottleInterval {
                return  // Skip this event - too soon after previous one
            }
        }
        lastResizeEventTime = now

        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            runRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task {
            try checkCancellation()
            try await runSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        // Wait for any in-flight resize task to complete before clearing the flag
        // This prevents race conditions where layout runs with stale ratios
        try await resizeWithMouseTask?.value

        currentlyManipulatedWithMouseWindowId = nil
        lastResizeEventTime = nil  // Reset debounce timer for next manipulation

        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()

            // Clear dwindle box snapshots to ensure clean state for next manipulation
            workspace.rootTilingContainer.dwindleCache.clearBoxSnapshots()
        }
        runRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .workspace, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer(let tilingParent):
            guard let rect = try await window.getAxRect() else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }

            // DWINDLE LAYOUT: Handle directly using cache, bypassing orientation-based lookups
            // This avoids the architectural mismatch where closestParent searches by orientation
            // but dwindle uses binary tree split logic. The cache's findParentControlling()
            // correctly handles the binary tree structure.
            if tilingParent.layout == .dwindle {
                let cache = tilingParent.dwindleCache

                // Calculate edge movements (same logic as table below)
                let leftDiff = lastAppliedLayoutRect.minX - rect.minX    // Positive = grew left
                let downDiff = rect.maxY - lastAppliedLayoutRect.maxY     // Positive = grew down
                let upDiff = lastAppliedLayoutRect.minY - rect.minY       // Positive = grew up
                let rightDiff = rect.maxX - lastAppliedLayoutRect.maxX    // Positive = grew right

                // Find which edge moved significantly (>5px threshold)
                // Process in same order as original table for consistency
                let edgeTable: [(diff: CGFloat, delta: Vector2D, edges: ManipulatedEdges)] = [
                    (leftDiff, Vector2D(x: -leftDiff, y: 0), ManipulatedEdges(horizontal: .negative, vertical: nil)),
                    (downDiff, Vector2D(x: 0, y: downDiff), ManipulatedEdges(horizontal: nil, vertical: .positive)),
                    (upDiff, Vector2D(x: 0, y: -upDiff), ManipulatedEdges(horizontal: nil, vertical: .negative)),
                    (rightDiff, Vector2D(x: rightDiff, y: 0), ManipulatedEdges(horizontal: .positive, vertical: nil))
                ]

                // Find first edge that moved significantly (1px threshold for smooth tracking)
                if let (diff, delta, edges) = edgeTable.first(where: { abs($0.diff) > 1 }) {
                    let shouldGrow = diff > 0

                    // Set manipulation flag BEFORE resize to prevent race conditions
                    currentlyManipulatedWithMouseWindowId = window.windowId

                    // Get monitor size for normalization (MainActor context)
                    let monitor = rect.center.monitorApproximation
                    let monitorSize = CGSize(width: monitor.visibleRect.width, height: monitor.visibleRect.height)

                    // Get sensitivity setting (MainActor context)
                    let sensitivity = config.mouseSensitivity

                    // Call cache resize - it will use findParentControlling() internally
                    cache.resize(window: window, delta: delta, shouldGrow: shouldGrow, windowSize: rect.size, edges: edges, monitorSize: monitorSize, sensitivity: sensitivity)
                    return
                }

                // No significant edge movement detected
                return
            }

            // TILES/SCROLL LAYOUT: Use orientation-based closestParent lookups
            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: nil) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: nil) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: nil) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: nil) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?, ManipulatedEdges)] = [
                (
                    lastAppliedLayoutRect.minX - rect.minX,
                    lParent,
                    0,
                    lOwnIndex,
                    ManipulatedEdges(horizontal: .negative, vertical: nil)
                ), // Horizontal, to the left of the window
                (
                    rect.maxY - lastAppliedLayoutRect.maxY,
                    dParent,
                    dOwnIndex.map { $0 + 1 },
                    dParent?.children.count,
                    ManipulatedEdges(horizontal: nil, vertical: .positive)
                ), // Vertical, to the down of the window
                (
                    lastAppliedLayoutRect.minY - rect.minY,
                    uParent,
                    0,
                    uOwnIndex,
                    ManipulatedEdges(horizontal: nil, vertical: .negative)
                ), // Vertical, to the up of the window
                (
                    rect.maxX - lastAppliedLayoutRect.maxX,
                    rParent,
                    rOwnIndex.map { $0 + 1 },
                    rParent?.children.count,
                    ManipulatedEdges(horizontal: .positive, vertical: nil)
                ), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex, _) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    // Tiles layout uses weight-based resizing
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    if parent.layout != .scroll {
                        for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                            sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                        }
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
