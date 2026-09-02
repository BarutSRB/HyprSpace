// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowMoveIPCIntegrationTests: XCTestCase {
    private final class FocusRecorder {
        var focusedTokens: [WindowToken] = []
    }

    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let workspaceIds: [WorkspaceDescriptor.ID]
        let monitor: Monitor
        let focusRecorder: FocusRecorder
    }

    func testMoveUnfocusedWindowKeepsFocusAndActiveWorkspace() throws {
        let fixture = try makeFixture(followsFocus: true)
        let focused = try addManagedWindow(pid: 489_001, windowId: 1, to: fixture.workspaceIds[0], fixture: fixture)
        let moved = try addManagedWindow(pid: 489_001, windowId: 2, to: fixture.workspaceIds[0], fixture: fixture)
        try select(focused, in: fixture.workspaceIds[0], fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            XCTAssertEqual(fixture.router.handle(moveRequest(moved, to: "2")), .executed)

            XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: moved.id), fixture.workspaceIds[1])
            XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: focused.id), fixture.workspaceIds[0])
            XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, focused.id)
            XCTAssertEqual(
                fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
                fixture.workspaceIds[0]
            )
            XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
            XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
            let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.reason, .workspaceTransition)
            XCTAssertTrue(pending.postLayoutActions.isEmpty)
        }
    }

    func testMoveFocusedWindowHonorsFollowSetting() throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(followsFocus: followsFocus)
            let fallback = try addManagedWindow(
                pid: 489_002,
                windowId: 11,
                to: fixture.workspaceIds[0],
                fixture: fixture
            )
            let moved = try addManagedWindow(pid: 489_002, windowId: 12, to: fixture.workspaceIds[0], fixture: fixture)
            try select(moved, in: fixture.workspaceIds[0], fixture: fixture)

            try withBlockedLayoutRefreshes(fixture) {
                XCTAssertEqual(fixture.router.handle(moveRequest(moved, to: "2")), .executed)
                XCTAssertEqual(
                    fixture.controller.workspaceManager.workspace(for: moved.id),
                    fixture.workspaceIds[1]
                )
                let expectedActive = followsFocus ? fixture.workspaceIds[1] : fixture.workspaceIds[0]
                XCTAssertEqual(
                    fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
                    expectedActive
                )

                let pending = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(pending.postLayoutActions.count, 1)
                let action = try XCTUnwrap(pending.postLayoutActions.first)
                XCTAssertTrue(action.isCurrent(using: fixture.controller.workspaceManager))
                action.runIfCurrent(using: fixture.controller.workspaceManager)
                XCTAssertEqual(fixture.focusRecorder.focusedTokens, [followsFocus ? moved.id : fallback.id])
            }
        }
    }

    func testMoveFromInactiveWorkspaceKeepsFocus() throws {
        let fixture = try makeFixture(followsFocus: true)
        let focused = try addManagedWindow(pid: 489_003, windowId: 21, to: fixture.workspaceIds[0], fixture: fixture)
        let moved = try addManagedWindow(pid: 489_003, windowId: 22, to: fixture.workspaceIds[1], fixture: fixture)
        try select(focused, in: fixture.workspaceIds[0], fixture: fixture)

        try withBlockedLayoutRefreshes(fixture) {
            XCTAssertEqual(fixture.router.handle(moveRequest(moved, to: "1")), .executed)
            XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: moved.id), fixture.workspaceIds[0])
            XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, focused.id)
            XCTAssertEqual(
                fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
                fixture.workspaceIds[0]
            )
            XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        }
    }

    func testMoveResultsForSatisfiedAbsentStaleAndBlockedTargets() throws {
        let fixture = try makeFixture(followsFocus: false)
        let window = try addManagedWindow(pid: 489_004, windowId: 31, to: fixture.workspaceIds[0], fixture: fixture)

        XCTAssertEqual(fixture.router.handle(moveRequest(window, to: "1")), .noChange)
        XCTAssertEqual(fixture.router.handle(moveRequest(window, to: "9")), .notFound)
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .moveToWorkspace,
                    windowId: IPCWindowOpaqueID.encode(pid: 489_004, windowId: 31, sessionToken: "other"),
                    workspaceTarget: .rawID("2")
                )
            ),
            .staleWindowId
        )
        XCTAssertEqual(
            fixture.router.handle(
                IPCWindowRequest(
                    name: .moveToWorkspace,
                    windowId: IPCWindowOpaqueID.encode(pid: 489_004, windowId: 99, sessionToken: "test"),
                    workspaceTarget: .rawID("2")
                )
            ),
            .notFound
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWindowRequest(name: .moveToWorkspace, windowId: opaqueId(window))),
            .invalidArguments
        )

        fixture.controller.toggleOverview()
        defer {
            if fixture.controller.isOverviewOpen() {
                fixture.controller.toggleOverview()
            }
        }
        XCTAssertEqual(fixture.router.handle(moveRequest(window, to: "2")), .ignoredOverview)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: window.id), fixture.workspaceIds[0])
    }

    private func moveRequest(_ handle: WindowHandle, to rawWorkspaceID: String) -> IPCWindowRequest {
        IPCWindowRequest(
            name: .moveToWorkspace,
            windowId: opaqueId(handle),
            workspaceTarget: .rawID(rawWorkspaceID)
        )
    }

    private func opaqueId(_ handle: WindowHandle) -> String {
        IPCWindowOpaqueID.encode(pid: handle.id.pid, windowId: handle.id.windowId, sessionToken: "test")
    }

    private func makeFixture(followsFocus: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowMoveIPCIntegrationTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.defaultLayoutType = .niri
        settings.workspaceConfigurations = ["1", "2"].map { name in
            WorkspaceConfiguration(name: name, monitorAssignment: .main, layoutType: .niri)
        }

        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 489_000),
            displayId: 489_000,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Window Move IPC Tests"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()

        let workspaceIds = try ["1", "2"].map { name in
            try XCTUnwrap(controller.workspaceManager.workspaceId(for: name, createIfMissing: false))
        }
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceIds[0], on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            workspaceIds: workspaceIds,
            monitor: monitor,
            focusRecorder: focusRecorder
        )
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
            _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        return try XCTUnwrap(controller.workspaceManager.handle(for: token))
    }

    private func select(
        _ handle: WindowHandle,
        in workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws {
        let controller = fixture.controller
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
        _ = controller.workspaceManager.setManagedFocus(handle.id, in: workspaceId, onMonitor: fixture.monitor.id)
        fixture.focusRecorder.focusedTokens.removeAll()
    }

    private func withBlockedLayoutRefreshes<T>(_ fixture: Fixture, _ body: () throws -> T) rethrows -> T {
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
