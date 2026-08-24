// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class HiddenBarSettingsTOMLTests: XCTestCase {
    func testRoundTripsAllHiddenBarFields() throws {
        var export = SettingsExport.defaults()
        export.hiddenBarEnabled = false
        export.hiddenBarHiddenBundleIDs = ["com.example.a", "com.example.b"]
        export.hiddenBarRehideIntervalSeconds = 12

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertEqual(decoded.hiddenBarEnabled, false)
        XCTAssertEqual(decoded.hiddenBarHiddenBundleIDs, ["com.example.a", "com.example.b"])
        XCTAssertEqual(decoded.hiddenBarRehideIntervalSeconds, 12)
    }

    func testEmptyBundleListRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.hiddenBarHiddenBundleIDs = []

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded.hiddenBarHiddenBundleIDs, [])
    }

    func testPopulatedBundleListSurvivesPreservingEncode() throws {
        var export = SettingsExport.defaults()
        export.hiddenBarHiddenBundleIDs = ["com.keep.me"]
        let previous = try SettingsTOMLCodec.encode(export)

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )
        XCTAssertTrue(rewritten.contains("com.keep.me"))
    }

    @MainActor
    func testApplyExportNormalizesRehideIntervalFromTOML() throws {
        let settings = makeSettingsStore()
        let cases = [
            (literal: "nan", expected: 5.0),
            (literal: "inf", expected: 5.0),
            (literal: "-inf", expected: 5.0),
            (literal: "1", expected: 2.0),
            (literal: "12", expected: 12.0),
            (literal: "31", expected: 30.0)
        ]

        for testCase in cases {
            let export = try SettingsTOMLCodec.decode(tomlWithRehideInterval(testCase.literal))
            settings.applyExport(export)

            XCTAssertEqual(
                settings.hiddenBarRehideIntervalSeconds,
                testCase.expected,
                "TOML value: \(testCase.literal)"
            )
        }
    }

    @MainActor
    func testApplyExportNormalizesHiddenBundleIDsFromTOML() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.hiddenBarHiddenBundleIDs = [
            "  com.example.first  ",
            "",
            "com.apple.systemuiserver",
            "com.example.first",
            "com.example.second"
        ]

        settings.applyExport(export)

        XCTAssertEqual(
            settings.hiddenBarHiddenBundleIDs,
            ["com.example.first", "com.example.second"]
        )
    }

    @MainActor
    func testSettingsEditsReconcileOnceExceptForDelayOnlyEdit() {
        let settings = makeSettingsStore()
        var reconciliations = 0

        HiddenBarSettingsEdits.setEnabled(true) { enabled in
            settings.hiddenBarEnabled = enabled
            reconciliations += 1
        }
        XCTAssertTrue(settings.hiddenBarEnabled)
        XCTAssertEqual(reconciliations, 1)

        reconciliations = 0
        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.example.item",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBarHiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)

        HiddenBarSettingsEdits.setHidden(
            true,
            bundleID: "com.apple.systemuiserver",
            settings: settings
        ) {
            reconciliations += 1
        }
        XCTAssertEqual(settings.hiddenBarHiddenBundleIDs, ["com.example.item"])
        XCTAssertEqual(reconciliations, 1)

        reconciliations = 0
        HiddenBarSettingsEdits.setRehideInterval(12, settings: settings)
        XCTAssertEqual(settings.hiddenBarRehideIntervalSeconds, 12)
        XCTAssertEqual(reconciliations, 0)
    }

    private func tomlWithRehideInterval(_ literal: String) throws -> Data {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.hasPrefix("rehideIntervalSeconds = ") else { return String(line) }
            return "rehideIntervalSeconds = \(literal)"
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarSettingsTests-\(UUID().uuidString)", isDirectory: true)
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
