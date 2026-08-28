// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension TOMLNode {
    private enum DestinationMatch {
        case deleted
        case unique(Int)
        case unsafe
    }

    static func mergeUnknownKeys(
        base: [String: TOMLNode],
        oldRaw: [String: TOMLNode],
        oldSchemaKnown: [String: TOMLNode]
    ) throws -> [String: TOMLNode] {
        var merged = base
        try preserveUnknownKeys(from: oldRaw, known: oldSchemaKnown, into: &merged, path: "")
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
                result.append(contentsOf: unknownArrayKeyPaths(
                    raw: rawArray,
                    known: knownArray,
                    prefix: path
                ))
            }
        }
        return result
    }

    private static func unknownArrayKeyPaths(
        raw: [TOMLNode],
        known: [TOMLNode],
        prefix: String
    ) -> [String] {
        raw.enumerated().flatMap { index, rawElement -> [String] in
            guard case let .table(rawTable) = rawElement,
                  index < known.count,
                  case let .table(knownTable) = known[index]
            else { return [] }
            return unknownKeyPaths(
                raw: rawTable,
                known: knownTable,
                prefix: "\(prefix)[\(index)]"
            )
        }
    }

    private static func preserveUnknownKeys(
        from oldRaw: [String: TOMLNode],
        known oldSchemaKnown: [String: TOMLNode],
        into merged: inout [String: TOMLNode],
        path: String
    ) throws {
        for (key, oldValue) in oldRaw {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard let knownValue = oldSchemaKnown[key] else {
                if merged[key] == nil {
                    merged[key] = oldValue
                }
                continue
            }

            switch (oldValue, knownValue, merged[key]) {
            case let (.table(oldTable), .table(knownTable), .table(mergedTable)):
                var updatedTable = mergedTable
                try preserveUnknownKeys(
                    from: oldTable,
                    known: knownTable,
                    into: &updatedTable,
                    path: childPath
                )
                merged[key] = .table(updatedTable)
            case let (.array(oldArray), .array(knownArray), .array(mergedArray)):
                merged[key] = .array(try preserveUnknownKeys(
                    from: oldArray,
                    known: knownArray,
                    into: mergedArray,
                    path: childPath
                ))
            default:
                continue
            }
        }
    }

    private static func preserveUnknownKeys(
        from oldArray: [TOMLNode],
        known knownArray: [TOMLNode],
        into mergedArray: [TOMLNode],
        path: String
    ) throws -> [TOMLNode] {
        var matches = [DestinationMatch?](repeating: nil, count: oldArray.count)
        var ownerCounts: [Int: Int] = [:]
        for index in oldArray.indices {
            guard case let .table(oldTable) = oldArray[index],
                  index < knownArray.count,
                  case let .table(knownTable) = knownArray[index]
            else { continue }
            let match = destinationMatch(
                for: oldTable,
                schemaKnown: knownTable,
                in: mergedArray,
                arrayPath: path
            )
            matches[index] = match
            if case let .unique(destinationIndex) = match {
                ownerCounts[destinationIndex, default: 0] += 1
            }
        }

        var result = mergedArray
        for index in oldArray.indices {
            guard case let .table(oldTable) = oldArray[index],
                  index < knownArray.count,
                  case let .table(knownTable) = knownArray[index]
            else { continue }
            let elementPath = "\(path)[\(index)]"
            guard !unknownKeyPaths(raw: oldTable, known: knownTable, prefix: elementPath).isEmpty else { continue }
            guard case let .unique(destinationIndex) = matches[index],
                  ownerCounts[destinationIndex] == 1
            else {
                if case .deleted = matches[index] { continue }
                throw SettingsTOMLCodecError.cannotSafelyPreserveArrayElement(elementPath)
            }
            guard case let .table(mergedTable) = result[destinationIndex] else { continue }
            var updatedTable = mergedTable
            try preserveUnknownKeys(
                from: oldTable,
                known: knownTable,
                into: &updatedTable,
                path: elementPath
            )
            result[destinationIndex] = .table(updatedTable)
        }
        return result
    }

    private static func destinationMatch(
        for oldTable: [String: TOMLNode],
        schemaKnown: [String: TOMLNode],
        in nodes: [TOMLNode],
        arrayPath: String
    ) -> DestinationMatch {
        if oldTable["id"] != nil, case let .string(id) = schemaKnown["id"] {
            let matches = matchingIndices(in: nodes) { candidate in
                guard case let .string(candidateID) = candidate["id"] else { return false }
                return canonicalID(candidateID) == canonicalID(id)
            }
            return classified(matches, empty: .deleted)
        }
        if isMonitorIdentityArray(arrayPath), hasMonitorIdentity(schemaKnown) {
            return classified(monitorMatchingIndices(for: schemaKnown, in: nodes), empty: .deleted)
        }
        let matches = matchingIndices(in: nodes) { candidate in
            schemaContent(candidate) == schemaContent(schemaKnown)
        }
        return classified(matches, empty: .unsafe)
    }

    private static func classified(_ matches: [Int], empty: DestinationMatch) -> DestinationMatch {
        switch matches.count {
        case 0: empty
        case 1: .unique(matches[0])
        default: .unsafe
        }
    }

    private static func isMonitorIdentityArray(_ path: String) -> Bool {
        path == "monitorOrientationOverrides" || path == "monitorRoutingOverrides"
    }

    private static func hasMonitorIdentity(_ table: [String: TOMLNode]) -> Bool {
        if monitorUUID(in: table) != nil { return true }
        if case .integer = table["monitorDisplayId"] { return true }
        if case let .string(name) = table["monitorName"] { return !name.isEmpty }
        return false
    }

    private static func monitorMatchingIndices(
        for source: [String: TOMLNode],
        in nodes: [TOMLNode]
    ) -> [Int] {
        if let sourceUUID = monitorUUID(in: source) {
            return matchingIndices(in: nodes) { candidate in
                monitorUUID(in: candidate) == sourceUUID
            }
        }
        if case let .integer(sourceID) = source["monitorDisplayId"] {
            return matchingIndices(in: nodes) { candidate in
                guard case let .integer(candidateID) = candidate["monitorDisplayId"] else { return false }
                return candidateID == sourceID
            }
        }
        guard case let .string(sourceName) = source["monitorName"] else { return [] }
        return matchingIndices(in: nodes) { candidate in
            guard case let .string(candidateName) = candidate["monitorName"] else { return false }
            return Monitor.namesMatch(sourceName, candidateName)
        }
    }

    private static func monitorUUID(in table: [String: TOMLNode]) -> String? {
        guard case let .string(value) = table["monitorDisplayUUID"] else { return nil }
        return DisplayUUID.canonical(value)
    }

    private static func matchingIndices(
        in nodes: [TOMLNode],
        where predicate: ([String: TOMLNode]) -> Bool
    ) -> [Int] {
        nodes.indices.filter { index in
            guard case let .table(candidate) = nodes[index] else { return false }
            return predicate(candidate)
        }
    }

    private static func schemaContent(_ table: [String: TOMLNode]) -> [String: TOMLNode] {
        var content = table
        content.removeValue(forKey: "id")
        return content
    }

    private static func canonicalID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString ?? value
    }
}
