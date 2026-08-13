// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    private func updateActiveTileIdx(for nodeId: NodeId, in col: NiriContainer) {
        let windowNodes = col.windowNodes
        let idx = windowNodes.firstIndex(where: { $0.id == nodeId }) ?? 0
        col.setActiveTileIdx(idx)
    }

    func moveSelectionByColumns(
        steps: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        guard steps != 0 else { return currentSelection }

        let projectedColumns = projectedColumns(in: workspaceId)
        guard !projectedColumns.isEmpty else { return nil }

        guard let currentColumn = column(of: currentSelection),
              let durableCurrentIndex = columnIndex(of: currentColumn, in: workspaceId)
        else {
            return nil
        }

        if let currentWindow = currentSelection as? NiriWindow,
           !isExcludedFromProjection(currentWindow.token, in: workspaceId)
        {
            updateActiveTileIdx(for: currentSelection.id, in: currentColumn)
        }

        let projectedCurrentIndex = projectedColumns.firstIndex { $0.column === currentColumn }
        let targetIndex: Int
        if let projectedCurrentIndex {
            guard let wrappedIndex = wrapIndex(
                projectedCurrentIndex + steps,
                total: projectedColumns.count,
                in: workspaceId
            ) else {
                return nil
            }
            targetIndex = wrappedIndex
        } else {
            let candidates = projectedColumns.indices.filter {
                steps > 0
                    ? projectedColumns[$0].durableIndex > durableCurrentIndex
                    : projectedColumns[$0].durableIndex < durableCurrentIndex
            }
            guard let firstIndex = steps > 0 ? candidates.first : candidates.last else { return nil }
            let remainingSteps = steps > 0 ? steps - 1 : steps + 1
            guard let wrappedIndex = wrapIndex(
                firstIndex + remainingSteps,
                total: projectedColumns.count,
                in: workspaceId
            ) else {
                return nil
            }
            targetIndex = wrappedIndex
        }

        let targetColumn = projectedColumns[targetIndex]
        let targetRows = targetColumn.windows
        guard !targetRows.isEmpty else {
            return nil
        }

        let activeWindow = projectedActiveWindow(in: targetColumn)
        let activeRowIndex = activeWindow.flatMap { activeWindow in
            targetRows.firstIndex(where: { $0 === activeWindow })
        } ?? 0
        let clampedRowIndex = min(targetRowIndex ?? activeRowIndex, targetRows.count - 1)
        return targetRows[clampedRowIndex]
    }

    func moveSelectionHorizontal(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        moveSelectionCrossContainer(
            direction: direction,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal,
            viewportOrientation: orientation,
            targetSiblingIndex: targetRowIndex
        )
    }

    private func moveSelectionCrossContainer(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        viewportOrientation: Monitor.Orientation,
        targetSiblingIndex: Int? = nil
    ) -> NiriNode? {
        guard let step = direction.primaryStep(for: orientation) else { return nil }

        guard let newSelection = moveSelectionByColumns(
            steps: step,
            currentSelection: currentSelection,
            in: workspaceId,
            targetRowIndex: targetSiblingIndex
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: newSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: viewportOrientation
        )

        return newSelection
    }

    func moveSelectionVertical(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: .horizontal,
            workspaceId: workspaceId
        )
    }

    private func moveSelectionWithinContainer(
        direction: Direction,
        currentSelection: NiriNode,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriNode? {
        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        guard let container = column(of: currentSelection) else {
            return step > 0 ? currentSelection.nextSibling() : currentSelection.prevSibling()
        }

        if container.isTabbed {
            return moveSelectionWithinContainerTabbed(
                direction: direction,
                in: container,
                orientation: orientation,
                workspaceId: workspaceId
            )
        }

        let windows = workspaceId.map { projectedWindows(in: container, workspaceId: $0) }
            ?? container.windowNodes
        guard let currentWindow = currentSelection as? NiriWindow,
              let currentIndex = windows.firstIndex(where: { $0 === currentWindow })
        else {
            return step > 0 ? windows.first : windows.last
        }
        let targetIndex = currentIndex + step
        guard windows.indices.contains(targetIndex) else { return nil }
        let target = windows[targetIndex]

        if let idx = container.windowNodes.firstIndex(where: { $0 === target }) {
            container.setActiveTileIdx(idx)
        }

        return target
    }

    private func moveSelectionWithinContainerTabbed(
        direction: Direction,
        in container: NiriContainer,
        orientation: Monitor.Orientation,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> NiriNode? {
        guard let step = direction.secondaryStep(for: orientation) else { return nil }

        let windows = workspaceId.map { projectedWindows(in: container, workspaceId: $0) }
            ?? container.windowNodes
        guard !windows.isEmpty else { return nil }

        let activeWindow = workspaceId.flatMap {
            projectedActiveWindow(in: container, workspaceId: $0)
        }
        let currentIdx = activeWindow.flatMap { activeWindow in
            windows.firstIndex(where: { $0 === activeWindow })
        } ?? 0
        let newIdx = currentIdx + step
        guard newIdx >= 0, newIdx < windows.count else { return nil }

        guard let durableIndex = container.windowNodes.firstIndex(where: { $0 === windows[newIdx] }) else {
            return nil
        }
        container.setActiveTileIdx(durableIndex)
        updateTabbedColumnVisibility(column: container)

        return windows[newIdx]
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        assertSanctionedMutation()
        if !projectionExclusions(in: workspaceId).isEmpty {
            ensureProjectedSelectionVisible(
                node: node,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                animationConfig: animationConfig,
                fromContainerIndex: fromContainerIndex
            )
            return
        }
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

        guard let container = column(of: node),
              let targetIdx = columnIndex(of: container, in: workspaceId)
        else {
            return
        }

        let prevIdx = fromContainerIndex ?? state.activeColumnIndex

        let sizeKeyPath: KeyPath<NiriContainer, CGFloat>
        let viewportSpan: CGFloat
        switch orientation {
        case .horizontal:
            sizeKeyPath = \.cachedWidth
            viewportSpan = workingFrame.width
        case .vertical:
            sizeKeyPath = \.cachedHeight
            viewportSpan = workingFrame.height
        }

        let scale = displayScale(in: workspaceId)
        let viewFrame = monitorForWorkspace(workspaceId)?.frame
        let oldActivePos = previousActiveContainerPosition
            ?? state.containerPosition(
                at: state.activeColumnIndex,
                containers: containers,
                gap: gaps,
                sizeKeyPath: sizeKeyPath
            )
        let newActivePos = state.containerPosition(
            at: targetIdx,
            containers: containers,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let offsetDelta = oldActivePos - newActivePos
        state.rebaseOffset(by: offsetDelta)

        state.activeColumnIndex = targetIdx
        state.activatePrevColumnOnRemoval = nil
        state.viewOffsetToRestore = nil

        let settings = effectiveSettings(in: workspaceId)
        state.ensureContainerVisible(
            containerIndex: targetIdx,
            containers: containers,
            gap: gaps,
            viewportSpan: viewportSpan,
            motion: motion,
            sizeKeyPath: sizeKeyPath,
            animate: true,
            centerMode: settings.centerFocusedColumn,
            alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
            animationConfig: animationConfig,
            fromContainerIndex: prevIdx,
            scale: scale,
            workingArea: workingFrame,
            viewFrame: viewFrame,
            orientation: orientation
        )

        state.selectionProgress = 0.0
    }

    func resolvePrimaryContainerSpans(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        for container in columns(in: workspaceId) {
            switch orientation {
            case .horizontal where container.cachedWidth <= 0:
                container.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gaps,
                    contentInset: tabContentInset(for: container)
                )
            case .vertical where container.cachedHeight <= 0:
                container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gaps)
            case .horizontal,
                 .vertical:
                break
            }
        }
    }

    func focusTarget(
        direction: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        if direction.primaryStep(for: orientation) != nil {
            return moveSelectionCrossContainer(
                direction: direction,
                currentSelection: currentSelection,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                viewportOrientation: orientation
            )
        }

        let target = moveSelectionWithinContainer(
            direction: direction,
            currentSelection: currentSelection,
            orientation: orientation,
            workspaceId: workspaceId
        )

        if let target {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
        return target
    }

    private func focusCombined(
        verticalDirection: Direction,
        horizontalDirection: Direction,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        targetRowIndex: Int? = nil
    ) -> NiriNode? {
        if let target = moveSelectionVertical(
            direction: verticalDirection,
            currentSelection: currentSelection,
            in: workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            return target
        }

        return moveSelectionHorizontal(
            direction: horizontalDirection,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation,
            targetRowIndex: targetRowIndex
        )
    }

    func focusDownOrLeft(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusCombined(
            verticalDirection: .down,
            horizontalDirection: .left,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation,
            targetRowIndex: Int.max
        )
    }

    func focusUpOrRight(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusCombined(
            verticalDirection: .up,
            horizontalDirection: .right,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    private func focusColumnByIndex(
        _ targetIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        let columns = projectedColumns(in: workspaceId)
        guard columns.indices.contains(targetIndex) else { return nil }

        if let currentWindow = currentSelection as? NiriWindow,
           !isExcludedFromProjection(currentWindow.token, in: workspaceId),
           let currentColumn = column(of: currentSelection)
        {
            updateActiveTileIdx(for: currentSelection.id, in: currentColumn)
        }

        state.activatePrevColumnOnRemoval = nil

        let targetColumn = columns[targetIndex]
        let windows = targetColumn.windows
        guard !windows.isEmpty else { return nil }

        let target = projectedActiveWindow(in: targetColumn) ?? windows[0]
        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        return target
    }

    func focusColumnFirst(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusColumnByIndex(
            0,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusColumnLast(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        let columns = projectedColumns(in: workspaceId)
        guard !columns.isEmpty else { return nil }
        return focusColumnByIndex(
            columns.count - 1,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusColumn(
        _ columnIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusColumnByIndex(
            columnIndex,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusWindowInColumn(
        _ windowIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtNiriIndex(
            windowIndex,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusWindowTop(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtVisualIndex(
            0,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusWindowBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        return focusWindowAtVisualIndex(
            Int.max,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusWindowDownOrTop(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        if let target = moveSelectionVertical(
            direction: .down,
            currentSelection: currentSelection,
            in: workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            return target
        }

        return focusWindowTop(
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func focusWindowUpOrBottom(
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        assertSanctionedMutation()
        if let target = moveSelectionVertical(
            direction: .up,
            currentSelection: currentSelection,
            in: workspaceId
        ) {
            ensureSelectionVisible(
                node: target,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            return target
        }

        return focusWindowBottom(
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    private func focusWindowAtNiriIndex(
        _ oneBasedWindowIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        let visualIndex = oneBasedWindowIndex <= 1 ? 0 : oneBasedWindowIndex - 1
        return focusWindowAtVisualIndex(
            visualIndex,
            currentSelection: currentSelection,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    private func focusWindowAtVisualIndex(
        _ visualIndex: Int,
        currentSelection: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriNode? {
        guard let currentColumn = column(of: currentSelection) else { return nil }

        let windows = projectedWindows(in: currentColumn, workspaceId: workspaceId)
        guard !windows.isEmpty else { return nil }

        let clampedVisualIndex = min(max(visualIndex, 0), windows.count - 1)
        let projectedStorageIndex = windows.count - 1 - clampedVisualIndex
        let target = windows[projectedStorageIndex]
        guard let durableStorageIndex = currentColumn.windowNodes.firstIndex(where: { $0 === target }) else {
            return nil
        }
        currentColumn.setActiveTileIdx(durableStorageIndex)
        if currentColumn.isTabbed {
            updateTabbedColumnVisibility(column: currentColumn)
        }

        ensureSelectionVisible(
            node: target,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        return target
    }

    func focusPrevious(
        currentNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        limitToWorkspace: Bool = true
    ) -> NiriWindow? {
        assertSanctionedMutation()
        let searchWorkspaceId = limitToWorkspace ? workspaceId : nil
        guard let previousWindow = findMostRecentlyFocusedWindow(
            excluding: currentNodeId,
            in: searchWorkspaceId
        ) else {
            return nil
        }

        state.activatePrevColumnOnRemoval = nil

        ensureSelectionVisible(
            node: previousWindow,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        return previousWindow
    }
}
