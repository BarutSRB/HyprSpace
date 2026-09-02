// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class QuakeTerminalAppearanceSettingsTests: XCTestCase {
    func testBackgroundEffectDefaultsToStandardBlur() {
        XCTAssertEqual(SettingsExport.defaults().quakeTerminalBackgroundEffect, .standardBlur)
    }

    func testBackgroundEffectGhosttyValues() {
        XCTAssertEqual(QuakeTerminalBackgroundEffect.standardBlur.ghosttyBackgroundBlurValue, "false")
        XCTAssertEqual(QuakeTerminalBackgroundEffect.glassRegular.ghosttyBackgroundBlurValue, "macos-glass-regular")
        XCTAssertEqual(QuakeTerminalBackgroundEffect.glassClear.ghosttyBackgroundBlurValue, "macos-glass-clear")
    }

    func testBackgroundBlurDefaultsToOff() {
        let defaults = SettingsExport.defaults()

        XCTAssertEqual(
            defaults.quakeTerminalBackgroundBlurRadius,
            QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
    }

    func testNormalizedBackgroundBlurRadiusClampsToSupportedRange() {
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(-30), 0)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(0), 0)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(20), 20)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(1000), 100)
    }

    func testGhosttyGlassDisablesNumericBackgroundBlur() {
        XCTAssertEqual(
            QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(40, glassEffectActive: true),
            0
        )
        XCTAssertEqual(
            QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(40, glassEffectActive: false),
            40
        )
    }

    func testBackgroundBlurIsOnlyVisibleThroughATranslucentTerminal() {
        let policy = QuakeTerminalAppearancePolicy.self

        XCTAssertFalse(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 0, opacity: 1.0))
        XCTAssertFalse(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 20, opacity: 0.85))
        XCTAssertTrue(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 20, opacity: 1.0))
    }

    func testRoundTripsBackgroundBlurRadiusInQuakeTerminalTable() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminalBackgroundBlurRadius = 35

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[quakeTerminal]"))
        XCTAssertTrue(toml.contains("backgroundBlurRadius = 35"))
        XCTAssertEqual(decoded.quakeTerminalBackgroundBlurRadius, 35)
    }

    func testRoundTripsEveryBackgroundEffectInQuakeTerminalTable() throws {
        for effect in QuakeTerminalBackgroundEffect.allCases {
            var export = SettingsExport.defaults()
            export.quakeTerminalBackgroundEffect = effect

            let data = try SettingsTOMLCodec.encode(export)
            let toml = String(decoding: data, as: UTF8.self)
            let decoded = try SettingsTOMLCodec.decode(data)

            XCTAssertTrue(toml.contains("backgroundEffect = \"\(effect.rawValue)\""))
            XCTAssertEqual(decoded.quakeTerminalBackgroundEffect, effect)
        }
    }

    @MainActor
    func testConfigWithoutBackgroundBlurRadiusDecodesToOff() throws {
        let defaults = SettingsExport.defaults()
        let toml = String(decoding: try SettingsTOMLCodec.encode(defaults), as: UTF8.self)
        let stripped = removingValue(in: toml, table: "quakeTerminal", key: "backgroundBlurRadius")

        let decoded = try SettingsTOMLCodec.decode(Data(stripped.utf8))
        XCTAssertNil(decoded.quakeTerminalBackgroundBlurRadius)

        let settings = makeSettingsStore()
        settings.applyExport(decoded)
        XCTAssertEqual(
            settings.quakeTerminalBackgroundBlurRadius,
            QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
    }

    func testMalformedBackgroundBlurRadiusRejectsDecode() throws {
        let defaults = String(
            decoding: try SettingsTOMLCodec.encode(SettingsExport.defaults()),
            as: UTF8.self
        )
        let malformed = replacingValue(
            in: defaults,
            table: "quakeTerminal",
            key: "backgroundBlurRadius",
            with: "\"heavy\""
        )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(malformed.utf8)))
    }

    @MainActor
    func testApplyExportClampsBackgroundBlurRadius() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.quakeTerminalBackgroundBlurRadius = -5
        settings.applyExport(export)
        XCTAssertEqual(settings.quakeTerminalBackgroundBlurRadius, 0)

        export.quakeTerminalBackgroundBlurRadius = 400
        settings.applyExport(export)
        XCTAssertEqual(settings.quakeTerminalBackgroundBlurRadius, 100)
        XCTAssertEqual(settings.toExport().quakeTerminalBackgroundBlurRadius, 100)
    }

    func testUnknownBackgroundEffectRejectsDecode() throws {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .replacingOccurrences(
                of: "backgroundEffect = \"\(QuakeTerminalBackgroundEffect.standardBlur.rawValue)\"",
                with: "backgroundEffect = \"futureGlass\""
            )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(toml.utf8))) { error in
            XCTAssertTrue(SettingsTOMLCodec.diagnosticDescription(for: error)
                .contains("quakeTerminal.backgroundEffect"))
        }
    }

    @MainActor
    func testAssigningOutOfRangeBackgroundBlurRadiusNormalizesInPlace() {
        let settings = makeSettingsStore()

        settings.quakeTerminalBackgroundBlurRadius = 250
        XCTAssertEqual(settings.quakeTerminalBackgroundBlurRadius, 100)

        settings.quakeTerminalBackgroundBlurRadius = -1
        XCTAssertEqual(settings.quakeTerminalBackgroundBlurRadius, 0)
    }

    @MainActor
    func testAutosavePersistsBackgroundBlurRadius() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeAppearanceAutosaveTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: false,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )

        settings.quakeTerminalBackgroundBlurRadius = 40
        settings.quakeTerminalBackgroundEffect = .glassClear

        let persisted = try SettingsTOMLCodec.decode(Data(contentsOf: persistence.fileURL))
        XCTAssertEqual(persisted.quakeTerminalBackgroundBlurRadius, 40)
        XCTAssertEqual(persisted.quakeTerminalBackgroundEffect, .glassClear)
    }

    private func replacingValue(
        in toml: String,
        table: String,
        key: String,
        with replacement: String
    ) -> String {
        transform(toml) { currentTable, line in
            guard currentTable == table, line.hasPrefix("\(key) = ") else { return line }
            return "\(key) = \(replacement)"
        }
    }

    private func removingValue(in toml: String, table: String, key: String) -> String {
        transform(toml) { currentTable, line in
            guard currentTable == table, line.hasPrefix("\(key) = ") else { return line }
            return nil
        }
    }

    private func transform(
        _ toml: String,
        _ operation: (_ table: String, _ line: String) -> String?
    ) -> String {
        var currentTable = ""
        return toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    currentTable = String(line.dropFirst().dropLast())
                }
                return operation(currentTable, line)
            }
            .joined(separator: "\n")
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeAppearanceSettingsTests-\(UUID().uuidString)", isDirectory: true)
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
