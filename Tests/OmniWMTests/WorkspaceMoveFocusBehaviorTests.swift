// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceMoveFocusBehaviorTests: XCTestCase {
    private final class FocusRecorder {
        var focusedTokens: [WindowToken] = []
    }

    private struct Fixture {
        let controller: WMController
        let workspaceIds: [WorkspaceDescriptor.ID]
        let monitor: Monitor
        let focusRecorder: FocusRecorder
    }

    private struct MonitorMoveFixture {
        let controller: WMController
        let sourceMonitor: Monitor
        let targetMonitor: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let inactiveTargetWorkspaceId: WorkspaceDescriptor.ID
        let activeTargetWorkspaceId: WorkspaceDescriptor.ID
        let focusRecorder: FocusRecorder
    }

    private struct NiriColumnFixture {
        let fallback: WindowHandle
        let selected: WindowHandle
        let stacked: WindowHandle
    }

    func testNiriAdjacentWindowMoveHonorsFollowSettingWithEmptySourceAndDynamicDestination() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.niri], followsFocus: followsFocus)
            let sourceWorkspaceId = fixture.workspaceIds[0]
            let moved = try addManagedWindow(
                pid: 488_001,
                windowId: followsFocus ? 2 : 1,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            try select(moved, in: sourceWorkspaceId, fixture: fixture)

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)

                let destinationWorkspaceId = try XCTUnwrap(
                    fixture.controller.workspaceManager.workspaceId(named: "2")
                )
                XCTAssertTrue(fixture.controller.workspaceManager.entries(in: sourceWorkspaceId).isEmpty)
                XCTAssertEqual(
                    fixture.controller.workspaceManager.workspace(for: moved.id),
                    destinationWorkspaceId
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
                    moved.id
                )

                try assertCompletion(
                    fixture,
                    activeWorkspaceId: followsFocus ? destinationWorkspaceId : sourceWorkspaceId,
                    expectedFocusToken: followsFocus ? moved.id : nil
                )
            }
        }
    }

    func testDwindleAdjacentWindowMoveHonorsFollowSetting() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.dwindle], followsFocus: followsFocus)
            let sourceWorkspaceId = fixture.workspaceIds[0]
            let fallback = try addManagedWindow(
                pid: 488_002,
                windowId: followsFocus ? 12 : 11,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            let moved = try addManagedWindow(
                pid: 488_002,
                windowId: followsFocus ? 14 : 13,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            try select(moved, in: sourceWorkspaceId, fixture: fixture)

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)

                let destinationWorkspaceId = try XCTUnwrap(
                    fixture.controller.workspaceManager.workspaceId(named: "2")
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.workspace(for: fallback.id),
                    sourceWorkspaceId
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.workspace(for: moved.id),
                    destinationWorkspaceId
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.lastFocusedToken(in: sourceWorkspaceId),
                    fallback.id
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
                    moved.id
                )

                try assertCompletion(
                    fixture,
                    activeWorkspaceId: followsFocus ? destinationWorkspaceId : sourceWorkspaceId,
                    expectedFocusToken: followsFocus ? moved.id : fallback.id
                )
            }
        }
    }

    func testNiriAdjacentWindowMoveUpHonorsFollowSetting() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: followsFocus)
            let sourceWorkspaceId = try XCTUnwrap(fixture.workspaceIds.last)
            let destinationWorkspaceId = try XCTUnwrap(fixture.workspaceIds.first)
            XCTAssertNotEqual(sourceWorkspaceId, destinationWorkspaceId)
            XCTAssertTrue(
                fixture.controller.workspaceManager.setActiveWorkspace(
                    sourceWorkspaceId,
                    on: fixture.monitor.id
                )
            )
            let moved = try addManagedWindow(
                pid: 488_004,
                windowId: followsFocus ? 62 : 61,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            try select(moved, in: sourceWorkspaceId, fixture: fixture)

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)

                XCTAssertTrue(fixture.controller.workspaceManager.entries(in: sourceWorkspaceId).isEmpty)
                XCTAssertEqual(
                    fixture.controller.workspaceManager.workspace(for: moved.id),
                    destinationWorkspaceId
                )
                XCTAssertEqual(
                    fixture.controller.workspaceManager.lastFocusedToken(in: destinationWorkspaceId),
                    moved.id
                )
                try assertCompletion(
                    fixture,
                    activeWorkspaceId: followsFocus ? destinationWorkspaceId : sourceWorkspaceId,
                    expectedFocusToken: followsFocus ? moved.id : nil
                )
            }
        }
    }

    func testNiriAdjacentColumnMoveHonorsFollowSetting() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.niri], followsFocus: followsFocus)
            let sourceWorkspaceId = fixture.workspaceIds[0]
            let column = try makeNiriColumnFixture(
                sourceWorkspaceId: sourceWorkspaceId,
                fixture: fixture,
                windowIdOffset: followsFocus ? 30 : 20
            )

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down)

                let destinationWorkspaceId = try XCTUnwrap(
                    fixture.controller.workspaceManager.workspaceId(named: "2")
                )
                try assertColumnMove(
                    fixture,
                    column: column,
                    sourceWorkspaceId: sourceWorkspaceId,
                    destinationWorkspaceId: destinationWorkspaceId
                )
                try assertCompletion(
                    fixture,
                    activeWorkspaceId: followsFocus ? destinationWorkspaceId : sourceWorkspaceId,
                    expectedFocusToken: followsFocus ? column.selected.id : column.fallback.id
                )
            }
        }
    }

    func testNiriIndexedColumnMoveHonorsFollowSetting() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: followsFocus)
            let sourceWorkspaceId = fixture.workspaceIds[0]
            let destinationWorkspaceId = fixture.workspaceIds[1]
            let column = try makeNiriColumnFixture(
                sourceWorkspaceId: sourceWorkspaceId,
                fixture: fixture,
                windowIdOffset: followsFocus ? 50 : 40
            )

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: 1)

                try assertColumnMove(
                    fixture,
                    column: column,
                    sourceWorkspaceId: sourceWorkspaceId,
                    destinationWorkspaceId: destinationWorkspaceId
                )
                try assertCompletion(
                    fixture,
                    activeWorkspaceId: followsFocus ? destinationWorkspaceId : sourceWorkspaceId,
                    expectedFocusToken: followsFocus ? column.selected.id : column.fallback.id
                )
            }
        }
    }

    func testNiriIndexedWindowMoveRefocusesRemainingSourceWindowAfterLayout() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: false)
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        let fallback = try addManagedWindow(
            pid: 488_005,
            windowId: 71,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let moved = try addManagedWindow(
            pid: 488_005,
            windowId: 72,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        try select(moved, in: sourceWorkspaceId, fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)

            XCTAssertEqual(
                fixture.controller.workspaceManager.workspace(for: fallback.id),
                sourceWorkspaceId
            )
            XCTAssertEqual(
                fixture.controller.workspaceManager.workspace(for: moved.id),
                destinationWorkspaceId
            )
            try assertCompletion(
                fixture,
                activeWorkspaceId: sourceWorkspaceId,
                expectedFocusToken: fallback.id
            )
        }
    }

    func testInvalidatedIndexedWindowMoveRecoversRemainingSourceWindow() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: false)
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let fallback = try addManagedWindow(
            pid: 488_006,
            windowId: 81,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let moved = try addManagedWindow(
            pid: 488_006,
            windowId: 82,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        try select(moved, in: sourceWorkspaceId, fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)

            let action = try pendingPostLayoutAction(fixture)
            fixture.controller.workspaceManager.invalidateLayout(for: [sourceWorkspaceId])
            XCTAssertFalse(action.isCurrent(using: fixture.controller.workspaceManager))
            action.runIfCurrent(using: fixture.controller.workspaceManager)

            XCTAssertEqual(fixture.focusRecorder.focusedTokens, [fallback.id])
            XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, fallback.id)
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, fallback.id)
        }
    }

    func testInvalidatedIndexedWindowMoveDoesNotOverrideNewerFocusIntent() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: false)
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        _ = try addManagedWindow(
            pid: 488_007,
            windowId: 91,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let moved = try addManagedWindow(
            pid: 488_007,
            windowId: 92,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        try select(moved, in: sourceWorkspaceId, fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)

            let action = try pendingPostLayoutAction(fixture)
            let newerRequest = fixture.controller.intentLedger.beginManagedRequest(
                token: moved.id,
                workspaceId: destinationWorkspaceId
            )
            fixture.controller.workspaceManager.invalidateLayout(for: [sourceWorkspaceId])
            XCTAssertFalse(action.isCurrent(using: fixture.controller.workspaceManager))
            action.runIfCurrent(using: fixture.controller.workspaceManager)

            XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
            XCTAssertEqual(
                fixture.controller.intentLedger.activeManagedRequest?.requestId,
                newerRequest.requestId
            )
        }
    }

    func testInvalidatedWorkspaceMoveDoesNotOverrideNewerNonManagedFocus() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: followsFocus)
            let sourceWorkspaceId = fixture.workspaceIds[0]
            _ = try addManagedWindow(
                pid: 488_010,
                windowId: followsFocus ? 122 : 121,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            let moved = try addManagedWindow(
                pid: 488_010,
                windowId: followsFocus ? 124 : 123,
                to: sourceWorkspaceId,
                fixture: fixture
            )
            try select(moved, in: sourceWorkspaceId, fixture: fixture)

            try withBlockedLayoutRefreshes(fixture) {
                fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)

                let action = try pendingPostLayoutAction(fixture)
                XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus())
                XCTAssertFalse(action.isCurrent(using: fixture.controller.workspaceManager))
                action.runIfCurrent(using: fixture.controller.workspaceManager)

                XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
                XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
                XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
            }
        }
    }

    func testCurrentIndexedWindowMoveDoesNotOverrideNewerFocusIntent() throws {
        let fixture = try makeFixture(layouts: [.niri, .niri], followsFocus: false)
        let sourceWorkspaceId = fixture.workspaceIds[0]
        let destinationWorkspaceId = fixture.workspaceIds[1]
        _ = try addManagedWindow(
            pid: 488_009,
            windowId: 111,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let moved = try addManagedWindow(
            pid: 488_009,
            windowId: 112,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        try select(moved, in: sourceWorkspaceId, fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 1)

            let action = try pendingPostLayoutAction(fixture)
            let newerRequest = fixture.controller.intentLedger.beginManagedRequest(
                token: moved.id,
                workspaceId: destinationWorkspaceId
            )
            XCTAssertTrue(action.isCurrent(using: fixture.controller.workspaceManager))
            action.runIfCurrent(using: fixture.controller.workspaceManager)

            XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
            XCTAssertEqual(
                fixture.controller.intentLedger.activeManagedRequest?.requestId,
                newerRequest.requestId
            )
        }
    }

    func testIndexedWindowMoveToCurrentWorkspaceIsNoOp() throws {
        let fixture = try makeFixture(layouts: [.niri], followsFocus: false)
        let workspaceId = fixture.workspaceIds[0]
        let window = try addManagedWindow(
            pid: 488_008,
            windowId: 101,
            to: workspaceId,
            fixture: fixture
        )
        try select(window, in: workspaceId, fixture: fixture)

        fixture.controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: 0)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: window.id), workspaceId)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testDirectMonitorMoveTargetsActiveWorkspaceAndHonorsFollowSetting() throws {
        for layout in [LayoutType.niri, .dwindle] {
            for followsFocus in [false, true] {
                let fixture = try makeMonitorMoveFixture(layout: layout, followsFocus: followsFocus)
                let idOffset = (layout == .niri ? 0 : 100) + (followsFocus ? 10 : 0)
                let fallback = try addManagedWindow(
                    pid: pid_t(488_100 + idOffset),
                    windowId: 1,
                    to: fixture.sourceWorkspaceId,
                    controller: fixture.controller
                )
                let moved = try addManagedWindow(
                    pid: pid_t(488_100 + idOffset),
                    windowId: 2,
                    to: fixture.sourceWorkspaceId,
                    controller: fixture.controller
                )
                _ = try addManagedWindow(
                    pid: pid_t(488_100 + idOffset),
                    windowId: 3,
                    to: fixture.activeTargetWorkspaceId,
                    controller: fixture.controller
                )
                try select(
                    moved,
                    in: fixture.sourceWorkspaceId,
                    on: fixture.sourceMonitor,
                    controller: fixture.controller,
                    focusRecorder: fixture.focusRecorder
                )

                try withBlockedLayoutRefreshes(
                    controller: fixture.controller,
                    affectedWorkspaceId: fixture.sourceWorkspaceId
                ) {
                    XCTAssertFalse(fixture.controller.settings.moveCrossesMonitorAtEdge)
                    XCTAssertEqual(
                        fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowToMonitor(.right)),
                        .executed
                    )

                    let manager = fixture.controller.workspaceManager
                    XCTAssertEqual(manager.workspace(for: fallback.id), fixture.sourceWorkspaceId)
                    XCTAssertEqual(manager.workspace(for: moved.id), fixture.activeTargetWorkspaceId)
                    XCTAssertNotEqual(manager.workspace(for: moved.id), fixture.inactiveTargetWorkspaceId)
                    XCTAssertEqual(
                        manager.activeWorkspace(on: fixture.targetMonitor.id)?.id,
                        fixture.activeTargetWorkspaceId
                    )
                    XCTAssertEqual(
                        manager.interactionMonitorId,
                        followsFocus ? fixture.targetMonitor.id : fixture.sourceMonitor.id
                    )
                    XCTAssertEqual(
                        fixture.controller.activeWorkspace()?.id,
                        followsFocus ? fixture.activeTargetWorkspaceId : fixture.sourceWorkspaceId
                    )
                    XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)

                    let pending = try XCTUnwrap(
                        fixture.controller.layoutRefreshController.layoutState.pendingRefresh
                    )
                    XCTAssertEqual(pending.reason, .workspaceTransition)
                    XCTAssertEqual(
                        pending.affectedWorkspaceIds,
                        [fixture.sourceWorkspaceId, fixture.activeTargetWorkspaceId]
                    )
                    XCTAssertEqual(pending.postLayoutActions.count, 1)
                    let action = try XCTUnwrap(pending.postLayoutActions.first)
                    XCTAssertTrue(action.isCurrent(using: manager))
                    action.runIfCurrent(using: manager)

                    let expectedFocusToken = followsFocus ? moved.id : fallback.id
                    XCTAssertEqual(fixture.focusRecorder.focusedTokens, [expectedFocusToken])
                    XCTAssertEqual(manager.pendingFocusedToken, expectedFocusToken)
                    XCTAssertEqual(
                        fixture.controller.intentLedger.activeManagedRequest?.token,
                        expectedFocusToken
                    )
                }
            }
        }
    }

    func testDirectMonitorMoveNoOpsWithoutFocusOrAdjacentMonitor() throws {
        let fixture = try makeMonitorMoveFixture(layout: .niri, followsFocus: false)
        let controller = fixture.controller
        let manager = controller.workspaceManager

        let noFocusWorldSeq = manager.worldSeq
        XCTAssertNil(manager.focusedToken)
        XCTAssertEqual(
            controller.commandHandler.handleHotkeyCommand(.moveWindowToMonitor(.right)),
            .executed
        )
        XCTAssertEqual(manager.worldSeq, noFocusWorldSeq)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)

        let window = try addManagedWindow(
            pid: 488_200,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        try select(
            window,
            in: fixture.sourceWorkspaceId,
            on: fixture.sourceMonitor,
            controller: controller,
            focusRecorder: fixture.focusRecorder
        )
        controller.layoutRefreshController.resetState()
        let noAdjacentWorldSeq = manager.worldSeq

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyCommand(.moveWindowToMonitor(.left)),
            .executed
        )
        XCTAssertEqual(manager.workspace(for: window.id), fixture.sourceWorkspaceId)
        XCTAssertEqual(manager.worldSeq, noAdjacentWorldSeq)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }
}

