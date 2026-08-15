// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

typealias OverviewWorkspaceLayoutItem = (
    id: WorkspaceDescriptor.ID,
    name: String,
    isActive: Bool
)

typealias OverviewWindowLayoutData = (
    token: WindowToken,
    workspaceId: WorkspaceDescriptor.ID,
    title: String,
    appName: String,
    appIcon: NSImage?,
    frame: CGRect
)

enum OverviewLayoutMetrics {
    static let searchBarHeight: CGFloat = 44
    static let searchBarPadding: CGFloat = 20
    static let workspaceLabelHeight: CGFloat = 32
    static let workspaceSectionPadding: CGFloat = 16
    static let windowSpacing: CGFloat = 16
    static let windowPadding: CGFloat = 24
    static let minThumbnailWidth: CGFloat = 200
    static let maxThumbnailWidth: CGFloat = 400
    static let thumbnailAspectRatio: CGFloat = 16.0 / 10.0
    static let closeButtonSize: CGFloat = 20
    static let closeButtonPadding: CGFloat = 6
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 40
}

@MainActor
struct OverviewLayoutCalculator {
    private static let navigationGeometryEpsilon: CGFloat = 0.5

    struct BuildContext {
        let screenFrame: CGRect
        let metricsScale: CGFloat
        let availableWidth: CGFloat
        let searchBarFrame: CGRect
        let scaledWindowPadding: CGFloat
        let scaledWorkspaceLabelHeight: CGFloat
        let scaledWorkspaceSectionPadding: CGFloat
        let scaledWindowSpacing: CGFloat
        let thumbnailWidth: CGFloat
        let initialContentY: CGFloat
        let contentTopPadding: CGFloat
        let contentBottomPadding: CGFloat
    }

    struct NiriWorkspaceProjection {
        let section: OverviewWorkspaceSection
        let columns: [OverviewNiriColumn]
        let columnDropZones: [OverviewColumnDropZone]
    }

    private struct HorizontalCandidate {
        let handle: WindowHandle
        let midX: CGFloat
        let midY: CGFloat
        let horizontalDistance: CGFloat
        let verticalDistance: CGFloat
        let verticalOverlap: CGFloat
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        max(0.5, min(1.5, scale))
    }

