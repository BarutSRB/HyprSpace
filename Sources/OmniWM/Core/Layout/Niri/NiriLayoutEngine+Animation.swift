// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    struct ColumnRemovalResult {
        let fallbackSelectionId: NodeId?
        let restorePreviousViewOffset: CGFloat?
    }

    func animateColumnsForRemoval(
        columnIndex removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> ColumnRemovalResult {
        let cols = columns(in: workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else {
            return ColumnRemovalResult(
                fallbackSelectionId: nil,
                restorePreviousViewOffset: nil
            )
        }

        let activeIdx = state.activeColumnIndex
        let primarySpan = switch orientation {
        case .horizontal: cols[removedIdx].cachedWidth
        case .vertical: cols[removedIdx].cachedHeight
        }
        let viewportOffset = primarySpan + gaps
        let postRemovalCount = cols.count - 1

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: viewportOffset,
            in: workspaceId,
            motion: motion,
            orientation: orientation
        )

        let removingNode = cols[removedIdx].windowNodes.first
        let fallback = removingNode.flatMap { fallbackSelectionOnRemoval(removing: $0.id, in: workspaceId) }

        if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.rebaseOffset(by: viewportOffset)
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else if removedIdx == activeIdx,
                  let prevOffset = state.activatePrevColumnOnRemoval
        {
            let newActiveIdx = max(0, activeIdx - 1)
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: prevOffset
            )
        } else if removedIdx == activeIdx {
            let newActiveIdx = min(activeIdx, max(0, postRemovalCount - 1))
            state.activeColumnIndex = newActiveIdx
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
            return ColumnRemovalResult(
                fallbackSelectionId: fallback,
                restorePreviousViewOffset: nil
            )
        }
    }

    func animateColumnsAroundRemoval(
        columns cols: [NiriContainer],
        removedIdx: Int,
        activeIdx: Int,
        offset: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation
    ) {
        guard removedIdx >= 0, removedIdx < cols.count else { return }

        guard motion.animationsEnabled else {
            for col in cols {
                col.animateMoveFrom(
                    displacement: .zero,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: false
                )
            }
            return
        }

        let animatedColumns: ArraySlice<NiriContainer>
        let displacement: CGFloat
        if activeIdx <= removedIdx {
            guard removedIdx + 1 < cols.count else { return }
            animatedColumns = cols[(removedIdx + 1)...]
            displacement = offset
        } else {
            animatedColumns = cols[..<removedIdx]
            displacement = -offset
        }

        let movement = switch orientation {
        case .horizontal: CGPoint(x: displacement, y: 0)
        case .vertical: CGPoint(x: 0, y: displacement)
        }
        for col in animatedColumns {
            if !col.offsetMoveAnimCurrent(displacement, orientation: orientation) {
                col.animateMoveFrom(
                    displacement: movement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    func animateColumnsForAddition(
        columnIndex addedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: ViewportState,
        gaps: CGFloat,
        workingFrame: CGRect,
        orientation: Monitor.Orientation
    ) {
        let cols = columns(in: workspaceId)
        guard addedIdx >= 0, addedIdx < cols.count else { return }

        let addedCol = cols[addedIdx]
        let activeIdx = state.activeColumnIndex

        let primarySpan: CGFloat
        switch orientation {
        case .horizontal:
            if addedCol.cachedWidth <= 0 {
                addedCol.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gaps,
                    contentInset: tabContentInset(for: addedCol)
                )
            }
            primarySpan = addedCol.cachedWidth
        case .vertical:
            if addedCol.cachedHeight <= 0 {
                addedCol.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gaps)
            }
            primarySpan = addedCol.cachedHeight
        }

        guard motion.animationsEnabled else {
            for col in cols {
                col.animateMoveFrom(
                    displacement: .zero,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: false
                )
            }
            return
        }

        let offset = primarySpan + gaps

        if activeIdx <= addedIdx {
            for col in cols[(addedIdx + 1)...] {
                if !col.offsetMoveAnimCurrent(-offset, orientation: orientation) {
                    let displacement = switch orientation {
                    case .horizontal: CGPoint(x: -offset, y: 0)
                    case .vertical: CGPoint(x: 0, y: -offset)
                    }
                    col.animateMoveFrom(
                        displacement: displacement,
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        } else {
            for col in cols[..<addedIdx] {
                if !col.offsetMoveAnimCurrent(offset, orientation: orientation) {
                    let displacement = switch orientation {
                    case .horizontal: CGPoint(x: offset, y: 0)
                    case .vertical: CGPoint(x: 0, y: offset)
                    }
                    col.animateMoveFrom(
                        displacement: displacement,
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        }
    }

    func tickAllColumnAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyRunning = false
        for column in root.columns {
            if column.tickMoveAnimation(at: time) { anyRunning = true }
            if column.tickWidthAnimation(at: time) { anyRunning = true }
        }
        return anyRunning
    }

    func hasAnyColumnAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.columns.contains { $0.hasMoveAnimationRunning || $0.hasWidthAnimationRunning }
    }

    func calculateCombinedLayout(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil,
        excludedTokens: Set<WindowToken>? = nil
    ) -> [WindowToken: CGRect] {
        calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime,
            excludedTokens: excludedTokens
        ).frames
    }

    func calculateCombinedLayoutWithVisibility(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil,
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        excludedTokens: Set<WindowToken>? = nil
    ) -> LayoutResult {
        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            fullscreenLayoutFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        return calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            excludedTokens: excludedTokens
        )
    }

    func calculateCombinedLayoutUsingPools(
        in workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        gaps: LayoutGaps,
        state: ViewportState,
        workingArea: WorkingAreaContext? = nil,
        animationTime: TimeInterval? = nil,
        viewOffsetOverride: CGFloat? = nil,
        settledVisibilityOffset: CGFloat? = nil,
        excludedTokens: Set<WindowToken>? = nil
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        framePool.removeAll(keepingCapacity: true)
        hiddenPool.removeAll(keepingCapacity: true)

        let area = workingArea ?? WorkingAreaContext(
            workingFrame: monitor.visibleFrame,
            fullscreenLayoutFrame: monitor.visibleFrame,
            viewFrame: monitor.frame,
            scale: 2.0
        )
        let hiddenPlacementMonitor = HiddenPlacementMonitorContext(monitor)
        let hiddenPlacementMonitors = monitors.values.map(HiddenPlacementMonitorContext.init)

        let orientation = self.monitor(for: monitor.id)?.orientation ?? monitor.autoOrientation

        calculateLayoutInto(
            frames: &framePool,
            hiddenHandles: &hiddenPool,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitor.visibleFrame,
            screenFrame: monitor.frame,
            gaps: gaps.asTuple,
            scale: area.scale,
            workingArea: area,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset,
            excludedTokens: excludedTokens
        )

        return (framePool, hiddenPool)
    }

    func captureWindowFrames(
        in workspaceId: WorkspaceDescriptor.ID,
        excluding excludedTokens: Set<WindowToken> = []
    ) -> [WindowToken: CGRect] {
        guard let root = root(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        for window in root.allWindows where !excludedTokens.contains(window.token) {
            if let frame = window.renderedFrame ?? window.frame {
                frames[window.token] = frame
            }
        }
        return frames
    }

    func triggerMoveAnimations(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        motion: MotionSnapshot,
        yContainmentFrame: CGRect? = nil,
        threshold: CGFloat = 1.0
    ) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyAnimationStarted = false

        for window in root.allWindows {
            guard let oldFrame = oldFrames[window.token],
                  let newFrame = newFrames[window.token]
            else {
                continue
            }

            let dx = oldFrame.origin.x - newFrame.origin.x
            let dy = oldFrame.origin.y - newFrame.origin.y

            if abs(dx) > threshold || abs(dy) > threshold {
                window.animateMoveFrom(
                    displacement: CGPoint(x: dx, y: dy),
                    yContainmentFrame: yContainmentFrame,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
                anyAnimationStarted = true
            }
        }

        return anyAnimationStarted
    }

    func hasAnyWindowAnimationsRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        return root.allWindows.contains { $0.hasMoveAnimationsRunning }
    }

    func tickAllWindowAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = root(for: workspaceId) else { return false }
        var anyRunning = false
        for window in root.allWindows {
            if window.tickMoveAnimations(at: time) {
                anyRunning = true
            }
        }
        return anyRunning
    }

    func animateProjectedColumns(
        from previous: NiriProjectedGeometrySnapshot,
        to current: NiriProjectedGeometrySnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation
    ) {
        for geometry in current.columns {
            let column = geometry.projectedColumn.column
            guard motion.animationsEnabled else {
                column.animateMoveFrom(
                    displacement: .zero,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: false
                )
                continue
            }
            guard let previousGeometry = previous.column(containing: column) else { continue }
            let displacement = switch orientation {
            case .horizontal:
                CGPoint(x: previousGeometry.primaryPosition - geometry.primaryPosition, y: 0)
            case .vertical:
                CGPoint(x: 0, y: previousGeometry.primaryPosition - geometry.primaryPosition)
            }
            guard displacement != .zero else { continue }
            column.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )
        }
    }
}
