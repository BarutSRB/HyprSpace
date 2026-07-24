// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarNotchModeSettingsTests: XCTestCase {
    func testNotchModeRoundTrips() throws {
        XCTAssertEqual(
            SettingsExport.defaults().workspaceBarNotchMode,
            WorkspaceBarNotchMode.moveBelowMenuBar.rawValue
        )

        var export = SettingsExport.defaults()
        export.workspaceBarNotchMode = WorkspaceBarNotchMode.splitActiveLeft.rawValue
        export.workspaceBarNotchActiveZoneWidth = 220
        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(toml.contains("notchMode = \"splitActiveLeft\""))
        XCTAssertTrue(toml.contains("notchActiveZoneWidth = 220"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.workspaceBarNotchMode, WorkspaceBarNotchMode.splitActiveLeft.rawValue)
        XCTAssertEqual(decoded.workspaceBarNotchActiveZoneWidth, 220)
    }

    func testNotchModeRecoversToDefaultWhenMissing() throws {
        let withoutKeys = try defaultsWithReplacements(
            ("notchMode = \"moveBelowMenuBar\"\n", ""),
            ("notchActiveZoneWidth = 180.0\n", "")
        )

        let decoded = try SettingsTOMLCodec.decode(withoutKeys)
        XCTAssertEqual(decoded.workspaceBarNotchMode, WorkspaceBarNotchMode.moveBelowMenuBar.rawValue)
        XCTAssertEqual(decoded.workspaceBarNotchActiveZoneWidth, 180)
    }

    func testMonitorOverrideNotchModeRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(
                monitorName: "Built-in",
                notchMode: .splitActiveRight,
                notchActiveZoneWidth: 240
            ),
            MonitorBarSettings(monitorName: "External")
        ]
        let data = try SettingsTOMLCodec.encode(export)

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.monitorBarSettings.count, 2)
        XCTAssertEqual(decoded.monitorBarSettings[0].notchMode, .splitActiveRight)
        XCTAssertEqual(decoded.monitorBarSettings[0].notchActiveZoneWidth, 240)
        XCTAssertNil(decoded.monitorBarSettings[1].notchMode)
        XCTAssertNil(decoded.monitorBarSettings[1].notchActiveZoneWidth)
    }

    func testLegacyNotchAwareKeySurfacesAsUnknownKey() throws {
        let withLegacyKey = try defaultsWithReplacements(
            ("notchMode = \"moveBelowMenuBar\"", "notchMode = \"moveBelowMenuBar\"\nnotchAware = true")
        )

        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: withLegacyKey).contains("workspaceBar.notchAware"))
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(withLegacyKey).workspaceBarNotchMode,
            WorkspaceBarNotchMode.moveBelowMenuBar.rawValue
        )
    }

    @MainActor
    func testApplyExportClampsNotchActiveZoneWidth() {
        let settings = makeSettingsStore()

        var export = SettingsExport.defaults()
        export.workspaceBarNotchActiveZoneWidth = 12
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarNotchActiveZoneWidth, 100)

        export.workspaceBarNotchActiveZoneWidth = 9999
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarNotchActiveZoneWidth, 400)

        export.workspaceBarNotchMode = "bogus"
        settings.applyExport(export)
        XCTAssertEqual(settings.workspaceBarNotchMode, .moveBelowMenuBar)
    }

    @MainActor
    func testResolvedBarSettingsMergesNotchOverrides() {
        let settings = makeSettingsStore()
        settings.workspaceBarNotchMode = .splitActiveLeft
        settings.workspaceBarNotchActiveZoneWidth = 180
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            name: "Built-in"
        )

        let global = settings.resolvedBarSettings(for: monitor)
        XCTAssertEqual(global.notchMode, .splitActiveLeft)
        XCTAssertEqual(global.notchActiveZoneWidth, 180)

        settings.updateBarSettings(
            MonitorBarSettings(
                monitorName: "Built-in",
                monitorDisplayId: 7,
                notchMode: .off,
                notchActiveZoneWidth: 300
            ),
            for: monitor
        )

        let resolved = settings.resolvedBarSettings(for: monitor)
        XCTAssertEqual(resolved.notchMode, .off)
        XCTAssertEqual(resolved.notchActiveZoneWidth, 300)
    }

    private func defaultsWithReplacements(_ replacements: (String, String)...) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for (target, replacement) in replacements {
            toml = toml.replacingOccurrences(of: target, with: replacement)
        }
        return Data(toml.utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMNotchModeTests-\(UUID().uuidString)", isDirectory: true)
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
