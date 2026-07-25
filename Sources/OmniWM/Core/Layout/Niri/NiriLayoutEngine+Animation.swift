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
        orientation: Monitor.Orientation = .horizontal
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
        let animationOffset = columnX(at: removedIdx + 1, columns: cols, gaps: gaps)
            - columnX(at: removedIdx, columns: cols, gaps: gaps)
        let postRemovalCount = cols.count - 1

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: animationOffset,
            in: workspaceId,
            motion: motion
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
        motion: MotionSnapshot
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

        for col in animatedColumns {
            if col.hasMoveAnimationRunning {
                col.offsetMoveAnimCurrent(displacement)
            } else {
                col.animateMoveFrom(
                    displacement: CGPoint(x: displacement, y: 0),
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
        workingAreaWidth: CGFloat
    ) {
        let cols = columns(in: workspaceId)
        guard addedIdx >= 0, addedIdx < cols.count else { return }

        let addedCol = cols[addedIdx]
        let activeIdx = state.activeColumnIndex

        if addedCol.cachedWidth <= 0 {
            addedCol.resolveAndCacheWidth(workingAreaWidth: workingAreaWidth, gaps: gaps)
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

        let offset = addedCol.cachedWidth + gaps

        if activeIdx <= addedIdx {
            for col in cols[(addedIdx + 1)...] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(-offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -offset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        } else {
            for col in cols[..<addedIdx] {
                if col.hasMoveAnimationRunning {
                    col.offsetMoveAnimCurrent(offset)
                } else {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: offset, y: 0),
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
        animationTime: TimeInterval? = nil
    ) -> [WindowToken: CGRect] {
        calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: monitor,
            gaps: gaps,
            state: state,
            workingArea: workingArea,
            animationTime: animationTime
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
        settledVisibilityOffset: CGFloat? = nil
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
            settledVisibilityOffset: settledVisibilityOffset
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
        settledVisibilityOffset: CGFloat? = nil
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
            settledVisibilityOffset: settledVisibilityOffset
        )

        return (framePool, hiddenPool)
    }

    func captureWindowFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let root = root(for: workspaceId) else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        for window in root.allWindows {
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

    func computeTileOffset(column: NiriContainer, tileIdx: Int, gaps: CGFloat) -> CGFloat {
        let windows = column.windowNodes
        guard tileIdx >= 0, tileIdx < windows.count else { return 0 }
        guard !column.isTabbed else { return gaps }

        var offset: CGFloat = gaps
        guard tileIdx > 0 else { return offset }
        for i in 0 ..< tileIdx {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            offset += height
            offset += gaps
        }
        return offset
    }

    func computeTileOffsets(column: NiriContainer, gaps: CGFloat) -> [CGFloat] {
        let windows = column.windowNodes
        guard !windows.isEmpty else { return [] }

        var offsets: [CGFloat] = [gaps]
        var y: CGFloat = gaps
        for i in 0 ..< windows.count - 1 {
            let height = windows[i].resolvedHeight ?? windows[i].frame?.height ?? 0
            y += height + gaps
            offsets.append(y)
        }
        return offsets
    }

    func tilesOrigin(column: NiriContainer) -> CGPoint {
        let xOffset = column.isTabbed ? renderStyle.tabIndicatorWidth : 0
        return CGPoint(x: xOffset, y: 0)
    }
}
