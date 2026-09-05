// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class FocusWithoutRaiseTests: XCTestCase {
    private enum FocusOperation: Equatable {
        case activate(pid_t)
        case focus(WindowToken)
        case deactivate(WindowToken)
        case activateSameApp(WindowToken)
        case raise
        case order(UInt32)
    }

    private final class FocusRecorder {
        var operations: [FocusOperation] = []
        var deactivateSucceeds = true
        var activateSameAppSucceeds = true
        var onActivateSameApp: ((WindowToken) -> Void)?
        var queuedRaises: [(job: RunLoopJob, completion: @MainActor @Sendable () -> Void)] = []
        var workerAvailable = true
    }

    func testSameAppHandoffUsesDedicatedPhaseAndDoesNotConsumeRetryBudget() throws {
        let ledger = IntentLedger()
        let workspaceId = WorkspaceDescriptor.ID()
        let sourceToken = WindowToken(pid: 820_001, windowId: 820_101)
        let targetToken = WindowToken(pid: sourceToken.pid, windowId: 820_102)
        let initial = ledger.beginManagedRequest(
            token: targetToken,
            workspaceId: workspaceId,
            origin: .focusFollowsMouse
        )
        ledger.beginManagedFocusRetryRuntimeCapture()

        let staged = try XCTUnwrap(ledger.beginSameAppActivationHandoff(
            requestId: initial.requestId,
            sourceToken: sourceToken
        ))

        XCTAssertEqual(
            staged.phase,
            .awaitingSameAppActivation(sourceToken: sourceToken)
        )
        XCTAssertEqual(staged.retryCount, 0)
        XCTAssertEqual(IntentLedger.sameAppActivationHandoffDeadline, .milliseconds(40))
        XCTAssertEqual(IntentLedger.activationSettleDeadline, .milliseconds(100))
        XCTAssertNil(ledger.recordRetry(
            requestId: staged.requestId,
            source: .focusedWindowChanged,
            retryLimit: 5
        ))

        let completed = try XCTUnwrap(ledger.completeSameAppActivationHandoff(
            requestId: staged.requestId
        ))
        ledger.endManagedFocusRetryRuntimeCapture()

        XCTAssertEqual(completed.phase, .awaitingConfirmation)
        XCTAssertEqual(completed.retryCount, 0)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().attempts, 0)
        XCTAssertEqual(ledger.managedFocusRetryRuntimeSnapshot().deadlineRearms, 0)
    }

    func testStrongerOriginPromotesSameAppHandoffToConfirmationPhase() throws {
        let origins: [ManagedFocusOrigin] = [.pointerHover, .keyboardOrProgrammatic]

        for origin in origins {
            let ledger = IntentLedger()
            let workspaceId = WorkspaceDescriptor.ID()
            let sourceToken = WindowToken(pid: 820_002, windowId: 820_201)
            let targetToken = WindowToken(pid: sourceToken.pid, windowId: 820_202)
            let initial = ledger.beginManagedRequest(
                token: targetToken,
                workspaceId: workspaceId,
                origin: .focusFollowsMouse
            )
            _ = try XCTUnwrap(ledger.beginSameAppActivationHandoff(
                requestId: initial.requestId,
                sourceToken: sourceToken
            ))

            let promoted = ledger.beginManagedRequest(
                token: targetToken,
                workspaceId: workspaceId,
                origin: origin
            )

            XCTAssertEqual(promoted.requestId, initial.requestId)
            XCTAssertEqual(promoted.origin, origin)
            XCTAssertEqual(promoted.phase, .awaitingConfirmation)
        }
    }

    func testSameAppHandoffSourceRekeyPreservesSamePIDAndCancelsCrossPID() throws {
        let workspaceId = WorkspaceDescriptor.ID()
        let source = WindowToken(pid: 820_002, windowId: 820_231)
        let target = WindowToken(pid: source.pid, windowId: 820_232)
        let samePIDSource = WindowToken(pid: source.pid, windowId: 820_233)
        let samePIDLedger = IntentLedger()
        let samePIDRequest = samePIDLedger.beginManagedRequest(
            token: target,
            workspaceId: workspaceId,
            origin: .focusFollowsMouse
        )
        _ = try XCTUnwrap(samePIDLedger.beginSameAppActivationHandoff(
            requestId: samePIDRequest.requestId,
            sourceToken: source
        ))

        samePIDLedger.rekeyManagedRequest(from: source, to: samePIDSource)

        XCTAssertEqual(samePIDLedger.activeManagedRequest?.requestId, samePIDRequest.requestId)
        XCTAssertEqual(samePIDLedger.activeManagedRequest?.token, target)
        XCTAssertEqual(
            samePIDLedger.activeManagedRequest?.phase,
            .awaitingSameAppActivation(sourceToken: samePIDSource)
        )

        let crossPIDLedger = IntentLedger()
        let deadlineWheel = DeadlineWheel()
        crossPIDLedger.deadlineWheel = deadlineWheel
        let crossPIDRequest = crossPIDLedger.beginManagedRequest(
            token: target,
            workspaceId: workspaceId,
            origin: .focusFollowsMouse
        )
        _ = try XCTUnwrap(crossPIDLedger.beginSameAppActivationHandoff(
            requestId: crossPIDRequest.requestId,
            sourceToken: source
        ))
        let deadlineGeneration = deadlineWheel.schedule(
            intentId: crossPIDRequest.requestId,
            after: .seconds(10)
        )

        crossPIDLedger.rekeyManagedRequest(
            from: source,
            to: WindowToken(pid: source.pid + 1, windowId: source.windowId)
        )

        XCTAssertNil(crossPIDLedger.activeManagedRequest)
        XCTAssertEqual(crossPIDLedger.intent(id: crossPIDRequest.requestId)?.phase, .cancelled)
        XCTAssertFalse(deadlineWheel.consumeExpiration(
            intentId: crossPIDRequest.requestId,
            generation: deadlineGeneration
        ))
    }

    func testStrongerRequestPromotesSameAppHandoffToImmediateFronting() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_002,
            windowId: 820_211,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_212,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

        fixture.controller.focusWindow(target, origin: .pointerHover)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activate(target.pid), .focus(target), .raise]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
    }

    func testDifferentTargetSupersedesHandoffWithoutSourceRestoreAndIgnoresLateSourceEcho() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_002,
            windowId: 820_241,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let firstTarget = addWindow(
            pid: source.pid,
            windowId: 820_242,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let replacementTarget = addWindow(
            pid: source.pid,
            windowId: 820_243,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let sourceEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: source))
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(firstTarget, origin: .focusFollowsMouse)
        let supersededRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )

        fixture.controller.focusWindow(replacementTarget, origin: .focusFollowsMouse)

        let replacementRequest = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNotEqual(replacementRequest.requestId, supersededRequestId)
        XCTAssertEqual(replacementRequest.token, replacementTarget)
        XCTAssertEqual(
            replacementRequest.phase,
            .awaitingSameAppActivation(sourceToken: source)
        )
        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .deactivate(source)]
        )
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: supersededRequestId)?.phase, .cancelled)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, replacementTarget)

        fixture.controller.hasStartedServices = true
        fixture.controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: source.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: sourceEntry.axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )
        fixture.controller.hasStartedServices = false

        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest, replacementRequest)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, replacementTarget)
        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .deactivate(source)]
        )
    }

    func testNewFocusFollowsMouseTargetUsesAttemptedCrossAppTargetAsHandoffSource() throws {
        let fixture = try makeFixture()
        let staleWorldFocus = addWindow(
            pid: 820_002,
            windowId: 820_251,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let attemptedTarget = addWindow(
            pid: 820_003,
            windowId: 820_252,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let replacementTarget = addWindow(
            pid: attemptedTarget.pid,
            windowId: 820_253,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(staleWorldFocus, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(attemptedTarget, origin: .focusFollowsMouse)

        XCTAssertEqual(fixture.recorder.operations, [.focus(attemptedTarget)])
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingConfirmation
        )
        XCTAssertEqual(fixture.controller.workspaceManager.renderableFocusToken, staleWorldFocus)

        fixture.controller.focusWindow(replacementTarget, origin: .focusFollowsMouse)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.focus(attemptedTarget), .deactivate(attemptedTarget)]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, replacementTarget)
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingSameAppActivation(sourceToken: attemptedTarget)
        )
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, replacementTarget)
    }

    func testNewFocusFollowsMouseTargetPrefersAttemptedTargetOverStaleSameAppWorldFocus() throws {
        let fixture = try makeFixture()
        let staleWorldFocus = addWindow(
            pid: 820_004,
            windowId: 820_254,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let attemptedTarget = addWindow(
            pid: staleWorldFocus.pid,
            windowId: 820_255,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let replacementTarget = addWindow(
            pid: staleWorldFocus.pid,
            windowId: 820_256,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(staleWorldFocus, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(attemptedTarget, origin: .focusFollowsMouse)
        let attemptedRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )
        fixture.controller.axEventHandler.handleIntentExpired(attemptedRequestId)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(staleWorldFocus), .activateSameApp(attemptedTarget)]
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingConfirmation
        )
        XCTAssertEqual(fixture.controller.workspaceManager.renderableFocusToken, staleWorldFocus)

        fixture.controller.focusWindow(replacementTarget, origin: .focusFollowsMouse)

        XCTAssertEqual(
            fixture.recorder.operations,
            [
                .deactivate(staleWorldFocus),
                .activateSameApp(attemptedTarget),
                .deactivate(attemptedTarget)
            ]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, replacementTarget)
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingSameAppActivation(sourceToken: attemptedTarget)
        )
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, replacementTarget)
    }

    func testCrossAppFocusOnlyEmitsOnlySpecificWindowFocus() throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_010,
            windowId: 820_110,
            to: fixture.workspaceId,
            controller: fixture.controller
        )

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

        XCTAssertEqual(fixture.recorder.operations, [.focus(target)])
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .focusFollowsMouse)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
    }

    func testRaiseEnabledFocusFollowsMouseAndNonFFMOriginsRetainFullFronting() throws {
        let cases: [(ManagedFocusOrigin, Bool)] = [
            (.focusFollowsMouse, true),
            (.pointerHover, false),
            (.keyboardOrProgrammatic, false)
        ]

        for (origin, raiseOnMouseFocus) in cases {
            let fixture = try makeFixture(raiseOnMouseFocus: raiseOnMouseFocus)
            let target = addWindow(
                pid: 820_011,
                windowId: 820_111,
                to: fixture.workspaceId,
                controller: fixture.controller
            )

            fixture.controller.focusWindow(target, origin: origin)

            XCTAssertEqual(
                fixture.recorder.operations,
                [.activate(target.pid), .focus(target), .raise],
                "origin=\(origin), raiseOnMouseFocus=\(raiseOnMouseFocus)"
            )
        }
    }

    func testRaiseEnabledSameAppFocusFollowsMouseSkipsHandoffAndFrontsImmediately() throws {
        let fixture = try makeFixture(raiseOnMouseFocus: true)
        let source = addWindow(
            pid: 820_011,
            windowId: 820_131,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_132,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.activate(target.pid), .focus(target), .raise]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
    }

    func testDeferredRetryRaisesAfterImmediateFocusAndProbesOnlyAfterWorkerCompletion() throws {
        for sameApp in [false, true] {
            let fixture = try makeFixture()
            let source = addWindow(
                pid: 830_001,
                windowId: 830_101,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            let target = addWindow(
                pid: sameApp ? source.pid : source.pid + 1,
                windowId: 830_102, to: fixture.workspaceId, controller: fixture.controller
            )
            setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
            let request = try XCTUnwrap(fixture.controller.focusWindow(
                target, raisesWindow: false, defersRetryRaise: true
            ))
            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target)])
            XCTAssertTrue(fixture.recorder.queuedRaises.isEmpty)
            fixture.recorder.operations.removeAll()
            var probes = 0
            fixture.controller.hasStartedServices = true
            fixture.controller.factResolver.factProvider = { _ in probes += 1
                return nil
            }

            fixture.controller.axEventHandler.handleIntentExpired(request.requestId)
            fixture.controller.axEventHandler.handleIntentExpired(request.requestId)

            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target)])
            XCTAssertEqual(fixture.recorder.queuedRaises.count, 1)
            XCTAssertEqual(probes, 0)
            XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, source)
            let queued = try XCTUnwrap(fixture.recorder.queuedRaises.first)
            queued.completion()
            queued.completion()
            XCTAssertEqual(probes, 1)
            XCTAssertFalse(fixture.recorder.operations.contains(.raise))
        }
    }

    func testDeferredRetryNativeConfirmationCancelsWorkerWithoutDelayingBorderOwnership() throws {
        let fixture = try makeFixture()
        let target = addWindow(pid: 830_003, windowId: 830_103, to: fixture.workspaceId, controller: fixture.controller)
        let request = try XCTUnwrap(fixture.controller.focusWindow(
            target, raisesWindow: false, defersRetryRaise: true
        ))
        fixture.controller.axEventHandler.handleIntentExpired(request.requestId)
        let queued = try XCTUnwrap(fixture.recorder.queuedRaises.first)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry, isWorkspaceActive: true, appFullscreen: false, activeRequestId: request.requestId
        )
        XCTAssertTrue(queued.job.isCancelled)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, target)
        XCTAssertEqual(fixture.controller.workspaceManager.borderFocusToken, target)
        var probes = 0
        fixture.controller.hasStartedServices = true
        fixture.controller.factResolver.factProvider = { _ in probes += 1
            return nil
        }
        queued.completion()
        XCTAssertEqual(probes, 0)
    }

    func testDeferredRetrySupersededOrReissuedRequestRejectsOldWorkerCompletion() throws {
        for sameWindow in [false, true] {
            let fixture = try makeFixture()
            let target = addWindow(
                pid: 830_004,
                windowId: 830_104,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            let other = addWindow(
                pid: 830_005,
                windowId: 830_105,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            let first = try XCTUnwrap(fixture.controller.focusWindow(
                target, raisesWindow: false, defersRetryRaise: true
            ))
            fixture.controller.axEventHandler.handleIntentExpired(first.requestId)
            let old = try XCTUnwrap(fixture.recorder.queuedRaises.first)
            let current = try XCTUnwrap(fixture.controller.focusWindow(
                sameWindow ? target : other, raisesWindow: false, defersRetryRaise: true
            ))
            XCTAssertTrue(old.job.isCancelled)
            fixture.controller.axEventHandler.handleIntentExpired(current.requestId)
            XCTAssertEqual(fixture.recorder.queuedRaises.count, 2)
            var probes = 0
            fixture.controller.hasStartedServices = true
            fixture.controller.factResolver.factProvider = { _ in probes += 1
                return nil
            }
            old.completion()
            XCTAssertEqual(probes, 0)
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, current.requestId)
            fixture.recorder.queuedRaises[1].completion()
            XCTAssertEqual(probes, 1)
        }
    }

    func testDeferredRetryUnavailableWorkerStillProbesWithoutMainThreadRaise() throws {
        let fixture = try makeFixture()
        fixture.recorder.workerAvailable = false
        let target = addWindow(pid: 830_006, windowId: 830_106, to: fixture.workspaceId, controller: fixture.controller)
        let request = try XCTUnwrap(fixture.controller.focusWindow(
            target, raisesWindow: false, defersRetryRaise: true
        ))
        fixture.recorder.operations.removeAll()
        var probes = 0
        fixture.controller.hasStartedServices = true
        fixture.controller.factResolver.factProvider = { _ in probes += 1
            return nil
        }
        fixture.controller.axEventHandler.handleIntentExpired(request.requestId)
        XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target)])
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertTrue(fixture.recorder.queuedRaises.isEmpty)
    }

    func testSkippingInitialRaisePreservesActivationExactFocusAndFullRetry() throws {
        for sameApp in [false, true] {
            let fixture = try makeFixture()
            let source = addWindow(
                pid: 820_050,
                windowId: 820_150,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            let target = addWindow(
                pid: sameApp ? source.pid : source.pid + 1,
                windowId: 820_151,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
            fixture.recorder.operations.removeAll()

            let request = try XCTUnwrap(fixture.controller.focusWindow(target, raisesWindow: false))

            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target)])
            XCTAssertEqual(request.origin, .keyboardOrProgrammatic)
            XCTAssertEqual(request.phase, .awaitingConfirmation)
            XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, target)
            XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, source)
            XCTAssertEqual(fixture.controller.workspaceManager.borderFocusToken, source)
            fixture.recorder.operations.removeAll()

            fixture.controller.axEventHandler.handleIntentExpired(request.requestId)

            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target), .raise])
        }
    }

    func testSkippingInitialRaiseRetainsNativeConfirmationAndBorderOwnership() throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_052,
            windowId: 820_152,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let request = try XCTUnwrap(fixture.controller.focusWindow(target, raisesWindow: false))
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))
        fixture.recorder.operations.removeAll()

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: request.requestId
        )

        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, target)
        XCTAssertEqual(fixture.controller.workspaceManager.borderFocusToken, target)
        fixture.controller.axEventHandler.handleIntentExpired(request.requestId)
        fixture.controller.retryManagedFocusFronting(request)
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
    }

    func testSkippingInitialRaiseCannotReviveStaleSupersededOrCancelledRetry() throws {
        let fixture = try makeFixture()
        let first = addWindow(
            pid: 820_053,
            windowId: 820_153,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let replacement = addWindow(
            pid: 820_054,
            windowId: 820_154,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let firstRequest = try XCTUnwrap(fixture.controller.focusWindow(first, raisesWindow: false))
        let staleGeneration = fixture.controller.deadlineWheel.schedule(
            intentId: firstRequest.requestId,
            after: .seconds(10)
        )
        _ = fixture.controller.deadlineWheel.schedule(intentId: firstRequest.requestId, after: .seconds(10))
        fixture.recorder.operations.removeAll()

        fixture.controller.axEventHandler.handleIntentExpired(
            firstRequest.requestId,
            deadlineGeneration: staleGeneration
        )

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, firstRequest.requestId)
        let replacementRequest = try XCTUnwrap(fixture.controller.focusWindow(replacement, raisesWindow: false))
        fixture.recorder.operations.removeAll()

        fixture.controller.axEventHandler.handleIntentExpired(firstRequest.requestId)
        fixture.controller.retryManagedFocusFronting(firstRequest)

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, replacementRequest.requestId)
        _ = fixture.controller.cancelManagedFocusRequest(replacementRequest)
        fixture.controller.axEventHandler.handleIntentExpired(replacementRequest.requestId)
        fixture.controller.retryManagedFocusFronting(replacementRequest)
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testRetriedSystemModalConfirmationOrdersUnlessFocusFollowsMouseOmitsExplicitRaise() throws {
        let cases: [(ManagedFocusOrigin, Bool, [FocusOperation])] = [
            (.focusFollowsMouse, false, []),
            (.focusFollowsMouse, true, [.order(820_141)]),
            (.pointerHover, false, [.order(820_142)])
        ]

        for (index, testCase) in cases.enumerated() {
            let (origin, raiseOnMouseFocus, expectedOperations) = testCase
            let fixture = try makeFixture(raiseOnMouseFocus: raiseOnMouseFocus)
            let target = addWindow(
                pid: pid_t(820_040 + index),
                windowId: 820_140 + index,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            fixture.controller.focusWindow(target, origin: origin)
            let requestId = try XCTUnwrap(
                fixture.controller.intentLedger.activeManagedRequest?.requestId
            )
            let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))
            fixture.recorder.operations.removeAll()
            fixture.controller.workspaceManager.setSystemModalFocus(target)
            fixture.controller.axEventHandler.frontmostApplicationPIDProvider = { target.pid }

            fixture.controller.axEventHandler.handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: true,
                appFullscreen: false,
                source: .focusedWindowChanged,
                origin: .retry,
                activeRequestId: requestId
            )

            XCTAssertEqual(
                fixture.recorder.operations,
                expectedOperations,
                "origin=\(origin), raiseOnMouseFocus=\(raiseOnMouseFocus)"
            )
        }
    }

    func testFocusWindowExecutesFromAuthoritativeMergedOrigin() throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_012,
            windowId: 820_112,
            to: fixture.workspaceId,
            controller: fixture.controller
        )

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        fixture.controller.focusWindow(target, origin: .pointerHover)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.focus(target), .activate(target.pid), .focus(target), .raise]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
    }

    func testDisablingFocusFollowsMousePreservesStrongerMergedRequest() throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_012,
            windowId: 820_122,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        fixture.controller.focusWindow(target, origin: .pointerHover)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)

        fixture.controller.setFocusFollowsMouse(false)

        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, requestId)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, target)
    }

    func testSameAppFocusOnlyStagesDeactivationBeforeTargetActivation() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_113,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_114,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(fixture.recorder.operations, [.deactivate(source)])
        XCTAssertEqual(request.phase, .awaitingSameAppActivation(sourceToken: source))
        XCTAssertEqual(request.retryCount, 0)

        fixture.controller.axEventHandler.handleIntentExpired(request.requestId)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(target)]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.retryCount, 0)
    }

    func testSameAppTargetActivationPrecedesConfirmationPhaseAndSettleRearm() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_143,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_144,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        var phaseAtTargetActivation: ManagedFocusRequest.Phase?
        fixture.recorder.onActivateSameApp = { activatedToken in
            guard activatedToken == target else { return }
            phaseAtTargetActivation = fixture.controller.intentLedger.activeManagedRequest?.phase
        }

        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        XCTAssertEqual(
            phaseAtTargetActivation,
            .awaitingSameAppActivation(sourceToken: source)
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingConfirmation
        )
    }

    func testNilFactAfterRetriedSameAppHandoffAdvancesRetryState() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_163,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_164,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingSameAppActivation(sourceToken: source, isRetry: true)
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.retryCount, 0)
        fixture.controller.factResolver.factProvider = { _ in nil }
        fixture.controller.hasStartedServices = true
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        defer {
            fixture.controller.hasStartedServices = false
            fixture.controller.eventIntake.close()
        }

        fixture.controller.axEventHandler.handleIntentExpired(requestId)
        fixture.controller.eventIntake.drainNow()

        XCTAssertEqual(
            fixture.recorder.operations,
            [
                .deactivate(source),
                .activateSameApp(target),
                .deactivate(source),
                .activateSameApp(target)
            ]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.retryCount, 1)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, target)
    }

    func testStaleHandoffDeadlineGenerationCannotRetryPromotedRequest() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_153,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_154,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        let staleGeneration = fixture.controller.deadlineWheel.schedule(
            intentId: requestId,
            after: .seconds(10)
        )
        fixture.controller.focusWindow(target, origin: .pointerHover)
        fixture.recorder.operations.removeAll()

        fixture.controller.axEventHandler.handleIntentExpired(
            requestId,
            deadlineGeneration: staleGeneration
        )

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, requestId)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.retryCount, 0)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, target)
    }

    func testSameAppHandoffReadsRaiseSettingLiveAtActivation() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_133,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_134,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)

        fixture.controller.settings.raiseOnMouseFocus = true
        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activate(target.pid), .activateSameApp(target), .raise]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.phase, .awaitingConfirmation)
    }

    func testIntermediateMissingFocusedWindowPreservesSameAppHandoff() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_013,
            windowId: 820_123,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_124,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        fixture.controller.hasStartedServices = true

        fixture.controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: target.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(fixture.recorder.operations, [.deactivate(source)])
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.phase,
            .awaitingSameAppActivation(sourceToken: source)
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, target)
    }

    func testSameAppDeactivationFailureCancelsBothPendingOwners() throws {
        let fixture = try makeFixture()
        fixture.recorder.deactivateSucceeds = false
        let source = addWindow(
            pid: 820_014,
            windowId: 820_114,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_115,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

        XCTAssertEqual(fixture.recorder.operations, [.deactivate(source)])
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testSameAppActivationFailureAttemptsSourceRollbackAndCancels() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_014,
            windowId: 820_124,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_125,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        fixture.recorder.activateSameAppSucceeds = false

        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(target), .activateSameApp(source)]
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testDisablingFocusFollowsMouseRollsBackSameAppHandoff() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_015,
            windowId: 820_115,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_116,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)

        fixture.controller.setFocusFollowsMouse(false)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
        fixture.controller.axEventHandler.handleIntentExpired(requestId)
        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
    }

    func testServiceStopDuringSameAppHandoffRestoresSourceAndRetiresBothOwners() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_015,
            windowId: 820_125,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_126,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.hasStartedServices = true
        fixture.controller.axEventHandler.frontmostApplicationPIDProvider = { source.pid }
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)

        fixture.controller.serviceLifecycleManager.stop()

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
        XCTAssertFalse(fixture.controller.hasStartedServices)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
        fixture.controller.axEventHandler.handleIntentExpired(requestId)
        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
    }

    func testPointerLeavingPendingTargetRollsBackSameAppHandoff() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_015,
            windowId: 820_135,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_136,
            to: fixture.workspaceId,
            controller: fixture.controller,
            mode: .floating
        )
        let monitor = try XCTUnwrap(fixture.controller.workspaceManager.monitor(for: fixture.workspaceId))
        let targetFrame = CGRect(
            x: monitor.visibleFrame.minX + 40,
            y: monitor.visibleFrame.minY + 40,
            width: 240,
            height: 160
        )
        fixture.controller.workspaceManager.updateFloatingGeometry(frame: targetFrame, for: target)
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()

        fixture.controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            windowIdUnderPointer: target.windowId
        )
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        fixture.controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: monitor.visibleFrame.maxX - 1, y: monitor.visibleFrame.maxY - 1)
        )

        fixture.controller.axEventHandler.handleIntentExpired(requestId)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testRetiringPendingTargetRestoresSourceBeforeRemoval() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_015,
            windowId: 820_145,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_146,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let targetEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))

        fixture.controller.axEventHandler.retireManagedWindow(
            targetEntry,
            reason: .staleIncarnation
        )

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: target))
    }

    func testCrossPIDTargetRekeyRestoresSourceBeforeIdentityCommit() async throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_015,
            windowId: 820_155,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_156,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let targetEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))
        let replacement = WindowToken(pid: 820_016, windowId: target.windowId)
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacement.pid),
            windowId: replacement.windowId
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        var sourceRestoredBeforeRekey = false
        fixture.recorder.onActivateSameApp = { activatedToken in
            guard activatedToken == source else { return }
            sourceRestoredBeforeRekey = fixture.controller.workspaceManager.entry(for: target) != nil
                && fixture.controller.workspaceManager.entry(for: replacement) == nil
        }
        fixture.controller.hasStartedServices = true
        fixture.controller.axEventHandler.frontmostApplicationPIDProvider = { source.pid }
        fixture.controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        fixture.controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }

        guard case .pending = fixture.controller.axEventHandler.rekeyManagedWindowIdentity(
            from: target,
            to: replacement,
            windowId: UInt32(replacement.windowId),
            axRef: replacementRef
        ) else {
            return XCTFail("Expected cross-PID rekey to enter acknowledgement")
        }
        var rebindState = try XCTUnwrap(
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[UInt32(replacement.windowId)]
        )
        rebindState.task?.cancel()
        rebindState.task = nil
        let executionOwner: UInt64 = 820_156
        rebindState.executionPhase = .running(executionOwner)
        fixture.controller.axEventHandler.admissionRetryStateByWindowId[UInt32(replacement.windowId)] = rebindState

        await fixture.controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: AXManagedWindowIdentity(token: target, axRef: targetEntry.axRef),
            to: AXManagedWindowIdentity(token: replacement, axRef: replacementRef),
            windowId: UInt32(replacement.windowId),
            retryGeneration: rebindState.generation,
            executionOwner: executionOwner,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertEqual(
            fixture.recorder.operations,
            [.deactivate(source), .activateSameApp(source)]
        )
        XCTAssertTrue(sourceRestoredBeforeRekey)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: target))
        XCTAssertEqual(fixture.controller.workspaceManager.entry(for: replacement)?.token, replacement)
    }

    func testExternalActivationAbandonsSameAppHandoffWithoutRestoringSource() throws {
        let fixture = try makeFixture()
        let source = addWindow(
            pid: 820_016,
            windowId: 820_116,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        let target = addWindow(
            pid: source.pid,
            windowId: 820_117,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        setFocused(source, in: fixture.workspaceId, controller: fixture.controller)
        fixture.recorder.operations.removeAll()
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        fixture.controller.hasStartedServices = true
        fixture.controller.factResolver.factProvider = { _ in nil }

        fixture.controller.axEventHandler.handleAppActivation(
            pid: 820_017,
            source: .cgsFrontAppChanged,
            origin: .external
        )

        XCTAssertEqual(fixture.recorder.operations, [.deactivate(source)])
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testDisabledFocusFollowsMouseRejectsRequestBeforeFocusOrProbe() async throws {
        let fixture = try makeFixture(focusFollowsMouseEnabled: false)
        let target = addWindow(
            pid: 820_018,
            windowId: 820_118,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        var factRequestCount = 0
        fixture.controller.hasStartedServices = true
        fixture.controller.factResolver.factProvider = { _ in
            factRequestCount += 1
            return nil
        }

        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        await Task.yield()

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertEqual(factRequestCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testDisablingPendingCrossAppFocusCancelsWithoutFactRetryOrDeadlineRearm() async throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_019,
            windowId: 820_119,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        var factRequestCount = 0
        fixture.controller.hasStartedServices = true
        fixture.controller.factResolver.factProvider = { _ in
            factRequestCount += 1
            return nil
        }
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let requestId = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest?.requestId)
        await Task.yield()
        await Task.yield()
        let initialFactRequestCount = factRequestCount
        fixture.recorder.operations.removeAll()

        fixture.controller.setFocusFollowsMouse(false)
        fixture.controller.axEventHandler.handleIntentExpired(requestId)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertEqual(factRequestCount, initialFactRequestCount)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testPendingFocusFollowsMouseRetryReadsRaiseSettingLive() throws {
        let fixture = try makeFixture()
        let target = addWindow(
            pid: 820_020,
            windowId: 820_120,
            to: fixture.workspaceId,
            controller: fixture.controller
        )
        fixture.controller.focusWindow(target, origin: .focusFollowsMouse)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        fixture.recorder.operations.removeAll()

        fixture.controller.settings.raiseOnMouseFocus = true
        fixture.controller.retryManagedFocusFronting(request)
        fixture.controller.settings.raiseOnMouseFocus = false
        fixture.controller.retryManagedFocusFronting(request)

        XCTAssertEqual(
            fixture.recorder.operations,
            [.activate(target.pid), .focus(target), .raise, .focus(target)]
        )
    }

    func testFocusOnlyPreservesHiddenLockAndForeignTransientGates() throws {
        enum Gate {
            case hidden
            case lockScreen
            case foreignTransient
        }

        for gate in [Gate.hidden, .lockScreen, .foreignTransient] {
            let fixture = try makeFixture()
            let target = addWindow(
                pid: 820_021,
                windowId: 820_121,
                to: fixture.workspaceId,
                controller: fixture.controller
            )
            switch gate {
            case .hidden:
                fixture.controller.workspaceManager.setAppHidden(true, pid: target.pid, source: .ax)
            case .lockScreen:
                fixture.controller.isLockScreenActive = true
            case .foreignTransient:
                fixture.controller.focusPolicyEngine.beginLease(
                    owner: .foreignTransientUI,
                    reason: "test",
                    suppressesFocusFollowsMouse: false,
                    duration: nil
                )
            }

            fixture.controller.focusWindow(target, origin: .focusFollowsMouse)

            XCTAssertTrue(fixture.recorder.operations.isEmpty, "gate=\(gate)")
        }
    }

    private func makeFixture(
        focusFollowsMouseEnabled: Bool = true,
        raiseOnMouseFocus: Bool = false
    ) throws -> (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        recorder: FocusRecorder
    ) {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMFocusWithoutRaiseTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append(.activate($0)) },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append(.focus(WindowToken(pid: pid, windowId: Int(windowId))))
                },
                deactivateSameAppWindow: { pid, windowId in
                    recorder.operations.append(.deactivate(WindowToken(pid: pid, windowId: Int(windowId))))
                    return recorder.deactivateSucceeds
                },
                activateAndFocusSameAppWindow: { pid, windowId, _ in
                    let token = WindowToken(pid: pid, windowId: Int(windowId))
                    recorder.operations.append(.activateSameApp(token))
                    recorder.onActivateSameApp?(token)
                    return recorder.activateSameAppSucceeds
                },
                raiseWindow: { _ in recorder.operations.append(.raise) },
                orderWindow: { recorder.operations.append(.order($0)) },
                enqueueRetryRaise: { _, _, job, completion in
                    guard recorder.workerAvailable else { return false }
                    recorder.queuedRaises.append((job, completion))
                    return true
                }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.settings.raiseOnMouseFocus = raiseOnMouseFocus
        controller.setFocusFollowsMouse(focusFollowsMouseEnabled)
        return (controller, workspaceId, recorder)
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        mode: TrackedWindowMode = .tiling
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: mode
        )
    }

    private func setFocused(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            ),
            file: file,
            line: line
        )
    }
}
