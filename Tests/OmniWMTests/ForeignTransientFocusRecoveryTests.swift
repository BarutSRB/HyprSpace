// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
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

        XCTAssertEqual(
            fixture.controller.windowActionHandler.focusCreatedFloatingWindow(popupToken),
            .rejected
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testCreatedFloatingFocusRejectsSystemModalBeforeLeaseOrManagedRequest() throws {
        let fixture = try makeFixture(prefix: "OmniWMSystemModalCreatedFloatingTests")
        let popupToken = WindowToken(pid: 559_013, windowId: 559_217)
        _ = trackFloatingWindow(
            in: fixture,
            token: popupToken,
            subrole: kAXSystemDialogSubrole as String,
            windowLevel: 3
        )

        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: popupToken))
        XCTAssertEqual(
            fixture.controller.windowActionHandler.focusCreatedFloatingWindow(popupToken),
            .systemModalBarrier
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testSystemModalAdmissionSchedulesFocusNeutralRelayout() throws {
        let fixture = try makeFixture(prefix: "OmniWMSystemModalAdmissionBarrierTests")
        defer { fixture.controller.layoutRefreshController.resetState() }
        let popupToken = WindowToken(pid: 559_016, windowId: 559_222)
        let axRef = WindowAdmissionTestSupport.axRef(for: popupToken)

        fixture.controller.axEventHandler.trackPreparedCreate(
            .init(
                windowId: UInt32(popupToken.windowId),
                token: popupToken,
                axRef: axRef,
                ruleEffects: .none,
                admissionHints: .none,
                replacementMetadata: .init(
                    bundleId: "Cisco-Systems.Spark",
                    workspaceId: fixture.workspaceId,
                    mode: .floating,
                    role: kAXWindowRole as String,
                    subrole: kAXSystemDialogSubrole as String,
                    title: nil,
                    windowLevel: 3,
                    parentWindowId: nil,
                    frame: CGRect(x: 0, y: 0, width: 280, height: 239),
                    transientWindowServerEvidence: false
                ),
                structuralReplacementMatch: nil,
                requiresPostCreateLifecycleVerification: false,
                interactionPolicy: .full
            )
        )

        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: popupToken))
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, fixture.mainToken)
        XCTAssertTrue(
            try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh
            ).suppressesWindowActivation
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testFocusNeutralRefreshMetadataClearsAutomaticRecovery() throws {
        let fixture = try makeFixture(prefix: "OmniWMSystemModalRefreshMetadataTests")
        var plan = EffectPlan()
        plan.effects.focusValidationWorkspaceIds = [fixture.workspaceId]
        plan.effects.focusValidationPreferredTokens[fixture.workspaceId] = fixture.mainToken

        fixture.controller.layoutRefreshController.applyRefreshMetadata(
            .init(
                kind: .relayout,
                reason: .axWindowCreated,
                suppressesWindowActivation: true
            ),
            to: &plan
        )

        XCTAssertTrue(plan.effects.suppressWindowActivation)
        XCTAssertTrue(plan.effects.focusValidationWorkspaceIds.isEmpty)
        XCTAssertTrue(plan.effects.focusValidationPreferredTokens.isEmpty)
    }

    func testCreatedFloatingFocusDoesNotDisplaceFocusedSystemModal() throws {
        let fixture = try makeFixture(prefix: "OmniWMFocusedSystemModalCreatedFloatingTests")
        let modalToken = WindowToken(pid: 559_014, windowId: 559_218)
        let floatingToken = WindowToken(pid: modalToken.pid, windowId: 559_219)
        _ = trackFloatingWindow(
            in: fixture,
            token: modalToken,
            subrole: kAXSystemDialogSubrole as String,
            windowLevel: 3
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.confirmManagedFocus(
                modalToken,
                in: fixture.workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        fixture.controller.workspaceManager.setSystemModalFocus(modalToken)
        _ = trackFloatingWindow(
            in: fixture,
            token: floatingToken,
            subrole: kAXStandardWindowSubrole as String,
            windowLevel: 0
        )

        XCTAssertTrue(fixture.controller.isSystemModalFocusActive)
        XCTAssertEqual(
            fixture.controller.windowActionHandler.focusCreatedFloatingWindow(floatingToken),
            .systemModalBarrier
        )
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, modalToken)
        XCTAssertEqual(fixture.controller.workspaceManager.systemModalFocusToken, modalToken)
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testCreatedFloatingFocusIgnoresStaleSystemModalMarker() throws {
        let fixture = try makeFixture(prefix: "OmniWMStaleSystemModalCreatedFloatingTests")
        let modalToken = WindowToken(pid: 559_015, windowId: 559_220)
        let floatingToken = WindowToken(pid: modalToken.pid, windowId: 559_221)
        _ = trackFloatingWindow(
            in: fixture,
            token: modalToken,
            subrole: kAXSystemDialogSubrole as String,
            windowLevel: 3
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.confirmManagedFocus(
                modalToken,
                in: fixture.workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        fixture.controller.workspaceManager.setSystemModalFocus(modalToken)
        XCTAssertTrue(
            fixture.controller.workspaceManager.confirmManagedFocus(
                fixture.mainToken,
                in: fixture.workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        _ = trackFloatingWindow(
            in: fixture,
            token: floatingToken,
            subrole: kAXStandardWindowSubrole as String,
            windowLevel: 0
        )

        XCTAssertFalse(fixture.controller.isSystemModalFocusActive)
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, fixture.mainToken)
        XCTAssertEqual(fixture.controller.workspaceManager.systemModalFocusToken, modalToken)
        XCTAssertEqual(
            fixture.controller.windowActionHandler.focusCreatedFloatingWindow(floatingToken),
            .focused
        )
        XCTAssertEqual(
            fixture.recorder.operations,
            [
                "order:\(floatingToken.windowId)",
                "activate:\(floatingToken.pid)",
                "focus:\(floatingToken.pid):\(floatingToken.windowId)",
                "raise"
            ]
        )
        XCTAssertEqual(fixture.controller.focusPolicyEngine.activeLease?.owner, .ruleCreatedFloatingWindow)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, floatingToken)
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, fixture.mainToken)
        XCTAssertEqual(fixture.controller.workspaceManager.systemModalFocusToken, modalToken)
        XCTAssertEqual(fixture.controller.workspaceManager.pendingFocusedToken, floatingToken)
    }

    func testNativeFullscreenOwnerSuppressesAutomaticRecovery() throws {
        let fixture = try makeFixture(prefix: "OmniWMFullscreenOwnerRecoveryScopeTests")
        let ownerWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let ownerToken = fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(
                for: WindowToken(pid: 559_010, windowId: 559_212)
            ),
            pid: 559_010,
            windowId: 559_212,
            to: ownerWorkspaceId
        )

        XCTAssertTrue(fixture.controller.workspaceManager.markNativeFullscreenSuspended(ownerToken))
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeNativeFullscreenFocusOwnerToken,
            ownerToken
        )
        XCTAssertTrue(fixture.controller.shouldSuppressManagedFocusRecovery)
    }

    func testUnrelatedNativeFullscreenTransitionDoesNotSuppressManagedBorder() throws {
        let fixture = try makeFixture(prefix: "OmniWMFullscreenBorderScopeTests")
        let otherWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let otherToken = fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(
                for: WindowToken(pid: 559_011, windowId: 559_213)
            ),
            pid: 559_011,
            windowId: 559_213,
            to: otherWorkspaceId
        )
        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        let world = WorldView(controller: fixture.controller, borderFrameResolver: { windowId in
            windowId == fixture.mainToken.windowId ? frame : nil
        })

        XCTAssertTrue(
            fixture.controller.workspaceManager.requestNativeFullscreenEnter(
                otherToken,
                in: otherWorkspaceId
            )
        )
        XCTAssertNotNil(SurfaceDerivation.deriveBorder(world: world))

        let sameWorkspaceToken = fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(
                for: WindowToken(pid: 559_012, windowId: 559_214)
            ),
            pid: 559_012,
            windowId: 559_214,
            to: fixture.workspaceId
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.requestNativeFullscreenEnter(
                sameWorkspaceToken,
                in: fixture.workspaceId
            )
        )
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
    }

    func testExitRequestedPlaceholderCannotReclaimNonManagedFocus() async throws {
        let fixture = try makeFixture(prefix: "OmniWMFullscreenExitActivationTests")
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fixture.mainToken))
        XCTAssertTrue(manager.requestNativeFullscreenExit(fixture.mainToken))
        XCTAssertTrue(manager.exitNonManagedFocus())
        manager.clearNonManagedFocusTarget(matching: fixture.mainToken)
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertFalse(
            manager.selectNativeFullscreenPlaceholder(
                fixture.mainToken,
                in: fixture.workspaceId
            )
        )

        fixture.controller.activateNativeFullscreenPlaceholder(fixture.mainToken)
        _ = fixture.controller.windowActionHandler.focusWindowFromBar(token: fixture.mainToken)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
    }

    func testPlaceholderActivationUsesStableOriginalTokenAfterWindowIdReuse() throws {
        let fixture = try makeFixture(prefix: "OmniWMFullscreenStableActivationTests")
        let manager = fixture.controller.workspaceManager
        let originalToken = WindowToken(pid: fixture.mainToken.pid, windowId: 559_215)
        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: originalToken),
            pid: originalToken.pid,
            windowId: originalToken.windowId,
            to: fixture.workspaceId
        )
        XCTAssertTrue(manager.markNativeFullscreenSuspended(originalToken))

        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 559_216)
        XCTAssertNotNil(
            manager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: WindowAdmissionTestSupport.axRef(for: replacementToken)
            )
        )
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fixture.mainToken))
        XCTAssertNotNil(
            manager.rekeyWindow(
                from: fixture.mainToken,
                to: originalToken,
                newAXRef: WindowAdmissionTestSupport.axRef(for: originalToken)
            )
        )

        fixture.controller.activateNativeFullscreenPlaceholder(originalToken)

        XCTAssertEqual(manager.nonManagedFocusToken, replacementToken)
        XCTAssertEqual(
            fixture.recorder.operations,
            [
                "activate:\(replacementToken.pid)",
                "focus:\(replacementToken.pid):\(replacementToken.windowId)",
                "raise"
            ]
        )
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

    private func trackFloatingWindow(
        in fixture: Fixture,
        token: WindowToken,
        subrole: String,
        windowLevel: Int32
    ) -> WindowToken {
        fixture.controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: fixture.workspaceId,
            mode: .floating,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "Cisco-Systems.Spark",
                workspaceId: fixture.workspaceId,
                mode: .floating,
                role: kAXWindowRole as String,
                subrole: subrole,
                title: nil,
                windowLevel: windowLevel,
                parentWindowId: nil,
                frame: CGRect(x: 0, y: 0, width: 280, height: 239),
                transientWindowServerEvidence: false
            )
        )
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
