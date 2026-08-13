// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

extension NiriLayoutEngine {
    @discardableResult
    func centerColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
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
        return withProjectedViewport(
            state: &state,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        ) { columns, projectedState in
            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            cancelInteractiveResize(for: columns[activeIndex], in: workspaceId)
            let targetOffset = projectedState.computeCenteredOffset(
                containerIndex: activeIndex,
                containers: columns,
                gap: gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                workingArea: workingFrame,
                viewFrame: viewFrame,
                orientation: orientation,
                scale: scale
            )
            projectedState.animateToOffset(
                targetOffset,
                motion: motion,
                scale: scale
            )
            return true
        } ?? false
    }

    @discardableResult
    func centerVisibleColumns(
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        assertSanctionedMutation()
        let settings = effectiveSettings(in: workspaceId)
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
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
        return withProjectedViewport(
            state: &state,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        ) { columns, projectedState in
            guard settings.centerFocusedColumn != .always,
                  !settings.alwaysCenterSingleColumn || columns.count > 1
            else {
                return false
            }

            let activeIndex = projectedState.activeColumnIndex.clamped(to: 0 ... columns.count - 1)
            projectedState.activeColumnIndex = activeIndex
            let areas = projectedState.normalizedFittingAreas(
                viewportSpan: viewportSpan,
                workingArea: workingFrame,
                viewFrame: viewFrame,
                orientation: orientation,
                scale: scale
            )
            let activePosition = projectedState.containerPosition(
                at: activeIndex,
                containers: columns,
                gap: gaps,
                sizeKeyPath: sizeKeyPath
            )
            let viewStart = activePosition + projectedState.viewOffset
            let workingStart = areas.origin(of: areas.working)
            let workingSpan = areas.span(of: areas.working)

            var spanTaken: CGFloat = 0
            var firstVisiblePosition: CGFloat?
            var activeContainerPosition: CGFloat?

            for (idx, column) in columns.enumerated() {
                let position = projectedState.containerPosition(
                    at: idx,
                    containers: columns,
                    gap: gaps,
                    sizeKeyPath: sizeKeyPath
                )
                if position < viewStart + workingStart + gaps {
                    continue
                }

                if firstVisiblePosition == nil {
                    firstVisiblePosition = position
                }

                let span = column[keyPath: sizeKeyPath]
                if viewStart + workingStart + workingSpan < position + span + gaps {
                    break
                }

                if idx == activeIndex {
                    activeContainerPosition = position
                }

                spanTaken += span + gaps
            }

            guard let firstVisiblePosition, let activeContainerPosition else { return false }
            cancelInteractiveResize(for: columns[activeIndex], in: workspaceId)
            let freeSpace = workingSpan - spanTaken + gaps
            let newViewStart = firstVisiblePosition - freeSpace / 2 - workingStart
            let targetOffset = newViewStart - activeContainerPosition

            projectedState.animateToOffset(targetOffset, motion: motion, scale: scale)
            projectedState.ensureContainerVisible(
                containerIndex: activeIndex,
                containers: columns,
                gap: gaps,
                viewportSpan: workingSpan,
                motion: motion,
                sizeKeyPath: sizeKeyPath,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                scale: scale,
                workingArea: workingFrame,
                viewFrame: viewFrame,
                orientation: orientation
            )
            return true
        } ?? false
    }

    private func cancelInteractiveResize(
        for column: NiriContainer,
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
}
