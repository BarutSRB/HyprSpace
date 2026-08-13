// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleExcludedProjectionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testSyncRetainsExcludedMembershipWhileOmittingItsFrame() {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let visible = WindowToken(pid: 1, windowId: 1)
        let excluded = WindowToken(pid: 2, windowId: 2)
        engine.setExcludedTokens([excluded], in: workspaceId)

        XCTAssertTrue(
            engine.syncWindows(
                [visible, excluded],
                in: workspaceId,
                focusedToken: visible
            ).isEmpty
        )

        let frames = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertTrue(engine.containsWindow(excluded, in: workspaceId))
        XCTAssertEqual(engine.windowCount(in: workspaceId), 2)
        XCTAssertEqual(Set(frames.keys), [visible])
        XCTAssertEqual(frames[visible], screen)
    }

    func testExcludedLeafCollapsesWithoutMutatingDurableTopology() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let third = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: third, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let rootId = root.id
        let rootOrientation = root.splitOrientation
        let rootRatio = root.splitRatio
        let secondNodeId = try XCTUnwrap(engine.findNode(for: second, in: workspaceId)?.id)
        let thirdNodeId = try XCTUnwrap(engine.findNode(for: third, in: workspaceId)?.id)

        engine.setExcludedTokens([first, second], in: workspaceId)
        let frames = engine.calculateLayout(for: workspaceId, screen: screen)

        XCTAssertEqual(Set(frames.keys), [third])
        XCTAssertEqual(frames[third], screen)
        XCTAssertEqual(engine.windowCount(in: workspaceId), 3)
        XCTAssertEqual(engine.tileCount(in: workspaceId), 3)
        XCTAssertEqual(engine.root(for: workspaceId)?.id, rootId)
        XCTAssertEqual(engine.root(for: workspaceId)?.splitOrientation, rootOrientation)
        XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, rootRatio)
        XCTAssertEqual(engine.findNode(for: second, in: workspaceId)?.id, secondNodeId)
        XCTAssertEqual(engine.findNode(for: third, in: workspaceId)?.id, thirdNodeId)

        engine.setExcludedTokens([], in: workspaceId)
        XCTAssertEqual(
            Set(engine.calculateLayout(for: workspaceId, screen: screen).keys),
            [first, second, third]
        )
        XCTAssertEqual(engine.root(for: workspaceId)?.id, rootId)
        XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, rootRatio)
    }

    func testExcludedActiveGroupMemberUsesVisibleMemberWithoutChangingSelection() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspaceId))
        let durableBefore = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspaceId))

        engine.setExcludedTokens([second], in: workspaceId)
        let frames = engine.calculateLayout(for: workspaceId, screen: screen)
        let durableAfter = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspaceId))

        XCTAssertEqual(Set(frames.keys), [first])
        XCTAssertEqual(frames[first], screen)
        XCTAssertTrue(engine.groupedTileSnapshots(in: workspaceId).isEmpty)
        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), first)
        XCTAssertEqual(durableAfter.id, durableBefore.id)
        XCTAssertEqual(durableAfter.members, durableBefore.members)
        XCTAssertEqual(durableAfter.activeIndex, durableBefore.activeIndex)
        XCTAssertEqual(engine.activeToken(in: workspaceId), second)

        engine.setExcludedTokens([], in: workspaceId)
        XCTAssertEqual(
            Set(engine.calculateLayout(for: workspaceId, screen: screen).keys),
            [second]
        )
        XCTAssertEqual(engine.activeToken(in: workspaceId), second)
    }

    func testSnapshotExclusionsRetainRemovedHiddenTokenUntilSync() {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let visible = WindowToken(pid: 1, windowId: 1)
        let removedHidden = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: visible, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: removedHidden, to: workspaceId, activeWindowFrame: nil)
        engine.setExcludedTokens(
            [removedHidden],
            authoritativeTokens: [visible, removedHidden],
            in: workspaceId
        )

        engine.setExcludedTokens([], authoritativeTokens: [visible], in: workspaceId)

        XCTAssertEqual(engine.excludedTokens(in: workspaceId), [removedHidden])
        XCTAssertEqual(
            Set(engine.calculateLayout(for: workspaceId, screen: screen).keys),
            [visible]
        )

        XCTAssertEqual(
            engine.syncWindows([visible], in: workspaceId, focusedToken: visible),
            [removedHidden]
        )
        XCTAssertTrue(engine.excludedTokens(in: workspaceId).isEmpty)
    }

    func testHiddenMinimumConstraintDoesNotBlockVisibleResize() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let hidden = WindowToken(pid: 2, windowId: 2)
        let second = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: hidden, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        engine.updateWindowConstraints(
            for: hidden,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 900, height: 1),
                maxSize: .zero,
                isFixed: false
            )
        )
        engine.setExcludedTokens([hidden], in: workspaceId)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.setSelectedNode(engine.findNode(for: second, in: workspaceId), in: workspaceId)
        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let before = try XCTUnwrap(root.splitRatio)

        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: workspaceId))
        XCTAssertNotEqual(root.splitRatio, before)
    }

    func testBalanceLeavesHiddenOnlySplitRatioUntouched() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let hidden = WindowToken(pid: 2, windowId: 2)
        let second = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: hidden, to: workspaceId, activeWindowFrame: nil)
        let hiddenSplit = try XCTUnwrap(engine.findNode(for: hidden, in: workspaceId)?.parent)
        hiddenSplit.kind = .split(orientation: .horizontal, ratio: 1.4)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        engine.setExcludedTokens([first, hidden], in: workspaceId)

        _ = engine.balanceSizes(in: workspaceId)

        XCTAssertEqual(hiddenSplit.splitRatio, 1.4)
    }

    func testInteractiveResizeSkipsCollapsedHiddenSplit() throws {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let hidden = WindowToken(pid: 2, windowId: 2)
        let selected = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: hidden, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: selected, to: workspaceId, activeWindowFrame: nil)
        engine.setExcludedTokens([hidden], in: workspaceId)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let collapsedSplit = try XCTUnwrap(engine.findNode(for: selected, in: workspaceId)?.parent)
        let rootRatio = try XCTUnwrap(root.splitRatio)
        let collapsedRatio = try XCTUnwrap(collapsedSplit.splitRatio)
        let start = CGPoint(x: 500, y: 400)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                token: selected,
                edges: [.left],
                startLocation: start,
                in: workspaceId,
                innerGap: engine.settings.innerGap
            )
        )
        XCTAssertTrue(engine.interactiveResizeUpdate(currentLocation: CGPoint(x: 450, y: 400)))
        XCTAssertNotEqual(root.splitRatio, rootRatio)
        XCTAssertEqual(collapsedSplit.splitRatio, collapsedRatio)
    }

    func testNavigationSkipsExcludedLeafUsingCollapsedGeometry() {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let left = WindowToken(pid: 1, windowId: 1)
        let middle = WindowToken(pid: 2, windowId: 2)
        let right = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: left, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertTrue(engine.setPreselection(.right, in: workspaceId))
        _ = engine.addWindow(token: middle, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertTrue(engine.setPreselection(.right, in: workspaceId))
        _ = engine.addWindow(token: right, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        XCTAssertEqual(engine.activateWindowOutcome(left, in: workspaceId), .selected)

        engine.setExcludedTokens([middle], in: workspaceId)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        XCTAssertEqual(
            engine.findGeometricNeighbor(from: left, direction: .right, in: workspaceId),
            right
        )
        XCTAssertEqual(engine.moveFocus(direction: .right, in: workspaceId), right)
        XCTAssertEqual(engine.projectedActiveToken(in: workspaceId), right)
    }

    @MainActor
    func testLayoutDiffProducesNoEffectsForExcludedTokens() {
        let handler = DwindleLayoutHandler(controller: nil)
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let visible = WindowToken(pid: 1, windowId: 1)
        let excluded = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: visible, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: excluded, to: workspaceId, activeWindowFrame: nil)
        engine.setExcludedTokens([excluded], in: workspaceId)
        let frames = engine.calculateLayout(for: workspaceId, screen: screen)
        let windows = [visible, excluded].map {
            LayoutWindowSnapshot(
                token: $0,
                constraints: .unconstrained,
                hiddenState: HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .layoutTransient(.left)
                ),
                layoutReason: .standard
            )
        }

        let diff = handler.layoutDiff(
            windows: windows,
            frames: frames,
            engine: engine,
            workspaceId: workspaceId,
            preferredHideSide: .left,
            canRestoreHiddenWorkspaceWindows: true,
            scale: 1,
            reassertHidden: true,
            pendingParkWindowIds: [excluded.windowId]
        )

        XCTAssertFalse(diff.frameChanges.contains { $0.token == excluded })
        XCTAssertFalse(diff.restoreChanges.contains { $0.token == excluded })
        XCTAssertFalse(diff.deferredHides.contains { $0.token == excluded })
        XCTAssertFalse(diff.visibilityChanges.contains { change in
            switch change {
            case let .show(token),
                 let .hide(token, _):
                token == excluded
            }
        })
    }
}
