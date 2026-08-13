// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum NiriMonitorPlaneGeometry {
    static func clampedFrame(
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

    static func overflowEdgeIntersectingNeighboringMonitor(
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

    private static func ownsViewport(
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
}

struct NiriSettledCoverageEvaluator {
    struct Input {
        let containerSpans: [CGFloat]
        let selectedIndex: Int
        let activeIndex: Int
        let semanticOffset: CGFloat
        let gap: CGFloat
        let workingFrame: CGRect
        let sourceMonitor: HiddenPlacementMonitorContext
        let monitors: [HiddenPlacementMonitorContext]
        let orientation: Monitor.Orientation
        let scale: CGFloat
    }

    private struct Score {
        let selectedVisibility: CGFloat
        let coverage: CGFloat
        let movement: CGFloat
        let rank: Int
    }

    static func bestOffset(for input: Input) -> CGFloat {
        guard input.containerSpans.indices.contains(input.selectedIndex),
              input.containerSpans.indices.contains(input.activeIndex)
        else {
            return input.semanticOffset
        }

        let scale = max(1, input.scale)
        let pixel = 1 / scale
        let selectedPosition = containerPosition(
            at: input.selectedIndex,
            spans: input.containerSpans,
            gap: input.gap
        )
        let activePosition = containerPosition(
            at: input.activeIndex,
            spans: input.containerSpans,
            gap: input.gap
        )
        let selectedSpan = input.containerSpans[input.selectedIndex]
        let viewportSpan = primarySpan(of: input.workingFrame, orientation: input.orientation)
        let padding = ((viewportSpan - selectedSpan) / 2).clamped(to: 0 ... input.gap)
        let leadingOffset = (
            selectedPosition - activePosition - padding
        ).roundedToPhysicalPixel(scale: scale)
        let trailingOffset = (
            selectedPosition - activePosition - (viewportSpan - padding - selectedSpan)
        ).roundedToPhysicalPixel(scale: scale)
        var bestOffset = input.semanticOffset
        var bestScore = score(offset: input.semanticOffset, rank: 0, input: input)

        let leadingScore = score(offset: leadingOffset, rank: 1, input: input)
        if isBetter(leadingScore, than: bestScore, pixel: pixel) {
            bestOffset = leadingOffset
            bestScore = leadingScore
        }

        let trailingScore = score(offset: trailingOffset, rank: 2, input: input)
        if isBetter(trailingScore, than: bestScore, pixel: pixel) {
            bestOffset = trailingOffset
        }

        return bestOffset
    }

    private static func score(
        offset: CGFloat,
        rank: Int,
        input: Input
    ) -> Score {
        let activePosition = containerPosition(
            at: input.activeIndex,
            spans: input.containerSpans,
            gap: input.gap
        )
        let viewPosition = activePosition + offset
        let revealFrame: CGRect = switch input.orientation {
        case .horizontal:
            input.workingFrame.insetBy(dx: -input.workingFrame.width * 0.25, dy: 0)
        case .vertical:
            input.workingFrame.insetBy(dx: 0, dy: -input.workingFrame.height * 0.25)
        }
        var position: CGFloat = 0
        var coverage: CGFloat = 0
        var coveredEnd = primaryOrigin(of: input.workingFrame, orientation: input.orientation)
        var selectedVisibility: CGFloat = 0

        for index in input.containerSpans.indices {
            let span = input.containerSpans[index]
            let renderedRect = renderedContainerRect(
                position: position,
                span: span,
                viewPosition: viewPosition,
                workingFrame: input.workingFrame,
                scale: max(1, input.scale),
                orientation: input.orientation
            )

            if primaryIntersects(
                renderedRect,
                revealFrame,
                orientation: input.orientation
            ), NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
                renderedRect,
                viewportFrame: input.workingFrame,
                orientation: input.orientation,
                hiddenPlacementMonitor: input.sourceMonitor,
                hiddenPlacementMonitors: input.monitors
            ) == nil {
                let clampedRect = NiriMonitorPlaneGeometry.clampedFrame(
                    renderedRect,
                    screenClampRect: input.sourceMonitor.frame,
                    orientation: input.orientation
                )
                if NiriMonitorPlaneGeometry.overflowEdgeIntersectingNeighboringMonitor(
                    clampedRect,
                    viewportFrame: input.workingFrame,
                    orientation: input.orientation,
                    hiddenPlacementMonitor: input.sourceMonitor,
                    hiddenPlacementMonitors: input.monitors
                ) == nil {
                    let visibleRect = clampedRect.intersection(input.workingFrame)
                    if !visibleRect.isNull {
                        let start = primaryOrigin(of: visibleRect, orientation: input.orientation)
                        let end = primaryMaximum(of: visibleRect, orientation: input.orientation)
                        let uncoveredStart = max(start, coveredEnd)
                        if end > uncoveredStart {
                            coverage += end - uncoveredStart
                            coveredEnd = end
                        }
                        if index == input.selectedIndex {
                            selectedVisibility = max(0, end - start)
                        }
                    }
                }
            }

            position += span + input.gap
        }

        return Score(
            selectedVisibility: selectedVisibility,
            coverage: coverage,
            movement: rank == 0 ? 0 : abs(offset - input.semanticOffset),
            rank: rank
        )
    }

    private static func isBetter(_ candidate: Score, than current: Score, pixel: CGFloat) -> Bool {
        if candidate.selectedVisibility > current.selectedVisibility + pixel {
            return true
        }
        if current.selectedVisibility > candidate.selectedVisibility + pixel {
            return false
        }
        if candidate.coverage > current.coverage + pixel {
            return true
        }
        if current.coverage > candidate.coverage + pixel {
            return false
        }
        if candidate.movement < current.movement {
            return true
        }
        if current.movement < candidate.movement {
            return false
        }
        return candidate.rank < current.rank
    }

    private static func containerPosition(
        at index: Int,
        spans: [CGFloat],
        gap: CGFloat
    ) -> CGFloat {
        var position: CGFloat = 0
        for candidateIndex in 0 ..< index {
            position += spans[candidateIndex] + gap
        }
        return position
    }

    private static func renderedContainerRect(
        position: CGFloat,
        span: CGFloat,
        viewPosition: CGFloat,
        workingFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let rect: CGRect = switch orientation {
        case .horizontal:
            CGRect(
                x: workingFrame.minX + position,
                y: workingFrame.minY,
                width: span,
                height: workingFrame.height
            )
        case .vertical:
            CGRect(
                x: workingFrame.minX,
                y: workingFrame.minY + position,
                width: workingFrame.width,
                height: span
            )
        }
        let canonicalRect = rect.roundedToPhysicalPixels(scale: scale)
        let renderedRect: CGRect = switch orientation {
        case .horizontal:
            canonicalRect.offsetBy(dx: -viewPosition, dy: 0)
        case .vertical:
            canonicalRect.offsetBy(dx: 0, dy: -viewPosition)
        }
        return renderedRect.roundedToPhysicalPixels(scale: scale)
    }

    private static func primaryIntersects(
        _ lhs: CGRect,
        _ rhs: CGRect,
        orientation: Monitor.Orientation
    ) -> Bool {
        switch orientation {
        case .horizontal:
            lhs.maxX > rhs.minX && lhs.minX < rhs.maxX
        case .vertical:
            lhs.maxY > rhs.minY && lhs.minY < rhs.maxY
        }
    }

    private static func primaryOrigin(
        of rect: CGRect,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        switch orientation {
        case .horizontal: rect.minX
        case .vertical: rect.minY
        }
    }

    private static func primaryMaximum(
        of rect: CGRect,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        switch orientation {
        case .horizontal: rect.maxX
        case .vertical: rect.maxY
        }
    }

    private static func primarySpan(
        of rect: CGRect,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        switch orientation {
        case .horizontal: rect.width
        case .vertical: rect.height
        }
    }
}

extension NiriLayoutEngine {
    @discardableResult
    func recoverSettledCoverage(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard interactiveResize == nil, interactiveMove == nil else { return false }
        let settings = effectiveSettings(in: workspaceId)
        guard settings.centerFocusedColumn != .always else { return false }

        guard singleWindowLayoutContext(
            in: workspaceId,
            excluding: projectionExclusions(in: workspaceId)
        ) == nil,
            let sourceMonitor = monitorForWorkspace(workspaceId)
        else {
            return false
        }

        return withProjectedViewport(
            state: &state,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        ) { containers, projectedState in
            guard !(settings.alwaysCenterSingleColumn && containers.count == 1),
                  containers.count > 1,
                  containers.allSatisfy({ $0.effectiveSizingMode == .normal }),
                  let selectedNodeId = projectedState.selectedNodeId,
                  let selectedNode = findNode(by: selectedNodeId, in: workspaceId) as? NiriWindow,
                  !isExcludedFromProjection(selectedNode.token, in: workspaceId),
                  let selectedContainer = findColumn(containing: selectedNode, in: workspaceId),
                  selectedContainer.effectiveSizingMode == .normal,
                  let selectedIndex = containers.firstIndex(where: { $0 === selectedContainer })
            else {
                return false
            }

            var spans: [CGFloat] = []
            spans.reserveCapacity(containers.count)
            for container in containers {
                let span: CGFloat = switch orientation {
                case .horizontal: container.targetWidth ?? container.cachedWidth
                case .vertical: container.cachedHeight
                }
                guard span > 0 else { return false }
                spans.append(span)
            }

            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... containers.count - 1)
            let offset = NiriSettledCoverageEvaluator.bestOffset(
                for: .init(
                    containerSpans: spans,
                    selectedIndex: selectedIndex,
                    activeIndex: activeIndex,
                    semanticOffset: projectedState.viewOffset,
                    gap: gaps,
                    workingFrame: workingFrame,
                    sourceMonitor: HiddenPlacementMonitorContext(sourceMonitor),
                    monitors: monitors.values.map(HiddenPlacementMonitorContext.init),
                    orientation: orientation,
                    scale: sourceMonitor.scale
                )
            )
            guard abs(offset - projectedState.viewOffset) > 0.0001 else { return false }

            projectedState.animateToOffset(offset, motion: motion, scale: sourceMonitor.scale)
            return true
        } ?? false
    }
}
