// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

enum SettingsConfigDiagnostics {
    static func issues(directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL) -> [DiagnosticsIssue] {
        var issues: [DiagnosticsIssue] = []

        let settingsURL = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        if let data = try? Data(contentsOf: settingsURL) {
            let unknown = SettingsTOMLCodec.unknownKeyPaths(in: data)
            if !unknown.isEmpty {
                issues.append(DiagnosticsIssue(kind: .unknownConfigKeys(keyPaths: unknown)))
            }
        }

        if SettingsFilePersistence.corruptFileNames.contains(where: { fileName in
            pathEntryExists(at: directoryURL.appendingPathComponent(fileName, isDirectory: false))
        }) {
            issues.append(DiagnosticsIssue(kind: .settingsFileCorrupt))
        }

        return issues
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &fileStatus) == 0
        }
    }
}
