// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FloatingFocusMRUTests: XCTestCase {
    func testWorkspaceFocusReturnsToTheFloatingWindowFocusedLast() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let tiled = manager.addWindow(axRef(4001, 11), pid: 4001, windowId: 11, to: workspaceId)
        let floating = manager.addWindow(
            axRef(4001, 12),
            pid: 4001,
            windowId: 12,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(tiled, in: workspaceId)
        _ = manager.rememberFocus(floating, in: workspaceId)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), floating)
    }

    func testWorkspaceFocusReturnsToTheTiledWindowWhenItWasFocusedLast() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let tiled = manager.addWindow(axRef(4002, 21), pid: 4002, windowId: 21, to: workspaceId)
        let floating = manager.addWindow(
            axRef(4002, 22),
            pid: 4002,
            windowId: 22,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(floating, in: workspaceId)
        _ = manager.rememberFocus(tiled, in: workspaceId)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), tiled)
    }

    func testRefocusingTheSameTiledWindowAfterAFloatingWindowWins() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let tiled = manager.addWindow(axRef(4005, 51), pid: 4005, windowId: 51, to: workspaceId)
        let floating = manager.addWindow(
            axRef(4005, 52),
            pid: 4005,
            windowId: 52,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(tiled, in: workspaceId)
        _ = manager.rememberFocus(floating, in: workspaceId)
        _ = manager.rememberFocus(tiled, in: workspaceId)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), tiled)
    }

    func testRefocusingTheSameFloatingWindowAfterATiledWindowWins() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let tiled = manager.addWindow(axRef(4006, 61), pid: 4006, windowId: 61, to: workspaceId)
        let floating = manager.addWindow(
            axRef(4006, 62),
            pid: 4006,
            windowId: 62,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(floating, in: workspaceId)
        _ = manager.rememberFocus(tiled, in: workspaceId)
        _ = manager.rememberFocus(floating, in: workspaceId)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), floating)
    }

    func testRemovingTheMostRecentFloatingWindowFallsBackToTheTiledWindow() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let tiled = manager.addWindow(axRef(4003, 31), pid: 4003, windowId: 31, to: workspaceId)
        let floating = manager.addWindow(
            axRef(4003, 32),
            pid: 4003,
            windowId: 32,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(tiled, in: workspaceId)
        _ = manager.rememberFocus(floating, in: workspaceId)
        _ = manager.removeWindow(pid: floating.pid, windowId: floating.windowId)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), tiled)
    }

    func testUnifiedSlotSurvivesAModeChangeOfTheRememberedWindow() {
        let manager = makeManager()
        let workspaceId = manager.workspaces[0].id
        let token = manager.addWindow(
            axRef(4004, 41),
            pid: 4004,
            windowId: 41,
            to: workspaceId,
            mode: .floating
        )

        _ = manager.rememberFocus(token, in: workspaceId)
        _ = manager.setWindowMode(.tiling, for: token)

        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: workspaceId), token)
    }

    private func makeManager() -> WorkspaceManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFloatingFocusMRUTests-\(UUID().uuidString)", isDirectory: true)
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
        return WorkspaceManager(settings: settings)
    }

    private func axRef(_ pid: pid_t, _ windowId: Int) -> AXWindowRef {
        AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
    }
}
