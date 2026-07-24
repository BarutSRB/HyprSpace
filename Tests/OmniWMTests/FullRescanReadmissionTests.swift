// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullRescanReadmissionTests: XCTestCase {
    func testNewlyCreatedFloatingWindowTakesFocus() {
        // A user-created floating window (create-placement context present) must be focused so the
        // post-admission focus recovery does not steal focus back to the previously focused window.
        XCTAssertTrue(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .floating,
                hasCreatePlacementContext: true
            )
        )
    }

    func testExistingOrTiledOrDiscoveredWindowsDoNotStealFocus() {
        // Already-tracked floating window seen again by a rescan must not re-grab focus.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: false,
                trackedMode: .floating,
                hasCreatePlacementContext: true
            )
        )
        // New tiled windows are focused through the layout path, not this floating fast path.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .tiling,
                hasCreatePlacementContext: true
            )
        )
        // A floating window discovered during startup enumeration has no create-placement context
        // and must not yank focus from wherever the user currently is.
        XCTAssertFalse(
            LayoutRefreshController.shouldFocusNewlyAdmittedFloatingWindow(
                isNewEntry: true,
                trackedMode: .floating,
                hasCreatePlacementContext: false
            )
        )
    }

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
