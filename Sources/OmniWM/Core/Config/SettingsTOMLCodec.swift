// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import TOML

// Only file in OmniWM that imports TOML — keep this boundary so swift-toml stays swappable.
enum SettingsTOMLCodec {
    static let currentSchemaVersion = 1

    private struct PersistedHotkeyArray: Decodable {
        let hotkeys: [PersistedHotkeyBinding]
    }

    static func encode(_ export: SettingsExport) throws -> Data {
        try encodeCanonical(export)
    }

    static func encode(_ export: SettingsExport, preservingUnknownKeysFrom previous: Data?) throws -> Data {
        let canonicalData = try encodeCanonical(export)
        guard let previous else { return canonicalData }

        let decoder = TOMLDecoder()
        let newCanonicalTree = try decoder.decode([String: TOMLNode].self, from: canonicalData)
        let oldRawTree: [String: TOMLNode]
        let oldExport: SettingsExport
        do {
            oldRawTree = try decoder.decode([String: TOMLNode].self, from: previous)
            oldExport = try decode(previous)
        } catch let error as SettingsTOMLCodecError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            throw SettingsTOMLCodecError.cannotSafelyPreservePreviousData
        } catch {
            throw SettingsTOMLCodecError.cannotSafelyPreservePreviousData
        }
        let oldSchemaKnownTree = try decoder.decode(
            [String: TOMLNode].self,
            from: encodeCanonical(oldExport)
        )

