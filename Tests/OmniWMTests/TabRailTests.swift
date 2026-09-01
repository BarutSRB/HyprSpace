// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class TabRailTests: XCTestCase {
    func testPartialMetadataStillProducesOneIndicatorPerTab() {
        let workspaceId = WorkspaceDescriptor.ID()
        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: .niriColumn(NodeId()),
            plannedSeq: 1,
            tileFrame: CGRect(x: 0, y: 0, width: 400, height: 500),
            tabCount: 2,
            activeVisualIndex: 1,
            activeWindowId: 42,
            tabs: [
                TabRailTabInfo(
                    visualIndex: 1,
                    token: nil,
                    windowId: 42,
                    appName: "Example",
                    title: "Document",
                    isActive: true
                )
            ]
        )

        XCTAssertEqual(info.tabCount, 2)
        XCTAssertEqual(info.normalizedTabs.map(\.visualIndex), [0, 1])
        XCTAssertEqual(info.normalizedTabs[1].title, "Document")
    }

    func testKeyIncludesLayoutOwnerAndWorkspace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let niriInfo = TabRailInfo(
            workspaceId: workspaceId,
            owner: .niriColumn(NodeId()),
            plannedSeq: 1,
            tileFrame: frame,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )
        let dwindleInfo = TabRailInfo(
            workspaceId: workspaceId,
            owner: .dwindleTile(UUID()),
            plannedSeq: 1,
            tileFrame: frame,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        XCTAssertNotEqual(niriInfo.key, dwindleInfo.key)
        XCTAssertEqual(niriInfo.key.workspaceId, workspaceId)
        XCTAssertEqual(dwindleInfo.key.workspaceId, workspaceId)
    }

    func testDefaultTabsClampActiveSelection() {
        let info = TabRailInfo(
            workspaceId: WorkspaceDescriptor.ID(),
            owner: .dwindleTile(UUID()),
            plannedSeq: 1,
            tileFrame: .zero,
            tabCount: 3,
            activeVisualIndex: 8,
            activeWindowId: nil
        )

        XCTAssertEqual(info.tabs.map(\.visualIndex), [0, 1, 2])
        XCTAssertEqual(info.tabs.map(\.isActive), [false, false, true])
    }

    func testLayoutMaintainsVisualOrderWithinAvailableHeight() {
        let layout = TabRailLayout(tabCount: 4, bounds: CGRect(x: 0, y: 0, width: 22, height: 80))

        XCTAssertEqual(layout.items.map(\.visualIndex), [0, 1, 2, 3])
        XCTAssertTrue(zip(layout.items, layout.items.dropFirst()).allSatisfy { pair in
            pair.0.hitRect.minY > pair.1.hitRect.minY
        })
        XCTAssertTrue(layout.items.allSatisfy { layout.railRect.contains($0.hitRect) })
    }

    @MainActor
    func testAnimationGeometryMovesExistingRailWithoutMetadataRedrawOrAccessibilityRefresh() throws {
        let manager = TabRailManager()
        defer { manager.removeAll() }
        let workspaceId = WorkspaceDescriptor.ID()
        let owner = TabRailOwner.dwindleTile(UUID())
        let tileFrame = CGRect(x: 100, y: 120, width: 420, height: 300)
        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 7,
            tileFrame: tileFrame,
            tabCount: 2,
            activeVisualIndex: 1,
            activeWindowId: nil,
            tabs: [
                TabRailTabInfo(
                    visualIndex: 0,
                    token: nil,
                    windowId: 41,
                    appName: "First",
                    title: "One",
                    isActive: false
                ),
                TabRailTabInfo(
                    visualIndex: 1,
                    token: nil,
                    windowId: 42,
                    appName: "Second",
                    title: "Two",
                    isActive: true
                )
            ]
        )
        manager.updateRails([info])
        let key = TabRailKey(workspaceId: workspaceId, owner: owner)

        let surfaceBefore = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first {
                $0.kind == .tabRail && $0.id.contains(workspaceId.uuidString)
            }
        )
        let windowBefore = try XCTUnwrap(manager.existingWindow(for: key))
        let frameBefore = try XCTUnwrap(surfaceBefore.frame)
        let view = try XCTUnwrap(windowBefore.contentView)
        let viewFrameBefore = view.frame
        let childrenBefore = try XCTUnwrap(view.accessibilityChildren())
        let childIdentifiersBefore = childrenBefore.map { ObjectIdentifier($0 as AnyObject) }
        let accessibilityFrameBefore = (childrenBefore.first as? NSAccessibilityElement)?.accessibilityFrame()

        let movedTileFrame = tileFrame.offsetBy(dx: 53, dy: 27)
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: movedTileFrame,
                visibleTileFrame: movedTileFrame
            )
        ])

        let surfaceAfterTick = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceBefore.id }
        )
        let windowAfterTick = try XCTUnwrap(manager.existingWindow(for: key))
        let frameAfterTick = try XCTUnwrap(surfaceAfterTick.frame)
        let childrenAfterTick = try XCTUnwrap(windowAfterTick.contentView?.accessibilityChildren())
        XCTAssertTrue(windowAfterTick === windowBefore)
        XCTAssertEqual(windowAfterTick.windowNumber, windowBefore.windowNumber)
        XCTAssertEqual(frameAfterTick.origin.x, frameBefore.origin.x + 53)
        XCTAssertEqual(frameAfterTick.origin.y, frameBefore.origin.y + 27)
        XCTAssertEqual(frameAfterTick.size, frameBefore.size)
        XCTAssertEqual(view.frame, viewFrameBefore)
        XCTAssertEqual(childrenAfterTick.map { ObjectIdentifier($0 as AnyObject) }, childIdentifiersBefore)
        XCTAssertEqual(
            (childrenAfterTick.first as? NSAccessibilityElement)?.accessibilityFrame(),
            accessibilityFrameBefore
        )

        let settledInfo = TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 8,
            tileFrame: movedTileFrame,
            tabCount: info.tabCount,
            activeVisualIndex: info.activeVisualIndex,
            activeWindowId: info.activeWindowId,
            tabs: info.tabs
        )
        manager.updateRails([settledInfo])
        let childrenAfterFullReconcile = try XCTUnwrap(windowBefore.contentView?.accessibilityChildren())
        XCTAssertNotEqual(
            (childrenAfterFullReconcile.first as? NSAccessibilityElement)?.accessibilityFrame(),
            accessibilityFrameBefore
        )
    }

    @MainActor
    func testAnimationGeometryHidesAndReusesRailWhenItReturnsOnscreen() throws {
        let manager = TabRailManager()
        defer { manager.removeAll() }
        let workspaceId = WorkspaceDescriptor.ID()
        let foreignWorkspaceId = WorkspaceDescriptor.ID()
        let owner = TabRailOwner.dwindleTile(UUID())
        let key = TabRailKey(workspaceId: workspaceId, owner: owner)
        let foreignKey = TabRailKey(workspaceId: foreignWorkspaceId, owner: owner)
        let tileFrame = CGRect(x: 100, y: 120, width: 420, height: 300)
        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 7,
            tileFrame: tileFrame,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil,
            tabs: [
                TabRailTabInfo(
                    visualIndex: 0,
                    token: nil,
                    windowId: 41,
                    appName: "First",
                    title: "One",
                    isActive: true
                ),
                TabRailTabInfo(
                    visualIndex: 1,
                    token: nil,
                    windowId: 42,
                    appName: "Second",
                    title: "Two",
                    isActive: false
                )
            ]
        )
        let foreignInfo = TabRailInfo(
            workspaceId: foreignWorkspaceId,
            owner: owner,
            plannedSeq: info.plannedSeq,
            tileFrame: tileFrame.offsetBy(dx: 500, dy: 0),
            tabCount: info.tabCount,
            activeVisualIndex: info.activeVisualIndex,
            activeWindowId: info.activeWindowId,
            tabs: info.tabs
        )
        manager.updateRails([info, foreignInfo])

        let surfaceBefore = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first {
                $0.kind == .tabRail && $0.id.contains(workspaceId.uuidString)
            }
        )
        let windowBefore = try XCTUnwrap(manager.existingWindow(for: key))
        let foreignWindow = try XCTUnwrap(manager.existingWindow(for: foreignKey))
        let windowNumber = windowBefore.windowNumber
        let foreignWindowNumber = foreignWindow.windowNumber

        manager.applyAnimationGeometry(
            [
                TabRailGeometryCommand(
                    key: foreignKey,
                    tileFrame: tileFrame,
                    visibleTileFrame: .null
                )
            ],
            in: workspaceId
        )

        XCTAssertTrue(windowBefore.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))
        XCTAssertTrue(foreignWindow.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: foreignWindowNumber))

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: tileFrame,
                visibleTileFrame: CGRect(x: tileFrame.minX, y: tileFrame.minY, width: 1, height: tileFrame.height)
            )
        ])

        XCTAssertFalse(windowBefore.isVisible)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: tileFrame, visibleTileFrame: tileFrame)
        ])

        XCTAssertTrue(windowBefore.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: tileFrame,
                visibleTileFrame: CGRect(x: tileFrame.minX, y: tileFrame.minY, width: tileFrame.width, height: 1)
            )
        ])

        XCTAssertFalse(windowBefore.isVisible)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: tileFrame, visibleTileFrame: tileFrame)
        ])

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: tileFrame, visibleTileFrame: .null)
        ])

        XCTAssertFalse(windowBefore.isVisible)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))

        let returnedFrame = tileFrame.offsetBy(dx: 70, dy: 45)
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: returnedFrame, visibleTileFrame: returnedFrame)
        ])

        let surfaceAfter = try XCTUnwrap(
            SurfaceCoordinator.shared.visibleSurfaceInfos().first { $0.id == surfaceBefore.id }
        )
        XCTAssertTrue(manager.existingWindow(for: key) === windowBefore)
        XCTAssertEqual(manager.existingWindow(for: key)?.windowNumber, windowNumber)
        XCTAssertNotNil(surfaceAfter.frame)
        XCTAssertTrue(windowBefore.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))
    }

    @MainActor
    func testAnimationGeometryCreatesCachedOffscreenRailWhenItEntersViewport() throws {
        let manager = TabRailManager()
        defer { manager.removeAll() }
        let workspaceId = WorkspaceDescriptor.ID()
        let owner = TabRailOwner.niriColumn(NodeId())
        let key = TabRailKey(workspaceId: workspaceId, owner: owner)
        let tileFrame = CGRect(x: -500, y: 100, width: 400, height: 300)
        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 9,
            tileFrame: tileFrame,
            visibleTileFrame: .null,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: nil
        )

        manager.updateRails([info])
        XCTAssertNil(manager.existingWindow(for: key))

        let enteredFrame = CGRect(x: 100, y: 120, width: 400, height: 300)
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: enteredFrame,
                visibleTileFrame: enteredFrame
            )
        ])

        let window = try XCTUnwrap(manager.existingWindow(for: key))
        let windowNumber = window.windowNumber
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))

        manager.applyAnimationGeometry([
            TabRailGeometryCommand(key: key, tileFrame: enteredFrame, visibleTileFrame: .null)
        ])
        manager.applyAnimationGeometry([
            TabRailGeometryCommand(
                key: key,
                tileFrame: enteredFrame.offsetBy(dx: 40, dy: 0),
                visibleTileFrame: enteredFrame.offsetBy(dx: 40, dy: 0)
            )
        ])

        XCTAssertTrue(manager.existingWindow(for: key) === window)
        XCTAssertEqual(manager.existingWindow(for: key)?.windowNumber, windowNumber)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: windowNumber))
    }

    func testIndicatorsAreCenteredInVisualBarWithoutShrinkingHitTargets() {
        let layout = TabRailLayout(tabCount: 4, bounds: CGRect(x: 7, y: 0, width: 22, height: 80))

        XCTAssertEqual(layout.items.count, 4)
        XCTAssertEqual(layout.barRect.minX, 19)
        XCTAssertEqual(layout.barRect.width, 10)
        XCTAssertEqual(layout.items.map(\.pillRect.midX), [24, 24, 24, 24])
        XCTAssertTrue(layout.items.allSatisfy { $0.hitRect.width > $0.pillRect.width })
    }

    func testSegmentsStayPixelAlignedAndCenteredAtEachBackingScale() throws {
        let trackBounds = CGRect(x: 0, y: 0, width: 10, height: 60)
        let sourceRect = CGRect(x: 0, y: 4, width: 10, height: 24)

        for scale: CGFloat in [1, 2] {
            let rect = TabRailSegmentGeometry.rect(
                sourceRect: sourceRect,
                trackBounds: trackBounds,
                width: 3,
                selected: true,
                scale: scale
            )
            let centeredRect = try XCTUnwrap(
                TabRailSegmentGeometry.equallyPaddedRects(
                    sourceRects: [0: sourceRect],
                    trackBounds: trackBounds,
                    width: 3,
                    selectedVisualIndex: 0,
                    verticalMargin: 2,
                    scale: scale
                )[0]
            )

            for segmentRect in [rect, centeredRect] {
                XCTAssertEqual(segmentRect.width, scale == 1 ? 4 : 3)
                XCTAssertEqual(segmentRect.midX, trackBounds.midX)
                XCTAssertEqual(segmentRect.minX * scale, (segmentRect.minX * scale).rounded())
                XCTAssertEqual(segmentRect.maxX * scale, (segmentRect.maxX * scale).rounded())
            }
        }
    }

    func testInactiveSegmentUsesSixtySevenPercentHeightAndStaysCentered() {
        let sourceRect = CGRect(x: 0, y: 4, width: 8, height: 24)
        let trackBounds = CGRect(x: 0, y: 0, width: 8, height: 58)
        let active = TabRailSegmentGeometry.rect(
            sourceRect: sourceRect,
            trackBounds: trackBounds,
            width: 3,
            selected: true,
            scale: 2
        )
        let inactive = TabRailSegmentGeometry.rect(
            sourceRect: sourceRect,
            trackBounds: trackBounds,
            width: 3,
            selected: false,
            scale: 2
        )

        XCTAssertEqual(active.width, inactive.width)
        XCTAssertEqual(active.height, 24)
        XCTAssertEqual(inactive.height, 16)
        XCTAssertEqual(active.midY, inactive.midY)
    }

    func testActiveAndInactiveSegmentsKeepCompactSpacingAndEqualEndCaps() throws {
        let sourceRects = [
            0: CGRect(x: 0, y: 34, width: 8, height: 24),
            1: CGRect(x: 0, y: 2, width: 8, height: 24)
        ]
        let trackHeight = TabRailSegmentGeometry.packedHeight(
            sourceRects: sourceRects,
            selectedVisualIndex: 0,
            verticalMargin: 2,
            endInset: 6,
            scale: 2
        )
        let trackBounds = CGRect(x: 0, y: 0, width: 8, height: trackHeight)
        let rects = TabRailSegmentGeometry.equallyPaddedRects(
            sourceRects: sourceRects,
            trackBounds: trackBounds,
            width: 3,
            selectedVisualIndex: 0,
            verticalMargin: 2,
            scale: 2
        )

        let active = try XCTUnwrap(rects[0])
        let inactive = try XCTUnwrap(rects[1])
        XCTAssertEqual(trackHeight, 60)
        XCTAssertEqual(active.height, 24)
        XCTAssertEqual(inactive.height, 16)
        XCTAssertEqual(trackBounds.maxY - active.maxY, 6)
        XCTAssertEqual(inactive.minY - trackBounds.minY, 6)
        XCTAssertEqual(active.minY - inactive.maxY, 8)
    }

    func testInactiveEndCapsDoNotGrowWithTabCount() throws {
        func endCaps(tabCount: Int, selectedVisualIndex: Int) throws -> (bottom: CGFloat, top: CGFloat) {
            let slotHeight: CGFloat = 28
            let slotGap: CGFloat = 4
            let sourceRects = Dictionary(uniqueKeysWithValues: (0 ..< tabCount).map { visualIndex in
                (
                    visualIndex,
                    CGRect(
                        x: 0,
                        y: CGFloat(visualIndex) * (slotHeight + slotGap) + 2,
                        width: 8,
                        height: slotHeight - 4
                    )
                )
            })
            let trackHeight = TabRailSegmentGeometry.packedHeight(
                sourceRects: sourceRects,
                selectedVisualIndex: selectedVisualIndex,
                verticalMargin: 2,
                endInset: 6,
                scale: 2
            )
            let trackBounds = CGRect(x: 0, y: 0, width: 8, height: trackHeight)
            let rects = TabRailSegmentGeometry.equallyPaddedRects(
                sourceRects: sourceRects,
                trackBounds: trackBounds,
                width: 3,
                selectedVisualIndex: selectedVisualIndex,
                verticalMargin: 2,
                scale: 2
            )
            let bottom = try XCTUnwrap(rects[0])
            let top = try XCTUnwrap(rects[tabCount - 1])
            return (bottom.minY - trackBounds.minY, trackBounds.maxY - top.maxY)
        }

        let threeTabs = try endCaps(tabCount: 3, selectedVisualIndex: 1)
        let sixTabs = try endCaps(tabCount: 6, selectedVisualIndex: 2)
        let threeTabsFirstSelected = try endCaps(tabCount: 3, selectedVisualIndex: 0)
        let sixTabsFirstSelected = try endCaps(tabCount: 6, selectedVisualIndex: 0)

        XCTAssertEqual(threeTabs.bottom, 6)
        XCTAssertEqual(threeTabs.top, 6)
        XCTAssertEqual(sixTabs.bottom, threeTabs.bottom)
        XCTAssertEqual(sixTabs.top, threeTabs.top)
        XCTAssertEqual(threeTabsFirstSelected.bottom, 6)
        XCTAssertEqual(threeTabsFirstSelected.top, 6)
        XCTAssertEqual(sixTabsFirstSelected.bottom, threeTabsFirstSelected.bottom)
        XCTAssertEqual(sixTabsFirstSelected.top, threeTabsFirstSelected.top)
    }

    func testHoverCardPrefersLeftAndAlignsWithHoveredTab() {
        let frame = TabRailHoverCardPlacement.frame(
            railFrame: CGRect(x: 500, y: 200, width: 22, height: 100),
            itemRect: CGRect(x: 0, y: 60, width: 22, height: 28),
            cardSize: CGSize(width: 260, height: 52),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            gap: 8
        )

        XCTAssertEqual(frame.minX, 232)
        XCTAssertEqual(frame.midY, 274)
    }

    func testHoverCardFlipsRightAndClampsToVisibleFrame() {
        let frame = TabRailHoverCardPlacement.frame(
            railFrame: CGRect(x: 4, y: 2, width: 22, height: 80),
            itemRect: CGRect(x: 0, y: 0, width: 22, height: 20),
            cardSize: CGSize(width: 260, height: 52),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            gap: 8
        )

        XCTAssertEqual(frame.minX, 34)
        XCTAssertEqual(frame.minY, 0)
    }
}
