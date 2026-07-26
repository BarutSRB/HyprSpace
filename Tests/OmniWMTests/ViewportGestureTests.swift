// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class ViewportGestureTests: XCTestCase {
    private func columns(_ widths: [CGFloat]) -> [NiriContainer] {
        widths.map { width in
            let column = NiriContainer()
            column.cachedWidth = width
            return column
        }
    }

    private func portraitColumns(_ heights: [CGFloat]) -> [NiriContainer] {
        heights.map { height in
            let column = NiriContainer()
            column.cachedWidth = 700
            column.cachedHeight = height
            return column
        }
    }

    private func makeState(activeColumnIndex: Int = 0, viewOffset: CGFloat = 0) -> ViewportState {
        var state = ViewportState()
        state.activeColumnIndex = activeColumnIndex
        state.viewOffset = viewOffset
        return state
    }

    func testMomentumWithoutVelocityStaysAtCurrentColumn() {
        var state = makeState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 0,
            columns: columns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .horizontal,
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, 0)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
    }

    func testMomentumFlingRestsAtProjectedOffsetWithoutSnapping() {
        var state = makeState()
        state.endGesture(
            currentOffset: 20,
            projectedOffset: 65,
            columns: columns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .horizontal,
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 1)
        XCTAssertEqual(state.viewOffset, -45)
        XCTAssertEqual(state.offsetTransition.rebaseDelta, -110)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)

        let viewStart = 110 + state.viewOffset
        XCTAssertEqual(viewStart, 65)
    }

    func testMomentumSpringsBackAtContentEdge() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .horizontal,
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(state.viewOffset, -50)
        XCTAssertEqual(state.offsetTransition.kind, .spring(.niriHorizontalViewMovement))
        XCTAssertEqual(220 + state.viewOffset, 170)
    }

    func testDisabledAnimationsJumpToClampedLandingWithoutDeceleration() {
        var state = makeState()
        state.endGesture(
            currentOffset: 30,
            projectedOffset: 500,
            columns: columns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .horizontal,
            motion: .disabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertEqual(state.viewOffset, -50)
        XCTAssertEqual(state.offsetTransition.kind, .jump)
    }

    func testPortraitSnapUsesContainerHeights() {
        var state = makeState()
        state.endGesture(
            currentOffset: 0,
            projectedOffset: 65,
            columns: portraitColumns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .vertical,
            motion: .disabled
        )

        XCTAssertEqual(state.activeColumnIndex, 1)
        XCTAssertEqual(state.viewOffset, -40)
        XCTAssertEqual(state.offsetTransition.kind, .jump)
    }

    func testPortraitMomentumUsesContainerHeights() {
        var state = makeState()
        state.endGesture(
            currentOffset: 20,
            projectedOffset: 65,
            columns: portraitColumns([100, 100, 100]),
            gap: 10,
            viewportSpan: 150,
            orientation: .vertical,
            motion: .enabled,
            snapToColumn: false
        )

        XCTAssertEqual(state.activeColumnIndex, 1)
        XCTAssertEqual(state.viewOffset, -45)
        XCTAssertEqual(state.offsetTransition.rebaseDelta, -110)
        XCTAssertEqual(state.offsetTransition.kind, .deceleration)
        XCTAssertEqual(110 + state.viewOffset, 65)
    }
}