        let merged = try TOMLNode.mergeUnknownKeys(
            base: newCanonicalTree,
            oldRaw: oldRawTree,
            oldSchemaKnown: oldSchemaKnownTree
        )
        guard merged != newCanonicalTree else { return canonicalData }

        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(merged)
    }

    private static func encodeCanonical(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        try decodeForLoad(data).export
    }

    static func decodeForLoad(_ data: Data) throws -> SettingsTOMLDecodeResult {
        let activeHyperKeyModifiers = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        defer { KeySymbolMapper.setHyperKeyModifiers(activeHyperKeyModifiers) }

        let decoder = TOMLDecoder()
        var raw = try decoder.decode([String: TOMLNode].self, from: data)
        let version = try schemaVersion(in: raw)
        guard version <= currentSchemaVersion else {
            throw SettingsTOMLCodecError.unsupportedSchemaVersion(
                found: version,
                supported: currentSchemaVersion
            )
        }

        if version == currentSchemaVersion {
            let canonical = try decoder.decode(CanonicalTOMLConfig.self, from: data)
            return SettingsTOMLDecodeResult(export: canonical.toSettingsExport(), migration: nil, migratedData: nil)
        }

        let report = try migrateVersionZero(&raw)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let migratedData = try encoder.encode(raw)
        let canonical = try decoder.decode(CanonicalTOMLConfig.self, from: migratedData)
        return SettingsTOMLDecodeResult(
            export: canonical.toSettingsExport(),
            migration: report,
            migratedData: migratedData
        )
    }

    static func unknownKeyPaths(in data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        do {
            let decoder = TOMLDecoder()
            let raw = try decoder.decode([String: TOMLNode].self, from: data)
            let known = try decoder.decode([String: TOMLNode].self, from: encodeCanonical(decode(data)))
            return TOMLNode.unknownKeyPaths(raw: raw, known: known, prefix: "").sorted()
        } catch {
            return []
        }
    }

    private static func schemaVersion(in raw: [String: TOMLNode]) throws -> Int {
        guard let node = raw["schemaVersion"] else { return 0 }
        guard case let .integer(rawVersion) = node,
              rawVersion >= 0,
              let version = Int(exactly: rawVersion)
        else {
            throw SettingsTOMLCodecError.invalidSchemaVersion
        }
        return version
    }

    private static func migrateVersionZero(_ raw: inout [String: TOMLNode]) throws -> SettingsMigrationReport {
        var defaultedPaths: [String] = []
        if addMissingValue(
            in: &raw,
            table: "focus",
            key: "raiseOnMouseFocus",
            value: .boolean(true)
        ) {
            defaultedPaths.append("focus.raiseOnMouseFocus")
        }
        if addMissingValue(
            in: &raw,
            table: "gaps",
            key: "fullscreenUsesOuterGaps",
            value: .boolean(false)
        ) {
            defaultedPaths.append("gaps.fullscreenUsesOuterGaps")
        }
        if addMissingValue(
            in: &raw,
            table: "workspaceBar",
            key: "hideInNativeFullscreen",
            value: .boolean(false)
        ) {
            defaultedPaths.append("workspaceBar.hideInNativeFullscreen")
        }
        if raw["scratchpads"] == nil {
            raw["scratchpads"] = .table(["labels": .table([:])])
            defaultedPaths.append("scratchpads.labels")
        } else if addMissingValue(
            in: &raw,
            table: "scratchpads",
            key: "labels",
            value: .table([:])
        ) {
            defaultedPaths.append("scratchpads.labels")
        }

        stampMissingAppRuleIDs(in: &raw)
        let hotkeyResult = try migrateVersionZeroHotkeys(in: &raw)
        raw["schemaVersion"] = .integer(Int64(currentSchemaVersion))
        return SettingsMigrationReport(
            fromVersion: 0,
            toVersion: currentSchemaVersion,
            defaultedPaths: defaultedPaths,
            addedHotkeyIDs: hotkeyResult.addedIDs,
            mappedHotkeys: hotkeyResult.mapped,
            retiredHotkeys: hotkeyResult.retired
        )
    }

    private static func addMissingValue(
        in raw: inout [String: TOMLNode],
        table tableKey: String,
        key: String,
        value: TOMLNode
    ) -> Bool {
        guard case .table(var table) = raw[tableKey], table[key] == nil else { return false }
        table[key] = value
        raw[tableKey] = .table(table)
        return true
    }

    private static func stampMissingAppRuleIDs(in raw: inout [String: TOMLNode]) {
        guard case let .array(entries) = raw["appRules"] else { return }
        raw["appRules"] = .array(entries.map { entry in
            guard case .table(var table) = entry, table["id"] == nil else { return entry }
            table["id"] = .string(UUID().uuidString)
            return .table(table)
        })
    }

    static let hotkeyIDsAddedAfterVersionZero: Set<String> = ["closeFocusedWindow"]

    private static func migrateVersionZeroHotkeys(
        in raw: inout [String: TOMLNode]
    ) throws -> SettingsHotkeyMigrationResult {
        guard case let .array(entries) = raw["hotkeys"] else {
            return SettingsHotkeyMigrationResult(addedIDs: [], mapped: [], retired: [])
        }

        let decoder = TOMLDecoder()
        let validationData = try TOMLEncoder().encode(["hotkeys": TOMLNode.array(entries)])
        _ = try decoder.decode(PersistedHotkeyArray.self, from: validationData)
        let defaultsTree = try decoder.decode(
            [String: TOMLNode].self,
            from: encodeCanonical(.defaults())
        )
        guard case let .array(defaultEntries) = defaultsTree["hotkeys"] else {
            throw SettingsTOMLCodecError.migrationInvariant("Canonical hotkey defaults could not be encoded.")
        }

        let mappings = [
            "assignFocusedWindowToScratchpad": "assignFocusedWindowToScratchpad.1",
            "toggleScratchpadWindow": "toggleScratchpad.1"
        ]
        let addedHotkeyIDs = Set(ScratchpadIndex.range.flatMap { index in
            ["toggleScratchpad.\(index)", "assignFocusedWindowToScratchpad.\(index)"]
        }).union(Self.hotkeyIDsAddedAfterVersionZero)
        let retirements = [
            "consumeOrExpelWindowLeft": ["consumeWindowIntoColumn", "expelWindowFromColumn"],
            "consumeOrExpelWindowRight": ["consumeWindowIntoColumn", "expelWindowFromColumn"]
        ]
        let explicitCurrentIDs = Set(entries.compactMap(hotkeyID))
        var migrated = migrateLegacyHotkeyEntries(
            entries,
            explicitCurrentIDs: explicitCurrentIDs,
            mappings: mappings,
            retirements: retirements
        )
        let addedIDs = appendMissingHotkeyDefaults(
            defaultEntries,
            eligibleIDs: addedHotkeyIDs,
            to: &migrated.entries
        )
        raw["hotkeys"] = .array(migrated.entries)
        return SettingsHotkeyMigrationResult(
            addedIDs: addedIDs,
            mapped: migrated.mapped,
            retired: migrated.retired
        )
    }

    private static func migrateLegacyHotkeyEntries(
        _ entries: [TOMLNode],
        explicitCurrentIDs: Set<String>,
        mappings: [String: String],
        retirements: [String: [String]]
    ) -> SettingsHotkeyMigrationAccumulator {
        var result = SettingsHotkeyMigrationAccumulator(entries: [], mapped: [], retired: [])
        for entry in entries {
            guard let id = hotkeyID(entry) else {
                result.entries.append(entry)
                continue
            }
            if let suggestedIDs = retirements[id] {
                result.retired.append(SettingsRetiredHotkey(id: id, suggestedIDs: suggestedIDs))
                continue
            }
            guard let currentID = mappings[id] else {
                result.entries.append(entry)
                continue
            }
            let keepCurrent = explicitCurrentIDs.contains(currentID)
            result.mapped.append(SettingsHotkeyMapping(
                previousID: id,
                currentID: currentID,
                keptExplicitCurrentBinding: keepCurrent
            ))
            guard !keepCurrent, case .table(var table) = entry else { continue }
            table["id"] = .string(currentID)
            result.entries.append(.table(table))
        }
        return result
    }

    private static func appendMissingHotkeyDefaults(
        _ defaults: [TOMLNode],
        eligibleIDs: Set<String>,
        to entries: inout [TOMLNode]
    ) -> [String] {
        let presentIDs = Set(entries.compactMap(hotkeyID))
        var addedIDs: [String] = []
        for entry in defaults {
            guard let id = hotkeyID(entry), eligibleIDs.contains(id), !presentIDs.contains(id) else { continue }
            entries.append(entry)
            addedIDs.append(id)
        }
        return addedIDs
    }

    private static func hotkeyID(_ node: TOMLNode) -> String? {
        guard case let .table(table) = node, case let .string(id) = table["id"] else { return nil }
        return id
    }
}

enum TOMLNode: Codable, Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case offsetDateTime(Date)
    case localDateTime(LocalDateTime)
    case localDate(LocalDate)
    case localTime(LocalTime)
    case array([TOMLNode])
    case table([String: TOMLNode])

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var table: [String: TOMLNode] = [:]
            for key in container.allKeys {
                table[key.stringValue] = try container.decode(TOMLNode.self, forKey: key)
            }
            self = .table(table)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [TOMLNode] = []
            while !container.isAtEnd {
                array.append(try container.decode(TOMLNode.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .float(value)
        } else if let value = try? container.decode(LocalDateTime.self) {
            self = .localDateTime(value)
        } else if let value = try? container.decode(LocalDate.self) {
            self = .localDate(value)
        } else if let value = try? container.decode(LocalTime.self) {
            self = .localTime(value)
        } else if let value = try? container.decode(Date.self) {
            self = .offsetDateTime(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.typeMismatch(
                TOMLNode.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported TOML node"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .float(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .offsetDateTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localDateTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localDate(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .localTime(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .table(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }
}
