// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DwindleGroupFocusIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let engine: DwindleLayoutEngine
        let inactiveToken: WindowToken
        let activeToken: WindowToken
    }

    func testDirectionalGroupFocusIsBoundedAndExplicitWrapCyclesLocally() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )

        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)

        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.wrapGroupFocus(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertTrue(frontedTokens.isEmpty)
    }

    func testDirectionalGroupFocusSkipsSuspendedMember() throws {
        let fixture = try makeFixture { _, _ in }
        let third = addGroupedMember(to: fixture)
        fixture.controller.workspaceManager.setLayoutReason(
            .nativeFullscreen,
            for: fixture.activeToken
        )
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), third)
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
    }

    func testGroupTabEdgeExitsSpatiallyAndSingletonVerticalFocusRemainsSpatial() throws {
        let fixture = try makeFixture { _, _ in }
        let neighbor = addSpatialNeighborBelowGroup(to: fixture)
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.engine.findGeometricNeighbor(
                from: fixture.activeToken,
                direction: .down,
                in: fixture.workspaceId
            ),
            neighbor
        )
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .down))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), neighbor)

        XCTAssertEqual(
            fixture.engine.findGeometricNeighbor(
                from: neighbor,
                direction: .up,
                in: fixture.workspaceId
            ),
            fixture.activeToken
        )
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
    }

    func testSpatialReturnToPendingGroupRevealWaitsForVerifiedFrame() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let neighbor = addSpatialNeighborAboveGroup(to: fixture)
        let pendingReveal = try beginPendingReveal(fixture)
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .up))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), neighbor)
        XCTAssertEqual(frontedTokens, [neighbor])

        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.focusNeighbor(direction: .down))
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertEqual(frontedTokens, [neighbor])

        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(frontedTokens, [neighbor])

        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(token: fixture.inactiveToken, frame: pendingReveal.frame),
            transactionId: pendingReveal.transactionId
        )
        XCTAssertEqual(frontedTokens, [neighbor, fixture.inactiveToken])
    }

    func testGroupMemberReorderIsBoundedAndKeepsActiveToken() throws {
        let fixture = try makeFixture { _, _ in }

        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.moveGroupMember(direction: .down))
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.members.map(\.token),
            [fixture.inactiveToken, fixture.activeToken]
        )
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.moveGroupMember(direction: .up))
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.members.map(\.token),
            [fixture.activeToken, fixture.inactiveToken]
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.moveGroupMember(direction: .up))
        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.moveGroupMember(direction: .down))
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.members.map(\.token),
            [fixture.inactiveToken, fixture.activeToken]
        )
    }

    func testMoveExtractsThenJoinsAndReportsOnlyGenuineEdge() throws {
        let fixture = try makeFixture { _, _ in }
        let preservedTileId = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.inactiveToken, in: fixture.workspaceId)?.id
        )
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .left),
            .movedWithinWorkspace
        )
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 2)
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.inactiveToken, in: fixture.workspaceId)?.id,
            preservedTileId
        )
        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        }

        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .left),
            .atWorkspaceEdge
        )
        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .right),
            .movedWithinWorkspace
        )
        let regrouped = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)
        )
        XCTAssertEqual(regrouped.id, preservedTileId)
        XCTAssertEqual(regrouped.members.map(\.token), [fixture.inactiveToken, fixture.activeToken])
        XCTAssertEqual(regrouped.activeToken, fixture.activeToken)
    }

    func testMoveFromGroupedSourceToGroupedNeighborIsTwoStep() throws {
        let fixture = try makeFixture { _, _ in }
        let destination = addGroupedNeighbor(to: fixture)
        let sourceTileId = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.id
        )
        let destinationTileId = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: destination.active, in: fixture.workspaceId)?.id
        )
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.engine.findGeometricNeighbor(
                from: fixture.activeToken,
                direction: .right,
                in: fixture.workspaceId
            ),
            destination.active
        )
        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .right),
            .movedWithinWorkspace
        )
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 3)
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.members.map(\.token),
            [fixture.activeToken]
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.inactiveToken, in: fixture.workspaceId)?.id,
            sourceTileId
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: destination.active, in: fixture.workspaceId)?.members.map(\.token),
            [destination.inactive, destination.active]
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: destination.active, in: fixture.workspaceId)?.id,
            destinationTileId
        )

        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        }
        XCTAssertEqual(
            fixture.engine.findGeometricNeighbor(
                from: fixture.activeToken,
                direction: .right,
                in: fixture.workspaceId
            ),
            destination.active
        )

        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .right),
            .movedWithinWorkspace
        )
        let joined = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)
        )
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 2)
        XCTAssertEqual(joined.id, destinationTileId)
        XCTAssertEqual(
            joined.members.map(\.token),
            [destination.inactive, destination.active, fixture.activeToken]
        )
        XCTAssertEqual(joined.activeToken, fixture.activeToken)
    }

    func testMoveEligibilityFailureIsBlockedWithoutMutation() throws {
        let fixture = try makeFixture { _, _ in }
        let before = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)
        )
        fixture.controller.workspaceManager.setLayoutReason(
            .nativeFullscreen,
            for: fixture.activeToken
        )

        XCTAssertEqual(
            fixture.controller.dwindleLayoutHandler.moveWindow(direction: .left),
            .blocked
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.inactiveToken, in: fixture.workspaceId),
            before
        )
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 1)
    }

    func testManagedFocusIngressActivatesBeforeFronting() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        fixture.controller.focusWindow(fixture.inactiveToken)

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.reason, .layoutCommand)
        let postLayout = try XCTUnwrap(pending.postLayoutActions.first)

        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)

        XCTAssertEqual(frontedTokens, [fixture.inactiveToken])
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.inactiveToken
        )
    }

    func testManagedFocusIngressDropsStalePostLayoutFronting() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        fixture.controller.focusWindow(fixture.inactiveToken)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        let postLayout = try XCTUnwrap(pending.postLayoutActions.first)
        _ = fixture.controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: fixture.workspaceId,
                viewportState: nil,
                rememberedFocusToken: fixture.activeToken,
                plannedSeq: fixture.controller.workspaceManager.worldSeq
            )
        )

        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)

        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testManagedFocusIngressDoesNotActivateGroupOnInactiveWorkspace() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let otherWorkspaceName = "98"
        fixture.controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: otherWorkspaceName, layoutType: .dwindle)
        )
        fixture.controller.workspaceManager.applySettings()
        let otherWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(named: otherWorkspaceName)
        )
        let monitor = try XCTUnwrap(
            fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(otherWorkspaceId, on: monitor.id)
        )
        XCTAssertFalse(
            fixture.controller.workspaceManager.visibleWorkspaceIds().contains(fixture.workspaceId)
        )

        fixture.controller.focusWindow(fixture.inactiveToken)

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertEqual(frontedTokens, [fixture.inactiveToken])
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.inactiveToken
        )
    }

    func testObservedAXFocusActivatesWithoutIssuingFocusRequest() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let entry = try XCTUnwrap(
            fixture.controller.workspaceManager.entry(for: fixture.inactiveToken)
        )

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: false
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.reason, .layoutCommand)
        XCTAssertEqual(pending.postLayoutActions.count, 1)

        pending.postLayoutActions[0].runIfCurrent(using: fixture.controller.workspaceManager)

        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testFocusRecoveryActivatesExactMemberOnSharedLeaf() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        fixture.controller.ensureFocusedTokenValid(
            in: fixture.workspaceId,
            preferredRecoveryToken: fixture.inactiveToken
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
    }

    func testNavigateToGroupedWindowUsesSingleWorkspaceTransition() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let handle = try XCTUnwrap(
            fixture.controller.workspaceManager.handle(for: fixture.inactiveToken)
        )

        XCTAssertTrue(fixture.controller.windowActionHandler.navigateToWindow(handle: handle))

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertEqual(pending.postLayoutActions.count, 1)

        pending.postLayoutActions[0].runIfCurrent(using: fixture.controller.workspaceManager)

        XCTAssertEqual(frontedTokens, [fixture.inactiveToken])
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.inactiveToken
        )
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .workspaceTransition
        )
    }

    func testPreferredKeyboardFocusFrameUsesGroupedContentFrame() throws {
        let fixture = try makeFixture { _, _ in }
        let contentFrame = try XCTUnwrap(
            fixture.engine.contentFrame(for: fixture.inactiveToken, in: fixture.workspaceId)
        )
        let tileFrame = try XCTUnwrap(
            fixture.engine.tileFrame(for: fixture.inactiveToken, in: fixture.workspaceId)
        )

        XCTAssertNotEqual(contentFrame, tileFrame)
        XCTAssertEqual(
            fixture.controller.preferredKeyboardFocusFrame(for: fixture.inactiveToken),
            contentFrame
        )
    }

    func testDwindleTabRailProjectsAndSelectsExactMember() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        let info = try XCTUnwrap(
            fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().first {
                $0.workspaceId == fixture.workspaceId
            }
        )
        XCTAssertEqual(info.tabs.compactMap(\.token), [fixture.inactiveToken, fixture.activeToken])
        XCTAssertEqual(info.activeVisualIndex, 1)
        guard case let .dwindleTile(tileId) = info.owner else {
            return XCTFail("expected a Dwindle tile rail")
        }
        XCTAssertEqual(
            tileId,
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.workspaceId)?.id
        )

        fixture.controller.dwindleLayoutHandler.selectGroupMember(
            info: info,
            visualIndex: 0,
            expectedToken: fixture.inactiveToken
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.origin,
            .pointerHover
        )
    }

    func testDwindleTabRailRejectsStaleOwner() throws {
        let fixture = try makeFixture { _, _ in }
        let info = TabRailInfo(
            workspaceId: fixture.workspaceId,
            owner: .dwindleTile(UUID()),
            plannedSeq: fixture.controller.workspaceManager.worldSeq,
            tileFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            tabCount: 2,
            activeVisualIndex: 1,
            activeWindowId: fixture.activeToken.windowId,
            tabs: [
                TabRailTabInfo(
                    visualIndex: 0,
                    token: fixture.inactiveToken,
                    windowId: fixture.inactiveToken.windowId,
                    appName: nil,
                    title: nil,
                    isActive: false
                ),
                TabRailTabInfo(
                    visualIndex: 1,
                    token: fixture.activeToken,
                    windowId: fixture.activeToken.windowId,
                    appName: nil,
                    title: nil,
                    isActive: true
                )
            ]
        )

        fixture.controller.dwindleLayoutHandler.selectGroupMember(
            info: info,
            visualIndex: 0,
            expectedToken: fixture.inactiveToken
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testDwindleTabRailIsSuppressedDuringStructuralAnimation() throws {
        let fixture = try makeFixture { _, _ in }
        let monitor = try XCTUnwrap(
            fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        )
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().isEmpty)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.registerDwindleAnimation(
                fixture.workspaceId,
                monitor: monitor,
                on: monitor.displayId
            )
        )

        XCTAssertTrue(fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().isEmpty)
    }

    func testValidRailSelectionIgnoresSuspendedPeer() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        fixture.controller.workspaceManager.setLayoutReason(
            .nativeFullscreen,
            for: fixture.inactiveToken
        )
        let info = try XCTUnwrap(
            fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().first {
                $0.workspaceId == fixture.workspaceId
            }
        )

        fixture.controller.dwindleLayoutHandler.selectGroupMember(
            info: info,
            visualIndex: 1,
            expectedToken: fixture.activeToken
        )

        XCTAssertEqual(frontedTokens, [fixture.activeToken])
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
    }

    func testFailedFullFrameRevealKeepsPreviousMemberVisible() throws {
        let fixture = try makeFixture { _, _ in }
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .layoutTransient(.left)
        )
        fixture.controller.workspaceManager.setHiddenState(
            hiddenState,
            for: fixture.inactiveToken
        )
        let activation = fixture.controller.workspaceManager.withEngineMutationScope {
            fixture.engine.activateWindowOutcome(fixture.inactiveToken, in: fixture.workspaceId)
        }
        XCTAssertEqual(activation, .activated)
        let monitor = try XCTUnwrap(
            fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        )
        let frames = fixture.controller.workspaceManager.withEngineMutationScope {
            fixture.engine.calculateLayout(
                for: fixture.workspaceId,
                screen: monitor.visibleFrame
            )
        }
        let constraints = WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false)
        let diff = fixture.controller.dwindleLayoutHandler.layoutDiff(
            windows: [
                LayoutWindowSnapshot(
                    token: fixture.inactiveToken,
                    constraints: constraints,
                    hiddenState: hiddenState,
                    layoutReason: .standard
                ),
                LayoutWindowSnapshot(
                    token: fixture.activeToken,
                    constraints: constraints,
                    hiddenState: nil,
                    layoutReason: .standard
                )
            ],
            frames: frames,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            preferredHideSide: .right,
            canRestoreHiddenWorkspaceWindows: true,
            scale: 1,
            reassertHidden: true,
            pendingParkWindowIds: []
        )
        XCTAssertEqual(diff.deferredHides.count, 1)
        let plan = WorkspaceLayoutPlan(
            workspaceId: fixture.workspaceId,
            monitor: fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: fixture.workspaceId,
                rememberedFocusToken: fixture.inactiveToken,
                plannedSeq: fixture.controller.workspaceManager.worldSeq
            ),
            diff: diff
        )

        XCTAssertTrue(fixture.controller.layoutRefreshController.executeLayoutPlan(plan))

        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: fixture.inactiveToken),
            hiddenState
        )
        XCTAssertNil(
            fixture.controller.workspaceManager.hiddenState(for: fixture.activeToken)
        )
    }

    func testFocusWaitsForVerifiedGroupReveal() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let pending = try beginPendingReveal(fixture)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.deferGroupSelectionCompletion(
                fixture.inactiveToken,
                workspaceId: fixture.workspaceId,
                focusAfterReveal: true,
                focusOrigin: .pointerHover
            )
        )

        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)

        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(
                token: fixture.inactiveToken,
                frame: pending.frame
            ),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(frontedTokens, [fixture.inactiveToken])
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: fixture.inactiveToken))
    }

    func testFailedGroupRevealRollsBackWithoutFronting() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let pending = try beginPendingReveal(fixture)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.deferGroupSelectionCompletion(
                fixture.inactiveToken,
                workspaceId: fixture.workspaceId,
                focusAfterReveal: true,
                focusOrigin: .keyboardOrProgrammatic
            )
        )

        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(
                token: fixture.inactiveToken,
                frame: pending.frame,
                failureReason: .contextUnavailable
            ),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
    }

    func testExecutorFailureDropsForwardedPostLayoutFocus() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .layoutTransient(.left)
        )
        fixture.controller.workspaceManager.setHiddenState(hiddenState, for: fixture.inactiveToken)
        fixture.controller.focusWindow(fixture.inactiveToken)
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        let currentAtEntry = postLayout.currentWorkspaces(
            using: fixture.controller.workspaceManager
        )
        let monitor = try XCTUnwrap(
            fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        )
        let frames = fixture.controller.workspaceManager.withEngineMutationScope {
            fixture.engine.calculateLayout(
                for: fixture.workspaceId,
                screen: monitor.visibleFrame
            )
        }
        let constraints = WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false)
        let diff = fixture.controller.dwindleLayoutHandler.layoutDiff(
            windows: [
                LayoutWindowSnapshot(
                    token: fixture.inactiveToken,
                    constraints: constraints,
                    hiddenState: hiddenState,
                    layoutReason: .standard
                ),
                LayoutWindowSnapshot(
                    token: fixture.activeToken,
                    constraints: constraints,
                    hiddenState: nil,
                    layoutReason: .standard
                )
            ],
            frames: frames,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            preferredHideSide: .right,
            canRestoreHiddenWorkspaceWindows: true,
            scale: 1,
            reassertHidden: true,
            pendingParkWindowIds: []
        )
        let plan = WorkspaceLayoutPlan(
            workspaceId: fixture.workspaceId,
            monitor: fixture.controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: fixture.workspaceId,
                rememberedFocusToken: fixture.inactiveToken,
                plannedSeq: fixture.controller.workspaceManager.worldSeq
            ),
            diff: diff
        )

        XCTAssertTrue(fixture.controller.layoutRefreshController.executeLayoutPlan(plan))
        if let transactionId = fixture.controller.dwindleLayoutHandler
            .pendingGroupRevealTransactionId(for: fixture.inactiveToken.windowId)
        {
            fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
                with: frameResult(
                    token: fixture.inactiveToken,
                    frame: try XCTUnwrap(frames[fixture.inactiveToken]),
                    failureReason: .contextUnavailable
                ),
                transactionId: transactionId
            )
        }
        let forwarded = postLayout.forwarded(
            by: [
                fixture.workspaceId: AcceptedSeq(
                    after: fixture.controller.workspaceManager.worldSeq,
                    domains: .layoutCommit.union(.focusCommit)
                )
            ],
            currentAtEntry: currentAtEntry
        )
        forwarded.runIfCurrent(using: fixture.controller.workspaceManager)

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.activeToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testPendingGroupRevealSurvivesManagedIdentityRekey() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let pending = try beginPendingReveal(fixture)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.deferGroupSelectionCompletion(
                fixture.inactiveToken,
                workspaceId: fixture.workspaceId,
                focusAfterReveal: true,
                focusOrigin: .keyboardOrProgrammatic
            )
        )
        let replacementToken = WindowToken(
            pid: fixture.inactiveToken.pid,
            windowId: fixture.inactiveToken.windowId + 100
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacementToken.pid),
            windowId: replacementToken.windowId
        )

        let replacementEntry = fixture.controller.axEventHandler.rekeyManagedWindowIdentity(
            from: fixture.inactiveToken,
            to: replacementToken,
            windowId: UInt32(replacementToken.windowId),
            axRef: replacementRef
        )

        XCTAssertNotNil(replacementEntry.committedEntry)
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), replacementToken)
        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(token: replacementToken, frame: pending.frame),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(frontedTokens, [replacementToken])
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, replacementToken)
    }

    func testManagedIdentityRekeyDoesNotReviveStaleGroupRevealFocus() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let pending = try beginPendingReveal(fixture)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.deferGroupSelectionCompletion(
                fixture.inactiveToken,
                workspaceId: fixture.workspaceId,
                focusAfterReveal: true,
                focusOrigin: .keyboardOrProgrammatic
            )
        )
        _ = fixture.controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: fixture.workspaceId,
                viewportState: nil,
                rememberedFocusToken: fixture.activeToken,
                plannedSeq: fixture.controller.workspaceManager.worldSeq
            )
        )
        let replacementToken = WindowToken(
            pid: fixture.inactiveToken.pid,
            windowId: fixture.inactiveToken.windowId + 100
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacementToken.pid),
            windowId: replacementToken.windowId
        )

        XCTAssertNotNil(
            fixture.controller.axEventHandler.rekeyManagedWindowIdentity(
                from: fixture.inactiveToken,
                to: replacementToken,
                windowId: UInt32(replacementToken.windowId),
                axRef: replacementRef
            ).committedEntry
        )
        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(token: replacementToken, frame: pending.frame),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), replacementToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testPendingGroupRevealSurvivesHideMemberIdentityRekey() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let pending = try beginPendingReveal(fixture)
        XCTAssertTrue(
            fixture.controller.dwindleLayoutHandler.deferGroupSelectionCompletion(
                fixture.inactiveToken,
                workspaceId: fixture.workspaceId,
                focusAfterReveal: true,
                focusOrigin: .keyboardOrProgrammatic
            )
        )
        let replacementToken = WindowToken(
            pid: fixture.activeToken.pid,
            windowId: fixture.activeToken.windowId + 100
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacementToken.pid),
            windowId: replacementToken.windowId
        )

        XCTAssertNotNil(
            fixture.controller.axEventHandler.rekeyManagedWindowIdentity(
                from: fixture.activeToken,
                to: replacementToken,
                windowId: UInt32(replacementToken.windowId),
                axRef: replacementRef
            ).committedEntry
        )
        XCTAssertNotNil(
            fixture.controller.dwindleLayoutHandler.pendingGroupRevealTransactionId(
                for: fixture.inactiveToken.windowId
            )
        )
        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(token: fixture.inactiveToken, frame: pending.frame),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), fixture.inactiveToken)
        XCTAssertNotNil(fixture.engine.tileSnapshot(for: replacementToken, in: fixture.workspaceId))
        XCTAssertEqual(frontedTokens, [fixture.inactiveToken])
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: fixture.inactiveToken))
    }

    func testFailedGroupRevealAfterHideMemberRekeyRollsBackToReplacement() throws {
        var frontedTokens: [WindowToken] = []
        let fixture = try makeFixture { pid, windowId in
            frontedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
        }
        let blocker = blockLayoutRefresh(fixture.controller, workspaceId: fixture.workspaceId)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let pending = try beginPendingReveal(fixture)
        let replacementToken = WindowToken(
            pid: fixture.activeToken.pid,
            windowId: fixture.activeToken.windowId + 100
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacementToken.pid),
            windowId: replacementToken.windowId
        )

        XCTAssertNotNil(
            fixture.controller.axEventHandler.rekeyManagedWindowIdentity(
                from: fixture.activeToken,
                to: replacementToken,
                windowId: UInt32(replacementToken.windowId),
                axRef: replacementRef
            ).committedEntry
        )
        fixture.controller.dwindleLayoutHandler.completePendingGroupRevealTransaction(
            with: frameResult(
                token: fixture.inactiveToken,
                frame: pending.frame,
                failureReason: .contextUnavailable
            ),
            transactionId: pending.transactionId
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.workspaceId), replacementToken)
        XCTAssertTrue(frontedTokens.isEmpty)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
    }

    private func makeFixture(
        onFront: @escaping (pid_t, UInt32) -> Void
    ) throws -> Fixture {
        let controller = makeController(onFront: onFront)
        let workspaceName = "97"
        controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: workspaceName, layoutType: .dwindle)
        )
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: workspaceName)
        )
        _ = controller.workspaceManager.focusWorkspace(named: workspaceName)
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.layoutRefreshController.resetState()

        let firstToken = addWindow(pid: 991, windowId: 1, workspaceId: workspaceId, controller: controller)
        let secondToken = addWindow(pid: 992, windowId: 2, workspaceId: workspaceId, controller: controller)
        let screen = controller.workspaceManager.monitor(for: workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: firstToken, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: secondToken, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            XCTAssertTrue(engine.groupWindow(direction: .left, in: workspaceId))
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
        }
        controller.layoutRefreshController.resetState()

        XCTAssertEqual(engine.activeToken(in: workspaceId), secondToken)
        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            inactiveToken: firstToken,
            activeToken: secondToken
        )
    }

    private func makeController(
        onFront: @escaping (pid_t, UInt32) -> Void
    ) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDwindleGroupFocusTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in onFront(pid, windowId) },
                raiseWindow: { _ in }
            )
        )
        let monitor = Monitor(
            id: .init(displayId: 97_000),
            displayId: 97_000,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            hasNotch: false,
            name: "Dwindle Group Focus"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        return controller
    }

    private func addGroupedMember(to fixture: Fixture) -> WindowToken {
        let token = addWindow(
            pid: 993,
            windowId: 3,
            workspaceId: fixture.workspaceId,
            controller: fixture.controller
        )
        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            _ = fixture.engine.addWindow(
                token: token,
                to: fixture.workspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            XCTAssertTrue(fixture.engine.groupWindow(direction: .left, in: fixture.workspaceId))
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        }
        fixture.controller.layoutRefreshController.resetState()
        return token
    }

    private func addSpatialNeighborBelowGroup(to fixture: Fixture) -> WindowToken {
        let token = addWindow(
            pid: 993,
            windowId: 3,
            workspaceId: fixture.workspaceId,
            controller: fixture.controller
        )
        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            XCTAssertTrue(fixture.engine.setPreselection(.down, in: fixture.workspaceId))
            _ = fixture.engine.addWindow(
                token: token,
                to: fixture.workspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            fixture.engine.setSelectedNode(
                fixture.engine.findNode(for: fixture.activeToken, in: fixture.workspaceId),
                in: fixture.workspaceId
            )
        }
        fixture.controller.layoutRefreshController.resetState()
        return token
    }

    private func addSpatialNeighborAboveGroup(to fixture: Fixture) -> WindowToken {
        let token = addWindow(
            pid: 995,
            windowId: 5,
            workspaceId: fixture.workspaceId,
            controller: fixture.controller
        )
        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            XCTAssertTrue(fixture.engine.setPreselection(.up, in: fixture.workspaceId))
            _ = fixture.engine.addWindow(
                token: token,
                to: fixture.workspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            fixture.engine.setSelectedNode(
                fixture.engine.findNode(for: fixture.activeToken, in: fixture.workspaceId),
                in: fixture.workspaceId
            )
        }
        fixture.controller.layoutRefreshController.resetState()
        return token
    }

    private func addGroupedNeighbor(
        to fixture: Fixture
    ) -> (inactive: WindowToken, active: WindowToken) {
        let inactive = addWindow(
            pid: 993,
            windowId: 3,
            workspaceId: fixture.workspaceId,
            controller: fixture.controller
        )
        let active = addWindow(
            pid: 994,
            windowId: 4,
            workspaceId: fixture.workspaceId,
            controller: fixture.controller
        )
        let screen = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        fixture.controller.workspaceManager.withEngineMutationScope {
            _ = fixture.engine.addWindow(
                token: inactive,
                to: fixture.workspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            XCTAssertTrue(fixture.engine.setPreselection(.right, in: fixture.workspaceId))
            _ = fixture.engine.addWindow(
                token: active,
                to: fixture.workspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            XCTAssertTrue(fixture.engine.groupWindow(direction: .left, in: fixture.workspaceId))
            _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
            fixture.engine.setSelectedNode(
                fixture.engine.findNode(for: fixture.activeToken, in: fixture.workspaceId),
                in: fixture.workspaceId
            )
        }
        fixture.controller.layoutRefreshController.resetState()
        return (inactive, active)
    }

    private func beginPendingReveal(
        _ fixture: Fixture
    ) throws -> (transactionId: UInt64, frame: CGRect) {
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .layoutTransient(.left)
        )
        fixture.controller.workspaceManager.setHiddenState(hiddenState, for: fixture.inactiveToken)
        let activation = fixture.controller.workspaceManager.withEngineMutationScope {
            fixture.engine.activateWindowOutcome(fixture.inactiveToken, in: fixture.workspaceId)
        }
        XCTAssertEqual(activation, .activated)
        let monitor = try XCTUnwrap(
            fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        )
        let frames = fixture.engine.calculateLayout(
            for: fixture.workspaceId,
            screen: monitor.visibleFrame
        )
        let frame = try XCTUnwrap(frames[fixture.inactiveToken])
        let entry = try XCTUnwrap(
            fixture.controller.workspaceManager.entry(for: fixture.inactiveToken)
        )
        let transactionId = try XCTUnwrap(
            fixture.controller.dwindleLayoutHandler.beginPendingGroupRevealTransaction(
                for: entry,
                targetFrame: frame,
                monitor: monitor,
                hides: [
                    LayoutDeferredHide(
                        token: fixture.activeToken,
                        side: .right,
                        revealToken: fixture.inactiveToken
                    )
                ],
                preserveWorkspaceInactive: false
            )
        )
        return (transactionId, frame)
    }

    private func frameResult(
        token: WindowToken,
        frame: CGRect,
        failureReason: AXFrameWriteFailureReason? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(token.pid),
                windowId: token.windowId
            ),
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                targetFrame: frame,
                observedFrame: failureReason == nil ? frame : nil,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: failureReason
            )
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func blockLayoutRefresh(
        _ controller: WMController,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        return blocker
    }

    private func unblockLayoutRefresh(
        _ controller: WMController,
        blocker: Task<Void, Never>
    ) {
        blocker.cancel()
        controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }
}
