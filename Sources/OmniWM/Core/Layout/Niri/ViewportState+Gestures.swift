// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension ViewportState {
    mutating func endGesture(
        currentOffset: Double,
        projectedOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        orientation: Monitor.Orientation,
        motion: MotionSnapshot,
        snapToColumn: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let sizeKeyPath: KeyPath<NiriContainer, CGFloat> = switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
        let totalContentSpan = Double(totalSpan(containers: columns, gap: gap, sizeKeyPath: sizeKeyPath))
        guard totalContentSpan.isFinite, totalContentSpan > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        guard snapToColumn else {
            endGestureWithMomentum(
                projectedOffset: projectedOffset,
                columns: columns,
                gap: gap,
                viewportSpan: viewportSpan,
                totalContentSpan: totalContentSpan,
                sizeKeyPath: sizeKeyPath,
                motion: motion
            )
            return
        }

        let activeContainerPosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let projectedViewPos = Double(activeContainerPosition) + projectedOffset
        let areas = normalizedFittingAreas(
            viewportSpan: viewportSpan,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation,
            scale: scale
        )

        let result = findSnapPointsAndTarget(
            projectedViewPos: projectedViewPos,
            projectedOffset: projectedOffset,
            currentOffset: currentOffset,
            columns: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath,
            areas: areas,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newContainerPosition = containerPosition(
            at: result.columnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let offsetDelta = activeContainerPosition - newContainerPosition

        let previousActiveColumnIndex = activeColumnIndex
        activeColumnIndex = result.columnIndex
        if previousActiveColumnIndex != result.columnIndex {
            viewOffsetToRestore = nil
        }

        let snapTargetOffset = result.viewPos - Double(newContainerPosition)
        let correctedTargetOffset = correctedGestureTargetOffset(
            targetViewPos: result.viewPos,
            columnIndex: result.columnIndex,
            columns: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath,
            areas: areas,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
        let pixel = 1.0 / Double(max(areas.scale, 1.0))
        let targetOffset = abs(correctedTargetOffset - snapTargetOffset) < pixel
            ? snapTargetOffset
            : correctedTargetOffset

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        rebaseOffset(by: offsetDelta)
        springOffset(to: CGFloat(targetOffset))

        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct SnapPoint {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct PreservedGestureOffset {
        let finalOffset: Double
        let normalizedActiveColumn: Int
    }

    private func findSnapPointsAndTarget(
        projectedViewPos: Double,
        projectedOffset: Double,
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        areas: ViewportFittingAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> SnapResult {
        guard !columns.isEmpty else { return SnapResult(viewPos: 0, columnIndex: 0) }

        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)
        let viewSpan = Double(areas.viewSpan)
        let gaps = Double(gap)
        var snapPoints: [SnapPoint] = []

        if isCentering {
            var containerPosition = 0.0
            for (idx, col) in columns.enumerated() {
                let containerSpan = Double(col[keyPath: sizeKeyPath])
                let mode = col.effectiveSizingMode
                let area = areas.area(for: mode)
                let areaSpan = Double(areas.span(of: area))
                let leadingStrut = Double(areas.origin(of: area))

                let viewPos: Double
                if mode.isFullscreen {
                    viewPos = containerPosition
                } else if areaSpan <= containerSpan {
                    viewPos = containerPosition - leadingStrut
                } else {
                    viewPos = containerPosition - (areaSpan - containerSpan) / 2.0 - leadingStrut
                }
                appendSnapPoint(viewPos, idx, to: &snapPoints)

                containerPosition += containerSpan + gaps
            }
        } else {
            let centerOnOverflow = centerMode == .onOverflow

            func snapPair(
                containerPosition: Double,
                column: NiriContainer,
                previousContainerSpan: Double?,
                nextContainerSpan: Double?
            ) -> (leading: Double, trailing: Double) {
                let containerSpan = Double(column[keyPath: sizeKeyPath])
                let mode = column.effectiveSizingMode

                if mode.isFullscreen {
                    return (containerPosition, containerPosition + containerSpan)
                }

                let area = areas.area(for: mode)
                let areaSpan = Double(areas.span(of: area))
                let leadingStrut = Double(areas.origin(of: area))
                let trailingStrut = viewSpan - areaSpan - leadingStrut
                let padding = mode.isMaximized ? 0 : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... gaps)
                let center = if areaSpan <= containerSpan {
                    containerPosition - leadingStrut
                } else {
                    containerPosition - (areaSpan - containerSpan) / 2.0 - leadingStrut
                }

                let isOverflowing: (Double?) -> Bool = { adjacentSpan in
                    guard centerOnOverflow, let adjacentSpan else { return false }
                    return adjacentSpan + 3.0 * gaps + containerSpan > areaSpan
                }

                let leading = isOverflowing(nextContainerSpan)
                    ? center
                    : containerPosition - padding - leadingStrut
                let trailing = isOverflowing(previousContainerSpan)
                    ? center + viewSpan
                    : containerPosition + containerSpan + padding + trailingStrut
                return (leading, trailing)
            }

            // Match Niri's snap-boundary guard: gestures may only snap within the first and last
            // column boundary points, which prevents high momentum at the strip ends from wrapping
            // or choosing an interior snap that would feel like scrolling past the content.
            let leadingSnap = snapPair(
                containerPosition: 0,
                column: columns[0],
                previousContainerSpan: nil,
                nextContainerSpan: columns.dropFirst().first.map { Double($0[keyPath: sizeKeyPath]) }
            ).leading
            let lastColIdx = columns.count - 1
            let lastContainerPosition = Double(containerPosition(
                at: lastColIdx,
                containers: columns,
                gap: gap,
                sizeKeyPath: sizeKeyPath
            ))
            let trailingSnap = snapPair(
                containerPosition: lastContainerPosition,
                column: columns[lastColIdx],
                previousContainerSpan: lastColIdx > 0
                    ? Double(columns[lastColIdx - 1][keyPath: sizeKeyPath])
                    : nil,
                nextContainerSpan: nil
            ).trailing - viewSpan

            appendSnapPoint(leadingSnap, 0, to: &snapPoints)
            appendSnapPoint(trailingSnap, lastColIdx, to: &snapPoints)

            func push(_ colIdx: Int, _ leading: Double, _ trailing: Double) {
                if leadingSnap < leading, leading < trailingSnap {
                    appendSnapPoint(leading, colIdx, to: &snapPoints)
                }

                let trailingViewPos = trailing - viewSpan
                if leadingSnap < trailingViewPos, trailingViewPos < trailingSnap {
                    appendSnapPoint(trailingViewPos, colIdx, to: &snapPoints)
                }
            }

            var containerPosition = 0.0
            for (idx, col) in columns.enumerated() {
                let pair = snapPair(
                    containerPosition: containerPosition,
                    column: col,
                    previousContainerSpan: idx > 0
                        ? Double(columns[idx - 1][keyPath: sizeKeyPath])
                        : nil,
                    nextContainerSpan: idx + 1 < columns.count
                        ? Double(columns[idx + 1][keyPath: sizeKeyPath])
                        : nil
                )
                push(idx, pair.leading, pair.trailing)

                containerPosition += Double(col[keyPath: sizeKeyPath]) + gaps
            }
        }

        snapPoints.sort { $0.viewPos < $1.viewPos }
        guard let closest = snapPoints
            .min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) })
        else {
            return SnapResult(viewPos: 0, columnIndex: 0)
        }

        var newColIdx = closest.columnIndex

        if !isCentering {
            let scrollingForward = projectedOffset >= currentOffset
            if scrollingForward {
                for idx in (newColIdx + 1) ..< columns.count {
                    let containerPosition = Double(containerPosition(
                        at: idx,
                        containers: columns,
                        gap: gap,
                        sizeKeyPath: sizeKeyPath
                    ))
                    let containerSpan = Double(columns[idx][keyPath: sizeKeyPath])
                    let mode = columns[idx].effectiveSizingMode
                    let area = areas.area(for: mode)

                    if mode.isFullscreen {
                        if closest.viewPos + viewSpan < containerPosition + containerSpan {
                            break
                        }
                    } else {
                        let areaSpan = Double(areas.span(of: area))
                        let leadingStrut = Double(areas.origin(of: area))
                        let padding = mode.isMaximized
                            ? 0
                            : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... gaps)
                        if closest.viewPos + leadingStrut + areaSpan
                            < containerPosition + containerSpan + padding
                        {
                            break
                        }
                    }

                    newColIdx = idx
                }
            } else {
                for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
                    let containerPosition = Double(containerPosition(
                        at: idx,
                        containers: columns,
                        gap: gap,
                        sizeKeyPath: sizeKeyPath
                    ))
                    let containerSpan = Double(columns[idx][keyPath: sizeKeyPath])
                    let mode = columns[idx].effectiveSizingMode
                    let area = areas.area(for: mode)

                    if mode.isFullscreen {
                        if containerPosition < closest.viewPos {
                            break
                        }
                    } else {
                        let areaSpan = Double(areas.span(of: area))
                        let leadingStrut = Double(areas.origin(of: area))
                        let padding = mode.isMaximized
                            ? 0
                            : ((areaSpan - containerSpan) / 2.0).clamped(to: 0 ... gaps)
                        if containerPosition - padding < closest.viewPos + leadingStrut {
                            break
                        }
                    }

                    newColIdx = idx
                }
            }
        }

        return SnapResult(viewPos: closest.viewPos, columnIndex: newColIdx)
    }

    private func correctedGestureTargetOffset(
        targetViewPos: Double,
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        areas: ViewportFittingAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool
    ) -> Double {
        guard columns.indices.contains(columnIndex) else { return 0 }
        let containerPosition = Double(containerPosition(
            at: columnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        ))
        let containerSpan = Double(columns[columnIndex][keyPath: sizeKeyPath])
        let mode = columns[columnIndex].effectiveSizingMode
        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)

        let offset = if isCentering {
            computeModeAwareCenteredOffset(
                currentViewStart: CGFloat(targetViewPos),
                targetPos: CGFloat(containerPosition),
                targetSpan: CGFloat(containerSpan),
                mode: mode,
                areas: areas,
                gap: gap
            )
        } else {
            computeModeAwareFitOffset(
                currentViewStart: CGFloat(targetViewPos),
                targetPos: CGFloat(containerPosition),
                targetSpan: CGFloat(containerSpan),
                mode: mode,
                areas: areas,
                gap: gap
            )
        }
        return Double(offset)
    }

    private func appendSnapPoint(_ viewPos: Double, _ columnIndex: Int, to snapPoints: inout [SnapPoint]) {
        guard viewPos.isFinite else { return }
        snapPoints.append(SnapPoint(viewPos: viewPos, columnIndex: columnIndex))
    }

    private mutating func endGestureWithMomentum(
        projectedOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        totalContentSpan: Double,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        motion: MotionSnapshot
    ) {
        let oldActivePosition = containerPosition(
            at: activeColumnIndex,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )

        guard let preserved = normalizedPreservedGestureOffset(
            currentOffset: projectedOffset,
            columns: columns,
            gap: gap,
            viewportSpan: Double(viewportSpan),
            totalContentSpan: totalContentSpan,
            sizeKeyPath: sizeKeyPath
        ) else {
            jumpOffset(to: CGFloat(projectedOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        let newActivePosition = containerPosition(
            at: preserved.normalizedActiveColumn,
            containers: columns,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
        let offsetDelta = oldActivePosition - newActivePosition

        if activeColumnIndex != preserved.normalizedActiveColumn {
            viewOffsetToRestore = nil
        }
        activeColumnIndex = preserved.normalizedActiveColumn

        let maxViewStart = max(0, totalContentSpan - Double(viewportSpan))
        let overscrolled = Double(oldActivePosition) + projectedOffset < 0
            || Double(oldActivePosition) + projectedOffset > maxViewStart

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(preserved.finalOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        rebaseOffset(by: offsetDelta)
        if overscrolled {
            springOffset(to: CGFloat(preserved.finalOffset))
        } else {
            decelerateOffset(to: CGFloat(preserved.finalOffset))
        }
        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    private func normalizedPreservedGestureOffset(
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportSpan: Double,
        totalContentSpan: Double,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> PreservedGestureOffset? {
        guard !columns.isEmpty,
              totalContentSpan.isFinite,
              totalContentSpan > 0,
              viewportSpan.isFinite,
              viewportSpan > 0
        else {
            return nil
        }

        let previousActiveColumn = activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        let gap = Double(gap)
        var positions: [Double] = []
        positions.reserveCapacity(columns.count)
        var runningPosition = 0.0
        for column in columns {
            positions.append(runningPosition)
            runningPosition += Double(column[keyPath: sizeKeyPath]) + gap
        }

        let previousActivePosition = positions[previousActiveColumn]
        let rawViewStart = previousActivePosition + currentOffset
        let maxViewStart = max(0, totalContentSpan - viewportSpan)
        let viewStart = rawViewStart.clamped(to: 0 ... maxViewStart)
        let viewEnd = viewStart + viewportSpan

        let currentContainerSpan = max(0, Double(columns[previousActiveColumn][keyPath: sizeKeyPath]))
        let currentColumnOverlap = visibleOverlap(
            start: previousActivePosition,
            end: previousActivePosition + currentContainerSpan,
            viewStart: viewStart,
            viewEnd: viewEnd
        )
        let normalizedActiveColumn: Int
        if currentContainerSpan > 0, currentColumnOverlap + 0.001 >= currentContainerSpan / 2.0 {
            normalizedActiveColumn = previousActiveColumn
        } else {
            let viewportCenter = viewStart + viewportSpan / 2.0
            var bestIndex = previousActiveColumn
            var bestOverlap = -Double.infinity
            var bestCenterDistance = Double.infinity

            for (index, column) in columns.enumerated() {
                let columnStart = positions[index]
                let columnSpan = max(0, Double(column[keyPath: sizeKeyPath]))
                let columnEnd = columnStart + columnSpan
                let overlap = visibleOverlap(
                    start: columnStart,
                    end: columnEnd,
                    viewStart: viewStart,
                    viewEnd: viewEnd
                )
                let centerDistance = abs((columnStart + columnEnd) / 2.0 - viewportCenter)

                if overlap > bestOverlap + 0.001 ||
                    (abs(overlap - bestOverlap) <= 0.001 && centerDistance < bestCenterDistance)
                {
                    bestIndex = index
                    bestOverlap = overlap
                    bestCenterDistance = centerDistance
                }
            }

            normalizedActiveColumn = bestIndex
        }

        let normalizedActivePosition = positions[normalizedActiveColumn]
        return PreservedGestureOffset(
            finalOffset: viewStart - normalizedActivePosition,
            normalizedActiveColumn: normalizedActiveColumn
        )
    }

    private func visibleOverlap(
        start: Double,
        end: Double,
        viewStart: Double,
        viewEnd: Double
    ) -> Double {
        max(0, min(end, viewEnd) - max(start, viewStart))
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        jumpOffset(to: CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }
}
