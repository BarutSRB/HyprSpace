// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

enum SettingsConfigDiagnostics {
    private struct NoticeIssue {
        let kind: DiagnosticsIssue.Kind
        let describesRecovery: Bool
    }

    static func issues(
        directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL,
        notice: SettingsConfigNotice? = nil
    ) -> [DiagnosticsIssue] {
        var issues: [DiagnosticsIssue] = []

        let settingsURL = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        if let data = try? Data(contentsOf: settingsURL) {
            let unknown = SettingsTOMLCodec.unknownKeyPaths(in: data)
            if !unknown.isEmpty {
                issues.append(DiagnosticsIssue(
                    kind: .unknownConfigKeys(keyPaths: unknown),
                    configFileURL: settingsURL
                ))
            }
        }

        let noticeIssue = notice.flatMap(issue(for:))
        if let noticeIssue {
            issues.append(DiagnosticsIssue(kind: noticeIssue.kind, configFileURL: settingsURL))
        }

        if noticeIssue?.describesRecovery != true,
           SettingsFilePersistence.corruptFileNames.contains(where: { fileName in
               pathEntryExists(at: directoryURL.appendingPathComponent(fileName, isDirectory: false))
           })
        {
            issues.append(DiagnosticsIssue(kind: .settingsFileCorrupt, configFileURL: settingsURL))
        }

        return issues
    }

    private static func issue(for notice: SettingsConfigNotice) -> NoticeIssue? {
        switch notice {
        case let .migrated(report, backupURL):
            guard pathEntryExists(at: backupURL) else { return nil }
            return NoticeIssue(
                kind: .settingsMigrated(report: report, backupURL: backupURL),
                describesRecovery: false
            )
        case let .migrationWriteBlocked(report, backupURL, reason):
            let existingBackupURL = backupURL.flatMap { pathEntryExists(at: $0) ? $0 : nil }
            return NoticeIssue(
                kind: .settingsPersistenceBlocked(
                    reason: ([reason] + report.messages).joined(separator: " "),
                    backupURL: existingBackupURL
                ),
                describesRecovery: false
            )
        case let .unsupportedVersion(found, supported):
            return NoticeIssue(
                kind: .settingsPersistenceBlocked(
                    reason: "schemaVersion \(found) is newer than supported version \(supported).",
                    backupURL: nil
                ),
                describesRecovery: false
            )
        case let .recoveredInvalid(backupURL, reason):
            guard pathEntryExists(at: backupURL) else { return nil }
            return NoticeIssue(
                kind: .settingsRecovered(reason: reason, backupURL: backupURL),
                describesRecovery: true
            )
        case let .persistenceWriteBlocked(reason):
            return NoticeIssue(
                kind: .settingsPersistenceBlocked(reason: reason, backupURL: nil),
                describesRecovery: false
            )
        case let .invalidExternal(reason):
            return NoticeIssue(kind: .settingsInvalidExternal(reason: reason), describesRecovery: false)
        }
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &fileStatus) == 0
        }
    }
}
