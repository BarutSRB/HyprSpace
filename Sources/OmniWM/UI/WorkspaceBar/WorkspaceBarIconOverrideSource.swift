// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum WorkspaceBarIconOverrideSource: Equatable {
    private static let bundleResourcePrefix = "bundle-resource:"

    case file(String)
    case bundleResource(String)

    init?(storedValue: String) {
        let normalized = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix(Self.bundleResourcePrefix) {
            let name = String(normalized.dropFirst(Self.bundleResourcePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            self = .bundleResource(name)
        } else {
            self = .file(normalized)
        }
    }

    var storedValue: String {
        switch self {
        case let .file(path):
            path
        case let .bundleResource(name):
            Self.bundleResourcePrefix + name
        }
    }

    var displayValue: String {
        switch self {
        case let .file(path):
            path
        case let .bundleResource(name):
            "App-provided: \(name)"
        }
    }
}
