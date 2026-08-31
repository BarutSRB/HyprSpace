// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullRescanReadmissionTests: XCTestCase {
    func testUnchangedTrackedEntryIsNotReadmitted() throws {
        let manager = makeManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(axRef(9001, 1), pid: 9001, windowId: 1, to: workspaceId)
        let entry = try XCTUnwrap(manager.entry(for: token))

        XCTAssertFalse(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
    }

    func testChangedStateStillReadmits() throws {
        let manager = makeManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let otherWorkspaceId = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        let token = manager.addWindow(axRef(9002, 2), pid: 9002, windowId: 2, to: workspaceId)
        let entry = try XCTUnwrap(manager.entry(for: token))

        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: otherWorkspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .floating,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: true,
                appFullscreen: false
            )
        )
        XCTAssertTrue(
            LayoutRefreshController.shouldReadmitTrackedWindow(
                entry: entry,
                workspaceId: workspaceId,
                mode: .tiling,
                ruleEffects: entry.ruleEffects,
                shouldPreservePreFullscreenState: false,
                appFullscreen: true
            )
        )
    }

    private func makeManager() -> WorkspaceManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFullRescanTests-\(UUID().uuidString)", isDirectory: true)
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
