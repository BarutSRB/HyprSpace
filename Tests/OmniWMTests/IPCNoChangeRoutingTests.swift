// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCNoChangeRoutingTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let monitor: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
    }

    func testWorkspaceSwitchesDistinguishNoChangeFromAbsentTargets() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspace(workspaceNumber: 1)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCWorkspaceRequest.focusName(target: .rawID("1"))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCWorkspaceRequest.focusName(target: .rawID("99"))), .notFound)
        XCTAssertEqual(
            fixture.router.handle(IPCWorkspaceRequest.rename(target: .rawID("1"), displayName: "")),
            .noChange
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWorkspaceRequest.rename(target: .rawID("99"), displayName: "x")),
            .notFound
        )
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspace(workspaceNumber: 7)), .notFound)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspace(workspaceNumber: 2)), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspace(workspaceNumber: 2)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceAnywhere(workspaceNumber: 2)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceBackAndForth), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)
    }

    func testWindowMovesDistinguishNoChangeFromAbsentTargets() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspace(workspaceNumber: 1)), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToMonitor(direction: .right)), .notFound)

        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(471_001), windowId: 11),
            pid: 471_001,
            windowId: 11,
            to: fixture.workspace1
        )
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(token, in: fixture.workspace1))
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, token)

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspace(workspaceNumber: 1)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspace(workspaceNumber: 7)), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToMonitor(direction: .right)), .notFound)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), fixture.workspace1)
    }

    func testSatisfiedMaintenanceCommandsReportNoChange() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.rescueOffscreenWindows), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.raiseAllFloatingWindows), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.setWorkspaceLayout(layout: .niri)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.focusMonitorNext), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.swapWorkspaceWithMonitor(direction: .left)), .notFound)
    }

    private func makeFixture() throws -> Fixture {
        let monitor = Monitor(
            id: .init(displayId: 471_000),
            displayId: 471_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "NoChange"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPCNoChangeRoutingTests-\(UUID().uuidString)", isDirectory: true)
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
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspace1 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            monitor: monitor,
            workspace1: workspace1,
            workspace2: workspace2
        )
    }
}
