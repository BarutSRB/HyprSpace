// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class OverviewScrollInputTests: XCTestCase {
    func testVerticalDominanceKeepsSign() {
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 1, deltaY: -8), -8)
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: -1, deltaY: 8), 8)
    }

    func testHorizontalDominanceKeepsSign() {
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 9, deltaY: 2), 9)
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: -9, deltaY: 2), -9)
    }

    func testTiePrefersVertical() {
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 5, deltaY: 5), 5)
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: -5, deltaY: 5), 5)
    }

    func testEpsilonFiltersNoise() {
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 0.00005, deltaY: 0), 0)
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 0, deltaY: -0.00005), 0)
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 0, deltaY: 0.0002), 0.0002)
    }

    func testZeroInput() {
        XCTAssertEqual(OverviewScrollInput.dominantDelta(deltaX: 0, deltaY: 0), 0)
    }
}