extension WorkspaceMoveFocusBehaviorTests {
    private func makeMonitorMoveFixture(
        layout: LayoutType,
        followsFocus: Bool
    ) throws -> MonitorMoveFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMonitorMoveFocusBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let targetFrame = CGRect(x: 1600, y: 0, width: 1600, height: 900)
        let sourceMonitor = Monitor(
            id: .init(displayId: 488_010),
            displayId: 488_010,
            frame: sourceFrame,
            visibleFrame: sourceFrame,
            hasNotch: false,
            name: "Workspace Monitor Move Source"
        )
        let targetMonitor = Monitor(
            id: .init(displayId: 488_011),
            displayId: 488_011,
            frame: targetFrame,
            visibleFrame: targetFrame,
            hasNotch: false,
            name: "Workspace Monitor Move Target"
        )
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
        settings.animationsEnabled = false
        settings.focusFollowsWindowToMonitor = followsFocus
        settings.moveCrossesMonitorAtEdge = false
        settings.defaultLayoutType = layout
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: layout
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: layout
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: layout
            )
        ]

        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(
                        WindowToken(pid: pid, windowId: Int(windowId))
                    )
                },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, targetMonitor])
        controller.workspaceManager.applySettings()
        installLayoutEngines(on: controller)

        let sourceWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let inactiveTargetWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        let activeTargetWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "3"))
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                inactiveTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                activeTargetWorkspaceId,
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
        controller.layoutRefreshController.resetState()

        return MonitorMoveFixture(
            controller: controller,
            sourceMonitor: sourceMonitor,
            targetMonitor: targetMonitor,
            sourceWorkspaceId: sourceWorkspaceId,
            inactiveTargetWorkspaceId: inactiveTargetWorkspaceId,
            activeTargetWorkspaceId: activeTargetWorkspaceId,
            focusRecorder: focusRecorder
        )
    }

    private func makeFixture(
        layouts: [LayoutType],
        followsFocus: Bool
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMoveFocusBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        let settings = makeSettings(root: root, layouts: layouts, followsFocus: followsFocus)

        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(
                        WindowToken(pid: pid, windowId: Int(windowId))
                    )
                },
                raiseWindow: { _ in }
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 488_000),
            displayId: 488_000,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Workspace Move Focus Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        installLayoutEngines(on: controller)

        let workspaceIds = try layouts.indices.map { index in
            try XCTUnwrap(
                controller.workspaceManager.workspaceId(
                    for: String(index + 1),
                    createIfMissing: false
                )
            )
        }
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceIds[0], on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            workspaceIds: workspaceIds,
            monitor: monitor,
            focusRecorder: focusRecorder
        )
    }

    private func makeSettings(
        root: URL,
        layouts: [LayoutType],
        followsFocus: Bool
    ) -> SettingsStore {
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
        settings.animationsEnabled = false
        settings.focusFollowsWindowToMonitor = followsFocus
        settings.defaultLayoutType = layouts.first ?? .niri
        settings.workspaceConfigurations = layouts.enumerated().map { index, layout in
            WorkspaceConfiguration(
                name: String(index + 1),
                monitorAssignment: .main,
                layoutType: layout
            )
        }
        return settings
    }

    private func installLayoutEngines(on controller: WMController) {
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()

        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine
    }

    private func addManagedWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws -> WindowHandle {
        try addManagedWindow(
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            controller: fixture.controller
        )
    }

    private func addManagedWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> WindowHandle {
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = controller.dwindleEngine?.addWindow(
                    token: token,
                    to: workspaceId,
                    activeWindowFrame: nil
                )
            }
        }
        return try XCTUnwrap(controller.workspaceManager.handle(for: token))
    }

    private func select(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws {
        try select(
            handle,
            in: workspaceId,
            on: fixture.monitor,
            controller: fixture.controller,
            focusRecorder: fixture.focusRecorder
        )
    }

    private func select(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor,
        controller: WMController,
        focusRecorder: FocusRecorder
    ) throws {
        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            let engine = try XCTUnwrap(controller.niriEngine)
            let node = try XCTUnwrap(engine.findNode(for: handle, in: workspaceId))
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                engine.activateWindow(node.id, in: workspaceId)
            }
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: node.id,
                focusedToken: handle.id,
                in: workspaceId,
                onMonitor: monitor.id
            )
        case .dwindle:
            let engine = try XCTUnwrap(controller.dwindleEngine)
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.activateWindow(handle.id, in: workspaceId)
            }
            _ = controller.workspaceManager.commitWorkspaceSelection(
                nodeId: nil,
                focusedToken: handle.id,
                in: workspaceId,
                onMonitor: monitor.id
            )
        }
        _ = controller.workspaceManager.setManagedFocus(
            handle.id,
            in: workspaceId,
            onMonitor: monitor.id
        )
        focusRecorder.focusedTokens.removeAll()
    }
}

