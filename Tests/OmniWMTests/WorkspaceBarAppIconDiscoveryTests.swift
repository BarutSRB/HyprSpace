// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarAppIconDiscoveryTests: XCTestCase {
    func testAssetCatalogDescriptorsKeepIconVariantsAndDeduplicateRenditions() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["AssetStorageVersion": "IBCocoaTouchImageCatalogTool"],
            [
                "Name": "AppIconDark",
                "AssetType": "Image",
                "PixelWidth": 1024,
                "PixelHeight": 1024,
                "Scale": 1
            ],
            [
                "Name": "AppIconDark",
                "AssetType": "Image",
                "PixelWidth": 512,
                "PixelHeight": 512,
                "Scale": 2
            ],
            [
                "Name": "AppIconLight",
                "AssetType": "Image",
                "PixelWidth": 1024,
                "PixelHeight": 1024
            ],
            [
                "Name": "SidebarIcon",
                "AssetType": "Image",
                "PixelWidth": 256,
                "PixelHeight": 256
            ],
            [
                "Name": "IconDarkTiny",
                "AssetType": "Image",
                "PixelWidth": 32,
                "PixelHeight": 32
            ],
            [
                "Name": "AppIcon_Assets/Color-1",
                "AssetType": "Color",
                "PixelWidth": 1024,
                "PixelHeight": 1024
            ]
        ])

        let descriptors = WorkspaceBarAppIconScanner.assetCatalogDescriptors(from: data)

        XCTAssertEqual(
            Set(descriptors.map(\.resourceName)),
            Set(["AppIconDark", "AppIconLight"])
        )
        XCTAssertEqual(
            descriptors.filter { $0.resourceName == "AppIconDark" }.count,
            1
        )
    }

    func testDeclaredIconBypassesHeuristicsAndSmallSizeFilter() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "Name": "BrandMark",
                "AssetType": "Image",
                "PixelWidth": 32,
                "PixelHeight": 24
            ]
        ])

        let descriptors = WorkspaceBarAppIconScanner.assetCatalogDescriptors(
            from: data,
            declaredNames: ["BrandMark"]
        )

        XCTAssertEqual(descriptors.map(\.resourceName), ["BrandMark"])
        XCTAssertEqual(descriptors.first?.score, 1_000)
    }

    func testScannerFindsDeclaredAndLooseIconsWithoutAssetCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMAppIconDiscoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let contentsURL = root.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIconFile": "BrandMark.icns",
                "CFBundleIcons": [
                    "CFBundleAlternateIcons": [
                        "Blue": [
                            "CFBundleIconFiles": ["AlternateBrand"]
                        ]
                    ]
                ]
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data().write(to: resourcesURL.appendingPathComponent("BrandMark.icns"))
        try Data().write(to: resourcesURL.appendingPathComponent("AlternateBrand.png"))
        try Data().write(to: resourcesURL.appendingPathComponent("DockIconDark.png"))
        try Data().write(to: resourcesURL.appendingPathComponent("ToolbarIcon.png"))

        let descriptors = await WorkspaceBarAppIconScanner.scan(bundleURL: root)

        XCTAssertEqual(
            Set(descriptors.map(\.resourceName)),
            Set(["AlternateBrand", "BrandMark", "DockIconDark"])
        )
    }

    func testDiscoveryResolvesLoadsAndCachesCandidates() async throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/cmux.app")
        let darkImage = NSImage(size: NSSize(width: 64, height: 64))
        let lightImage = NSImage(size: NSSize(width: 64, height: 64))
        var loadedNames: [String] = []
        let descriptors = [
            WorkspaceBarAppIconDescriptor(
                resourceName: "AppIconDark",
                assetType: "Image",
                pixelWidth: 1024,
                pixelHeight: 1024,
                isDeclared: false,
                score: 900
            ),
            WorkspaceBarAppIconDescriptor(
                resourceName: "AppIconLight",
                assetType: "Image",
                pixelWidth: 1024,
                pixelHeight: 1024,
                isDeclared: false,
                score: 900
            )
        ]
        let discovery = WorkspaceBarAppIconDiscovery(
            descriptorLoader: { _ in descriptors },
            bundleURLResolver: { _ in bundleURL },
            imageLoader: { _, name in
                loadedNames.append(name)
                return name == "AppIconDark" ? darkImage : lightImage
            }
        )

        let first = await discovery.discover(
            bundleId: "com.cmuxterm.app",
            preferredBundleURL: nil
        )
        let second = await discovery.discover(
            bundleId: "com.cmuxterm.app",
            preferredBundleURL: nil
        )

        XCTAssertEqual(first.bundleURL, bundleURL)
        XCTAssertEqual(first.candidates.map(\.resourceName), [
            "AppIconDark",
            "AppIconLight"
        ])
        XCTAssertTrue(first.candidates[0].image === darkImage)
        XCTAssertEqual(second.candidates.map(\.resourceName), [
            "AppIconDark",
            "AppIconLight"
        ])
        XCTAssertEqual(loadedNames, ["AppIconDark", "AppIconLight"])
    }

    func testDiscoveryReportsMissingBundle() async {
        let discovery = WorkspaceBarAppIconDiscovery(
            descriptorLoader: { _ in [] },
            bundleURLResolver: { _ in nil },
            imageLoader: { _, _ in nil }
        )

        let result = await discovery.discover(
            bundleId: "com.example.missing",
            preferredBundleURL: nil
        )

        XCTAssertNil(result.bundleURL)
        XCTAssertTrue(result.candidates.isEmpty)
    }
}
