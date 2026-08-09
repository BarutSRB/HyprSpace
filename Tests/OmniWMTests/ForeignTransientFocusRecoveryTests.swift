// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ForeignTransientFocusRecoveryTests: XCTestCase {
    func testTrackedHandsOffTargetSuppressesAXWindowCreatedRelayout() async throws {
        try await assertConcreteTargetSuppressesAXWindowCreatedRelayout(tracked: true)
    }

    func testProvisionalTargetSuppressesAXWindowCreatedRelayout() async throws {
        try await assertConcreteTargetSuppressesAXWindowCreatedRelayout(tracked: false)
    }

    func testActiveNonManagedFocusWithoutTargetRecoversRememberedMainWindow() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientNilTargetTests")

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus())
        XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(fixture.controller.workspaceManager.nonManagedFocusToken)

        assertManagedRecovery(fixture)
    }

    func testInactiveNonManagedFocusWithRetainedTargetRecoversRememberedMainWindow() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientInactiveTargetTests")
        let popupToken = WindowToken(pid: 559_002, windowId: 559_202)

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: popupToken))
        XCTAssertTrue(fixture.controller.workspaceManager.exitNonManagedFocus())
        XCTAssertFalse(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertEqual(fixture.controller.workspaceManager.nonManagedFocusToken, popupToken)

        assertManagedRecovery(fixture)
    }

    func testClosingProvisionalTargetClearsSuppressionAndRecoversRememberedMainWindow() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientProvisionalCloseTests")
        let popupToken = WindowToken(pid: 559_003, windowId: 559_203)

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: popupToken))
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(popupToken.windowId))
        )

        XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(fixture.controller.workspaceManager.nonManagedFocusToken)
        assertManagedRecovery(fixture)
    }

    func testClosingTrackedHandsOffTargetClearsSuppressionAndRecoversRememberedMainWindow() async throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientTrackedCloseTests")
        let popupToken = trackHandsOffPopup(in: fixture, pid: 559_004, windowId: 559_204)

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: popupToken))
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(popupToken.windowId))
        )

        XCTAssertNil(fixture.controller.workspaceManager.entry(for: popupToken))
        XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(fixture.controller.workspaceManager.nonManagedFocusToken)
        assertManagedRecovery(fixture)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(fixture.recorder.operations, expectedRecoveryOperations(fixture))
    }

    func testClosingOlderOverlappingTargetPreservesCurrentTargetSuppression() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientOverlappingTargetTests")
        let olderPopupToken = WindowToken(pid: 559_005, windowId: 559_205)
        let currentPopupToken = WindowToken(pid: 559_005, windowId: 559_206)

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: olderPopupToken))
        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: currentPopupToken))
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(olderPopupToken.windowId))
        )
        fixture.controller.ensureFocusedTokenValid(in: fixture.workspaceId)

        XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertEqual(fixture.controller.workspaceManager.nonManagedFocusToken, currentPopupToken)
        XCTAssertNil(fixture.controller.workspaceManager.focusedToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testAppExitPathsClearMatchingTargetAndPermitRecovery() throws {
        let deactivationFixture = try makeFixture(prefix: "OmniWMForeignTransientDeactivationTests")
        let deactivatedPopupToken = WindowToken(pid: 559_006, windowId: 559_207)
        XCTAssertTrue(
            deactivationFixture.controller.workspaceManager.enterNonManagedFocus(
                target: deactivatedPopupToken
            )
        )

        deactivationFixture.controller.axEventHandler.handleAppDeactivated(pid: deactivatedPopupToken.pid)

        XCTAssertNil(deactivationFixture.controller.workspaceManager.nonManagedFocusToken)
        assertManagedRecovery(deactivationFixture)

        let terminationFixture = try makeFixture(prefix: "OmniWMForeignTransientTerminationTests")
        let terminatedPopupToken = WindowToken(pid: 559_007, windowId: 559_208)
        XCTAssertTrue(
            terminationFixture.controller.workspaceManager.enterNonManagedFocus(
                target: terminatedPopupToken
            )
        )

        terminationFixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: terminatedPopupToken.pid
        )

        XCTAssertNil(terminationFixture.controller.workspaceManager.nonManagedFocusToken)
        assertManagedRecovery(terminationFixture)
    }

    func testCreatedFloatingFocusRejectsHandsOffSurfaceBeforeLeaseOrManagedRequest() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientCreatedFloatingTests")
        let popupToken = trackHandsOffPopup(in: fixture, pid: 559_008, windowId: 559_209)

        XCTAssertFalse(fixture.controller.windowActionHandler.focusCreatedFloatingWindow(popupToken))
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    private func assertConcreteTargetSuppressesAXWindowCreatedRelayout(
        tracked: Bool
    ) async throws {
        let fixture = try makeFixture(
            prefix: tracked
                ? "OmniWMForeignTransientTrackedRelayoutTests"
                : "OmniWMForeignTransientProvisionalRelayoutTests"
        )
        let popupToken = WindowToken(pid: 559_009, windowId: tracked ? 559_210 : 559_211)
        if tracked {
            _ = trackHandsOffPopup(
                in: fixture,
                pid: popupToken.pid,
                windowId: popupToken.windowId
            )
        }

        XCTAssertTrue(fixture.controller.workspaceManager.enterNonManagedFocus(target: popupToken))
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertTrue(fixture.controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertEqual(fixture.controller.workspaceManager.nonManagedFocusToken, popupToken)
        XCTAssertNil(fixture.controller.workspaceManager.focusedToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    private func assertManagedRecovery(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        fixture.controller.ensureFocusedTokenValid(in: fixture.workspaceId)

        XCTAssertEqual(
            fixture.recorder.operations,
            expectedRecoveryOperations(fixture),
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.token,
            fixture.mainToken,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.pendingFocusedToken,
            fixture.mainToken,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken,
            file: file,
            line: line
        )
    }

    private func expectedRecoveryOperations(_ fixture: Fixture) -> [String] {
        [
            "activate:\(fixture.mainToken.pid)",
            "focus:\(fixture.mainToken.pid):\(fixture.mainToken.windowId)",
            "raise"
        ]
    }

    private func trackHandsOffPopup(
        in fixture: Fixture,
        pid: pid_t,
        windowId: Int
    ) -> WindowToken {
        let token = fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
            pid: pid,
            windowId: windowId,
            to: fixture.workspaceId,
            mode: .floating
        )
        fixture.controller.workspaceManager.setInteractionPolicy(.handsOffSurface, for: token)
        return token
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: prefix,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in recorder.operations.append("raise") },
                orderWindow: { recorder.operations.append("order:\($0)") }
            )
        )
        let monitor = Monitor(
            id: .init(displayId: 55_901),
            displayId: 55_901,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Foreign Transient Focus"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let mainToken = WindowToken(pid: 559_001, windowId: 559_101)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: mainToken),
            pid: mainToken.pid,
            windowId: mainToken.windowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                mainToken,
                in: workspaceId,
                onMonitor: monitor.id,
                activateWorkspaceOnMonitor: false
            )
        )

        return Fixture(
            controller: controller,
            workspaceId: workspaceId,
            mainToken: mainToken,
            recorder: recorder
        )
    }

    private final class FocusRecorder: @unchecked Sendable {
        var operations: [String] = []
    }

    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let mainToken: WindowToken
        let recorder: FocusRecorder
    }
}
