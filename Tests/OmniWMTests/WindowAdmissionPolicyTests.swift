// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionPolicyTests: XCTestCase {
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
                windowInfo: windowInfo,
                trackedMode: .tiling
            )
        )
    }

    func testDegenerateFloatingWindowIsNotAdmitted() {
        // A menu-bar app's invisible helper window (BetterDisplay parks a 1x1 window off the bottom
        // of the screen) classifies as floating, because an accessory app's window without a close
        // button floats. Geometry has to keep it out: admitting it puts a workspace-bar entry there
        // that opens nothing, and focus landing on it bounces straight back to the previous window.
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 468_101
        let windowId = 468_102
        let windowInfo = WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: CGRect(x: 0, y: 1889, width: 1, height: 1)
        )
        let evaluation = accessoryHelperEvaluation(
            pid: pid,
            windowId: windowId,
            windowInfo: windowInfo,
            frame: windowInfo.frame
        )

        XCTAssertEqual(
            AXWindowService.heuristicDisposition(for: evaluation.facts.ax).disposition,
            .floating,
            "precondition: the classifier floats this window, so only geometry can keep it out"
        )
        XCTAssertTrue(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                windowInfo: windowInfo,
                trackedMode: .floating
            )
        )
    }

    func testFixedSizeFloatingWindowIsStillAdmitted() {
        // The geometry gate must not swallow ordinary floating windows, including ones that refuse
        // to be resized - unlike tiling, floating admission does not require a settable size.
        let controller = WindowAdmissionTestSupport.controller()
        let pid: pid_t = 468_201
        let windowId = 468_202
        let frame = CGRect(x: 120, y: 80, width: 420, height: 260)
        let windowInfo = WindowServerInfo(id: UInt32(windowId), pid: pid, level: 0, frame: frame)
        var evaluation = accessoryHelperEvaluation(
            pid: pid,
            windowId: windowId,
            windowInfo: windowInfo,
            frame: frame
        )
        evaluation = WMController.WindowDecisionEvaluation(
            token: evaluation.token,
            facts: evaluation.facts,
            decision: evaluation.decision,
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: WindowAdmissionGeometryEvidence(isSizeSettable: false, frame: frame)
        )

        XCTAssertFalse(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                windowInfo: windowInfo,
                trackedMode: .floating
            )
        )
        XCTAssertTrue(
            controller.shouldDeferAdmission(
                evaluation: evaluation,
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                windowInfo: windowInfo,
                trackedMode: .tiling
            ),
            "the same window still cannot be tiled, because it refuses a size"
        )
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

/// Mirrors what the AX layer reports for a menu-bar app's helper window: an accessory-policy
/// process, `AXUnknown` subrole, and every window button absent.
private func accessoryHelperEvaluation(
    pid: pid_t,
    windowId: Int,
    windowInfo: WindowServerInfo,
    frame: CGRect
) -> WMController.WindowDecisionEvaluation {
    let facts = WindowRuleFacts(
        appName: "BetterDisplay",
        ax: AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: "AXUnknown",
            title: nil,
            hasCloseButton: false,
            hasFullscreenButton: false,
            fullscreenButtonEnabled: nil,
            hasZoomButton: false,
            hasMinimizeButton: false,
            appPolicy: .accessory,
            bundleId: "pro.betterdisplay.BetterDisplay",
            attributeFetchSucceeded: true
        ),
        sizeConstraints: nil,
        windowServer: windowInfo
    )
    return WMController.WindowDecisionEvaluation(
        token: WindowToken(pid: pid, windowId: windowId),
        facts: facts,
        decision: WindowDecision(
            disposition: .floating,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [.accessoryWithoutClose],
            deferredReason: nil
        ),
        appFullscreen: false,
        manualOverride: nil,
        admissionGeometry: WindowAdmissionGeometryEvidence(isSizeSettable: true, frame: frame)
    )
}

private func explicitProxyEvaluation(
    pid: pid_t,
    windowId: Int,
    windowInfo: WindowServerInfo
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
            disposition: .managed,
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
            isSizeSettable: true,
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
    )
}
