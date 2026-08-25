// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class SpringAnimationTests: XCTestCase {
    func testZeroDampingSettlesImmediately() {
        let animation = SpringAnimation(
            from: 10,
            to: 100,
            startTime: 0,
            config: SpringConfig(
                dampingRatio: 0,
                stiffness: 800,
                epsilon: 0.0001,
                velocityEpsilon: 0.01
            )
        )

        XCTAssertEqual(animation.value(at: 0), 100)
        XCTAssertEqual(animation.velocity(at: 0), 0)
        XCTAssertTrue(animation.isComplete(at: 0))
    }

    func testNonpositiveCompletionThresholdsSettleImmediately() {
        let animation = SpringAnimation(
            from: 10,
            to: 100,
            startTime: 0,
            config: SpringConfig(
                dampingRatio: 1,
                stiffness: 800,
                epsilon: 0,
                velocityEpsilon: 0
            )
        )

        XCTAssertEqual(animation.value(at: 0), 100)
        XCTAssertTrue(animation.isComplete(at: 0))
    }

    func testNonfiniteInputsAndTimeFailClosed() {
        let animation = SpringAnimation(
            from: .nan,
            to: .infinity,
            initialVelocity: .nan,
            startTime: .infinity,
            config: SpringConfig(
                dampingRatio: .nan,
                stiffness: .infinity,
                epsilon: .nan,
                velocityEpsilon: .infinity
            ),
            displayRefreshRate: .nan
        )

        XCTAssertTrue(animation.value(at: 0).isFinite)
        XCTAssertEqual(animation.velocity(at: 0), 0)
        XCTAssertTrue(animation.isComplete(at: 0))
        XCTAssertTrue(animation.isComplete(at: .nan))
    }

    func testNonfiniteRebaseEndsAnimationAtFiniteTarget() {
        let animation = SpringAnimation(from: 0, to: 100, startTime: 0)
        animation.offsetBy(.infinity)

        XCTAssertTrue(animation.value(at: 0).isFinite)
        XCTAssertTrue(animation.isComplete(at: 0))
    }
}
