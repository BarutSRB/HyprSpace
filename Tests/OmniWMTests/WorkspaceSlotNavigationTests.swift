// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WorkspaceSlotNavigationTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let monitorA: Monitor
        let monitorB: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
        let workspace3: WorkspaceDescriptor.ID

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var navigation: WorkspaceNavigationHandler {
            controller.workspaceNavigationHandler
        }
    }

    func testSlotResolvesPositionInInteractionMonitorOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.navigation.workspaceSlot(1)?.id, fixture.workspace1)
        XCTAssertEqual(fixture.navigation.workspaceSlot(2)?.id, fixture.workspace3)
        XCTAssertNil(fixture.navigation.workspaceSlot(3))
        XCTAssertNil(fixture.navigation.workspaceSlot(0))

        _ = fixture.manager.setInteractionMonitor(fixture.monitorB.id)
        XCTAssertEqual(fixture.navigation.workspaceSlot(1)?.id, fixture.workspace2)
        XCTAssertNil(fixture.navigation.workspaceSlot(2))
    }

    func testSwitchWorkspaceSlotActivatesWorkspaceOnInteractionMonitorOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertTrue(fixture.navigation.switchWorkspaceSlot(2))
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorB.id)?.id, fixture.workspace2)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace3)

        XCTAssertFalse(fixture.navigation.switchWorkspaceSlot(2))
        XCTAssertFalse(fixture.navigation.switchWorkspaceSlot(3))
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)

        fixture.navigation.switchWorkspace(index: 1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
    }

    func testMoveFocusedWindowToSlotUsesInteractionMonitorOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        XCTAssertFalse(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 2))

        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertTrue(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 2))
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
        XCTAssertFalse(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 3))
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
    }

    func testHotkeyCommandsRouteToSlotNavigation() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.moveToWorkspaceSlot(2)), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.switchWorkspaceSlot(2)), .executed)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
    }

    func testRouterDistinguishesInvalidAbsentAndUnchangedSlots() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceSlot(slotNumber: 0)), .invalidArguments)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceSlot(slotNumber: 9)), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceSlot(slotNumber: 1)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.switchWorkspaceSlot(slotNumber: 2)), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace3)

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspaceSlot(slotNumber: 0)), .invalidArguments)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspaceSlot(slotNumber: 1)), .notFound)

        let token = addFocusedWindow(to: fixture.workspace3, in: fixture)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspaceSlot(slotNumber: 2)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspaceSlot(slotNumber: 9)), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.moveToWorkspaceSlot(slotNumber: 1)), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace1)
    }

    private func addFocusedWindow(to workspaceId: WorkspaceDescriptor.ID, in fixture: Fixture) -> WindowToken {
        let token = fixture.manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(473_001), windowId: 11),
            pid: 473_001,
            windowId: 11,
            to: workspaceId
        )
        fixture.manager.withEngineMutationScope(in: workspaceId) {
            _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        XCTAssertTrue(fixture.manager.setManagedFocus(token, in: workspaceId))
        XCTAssertEqual(fixture.manager.selectedManagedToken, token)
        return token
    }

    private func makeFixture() throws -> Fixture {
        let monitorA = makeMonitor(displayId: 473_100, name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let monitorB = makeMonitor(
            displayId: 473_101,
            name: "B",
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMWorkspaceSlotNavigationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
                monitorAssignment: .specificDisplay(OutputId(from: monitorA)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitorB)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: monitorA)),
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
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitorA, monitorB])
        manager.applySettings()
        let workspace1 = try XCTUnwrap(manager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(manager.workspaceId(named: "2"))
        let workspace3 = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(workspace1, on: monitorA.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(workspace2, on: monitorB.id, updateInteractionMonitor: false))
        _ = manager.setInteractionMonitor(monitorA.id)
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            monitorA: monitorA,
            monitorB: monitorB,
            workspace1: workspace1,
            workspace2: workspace2,
            workspace3: workspace3
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }
}
