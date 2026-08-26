// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class OrderedOutWindowRetirementTests: XCTestCase {
    func testExhaustedFocusActivationRescansTheOwningApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_001), windowId: 913_101),
            pid: 913_001,
            windowId: 913_101,
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
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        // The window is gone but the app still runs, so every focus attempt finds no window.
        for _ in 0 ... AXEventHandler.activationRetryLimit {
            controller.axEventHandler.handleActivationFactsResolved(
                ActivationFacts(
                    pid: token.pid,
                    source: .focusedWindowChanged,
                    origin: .retry,
                    observationGeneration: 0,
                    requestedAtSeq: UInt64.max,
                    focusedWindow: nil
                )
            )
        }

        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testFrontmostAppLosingItsFocusedWindowRescansThatApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_002), windowId: 913_102),
            pid: 913_002,
            windowId: 913_102,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        // The app keeps focus and loses its window, so the focused token never changes.
        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.focusedToken, token)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }
}