extension WorkspaceMoveFocusBehaviorTests {
    private func makeNiriColumnFixture(
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture,
        windowIdOffset: Int
    ) throws -> NiriColumnFixture {
        let fallback = try addManagedWindow(
            pid: 488_003,
            windowId: windowIdOffset + 1,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let selected = try addManagedWindow(
            pid: 488_003,
            windowId: windowIdOffset + 2,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        let stacked = try addManagedWindow(
            pid: 488_003,
            windowId: windowIdOffset + 3,
            to: sourceWorkspaceId,
            fixture: fixture
        )
        XCTAssertTrue(
            fixture.controller.niriLayoutHandler.consumeOrExpelWindow(
                handle: stacked,
                direction: .left
            ).didMutate
        )
        try select(selected, in: sourceWorkspaceId, fixture: fixture)
        return NiriColumnFixture(fallback: fallback, selected: selected, stacked: stacked)
    }

    private func assertColumnMove(
        _ fixture: Fixture,
        column: NiriColumnFixture,
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        destinationWorkspaceId: WorkspaceDescriptor.ID
    ) throws {
        let manager = fixture.controller.workspaceManager
        XCTAssertEqual(manager.workspace(for: column.fallback.id), sourceWorkspaceId)
        XCTAssertEqual(manager.workspace(for: column.selected.id), destinationWorkspaceId)
        XCTAssertEqual(manager.workspace(for: column.stacked.id), destinationWorkspaceId)
        XCTAssertEqual(manager.lastFocusedToken(in: sourceWorkspaceId), column.fallback.id)
        XCTAssertEqual(manager.lastFocusedToken(in: destinationWorkspaceId), column.selected.id)

        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let selectedNode = try XCTUnwrap(engine.findNode(for: column.selected, in: destinationWorkspaceId))
        let destinationColumn = try XCTUnwrap(
            engine.findColumn(containing: selectedNode, in: destinationWorkspaceId)
        )
        XCTAssertEqual(
            Set(destinationColumn.windowNodes.map(\.token)),
            [column.selected.id, column.stacked.id]
        )
    }

    private func assertCompletion(
        _ fixture: Fixture,
        activeWorkspaceId: WorkspaceDescriptor.ID,
        expectedFocusToken: WindowToken?
    ) throws {
        let controller = fixture.controller
        let manager = controller.workspaceManager
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitor.id)?.id, activeWorkspaceId)
        XCTAssertEqual(manager.interactionMonitorId, fixture.monitor.id)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)

