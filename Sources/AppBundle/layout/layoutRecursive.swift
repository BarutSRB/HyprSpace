import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                for window in workspace.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                    case .dwindle:
                        try await container.layoutDwindle(point, width: width, height: height, virtual: virtual, context)
                    case .scroll:
                        try await container.layoutScroll(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let currentMonitor = try await getCenter()?.monitorApproximation // Probably not idempotent
        if let currentMonitor, let windowTopLeftCorner = try await getAxTopLeftCorner(), workspace != currentMonitor.activeWorkspace {
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let moveTo = workspace.workspaceMonitor
            setAxTopLeftCorner(CGPoint(
                x: moveTo.visibleRect.topLeftX + xProportion * moveTo.visibleRect.width,
                y: moveTo.visibleRect.topLeftY + yProportion * moveTo.visibleRect.height,
            ))
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }

    @MainActor
    fileprivate func layoutDwindle(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        // Dwindle layout uses a persistent binary tree cache that maintains split ratios
        // across layout recalculations, enabling window resizing.
        guard let container = self as? TilingContainer else { return }
        guard !children.isEmpty else { return }

        // Single child takes full space - no need for cache
        if children.count == 1 {
            try await children[0].layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            return
        }

        // Get or create the dwindle cache
        let cache = container.dwindleCache

        // Rebuild cache if window structure changed
        let rect = CGRect(x: point.x, y: point.y, width: width, height: height)
        if cache.needsRebuild(for: container.children) {
            cache.rebuild(from: container.children, availableRect: rect)
        }

        // Layout using cache - this maintains split ratios and updates geometry
        try await cache.layout(in: rect, context: context)
    }

    @MainActor
    fileprivate func layoutScroll(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard !children.isEmpty else { return }

        // Special case: single window uses full width
        if children.count == 1 {
            try await children[0].layoutRecursive(
                point,
                width: width,
                height: height,
                virtual: virtual,
                context
            )
            return
        }

        // Carousel scroll layout (horizontal only):
        // - Focused window: centered, 80% screen width
        // - Peek effect: 10% of left/right neighbors visible at edges
        // - Custom widths: preserved from previous layouts (if resized)

        let focusedWidthRatio: CGFloat = 0.8
        let defaultWindowWidth = width * focusedWidthRatio
        let peekMargin = width * ((1.0 - focusedWidthRatio) / 2.0)

        // Find the focused (most recent) window
        let anchorNode = mostRecentChild ?? children[0]
        guard let anchorIndex = children.firstIndex(where: { $0 === anchorNode }) else { return }

        // Get window widths (custom if resized, otherwise default 80%)
        let windowWidths: [CGFloat] = children.map { child in
            if let virtualRect = child.lastAppliedLayoutVirtualRect {
                return virtualRect.width
            }
            return defaultWindowWidth
        }

        // Calculate positions:
        // Focused window is centered with peekMargin on left
        let focusedX = point.x + peekMargin
        var positions = Array(repeating: point.x, count: children.count)
        positions[anchorIndex] = focusedX

        // Position windows to the right of focused
        var rightCursor = focusedX + windowWidths[anchorIndex]
        if anchorIndex + 1 < children.count {
            for index in (anchorIndex + 1)..<children.count {
                positions[index] = rightCursor
                rightCursor += windowWidths[index]
            }
        }

        // Position windows to the left of focused
        var leftCursor = focusedX
        if anchorIndex > 0 {
            for index in stride(from: anchorIndex - 1, through: 0, by: -1) {
                leftCursor -= windowWidths[index]
                positions[index] = leftCursor
            }
        }

        // Virtual positions (gapless, for logical representation)
        var virtualPositions = Array(repeating: virtual.topLeftX, count: children.count)
        virtualPositions[anchorIndex] = virtual.topLeftX

        var virtualRightCursor = virtual.topLeftX + windowWidths[anchorIndex]
        if anchorIndex + 1 < children.count {
            for index in (anchorIndex + 1)..<children.count {
                virtualPositions[index] = virtualRightCursor
                virtualRightCursor += windowWidths[index]
            }
        }

        var virtualLeftCursor = virtual.topLeftX
        if anchorIndex > 0 {
            for index in stride(from: anchorIndex - 1, through: 0, by: -1) {
                virtualLeftCursor -= windowWidths[index]
                virtualPositions[index] = virtualLeftCursor
            }
        }

        // Layout all windows
        for (index, child) in children.enumerated() {
            let childWidth = windowWidths[index]
            let childPoint = CGPoint(x: positions[index], y: point.y)

            try await child.layoutRecursive(
                childPoint,
                width: childWidth,
                height: height,
                virtual: Rect(
                    topLeftX: virtualPositions[index],
                    topLeftY: virtual.topLeftY,
                    width: childWidth,
                    height: virtual.height
                ),
                context
            )
            child.setWeight(.h, childWidth)
        }
    }
}
