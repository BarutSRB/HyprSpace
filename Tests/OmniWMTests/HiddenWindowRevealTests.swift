// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class HiddenWindowRevealTests: XCTestCase {
    private let monitor = HiddenPlacementMonitorContext(
        id: Monitor.ID(displayId: 900_100),
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
    )

    func testPositiveRevealIsOnePoint() {
        XCTAssertEqual(
            HiddenWindowPlacementResolver.effectiveReveal(baseReveal: 1.0),
            1.0
        )
    }

    func testZeroRevealStaysZero() {
        XCTAssertEqual(
            HiddenWindowPlacementResolver.effectiveReveal(baseReveal: 0),
            0
        )
    }

    func testHiddenWindowKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 230, height: 408)
        let origin = HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: size,
            requestedSide: .left,
            targetY: 268,
            baseReveal: 1.0,
            monitor: monitor,
            monitors: [monitor]
        )

        let onScreenWidth = (origin.x + size.width) - monitor.visibleFrame.minX
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
        XCTAssertEqual(origin.x.rounded(), origin.x)
    }

    func testTransientPlacementKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 893, height: 1130)
        let placement = HiddenWindowPlacementResolver.placement(
            for: size,
            requestedEdge: .minimum,
            orthogonalOrigin: 0,
            baseReveal: 1.0,
            orientation: .horizontal,
            monitor: monitor,
            monitors: [monitor]
        )

        let onScreenWidth = (placement.origin.x + size.width) - monitor.visibleFrame.minX
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
    }

    func testMaximumEdgeKeepsAtLeastOnePointOnScreen() {
        let size = CGSize(width: 893, height: 1130)
        let placement = HiddenWindowPlacementResolver.placement(
            for: size,
            requestedEdge: .maximum,
            orthogonalOrigin: 0,
            baseReveal: 1.0,
            orientation: .horizontal,
            monitor: monitor,
            monitors: [monitor]
        )

        let onScreenWidth = monitor.visibleFrame.maxX - placement.origin.x
        XCTAssertGreaterThanOrEqual(onScreenWidth, 1.0)
    }
}
