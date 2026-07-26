// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarIconOverrideUITests: XCTestCase {
    func testSelectionStoresStandardizedAbsolutePathAndRefreshesResolver() {
        let settings = makeSettingsStore()
        var refreshes: [Bool] = []
        let selectedURL = URL(fileURLWithPath: "/tmp/OmniWMIcons/../custom.icns")

        XCTAssertTrue(
            WorkspaceBarIconOverrideEdits.applySelection(
                selectedURL,
                bundleID: "  com.example.App \n",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )
        XCTAssertEqual(
            settings.workspaceBarIconOverrideValue(for: "COM.EXAMPLE.APP"),
            "/tmp/custom.icns"
        )
        XCTAssertEqual(refreshes, [true])
    }

    func testBundledResourceSelectionStoresLocatorAndRefreshesResolver() {
        let settings = makeSettingsStore()
        var refreshes: [Bool] = []

        XCTAssertTrue(
            WorkspaceBarIconOverrideEdits.applySource(
                .bundleResource("AppIconDark"),
                bundleID: " com.cmuxterm.app ",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )

        XCTAssertEqual(
            settings.workspaceBarIconOverrideValue(for: "COM.CMUXTERM.APP"),
            "bundle-resource:AppIconDark"
        )
        XCTAssertEqual(refreshes, [true])
    }

    func testReselectingSamePathForcesReloadWithoutMutatingSettings() {
        let settings = makeSettingsStore()
        let selectedURL = URL(fileURLWithPath: "/tmp/custom.icns")
        XCTAssertTrue(
            settings.setWorkspaceBarIconOverride(
                selectedURL.standardizedFileURL.path,
                for: "com.example.App"
            )
        )
        let before = settings.workspaceBarIconOverrides
        var refreshes: [Bool] = []

        XCTAssertFalse(
            WorkspaceBarIconOverrideEdits.applySelection(
                selectedURL,
                bundleID: "COM.EXAMPLE.APP",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )

        XCTAssertEqual(settings.workspaceBarIconOverrides, before)
        XCTAssertEqual(refreshes, [true])
    }

    func testCancelledAndInvalidSelectionsDoNotMutateOrRefresh() {
        let settings = makeSettingsStore()
        var refreshes: [Bool] = []

        XCTAssertFalse(
            WorkspaceBarIconOverrideEdits.applySelection(
                nil,
                bundleID: "com.example.App",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )
        XCTAssertFalse(
            WorkspaceBarIconOverrideEdits.applySelection(
                URL(fileURLWithPath: "/tmp/custom.icns"),
                bundleID: " \n",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )

        XCTAssertTrue(settings.workspaceBarIconOverrides.isEmpty)
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testRemoveRefreshesOnlyWhenOverrideExists() {
        let settings = makeSettingsStore()
        XCTAssertTrue(
            settings.setWorkspaceBarIconOverride(
                "/tmp/custom.icns",
                for: "com.example.App"
            )
        )
        var refreshes: [Bool] = []

        XCTAssertTrue(
            WorkspaceBarIconOverrideEdits.remove(
                bundleID: "COM.EXAMPLE.APP",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )
        XCTAssertFalse(
            WorkspaceBarIconOverrideEdits.remove(
                bundleID: "com.example.App",
                settings: settings,
                refresh: { refreshes.append($0) }
            )
        )

        XCTAssertTrue(settings.workspaceBarIconOverrides.isEmpty)
        XCTAssertEqual(refreshes, [false])
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMWorkspaceBarIconOverrideUITests-\(UUID().uuidString)",
                isDirectory: true
            )
        return SettingsStore(
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
    }
}
