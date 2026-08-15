// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class MultitouchGestureSourceTests: XCTestCase {
    private let location = CGPoint(x: 100, y: 200)

    private func frame(
        _ positions: [(Float, Float)],
        timestamp: Double = 1.0
    ) -> MultitouchGestureSource.RawFrame {
        MultitouchGestureSource.RawFrame(
            touches: positions.map { MultitouchGestureSource.RawTouch(x: $0.0, y: $0.1) },
            timestamp: timestamp
        )
    }

    func testNoTouchesWhileIdleProducesNoSnapshot() {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: 0
        )
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.activeCount, 0)
    }

    func testFirstContactBeginsGesture() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(result.activeCount, 3)
        XCTAssertEqual(snapshot.touches.count, 3)
        XCTAssertEqual(snapshot.location, location)
    }

    func testContinuedContactReportsChanged() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5), (0.5, 0.5)]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.changed.rawValue)
        XCTAssertEqual(result.activeCount, 3)
    }

    func testFingerLiftEndsGestureCleanly() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.ended.rawValue)
        XCTAssertTrue(snapshot.touches.isEmpty)
        XCTAssertEqual(result.activeCount, 0)
    }

    func testPartialLiftStillReportsLoweredCount() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5)]),
            location: location,
            previousActiveCount: 3
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.phaseRawValue, NSEvent.Phase.changed.rawValue)
        XCTAssertEqual(result.activeCount, 2)
    }

    func testNormalizedPositionsArePropagated() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.25, 0.75)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let touch = try XCTUnwrap(snapshot.touches.first)
        XCTAssertEqual(touch.phase, .moved)
        XCTAssertEqual(touch.normalizedPosition, CGPoint(x: 0.25, y: 0.75))
    }

    func testNonFiniteContactPositionSanitizesToNil() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(.nan, 0.5)]),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let touch = try XCTUnwrap(snapshot.touches.first)
        XCTAssertNil(touch.normalizedPosition)
    }

    func testInlineTouchStoragePreservesOverflowContacts() throws {
        let positions = (0 ..< 20).map { index in
            (Float(index) / 20, Float(20 - index) / 20)
        }
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame(positions),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        let lastPosition = try XCTUnwrap(snapshot.touches.last?.normalizedPosition)

        XCTAssertEqual(result.activeCount, 20)
        XCTAssertEqual(snapshot.touches.count, 20)
        XCTAssertEqual(lastPosition.x, 0.95, accuracy: 0.0001)
        XCTAssertEqual(lastPosition.y, 0.05, accuracy: 0.0001)
    }

    func testTimestampIsPropagated() throws {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)], timestamp: 42.5),
            location: location,
            previousActiveCount: 0
        )
        let snapshot = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(snapshot.timestamp, 42.5)
    }

    func testGestureLifecycleProducesBeganChangedEnded() throws {
        var previousActiveCount = 0

        let down = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(down.snapshot).phaseRawValue, NSEvent.Phase.began.rawValue)
        previousActiveCount = down.activeCount

        let move = MultitouchGestureSource.makeSnapshot(
            frame: frame([(0.4, 0.5), (0.45, 0.5), (0.5, 0.5)]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(move.snapshot).phaseRawValue, NSEvent.Phase.changed.rawValue)
        previousActiveCount = move.activeCount

        let lift = MultitouchGestureSource.makeSnapshot(
            frame: frame([]),
            location: location,
            previousActiveCount: previousActiveCount
        )
        XCTAssertEqual(try XCTUnwrap(lift.snapshot).phaseRawValue, NSEvent.Phase.ended.rawValue)
        XCTAssertEqual(lift.activeCount, 0)
    }
}
