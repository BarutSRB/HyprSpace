// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func interactiveMoveBegin(
        windowId: NodeId,
        windowToken: WindowToken,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard interactiveMove == nil else { return false }
        guard interactiveResize == nil else { return false }

        guard let windowNode = findNode(by: windowId, in: workspaceId) as? NiriWindow else { return false }
        guard let column = findColumn(containing: windowNode, in: workspaceId) else { return false }
        guard let colIdx = columnIndex(of: column, in: workspaceId) else { return false }

        if windowNode.isFullscreen {
            return false
        }

        interactiveMove = InteractiveMove(
            windowId: windowId,
            windowToken: windowToken,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            originalColumnIndex: colIdx,
            originalFrame: windowNode.renderedFrame ?? windowNode.frame ?? .zero,
            isInsertMode: isInsertMode,
            orientation: orientation,
            gaps: gaps,
            currentHoverTarget: nil
        )

        let cols = columns(in: workspaceId)
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let settings = effectiveSettings(in: workspaceId)
        state.transitionToColumn(
            colIdx,
            columns: cols,
            gap: gaps,
            workingArea: workingFrame,
            orientation: orientation,
            motion: motion,
            animate: false,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            scale: displayScale(in: workspaceId),
            viewFrame: monitorForWorkspace(workspaceId)?.frame
        )

        return true
    }

    func interactiveMoveUpdate(currentLocation: CGPoint) -> MoveHoverTarget? {
        guard var move = interactiveMove else { return nil }
        guard findNode(by: move.windowId, in: move.workspaceId) != nil else {
            interactiveMoveCancel()
            return nil
        }

        let dragDistance = hypot(
            currentLocation.x - move.startMouseLocation.x,
            currentLocation.y - move.startMouseLocation.y
        )
        guard dragDistance >= moveConfiguration.dragThreshold else {
            return nil
        }

        let hoverTarget = hitTestMoveTarget(
            point: currentLocation,
            excludingWindowId: move.windowId,
            isInsertMode: move.isInsertMode,
            orientation: move.orientation,
            in: move.workspaceId
        )

        move.currentHoverTarget = hoverTarget
        interactiveMove = move

        return hoverTarget
    }

    func interactiveMoveEnd(
        at _: CGPoint,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        guard let move = interactiveMove else { return false }
        defer { interactiveMove = nil }

        guard let target = move.currentHoverTarget else {
            return false
        }

        switch target {
        case let .window(targetNodeId, _, position):
            switch position {
            case .swap:
                return swapWindowsByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    in: move.workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: move.orientation
                )
            case .before,
                 .after:
                return insertWindowByMove(
                    sourceWindowId: move.windowId,
                    targetWindowId: targetNodeId,
                    position: position,
                    in: move.workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: move.orientation
                )
            }

        case .columnGap,
             .workspaceEdge:
            return false
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func hitTestMoveTarget(
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool = false,
        orientation: Monitor.Orientation,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> MoveHoverTarget? {
        guard let root = root(for: workspaceId) else { return nil }

        for column in root.columns {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      window.id != excludingWindowId,
                      !isExcludedFromProjection(window.token, in: workspaceId),
                      let frame = window.renderedFrame ?? window.frame else { continue }

                if frame.contains(point) {
                    let position: InsertPosition = if isInsertMode {
                        switch orientation {
                        case .horizontal:
                            point.y < frame.midY ? .before : .after
                        case .vertical:
                            point.x < frame.midX ? .before : .after
                        }
                    } else {
                        .swap
                    }
                    return .window(
                        nodeId: window.id,
                        token: window.token,
                        insertPosition: position
                    )
                }
            }
        }

        return nil
    }

    func swapWindowsByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        fromColumnIndex: Int? = nil
    ) -> Bool {
        guard let sourceWindow = findNode(by: sourceWindowId, in: workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        if sourceColumn.id == targetColumn.id {
            sourceWindow.swapWith(targetWindow)

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
        } else {
            guard let sourceIdx = sourceColumn.children.firstIndex(where: { $0.id == sourceWindowId }),
                  let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId })
            else {
                return false
            }

            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                removing: targetWindow,
                in: workspaceId,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ), columnCanAcceptTransfer(
                sourceColumn,
                adding: targetWindow,
                removing: sourceWindow,
                in: workspaceId,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else {
                return false
            }

            let sourceSize = sourceWindow.size
            let sourceHeight = sourceWindow.height
            let targetSize = targetWindow.size
            let targetHeight = targetWindow.height

            sourceWindow.detach()
            targetWindow.detach()

            sourceColumn.insertChild(targetWindow, at: sourceIdx)
            targetColumn.insertChild(sourceWindow, at: targetIdx)

            sourceWindow.size = targetSize
            sourceWindow.height = targetHeight
            targetWindow.size = sourceSize
            targetWindow.height = sourceHeight

            if sourceColumn.isTabbed {
                sourceColumn.clampActiveTileIdx()
            }
            if targetColumn.isTabbed {
                targetColumn.clampActiveTileIdx()
            }
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        return true
    }

    func insertWindowByMove(
        sourceWindowId: NodeId,
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard let sourceWindow = findNode(by: sourceWindowId, in: workspaceId) as? NiriWindow,
              let targetWindow = findNode(by: targetWindowId, in: workspaceId) as? NiriWindow
        else {
            return false
        }

        guard let sourceColumn = findColumn(containing: sourceWindow, in: workspaceId),
              let targetColumn = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return false
        }

        guard let targetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) else {
            return false
        }

        let sameColumn = sourceColumn.id == targetColumn.id
        let sourceColumnWillBeEmpty = sourceColumn.children.count == 1 && !sameColumn

        if !sameColumn {
            guard columnCanAcceptTransfer(
                targetColumn,
                adding: sourceWindow,
                in: workspaceId,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            ) else {
                return false
            }
        }

        sourceWindow.detach()

        let insertIdx: Int
        if sameColumn {
            let currentTargetIdx = targetColumn.children.firstIndex(where: { $0.id == targetWindowId }) ?? targetIdx
            insertIdx = position == .before ? currentTargetIdx : currentTargetIdx + 1
        } else {
            insertIdx = position == .before ? targetIdx : targetIdx + 1
        }

        targetColumn.insertChild(sourceWindow, at: insertIdx)

        sourceWindow.size = 1.0
        sourceWindow.height = .default

        if sourceColumnWillBeEmpty {
            sourceColumn.remove()
        }

        if sourceColumn.isTabbed {
            sourceColumn.clampActiveTileIdx()
        }
        if targetColumn.isTabbed {
            targetColumn.clampActiveTileIdx()
        }

        ensureSelectionVisible(
            node: sourceWindow,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        return true
    }

    func insertionDropzoneFrame(
        targetWindowId: NodeId,
        position: InsertPosition,
        in workspaceId: WorkspaceDescriptor.ID,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect? {
        guard let targetWindow = findNode(by: targetWindowId, in: workspaceId) as? NiriWindow,
              let targetFrame = targetWindow.renderedFrame ?? targetWindow.frame,
              let column = findColumn(containing: targetWindow, in: workspaceId)
        else {
            return nil
        }

        let windows = column.windowNodes
        let n = windows.count
        let postInsertionCount = n + 1
        let firstFrame = windows.first?.renderedFrame ?? windows.first?.frame
        let lastFrame = windows.last?.renderedFrame ?? windows.last?.frame
        let totalGaps = CGFloat(postInsertionCount - 1) * gaps

        switch orientation {
        case .horizontal:
            guard let bottom = firstFrame?.minY, let top = lastFrame?.maxY else { return nil }
            let columnHeight = top - bottom
            let newHeight = max(0, (columnHeight - totalGaps) / CGFloat(postInsertionCount))
            let y: CGFloat = switch position {
            case .before:
                max(bottom, targetFrame.minY - gaps - newHeight)
            case .after:
                targetFrame.maxY + gaps
            case .swap:
                targetFrame.minY
            }
            return CGRect(x: targetFrame.minX, y: y, width: targetFrame.width, height: newHeight)
        case .vertical:
            guard let left = firstFrame?.minX, let right = lastFrame?.maxX else { return nil }
            let rowWidth = right - left
            let newWidth = max(0, (rowWidth - totalGaps) / CGFloat(postInsertionCount))
            let x: CGFloat = switch position {
            case .before:
                max(left, targetFrame.minX - gaps - newWidth)
            case .after:
                targetFrame.maxX + gaps
            case .swap:
                targetFrame.minX
            }
            return CGRect(x: x, y: targetFrame.minY, width: newWidth, height: targetFrame.height)
        }
    }
}
