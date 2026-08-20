// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum DiagnosticsRetention {
    private static let temporaryLifetime: TimeInterval = 60 * 60

    static func wipe(
        directory: URL,
        prefixes: [String] = ["omniwm-"],
        except: Set<URL> = [],
        keepingNewest keepCount: Int = 0
    ) {
        removeStaleTemporaryFiles(directory: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let candidates = files.filter { file in
            prefixes.contains { file.lastPathComponent.hasPrefix($0) }
        }
        var preserved = Set(except.map { $0.standardizedFileURL.path })
        if keepCount > 0 {
            let newest = candidates
                .map { (
                    $0,
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                ) }
                .sorted { $0.1 > $1.1 }
                .prefix(keepCount)
            preserved.formUnion(newest.map { $0.0.standardizedFileURL.path })
        }
        for file in candidates {
            guard !preserved.contains(file.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func removeStaleTemporaryFiles(directory: URL, now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }

        let cutoff = now.addingTimeInterval(-temporaryLifetime)
        for file in files {
            let name = file.lastPathComponent
            guard isOwnedTemporaryFile(name),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isOwnedTemporaryFile(_ name: String) -> Bool {
        (
            name.hasPrefix(".omniwm-diagnostics-")
                || name.hasPrefix(".omniwm-trace-")
                || name.hasPrefix(".omniwm-performance-")
        )
            && name.hasSuffix(".tmp")
    }
}
