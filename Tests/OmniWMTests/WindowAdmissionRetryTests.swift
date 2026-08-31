// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class FocusedFactReadGate {
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

@MainActor
final class WindowAdmissionRetryTests: XCTestCase {
    func testMissingWindowInfoRetryRecordsTypedReason() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_201
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        controller.axEventHandler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))

        let trace = controller.axEventHandler.createFocusTraceDump()
        XCTAssertTrue(trace.contains("window=\(windowId) pid=nil reason=window_info_missing attempt=1"))
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testRetryExhaustionSurvivesPIDAliasUntilAXIncarnationChanges() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_403
        let firstToken = WindowToken(pid: 467_303, windowId: Int(windowId))
        let firstAXRef = AXWindowRef(element: AXUIElementCreateApplication(firstToken.pid), windowId: Int(windowId))
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: firstToken,
            axRef: firstAXRef,
            reason: .degenerateGeometry,
            attempt: AXEventHandler.createdWindowRetryLimit,
            generation: 1,
            trigger: .candidate(token: firstToken, axRef: firstAXRef),
            exhausted: true,
            task: nil
        )

        let aliasToken = WindowToken(pid: firstToken.pid + 1, windowId: Int(windowId))
        XCTAssertFalse(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: aliasToken,
                axRef: firstAXRef,
                reason: .degenerateGeometry,
                trigger: .candidate(token: aliasToken, axRef: firstAXRef)
            )
        )
        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]?.attempt,
            AXEventHandler.createdWindowRetryLimit
        )

        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(aliasToken.pid + 1),
            windowId: Int(windowId)
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: aliasToken,
                axRef: replacementAXRef,
                reason: .degenerateGeometry,
                trigger: .candidate(token: aliasToken, axRef: replacementAXRef)
            )
        )
        XCTAssertEqual(controller.axEventHandler.admissionRetryStateByWindowId[windowId]?.attempt, 1)
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testCreateRetryCannotReplaceConcreteCandidateTrigger() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_405
        let token = WindowToken(pid: 467_305, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: nil,
                axRef: axRef,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(state.expectedToken, token)
        XCTAssertTrue(CFEqual(state.axRef?.element, axRef.element))
        guard case let .candidate(triggerToken, triggerAXRef, _) = state.trigger else {
            return XCTFail("Expected concrete candidate retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertTrue(CFEqual(triggerAXRef.element, axRef.element))
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testDeferredDiscoveryCandidateRetainsRetryTriggerWhenDrained() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_805
        let token = WindowToken(pid: 467_705, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .factsDeferred,
                placementOrigin: .discovery
            )
        )

        var runningState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]
        )
        runningState.task?.cancel()
        runningState.task = nil
        runningState.executionPhase = .running(701)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = runningState
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.processCreatedWindow(
            windowId: windowId,
            fallbackToken: token,
            fallbackAXRef: axRef,
            placementOrigin: .discovery,
            retryTrigger: runningState.trigger
        )
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        controller.axEventHandler.windowInfoProvider = { _ in nil }

        await controller.axEventHandler.drainDeferredCreatedWindows()

        let rescheduled = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]
        )
        guard case let .candidate(triggerToken, triggerAXRef, placementOrigin) = rescheduled.trigger else {
            return XCTFail("Expected discovery candidate retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertTrue(CFEqual(triggerAXRef.element, axRef.element))
        XCTAssertEqual(placementOrigin, .discovery)
        XCTAssertEqual(rescheduled.attempt, runningState.attempt + 1)
        XCTAssertNotNil(rescheduled.task)
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testCandidateRetryCannotReplaceFocusedRetrySemantics() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_406
        let token = WindowToken(pid: 467_306, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 7,
                    callbackGeneration: nil
                )
            )
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        guard case let .focused(triggerToken, source, observationGeneration, _) = state.trigger else {
            return XCTFail("Expected focused retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertEqual(source, .focusedWindowChanged)
        XCTAssertEqual(observationGeneration, 7)
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
    }

    func testSuccessfulLowerPriorityAdmissionConsumesFocusedRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_407
        let token = WindowToken(pid: 467_307, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 7,
                    callbackGeneration: nil
                )
            )
        )
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )

        controller.axEventHandler.finishAdmissionRetryAfterTracking(windowId: windowId)

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testKnownProxyElementsShareRetryPriorityAndBudget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_408
        let logicalToken = WindowToken(pid: 467_308, windowId: Int(windowId))
        let helperToken = WindowToken(pid: 467_309, windowId: Int(windowId))
        let logicalAXRef = WindowAdmissionTestSupport.axRef(for: logicalToken)
        let helperAXRef = WindowAdmissionTestSupport.axRef(for: helperToken)
        controller.axEventHandler.updateIdentityAliases([
            Int(windowId): .init(
                pids: [logicalToken.pid, helperToken.pid],
                axRefs: [logicalAXRef, helperAXRef]
            )
        ])
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: helperToken.pid,
                axRef: helperAXRef,
                reason: .degenerateGeometry
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: logicalToken,
                axRef: logicalAXRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: logicalToken,
                    source: .focusedWindowChanged,
                    observationGeneration: 9,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: helperToken.pid,
                axRef: helperAXRef,
                reason: .degenerateGeometry
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(state.attempt, 1)
        guard case .focused = state.trigger else {
            return XCTFail("Expected focused retry")
        }
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testAppTerminationRetiresAdmissionRetryAndOnlyItsIdentityAliases() {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let terminatedPID: pid_t = 467_310
        let survivingPID: pid_t = 467_311
        let windowId: UInt32 = 467_409
        let token = WindowToken(pid: terminatedPID, windowId: Int(windowId))
        let terminatedAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(terminatedPID),
            windowId: token.windowId
        )
        let survivingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(survivingPID),
            windowId: token.windowId
        )
        controller.axEventHandler.updateIdentityAliases([
            Int(windowId): .init(
                pids: [terminatedPID, survivingPID],
                axRefs: [terminatedAXRef, survivingAXRef]
            )
        ])
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: nil,
                reason: .factsDeferred,
                trigger: .create
            )
        )
        _ = controller.axEventHandler.retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller
        )
        let protectionScope = RescanScope.targeted(
            appPIDs: [terminatedPID, survivingPID],
            nativeSpaceIds: []
        )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: WindowToken(pid: survivingPID, windowId: 467_410),
            scope: protectionScope
        )
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.processCreatedWindow(windowId: windowId)
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        XCTAssertTrue(controller.axEventHandler.isCreatedWindowDeferred(windowId))

        controller.axEventHandler.cleanupFocusStateForTerminatedApp(pid: terminatedPID)

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertFalse(controller.axEventHandler.isCreatedWindowDeferred(windowId))
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope)
        XCTAssertNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)))
        XCTAssertEqual(
            controller.axEventHandler.identityAliasesByWindowId[Int(windowId)]?.current?.pids,
            [survivingPID]
        )
        XCTAssertEqual(
            controller.axEventHandler.identityAliasesByWindowId[Int(windowId)]?.current?.axRefs.count,
            1
        )
    }

    func testManagedRetirementSettlesAdmissionProtectionAfterWorldRemoval() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let protectedToken = WindowToken(pid: 467_312, windowId: 467_411)
        let retiringToken = WindowToken(pid: protectedToken.pid, windowId: 467_412)
        _ = WindowAdmissionTestSupport.track(
            protectedToken,
            in: workspaceId,
            controller: controller
        )
        let retiringAXRef = WindowAdmissionTestSupport.track(
            retiringToken,
            in: workspaceId,
            controller: controller
        )
        let windowId = UInt32(retiringToken.windowId)
        let scope = RescanScope.targeted(appPIDs: [retiringToken.pid], nativeSpaceIds: [])
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] =
            AdmissionRetryState(
                expectedToken: retiringToken,
                axRef: retiringAXRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: 1,
                trigger: .candidate(token: retiringToken, axRef: retiringAXRef),
                exhausted: false
            )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: protectedToken,
            scope: scope
        )
        let retiringEntry = try XCTUnwrap(
            controller.workspaceManager.entry(for: retiringToken)
        )

        controller.axEventHandler.retireManagedWindow(
            retiringEntry,
            reason: .staleIncarnation
        )

        XCTAssertNil(controller.workspaceManager.entry(for: retiringToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: protectedToken))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testHigherPriorityRunningPreemptionKeepsAttemptAndChangesGeneration() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_410
        let token = WindowToken(pid: 467_312, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .degenerateGeometry,
            attempt: 3,
            generation: 71,
            trigger: .candidate(token: token, axRef: axRef),
            exhausted: false,
            executionPhase: .running(11),
            task: Task {}
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 12,
                    callbackGeneration: nil
                )
            )
        )

        let preempted = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(preempted.attempt, 3)
        XCTAssertNotEqual(preempted.generation, 71)
        XCTAssertEqual(preempted.executionPhase, .waiting)
        XCTAssertNotNil(preempted.task)
        guard case .focused = preempted.trigger else {
            return XCTFail("Expected focused retry")
        }
    }

    func testMissingFocusedFactsRetireRunningOwnerAndAllowCandidateRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_422
        let token = WindowToken(pid: 467_322, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let execution = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: token,
            axRef: axRef,
            generation: 81,
            executionOwner: 21
        )
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: nil,
                focusedAdmissionRetryExecution: execution
            )
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }
        let candidate = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNotEqual(candidate.generation, execution.generation)
        XCTAssertEqual(candidate.executionPhase, .waiting)
        XCTAssertNotNil(candidate.task)
        guard case let .candidate(candidateToken, candidateAXRef, _) = candidate.trigger else {
            return XCTFail("Expected candidate retry")
        }
        XCTAssertEqual(candidateToken, token)
        XCTAssertTrue(CFEqual(candidateAXRef.element, axRef.element))
    }

    func testPendingFocusedOutcomeReplacesRunningOwnerWithWaitingGeneration() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_428
        let token = WindowToken(pid: 467_328, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let execution = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: token,
            axRef: axRef,
            generation: 88,
            executionOwner: 28
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .focusedWindowChanged,
                    observationGeneration: 0,
                    callbackGeneration: nil
                )
            )
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }

        let pending = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNotEqual(pending.generation, execution.generation)
        XCTAssertEqual(pending.attempt, 2)
        XCTAssertEqual(pending.executionPhase, .waiting)
        XCTAssertNotNil(pending.task)
        XCTAssertFalse(controller.axEventHandler.ownsFocusedAdmissionRetryExecution(execution))
        guard case .focused = pending.trigger else {
            return XCTFail("Expected focused retry")
        }
    }

    func testManagedFocusedOutcomeDiscardsRetainedCreatePlacementContext() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_431
        let token = WindowToken(pid: 467_331, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.track(
            token,
            in: workspaceId,
            controller: controller
        )
        _ = controller.axEventHandler.retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller
        )
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)))
    }

    func testRejectedFocusedFactsRetireRunningOwnerAndAllowCandidateRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_423
        let token = WindowToken(pid: 467_323, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let execution = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: token,
            axRef: axRef,
            generation: 82,
            executionOwner: 22
        )
        controller.axEventHandler.admissionQuarantineByWindowId[token.windowId] = AdmissionQuarantine(
            token: token,
            axRef: axRef
        )
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                ),
                focusedAdmissionRetryExecution: execution
            )
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(controller.axEventHandler.pendingCreatePlacementContext(for: Int(windowId)))
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }
        let candidate = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNotEqual(candidate.generation, execution.generation)
        XCTAssertEqual(candidate.executionPhase, .waiting)
        XCTAssertNotNil(candidate.task)
        guard case .candidate = candidate.trigger else {
            return XCTFail("Expected candidate retry")
        }
    }

    func testFocusedRetryEarlyExitRetiresRunningOwnerAndAllowsCandidateRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_424
        let token = WindowToken(pid: 467_324, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .factsDeferred,
            attempt: 1,
            generation: 83,
            trigger: .focused(
                token: token,
                source: .focusedWindowChanged,
                observationGeneration: 0,
                callbackGeneration: nil
            ),
            exhausted: false,
            task: nil
        )

        XCTAssertTrue(controller.axEventHandler.retryAdmissionAfterFrameChange(windowId: windowId))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(
            controller.axEventHandler.scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }
        let candidate = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNotEqual(candidate.generation, 83)
        XCTAssertEqual(candidate.executionPhase, .waiting)
        XCTAssertNotNil(candidate.task)
        guard case .candidate = candidate.trigger else {
            return XCTFail("Expected candidate retry")
        }
    }

    func testStaleFocusedRetryRetirementSettlesDeferredReplacementProtection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_325, windowId: 467_425)
        let retryToken = WindowToken(pid: oldToken.pid, windowId: 467_426)
        let windowId = UInt32(retryToken.windowId)
        _ = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        _ = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: retryToken,
            axRef: WindowAdmissionTestSupport.axRef(for: retryToken),
            generation: 84,
            executionOwner: 22
        )
        let scope = RescanScope.targeted(appPIDs: [oldToken.pid], nativeSpaceIds: [])
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: oldToken,
            scope: scope
        )

        controller.axEventHandler.retireStaleFocusedAdmissionRetry(
            pid: retryToken.pid,
            observationGeneration: 0
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testStaleFocusedContinuationRetiresWithoutCancellingIdentityRebind() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let oldToken = WindowToken(pid: 467_326, windowId: 467_426)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 467_427)
        let newRef = WindowAdmissionTestSupport.axRef(for: newToken)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(newToken.windowId),
                expectedToken: newToken,
                axRef: newRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: newToken,
                    source: .focusedWindowChanged,
                    observationGeneration: 15,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(newToken.windowId),
                expectedToken: newToken,
                axRef: newRef,
                reason: .factsDeferred,
                trigger: .identityRebind(
                    oldWindow: AXManagedWindowIdentity(
                        token: oldToken,
                        axRef: WindowAdmissionTestSupport.axRef(for: oldToken)
                    ),
                    newWindow: AXManagedWindowIdentity(token: newToken, axRef: newRef),
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                )
            )
        )
        defer {
            controller.axEventHandler.cancelCreatedWindowRetry(windowId: UInt32(newToken.windowId))
        }

        controller.axEventHandler.retireStaleFocusedAdmissionRetry(
            pid: newToken.pid,
            observationGeneration: 15
        )

        let state = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(newToken.windowId)]
        )
        guard case .identityRebind = state.trigger else {
            return XCTFail("Expected identity rebind retry to remain live")
        }
        XCTAssertNil(state.focusedAdmissionContinuation)
    }

    func testRuleReevaluationCancellationSettlesDeferredReplacementProtection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let protectedToken = WindowToken(pid: 467_335, windowId: 467_435)
        let retryToken = WindowToken(pid: protectedToken.pid, windowId: 467_436)
        _ = WindowAdmissionTestSupport.track(
            protectedToken,
            in: workspaceId,
            controller: controller
        )
        let retryAXRef = WindowAdmissionTestSupport.axRef(for: retryToken)
        _ = controller.workspaceManager.addWindow(
            retryAXRef,
            pid: retryToken.pid,
            windowId: retryToken.windowId,
            to: workspaceId,
            mode: .floating
        )
        let windowId = UInt32(retryToken.windowId)
        let scope = RescanScope.targeted(appPIDs: [retryToken.pid], nativeSpaceIds: [])
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] =
            AdmissionRetryState(
                expectedToken: retryToken,
                axRef: retryAXRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: 85,
                trigger: .ruleReevaluation(
                    token: retryToken,
                    axRef: retryAXRef
                ),
                exhausted: false
            )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: protectedToken,
            scope: scope
        )

        controller.axEventHandler.cancelTrackedTilingPromotionRetry(
            windowId: retryToken.windowId
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testRuleReevaluationCompletionSettlesDeferredReplacementProtection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let protectedToken = WindowToken(pid: 467_336, windowId: 467_437)
        let retryToken = WindowToken(pid: protectedToken.pid, windowId: 467_438)
        _ = WindowAdmissionTestSupport.track(
            protectedToken,
            in: workspaceId,
            controller: controller
        )
        let retryAXRef = WindowAdmissionTestSupport.axRef(for: retryToken)
        let windowId = UInt32(retryToken.windowId)
        let generation: UInt64 = 86
        let executionOwner: UInt64 = 23
        let scope = RescanScope.targeted(appPIDs: [retryToken.pid], nativeSpaceIds: [])
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] =
            AdmissionRetryState(
                expectedToken: retryToken,
                axRef: retryAXRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: generation,
                trigger: .ruleReevaluation(token: retryToken, axRef: retryAXRef),
                exhausted: false,
                executionPhase: .running(executionOwner)
            )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: protectedToken,
            scope: scope
        )

        controller.axEventHandler.finishRuleReevaluationRetry(
            windowId: windowId,
            generation: generation,
            executionOwner: executionOwner,
            token: retryToken,
            axRef: retryAXRef,
            reason: .factsDeferred,
            stale: false
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testStaleFocusedFactCompletionCannotMutateNewerRetryOwner() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_425
        let token = WindowToken(pid: 467_325, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        _ = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: token,
            axRef: axRef,
            generation: 85,
            executionOwner: 25
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: nil,
                focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution(
                    windowId: windowId,
                    generation: 84,
                    executionOwner: 24
                )
            )
        )

        let current = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(current.generation, 85)
        XCTAssertEqual(current.executionPhase, .running(25))
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
    }

    func testMatchingCollisionReplaysFocusedRetryAfterAuthoritativeTracking() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_426
        let token = WindowToken(pid: 467_326, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        var resolvedPIDs: [pid_t] = []
        controller.factResolver.factProvider = { pid in
            resolvedPIDs.append(pid)
            return nil
        }
        controller.hasStartedServices = true
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .factsDeferred,
            attempt: 1,
            generation: 86,
            trigger: .focused(
                token: token,
                source: .focusedWindowChanged,
                observationGeneration: 0,
                callbackGeneration: nil
            ),
            exhausted: false,
            task: Task {}
        )

        controller.axEventHandler.finishAdmissionRetryAfterCollision(
            windowId: windowId,
            token: token,
            axRef: axRef
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(resolvedPIDs, [token.pid])
    }

    func testIdentityRebindCompletionReplaysRetainedFocusedContinuation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_328, windowId: 467_428)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 467_429)
        let newRef = WindowAdmissionTestSupport.axRef(for: newToken)
        var resolvedPIDs: [pid_t] = []
        controller.factResolver.factProvider = { pid in
            resolvedPIDs.append(pid)
            return nil
        }
        controller.hasStartedServices = true
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(newToken.windowId),
                expectedToken: newToken,
                axRef: newRef,
                reason: .degenerateGeometry,
                trigger: .focused(
                    token: newToken,
                    source: .focusedWindowChanged,
                    observationGeneration: 0,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(newToken.windowId),
                expectedToken: newToken,
                axRef: newRef,
                reason: .factsDeferred,
                trigger: .identityRebind(
                    oldWindow: AXManagedWindowIdentity(
                        token: oldToken,
                        axRef: WindowAdmissionTestSupport.axRef(for: oldToken)
                    ),
                    newWindow: AXManagedWindowIdentity(token: newToken, axRef: newRef),
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                )
            )
        )
        _ = controller.workspaceManager.addWindow(
            newRef,
            pid: newToken.pid,
            windowId: newToken.windowId,
            to: workspaceId,
            mode: .floating
        )

        controller.axEventHandler.finishAdmissionRetryAfterTracking(
            windowId: UInt32(newToken.windowId)
        )

        XCTAssertNil(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(newToken.windowId)]
        )
        XCTAssertEqual(resolvedPIDs, [newToken.pid])
    }

    func testIdentityRebindReplayRetainsFullRescanBarrierUntilFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { controller.eventIntake.close() }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_330, windowId: 467_430)
        let modalToken = WindowToken(pid: oldToken.pid, windowId: 467_431)
        let modalRef = WindowAdmissionTestSupport.axRef(for: modalToken)
        controller.factResolver.factProvider = { _ in
            FocusedWindowFact(
                axRef: modalRef,
                isFullscreen: false,
                isSystemModalSurface: true
            )
        }
        controller.axEventHandler.frontmostApplicationPIDProvider = { modalToken.pid }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.hasStartedServices = true
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(modalToken.windowId),
                expectedToken: modalToken,
                axRef: modalRef,
                reason: .degenerateGeometry,
                trigger: .focused(
                    token: modalToken,
                    source: .focusedWindowChanged,
                    observationGeneration: 0,
                    callbackGeneration: nil
                )
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(modalToken.windowId),
                expectedToken: modalToken,
                axRef: modalRef,
                reason: .factsDeferred,
                trigger: .identityRebind(
                    oldWindow: AXManagedWindowIdentity(
                        token: oldToken,
                        axRef: WindowAdmissionTestSupport.axRef(for: oldToken)
                    ),
                    newWindow: AXManagedWindowIdentity(token: modalToken, axRef: modalRef),
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                )
            )
        )
        _ = controller.workspaceManager.addWindow(
            modalRef,
            pid: modalToken.pid,
            windowId: modalToken.windowId,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setSystemModalFocus(modalToken)

        controller.axEventHandler.finishAdmissionRetryAfterTracking(
            windowId: UInt32(modalToken.windowId)
        )

        XCTAssertTrue(controller.axEventHandler.hasLiveFocusedAdmissionContinuation(for: modalToken))
        let replayExecutionPhase = controller.axEventHandler
            .admissionRetryStateByWindowId[UInt32(modalToken.windowId)]?.executionPhase
        controller.axEventHandler.finishAdmissionRetryAfterTracking(
            windowId: UInt32(modalToken.windowId)
        )
        XCTAssertEqual(
            controller.axEventHandler
                .admissionRetryStateByWindowId[UInt32(modalToken.windowId)]?.executionPhase,
            replayExecutionPhase
        )
        controller.eventIntake.drainNow()

        XCTAssertNil(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(modalToken.windowId)]
        )
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, modalToken)
    }

    func testCollisionRequiresMatchingTokenAndAXElement() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_427
        let token = WindowToken(pid: 467_327, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .factsDeferred,
            attempt: 1,
            generation: 87,
            trigger: .focused(
                token: token,
                source: .focusedWindowChanged,
                observationGeneration: 0,
                callbackGeneration: nil
            ),
            exhausted: false,
            task: Task {}
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }
        let differentAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid + 1),
            windowId: token.windowId
        )

        controller.axEventHandler.finishAdmissionRetryAfterCollision(
            windowId: windowId,
            token: token,
            axRef: differentAXRef
        )
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])

        controller.axEventHandler.finishAdmissionRetryAfterCollision(
            windowId: windowId,
            token: WindowToken(pid: token.pid + 1, windowId: token.windowId),
            axRef: axRef
        )
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testPendingFocusedFactRequestOverwriteRetiresOnlySupersededOwner() async {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_429
        let token = WindowToken(pid: 467_329, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let execution = installRunningFocusedRetry(
            controller: controller,
            windowId: windowId,
            token: token,
            axRef: axRef,
            generation: 89,
            executionOwner: 29
        )
        let unrelatedWindowId: UInt32 = 467_430
        let unrelatedToken = WindowToken(pid: 467_330, windowId: Int(unrelatedWindowId))
        let unrelatedAXRef = WindowAdmissionTestSupport.axRef(for: unrelatedToken)
        _ = installRunningFocusedRetry(
            controller: controller,
            windowId: unrelatedWindowId,
            token: unrelatedToken,
            axRef: unrelatedAXRef,
            generation: 90,
            executionOwner: 30
        )
        let gate = FocusedFactReadGate()
        let readFinished = expectation(description: "Deferred fact read finished")
        controller.factResolver.deferredFactProvider = { _ in
            await gate.wait()
            readFinished.fulfill()
            return nil
        }
        controller.eventIntake.open(sink: controller.eventInterpreter)

        XCTAssertTrue(
            controller.factResolver.resolveActivationFacts(
                pid: token.pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 1
            )
        )
        XCTAssertTrue(
            controller.factResolver.resolveActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                focusedAdmissionRetryExecution: execution
            )
        )
        XCTAssertTrue(
            controller.factResolver.resolveActivationFacts(
                pid: token.pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 2
            )
        )

        controller.eventIntake.drainNow()

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[unrelatedWindowId])
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)

        controller.factResolver.stop()
        controller.eventIntake.close()
        gate.release()
        await fulfillment(of: [readFinished], timeout: 2)
        controller.factResolver.deferredFactProvider = nil
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: unrelatedWindowId)
    }

    func testStoppedResolverDropsOldActivationCompletionAfterRestart() async {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_331
        let gate = FocusedFactReadGate()
        let readStarted = expectation(description: "Deferred fact read started")
        let readFinished = expectation(description: "Deferred fact read finished")
        controller.factResolver.deferredFactProvider = { _ in
            readStarted.fulfill()
            await gate.wait()
            readFinished.fulfill()
            return nil
        }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        XCTAssertTrue(
            controller.factResolver.resolveActivationFacts(
                pid: pid,
                source: .workspaceDidActivateApplication,
                origin: .external,
                observationGeneration: 1
            )
        )
        await fulfillment(of: [readStarted], timeout: 2)

        controller.factResolver.stop()
        controller.eventIntake.close()
        controller.eventIntake.open(sink: controller.eventInterpreter)
        let reopenedSeq = controller.eventIntake.lastSeq
        gate.release()
        await fulfillment(of: [readFinished], timeout: 2)
        await Task.yield()
        controller.eventIntake.drainNow()

        XCTAssertEqual(controller.eventIntake.lastSeq, reopenedSeq)
        controller.factResolver.stop()
        controller.eventIntake.close()
        controller.factResolver.deferredFactProvider = nil
    }

    func testRetryOwnershipCountersRemainMonotonicAcrossReset() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let firstWindowId: UInt32 = 467_420
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: firstWindowId,
                expectedToken: nil,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )
        let firstGeneration = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[firstWindowId]?.generation
        )
        controller.axEventHandler.nextAdmissionRetryExecutionOwner = 91

        controller.axEventHandler.resetCreatedWindowRetryState()

        let secondWindowId: UInt32 = 467_421
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: secondWindowId,
                expectedToken: nil,
                reason: .windowInfoMissing,
                trigger: .create
            )
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: secondWindowId) }
        let secondGeneration = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[secondWindowId]?.generation
        )
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(controller.axEventHandler.nextAdmissionRetryExecutionOwner, 91)
    }

    func testTrackingCollisionFinishesOnlyTheExactNonRebindRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_411
        let token = WindowToken(pid: 467_313, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let trackedToken = WindowToken(pid: token.pid - 1, windowId: token.windowId)
        _ = WindowAdmissionTestSupport.track(trackedToken, in: workspaceId, controller: controller)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .factsDeferred,
            attempt: 2,
            generation: 72,
            trigger: .candidate(token: token, axRef: axRef),
            exhausted: false,
            task: Task {}
        )
        let unrelatedToken = WindowToken(pid: token.pid + 1, windowId: token.windowId)
        let unrelatedAXRef = WindowAdmissionTestSupport.axRef(for: unrelatedToken)

        controller.axEventHandler.finishAdmissionRetryAfterCollision(
            windowId: windowId,
            token: unrelatedToken,
            axRef: unrelatedAXRef
        )
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])

        controller.axEventHandler.trackPreparedCreate(
            .init(
                windowId: windowId,
                token: token,
                axRef: axRef,
                ruleEffects: .none,
                admissionHints: .none,
                replacementMetadata: .init(
                    bundleId: nil,
                    workspaceId: workspaceId,
                    mode: .tiling,
                    role: nil,
                    subrole: nil,
                    title: nil,
                    windowLevel: nil,
                    parentWindowId: nil,
                    frame: nil
                ),
                structuralReplacementMatch: nil
            )
        )
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: Int(windowId))?.token, trackedToken)
    }

    func testCollisionDoesNotFinishIdentityRebindRetry() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_412
        let oldToken = WindowToken(pid: 467_314, windowId: Int(windowId))
        let oldAXRef = WindowAdmissionTestSupport.axRef(for: oldToken)
        let newToken = WindowToken(pid: 467_315, windowId: Int(windowId))
        let newAXRef = WindowAdmissionTestSupport.axRef(for: newToken)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: newToken,
            axRef: newAXRef,
            reason: .factsDeferred,
            attempt: 2,
            generation: 73,
            trigger: .identityRebind(
                oldWindow: .init(token: oldToken, axRef: oldAXRef),
                newWindow: .init(token: newToken, axRef: newAXRef),
                managedReplacementMetadata: nil,
                admissionHints: nil,
                sizeConstraints: nil
            ),
            exhausted: false,
            task: Task {}
        )
        defer { controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId) }

        controller.axEventHandler.finishAdmissionRetryAfterCollision(
            windowId: windowId,
            token: newToken,
            axRef: newAXRef
        )

        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    private func installRunningFocusedRetry(
        controller: WMController,
        windowId: UInt32,
        token: WindowToken,
        axRef: AXWindowRef,
        generation: UInt64,
        executionOwner: UInt64
    ) -> FocusedAdmissionRetryExecution {
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token,
            axRef: axRef,
            reason: .factsDeferred,
            attempt: 1,
            generation: generation,
            trigger: .focused(
                token: token,
                source: .focusedWindowChanged,
                observationGeneration: 0,
                callbackGeneration: nil
            ),
            exhausted: false,
            executionPhase: .running(executionOwner),
            task: Task {}
        )
        return FocusedAdmissionRetryExecution(
            windowId: windowId,
            generation: generation,
            executionOwner: executionOwner
        )
    }
}
