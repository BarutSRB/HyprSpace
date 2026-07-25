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

    private func primarySizeKeyPath(
        for orientation: Monitor.Orientation
    ) -> KeyPath<NiriContainer, CGFloat> {
        switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
    }

    private func primaryDisplacement(
        _ primary: CGFloat,
        secondary: CGFloat = 0,
        orientation: Monitor.Orientation
    ) -> CGPoint {
        switch orientation {
        case .horizontal: CGPoint(x: primary, y: secondary)
        case .vertical: CGPoint(x: secondary, y: primary)
        }
    }

    private func transferDisplacement(
        sourcePosition: CGFloat,
        sourceRenderOffset: CGPoint,
        targetPosition: CGFloat,
        targetRenderOffset: CGPoint,
        secondary: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGPoint {
        let sourceRender = switch orientation {
        case .horizontal: sourceRenderOffset.x
        case .vertical: sourceRenderOffset.y
        }
        let targetRender = switch orientation {
        case .horizontal: targetRenderOffset.x
        case .vertical: targetRenderOffset.y
        }
        return primaryDisplacement(
            sourcePosition + sourceRender - targetPosition - targetRender,
            secondary: secondary,
            orientation: orientation
        )
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
        workingFrame: CGRect,
        orientation: Monitor.Orientation
    ) {
        guard let root = root(for: workspaceId) else { return }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: node)

        let newColumn = NiriContainer()
        initializeNewContainerSizing(newColumn, in: workspaceId)

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
                workingFrame: workingFrame,
                orientation: orientation
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
        orientation: Monitor.Orientation,
        sizingPolicy: NewContainerSizingPolicy = .workspaceDefault
    ) -> Bool {
        assertSanctionedMutation()
        guard let root = root(for: workspaceId) else { return false }
        guard let sourceColumn = findColumn(containing: window, in: workspaceId) else { return false }

        let sourceWasTabbed = sourceColumn.displayMode == .tabbed
        sourceColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        switch sizingPolicy {
        case .workspaceDefault:
            initializeNewContainerSizing(newColumn, in: workspaceId)
        case .inheritSource:
            copyContainerSizingState(from: sourceColumn, to: newColumn)
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
                workingFrame: workingFrame,
                orientation: orientation
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
            gaps: gaps,
            orientation: orientation
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
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        let resolvedWidth = resolvedContainerResetPrimarySpan(in: workspaceId)
        switch orientation {
        case .horizontal:
            let targetPixels = (workingFrame.width - gaps) * resolvedWidth.proportion - gaps
            for column in cols {
                column.width = .proportion(resolvedWidth.proportion)
                column.isFullWidth = false
                column.savedWidth = nil
                column.presetWidthIdx = resolvedWidth.presetWidthIdx
                column.hasManualSingleWindowWidthOverride = false

                column.animateWidthTo(
                    newWidth: column.clampedToWidthBounds(
                        targetPixels,
                        contentInset: tabContentInset(for: column)
                    ),
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: motion.animationsEnabled
                )

                for window in column.windowNodes {
                    window.size = 1.0
                }
            }
        case .vertical:
            let targetPixels = (workingFrame.height - gaps) * resolvedWidth.proportion - gaps
            for column in cols {
                column.height = .proportion(resolvedWidth.proportion)
                column.isFullHeight = false
                column.savedHeight = nil
                column.hasManualSingleWindowHeightOverride = false
                column.cachedHeight = column.clampedToHeightBounds(targetPixels)

                for window in column.windowNodes {
                    window.windowWidth = .auto(weight: 1)
                }
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
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard let step = direction.primaryStep(for: orientation) else { return false }

        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId) else { return false }

        let targetIdx = currentIdx + step
        guard targetIdx >= 0, targetIdx < cols.count else { return false }
        return moveColumn(
            column,
            to: targetIdx,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func moveColumnToFirst(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            1,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func moveColumnToLast(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        return moveColumnToIndex(
            column,
            Int.max,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func moveColumnToIndex(
        _ column: NiriContainer,
        _ oneBasedIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
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
            gaps: gaps,
            orientation: orientation
        )
    }

    private func moveColumn(
        _ column: NiriContainer,
        to targetIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard let currentIdx = columnIndex(of: column, in: workspaceId),
              cols.indices.contains(targetIdx)
        else { return false }
        if targetIdx == currentIdx { return false }

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: orientation)
        let currentPosition = state.containerPosition(
            at: currentIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let nextPosition = currentIdx + 1 < cols.count
            ? state.containerPosition(
                at: currentIdx + 1,
                containers: cols,
                gap: gaps,
                sizeKeyPath: sizeKeyPath
            )
            : currentPosition + (
                column[keyPath: sizeKeyPath] > 0
                    ? column[keyPath: sizeKeyPath]
                    : (orientation == .horizontal ? workingFrame.width : workingFrame.height)
                    / CGFloat(effectiveVisibleContainerCount(in: workspaceId))
            ) + gaps

        guard let root = root(for: workspaceId) else { return false }
        cancelInteractiveResizeForMovedColumn(column, in: workspaceId)
        root.insertChild(column, at: targetIdx)

        let newCols = columns(in: workspaceId)
        let positionAtOldIndex = state.containerPosition(
            at: currentIdx,
            containers: newCols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let viewOffsetDelta = currentPosition - positionAtOldIndex
        state.offsetViewport(by: viewOffsetDelta)

        let newPosition = state.containerPosition(
            at: targetIdx,
            containers: newCols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        column.animateMoveFrom(
            displacement: primaryDisplacement(
                currentPosition - newPosition,
                orientation: orientation
            ),
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: motion.animationsEnabled
        )

        let othersOffset = nextPosition - currentPosition
        if currentIdx < targetIdx {
            for i in currentIdx ..< targetIdx {
                let col = newCols[i]
                if col.id != column.id {
                    col.animateMoveFrom(
                        displacement: primaryDisplacement(
                            othersOffset,
                            orientation: orientation
                        ),
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
                        displacement: primaryDisplacement(
                            -othersOffset,
                            orientation: orientation
                        ),
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
            orientation: orientation,
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
        orientation: Monitor.Orientation,
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
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        guard !column.isTabbed else { return true }
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
        orientation: Monitor.Orientation
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
            gaps: gaps,
            orientation: orientation
        ) else {
            return false
        }

        let targetInsertionPolicy: TargetColumnInsertionPolicy = direction == .down ? .append : .visualBottom

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let cols = columns(in: workspaceId)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let previousActiveColumnIndex = state.activeColumnIndex
        let sizeKeyPath = primarySizeKeyPath(for: orientation)
        let previousActiveColumnPosition = state.containerPosition(
            at: previousActiveColumnIndex,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourcePosition = state.containerPosition(
            at: currentIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(
            column: currentColumn,
            tileIdx: sourceTileIdx,
            gaps: gaps,
            orientation: orientation
        )

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
        let targetPosition = state.containerPosition(
            at: targetColIdx,
            containers: newCols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let targetColRenderOffset = targetColumn.renderOffset()
        let targetTileOffset = computeTileOffset(
            column: targetColumn,
            tileIdx: transfer.insertedTileIndex,
            gaps: gaps,
            orientation: orientation
        )

        let displacement = transferDisplacement(
            sourcePosition: sourcePosition,
            sourceRenderOffset: sourceColRenderOffset,
            targetPosition: targetPosition,
            targetRenderOffset: targetColRenderOffset,
            secondary: sourceTileOffset - targetTileOffset,
            orientation: orientation
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
        gaps: CGFloat,
        orientation: Monitor.Orientation
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
            gaps: gaps,
            orientation: orientation
        ) else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let sourcePosition = state.containerPosition(
            at: sourceColumnIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(
            column: sourceColumn,
            tileIdx: sourceTileIdx,
            gaps: gaps,
            orientation: orientation
        )

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
                gaps: gaps,
                orientation: orientation
            )
            cleanupEmptyColumn(sourceColumn, in: workspaceId, state: &state)
        }

        let newCols = columns(in: workspaceId)
        let targetColIdx = columnIndex(of: targetColumn, in: workspaceId) ?? targetColumnIdx
        let targetPosition = state.containerPosition(
            at: targetColIdx,
            containers: newCols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let targetColRenderOffset = targetColumn.renderOffset(at: now)
        let targetTileOffset = computeTileOffset(
            column: targetColumn,
            tileIdx: transfer.insertedTileIndex,
            gaps: gaps,
            orientation: orientation
        )

        let displacement = transferDisplacement(
            sourcePosition: sourcePosition,
            sourceRenderOffset: sourceColRenderOffset,
            targetPosition: targetPosition,
            targetRenderOffset: targetColRenderOffset,
            secondary: sourceTileOffset - targetTileOffset,
            orientation: orientation
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
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        guard sourceColumn.windowNodes.count > 1,
              let root = root(for: workspaceId),
              let sourceColumnIdx = columnIndex(of: sourceColumn, in: workspaceId),
              let window = sourceColumn.windowNodes.first
        else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)
        let sourceTileIdx = sourceColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourcePosition = state.containerPosition(
            at: sourceColumnIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceColRenderOffset = sourceColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(
            column: sourceColumn,
            tileIdx: sourceTileIdx,
            gaps: gaps,
            orientation: orientation
        )
        let replacementSelectionId = sourceColumn.windowNodes.dropFirst().first?.id
        let selectedExpelledWindow = state.selectedNodeId == window.id

        let newColumn = NiriContainer()
        copyContainerSizingState(from: sourceColumn, to: newColumn)
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
                workingFrame: workingFrame,
                orientation: orientation
            )
        }

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetPosition = state.containerPosition(
                at: newColIdx,
                containers: newCols,
                gap: gaps,
                sizeKeyPath: sizeKeyPath
            )
            let targetColRenderOffset = newColumn.renderOffset(at: now)
            let displacement = transferDisplacement(
                sourcePosition: sourcePosition,
                sourceRenderOffset: sourceColRenderOffset,
                targetPosition: targetPosition,
                targetRenderOffset: targetColRenderOffset,
                secondary: sourceTileOffset,
                orientation: orientation
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
        orientation: Monitor.Orientation
    ) -> Bool {
        guard direction == .left || direction == .right else { return false }

        guard let currentColumn = findColumn(containing: window, in: workspaceId),
              let root = root(for: workspaceId),
              let currentColIdx = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return false
        }

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let sizeKeyPath = primarySizeKeyPath(for: orientation)
        let now = animationClock?.now() ?? CACurrentMediaTime()
        let cols = columns(in: workspaceId)

        let sourceTileIdx = currentColumn.windowNodes.firstIndex(where: { $0 === window }) ?? 0
        let sourcePosition = state.containerPosition(
            at: currentColIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceColRenderOffset = currentColumn.renderOffset(at: now)
        let sourceTileOffset = computeTileOffset(
            column: currentColumn,
            tileIdx: sourceTileIdx,
            gaps: gaps,
            orientation: orientation
        )

        let wasTabbed = currentColumn.displayMode == .tabbed
        currentColumn.adjustActiveTileIdxForRemoval(of: window)

        let newColumn = NiriContainer()
        copyContainerSizingState(from: currentColumn, to: newColumn)

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
                workingFrame: workingFrame,
                orientation: orientation
            )
        }

        let newCols = columns(in: workspaceId)
        if let newColIdx = columnIndex(of: newColumn, in: workspaceId) {
            let targetPosition = state.containerPosition(
                at: newColIdx,
                containers: newCols,
                gap: gaps,
                sizeKeyPath: sizeKeyPath
            )
            let targetColRenderOffset = newColumn.renderOffset(at: now)

            let displacement = transferDisplacement(
                sourcePosition: sourcePosition,
                sourceRenderOffset: sourceColRenderOffset,
                targetPosition: targetPosition,
                targetRenderOffset: targetColRenderOffset,
                secondary: sourceTileOffset,
                orientation: orientation
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
        orientation: Monitor.Orientation,
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
                orientation: orientation,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex
            )
        }
    }
}
