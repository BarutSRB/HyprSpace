// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    @discardableResult
    func toggleColumnTabbed(
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId, in: workspaceId),
              let column = column(of: selectedNode)
        else {
            return false
        }

        let newMode: ColumnDisplay = column.displayMode == .normal ? .tabbed : .normal
        return setColumnDisplay(
            newMode,
            for: column,
            in: workspaceId,
            motion: motion,
            orientation: orientation
        )
    }

    @discardableResult
    func setColumnDisplay(
        _ mode: ColumnDisplay,
        for column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        orientation: Monitor.Orientation,
        gaps: CGFloat = 0
    ) -> Bool {
        guard column.displayMode != mode else { return false }

        if let resize = interactiveResize,
           let resizeWindow = findNode(by: resize.windowId, in: resize.workspaceId) as? NiriWindow,
           let resizeColumn = findColumn(containing: resizeWindow, in: resize.workspaceId),
           resizeColumn.id == column.id
        {
            clearInteractiveResize()
        }

        let windows = column.windowNodes
        guard !windows.isEmpty else {
            column.displayMode = mode
            return true
        }

        let prevOrigin = tilesOrigin(column: column)

        column.displayMode = mode
        let newOrigin = tilesOrigin(column: column)
        let originDelta = CGPoint(x: prevOrigin.x - newOrigin.x, y: prevOrigin.y - newOrigin.y)

        column.displayMode = .normal
        let tileOffsets = computeTileOffsets(
            column: column,
            gaps: gaps,
            orientation: orientation
        )

        for (idx, window) in windows.enumerated() {
            let previousSecondaryOrigin = switch orientation {
            case .horizontal: prevOrigin.y
            case .vertical: prevOrigin.x
            }
            var secondaryDelta = idx < tileOffsets.count ? tileOffsets[idx] : 0
            secondaryDelta -= previousSecondaryOrigin

            if mode == .normal {
                secondaryDelta *= -1
            }

            let delta = switch orientation {
            case .horizontal:
                CGPoint(x: originDelta.x, y: originDelta.y + secondaryDelta)
            case .vertical:
                CGPoint(x: originDelta.x + secondaryDelta, y: originDelta.y)
            }
            if delta.x != 0 || delta.y != 0 {
                window.animateMoveFrom(
                    displacement: delta,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }

        column.displayMode = mode
        let currentTarget = column.targetWidth ?? column.cachedWidth
        if currentTarget > 0 {
            let clampedTarget = column.clampedToWidthBounds(
                currentTarget,
                contentInset: tabContentInset(for: column)
            )
            if clampedTarget != currentTarget {
                column.animateWidthTo(
                    newWidth: clampedTarget,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }
        updateTabbedColumnVisibility(column: column)

        return true
    }

    func updateTabbedColumnVisibility(column: NiriContainer) {
        assertSanctionedMutation()
        let windows = column.windowNodes
        guard !windows.isEmpty else { return }

        column.clampActiveTileIdx()

        if column.displayMode == .tabbed {
            for (idx, window) in windows.enumerated() {
                let isActive = idx == column.activeTileIdx
                window.isHiddenInTabbedMode = !isActive
            }
        } else {
            for window in windows {
                window.isHiddenInTabbedMode = false
            }
        }
    }

    @discardableResult
    func activateTab(at index: Int, in column: NiriContainer) -> Bool {
        guard column.displayMode == .tabbed else { return false }

        let prevIdx = column.activeTileIdx
        column.setActiveTileIdx(index)

        if prevIdx != column.activeTileIdx {
            updateTabbedColumnVisibility(column: column)
            return true
        }
        return false
    }

    func activeColumn(in workspaceId: WorkspaceDescriptor.ID, state: ViewportState) -> NiriContainer? {
        guard let selectedId = state.selectedNodeId,
              let selectedNode = findNode(by: selectedId, in: workspaceId)
        else {
            return nil
        }
        return column(of: selectedNode)
    }
}