        let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        let action = try XCTUnwrap(pending.postLayoutActions.first)
        XCTAssertTrue(action.isCurrent(using: manager))
        action.runIfCurrent(using: manager)

        if let expectedFocusToken {
            XCTAssertEqual(fixture.focusRecorder.focusedTokens, [expectedFocusToken])
            XCTAssertEqual(manager.pendingFocusedToken, expectedFocusToken)
            XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, expectedFocusToken)
        } else {
            XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
            XCTAssertNil(manager.pendingFocusedToken)
            XCTAssertNil(manager.focusedToken)
            XCTAssertTrue(manager.isNonManagedFocusActive)
            XCTAssertNil(manager.renderableFocusToken)
            XCTAssertNil(controller.intentLedger.activeManagedRequest)
        }
    }

    private func pendingPostLayoutAction(_ fixture: Fixture) throws -> RefreshPostLayoutAction {
        let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.reason, .workspaceTransition)
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        return try XCTUnwrap(pending.postLayoutActions.first)
    }

    private func withBlockedLayoutRefreshes<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        try withBlockedLayoutRefreshes(
            controller: fixture.controller,
            affectedWorkspaceId: fixture.workspaceIds[0],
            body
        )
    }

    private func withBlockedLayoutRefreshes<T>(
        controller: WMController,
        affectedWorkspaceId: WorkspaceDescriptor.ID,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [affectedWorkspaceId]
        )
        defer {
            blocker.cancel()
            refreshController.layoutState.activeRefreshTask = nil
            refreshController.layoutState.activeRefresh = nil
            refreshController.layoutState.pendingRefresh = nil
        }
        return try body()
    }
}
