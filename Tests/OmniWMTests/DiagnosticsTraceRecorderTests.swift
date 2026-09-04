// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Dispatch
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
private final class DiagnosticsEvidenceGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class DiagnosticsTraceRecorderTests: XCTestCase {
    func testDiagnosticStringBudgetPreservesValidUTF8() {
        let bounded = RuntimeTraceLimits.boundedString(String(repeating: "🪟", count: 2_000))

        XCTAssertLessThanOrEqual(bounded.utf8.count, RuntimeTraceLimits.diagnosticStringBytes)
        XCTAssertEqual(String(data: Data(bounded.utf8), encoding: .utf8), bounded)
    }

    func testSessionTraceRecorderGatingEvictionAndReset() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 3) { "\($0)" }

        recorder.record(1)
        XCTAssertEqual(recorder.dump(), "none", "records dropped while capture inactive")

        recorder.beginCapture()
        recorder.record(1)
        recorder.record(2)
        recorder.record(3)
        recorder.record(4)
        XCTAssertEqual(
            recorder.dump(),
            "incomplete=true evicted=1\n2\n3\n4",
            "ring reports that its oldest record was evicted"
        )

        recorder.record(5)
        XCTAssertEqual(
            recorder.dump(),
            "incomplete=true evicted=2\n3\n4\n5",
            "snapshot rotation retains the newest records across flushes"
        )

        recorder.endCapture()
        recorder.record(6)
        XCTAssertEqual(
            recorder.dump(),
            "incomplete=true evicted=2\n3\n4\n5",
            "records dropped after capture ends without hiding prior eviction"
        )

        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none", "beginCapture resets the ring")
    }

    func testSessionTraceRecorderDoesNotEvaluateWhenInactive() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 4) { "\($0)" }
        var evaluations = 0
        let make: () -> Int = {
            evaluations += 1
            return 7
        }

        recorder.record(make())
        XCTAssertEqual(evaluations, 0, "autoclosure must not run while inactive")

        recorder.beginCapture()
        recorder.record(make())
        XCTAssertEqual(evaluations, 1)
    }

    func testSessionTraceRecorderDefersEveryRingAllocationUntilCaptureStart() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 4) { "\($0)" }

        XCTAssertFalse(recorder.isStoragePrepared, "active ring must not allocate before capture")
        XCTAssertFalse(recorder.isSpareStoragePrepared, "spare ring must not allocate before capture")

        recorder.beginCapture()
        XCTAssertTrue(recorder.isStoragePrepared)
        XCTAssertTrue(
            recorder.isSpareStoragePrepared,
            "spare must be ready so snapshot rotation never allocates while holding the lock"
        )

        recorder.record(1)
        recorder.endCapture()
        XCTAssertTrue(recorder.isStoragePrepared, "endCapture freezes producers without dropping storage")
        XCTAssertEqual(recorder.dump(), "1")
    }

    func testSessionTraceRecorderReleaseStorageDropsActiveSpareAndRetainedRings() {
        let recorder = SessionTraceRecorder<Int>(sectionTitle: "Nums", capacity: 4) { "\($0)" }

        recorder.beginCapture()
        recorder.record(1)
        XCTAssertEqual(recorder.dump(), "1", "dump retains records so the final write can read them")
        XCTAssertTrue(recorder.isRetainedStoragePrepared)
        XCTAssertEqual(recorder.dump(), "1", "an empty active ring must still return retained records")
        recorder.endCapture()

        recorder.releaseStorage()
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(recorder.isRetainedStoragePrepared)
        XCTAssertEqual(recorder.dump(), "none", "retained snapshot storage is released too")
        XCTAssertFalse(recorder.isStoragePrepared, "an empty read must not recreate released storage")
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(recorder.isRetainedStoragePrepared)

        var lines: [String] = []
        recorder.forEachLine {
            lines.append($0)
            return true
        }
        XCTAssertEqual(lines, ["none"])
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(recorder.isRetainedStoragePrepared)
    }

    func testVerboseEventRecorderPreparesOnlyActiveStorageAndReleasesIt() {
        let recorder = DiagnosticsEventRecorder()

        XCTAssertFalse(recorder.isVerboseStoragePrepared)
        XCTAssertFalse(recorder.isVerboseSpareStoragePrepared)

        recorder.beginVerboseCapture()
        XCTAssertTrue(recorder.isVerboseStoragePrepared)
        XCTAssertFalse(recorder.isVerboseSpareStoragePrepared)
        recorder.recordVerbose(name: "frame.changed", windowId: 42)
        recorder.endVerboseCapture()

        var lines: [String] = []
        recorder.forEachVerboseLine {
            lines.append($0)
            return true
        }
        XCTAssertEqual(lines.count, 1)

        recorder.releaseVerboseStorage()
        XCTAssertFalse(recorder.isVerboseStoragePrepared)
        XCTAssertFalse(recorder.isVerboseSpareStoragePrepared)

        lines.removeAll()
        recorder.forEachVerboseLine {
            lines.append($0)
            return true
        }
        XCTAssertEqual(lines, ["none"])
        XCTAssertFalse(recorder.isVerboseStoragePrepared)

        recorder.recordVerbose(name: "after-release", windowId: 42)
        XCTAssertFalse(recorder.isVerboseStoragePrepared)
    }

    @MainActor
    func testDelayedPriorCaptureLineageIsZeroedDuringNextCapture() {
        let firstGeneration: UInt64 = 101
        let secondGeneration: UInt64 = 102
        FrameApplyTrace.shared.beginCapture()
        AXWriteLatencyTrace.shared.beginCapture()
        FrameEffectTraceContext.beginCapture(generation: firstGeneration)
        let staleTraceRequestId = FrameEffectTraceContext.makeRequestTraceId()
        FrameEffectTraceContext.endCapture()
        FrameApplyTrace.shared.endCapture()
        AXWriteLatencyTrace.shared.endCapture()

        FrameApplyTrace.shared.beginCapture()
        AXWriteLatencyTrace.shared.beginCapture()
        FrameEffectTraceContext.beginCapture(generation: secondGeneration)
        defer {
            FrameEffectTraceContext.endCapture()
            FrameApplyTrace.shared.endCapture()
            AXWriteLatencyTrace.shared.endCapture()
        }

        let pid: pid_t = 701_001
        let windowId = 701_101
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        FrameApplyTrace.recordResult(
            AXFrameApplyResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                targetFrame: frame,
                currentFrameHint: nil,
                writeResult: .skipped(
                    targetFrame: frame,
                    currentFrameHint: nil,
                    failureReason: .cancelled
                ),
                traceRequestId: staleTraceRequestId
            )
        )

        let generations = LockedWindowGenerationMap()
        let request = AppAXFrameWriteRequest(
            requestId: 2,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            frame: frame,
            currentFrameHint: nil,
            generation: generations.nextGeneration(for: windowId),
            verify: true,
            traceRequestId: staleTraceRequestId
        )
        generations.invalidateAndRemove(windowId)
        _ = AppAXContext.executeFrameWriteRequests(
            [request],
            pid: pid,
            axApp: AXUIElementCreateApplication(pid),
            generations: generations,
            suppression: nil,
            hardSuppression: nil,
            isCancelled: { false }
        )

        let offMainIdentifier = DispatchQueue.global().sync {
            FrameEffectTraceContext.currentCaptureIdentifier(staleTraceRequestId)
        }
        XCTAssertEqual(offMainIdentifier, 0)
        XCTAssertTrue(FrameApplyTrace.shared.dump().contains("trace=0"))
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("trace=\(staleTraceRequestId)"))
        XCTAssertTrue(AXWriteLatencyTrace.shared.dump().contains("event=attempt"))
        XCTAssertTrue(AXWriteLatencyTrace.shared.dump().contains("trace=0"))
        XCTAssertFalse(AXWriteLatencyTrace.shared.dump().contains("trace=\(staleTraceRequestId)"))
    }

    func testRetryMailboxQueueDelayExcludesPriorAttemptAndRefetchTime() {
        XCTAssertEqual(
            AppAXContext.mailboxQueueDelay(attempt: 1, startedNs: 900, enqueuedAt: 400),
            500
        )
        XCTAssertEqual(
            AppAXContext.mailboxQueueDelay(attempt: 2, startedNs: 9_000, enqueuedAt: 400),
            0
        )
    }

    @MainActor
    func testTerminalRefusalCarriesAcceptedRetryLineage() throws {
        FrameEffectTraceContext.beginCapture(generation: 105)
        defer { FrameEffectTraceContext.endCapture() }

        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 704_001
        let windowId = 704_101
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let target = CGRect(x: 20, y: 30, width: 640, height: 480)
        let observed = CGRect(x: 20, y: 30, width: 600, height: 440)
        let failure = AXFrameWriteFailureReason.sizeWriteFailed(.attributeUnsupported)
        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: false,
                terminalObserver: nil,
                traceOrigin: FrameEffectTraceContext.originForSubmission()
            ).request
        )
        _ = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: firstRequest,
                observed: observed,
                failure: failure
            )
        ])
        let retryRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: window,
                frame: target,
                isRetry: true,
                terminalObserver: nil,
                parentTraceRequestId: firstRequest.traceRequestId
            ).request
        )
        let outcome = ledger.handleFrameApplyResults([
            WindowAdmissionTestSupport.frameResult(
                request: retryRequest,
                observed: observed,
                failure: failure
            )
        ])
        let refusal = try XCTUnwrap(outcome.terminalRefusals.first)

        XCTAssertEqual(refusal.requestId, retryRequest.requestId)
        XCTAssertEqual(refusal.traceRequestId, retryRequest.traceRequestId)
        XCTAssertNotEqual(refusal.traceRequestId, 0)
    }

    @MainActor
    func testOrdinaryPendingCoalescenceRelatesExistingTraceAndKeepsResultLineage() throws {
        let captureGeneration: UInt64 = 103
        FrameApplyTrace.shared.beginCapture()
        FrameEffectTraceContext.beginCapture(generation: captureGeneration)
        defer {
            FrameEffectTraceContext.endCapture()
            FrameApplyTrace.shared.endCapture()
        }

        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 702_001
        let windowId = 702_101
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                frame: frame,
                isRetry: false,
                terminalObserver: nil,
                traceOrigin: FrameEffectTraceContext.originForSubmission()
            ).request
        )
        let coalesced = ledger.prepareFrameApplication(
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: nil,
            traceOrigin: FrameEffectTraceContext.originForSubmission()
        )

        XCTAssertNil(coalesced.request)
        let coalescedLine = try XCTUnwrap(
            FrameApplyTrace.shared.dump().split(separator: "\n").first {
                $0.contains("event=ledger-coalesced/pending")
            }
        )
        XCTAssertTrue(coalescedLine.contains("related=\(firstRequest.traceRequestId)"))
        XCTAssertFalse(coalescedLine.contains("terminal"))

        let result = AXFrameApplyResult(
            requestId: firstRequest.requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            ),
            traceRequestId: firstRequest.traceRequestId
        )
        FrameApplyTrace.recordResult(result)
        _ = ledger.handleFrameApplyResults([result])

        let resultLine = try XCTUnwrap(
            FrameApplyTrace.shared.dump().split(separator: "\n").first {
                $0.contains("event=outcome=confirmed")
            }
        )
        XCTAssertTrue(resultLine.contains("trace=\(firstRequest.traceRequestId)"))
    }

    @MainActor
    func testParkPendingCoalescenceTracksRetryAndSupersessionLineage() throws {
        let captureGeneration: UInt64 = 104
        FrameApplyTrace.shared.beginCapture()
        FrameEffectTraceContext.beginCapture(generation: captureGeneration)
        let manager = AXManager()
        defer {
            manager.cleanup()
            FrameEffectTraceContext.endCapture()
            FrameApplyTrace.shared.endCapture()
        }

        let pid: pid_t = 703_001
        let windowId = 703_101
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let frame = CGRect(x: 2_559, y: 16, width: 800, height: 600)
        let target = AXFrameApplicationTarget(pid: pid, window: expectedWindow, frame: frame)
        let firstRequest = try XCTUnwrap(manager.prepareParkFrameApplications([target]).first)

        XCTAssertTrue(manager.prepareParkFrameApplications([target]).isEmpty)
        var lines = FrameApplyTrace.shared.dump().split(separator: "\n")
        let firstCoalesced = try XCTUnwrap(lines.first { $0.contains("event=park-ledger-coalesced/pending") })
        XCTAssertTrue(firstCoalesced.contains("related=\(firstRequest.traceRequestId)"))
        XCTAssertFalse(firstCoalesced.contains("terminal"))

        let failedResult = AXFrameApplyResult(
            requestId: firstRequest.requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: frame.offsetBy(dx: -1, dy: 0),
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            ),
            traceRequestId: firstRequest.traceRequestId
        )
        let retryRequest = try XCTUnwrap(manager.processParkFrameApplyResults([failedResult]).first)
        XCTAssertTrue(manager.prepareParkFrameApplications([target]).isEmpty)

        let replacementTarget = AXFrameApplicationTarget(
            pid: pid,
            window: expectedWindow,
            frame: frame.offsetBy(dx: -20, dy: 0)
        )
        let replacementRequest = try XCTUnwrap(
            manager.prepareParkFrameApplications([replacementTarget]).first
        )
        lines = FrameApplyTrace.shared.dump().split(separator: "\n")
        let retryCoalesced = try XCTUnwrap(
            lines.last { $0.contains("event=park-ledger-coalesced/pending") }
        )
        let superseded = try XCTUnwrap(
            lines.first { $0.contains("event=outcome=ax-park-cancelled/superseded") }
        )
        XCTAssertTrue(retryCoalesced.contains("related=\(retryRequest.traceRequestId)"))
        XCTAssertTrue(superseded.contains("trace=\(retryRequest.traceRequestId)"))
        XCTAssertTrue(superseded.contains("related=\(replacementRequest.traceRequestId)"))
        XCTAssertTrue(
            lines.contains {
                $0.contains("event=outcome=ax-park-failed/verificationMismatch")
                    && $0.contains("trace=\(firstRequest.traceRequestId)")
            }
        )
    }

    @MainActor
    func testFrameObservationStaleScheduleHandsOffWithoutSamplingReplacement() throws {
        let tracker = FrameEffectObservationTracker(timeoutNs: 1_000, maxMismatchCount: 2)
        let captureGeneration: UInt64 = 91
        let firstTraceId = captureGeneration << 32 | 1
        let replacementTraceId = captureGeneration << 32 | 2
        let firstTarget = CGRect(x: 10, y: 20, width: 300, height: 200)
        let replacementTarget = CGRect(x: 40, y: 50, width: 600, height: 400)
        tracker.beginCapture(generation: captureGeneration, startTimeoutTask: false)
        defer { tracker.endCapture() }

        tracker.register(
            traceRequestId: firstTraceId,
            requestId: 1,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: firstTarget,
            startedNs: 10
        )
        let staleToken = try XCTUnwrap(tracker.noteFrameChanged(windowId: 42, eventNs: 20))
        tracker.register(
            traceRequestId: replacementTraceId,
            requestId: 2,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: replacementTarget,
            startedNs: 30
        )
        XCTAssertNil(tracker.noteFrameChanged(windowId: 42, eventNs: 40))

        guard case let .reschedule(replacementToken) = tracker.prepareObservation(
            windowId: 42,
            token: staleToken
        ) else {
            return XCTFail("stale task must hand off without sampling")
        }
        XCTAssertEqual(tracker.pendingCount, 1)
        XCTAssertEqual(
            tracker.prepareObservation(windowId: 42, token: replacementToken),
            .sample
        )
        XCTAssertNil(
            tracker.completeObservation(
                windowId: 42,
                token: replacementToken,
                observed: replacementTarget,
                sampledNs: 50
            )
        )
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    @MainActor
    func testFrameObservationEndCaptureReleasesDictionaryStorage() {
        let tracker = FrameEffectObservationTracker(timeoutNs: 1_000, maxMismatchCount: 2)
        let captureGeneration: UInt64 = 96
        let traceRequestId = captureGeneration << 32 | 1

        tracker.beginCapture(generation: captureGeneration, startTimeoutTask: false)
        tracker.register(
            traceRequestId: traceRequestId,
            requestId: 1,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: CGRect(x: 10, y: 20, width: 300, height: 200),
            startedNs: 10
        )
        XCTAssertNotNil(tracker.noteFrameChanged(windowId: 42, eventNs: 20))
        XCTAssertNil(tracker.noteFrameChanged(windowId: 42, eventNs: 30))
        XCTAssertGreaterThanOrEqual(tracker.retainedStorageCapacity, 3)

        tracker.endCapture()

        XCTAssertEqual(tracker.pendingCount, 0)
        XCTAssertEqual(tracker.retainedStorageCapacity, 0)
    }

    @MainActor
    func testFrameObservationCaptureRestartDiscardsPriorScheduledToken() throws {
        let tracker = FrameEffectObservationTracker(timeoutNs: 1_000, maxMismatchCount: 2)
        let firstGeneration: UInt64 = 93
        let secondGeneration: UInt64 = 94
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let firstTraceRequestId = firstGeneration << 32 | 1
        let secondTraceRequestId = secondGeneration << 32 | 1

        tracker.beginCapture(generation: firstGeneration, startTimeoutTask: false)
        tracker.register(
            traceRequestId: firstTraceRequestId,
            requestId: 1,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: target,
            startedNs: 10
        )
        let priorToken = try XCTUnwrap(tracker.noteFrameChanged(windowId: 42, eventNs: 20))
        tracker.endCapture()

        tracker.beginCapture(generation: secondGeneration, startTimeoutTask: false)
        defer { tracker.endCapture() }
        tracker.register(
            traceRequestId: secondTraceRequestId,
            requestId: 2,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: target,
            startedNs: 30
        )
        let currentToken = try XCTUnwrap(tracker.noteFrameChanged(windowId: 42, eventNs: 40))

        XCTAssertEqual(tracker.prepareObservation(windowId: 42, token: priorToken), .none)
        XCTAssertEqual(tracker.prepareObservation(windowId: 42, token: currentToken), .sample)
    }

    @MainActor
    func testCancelledOrdinaryRetryRetiresServerObservation() {
        let captureGeneration: UInt64 = 95
        let manager = AXManager()
        let pid: pid_t = 705_001
        let windowId = 705_101
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )

        FrameApplyTrace.shared.beginCapture()
        FrameEffectTraceContext.beginCapture(generation: captureGeneration)
        FrameEffectObservationTracker.shared.beginCapture(
            generation: captureGeneration,
            startTimeoutTask: false
        )
        defer {
            manager.cleanup()
            FrameEffectObservationTracker.shared.endCapture()
            FrameEffectTraceContext.endCapture()
            FrameApplyTrace.shared.endCapture()
        }

        let traceRequestId = FrameEffectTraceContext.makeRequestTraceId()
        FrameEffectObservationTracker.shared.register(
            traceRequestId: traceRequestId,
            requestId: 1,
            pid: pid,
            windowId: windowId,
            lane: .ordinary,
            attempt: 1,
            target: target,
            startedNs: 10
        )
        manager.scheduleFrameRetry(
            AXFrameRetryRequest(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                frame: target,
                currentFrameHint: target.offsetBy(dx: -1, dy: 0),
                traceRequestId: traceRequestId
            )
        )

        manager.cancelPendingFrameJobs([(pid: pid, windowId: windowId)])

        XCTAssertEqual(FrameEffectObservationTracker.shared.pendingCount, 0)
        let trace = FrameApplyTrace.shared.dump()
        XCTAssertTrue(trace.contains("event=outcome=skip/cancelled"))
        XCTAssertTrue(trace.contains("event=server-observation/write-terminal/terminal"))
        XCTAssertFalse(trace.contains("server-observation/timeout"))
    }

    @MainActor
    func testFrameObservationStopsWhenAXValuesCannotBeCreated() {
        let tracker = FrameEffectObservationTracker(timeoutNs: 1_000, maxMismatchCount: 2)
        let captureGeneration: UInt64 = 92
        let traceRequestId = captureGeneration << 32 | 1
        let target = CGRect(x: 10, y: 20, width: 300, height: 200)
        tracker.beginCapture(generation: captureGeneration, startTimeoutTask: false)
        defer { tracker.endCapture() }
        tracker.register(
            traceRequestId: traceRequestId,
            requestId: 1,
            pid: 7,
            windowId: 42,
            lane: .ordinary,
            attempt: 1,
            target: target,
            startedNs: 10
        )

        tracker.noteWriteResult(
            AXFrameApplyResult(
                requestId: 1,
                pid: 7,
                windowId: 42,
                expectedWindow: AXWindowRef(
                    element: AXUIElementCreateApplication(7),
                    windowId: 42
                ),
                targetFrame: target,
                currentFrameHint: nil,
                writeResult: .skipped(
                    targetFrame: target,
                    currentFrameHint: nil,
                    failureReason: .valueCreationFailed
                ),
                traceRequestId: traceRequestId
            )
        )

        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testLogErrorTapCapturesOnlyErrorAndFault() {
        LogErrorTap.shared.reset()

        Log.config.error("boom-error")
        Log.terminal.fault("boom-fault")
        Log.layout.debug("boom-debug")
        Log.ax.info("boom-info")
        Log.ipc.notice("boom-notice")

        let dump = LogErrorTap.shared.dump()
        XCTAssertTrue(dump.contains("boom-error"))
        XCTAssertTrue(dump.contains("boom-fault"))
        XCTAssertFalse(dump.contains("boom-debug"))
        XCTAssertFalse(dump.contains("boom-info"))
        XCTAssertFalse(dump.contains("boom-notice"))
        XCTAssertTrue(dump.contains("[error] config"))
        XCTAssertTrue(dump.contains("[fault] terminal"))

        LogErrorTap.shared.reset()
        XCTAssertEqual(LogErrorTap.shared.dump(), "none")
    }

    func testLogErrorTapBoundsIndividualStrings() {
        LogErrorTap.shared.reset()
        let oversized = String(repeating: "🪟", count: 2_000)

        LogErrorTap.shared.record(category: oversized, level: oversized, message: oversized)

        let dump = LogErrorTap.shared.dump()
        XCTAssertFalse(dump.contains(oversized))
        XCTAssertLessThanOrEqual(
            dump.utf8.count,
            RuntimeTraceLimits.diagnosticStringBytes * 3 + 128
        )
        LogErrorTap.shared.reset()
    }

    @MainActor
    func testCaptureCoordinatorTogglesDomainRecorders() async {
        AppVisibilityTrace.record(
            .notification,
            pid: 1,
            visibility: .hidden,
            outcome: .observed
        )
        XCTAssertFalse(AppVisibilityTrace.shared.dump().contains("event=notification"))
        RawAXNotificationTrace.record(name: "ax.before", pid: 1, windowId: nil)
        XCTAssertFalse(RawAXNotificationTrace.shared.dump().contains("ax.before"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceRecorder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory)
        let startOutcome = await coordinator.toggle(desiredState: .active) { "report" }
        guard case .started = startOutcome else {
            return XCTFail("expected capture to start")
        }

        RawAXNotificationTrace.record(name: "ax.during", pid: 7, windowId: 42)
        AppVisibilityTrace.record(
            .stateTransition,
            pid: 7,
            visibility: .hidden,
            outcome: .applied,
            intakeSequence: 12,
            worldSequence: 34,
            intentId: 56,
            windowId: 42,
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000042"),
            generation: 3,
            intentGeneration: 2,
            managedWindowCount: 2,
            affectedWorkspaceCount: 2,
            activeWorkspaceCount: 1,
            destination: .window,
            source: .service
        )
        NiriLayoutTrace.record(.viewport, workspaceId: nil, "jump 0→10 col=0")
        AnimationTickTrace.shared.record(
            AnimationTickTrace.Record(
                mediaTime: 1,
                displayId: 1,
                intervalMs: 99,
                expectedMs: 6,
                entrySlackMs: 2.5,
                completionSlackMs: -3.5,
                scrollMs: 5,
                dwindleMs: 0,
                closingMs: 0,
                reconcileMs: 1,
                totalMs: 6,
                classification: DisplayTickClassification(
                    longTimestampGap: true,
                    workExceededNominalPeriod: false,
                    completionPastTarget: true
                )
            )
        )
        BorderOpMetricsRecorder.shared.noteApply()
        ScrollTickTrace.shared.record(
            ScrollTickTrace.Record(
                mediaTime: 2,
                displayId: 1,
                animsMs: 0.1,
                snapshotMs: 0.2,
                buildMs: 0.1,
                commitMs: 290.0,
                totalMs: 290.4,
                show: 1,
                hide: 1,
                frames: 9,
                windowCount: 12,
                isAnimationTick: true
            )
        )
        AXWriteLatencyTrace.shared.record(
            AXWriteLatencyTrace.Record(
                kind: .batch,
                uptimeNs: 2,
                requestTraceId: 0,
                requestId: 0,
                pid: 4242,
                bundleId: "example.test",
                callbackGeneration: 3,
                lane: .ordinary,
                submissionId: 0,
                drainId: 7,
                windowId: 0,
                attempt: 0,
                count: 9,
                queueNs: 0,
                sizeNs: 0,
                positionNs: 0,
                verificationNs: 0,
                enhancedUIProbeNs: 1_000,
                enhancedUIDisableNs: 2_000,
                enhancedUIRestoreNs: 3_000,
                totalNs: 288_000_000,
                enhancedUI: true,
                failureReason: nil
            )
        )
        let appVisibilityDump = AppVisibilityTrace.shared.dump()
        XCTAssertTrue(appVisibilityDump.contains("event=state_transition"))
        XCTAssertTrue(appVisibilityDump.contains("pid=7"))
        XCTAssertTrue(appVisibilityDump.contains("visibility=hidden"))
        XCTAssertTrue(appVisibilityDump.contains("outcome=applied"))
        XCTAssertTrue(appVisibilityDump.contains("intake_seq=12"))
        XCTAssertTrue(appVisibilityDump.contains("world_seq=34"))
        XCTAssertTrue(appVisibilityDump.contains("intent=56"))
        XCTAssertTrue(appVisibilityDump.contains("win=42"))
        XCTAssertTrue(appVisibilityDump.contains("workspace=00000000-0000-0000-0000-000000000042"))
        XCTAssertTrue(appVisibilityDump.contains("generation=3"))
        XCTAssertTrue(appVisibilityDump.contains("intent_generation=2"))
        XCTAssertTrue(appVisibilityDump.contains("managed_windows=2"))
        XCTAssertTrue(appVisibilityDump.contains("affected_workspaces=2"))
        XCTAssertTrue(appVisibilityDump.contains("active_workspaces=1"))
        XCTAssertTrue(appVisibilityDump.contains("destination=window"))
        XCTAssertTrue(appVisibilityDump.contains("source=service"))
        XCTAssertTrue(RawAXNotificationTrace.shared.dump().contains("ax.during"))
        XCTAssertTrue(NiriLayoutTrace.shared.dump().contains("jump 0→10"))
        let tickDump = AnimationTickTrace.shared.dump()
        XCTAssertTrue(tickDump.contains("entry_slack=2.50ms completion_slack=-3.50ms"))
        XCTAssertTrue(tickDump.hasSuffix(" LONG_GAP COMPLETION_PAST_TARGET"))
        XCTAssertFalse(tickDump.contains("WORK_OVER_PERIOD"))
        XCTAssertTrue(BorderOpMetricsRecorder.shared.dump().contains("applyCalls=1"))
        XCTAssertTrue(ScrollTickTrace.shared.dump().contains("commit=290.00ms"))
        XCTAssertTrue(AXWriteLatencyTrace.shared.dump().contains("pid=4242"))

        let outcome = await coordinator.toggle(desiredState: .inactive) { "report" }
        guard case let .stopped(artifact) = outcome else {
            return XCTFail("expected capture to stop with an artifact")
        }
        let body = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("== macOS App Visibility Trace =="))
        XCTAssertTrue(body.contains("event=state_transition"))
        XCTAssertTrue(body.contains("== Raw AX Notifications =="))
        XCTAssertTrue(body.contains("== Niri Layout Trace =="))
        XCTAssertTrue(body.contains("== Frame Apply Trace =="))
        XCTAssertTrue(body.contains("== Animation Tick Timing =="))
        XCTAssertTrue(body.contains("== Scroll Tick Breakdown =="))
        XCTAssertTrue(body.contains("== AX Write Latency =="))
        XCTAssertTrue(body.contains("== Overview Frame Timing =="))
        XCTAssertTrue(body.contains("== Border Op Metrics =="))
        XCTAssertTrue(body.contains("== Mouse Trace =="))
        try? FileManager.default.removeItem(at: artifact.url)

        AppVisibilityTrace.record(
            .notification,
            pid: 1,
            visibility: .visible,
            outcome: .observed
        )
        XCTAssertFalse(AppVisibilityTrace.shared.dump().contains("event=notification"))
        RawAXNotificationTrace.record(name: "ax.after", pid: 1, windowId: nil)
        XCTAssertFalse(RawAXNotificationTrace.shared.dump().contains("ax.after"))
    }

    @MainActor
    func testFinalizationFreezesRecorderBeforeAwaitingEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceFinalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Test Records", capacity: 4) { $0 }
        let diagnosticsEventRecorder = DiagnosticsEventRecorder()
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder],
            diagnosticsEventRecorder: diagnosticsEventRecorder
        )
        let gate = DiagnosticsEvidenceGate()
        defer { gate.release() }
        let evidenceStarted = expectation(description: "automatic evidence started")

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: { "start report" },
            automaticEvidenceProvider: {
                evidenceStarted.fulfill()
                await gate.wait()
                return "status=timed_out"
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        recorder.record("before stop")
        diagnosticsEventRecorder.recordVerbose(name: "verbose-before-stop")

        let stopTask = Task { @MainActor in
            await coordinator.toggle(desiredState: .inactive, reportProvider: { "end report" })
        }
        await fulfillment(of: [evidenceStarted], timeout: 2)

        XCTAssertEqual(coordinator.status.phase, .finalizing)
        XCTAssertFalse(recorder.isActive)
        XCTAssertTrue(diagnosticsEventRecorder.isVerboseStoragePrepared)
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseSpareStoragePrepared)
        recorder.record("after stop")
        diagnosticsEventRecorder.recordVerbose(name: "verbose-after-stop")
        gate.release()

        guard case let .stopped(artifact) = await stopTask.value else {
            return XCTFail("expected final artifact")
        }
        let body = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(body.contains("before stop"))
        XCTAssertFalse(body.contains("after stop"))
        XCTAssertTrue(body.contains("verbose-before-stop"))
        XCTAssertFalse(body.contains("verbose-after-stop"))
        XCTAssertTrue(body.contains("== Automatic AX Evidence ==\nstatus=timed_out"))
        XCTAssertFalse(diagnosticsEventRecorder.isVerboseStoragePrepared)
        XCTAssertEqual(coordinator.status.phase, .idle)
    }

    @MainActor
    func testFinalTraceIsByteBoundedAndPreservesReservedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTraceBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionTraceRecorder<String>(sectionTitle: "Large Records", capacity: 8_000) { $0 }
        let coordinator = RuntimeTraceCaptureCoordinator(
            diagnosticsDirectory: directory,
            recorders: [recorder]
        )
        var reportCount = 0

        guard case .started = await coordinator.toggle(
            desiredState: .active,
            reportProvider: {
                reportCount += 1
                return reportCount == 1
                    ? "start-sentinel\n" + String(repeating: "s", count: 2 * 1024 * 1024)
                    : "end-sentinel\n" + String(repeating: "e", count: 2 * 1024 * 1024)
            },
            automaticEvidenceProvider: {
                "automatic-sentinel\n" + String(repeating: "a", count: 1024 * 1024)
            }
        ) else {
            return XCTFail("expected capture to start")
        }
        for index in 0 ..< 8_000 {
            recorder.record("record-\(index)-" + String(repeating: "x", count: 4_096))
        }

        guard case let .stopped(artifact) = await coordinator.toggle(
            desiredState: .inactive,
            reportProvider: { "unused" }
        ) else {
            return XCTFail("expected capture artifact")
        }
        let data = try Data(contentsOf: artifact.url)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertLessThanOrEqual(data.count, RuntimeTraceLimits.captureBytes)
        XCTAssertEqual(body.components(separatedBy: "== Trace Data Truncated ==").count - 1, 1)
        XCTAssertTrue(body.contains("start-sentinel"))
        XCTAssertTrue(body.contains("automatic-sentinel"))
        XCTAssertTrue(body.contains("end-sentinel"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".omniwm-trace-") && $0.hasSuffix(".tmp") }
        )
    }

    func testBorderOpMetricsRecorderGatingAndReset() {
        let recorder = BorderOpMetricsRecorder()

        recorder.noteApply()
        XCTAssertEqual(recorder.dump(), "none", "counters ignored while inactive")

        recorder.beginCapture()
        recorder.noteApply()
        recorder.noteUpdate()
        recorder.noteWindowCreation()
        recorder.noteLevelQuery()
        recorder.noteLevelFallback()
        recorder.noteLevelRetry()
        recorder.noteScaleReconfiguration()
        recorder.noteMoveOnly()
        recorder.noteMoveOnly()
        recorder.noteCornerRadiusQuery()
        recorder.noteRedraw(rasterizedArea: 123.4)
        recorder.noteFlush()
        let dump = recorder.dump()
        XCTAssertTrue(dump.contains("applyCalls=1"))
        XCTAssertTrue(dump.contains("updateCalls=1"))
        XCTAssertTrue(dump.contains("windowCreations=1"))
        XCTAssertTrue(dump.contains("levelQueries=1"))
        XCTAssertTrue(dump.contains("levelFallbacks=1"))
        XCTAssertTrue(dump.contains("levelRetries=1"))
        XCTAssertTrue(dump.contains("scaleReconfigurations=1"))
        XCTAssertTrue(dump.contains("moveOnly=2"))
        XCTAssertTrue(dump.contains("queries=1"))
        XCTAssertTrue(dump.contains("redraws=1 flushes=1"))
        XCTAssertTrue(dump.contains("rasterizedPointArea=124"))

        recorder.endCapture()
        recorder.noteApply()
        XCTAssertTrue(recorder.dump().contains("applyCalls=1"), "counters frozen after capture ends")

        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none", "beginCapture resets counters")
    }

    func testLayoutBuildMetricsSeparatesRoutes() {
        var metrics = LayoutBuildMetrics()
        metrics.recordBuild(seconds: 0.001, route: .relayout, workspaceCount: 1, windowCount: 12)
        metrics.recordBuild(seconds: 0.002, route: .scrollTick, workspaceCount: 1, windowCount: 12)

        let dump = metrics.dump()
        XCTAssertTrue(dump.contains("builds=2"))
        XCTAssertTrue(dump.contains("route=relayout ws=1 win=11-20"))
        XCTAssertTrue(dump.contains("route=scrollTick ws=1 win=11-20"))
    }
}
