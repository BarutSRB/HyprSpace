// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum InputMethodBundleRegistry {
    static let systemTextInputAgentBundleIds: Set<String> = [
        "com.apple.characterpaletteim",
        "com.apple.emojifunctionrowitem-container",
        "com.apple.textinputmenuagent",
        "com.apple.textinputswitcher"
    ]

    static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/Input Methods", isDirectory: true),
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
    ]

    static func discover(
        in directories: [URL] = searchDirectories,
        fileManager: FileManager = .default
    ) -> Set<String> {
        var bundleIds = systemTextInputAgentBundleIds
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "app" {
                guard let bundleId = Bundle(url: url)?.bundleIdentifier else { continue }
                bundleIds.insert(bundleId.lowercased())
            }
        }
        return bundleIds
    }
}
