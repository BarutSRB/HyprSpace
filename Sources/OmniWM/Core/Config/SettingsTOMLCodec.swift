// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import TOML

// Only file in OmniWM that imports TOML — keep this boundary so swift-toml stays swappable.
enum SettingsTOMLCodec {
    static func encode(_ export: SettingsExport) throws -> Data {
        try encodeCanonical(export)
    }

    static func encode(_ export: SettingsExport, preservingUnknownKeysFrom previous: Data?) throws -> Data {
        let canonicalData = try encodeCanonical(export)
        guard let previous, !previous.isEmpty else { return canonicalData }

        do {
            let decoder = TOMLDecoder()
            let newCanonicalTree = try decoder.decode([String: TOMLNode].self, from: canonicalData)
            let oldRawTree = try decoder.decode([String: TOMLNode].self, from: previous)
            let oldSchemaKnownTree = try decoder.decode(
                [String: TOMLNode].self,
                from: encodeCanonical(decode(previous))
            )
            let merged = TOMLNode.mergeUnknownKeys(
                base: newCanonicalTree,
                oldRaw: oldRawTree,
                oldSchemaKnown: oldSchemaKnownTree
            )
            guard merged != newCanonicalTree else { return canonicalData }

            let encoder = TOMLEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try encoder.encode(merged)
        } catch {
            return canonicalData
        }
    }

    private static func encodeCanonical(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        let previousHyperKeyModifiers = KeySymbolMapper.hyperModifiers
        do {
            return try decodeCanonical(from: data)
        } catch {
            // CanonicalTOMLConfig.init applies the decoded Hyper composition before the
            // hotkeys table parses; a rejected decode must not leave it active.
            KeySymbolMapper.setHyperKeyModifiers(
                HyperKeyModifiers(carbonMask: previousHyperKeyModifiers) ?? .default
            )
            throw error
        }
    }

    private static func decodeCanonical(from data: Data) throws -> SettingsExport {
        do {
            let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
            return canonical.toSettingsExport()
        } catch DecodingError.keyNotFound(_, _) {
            let decoder = TOMLDecoder()
            decoder.userInfo[.settingsTOMLRecoverMissingKeys] = true
            let canonical = try decoder.decode(CanonicalTOMLConfig.self, from: data)
            return canonical.toSettingsExport()
        }
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
}

private enum TOMLNode: Codable, Equatable {
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

    static func mergeUnknownKeys(
        base: [String: TOMLNode],
        oldRaw: [String: TOMLNode],
        oldSchemaKnown: [String: TOMLNode]
    ) -> [String: TOMLNode] {
        var merged = base
        preserveUnknownKeys(from: oldRaw, known: oldSchemaKnown, into: &merged)
        return merged
    }

    static func unknownKeyPaths(
        raw: [String: TOMLNode],
        known: [String: TOMLNode],
        prefix: String
    ) -> [String] {
        var result: [String] = []
        for (key, rawValue) in raw {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            guard let knownValue = known[key] else {
                result.append(path)
                continue
            }
            if case let .table(rawTable) = rawValue, case let .table(knownTable) = knownValue {
                result.append(contentsOf: unknownKeyPaths(raw: rawTable, known: knownTable, prefix: path))
            } else if case let .array(rawArray) = rawValue, case let .array(knownArray) = knownValue {
                for (index, rawElement) in rawArray.enumerated() {
                    guard case let .table(rawTable) = rawElement,
                          index < knownArray.count,
                          case let .table(knownTable) = knownArray[index]
                    else { continue }
                    result.append(contentsOf: unknownKeyPaths(
                        raw: rawTable,
                        known: knownTable,
                        prefix: "\(path)[\(index)]"
                    ))
                }
            }
        }
        return result
    }

    private static func preserveUnknownKeys(
        from oldRaw: [String: TOMLNode],
        known oldSchemaKnown: [String: TOMLNode],
        into merged: inout [String: TOMLNode]
    ) {
        for (key, oldValue) in oldRaw {
            guard let knownValue = oldSchemaKnown[key] else {
                if merged[key] == nil {
                    merged[key] = oldValue
                }
                continue
            }

            guard case .table(let oldTable) = oldValue,
                  case .table(let knownTable) = knownValue,
                  case .table(var mergedTable) = merged[key]
            else {
                continue
            }

            preserveUnknownKeys(from: oldTable, known: knownTable, into: &mergedTable)
            merged[key] = .table(mergedTable)
        }
    }
}

private struct DynamicCodingKey: CodingKey {
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
