// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class MultitouchFrameMailboxTests: XCTestCase {
    func testBurstPreservesTransitionsAndKeepsLatestChange() {
        let mailbox = MultitouchFrameMailbox(capacity: 6)
        mailbox.activate(generation: 7)
        mailbox.beginPerformanceCapture()

        XCTAssertTrue(mailbox.offer(frame(touches: 1, timestamp: 1), generation: 7))
        for timestamp in 2 ... 10_001 {
            XCTAssertFalse(mailbox.offer(frame(touches: 1, timestamp: Double(timestamp)), generation: 7))
        }
        XCTAssertFalse(mailbox.offer(frame(touches: 0, timestamp: 10_002), generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .changed, .ended])
        XCTAssertEqual(deliveries[1].frame.timestamp, 10_001)
        let snapshot = mailbox.endPerformanceCapture()
        XCTAssertEqual(snapshot?.rawCallbacks, 10_002)
        XCTAssertEqual(snapshot?.overwrittenChanges, 9_999)
        XCTAssertEqual(snapshot?.transitionsQueued, 2)
        XCTAssertEqual(snapshot?.drainBatches, 1)
        XCTAssertEqual(snapshot?.cursorSamples, 1)
    }

    func testBoundDropsOnlyCompleteOldGestures() {
        let mailbox = MultitouchFrameMailbox(capacity: 6)
        mailbox.activate(generation: 9)

        for gesture in 0 ..< 10 {
            XCTAssertEqual(
                mailbox.offer(frame(touches: 1, timestamp: Double(gesture * 2)), generation: 9),
                gesture == 0
            )
            XCTAssertFalse(mailbox.offer(frame(touches: 0, timestamp: Double(gesture * 2 + 1)), generation: 9))
        }

        let deliveries = mailbox.take()
        XCTAssertLessThanOrEqual(deliveries.count, mailbox.capacity)
        XCTAssertEqual(deliveries.map(\.kind), [.began, .ended, .began, .ended])
    }

    func testEndAtCapacityEvictsACompleteGestureInsteadOfStrandingBegin() {
        let mailbox = MultitouchFrameMailbox(capacity: 3)
        mailbox.activate(generation: 10)

        XCTAssertTrue(mailbox.offer(frame(touches: 1, timestamp: 1), generation: 10))
        XCTAssertFalse(mailbox.offer(frame(touches: 0, timestamp: 2), generation: 10))
        XCTAssertFalse(mailbox.offer(frame(touches: 1, timestamp: 3), generation: 10))
        XCTAssertFalse(mailbox.offer(frame(touches: 0, timestamp: 4), generation: 10))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .ended])
        XCTAssertEqual(deliveries.map(\.frame.timestamp), [3, 4])
    }

    func testStaleGenerationNeverSchedulesDrain() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 2)
        mailbox.beginPerformanceCapture()

        XCTAssertFalse(mailbox.offer(frame(touches: 1, timestamp: 1), generation: 1))
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertEqual(mailbox.endPerformanceCapture()?.staleCallbacks, 1)
    }

    func testCaptureSeedsPreexistingPendingFramesAndRetainsHighWaterAfterDrain() {
        let mailbox = MultitouchFrameMailbox(capacity: 6)
        mailbox.activate(generation: 11)
        XCTAssertTrue(mailbox.offer(frame(touches: 1, timestamp: 1), generation: 11))
        XCTAssertFalse(mailbox.offer(frame(touches: 1, timestamp: 2), generation: 11))

        mailbox.beginPerformanceCapture()
        let initial = mailbox.performanceSnapshot()

        XCTAssertEqual(initial?.pendingFrames, 2)
        XCTAssertEqual(initial?.maximumPendingFrames, 2)
        XCTAssertEqual(initial?.rawCallbacks, 0)

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.count, 2)
        let final = mailbox.endPerformanceCapture()
        XCTAssertEqual(final?.pendingFrames, 0)
        XCTAssertEqual(final?.maximumPendingFrames, 2)
        XCTAssertEqual(final?.drainBatches, 1)
        XCTAssertEqual(final?.cursorSamples, 1)
    }

    private func frame(touches: Int, timestamp: Double) -> MultitouchGestureSource.RawFrame {
        MultitouchGestureSource.RawFrame(
            touches: Array(repeating: .init(x: 0.5, y: 0.5), count: touches),
            timestamp: timestamp
        )
    }
}
