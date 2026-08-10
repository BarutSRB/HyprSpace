// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class DwindleCommandRoutingTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let sourceMonitor: Monitor
        let targetMonitor: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let firstToken: WindowToken
        let activeToken: WindowToken
    }

    func testFocusAtGroupEdgeUsesEligibleAdjacentMonitorWithoutLocalWrap() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.targetMonitor.id
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertTrue(pending.affectedWorkspaceIds.contains(fixture.targetWorkspaceId))
    }

    func testFocusAtGroupEdgeWrapsLocallyWhenAdjacentWorkspaceHasNoCandidate() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.firstToken)
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .layoutCommand)
        XCTAssertTrue(pending.affectedWorkspaceIds.contains(fixture.sourceWorkspaceId))
    }

    func testLocalSpatialExitPrecedesEligibleAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let localNeighbor = addWindow(
            pid: 31_105,
            windowId: 31_205,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            XCTAssertTrue(fixture.engine.setPreselection(.down, in: fixture.sourceWorkspaceId))
            _ = fixture.engine.addWindow(
                token: localNeighbor,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focus(.down)),
            .executed
        )

        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), localNeighbor)
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
    }

    func testSharedWrapAndReorderCommandsRouteToDwindleGroups() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: true)
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusWindowDownOrTop),
            .executed
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.firstToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.focusWindowUpOrBottom),
            .executed
        )
        XCTAssertEqual(fixture.engine.activeToken(in: fixture.sourceWorkspaceId), fixture.activeToken)

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowUp),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.activeToken, fixture.firstToken]
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowUp),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.activeToken, fixture.firstToken]
        )
        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowDown),
            .executed
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(
                for: fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )?.members.map(\.token),
            [fixture.firstToken, fixture.activeToken]
        )
    }

    func testMoveAtSingletonEdgeTransfersToAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        fixture.controller.settings.moveCrossesMonitorAtEdge = true
        fixture.controller.settings.focusFollowsWindowToMonitor = false
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.move(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.targetWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.targetMonitor.id
        )
        XCTAssertNil(fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId))
        let pending = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh
        )
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertEqual(
            pending.affectedWorkspaceIds,
            [fixture.sourceWorkspaceId, fixture.targetWorkspaceId]
        )
    }

    func testEligibilityBlockedMoveDoesNotTransferToAdjacentMonitor() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        fixture.controller.settings.moveCrossesMonitorAtEdge = true
        let before = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        fixture.controller.workspaceManager.setLayoutReason(
            .nativeFullscreen,
            for: fixture.activeToken
        )
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.move(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertEqual(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId),
            before
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testMoveContainerSwapsWholeGroupAndNeverTransfersAtMonitorEdge() throws {
        let fixture = try makeFixture(groupedSource: true, includeTargetCandidate: false)
        fixture.controller.settings.moveCrossesMonitorAtEdge = true
        let thirdToken = addWindow(
            pid: 31_104,
            windowId: 31_204,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            XCTAssertTrue(fixture.engine.setPreselection(.right, in: fixture.sourceWorkspaceId))
            _ = fixture.engine.addWindow(
                token: thirdToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.activeToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let groupedBefore = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        let thirdBefore = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: thirdToken, in: fixture.sourceWorkspaceId)
        )
        let groupedNodeIdBefore = try XCTUnwrap(
            fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId)?.id
        )
        let thirdNodeIdBefore = try XCTUnwrap(
            fixture.engine.findNode(for: thirdToken, in: fixture.sourceWorkspaceId)?.id
        )
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveColumn(.right)),
            .executed
        )

        let groupedAfter = try XCTUnwrap(
            fixture.engine.tileSnapshot(for: fixture.activeToken, in: fixture.sourceWorkspaceId)
        )
        XCTAssertEqual(groupedAfter.id, groupedBefore.id)
        XCTAssertEqual(groupedAfter.members.map(\.token), [fixture.firstToken, fixture.activeToken])
        XCTAssertEqual(groupedAfter.activeToken, fixture.activeToken)
        XCTAssertEqual(
            fixture.engine.findNode(for: fixture.activeToken, in: fixture.sourceWorkspaceId)?.id,
            thirdNodeIdBefore
        )
        XCTAssertEqual(
            fixture.engine.findNode(for: thirdToken, in: fixture.sourceWorkspaceId)?.id,
            groupedNodeIdBefore
        )
        XCTAssertNotEqual(groupedBefore.id, thirdBefore.id)
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveColumn(.down)),
            .executed
        )

        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.activeToken),
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.sourceMonitor.id
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    func testSharedCycleSizeCommandRoutesToDwindleSplitRatio() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        let secondToken = addWindow(
            pid: 31_106,
            windowId: 31_206,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = fixture.engine.addWindow(
                token: secondToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
        }
        let before = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId)?.splitRatio)
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.cycleSizeForward),
            .executed
        )

        let after = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId)?.splitRatio)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
            .layoutCommand
        )
    }

    func testIPCResizeRoutesGrowAndShrinkAlongAxis() throws {
        let fixture = try makeFixture(groupedSource: false, includeTargetCandidate: false)
        let secondToken = addWindow(
            pid: 31_107,
            windowId: 31_207,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = fixture.engine.addWindow(
                token: secondToken,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = fixture.engine.calculateLayout(
                for: fixture.sourceWorkspaceId,
                screen: fixture.sourceMonitor.visibleFrame
            )
            _ = fixture.engine.activateWindowOutcome(
                fixture.firstToken,
                in: fixture.sourceWorkspaceId
            )
        }
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture.controller, blocker: blocker) }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "test")
        let root = try XCTUnwrap(fixture.engine.root(for: fixture.sourceWorkspaceId))

        XCTAssertEqual(router.handle(.resize(axis: .horizontal, operation: .grow)), .executed)
        XCTAssertEqual(root.splitRatio ?? 0, 1.1, accuracy: 0.000_001)

        XCTAssertEqual(router.handle(.resize(axis: .horizontal, operation: .shrink)), .executed)
        XCTAssertEqual(root.splitRatio ?? 0, 1.0, accuracy: 0.000_001)
    }

    private func makeFixture(
        groupedSource: Bool,
        includeTargetCandidate: Bool
    ) throws -> Fixture {
        let sourceMonitor = Monitor(
            id: .init(displayId: 31_001),
            displayId: 31_001,
            frame: CGRect(x: 0, y: 900, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1600, height: 900),
            hasNotch: false,
            name: "Source"
        )
        let targetMonitor = Monitor(
            id: .init(displayId: 31_002),
            displayId: 31_002,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Target"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMDwindleCommandRoutingTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .dwindle
            )
        ]
        settings.focusCrossesMonitorAtEdge = true
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, targetMonitor])
        controller.workspaceManager.applySettings()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: "1")
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: "2")
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                targetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                sourceWorkspaceId,
                on: sourceMonitor.id
            )
        )

        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let firstToken = addWindow(
            pid: 31_101,
            windowId: 31_201,
            to: sourceWorkspaceId,
            controller: controller
        )
        let activeToken = groupedSource ? addWindow(
            pid: 31_102,
            windowId: 31_202,
            to: sourceWorkspaceId,
            controller: controller
        ) : firstToken
        let targetToken = includeTargetCandidate ? addWindow(
            pid: 31_103,
            windowId: 31_203,
            to: targetWorkspaceId,
            controller: controller
        ) : nil

        controller.workspaceManager.withEngineMutationScope(in: sourceWorkspaceId) {
            _ = engine.addWindow(token: firstToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            if groupedSource {
                _ = engine.addWindow(token: activeToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            }
            _ = engine.calculateLayout(for: sourceWorkspaceId, screen: sourceMonitor.visibleFrame)
            if groupedSource {
                XCTAssertTrue(engine.groupWindow(direction: .left, in: sourceWorkspaceId))
                _ = engine.calculateLayout(for: sourceWorkspaceId, screen: sourceMonitor.visibleFrame)
            }
            if let targetToken {
                _ = engine.addWindow(token: targetToken, to: targetWorkspaceId, activeWindowFrame: nil)
                _ = engine.calculateLayout(for: targetWorkspaceId, screen: targetMonitor.visibleFrame)
            }
        }
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                activeToken,
                in: sourceWorkspaceId,
                onMonitor: sourceMonitor.id
            )
        )
        if let targetToken {
            XCTAssertNotNil(controller.preferredKeyboardFocusFrame(for: targetToken))
        }

        return Fixture(
            controller: controller,
            engine: engine,
            sourceMonitor: sourceMonitor,
            targetMonitor: targetMonitor,
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            firstToken: firstToken,
            activeToken: activeToken
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func blockLayoutRefresh(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.sourceWorkspaceId]
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
