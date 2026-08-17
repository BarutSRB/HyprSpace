// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAdmissionTests: XCTestCase {
    func testUnexpectedActivationClearsManagedCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_211), windowId: 467_221),
            pid: 467_211,
            windowId: 467_221,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: 467_212, source: .cgsFrontAppChanged)

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testConflictingExternalActivationCancelsPendingCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(467_901), windowId: 467_902),
            pid: 467_901,
            windowId: 467_902,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: token.pid + 1, source: .cgsFrontAppChanged)

        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testKnownAXPidAliasPreservesPendingCommandTargetBeforeFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_903
        let axPID: pid_t = 467_904
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(axPID), windowId: 467_905),
            pid: logicalPID,
            windowId: 467_905,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true

        controller.axEventHandler.handleAppActivation(pid: axPID, source: .cgsFrontAppChanged)

        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, token)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }

    func testSupersededActivationFactsCannotRestoreStaleCommandTarget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let managedPID: pid_t = 467_911
        let externalPID: pid_t = 467_912
        let windowId = 467_913
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(managedPID), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: managedPID,
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
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: managedPID, source: .cgsFrontAppChanged)
        controller.axEventHandler.handleAppActivation(pid: externalPID, source: .cgsFrontAppChanged)

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: managedPID,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 1,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: axRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.focusedToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testStaleFocusedRetryCannotSupersedeNewerExternalActivation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let firstPID: pid_t = 467_914
        let secondPID: pid_t = 467_915
        let firstToken = WindowToken(pid: firstPID, windowId: 467_916)
        let secondToken = WindowToken(pid: secondPID, windowId: 467_917)
        _ = WindowAdmissionTestSupport.track(firstToken, in: workspaceId, controller: controller)
        let secondAXRef = WindowAdmissionTestSupport.track(secondToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                firstToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: firstPID, source: .cgsFrontAppChanged)
        controller.axEventHandler.handleAppActivation(pid: secondPID, source: .cgsFrontAppChanged)

        controller.axEventHandler.handleAppActivation(
            pid: firstPID,
            source: .focusedWindowChanged,
            origin: .retry,
            causalObservationGeneration: 1
        )
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: secondPID,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 2,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: secondAXRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, secondToken)
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
    }

    func testStaleFocusedRetryRetiresBeforeFocusPolicySuppression() {
        let controller = WindowAdmissionTestSupport.controller()
        let stalePID: pid_t = 467_920
        let currentPID: pid_t = 467_921
        let windowId: UInt32 = 467_922
        let token = WindowToken(pid: stalePID, windowId: Int(windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(stalePID), windowId: token.windowId)
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        controller.axEventHandler.handleAppActivation(pid: stalePID, source: .focusedWindowChanged)
        controller.axEventHandler.handleAppActivation(pid: currentPID, source: .focusedWindowChanged)
        XCTAssertTrue(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: .focused(
                    token: token,
                    source: .workspaceDidActivateApplication,
                    observationGeneration: 1,
                    callbackGeneration: nil
                )
            )
        )
        controller.focusPolicyEngine.beginLease(
            owner: .nativeMenu,
            reason: "test",
            duration: nil
        )

        controller.axEventHandler.handleAppActivation(
            pid: stalePID,
            source: .workspaceDidActivateApplication,
            origin: .retry,
            causalObservationGeneration: 1
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
    }

    func testFrontmostRetriedAuthoritativeSystemModalUsesFocusNeutralOrdering() throws {
        var operations: [String] = []
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMRetriedSystemModalOrderingTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations.append("activate") },
                focusSpecificWindow: { _, _, _ in operations.append("focus") },
                raiseWindow: { _ in operations.append("raise") },
                orderWindow: { operations.append("order:\($0)") }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let previousToken = WindowToken(pid: 467_923, windowId: 467_924)
        let modalToken = WindowToken(pid: previousToken.pid, windowId: 467_925)
        _ = WindowAdmissionTestSupport.track(previousToken, in: workspaceId, controller: controller)
        let modalRef = WindowAdmissionTestSupport.track(
            modalToken,
            in: workspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                previousToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.frontmostApplicationPIDProvider = { modalToken.pid }
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: modalToken.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: modalRef,
                    isFullscreen: false,
                    isSystemModalSurface: true
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, modalToken)
        XCTAssertEqual(controller.workspaceManager.systemModalFocusToken, modalToken)
        XCTAssertEqual(operations, ["order:\(modalToken.windowId)"])
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)

        operations.removeAll()
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: modalToken))
        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: .focusedWindowChanged,
            origin: .external
        )
        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: .workspaceDidActivateApplication,
            origin: .retry
        )

        XCTAssertTrue(operations.isEmpty)
    }

    func testBackgroundRetriedAuthoritativeSystemModalDoesNotMutateFocusOrOrder() throws {
        var operations: [String] = []
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMBackgroundRetriedSystemModalTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations.append("activate") },
                focusSpecificWindow: { _, _, _ in operations.append("focus") },
                raiseWindow: { _ in operations.append("raise") },
                orderWindow: { _ in operations.append("order") }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let frontmostToken = WindowToken(pid: 467_926, windowId: 467_927)
        let backgroundModalToken = WindowToken(pid: 467_928, windowId: 467_929)
        _ = WindowAdmissionTestSupport.track(frontmostToken, in: workspaceId, controller: controller)
        let backgroundModalRef = WindowAdmissionTestSupport.track(
            backgroundModalToken,
            in: workspaceId,
            controller: controller
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                frontmostToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.frontmostApplicationPIDProvider = { frontmostToken.pid }
        controller.hasStartedServices = true

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: backgroundModalToken.pid,
                source: .focusedWindowChanged,
                origin: .retry,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: backgroundModalRef,
                    isFullscreen: false,
                    isSystemModalSurface: true
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, frontmostToken)
        XCTAssertNil(controller.workspaceManager.systemModalFocusToken)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
    }

    func testTraceShapedTransientDecisionSuppressesRenderableFocusTargetAndBorder() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(86_312), windowId: 7_905),
            pid: 86_312,
            windowId: 7_905,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parentToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let parentFrame = CGRect(x: 1_280, y: 70, width: 1_200, height: 1_350)
        let managedWorld = WorldView(controller: controller, borderFrameResolver: { windowId in
            windowId == parentToken.windowId ? parentFrame : nil
        })
        XCTAssertNotNil(SurfaceDerivation.deriveBorder(world: managedWorld))

        let token = WindowToken(pid: 86_312, windowId: 7_916)
        let popupFrame = CGRect(x: 2_128, y: 126, width: 320, height: 425)
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: AXWindowDecisionEvidence(
                facts: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXUnknownSubrole as String,
                    title: "Extension",
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: .regular,
                    bundleId: "com.google.Chrome",
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: WindowSizeConstraints(
                    minSize: CGSize(width: 100, height: 100),
                    maxSize: .zero,
                    isFixed: false
                )
            ),
            appFullscreen: false,
            windowInfo: WindowServerInfo(
                id: UInt32(token.windowId),
                pid: token.pid,
                level: 0,
                frame: popupFrame,
                tags: 5_369_504_898,
                attributes: 3,
                parentId: UInt32(parentToken.windowId)
            ),
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: true,
                frame: popupFrame
            )
        )
        let rejectionReason = evaluation.decision.admissionRejectionReason

        XCTAssertEqual(evaluation.decision.disposition, .unmanaged)
        XCTAssertEqual(rejectionReason, .nonRenderableTransientSurface)
        XCTAssertTrue(WindowAdmissionPendingReason.windowServerEvidenceMissing.suppressesNonManagedFocusTarget)
        XCTAssertFalse(WindowAdmissionPendingReason.factsDeferred.suppressesNonManagedFocusTarget)
        XCTAssertTrue(rejectionReason.suppressesNonManagedFocusTarget)
        XCTAssertFalse(WindowAdmissionRejectionReason.policyIgnored.suppressesNonManagedFocusTarget)

        XCTAssertTrue(
            controller.workspaceManager.enterNonManagedFocus(
                target: rejectionReason.suppressesNonManagedFocusTarget ? nil : token
            )
        )
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.nonManagedFocusToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
        let nonManagedWorld = WorldView(controller: controller, borderFrameResolver: { _ in popupFrame })
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: nonManagedWorld))
    }
}
