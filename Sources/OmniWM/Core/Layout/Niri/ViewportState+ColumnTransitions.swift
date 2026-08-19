// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension ViewportState {
    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        workingArea: CGRect,
        orientation: Monitor.Orientation,
        motion: MotionSnapshot,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0,
        viewFrame: CGRect? = nil
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))
        let viewportSpan: CGFloat = switch orientation {
        case .horizontal: workingArea.width
        case .vertical: workingArea.height
        }

        let oldActivePosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: orientation.renderedSpanKeyPath
        )

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActivePosition = containerPosition(
            at: clampedIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: orientation.renderedSpanKeyPath
        )
        let offsetDelta = oldActivePosition - newActivePosition

        rebaseOffset(by: offsetDelta)

        let settledActivePosition = containerPosition(
            at: clampedIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: orientation.settledSpanKeyPath
        )
        let targetOffset = computeVisibleOffset(
            containerIndex: clampedIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: orientation.settledSpanKeyPath,
            currentViewStart: settledActivePosition + viewOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex ?? prevActiveColumn,
            scale: scale,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation
        )

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffset
        if abs(toDiff) < pixel {
            rebaseOffset(by: toDiff)
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            jumpOffset(to: targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func ensureContainerVisible(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        motion: MotionSnapshot,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation
    ) {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return }

        let stationaryOffset = viewOffset
        let activePos = containerPosition(
            at: activeColumnIndex,
            containers: containers,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let stationaryViewStart = activePos + stationaryOffset
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        let targetOffset = computeVisibleOffset(
            containerIndex: containerIndex,
            containers: containers,
            gap: gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            currentViewStart: stationaryViewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromContainerIndex,
            scale: scale,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation
        )

        if abs(targetOffset - stationaryOffset) <= pixelEpsilon {
            return
        }

        if animate {
            animateToOffset(
                targetOffset,
                motion: motion,
                config: animationConfig,
                scale: scale
            )
        } else {
            jumpOffset(to: targetOffset)
        }
    }
}
