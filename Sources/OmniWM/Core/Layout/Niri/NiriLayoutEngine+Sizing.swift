// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    private func cachedWidthForResizeStart(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if column.cachedWidth <= 0 {
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column
            {
                column.cachedWidth = resolvedSingleWindowRect(
                    for: singleWindowContext,
                    in: workingFrame,
                    scale: 1.0,
                    primaryGap: gaps,
                    secondaryGap: 0,
                    orientation: .horizontal
                ).width
            } else {
                column.resolveAndCacheWidth(
                    workingAreaWidth: workingFrame.width,
                    gaps: gaps,
                    contentInset: tabContentInset(for: column)
                )
            }
        }

        return column.cachedWidth
    }

    private func cachedHeightForResizeStart(
        _ column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        if column.cachedHeight <= 0 {
            column.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: gaps)
        }

        return column.cachedHeight
    }

    func tabContentInset(for column: NiriContainer) -> CGFloat {
        column.isTabbed ? renderStyle.tabIndicatorWidth : 0
    }

    private func resolvedColumnPixels(
        _ width: ProportionalSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        let rawWidth: CGFloat = switch width {
        case let .proportion(proportion):
            (workingFrame.width - gaps) * proportion - gaps
        case let .fixed(fixed):
            fixed
        }

        return column.clampedToWidthBounds(
            rawWidth,
            contentInset: tabContentInset(for: column)
        )
    }

    private func resolvedContainerWidthPreset(
        _ preset: PresetSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        resolvedColumnPixels(
            preset.asProportionalSize,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func resolvedContainerHeightPixels(
        _ height: ProportionalSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        let rawHeight: CGFloat = switch height {
        case let .proportion(proportion):
            (workingFrame.height - gaps) * proportion - gaps
        case let .fixed(fixed):
            fixed
        }

        return column.clampedToHeightBounds(rawHeight)
    }

    private func resolvedContainerHeightPreset(
        _ preset: PresetSize,
        for column: NiriContainer,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> CGFloat {
        resolvedContainerHeightPixels(
            preset.asProportionalSize,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func containerPrimarySpanSpec(
        for change: NiriSizeChange,
        currentSpec: ProportionalSize,
        currentPixels: CGFloat,
        axisSpan: CGFloat,
        gaps: CGFloat
    ) -> ProportionalSize {
        switch change {
        case let .setFixed(fixed):
            return .fixed(fixed.clamped(to: 1 ... NiriSizeChange.maxPixels))
        case let .setProportion(proportion):
            return .proportion((proportion / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        case let .adjustFixed(delta):
            return .fixed((currentPixels + delta).clamped(to: 1 ... NiriSizeChange.maxPixels))
        case let .adjustProportion(delta):
            let currentProportion: CGFloat
            switch currentSpec {
            case let .proportion(proportion):
                currentProportion = proportion
            case .fixed:
                let proportionalSpan = axisSpan - gaps
                if proportionalSpan == 0 {
                    currentProportion = 1
                } else {
                    currentProportion = (currentPixels + gaps) / proportionalSpan
                }
            }
            return .proportion((currentProportion + delta / 100).clamped(to: 0 ... NiriSizeChange.maxProportion))
        }
    }

    private func changedWindowSecondaryPixels(
        for change: NiriSizeChange,
        currentPixels: CGFloat,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        let proportionalSpan = availableSpan - gaps
        let currentProportion = proportionalSpan == 0 ? 1 : (currentPixels + gaps) / proportionalSpan
        switch change {
        case let .setFixed(fixed):
            return fixed
        case let .setProportion(proportion):
            return proportionalSpan * (proportion / 100) - gaps
        case let .adjustFixed(delta):
            return currentPixels + delta
        case let .adjustProportion(delta):
            return proportionalSpan * (currentProportion + delta / 100) - gaps
        }
    }

    private func resolvedPresetWindowSecondarySpan(
        _ preset: PresetSize,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        switch preset.kind {
        case let .proportion(proportion):
            (availableSpan - gaps) * proportion - gaps
        case let .fixed(fixed):
            fixed
        }
    }

    private func applyColumnWidth(
        _ column: NiriContainer,
        width newWidth: ProportionalSize,
        presetIndex: Int?,
        previousWidth: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        recoversSettledCoverage: Bool = true
    ) {
        cancelInteractiveResize(for: column, in: workspaceId)

        column.width = newWidth
        column.presetWidthIdx = presetIndex
        column.isFullWidth = false
        column.savedWidth = nil
        column.hasManualSingleWindowWidthOverride = true

        let targetPixels = resolvedColumnPixels(
            newWidth,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )

        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: motion.animationsEnabled
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        if recoversSettledCoverage {
            recoverSettledCoverage(
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func ensureSelectionVisibleForPendingWidth(
        _ column: NiriContainer,
        targetWidth: CGFloat,
        previousWidth: CGFloat,
        restorePreviousWidthAfterFit: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        guard orientation == .horizontal else { return }
        guard let window = column.windowNodes.first else { return }

        // Expose the target width only for viewport-fit math. Animated width
        // changes restore the previous cache so the spring can continue from
        // the old span; immediate width changes keep the new target cached.
        if restorePreviousWidthAfterFit {
            column.cachedWidth = targetWidth
            defer { column.cachedWidth = previousWidth }
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        } else {
            column.cachedWidth = targetWidth
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func applyContainerHeight(
        _ column: NiriContainer,
        height newHeight: ProportionalSize,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        cancelInteractiveResize(for: column, in: workspaceId)

        column.height = newHeight
        column.isFullHeight = false
        column.savedHeight = nil
        column.hasManualSingleWindowHeightOverride = true
        column.cachedHeight = resolvedContainerHeightPixels(
            newHeight,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )

        if let window = column.activeWindow ?? column.windowNodes.first {
            ensureSelectionVisible(
                node: window,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: .vertical
            )
        }
        recoverSettledCoverage(
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .vertical
        )
    }

    private func toggleContainerHeight(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        let currentHeight = cachedHeightForResizeStart(
            column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let nextIndex: Int
        if forwards {
            nextIndex = presetContainerPrimarySpans.firstIndex { preset in
                currentHeight + 1 < resolvedContainerHeightPreset(
                    preset,
                    for: column,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            } ?? 0
        } else {
            nextIndex = presetContainerPrimarySpans.lastIndex { preset in
                resolvedContainerHeightPreset(
                    preset,
                    for: column,
                    workingFrame: workingFrame,
                    gaps: gaps
                ) + 1 < currentHeight
            } ?? (presetContainerPrimarySpans.count - 1)
        }

        let currentSpec = column.isFullHeight ? ProportionalSize.proportion(1) : column.height
        let newHeight = containerPrimarySpanSpec(
            for: NiriSizeChange(presetContainerPrimarySpans[nextIndex]),
            currentSpec: currentSpec,
            currentPixels: currentHeight,
            axisSpan: workingFrame.height,
            gaps: gaps
        )
        applyContainerHeight(
            column,
            height: newHeight,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    private func toggleFullHeight(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .vertical
        )
        let containers = columns(in: workspaceId)
        let activeIndex = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let previousActivePosition = state.containerPosition(
            at: activeIndex,
            containers: containers,
            gap: gaps,
            sizeKeyPath: \.cachedHeight
        )
        let previousHeight = cachedHeightForResizeStart(
            column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        cancelInteractiveResize(for: column, in: workspaceId)
        column.hasManualSingleWindowHeightOverride = true

        if column.isFullHeight {
            column.isFullHeight = false
            if let savedHeight = column.savedHeight {
                column.height = savedHeight
                column.savedHeight = nil
            }
        } else {
            column.savedHeight = column.height
            column.isFullHeight = true
        }

        let effectiveHeight = column.isFullHeight ? ProportionalSize.proportion(1) : column.height
        column.cachedHeight = resolvedContainerHeightPixels(
            effectiveHeight,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )

        guard abs(column.cachedHeight - previousHeight) > 0.001 else { return }

        let settings = effectiveSettings(in: workspaceId)
        if settings.centerFocusedColumn == .always
            || (settings.alwaysCenterSingleColumn && containers.count == 1)
        {
            if let window = column.activeWindow ?? column.windowNodes.first {
                ensureSelectionVisible(
                    node: window,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: .vertical
                )
            }
        } else {
            let currentActivePosition = state.containerPosition(
                at: activeIndex,
                containers: containers,
                gap: gaps,
                sizeKeyPath: \.cachedHeight
            )
            state.rebaseOffset(by: previousActivePosition - currentActivePosition)
        }
        recoverSettledCoverage(
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .vertical
        )
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

    func calculateVerticalPixelsPerWeightUnit(
        column: NiriContainer,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGFloat {
        let windows = projectedWindows(in: column, workspaceId: workspaceId)
        guard !windows.isEmpty else { return 0 }

        let totalWeight = windows.reduce(CGFloat(0)) { $0 + $1.size }
        guard totalWeight > 0 else { return 0 }

        let totalGaps = CGFloat(windows.count + 1) * gaps.vertical
        let usableHeight = monitorFrame.height - totalGaps

        return usableHeight / totalWeight
    }

    func setWindowSizingMode(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        mode: SizingMode,
        state: inout ViewportState
    ) {
        let previousMode = window.sizingMode

        if previousMode == mode {
            return
        }

        if previousMode == .fullscreen, mode == .normal {
            if let savedHeight = window.savedHeight {
                window.height = savedHeight
                window.savedHeight = nil
            }

            if let savedOffset = state.viewOffsetToRestore {
                state.animateViewOffsetRestore(savedOffset, motion: motion)
            }
        }

        if previousMode == .normal, mode == .fullscreen {
            window.savedHeight = window.height
            state.saveViewOffsetForFullscreen()
            window.stopMoveAnimations()
        }

        window.sizingMode = mode
    }

    func toggleFullscreen(
        _ window: NiriWindow,
        motion: MotionSnapshot,
        state: inout ViewportState
    ) {
        assertSanctionedMutation()
        let newMode: SizingMode = window.sizingMode == .fullscreen ? .normal : .fullscreen
        setWindowSizingMode(window, motion: motion, mode: newMode, state: &state)
    }

    func toggleContainerPrimarySpan(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard !presetContainerPrimarySpans.isEmpty else { return }
        if orientation == .vertical {
            toggleContainerHeight(
                column,
                forwards: forwards,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            return
        }

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )

        let presetCount = presetContainerPrimarySpans.count

        let nextIdx: Int
        if !column.isFullWidth, let currentIdx = column.presetWidthIdx {
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        } else {
            let currentTile: CGFloat
            if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
               singleWindowContext.container === column,
               !column.hasManualSingleWindowWidthOverride
            {
                currentTile = resolvedColumnPixels(
                    column.width,
                    for: column,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            } else {
                currentTile = previousWidth
            }

            if forwards {
                nextIdx = presetContainerPrimarySpans.firstIndex { preset in
                    currentTile + 1 < resolvedContainerWidthPreset(
                        preset,
                        for: column,
                        workingFrame: workingFrame,
                        gaps: gaps
                    )
                } ?? 0
            } else {
                let matchingIndex = presetContainerPrimarySpans.lastIndex { preset in
                    resolvedContainerWidthPreset(
                        preset,
                        for: column,
                        workingFrame: workingFrame,
                        gaps: gaps
                    ) + 1 < currentTile
                }
                nextIdx = matchingIndex ?? (presetCount - 1)
            }
        }

        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let newWidth = containerPrimarySpanSpec(
            for: NiriSizeChange(presetContainerPrimarySpans[nextIdx]),
            currentSpec: currentSpec,
            currentPixels: previousWidth,
            axisSpan: workingFrame.width,
            gaps: gaps
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nextIdx,
            previousWidth: previousWidth,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func toggleWindowPrimarySpan(
        _ window: NiriWindow,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        toggleContainerPrimarySpan(
            column,
            forwards: forwards,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func setContainerPrimarySpan(
        _ column: NiriContainer,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        if orientation == .vertical {
            let previousHeight = cachedHeightForResizeStart(
                column,
                workingFrame: workingFrame,
                gaps: gaps
            )
            let currentSpec = column.isFullHeight ? ProportionalSize.proportion(1) : column.height
            let newHeight = containerPrimarySpanSpec(
                for: change,
                currentSpec: currentSpec,
                currentPixels: previousHeight,
                axisSpan: workingFrame.height,
                gaps: gaps
            )
            applyContainerHeight(
                column,
                height: newHeight,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            return
        }

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let currentSpec = column.isFullWidth ? ProportionalSize.proportion(1) : column.width
        let currentPixels = resolvedColumnPixels(
            currentSpec,
            for: column,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let newWidth = containerPrimarySpanSpec(
            for: change,
            currentSpec: currentSpec,
            currentPixels: currentPixels,
            axisSpan: workingFrame.width,
            gaps: gaps
        )

        applyColumnWidth(
            column,
            width: newWidth,
            presetIndex: nil,
            previousWidth: previousWidth,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func setWindowPrimarySpan(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard let column = findColumn(containing: window, in: workspaceId) else { return }
        setContainerPrimarySpan(
            column,
            change: change,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func toggleContainerFullPrimarySpan(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        if orientation == .vertical {
            toggleFullHeight(
                column,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            return
        }

        let previousWidth = cachedWidthForResizeStart(
            column,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps
        )
        let targetPixels: CGFloat
        cancelInteractiveResize(for: column, in: workspaceId)

        if column.isFullWidth {
            column.isFullWidth = false
            if let saved = column.savedWidth {
                column.width = saved
                column.savedWidth = nil
            }
            column.hasManualSingleWindowWidthOverride = true
            targetPixels = resolvedColumnPixels(column.width, for: column, workingFrame: workingFrame, gaps: gaps)
        } else {
            column.savedWidth = column.width
            column.isFullWidth = true
            column.presetWidthIdx = nil
            column.hasManualSingleWindowWidthOverride = true
            targetPixels = resolvedColumnPixels(.proportion(1), for: column, workingFrame: workingFrame, gaps: gaps)
        }

        let didStartWidthAnimation = column.animateWidthTo(
            newWidth: targetPixels,
            clock: animationClock,
            config: windowMovementAnimationConfig,
            displayRefreshRate: displayRefreshRate(in: workspaceId),
            animated: motion.animationsEnabled
        )

        ensureSelectionVisibleForPendingWidth(
            column,
            targetWidth: targetPixels,
            previousWidth: previousWidth,
            restorePreviousWidthAfterFit: didStartWidthAnimation,
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        recoverSettledCoverage(
            in: workspaceId,
            motion: motion,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }

    func expandContainerToAvailablePrimarySpan(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot = .enabled,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        switch orientation {
        case .horizontal:
            guard !column.isFullWidth else { return }
        case .vertical:
            guard !column.isFullHeight else { return }
        }
        guard column.windowNodes.allSatisfy({ $0.sizingMode == .normal }) else { return }

        if centerFocusedColumn == .always || orientation == .vertical {
            toggleContainerFullPrimarySpan(
                column,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
            return
        }

        var resultingWidth: CGFloat?
        _ = withProjectedViewport(
            state: &state,
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        ) { columns, projectedState in
            guard let activeColumnIndex = columns.firstIndex(where: { $0 === column }) else { return }
            let viewX = projectedState.columnX(
                at: projectedState.activeColumnIndex.clamped(to: 0 ... max(0, columns.count - 1)),
                columns: columns,
                gap: gaps
            ) + projectedState.viewOffset

            var widthTaken: CGFloat = 0
            var leftmostColX: CGFloat?
            var activeColX: CGFloat?
            var activeColumnWasFullyVisible = false
            var countedNonActiveColumn = false

            for idx in columns.indices {
                let colX = projectedState.columnX(at: idx, columns: columns, gap: gaps)
                if colX < viewX + gaps {
                    continue
                }

                if leftmostColX == nil {
                    leftmostColX = colX
                }

                let width = columns[idx].cachedWidth
                if viewX + workingFrame.width < colX + width + gaps {
                    break
                }

                if idx == activeColumnIndex {
                    activeColumnWasFullyVisible = true
                    activeColX = colX
                } else {
                    countedNonActiveColumn = true
                }

                widthTaken += width + gaps
            }

            guard activeColumnWasFullyVisible else { return }
            let availableWidth = workingFrame.width - gaps - widthTaken
            guard availableWidth > 0 else { return }

            if !countedNonActiveColumn {
                toggleContainerFullPrimarySpan(
                    column,
                    in: workspaceId,
                    motion: motion,
                    state: &projectedState,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
                resultingWidth = column.cachedWidth
                return
            }

            guard let leftmostColX, let activeColX else { return }
            let previousWidth = cachedWidthForResizeStart(
                column,
                in: workspaceId,
                workingFrame: workingFrame,
                gaps: gaps
            )
            let targetWidth = (column.cachedWidth + availableWidth).clamped(to: 1 ... NiriSizeChange.maxPixels)
            applyColumnWidth(
                column,
                width: .fixed(targetWidth),
                presetIndex: nil,
                previousWidth: previousWidth,
                in: workspaceId,
                motion: motion,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                recoversSettledCoverage: false
            )
            resultingWidth = column.cachedWidth
            let targetOffset = leftmostColX - gaps - activeColX
            projectedState.animateToOffset(
                targetOffset,
                motion: motion,
                scale: displayScale(in: workspaceId)
            )
            recoverSettledCoverage(
                in: workspaceId,
                motion: motion,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
        if let resultingWidth {
            column.cachedWidth = resultingWidth
        }
    }

    private func currentWindowWidth(_ window: NiriWindow) -> CGFloat {
        switch window.windowWidth {
        case let .fixed(width):
            width
        case .auto,
             .preset:
            window.resolvedWidth ?? window.frame?.width ?? max(1, window.widthWeight)
        }
    }

    private func convertWidthsToAuto(_ windows: [NiriWindow]) {
        guard !windows.isEmpty else { return }

        let widths = windows.map { max(1, $0.resolvedWidth ?? $0.frame?.width ?? $0.widthWeight) }
        let median = max(1, widths.sorted()[widths.count / 2])

        for (window, width) in zip(windows, widths) {
            window.windowWidth = .auto(weight: width / median)
        }
    }

    private func availableWindowWidth(
        in column: NiriContainer,
        projectedWindowCount: Int,
        workingFrame: CGRect
    ) -> CGFloat {
        let contentInset = column.isTabbed && projectedWindowCount > 1
            ? tabContentInset(for: column)
            : 0
        return max(1, workingFrame.width - contentInset)
    }

    private func setVerticalWindowWidth(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in column: NiriContainer,
        projectedWindows: [NiriWindow],
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        if window.windowWidth.isAuto {
            convertWidthsToAuto(projectedWindows)
        }

        let currentWindowPixels = currentWindowWidth(window)
        let availableWidth = availableWindowWidth(
            in: column,
            projectedWindowCount: projectedWindows.count,
            workingFrame: workingFrame
        )
        var windowWidth = changedWindowSecondaryPixels(
            for: change,
            currentPixels: currentWindowPixels,
            availableSpan: availableWidth,
            gaps: gaps
        )

        let minWidthTaken: CGFloat
        if column.isTabbed {
            minWidthTaken = 0
        } else {
            minWidthTaken = projectedWindows
                .filter { $0 !== window }
                .reduce(CGFloat(0)) { partial, otherWindow in
                    partial + max(1, otherWindow.constraints.minSize.width) + gaps
                }
        }

        let widthLeft = max(1, availableWidth - gaps - minWidthTaken - gaps)
        windowWidth = min(widthLeft, windowWidth)
        windowWidth = window.constraints.clampWidth(windowWidth)
        window.windowWidth = .fixed(windowWidth.clamped(to: 1 ... NiriSizeChange.maxPixels))
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }

    private func currentWindowHeight(_ window: NiriWindow) -> CGFloat {
        switch window.height {
        case let .fixed(height):
            height
        case .auto,
             .preset:
            window.resolvedHeight ?? window.frame?.height ?? max(1, window.heightWeight)
        }
    }

    private func convertHeightsToAuto(_ windows: [NiriWindow]) {
        guard !windows.isEmpty else { return }

        let heights = windows.map { max(1, $0.resolvedHeight ?? $0.frame?.height ?? $0.heightWeight) }
        let median = max(1, heights.sorted()[heights.count / 2])

        for (window, height) in zip(windows, heights) {
            window.height = .auto(weight: height / median)
        }
    }

    func setWindowSecondarySpan(
        _ window: NiriWindow,
        change: NiriSizeChange,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if orientation == .vertical {
            setVerticalWindowWidth(
                window,
                change: change,
                in: column,
                projectedWindows: projectedWindows,
                workingFrame: workingFrame,
                gaps: gaps
            )
            return
        }

        if window.height.isAuto {
            convertHeightsToAuto(projectedWindows)
        }

        let currentWindowPixels = currentWindowHeight(window)
        var windowHeight = changedWindowSecondaryPixels(
            for: change,
            currentPixels: currentWindowPixels,
            availableSpan: workingFrame.height,
            gaps: gaps
        )

        let minHeightTaken: CGFloat
        if column.isTabbed {
            minHeightTaken = 0
        } else {
            minHeightTaken = projectedWindows
                .filter { $0 !== window }
                .reduce(CGFloat(0)) { partial, otherWindow in
                    partial + max(1, otherWindow.constraints.minSize.height) + gaps
                }
        }

        let heightLeft = max(1, workingFrame.height - gaps - minHeightTaken - gaps)
        windowHeight = min(heightLeft, windowHeight)
        windowHeight = window.constraints.clampHeight(windowHeight)
        window.height = .fixed(windowHeight.clamped(to: 1 ... NiriSizeChange.maxPixels))
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }

    func resetWindowSecondarySpan(
        _ window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if orientation == .vertical {
            if column.isTabbed {
                for tile in projectedWindows {
                    tile.windowWidth = .auto(weight: 1)
                }
            } else {
                window.windowWidth = .auto(weight: 1)
            }
            return
        }

        if column.isTabbed {
            for tile in projectedWindows {
                tile.height = .auto(weight: 1)
                tile.savedHeight = nil
            }
        } else {
            window.height = .auto(weight: 1)
            window.savedHeight = nil
        }
    }

    func toggleWindowSecondarySpan(
        _ window: NiriWindow,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) {
        assertSanctionedMutation()
        guard !presetWindowSecondarySpans.isEmpty else { return }
        guard !isExcludedFromProjection(window.token, in: workspaceId),
              let column = findColumn(containing: window, in: workspaceId)
        else {
            return
        }
        let projectedWindows = projectedWindows(in: column, workspaceId: workspaceId)
        cancelInteractiveResize(for: column, in: workspaceId)
        if orientation == .vertical {
            let availableWidth = availableWindowWidth(
                in: column,
                projectedWindowCount: projectedWindows.count,
                workingFrame: workingFrame
            )
            if window.windowWidth.isAuto {
                convertWidthsToAuto(projectedWindows)
            }

            let presetCount = presetWindowSecondarySpans.count
            let nextIndex: Int
            switch window.windowWidth {
            case let .preset(currentIndex) where window.sizingMode != .maximized:
                if forwards {
                    nextIndex = (currentIndex + 1) % presetCount
                } else {
                    nextIndex = (currentIndex - 1 + presetCount) % presetCount
                }
            default:
                let current = currentWindowWidth(window)
                if forwards {
                    nextIndex = presetWindowSecondarySpans.firstIndex { preset in
                        current + 1 < resolvedPresetWindowSecondarySpan(
                            preset,
                            availableSpan: availableWidth,
                            gaps: gaps
                        )
                    } ?? 0
                } else {
                    nextIndex = presetWindowSecondarySpans.lastIndex { preset in
                        resolvedPresetWindowSecondarySpan(
                            preset,
                            availableSpan: availableWidth,
                            gaps: gaps
                        ) + 1 < current
                    } ?? (presetCount - 1)
                }
            }

            window.windowWidth = .preset(nextIndex)
            if window.sizingMode == .maximized {
                window.sizingMode = .normal
            }
            return
        }

        if window.height.isAuto {
            convertHeightsToAuto(projectedWindows)
        }

        let presetCount = presetWindowSecondarySpans.count
        let nextIdx: Int
        switch window.height {
        case let .preset(currentIdx) where window.sizingMode != .maximized:
            if forwards {
                nextIdx = (currentIdx + 1) % presetCount
            } else {
                nextIdx = (currentIdx - 1 + presetCount) % presetCount
            }
        default:
            let current = currentWindowHeight(window)
            if forwards {
                nextIdx = presetWindowSecondarySpans.firstIndex { preset in
                    current + 1 < resolvedPresetWindowSecondarySpan(
                        preset,
                        availableSpan: workingFrame.height,
                        gaps: gaps
                    )
                } ?? 0
            } else {
                nextIdx = presetWindowSecondarySpans.lastIndex { preset in
                    resolvedPresetWindowSecondarySpan(
                        preset,
                        availableSpan: workingFrame.height,
                        gaps: gaps
                    ) + 1 < current
                } ?? (presetCount - 1)
            }
        }

        window.height = .preset(nextIdx)
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }
}

private extension NiriSizeChange {
    init(_ preset: PresetSize) {
        switch preset.kind {
        case let .proportion(proportion):
            self = .setProportion(proportion * 100)
        case let .fixed(fixed):
            self = .setFixed(fixed)
        }
    }
}
