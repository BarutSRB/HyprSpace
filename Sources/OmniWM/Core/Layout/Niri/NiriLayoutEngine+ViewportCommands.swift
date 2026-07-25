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
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... (columns.count - 1))
        state.activeColumnIndex = activeIndex
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

        cancelInteractiveResize(for: columns[activeIndex], in: workspaceId)

        let scale = displayScale(in: workspaceId)
        let viewFrame = monitorForWorkspace(workspaceId)?.frame
        let targetOffset = state.computeCenteredOffset(
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
        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: scale
        )
        return true
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
        let columns = columns(in: workspaceId)
        guard !columns.isEmpty else { return false }

        let settings = effectiveSettings(in: workspaceId)
        if settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && columns.count <= 1)
        {
            return false
        }

        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... (columns.count - 1))
        state.activeColumnIndex = activeIndex
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
        let areas = state.normalizedFittingAreas(
            viewportSpan: viewportSpan,
            workingArea: workingFrame,
            viewFrame: viewFrame,
            orientation: orientation,
            scale: scale
        )
        let activePosition = state.containerPosition(
            at: activeIndex,
            containers: columns,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let workingStart = areas.origin(of: areas.working)
        let workingSpan = areas.span(of: areas.working)

        var spanTaken: CGFloat = 0
        var firstVisiblePosition: CGFloat?
        var activeContainerPosition: CGFloat?

        for (idx, column) in columns.enumerated() {
            let position = state.containerPosition(
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

        state.animateToOffset(
            targetOffset,
            motion: motion,
            scale: scale
        )

        state.ensureContainerVisible(
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
