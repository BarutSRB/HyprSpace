// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class PerformanceOwnerGaugeTests: XCTestCase {
    func testEventIntakeCaptureSeedsPreexistingQueueDepth() throws {
        let intake = EventIntake()
        let sink = PerformanceGaugeIntakeSink()
        intake.open(sink: sink)
        defer { intake.close() }

        XCTAssertTrue(intake.enqueue(.activeSpaceChanged))
        XCTAssertTrue(intake.enqueue(.appActivated(pid: 901)))
        XCTAssertTrue(intake.enqueue(.systemWake))
        intake.beginPerformanceCapture()

        let initial = try XCTUnwrap(intake.performanceSnapshot())
        XCTAssertEqual(initial.currentQueueDepth, 3)
        XCTAssertEqual(initial.maximumQueueDepth, 3)
        XCTAssertEqual(initial.acceptedEvents, 0)

        intake.drainNow()
        let final = try XCTUnwrap(intake.endPerformanceCapture())
        XCTAssertEqual(final.currentQueueDepth, 0)
        XCTAssertEqual(final.maximumQueueDepth, 3)
        XCTAssertEqual(final.deliveredEvents, 3)
    }

    func testEventIntakeCaptureCountsCoalescingAcrossInactiveBoundary() throws {
        let intake = EventIntake()
        let sink = PerformanceGaugeIntakeSink()
        intake.open(sink: sink)
        defer { intake.close() }

        XCTAssertTrue(intake.enqueue(.cgs(.frameChanged(windowId: 901))))
        XCTAssertNil(intake.performanceSnapshot())

        intake.beginPerformanceCapture()
        XCTAssertTrue(intake.enqueue(.cgs(.frameChanged(windowId: 901))))

        let queued = try XCTUnwrap(intake.performanceSnapshot())
        XCTAssertEqual(queued.acceptedEvents, 1)
        XCTAssertEqual(queued.coalescedEvents, 1)
        XCTAssertEqual(queued.currentQueueDepth, 1)
        XCTAssertEqual(queued.maximumQueueDepth, 1)

        intake.drainNow()

        let final = try XCTUnwrap(intake.endPerformanceCapture())
        XCTAssertEqual(final.acceptedEvents, 1)
        XCTAssertEqual(final.coalescedEvents, 1)
        XCTAssertEqual(final.deliveredEvents, 1)
        XCTAssertEqual(final.drainBatches, 1)
        XCTAssertNil(intake.performanceSnapshot())
    }

    func testLayoutCaptureSeedsInstalledDisplayLinkGauge() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.activeDisplayLinkCountForTests = { 3 }
        defer {
            refreshController.activeDisplayLinkCountForTests = nil
            refreshController.resetState()
        }

        refreshController.beginPerformanceCapture()
        let initial = try XCTUnwrap(refreshController.performanceSnapshot())

        XCTAssertEqual(initial.activeDisplayLinks, 3)
        XCTAssertEqual(initial.activeDisplayLinkHighWater, 3)
        XCTAssertEqual(initial.displayLinksCreated, 0)
        XCTAssertEqual(initial.displayLinkCallbacks, 0)

        let final = try XCTUnwrap(refreshController.endPerformanceCapture())
        XCTAssertEqual(final.activeDisplayLinks, 3)
        XCTAssertEqual(final.activeDisplayLinkHighWater, 3)
    }
}

@MainActor
private final class PerformanceGaugeIntakeSink: EventIntakeSink {
    func handleIntakeEvent(_: StampedIntakeEvent) {}
}
