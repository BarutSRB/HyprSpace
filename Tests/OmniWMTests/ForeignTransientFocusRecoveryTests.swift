// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ForeignTransientFocusRecoveryTests: XCTestCase {
    func testProvisionalTargetSuppressesAXWindowCreatedRelayout() async throws {
        try await assertConcreteTargetSuppressesAXWindowCreatedRelayout()
    }

    func testExternalFocusWithoutIdentitySuppressesAutomaticRecovery() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientNilTargetTests")

        XCTAssertTrue(fixture.controller.workspaceManager.recordExternalFocus())
        XCTAssertTrue(fixture.controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertNil(fixture.controller.workspaceManager.externalFocusToken)

        assertNoAutomaticRecovery(fixture)
    }

    func testClearingNativeOwnerClearsExternalIdentityWithoutRecovery() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientInactiveTargetTests")
        let popupToken = WindowToken(pid: 559_002, windowId: 559_202)

        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: popupToken.pid,
                windowId: popupToken.windowId
            )
        )
        XCTAssertTrue(fixture.controller.workspaceManager.clearNativeFocusOwner())
        XCTAssertFalse(fixture.controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertNil(fixture.controller.workspaceManager.externalFocusToken)

        assertNoAutomaticRecovery(fixture)
    }

    func testClosingExternalTargetClearsExactIdentityWithoutRecovery() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientProvisionalCloseTests")
        let popupToken = WindowToken(pid: 559_003, windowId: 559_203)

        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: popupToken.pid,
                windowId: popupToken.windowId
            )
        )
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(popupToken.windowId))
        )

        XCTAssertTrue(fixture.controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertNil(fixture.controller.workspaceManager.externalFocusToken)
        assertNoAutomaticRecovery(fixture)
    }

    func testClosingOlderOverlappingTargetPreservesCurrentTargetSuppression() throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientOverlappingTargetTests")
        let olderPopupToken = WindowToken(pid: 559_005, windowId: 559_205)
        let currentPopupToken = WindowToken(pid: 559_005, windowId: 559_206)

        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: olderPopupToken.pid,
                windowId: olderPopupToken.windowId
            )
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: currentPopupToken.pid,
                windowId: currentPopupToken.windowId
            )
        )
        fixture.controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(olderPopupToken.windowId))
        )
        fixture.controller.ensureFocusedTokenValid(in: fixture.workspaceId)

        XCTAssertTrue(fixture.controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(fixture.controller.workspaceManager.externalFocusToken, currentPopupToken)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.mainToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    func testAppExitPathsClearExactExternalIdentityWithoutAutomaticRecovery() throws {
        let deactivationFixture = try makeFixture(prefix: "OmniWMForeignTransientDeactivationTests")
        let deactivatedPopupToken = WindowToken(pid: 559_006, windowId: 559_207)
        XCTAssertTrue(
            deactivationFixture.controller.workspaceManager.recordExternalFocus(
                pid: deactivatedPopupToken.pid,
                windowId: deactivatedPopupToken.windowId
            )
        )

        deactivationFixture.controller.axEventHandler.handleAppDeactivated(pid: deactivatedPopupToken.pid)

        XCTAssertNil(deactivationFixture.controller.workspaceManager.externalFocusToken)
        assertNoAutomaticRecovery(deactivationFixture)

        let terminationFixture = try makeFixture(prefix: "OmniWMForeignTransientTerminationTests")
        let terminatedPopupToken = WindowToken(pid: 559_007, windowId: 559_208)
        XCTAssertTrue(
            terminationFixture.controller.workspaceManager.recordExternalFocus(
                pid: terminatedPopupToken.pid,
                windowId: terminatedPopupToken.windowId
            )
        )

        terminationFixture.controller.serviceLifecycleManager.handleAppTerminated(
            pid: terminatedPopupToken.pid
        )

        XCTAssertNil(terminationFixture.controller.workspaceManager.externalFocusToken)
        assertNoAutomaticRecovery(terminationFixture)
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
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { windowId in
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

    func testExitRequestedPlaceholderCannotReclaimExternalFocus() async throws {
        let fixture = try makeFixture(prefix: "OmniWMFullscreenExitActivationTests")
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fixture.mainToken))
        XCTAssertTrue(manager.requestNativeFullscreenExit(fixture.mainToken))
        XCTAssertTrue(manager.clearNativeFocusOwner())
        manager.clearExternalFocusIdentity(matching: fixture.mainToken)
        XCTAssertFalse(manager.nativeFocusOwner.isExternal)
        XCTAssertNil(manager.externalFocusToken)
        XCTAssertFalse(
            manager.selectNativeFullscreenPlaceholder(
                fixture.mainToken,
                in: fixture.workspaceId
            )
        )

        fixture.controller.activateNativeFullscreenPlaceholder(fixture.mainToken)
        _ = fixture.controller.windowActionHandler.focusWindowFromBar(token: fixture.mainToken)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertFalse(manager.nativeFocusOwner.isExternal)
        XCTAssertNil(manager.externalFocusToken)
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

        XCTAssertEqual(manager.externalFocusToken, replacementToken)
        XCTAssertEqual(
            fixture.recorder.operations,
            [
                "activate:\(replacementToken.pid)",
                "focus:\(replacementToken.pid):\(replacementToken.windowId)",
                "raise"
            ]
        )
    }

    private func assertConcreteTargetSuppressesAXWindowCreatedRelayout() async throws {
        let fixture = try makeFixture(prefix: "OmniWMForeignTransientProvisionalRelayoutTests")
        let popupToken = WindowToken(pid: 559_009, windowId: 559_211)

        XCTAssertTrue(
            fixture.controller.workspaceManager.recordExternalFocus(
                pid: popupToken.pid,
                windowId: popupToken.windowId
            )
        )
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .axWindowCreated,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertTrue(fixture.controller.workspaceManager.nativeFocusOwner.isExternal)
        XCTAssertEqual(fixture.controller.workspaceManager.externalFocusToken, popupToken)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.mainToken)
        XCTAssertEqual(
            fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId),
            fixture.mainToken
        )
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken)
    }

    private func assertNoAutomaticRecovery(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        fixture.controller.ensureFocusedTokenValid(in: fixture.workspaceId)

        XCTAssertTrue(fixture.recorder.operations.isEmpty, file: file, line: line)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest, file: file, line: line)
        XCTAssertNil(fixture.controller.workspaceManager.pendingFocusedToken, file: file, line: line)
        XCTAssertEqual(
            fixture.controller.workspaceManager.selectedManagedToken,
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
