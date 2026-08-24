// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

final class SettingsTOMLCodecTests: XCTestCase {
    func testDefaultTOMLOmitsUnassignableHotkeyActions() throws {
        let toml = String(
            decoding: try SettingsTOMLCodec.encode(.defaults()),
            as: UTF8.self
        )

        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            XCTAssertFalse(toml.contains(#"id = "\#(id)""#))
        }
    }

    func testTOMLRejectsUnassignableHotkeyActions() throws {
        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            let source = Data(
                (String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self) + """

                [[hotkeys]]
                binding = "Option+H"
                id = "\(id)"
                """).utf8
            )

            XCTAssertThrowsError(try SettingsTOMLCodec.decode(source)) { error in
                XCTAssertEqual(
                    error as? HotkeyBindingResolutionError,
                    .unassignableActionID(id)
                )
                XCTAssertEqual(
                    error.localizedDescription,
                    "hotkeys: \(id) cannot be assigned as a hotkey."
                )
            }
        }
    }

    func testTOMLRejectsFileMissingAKnownHotkeyAction() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        let withoutEntry = try canonicalDefaultLines { lines in
            let idIndex = try XCTUnwrap(lines.firstIndex(of: #"id = "\#(firstID)""#))
            XCTAssertEqual(lines[idIndex - 2], "[[hotkeys]]")
            lines.removeSubrange((idIndex - 2) ... idIndex)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutEntry)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .missingActionID(firstID))
        }
    }

    func testTOMLRejectsDuplicateHotkeyAction() throws {
        let firstID = try XCTUnwrap(HotkeyBindingRegistry.defaults().first?.id)
        let duplicated = try canonicalDefaultLines { lines in
            let idIndex = try XCTUnwrap(lines.firstIndex(of: #"id = "\#(firstID)""#))
            XCTAssertEqual(lines[idIndex - 2], "[[hotkeys]]")
            lines.insert(contentsOf: lines[(idIndex - 2) ... idIndex], at: idIndex + 1)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(duplicated)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID(firstID))
        }
    }

    func testTOMLRejectsMissingRequiredKey() throws {
        let withoutKey = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("followsMouse = ") })
            lines.remove(at: index)
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(withoutKey)) { error in
            guard case let DecodingError.keyNotFound(key, context) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "followsMouse")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["focus"])
        }
    }

    func testTOMLRejectsCorruptSystemHyperTrigger() throws {
        let corrupt = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("systemHyperTrigger = ") })
            lines[index] = #"systemHyperTrigger = "NotAKey""#
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(corrupt)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["general", "systemHyperTrigger"])
        }
    }

    func testTOMLRejectsCorruptHyperKeyModifiers() throws {
        let corrupt = try canonicalDefaultLines { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("hyperKeyModifiers = ") })
            lines[index] = #"hyperKeyModifiers = "Control""#
        }

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(corrupt)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["general", "hyperKeyModifiers"])
        }
    }

    func testHotkeyResolverRejectsUnknownMissingAndDuplicateActionIDs() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let complete = defaults.map { PersistedHotkeyBinding(id: $0.id, trigger: $0.binding) }
        XCTAssertEqual(try HotkeyBindingRegistry.resolve(complete).count, defaults.count)

        let withUnknown = complete + [PersistedHotkeyBinding(id: "retired.action", trigger: .unassigned)]
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withUnknown)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .unknownActionID("retired.action"))
            XCTAssertEqual(
                error.localizedDescription,
                "hotkeys: retired.action is not an action in this build."
            )
        }

        for id in ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"] {
            let withUnassignable = complete + [PersistedHotkeyBinding(id: id, trigger: .unassigned)]
            XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withUnassignable)) { error in
                XCTAssertEqual(error as? HotkeyBindingResolutionError, .unassignableActionID(id))
                XCTAssertEqual(
                    error.localizedDescription,
                    "hotkeys: \(id) cannot be assigned as a hotkey."
                )
            }
        }

        let firstID = try XCTUnwrap(defaults.first?.id)
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(Array(complete.dropFirst()))) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .missingActionID(firstID))
        }

        let withDuplicate = try complete + [XCTUnwrap(complete.first)]
        XCTAssertThrowsError(try HotkeyBindingRegistry.resolve(withDuplicate)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID(firstID))
        }
    }

    @MainActor
    func testLoadFailureReportsRejectedHotkeyActionsPrecisely() throws {
        let cases = [
            ("retired.action", "hotkeys: retired.action is not an action in this build."),
            (
                "consumeOrExpelWindowLeft",
                "hotkeys: consumeOrExpelWindowLeft cannot be assigned as a hotkey."
            )
        ]

        for (id, expectedMessage) in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OmniWMHotkeyReport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self) + """

            [[hotkeys]]
            binding = "Option+H"
            id = "\(id)"
            """
            try Data(source.utf8).write(to: directory.appendingPathComponent("settings.toml"))

            LogErrorTap.shared.reset()
            let persistence = SettingsFilePersistence(
                directory: directory,
                startWatching: false,
                deferSaves: false
            )
            _ = persistence.load()

            XCTAssertTrue(LogErrorTap.shared.dump().contains(expectedMessage))
        }
    }

    private func canonicalDefaultLines(_ mutate: (inout [String]) throws -> Void) throws -> Data {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        var lines = canonical.components(separatedBy: "\n")
        let original = lines
        try mutate(&lines)
        XCTAssertNotEqual(lines, original)
        return Data(lines.joined(separator: "\n").utf8)
    }

    func testMonitorInnerGapOverrideRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.monitorGapSettings = [
            MonitorGapSettings(
                monitorName: "Built-in",
                monitorDisplayId: 7,
                innerGap: 6,
                outerGapTop: 20
            )
        ]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertEqual(decoded.monitorGapSettings, export.monitorGapSettings)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("innerGap = 6.0"))
    }

    func testPreservingEncodeKeepsUnknownKeysInsideKnownTables() throws {
        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n"),
            ("[niri]\n", "[niri]\nfutureNiriSetting = true\n")
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("futureNiriSetting = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeUsesCanonicalDataOnlyWhenPreviousDataIsAbsent() throws {
        let export = SettingsExport.defaults()

        let rewritten = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: nil)

        XCTAssertEqual(rewritten, try SettingsTOMLCodec.encode(export))
    }

    func testPreservingEncodeRejectsEmptyPreviousData() {
        XCTAssertThrowsError(
            try SettingsTOMLCodec.encode(.defaults(), preservingUnknownKeysFrom: Data())
        ) { error in
            XCTAssertEqual(error as? SettingsTOMLCodecError, .cannotSafelyPreservePreviousData)
        }
    }

    func testPreservingEncodeRejectsMalformedPreviousData() {
        XCTAssertThrowsError(
            try SettingsTOMLCodec.encode(
                .defaults(),
                preservingUnknownKeysFrom: Data("[general\ninvalid".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? SettingsTOMLCodecError, .cannotSafelyPreservePreviousData)
        }
    }

    func testPreservingEncodeKeepsUnknownExtensionTables() throws {
        let previous = try defaultsWithSuffix(
            """

            [future]
            topValue = "top"

            [future.nested]
            flag = true
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("[future]"))
        XCTAssertTrue(rewritten.contains("topValue = \"top\""))
        XCTAssertTrue(rewritten.contains("[future.nested]"))
        XCTAssertTrue(rewritten.contains("flag = true"))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsUnknownDateTimeTypes() throws {
        let previous = try defaultsWithSuffix(
            """

            [futureTimeTypes]
            futureDate = 2026-06-15
            futureLocalDateTime = 2026-06-15T12:30:00
            futureOffset = 2026-06-15T12:30:00-04:00
            futureTime = 12:30:00
            """
        )

        var export = try SettingsTOMLCodec.decode(previous)
        export.gapSize = 24

        let rewritten = String(
            decoding: try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous),
            as: UTF8.self
        )

        XCTAssertTrue(rewritten.contains("futureDate = 2026-06-15"))
        XCTAssertTrue(rewritten.contains("futureLocalDateTime = 2026-06-15T12:30:00"))
        XCTAssertTrue(rewritten.contains("futureTime = 12:30:00"))

        let actualValue = try XCTUnwrap(tomlValue(for: "futureOffset", in: rewritten))
        let actual = try XCTUnwrap(parseOffsetDateTime(actualValue))
        let expected = try XCTUnwrap(parseOffsetDateTime("2026-06-15T12:30:00-04:00"))
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPreservingEncodeDoesNotResurrectClearedKnownOptionals() throws {
        let previous = try SettingsTOMLCodec.encode(.defaults())

        var export = try SettingsTOMLCodec.decode(previous)
        export.quakeTerminalOpacity = nil

        let rewrittenData = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        let rewritten = String(decoding: rewrittenData, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(rewrittenData)

        XCTAssertFalse(rewritten.contains("opacity = 1.0"))
        XCTAssertNil(decoded.quakeTerminalOpacity)
    }

    @MainActor
    func testSavePathPreservesUnknownKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = try defaultsWithReplacements(
            ("[general]\n", "[general]\nfutureSetting = \"keep-me\"\n")
        )
        let fileURL = directory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try previous.write(to: fileURL, options: .atomic)

        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        var export = persistence.load()
        export.gapSize = 24

        try persistence.saveImmediately(export)

        let rewritten = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(rewritten.contains("futureSetting = \"keep-me\""))
        XCTAssertTrue(rewritten.contains("size = 24.0"))
    }

    func testPreservingEncodeKeepsCanonicalBytesWhenNoUnknownKeysExist() throws {
        let export = SettingsExport.defaults()
        let canonicalData = try SettingsTOMLCodec.encode(export)

        let rewritten = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: canonicalData)

        XCTAssertEqual(rewritten, canonicalData)
    }

    func testTrackpadScrollStyleRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().trackpadScrollStyle, TrackpadScrollStyle.snap.rawValue)

        var export = SettingsExport.defaults()
        export.trackpadScrollStyle = TrackpadScrollStyle.momentum.rawValue
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("trackpadScrollStyle = \"momentum\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).trackpadScrollStyle, TrackpadScrollStyle.momentum.rawValue)
    }

    func testMouseMoveModifierRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().mouseMoveModifierKey, MouseMoveModifierKey.option.rawValue)
        XCTAssertTrue(
            String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
                .contains("mouseMoveModifierKey = \"option\"")
        )

        for modifier in [MouseMoveModifierKey.off, .controlOption] {
            var export = SettingsExport.defaults()
            export.mouseMoveModifierKey = modifier.rawValue
            let data = try SettingsTOMLCodec.encode(export)

            XCTAssertEqual(try SettingsTOMLCodec.decode(data).mouseMoveModifierKey, modifier.rawValue)
        }
    }

    @MainActor
    func testUnsupportedMouseMoveModifierFallsBackToOptionWhenApplied() throws {
        var export = SettingsExport.defaults()
        export.mouseMoveModifierKey = "shift"
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let settings = makeSettingsStore()

        settings.applyExport(decoded)

        XCTAssertEqual(settings.mouseMoveModifierKey, .option)
        XCTAssertEqual(settings.toExport().mouseMoveModifierKey, MouseMoveModifierKey.option.rawValue)
    }

    @MainActor
    func testMouseMoveModifierStoreMappingRoundTrips() {
        let source = makeSettingsStore()
        source.mouseMoveModifierKey = .controlCommand
        let destination = makeSettingsStore()

        destination.applyExport(source.toExport())

        XCTAssertEqual(destination.mouseMoveModifierKey, .controlCommand)
        XCTAssertEqual(destination.toExport().mouseMoveModifierKey, MouseMoveModifierKey.controlCommand.rawValue)
    }

    func testMalformedMouseMoveModifierTypeRejectsDecode() throws {
        let malformed = try defaultsWithReplacements(
            ("mouseMoveModifierKey = \"option\"\n", "mouseMoveModifierKey = 3\n")
        )

        XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformed))
    }

    func testWorkspaceSwipeSettingsRoundTrip() throws {
        let defaults = SettingsExport.defaults()
        XCTAssertFalse(defaults.workspaceSwipeEnabled)
        XCTAssertEqual(defaults.workspaceSwipeFingerCount, GestureFingerCount.three.rawValue)
        XCTAssertEqual(defaults.workspaceSwipeAxis, WorkspaceSwipeAxis.vertical.rawValue)

        var export = defaults
        export.workspaceSwipeEnabled = true
        export.workspaceSwipeFingerCount = GestureFingerCount.four.rawValue
        export.workspaceSwipeAxis = WorkspaceSwipeAxis.horizontal.rawValue
        let data = try SettingsTOMLCodec.encode(export)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(encoded.contains("workspaceSwipeEnabled = true"))
        XCTAssertTrue(encoded.contains("workspaceSwipeFingerCount = 4"))
        XCTAssertTrue(encoded.contains("workspaceSwipeAxis = \"horizontal\""))

        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertTrue(decoded.workspaceSwipeEnabled)
        XCTAssertEqual(decoded.workspaceSwipeFingerCount, GestureFingerCount.four.rawValue)
        XCTAssertEqual(decoded.workspaceSwipeAxis, WorkspaceSwipeAxis.horizontal.rawValue)
    }

    @MainActor
    func testNonfiniteTOMLScrollSensitivityNormalizesWhenApplied() throws {
        for literal in ["nan", "inf", "-inf"] {
            let data = try defaultsWithReplacements(
                ("scrollSensitivity = 5.0\n", "scrollSensitivity = \(literal)\n")
            )
            let export = try SettingsTOMLCodec.decode(data)
            let settings = makeSettingsStore()

            XCTAssertFalse(export.scrollSensitivity.isFinite)
            settings.applyExport(export)

            XCTAssertEqual(settings.scrollSensitivity, SettingsExport.defaults().scrollSensitivity)
            XCTAssertEqual(settings.toExport().scrollSensitivity, SettingsExport.defaults().scrollSensitivity)
        }
    }

    @MainActor
    func testProgrammaticScrollSensitivityNormalizesBeforeExport() {
        let settings = makeSettingsStore()

        settings.scrollSensitivity = .nan
        XCTAssertEqual(settings.scrollSensitivity, SettingsExport.defaults().scrollSensitivity)
        settings.scrollSensitivity = .infinity
        XCTAssertEqual(settings.scrollSensitivity, SettingsExport.defaults().scrollSensitivity)
        settings.scrollSensitivity = 0
        XCTAssertEqual(settings.scrollSensitivity, 0.1)
        settings.scrollSensitivity = 101
        XCTAssertEqual(settings.scrollSensitivity, 100)
        XCTAssertEqual(settings.toExport().scrollSensitivity, 100)
    }

    @MainActor
    func testUnsupportedWorkspaceSwipeValuesFallBackWhenApplied() throws {
        let data = try defaultsWithReplacements(
            ("workspaceSwipeFingerCount = 3\n", "workspaceSwipeFingerCount = 5\n"),
            ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = \"diagonal\"\n")
        )
        let export = try SettingsTOMLCodec.decode(data)

        XCTAssertEqual(export.workspaceSwipeFingerCount, 5)
        XCTAssertEqual(export.workspaceSwipeAxis, "diagonal")

        let settings = makeSettingsStore()
        settings.applyExport(export)

        XCTAssertEqual(settings.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(settings.workspaceSwipeAxis, .vertical)
    }

    @MainActor
    func testHorizontalWorkspaceSwipeSelectionSurvivesFingerCountCollision() {
        var export = SettingsExport.defaults()
        export.scrollGestureEnabled = true
        export.gestureFingerCount = GestureFingerCount.three.rawValue
        export.workspaceSwipeEnabled = true
        export.workspaceSwipeFingerCount = GestureFingerCount.three.rawValue
        export.workspaceSwipeAxis = WorkspaceSwipeAxis.horizontal.rawValue

        let settings = makeSettingsStore()
        settings.applyExport(export)

        XCTAssertEqual(settings.workspaceSwipeAxis, .horizontal)
        XCTAssertTrue(settings.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(settings.effectiveWorkspaceSwipeAxis, .vertical)

        settings.workspaceSwipeFingerCount = .four

        XCTAssertEqual(settings.workspaceSwipeAxis, .horizontal)
        XCTAssertFalse(settings.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(settings.effectiveWorkspaceSwipeAxis, .horizontal)
    }

    func testMalformedWorkspaceSwipeTypesRejectDecode() throws {
        let replacements = [
            ("workspaceSwipeEnabled = false\n", "workspaceSwipeEnabled = \"false\"\n"),
            ("workspaceSwipeFingerCount = 3\n", "workspaceSwipeFingerCount = \"three\"\n"),
            ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = 3\n")
        ]

        for (target, replacement) in replacements {
            let malformed = try defaultsWithReplacements((target, replacement))
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(malformed))
        }
    }

    @MainActor
    func testMalformedExternalWorkspaceSwipeReloadDoesNotPartiallyApplyOrNotify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: true,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.workspaceSwipeEnabled = true
        settings.workspaceSwipeFingerCount = .four
        settings.workspaceSwipeAxis = .horizontal
        var externalReloadCount = 0
        settings.onExternalSettingsReloaded = {
            externalReloadCount += 1
        }

        let malformed = try defaultsWithReplacements(
            ("workspaceSwipeAxis = \"vertical\"\n", "workspaceSwipeAxis = 3\n")
        )
        try malformed.write(to: persistence.fileURL, options: .atomic)
        XCTAssertNil(persistence.reloadIfChanged())
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(externalReloadCount, 0)
        XCTAssertTrue(settings.workspaceSwipeEnabled)
        XCTAssertEqual(settings.workspaceSwipeFingerCount, .four)
        XCTAssertEqual(settings.workspaceSwipeAxis, .horizontal)

        let valid = try SettingsTOMLCodec.encode(.defaults())
        try valid.write(to: persistence.fileURL, options: .atomic)
        for _ in 0 ..< 200 {
            if externalReloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(externalReloadCount, 1)
        XCTAssertFalse(settings.workspaceSwipeEnabled)
        XCTAssertEqual(settings.workspaceSwipeFingerCount, .three)
        XCTAssertEqual(settings.workspaceSwipeAxis, .vertical)
    }

    func testFocusLockModifierRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().focusLockModifier, FocusLockModifier.off.rawValue)
        XCTAssertTrue(
            String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
                .contains("lockModifier = \"off\"")
        )

        var export = SettingsExport.defaults()
        export.focusLockModifier = FocusLockModifier.leftOption.rawValue
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("lockModifier = \"leftOption\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).focusLockModifier, FocusLockModifier.leftOption.rawValue)
    }

    func testFocusCrossesMonitorAtEdgeRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().focusCrossesMonitorAtEdge)

        var export = SettingsExport.defaults()
        export.focusCrossesMonitorAtEdge = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("crossesMonitorAtEdge = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).focusCrossesMonitorAtEdge)
    }

    func testMoveCrossesMonitorAtEdgeRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().moveCrossesMonitorAtEdge)

        var export = SettingsExport.defaults()
        export.moveCrossesMonitorAtEdge = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("moveCrossesMonitorAtEdge = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).moveCrossesMonitorAtEdge)
    }

    func testCursorContainmentRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().cursorContainmentEnabled)

        var export = SettingsExport.defaults()
        export.cursorContainmentEnabled = true
        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("constrainToArrangement = true"))
        XCTAssertTrue(try SettingsTOMLCodec.decode(data).cursorContainmentEnabled)
    }

    private func defaultsWithReplacements(_ replacements: (String, String)...) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        for (target, replacement) in replacements {
            toml = toml.replacingOccurrences(of: target, with: replacement)
        }
        return Data(toml.utf8)
    }

    private func defaultsWithSuffix(_ suffix: String) throws -> Data {
        var toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        toml += suffix
        toml += "\n"
        return Data(toml.utf8)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCodecTests-\(UUID().uuidString)", isDirectory: true)
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

    private func tomlValue(for key: String, in toml: String) -> String? {
        let prefix = "\(key) = "
        return toml
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func parseOffsetDateTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]

        return fractional.date(from: value) ?? wholeSeconds.date(from: value)
    }
}
