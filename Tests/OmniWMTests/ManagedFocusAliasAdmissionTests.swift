// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAliasAdmissionTests: XCTestCase {
    func testSameAppCausalityUsesAdmittedAndRecordedIdentitiesWithoutWindowQueries() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let logicalPID: pid_t = 814_001
        let axPID: pid_t = 814_002
        let previousPID: pid_t = 814_003
        let currentPID: pid_t = 814_004
        let unknownPID: pid_t = 814_005
        let windowId = 814_006
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(axPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(axRef, pid: logicalPID, windowId: windowId, to: workspaceId)
        controller.axEventHandler.updateIdentityAliases([windowId: .init(pids: [previousPID], axRefs: [])])
        controller.axEventHandler.updateIdentityAliases([windowId: .init(pids: [currentPID], axRefs: [])])
        var queries = 0
        controller.axEventHandler.windowInfoProvider = {
            queries += 1
            return WindowServerInfo(id: $0, pid: unknownPID, level: 0, frame: .zero)
        }

        for pid in [logicalPID, axPID, previousPID, currentPID] {
            let causality = controller.axEventHandler.sameAppFocusCausality(
                pid: pid, source: .focusedWindowChanged, origin: .external, focusedToken: token
            )
            XCTAssertEqual(causality?.focusedToken, token)
            XCTAssertEqual(causality?.workspaceId, workspaceId)
        }
        XCTAssertNil(controller.axEventHandler.sameAppFocusCausality(
            pid: unknownPID, source: .focusedWindowChanged, origin: .external, focusedToken: token
        ))
        _ = controller.workspaceManager.removeWindow(pid: logicalPID, windowId: windowId)
        XCTAssertNil(controller.axEventHandler.sameAppFocusCausality(
            pid: logicalPID, source: .focusedWindowChanged, origin: .external, focusedToken: token
        ))
        XCTAssertEqual(queries, 0)
    }

    func testFocusedWindowIntakeAvoidsLiveIdentityQueriesForUnrelatedPendingFocus() throws {
        for origin in [ActivationCallOrigin.external, .probe, .retry] {
            let controller = WindowAdmissionTestSupport.controller()
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            let token = WindowToken(pid: 814_011, windowId: 814_012)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
            _ = controller.workspaceManager.beginManagedFocusRequest(
                token,
                in: workspaceId,
                requestId: request.requestId
            )
            var queries = 0
            var resolvedPIDs: [pid_t] = []
            controller.axEventHandler.windowInfoProvider = { _ in
                queries += 1
                return nil
            }
            controller.factResolver.factProvider = {
                resolvedPIDs.append($0)
                return nil
            }
            controller.hasStartedServices = true
            defer { controller.hasStartedServices = false }

            controller.axEventHandler.handleAppActivation(pid: 814_013, source: .focusedWindowChanged, origin: origin)

            XCTAssertEqual(queries, 0)
            XCTAssertEqual(resolvedPIDs, [814_013])
            XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
            XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        }
    }

    func testExternalAppSwitchRetainsLiveIdentityAuthority() throws {
        for source in [ActivationEventSource.workspaceDidActivateApplication, .cgsFrontAppChanged] {
            for matchesLiveIdentity in [true, false] {
                let controller = WindowAdmissionTestSupport.controller()
                let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(
                    for: "1",
                    createIfMissing: true
                ))
                let token = WindowToken(pid: 814_021, windowId: 814_022)
                let observedPID: pid_t = 814_023
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
                let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
                _ = controller.workspaceManager.beginManagedFocusRequest(
                    token,
                    in: workspaceId,
                    requestId: request.requestId
                )
                var queries = 0
                controller.axEventHandler.windowInfoProvider = {
                    queries += 1
                    return matchesLiveIdentity ? WindowServerInfo(id: $0, pid: observedPID, level: 0, frame: .zero) :
                        nil
                }
                controller.factResolver.factProvider = { _ in nil }
                controller.hasStartedServices = true
                defer { controller.hasStartedServices = false }

                controller.axEventHandler.handleAppActivation(pid: observedPID, source: source)

                XCTAssertEqual(queries, 1)
                if matchesLiveIdentity {
                    XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
                    XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
                } else {
                    XCTAssertNil(controller.intentLedger.activeManagedRequest)
                    XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
                    XCTAssertEqual(
                        controller.workspaceManager.nativeFocusOwner,
                        .external(pid: observedPID, windowId: nil)
                    )
                }
            }
        }
    }

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
