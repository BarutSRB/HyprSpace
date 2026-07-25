// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    private struct ColumnTransferResult {
        let insertedTileIndex: Int
        let sourceBecameEmpty: Bool
        let sourceColumnIndexBeforeCleanup: Int
        let targetColumnIndexAfterInsert: Int
    }

    private enum TargetColumnInsertionPolicy {
        case append
        case visualBottom

        func insertionIndex(in targetColumn: NiriContainer) -> Int {
            switch self {
            case .append:
                targetColumn.children.count
            case .visualBottom:
                visualBottomInsertionIndex(in: targetColumn)
            }
        }

        private func visualBottomInsertionIndex(in _: NiriContainer) -> Int {
            // Current child ordering renders index 0 at the visual bottom of a column.
            0
        }
    }

    private func resetMovedWindowColumnLocalSizing(_ window: NiriWindow) {
        window.height = .default
        window.windowWidth = .default
        window.resolvedHeight = nil
        window.resolvedWidth = nil
        window.heightFixedByConstraint = false
        window.widthFixedByConstraint = false
    }

    @discardableResult
    private func moveWindowToColumn(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        to targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        targetInsertionPolicy: TargetColumnInsertionPolicy = .append,
        activateInsertedWindowInTarget: Bool = false
    ) -> ColumnTransferResult {
        let sourceColumnIndexBeforeCleanup = columnIndex(of: sourceColumn, in: workspaceId) ?? 0
        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        let targetActiveTileIdxBeforeInsert = targetColumn.activeTileIdx
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        node.detach()
        let insertedIndex = targetInsertionPolicy
            .insertionIndex(in: targetColumn)
            .clamped(to: 0 ... targetColumn.children.count)
        targetColumn.insertChild(node, at: insertedIndex)
        NiriLayoutTrace.record(
            .insertion,
            workspaceId: workspaceId,
            "moveToColumn index=\(insertedIndex) policy=\(String(describing: targetInsertionPolicy)) count=\(targetColumn.children.count)"
        )
        resetMovedWindowColumnLocalSizing(node)

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        if activateInsertedWindowInTarget {
            targetColumn.setActiveTileIdx(insertedIndex)
        } else if insertedIndex <= targetActiveTileIdxBeforeInsert {
            targetColumn.setActiveTileIdx(targetActiveTileIdxBeforeInsert + 1)
        }

        if targetColumn.displayMode == .tabbed {
            updateTabbedColumnVisibility(column: targetColumn)
        } else {
            node.isHiddenInTabbedMode = false
        }

        return ColumnTransferResult(
            insertedTileIndex: insertedIndex,
            sourceBecameEmpty: sourceColumn.children.isEmpty,
            sourceColumnIndexBeforeCleanup: sourceColumnIndexBeforeCleanup,
            targetColumnIndexAfterInsert: columnIndex(of: targetColumn, in: workspaceId) ??
                sourceColumnIndexBeforeCleanup
        )
    }

    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        guard let root = root(for: workspaceId) else { return }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        let newColumn = NiriContainer()
        initializeNewColumnWidth(newColumn, in: workspaceId)

        if direction == .right {
            root.insertAfter(newColumn, reference: sourceColumn)
        } else {
            root.insertBefore(newColumn, reference: sourceColumn)
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            if newColIdx == state.activeColumnIndex + 1 {
                state.activatePrevColumnOnRemoval = state.viewOffset
            }
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                motion: motion,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingAreaWidth
            )
        }

        node.detach()
        newColumn.appendChild(node)

        node.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
    }

    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        widthPolicy: NewColumnWidthPolicy = .workspaceDefault
    ) -> Bool {
        assertSanctionedMutation()
        guard let root = root(for: workspaceId) else { return false }
        guard let sourceColumn = findColumn(containing: window, in: workspaceId) else { return false }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        switch widthPolicy {
        case .workspaceDefault:
            initializeNewColumnWidth(newColumn, in: workspaceId)
        case .inheritSource:
            copyColumnWidthState(from: sourceColumn, to: newColumn)
        }

        let cols = columns(in: workspaceId)
        let clampedIndex = insertIndex.clamped(to: 0 ... cols.count)
        if clampedIndex >= cols.count {
            root.appendChild(newColumn)
        } else {
            root.insertBefore(newColumn, reference: cols[clampedIndex])
        }

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                motion: motion,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        window.detach()
        newColumn.appendChild(window)
        window.isHiddenInTabbedMode = false

        if sourceWasTabbed, !sourceColumn.children.isEmpty {
            sourceColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: sourceColumn)
        }

        cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )

        return true
    }

    func cleanupEmptyColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) {
        guard column.children.isEmpty else { return }

        // Window-close removals use removeWindows(...); this is structural cleanup for move/consume paths.
        column.remove()
    }

    func normalizeColumnSizes(in workspaceId: WorkspaceDescriptor.ID) {
        let cols = columns(in: workspaceId)
        guard cols.count > 1 else { return }

        let totalSize = cols.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(cols.count)

        for col in cols {
            let normalized = col.size / avgSize
            col.size = max(0.5, min(2.0, normalized))
        }
    }

    func normalizeWindowSizes(in column: NiriContainer) {
        let windows = column.children.compactMap { $0 as? NiriWindow }
        guard !windows.isEmpty else { return }

        let totalSize = windows.reduce(CGFloat(0)) { $0 + $1.size }
        let avgSize = totalSize / CGFloat(windows.count)

        for window in windows {
            let normalized = window.size / avgSize
            window.size = max(0.5, min(2.0, normalized))
        }
    }

    @discardableResult
    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        let resolvedWidth = resolvedColumnResetWidth(in: workspaceId)
        let targetPixels = (workingAreaWidth - gaps) * resolvedWidth.proportion - gaps

        for column in cols {
            column.width = .proportion(resolvedWidth.proportion)
            column.isFullWidth = false
            column.savedWidth = nil
            column.presetWidthIdx = resolvedWidth.presetWidthIdx
            column.hasManualSingleWindowWidthOverride = false

            column.animateWidthTo(
                newWidth: column.clampedToWidthBounds(targetPixels),
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )

            for window in column.windowNodes {
                window.size = 1.0
            }
        }
        return true
    }

    func moveColumn(
        _ column: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        guard direction == .left || direction == .right else { return false }

        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId) else { return false }

        let step = (direction == .right) ? 1 : -1
        let targetIdx = currentIdx + step
        guard targetIdx >= 0, targetIdx < cols.count else { return false }
        return moveColumn(
            column,
            to: targetIdx,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func moveColumnToFirst(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            1,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func moveColumnToLast(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            Int.max,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func moveColumnToIndex(
        _ column: NiriContainer,
        _ oneBasedIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        let targetIdx = min(oneBasedIndex <= 1 ? 0 : oneBasedIndex - 1, cols.count - 1)
        return moveColumn(
            column,
            to: targetIdx,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func moveColumn(
        _ column: NiriContainer,
        to targetIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId),
              cols.indices.contains(targetIdx)
        else { return false }
        if targetIdx == currentIdx { return false }

        let currentColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let nextColX = currentIdx + 1 < cols.count
            ? state.columnX(at: currentIdx + 1, columns: cols, gap: gaps)
            : currentColX + (
                column.cachedWidth > 0
                    ? column.cachedWidth
                    : workingFrame.width / CGFloat(effectiveMaxVisibleColumns(in: workspaceId))
            ) + gaps

        guard let root = root(for: workspaceId) else { return false }
        cancelInteractiveResizeForMovedColumn(column, in: workspaceId)
        root.insertChild(column, at: targetIdx)

        let newCols = columns(in: workspaceId)
        let viewOffsetDelta = -state.columnX(at: currentIdx, columns: newCols, gap: gaps) + currentColX
        state.offsetViewport(by: viewOffsetDelta)

        let newColX = state.columnX(at: targetIdx, columns: newCols, gap: gaps)
        column.animateMoveFrom(
            displacement: CGPoint(x: currentColX - newColX, y: 0),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: motion.animationsEnabled
        )

        let othersXOffset = nextColX - currentColX
        if currentIdx < targetIdx {
            for i in currentIdx ..< targetIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        } else {
            for i in (targetIdx + 1) ... currentIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: CGPoint(x: -othersXOffset, y: 0),
                        clock: animationClock,
                        config: windowMovementAnimationConfig,
                        displayRefreshRate: displayRefreshRate(in: workspaceId),
                        animated: motion.animationsEnabled
                    )
                }
            }
        }

        ensureColumnVisible(
            column,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            animationConfig: windowMovementAnimationConfig,
            fromContainerIndex: currentIdx
        )

        return true
    }

    private func cancelInteractiveResizeForMovedColumn(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let resize = interactiveResize, resize.workspaceId == workspaceId else { return }
        guard let resizeWindow = findNode(by: resize.windowId, in: workspaceId) as? NiriWindow,
              let resizeColumn = findColumn(containing: resizeWindow, in: workspaceId),
              resizeColumn === column
        else {
            return
        }

        clearInteractiveResize()
    }

    func consumeOrExpelWindow(
        _ window: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        allowEdgeWrap: Bool = true
    ) -> Bool {
        assertSanctionedMutation()
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        if currentColumn.windowNodes.count > 1 {
            return expelWindow(
                window,
                to: direction,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }

        let cols = columns(in: workspaceId)
        let step = (direction == .right) ? 1 : -1
        let neighborIdx: Int
        if allowEdgeWrap {
            guard let wrappedIdx = wrapIndex(currentIdx + step, total: cols.count, in: workspaceId) else {
                return false
            }
            neighborIdx = wrappedIdx
        } else {
            let adjacentIdx = currentIdx + step
            guard adjacentIdx >= 0, adjacentIdx < cols.count else {
                return false
            }
            neighborIdx = adjacentIdx
        }

        if neighborIdx == currentIdx { return false }

        let neighborColumn = cols[neighborIdx]
        guard neighborColumn.id != currentColumn.id else { return false }

        return consumeWindow(
            window,
            into: neighborColumn,
            enteringFrom: direction,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func columnCanAcceptTransfer(
        _ column: NiriContainer,
        adding window: NiriWindow,
        removing removedWindow: NiriWindow? = nil,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        guard !column.isTabbed else { return true }
        let orientation = monitorForWorkspace(workspaceId)?.orientation ?? .horizontal
        let axisSpace = orientation == .horizontal ? workingFrame.height : workingFrame.width
        func axisMinimum(_ tile: NiriWindow) -> CGFloat {
            let minSize = tile.constraints.normalized().minSize
            return orientation == .horizontal ? minSize.height : minSize.width
        }
        let remaining = column.windowNodes.filter { $0 !== removedWindow }
        let minSum = remaining.reduce(axisMinimum(window)) { $0 + axisMinimum($1) }
        let gapSum = gaps * CGFloat(remaining.count + 2)
        return minSum + gapSum <= axisSpace + 0.5
    }

    @discardableResult
    func consumeWindow(
        _ window: NiriWindow,
        into targetColumn: NiriContainer,
        enteringFrom direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> Bool {
        assertSanctionedMutation()
        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let currentIdx = columnIndex(of: currentColumn, in: workspaceId),
              currentColumn.id != targetColumn.id
        else {
            return false
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        ) else {
            return false
        }

        let targetInsertionPolicy: TargetColumnInsertionPolicy = direction == .down ? .append : .visualBottom

        let cols = columns(in: workspaceId)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let previousActiveColumnIndex = state.activeColumnIndex
        let sizeKeyPath: KeyPath<NiriContainer, CGFloat> = switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
        let previousActiveColumnPosition = state.containerPosition(
            at: previousActiveColumnIndex,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: currentIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let transfer = moveWindowToColumn(
            window,
            from: currentColumn,
            to: targetColumn,
            in: workspaceId,
            targetInsertionPolicy: targetInsertionPolicy,
            activateInsertedWindowInTarget: true
        )

        state.selectedNodeId = window.id

        if transfer.sourceBecameEmpty {
            _ = animateColumnsForRemoval(
                columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                in: workspaceId,
                motion: motion,
                state: &state,
                gaps: gaps,
                orientation: orientation
            )
            cleanupEmptyColumn(currentColumn, in: workspaceId, state: &state)
        }

        let newCols = columns(in: workspaceId)
        let targetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? transfer.targetColumnIndexAfterInsert
        let targetColX = state.columnX(at: targetColIdx, columns: newCols, gap: gaps)
        let targetColRenderOffset = targetColumn.renderOffset()
        let targetTileOffset = computeTileOffset(
            column: targetColumn,
            tileIdx: transfer.insertedTileIndex,
            gaps: gaps
        )

        let displacement = CGPoint(
            x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
            y: sourceTileOffset - targetTileOffset
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )
        }

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation,
            fromContainerIndex: previousActiveColumnIndex,
            previousActiveContainerPosition: previousActiveColumnPosition
        )

        return true
    }

    func consumeWindowIntoColumn(
        focusedColumn targetColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        let cols = columns(in: workspaceId)
        guard let targetColumnIdx = columnIndex(of: targetColumn, in: workspaceId),
              targetColumnIdx + 1 < cols.count
        else {
            return false
        }

        let sourceColumnIdx = targetColumnIdx + 1
        let sourceColumn = cols[sourceColumnIdx]
        guard let window = sourceColumn.windowNodes.last,
              let sourceTileIdx = sourceColumn.windowNodes.firstIndex(where: { $0 === window })
        else {
            return false
        }

        guard columnCanAcceptTransfer(
            targetColumn,
            adding: window,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        ) else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let sourceColX = state.columnX(at: sourceColumnIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: sourceColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let transfer = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: targetColumn,
            in: workspaceId,
            targetInsertionPolicy: .visualBottom
        )

        if transfer.sourceBecameEmpty {
            _ = animateColumnsForRemoval(
                columnIndex: transfer.sourceColumnIndexBeforeCleanup,
                in: workspaceId,
                motion: motion,
                state: &state,
                gaps: gaps
            )
            cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
        }

        let newCols = columns(in: workspaceId)
        let targetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? targetColumnIdx
        let targetColX = state.columnX(at: targetColIdx, columns: newCols, gap: gaps)
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let targetTileOffset = computeTileOffset(
            column: targetColumn,
            tileIdx: transfer.insertedTileIndex,
            gaps: gaps
        )

        let displacement = CGPoint(
            x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
            y: sourceTileOffset - targetTileOffset
        )
        if displacement.x != 0 || displacement.y != 0 {
            window.animateMoveFrom(
                displacement: displacement,
                clock: animationClock,
                config: windowMovementAnimationConfig,
                displayRefreshRate: displayRefreshRate(in: workspaceId),
                animated: motion.animationsEnabled
            )
        }

        return true
    }

    func expelWindowFromColumn(
        focusedColumn sourceColumn: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        assertSanctionedMutation()
        guard sourceColumn.windowNodes.count > 1,
              let root = root(for: workspaceId),
              let sourceColumnIdx = columnIndex(of: sourceColumn, in: workspaceId),
              let window = sourceColumn.windowNodes.first
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)
        let sourceTileIdx = sourceColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: sourceColumnIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: sourceColumn, tileIdx: sourceTileIdx, gaps: gaps)
        let replacementSelectionId = sourceColumn.windowNodes.dropFirst().first?.id
        let selectedExpelledWindow = state.selectedNodeId == window.id

        let newColumn = NiriContainer()
        copyColumnWidthState(from: sourceColumn, to: newColumn)
        root.insertAfter(newColumn, reference: sourceColumn)

        _ = moveWindowToColumn(
            window,
            from: sourceColumn,
            to: newColumn,
            in: workspaceId
        )

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                motion: motion,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetColX = state.columnX(at: newColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = newColumn.renderOffset(at: now)
            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }

        if selectedExpelledWindow {
            state.selectedNodeId = replacementSelectionId
        }

        return true
    }

    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let root = root(for: workspaceId),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)

        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourceColX = state.columnX(at: currentColIdx, columns: cols, gap: gaps)
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(column: currentColumn, tileIdx: sourceTileIdx, gaps: gaps)

        let wasTabbed = currentColumn.displayMode == .tabbed
        currentColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        copyColumnWidthState(from: currentColumn, to: newColumn)

        if direction == .right {
            root.insertAfter(newColumn, reference: currentColumn)
        } else {
            root.insertBefore(newColumn, reference: currentColumn)
        }

        window.detach()
        newColumn.appendChild(window)
        resetMovedWindowColumnLocalSizing(window)
        window.isHiddenInTabbedMode = false

        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            animateColumnsForAddition(
                columnIndex: newColIdx,
                in: workspaceId,
                motion: motion,
                state: state,
                gaps: gaps,
                workingAreaWidth: workingFrame.width
            )
        }

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetColX = state.columnX(at: newColIdx, columns: newCols, gap: gaps)
            let targetColRenderOffset = newColumn.renderOffset(at: now)

            let displacement = CGPoint(
                x: sourceColX + sourceColRenderOffset.x - (targetColX + targetColRenderOffset.x),
                y: sourceTileOffset
            )

            if displacement.x != 0 || displacement.y != 0 {
                window.animateMoveFrom(
                    displacement: displacement,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )
            }
        }

        if wasTabbed, !currentColumn.children.isEmpty {
            currentColumn.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: currentColumn)
        }

        cleanupEmptyColumn(currentColumn, in: workspaceId, state: &state)

        ensureSelectionVisible(
            node: window,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        return true
    }

    private func ensureColumnVisible(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        if let firstWindow = column.windowNodes.first {
            ensureSelectionVisible(
                node: firstWindow,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex
            )
        }
    }
}
