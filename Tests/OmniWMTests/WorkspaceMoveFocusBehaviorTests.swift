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
}

extension WorkspaceMoveFocusBehaviorTests {
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
        let controller = fixture.controller
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
        let controller = fixture.controller
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
                onMonitor: fixture.monitor.id
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
                onMonitor: fixture.monitor.id
            )
        }
        _ = controller.workspaceManager.setManagedFocus(
            handle.id,
            in: workspaceId,
            onMonitor: fixture.monitor.id
        )
        fixture.focusRecorder.focusedTokens.removeAll()
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
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = fixture.controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [fixture.workspaceIds[0]]
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
