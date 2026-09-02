// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsMigrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configDirectory: URL
        let dotfilesDirectory: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testVersionZeroFixturesMigrateCustomValuesAndReportExactChanges() throws {
        let cases: [(
            name: String,
            raise: Bool,
            fullscreenGaps: Bool,
            defaultedPaths: Set<String>,
            retired: Set<String>
        )] = [
            (
                "v0.6.2-custom",
                true,
                false,
                [
                    "focus.raiseOnMouseFocus",
                    "gaps.fullscreenUsesOuterGaps",
                    "workspaceBar.hideInNativeFullscreen",
                    "scratchpads.labels"
                ],
                ["consumeOrExpelWindowLeft", "consumeOrExpelWindowRight"]
            ),
            (
                "v0.6.3-custom",
                false,
                true,
                ["workspaceBar.hideInNativeFullscreen", "scratchpads.labels"],
                []
            )
        ]

        for testCase in cases {
            let result = try SettingsTOMLCodec.decodeForLoad(legacyFixtureData(named: testCase.name))
            let migration = try XCTUnwrap(result.migration)
            let migratedData = try XCTUnwrap(result.migratedData)
            let export = result.export

            XCTAssertEqual(migration.fromVersion, 0, testCase.name)
            XCTAssertEqual(migration.toVersion, 1, testCase.name)
            XCTAssertEqual(Set(migration.defaultedPaths), testCase.defaultedPaths, testCase.name)
            XCTAssertEqual(Set(migration.addedHotkeyIDs), expectedAddedScratchpadIDs, testCase.name)
            XCTAssertEqual(
                Set(migration.retiredHotkeys.map(\.id)),
                testCase.retired,
                testCase.name
            )
            XCTAssertEqual(
                Set(migration.retiredHotkeys.flatMap(\.suggestedIDs)),
                testCase.retired.isEmpty ? [] : ["consumeWindowIntoColumn", "expelWindowFromColumn"],
                testCase.name
            )

            XCTAssertTrue(export.focusFollowsMouse, testCase.name)
            XCTAssertEqual(export.raiseOnMouseFocus, testCase.raise, testCase.name)
            XCTAssertEqual(export.gapSize, 27, testCase.name)
            XCTAssertEqual(export.fullscreenUsesOuterGaps, testCase.fullscreenGaps, testCase.name)
            XCTAssertEqual(export.defaultLayoutType, LayoutType.dwindle.rawValue, testCase.name)
            XCTAssertFalse(export.workspaceBarHideInNativeFullscreen, testCase.name)
            XCTAssertEqual(export.workspaceBarExcludedBundleIDs, ["com.example.Hidden"], testCase.name)
            XCTAssertEqual(export.scratchpadLabels, [:], testCase.name)
            XCTAssertNil(export.niriDefaultContainerPrimarySpan, testCase.name)

            let workspace = try XCTUnwrap(export.workspaceConfigurations.only, testCase.name)
            XCTAssertEqual(workspace.id.uuidString, "11111111-1111-1111-1111-111111111111", testCase.name)
            XCTAssertEqual(workspace.name, "dev", testCase.name)
            XCTAssertEqual(workspace.displayName, "Development", testCase.name)
            XCTAssertEqual(workspace.monitorAssignment, .secondary, testCase.name)
            XCTAssertEqual(workspace.layoutType, .dwindle, testCase.name)

            let rule = try XCTUnwrap(export.appRules.only, testCase.name)
            XCTAssertEqual(rule.id.uuidString, "22222222-2222-2222-2222-222222222222", testCase.name)
            XCTAssertEqual(rule.bundleId, "com.example.Terminal", testCase.name)
            XCTAssertEqual(rule.titleRegex, "^Project", testCase.name)
            XCTAssertEqual(rule.layout, .float, testCase.name)
            XCTAssertEqual(rule.assignToWorkspace, "dev", testCase.name)
            XCTAssertEqual(rule.initialContainerPrimarySpan, 0.65, testCase.name)
            XCTAssertEqual(rule.minWidth, 720, testCase.name)
            XCTAssertEqual(rule.minHeight, 480, testCase.name)

            XCTAssertEqual(hotkey("swapSplit", in: export)?.binding.humanReadableString, "Option+J", testCase.name)
            XCTAssertEqual(
                hotkey("assignFocusedWindowToScratchpad.1", in: export)?.binding.humanReadableString,
                "Option+J",
                testCase.name
            )
            XCTAssertEqual(
                hotkey("toggleScratchpad.1", in: export)?.binding.humanReadableString,
                "Option+K",
                testCase.name
            )
            for id in expectedAddedScratchpadIDs {
                XCTAssertTrue(hotkey(id, in: export)?.binding.isUnassigned == true, "\(testCase.name): \(id)")
            }
            XCTAssertNil(hotkey("assignFocusedWindowToScratchpad", in: export), testCase.name)
            XCTAssertNil(hotkey("toggleScratchpadWindow", in: export), testCase.name)
            XCTAssertNil(hotkey("consumeOrExpelWindowLeft", in: export), testCase.name)
            XCTAssertNil(hotkey("consumeOrExpelWindowRight", in: export), testCase.name)

            XCTAssertEqual(
                migration.mappedHotkeys,
                [
                    SettingsHotkeyMapping(
                        previousID: "assignFocusedWindowToScratchpad",
                        currentID: "assignFocusedWindowToScratchpad.1",
                        keptExplicitCurrentBinding: false
                    ),
                    SettingsHotkeyMapping(
                        previousID: "toggleScratchpadWindow",
                        currentID: "toggleScratchpad.1",
                        keptExplicitCurrentBinding: false
                    )
                ],
                testCase.name
            )
            let migratedText = String(decoding: migratedData, as: UTF8.self)
            XCTAssertTrue(migratedText.contains("schemaVersion = 1"), testCase.name)
            let unknownPaths = Set(SettingsTOMLCodec.unknownKeyPaths(in: migratedData))
            XCTAssertTrue(unknownPaths.contains("general.futureSetting"), testCase.name)
            XCTAssertTrue(unknownPaths.contains("futureExtension"), testCase.name)
        }
    }

    func testExplicitSlotOneBindingsWinOverLegacyAliases() throws {
        var data = try legacyFixtureData(named: "v0.6.3-custom")
        data = addingHotkey(id: "assignFocusedWindowToScratchpad.1", binding: "Option+L", to: data)
        data = addingHotkey(id: "toggleScratchpad.1", binding: "Option+M", to: data)

        let result = try SettingsTOMLCodec.decodeForLoad(data)
        let migration = try XCTUnwrap(result.migration)

        XCTAssertEqual(
            hotkey("assignFocusedWindowToScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+L"
        )
        XCTAssertEqual(
            hotkey("toggleScratchpad.1", in: result.export)?.binding.humanReadableString,
            "Option+M"
        )
        XCTAssertEqual(
            migration.mappedHotkeys,
            [
                SettingsHotkeyMapping(
                    previousID: "assignFocusedWindowToScratchpad",
                    currentID: "assignFocusedWindowToScratchpad.1",
                    keptExplicitCurrentBinding: true
                ),
                SettingsHotkeyMapping(
                    previousID: "toggleScratchpadWindow",
                    currentID: "toggleScratchpad.1",
                    keptExplicitCurrentBinding: true
                )
            ]
        )
    }

    func testVersionZeroMigrationStillRejectsUnknownAndDuplicateHotkeys() throws {
        let fixture = try legacyFixtureData(named: "v0.6.3-custom")
        let unknown = addingHotkey(id: "retired.action", binding: "Unassigned", to: fixture)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(unknown)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .unknownActionID("retired.action"))
        }

        let duplicate = addingHotkey(id: "swapSplit", binding: "Unassigned", to: fixture)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(duplicate)) { error in
            XCTAssertEqual(error as? HotkeyBindingResolutionError, .duplicateActionID("swapSplit"))
        }
    }

    func testVersionZeroMigrationStillRejectsMalformedTriggersTypesAndValues() throws {
        let fixture = String(decoding: try legacyFixtureData(named: "v0.6.3-custom"), as: UTF8.self)
        let retiredFixture = String(decoding: try legacyFixtureData(named: "v0.6.2-custom"), as: UTF8.self)
        let ignoredAlias = String(decoding: addingHotkey(
            id: "assignFocusedWindowToScratchpad.1",
            binding: "Option+L",
            to: Data(fixture.replacingOccurrences(
                of: "binding = \"Option+J\"\nid = \"assignFocusedWindowToScratchpad\"",
                with: "binding = \"NotAKey\"\nid = \"assignFocusedWindowToScratchpad\""
            ).utf8)
        ), as: UTF8.self)
        let cases = [
            (
                fixture.replacingOccurrences(
                    of: "binding = \"Option+J\"\nid = \"assignFocusedWindowToScratchpad\"",
                    with: "binding = \"NotAKey\"\nid = \"assignFocusedWindowToScratchpad\""
                ),
                "hotkeys["
            ),
            (
                fixture.replacingOccurrences(of: "followsMouse = true", with: "followsMouse = \"true\""),
                "focus.followsMouse"
            ),
            (
                fixture.replacingOccurrences(
                    of: "systemHyperTrigger = \"None\"",
                    with: "systemHyperTrigger = \"Nope\""
                ),
                "general.systemHyperTrigger"
            ),
            (
                retiredFixture.replacingOccurrences(
                    of: "binding = \"Unassigned\"\nid = \"consumeOrExpelWindowLeft\"",
                    with: "binding = \"NotAKey\"\nid = \"consumeOrExpelWindowLeft\""
                ),
                "hotkeys["
            ),
            (
                ignoredAlias,
                "hotkeys["
            )
        ]

        for (source, expectedPath) in cases {
            XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(Data(source.utf8))) { error in
                XCTAssertTrue(
                    SettingsTOMLCodec.diagnosticDescription(for: error).contains(expectedPath),
                    "Expected \(expectedPath), got \(SettingsTOMLCodec.diagnosticDescription(for: error))"
                )
            }
        }
    }

    func testCurrentSchemaIsEncodedAndFutureSchemaIsRejectedExplicitly() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        XCTAssertTrue(canonical.contains("schemaVersion = 1"))
        let future = canonical.replacingOccurrences(of: "schemaVersion = 1", with: "schemaVersion = 2")
        XCTAssertNotEqual(future, canonical)

        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(Data(future.utf8))) { error in
            XCTAssertEqual(
                error as? SettingsTOMLCodecError,
                .unsupportedSchemaVersion(found: 2, supported: 1)
            )
        }
    }

    @MainActor
    func testVersion061MigrationSucceedsWhileVersion060DirectionalResizeIsLeftUntouched() throws {
        let version061 = try legacyFixtureData(named: "v0.6.2-custom")
        let supported = try SettingsTOMLCodec.decodeForLoad(version061)
        XCTAssertNotNil(supported.migration)
        XCTAssertNotNil(supported.migratedData)

        let version060 = try version060DirectionalResizeData(from: version061)
        XCTAssertThrowsError(try SettingsTOMLCodec.decodeForLoad(version060)) { error in
            XCTAssertEqual(
                error as? HotkeyBindingResolutionError,
                .unknownActionID("resizeGrow.left")
            )
        }

        let fixture = try makeFixture("version-0.6.0")
        defer { fixture.remove() }
        try version060.write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let outcome = persistence.loadOutcome()
        guard let notice = outcome.notice,
              case let .invalidRejected(reason) = notice
        else {
            return XCTFail("Expected unsupported legacy settings to be left untouched")
        }

        XCTAssertTrue(reason.contains("resizeGrow.left"))
        XCTAssertNil(outcome.export)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), version060)
        assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preVersionOneURL(in: fixture).path))
    }

    @MainActor
    func testStartupMigrationBacksUpExactBytesAndRewritesCanonicalVersionOne() throws {
        for name in ["v0.6.2-custom", "v0.6.3-custom"] {
            let fixture = try makeFixture(name)
            defer { fixture.remove() }
            let original = try legacyFixtureData(named: name)
            try original.write(to: settingsURL(in: fixture))
            let persistence = makePersistence(in: fixture)

            let outcome = persistence.loadOutcome()
            let export = try XCTUnwrap(outcome.export)
            guard let notice = outcome.notice,
                  case let .migrated(report, backupURL) = notice
            else {
                return XCTFail("Expected migration notice for \(name)")
            }

            XCTAssertEqual(report.fromVersion, 0, name)
            XCTAssertEqual(backupURL, preVersionOneURL(in: fixture), name)
            XCTAssertEqual(try Data(contentsOf: backupURL), original, name)
            let rewritten = try Data(contentsOf: settingsURL(in: fixture))
            XCTAssertNotEqual(rewritten, original, name)
            XCTAssertEqual(try SettingsTOMLCodec.decode(rewritten), export, name)
            XCTAssertTrue(String(decoding: rewritten, as: UTF8.self).contains("schemaVersion = 1"), name)
            let unknownPaths = Set(SettingsTOMLCodec.unknownKeyPaths(in: rewritten))
            XCTAssertTrue(unknownPaths.contains("general.futureSetting"), name)
            XCTAssertTrue(unknownPaths.contains("futureExtension"), name)
            XCTAssertFalse(persistence.settingsWritesBlocked, name)
            assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
        }
    }

    @MainActor
    func testMigrationStampsIDsOnLegacyAppRulesAndPreservesTheirExtensions() throws {
        let fixture = try makeFixture("idless-app-rules")
        defer { fixture.remove() }
        let originalRule = """
        [[appRules]]
        assignToWorkspace = "dev"
        bundleId = "com.example.Terminal"
        id = "22222222-2222-2222-2222-222222222222"
        initialContainerPrimarySpan = 0.65
        layout = "float"
        minHeight = 480.0
        minWidth = 720.0
        titleRegex = "^Project"
        """
        let ambiguousRules = """
        [[appRules]]
        bundleId = "com.example.Shared"
        extensionMarker = "first"
        layout = "float"

        [[appRules]]
        bundleId = "com.example.Shared"
        extensionMarker = "second"
        layout = "tile"
        """
        let legacy = String(
            decoding: try legacyFixtureData(named: "v0.6.3-custom"),
            as: UTF8.self
        ).replacingOccurrences(of: originalRule, with: ambiguousRules)
        XCTAssertTrue(legacy.contains("extensionMarker = \"first\""))
        try Data(legacy.utf8).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)

        let outcome = persistence.loadOutcome()
        let export = try XCTUnwrap(outcome.export)
        let rewritten = try String(contentsOf: settingsURL(in: fixture), encoding: .utf8)
        let ruleSections = rewritten.components(separatedBy: "[[appRules]]")

        XCTAssertEqual(export.appRules.map(\.bundleId), ["com.example.Shared", "com.example.Shared"])
        XCTAssertEqual(export.appRules.map(\.layout), [.float, .tile])
        XCTAssertEqual(ruleSections.count, 3)
        XCTAssertTrue(ruleSections[1].contains("id = \"\(export.appRules[0].id.uuidString)\""))
        XCTAssertTrue(ruleSections[2].contains("id = \"\(export.appRules[1].id.uuidString)\""))
        XCTAssertTrue(ruleSections[1].contains("extensionMarker = \"first\""))
        XCTAssertFalse(ruleSections[1].contains("extensionMarker = \"second\""))
        XCTAssertTrue(ruleSections[2].contains("extensionMarker = \"second\""))
        XCTAssertFalse(ruleSections[2].contains("extensionMarker = \"first\""))
        let markerPaths = SettingsTOMLCodec.unknownKeyPaths(in: Data(rewritten.utf8))
            .filter { $0.hasSuffix(".extensionMarker") }
        XCTAssertEqual(
            Set(markerPaths),
            ["appRules[0].extensionMarker", "appRules[1].extensionMarker"]
        )

        var reordered = export
        reordered.appRules.reverse()
        try persistence.saveImmediately(reordered)
        let reorderedText = try String(contentsOf: settingsURL(in: fixture), encoding: .utf8)
        let reorderedSections = reorderedText.components(separatedBy: "[[appRules]]")
        let firstSection = try XCTUnwrap(reorderedSections.first {
            $0.contains(export.appRules[0].id.uuidString)
        })
        let secondSection = try XCTUnwrap(reorderedSections.first {
            $0.contains(export.appRules[1].id.uuidString)
        })
        XCTAssertTrue(firstSection.contains("extensionMarker = \"first\""))
        XCTAssertTrue(secondSection.contains("extensionMarker = \"second\""))
    }

    @MainActor
    func testMatchingMigrationBackupIsReusedAndSecondLoadIsIdempotent() throws {
        let fixture = try makeFixture("idempotent")
        defer { fixture.remove() }
        let original = try legacyFixtureData(named: "v0.6.3-custom")
        try original.write(to: settingsURL(in: fixture))
        try original.write(to: preVersionOneURL(in: fixture))
        let originalBackupInode = try fileInode(at: preVersionOneURL(in: fixture))
        let persistence = makePersistence(in: fixture)

        let first = persistence.loadOutcome()
        guard let firstNotice = first.notice,
              case let .migrated(_, backupURL) = firstNotice
        else {
            return XCTFail("Expected migration notice")
        }
        XCTAssertEqual(backupURL, preVersionOneURL(in: fixture))
        let rewritten = try Data(contentsOf: settingsURL(in: fixture))
        let rewrittenInode = try fileInode(at: settingsURL(in: fixture))

        let second = persistence.loadOutcome()

        XCTAssertNil(second.notice)
        XCTAssertEqual(second.export, first.export)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), rewritten)
        XCTAssertEqual(try fileInode(at: settingsURL(in: fixture)), rewrittenInode)
        XCTAssertEqual(try fileInode(at: preVersionOneURL(in: fixture)), originalBackupInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preVersionOneURL(in: fixture, index: 1).path))
    }

    @MainActor
    func testLiveMigrationNotifiesOnceAndSuppressesCanonicalSelfWrite() async throws {
        let fixture = try makeFixture("live")
        defer { fixture.remove() }
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = SettingsFilePersistence(
            directory: fixture.configDirectory,
            startWatching: true,
            deferSaves: false
        )
        XCTAssertNil(persistence.loadOutcome().notice)
        var outcomes: [SettingsFileLoadOutcome] = []
        persistence.setExternalChangeHandler { outcome in
            outcomes.append(outcome)
        }
        let legacy = try legacyFixtureData(named: "v0.6.3-custom")

        try legacy.write(to: settingsURL(in: fixture), options: .atomic)
        for _ in 0 ..< 200 {
            if !outcomes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(outcomes.count, 1)
        let outcome = try XCTUnwrap(outcomes.only)
        guard let notice = outcome.notice,
              case let .migrated(report, backupURL) = notice
        else {
            return XCTFail("Expected migrated live-reload outcome")
        }
        XCTAssertEqual(report.fromVersion, 0)
        XCTAssertEqual(try Data(contentsOf: backupURL), legacy)
        XCTAssertEqual(backupURL, preVersionOneURL(in: fixture))
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))),
            try XCTUnwrap(outcome.export)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: preVersionOneURL(in: fixture, index: 1).path))
        assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
    }

    @MainActor
    func testMigrationUsesSecondarySlotAndExhaustionBlocksWrites() throws {
        do {
            let fixture = try makeFixture("secondary")
            defer { fixture.remove() }
            let original = try legacyFixtureData(named: "v0.6.3-custom")
            try original.write(to: settingsURL(in: fixture))
            try Data("occupied".utf8).write(to: preVersionOneURL(in: fixture))
            let persistence = makePersistence(in: fixture)

            let outcome = persistence.loadOutcome()
            guard let notice = outcome.notice,
                  case let .migrated(_, backupURL) = notice
            else {
                return XCTFail("Expected migration notice")
            }
            XCTAssertEqual(backupURL, preVersionOneURL(in: fixture, index: 1))
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertFalse(persistence.settingsWritesBlocked)
        }

        do {
            let fixture = try makeFixture("exhausted")
            defer { fixture.remove() }
            let original = try legacyFixtureData(named: "v0.6.3-custom")
            try original.write(to: settingsURL(in: fixture))
            try Data("occupied-0".utf8).write(to: preVersionOneURL(in: fixture))
            try Data("occupied-1".utf8).write(to: preVersionOneURL(in: fixture, index: 1))
            let persistence = makePersistence(in: fixture)

            let outcome = persistence.loadOutcome()
            let export = try XCTUnwrap(outcome.export)
            guard let notice = outcome.notice,
                  case let .migrationWriteBlocked(report, backupURL, reason) = notice
            else {
                return XCTFail("Expected blocked migration notice")
            }
            XCTAssertEqual(report.fromVersion, 0)
            XCTAssertNil(backupURL)
            XCTAssertTrue(reason.contains("Both pre-version-1 settings backup slots are occupied"))
            XCTAssertTrue(persistence.settingsWritesBlocked)
            XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), original)
            XCTAssertThrowsError(try persistence.saveImmediately(export)) { error in
                guard let persistenceError = error as? SettingsFilePersistenceError,
                      case .writesBlocked = persistenceError
                else {
                    return XCTFail("Expected writesBlocked, got \(error)")
                }
            }
            assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
        }
    }

    @MainActor
    func testUnsupportedFutureSchemaLeavesBytesUntouchedAndBlocksWrites() throws {
        let fixture = try makeFixture("future")
        defer { fixture.remove() }
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let future = Data(canonical.replacingOccurrences(of: "schemaVersion = 1", with: "schemaVersion = 2").utf8)
        try future.write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)

        let outcome = persistence.loadOutcome()
        guard let notice = outcome.notice,
              case let .unsupportedVersion(found, supported) = notice
        else {
            return XCTFail("Expected unsupported version notice")
        }

        XCTAssertEqual(found, 2)
        XCTAssertEqual(supported, 1)
        XCTAssertEqual(outcome.export, SettingsExport.defaults())
        XCTAssertTrue(persistence.settingsWritesBlocked)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), future)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preVersionOneURL(in: fixture).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preVersionOneURL(in: fixture, index: 1).path))
        assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
        XCTAssertThrowsError(try persistence.saveImmediately(.defaults())) { error in
            guard let persistenceError = error as? SettingsFilePersistenceError,
                  case .writesBlocked = persistenceError
            else {
                return XCTFail("Expected writesBlocked, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), future)
    }

    @MainActor
    func testSaveRaceWithFutureSchemaPublishesOneCriticalBlockAndPreservesBytes() throws {
        let fixture = try makeFixture("future-save-race")
        defer { fixture.remove() }
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let settings = makeSettings(in: fixture, persistence: persistence, autosaveEnabled: true)
        var noticeChanges = 0
        settings.onConfigNoticeChanged = { noticeChanges += 1 }
        settings.gapSize += 1
        XCTAssertEqual(noticeChanges, 0)
        let canonical = String(decoding: try Data(contentsOf: settingsURL(in: fixture)), as: UTF8.self)
        let future = Data(canonical.replacingOccurrences(
            of: "schemaVersion = 1",
            with: "schemaVersion = 2"
        ).utf8)
        try future.write(to: settingsURL(in: fixture), options: .atomic)

        settings.gapSize += 1

        guard let notice = settings.configNotice,
              case let .unsupportedVersion(found, supported) = notice
        else {
            return XCTFail("Expected unsupported-version save notice")
        }
        XCTAssertEqual(found, 2)
        XCTAssertEqual(supported, 1)
        XCTAssertTrue(settings.settingsWritesBlocked)
        XCTAssertEqual(noticeChanges, 1)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), future)
        let issues = SettingsConfigDiagnostics.issues(directoryURL: fixture.configDirectory, notice: notice)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .critical)

        settings.gapSize += 1
        XCTAssertEqual(noticeChanges, 1)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), future)
    }

    @MainActor
    func testSaveRaceWithExhaustedMigrationBackupsPublishesCriticalBlockAndPreservesBytes() throws {
        let fixture = try makeFixture("migration-save-race")
        defer { fixture.remove() }
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let settings = makeSettings(in: fixture, persistence: persistence, autosaveEnabled: true)
        var noticeChanges = 0
        settings.onConfigNoticeChanged = { noticeChanges += 1 }
        let legacy = try legacyFixtureData(named: "v0.6.3-custom")
        try legacy.write(to: settingsURL(in: fixture), options: .atomic)
        try Data("occupied-0".utf8).write(to: preVersionOneURL(in: fixture))
        try Data("occupied-1".utf8).write(to: preVersionOneURL(in: fixture, index: 1))

        settings.gapSize += 1

        guard let notice = settings.configNotice,
              case let .migrationWriteBlocked(report, backupURL, reason) = notice
        else {
            return XCTFail("Expected blocked migration save notice")
        }
        XCTAssertEqual(report.fromVersion, 0)
        XCTAssertNil(backupURL)
        XCTAssertTrue(reason.contains("Both pre-version-1 settings backup slots are occupied"))
        XCTAssertTrue(settings.settingsWritesBlocked)
        XCTAssertEqual(noticeChanges, 1)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), legacy)
        let issues = SettingsConfigDiagnostics.issues(directoryURL: fixture.configDirectory, notice: notice)
        let criticalIssues = issues.filter { $0.severity == .critical }
        XCTAssertEqual(criticalIssues.count, 1)
        guard case .settingsPersistenceBlocked = criticalIssues[0].kind else {
            return XCTFail("Expected one critical settings-persistence issue")
        }

        settings.gapSize += 1
        XCTAssertEqual(noticeChanges, 1)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), legacy)
    }

    @MainActor
    func testMalformedExternalEditClearsFutureVersionBlockWithoutChangingLiveSettings() async throws {
        let fixture = try makeFixture("future-then-malformed")
        defer { fixture.remove() }
        var initial = SettingsExport.defaults()
        initial.gapSize = 17
        let canonical = String(decoding: try SettingsTOMLCodec.encode(initial), as: UTF8.self)
        try Data(canonical.utf8).write(to: settingsURL(in: fixture))
        let persistence = SettingsFilePersistence(
            directory: fixture.configDirectory,
            startWatching: true,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: fixture.root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        var appliedReloads = 0
        var noticeChanges = 0
        settings.onExternalSettingsReloaded = {
            appliedReloads += 1
        }
        settings.onConfigNoticeChanged = {
            noticeChanges += 1
        }
        let future = Data(canonical.replacingOccurrences(
            of: "schemaVersion = 1",
            with: "schemaVersion = 2"
        ).utf8)

        try future.write(to: settingsURL(in: fixture), options: .atomic)
        for _ in 0 ..< 200 {
            if settings.settingsWritesBlocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(settings.settingsWritesBlocked)
        XCTAssertEqual(settings.gapSize, 17)
        XCTAssertEqual(appliedReloads, 0)

        let malformed = Data("[general\nmalformed".utf8)
        try malformed.write(to: settingsURL(in: fixture), options: .atomic)
        for _ in 0 ..< 200 {
            if !settings.settingsWritesBlocked,
               let notice = settings.configNotice,
               case .invalidRejected = notice
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(settings.settingsWritesBlocked)
        guard let notice = settings.configNotice, case .invalidRejected = notice else {
            return XCTFail("Expected invalid external-edit notice")
        }
        XCTAssertEqual(settings.gapSize, 17)
        XCTAssertEqual(appliedReloads, 0)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), malformed)
        assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)

        noticeChanges = 0
        settings.gapSize = 29
        settings.flushNow()
        guard let recoveredNotice = settings.configNotice,
              case let .recoveredInvalid(backupURL, _) = recoveredNotice
        else {
            return XCTFail("Expected save to publish recovered-invalid notice")
        }
        XCTAssertEqual(noticeChanges, 1)
        XCTAssertEqual(backupURL, corruptURL(in: fixture, index: 0))
        XCTAssertEqual(try Data(contentsOf: backupURL), malformed)
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))).gapSize,
            29
        )
    }

    @MainActor
    func testMigrationThroughSymlinkPreservesLinkTargetAndPermissions() throws {
        let fixture = try makeFixture("symlink")
        defer { fixture.remove() }
        let original = try legacyFixtureData(named: "v0.6.3-custom")
        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        try original.write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: targetURL.path)
        let originalTargetInode = try fileInode(at: targetURL)
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let persistence = makePersistence(in: fixture)

        let outcome = persistence.loadOutcome()
        guard let notice = outcome.notice,
              case let .migrated(_, backupURL) = notice
        else {
            return XCTFail("Expected migration notice")
        }

        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(backupURL, preVersionOneURL(in: fixture))
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        let targetData = try Data(contentsOf: targetURL)
        XCTAssertTrue(String(decoding: targetData, as: UTF8.self).contains("schemaVersion = 1"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(targetData), try XCTUnwrap(outcome.export))
        XCTAssertNotEqual(try fileInode(at: targetURL), originalTargetInode)
        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        assertNoCorruptFiles(in: fixture, file: #filePath, line: #line)
    }

    private var expectedAddedScratchpadIDs: Set<String> {
        Set((2 ... 10).flatMap { index in
            ["toggleScratchpad.\(index)", "assignFocusedWindowToScratchpad.\(index)"]
        })
    }

    private func hotkey(_ id: String, in export: SettingsExport) -> HotkeyBinding? {
        export.hotkeyBindings.first { $0.id == id }
    }

    private func addingHotkey(id: String, binding: String, to data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        text += "\n\n[[hotkeys]]\n"
        text += "binding = \"\(binding)\"\n"
        text += "id = \"\(id)\"\n"
        return Data(text.utf8)
    }

    private func version060DirectionalResizeData(from data: Data) throws -> Data {
        var text = String(decoding: data, as: UTF8.self)
        let replacements = [
            ("resizeGrow.horizontal", ["resizeGrow.left", "resizeGrow.right"]),
            ("resizeGrow.vertical", ["resizeGrow.up", "resizeGrow.down"]),
            ("resizeShrink.horizontal", ["resizeShrink.left", "resizeShrink.right"]),
            ("resizeShrink.vertical", ["resizeShrink.up", "resizeShrink.down"])
        ]
        for (currentID, previousIDs) in replacements {
            let current = "[[hotkeys]]\nbinding = \"Unassigned\"\nid = \"\(currentID)\""
            guard text.contains(current) else {
                throw NSError(domain: "SettingsMigrationTests", code: 1)
            }
            let previous = previousIDs.map { id in
                "[[hotkeys]]\nbinding = \"Unassigned\"\nid = \"\(id)\""
            }.joined(separator: "\n\n")
            text = text.replacingOccurrences(of: current, with: previous)
        }
        return Data(text.utf8)
    }

    private func legacyFixtureData(named name: String) throws -> Data {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: resources
            .appendingPathComponent("Fixtures/Settings", isDirectory: true)
            .appendingPathComponent("\(name).toml", isDirectory: false))
    }

    @MainActor
    private func makeSettings(
        in fixture: Fixture,
        persistence: SettingsFilePersistence,
        autosaveEnabled: Bool
    ) -> SettingsStore {
        SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: fixture.root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: autosaveEnabled
        )
    }

    private func makeFixture(_ suffix: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsMigration-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfilesDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, configDirectory: configDirectory, dotfilesDirectory: dotfilesDirectory)
    }

    @MainActor
    private func makePersistence(in fixture: Fixture) -> SettingsFilePersistence {
        SettingsFilePersistence(directory: fixture.configDirectory, startWatching: false, deferSaves: false)
    }

    private func settingsURL(in fixture: Fixture) -> URL {
        fixture.configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
    }

    private func preVersionOneURL(in fixture: Fixture, index: Int = 0) -> URL {
        fixture.configDirectory.appendingPathComponent(
            SettingsFilePersistence.preVersionOneFileNames[index],
            isDirectory: false
        )
    }

    private func corruptURL(in fixture: Fixture, index: Int) -> URL {
        fixture.configDirectory.appendingPathComponent(
            SettingsFilePersistence.corruptFileNames[index],
            isDirectory: false
        )
    }

    private func assertNoCorruptFiles(
        in fixture: Fixture,
        file: StaticString,
        line: UInt
    ) {
        for index in SettingsFilePersistence.corruptFileNames.indices {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: corruptURL(in: fixture, index: index).path),
                file: file,
                line: line
            )
        }
    }

    private func fileInode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func assertSymlink(
        at linkURL: URL,
        destination: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            destination,
            file: file,
            line: line
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
