// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AsyncRetryRaiseTests: XCTestCase {
    func testRetirementAndLifecycleInvalidateQueuedRetry() throws {
        for transition in 0 ..< 7 {
            let ledger = IntentLedger()
            let token = WindowToken(pid: 831_001, windowId: 831_101)
            let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
            ledger.enableDeferredRetryRaise(for: request)
            let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
            switch transition {
            case 0: _ = ledger.confirm(id: request.requestId)
            case 1: _ = ledger.cancel(id: request.requestId)
            case 2: _ = ledger.markExpired(id: request.requestId)
            case 3: _ = ledger.supersede(id: request.requestId)
            case 4: ledger.reset()
            case 5: ledger.discardPendingFocus(token)
            default:
                _ = ledger.beginManagedRequest(
                    token: WindowToken(pid: token.pid, windowId: token.windowId + 1), workspaceId: request.workspaceId
                )
            }
            XCTAssertTrue(job.isCancelled, "transition=\(transition)")
            XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        }
    }

    func testSurvivingRequestGetsFreshDeadlineWhenQueuedRetryIsInvalidated() throws {
        for transition in 0 ..< 3 {
            let ledger = IntentLedger()
            let wheel = DeadlineWheel()
            ledger.deadlineWheel = wheel
            defer { wheel.stop() }
            let token = WindowToken(pid: 831_002, windowId: 831_102)
            let request = ledger.beginManagedRequest(token: token, workspaceId: .init())
            let consumed = wheel.schedule(intentId: request.requestId, after: .seconds(10))
            XCTAssertTrue(wheel.consumeExpiration(intentId: request.requestId, generation: consumed))
            ledger.enableDeferredRetryRaise(for: request)
            let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
            switch transition {
            case 0:
                _ = ledger.beginManagedRequest(token: token, workspaceId: request.workspaceId)
            case 1:
                _ = ledger.retargetManagedRequest(requestId: request.requestId, token: token, to: .init())
            default:
                ledger.rekey(from: token, to: WindowToken(pid: token.pid, windowId: token.windowId + 1))
            }
            XCTAssertTrue(job.isCancelled)
            XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
            XCTAssertNotNil(ledger.activeManagedRequest(requestId: request.requestId))
            XCTAssertTrue(wheel.consumeExpiration(intentId: request.requestId, generation: consumed + 1))
        }
    }

    func testContextCancellationCompletesLiveRequestOnlyOnce() throws {
        let ledger = IntentLedger()
        let request = ledger.beginManagedRequest(
            token: WindowToken(pid: 831_003, windowId: 831_103), workspaceId: .init()
        )
        ledger.enableDeferredRetryRaise(for: request)
        let job = try XCTUnwrap(ledger.beginDeferredRetryRaise(for: request))
        XCTAssertNil(ledger.beginDeferredRetryRaise(for: request))
        job.cancel()
        XCTAssertEqual(ledger.completeDeferredRetryRaise(job: job), request)
        XCTAssertNil(ledger.completeDeferredRetryRaise(job: job))
        XCTAssertNotNil(ledger.beginDeferredRetryRaise(for: request))
    }

    func testWorkerRejectsCancelledSuppressedMissingAndReplacedWindows() {
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_004), windowId: 831_104)
        $appThreadToken.withValue(AppThreadToken(pid: 831_004)) {
            for condition in 0 ..< 6 {
                let windows = ThreadGuardedValue([window.windowId: window.element])
                defer { windows.destroy() }
                let suppression = LockedWindowIdSet()
                let job = RunLoopJob()
                switch condition {
                case 0: job.cancel()
                case 1: suppression.insert(window.windowId)
                case 2: suppression.setHardSuppressed(true)
                case 3: windows[window.windowId] = nil
                case 4: windows[window.windowId] = AXUIElementCreateApplication(831_005)
                default: break
                }
                var raises = 0
                let result = AppAXContext.performRetryRaise(
                    window, windows: windows, suppression: suppression, job: job,
                    raiseWindow: { _ in raises += 1
                        return true
                    }
                )
                XCTAssertEqual(result, condition == 5)
                XCTAssertEqual(raises, condition == 5 ? 1 : 0)
            }
        }
    }

    func testCancellingAnExecutingWorkerRaiseDoesNotWaitForTheRaise() throws {
        let job = RunLoopJob()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let window = AXWindowRef(element: AXUIElementCreateApplication(831_006), windowId: 831_106)
        Thread.detachNewThread {
            $appThreadToken.withValue(AppThreadToken(pid: 831_006)) {
                let windows = ThreadGuardedValue([window.windowId: window.element])
                defer { windows.destroy()
                    finished.signal()
                }
                _ = AppAXContext.performRetryRaise(
                    window, windows: windows, suppression: LockedWindowIdSet(), job: job,
                    raiseWindow: { _ in
                        entered.signal()
                        _ = release.wait(timeout: .now() + 3)
                        return true
                    }
                )
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let start = ContinuousClock.now
        job.cancel()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(job.isCancelled)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
    }
}
