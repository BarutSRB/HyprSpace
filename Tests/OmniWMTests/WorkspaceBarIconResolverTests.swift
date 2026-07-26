// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarIconResolverTests: XCTestCase {
    func testResolvesAbsoluteRelativeAndHomePaths() throws {
        let root = URL(fileURLWithPath: "/tmp/omniwm-icon-resolver")
        let settingsFileURL = root.appendingPathComponent("config/settings.toml")
        let homeDirectoryURL = root.appendingPathComponent("home")
        var imagesByPath: [String: NSImage] = [:]
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: settingsFileURL,
            homeDirectoryURL: homeDirectoryURL,
            imageLoader: { url in
                let image = NSImage(size: NSSize(width: 16, height: 16))
                imagesByPath[url.path] = image
                return image
            },
            unavailableLogger: { _ in }
        )

        resolver.synchronize(
            overrides: [
                "com.example.absolute": "/Library/Application Support/Absolute.icns",
                "com.example.relative": "icons/Relative.png",
                "com.example.home": "~/Pictures/Home.png"
            ]
        )

        let absolute = try XCTUnwrap(resolver.overrideResolution(for: "COM.EXAMPLE.ABSOLUTE"))
        let relative = try XCTUnwrap(resolver.overrideResolution(for: "com.example.relative"))
        let home = try XCTUnwrap(resolver.overrideResolution(for: "com.example.home"))

        XCTAssertEqual(absolute.displayValue, "/Library/Application Support/Absolute.icns")
        XCTAssertEqual(
            relative.displayValue,
            root.appendingPathComponent("config/icons/Relative.png").path
        )
        XCTAssertEqual(
            home.displayValue,
            root.appendingPathComponent("home/Pictures/Home.png").path
        )
        XCTAssertTrue(absolute.image === imagesByPath[absolute.displayValue])
        XCTAssertTrue(relative.image === imagesByPath[relative.displayValue])
        XCTAssertTrue(home.image === imagesByPath[home.displayValue])
    }

    func testCachesSuccessAndFailureUntilForcedReload() throws {
        let settingsFileURL = URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml")
        var loadCount = 0
        var unavailableMessages: [String] = []
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: settingsFileURL,
            imageLoader: { url in
                loadCount += 1
                guard !url.lastPathComponent.hasPrefix("missing") else { return nil }
                return NSImage(size: NSSize(width: 20, height: 20))
            },
            unavailableLogger: { unavailableMessages.append($0) }
        )
        let overrides = [
            "com.example.valid": "valid.png",
            "com.example.missing": "missing.png"
        ]

        XCTAssertFalse(resolver.hasOverrides)
        XCTAssertTrue(resolver.synchronize(overrides: overrides))
        XCTAssertTrue(resolver.hasOverrides)
        let firstImage = try XCTUnwrap(resolver.image(for: "com.example.valid"))
        XCTAssertNil(resolver.image(for: "com.example.missing"))
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(
            unavailableMessages,
            ["Workspace bar icon override unavailable for com.example.missing"]
        )

        XCTAssertFalse(resolver.synchronize(overrides: overrides))
        XCTAssertTrue(resolver.image(for: "COM.EXAMPLE.VALID") === firstImage)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(unavailableMessages.count, 1)

        XCTAssertTrue(resolver.synchronize(overrides: overrides, forceReload: true))
        let reloadedImage = try XCTUnwrap(resolver.image(for: "com.example.valid"))
        XCTAssertFalse(reloadedImage === firstImage)
        XCTAssertEqual(loadCount, 4)
        XCTAssertEqual(unavailableMessages.count, 2)
    }

    func testReloadsChangedMappingAndPrunesRemovedBundleIds() throws {
        let settingsFileURL = URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml")
        var loadedPaths: [String] = []
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: settingsFileURL,
            imageLoader: { url in
                loadedPaths.append(url.path)
                return NSImage(size: NSSize(width: 18, height: 18))
            },
            unavailableLogger: { _ in }
        )

        resolver.synchronize(
            overrides: [
                "com.example.keep": "first.png",
                "com.example.remove": "removed.png"
            ]
        )
        let firstImage = try XCTUnwrap(resolver.image(for: "com.example.keep"))

        resolver.synchronize(overrides: ["COM.EXAMPLE.KEEP": "second.png"])
        let secondImage = try XCTUnwrap(resolver.image(for: "com.example.keep"))

        XCTAssertFalse(secondImage === firstImage)
        XCTAssertNil(resolver.overrideResolution(for: "com.example.remove"))
        XCTAssertEqual(
            loadedPaths,
            [
                "/tmp/omniwm-icon-resolver/first.png",
                "/tmp/omniwm-icon-resolver/removed.png",
                "/tmp/omniwm-icon-resolver/second.png"
            ]
        )

        resolver.synchronize(overrides: [:])
        XCTAssertFalse(resolver.hasOverrides)
    }

    func testSharedPathDecodesOncePerReload() throws {
        let settingsFileURL = URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml")
        var loadCount = 0
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: settingsFileURL,
            imageLoader: { _ in
                loadCount += 1
                return NSImage(size: NSSize(width: 12, height: 12))
            },
            unavailableLogger: { _ in }
        )

        resolver.synchronize(
            overrides: [
                "com.example.first": "shared.png",
                "com.example.second": "shared.png"
            ]
        )

        let first = try XCTUnwrap(resolver.image(for: "com.example.first"))
        let second = try XCTUnwrap(resolver.image(for: "com.example.second"))
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(first === second)

        resolver.synchronize(
            overrides: [
                "com.example.first": "shared.png",
                "com.example.second": "shared.png",
                "com.example.third": "shared.png"
            ]
        )

        let third = try XCTUnwrap(resolver.image(for: "com.example.third"))
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(first === third)
    }

    func testLoadsBundleResourceByName() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        var requests: [String] = []
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml"),
            imageLoader: { _ in nil },
            bundleResourceImageLoader: { bundleId, name in
                requests.append("\(bundleId):\(name)")
                return image
            },
            unavailableLogger: { _ in }
        )

        resolver.synchronize(
            overrides: ["com.cmuxterm.app": "bundle-resource:AppIconDark"]
        )

        let resolution = try XCTUnwrap(
            resolver.overrideResolution(for: "COM.CMUXTERM.APP")
        )
        XCTAssertEqual(resolution.source, .bundleResource("AppIconDark"))
        XCTAssertEqual(resolution.displayValue, "App-provided: AppIconDark")
        XCTAssertTrue(resolution.image === image)
        XCTAssertEqual(requests, ["com.cmuxterm.app:AppIconDark"])
    }

    func testTargetedReloadReloadsOnlyRequestedBundleId() {
        var requestsByBundleId: [String: Int] = [:]
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml"),
            imageLoader: { _ in nil },
            bundleResourceImageLoader: { bundleId, _ in
                requestsByBundleId[bundleId, default: 0] += 1
                return NSImage(size: NSSize(width: 32, height: 32))
            },
            unavailableLogger: { _ in }
        )
        let overrides = [
            "com.example.first": "bundle-resource:AppIconDark",
            "com.example.second": "bundle-resource:AppIconLight"
        ]

        resolver.synchronize(overrides: overrides)
        resolver.synchronize(
            overrides: overrides,
            forceReloadBundleId: "COM.EXAMPLE.FIRST"
        )

        XCTAssertEqual(requestsByBundleId["com.example.first"], 2)
        XCTAssertEqual(requestsByBundleId["com.example.second"], 1)
    }

    func testTargetedReloadRefreshesEveryBundleSharingTheFileSource() throws {
        var loadCount = 0
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml"),
            imageLoader: { _ in
                loadCount += 1
                return NSImage(size: NSSize(width: CGFloat(loadCount), height: 32))
            },
            unavailableLogger: { _ in }
        )
        let overrides = [
            "com.example.alpha": "shared.png",
            "com.example.zulu": "shared.png"
        ]

        resolver.synchronize(overrides: overrides)
        let original = try XCTUnwrap(resolver.image(for: "com.example.alpha"))

        resolver.synchronize(
            overrides: overrides,
            forceReloadBundleId: "com.example.zulu"
        )

        let refreshedAlpha = try XCTUnwrap(resolver.image(for: "com.example.alpha"))
        let refreshedZulu = try XCTUnwrap(resolver.image(for: "com.example.zulu"))
        XCTAssertEqual(loadCount, 2)
        XCTAssertFalse(refreshedAlpha === original)
        XCTAssertTrue(refreshedAlpha === refreshedZulu)
    }

    func testTargetedReloadReportsNoChangeWhenLoaderReturnsSameImage() {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: URL(fileURLWithPath: "/tmp/omniwm-icon-resolver/settings.toml"),
            imageLoader: { _ in nil },
            bundleResourceImageLoader: { _, _ in image },
            unavailableLogger: { _ in }
        )
        let overrides = ["com.example.app": "bundle-resource:AppIcon"]

        XCTAssertTrue(resolver.synchronize(overrides: overrides))
        XCTAssertFalse(
            resolver.synchronize(
                overrides: overrides,
                forceReloadBundleId: "com.example.app"
            )
        )
    }

    func testControllerRevisionTracksUnavailableAppLaunchRecovery() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMWorkspaceBarIconResolverTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let settings = makeSettingsStore(at: root)
        XCTAssertTrue(
            settings.setWorkspaceBarIconOverride(
                "bundle-resource:AppIcon",
                for: "com.example.app"
            )
        )
        let firstImage = NSImage(size: NSSize(width: 32, height: 32))
        let secondImage = NSImage(size: NSSize(width: 32, height: 32))
        var currentImage: NSImage?
        let resolver = WorkspaceBarIconResolver(
            settingsFileURL: settings.settingsFileURL,
            imageLoader: { _ in nil },
            bundleResourceImageLoader: { _, _ in currentImage },
            unavailableLogger: { _ in }
        )
        let controller = WMController(
            settings: settings,
            workspaceBarIconResolver: resolver
        )

        XCTAssertEqual(controller.workspaceBarIconResolutionRevision, 1)
        XCTAssertNil(resolver.image(for: "com.example.app"))

        controller.refreshUnavailableWorkspaceBarIconOverride(
            bundleId: "COM.EXAMPLE.APP"
        )
        XCTAssertEqual(controller.workspaceBarIconResolutionRevision, 1)

        currentImage = firstImage
        controller.refreshUnavailableWorkspaceBarIconOverride(
            bundleId: "com.example.app"
        )
        XCTAssertEqual(controller.workspaceBarIconResolutionRevision, 2)
        XCTAssertTrue(resolver.image(for: "com.example.app") === firstImage)

        currentImage = secondImage
        controller.refreshUnavailableWorkspaceBarIconOverride(
            bundleId: "com.example.app"
        )
        XCTAssertEqual(controller.workspaceBarIconResolutionRevision, 2)
        XCTAssertTrue(resolver.image(for: "com.example.app") === firstImage)
    }

    private func makeSettingsStore(at root: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
