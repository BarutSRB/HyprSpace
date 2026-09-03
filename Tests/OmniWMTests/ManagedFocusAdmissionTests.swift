// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ManagedFocusAdmissionTests: XCTestCase {
    func testFocusOnlySessionChangesRequestBorderSurfaceInvalidation() {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.workspaceManager
        let token = WindowToken(pid: 467_001, windowId: 467_002)
        var scopes: [SessionSurfaceInvalidationScope] = []
        manager.onSessionStateChanged = { scopes.append($0) }

        XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId))
        manager.suppressFocusBorder(for: token)
        manager.setSystemModalFocus(token)
        XCTAssertTrue(manager.recordOwnedSurfaceFocus())
        XCTAssertTrue(manager.clearNativeFocusOwner())

        XCTAssertEqual(scopes, [.border, .border, .border, .border, .border])
    }

    func testUnexpectedActivationPreservesManagedSelectionBeforeFactResolution() throws {
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

        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
    }

    func testConflictingExternalActivationCancelsPendingRequestAndPreservesSelection() throws {
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
        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
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
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
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

        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
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

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, secondToken)
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)
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

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, modalToken)
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

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, frontmostToken)
        XCTAssertNil(controller.workspaceManager.systemModalFocusToken)
        XCTAssertTrue(operations.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
    }

    func testTraceShapedExternalDecisionPreservesSelectedParentBorderTarget() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let parentToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(10_763), windowId: 3_128),
            pid: 10_763,
            windowId: 3_128,
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
        let managedWorld = WorldView(controller: controller, liveBoundsProvider: { windowId in
            windowId == parentToken.windowId ? parentFrame : nil
        })
        XCTAssertEqual(SurfaceDerivation.deriveBorder(world: managedWorld)?.token, parentToken)

        let token = WindowToken(pid: 10_763, windowId: 3_260)
        let popupFrame = CGRect(x: 2_128, y: 126, width: 280, height: 40)
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: AXWindowDecisionEvidence(
                facts: AXWindowFacts(
                    role: "AXPopover",
                    subrole: kAXUnknownSubrole as String,
                    title: "Firefox transient",
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: false,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: .regular,
                    bundleId: "org.mozilla.firefox",
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
        XCTAssertEqual(rejectionReason, .externalSurface)
        XCTAssertFalse(WindowAdmissionPendingReason.windowServerEvidenceMissing.hasVerifiedExternalWindowIdentity)
        XCTAssertTrue(WindowAdmissionPendingReason.factsDeferred.hasVerifiedExternalWindowIdentity)

        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: token.pid,
                windowId: token.windowId,
                verifiedManagedParentToken: parentToken
            )
        )
        XCTAssertTrue(controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, token)
        XCTAssertEqual(
            controller.workspaceManager.externalFocusIdentity?.verifiedManagedParentToken,
            parentToken
        )
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, parentToken)
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(
                pid: token.pid,
                windowId: token.windowId,
                verifiedManagedParentToken: parentToken
            )
        )
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
        XCTAssertEqual(controller.workspaceManager.borderFocusToken, parentToken)
        XCTAssertFalse(controller.isSystemModalFocusActive)
        let externalWorld = WorldView(controller: controller, liveBoundsProvider: { windowId in
            windowId == parentToken.windowId ? parentFrame : nil
        })
        XCTAssertEqual(SurfaceDerivation.deriveBorder(world: externalWorld)?.token, parentToken)
    }

    func testExternalFocusRejectsManagedParentThatDoesNotMatchSelection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let selectedToken = WindowToken(pid: 468_101, windowId: 468_102)
        let otherToken = WindowToken(pid: 468_103, windowId: 468_104)
        _ = WindowAdmissionTestSupport.track(selectedToken, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(otherToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                selectedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let externalToken = WindowToken(pid: 468_105, windowId: 468_106)

        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: externalToken.pid,
                windowId: externalToken.windowId,
                verifiedManagedParentToken: otherToken
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, selectedToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, externalToken)
        XCTAssertNil(controller.workspaceManager.externalFocusIdentity?.verifiedManagedParentToken)
        XCTAssertNil(controller.workspaceManager.renderableFocusToken)
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
    }

    func testPIDOnlyExternalFocusDowngradeClearsParentContinuity() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let parentToken = WindowToken(pid: 468_111, windowId: 468_112)
        _ = WindowAdmissionTestSupport.track(parentToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parentToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let externalToken = WindowToken(pid: 468_111, windowId: 468_113)
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: externalToken.pid,
                windowId: externalToken.windowId,
                verifiedManagedParentToken: parentToken
            )
        )
        XCTAssertEqual(controller.workspaceManager.borderFocusToken, parentToken)

        controller.workspaceManager.clearExternalFocusIdentity(matching: externalToken)

        XCTAssertNil(controller.workspaceManager.externalFocusToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusIdentity?.pid, externalToken.pid)
        XCTAssertNil(controller.workspaceManager.externalFocusIdentity?.verifiedManagedParentToken)
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
    }

    func testParentRemovalClearsExternalFocusContinuity() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let parentToken = WindowToken(pid: 468_121, windowId: 468_122)
        _ = WindowAdmissionTestSupport.track(parentToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parentToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let externalToken = WindowToken(pid: 468_121, windowId: 468_123)
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: externalToken.pid,
                windowId: externalToken.windowId,
                verifiedManagedParentToken: parentToken
            )
        )

        XCTAssertNotNil(
            controller.workspaceManager.removeWindow(
                pid: parentToken.pid,
                windowId: parentToken.windowId
            )
        )

        XCTAssertNil(controller.workspaceManager.selectedManagedToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, externalToken)
        XCTAssertNil(controller.workspaceManager.externalFocusIdentity?.verifiedManagedParentToken)
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
    }

    func testParentRekeyClearsExternalFocusContinuityUntilFreshEvidence() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let parentToken = WindowToken(pid: 468_131, windowId: 468_132)
        let replacementToken = WindowToken(pid: 468_131, windowId: 468_133)
        _ = WindowAdmissionTestSupport.track(parentToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parentToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let externalToken = WindowToken(pid: 468_131, windowId: 468_134)
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: externalToken.pid,
                windowId: externalToken.windowId,
                verifiedManagedParentToken: parentToken
            )
        )

        XCTAssertNotNil(
            controller.workspaceManager.rekeyWindow(
                from: parentToken,
                to: replacementToken,
                newAXRef: WindowAdmissionTestSupport.axRef(for: replacementToken)
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, replacementToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, externalToken)
        XCTAssertNil(controller.workspaceManager.externalFocusIdentity?.verifiedManagedParentToken)
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
    }

    func testUnverifiedAndOwnedExternalFocusRemainBorderless() {
        let controller = WindowAdmissionTestSupport.controller()
        let world = WorldView(controller: controller, liveBoundsProvider: { _ in
            CGRect(x: 40, y: 40, width: 800, height: 600)
        })

        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: 468_201, windowId: 468_202))
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))

        XCTAssertTrue(controller.workspaceManager.recordOwnedSurfaceFocus())
        XCTAssertNil(controller.workspaceManager.borderFocusToken)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
    }

    func testVerifiedParentContinuityRetainsSuppressionModalAndHiddenGates() throws {
        let suppressed = try makeParentContinuityFixture(pid: 468_210)
        suppressed.controller.workspaceManager.suppressFocusBorder(for: suppressed.parent)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(suppressed)))

        let modal = try makeParentContinuityFixture(pid: 468_220)
        modal.controller.workspaceManager.setSystemModalFocus(modal.parent)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(modal)))

        let hidden = try makeParentContinuityFixture(pid: 468_230)
        hidden.controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .scratchpad),
            for: hidden.parent
        )
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(hidden)))
    }

    func testVerifiedParentContinuityRemainsBorderlessOnInactiveWorkspace() throws {
        let fixture = try makeParentContinuityFixture(pid: 468_240)
        _ = fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        XCTAssertTrue(
            fixture.controller.workspaceManager.confirmManagedFocus(
                fixture.parent,
                in: fixture.workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: fixture.child.pid,
                windowId: fixture.child.windowId,
                verifiedManagedParentToken: fixture.parent
            )
        )

        XCTAssertEqual(fixture.controller.workspaceManager.borderFocusToken, fixture.parent)
        XCTAssertFalse(fixture.controller.workspaceManager.visibleWorkspaceIds().contains(fixture.workspaceId))
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(fixture)))
    }

    func testVerifiedParentContinuityRemainsBorderlessInLayoutFullscreen() throws {
        let fixture = try makeParentContinuityFixture(pid: 468_250)
        fixture.controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        fixture.controller.workspaceManager.withEngineMutationScope {
            let node = engine.addWindow(
                token: fixture.parent,
                to: fixture.workspaceId,
                afterSelection: nil
            )
            var state = ViewportState()
            engine.toggleFullscreen(node, motion: .disabled, state: &state)
        }

        XCTAssertTrue(engine.isWindowFullscreen(fixture.parent, in: fixture.workspaceId))
        XCTAssertEqual(fixture.controller.workspaceManager.borderFocusToken, fixture.parent)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(fixture)))
    }

    func testBackgroundFocusedWindowChangeRequiresMouseAuthorityBeforeMutation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let frontmostToken = WindowToken(pid: 468_001, windowId: 468_002)
        let backgroundToken = WindowToken(pid: 468_003, windowId: 468_004)
        _ = WindowAdmissionTestSupport.track(frontmostToken, in: workspaceId, controller: controller)
        let backgroundRef = WindowAdmissionTestSupport.track(
            backgroundToken,
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
        var requestedPIDs: [pid_t] = []
        controller.factResolver.factProvider = { pid in
            requestedPIDs.append(pid)
            return nil
        }
        controller.axEventHandler.frontmostApplicationPIDProvider = { frontmostToken.pid }
        controller.hasStartedServices = true

        _ = controller.axEventHandler.handleAppActivation(
            pid: frontmostToken.pid,
            source: .workspaceDidActivateApplication
        )
        XCTAssertFalse(
            controller.axEventHandler.handleAppActivation(
                pid: backgroundToken.pid,
                source: .focusedWindowChanged
            )
        )

        XCTAssertEqual(requestedPIDs, [frontmostToken.pid])
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, frontmostToken)
        XCTAssertFalse(controller.workspaceManager.nativeFocusOwner.isExternal)

        controller.axEventHandler.noteMouseFocusIntent(token: backgroundToken)
        _ = controller.axEventHandler.handleAppActivation(
            pid: backgroundToken.pid,
            source: .focusedWindowChanged
        )
        XCTAssertEqual(requestedPIDs, [frontmostToken.pid, backgroundToken.pid])
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: backgroundToken.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 2,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: backgroundRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, backgroundToken)
    }

    func testFocusedWindowFactsAreRejectedIfNativeFrontmostEvidenceChangesDuringResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 468_011
        let originalToken = WindowToken(pid: pid, windowId: 468_012)
        let staleToken = WindowToken(pid: pid, windowId: 468_013)
        _ = WindowAdmissionTestSupport.track(originalToken, in: workspaceId, controller: controller)
        let staleRef = WindowAdmissionTestSupport.track(staleToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                originalToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var frontmostPID = pid
        controller.axEventHandler.frontmostApplicationPIDProvider = { frontmostPID }
        controller.factResolver.factProvider = { _ in nil }
        controller.hasStartedServices = true
        _ = controller.axEventHandler.handleAppActivation(
            pid: pid,
            source: .workspaceDidActivateApplication
        )
        _ = controller.axEventHandler.handleAppActivation(
            pid: pid,
            source: .focusedWindowChanged
        )

        frontmostPID = 468_014
        controller.axEventHandler.latestNativeActivationPID = frontmostPID
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 2,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: staleRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, originalToken)
    }

    func testBackgroundFocusedWindowChangeRequiresExactManagedFocusRequestAtFactResolution() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let frontmostToken = WindowToken(pid: 468_021, windowId: 468_022)
        let requestedToken = WindowToken(pid: 468_023, windowId: 468_024)
        let staleSiblingToken = WindowToken(pid: requestedToken.pid, windowId: 468_025)
        _ = WindowAdmissionTestSupport.track(frontmostToken, in: workspaceId, controller: controller)
        let requestedRef = WindowAdmissionTestSupport.track(
            requestedToken,
            in: workspaceId,
            controller: controller
        )
        let staleSiblingRef = WindowAdmissionTestSupport.track(
            staleSiblingToken,
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
        var requestedPIDs: [pid_t] = []
        controller.factResolver.factProvider = { pid in
            requestedPIDs.append(pid)
            return nil
        }
        controller.hasStartedServices = true
        _ = controller.axEventHandler.handleAppActivation(
            pid: frontmostToken.pid,
            source: .workspaceDidActivateApplication
        )
        let request = controller.intentLedger.beginManagedRequest(
            token: requestedToken,
            workspaceId: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.beginManagedFocusRequest(
                requestedToken,
                in: workspaceId,
                requestId: request.requestId
            )
        )

        _ = controller.axEventHandler.handleAppActivation(
            pid: requestedToken.pid,
            source: .focusedWindowChanged
        )
        XCTAssertEqual(requestedPIDs, [frontmostToken.pid, requestedToken.pid])
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: requestedToken.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 2,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: staleSiblingRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, frontmostToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, requestedToken)

        _ = controller.axEventHandler.handleAppActivation(
            pid: requestedToken.pid,
            source: .focusedWindowChanged
        )
        XCTAssertEqual(requestedPIDs, [frontmostToken.pid, requestedToken.pid, requestedToken.pid])
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: requestedToken.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 3,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: requestedRef,
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, requestedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
    }

    private typealias ParentContinuityFixture = (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        parent: WindowToken,
        child: WindowToken,
        frame: CGRect
    )

    private func makeParentContinuityFixture(pid: pid_t) throws -> ParentContinuityFixture {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let parent = WindowToken(pid: pid, windowId: Int(pid) + 1)
        let child = WindowToken(pid: pid, windowId: Int(pid) + 2)
        _ = WindowAdmissionTestSupport.track(parent, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                parent,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: child.pid,
                windowId: child.windowId,
                verifiedManagedParentToken: parent
            )
        )
        let fixture = (
            controller: controller,
            workspaceId: workspaceId,
            parent: parent,
            child: child,
            frame: CGRect(x: 80, y: 90, width: 900, height: 640)
        )
        XCTAssertNotNil(SurfaceDerivation.deriveBorder(world: parentContinuityWorld(fixture)))
        return fixture
    }

    private func parentContinuityWorld(_ fixture: ParentContinuityFixture) -> WorldView {
        WorldView(controller: fixture.controller, liveBoundsProvider: { windowId in
            windowId == fixture.parent.windowId ? fixture.frame : nil
        })
    }
}
