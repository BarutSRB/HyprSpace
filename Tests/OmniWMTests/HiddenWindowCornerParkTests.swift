// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

/// Windows belonging to an inactive workspace are parked past a bottom corner of their display,
/// so the residue macOS insists on keeping on screen is a single square rather than a hairline
/// running the whole height of the window.
final class HiddenWindowCornerParkTests: XCTestCase {
    private let reveal: CGFloat = 1.0

    private let main = HiddenPlacementMonitorContext(
        id: Monitor.ID(displayId: 900_200),
        frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
        visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
    )

    private func park(
        size: CGSize,
        side: HideSide,
        targetY: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGPoint {
        HiddenWindowPlacementResolver.physicalScreenEdgeOrigin(
            for: size,
            requestedSide: side,
            targetY: targetY,
            baseReveal: reveal,
            scale: 2.0,
            monitor: monitor,
            monitors: monitors
        )
    }

    func testParkLeavesOnlyARevealSquareOnScreen() {
        let size = CGSize(width: 3360, height: 1860)
        let origin = park(size: size, side: .right, targetY: 0, monitor: main, monitors: [main])

        // Parking sideways would leave `reveal` x 1860 of the window showing down the edge.
        XCTAssertEqual(
            CGRect(origin: origin, size: size).intersection(main.frame),
            CGRect(x: main.frame.maxX - reveal, y: main.frame.minY, width: reveal, height: reveal)
        )
    }

    func testParkTakesTheWindowPastTheDisplayBottom() {
        let size = CGSize(width: 3360, height: 1860)
        let origin = park(size: size, side: .right, targetY: 0, monitor: main, monitors: [main])

        XCTAssertEqual(origin.x, main.frame.maxX - reveal)
        XCTAssertEqual(origin.y, main.frame.minY - size.height + reveal)
    }

    /// The residue belongs at the physical bottom edge, underneath a Dock parked on that edge,
    /// not in the strip the Dock reserves - `visibleFrame` would leave it beside the Dock.
    func testParkClearsTheDockStripInsteadOfStoppingAtIt() {
        let docked = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 900_300),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 70, width: 1600, height: 900)
        )
        let size = CGSize(width: 200, height: 300)
        let origin = park(size: size, side: .right, targetY: 400, monitor: docked, monitors: [docked])

        XCTAssertEqual(origin.y, docked.frame.minY - size.height + reveal)
        XCTAssertEqual(
            CGRect(origin: origin, size: size).intersection(docked.frame),
            CGRect(x: docked.frame.maxX - reveal, y: docked.frame.minY, width: reveal, height: reveal)
        )
    }

    /// Laptop display sitting to the left of, and lower than, an external one. Leaving through
    /// the right corner would drop the whole body onto the external display.
    func testParkAvoidsTheCornerThatSpillsOntoANeighbouringDisplay() {
        let builtIn = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 900_100),
            frame: CGRect(x: -1800, y: 721, width: 1800, height: 1169),
            visibleFrame: CGRect(x: -1800, y: 721, width: 1800, height: 1130)
        )
        let size = CGSize(width: 1800, height: 1130)
        let origin = park(
            size: size,
            side: .right,
            targetY: 721,
            monitor: builtIn,
            monitors: [builtIn, main]
        )

        XCTAssertEqual(origin.x, builtIn.frame.minX - size.width + reveal)
        XCTAssertEqual(origin.y, builtIn.frame.minY - size.height + reveal)
        XCTAssertTrue(CGRect(origin: origin, size: size).intersection(main.frame).isNull)
    }

    /// macOS keeps a strip of the window's top edge on screen - 32pt for one app, 41pt for the
    /// next - so a settled park sits above the origin it was given. It still counts as parked,
    /// otherwise the unreachable origin is re-requested on every refresh and never verifies.
    func testClampedParkCountsAsParked() {
        let size = CGSize(width: 3360, height: 1860)
        let clamped = CGRect(
            origin: CGPoint(x: main.frame.maxX - reveal, y: main.frame.minY - size.height + 32),
            size: size
        )

        XCTAssertTrue(
            HiddenWindowPlacementResolver.isParked(
                frame: clamped,
                baseReveal: reveal,
                scale: 2.0,
                monitor: main,
                monitors: [main]
            )
        )
    }

    func testWindowStillOnScreenDoesNotCountAsParked() {
        let onScreen = CGRect(x: 0, y: 0, width: 3360, height: 1860)

        XCTAssertFalse(
            HiddenWindowPlacementResolver.isParked(
                frame: onScreen,
                baseReveal: reveal,
                scale: 2.0,
                monitor: main,
                monitors: [main]
            )
        )
    }

    /// Parked against an edge that a newly attached display now sits behind: the hairline is
    /// still a hairline, but the body is on that display, so the park has to be redone.
    func testParkSpillingOntoAnotherDisplayDoesNotCountAsParked() {
        let toTheRight = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 900_500),
            frame: CGRect(x: 3360, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 3360, y: 0, width: 1920, height: 1080)
        )
        let size = CGSize(width: 800, height: 600)
        let parked = CGRect(
            origin: CGPoint(x: main.frame.maxX - reveal, y: main.frame.minY - size.height + 32),
            size: size
        )

        XCTAssertFalse(
            HiddenWindowPlacementResolver.isParked(
                frame: parked,
                baseReveal: reveal,
                scale: 2.0,
                monitor: main,
                monitors: [main, toTheRight]
            )
        )
    }

    /// Zoom is parked flush with the edge instead of keeping a reveal, and has to settle too.
    func testFlushParkWithoutRevealCountsAsParked() {
        let size = CGSize(width: 800, height: 600)
        let flush = CGRect(
            origin: CGPoint(x: main.frame.maxX, y: main.frame.minY - size.height + 32),
            size: size
        )

        XCTAssertTrue(
            HiddenWindowPlacementResolver.isParked(
                frame: flush,
                baseReveal: 0,
                scale: 2.0,
                monitor: main,
                monitors: [main]
            )
        )
    }

    /// A display directly below catches both bottom corners. Side parking keeps the window's own
    /// row, which that display never covers, so it beats leaking a column onto it.
    func testParkFallsBackToTheSideEdgeWhenBothCornersSpill() {
        let top = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 900_400),
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let below = HiddenPlacementMonitorContext(
            id: Monitor.ID(displayId: 900_401),
            frame: CGRect(x: 0, y: -1000, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 0, y: -1000, width: 1000, height: 1000)
        )
        let size = CGSize(width: 400, height: 300)
        let origin = park(size: size, side: .right, targetY: 200, monitor: top, monitors: [top, below])

        XCTAssertEqual(origin, CGPoint(x: top.visibleFrame.maxX - reveal, y: 200))
        XCTAssertTrue(CGRect(origin: origin, size: size).intersection(below.frame).isNull)
    }
}
