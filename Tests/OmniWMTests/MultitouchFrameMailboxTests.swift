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

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1, generation: 7))
        for tick in 2 ... 10_001 {
            XCTAssertFalse(offer(mailbox, touches: 1, at: 1 + Double(tick - 1) / 1_000, generation: 7))
        }
        XCTAssertFalse(offer(mailbox, touches: 0, at: 11.001, generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .changed, .ended])
        XCTAssertEqual(deliveries[1].frame.timestamp, 11)
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
                offer(mailbox, touches: 1, at: Double(gesture * 2), generation: 9),
                gesture == 0
            )
            XCTAssertFalse(offer(mailbox, touches: 0, at: Double(gesture * 2 + 1), generation: 9))
        }

        let deliveries = mailbox.take()
        XCTAssertLessThanOrEqual(deliveries.count, mailbox.capacity)
        XCTAssertEqual(deliveries.map(\.kind), [.began, .ended, .began, .ended])
    }

    func testEndAtCapacityEvictsACompleteGestureInsteadOfStrandingBegin() {
        let mailbox = MultitouchFrameMailbox(capacity: 3)
        mailbox.activate(generation: 10)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1, generation: 10))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 2, generation: 10))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 3, generation: 10))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 4, generation: 10))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .ended])
        XCTAssertEqual(deliveries.map(\.frame.timestamp), [3, 4])
    }

    func testStaleGenerationNeverSchedulesDrain() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 2)
        mailbox.beginPerformanceCapture()

        XCTAssertFalse(offer(mailbox, touches: 1, at: 1, slot: 0, generation: 1))
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertEqual(mailbox.endPerformanceCapture()?.staleCallbacks, 1)
    }

    func testCaptureSeedsPreexistingPendingFramesAndRetainsHighWaterAfterDrain() {
        let mailbox = MultitouchFrameMailbox(capacity: 6)
        mailbox.activate(generation: 11)
        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, generation: 11))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, generation: 11))

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

    func testSecondDeviceCannotOverwriteOrEndOwnerGesture() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.02, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.03, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.04, slot: 0, generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .changed, .ended])
        XCTAssertEqual(deliveries.map(\.frame.timestamp), [1.00, 1.02, 1.04])
    }

    func testQuarantinedDeviceBeginsOnlyAfterItLifts() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.02, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.03, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.04, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.05, slot: 1, generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .ended, .began])
        XCTAssertEqual(deliveries.last?.frame.timestamp, 1.05)
    }

    func testActivateClearsOwnerAndQuarantine() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, slot: 1, generation: 7))
        mailbox.activate(generation: 8)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.02, slot: 1, generation: 8))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.03, slot: 0, generation: 8))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began])
        XCTAssertEqual(deliveries.first?.frame.timestamp, 1.02)
    }

    func testQuarantinedDeviceQueuesNoWork() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)
        mailbox.beginPerformanceCapture()

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.000, slot: 0, generation: 7))
        for tick in 1 ... 1_000 {
            let timestamp = 1 + Double(tick) / 1_000
            XCTAssertFalse(offer(mailbox, touches: 1, at: timestamp, slot: 0, generation: 7))
            XCTAssertFalse(offer(mailbox, touches: 1, at: timestamp, slot: 1, generation: 7))
        }
        XCTAssertFalse(offer(mailbox, touches: 0, at: 2.001, slot: 0, generation: 7))

        XCTAssertEqual(mailbox.take().map(\.kind), [.began, .changed, .ended])
        let snapshot = mailbox.endPerformanceCapture()
        XCTAssertEqual(snapshot?.rawCallbacks, 2_002)
        XCTAssertEqual(snapshot?.overwrittenChanges, 999)
        XCTAssertEqual(snapshot?.transitionsQueued, 2)
        XCTAssertEqual(snapshot?.maximumPendingFrames, 3)
        XCTAssertEqual(snapshot?.pendingFrames, 0)
        XCTAssertEqual(snapshot?.drainBatches, 1)
    }

    func testOwnerFrameAfterMissingLiftCancelsAndRestarts() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)
        mailbox.beginPerformanceCapture()

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.20, slot: 0, generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .changed, .cancelled, .began])
        XCTAssertEqual(deliveries.map(\.frame.timestamp), [1.00, 1.01, 1.20, 1.20])
        XCTAssertTrue(deliveries[2].frame.touches.isEmpty)
        XCTAssertEqual(deliveries[3].frame.touches.count, 1)
        XCTAssertEqual(mailbox.endPerformanceCapture()?.transitionsQueued, 3)
    }

    func testSecondDeviceAfterMissingLiftCancelsOwnerAndBegins() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.01, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.20, slot: 1, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.21, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.22, slot: 1, generation: 7))

        let deliveries = mailbox.take()
        XCTAssertEqual(deliveries.map(\.kind), [.began, .changed, .cancelled, .began, .ended])
        XCTAssertEqual(deliveries.map(\.frame.timestamp), [1.00, 1.01, 1.20, 1.20, 1.22])
    }

    func testLateLiftFrameEndsWithoutCancel() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 0, at: 1.50, slot: 0, generation: 7))

        XCTAssertEqual(mailbox.take().map(\.kind), [.began, .ended])
    }

    func testGapWithinBoundaryKeepsGestureContinuous() {
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 7)

        XCTAssertTrue(offer(mailbox, touches: 1, at: 1.00, slot: 0, generation: 7))
        XCTAssertFalse(offer(mailbox, touches: 1, at: 1.11, slot: 0, generation: 7))

        XCTAssertEqual(mailbox.take().map(\.kind), [.began, .changed])
    }

    private func offer(
        _ mailbox: MultitouchFrameMailbox,
        touches: Int,
        at timestamp: Double,
        slot: Int = 0,
        generation: UInt
    ) -> Bool {
        mailbox.offer(
            MultitouchGestureSource.RawFrame(
                touches: Array(repeating: .init(x: 0.5, y: 0.5), count: touches),
                timestamp: timestamp
            ),
            generation: generation,
            slot: slot
        )
    }
}