    static func viewportFrame(for monitorFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: monitorFrame.size)
    }

    static func localizedFrame(_ frame: CGRect, to monitorFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -monitorFrame.minX, dy: -monitorFrame.minY)
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        calculateLayout(
            workspaces: workspaces,
            windows: windows,
            niriSnapshotsByWorkspace: [:],
            screenFrame: screenFrame,
            searchQuery: searchQuery,
            scale: scale
        )
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        let context = buildContext(screenFrame: screenFrame, scale: scale)
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = context.searchBarFrame

        var windowsByWorkspace: [WorkspaceDescriptor.ID: [(WindowHandle, OverviewWindowLayoutData)]] = [:]
        windowsByWorkspace.reserveCapacity(workspaces.count)

        var windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)] = [:]
        windowsByToken.reserveCapacity(windows.count)

        for (handle, windowData) in windows {
            windowsByWorkspace[windowData.workspaceId, default: []].append((handle, windowData))
            windowsByToken[windowData.token] = (handle, windowData)
        }

        var sections: [OverviewWorkspaceSection] = []
        sections.reserveCapacity(workspaces.count)

        var niriColumnsByWorkspace: [WorkspaceDescriptor.ID: [OverviewNiriColumn]] = [:]
        var niriColumnDropZonesByWorkspace: [WorkspaceDescriptor.ID: [OverviewColumnDropZone]] = [:]
        var currentY = context.initialContentY

        for workspace in workspaces {
            guard let workspaceWindows = windowsByWorkspace[workspace.id], !workspaceWindows.isEmpty else {
                continue
            }

            if let snapshot = niriSnapshotsByWorkspace[workspace.id],
               let projection = buildNiriWorkspaceProjection(
                   workspace: workspace,
                   snapshot: snapshot,
                   windowsByToken: windowsByToken,
                   searchQuery: searchQuery,
                   currentY: &currentY,
                   context: context
               )
            {
                sections.append(projection.section)
                if !projection.columns.isEmpty {
                    niriColumnsByWorkspace[workspace.id] = projection.columns
                }
                if !projection.columnDropZones.isEmpty {
                    niriColumnDropZonesByWorkspace[workspace.id] = projection.columnDropZones
                }
                continue
            }

            if let section = buildGenericWorkspaceSection(
                workspace: workspace,
                windows: workspaceWindows,
                searchQuery: searchQuery,
                currentY: &currentY,
                context: context
            ) {
                sections.append(section)
            }
        }

        layout.workspaceSections = sections
        layout.niriColumnsByWorkspace = niriColumnsByWorkspace
        layout.niriColumnDropZonesByWorkspace = niriColumnDropZonesByWorkspace
        layout.totalContentHeight = totalContentHeight(currentY: currentY, context: context)
        return layout
    }

    private static func buildContext(screenFrame: CGRect, scale: CGFloat) -> BuildContext {
        let metricsScale = clampedScale(scale)
        let scaledSearchBarHeight = OverviewLayoutMetrics.searchBarHeight * metricsScale
        let scaledSearchBarPadding = OverviewLayoutMetrics.searchBarPadding * metricsScale
        let searchBarY = screenFrame.maxY - scaledSearchBarHeight - scaledSearchBarPadding
        let searchBarFrame = CGRect(
            x: screenFrame.minX + screenFrame.width * 0.25,
            y: searchBarY,
            width: screenFrame.width * 0.5,
            height: scaledSearchBarHeight
        )

        let scaledWindowPadding = OverviewLayoutMetrics.windowPadding * metricsScale
        let availableWidth = screenFrame.width - (scaledWindowPadding * 2)
        let thumbnailWidth = min(
            OverviewLayoutMetrics.maxThumbnailWidth * metricsScale,
            max(OverviewLayoutMetrics.minThumbnailWidth * metricsScale, availableWidth / 4)
        )

        return BuildContext(
            screenFrame: screenFrame,
            metricsScale: metricsScale,
            availableWidth: availableWidth,
            searchBarFrame: searchBarFrame,
            scaledWindowPadding: scaledWindowPadding,
            scaledWorkspaceLabelHeight: OverviewLayoutMetrics.workspaceLabelHeight * metricsScale,
            scaledWorkspaceSectionPadding: OverviewLayoutMetrics.workspaceSectionPadding * metricsScale,
            scaledWindowSpacing: OverviewLayoutMetrics.windowSpacing * metricsScale,
            thumbnailWidth: thumbnailWidth,
            initialContentY: searchBarY - OverviewLayoutMetrics.contentTopPadding * metricsScale,
            contentTopPadding: OverviewLayoutMetrics.contentTopPadding * metricsScale,
            contentBottomPadding: OverviewLayoutMetrics.contentBottomPadding * metricsScale
        )
    }

    private static func buildGenericWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [(WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat,
        context: BuildContext
    ) -> OverviewWorkspaceSection? {
        guard !windows.isEmpty else { return nil }

        let orderedWindows = windows.sorted { lhs, rhs in
            compareWindowsForPreview(lhs.1, rhs.1)
        }

        currentY -= context.scaledWorkspaceLabelHeight

        let labelFrame = CGRect(
            x: context.screenFrame.minX + context.scaledWindowPadding,
            y: currentY,
            width: context.availableWidth,
            height: context.scaledWorkspaceLabelHeight
        )

        currentY -= context.scaledWorkspaceSectionPadding

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(orderedWindows.count)

        let normalizedFrames = orderedWindows.map { normalizedSourceFrame($0.1.frame) }
        let sourceBounds = boundingRect(for: normalizedFrames)
        let previewScale = workspacePreviewScale(for: sourceBounds.size, context: context)
        let projectedSize = CGSize(
            width: sourceBounds.width * previewScale,
            height: sourceBounds.height * previewScale
        )
        let previewOrigin = CGPoint(
            x: context.screenFrame.minX + (context.screenFrame.width - projectedSize.width) / 2,
            y: currentY - projectedSize.height
        )

        for ((handle, windowData), sourceFrame) in zip(orderedWindows, normalizedFrames) {
            let overviewFrame = projectFrame(
                sourceFrame,
                from: sourceBounds,
                previewOrigin: previewOrigin,
                scale: previewScale
            )

            windowItems.append(
                makeWindowItem(
                    handle: handle,
                    workspaceId: workspace.id,
                    windowData: windowData,
                    overviewFrame: overviewFrame,
                    searchQuery: searchQuery
                )
            )
        }

        let gridFrame = CGRect(
            origin: previewOrigin,
            size: projectedSize
        )

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            currentY: currentY,
            context: context
        )

        currentY = section.sectionFrame.minY - context.scaledWorkspaceSectionPadding
        return section
    }

    private static func buildNiriWorkspaceProjection(
        workspace: OverviewWorkspaceLayoutItem,
        snapshot: NiriOverviewWorkspaceSnapshot,
        windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat,
        context: BuildContext
    ) -> NiriWorkspaceProjection? {
        guard !snapshot.columns.isEmpty else { return nil }

        currentY -= context.scaledWorkspaceLabelHeight

        let labelFrame = CGRect(
            x: context.screenFrame.minX + context.scaledWindowPadding,
            y: currentY,
            width: context.availableWidth,
            height: context.scaledWorkspaceLabelHeight
        )

        currentY -= context.scaledWorkspaceSectionPadding

        let columnCount = snapshot.columns.count
        let totalWeight = snapshot.columns.reduce(CGFloat(0)) { partial, column in
            partial + max(column.widthWeight, 0.001)
        }
        let rawColumnWidths = snapshot.columns.map { column in
            preferredNiriColumnWidth(
                for: column,
                totalWeight: totalWeight,
                columnCount: columnCount,
                context: context
            )
        }
        let rawColumnHeights = snapshot.columns.map { column in
            preferredNiriColumnHeight(for: column, spacing: context.scaledWindowSpacing)
        }
        let rawTotalWidth = rawColumnWidths.reduce(CGFloat(0), +) +
            context.scaledWindowSpacing * CGFloat(max(0, columnCount - 1))
        let rawMaxHeight = max(rawColumnHeights.max() ?? 1, 1)
        let workspaceScale = workspacePreviewScale(
            for: CGSize(width: rawTotalWidth, height: rawMaxHeight),
            context: context
        )
        let columnWidths = rawColumnWidths.map { $0 * workspaceScale }
        let columnHeights = rawColumnHeights.map { $0 * workspaceScale }
        let totalGridWidth = rawTotalWidth * workspaceScale
        let gridHeight = rawMaxHeight * workspaceScale
        let gridStartX = context.screenFrame.minX + (context.screenFrame.width - totalGridWidth) / 2
        let gridFrame = CGRect(
            x: gridStartX,
            y: currentY - gridHeight,
            width: totalGridWidth,
            height: gridHeight
        )

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(snapshot.columns.reduce(0) { $0 + $1.tiles.count })

        var projectedColumns: [OverviewNiriColumn] = []
        projectedColumns.reserveCapacity(snapshot.columns.count)

        var currentX = gridStartX
        for (columnIndex, columnSnapshot) in snapshot.columns.enumerated() {
            let columnWidth = columnWidths.indices.contains(columnIndex) ? columnWidths[columnIndex] : 0
            let columnHeight = columnHeights.indices.contains(columnIndex) ? columnHeights[columnIndex] : gridHeight
            let columnFrame = CGRect(
                x: currentX,
                y: gridFrame.minY,
                width: columnWidth,
                height: columnHeight
            )

            let mappedWindows = columnSnapshot.tiles.compactMap { windowsByToken[$0.token] }
            let projectedTileHeights = columnSnapshot.tiles.map { max($0.preferredHeight, 1) * workspaceScale }

            var handles: [WindowHandle] = []
            handles.reserveCapacity(mappedWindows.count)

            var nextTileY = columnFrame.maxY
            for (tileIndex, (handle, windowData)) in mappedWindows.enumerated() {
                let tileHeight = projectedTileHeights.indices.contains(tileIndex)
                    ? projectedTileHeights[tileIndex]
                    : max(windowData.frame.height * workspaceScale, 1)
                let tileY = nextTileY - tileHeight
                let tileFrame = CGRect(
                    x: columnFrame.minX,
                    y: tileY,
                    width: columnFrame.width,
                    height: tileHeight
                )

                windowItems.append(
                    makeWindowItem(
                        handle: handle,
                        workspaceId: workspace.id,
                        windowData: windowData,
                        overviewFrame: tileFrame,
                        searchQuery: searchQuery
                    )
                )
                handles.append(handle)
                nextTileY = tileY - context.scaledWindowSpacing
            }

            projectedColumns.append(
                OverviewNiriColumn(
                    workspaceId: workspace.id,
                    columnIndex: columnSnapshot.index,
                    frame: columnFrame,
                    windowHandles: handles
                )
            )

            currentX += columnWidth + context.scaledWindowSpacing
        }

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            currentY: currentY,
            context: context
        )

        currentY = section.sectionFrame.minY - context.scaledWorkspaceSectionPadding

        return NiriWorkspaceProjection(
            section: section,
            columns: projectedColumns,
            columnDropZones: buildNiriColumnDropZones(
                workspaceId: workspace.id,
                gridFrame: gridFrame,
                columns: projectedColumns,
                context: context
            )
        )
    }

    private static func preferredNiriColumnWidth(
        for column: NiriOverviewColumnSnapshot,
        totalWeight: CGFloat,
        columnCount: Int,
        context: BuildContext
    ) -> CGFloat {
        if let preferredWidth = column.preferredWidth, preferredWidth > 0 {
            return preferredWidth
        }

        let normalizedWeight = max(column.widthWeight, 0.001) / max(totalWeight, 0.001)
        return context.thumbnailWidth * CGFloat(columnCount) * normalizedWeight
    }

    private static func preferredNiriColumnHeight(
        for column: NiriOverviewColumnSnapshot,
        spacing: CGFloat
    ) -> CGFloat {
        guard !column.tiles.isEmpty else { return 1 }

        let preferredHeight = column.tiles.reduce(CGFloat(0)) { partial, tile in
            partial + max(tile.preferredHeight, 1)
        }
        return preferredHeight + spacing * CGFloat(max(0, column.tiles.count - 1))
    }

    private static func compareWindowsForPreview(
        _ lhs: OverviewWindowLayoutData,
        _ rhs: OverviewWindowLayoutData
    ) -> Bool {
        let lhsFrame = normalizedSourceFrame(lhs.frame)
        let rhsFrame = normalizedSourceFrame(rhs.frame)
        if abs(lhsFrame.maxY - rhsFrame.maxY) > 1 {
            return lhsFrame.maxY > rhsFrame.maxY
        }
        if abs(lhsFrame.minX - rhsFrame.minX) > 1 {
            return lhsFrame.minX < rhsFrame.minX
        }
        return lhs.title < rhs.title
    }

    private static func normalizedSourceFrame(_ frame: CGRect) -> CGRect {
        let standardized = frame.standardized
        return CGRect(
            x: standardized.minX,
            y: standardized.minY,
            width: max(standardized.width, 1),
            height: max(standardized.height, 1)
        )
    }

    private static func boundingRect(for frames: [CGRect]) -> CGRect {
        let bounds = frames.reduce(into: CGRect.null) { partial, frame in
            partial = partial.union(frame)
        }
        if bounds.isNull {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
    }

    private static func workspacePreviewScale(
        for sourceSize: CGSize,
        context: BuildContext
    ) -> CGFloat {
        let safeWidth = max(sourceSize.width, 1)
        let safeHeight = max(sourceSize.height, 1)
        let maxPreviewWidth = min(
            context.availableWidth,
            context.screenFrame.width * 0.72 * context.metricsScale
        )
        let maxPreviewHeight = max(
            context.thumbnailWidth / OverviewLayoutMetrics.thumbnailAspectRatio,
            context.screenFrame.height * 0.42 * context.metricsScale
        )
        return max(
            0.01,
            min(maxPreviewWidth / safeWidth, maxPreviewHeight / safeHeight)
        )
    }

    private static func projectFrame(
        _ sourceFrame: CGRect,
        from sourceBounds: CGRect,
        previewOrigin: CGPoint,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: previewOrigin.x + (sourceFrame.minX - sourceBounds.minX) * scale,
            y: previewOrigin.y + (sourceFrame.minY - sourceBounds.minY) * scale,
            width: sourceFrame.width * scale,
            height: sourceFrame.height * scale
        )
    }

    private static func buildNiriColumnDropZones(
        workspaceId: WorkspaceDescriptor.ID,
        gridFrame: CGRect,
        columns: [OverviewNiriColumn],
        context: BuildContext
    ) -> [OverviewColumnDropZone] {
        guard !columns.isEmpty else { return [] }

        let edgeZoneWidth = max(12 * context.metricsScale, min(30 * context.metricsScale, context.scaledWindowSpacing))
        var zones: [OverviewColumnDropZone] = []
        zones.reserveCapacity(columns.count + 1)

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: 0,
                frame: CGRect(
                    x: gridFrame.minX - edgeZoneWidth,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        if columns.count > 1 {
            for index in 0 ..< (columns.count - 1) {
                let left = columns[index].frame.maxX
                let right = columns[index + 1].frame.minX
                zones.append(
                    OverviewColumnDropZone(
                        workspaceId: workspaceId,
                        insertIndex: index + 1,
                        frame: CGRect(
                            x: left,
                            y: gridFrame.minY,
                            width: max(0, right - left),
                            height: gridFrame.height
                        )
                    )
                )
            }
        }

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: columns.count,
                frame: CGRect(
                    x: gridFrame.maxX,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        return zones
    }

    private static func makeWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [OverviewWindowItem],
        labelFrame: CGRect,
        gridFrame: CGRect,
        currentY: CGFloat,
        context: BuildContext
    ) -> OverviewWorkspaceSection {
        let sectionBottom = gridFrame.minY
        let sectionFrame = CGRect(
            x: context.screenFrame.minX,
            y: sectionBottom,
            width: context.screenFrame.width,
            height: currentY + context.scaledWorkspaceLabelHeight - sectionBottom
        )

        return OverviewWorkspaceSection(
            workspaceId: workspace.id,
            name: workspace.name,
            windows: windows,
            sectionFrame: sectionFrame,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            isActive: workspace.isActive
        )
    }

    private static func makeWindowItem(
        handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
        windowData: OverviewWindowLayoutData,
        overviewFrame: CGRect,
        searchQuery: String
    ) -> OverviewWindowItem {
        let matchesSearch = searchQuery.isEmpty ||
            windowData.title.localizedCaseInsensitiveContains(searchQuery) ||
            windowData.appName.localizedCaseInsensitiveContains(searchQuery)

        return OverviewWindowItem(
            handle: handle,
            windowId: windowData.token.windowId,
            workspaceId: workspaceId,
            thumbnail: nil,
            title: windowData.title,
            appName: windowData.appName,
            appIcon: windowData.appIcon,
            originalFrame: windowData.frame,
            overviewFrame: overviewFrame,
            isHovered: false,
            isSelected: false,
            matchesSearch: matchesSearch,
            closeButtonHovered: false
        )
    }

    private static func totalContentHeight(currentY: CGFloat, context: BuildContext) -> CGFloat {
        let contentTop = context.searchBarFrame.minY - context.contentTopPadding
        let contentBottom = currentY + context.scaledWorkspaceSectionPadding - context.contentBottomPadding
        return contentTop - contentBottom
    }

    static func updateSearchFilter(layout: inout OverviewLayout, searchQuery: String) {
        for sectionIndex in layout.workspaceSections.indices {
            for windowIndex in layout.workspaceSections[sectionIndex].windows.indices {
                let window = layout.workspaceSections[sectionIndex].windows[windowIndex]
                let matches = searchQuery.isEmpty ||
                    window.title.localizedCaseInsensitiveContains(searchQuery) ||
                    window.appName.localizedCaseInsensitiveContains(searchQuery)
                layout.workspaceSections[sectionIndex].windows[windowIndex].matchesSearch = matches
            }
        }
    }

    static func scrollOffsetBounds(layout: OverviewLayout, screenFrame: CGRect) -> ClosedRange<CGFloat> {
        let metricsScale = clampedScale(layout.scale)
        let contentTop = layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        let contentBottom = contentTop - layout.totalContentHeight
        let minOffset = min(0, contentBottom - screenFrame.minY)
        return minOffset ... 0
    }

    static func clampedScrollOffset(
        _ scrollOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        scrollOffset.clamped(to: scrollOffsetBounds(layout: layout, screenFrame: screenFrame))
    }

    static func visibleContentFrame(
        layout: OverviewLayout,
        screenFrame: CGRect,
        scrollOffset: CGFloat? = nil
    ) -> CGRect {
        let metricsScale = clampedScale(layout.scale)
        let contentTop = layout.searchBarFrame.minY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        let offset = scrollOffset ?? layout.scrollOffset
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY + offset,
            width: screenFrame.width,
            height: max(0, contentTop - screenFrame.minY)
        )
    }

    static func scrollOffsetRevealing(
        targetFrame: CGRect,
        currentOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        let currentOffset = clampedScrollOffset(
            currentOffset,
            layout: layout,
            screenFrame: screenFrame
        )
        let viewport = visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: currentOffset
        )
        guard viewport.height > 0 else { return currentOffset }

        let targetFrame = targetFrame.standardized
        let padding = min(
            OverviewLayoutMetrics.windowSpacing * clampedScale(layout.scale),
            max(0, (viewport.height - targetFrame.height) / 2)
        )
        let paddedViewport = viewport.insetBy(dx: 0, dy: padding)

        if targetFrame.minY >= paddedViewport.minY,
           targetFrame.maxY <= paddedViewport.maxY
        {
            return currentOffset
        }

        let nextOffset: CGFloat
        if targetFrame.height >= viewport.height {
            nextOffset = targetFrame.maxY - viewport.maxY + currentOffset
        } else {
            let alignTop = targetFrame.maxY - paddedViewport.maxY + currentOffset
            let alignBottom = targetFrame.minY - paddedViewport.minY + currentOffset
            nextOffset = abs(alignTop - currentOffset) <= abs(alignBottom - currentOffset)
                ? alignTop
                : alignBottom
        }

        return clampedScrollOffset(
            nextOffset,
            layout: layout,
            screenFrame: screenFrame
        )
    }

    static func findNextWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        direction: Direction
    ) -> WindowHandle? {
        let visibleWindows = layout.allWindows.filter(\.matchesSearch)
        guard !visibleWindows.isEmpty else { return nil }

        guard let currentHandle else {
            return visibleWindows.first?.handle
        }

        guard let currentIndex = visibleWindows.firstIndex(where: { $0.handle == currentHandle }) else {
            return visibleWindows.first?.handle
        }

        let currentWindow = visibleWindows[currentIndex]

        switch direction {
        case .left:
            return findHorizontalWindow(
                in: visibleWindows,
                from: currentWindow,
                movingLeft: true
            )

        case .right:
            return findHorizontalWindow(
                in: visibleWindows,
                from: currentWindow,
                movingLeft: false
            )

        case .up:
            let upWindows = visibleWindows.filter {
                $0.overviewFrame.midY > currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = lhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let rhsYDiff = rhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = upWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return upWindows.first?.handle

        case .down:
            let downWindows = visibleWindows.filter {
                $0.overviewFrame.midY < currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = currentWindow.overviewFrame.midY - lhs.overviewFrame.midY
                let rhsYDiff = currentWindow.overviewFrame.midY - rhs.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = downWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return downWindows.first?.handle
        }
    }

    static func findCycledWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        forward: Bool
    ) -> WindowHandle? {
        let visibleWindows = layout.allWindows.filter(\.matchesSearch)
        guard !visibleWindows.isEmpty else { return nil }
        guard let currentHandle,
              let currentIndex = visibleWindows.firstIndex(where: { $0.handle == currentHandle })
        else {
            return visibleWindows.first?.handle
        }

        return forward
            ? findWrappedNext(in: visibleWindows, from: currentIndex)
            : findWrappedPrevious(in: visibleWindows, from: currentIndex)
    }

    private static func findHorizontalWindow(
        in windows: [OverviewWindowItem],
        from currentWindow: OverviewWindowItem,
        movingLeft: Bool
    ) -> WindowHandle {
        let currentFrame = currentWindow.overviewFrame
        var directCandidate: HorizontalCandidate?
        var wrappedCandidate: HorizontalCandidate?

        for window in windows {
            guard window.workspaceId == currentWindow.workspaceId,
                  window.handle != currentWindow.handle
            else {
                continue
            }

            let frame = window.overviewFrame
            let horizontalDelta = frame.midX - currentFrame.midX
            let verticalOverlap = min(frame.maxY, currentFrame.maxY) - max(frame.minY, currentFrame.minY)
            guard abs(horizontalDelta) > navigationGeometryEpsilon,
                  verticalOverlap > navigationGeometryEpsilon
            else {
                continue
            }

            let candidate = HorizontalCandidate(
                handle: window.handle,
                midX: frame.midX,
                midY: frame.midY,
                horizontalDistance: abs(horizontalDelta),
                verticalDistance: abs(frame.midY - currentFrame.midY),
                verticalOverlap: verticalOverlap
            )
            let isDirect = movingLeft ? horizontalDelta < 0 : horizontalDelta > 0
            if isDirect,
               directCandidate.map({ isBetterAligned(candidate, than: $0) }) ?? true
            {
                directCandidate = candidate
            }
            if wrappedCandidate.map({
                isBetterWrapped(candidate, than: $0, movingLeft: movingLeft)
            }) ?? true {
                wrappedCandidate = candidate
            }
        }

        return directCandidate?.handle ?? wrappedCandidate?.handle ?? currentWindow.handle
    }

    private static func isBetterAligned(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate
    ) -> Bool {
        if candidate.horizontalDistance != current.horizontalDistance {
            return candidate.horizontalDistance < current.horizontalDistance
        }
        return isBetterVerticalMatch(candidate, than: current)
    }

    private static func isBetterWrapped(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate,
        movingLeft: Bool
    ) -> Bool {
        if candidate.midX != current.midX {
            return movingLeft ? candidate.midX > current.midX : candidate.midX < current.midX
        }
        return isBetterVerticalMatch(candidate, than: current)
    }

    private static func isBetterVerticalMatch(
        _ candidate: HorizontalCandidate,
        than current: HorizontalCandidate
    ) -> Bool {
        if candidate.verticalOverlap != current.verticalOverlap {
            return candidate.verticalOverlap > current.verticalOverlap
        }
        if candidate.verticalDistance != current.verticalDistance {
            return candidate.verticalDistance < current.verticalDistance
        }
        if candidate.midY != current.midY {
            return candidate.midY > current.midY
        }
        if candidate.handle.pid != current.handle.pid {
            return candidate.handle.pid < current.handle.pid
        }
        return candidate.handle.windowId < current.handle.windowId
    }

    private static func findWrappedNext(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let nextIndex = (index + 1) % windows.count
        return windows[nextIndex].handle
    }

    private static func findWrappedPrevious(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let prevIndex = (index - 1 + windows.count) % windows.count
        return windows[prevIndex].handle
    }
}
