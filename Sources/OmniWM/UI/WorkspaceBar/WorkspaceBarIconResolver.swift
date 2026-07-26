// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WorkspaceBarIconResolver {
    struct OverrideResolution {
        let source: WorkspaceBarIconOverrideSource
        let displayValue: String
        let image: NSImage?
    }

    typealias ImageLoader = (URL) -> NSImage?
    typealias BundleResourceImageLoader = (String, String) -> NSImage?
    typealias UnavailableLogger = (String) -> Void

    private enum LoadKey: Hashable {
        case file(String)
        case bundleResource(String, String)
    }

    private struct LoadDetails {
        let key: LoadKey
        let displayValue: String
    }

    private enum LoadResult {
        case image(NSImage)
        case unavailable

        var image: NSImage? {
            switch self {
            case let .image(image):
                image
            case .unavailable:
                nil
            }
        }
    }

    private struct NormalizedOverride {
        let bundleId: String
        let normalizedBundleId: String
        let configuredValue: String
        let source: WorkspaceBarIconOverrideSource
    }

    private let settingsDirectoryURL: URL
    private let homeDirectoryURL: URL
    private let imageLoader: ImageLoader
    private let bundleResourceImageLoader: BundleResourceImageLoader
    private let unavailableLogger: UnavailableLogger
    private var overridesByBundleId: [String: OverrideResolution] = [:]

    init(
        settingsFileURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        imageLoader: @escaping ImageLoader = {
            guard let image = NSImage(contentsOf: $0), image.isValid else { return nil }
            return image
        },
        bundleResourceImageLoader: @escaping BundleResourceImageLoader = { bundleId, name in
            let workspace = NSWorkspace.shared
            let runningURL = workspace.runningApplications.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleId) == .orderedSame
            }?.bundleURL
            guard let bundleURL = runningURL
                ?? workspace.urlForApplication(withBundleIdentifier: bundleId),
                let image = Bundle(url: bundleURL)?.image(forResource: NSImage.Name(name)),
                image.isValid
            else {
                return nil
            }
            return image
        },
        unavailableLogger: @escaping UnavailableLogger = {
            Log.config.notice($0)
        }
    ) {
        settingsDirectoryURL = settingsFileURL.deletingLastPathComponent().standardizedFileURL
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
        self.imageLoader = imageLoader
        self.bundleResourceImageLoader = bundleResourceImageLoader
        self.unavailableLogger = unavailableLogger
    }

    var hasOverrides: Bool {
        !overridesByBundleId.isEmpty
    }

    @discardableResult
    func synchronize(
        overrides: [String: String],
        forceReload: Bool = false,
        forceReloadBundleId: String? = nil
    ) -> Bool {
        let normalizedOverrides = Self.normalizedOverrides(overrides)
        let normalizedReloadBundleId = forceReloadBundleId.flatMap(Self.normalizedBundleId)
        let forcedLoadKeys = Set(normalizedOverrides.compactMap { item -> LoadKey? in
            guard forceReload || normalizedReloadBundleId == item.normalizedBundleId else {
                return nil
            }
            return loadDetails(for: item).key
        })
        var nextOverrides: [String: OverrideResolution] = [:]
        nextOverrides.reserveCapacity(normalizedOverrides.count)
        var loadsBySource: [LoadKey: LoadResult] = [:]
        loadsBySource.reserveCapacity(normalizedOverrides.count)

        for item in normalizedOverrides {
            let details = loadDetails(for: item)

            if !forcedLoadKeys.contains(details.key),
               let existing = overridesByBundleId[item.normalizedBundleId],
               existing.source == item.source,
               existing.displayValue == details.displayValue
            {
                nextOverrides[item.normalizedBundleId] = existing
                loadsBySource[details.key] = existing.image.map(LoadResult.image)
                    ?? .unavailable
                continue
            }

            let loadResult: LoadResult
            if let loaded = loadsBySource[details.key] {
                loadResult = loaded
            } else if let image = loadImage(for: item.source, bundleId: item.bundleId) {
                loadResult = .image(image)
                loadsBySource[details.key] = loadResult
            } else {
                loadResult = .unavailable
                loadsBySource[details.key] = loadResult
            }

            let resolution = OverrideResolution(
                source: item.source,
                displayValue: details.displayValue,
                image: loadResult.image
            )
            nextOverrides[item.normalizedBundleId] = resolution

            if resolution.image == nil {
                unavailableLogger(
                    "Workspace bar icon override unavailable for \(item.bundleId)"
                )
            }
        }

        return replaceOverrides(with: nextOverrides)
    }

    private func loadDetails(for item: NormalizedOverride) -> LoadDetails {
        switch item.source {
        case let .file(path):
            let resolvedPath = resolveURL(for: path).path
            return LoadDetails(
                key: .file(resolvedPath),
                displayValue: resolvedPath
            )
        case let .bundleResource(name):
            return LoadDetails(
                key: .bundleResource(item.normalizedBundleId, name),
                displayValue: item.source.displayValue
            )
        }
    }

    func overrideResolution(for bundleId: String) -> OverrideResolution? {
        guard let normalizedBundleId = Self.normalizedBundleId(bundleId) else { return nil }
        return overridesByBundleId[normalizedBundleId]
    }

    func image(for bundleId: String) -> NSImage? {
        overrideResolution(for: bundleId)?.image
    }

    private func loadImage(
        for source: WorkspaceBarIconOverrideSource,
        bundleId: String
    ) -> NSImage? {
        switch source {
        case let .file(path):
            imageLoader(resolveURL(for: path))
        case let .bundleResource(name):
            bundleResourceImageLoader(bundleId, name)
        }
    }

    private func resolveURL(for path: String) -> URL {
        if path == "~" {
            return homeDirectoryURL
        }
        if path.hasPrefix("~/") {
            return homeDirectoryURL
                .appendingPathComponent(String(path.dropFirst(2)))
                .standardizedFileURL
        }
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return settingsDirectoryURL.appendingPathComponent(path).standardizedFileURL
    }

    private static func normalizedOverrides(_ overrides: [String: String]) -> [NormalizedOverride] {
        SettingsStore.normalizedWorkspaceBarIconOverrides(overrides).compactMap { bundleId, value in
            guard let source = WorkspaceBarIconOverrideSource(storedValue: value) else {
                return nil
            }
            return NormalizedOverride(
                bundleId: bundleId,
                normalizedBundleId: bundleId.lowercased(),
                configuredValue: value,
                source: source
            )
        }.sorted {
            if $0.normalizedBundleId != $1.normalizedBundleId {
                return $0.normalizedBundleId < $1.normalizedBundleId
            }
            if $0.bundleId != $1.bundleId {
                return $0.bundleId < $1.bundleId
            }
            return $0.configuredValue < $1.configuredValue
        }
    }

    private static func normalizedBundleId(_ bundleId: String) -> String? {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func replaceOverrides(with nextOverrides: [String: OverrideResolution]) -> Bool {
        let changed = !Self.resolutionsMatch(overridesByBundleId, nextOverrides)
        overridesByBundleId = nextOverrides
        return changed
    }

    private static func resolutionsMatch(
        _ lhs: [String: OverrideResolution],
        _ rhs: [String: OverrideResolution]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (bundleId, lhsResolution) in lhs {
            guard let rhsResolution = rhs[bundleId],
                  lhsResolution.source == rhsResolution.source,
                  lhsResolution.displayValue == rhsResolution.displayValue,
                  imagesMatch(lhsResolution.image, rhsResolution.image)
            else {
                return false
            }
        }
        return true
    }

    private static func imagesMatch(_ lhs: NSImage?, _ rhs: NSImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs === rhs
        default:
            false
        }
    }
}
