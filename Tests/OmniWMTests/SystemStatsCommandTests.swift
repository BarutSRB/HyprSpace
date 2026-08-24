// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class SystemStatsCommandTests: XCTestCase {
    func testToggleSystemStatsSpecRegistered() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .toggleSystemStats))

        XCTAssertEqual(spec.id, "toggleSystemStats")
        XCTAssertEqual(spec.title, "Toggle System Stats")
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.ipcCommandName, .toggleSystemStats)
        XCTAssertNotNil(spec.ipcDescriptor)
    }

    func testActionSpecIDsUnique() {
        let ids = ActionCatalog.allSpecs().map(\.id)

        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testToggleSystemStatsNameMapping() {
        XCTAssertEqual(IPCCommandRequest.toggleSystemStats.name, .toggleSystemStats)
    }

    func testToggleSystemStatsJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(IPCCommandRequest.toggleSystemStats)

        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), .toggleSystemStats)
    }

    func testToggleSystemStatsManifestResolves() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["toggle-system-stats"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .toggleSystemStats })

        XCTAssertEqual(descriptor.commandWords, ["toggle-system-stats"])
        XCTAssertEqual(try IPCCommandRequest(name: descriptor.name, argumentValues: []), .toggleSystemStats)
    }

    @MainActor
    func testRouterExecutesToggleSystemStats() {
        let controller = WMController(settings: makeSettingsStore())
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.toggleSystemStats), .executed)
    }

    func testSystemStatsButtonSettingRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().workspaceBarSystemStatsButton)

        var export = SettingsExport.defaults()
        export.workspaceBarSystemStatsButton = true
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("systemStatsButton = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).workspaceBarSystemStatsButton)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSystemStatsTests-\(UUID().uuidString)", isDirectory: true)
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
