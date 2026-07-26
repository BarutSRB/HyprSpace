// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct WorkspaceBarAppIconDescriptor: Hashable, Sendable {
    let resourceName: String
    let assetType: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let isDeclared: Bool
    let score: Int
}

struct WorkspaceBarAppIconCandidate: Identifiable {
    let resourceName: String
    let image: NSImage

    var id: String {
        resourceName
    }
}

struct WorkspaceBarAppIconDiscoveryResult {
    let bundleURL: URL?
    let candidates: [WorkspaceBarAppIconCandidate]
}

struct WorkspaceBarAssetCatalogRendition: Decodable, Sendable {
    let name: String?
    let assetType: String?
    let pixelWidth: Int?
    let pixelHeight: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case assetType = "AssetType"
        case pixelWidth = "PixelWidth"
        case pixelHeight = "PixelHeight"
    }
}

enum WorkspaceBarAppIconScanner {
    private struct ScoreInput {
        let name: String
        let assetType: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let isDeclared: Bool
        let isLooseIconFile: Bool
    }

    private static let imageExtensions = Set([
        "heic",
        "icns",
        "jpeg",
        "jpg",
        "pdf",
        "png",
        "svg",
        "tif",
        "tiff"
    ])

    static func scan(bundleURL: URL) async -> [WorkspaceBarAppIconDescriptor] {
        let scanTask = Task.detached(priority: .userInitiated) {
            await scanOffMain(bundleURL: bundleURL)
        }
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    static func assetCatalogDescriptors(
        from data: Data,
        declaredNames: Set<String> = []
    ) -> [WorkspaceBarAppIconDescriptor] {
        guard let renditions = try? JSONDecoder().decode(
            [WorkspaceBarAssetCatalogRendition].self,
            from: data
        ) else {
            return []
        }

        let descriptors: [WorkspaceBarAppIconDescriptor] = renditions.compactMap { rendition in
            guard let name = rendition.name,
                  let candidateScore = Self.score(
                      ScoreInput(
                          name: name,
                          assetType: rendition.assetType,
                          pixelWidth: rendition.pixelWidth,
                          pixelHeight: rendition.pixelHeight,
                          isDeclared: declaredNames.contains(name),
                          isLooseIconFile: false
                      )
                  )
            else {
                return nil
            }
            return WorkspaceBarAppIconDescriptor(
                resourceName: name,
                assetType: rendition.assetType,
                pixelWidth: rendition.pixelWidth,
                pixelHeight: rendition.pixelHeight,
                isDeclared: declaredNames.contains(name),
                score: candidateScore
            )
        }
        return deduplicated(descriptors)
    }

    private static func scanOffMain(
        bundleURL: URL
    ) async -> [WorkspaceBarAppIconDescriptor] {
        guard !Task.isCancelled else { return [] }
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourceURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let declaredNames = declaredIconNames(infoURL: infoURL)
        let declaredDescriptors = declaredNames.map {
            WorkspaceBarAppIconDescriptor(
                resourceName: $0,
                assetType: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                isDeclared: true,
                score: 1_000
            )
        }
        return deduplicated(
            declaredDescriptors + (await resourceDescriptors(
                resourceURL: resourceURL,
                declaredNames: declaredNames
            ))
        )
    }

    private static func resourceDescriptors(
        resourceURL: URL,
        declaredNames: Set<String>
    ) async -> [WorkspaceBarAppIconDescriptor] {
        guard !Task.isCancelled else { return [] }
        let resourceFiles = (
            try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        ) ?? []
        var descriptors: [WorkspaceBarAppIconDescriptor] = []

        let assetCatalogURL = resourceURL.appendingPathComponent("Assets.car")
        let assetCatalogData = await assetCatalogInfo(at: assetCatalogURL)
        guard !Task.isCancelled else { return [] }
        if let assetCatalogData {
            descriptors.append(
                contentsOf: assetCatalogDescriptors(
                    from: assetCatalogData,
                    declaredNames: declaredNames
                )
            )
        }

        for fileURL in resourceFiles {
            guard !Task.isCancelled else { return [] }
            let fileExtension = fileURL.pathExtension.lowercased()
            guard imageExtensions.contains(fileExtension) else { continue }
            let name = fileURL.deletingPathExtension().lastPathComponent
            guard let score = score(
                ScoreInput(
                    name: name,
                    assetType: nil,
                    pixelWidth: nil,
                    pixelHeight: nil,
                    isDeclared: declaredNames.contains(name),
                    isLooseIconFile: fileExtension == "icns"
                )
            ) else {
                continue
            }
            descriptors.append(
                WorkspaceBarAppIconDescriptor(
                    resourceName: name,
                    assetType: nil,
                    pixelWidth: nil,
                    pixelHeight: nil,
                    isDeclared: declaredNames.contains(name),
                    score: score
                )
            )
        }
        return descriptors
    }

    private static func deduplicated(
        _ descriptors: [WorkspaceBarAppIconDescriptor]
    ) -> [WorkspaceBarAppIconDescriptor] {
        var bestByName: [String: WorkspaceBarAppIconDescriptor] = [:]
        for descriptor in descriptors {
            if let existing = bestByName[descriptor.resourceName],
               existing.score >= descriptor.score
            {
                continue
            }
            bestByName[descriptor.resourceName] = descriptor
        }
        return bestByName.values.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.resourceName.localizedStandardCompare($1.resourceName)
                == .orderedAscending
        }.prefix(48).map(\.self)
    }

