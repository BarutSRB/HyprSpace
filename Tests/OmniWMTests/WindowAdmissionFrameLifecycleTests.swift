// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionFrameLifecycleTests: XCTestCase {
    func testFrameLedgerEmitsTerminalSizeRefusalAfterSingleRetry() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_301
        let windowId = 467_401
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 0, y: 0, width: 1, height: 1)
        let failure = AXFrameWriteFailureReason.sizeWriteFailed(.attributeUnsupported)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        var observerResults: [AXFrameApplyResult] = []

        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: false,
                terminalObserver: { observerResults.append($0) }
            ).request
        )
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: firstRequest,
                observed: observed,
                failure: failure
            )
        ])
        XCTAssertEqual(firstOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])
        XCTAssertEqual(firstOutcome.retries.first?.requestId, firstRequest.requestId)
        XCTAssertTrue(firstOutcome.deliveries.isEmpty)
        XCTAssertTrue(firstOutcome.terminalRefusals.isEmpty)
        XCTAssertTrue(firstOutcome.terminalFailures.isEmpty)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger, pid: pid, window: window, frame: target, isRetry: true
            )
        )
        let retryResult = WindowAdmissionTestSupport.frameResult(
            request: retryRequest,
            observed: observed,
            failure: failure
        )
        let retryOutcome = ledger.handleFrameApplyResults([retryResult])

        XCTAssertEqual(
            retryOutcome.terminalRefusals,
            [
                AXFrameTerminalRefusal(
                    pid: pid,
                    windowId: windowId,
                    targetFrame: target,
                    observedFrame: observed,
                    failureReason: failure,
                    requestId: retryRequest.requestId,
                    traceRequestId: retryRequest.traceRequestId
                )
            ]
        )
        XCTAssertTrue(retryOutcome.retries.isEmpty)
        XCTAssertEqual(retryOutcome.deliveries.count, 1)
        XCTAssertEqual(retryOutcome.terminalFailures, [retryResult])
        let terminalFailure = try XCTUnwrap(retryOutcome.terminalFailures.first)
        XCTAssertEqual(terminalFailure.requestId, retryRequest.requestId)
        XCTAssertEqual(terminalFailure.pid, pid)
        XCTAssertEqual(terminalFailure.windowId, windowId)
        XCTAssertTrue(sameAXWindowIdentity(terminalFailure.expectedWindow, window))
        XCTAssertEqual(terminalFailure.targetFrame, target)
        XCTAssertEqual(terminalFailure.writeResult.failureReason, failure)
        XCTAssertTrue(observerResults.isEmpty)
        for delivery in retryOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(observerResults, [retryResult])
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: windowId))
    }

    func testRepeatedTerminalSizeConvergenceNormalizesObserverAndDeduplicatesExactTarget() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_305
        let windowId = 467_405
        let target = CGRect(x: 16, y: 16, width: 1_259, height: 1_378)
        let observed = CGRect(x: 16, y: 10, width: 1_259, height: 1_384)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        var terminalResults: [AXFrameApplyResult] = []

        let settlement = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed,
            terminalObserver: { terminalResults.append($0) }
        )

        XCTAssertTrue(settlement.outcome.retries.isEmpty)
        XCTAssertTrue(settlement.outcome.terminalRefusals.isEmpty)
        XCTAssertEqual(settlement.outcome.deliveries.count, 1)
        XCTAssertEqual(settlement.acceptedResults.count, 1)
        let acceptedResult = try XCTUnwrap(settlement.acceptedResults.first)
        XCTAssertNil(acceptedResult.writeResult.failureReason)
        XCTAssertTrue(acceptedResult.writeResult.isVerifiedSuccess)
        XCTAssertEqual(acceptedResult.confirmedFrame, observed)
        XCTAssertEqual(acceptedResult.targetFrame, target)

        for delivery in settlement.outcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(terminalResults, [acceptedResult])
        XCTAssertEqual(ledger.lastAppliedFrame(for: windowId), observed)
        XCTAssertNil(ledger.recentFrameWriteFailure(for: windowId))
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: windowId))

        let dedupedDecision = ledger.prepareFrameApplication(
            pid: pid,
            windowId: windowId,
            expectedWindow: window,
            frame: target,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNil(dedupedDecision.request)
    }

    func testStableGhosttyWidthFloorConvergesWithoutTerminalRefusal() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_312
        let target = CGRect(x: 0, y: 0, width: 95, height: 1_410)
        let observed = CGRect(x: 0, y: 0, width: 105, height: 1_410)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_415)

        let settlement = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed
        )

        XCTAssertTrue(settlement.outcome.retries.isEmpty)
        XCTAssertTrue(settlement.outcome.terminalRefusals.isEmpty)
        XCTAssertTrue(settlement.outcome.terminalFailures.isEmpty)
        XCTAssertEqual(settlement.acceptedResults.map(\.confirmedFrame), [observed])
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
    }

    func testAcceptedSizeConvergenceSuppressesOnlyItsExactTarget() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_306
        let windowId = 467_406
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let changedTarget = CGRect(x: 20, y: 30, width: 656, height: 480)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)

        _ = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed
        )

        XCTAssertNil(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )

        let changedDecision = ledger.prepareFrameApplication(
            pid: pid,
            windowId: windowId,
            expectedWindow: window,
            frame: changedTarget,
            isRetry: false,
            terminalObserver: nil
        )
        let changedRequest = try XCTUnwrap(changedDecision.request)
        XCTAssertEqual(changedRequest.frame, changedTarget)
        XCTAssertEqual(changedRequest.currentFrameHint, observed)
        XCTAssertEqual(ledger.pendingFrameWrite(for: windowId), changedTarget)
    }

    func testAcceptedSizeConvergenceIsInvalidatedByExternalFrameDrift() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_316
        let windowId = 467_416
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let externalFrame = CGRect(x: 24, y: 22, width: 648, height: 488)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)

        _ = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed
        )

        XCTAssertTrue(
            ledger.shouldSuppressFrameChangeRelayout(
                for: windowId,
                observedFrame: observed
            )
        )
        XCTAssertFalse(
            ledger.shouldSuppressFrameChangeRelayout(
                for: windowId,
                observedFrame: externalFrame
            )
        )
        XCTAssertNotNil(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
    }

    func testOrdinaryAppliedFrameDriftInvalidatesCachedTargetAndReappliesOnlyAffectedWindow() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_319
        let firstWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_419
        )
        let secondWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_420
        )
        let firstTarget = CGRect(x: 20, y: 30, width: 640, height: 480)
        let secondTarget = CGRect(x: 680, y: 30, width: 640, height: 480)
        ledger.confirmFrameWrite(for: firstWindow.windowId, frame: firstTarget)
        ledger.confirmFrameWrite(for: secondWindow.windowId, frame: secondTarget)

        XCTAssertNil(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: firstWindow,
                frame: firstTarget
            )
        )
        XCTAssertFalse(
            ledger.shouldSuppressFrameChangeRelayout(
                for: firstWindow.windowId,
                observedFrame: firstTarget.offsetBy(dx: 5, dy: 0)
            )
        )

        let correctiveRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: firstWindow,
                frame: firstTarget
            )
        )
        XCTAssertEqual(correctiveRequest.frame, firstTarget)
        XCTAssertNil(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: secondWindow,
                frame: secondTarget
            )
        )

        _ = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: correctiveRequest)
        ])
        XCTAssertTrue(
            ledger.shouldSuppressFrameChangeRelayout(
                for: firstWindow.windowId,
                observedFrame: firstTarget
            )
        )
        XCTAssertNil(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: firstWindow,
                frame: firstTarget
            )
        )
    }

    func testDirectPendingFrameCancellationReturnsExactTerminalFailure() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_319
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_419
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let request = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target
            )
        )
        XCTAssertNil(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target
            )
        )

        let cancellation = ledger.cancelFrameJob(pid: pid, windowId: window.windowId)

        XCTAssertTrue(cancellation.deliveries.isEmpty)
        let terminalFailure = try XCTUnwrap(cancellation.terminalFailure)
        XCTAssertEqual(terminalFailure.requestId, request.requestId)
        XCTAssertEqual(terminalFailure.pid, pid)
        XCTAssertEqual(terminalFailure.windowId, window.windowId)
        XCTAssertTrue(sameAXWindowIdentity(terminalFailure.expectedWindow, window))
        XCTAssertEqual(terminalFailure.targetFrame, target)
        XCTAssertEqual(terminalFailure.writeResult.failureReason, .cancelled)
        XCTAssertNil(ledger.cancelFrameJob(pid: pid, windowId: window.windowId).terminalFailure)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
        let replacement = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target
            )
        )
        XCTAssertNotEqual(replacement.requestId, request.requestId)
    }

    func testObserverSupersedingPendingFrameWriteReceivesCancellationSettlement() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_320
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_421
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target
            )
        )
        var terminalResults: [AXFrameApplyResult] = []

        let observerDecision = ledger.prepareFrameApplication(
            pid: pid,
            windowId: window.windowId,
            expectedWindow: window,
            frame: target,
            isRetry: false,
            terminalObserver: { terminalResults.append($0) }
        )
        XCTAssertNotNil(observerDecision.request)
        XCTAssertTrue(observerDecision.deliveries.isEmpty)

        let cancellation = ledger.cancelFrameJob(pid: pid, windowId: window.windowId)
        XCTAssertEqual(cancellation.deliveries.count, 1)
        XCTAssertEqual(cancellation.terminalFailure?.writeResult.failureReason, .cancelled)
        XCTAssertEqual(cancellation.terminalFailure?.requestId, observerDecision.request?.requestId)
        for delivery in cancellation.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
    }

    func testScheduledRetryCancellationPreservesObserverRequestIdentityForGenericFailure() async throws {
        let manager = AXManager()
        let pid: pid_t = 467_321
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_421
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        var observerResults: [AXFrameApplyResult] = []
        var genericFailures: [AXFrameApplyResult] = []
        manager.onFrameApplyTerminated = { genericFailures.append($0) }

        manager.applyFramesParallel(
            [AXFrameApplicationTarget(pid: pid, window: window, frame: target)],
            terminalObserver: { observerResults.append($0) }
        )
        XCTAssertTrue(observerResults.isEmpty)
        XCTAssertTrue(genericFailures.isEmpty)

        manager.cancelPendingFrameJobs([(pid: pid, windowId: window.windowId)])
        await Task.yield()

        let observerResult = try XCTUnwrap(observerResults.first)
        let genericFailure = try XCTUnwrap(genericFailures.first)
        XCTAssertEqual(observerResults.count, 1)
        XCTAssertEqual(genericFailures.count, 1)
        XCTAssertGreaterThan(observerResult.requestId, 0)
        XCTAssertEqual(genericFailure.requestId, observerResult.requestId)
        XCTAssertEqual(genericFailure.pid, pid)
        XCTAssertEqual(genericFailure.windowId, window.windowId)
        XCTAssertTrue(sameAXWindowIdentity(genericFailure.expectedWindow, window))
        XCTAssertEqual(genericFailure.targetFrame, target)
        XCTAssertEqual(genericFailure.writeResult.failureReason, .cancelled)
    }

    func testRetryExhaustionInvokesManagerTerminalFailureCallback() async throws {
        let manager = AXManager()
        let pid: pid_t = 467_322
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_422
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        var genericFailures: [AXFrameApplyResult] = []
        manager.onFrameApplyTerminated = { genericFailures.append($0) }

        manager.applyFramesParallel([
            AXFrameApplicationTarget(pid: pid, window: window, frame: target)
        ])
        XCTAssertTrue(genericFailures.isEmpty)

        await Task.yield()

        let genericFailure = try XCTUnwrap(genericFailures.first)
        XCTAssertEqual(genericFailures.count, 1)
        XCTAssertGreaterThan(genericFailure.requestId, 0)
        XCTAssertEqual(genericFailure.pid, pid)
        XCTAssertEqual(genericFailure.windowId, window.windowId)
        XCTAssertTrue(sameAXWindowIdentity(genericFailure.expectedWindow, window))
        XCTAssertEqual(genericFailure.targetFrame, target)
        XCTAssertEqual(genericFailure.writeResult.failureReason, .contextUnavailable)
    }

    func testAcceptedSizeConvergenceIsInvalidatedWhenExternalFrameCannotBeRead() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_317
        let windowId = 467_417
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)

        _ = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed
        )

        XCTAssertFalse(
            ledger.shouldSuppressFrameChangeRelayout(
                for: windowId,
                observedFrame: nil
            )
        )
        XCTAssertNotNil(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
    }

    func testSizeConvergenceAcceptsExactFrameToleranceBoundary() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_318
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_418
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 30, width: 641, height: 480)

        let settlement = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: window,
            target: target,
            observed: observed
        )

        XCTAssertTrue(settlement.outcome.terminalRefusals.isEmpty)
        XCTAssertEqual(settlement.acceptedResults.map(\.confirmedFrame), [observed])
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), observed)
    }

    func testSizeConvergenceRequiresStableRetryObservation() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_307
        let windowId = 467_407
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let firstObserved = CGRect(x: 20, y: 22, width: 648, height: 488)
        let retryObserved = CGRect(x: 20, y: 20, width: 648, height: 490)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let firstRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: target)
        )
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: firstRequest,
                observed: firstObserved
            )
        ])
        XCTAssertEqual(firstOutcome.retries.count, 1)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target,
                isRetry: true
            )
        )
        var acceptedResults: [AXFrameApplyResult] = []
        let retryOutcome = ledger.handleFrameApplyResults(
            [
                WindowAdmissionTestSupport.verificationMismatchFrameResult(
                    request: retryRequest,
                    observed: retryObserved
                )
            ],
            onAcceptedSuccess: { acceptedResults.append($0) }
        )

        XCTAssertTrue(acceptedResults.isEmpty)
        XCTAssertEqual(
            retryOutcome.terminalRefusals,
            [
                AXFrameTerminalRefusal(
                    pid: pid,
                    windowId: windowId,
                    targetFrame: target,
                    observedFrame: retryObserved,
                    failureReason: .verificationMismatch,
                    requestId: retryRequest.requestId,
                    traceRequestId: retryRequest.traceRequestId
                )
            ]
        )
        XCTAssertNil(ledger.lastAppliedFrame(for: windowId))
    }

    func testAcceptedSizeConvergenceDoesNotSuppressStackedWindowMoves() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_308
        let firstWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_408
        )
        let secondWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_409
        )
        let firstTarget = CGRect(x: 20, y: 30, width: 640, height: 220)
        let secondTarget = CGRect(x: 20, y: 270, width: 640, height: 220)
        let firstObserved = CGRect(x: 20, y: 26, width: 648, height: 224)
        let secondObserved = CGRect(x: 20, y: 266, width: 648, height: 224)

        _ = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: firstWindow,
            target: firstTarget,
            observed: firstObserved
        )
        _ = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: secondWindow,
            target: secondTarget,
            observed: secondObserved
        )

        let movedFirstTarget = CGRect(origin: secondTarget.origin, size: firstTarget.size)
        let movedSecondTarget = CGRect(origin: firstTarget.origin, size: secondTarget.size)
        let movedFirstObserved = CGRect(origin: secondObserved.origin, size: firstObserved.size)
        let movedSecondObserved = CGRect(origin: firstObserved.origin, size: secondObserved.size)
        let firstMove = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: firstWindow,
            target: movedFirstTarget,
            observed: movedFirstObserved
        )
        let secondMove = try settleSizeConvergence(
            ledger,
            pid: pid,
            window: secondWindow,
            target: movedSecondTarget,
            observed: movedSecondObserved
        )

        XCTAssertEqual(firstMove.acceptedResults.map(\.confirmedFrame), [movedFirstObserved])
        XCTAssertEqual(secondMove.acceptedResults.map(\.confirmedFrame), [movedSecondObserved])
        XCTAssertEqual(ledger.lastAppliedFrame(for: firstWindow.windowId), movedFirstObserved)
        XCTAssertEqual(ledger.lastAppliedFrame(for: secondWindow.windowId), movedSecondObserved)
    }

    func testSizeConvergenceRejectsMovementOversizedDeltaAndSetterFailures() throws {
        let pid: pid_t = 467_307
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)

        let positionLedger = AXFrameApplicationLedger()
        let positionWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_408
        )
        let positionOutcome = try exhaustFrameFailure(
            positionLedger,
            pid: pid,
            window: positionWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: $0,
                observed: CGRect(x: 22, y: 22, width: 648, height: 488)
            )
        }
        XCTAssertEqual(positionOutcome.terminalRefusals.count, 1)
        XCTAssertNil(positionLedger.lastAppliedFrame(for: positionWindow.windowId))
        XCTAssertEqual(
            positionLedger.recentFrameWriteFailure(for: positionWindow.windowId),
            .verificationMismatch
        )

        let oppositeAnchorLedger = AXFrameApplicationLedger()
        let oppositeAnchorWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_415
        )
        let oppositeAnchorOutcome = try exhaustFrameFailure(
            oppositeAnchorLedger,
            pid: pid,
            window: oppositeAnchorWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: $0,
                observed: CGRect(x: 12, y: 22, width: 648, height: 488)
            )
        }
        XCTAssertEqual(oppositeAnchorOutcome.terminalRefusals.count, 1)
        XCTAssertNil(oppositeAnchorLedger.lastAppliedFrame(for: oppositeAnchorWindow.windowId))
        XCTAssertEqual(
            oppositeAnchorLedger.recentFrameWriteFailure(for: oppositeAnchorWindow.windowId),
            .verificationMismatch
        )

        let verticalAnchorLedger = AXFrameApplicationLedger()
        let verticalAnchorWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_416
        )
        let verticalAnchorOutcome = try exhaustFrameFailure(
            verticalAnchorLedger,
            pid: pid,
            window: verticalAnchorWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: $0,
                observed: CGRect(x: 20, y: 30, width: 648, height: 488)
            )
        }
        XCTAssertEqual(verticalAnchorOutcome.terminalRefusals.count, 1)
        XCTAssertNil(verticalAnchorLedger.lastAppliedFrame(for: verticalAnchorWindow.windowId))
        XCTAssertEqual(
            verticalAnchorLedger.recentFrameWriteFailure(for: verticalAnchorWindow.windowId),
            .verificationMismatch
        )

        let oversizedLedger = AXFrameApplicationLedger()
        let oversizedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_409
        )
        let oversizedOutcome = try exhaustFrameFailure(
            oversizedLedger,
            pid: pid,
            window: oversizedWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: $0,
                observed: CGRect(x: 20, y: 13, width: 657, height: 497)
            )
        }
        XCTAssertEqual(oversizedOutcome.terminalRefusals.count, 1)
        XCTAssertNil(oversizedLedger.lastAppliedFrame(for: oversizedWindow.windowId))
        XCTAssertEqual(
            oversizedLedger.recentFrameWriteFailure(for: oversizedWindow.windowId),
            .verificationMismatch
        )

        let setterLedger = AXFrameApplicationLedger()
        let setterWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_410
        )
        let setterFailure = AXFrameWriteFailureReason.sizeWriteFailed(.attributeUnsupported)
        let setterOutcome = try exhaustFrameFailure(
            setterLedger,
            pid: pid,
            window: setterWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.frameResult(
                request: $0,
                observed: CGRect(x: 20, y: 22, width: 648, height: 488),
                failure: setterFailure
            )
        }
        XCTAssertEqual(setterOutcome.terminalRefusals.count, 1)
        XCTAssertNil(setterLedger.lastAppliedFrame(for: setterWindow.windowId))
        XCTAssertEqual(setterLedger.recentFrameWriteFailure(for: setterWindow.windowId), setterFailure)

        let positionSetterLedger = AXFrameApplicationLedger()
        let positionSetterWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 467_414
        )
        let positionSetterFailure = AXFrameWriteFailureReason.positionWriteFailed(.attributeUnsupported)
        let positionSetterOutcome = try exhaustFrameFailure(
            positionSetterLedger,
            pid: pid,
            window: positionSetterWindow,
            target: target
        ) {
            WindowAdmissionTestSupport.frameResult(
                request: $0,
                observed: CGRect(x: 20, y: 22, width: 648, height: 488),
                failure: positionSetterFailure,
                sizeError: .success,
                positionError: .attributeUnsupported
            )
        }
        XCTAssertEqual(positionSetterOutcome.terminalRefusals.count, 1)
        XCTAssertNil(positionSetterLedger.lastAppliedFrame(for: positionSetterWindow.windowId))
        XCTAssertEqual(
            positionSetterLedger.recentFrameWriteFailure(for: positionSetterWindow.windowId),
            positionSetterFailure
        )
    }

    func testForgedWindowIdentityCannotAcceptSizeConvergence() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_308
        let windowId = 467_411
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let firstRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: target)
        )
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: firstRequest,
                observed: observed
            )
        ])
        XCTAssertEqual(firstOutcome.retries.count, 1)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target,
                isRetry: true
            )
        )
        let validResult = WindowAdmissionTestSupport.verificationMismatchFrameResult(
            request: retryRequest,
            observed: observed
        )
        let forgedResult = AXFrameApplyResult(
            requestId: validResult.requestId,
            pid: validResult.pid,
            windowId: validResult.windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(pid + 1),
                windowId: windowId
            ),
            targetFrame: validResult.targetFrame,
            currentFrameHint: validResult.currentFrameHint,
            writeResult: validResult.writeResult
        )
        var acceptedResults: [AXFrameApplyResult] = []

        let forgedOutcome = ledger.handleFrameApplyResults(
            [forgedResult],
            onAcceptedSuccess: { acceptedResults.append($0) }
        )
        XCTAssertTrue(forgedOutcome.deliveries.isEmpty)
        XCTAssertTrue(forgedOutcome.retries.isEmpty)
        XCTAssertTrue(forgedOutcome.terminalRefusals.isEmpty)
        XCTAssertTrue(forgedOutcome.terminalFailures.isEmpty)
        XCTAssertTrue(acceptedResults.isEmpty)
        XCTAssertTrue(ledger.hasPendingFrameWrite(for: windowId))
        XCTAssertNil(ledger.lastAppliedFrame(for: windowId))

        let validOutcome = ledger.handleFrameApplyResults(
            [validResult],
            onAcceptedSuccess: { acceptedResults.append($0) }
        )
        XCTAssertTrue(validOutcome.terminalRefusals.isEmpty)
        XCTAssertEqual(acceptedResults.map(\.confirmedFrame), [observed])
    }

    func testSizeConvergenceEvidenceSurvivesSameIncarnationRekey() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_317
        let oldWindowId = 467_417
        let newWindowId = 467_418
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 22, width: 648, height: 488)
        let oldWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newWindow = AXWindowRef(element: oldWindow.element, windowId: newWindowId)
        let firstRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: oldWindow,
                frame: target
            )
        )
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: firstRequest,
                observed: observed
            )
        ])
        XCTAssertEqual(firstOutcome.retries.count, 1)

        ledger.rekeyWindowState(oldWindowId: oldWindowId, newWindowId: newWindowId)
        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: newWindow,
                frame: target,
                isRetry: true
            )
        )
        var acceptedResults: [AXFrameApplyResult] = []
        let retryOutcome = ledger.handleFrameApplyResults(
            [
                WindowAdmissionTestSupport.verificationMismatchFrameResult(
                    request: retryRequest,
                    observed: observed
                )
            ],
            onAcceptedSuccess: { acceptedResults.append($0) }
        )

        XCTAssertTrue(retryOutcome.terminalRefusals.isEmpty)
        XCTAssertEqual(acceptedResults.map(\.windowId), [newWindowId])
        XCTAssertEqual(acceptedResults.map(\.confirmedFrame), [observed])
        XCTAssertEqual(ledger.lastAppliedFrame(for: newWindowId), observed)
    }

    func testFrameLedgerDoesNotAcceptStaleSuccessForQuarantineReset() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_302
        let windowId = 467_402
        let firstTarget = CGRect(x: 20, y: 30, width: 640, height: 480)
        let secondTarget = CGRect(x: 40, y: 50, width: 800, height: 600)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: firstTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        let secondRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: secondTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var acceptedWindowIds: [Int] = []

        let staleOutcome = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: firstRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertTrue(acceptedWindowIds.isEmpty)
        XCTAssertTrue(staleOutcome.terminalFailures.isEmpty)

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: secondRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testFrameLedgerRejectsResultFromDifferentExpectedWindowIdentity() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_303
        let windowId = 467_403
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let request = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: target)
        )
        let validResult = WindowAdmissionTestSupport.successfulFrameResult(request: request)
        let forgedResult = AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(pid + 1),
                windowId: windowId
            ),
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: validResult.writeResult
        )
        var acceptedWindowIds: [Int] = []

        let forgedOutcome = ledger.handleFrameApplyResults(
            [forgedResult],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertTrue(acceptedWindowIds.isEmpty)
        XCTAssertTrue(forgedOutcome.terminalFailures.isEmpty)
        XCTAssertTrue(ledger.hasPendingFrameWrite(for: windowId))

        _ = ledger.handleFrameApplyResults(
            [validResult],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testFrameLedgerRejectsOldIncarnationResultAfterStateRemoval() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 467_304
        let windowId = 467_404
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let oldWindow = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let newWindow = AXWindowRef(element: AXUIElementCreateApplication(pid + 1), windowId: windowId)
        let oldRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: oldWindow,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        _ = ledger.removeWindowState(windowId: windowId)
        let newRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid + 1,
                windowId: windowId,
                expectedWindow: newWindow,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var acceptedWindowIds: [Int] = []

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: oldRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertTrue(acceptedWindowIds.isEmpty)

        _ = ledger.handleFrameApplyResults(
            [WindowAdmissionTestSupport.successfulFrameResult(request: newRequest)],
            onAcceptedSuccess: { acceptedWindowIds.append($0.windowId) }
        )
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testBoundedSizeSetterFailureAdoptsObservedMinimumWithoutQuarantine() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_309
        let windowId = 467_412
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 20, y: 30, width: 648, height: 488),
            failureReason: .sizeWriteFailed(.attributeUnsupported)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(
            controller.workspaceManager.observedMinSize(for: token),
            CGSize(width: 648, height: 488)
        )
        XCTAssertFalse(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
    }

    func testPositionSetterFailureDoesNotAdoptFullscreenFrameAsObservedMinimum() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_310
        let windowId = 467_413
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 16, y: 16, width: 2_528, height: 1_378),
            observedFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_388),
            failureReason: .positionWriteFailed(.failure)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.observedMinSize(for: token))
        XCTAssertFalse(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
    }

    func testMeaningfulVerificationMismatchDoesNotAdoptObservedMinimum() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_311
        let windowId = 467_414
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 1_288, y: 0, width: 1_272, height: 1_410),
            observedFrame: CGRect(x: 1_288, y: 0, width: 2_560, height: 1_410),
            failureReason: .verificationMismatch
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.observedMinSize(for: token))
        XCTAssertFalse(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
    }

    func testRepeatedDegenerateVerificationMismatchQuarantinesIncarnation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_702
        let windowId = 467_802
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            failureReason: .verificationMismatch
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
    }

    func testRepeatedDegenerateTerminalRefusalRemovesAndQuarantinesIncarnation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_701
        let windowId = 467_801
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let proxyAXRef = AXWindowRef(element: AXUIElementCreateApplication(pid + 1), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [pid, pid + 1], axRefs: [axRef, proxyAXRef])
        ])
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let refusal = AXFrameTerminalRefusal(
            pid: pid,
            windowId: windowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            failureReason: .sizeWriteFailed(.attributeUnsupported)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: axRef))
        XCTAssertTrue(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: proxyAXRef))
        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, token)

        let replacement = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 2),
            windowId: windowId
        )
        XCTAssertFalse(controller.axEventHandler.isAdmissionQuarantined(windowId: windowId, axRef: replacement))
    }

    func testBackgroundPendingFocusTerminalRefusalPreservesConfirmedFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let refusedPID: pid_t = 467_711
        let focusedPID: pid_t = 467_712
        let refusedWindowId = 467_811
        let focusedWindowId = 467_812
        let refusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(refusedPID), windowId: refusedWindowId),
            pid: refusedPID,
            windowId: refusedWindowId,
            to: workspaceId
        )
        let focusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(focusedPID), windowId: focusedWindowId),
            pid: focusedPID,
            windowId: focusedWindowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                focusedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(
            token: refusedToken,
            workspaceId: workspaceId
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            refusedToken,
            in: workspaceId,
            requestId: request.requestId
        )
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, refusedToken)
        let refusal = AXFrameTerminalRefusal(
            pid: refusedPID,
            windowId: refusedWindowId,
            targetFrame: CGRect(x: 20, y: 30, width: 640, height: 480),
            observedFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            failureReason: .sizeWriteFailed(.attributeUnsupported)
        )

        controller.axEventHandler.handleTerminalFrameRefusal(refusal)
        controller.axEventHandler.handleTerminalFrameRefusal(refusal)

        XCTAssertNil(controller.workspaceManager.entry(for: refusedToken))
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, focusedToken)
        XCTAssertEqual(controller.workspaceManager.renderableFocusToken, focusedToken)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
    }

    func testRememberedTerminalRefusalStopsReissuingTheSameTarget() throws {
        let pid: pid_t = 467_331
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_431)
        let target = CGRect(x: 100, y: 60, width: 900, height: 400)
        let observed = CGRect(x: 100, y: 60, width: 900, height: 492)
        let ledger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)

        XCTAssertNil(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: target)
        )
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))

        var observerResults: [AXFrameApplyResult] = []
        let declined = ledger.prepareFrameApplication(
            pid: pid,
            windowId: window.windowId,
            expectedWindow: window,
            frame: target,
            isRetry: false,
            terminalObserver: { observerResults.append($0) }
        )
        XCTAssertNil(declined.request)
        XCTAssertFalse(declined.shouldCancelPendingRetry)
        XCTAssertEqual(declined.deliveries.count, 1)
        for delivery in declined.deliveries {
            delivery.deliver()
        }
        let refused = try XCTUnwrap(observerResults.first)
        XCTAssertEqual(observerResults.count, 1)
        XCTAssertEqual(refused.targetFrame, target)
        XCTAssertEqual(refused.writeResult.failureReason, .verificationMismatch)
        XCTAssertEqual(refused.writeResult.observedFrame, observed)
        XCTAssertNil(refused.confirmedFrame)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: window.windowId))
    }

    func testRememberedTerminalRefusalReleasesOnTargetChangeForceApplyAndInvalidation() throws {
        let pid: pid_t = 467_332
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_432)
        let target = CGRect(x: 100, y: 60, width: 900, height: 400)
        let observed = CGRect(x: 100, y: 60, width: 900, height: 492)

        let targetChangeLedger = try refusedTargetLedger(
            pid: pid, window: window, target: target, observed: observed
        )
        let tallerTarget = CGRect(x: 100, y: 60, width: 900, height: 560)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(
                targetChangeLedger, pid: pid, window: window, frame: tallerTarget
            )
        )

        let forceApplyLedger = try refusedTargetLedger(
            pid: pid, window: window, target: target, observed: observed
        )
        forceApplyLedger.forceApplyNextFrame(for: window.windowId)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(
                forceApplyLedger, pid: pid, window: window, frame: target
            )
        )

        let invalidationLedger = try refusedTargetLedger(
            pid: pid, window: window, target: target, observed: observed
        )
        invalidationLedger.invalidateAppliedFrame(for: window.windowId)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(
                invalidationLedger, pid: pid, window: window, frame: target
            )
        )

        let removalLedger = try refusedTargetLedger(
            pid: pid, window: window, target: target, observed: observed
        )
        XCTAssertTrue(removalLedger.removeWindowState(windowId: window.windowId).isEmpty)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(
                removalLedger, pid: pid, window: window, frame: target
            )
        )
    }

    func testEnforcedSizePlacementAnchorsTheRefusedSizeToTheTargetTopLeft() throws {
        let pid: pid_t = 467_333
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_433)
        let target = CGRect(x: 2_409, y: 1_113, width: 1_257, height: 280)
        let observed = CGRect(x: 2_409, y: 901, width: 1_257, height: 492)
        let ledger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)

        let scrolled = CGRect(x: 1_286, y: 1_113, width: 1_257, height: 280)
        XCTAssertEqual(
            ledger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled),
            CGRect(x: 1_286, y: 901, width: 1_257, height: 492)
        )
        XCTAssertEqual(
            ledger.enforcedSizePlacement(for: window.windowId, targetFrame: target),
            observed
        )
        XCTAssertNil(
            ledger.enforcedSizePlacement(
                for: window.windowId,
                targetFrame: CGRect(x: 1_286, y: 1_113, width: 1_257, height: 560)
            )
        )
    }

    func testPositionOnlyWriteKeepsTheTerminalSizeRefusalRemembered() throws {
        let pid: pid_t = 467_334
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_434)
        let target = CGRect(x: 2_409, y: 1_113, width: 1_257, height: 280)
        let observed = CGRect(x: 2_409, y: 901, width: 1_257, height: 492)
        let ledger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)

        let scrolled = CGRect(x: 1_286, y: 1_113, width: 1_257, height: 280)
        let placement = try XCTUnwrap(
            ledger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled)
        )
        let positionRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                frame: placement,
                components: .position,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        XCTAssertEqual(positionRequest.components, .position)
        let outcome = ledger.handleFrameApplyResults([
            AXFrameApplyResult(
                requestId: positionRequest.requestId,
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                targetFrame: placement,
                currentFrameHint: positionRequest.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    observedFrame: placement,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: .position
                )
            )
        ])
        XCTAssertTrue(outcome.terminalFailures.isEmpty)
        XCTAssertEqual(ledger.lastAppliedFrame(for: window.windowId), placement)
        XCTAssertEqual(
            ledger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled),
            placement
        )

        let tallerTarget = CGRect(x: 1_286, y: 1_113, width: 1_257, height: 560)
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: tallerTarget)
        )
        XCTAssertNil(ledger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled))
    }

    func testObservedFrameAtTheRefusedSizeReleasesTheRefusal() throws {
        let pid: pid_t = 467_336
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_436)
        let target = CGRect(x: 2_409, y: 1_113, width: 1_257, height: 280)
        let observed = CGRect(x: 2_409, y: 901, width: 1_257, height: 492)
        let scrolled = CGRect(x: 1_286, y: 1_113, width: 1_257, height: 280)

        let releasedLedger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)
        let placement = try XCTUnwrap(
            releasedLedger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled)
        )
        let released = CGRect(x: placement.minX, y: placement.minY, width: target.width, height: target.height)
        XCTAssertTrue(
            try positionOnlyReadback(releasedLedger, pid: pid, window: window, placement: placement, observed: released)
                .terminalFailures.isEmpty
        )
        XCTAssertNil(releasedLedger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled))
        XCTAssertNotNil(
            WindowAdmissionTestSupport.frameRequest(releasedLedger, pid: pid, window: window, frame: target)
        )

        let clampedLedger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)
        XCTAssertTrue(
            try positionOnlyReadback(clampedLedger, pid: pid, window: window, placement: placement, observed: placement)
                .terminalFailures.isEmpty
        )
        XCTAssertEqual(clampedLedger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled), placement)
        XCTAssertNil(WindowAdmissionTestSupport.frameRequest(clampedLedger, pid: pid, window: window, frame: target))

        let otherIdentity = AXWindowRef(element: AXUIElementCreateApplication(pid + 1), windowId: window.windowId)
        let identityLedger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)
        XCTAssertTrue(
            try positionOnlyReadback(
                identityLedger, pid: pid, window: otherIdentity, placement: placement, observed: released
            ).terminalFailures.isEmpty
        )
        XCTAssertEqual(identityLedger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled), placement)
        XCTAssertNil(WindowAdmissionTestSupport.frameRequest(identityLedger, pid: pid, window: window, frame: target))
    }

    func testIdenticalRepeatFailureKeepsTheRefusalTerminalAcrossTheRetryChain() throws {
        let pid: pid_t = 467_338
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 467_438)
        let target = CGRect(x: 2_409, y: 1_113, width: 1_257, height: 280)
        let observed = CGRect(x: 2_409, y: 901, width: 1_257, height: 492)
        let ledger = try refusedTargetLedger(pid: pid, window: window, target: target, observed: observed)

        let scrolled = CGRect(x: 1_286, y: 1_113, width: 1_257, height: 280)
        let scrolledObserved = CGRect(x: 1_286, y: 901, width: 1_257, height: 492)
        let request = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(ledger, pid: pid, window: window, frame: scrolled)
        )
        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: request,
                observed: scrolledObserved
            )
        ])
        XCTAssertEqual(outcome.retries.count, 1)
        XCTAssertTrue(outcome.terminalRefusals.isEmpty)
        XCTAssertEqual(
            ledger.enforcedSizePlacement(for: window.windowId, targetFrame: scrolled),
            scrolledObserved
        )
    }

    private func refusedTargetLedger(
        pid: pid_t,
        window: AXWindowRef,
        target: CGRect,
        observed: CGRect
    ) throws -> AXFrameApplicationLedger {
        let ledger = AXFrameApplicationLedger()
        let outcome = try exhaustFrameFailure(ledger, pid: pid, window: window, target: target) {
            WindowAdmissionTestSupport.verificationMismatchFrameResult(request: $0, observed: observed)
        }
        XCTAssertEqual(outcome.terminalRefusals.count, 1)
        return ledger
    }

    private func positionOnlyReadback(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        window: AXWindowRef,
        placement: CGRect,
        observed: CGRect
    ) throws -> AXFrameApplyOutcome {
        let request = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                frame: placement,
                components: .position,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        return ledger.handleFrameApplyResults([
            AXFrameApplyResult(
                requestId: request.requestId,
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                targetFrame: placement,
                currentFrameHint: request.currentFrameHint,
                writeResult: AXFrameWriteResult(
                    observedFrame: observed,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: .position
                )
            )
        ])
    }

    private func settleSizeConvergence(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        window: AXWindowRef,
        target: CGRect,
        observed: CGRect,
        terminalObserver: AXFrameApplicationTerminalObserver? = nil
    ) throws -> (outcome: AXFrameApplyOutcome, acceptedResults: [AXFrameApplyResult]) {
        let firstDecision = ledger.prepareFrameApplication(
            pid: pid,
            windowId: window.windowId,
            expectedWindow: window,
            frame: target,
            isRetry: false,
            terminalObserver: terminalObserver
        )
        let firstRequest = try XCTUnwrap(firstDecision.request)
        let firstOutcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: firstRequest,
                observed: observed
            )
        ])
        XCTAssertEqual(firstOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                frame: target,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])
        XCTAssertTrue(firstOutcome.deliveries.isEmpty)
        XCTAssertTrue(firstOutcome.terminalRefusals.isEmpty)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target,
                isRetry: true
            )
        )
        var acceptedResults: [AXFrameApplyResult] = []
        let outcome = ledger.handleFrameApplyResults(
            [
                WindowAdmissionTestSupport.verificationMismatchFrameResult(
                    request: retryRequest,
                    observed: observed
                )
            ],
            onAcceptedSuccess: { acceptedResults.append($0) }
        )
        return (outcome, acceptedResults)
    }

    private func exhaustFrameFailure(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        window: AXWindowRef,
        target: CGRect,
        makeResult: (AXFrameApplicationRequest) -> AXFrameApplyResult
    ) throws -> AXFrameApplyOutcome {
        let firstRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target
            )
        )
        let firstOutcome = ledger.handleFrameApplyResults([makeResult(firstRequest)])
        XCTAssertEqual(firstOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: pid,
                windowId: window.windowId,
                expectedWindow: window,
                frame: target,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])
        XCTAssertTrue(firstOutcome.terminalRefusals.isEmpty)

        let retryRequest = try XCTUnwrap(
            WindowAdmissionTestSupport.frameRequest(
                ledger,
                pid: pid,
                window: window,
                frame: target,
                isRetry: true
            )
        )
        return ledger.handleFrameApplyResults([makeResult(retryRequest)])
    }
}
