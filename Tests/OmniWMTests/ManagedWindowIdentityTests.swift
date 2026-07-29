// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class ManagedWindowRebindGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ManagedWindowRebindLiveness {
    var isAlive = true
}

@MainActor
final class ManagedWindowIdentityTests: XCTestCase {
    func testWorkspaceManagerRejectsDuplicateWindowIdBeforeReconcileMutation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let firstWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let secondWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let windowId = 467_501
        let existingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_601), windowId: windowId),
            pid: 467_601,
            windowId: windowId,
            to: firstWorkspace
        )

        let returnedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_602), windowId: windowId),
            pid: 467_602,
            windowId: windowId,
            to: secondWorkspace,
            mode: .floating
        )

        XCTAssertEqual(returnedToken, existingToken)
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [existingToken])
        XCTAssertEqual(controller.workspaceManager.entry(for: existingToken)?.workspaceId, firstWorkspace)
        XCTAssertEqual(controller.workspaceManager.entry(for: existingToken)?.mode, .tiling)
    }

    func testObservedAliasPIDUsesCanonicalManagedWindowToken() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let element = AXUIElementCreateApplication(467_921)
        let axRef = AXWindowRef(element: element, windowId: 467_923)
        let canonicalToken = controller.workspaceManager.addWindow(
            axRef,
            pid: 467_921,
            windowId: 467_923,
            to: workspaceId
        )

        XCTAssertEqual(
            controller.axEventHandler.canonicalObservedWindowToken(
                pid: 467_922,
                axRef: AXWindowRef(element: element, windowId: canonicalToken.windowId)
            ),
            canonicalToken
        )
    }

    func testKnownAlternateProxyElementCanonicalizesAcrossPartialScan() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_930
        let helperPID: pid_t = 467_931
        let windowId = 467_932
        let logicalAXRef = AXWindowRef(element: AXUIElementCreateApplication(logicalPID), windowId: windowId)
        let helperAXRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            helperAXRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(
                pids: [logicalPID, helperPID],
                axRefs: [logicalAXRef, helperAXRef]
            )
        ])
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [helperPID], axRefs: [helperAXRef])
        ])

        let observedToken = controller.axEventHandler.canonicalObservedWindowToken(
            pid: logicalPID,
            axRef: logicalAXRef
        )

        XCTAssertEqual(observedToken, token)
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, token)
    }

    func testStaleAXDestroyCannotRemoveReplacementIncarnation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId = 467_934
        let oldAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_935), windowId: windowId)
        let oldToken = controller.workspaceManager.addWindow(
            oldAXRef,
            pid: 467_935,
            windowId: windowId,
            to: workspaceId
        )
        let oldEntry = try XCTUnwrap(controller.workspaceManager.entry(for: oldToken))
        controller.axEventHandler.discardStaleManagedWindowIncarnation(oldEntry)
        let replacementAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_936),
            windowId: windowId
        )
        let replacementToken = controller.workspaceManager.addWindow(
            replacementAXRef,
            pid: 467_936,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.terminalFrameFailureStateByWindowId[windowId] = TerminalFrameFailureState(
            axRef: replacementAXRef,
            count: 1
        )

        controller.axEventHandler.handleRemoved(pid: oldToken.pid, winId: windowId, axRef: oldAXRef)

        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, replacementToken)
        XCTAssertEqual(controller.axEventHandler.terminalFrameFailureStateByWindowId[windowId]?.count, 1)
    }

    func testStaleAXDestroyCannotClearIdentitylessReplacementAdmission() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId: UInt32 = 467_940
        let replacementToken = WindowToken(pid: 467_941, windowId: Int(windowId))
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: replacementToken,
            axRef: nil,
            reason: .axWindowMissing,
            attempt: 1,
            generation: 1,
            trigger: .create,
            exhausted: false,
            task: nil
        )
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        let staleAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(467_942),
            windowId: Int(windowId)
        )

        controller.axEventHandler.handleRemoved(
            pid: 467_942,
            winId: Int(windowId),
            axRef: staleAXRef
        )

        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testWaitingIdentityRebindTargetDestroyCancelsRetryWithoutRemovingOldWorldEntry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 1)
        var waitingState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]
        )
        waitingState.executionPhase = .waiting
        controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId] = waitingState
        controller.axEventHandler.protectDeferredReplacement(
            windowId: pending.windowId,
            token: pending.oldWindow.token,
            scope: .all
        )

        guard case let .waitingIdentityRebindTarget(generation, oldWindow, newWindow) =
            controller.axEventHandler.managedWindowDestroyDisposition(
                windowId: pending.newWindow.token.windowId,
                axRef: pending.newWindow.axRef
            )
        else {
            return XCTFail("Expected waiting identity-rebind target destroy")
        }
        XCTAssertEqual(generation, waitingState.generation)
        XCTAssertEqual(oldWindow.token, pending.oldWindow.token)
        XCTAssertEqual(newWindow.token, pending.newWindow.token)

        controller.axEventHandler.handleRemoved(
            pid: pending.newWindow.token.pid,
            winId: pending.newWindow.token.windowId,
            axRef: pending.newWindow.axRef
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        XCTAssertNil(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[pending.windowId]
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
    }

    func testRunningIdentityRebindTargetDestroyBlocksCommit() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 2)
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        controller.axEventHandler.protectDeferredReplacement(
            windowId: pending.windowId,
            token: pending.oldWindow.token,
            scope: .all
        )

        controller.axEventHandler.handleRemoved(
            pid: pending.newWindow.token.pid,
            winId: pending.newWindow.token.windowId,
            axRef: pending.newWindow.axRef
        )
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.kind.rawValue,
            LayoutRefreshController.ScheduledRefreshKind.fullRescan.rawValue
        )
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.reason,
            .staleFullRescan
        )
        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        XCTAssertNil(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[pending.windowId]
        )
    }

    func testDestroyDuringIdentityRebindAcknowledgementPreservesOldWorldEntry() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 5)
        let gate = ManagedWindowRebindGate()
        defer {
            gate.release()
            controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
        }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        var finalizationStarted = false
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in
            finalizationStarted = true
            return true
        }

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)

        controller.axEventHandler.handleRemoved(
            pid: pending.newWindow.token.pid,
            winId: pending.newWindow.token.windowId,
            axRef: pending.newWindow.axRef
        )

        let destroyedState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]
        )
        XCTAssertTrue(destroyedState.identityRebindTargetDestroyed)
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.kind.rawValue,
            LayoutRefreshController.ScheduledRefreshKind.fullRescan.rawValue
        )
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.reason,
            .staleFullRescan
        )
        let oldEntryBeforeCompletion = try XCTUnwrap(
            controller.workspaceManager.entry(for: pending.oldWindow.token)
        )
        XCTAssertTrue(CFEqual(oldEntryBeforeCompletion.axRef.element, pending.oldWindow.axRef.element))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))

        gate.release()
        await completion.value

        XCTAssertFalse(finalizationStarted)
        let oldEntryAfterCompletion = try XCTUnwrap(
            controller.workspaceManager.entry(for: pending.oldWindow.token)
        )
        XCTAssertTrue(CFEqual(oldEntryAfterCompletion.axRef.element, pending.oldWindow.axRef.element))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testAuthoritativeOldDestroyRemainsCurrentDuringIdentityRebind() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 3)

        guard case .current = controller.axEventHandler.managedWindowDestroyDisposition(
            windowId: pending.oldWindow.token.windowId,
            axRef: pending.oldWindow.axRef
        ) else {
            return XCTFail("Expected authoritative old element to remain current")
        }

        controller.axEventHandler.handleRemoved(
            pid: pending.oldWindow.token.pid,
            winId: pending.oldWindow.token.windowId,
            axRef: pending.oldWindow.axRef
        )

        XCTAssertNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testStaleExecutionOwnerCannotDeferTargetDestroy() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 4)
        guard case let .running(executionOwner) = pending.state.executionPhase else {
            return XCTFail("Expected running identity-rebind owner")
        }
        var newerState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]
        )
        newerState.executionPhase = .running(executionOwner &+ 1)
        controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId] = newerState

        XCTAssertFalse(
            controller.axEventHandler.deferDestroyedPendingManagedWindowIdentityRebind(
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                executionOwner: executionOwner,
                oldWindow: pending.oldWindow,
                newWindow: pending.newWindow,
                axRef: pending.newWindow.axRef
            )
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]?.executionPhase,
            .running(executionOwner &+ 1)
        )
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testKnownProxyCannotBypassAdmissionQuarantine() {
        let controller = WindowAdmissionTestSupport.controller()
        let windowId = 467_943
        let token = WindowToken(pid: 467_944, windowId: windowId)
        let refusedAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_944), windowId: windowId)
        let proxyAXRef = AXWindowRef(element: AXUIElementCreateApplication(467_945), windowId: windowId)
        controller.axEventHandler.admissionQuarantineByWindowId[windowId] = AdmissionQuarantine(
            token: token,
            axRef: refusedAXRef
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(
                pids: [467_944, 467_945],
                axRefs: [refusedAXRef, proxyAXRef]
            )
        ])

        XCTAssertTrue(
            controller.axEventHandler.isAdmissionQuarantined(
                windowId: windowId,
                axRef: proxyAXRef
            )
        )
        XCTAssertNotNil(controller.axEventHandler.admissionQuarantineByWindowId[windowId])
    }

    func testChangedAXIncarnationCanReplaceExplicitlyRetiredWindowId() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId = 467_933
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_931), windowId: windowId),
            pid: 467_931,
            windowId: windowId,
            to: workspaceId
        )
        let oldEntry = try XCTUnwrap(controller.workspaceManager.entry(for: oldToken))

        controller.axEventHandler.discardStaleManagedWindowIncarnation(oldEntry)
        let replacementToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_932), windowId: windowId),
            pid: 467_932,
            windowId: windowId,
            to: workspaceId
        )

        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertEqual(replacementToken, WindowToken(pid: 467_932, windowId: windowId))
        XCTAssertEqual(controller.workspaceManager.entry(forWindowId: windowId)?.token, replacementToken)
    }

    func testSuccessfulIdentityRebindConsumesPendingRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_973
        let token = WindowToken(pid: 467_974, windowId: Int(windowId))
        let axRef = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let identity = AXManagedWindowIdentity(token: token, axRef: axRef)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .identityRebind(
                    oldWindow: identity,
                    newWindow: identity,
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                )
            )
        )

        let rebound = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: token,
            to: token,
            windowId: windowId,
            axRef: axRef
        )

        XCTAssertNotNil(rebound.committedEntry)
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testCreatePathKeepsIdentityRebindPendingWithoutDuplicateAdmission() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let windowId: UInt32 = 467_975
        let oldToken = WindowToken(pid: 467_976, windowId: Int(windowId))
        let newToken = WindowToken(pid: 467_977, windowId: Int(windowId))
        let sharedElement = AXUIElementCreateApplication(oldToken.pid)
        let oldRef = AXWindowRef(element: sharedElement, windowId: Int(windowId))
        let newRef = AXWindowRef(element: sharedElement, windowId: Int(windowId))
        _ = controller.workspaceManager.addWindow(
            oldRef,
            pid: oldToken.pid,
            windowId: oldToken.windowId,
            to: workspaceId
        )
        controller.hasStartedServices = true
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in false }
        controller.axEventHandler.windowInfoProvider = { requestedWindowId in
            guard requestedWindowId == windowId else { return nil }
            return WindowServerInfo(
                id: windowId,
                pid: newToken.pid,
                level: 0,
                frame: CGRect(x: 10, y: 20, width: 800, height: 600)
            )
        }

        controller.axEventHandler.processCreatedWindow(
            windowId: windowId,
            fallbackToken: newToken,
            fallbackAXRef: newRef
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        guard case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger else {
            return XCTFail("Expected identity rebind retry")
        }
        XCTAssertEqual(retryOld.token, oldToken)
        XCTAssertEqual(retryNew.token, newToken)
        XCTAssertNotNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNil(controller.workspaceManager.entry(for: newToken))
        XCTAssertEqual(controller.workspaceManager.allEntries().count, 1)
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testSameIncarnationLowerPriorityRetryCannotReplaceIdentityRebind() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 5)
        let generation = pending.state.generation

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: pending.windowId,
                expectedToken: pending.newWindow.token,
                axRef: pending.newWindow.axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: pending.newWindow.token,
                    source: .focusedWindowChanged,
                    observationGeneration: 1,
                    callbackGeneration: nil
                )
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        guard case .identityRebind = state.trigger else {
            return XCTFail("Expected higher-priority identity rebind retry")
        }
        XCTAssertEqual(state.generation, generation)
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testReplacementIncarnationDisplacesStaleIdentityRebindRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 6)
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(pending.newWindow.token.pid + 1),
            windowId: pending.newWindow.token.windowId
        )

        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: pending.windowId,
                expectedToken: pending.newWindow.token,
                axRef: replacementRef,
                reason: .factsDeferred,
                trigger: .candidate(token: pending.newWindow.token, axRef: replacementRef)
            )
        )

        let state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        guard case .candidate = state.trigger else {
            return XCTFail("Expected replacement candidate retry")
        }
        XCTAssertNotEqual(state.generation, pending.state.generation)
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testDelayedAcknowledgementPreservesOldIdentityUntilCommit() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 10)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))

        gate.release()
        await completion.value

        XCTAssertNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testSameTokenReplacementCommitsNewAXIncarnationAndInvalidatesFrameState() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(
            controller: controller,
            suffix: 11,
            sameTokenReplacement: true
        )
        let acknowledgementGate = ManagedWindowRebindGate()
        let finalizationGate = ManagedWindowRebindGate()
        defer {
            acknowledgementGate.release()
            finalizationGate.release()
        }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        let finalizationEntered = expectation(description: "rebind finalization entered")
        let staleFrame = CGRect(x: 10, y: 20, width: 700, height: 500)
        var acknowledgementObserved = false
        controller.axManager.confirmFrameWrite(
            for: pending.oldWindow.token.windowId,
            frame: staleFrame
        )
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { oldWindow, newWindow in
            acknowledgementObserved = oldWindow.token == newWindow.token
                && !CFEqual(oldWindow.axRef.element, newWindow.axRef.element)
            acknowledgementEntered.fulfill()
            await acknowledgementGate.wait()
            return true
        }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in
            finalizationEntered.fulfill()
            await finalizationGate.wait()
            return true
        }

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)

        XCTAssertTrue(acknowledgementObserved)
        let entryBeforeCommit = try XCTUnwrap(
            controller.workspaceManager.entry(for: pending.oldWindow.token)
        )
        XCTAssertTrue(CFEqual(entryBeforeCommit.axRef.element, pending.oldWindow.axRef.element))
        XCTAssertEqual(
            controller.axManager.lastAppliedFrame(for: pending.oldWindow.token.windowId),
            staleFrame
        )

        acknowledgementGate.release()
        await fulfillment(of: [finalizationEntered], timeout: 2)

        let committedEntry = try XCTUnwrap(
            controller.workspaceManager.entry(for: pending.newWindow.token)
        )
        XCTAssertTrue(CFEqual(committedEntry.axRef.element, pending.newWindow.axRef.element))
        XCTAssertFalse(CFEqual(committedEntry.axRef.element, pending.oldWindow.axRef.element))
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: pending.newWindow.token.windowId))

        finalizationGate.release()
        await completion.value

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testFailedAcknowledgementKeepsOldIdentityAndAdvancesRetry() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 20)
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in false }

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]?.attempt,
            pending.state.attempt + 1
        )
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testFailedAcknowledgementForTerminatedTargetRetiresRetry() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 21)
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in false }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in false }

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testCapturedConstraintsSurvivePendingIdentityRebind() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let constraints = WindowSizeConstraints.fixed(size: CGSize(width: 640, height: 480))
        let pending = try makePendingRebind(
            controller: controller,
            suffix: 22,
            sizeConstraints: constraints
        )
        guard case let .identityRebind(_, _, _, _, capturedConstraints) = pending.state.trigger else {
            return XCTFail("Expected identity rebind retry")
        }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil,
            sizeConstraints: capturedConstraints
        )

        XCTAssertEqual(
            controller.workspaceManager.cachedConstraints(
                for: pending.newWindow.token,
                maxAge: .greatestFiniteMagnitude
            ),
            constraints.normalized()
        )
    }

    func testCollisionAfterAcknowledgementCannotCommit() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 30)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }
        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)
        let collisionToken = controller.workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(pending.newWindow.token.pid + 1),
                windowId: pending.newWindow.token.windowId
            ),
            pid: pending.newWindow.token.pid + 1,
            windowId: pending.newWindow.token.windowId,
            to: pending.workspaceId
        )

        gate.release()
        await completion.value

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertEqual(
            controller.workspaceManager.entry(forWindowId: pending.newWindow.token.windowId)?.token,
            collisionToken
        )
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testTerminationDuringAcknowledgementCannotCommit() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 40)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        let liveness = ManagedWindowRebindLiveness()
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in
            liveness.isAlive
        }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }
        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)
        liveness.isAlive = false

        gate.release()
        await completion.value

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
    }

    func testStaleAcknowledgementCannotConsumeNewerRetryGeneration() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 50)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let acknowledgementEntered = expectation(description: "rebind acknowledgement entered")
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }
        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)
        var newerState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]
        )
        newerState.generation &+= 1
        controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId] = newerState

        gate.release()
        await completion.value

        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]?.generation,
            newerState.generation
        )
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testStaleFinalizationCannotRunSuccessCleanup() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 60)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let finalizationEntered = expectation(description: "rebind finalization entered")
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in
            finalizationEntered.fulfill()
            await gate.wait()
            return true
        }
        controller.axEventHandler.admissionQuarantineByWindowId[pending.oldWindow.token.windowId] =
            AdmissionQuarantine(token: pending.oldWindow.token, axRef: pending.oldWindow.axRef)

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [finalizationEntered], timeout: 2)
        XCTAssertNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.newWindow.token))

        var newerState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]
        )
        newerState.generation &+= 1
        controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId] = newerState
        gate.release()
        await completion.value

        XCTAssertEqual(
            controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId]?.generation,
            newerState.generation
        )
        XCTAssertNotNil(
            controller.axEventHandler.admissionQuarantineByWindowId[pending.oldWindow.token.windowId]
        )
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: pending.windowId)
    }

    func testFailedFinalizationStillRetiresOldFrameState() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 61)
        let oldFrame = CGRect(x: 10, y: 20, width: 700, height: 500)
        controller.axManager.confirmFrameWrite(
            for: pending.oldWindow.token.windowId,
            frame: oldFrame
        )
        controller.axEventHandler.admissionQuarantineByWindowId[pending.oldWindow.token.windowId] =
            AdmissionQuarantine(token: pending.oldWindow.token, axRef: pending.oldWindow.axRef)
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in false }

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNotNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: pending.oldWindow.token.windowId))
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: pending.newWindow.token.windowId))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        XCTAssertNotNil(
            controller.axEventHandler.admissionQuarantineByWindowId[pending.oldWindow.token.windowId]
        )
    }

    func testTerminalObserverWorldRetirementPreventsContextFinalization() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 63)
        var terminalDeliveryCount = 0
        var finalizationCount = 0
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in
            finalizationCount += 1
            return true
        }
        controller.axManager.applyFramesParallel([
            .init(
                pid: pending.oldWindow.token.pid,
                window: pending.oldWindow.axRef,
                frame: CGRect(x: 10, y: 20, width: 700, height: 500)
            )
        ]) { _ in
            terminalDeliveryCount += 1
            _ = controller.workspaceManager.removeWindow(
                pid: pending.newWindow.token.pid,
                windowId: pending.newWindow.token.windowId
            )
        }
        XCTAssertEqual(terminalDeliveryCount, 0)

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: pending.oldWindow,
            to: pending.newWindow,
            windowId: pending.windowId,
            retryGeneration: pending.state.generation,
            managedReplacementMetadata: nil,
            admissionHints: nil
        )

        XCTAssertEqual(terminalDeliveryCount, 1)
        XCTAssertEqual(finalizationCount, 0)
        XCTAssertNil(controller.workspaceManager.entry(for: pending.oldWindow.token))
        XCTAssertNil(controller.workspaceManager.entry(for: pending.newWindow.token))
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[pending.windowId])
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.activeRefresh?.reason,
            .staleFullRescan
        )
    }

    func testFrameLedgerCommitsBeforeContextFinalizationAndIsNotResetTwice() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let pending = try makePendingRebind(controller: controller, suffix: 62)
        let gate = ManagedWindowRebindGate()
        defer { gate.release() }
        let finalizationEntered = expectation(description: "rebind finalization entered")
        let oldFrame = CGRect(x: 10, y: 20, width: 700, height: 500)
        let newFrame = CGRect(x: 30, y: 40, width: 900, height: 600)
        controller.axManager.confirmFrameWrite(
            for: pending.oldWindow.token.windowId,
            frame: oldFrame
        )
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in
            finalizationEntered.fulfill()
            await gate.wait()
            return false
        }

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: pending.oldWindow,
                to: pending.newWindow,
                windowId: pending.windowId,
                retryGeneration: pending.state.generation,
                managedReplacementMetadata: nil,
                admissionHints: nil
            )
        }
        await fulfillment(of: [finalizationEntered], timeout: 2)

        XCTAssertNil(controller.axManager.lastAppliedFrame(for: pending.oldWindow.token.windowId))
        controller.axManager.confirmFrameWrite(
            for: pending.newWindow.token.windowId,
            frame: newFrame
        )

        gate.release()
        await completion.value

        XCTAssertEqual(
            controller.axManager.lastAppliedFrame(for: pending.newWindow.token.windowId),
            newFrame
        )
    }

    private func makePendingRebind(
        controller: WMController,
        suffix: Int,
        sizeConstraints: WindowSizeConstraints? = nil,
        sameTokenReplacement: Bool = false
    ) throws -> (
        workspaceId: WorkspaceDescriptor.ID,
        windowId: UInt32,
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity,
        state: AdmissionRetryState
    ) {
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: pid_t(468_000 + suffix), windowId: 468_100 + suffix)
        let newToken = sameTokenReplacement
            ? oldToken
            : WindowToken(pid: pid_t(468_200 + suffix), windowId: 468_300 + suffix)
        let oldRef = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        let newRef = AXWindowRef(
            element: AXUIElementCreateApplication(newToken.pid + (sameTokenReplacement ? 1 : 0)),
            windowId: newToken.windowId
        )
        controller.hasStartedServices = true
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { _ in true }

        guard case .pending = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: oldToken,
            to: newToken,
            windowId: UInt32(newToken.windowId),
            axRef: newRef,
            sizeConstraints: sizeConstraints
        ) else {
            XCTFail("Expected identity rebind to enter the retry lifecycle")
            throw NSError(domain: "ManagedWindowIdentityTests", code: 1)
        }
        let windowId = UInt32(newToken.windowId)
        var state = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        state.task?.cancel()
        state.task = nil
        state.executionPhase = .running(UInt64(500_000 + suffix))
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = state
        return (
            workspaceId,
            windowId,
            AXManagedWindowIdentity(token: oldToken, axRef: oldRef),
            AXManagedWindowIdentity(token: newToken, axRef: newRef),
            state
        )
    }
}

@MainActor
private extension AXEventHandler {
    func completeManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        windowId: UInt32,
        retryGeneration: UInt64,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?,
        sizeConstraints: WindowSizeConstraints? = nil
    ) async {
        guard let state = admissionRetryStateByWindowId[windowId],
              case let .running(executionOwner) = state.executionPhase
        else {
            XCTFail("Expected a running identity-rebind owner")
            return
        }
        await completeManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            windowId: windowId,
            retryGeneration: retryGeneration,
            executionOwner: executionOwner,
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints,
            sizeConstraints: sizeConstraints
        )
    }
}
