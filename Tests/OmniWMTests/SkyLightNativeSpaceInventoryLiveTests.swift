// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SkyLightNativeSpaceInventoryLiveTests: XCTestCase {
    func testLiveTransactionMoveIsObservedThroughWindowServerBounds() async throws {
        try requireLiveTestsEnabled()
        let sky = SkyLight.shared
        let wid = sky.createBorderWindow(frame: CGRect(x: -9000, y: -9000, width: 10, height: 10))
        guard wid != 0 else {
            throw XCTSkip("Unable to create an owned SkyLight test window")
        }
        defer { sky.releaseBorderWindow(wid) }
        _ = sky.configureWindow(wid, resolution: 1, opaque: false)
        let initialBounds = try XCTUnwrap(sky.getWindowBounds(wid))
        defer { _ = sky.moveWindow(wid, to: initialBounds.origin) }
        let nestedTarget = CGPoint(x: initialBounds.origin.x + 4, y: initialBounds.origin.y + 4)
        let scopedTarget = CGPoint(x: initialBounds.origin.x + 8, y: initialBounds.origin.y + 8)
        var scopedSubmission: SkyLight.TransactionSubmissionResult?

        sky.withTransactionScope {
            sky.transactionMove(wid, origin: nestedTarget)
            scopedSubmission = sky.batchMoveWindows([(windowId: wid, origin: scopedTarget)])
        }

        XCTAssertEqual(scopedSubmission, .deferred)
        let scopedMovedBounds = await observedBounds(of: wid, matching: scopedTarget)
        XCTAssertEqual(scopedMovedBounds?.size, initialBounds.size)
        XCTAssertTrue(sky.moveWindow(wid, to: initialBounds.origin))
        let scopedRestoredBounds = await observedBounds(of: wid, matching: initialBounds.origin)
        XCTAssertEqual(scopedRestoredBounds?.size, initialBounds.size)

        let submittedTarget = CGPoint(x: initialBounds.origin.x + 12, y: initialBounds.origin.y + 12)
        let submitted = sky.batchMoveWindows([(windowId: wid, origin: submittedTarget)])
        XCTAssertEqual(submitted, .submitted)
        let submittedMovedBounds = await observedBounds(of: wid, matching: submittedTarget)
        XCTAssertEqual(submittedMovedBounds?.size, initialBounds.size)
        XCTAssertTrue(sky.moveWindow(wid, to: initialBounds.origin))
        let submittedRestoredBounds = await observedBounds(of: wid, matching: initialBounds.origin)
        XCTAssertEqual(submittedRestoredBounds?.size, initialBounds.size)

        let orderedWid = sky.createBorderWindow(frame: CGRect(x: -8960, y: -9000, width: 10, height: 10))
        guard orderedWid != 0 else {
            throw XCTSkip("Unable to create a second owned SkyLight test window")
        }
        defer { sky.releaseBorderWindow(orderedWid) }
        _ = sky.configureWindow(orderedWid, resolution: 1, opaque: false)
        let orderedInitialInfo = try XCTUnwrap(sky.queryWindowInfo(orderedWid))
        let alternateLevel: Int32 = orderedInitialInfo.level == 3 ? 0 : 3
        let orderedTarget = CGPoint(
            x: orderedInitialInfo.frame.origin.x + 8,
            y: orderedInitialInfo.frame.origin.y + 8
        )

        sky.orderWindow(wid, relativeTo: 0)
        sky.withTransactionScope {
            sky.transactionMoveAndOrder(
                orderedWid,
                origin: orderedTarget,
                level: alternateLevel,
                relativeTo: wid,
                order: .below
            )
        }

        let orderedMovedInfo = await observedWindowInfo(
            of: orderedWid,
            matching: orderedTarget,
            level: alternateLevel
        )
        XCTAssertEqual(orderedMovedInfo?.frame.size, orderedInitialInfo.frame.size)
        XCTAssertEqual(sky.isWindowOrderedIn(orderedWid), true)

        sky.transactionMoveAndOrder(
            orderedWid,
            origin: orderedInitialInfo.frame.origin,
            level: orderedInitialInfo.level,
            relativeTo: 0,
            order: .above
        )
        let orderedRestoredInfo = await observedWindowInfo(
            of: orderedWid,
            matching: orderedInitialInfo.frame.origin,
            level: orderedInitialInfo.level
        )
        XCTAssertEqual(orderedRestoredInfo?.frame.size, orderedInitialInfo.frame.size)
    }

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
        try requireLiveTestsEnabled()
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

    private func requireLiveTestsEnabled() throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1 to run private SkyLight integration tests")
        }
    }

    private func observedBounds(of wid: UInt32, matching origin: CGPoint) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        repeat {
            if let bounds = SkyLight.shared.getWindowBounds(wid),
               abs(bounds.origin.x - origin.x) < 2,
               abs(bounds.origin.y - origin.y) < 2
            {
                return bounds
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        } while clock.now < deadline
        return nil
    }

    private func observedWindowInfo(
        of wid: UInt32,
        matching origin: CGPoint,
        level: Int32
    ) async -> WindowServerInfo? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        repeat {
            if let info = SkyLight.shared.queryWindowInfo(wid),
               info.level == level,
               abs(info.frame.origin.x - origin.x) < 2,
               abs(info.frame.origin.y - origin.y) < 2
            {
                return info
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        } while clock.now < deadline
        return nil
    }
}
