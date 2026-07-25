// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct ViewportFittingAreas {
    let working: CGRect
    let parent: CGRect
    let orientation: Monitor.Orientation
    let scale: CGFloat

    var viewSpan: CGFloat {
        span(of: parent)
    }

    func span(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.width
        case .vertical:
            rect.height
        }
    }

    func origin(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.minX
        case .vertical:
            rect.minY
        }
    }

    func area(for mode: SizingMode) -> CGRect {
        mode.isMaximized ? parent : working
    }
}

extension SizingMode {
    var isMaximized: Bool {
        self == .maximized
    }

    var isFullscreen: Bool {
        self == .fullscreen
    }
}

extension NiriContainer {
    var effectiveSizingMode: SizingMode {
        var anyFullscreen = false
        var anyMaximized = false
        for window in windowNodes {
            switch window.sizingMode {
            case .normal:
                continue
            case .maximized:
                anyMaximized = true
            case .fullscreen:
                anyFullscreen = true
            }
        }

        if anyFullscreen {
            return .fullscreen
        } else if anyMaximized {
            return .maximized
        } else {
            return .normal
        }
    }
}

extension ViewportState {
    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func containerPosition(
        at index: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        var pos: CGFloat = 0
        for i in 0 ..< index {
            guard i < containers.count else { break }
            pos += containers[i][keyPath: sizeKeyPath] + gap
        }
        return pos
    }

    func totalSpan(containers: [NiriContainer], gap: CGFloat, sizeKeyPath: KeyPath<NiriContainer, CGFloat>) -> CGFloat {
        guard !containers.isEmpty else { return 0 }
        let sizeSum = containers.reduce(0) { $0 + $1[keyPath: sizeKeyPath] }
        let gapSum = CGFloat(max(0, containers.count - 1)) * gap
        return sizeSum + gapSum
    }

    func normalizedFittingAreas(
        viewportSpan: CGFloat,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation,
        scale: CGFloat = 2.0
    ) -> ViewportFittingAreas {
        let crossSpan: CGFloat = switch orientation {
        case .horizontal:
            workingArea?.height ?? viewFrame?.height ?? 0
        case .vertical:
            workingArea?.width ?? viewFrame?.width ?? 0
        }
        let fallbackParentFrame: CGRect = switch orientation {
        case .horizontal:
            CGRect(x: 0, y: 0, width: viewportSpan, height: crossSpan)
        case .vertical:
            CGRect(x: 0, y: 0, width: crossSpan, height: viewportSpan)
        }
        let parentFrame = viewFrame ?? workingArea ?? fallbackParentFrame

        let localWorking: CGRect
        if let workingArea {
            localWorking = CGRect(
                origin: .zero,
                size: workingArea.size
            )
        } else {
            localWorking = CGRect(origin: .zero, size: parentFrame.size)
        }

        let parent: CGRect
        if let workingArea {
            parent = CGRect(
                x: parentFrame.minX - workingArea.minX,
                y: parentFrame.minY - workingArea.minY,
                width: parentFrame.width,
                height: parentFrame.height
            )
        } else {
            parent = CGRect(
                origin: .zero,
                size: parentFrame.size
            )
        }

        let fallbackLocalSize = workingArea?.size ?? fallbackParentFrame.size
        let fallbackLocalFrame = CGRect(origin: .zero, size: fallbackLocalSize)
        let primarySpan: (CGRect) -> CGFloat = { rect in
            switch orientation {
            case .horizontal:
                rect.width
            case .vertical:
                rect.height
            }
        }

        return ViewportFittingAreas(
            working: primarySpan(localWorking) > 0 ? localWorking : fallbackLocalFrame,
            parent: primarySpan(parent) > 0 ? parent : fallbackLocalFrame,
            orientation: orientation,
            scale: scale
        )
    }

