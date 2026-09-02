// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ConfigDiagnosticsTests: XCTestCase {
    @MainActor
    func testDefaultConfigHasNoUnknownKeys() throws {
        let data = try SettingsTOMLCodec.encode(makeExport())
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    @MainActor
    func testBogusKeyDetected() throws {
        let base = String(decoding: try SettingsTOMLCodec.encode(makeExport()), as: UTF8.self)
        let data = Data(("bogusKey = 1\n" + base).utf8)
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).contains("bogusKey"))
    }

    func testEmptyDataHasNoUnknownKeys() {
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: Data()), [])
    }

    func testRecoveryIssuePersistsUntilBothBackupSlotsAreAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMConfigRecoveryDiag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent(SettingsFilePersistence.corruptFileName)
        let secondURL = directory.appendingPathComponent(SettingsFilePersistence.secondaryCorruptFileName)
        try Data([0x01]).write(to: firstURL)
        XCTAssertEqual(SettingsConfigDiagnostics.issues(directoryURL: directory).map(\.kind), [.settingsFileCorrupt])

        try Data([0x02]).write(to: secondURL)
        XCTAssertEqual(SettingsConfigDiagnostics.issues(directoryURL: directory).map(\.kind), [.settingsFileCorrupt])

        try FileManager.default.removeItem(at: firstURL)
        XCTAssertEqual(SettingsConfigDiagnostics.issues(directoryURL: directory).map(\.kind), [.settingsFileCorrupt])

        try FileManager.default.removeItem(at: secondURL)
        XCTAssertTrue(SettingsConfigDiagnostics.issues(directoryURL: directory).isEmpty)
    }

    func testRecoveryIssueDetectsDanglingBackupSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMConfigRecoverySymlinkDiag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backupURL = directory.appendingPathComponent(SettingsFilePersistence.corruptFileName)
        let missingURL = directory.appendingPathComponent("missing.toml")
        try FileManager.default.createSymbolicLink(at: backupURL, withDestinationURL: missingURL)

        XCTAssertEqual(SettingsConfigDiagnostics.issues(directoryURL: directory).map(\.kind), [.settingsFileCorrupt])
    }

    func testInformationalConfigNoticesDisappearWhenBackupIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMConfigNoticeLifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = SettingsMigrationReport(
            fromVersion: 0,
            toVersion: 1,
            defaultedPaths: [],
            addedHotkeyIDs: [],
            mappedHotkeys: [],
            retiredHotkeys: []
        )
        let migrationBackup = directory.appendingPathComponent(SettingsFilePersistence.preVersionOneFileName)
        try Data([0x01]).write(to: migrationBackup)
        let migrated = SettingsConfigNotice.migrated(report: report, backupURL: migrationBackup)

        XCTAssertEqual(SettingsConfigDiagnostics.issues(
            directoryURL: directory,
            notice: migrated
        ).map(\.kind), [.settingsMigrated(report: report, backupURL: migrationBackup)])
        try FileManager.default.removeItem(at: migrationBackup)
        XCTAssertTrue(SettingsConfigDiagnostics.issues(directoryURL: directory, notice: migrated).isEmpty)

        let recoveryBackup = directory.appendingPathComponent(SettingsFilePersistence.corruptFileName)
        try Data([0x02]).write(to: recoveryBackup)
        let recovered = SettingsConfigNotice.recoveredInvalid(backupURL: recoveryBackup, reason: "invalid")
        XCTAssertEqual(SettingsConfigDiagnostics.issues(
            directoryURL: directory,
            notice: recovered
        ).map(\.kind), [.settingsRecovered(reason: "invalid", backupURL: recoveryBackup)])
        try FileManager.default.removeItem(at: recoveryBackup)
        XCTAssertTrue(SettingsConfigDiagnostics.issues(directoryURL: directory, notice: recovered).isEmpty)

        let blocked = SettingsConfigNotice.migrationWriteBlocked(
            report: report,
            backupURL: migrationBackup,
            reason: "blocked"
        )
        XCTAssertEqual(
            SettingsConfigDiagnostics.issues(directoryURL: directory, notice: blocked).first?.severity,
            .critical
        )
    }

    func testRecoveryIssueCopyIsNeutralAndNamesBothSlots() {
        let issue = DiagnosticsIssue(kind: .settingsFileCorrupt)

        XCTAssertEqual(issue.title, "Settings recovery file available")
        XCTAssertTrue(issue.message.contains(SettingsFilePersistence.corruptFileName))
        XCTAssertTrue(issue.message.contains(SettingsFilePersistence.secondaryCorruptFileName))
        XCTAssertFalse(issue.message.contains("reset it to defaults"))
        XCTAssertTrue(issue.remediation.contains(SettingsFilePersistence.corruptFileName))
        XCTAssertTrue(issue.remediation.contains(SettingsFilePersistence.secondaryCorruptFileName))
    }

    func testRejectedEditDiagnosticUsesResolvedConfigAndExactDecodePaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMResolvedXDGConfig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        let source = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .replacingOccurrences(of: "followsMouse = false", with: "followsMouse = \"false\"")
        let reason: String
        do {
            _ = try SettingsTOMLCodec.decodeForLoad(Data(source.utf8))
            return XCTFail("Expected strict type rejection")
        } catch {
            reason = SettingsTOMLCodec.diagnosticDescription(for: error)
        }

        let issues = SettingsConfigDiagnostics.issues(
            directoryURL: directory,
            notice: .invalidRejected(reason: reason)
        )
        let issue = try XCTUnwrap(issues.first)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issue.configFileURL, settingsURL)
        XCTAssertTrue(reason.contains("focus.followsMouse"))
        XCTAssertTrue(issue.message.contains(settingsURL.path))
        XCTAssertTrue(issue.message.contains("focus.followsMouse"))
        XCTAssertTrue(issue.remediation.contains(settingsURL.path))
    }

    @MainActor
    func testUnknownKeyInsideAppRuleArrayDetected() throws {
        let base = String(decoding: try SettingsTOMLCodec.encode(makeExport()), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("appRules") }
            .joined(separator: "\n")
        let toml = base + """

        [[appRules]]
        bundleId = "com.example.app"
        bogusRuleKey = true
        """
        let unknown = SettingsTOMLCodec.unknownKeyPaths(in: Data(toml.utf8))
        XCTAssertEqual(unknown.count, 1)
        XCTAssertTrue(unknown[0].hasPrefix("appRules["))
        XCTAssertTrue(unknown[0].hasSuffix("].bogusRuleKey"))
    }

    @MainActor
    private func makeExport() -> SettingsExport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMConfigDiagTests-\(UUID().uuidString)", isDirectory: true)
        let store = SettingsStore(
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
        return store.toExport()
    }
}
