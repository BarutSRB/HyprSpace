// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum SettingsFilePersistenceError: Error, Equatable, LocalizedError {
    case corruptBackupSlotsExhausted
    case danglingSettingsSymlink(String)
    case preVersionOneBackupSlotsExhausted
    case writesBlocked(String)

    var errorDescription: String? {
        switch self {
        case .corruptBackupSlotsExhausted:
            "Both settings recovery slots are occupied."
        case let .danglingSettingsSymlink(path):
            "The settings symlink at \(path) points to a missing file; create its target or replace the symlink, then restart OmniWM."
        case .preVersionOneBackupSlotsExhausted:
            "Both pre-version-1 settings backup slots are occupied."
        case let .writesBlocked(reason):
            "Settings writes are blocked: \(reason)"
        }
    }
}

enum SettingsConfigNotice: Equatable {
    case migrated(report: SettingsMigrationReport, backupURL: URL)
    case migrationWriteBlocked(report: SettingsMigrationReport, backupURL: URL?, reason: String)
    case unsupportedVersion(found: Int, supported: Int)
    case recoveredInvalid(backupURL: URL, reason: String)
    case persistenceWriteBlocked(reason: String)
    case invalidRejected(reason: String)

    var blockingReason: String? {
        switch self {
        case let .migrationWriteBlocked(_, _, reason),
             let .persistenceWriteBlocked(reason):
            reason
        case let .unsupportedVersion(found, supported):
            SettingsTOMLCodecError.unsupportedSchemaVersion(
                found: found,
                supported: supported
            ).localizedDescription
        case .migrated,
             .recoveredInvalid,
             .invalidRejected:
            nil
        }
    }
}

struct SettingsFileLoadOutcome: Equatable {
    let export: SettingsExport?
    let notice: SettingsConfigNotice?
}