    func computeCenteredOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return 0 }

        let areas = normalizedFittingAreas(
            viewportSpan: viewportSpan,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation,
            scale: scale
        )
        let targetPos = containerPosition(
            at: containerIndex,
            containers: containers,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetSize = containers[containerIndex][keyPath: sizeKeyPath]
        let mode = containers[containerIndex].effectiveSizingMode

        return computeModeAwareCenteredOffset(
            currentViewStart: targetPos,
            targetPos: targetPos,
            targetSpan: targetSize,
            mode: mode,
            areas: areas,
            gap: gap
        )
    }

    private func computeFitOffset(
        currentViewPos: CGFloat,
        viewSpan: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        gap: CGFloat,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        if viewSpan <= targetSpan + pixelEpsilon {
            return 0
        }

        let padding = ((viewSpan - targetSpan) / 2).clamped(to: 0 ... gap)
        let preferredStart = targetPos - padding
        let targetEnd = targetPos + targetSpan
        let preferredEnd = targetEnd + padding

        if currentViewPos - pixelEpsilon <= preferredStart
            && preferredEnd <= currentViewPos + viewSpan + pixelEpsilon
        {
            return currentViewPos - targetPos
        }

        let distToStart = abs(currentViewPos - preferredStart)
        let distToEnd = abs((currentViewPos + viewSpan) - preferredEnd)

        if distToStart <= distToEnd {
            return -padding
        } else {
            return -(viewSpan - padding - targetSpan)
        }
    }

    func computeModeAwareFitOffset(
        currentViewStart: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        mode: SizingMode,
        areas: ViewportFittingAreas,
        gap: CGFloat
    ) -> CGFloat {
        if mode.isFullscreen {
            return 0
        }

        let area = areas.area(for: mode)
        let areaStart = areas.origin(of: area)
        let padding = mode.isMaximized ? 0 : gap
        let newOffset = computeFitOffset(
            currentViewPos: currentViewStart + areaStart,
            viewSpan: areas.span(of: area),
            targetPos: targetPos,
            targetSpan: targetSpan,
            gap: padding,
            scale: areas.scale
        )
        return newOffset - areaStart
    }

    func computeModeAwareCenteredOffset(
        currentViewStart: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        mode: SizingMode,
        areas: ViewportFittingAreas,
        gap: CGFloat
    ) -> CGFloat {
        if mode.isFullscreen {
            return computeModeAwareFitOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSpan,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        let area = areas.area(for: mode)
        let areaSpan = areas.span(of: area)
        let areaStart = areas.origin(of: area)
        if areaSpan <= targetSpan {
            return computeModeAwareFitOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSpan,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        return -(areaSpan - targetSpan) / 2 - areaStart
    }

    func computeVisibleOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return 0 }

        let areas = normalizedFittingAreas(
            viewportSpan: viewportSpan,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation,
            scale: scale
        )
        let effectiveCenterMode = (containers.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode
        let targetPos = containerPosition(
            at: containerIndex,
            containers: containers,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let targetSize = containers[containerIndex][keyPath: sizeKeyPath]
        let targetMode = containers[containerIndex].effectiveSizingMode

        var targetOffset: CGFloat

        switch effectiveCenterMode {
        case .always:
            targetOffset = computeModeAwareCenteredOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSize,
                mode: targetMode,
                areas: areas,
                gap: gap
            )

        case .onOverflow:
            if let fromIdx = fromContainerIndex,
               fromIdx != containerIndex,
               containers.indices.contains(fromIdx)
            {
                let sourceIdx = if fromIdx > containerIndex {
                    min(containerIndex + 1, containers.count - 1)
                } else {
                    max(containerIndex - 1, 0)
                }
                let sourcePos = containerPosition(
                    at: sourceIdx,
                    containers: containers,
                    gap: gap,
                    sizeKeyPath: sizeKeyPath
                )
                let sourceSize = containers[sourceIdx][keyPath: sizeKeyPath]
                let pairSpan = if sourcePos < targetPos {
                    targetPos - sourcePos + targetSize
                } else {
                    sourcePos - targetPos + sourceSize
                }

                if pairSpan + gap * 2 <= areas.span(of: areas.working) {
                    targetOffset = computeModeAwareFitOffset(
                        currentViewStart: currentViewStart,
                        targetPos: targetPos,
                        targetSpan: targetSize,
                        mode: targetMode,
                        areas: areas,
                        gap: gap
                    )
                } else {
                    targetOffset = computeModeAwareCenteredOffset(
                        currentViewStart: currentViewStart,
                        targetPos: targetPos,
                        targetSpan: targetSize,
                        mode: targetMode,
                        areas: areas,
                        gap: gap
                    )
                }
            } else {
                targetOffset = computeModeAwareFitOffset(
                    currentViewStart: currentViewStart,
                    targetPos: targetPos,
                    targetSpan: targetSize,
                    mode: targetMode,
                    areas: areas,
                    gap: gap
                )
            }

        case .never:
            targetOffset = computeModeAwareFitOffset(
                currentViewStart: currentViewStart,
                targetPos: targetPos,
                targetSpan: targetSize,
                mode: targetMode,
                areas: areas,
                gap: gap
            )
        }

        return targetOffset
    }

    func computeCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        computeCenteredOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: .horizontal,
            scale: scale
        )
    }

    func computeVisibleOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil
    ) -> CGFloat {
        let colX = columnX(at: columnIndex, columns: columns, gap: gap)
        return computeVisibleOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: colX + currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex,
            scale: scale,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: .horizontal
        )
    }
}
