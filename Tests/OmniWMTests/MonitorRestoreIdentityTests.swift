// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MonitorRestoreIdentityTests: XCTestCase {
    private let displayUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let displayUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let displayUUIDC = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"

    func testRestoreAssignmentsFollowUUIDWhenRuntimeIdsSwap() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let previousA = monitor(id: 2, name: "Identical", uuid: displayUUIDA, x: 0)
        let previousB = monitor(id: 3, name: "Identical", uuid: displayUUIDB, x: 1440)
        let currentA = monitor(id: 3, name: "Identical", uuid: displayUUIDA, x: 0)
        let currentB = monitor(id: 2, name: "Identical", uuid: displayUUIDB, x: 1440)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousA),
                    workspaceId: workspaceA
                ),
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousB),
                    workspaceId: workspaceB
                )
            ],
            monitors: [currentA, currentB],
            workspaceExists: { _ in true }
        )

        XCTAssertEqual(assignments[currentA.id], workspaceA)
        XCTAssertEqual(assignments[currentB.id], workspaceB)
    }

    func testKnownUUIDMismatchUsesGeometryInsteadOfRecycledId() {
        let workspace = UUID()
        let previous = monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        let recycled = monitor(id: 2, name: "Display", uuid: displayUUIDB, x: 2000)
        let geometricMatch = monitor(id: 9, name: "Display", uuid: displayUUIDC, x: 0)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previous),
                    workspaceId: workspace
                )
            ],
            monitors: [recycled, geometricMatch],
            workspaceExists: { _ in true }
        )

        XCTAssertNil(assignments[recycled.id])
        XCTAssertEqual(assignments[geometricMatch.id], workspace)
    }

    func testUUIDLessSnapshotCanUseExactRuntimeIdAndName() {
        let workspace = UUID()
        let previous = monitor(id: 2, name: "Display", uuid: nil, x: 0)
        let exactRuntime = monitor(id: 2, name: "Display", uuid: nil, x: 2000)
        let geometricMatch = monitor(id: 9, name: "Display", uuid: nil, x: 0)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previous),
                    workspaceId: workspace
                )
            ],
            monitors: [exactRuntime, geometricMatch],
            workspaceExists: { _ in true }
        )

        XCTAssertEqual(assignments[exactRuntime.id], workspace)
        XCTAssertNil(assignments[geometricMatch.id])
    }

    func testDuplicateUUIDsSkipIdentityAndRemainOneToOneByGeometry() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let previousA = monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        let previousB = monitor(id: 3, name: "Display", uuid: displayUUIDA, x: 1440)
        let currentA = monitor(id: 8, name: "Display", uuid: displayUUIDA, x: 0)
        let currentB = monitor(id: 9, name: "Display", uuid: displayUUIDA, x: 1440)

        let assignments = resolveWorkspaceRestoreAssignments(
            snapshots: [
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousA),
                    workspaceId: workspaceA
                ),
                WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: previousB),
                    workspaceId: workspaceB
                )
            ],
            monitors: [currentA, currentB],
            workspaceExists: { _ in true }
        )

        XCTAssertEqual(assignments[currentA.id], workspaceA)
        XCTAssertEqual(assignments[currentB.id], workspaceB)
        XCTAssertEqual(Set(assignments.values).count, 2)
    }

    func testRestoreKeysUseStableUUIDIdentity() {
        let first = MonitorRestoreKey(
            monitor: monitor(id: 2, name: "Old", uuid: displayUUIDA, x: 0)
        )
        let second = MonitorRestoreKey(
            monitor: monitor(id: 9, name: "New", uuid: displayUUIDA, x: 2000)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testDisplayFingerprintRoundTripsUUIDAndDecodesMissingUUID() throws {
        let fingerprint = DisplayFingerprint(
            monitor: monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        )
        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(DisplayFingerprint.self, from: data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "displayUUID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(DisplayFingerprint.self, from: legacyData)

        XCTAssertEqual(decoded, fingerprint)
        XCTAssertEqual(decoded.displayUUID, displayUUIDA)
        XCTAssertNil(legacy.displayUUID)
    }

    func testDisplayFingerprintRejectsMalformedPersistedUUID() throws {
        let fingerprint = DisplayFingerprint(
            monitor: monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        )
        let data = try JSONEncoder().encode(fingerprint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["displayUUID"] = "not-a-uuid"
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(DisplayFingerprint.self, from: malformed))
    }

    func testPersistedHydrationFollowsUUIDAcrossRecycledRuntimeId() throws {
        let previous = monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        let recycled = monitor(id: 2, name: "Display", uuid: displayUUIDB, x: 2000)
        let current = monitor(id: 9, name: "Renamed", uuid: displayUUIDA, x: 0)

        let preferredMonitorId = try persistedPreferredMonitor(
            previous: previous,
            current: [recycled, current]
        )

        XCTAssertEqual(preferredMonitorId, current.id)
    }

    func testPersistedHydrationUUIDMismatchUsesGeometryInsteadOfRecycledId() throws {
        let previous = monitor(id: 2, name: "Display", uuid: displayUUIDA, x: 0)
        let recycled = monitor(id: 2, name: "Display", uuid: displayUUIDB, x: 2000)
        let geometricMatch = monitor(id: 9, name: "Display", uuid: displayUUIDC, x: 0)

        let preferredMonitorId = try persistedPreferredMonitor(
            previous: previous,
            current: [recycled, geometricMatch]
        )

        XCTAssertEqual(preferredMonitorId, geometricMatch.id)
    }

    func testPersistedHydrationUUIDLessFingerprintUsesRuntimeIdAndName() throws {
        let previous = monitor(id: 2, name: "Display", uuid: nil, x: 0)
        let exactRuntime = monitor(id: 2, name: "Display", uuid: nil, x: 2000)
        let geometricMatch = monitor(id: 9, name: "Display", uuid: nil, x: 0)

        let preferredMonitorId = try persistedPreferredMonitor(
            previous: previous,
            current: [exactRuntime, geometricMatch]
        )

        XCTAssertEqual(preferredMonitorId, exactRuntime.id)
    }

    private func monitor(
        id: CGDirectDisplayID,
        name: String,
        uuid: String?,
        x: CGFloat
    ) -> Monitor {
        Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: CGRect(x: x, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: x, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name,
            displayUUID: uuid
        )
    }

    private func persistedPreferredMonitor(
        previous: Monitor,
        current: [Monitor]
    ) throws -> Monitor.ID? {
        let workspaceId = UUID()
        let token = WindowToken(pid: 123, windowId: 456)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.identity",
            workspaceId: workspaceId,
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: "Window",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let entry = PersistedWindowRestoreEntry(
            key: try XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata)),
            identity: nil,
            restoreIntent: PersistedRestoreIntent(
                workspaceName: "1",
                topologyProfile: TopologyProfile(monitors: [previous]),
                preferredMonitor: DisplayFingerprint(monitor: previous),
                floatingFrame: nil,
                normalizedFloatingOrigin: nil,
                restoreToFloating: false,
                rescueEligible: false
            )
        )
        let plan = RestorePlanner().planPersistedHydration(
            RestorePlanner.PersistedHydrationInput(
                token: token,
                metadata: metadata,
                catalog: PersistedWindowRestoreCatalog(entries: [entry]),
                consumedEntries: [],
                monitors: current,
                workspaceIdForName: { $0 == "1" ? workspaceId : nil }
            )
        )
        return try XCTUnwrap(plan).preferredMonitorId
    }
}
