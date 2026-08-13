// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}

struct LayoutResult {
    let frames: [WindowToken: CGRect]
    let hiddenHandles: [WindowToken: HideSide]
}

private enum ContainerVisibilityState {
    case visible
    case hidden(AxisHideEdge)
}

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation,
        excludedTokens: Set<WindowToken>? = nil
    ) -> [WindowToken: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            excludedTokens: excludedTokens
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        excludedTokens: Set<WindowToken>? = nil
    ) -> LayoutResult {
        var frames: [WindowToken: CGRect] = [:]
        var hiddenHandles: [WindowToken: HideSide] = [:]
        calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            excludedTokens: excludedTokens
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowToken: CGRect],
        hiddenHandles: inout [WindowToken: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        excludedTokens: Set<WindowToken>? = nil
    ) {
        if let excludedTokens {
            setProjectionExclusions(excludedTokens, in: workspaceId)
        }
        let excludedTokens = projectionExclusions(in: workspaceId)
        let projectedColumns = projectedColumns(in: workspaceId)
        guard !projectedColumns.isEmpty else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let fullscreenLayoutFrame = workingArea?.fullscreenLayoutFrame ?? workingFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let primaryGap: CGFloat
        let secondaryGap: CGFloat
        switch orientation {
        case .horizontal:
            primaryGap = gaps.horizontal
            secondaryGap = gaps.vertical
        case .vertical:
            primaryGap = gaps.vertical
            secondaryGap = gaps.horizontal
        }

        let time = animationTime ?? CACurrentMediaTime()
        let workspaceOffset: CGFloat = 0
        let canonicalFullscreenRect = fullscreenLayoutFrame.roundedToPhysicalPixels(scale: effectiveScale)
        let renderedFullscreenRect = canonicalFullscreenRect
            .offsetBy(dx: workspaceOffset, dy: 0)
            .roundedToPhysicalPixels(scale: effectiveScale)

        if !excludedTokens.isEmpty {
            for column in columns(in: workspaceId)
                where column.windowNodes.allSatisfy({ excludedTokens.contains($0.token) })
            {
                column.frame = nil
                column.renderedFrame = nil
            }
        }

        if let singleWindowContext = singleWindowLayoutContext(
            in: workspaceId,
            excluding: excludedTokens
        ) {
            layoutSingleWindowWorkspace(
                singleWindowContext,
                workingFrame: workingFrame,
                fullscreenLayoutFrame: fullscreenLayoutFrame,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                workspaceOffset: workspaceOffset,
                scale: effectiveScale,
                primaryGap: primaryGap,
                secondaryGap: secondaryGap,
                screenClampRect: viewFrame,
                time: time,
                result: &frames,
                orientation: orientation
            )
            return
        }

        for projectedColumn in projectedColumns
            where projectedColumn.windows.count == projectedColumn.column.windowNodes.count
        {
            switch orientation {
            case .horizontal:
                if projectedColumn.column.cachedWidth <= 0 {
                    projectedColumn.column.resolveAndCacheWidth(
                        workingAreaWidth: workingFrame.width,
                        gaps: primaryGap,
                        contentInset: projectedColumn.windows.count > 1
                            ? tabContentInset(for: projectedColumn.column)
                            : 0
                    )
                }
            case .vertical:
                if projectedColumn.column.cachedHeight <= 0 {
                    projectedColumn.column.resolveAndCacheHeight(
                        workingAreaHeight: workingFrame.height,
                        gaps: primaryGap
                    )
                }
            }
        }

        let containerSpans = projectedColumns.map {
            projectedPrimarySpan(
                for: $0,
                workingFrame: workingFrame,
                gap: primaryGap,
                orientation: orientation
            )
        }
        let containerRenderOffsets = projectedColumns.map { $0.column.renderOffset(at: time) }

        var containerPositions = [CGFloat]()
        containerPositions.reserveCapacity(projectedColumns.count)
        var runningPos: CGFloat = 0
        for i in 0 ..< projectedColumns.count {
            containerPositions.append(runningPos)
            let span = containerSpans[i]
            runningPos += span + primaryGap
        }

        let viewOffset = viewOffsetOverride ?? state.viewOffset
        let activeIdx = projectedActiveColumnIndex(
            state: state,
            columns: projectedColumns,
            in: workspaceId
        )
        let activePos = containerPositions[activeIdx]
        let viewPos = activePos + viewOffset
        let visibilityViewPositions: [CGFloat] = settledVisibilityOffset.map {
            [activePos + $0, viewPos]
        } ?? [viewPos]
        let revealMargin: CGFloat = switch orientation {
        case .horizontal: workingFrame.width * 0.25
        case .vertical: workingFrame.height * 0.25
        }

        for idx in 0 ..< projectedColumns.count {
            let projectedColumn = projectedColumns[idx]
            let containerPos = containerPositions[idx]
            let containerSpan = containerSpans[idx]
            let renderOffset = containerRenderOffsets[idx]
            let canonicalContainerRect = canonicalContainerRect(
                position: containerPos,
                span: containerSpan,
                workingFrame: workingFrame,
                scale: effectiveScale,
                orientation: orientation
            )
            let visibilityRect = visibleRenderedContainerRect(
                canonicalRect: canonicalContainerRect,
                viewPosition: viewPos,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                scale: effectiveScale,
                orientation: orientation
            )
            var visibilityState = sampledContainerVisibilityState(
                canonicalRect: canonicalContainerRect,
                viewPositions: visibilityViewPositions,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                viewportFrame: workingFrame,
                revealMargin: revealMargin,
                fallback: idx == 0 ? .minimum : .maximum,
                scale: effectiveScale,
                orientation: orientation,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
            if case .visible = visibilityState {
                let clampedVisibilityRect = NiriMonitorPlaneGeometry.clampedFrame(
                    visibilityRect,
                    screenClampRect: viewFrame,
                    orientation: orientation
                )
                if let liveOverflowEdge = NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
                    clampedVisibilityRect,
                    viewportFrame: workingFrame,
                    orientation: orientation,
                    hiddenPlacementMonitor: hiddenPlacementMonitor,
                    hiddenPlacementMonitors: hiddenPlacementMonitors
                ) {
                    visibilityState = .hidden(liveOverflowEdge)
                }
            }
            let renderedContainerRect: CGRect
            switch visibilityState {
            case .visible:
                renderedContainerRect = visibilityRect
                if projectedColumn.column.isTabbed, projectedColumn.windows.count > 1 {
                    let parkEdge = hiddenEdge(
                        for: visibilityRect,
                        viewportFrame: workingFrame,
                        fallback: idx == 0 ? .minimum : .maximum,
                        orientation: orientation
                    )
                    let activeWindow = projectedActiveWindow(in: projectedColumn)
                    for window in projectedColumn.windows where window !== activeWindow {
                        hiddenHandles[window.token] = parkEdge.encodedHideSide
                    }
                }
            case let .hidden(hiddenEdge):
                for window in projectedColumn.windows {
                    hiddenHandles[window.token] = hiddenEdge.encodedHideSide
                }
                renderedContainerRect = hiddenRenderedContainerRect(
                    canonicalRect: canonicalContainerRect,
                    edge: hiddenEdge,
                    viewFrame: viewFrame,
                    scale: effectiveScale,
                    orientation: orientation,
                    hiddenPlacementMonitor: hiddenPlacementMonitor,
                    hiddenPlacementMonitors: hiddenPlacementMonitors
                )
            }

            layoutContainer(
                container: projectedColumn.column,
                windows: projectedColumn.windows,
                canonicalContainerRect: canonicalContainerRect,
                renderedContainerRect: renderedContainerRect,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                secondaryGap: secondaryGap,
                secondarySpanOverride: nil,
                scale: effectiveScale,
                screenClampRect: viewFrame,
                animationTime: time,
                result: &frames,
                orientation: orientation
            )
        }
    }

    private func canonicalContainerRect(
        position: CGFloat,
        span: CGFloat,
        workingFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            let width = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x + position,
                y: workingFrame.origin.y,
                width: width,
                height: workingFrame.height
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            let height = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x,
                y: workingFrame.origin.y + position,
                width: workingFrame.width,
                height: height
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func visibleRenderedContainerRect(
        canonicalRect: CGRect,
        viewPosition: CGFloat,
        workspaceOffset: CGFloat,
        renderOffset: CGPoint,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let translation: CGPoint = switch orientation {
        case .horizontal:
            CGPoint(
                x: -viewPosition + workspaceOffset + renderOffset.x,
                y: renderOffset.y
            )
        case .vertical:
            CGPoint(
                x: workspaceOffset + renderOffset.x,
                y: -viewPosition + renderOffset.y
            )
        }
        return canonicalRect.offsetBy(dx: translation.x, dy: translation.y)
            .roundedToPhysicalPixels(scale: scale)
    }

    private func sampledContainerVisibilityState(
        canonicalRect: CGRect,
        viewPositions: [CGFloat],
        workspaceOffset: CGFloat,
        renderOffset: CGPoint,
        viewportFrame: CGRect,
        revealMargin: CGFloat,
        fallback: AxisHideEdge,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> ContainerVisibilityState {
        var settledHidden: ContainerVisibilityState?
        for viewPosition in viewPositions {
            let sampleRect = visibleRenderedContainerRect(
                canonicalRect: canonicalRect,
                viewPosition: viewPosition,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                scale: scale,
                orientation: orientation
            )
            let sampleState = containerVisibilityState(
                for: sampleRect,
                viewportFrame: viewportFrame,
                revealMargin: revealMargin,
                fallback: fallback,
                orientation: orientation,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                hiddenPlacementMonitors: hiddenPlacementMonitors
            )
            if case .visible = sampleState {
                return .visible
            }
            if settledHidden == nil {
                settledHidden = sampleState
            }
        }
        return settledHidden ?? .hidden(fallback)
    }

    private func containerVisibilityState(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        revealMargin: CGFloat,
        fallback: AxisHideEdge,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> ContainerVisibilityState {
        let defaultHideEdge = hiddenEdge(
            for: renderedRect,
            viewportFrame: viewportFrame,
            fallback: fallback,
            orientation: orientation
        )
        let revealViewport = switch orientation {
        case .horizontal: viewportFrame.insetBy(dx: -revealMargin, dy: 0)
        case .vertical: viewportFrame.insetBy(dx: 0, dy: -revealMargin)
        }
        guard containerIntersectsViewport(
            renderedRect,
            viewportFrame: revealViewport,
            orientation: orientation
        ) else {
            return .hidden(defaultHideEdge)
        }
        if let overflowEdge = NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
            renderedRect,
            viewportFrame: viewportFrame,
            orientation: orientation,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) {
            return .hidden(overflowEdge)
        }
        return .visible
    }

    private func containerIntersectsViewport(
        _ containerRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> Bool {
        switch orientation {
        case .horizontal:
            containerRect.maxX > viewportFrame.minX && containerRect.minX < viewportFrame.maxX
        case .vertical:
            containerRect.maxY > viewportFrame.minY && containerRect.minY < viewportFrame.maxY
        }
    }

    private func hiddenEdge(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        fallback: AxisHideEdge,
        orientation: Monitor.Orientation
    ) -> AxisHideEdge {
        switch orientation {
        case .horizontal:
            let leftOverflow = viewportFrame.minX - renderedRect.minX
            let rightOverflow = renderedRect.maxX - viewportFrame.maxX
            if leftOverflow > rightOverflow, leftOverflow > 0 {
                return .minimum
            }
            if rightOverflow > leftOverflow, rightOverflow > 0 {
                return .maximum
            }
        case .vertical:
            let topOverflow = viewportFrame.minY - renderedRect.minY
            let bottomOverflow = renderedRect.maxY - viewportFrame.maxY
            if topOverflow > bottomOverflow, topOverflow > 0 {
                return .minimum
            }
            if bottomOverflow > topOverflow, bottomOverflow > 0 {
                return .maximum
            }
        }
        return fallback
    }

    private func hiddenRenderedContainerRect(
        canonicalRect: CGRect,
        edge: AxisHideEdge,
        viewFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            if let hiddenPlacementMonitor {
                return HiddenWindowPlacementResolver.placement(
                    for: canonicalRect.size,
                    requestedEdge: edge,
                    orthogonalOrigin: canonicalRect.minY,
                    baseReveal: 1.0,
                    orientation: .horizontal,
                    monitor: hiddenPlacementMonitor,
                    monitors: hiddenPlacementMonitors
                )
                .frame(for: canonicalRect.size)
                .roundedToPhysicalPixels(scale: scale)
            }

            return hiddenColumnRect(
                edge: edge,
                width: canonicalRect.width,
                height: canonicalRect.height,
                screenY: canonicalRect.minY,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            if let hiddenPlacementMonitor {
                return HiddenWindowPlacementResolver.placement(
                    for: canonicalRect.size,
                    requestedEdge: edge,
                    orthogonalOrigin: canonicalRect.minX,
                    baseReveal: 1.0,
                    orientation: .vertical,
                    monitor: hiddenPlacementMonitor,
                    monitors: hiddenPlacementMonitors
                )
                .frame(for: canonicalRect.size)
                .roundedToPhysicalPixels(scale: scale)
            }

            return hiddenRowRect(
                edge: edge,
                width: canonicalRect.width,
                height: canonicalRect.height,
                screenX: canonicalRect.minX,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func centeredSingleWindowRect(
        in workingFrame: CGRect,
        size: CGSize,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: workingFrame.minX + (workingFrame.width - size.width) / 2,
            y: workingFrame.minY + (workingFrame.height - size.height) / 2,
            width: size.width,
            height: size.height
        ).roundedToPhysicalPixels(scale: scale)
    }

    private func rectExpandedToMinimum(_ rect: CGRect, minSize: CGSize) -> CGRect {
        var expanded = rect
        if expanded.width < minSize.width {
            expanded.origin.x -= (minSize.width - expanded.width) / 2
            expanded.size.width = minSize.width
        }
        if expanded.height < minSize.height {
            expanded.origin.y -= (minSize.height - expanded.height) / 2
            expanded.size.height = minSize.height
        }
        return expanded
    }

    func resolvedSingleWindowRect(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        fullscreenLayoutFrame: CGRect? = nil,
        scale: CGFloat,
        primaryGap: CGFloat,
        secondaryGap: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let minSize = context.window.constraints.normalized().minSize
        let hasManualPrimaryOverride = switch orientation {
        case .horizontal:
            context.container.hasManualSingleWindowWidthOverride
        case .vertical:
            context.container.hasManualSingleWindowHeightOverride
        }
        let hasManualSecondaryOverride = orientation == .vertical && context.window.windowWidth != .default
        guard hasManualPrimaryOverride || hasManualSecondaryOverride else {
            let baseFrame = context.fit.usesFullscreenLayoutFrame ? fullscreenLayoutFrame ?? workingFrame : workingFrame
            return rectExpandedToMinimum(context.fit.frame(in: baseFrame), minSize: minSize)
                .roundedToPhysicalPixels(scale: scale)
        }

        let boundedSize: CGSize
        switch orientation {
        case .horizontal:
            if context.container.cachedWidth <= 0 {
                context.container.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: primaryGap,
                    contentInset: 0
                )
            }
            boundedSize = CGSize(
                width: min(workingFrame.width, max(0, context.container.cachedWidth)),
                height: workingFrame.height
            )
        case .vertical:
            let windowWidth: CGFloat
            if hasManualSecondaryOverride {
                windowWidth = switch context.window.windowWidth {
                case let .fixed(width):
                    width
                case let .preset(index):
                    resolvePresetSpan(
                        presetWindowSecondarySpans,
                        index: index,
                        availableSpace: workingFrame.width,
                        gap: secondaryGap
                    ) ?? workingFrame.width
                case .auto:
                    context.window.resolvedWidth ?? context.window.frame?.width ?? workingFrame.width
                }
            } else {
                windowWidth = workingFrame.width
            }
            if context.container.cachedHeight <= 0 {
                context.container.resolveAndCacheHeight(
                    workingAreaHeight: workingFrame.height,
                    gaps: primaryGap
                )
            }
            let tabOffset: CGFloat = 0
            let containerWidth = hasManualSecondaryOverride
                ? context.window.constraints.clampWidth(windowWidth) + tabOffset
                : windowWidth
            boundedSize = CGSize(
                width: min(workingFrame.width, max(0, containerWidth)),
                height: min(workingFrame.height, max(0, context.container.cachedHeight))
            )
        }
        return rectExpandedToMinimum(
            centeredSingleWindowRect(in: workingFrame, size: boundedSize, scale: scale),
            minSize: minSize
        ).roundedToPhysicalPixels(scale: scale)
    }

    private func layoutSingleWindowWorkspace(
        _ context: SingleWindowLayoutContext,
        workingFrame: CGRect,
        fullscreenLayoutFrame: CGRect,
        fullscreenRect: CGRect,
        renderedFullscreenRect: CGRect,
        workspaceOffset: CGFloat,
        scale: CGFloat,
        primaryGap: CGFloat,
        secondaryGap: CGFloat,
        screenClampRect: CGRect,
        time: TimeInterval,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        let canonicalRect = resolvedSingleWindowRect(
            for: context,
            in: workingFrame,
            fullscreenLayoutFrame: fullscreenLayoutFrame,
            scale: scale,
            primaryGap: primaryGap,
            secondaryGap: secondaryGap,
            orientation: orientation
        )
        let renderOffset = context.container.renderOffset(at: time)
        let renderedRect = canonicalRect
            .offsetBy(dx: workspaceOffset + renderOffset.x, dy: renderOffset.y)
            .roundedToPhysicalPixels(scale: scale)
        let tabOffset: CGFloat = 0
        let secondarySpanOverride: CGFloat? = if orientation == .vertical,
                                                 context.window.windowWidth != .default
        {
            max(0, canonicalRect.width - tabOffset)
        } else {
            nil
        }

        layoutContainer(
            container: context.container,
            windows: [context.window],
            canonicalContainerRect: canonicalRect,
            renderedContainerRect: renderedRect,
            fullscreenRect: fullscreenRect,
            renderedFullscreenRect: renderedFullscreenRect,
            secondaryGap: 0,
            secondarySpanOverride: secondarySpanOverride,
            scale: scale,
            screenClampRect: screenClampRect,
            animationTime: time,
            result: &result,
            orientation: orientation
        )
    }

    private func layoutContainer(
        container: NiriContainer,
        windows: [NiriWindow],
        canonicalContainerRect: CGRect,
        renderedContainerRect: CGRect,
        fullscreenRect: CGRect,
        renderedFullscreenRect: CGRect,
        secondaryGap: CGFloat,
        secondarySpanOverride: CGFloat?,
        scale: CGFloat,
        screenClampRect: CGRect,
        animationTime: TimeInterval? = nil,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        container.frame = canonicalContainerRect
        container.renderedFrame = renderedContainerRect

        guard !windows.isEmpty else { return }

        let isTabbed = container.isTabbed && windows.count > 1
        let tabOffset = isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: canonicalContainerRect.origin.x + tabOffset,
            y: canonicalContainerRect.origin.y,
            width: max(0, canonicalContainerRect.width - tabOffset),
            height: canonicalContainerRect.height
        )

        let time = animationTime ?? CACurrentMediaTime()

        let availableSpace: CGFloat = switch orientation {
        case .horizontal: contentRect.height
        case .vertical: contentRect.width
        }

        let resolvedSpans = if let secondarySpanOverride, windows.count == 1 {
            [secondarySpanOverride]
        } else {
            resolveWindowSpans(
                windows: windows,
                availableSpace: availableSpace,
                gap: secondaryGap,
                isTabbed: isTabbed,
                orientation: orientation
            )
        }

        let sizingModes = windows.map { $0.sizingMode }
        let windowRenderOffsets = windows.map { $0.renderOffset(at: time) }
        let windowTokens = windows.map { $0.token }

        var pos: CGFloat = switch orientation {
        case .horizontal: contentRect.origin.y
        case .vertical: contentRect.origin.x
        }
        pos += secondaryGap

        for i in 0 ..< windows.count {
            let span = resolvedSpans[i]
            let sizingMode = sizingModes[i]

            let frame: CGRect
            let renderedBaseFrame: CGRect
            let resolvedSpan: CGFloat
            switch sizingMode {
            case .fullscreen,
                 .maximized:
                frame = fullscreenRect.roundedToPhysicalPixels(scale: scale)
                renderedBaseFrame = renderedFullscreenRect
                resolvedSpan = switch orientation {
                case .horizontal: frame.height
                case .vertical: frame.width
                }
            case .normal:
                switch orientation {
                case .horizontal:
                    frame = CGRect(
                        x: contentRect.origin.x,
                        y: pos,
                        width: contentRect.width,
                        height: span
                    ).roundedToPhysicalPixels(scale: scale)
                case .vertical:
                    frame = CGRect(
                        x: pos,
                        y: contentRect.origin.y,
                        width: span,
                        height: contentRect.height
                    ).roundedToPhysicalPixels(scale: scale)
                }
                renderedBaseFrame = frame.offsetBy(
                    dx: renderedContainerRect.origin.x - canonicalContainerRect.origin.x,
                    dy: renderedContainerRect.origin.y - canonicalContainerRect.origin.y
                )
                .roundedToPhysicalPixels(scale: scale)
                resolvedSpan = span
            }

            windows[i].frame = frame
            switch orientation {
            case .horizontal:
                windows[i].resolvedHeight = resolvedSpan
            case .vertical:
                windows[i].resolvedWidth = resolvedSpan
            }

            var animatedFrame: CGRect
            switch sizingMode {
            case .fullscreen,
                 .maximized:
                animatedFrame = renderedBaseFrame
            case .normal:
                let windowOffset = windowRenderOffsets[i]
                var offsetFrame = renderedBaseFrame.offsetBy(dx: windowOffset.x, dy: windowOffset.y)
                switch orientation {
                case .horizontal:
                    let minY = renderedContainerRect.minY
                    let maxY = renderedContainerRect.maxY - offsetFrame.height
                    if maxY >= minY {
                        offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
                    }
                case .vertical:
                    let minX = renderedContainerRect.minX
                    let maxX = renderedContainerRect.maxX - offsetFrame.width
                    if maxX >= minX {
                        offsetFrame.origin.x = min(max(offsetFrame.origin.x, minX), maxX)
                    }
                    if let containmentFrame = windows[i].moveYContainmentFrame,
                       renderedBaseFrame.minY >= containmentFrame.minY,
                       renderedBaseFrame.maxY <= containmentFrame.maxY
                    {
                        let minY = containmentFrame.minY
                        let maxY = containmentFrame.maxY - offsetFrame.height
                        if maxY >= minY {
                            offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
                        }
                    }
                }
                animatedFrame = offsetFrame
            }
            animatedFrame = NiriMonitorPlaneGeometry.clampedFrame(
                animatedFrame,
                screenClampRect: screenClampRect,
                orientation: orientation
            )
            let roundedAnimatedFrame = animatedFrame.roundedToPhysicalPixels(scale: scale)
            windows[i].renderedFrame = roundedAnimatedFrame
            result[windowTokens[i]] = roundedAnimatedFrame

            if !isTabbed {
                pos += span
                if i < windows.count - 1 {
                    pos += secondaryGap
                }
            }
        }
    }

    private func resolveWindowSpans(
        windows: [NiriWindow],
        availableSpace: CGFloat,
        gap: CGFloat,
        isTabbed: Bool,
        orientation: Monitor.Orientation
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }

        let inputs: [NiriAxisSolver.Input] = windows.map { window in
            switch orientation {
            case .horizontal:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.height {
                case let .fixed(h):
                    isFixed = true
                    fixedValue = h
                case .auto:
                    isFixed = false
                    fixedValue = nil
                case let .preset(index):
                    isFixed = true
                    fixedValue = resolvePresetSpan(
                        presetWindowSecondarySpans,
                        index: index,
                        availableSpace: availableSpace,
                        gap: gap
                    )
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.heightWeight),
                    minConstraint: window.constraints.minSize.height,
                    maxConstraint: window.constraints.maxSize.height,
                    hasMaxConstraint: window.constraints.hasMaxHeight,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            case .vertical:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.windowWidth {
                case let .fixed(w):
                    isFixed = true
                    fixedValue = w
                case .auto:
                    isFixed = false
                    fixedValue = nil
                case let .preset(index):
                    isFixed = true
                    fixedValue = resolvePresetSpan(
                        presetWindowSecondarySpans,
                        index: index,
                        availableSpace: availableSpace,
                        gap: gap
                    )
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.widthWeight),
                    minConstraint: window.constraints.minSize.width,
                    maxConstraint: window.constraints.maxSize.width,
                    hasMaxConstraint: window.constraints.hasMaxWidth,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            }
        }

        let cacheKey = NiriAxisSolveKey(
            inputs: inputs,
            availableSpace: availableSpace,
            gap: gap,
            isTabbed: isTabbed
        )
        let outputs: [NiriAxisSolver.Output]
        if let cached = axisSolveCache[cacheKey] {
            outputs = cached
        } else {
            outputs = NiriAxisSolver.solve(
                windows: inputs,
                availableSpace: availableSpace,
                gapSize: gap,
                isTabbed: isTabbed
            )
            if axisSolveCache.count >= 256 {
                axisSolveCache.removeAll(keepingCapacity: true)
            }
            axisSolveCache[cacheKey] = outputs
        }

        for (i, output) in outputs.enumerated() {
            switch orientation {
            case .horizontal:
                windows[i].heightFixedByConstraint = output.wasConstrained
            case .vertical:
                windows[i].widthFixedByConstraint = output.wasConstrained
            }
        }

        return outputs.map(\.value)
    }

    private func resolvePresetSpan(
        _ presets: [PresetSize],
        index: Int,
        availableSpace: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        guard presets.indices.contains(index) else { return nil }
        switch presets[index].kind {
        case let .proportion(proportion):
            return (availableSpace - gap) * proportion - gap
        case let .fixed(value):
            return value
        }
    }

    private func hiddenRowRect(
        edge: AxisHideEdge,
        width: CGFloat,
        height: CGFloat,
        screenX: CGFloat,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let y: CGFloat
        switch edge {
        case .minimum:
            y = edgeFrame.minY - height + edgeReveal
        case .maximum:
            y = edgeFrame.maxY - edgeReveal
        }
        let origin = CGPoint(x: screenX, y: y)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func hiddenColumnRect(
        edge: AxisHideEdge,
        width: CGFloat,
        height: CGFloat,
        screenY: CGFloat,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let x: CGFloat
        switch edge {
        case .minimum:
            x = edgeFrame.minX - width + edgeReveal
        case .maximum:
            x = edgeFrame.maxX - edgeReveal
        }
        let origin = CGPoint(x: x, y: screenY)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