    private static func declaredIconNames(infoURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any]
        else {
            return []
        }

        var names: Set<String> = []
        collectIconNames(from: dictionary, names: &names)
        return names
    }

    private static func collectIconNames(from value: Any, names: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "CFBundleIconName" || key == "CFBundleIconFile" {
                    if let name = child as? String {
                        let resourceName = resourceName(from: name)
                        if !resourceName.isEmpty {
                            names.insert(resourceName)
                        }
                    }
                } else if key == "CFBundleIconFiles", let iconNames = child as? [String] {
                    names.formUnion(
                        iconNames.map(resourceName(from:)).filter { !$0.isEmpty }
                    )
                }
                collectIconNames(from: child, names: &names)
            }
        } else if let values = value as? [Any] {
            for child in values {
                collectIconNames(from: child, names: &names)
            }
        }
    }

    private static func resourceName(from value: String) -> String {
        let url = URL(fileURLWithPath: value)
        let fileExtension = url.pathExtension.lowercased()
        guard imageExtensions.contains(fileExtension) || fileExtension == "icon" else {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func assetCatalogInfo(at url: URL) async -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await WorkspaceBarAssetCatalogProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/assetutil"),
            arguments: ["--info", url.path],
            timeout: .seconds(3)
        )
    }

    private static func score(_ input: ScoreInput) -> Int? {
        guard !input.name.isEmpty, !input.name.contains("/") else { return nil }

        let normalizedName = input.name.lowercased().filter { $0.isLetter || $0.isNumber }
        let normalizedType = input.assetType?.lowercased() ?? ""
        if !normalizedType.isEmpty,
           !normalizedType.contains("image"),
           !normalizedType.contains("icon")
        {
            return nil
        }

        if !input.isDeclared,
           let pixelWidth = input.pixelWidth,
           let pixelHeight = input.pixelHeight,
           min(pixelWidth, pixelHeight) < 64 || abs(pixelWidth - pixelHeight) > 4
        {
            return nil
        }

        if input.isDeclared {
            return 1_000
        }
        if normalizedName == "appicon" {
            return 950
        }
        if normalizedName.contains("appicon")
            || normalizedName.contains("applicationicon")
        {
            return 900
        }
        if normalizedName.contains("dockicon") {
            return 850
        }
        if input.isLooseIconFile {
            return 800
        }
        if normalizedName.contains("icon"),
           ["dark", "light", "alternate", "classic", "color", "mono"].contains(
               where: normalizedName.contains
           )
        {
            return 700
        }
        return nil
    }
}

