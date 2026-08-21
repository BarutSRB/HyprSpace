// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class TabRailTests: XCTestCase {
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
        let layout = TabRailLayout(tabCount: 4, bounds: CGRect(x: 0, y: 0, width: 20, height: 80))

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
}
