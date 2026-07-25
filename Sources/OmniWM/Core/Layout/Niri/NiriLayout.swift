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
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowToken: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation
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
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil
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
            settledVisibilityOffset: settledVisibilityOffset
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
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = [],
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil
    ) {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

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

        if let singleWindowContext = singleWindowLayoutContext(in: workspaceId) {
            layoutSingleWindowWorkspace(
                singleWindowContext,
                workingFrame: workingFrame,
                fullscreenLayoutFrame: fullscreenLayoutFrame,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                workspaceOffset: workspaceOffset,
                scale: effectiveScale,
                gaps: gaps.horizontal,
                screenClampRect: viewFrame,
                time: time,
                result: &frames,
                orientation: orientation
            )
            return
        }

        for container in containers {
            switch orientation {
            case .horizontal:
                if container.cachedWidth <= 0 {
                    container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: primaryGap)
                }
            case .vertical:
                if container.cachedHeight <= 0 {
                    container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: primaryGap)
                }
            }
        }

        let containerSpans: [CGFloat] = switch orientation {
        case .horizontal: containers.map { $0.cachedWidth }
        case .vertical: containers.map { $0.cachedHeight }
        }
        let containerRenderOffsets = containers.map { $0.renderOffset(at: time) }
        let containerWindowNodes = containers.map { $0.windowNodes }

        var containerPositions = [CGFloat]()
        containerPositions.reserveCapacity(containers.count)
        var runningPos: CGFloat = 0
        for i in 0 ..< containers.count {
            containerPositions.append(runningPos)
            let span = containerSpans[i]
            runningPos += span + primaryGap
        }

        let viewOffset = viewOffsetOverride ?? state.viewOffset
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let activePos = containers.isEmpty ? 0 : containerPositions[activeIdx]
        let viewPos = activePos + viewOffset
        let visibilityViewPositions: [CGFloat] = settledVisibilityOffset.map {
            [activePos + $0, viewPos]
        } ?? [viewPos]
        let revealMargin: CGFloat = switch orientation {
        case .horizontal: workingFrame.width * 0.25
        case .vertical: workingFrame.height * 0.25
        }

        for idx in 0 ..< containers.count {
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
                let clampedVisibilityRect = monitorPlaneClampedFrame(
                    visibilityRect,
                    screenClampRect: viewFrame,
                    orientation: orientation
                )
                if let liveOverflowEdge = overflowEdgeIntersectingNeighboringMonitor(
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
                if containers[idx].isTabbed {
                    let parkEdge = hiddenEdge(
                        for: visibilityRect,
                        viewportFrame: workingFrame,
                        fallback: idx == 0 ? .minimum : .maximum,
                        orientation: orientation
                    )
                    for window in containerWindowNodes[idx] where window.isHiddenInTabbedMode {
                        hiddenHandles[window.token] = parkEdge.encodedHideSide
                    }
                }
            case let .hidden(hiddenEdge):
                for window in containerWindowNodes[idx] {
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
                container: containers[idx],
                canonicalContainerRect: canonicalContainerRect,
                renderedContainerRect: renderedContainerRect,
                fullscreenRect: canonicalFullscreenRect,
                renderedFullscreenRect: renderedFullscreenRect,
                secondaryGap: secondaryGap,
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
        if let overflowEdge = overflowEdgeIntersectingNeighboringMonitor(
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

    private func overflowEdgeIntersectingNeighboringMonitor(
        _ renderedRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> AxisHideEdge? {
        let minimumOverflow: CGRect?
        let maximumOverflow: CGRect?
        switch orientation {
        case .horizontal:
            let minimumMaxX = min(renderedRect.maxX, viewportFrame.minX)
            minimumOverflow = minimumMaxX > renderedRect.minX
                ? CGRect(
                    x: renderedRect.minX,
                    y: renderedRect.minY,
                    width: minimumMaxX - renderedRect.minX,
                    height: renderedRect.height
                )
                : nil
            let maximumMinX = max(renderedRect.minX, viewportFrame.maxX)
            maximumOverflow = renderedRect.maxX > maximumMinX
                ? CGRect(
                    x: maximumMinX,
                    y: renderedRect.minY,
                    width: renderedRect.maxX - maximumMinX,
                    height: renderedRect.height
                )
                : nil
        case .vertical:
            let minimumMaxY = min(renderedRect.maxY, viewportFrame.minY)
            minimumOverflow = minimumMaxY > renderedRect.minY
                ? CGRect(
                    x: renderedRect.minX,
                    y: renderedRect.minY,
                    width: renderedRect.width,
                    height: minimumMaxY - renderedRect.minY
                )
                : nil
            let maximumMinY = max(renderedRect.minY, viewportFrame.maxY)
            maximumOverflow = renderedRect.maxY > maximumMinY
                ? CGRect(
                    x: renderedRect.minX,
                    y: maximumMinY,
                    width: renderedRect.width,
                    height: renderedRect.maxY - maximumMinY
                )
                : nil
        }

        if let minimumOverflow {
            for otherMonitor in hiddenPlacementMonitors where !ownsViewport(
                otherMonitor,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                viewportFrame: viewportFrame
            ) {
                if minimumOverflow.intersects(otherMonitor.frame) {
                    return .minimum
                }
            }
        }

        if let maximumOverflow {
            for otherMonitor in hiddenPlacementMonitors where !ownsViewport(
                otherMonitor,
                hiddenPlacementMonitor: hiddenPlacementMonitor,
                viewportFrame: viewportFrame
            ) {
                if maximumOverflow.intersects(otherMonitor.frame) {
                    return .maximum
                }
            }
        }

        return nil
    }

    private func ownsViewport(
        _ candidateMonitor: HiddenPlacementMonitorContext,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        viewportFrame: CGRect
    ) -> Bool {
        if let hiddenPlacementMonitor {
            return candidateMonitor.id == hiddenPlacementMonitor.id
        }

        return candidateMonitor.frame.intersects(viewportFrame)
            || candidateMonitor.visibleFrame.intersects(viewportFrame)
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
                    scale: scale,
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
                    scale: scale,
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
        width: CGFloat,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: workingFrame.minX + (workingFrame.width - width) / 2,
            y: workingFrame.minY,
            width: width,
            height: workingFrame.height
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
        gaps: CGFloat
    ) -> CGRect {
        let minSize = context.window.constraints.normalized().minSize
        guard context.container.hasManualSingleWindowWidthOverride else {
            let baseFrame = context.fit.mode == .fill ? fullscreenLayoutFrame ?? workingFrame : workingFrame
            return rectExpandedToMinimum(context.fit.frame(in: baseFrame), minSize: minSize)
                .roundedToPhysicalPixels(scale: scale)
        }

        if context.container.cachedWidth <= 0 {
            context.container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: gaps)
        }

        let resolvedWidth = min(workingFrame.width, max(0, context.container.cachedWidth))
        return rectExpandedToMinimum(
            centeredSingleWindowRect(in: workingFrame, width: resolvedWidth, scale: scale),
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
        gaps: CGFloat,
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
            gaps: gaps
        )
        let renderOffset = context.container.renderOffset(at: time)
        let renderedRect = canonicalRect
            .offsetBy(dx: workspaceOffset + renderOffset.x, dy: renderOffset.y)
            .roundedToPhysicalPixels(scale: scale)

        layoutContainer(
            container: context.container,
            canonicalContainerRect: canonicalRect,
            renderedContainerRect: renderedRect,
            fullscreenRect: fullscreenRect,
            renderedFullscreenRect: renderedFullscreenRect,
            secondaryGap: 0,
            scale: scale,
            screenClampRect: screenClampRect,
            animationTime: time,
            result: &result,
            orientation: orientation
        )
    }

    private func layoutContainer(
        container: NiriContainer,
        canonicalContainerRect: CGRect,
        renderedContainerRect: CGRect,
        fullscreenRect: CGRect,
        renderedFullscreenRect: CGRect,
        secondaryGap: CGFloat,
        scale: CGFloat,
        screenClampRect: CGRect,
        animationTime: TimeInterval? = nil,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        container.frame = canonicalContainerRect
        container.renderedFrame = renderedContainerRect

        let tabOffset = container.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: canonicalContainerRect.origin.x + tabOffset,
            y: canonicalContainerRect.origin.y,
            width: max(0, canonicalContainerRect.width - tabOffset),
            height: canonicalContainerRect.height
        )

        let windows = container.windowNodes
        guard !windows.isEmpty else { return }

        let isTabbed = container.isTabbed
        let time = animationTime ?? CACurrentMediaTime()

        let availableSpace: CGFloat = switch orientation {
        case .horizontal: contentRect.height
        case .vertical: contentRect.width
        }

        let resolvedSpans = resolveWindowSpans(
            windows: windows,
            availableSpace: availableSpace,
            gap: secondaryGap,
            isTabbed: isTabbed,
            orientation: orientation
        )

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
            animatedFrame = monitorPlaneClampedFrame(
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

    private func monitorPlaneClampedFrame(
        _ frame: CGRect,
        screenClampRect: CGRect,
        orientation: Monitor.Orientation
    ) -> CGRect {
        var clampedFrame = frame
        switch orientation {
        case .horizontal:
            let minX = screenClampRect.minX - clampedFrame.width + 1
            let maxX = screenClampRect.maxX - 1
            if maxX >= minX {
                clampedFrame.origin.x = min(max(clampedFrame.origin.x, minX), maxX)
            }
        case .vertical:
            let minY = screenClampRect.minY - clampedFrame.height + 1
            let maxY = screenClampRect.maxY - 1
            if maxY >= minY {
                clampedFrame.origin.y = min(max(clampedFrame.origin.y, minY), maxY)
            }
        }
        return clampedFrame
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
                        presetWindowHeights,
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
                        presetWindowHeights,
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
