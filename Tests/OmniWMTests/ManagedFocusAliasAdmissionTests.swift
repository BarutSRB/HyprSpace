// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAliasAdmissionTests: XCTestCase {
    func testRepeatedUncorroboratedObserverPIDAliasDoesNotConsumeManagedFocusRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let observerPID: pid_t = 467_927
        let helperPID: pid_t = 467_928
        let windowId = 467_929
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [observerPID, helperPID], axRefs: [axRef])
        ])
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        for observationGeneration in UInt64(1) ... 8 {
            controller.axEventHandler.handleAppActivation(pid: observerPID, source: .cgsFrontAppChanged)
            controller.axEventHandler.handleActivationFactsResolved(
                ActivationFacts(
                    pid: observerPID,
                    source: .cgsFrontAppChanged,
                    origin: .external,
                    observationGeneration: observationGeneration,
                    requestedAtSeq: controller.intentLedger.intent(id: request.requestId)?.issuedAtSeq ?? 0,
                    focusedWindow: nil
                )
            )
        }

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, token)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.retryCount, 0)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
    }

    func testMissingFocusedWindowFromRetryConsumesManagedFocusAttempt() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_930, windowId: 467_931)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(
            pid: token.pid,
            source: .focusedWindowChanged,
            origin: .retry
        )
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 1,
                requestedAtSeq: controller.intentLedger.intent(id: request.requestId)?.issuedAtSeq ?? 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.retryCount, 1)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
    }

    func testMissingFocusedWindowFromProbeDoesNotConsumeManagedFocusAttempt() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_932, windowId: 467_933)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(
            pid: token.pid,
            source: .focusedWindowChanged,
            origin: .probe
        )
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .probe,
                observationGeneration: 1,
                requestedAtSeq: controller.intentLedger.intent(id: request.requestId)?.issuedAtSeq ?? 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.retryCount, 0)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
    }

    func testMissingFocusedWindowFromObserverPIDAliasPreservesConfirmedManagedFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let observerPID: pid_t = 467_946
        let helperPID: pid_t = 467_947
        let windowId = 467_948
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: helperPID,
            windowId: windowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.updateIdentityAliases([
            windowId: .init(pids: [observerPID, helperPID], axRefs: [axRef])
        ])
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: observerPID, source: .focusedWindowChanged)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: observerPID,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
    }

    func testMissingFocusedWindowFromExactPIDPreservesSelectionAsExternalNativeFocus() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_949, windowId: 467_950)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: token.pid, source: .focusedWindowChanged)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: 0,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(pid: token.pid, windowId: nil)
        )
    }
}
