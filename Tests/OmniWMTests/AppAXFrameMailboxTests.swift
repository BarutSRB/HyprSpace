// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Darwin
import Dispatch
@testable import OmniWM
import XCTest

@MainActor
final class AppAXFrameMailboxTests: XCTestCase {
    func testConcurrentAtomicCountersAreExactAndFreezeAfterEnd() {
        let metrics = AppAXContextRuntimeMetrics.shared
        metrics.beginCapture()

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            metrics.noteSubmitted(1, lane: .ordinary)
            metrics.noteEnhancedUICalls(1)
        }

        metrics.endCapture()
        let frozen = metrics.snapshot()
        metrics.noteSubmitted(1, lane: .ordinary)
        metrics.noteEnhancedUICalls(1)

        XCTAssertEqual(frozen.ordinarySubmitted, 10_000)
        XCTAssertEqual(frozen.enhancedUICalls, 10_000)
        XCTAssertEqual(metrics.snapshot(), frozen)
    }

    func testEndCaptureWaitsForAnAdmittedConcurrentWriter() {
        let metrics = AppAXContextRuntimeMetrics.shared
        let generations = LockedWindowGenerationMap()
        let frameRequest = request(id: 9_001, windowId: 9_002, generations: generations)
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        let items = (0 ..< 100_000).map { index in
            AppAXFrameMailbox.Item(
                submissionId: 1,
                index: index,
                request: frameRequest,
                enqueuedAt: enqueuedAt
            )
        }
        let group = DispatchGroup()
        metrics.beginCapture()
        group.enter()
        DispatchQueue.global().async {
            metrics.noteOrdinaryStarted(items)
            group.leave()
        }
        while metrics.snapshot().ordinaryStarted == 0 {
            sched_yield()
        }

        metrics.endCapture()
        let frozen = metrics.snapshot()
        group.wait()

        XCTAssertEqual(frozen.ordinaryStarted, UInt64(items.count))
        XCTAssertEqual(frozen.queueWaitSamples, UInt64(items.count))
        XCTAssertEqual(metrics.snapshot(), frozen)
    }

    func testLatestPendingRequestReplacesOlderRequestWithExactlyOneCancellation() throws {
        let mailbox = AppAXFrameMailbox()
        let generations = LockedWindowGenerationMap()
        var completions: [[AXFrameApplyResult]] = []

        let first = request(id: 1, windowId: 41, generations: generations)
        let firstOutcome = mailbox.enqueue([first]) { completions.append($0) }
        let firstDrain = try XCTUnwrap(firstOutcome.drain)

        let second = request(id: 2, windowId: 41, generations: generations)
        XCTAssertNil(mailbox.enqueue([second]) { completions.append($0) }.drain)
        let third = request(id: 3, windowId: 41, generations: generations)
        let replacement = mailbox.enqueue([third]) { completions.append($0) }
        replacement.deliveries.forEach { $0.deliver() }

        XCTAssertNil(replacement.drain)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].map(\.requestId), [2])
        XCTAssertEqual(completions[0][0].writeResult.failureReason, .cancelled)
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertEqual(mailbox.inFlightCount, 1)

        let firstFinish = mailbox.finish(
            drainId: firstDrain.id,
            results: [skippedFrameApplyResult(for: first, reason: .suppressed)]
        )
        firstFinish.deliveries.forEach { $0.deliver() }
        let nextDrain = try XCTUnwrap(firstFinish.drain)
        let finalFinish = mailbox.finish(
            drainId: nextDrain.id,
            results: [skippedFrameApplyResult(for: third, reason: .suppressed)]
        )
        finalFinish.deliveries.forEach { $0.deliver() }

        XCTAssertEqual(completions.map { $0.first?.requestId }, [2, 1, 3])
    }

    func testCancelAllCompletesInFlightAndPendingSubmissionsOnlyOnce() throws {
        let mailbox = AppAXFrameMailbox()
        let generations = LockedWindowGenerationMap()
        var completions: [[AXFrameApplyResult]] = []
        let first = request(id: 1, windowId: 51, generations: generations)
        let firstDrain = try XCTUnwrap(mailbox.enqueue([first]) { completions.append($0) }.drain)
        let second = request(id: 2, windowId: 52, generations: generations)
        _ = mailbox.enqueue([second]) { completions.append($0) }

        mailbox.cancelAll().forEach { $0.deliver() }
        let lateFinish = mailbox.finish(
            drainId: firstDrain.id,
            results: [skippedFrameApplyResult(for: first, reason: .suppressed)]
        )

        XCTAssertNil(lateFinish.drain)
        XCTAssertTrue(lateFinish.deliveries.isEmpty)
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(Set(completions.compactMap { $0.first?.requestId }), [1, 2])
        XCTAssertTrue(completions.allSatisfy { $0.first?.writeResult.failureReason == .cancelled })
    }

    func testShutdownCompletesInFlightAndPendingOrdinarySubmissionsAndRejectsNewWork() throws {
        try assertShutdownCompletesInFlightAndPendingSubmissions(lane: .ordinary)
    }

    func testShutdownCompletesInFlightAndPendingParkSubmissionsAndRejectsNewWork() throws {
        try assertShutdownCompletesInFlightAndPendingSubmissions(lane: .park)
    }

    private func assertShutdownCompletesInFlightAndPendingSubmissions(
        lane: AppAXFrameLane
    ) throws {
        let mailbox = AppAXFrameMailbox(lane: lane)
        let generations = LockedWindowGenerationMap()
        var completions: [[AXFrameApplyResult]] = []
        AppAXContextRuntimeMetrics.shared.beginCapture()
        defer { AppAXContextRuntimeMetrics.shared.endCapture() }
        let first = request(id: 1, windowId: 53, generations: generations)
        let firstDrain = try XCTUnwrap(mailbox.enqueue([first]) { completions.append($0) }.drain)
        let second = request(id: 2, windowId: 54, generations: generations)
        _ = mailbox.enqueue([second]) { completions.append($0) }

        mailbox.beginShutdown().forEach { $0.deliver() }
        let lateFinish = mailbox.finish(
            drainId: firstDrain.id,
            results: [skippedFrameApplyResult(for: first, reason: .suppressed)]
        )
        let third = request(id: 3, windowId: 55, generations: generations)
        let stopped = mailbox.enqueue([third]) { completions.append($0) }
        stopped.deliveries.forEach { $0.deliver() }

        XCTAssertNil(lateFinish.drain)
        XCTAssertTrue(lateFinish.deliveries.isEmpty)
        XCTAssertNil(stopped.drain)
        XCTAssertEqual(Set(completions.compactMap { $0.first?.requestId }), [1, 2, 3])
        XCTAssertTrue(completions.allSatisfy { $0.first?.writeResult.failureReason == .cancelled })
        let snapshot = AppAXContextRuntimeMetrics.shared.snapshot()
        switch lane {
        case .ordinary:
            XCTAssertEqual(snapshot.ordinarySubmitted, 3)
            XCTAssertEqual(snapshot.ordinaryCompleted, 3)
            XCTAssertEqual(snapshot.ordinaryCancelled, 3)
            XCTAssertEqual(snapshot.ordinaryPending, 0)
            XCTAssertEqual(snapshot.ordinaryInFlight, 0)
        case .park:
            XCTAssertEqual(snapshot.parkSubmitted, 3)
            XCTAssertEqual(snapshot.parkCompleted, 3)
            XCTAssertEqual(snapshot.parkCancelled, 3)
            XCTAssertEqual(snapshot.parkPending, 0)
            XCTAssertEqual(snapshot.parkInFlight, 0)
        case .closing:
            XCTFail("Unexpected closing lane")
        }
    }

    func testStaleOnlyBatchDoesNotTouchEnhancedUI() {
        let generations = LockedWindowGenerationMap()
        let request = request(id: 1, windowId: 61, generations: generations)
        generations.invalidateAndRemove(request.windowId)
        AppAXContextRuntimeMetrics.shared.beginCapture()

        let results = AppAXContext.executeFrameWriteRequests(
            [request],
            pid: request.pid,
            axApp: AXUIElementCreateApplication(request.pid),
            generations: generations,
            suppression: nil,
            hardSuppression: nil,
            isCancelled: { false }
        )
        AppAXContextRuntimeMetrics.shared.endCapture()
        let snapshot = AppAXContextRuntimeMetrics.shared.snapshot()

        XCTAssertEqual(results.first?.writeResult.failureReason, .cancelled)
        XCTAssertEqual(snapshot.staleBeforeIPC, 1)
        XCTAssertEqual(snapshot.enhancedUICalls, 0)
    }

    func testTenThousandHeldOrdinarySubmissionsRemainBoundedAndCompleteExactlyOnce() throws {
        try assertTenThousandHeldSubmissionsRemainBounded(lane: .ordinary)
    }

    func testTenThousandHeldParkSubmissionsRemainBoundedAndCompleteExactlyOnce() throws {
        try assertTenThousandHeldSubmissionsRemainBounded(lane: .park)
    }

    private func assertTenThousandHeldSubmissionsRemainBounded(
        lane: AppAXFrameLane
    ) throws {
        let mailbox = AppAXFrameMailbox(lane: lane)
        let generations = LockedWindowGenerationMap()
        var completionCounts: [UInt64: Int] = [:]
        var completedResults: [AXFrameApplyResult] = []
        var firstDrain: AppAXFrameMailbox.Drain?
        AppAXContextRuntimeMetrics.shared.beginCapture()
        defer { AppAXContextRuntimeMetrics.shared.endCapture() }

        for id in UInt64(1) ... 10_000 {
            let frameRequest = request(id: id, windowId: 71, generations: generations)
            let outcome = mailbox.enqueue([frameRequest]) { results in
                completionCounts[id, default: 0] += 1
                completedResults.append(contentsOf: results)
            }
            outcome.deliveries.forEach { $0.deliver() }
            if firstDrain == nil {
                firstDrain = outcome.drain
            } else {
                XCTAssertNil(outcome.drain)
            }
        }

        let held = AppAXContextRuntimeMetrics.shared.snapshot()
        XCTAssertEqual(mailbox.inFlightCount, 1)
        XCTAssertEqual(mailbox.pendingCount, 1)
        switch lane {
        case .ordinary:
            XCTAssertEqual(held.ordinarySubmitted, 10_000)
            XCTAssertEqual(held.ordinaryReplaced, 9_998)
            XCTAssertEqual(held.ordinaryCompleted, 9_998)
            XCTAssertEqual(held.ordinaryCancelled, 9_998)
            XCTAssertEqual(held.ordinaryPendingHighWater, 1)
            XCTAssertEqual(held.ordinaryInFlightHighWater, 1)
        case .park:
            XCTAssertEqual(held.parkSubmitted, 10_000)
            XCTAssertEqual(held.parkReplaced, 9_998)
            XCTAssertEqual(held.parkCompleted, 9_998)
            XCTAssertEqual(held.parkCancelled, 9_998)
            XCTAssertEqual(held.parkPendingHighWater, 1)
            XCTAssertEqual(held.parkInFlightHighWater, 1)
        case .closing:
            XCTFail("Unexpected closing lane")
        }

        let initialDrain = try XCTUnwrap(firstDrain)
        noteStarted(initialDrain.items, lane: lane)
        let next = mailbox.finish(
            drainId: initialDrain.id,
            results: initialDrain.items.map {
                skippedFrameApplyResult(for: $0.request, reason: .suppressed)
            }
        )
        next.deliveries.forEach { $0.deliver() }
        let finalDrain = try XCTUnwrap(next.drain)
        noteStarted(finalDrain.items, lane: lane)
        let final = mailbox.finish(
            drainId: finalDrain.id,
            results: finalDrain.items.map {
                skippedFrameApplyResult(for: $0.request, reason: .suppressed)
            }
        )
        final.deliveries.forEach { $0.deliver() }

        let completed = AppAXContextRuntimeMetrics.shared.snapshot()
        XCTAssertNil(final.drain)
        XCTAssertEqual(mailbox.inFlightCount, 0)
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertEqual(completionCounts.count, 10_000)
        XCTAssertTrue(completionCounts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(completedResults.count, 10_000)
        XCTAssertEqual(
            completedResults.count(where: { $0.writeResult.failureReason == .cancelled }),
            9_998
        )
        switch lane {
        case .ordinary:
            XCTAssertEqual(completed.ordinaryCompleted, 10_000)
            XCTAssertEqual(completed.ordinaryCancelled, 9_998)
            XCTAssertEqual(completed.ordinaryStarted, 2)
        case .park:
            XCTAssertEqual(completed.parkCompleted, 10_000)
            XCTAssertEqual(completed.parkCancelled, 9_998)
            XCTAssertEqual(completed.parkStarted, 2)
        case .closing:
            XCTFail("Unexpected closing lane")
        }
        XCTAssertEqual(completed.queueWaitSamples, 2)
    }

    func testCaptureSeedsAndAggregatesAllFrameLanes() throws {
        let firstMailbox = AppAXFrameMailbox()
        let secondMailbox = AppAXFrameMailbox()
        let parkMailbox = AppAXFrameMailbox(lane: .park)
        let closingMailbox = AppAXClosingFrameMailbox()
        let firstGenerations = LockedWindowGenerationMap()
        let secondGenerations = LockedWindowGenerationMap()
        let parkGenerations = LockedWindowGenerationMap()

        let firstDrain = try XCTUnwrap(firstMailbox.enqueue([
            request(id: 1, windowId: 81, generations: firstGenerations)
        ]) { _ in }.drain)
        _ = firstMailbox.enqueue([
            request(id: 2, windowId: 82, generations: firstGenerations)
        ]) { _ in }
        let secondDrain = try XCTUnwrap(secondMailbox.enqueue([
            request(id: 3, windowId: 83, generations: secondGenerations),
            request(id: 4, windowId: 84, generations: secondGenerations)
        ]) { _ in }.drain)
        _ = secondMailbox.enqueue([
            request(id: 5, windowId: 85, generations: secondGenerations)
        ]) { _ in }
        let parkDrain = try XCTUnwrap(parkMailbox.enqueue([
            request(id: 6, windowId: 86, generations: parkGenerations)
        ]) { _ in }.drain)
        _ = parkMailbox.enqueue([
            request(id: 7, windowId: 87, generations: parkGenerations)
        ]) { _ in }
        let closingDrain = try XCTUnwrap(closingMailbox.enqueue([
            closingRequest(windowId: 91),
            closingRequest(windowId: 92)
        ]))
        _ = closingMailbox.enqueue([closingRequest(windowId: 93)])

        var initialDepths = firstMailbox.runtimeDepths
        initialDepths.add(secondMailbox.runtimeDepths)
        initialDepths.add(parkMailbox.runtimeDepths)
        initialDepths.add(closingMailbox.runtimeDepths)
        let initial = AppAXContextRuntimeMetrics.shared.beginCapture(initialDepths: initialDepths)
        defer { AppAXContextRuntimeMetrics.shared.endCapture() }

        XCTAssertEqual(initial.ordinaryPending, 2)
        XCTAssertEqual(initial.ordinaryInFlight, 3)
        XCTAssertEqual(initial.parkPending, 1)
        XCTAssertEqual(initial.parkInFlight, 1)
        XCTAssertEqual(initial.closingPending, 1)
        XCTAssertEqual(initial.closingInFlight, 2)
        XCTAssertEqual(initial.pending, 4)
        XCTAssertEqual(initial.inFlight, 6)
        XCTAssertEqual(initial.pendingHighWater, 4)
        XCTAssertEqual(initial.inFlightHighWater, 6)

        AppAXContextRuntimeMetrics.shared.noteOrdinaryStarted(firstDrain.items)
        AppAXContextRuntimeMetrics.shared.noteOrdinaryStarted(secondDrain.items)
        AppAXContextRuntimeMetrics.shared.noteParkStarted(parkDrain.items)
        AppAXContextRuntimeMetrics.shared.noteClosingStarted(closingDrain.requests.count)
        let started = AppAXContextRuntimeMetrics.shared.snapshot()
        XCTAssertEqual(started.ordinaryStarted, 3)
        XCTAssertEqual(started.parkStarted, 1)
        XCTAssertEqual(started.closingStarted, 2)
        XCTAssertEqual(started.queueWaitSamples, 0)

        _ = firstMailbox.enqueue([
            request(id: 8, windowId: 88, generations: firstGenerations)
        ]) { _ in }
        _ = parkMailbox.enqueue([
            request(id: 9, windowId: 89, generations: parkGenerations)
        ]) { _ in }
        _ = closingMailbox.enqueue([closingRequest(windowId: 94)])

        let expanded = AppAXContextRuntimeMetrics.shared.snapshot()
        XCTAssertEqual(expanded.ordinaryPending, 3)
        XCTAssertEqual(expanded.parkPending, 2)
        XCTAssertEqual(expanded.closingPending, 2)
        XCTAssertEqual(expanded.pending, 7)
        XCTAssertEqual(expanded.pendingHighWater, 7)
        XCTAssertEqual(expanded.inFlightHighWater, 6)
        XCTAssertEqual(expanded.ordinarySubmitted, 1)
        XCTAssertEqual(expanded.parkSubmitted, 1)
        XCTAssertEqual(expanded.closingSubmitted, 1)

        firstMailbox.cancelAll().forEach { $0.deliver() }
        secondMailbox.cancelAll().forEach { $0.deliver() }
        parkMailbox.cancelAll().forEach { $0.deliver() }
        closingMailbox.cancelAll()

        let drained = AppAXContextRuntimeMetrics.shared.snapshot()
        XCTAssertEqual(drained.pending, 0)
        XCTAssertEqual(drained.inFlight, 0)
        XCTAssertEqual(drained.pendingHighWater, 7)
        XCTAssertEqual(drained.inFlightHighWater, 6)
    }

    private func noteStarted(
        _ items: [AppAXFrameMailbox.Item],
        lane: AppAXFrameLane
    ) {
        switch lane {
        case .ordinary:
            AppAXContextRuntimeMetrics.shared.noteOrdinaryStarted(items)
        case .park:
            AppAXContextRuntimeMetrics.shared.noteParkStarted(items)
        case .closing:
            XCTFail("Unexpected closing lane")
        }
    }

    private func request(
        id: UInt64,
        windowId: Int,
        generations: LockedWindowGenerationMap
    ) -> AppAXFrameWriteRequest {
        let pid = pid_t(700_000 + windowId)
        return AppAXFrameWriteRequest(
            requestId: id,
            pid: pid,
            windowId: windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            currentFrameHint: nil,
            generation: generations.nextGeneration(for: windowId),
            verify: true
        )
    }

    private func closingRequest(windowId: Int) -> AppAXClosingFrameWriteRequest {
        let pid = pid_t(800_000 + windowId)
        return AppAXClosingFrameWriteRequest(
            target: AXClosingFrameTarget(
                animationId: UUID(),
                pid: pid,
                expectedWindow: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                frame: CGRect(x: 20, y: 30, width: 200, height: 100),
                currentFrameHint: nil
            ),
            generation: 1
        )
    }
}
