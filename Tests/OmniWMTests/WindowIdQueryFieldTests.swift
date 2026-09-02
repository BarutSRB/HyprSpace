// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowIdQueryFieldTests: XCTestCase {
    func testWindowsQueryIncludesWindowIdByDefaultAndHonorsFieldToken() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "WindowIdQueryFieldTests")
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Window Id"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = WindowToken(pid: 880_140, windowId: 880_132)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "window-id-tests")
        router.windowOrderedInProvider = { _ in true }

        let defaultWindow = try XCTUnwrap(router.windowsResult(IPCQueryRequest(name: .windows)).windows.first)
        XCTAssertEqual(defaultWindow.windowId, 880_132)
        XCTAssertTrue(String(decoding: try IPCWire.makeEncoder().encode(defaultWindow), as: UTF8.self)
            .contains("\"windowId\":880132"))

        let pidOnly = try XCTUnwrap(router.windowsResult(IPCQueryRequest(name: .windows, fields: ["pid"])).windows
            .first)
        XCTAssertNil(pidOnly.windowId)
        XCTAssertEqual(pidOnly.pid, 880_140)

        let windowIdOnly = try XCTUnwrap(
            router.windowsResult(IPCQueryRequest(name: .windows, fields: ["window-id"])).windows.first
        )
        XCTAssertEqual(windowIdOnly.windowId, 880_132)
        XCTAssertNil(windowIdOnly.pid)
        XCTAssertTrue(IPCAutomationManifest.windowFieldCatalog.contains("window-id"))
    }
}
