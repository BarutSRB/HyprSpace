// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class CGSPhantomEventGuardTests: XCTestCase {
    func testCGSDestroyForParkedTrackedWindowIsIgnored() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_001), windowId: 941_101),
            pid: 941_001, windowId: 941_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: token
        )

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(token.windowId), spaceId: 0)
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNotNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSDestroyForLiveTrackedWindowIsIgnored() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let windowId: UInt32 = 945_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(945_001), windowId: Int(windowId)),
            pid: 945_001, windowId: Int(windowId), to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: token.pid,
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNotNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCloseRemovesParkedTrackedWindowDespiteStaleWindowServerInfo() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let windowId: UInt32 = 946_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(946_001), windowId: Int(windowId)),
            pid: 946_001, windowId: Int(windowId), to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            for: token
        )
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: token.pid,
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        }

        controller.axEventHandler.handleCGSEvent(.closed(windowId: windowId))

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))

        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCreateForTrackedWindowVerifiesIdentityWithoutMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(942_001), windowId: 942_101),
            pid: 942_001, windowId: 942_101, to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let entryBefore = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        controller.axEventHandler.handleCGSEvent(
            .created(windowId: UInt32(token.windowId), spaceId: 0)
        )

        let entryAfter = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(CFEqual(entryAfter.axRef.element, entryBefore.axRef.element))
        XCTAssertEqual(entryAfter.workspaceId, entryBefore.workspaceId)
        XCTAssertEqual(entryAfter.mode, entryBefore.mode)
        XCTAssertEqual(entryAfter.hiddenState, entryBefore.hiddenState)
        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("create_seen window=\(token.windowId)"))
        XCTAssertFalse(trace.contains("create_retry_scheduled"))
        XCTAssertFalse(trace.contains("admission_rejected"))
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: token.windowId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSCreateForOwnProcessWindowSchedulesNoRetry() throws {
        let controller = Self.controller()
        let windowId: UInt32 = 943_101
        controller.axEventHandler.windowInfoProvider = { id in
            guard id == windowId else { return nil }
            return WindowServerInfo(
                id: id,
                pid: getpid(),
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 400, height: 300)
            )
        }

        controller.axEventHandler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))

        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("create_seen window=\(windowId)"))
        XCTAssertFalse(trace.contains("create_retry_scheduled"))
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)))
        XCTAssertNil(controller.workspaceManager.entry(forWindowId: Int(windowId)))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testCGSDestroyForUnmanagedWindowDoesNotScheduleFullRescan() {
        let controller = Self.controller()
        let windowId: UInt32 = 944_101
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: windowId, spaceId: 0)
        )

        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    private static func controller() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCGSPhantomTests-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
