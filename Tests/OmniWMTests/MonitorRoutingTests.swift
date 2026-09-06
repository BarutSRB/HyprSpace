// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MonitorRoutingTests: XCTestCase {
    private func makeMonitor(
        _ displayId: CGDirectDisplayID,
        _ name: String,
        displayUUID: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name,
            displayUUID: displayUUID
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

    func testArrangementPrefersExactSetThenSmallestCoveringSetWithStableTies() {
        let monitors = [makeMonitor(1, "A"), makeMonitor(2, "B")]
        let exact = MonitorArrangement(monitors: [routing(1, "A", 0, 0), routing(2, "B", 0, 1)])
        let covering = MonitorArrangement(monitors: [
            routing(1, "A", 0, 0), routing(2, "B", 1, 0), routing(3, "C", 2, 0)
        ])
        let largest = MonitorArrangement(monitors: covering.monitors + [routing(4, "D", 3, 0)])
        let tied = MonitorArrangement(monitors: [
            routing(1, "A", 0, 0), routing(2, "B", 0, 1), routing(4, "D", 0, 2)
        ])
        let arrangements = [largest, covering, tied, exact]

        XCTAssertEqual(MonitorRouting.arrangementIndex(for: monitors, in: arrangements), 3)
        XCTAssertEqual(MonitorRouting.arrangementIndex(for: monitors, in: [largest, covering, tied]), 1)
        XCTAssertEqual(MonitorRouting.arrangementIndex(for: monitors, in: [tied, covering]), 0)
        XCTAssertEqual(MonitorRouting.arrangementIndex(for: monitors, in: [exact, exact]), 0)
        XCTAssertNil(MonitorRouting.exactArrangementIndex(for: monitors, in: [covering]))
        XCTAssertNil(MonitorRouting.arrangementIndex(for: [], in: arrangements))
        XCTAssertTrue(MonitorRouting.layout(for: [makeMonitor(9, "Unknown")], in: arrangements).isEmpty)
        XCTAssertTrue(MonitorRouting.layout(for: monitors + [makeMonitor(3, "C")], in: [exact]).isEmpty)
    }

    func testArrangementFollowsUUIDsAcrossReconnectOrderAndGeometryChanges() {
        let firstUUID = "11111111-1111-4111-8111-111111111111"
        let secondUUID = "22222222-2222-4222-8222-222222222222"
        let old = [
            makeMonitor(1, "First", displayUUID: firstUUID),
            makeMonitor(2, "Second", displayUUID: secondUUID)
        ]
        let arrangement = MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "First", monitorDisplayUUID: firstUUID, gridColumn: 0, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Second", monitorDisplayUUID: secondUUID, gridColumn: 1, gridRow: 0)
        ])
        let current = [
            makeMonitor(20, "Renamed second", displayUUID: secondUUID),
            makeMonitor(
                10,
                "Renamed first",
                displayUUID: firstUUID,
                frame: CGRect(x: 400, y: 1080, width: 1080, height: 1920)
            )
        ]

        XCTAssertEqual(MonitorRouting.layout(for: old, in: [arrangement]), arrangement.monitors)
        XCTAssertEqual(MonitorRouting.layout(for: current, in: [arrangement]), arrangement.monitors)
        XCTAssertEqual(
            adjacent(
                from: current[1],
                .right,
                layout: MonitorRouting.layout(for: current, in: [arrangement]),
                monitors: current
            ),
            .monitor(current[0])
        )
        let recycled = makeMonitor(1, "First", displayUUID: "33333333-3333-4333-8333-333333333333")
        XCTAssertNil(MonitorRouting.arrangementIndex(for: [recycled, old[1]], in: [arrangement]))
        XCTAssertEqual(MonitorRouting.arrangementIndex(
            for: [makeMonitor(1, "first")],
            in: [MonitorArrangement(monitors: [routing(1, "First", 0, 0)])]
        ), 0)
    }

    func testInvalidExactArrangementDoesNotSelectAnotherLayout() {
        let monitors = [makeMonitor(1, "A"), makeMonitor(2, "B")]
        let covering = MonitorArrangement(monitors: [
            routing(1, "A", 0, 0), routing(2, "B", 1, 0), routing(3, "C", 2, 0)
        ])
        let invalid = MonitorArrangement(monitors: [routing(1, "A", 0, 0), routing(2, "B", 0, 0)])
        let layout = MonitorRouting.layout(for: monitors, in: [covering, invalid])

        XCTAssertEqual(layout, invalid.monitors)
        XCTAssertEqual(adjacent(from: monitors[0], .right, layout: layout, monitors: monitors), .fallBackToMacOS)
        let ambiguous = MonitorArrangement(monitors: covering.monitors + [routing(1, "A", 9, 0)])
        XCTAssertNil(MonitorRouting.arrangementIndex(for: monitors, in: [ambiguous]))
    }

    func testStoreCreatesIndependentSubsetAndPreservesExactArrangementIdentity() {
        let monitors = [makeMonitor(1, "A"), makeMonitor(2, "B")]
        let original = MonitorArrangement(monitors: [
            routing(1, "A", 0, 0), routing(2, "B", 1, 0), routing(3, "C", 2, 0)
        ])
        var arrangements = [original]
        let vertical = [routing(1, "A", 0, 0), routing(2, "B", 0, 1)]
        MonitorRouting.store(vertical, for: monitors, in: &arrangements)

        XCTAssertEqual(arrangements.count, 2)
        XCTAssertEqual(arrangements[0], original)
        XCTAssertEqual(MonitorRouting.layout(for: monitors, in: arrangements), vertical)
        let subsetID = arrangements[1].id
        let horizontal = [routing(1, "A", 0, 0), routing(2, "B", 1, 0)]
        MonitorRouting.store(horizontal, for: monitors, in: &arrangements)

        XCTAssertEqual(arrangements.count, 2)
        XCTAssertEqual(arrangements[0], original)
        XCTAssertEqual(arrangements[1].id, subsetID)
        XCTAssertEqual(arrangements[1].monitors, horizontal)
        MonitorRouting.store([], for: [], in: &arrangements)
        XCTAssertEqual(arrangements.count, 2)
    }
}