@MainActor
final class WorkspaceBarAppIconDiscovery {
    typealias DescriptorLoader = @Sendable (URL) async -> [WorkspaceBarAppIconDescriptor]
    typealias BundleURLResolver = (String) -> URL?
    typealias ImageLoader = (URL, String) -> NSImage?

    private struct CacheKey: Hashable {
        let bundlePath: String
        let infoModifiedAt: Date?
        let resourcesModifiedAt: Date?
        let assetsModifiedAt: Date?
    }

    private let descriptorLoader: DescriptorLoader
    private let bundleURLResolver: BundleURLResolver
    private let imageLoader: ImageLoader
    private var cache: [CacheKey: [WorkspaceBarAppIconCandidate]] = [:]

    init(
        descriptorLoader: @escaping DescriptorLoader = WorkspaceBarAppIconScanner.scan,
        bundleURLResolver: @escaping BundleURLResolver = { bundleId in
            let workspace = NSWorkspace.shared
            return workspace.runningApplications.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleId) == .orderedSame
            }?.bundleURL ?? workspace.urlForApplication(withBundleIdentifier: bundleId)
        },
        imageLoader: @escaping ImageLoader = { bundleURL, name in
            guard let image = Bundle(url: bundleURL)?.image(forResource: NSImage.Name(name)),
                  image.isValid
            else {
                return nil
            }
            return image
        }
    ) {
        self.descriptorLoader = descriptorLoader
        self.bundleURLResolver = bundleURLResolver
        self.imageLoader = imageLoader
    }

    func discover(
        bundleId: String,
        preferredBundleURL: URL?
    ) async -> WorkspaceBarAppIconDiscoveryResult {
        guard let bundleURL = preferredBundleURL ?? bundleURLResolver(bundleId) else {
            return WorkspaceBarAppIconDiscoveryResult(bundleURL: nil, candidates: [])
        }

        let normalizedBundleURL = bundleURL.standardizedFileURL
        let cacheKey = cacheKey(for: normalizedBundleURL)
        if let cached = cache[cacheKey] {
            return WorkspaceBarAppIconDiscoveryResult(
                bundleURL: normalizedBundleURL,
                candidates: cached
            )
        }

        let descriptors = await descriptorLoader(normalizedBundleURL)
        guard !Task.isCancelled else {
            return WorkspaceBarAppIconDiscoveryResult(
                bundleURL: normalizedBundleURL,
                candidates: []
            )
        }

        var candidates: [WorkspaceBarAppIconCandidate] = []
        for (index, descriptor) in descriptors.enumerated() {
            if index > 0, index.isMultiple(of: 8) {
                await Task.yield()
                guard !Task.isCancelled else {
                    return WorkspaceBarAppIconDiscoveryResult(
                        bundleURL: normalizedBundleURL,
                        candidates: []
                    )
                }
            }
            guard let image = imageLoader(
                normalizedBundleURL,
                descriptor.resourceName
            ) else {
                continue
            }
            candidates.append(
                WorkspaceBarAppIconCandidate(
                    resourceName: descriptor.resourceName,
                    image: image
                )
            )
        }

        if cache.count >= 16 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[cacheKey] = candidates
        return WorkspaceBarAppIconDiscoveryResult(
            bundleURL: normalizedBundleURL,
            candidates: candidates
        )
    }

    private func cacheKey(for bundleURL: URL) -> CacheKey {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let assetsURL = resourcesURL.appendingPathComponent("Assets.car")
        return CacheKey(
            bundlePath: bundleURL.path,
            infoModifiedAt: modificationDate(for: infoURL),
            resourcesModifiedAt: modificationDate(for: resourcesURL),
            assetsModifiedAt: modificationDate(for: assetsURL)
        )
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
