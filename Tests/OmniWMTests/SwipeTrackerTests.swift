// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class SwipeTrackerTests: XCTestCase {
    func testVelocityUsesTrailingWindowAverage() {
        let tracker = SwipeTracker()

        tracker.push(delta: 10, timestamp: 1.000)
        tracker.push(delta: 10, timestamp: 1.025)
        tracker.push(delta: 10, timestamp: 1.050)
        tracker.push(delta: 10, timestamp: 1.075)
        tracker.push(delta: 10, timestamp: 1.100)

        XCTAssertEqual(tracker.velocity(), 40.0 / 0.075, accuracy: 0.001)
    }

    func testVelocityDropsToZeroAfterStillTail() {
        let tracker = SwipeTracker()

        tracker.push(delta: 120, timestamp: 1.00)
        tracker.push(delta: 0, timestamp: 1.04)
        tracker.push(delta: 0, timestamp: 1.08)

        XCTAssertEqual(tracker.velocity(), 0, accuracy: 0.001)
    }

    func testPartialStillTailDilutesVelocity() {
        let tracker = SwipeTracker()

        tracker.push(delta: 60, timestamp: 1.00)
        tracker.push(delta: 60, timestamp: 1.02)
        tracker.push(delta: 0, timestamp: 1.04)
        tracker.push(delta: 0, timestamp: 1.06)

        XCTAssertGreaterThan(tracker.velocity(), 0)
        XCTAssertLessThan(tracker.velocity(), 6000)
    }

    func testSingleSampleVelocityIsZero() {
        let tracker = SwipeTracker()

        tracker.push(delta: 120, timestamp: 1.00)

        XCTAssertEqual(tracker.velocity(), 0)
    }

    func testOutOfOrderPushIsIgnored() {
        let tracker = SwipeTracker()

        tracker.push(delta: 40, timestamp: 1.00)
        tracker.push(delta: 40, timestamp: 1.04)
        tracker.push(delta: 400, timestamp: 1.03)

        XCTAssertEqual(tracker.position, 80)
        XCTAssertEqual(tracker.velocity(), 2000, accuracy: 0.001)
    }

    func testNonfiniteSamplesAreRejectedWithoutPoisoningState() {
        let tracker = SwipeTracker()

        XCTAssertTrue(tracker.push(delta: 40, timestamp: 1))
        XCTAssertFalse(tracker.push(delta: .nan, timestamp: 1.01))
        XCTAssertFalse(tracker.push(delta: 40, timestamp: .infinity))

        XCTAssertEqual(tracker.position, 40)
        XCTAssertTrue(tracker.velocity().isFinite)
    }
}
