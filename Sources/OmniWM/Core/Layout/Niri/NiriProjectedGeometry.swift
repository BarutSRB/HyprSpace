// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct NiriProjectedViewportAnchor {
    let columnId: NodeId
    let projectedIndex: Int
    let primaryPosition: CGFloat
}

struct NiriProjectedColumnGeometry {
    let projectedColumn: NiriProjectedColumn
    let primaryPosition: CGFloat
    let secondaryOffsets: [CGFloat]
}

struct NiriProjectedGeometrySnapshot {
    let columns: [NiriProjectedColumnGeometry]

    func column(containing column: NiriContainer) -> NiriProjectedColumnGeometry? {
        columns.first { $0.projectedColumn.column === column }
    }

    func secondaryOffset(of window: NiriWindow, in container: NiriContainer) -> CGFloat? {
        guard let geometry = column(containing: container),
              let index = geometry.projectedColumn.windows.firstIndex(where: { $0 === window }),
              geometry.secondaryOffsets.indices.contains(index)
        else {
            return nil
        }
        return geometry.secondaryOffsets[index]
    }
}

extension NiriLayoutEngine {
    func projectedGeometrySnapshot(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriProjectedGeometrySnapshot {
        let projectedColumns = projectedColumns(in: workspaceId)
        var primaryPosition: CGFloat = 0
        var geometry: [NiriProjectedColumnGeometry] = []
        geometry.reserveCapacity(projectedColumns.count)

        for projectedColumn in projectedColumns {
            let effectiveTabbed = projectedColumn.column.isTabbed && projectedColumn.windows.count > 1
            geometry.append(
                NiriProjectedColumnGeometry(
                    projectedColumn: projectedColumn,
                    primaryPosition: primaryPosition,
                    secondaryOffsets: projectedSecondaryOffsets(
                        for: projectedColumn.windows,
                        effectiveTabbed: effectiveTabbed,
                        gaps: gaps,
                        orientation: orientation
                    )
                )
            )
            primaryPosition += projectedPrimarySpan(
                for: projectedColumn,
                workingFrame: workingFrame,
                gap: gaps,
                orientation: orientation
            ) + gaps
        }

        return NiriProjectedGeometrySnapshot(columns: geometry)
    }

    func projectedViewportAnchor(
        state: ViewportState,
        geometry: NiriProjectedGeometrySnapshot,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriProjectedViewportAnchor? {
        let projectedColumns = geometry.columns.map(\.projectedColumn)
        guard !projectedColumns.isEmpty else { return nil }
        let index = projectedActiveColumnIndex(
            state: state,
            columns: projectedColumns,
            in: workspaceId
        )
        guard geometry.columns.indices.contains(index) else { return nil }
        let column = geometry.columns[index]
        return NiriProjectedViewportAnchor(
            columnId: column.projectedColumn.column.id,
            projectedIndex: index,
            primaryPosition: column.primaryPosition
        )
    }

    func projectedSecondaryOffsets(
        for windows: [NiriWindow],
        effectiveTabbed: Bool,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }
        if effectiveTabbed {
            return Array(repeating: gaps, count: windows.count)
        }

        var offsets: [CGFloat] = []
        offsets.reserveCapacity(windows.count)
        var position = gaps
        for window in windows {
            offsets.append(position)
            let span = switch orientation {
            case .horizontal: window.resolvedHeight ?? window.frame?.height ?? 0
            case .vertical: window.resolvedWidth ?? window.frame?.width ?? 0
            }
            position += span + gaps
        }
        return offsets
    }

    func projectedTilesOrigin(
        displayMode: ColumnDisplay,
        visibleWindowCount: Int
    ) -> CGPoint {
        let xOffset = displayMode == .tabbed && visibleWindowCount > 1
            ? renderStyle.tabIndicatorWidth
            : 0
        return CGPoint(x: xOffset, y: 0)
    }
}
