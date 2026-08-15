// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionPolicyTests: XCTestCase {
    func testFirstObservableAdmissionCarriesResolvedInteractionPolicy() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_090, windowId: 467_091)
        var observedPolicy: WindowInteractionPolicy?
        controller.workspaceManager.onWindowPresenceObserved = { handle in
            observedPolicy = controller.workspaceManager.entry(for: handle)?.interactionPolicy
        }

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(token.pid),
                windowId: token.windowId
            ),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            interactionPolicy: .handsOffSurface
        )

        XCTAssertEqual(observedPolicy, .handsOffSurface)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.interactionPolicy, .handsOffSurface)
    }

    func testAutomaticRuleReevaluationRefreshesInteractionPolicyWithoutReadmission() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_092, windowId: 467_093)
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating,
            interactionPolicy: .handsOffSurface
        )

        let outcome = await controller.reevaluateWindowRules(for: [.window(token)])

        XCTAssertTrue(outcome.evaluatedAnyWindow)
        XCTAssertFalse(outcome.relayoutNeeded)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.interactionPolicy, .untracked)
    }

    func testMeaningfulAdmissionFrameRejectsOneByOneProxyGeometry() {
        XCTAssertFalse(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 1, height: 400)))
        XCTAssertTrue(WMController.isMeaningfulAdmissionFrame(CGRect(x: 0, y: 0, width: 640, height: 480)))
    }

    func testExplicitUserRuleCannotBypassTilingManageability() {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_101
        let windowId = 467_102
        let windowInfo = WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let evaluation = explicitProxyEvaluation(pid: pid, windowId: windowId, windowInfo: windowInfo)

        XCTAssertTrue(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                mode: .tiling,
                windowInfo: windowInfo
            )
        )
    }

    func testNewFloatingAdmissionRejectsOneByOneProxyGeometry() {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_103
        let windowId = 467_104
        let windowInfo = WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let evaluation = explicitProxyEvaluation(
            pid: pid,
            windowId: windowId,
            windowInfo: windowInfo,
            disposition: .floating,
            isSizeSettable: false
        )

        XCTAssertTrue(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                mode: .floating,
                windowInfo: windowInfo
            )
        )
    }

    func testFixedSizeFloatingAdmissionDoesNotRequireSettableSize() {
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 467_105
        let windowId = 467_106
        let windowInfo = WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 420, height: 260)
        )
        let evaluation = explicitProxyEvaluation(
            pid: pid,
            windowId: windowId,
            windowInfo: windowInfo,
            disposition: .floating,
            isSizeSettable: false
        )

        XCTAssertFalse(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                mode: .floating,
                windowInfo: windowInfo
            )
        )
    }

    func testExistingFloatingWindowBypassesTemporaryProxyGeometry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 467_107, windowId: 467_108)
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        let windowInfo = WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let evaluation = explicitProxyEvaluation(
            pid: token.pid,
            windowId: token.windowId,
            windowInfo: windowInfo,
            disposition: .floating,
            isSizeSettable: false
        )

        XCTAssertFalse(
            controller.axEventHandler.deferAdmissionIfNeeded(
                evaluation: evaluation,
                axRef: axRef,
                token: token,
                mode: .floating,
                existingEntry: controller.workspaceManager.entry(for: token)
            )
        )
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(token.windowId)])
    }

    func testNewDegenerateFloatingAdmissionUsesBoundedCandidateRetry() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 467_109, windowId: 467_110)
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        let windowInfo = WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let evaluation = explicitProxyEvaluation(
            pid: token.pid,
            windowId: token.windowId,
            windowInfo: windowInfo,
            disposition: .floating,
            isSizeSettable: false
        )

        XCTAssertTrue(
            controller.axEventHandler.deferAdmissionIfNeeded(
                evaluation: evaluation,
                axRef: axRef,
                token: token,
                mode: .floating,
                existingEntry: nil,
                placementOrigin: .discovery
            )
        )
        let state = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(token.windowId)]
        )
        XCTAssertEqual(state.reason, .degenerateGeometry)
        XCTAssertEqual(state.attempt, 1)
        guard case let .candidate(triggerToken, _, placementOrigin) = state.trigger else {
            return XCTFail("Expected candidate retry")
        }
        XCTAssertEqual(triggerToken, token)
        XCTAssertEqual(placementOrigin, .discovery)
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: UInt32(token.windowId))
    }

    func testTraceSequenceThirteenRetriesDegenerateProxyThenRejectsMatureParentedSurface() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 86_312, windowId: 7_916)
        let windowId = try XCTUnwrap(UInt32(exactly: token.windowId))
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        let evidence = AXWindowDecisionEvidence(
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
        )
        let proxyInfo = WindowServerInfo(
            id: windowId,
            pid: token.pid,
            level: 0,
            frame: .zero,
            tags: 4_294_967_296,
            attributes: 1,
            parentId: 0
        )
        let proxyEvaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: proxyInfo,
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: false,
                frame: proxyInfo.frame
            )
        )

        XCTAssertEqual(proxyEvaluation.decision.disposition, .floating)
        XCTAssertTrue(
            controller.axEventHandler.deferAdmissionIfNeeded(
                evaluation: proxyEvaluation,
                axRef: axRef,
                token: token,
                mode: .floating,
                existingEntry: nil
            )
        )
        let retryState = try XCTUnwrap(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(retryState.reason, .degenerateGeometry)
        XCTAssertEqual(retryState.attempt, 1)
        guard case let .candidate(retryToken, _, placementOrigin) = retryState.trigger else {
            return XCTFail("Expected bounded candidate retry")
        }
        XCTAssertEqual(retryToken, token)
        XCTAssertEqual(placementOrigin, .liveCreate)

        let matureFrame = CGRect(x: 2_128, y: 126, width: 320, height: 425)
        let matureEvaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: WindowServerInfo(
                id: windowId,
                pid: token.pid,
                level: 0,
                frame: matureFrame,
                tags: 5_369_504_898,
                attributes: 3,
                parentId: 7_905
            ),
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: true,
                frame: matureFrame
            )
        )

        XCTAssertEqual(matureEvaluation.decision.disposition, .unmanaged)
        XCTAssertEqual(
            matureEvaluation.decision.source,
            .builtInRule(WindowRuleEngine.transientWidgetSurfaceRuleName)
        )
        XCTAssertNil(matureEvaluation.decision.deferredReason)
        XCTAssertNil(matureEvaluation.decision.trackedMode)
        XCTAssertEqual(matureEvaluation.decision.admissionRejectionReason, .nonRenderableTransientSurface)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: windowId)
    }

    func testManualTilePromotionDefersUnmanageableFloatingWindow() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_918
        let windowId = 467_919
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )

        XCTAssertEqual(controller.toggleFocusedWindowFloating(), .executed)

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertEqual(controller.workspaceManager.manualLayoutOverride(for: token), .forceTile)
        XCTAssertNotNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])

        XCTAssertEqual(controller.toggleFocusedWindowFloating(), .executed)

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)])
        controller.axEventHandler.handleCGSEvent(.destroyed(windowId: UInt32(windowId), spaceId: 0))
    }
}

private func explicitProxyEvaluation(
    pid: pid_t,
    windowId: Int,
    windowInfo: WindowServerInfo,
    disposition: WindowDecisionDisposition = .managed,
    isSizeSettable: Bool = true
) -> WMController.WindowDecisionEvaluation {
    let facts = WindowRuleFacts(
        appName: "Proxy",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Proxy",
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: "example.proxy",
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: windowInfo
    )
    return WMController.WindowDecisionEvaluation(
        token: WindowToken(pid: pid, windowId: windowId),
        facts: facts,
        decision: WindowDecision(
            disposition: disposition,
            source: .userRule(UUID()),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        ),
        appFullscreen: false,
        manualOverride: nil,
        admissionGeometry: WindowAdmissionGeometryEvidence(
            isSizeSettable: isSizeSettable,
            frame: windowInfo.frame
        )
    )
}
