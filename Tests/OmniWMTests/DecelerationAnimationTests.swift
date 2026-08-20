// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DecelerationAnimationTests: XCTestCase {
    private let decay = 1000.0 * log(DecelerationAnimation.decelerationRate)

    func testSettlesAtProjectedEndpoint() {
        let animation = DecelerationAnimation(from: 0, velocity: 300, startTime: 0)
        let expected = 0 - 300 / decay

        XCTAssertEqual(animation.restingOffset, expected, accuracy: 0.001)
        XCTAssertEqual(animation.value(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(animation.velocity(at: 0), 300, accuracy: 0.001)
        XCTAssertEqual(animation.value(at: 10), expected, accuracy: 0.01)
        XCTAssertTrue(animation.isComplete(at: 10))
    }

    func testZeroVelocitySettlesImmediately() {
        let animation = DecelerationAnimation(from: 42, velocity: 0, startTime: 0)

        XCTAssertEqual(animation.restingOffset, 42, accuracy: 0.0001)
        XCTAssertEqual(animation.value(at: 0), 42, accuracy: 0.0001)
        XCTAssertTrue(animation.isComplete(at: 0))
    }

    func testOffsetByShiftsLiveValue() {
        let animation = DecelerationAnimation(from: 0, velocity: 300, startTime: 0)
        let before = animation.value(at: 1.0)
        animation.offsetBy(25)

        XCTAssertEqual(animation.value(at: 1.0), before + 25, accuracy: 0.001)
    }

    func testNonfiniteInputsSettleImmediatelyAtFiniteValue() {
        let invalidOrigin = DecelerationAnimation(from: .nan, velocity: .infinity, startTime: .nan)
        XCTAssertTrue(invalidOrigin.value(at: 0).isFinite)
        XCTAssertTrue(invalidOrigin.restingOffset.isFinite)
        XCTAssertTrue(invalidOrigin.isComplete(at: 0))

        let invalidTime = DecelerationAnimation(from: 42, velocity: 300, startTime: 0)
        XCTAssertEqual(invalidTime.value(at: .nan), invalidTime.restingOffset)
        XCTAssertTrue(invalidTime.isComplete(at: .infinity))
    }

    func testNonfiniteRebaseEndsAnimation() {
        let animation = DecelerationAnimation(from: 0, velocity: 300, startTime: 0)
        animation.offsetBy(.nan)

        XCTAssertTrue(animation.isComplete(at: 0))
        XCTAssertTrue(animation.value(at: 0).isFinite)
    }
}
