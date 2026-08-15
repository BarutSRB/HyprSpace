// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func hitTestResize(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        threshold: CGFloat? = nil
    ) -> ResizeHitTestResult? {
        guard let root = root(for: workspaceId) else { return nil }

        let threshold = threshold ?? resizeConfiguration.edgeThreshold

        for (colIdx, column) in root.columns.enumerated() {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if window.isFullscreen {
                    continue
                }

                let edges = detectEdges(point: point, frame: frame, threshold: threshold)
                if !edges.isEmpty {
                    return ResizeHitTestResult(
                        windowToken: window.token,
                        nodeId: window.id,
                        edges: edges,
                        columnIndex: colIdx,
                        windowFrame: frame
                    )
                }
            }
        }

        return nil
    }

    func hitTestTiled(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = root(for: workspaceId) else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    return window
                }
            }
        }

        return nil
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriWindow? {
        guard let root = root(for: workspaceId) else { return nil }

        var firstVisibleMatch: NiriWindow?

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      isProjectedFocusableWindow(window, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame,
                      frame.contains(point)
                else {
                    continue
                }

                if window.isFullscreen {
                    return window
                }

                if firstVisibleMatch == nil {
                    firstVisibleMatch = window
                }
            }
        }

        return firstVisibleMatch
    }

    private func detectEdges(point: CGPoint, frame: CGRect, threshold: CGFloat) -> ResizeEdge {
        var edges: ResizeEdge = []

        let expandedFrame = frame.insetBy(dx: -threshold, dy: -threshold)
        guard expandedFrame.contains(point) else {
            return []
        }

        let innerFrame = frame.insetBy(dx: threshold, dy: threshold)
        if innerFrame.contains(point) {
            return []
        }

        if point.x <= frame.minX + threshold, point.x >= frame.minX - threshold {
            edges.insert(.left)
        }
        if point.x >= frame.maxX - threshold, point.x <= frame.maxX + threshold {
            edges.insert(.right)
        }
        if point.y <= frame.minY + threshold, point.y >= frame.minY - threshold {
            edges.insert(.bottom)
        }
        if point.y >= frame.maxY - threshold, point.y <= frame.maxY + threshold {
            edges.insert(.top)
        }

        return edges
    }

    private func interactiveResizeStartWidth(
        for column: NiriContainer,
        window: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID
    ) -> CGFloat {
        if column.cachedWidth > 0 {
            return column.cachedWidth
        }
        if let width = column.frame?.width, width > 0 {
            return width
        }
        if let width = column.renderedFrame?.width, width > 0 {
            return width
        }
        if let width = window.frame?.width, width > 0 {
            let tabOffset = projectedWindows(in: column, workspaceId: workspaceId).count > 1
                ? renderStyle.tabIndicatorWidth
                : 0
            return width + tabOffset
        }
        return projectedWidthBounds(for: column, workspaceId: workspaceId).min
    }

    private func interactiveResizeStartHeight(
        for column: NiriContainer,
        window: NiriWindow,
        workspaceId: WorkspaceDescriptor.ID
    ) -> CGFloat {
        if column.cachedHeight > 0 {
            return column.cachedHeight
        }
        if let height = column.frame?.height, height > 0 {
            return height
        }
        if let height = column.renderedFrame?.height, height > 0 {
            return height
        }
        if let height = window.frame?.height, height > 0 {
            return height
        }
        return projectedHeightBounds(for: column, workspaceId: workspaceId).min
    }

    private func calculateHorizontalPixelsPerWeightUnit(
        column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.widthWeight }
        guard totalWeight > 0 else { return 0 }

        let tabOffset = column.isTabbed && windows.count > 1 ? renderStyle.tabIndicatorWidth : 0
        let totalGaps = CGFloat(windows.count + 1) * gaps.horizontal
        let usableWidth = monitorFrame.width - tabOffset - totalGaps

        return usableWidth / totalWeight
    }

    func interactiveResizeBegin(
        windowId: NodeId,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation,
        viewOffset: CGFloat? = nil
    ) -> Bool {
        guard interactiveResize == nil else { return false }
        guard interactiveMove == nil else { return false }

        guard let windowNode = findNode(by: windowId, in: workspaceId) as? NiriWindow else { return false }
        guard isProjectedFocusableWindow(windowNode, in: workspaceId) else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }
        if windowNode.isFullscreen {
            return false
        }

        if windowNode.constraints.isFixed {
            return false
        }

        let originalContainerSpan: CGFloat?
        let originalWindowBaseline: InteractiveResize.WindowBaseline?
        switch orientation {
        case .horizontal:
            originalContainerSpan = edges.hasHorizontal
                ? interactiveResizeStartWidth(for: column, window: windowNode, workspaceId: workspaceId)
                : nil
            originalWindowBaseline = edges.hasVertical ? .weight(windowNode.size) : nil
        case .vertical:
            originalContainerSpan = edges.hasVertical
                ? interactiveResizeStartHeight(for: column, window: windowNode, workspaceId: workspaceId)
                : nil
            if edges.hasHorizontal,
               let singleWindowContext = singleWindowLayoutContext(
                   in: workspaceId,
                   excluding: projectionExclusions(in: workspaceId)
               ),
               singleWindowContext.container === column
            {
                originalWindowBaseline = .fixedPixels(
                    windowNode.resolvedWidth
                        ?? windowNode.frame?.width
                        ?? windowNode.renderedFrame?.width
                        ?? windowNode.widthWeight
                )
            } else {
                originalWindowBaseline = edges.hasHorizontal ? .weight(windowNode.widthWeight) : nil
            }
        }
        let isLeadingPrimaryEdge = switch orientation {
        case .horizontal: edges.contains(.left)
        case .vertical: edges.contains(.bottom)
        }

        interactiveResize = InteractiveResize(
            windowId: windowId,
            workspaceId: workspaceId,
            originalContainerSpan: originalContainerSpan,
            originalWindowBaseline: originalWindowBaseline,
            edges: edges,
            startMouseLocation: startLocation,
            columnIndex: colIdx,
            orientation: orientation,
            originalViewOffset: isLeadingPrimaryEdge ? viewOffset : nil
        )

        NiriLayoutTrace.record(
            .resize,
            workspaceId: workspaceId,
            "begin win=\(windowId) col=\(colIdx) edges=\(String(describing: edges))"
        )
        return true
    }

    func interactiveResizeUpdate(
        currentLocation: CGPoint,
        monitorFrame: CGRect,
        gaps: LayoutGaps,
        viewportState: ((inout ViewportState) -> Void) -> Void = { _ in }
    ) -> Bool {
        guard let resize = interactiveResize else { return false }

        guard let windowNode = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow else {
            clearInteractiveResize()
            return false
        }

        guard let column = findColumn(containing: windowNode, in: resize.workspaceId) else {
            clearInteractiveResize()
            return false
        }

        let delta = CGPoint(
            x: currentLocation.x - resize.startMouseLocation.x,
            y: currentLocation.y - resize.startMouseLocation.y
        )

        var changed = false

        switch resize.orientation {
        case .horizontal:
            if resize.edges.hasHorizontal, let originalWidth = resize.originalContainerSpan {
                column.widthAnimation = nil
                column.targetWidth = nil

                var dx = delta.x

                if resize.edges.contains(.left) {
                    dx = -dx
                }

                let widthBounds = projectedWidthBounds(for: column, workspaceId: resize.workspaceId)
                let minWidth = widthBounds.min
                let viewportMaxWidth = monitorFrame.width - gaps.horizontal
                let maxWidth = max(
                    minWidth,
                    min(viewportMaxWidth, widthBounds.max ?? viewportMaxWidth)
                )

                let newWidth = originalWidth + dx
                column.cachedWidth = newWidth.clamped(to: minWidth ... maxWidth)
                column.width = .fixed(column.cachedWidth)
                column.presetWidthIdx = nil
                column.isFullWidth = false
                column.savedWidth = nil
                column.hasManualSingleWindowWidthOverride = true
                changed = true

                if resize.edges.contains(.left), let origOffset = resize.originalViewOffset {
                    let widthDelta = column.cachedWidth - originalWidth
                    viewportState { state in
                        state.jumpOffset(to: origOffset + widthDelta)
                    }
                }
            }

            if resize.edges.hasVertical,
               case let .weight(originalHeight)? = resize.originalWindowBaseline
            {
                var dy = delta.y

                if resize.edges.contains(.bottom) {
                    dy = -dy
                }

                let pixelsPerWeight = calculateVerticalPixelsPerWeightUnit(
                    column: column,
                    workspaceId: resize.workspaceId,
                    monitorFrame: monitorFrame,
                    gaps: gaps
                )

                if pixelsPerWeight > 0 {
                    let weightDelta = dy / pixelsPerWeight
                    let newWeight = originalHeight + weightDelta
                    windowNode.size = newWeight.clamped(
                        to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                    )
                    changed = true
                }
            }
        case .vertical:
            if resize.edges.hasHorizontal, let windowBaseline = resize.originalWindowBaseline {
                var dx = delta.x

                if resize.edges.contains(.left) {
                    dx = -dx
                }

                switch windowBaseline {
                case let .fixedPixels(originalWidth):
                    let constraints = windowNode.constraints.normalized()
                    let minWidth = constraints.minSize.width
                    let viewportMaxWidth = monitorFrame.width - gaps.horizontal
                    let constrainedMaxWidth = constraints.hasMaxWidth
                        ? constraints.maxSize.width
                        : viewportMaxWidth
                    let maxWidth = max(minWidth, min(viewportMaxWidth, constrainedMaxWidth))
                    let newWidth = (originalWidth + dx).clamped(to: minWidth ... maxWidth)
                    windowNode.windowWidth = .fixed(newWidth)
                    changed = true
                case let .weight(originalWidthWeight):
                    let pixelsPerWeight = calculateHorizontalPixelsPerWeightUnit(
                        column: column,
                        workspaceId: resize.workspaceId,
                        monitorFrame: monitorFrame,
                        gaps: gaps
                    )

                    if pixelsPerWeight > 0 {
                        let weightDelta = dx / pixelsPerWeight
                        let newWeight = (originalWidthWeight + weightDelta).clamped(
                            to: resizeConfiguration.minWindowWeight ... resizeConfiguration.maxWindowWeight
                        )
                        let constrainedWidth = windowNode.constraints.clampWidth(
                            newWeight * pixelsPerWeight
                        )
                        windowNode.windowWidth = .auto(weight: constrainedWidth / pixelsPerWeight)
                        changed = true
                    }
                }
            }

            if resize.edges.hasVertical, let originalHeight = resize.originalContainerSpan {
                var dy = delta.y

                if resize.edges.contains(.bottom) {
                    dy = -dy
                }

                let heightBounds = projectedHeightBounds(for: column, workspaceId: resize.workspaceId)
                let minHeight = heightBounds.min
                let viewportMaxHeight = monitorFrame.height - gaps.vertical
                let maxHeight = max(
                    minHeight,
                    min(viewportMaxHeight, heightBounds.max ?? viewportMaxHeight)
                )

                let newHeight = originalHeight + dy
                column.cachedHeight = newHeight.clamped(to: minHeight ... maxHeight)
                column.height = .fixed(column.cachedHeight)
                column.isFullHeight = false
                column.savedHeight = nil
                column.hasManualSingleWindowHeightOverride = true
                changed = true

                if resize.edges.contains(.bottom), let origOffset = resize.originalViewOffset {
                    let heightDelta = column.cachedHeight - originalHeight
                    viewportState { state in
                        state.jumpOffset(to: origOffset + heightDelta)
                    }
                }
            }
        }

        return changed
    }

    func projectedWidthBounds(
        for column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (min: CGFloat, max: CGFloat?) {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        var minimum: CGFloat = 1
        var maximum: CGFloat?
        for window in windows {
            let constraints = window.constraints.normalized()
            minimum = max(minimum, constraints.minSize.width)
            if constraints.hasMaxWidth {
                maximum = min(maximum ?? constraints.maxSize.width, constraints.maxSize.width)
            }
        }
        let contentInset = column.isTabbed && windows.count > 1 ? tabContentInset(for: column) : 0
        return (
            minimum + contentInset,
            maximum.map { max($0, minimum) + contentInset }
        )
    }

    func projectedHeightBounds(
        for column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID
    ) -> (min: CGFloat, max: CGFloat?) {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        var minimum: CGFloat = 1
        var maximum: CGFloat?
        for window in windows {
            let constraints = window.constraints.normalized()
            minimum = max(minimum, constraints.minSize.height)
            if constraints.hasMaxHeight {
                maximum = min(maximum ?? constraints.maxSize.height, constraints.maxSize.height)
            }
        }
        return (minimum, maximum.map { max($0, minimum) })
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        assertSanctionedMutation()
        guard let resize = interactiveResize else { return }

        if let windowId, windowId != resize.windowId {
            return
        }

        interactiveResize = nil
        if let windowNode = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow {
            ensureSelectionVisible(
                node: windowNode,
                in: resize.workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: resize.orientation
            )
            if resize.originalContainerSpan != nil {
                recoverSettledCoverage(
                    in: resize.workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: resize.orientation
                )
            }
        }

        NiriLayoutTrace.record(.resize, workspaceId: resize.workspaceId, "end win=\(resize.windowId)")
    }
}
