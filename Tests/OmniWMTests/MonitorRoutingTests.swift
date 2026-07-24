// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MonitorRoutingTests: XCTestCase {
    private func makeMonitor(_ displayId: CGDirectDisplayID, _ name: String) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            hasNotch: false,
            name: name
        )
    }

    private func routing(
        _ displayId: CGDirectDisplayID,
        _ name: String,
        _ column: Int,
        _ row: Int
    ) -> MonitorRoutingSettings {
        MonitorRoutingSettings(monitorName: name, monitorDisplayId: displayId, gridColumn: column, gridRow: row)
    }

    private func adjacent(
        from source: Monitor,
        _ direction: Direction,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor],
        wrap: Bool = false
    ) -> MonitorRouting.Adjacency {
        MonitorRouting.gridAdjacent(
            from: source,
            direction: direction,
            layout: layout,
            monitors: monitors,
            wrapAround: wrap
        )
    }

    func testHorizontalPairResolvesLeftRight() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let monitors = [a, b]
        let layout = [routing(1, "A", 0, 0), routing(2, "B", 1, 0)]

        XCTAssertEqual(adjacent(from: a, .right, layout: layout, monitors: monitors), .monitor(b))
        XCTAssertEqual(adjacent(from: b, .left, layout: layout, monitors: monitors), .monitor(a))
        XCTAssertEqual(adjacent(from: a, .left, layout: layout, monitors: monitors), .edge)
        XCTAssertEqual(adjacent(from: a, .up, layout: layout, monitors: monitors), .edge)
        XCTAssertEqual(adjacent(from: a, .down, layout: layout, monitors: monitors), .edge)
    }

    func testVerticalPairResolvesUpDownWithSmallerRowAsUp() {
        let top = makeMonitor(1, "Top")
        let bottom = makeMonitor(2, "Bottom")
        let monitors = [top, bottom]
        let layout = [routing(1, "Top", 0, 0), routing(2, "Bottom", 0, 1)]

        XCTAssertEqual(adjacent(from: bottom, .up, layout: layout, monitors: monitors), .monitor(top))
        XCTAssertEqual(adjacent(from: top, .down, layout: layout, monitors: monitors), .monitor(bottom))
        XCTAssertEqual(adjacent(from: top, .up, layout: layout, monitors: monitors), .edge)
    }

    func testTwoByTwoResolvesAllDirections() {
        let topLeft = makeMonitor(1, "TL")
        let topRight = makeMonitor(2, "TR")
        let bottomLeft = makeMonitor(3, "BL")
        let bottomRight = makeMonitor(4, "BR")
        let monitors = [topLeft, topRight, bottomLeft, bottomRight]
        let layout = [
            routing(1, "TL", 0, 0),
            routing(2, "TR", 1, 0),
            routing(3, "BL", 0, 1),
            routing(4, "BR", 1, 1)
        ]

        XCTAssertEqual(adjacent(from: topLeft, .right, layout: layout, monitors: monitors), .monitor(topRight))
        XCTAssertEqual(adjacent(from: topLeft, .down, layout: layout, monitors: monitors), .monitor(bottomLeft))
        XCTAssertEqual(adjacent(from: bottomRight, .left, layout: layout, monitors: monitors), .monitor(bottomLeft))
        XCTAssertEqual(adjacent(from: bottomRight, .up, layout: layout, monitors: monitors), .monitor(topRight))
    }

    func testDiagonalDoesNotLeakIntoHorizontalResolution() {
        let source = makeMonitor(1, "Source")
        let farSameRow = makeMonitor(2, "FarSameRow")
        let nearDiagonal = makeMonitor(3, "NearDiagonal")
        let monitors = [source, farSameRow, nearDiagonal]
        let layout = [
            routing(1, "Source", 0, 0),
            routing(2, "FarSameRow", 2, 0),
            routing(3, "NearDiagonal", 1, 1)
        ]

        XCTAssertEqual(adjacent(from: source, .right, layout: layout, monitors: monitors), .monitor(farSameRow))
    }

    func testNoNeighborInLineReturnsEdge() {
        let source = makeMonitor(1, "Source")
        let other = makeMonitor(2, "Other")
        let monitors = [source, other]
        let layout = [routing(1, "Source", 0, 0), routing(2, "Other", 1, 1)]

        XCTAssertEqual(adjacent(from: source, .right, layout: layout, monitors: monitors), .edge)
        XCTAssertEqual(adjacent(from: source, .down, layout: layout, monitors: monitors), .edge)
    }

    func testWrapAroundWrapsWithinLine() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let c = makeMonitor(3, "C")
        let monitors = [a, b, c]
        let layout = [routing(1, "A", 0, 0), routing(2, "B", 1, 0), routing(3, "C", 2, 0)]

        XCTAssertEqual(adjacent(from: c, .right, layout: layout, monitors: monitors, wrap: true), .monitor(a))
        XCTAssertEqual(adjacent(from: a, .left, layout: layout, monitors: monitors, wrap: true), .monitor(c))
        XCTAssertEqual(adjacent(from: c, .right, layout: layout, monitors: monitors, wrap: false), .edge)
    }

    func testSourceWithoutEntryFallsBackToMacOS() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let monitors = [a, b]
        let layout = [routing(2, "B", 1, 0)]

        XCTAssertEqual(adjacent(from: a, .right, layout: layout, monitors: monitors), .fallBackToMacOS)
    }

    func testIncompleteLayoutFallsBackWhenSourceHasEntry() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let monitors = [a, b]
        let layout = [routing(1, "A", 0, 0)]

        XCTAssertEqual(adjacent(from: a, .right, layout: layout, monitors: monitors), .fallBackToMacOS)
    }

    func testDuplicateCellsFallBackToMacOS() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let monitors = [a, b]
        let layout = [routing(1, "A", 0, 0), routing(2, "B", 0, 0)]

        XCTAssertEqual(adjacent(from: a, .right, layout: layout, monitors: monitors), .fallBackToMacOS)
    }

    func testDisconnectedEntriesIgnored() {
        let a = makeMonitor(1, "A")
        let b = makeMonitor(2, "B")
        let monitors = [a, b]
        let layout = [
            routing(1, "A", 0, 0),
            routing(2, "B", 1, 0),
            routing(9, "Ghost", 2, 0)
        ]

        XCTAssertEqual(adjacent(from: b, .right, layout: layout, monitors: monitors), .edge)
        XCTAssertEqual(adjacent(from: a, .right, layout: layout, monitors: monitors), .monitor(b))
    }
}
