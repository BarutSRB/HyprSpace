// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum SettingsTOMLCodecError: Error, Equatable, LocalizedError {
    case cannotSafelyPreservePreviousData
    case cannotSafelyPreserveArrayElement(String)
    case invalidSchemaVersion
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case migrationInvariant(String)

    var errorDescription: String? {
        switch self {
        case .cannotSafelyPreservePreviousData:
            "The existing settings data could not be parsed and preserved safely."
        case let .cannotSafelyPreserveArrayElement(path):
            "Unknown settings data at \(path) could not be matched to exactly one retained array element."
        case .invalidSchemaVersion:
            "schemaVersion must be a non-negative integer."
        case let .unsupportedSchemaVersion(found, supported):
            "settings.toml uses schemaVersion \(found), but this build supports up to version \(supported)."
        case let .migrationInvariant(message):
            message
        }
    }
}

struct SettingsHotkeyMapping: Equatable {
    let previousID: String
    let currentID: String
    let keptExplicitCurrentBinding: Bool
}

struct SettingsRetiredHotkey: Equatable {
    let id: String
    let suggestedIDs: [String]
}

struct SettingsHotkeyMigrationResult {
    let addedIDs: [String]
    let mapped: [SettingsHotkeyMapping]
    let retired: [SettingsRetiredHotkey]
}

struct SettingsHotkeyMigrationAccumulator {
    var entries: [TOMLNode]
    var mapped: [SettingsHotkeyMapping]
    var retired: [SettingsRetiredHotkey]
}

struct SettingsMigrationReport: Equatable {
    let fromVersion: Int
    let toVersion: Int
    let defaultedPaths: [String]
    let addedHotkeyIDs: [String]
    let mappedHotkeys: [SettingsHotkeyMapping]
    let retiredHotkeys: [SettingsRetiredHotkey]

    var messages: [String] {
        var result = defaultedPaths.map { "Defaulted \($0)." }
        if !addedHotkeyIDs.isEmpty {
            result.append("Added required hotkeys: \(addedHotkeyIDs.joined(separator: ", ")).")
        }
        result.append(contentsOf: mappedHotkeys.map { mapping in
            if mapping.keptExplicitCurrentBinding {
                return "Ignored legacy hotkey \(mapping.previousID) because \(mapping.currentID) was explicitly configured."
            }
            return "Mapped hotkey \(mapping.previousID) to \(mapping.currentID)."
        })
        result.append(contentsOf: retiredHotkeys.map { hotkey in
            "Retired hotkey \(hotkey.id); use \(hotkey.suggestedIDs.joined(separator: " or "))."
        })
        return result
    }
}

struct SettingsTOMLDecodeResult: Equatable {
    let export: SettingsExport
    let migration: SettingsMigrationReport?
    let migratedData: Data?
}

extension SettingsTOMLCodec {
    static func diagnosticDescription(for error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            "\(diagnosticPath(context.codingPath + [key])): \(context.debugDescription)"
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context),
             let DecodingError.dataCorrupted(context):
            "\(diagnosticPath(context.codingPath)): \(context.debugDescription)"
        default:
            error.localizedDescription
        }
    }

    private static func diagnosticPath(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "settings.toml" : result
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
