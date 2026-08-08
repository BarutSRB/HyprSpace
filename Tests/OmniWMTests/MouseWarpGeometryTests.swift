// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseWarpGeometryTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func testRightEdgeCrossingMapsToRightDirectionAndLeftEntry() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 999, y: 700), frame: frame, margin: 2)
        XCTAssertEqual(crossing?.direction, .right)
        XCTAssertEqual(crossing?.entryEdge, .left)
        XCTAssertEqual(crossing?.ratio ?? -1, 0.3, accuracy: 0.0001)
    }

    func testLeftEdgeCrossingMapsToLeftDirectionAndRightEntry() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 1, y: 250), frame: frame, margin: 2)
        XCTAssertEqual(crossing?.direction, .left)
        XCTAssertEqual(crossing?.entryEdge, .right)
    }

    func testTopAndBottomEdgesMapToUpAndDown() {
        let top = MouseWarpGeometry.crossing(location: CGPoint(x: 400, y: 999), frame: frame, margin: 2)
        XCTAssertEqual(top?.direction, .up)
        XCTAssertEqual(top?.entryEdge, .bottom)

        let bottom = MouseWarpGeometry.crossing(location: CGPoint(x: 400, y: 1), frame: frame, margin: 2)
        XCTAssertEqual(bottom?.direction, .down)
        XCTAssertEqual(bottom?.entryEdge, .top)
    }

    func testInteriorLocationDoesNotCross() {
        XCTAssertNil(MouseWarpGeometry.crossing(location: CGPoint(x: 500, y: 500), frame: frame, margin: 2))
    }

    func testProportionalPlacementPreservedOnSideBySideNeighbor() {
        let crossing = MouseWarpGeometry.crossing(location: CGPoint(x: 999, y: 700), frame: frame, margin: 2)
        let target = CGRect(x: 5000, y: 0, width: 1000, height: 1000)
        let destination = MouseWarpGeometry.destinationPoint(
            on: target,
            entryEdge: crossing?.entryEdge ?? .left,
            ratio: crossing?.ratio ?? 0,
            margin: 2
        )
        XCTAssertEqual(destination.x, 5003, accuracy: 0.5)
        XCTAssertEqual(destination.y, 700, accuracy: 0.5)
    }

    func testProportionalPlacementPreservedWhenNeighborIsPhysicallyBelow() {
        let target = CGRect(x: 0, y: -1000, width: 1000, height: 1000)
        let destination = MouseWarpGeometry.destinationPoint(on: target, entryEdge: .left, ratio: 0.3, margin: 2)
        XCTAssertEqual(destination.x, 3, accuracy: 0.5)
        XCTAssertEqual(destination.y, -300, accuracy: 0.5)
    }

    func testEndpointAndOutOfRangeRatiosStayClearOfEveryCrossingBand() {
        let target = CGRect(x: -500, y: -300, width: 1000, height: 800)
        let cases: [(MouseWarpGeometry.Edge, CGPoint, CGPoint)] = [
            (.left, CGPoint(x: -497, y: 484), CGPoint(x: -497, y: -284)),
            (.right, CGPoint(x: 497, y: 484), CGPoint(x: 497, y: -284)),
            (.top, CGPoint(x: -484, y: 497), CGPoint(x: 484, y: 497)),
            (.bottom, CGPoint(x: -484, y: -297), CGPoint(x: 484, y: -297))
        ]

        for (entryEdge, lowExpected, highExpected) in cases {
            for ratio in [CGFloat(-0.5), 0] {
                let destination = MouseWarpGeometry.destinationPoint(
                    on: target,
                    entryEdge: entryEdge,
                    ratio: ratio,
                    margin: 2
                )
                XCTAssertEqual(destination, lowExpected, "\(entryEdge) ratio \(ratio)")
                XCTAssertNil(MouseWarpGeometry.crossing(location: destination, frame: target, margin: 2))
            }
            for ratio in [CGFloat(1), 1.5] {
                let destination = MouseWarpGeometry.destinationPoint(
                    on: target,
                    entryEdge: entryEdge,
                    ratio: ratio,
                    margin: 2
                )
                XCTAssertEqual(destination, highExpected, "\(entryEdge) ratio \(ratio)")
                XCTAssertNil(MouseWarpGeometry.crossing(location: destination, frame: target, margin: 2))
            }
        }
    }

    func testIssue541DestinationIsCornerSafeAndDoesNotRearm() {
        let target = CGRect(x: 3360, y: 1418, width: 1080, height: 1920)
        let destination = MouseWarpGeometry.destinationPoint(
            on: target,
            entryEdge: .right,
            ratio: 1,
            margin: 1
        )

        XCTAssertEqual(destination, CGPoint(x: 4438, y: 1434))
        XCTAssertTrue(target.contains(destination))
        XCTAssertNil(MouseWarpGeometry.crossing(location: destination, frame: target, margin: 1))
    }

    func testTinyNegativeOriginFramesUseMidpointOnTheTangentAxis() {
        let target = CGRect(x: -20, y: -10, width: 20, height: 20)

        XCTAssertEqual(
            MouseWarpGeometry.destinationPoint(on: target, entryEdge: .left, ratio: 0, margin: 1),
            CGPoint(x: -18, y: 0)
        )
        XCTAssertEqual(
            MouseWarpGeometry.destinationPoint(on: target, entryEdge: .top, ratio: 0, margin: 1),
            CGPoint(x: -10, y: 8)
        )
    }

    func testZeroSizedFramesUseMidpointOnBothAxes() {
        let target = CGRect(x: -40, y: -30, width: 0, height: 0)

        for entryEdge in [
            MouseWarpGeometry.Edge.left,
            .right,
            .top,
            .bottom
        ] {
            for ratio in [CGFloat(-1), 0, 1, 2] {
                XCTAssertEqual(
                    MouseWarpGeometry.destinationPoint(
                        on: target,
                        entryEdge: entryEdge,
                        ratio: ratio,
                        margin: 1
                    ),
                    target.origin
                )
            }
        }
    }

    func testNegativeMarginKeepsEntryAxisInsideFrame() {
        let destination = MouseWarpGeometry.destinationPoint(
            on: frame,
            entryEdge: .left,
            ratio: 0.5,
            margin: -10
        )

        XCTAssertEqual(destination, CGPoint(x: 1, y: 500))
    }
}
