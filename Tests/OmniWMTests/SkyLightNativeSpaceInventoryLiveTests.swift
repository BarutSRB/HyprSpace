// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SkyLightNativeSpaceInventoryLiveTests: XCTestCase {
    func testLiveNativeSpaceInventoryReturnsCompleteDeduplicatedDetails() throws {
        let spaceIds = try liveSpaceIds()
        let inventory = try authoritativeInventory(spaceIds: spaceIds)

        XCTAssertEqual(Set(inventory.keys), spaceIds)
        for windows in inventory.values {
            XCTAssertTrue(windows.allSatisfy { $0.id != 0 })
            XCTAssertEqual(Set(windows.map(\.id)).count, windows.count)
        }
    }

    func testRepeatedLiveNativeSpaceInventoryQueriesRemainUsable() throws {
        let spaceIds = try liveSpaceIds()
        var authoritativeQueryCount = 0

        for _ in 0 ..< 256 {
            switch SkyLight.shared.nativeSpaceWindowInventory(spaceIds: spaceIds) {
            case .authoritative:
                authoritativeQueryCount += 1
            case .queryFailed:
                continue
            case .unavailable:
                throw XCTSkip("SLSCopyWindowsWithOptionsAndTags is unavailable")
            }
        }

        XCTAssertGreaterThan(authoritativeQueryCount, 0)
    }

    private func liveSpaceIds() throws -> Set<UInt64> {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 to run private SkyLight integration tests")
        }
        let spaceIds = Set(SkyLight.shared.managedSpaces().map(\.currentSpaceId))
        guard !spaceIds.isEmpty, !spaceIds.contains(0) else {
            throw XCTSkip("No usable native Space inventory is available")
        }
        return spaceIds
    }

    private func authoritativeInventory(
        spaceIds: Set<UInt64>
    ) throws -> [UInt64: [WindowServerInfo]] {
        switch SkyLight.shared.nativeSpaceWindowInventory(spaceIds: spaceIds) {
        case let .authoritative(inventory):
            inventory
        case .queryFailed:
            throw XCTSkip("The live native Space inventory changed during the query")
        case .unavailable:
            throw XCTSkip("SLSCopyWindowsWithOptionsAndTags is unavailable")
        }
    }
}
