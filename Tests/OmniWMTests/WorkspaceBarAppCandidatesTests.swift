// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarAppCandidatesTests: XCTestCase {
    func testBuildMergesManagedAppsAndConfiguredOfflineBundleIDsCaseInsensitively() throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16))

        let candidates = WorkspaceBarAppCandidates.build(
            managedApps: [
                WorkspaceBarManagedAppCandidate(
                    bundleID: "com.example.Managed",
                    name: nil,
                    icon: nil,
                    bundleURL: nil
                ),
                WorkspaceBarManagedAppCandidate(
                    bundleID: "COM.EXAMPLE.MANAGED",
                    name: "Managed",
                    icon: icon,
                    bundleURL: URL(fileURLWithPath: "/Applications/Managed.app")
                ),
                WorkspaceBarManagedAppCandidate(
                    bundleID: "  ",
                    name: "Ignored",
                    icon: nil,
                    bundleURL: nil
                )
            ],
            configuredBundleIDs: [
                "com.Example.Managed",
                "com.example.Offline",
                "\n"
            ]
        )

        XCTAssertEqual(candidates.map(\.bundleID), [
            "com.example.Offline",
            "com.Example.Managed"
        ])

        let managed = try XCTUnwrap(
            candidates.first {
                $0.bundleID.caseInsensitiveCompare("com.example.managed") == .orderedSame
            }
        )
        XCTAssertEqual(managed.name, "Managed")
        XCTAssertTrue(managed.icon === icon)
        XCTAssertTrue(managed.isManaged)
        XCTAssertEqual(
            managed.bundleURL,
            URL(fileURLWithPath: "/Applications/Managed.app")
        )

        let offline = try XCTUnwrap(
            candidates.first {
                $0.bundleID.caseInsensitiveCompare("com.example.offline") == .orderedSame
            }
        )
        XCTAssertNil(offline.name)
        XCTAssertNil(offline.icon)
        XCTAssertFalse(offline.isManaged)
    }

    func testBuildSortsByDisplayNameThenBundleID() {
        let candidates = WorkspaceBarAppCandidates.build(
            managedApps: [
                WorkspaceBarManagedAppCandidate(
                    bundleID: "com.example.zulu",
                    name: "Beta",
                    icon: nil,
                    bundleURL: nil
                ),
                WorkspaceBarManagedAppCandidate(
                    bundleID: "com.example.alpha",
                    name: "alpha",
                    icon: nil,
                    bundleURL: nil
                ),
                WorkspaceBarManagedAppCandidate(
                    bundleID: "com.example.beta",
                    name: "Alpha",
                    icon: nil,
                    bundleURL: nil
                )
            ],
            configuredBundleIDs: ["com.example.offline"]
        )

        XCTAssertEqual(candidates.map(\.bundleID), [
            "com.example.alpha",
            "com.example.beta",
            "com.example.zulu",
            "com.example.offline"
        ])
    }

    func testBundleIDNormalizationTrimsAndRejectsEmptyValues() {
        XCTAssertEqual(
            WorkspaceBarAppCandidates.normalizedBundleID("  com.example.App \n"),
            "com.example.App"
        )
        XCTAssertNil(WorkspaceBarAppCandidates.normalizedBundleID(" \n"))
        XCTAssertNil(WorkspaceBarAppCandidates.normalizedBundleID(nil))
    }
}
