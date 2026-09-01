// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NativeFocusAdmissionTests: XCTestCase {
    func testExactExternalFocusIsAdoptedAtomicallyWithoutPlatformFocusOperations() throws {
        let operations = FocusOperationRecorder()
        let controller = Self.controller(operations: operations)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let monitors = [
            Self.monitor(displayId: 41, x: 0),
            Self.monitor(displayId: 42, x: 1_600)
        ]
        manager.applyMonitorConfigurationChange(monitors)
        let admissionMonitorId = try XCTUnwrap(manager.monitorForWorkspace(workspaceId)?.id)
        let previousMonitorId = try XCTUnwrap(monitors.first { $0.id != admissionMonitorId }?.id)
        XCTAssertTrue(manager.setInteractionMonitor(previousMonitorId))

        let token = WindowToken(pid: 510_001, windowId: 510_002)
        XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId))
        manager.suppressFocusBorder(for: token)
        var sessionChangeCount = 0
        manager.onSessionStateChanged = { sessionChangeCount += 1 }

        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )

        let focus = manager.reconcileSnapshot().focusSession
        XCTAssertEqual(focus.nativeFocusOwner, .managed(token))
        XCTAssertEqual(focus.selectedManagedToken, token)
        XCTAssertEqual(focus.lastFocusedByWorkspace[workspaceId], token)
        XCTAssertEqual(focus.lastTiledFocusedByWorkspace[workspaceId], token)
        XCTAssertEqual(focus.lastTiledFocusedToken, token)
        XCTAssertEqual(focus.tiledFocusHistory.first, token)
        XCTAssertEqual(focus.interactionMonitorId, admissionMonitorId)
        XCTAssertEqual(focus.previousInteractionMonitorId, previousMonitorId)
        XCTAssertNil(focus.suppressedFocusToken)
        XCTAssertEqual(focus.pendingManagedFocus, .empty)
        XCTAssertEqual(sessionChangeCount, 1)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testExactExternalFocusAdmissionSkipsNiriCreateActivationAfterRelayout() async throws {
        let operations = FocusOperationRecorder()
        let (controller, workspaceId) = try await Self.niriController(operations: operations)
        let manager = controller.workspaceManager
        let token = WindowToken(pid: 510_011, windowId: 510_012)
        XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId))

        controller.axEventHandler.trackPreparedCreate(
            Self.preparedCreate(token: token, workspaceId: workspaceId)
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(manager.nativeManagedFocusToken, token)
        XCTAssertEqual(manager.selectedManagedToken, token)
        XCTAssertNil(manager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(controller.intentLedger.entries.isEmpty)
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testDifferentNiriCreateStillPerformsNormalActivationAfterAdoptedFocus() async throws {
        let operations = FocusOperationRecorder()
        let (controller, workspaceId) = try await Self.niriController(operations: operations)
        let manager = controller.workspaceManager
        let focusedToken = WindowToken(pid: 510_013, windowId: 510_014)
        XCTAssertTrue(
            manager.recordExternalFocus(
                pid: focusedToken.pid,
                windowId: focusedToken.windowId
            )
        )
        controller.axEventHandler.trackPreparedCreate(
            Self.preparedCreate(token: focusedToken, workspaceId: workspaceId)
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        XCTAssertTrue(operations.values.isEmpty)

        let newToken = WindowToken(pid: 510_015, windowId: 510_016)
        controller.axEventHandler.trackPreparedCreate(
            Self.preparedCreate(token: newToken, workspaceId: workspaceId)
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(operations.values, ["activate", "focus", "raise"])
        XCTAssertEqual(manager.nativeManagedFocusToken, focusedToken)
        XCTAssertEqual(manager.pendingFocusedToken, newToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, newToken)
    }

    func testFloatingAdmissionAdoptsFocusWithoutUpdatingTiledHistory() throws {
        let operations = FocusOperationRecorder()
        let controller = Self.controller(operations: operations)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 510_003, windowId: 510_004)
        XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId))

        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )

        let focus = manager.reconcileSnapshot().focusSession
        XCTAssertEqual(focus.nativeFocusOwner, .managed(token))
        XCTAssertEqual(focus.selectedManagedToken, token)
        XCTAssertEqual(focus.lastFocusedByWorkspace[workspaceId], token)
        XCTAssertEqual(focus.lastFloatingFocusedByWorkspace[workspaceId], token)
        XCTAssertNil(focus.lastTiledFocusedByWorkspace[workspaceId])
        XCTAssertNil(focus.lastTiledFocusedToken)
        XCTAssertFalse(focus.tiledFocusHistory.contains(token))
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testAnonymousMismatchedAndOwnedNativeFocusAreNotAdopted() throws {
        enum FocusCase {
            case anonymous
            case pidOnly
            case mismatched
            case owned
        }

        for (index, focusCase) in [FocusCase.anonymous, .pidOnly, .mismatched, .owned].enumerated() {
            let operations = FocusOperationRecorder()
            let controller = Self.controller(operations: operations)
            let manager = controller.workspaceManager
            let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
            let token = WindowToken(pid: pid_t(510_100 + index), windowId: 510_200 + index)

            switch focusCase {
            case .anonymous:
                XCTAssertTrue(manager.recordExternalFocus())
            case .pidOnly:
                XCTAssertTrue(manager.recordExternalFocus(pid: token.pid))
            case .mismatched:
                XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId + 1))
            case .owned:
                XCTAssertTrue(manager.recordOwnedSurfaceFocus())
            }
            let expectedOwner = manager.nativeFocusOwner

            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId
            )

            XCTAssertEqual(manager.nativeFocusOwner, expectedOwner)
            XCTAssertNil(manager.selectedManagedToken)
            XCTAssertNil(manager.lastFocusedToken(in: workspaceId))
            XCTAssertTrue(operations.values.isEmpty)
        }
    }

    func testPendingManagedRequestPreventsAdoptionAndRemainsUntouched() throws {
        let operations = FocusOperationRecorder()
        let controller = Self.controller(operations: operations)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let pendingToken = WindowToken(pid: 510_301, windowId: 510_302)
        _ = WindowAdmissionTestSupport.track(pendingToken, in: workspaceId, controller: controller)
        let request = controller.intentLedger.beginManagedRequest(token: pendingToken, workspaceId: workspaceId)
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: workspaceId,
                requestId: request.requestId
            )
        )

        let admittedToken = WindowToken(pid: 510_303, windowId: 510_304)
        XCTAssertTrue(
            manager.recordExternalFocus(
                pid: admittedToken.pid,
                windowId: admittedToken.windowId,
                preservePendingManagedFocus: true
            )
        )
        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: admittedToken),
            pid: admittedToken.pid,
            windowId: admittedToken.windowId,
            to: workspaceId
        )

        XCTAssertEqual(manager.nativeFocusOwner, .external(pid: admittedToken.pid, windowId: admittedToken.windowId))
        XCTAssertNil(manager.selectedManagedToken)
        XCTAssertEqual(manager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, pendingToken)
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testExistingEntryAndRekeyDoNotAdoptExternalFocus() throws {
        let operations = FocusOperationRecorder()
        let controller = Self.controller(operations: operations)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let existingToken = WindowToken(pid: 510_401, windowId: 510_402)
        let existingAXRef = WindowAdmissionTestSupport.track(
            existingToken,
            in: workspaceId,
            controller: controller
        )
        XCTAssertTrue(manager.recordExternalFocus(pid: existingToken.pid, windowId: existingToken.windowId))

        _ = manager.addWindow(
            existingAXRef,
            pid: existingToken.pid,
            windowId: existingToken.windowId,
            to: workspaceId
        )

        XCTAssertEqual(manager.nativeFocusOwner, .external(pid: existingToken.pid, windowId: existingToken.windowId))
        XCTAssertNil(manager.selectedManagedToken)

        let oldToken = WindowToken(pid: 510_403, windowId: 510_404)
        let newToken = WindowToken(pid: 510_405, windowId: 510_406)
        _ = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        XCTAssertTrue(manager.recordExternalFocus(pid: newToken.pid, windowId: newToken.windowId))
        XCTAssertNotNil(
            manager.rekeyWindow(
                from: oldToken,
                to: newToken,
                newAXRef: WindowAdmissionTestSupport.axRef(for: newToken)
            )
        )

        XCTAssertEqual(manager.nativeFocusOwner, .external(pid: newToken.pid, windowId: newToken.windowId))
        XCTAssertNil(manager.selectedManagedToken)
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testNativeFullscreenAdmissionCannotAdoptExternalFocus() throws {
        let operations = FocusOperationRecorder()
        let controller = Self.controller(operations: operations)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 510_501, windowId: 510_502)
        XCTAssertTrue(manager.recordExternalFocus(pid: token.pid, windowId: token.windowId))

        controller.axEventHandler.trackPreparedCreate(
            .init(
                windowId: UInt32(token.windowId),
                token: token,
                axRef: WindowAdmissionTestSupport.axRef(for: token),
                ruleEffects: .none,
                admissionHints: .none,
                appFullscreen: true,
                replacementMetadata: .init(
                    bundleId: nil,
                    workspaceId: workspaceId,
                    mode: .tiling,
                    role: nil,
                    subrole: nil,
                    title: nil,
                    windowLevel: nil,
                    parentWindowId: nil,
                    frame: nil
                ),
                structuralReplacementMatch: nil
            )
        )

        XCTAssertNotNil(manager.entry(for: token))
        XCTAssertEqual(manager.nativeFocusOwner, .external(pid: token.pid, windowId: token.windowId))
        XCTAssertNil(manager.selectedManagedToken)
        XCTAssertTrue(operations.values.isEmpty)
    }

    func testReducerRevalidatesExactExternalFocusAndPendingState() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 510_601, windowId: 510_602)
        let otherToken = WindowToken(pid: 510_603, windowId: 510_604)
        let event = WMEvent.windowAdmitted(
            token: token,
            workspaceId: workspaceId,
            monitorId: nil,
            mode: .tiling,
            axRef: WindowAdmissionTestSupport.axRef(for: token),
            ruleEffects: .none,
            admissionHints: .none,
            lifetimeAuthority: .directLifecycle,
            adoptNativeFocus: true,
            managedReplacementMetadata: nil,
            source: .workspaceManager
        )

        var mismatchedFocus = FocusSessionSnapshot()
        mismatchedFocus.nativeFocusOwner = .external(pid: otherToken.pid, windowId: otherToken.windowId)
        let mismatchedPlan = StateReducer.reduce(
            event: event,
            existingEntry: nil,
            currentSnapshot: Self.snapshot(focus: mismatchedFocus),
            monitors: []
        )

        var pendingFocus = FocusSessionSnapshot()
        pendingFocus.nativeFocusOwner = .external(pid: token.pid, windowId: token.windowId)
        pendingFocus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: otherToken,
            workspaceId: workspaceId,
            monitorId: nil,
            requestId: 7
        )
        let pendingPlan = StateReducer.reduce(
            event: event,
            existingEntry: nil,
            currentSnapshot: Self.snapshot(focus: pendingFocus),
            monitors: []
        )

        var sameTokenPendingFocus = FocusSessionSnapshot()
        sameTokenPendingFocus.nativeFocusOwner = .external(pid: token.pid, windowId: token.windowId)
        sameTokenPendingFocus.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: token,
            workspaceId: workspaceId,
            monitorId: nil,
            requestId: 8
        )
        let sameTokenPendingPlan = StateReducer.reduce(
            event: event,
            existingEntry: nil,
            currentSnapshot: Self.snapshot(focus: sameTokenPendingFocus),
            monitors: []
        )

        let existingEntry = WindowState(
            token: token,
            axRef: WindowAdmissionTestSupport.axRef(for: token),
            workspaceId: workspaceId,
            mode: .tiling,
            managedReplacementMetadata: nil,
            ruleEffects: .none,
            admissionHints: .none
        )
        var existingEntryFocus = FocusSessionSnapshot()
        existingEntryFocus.nativeFocusOwner = .external(pid: token.pid, windowId: token.windowId)
        let existingEntryPlan = StateReducer.reduce(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: Self.snapshot(focus: existingEntryFocus),
            monitors: [],
            windowExistedBeforeMutation: true
        )

        XCTAssertNil(mismatchedPlan.focusSession)
        XCTAssertNil(pendingPlan.focusSession)
        XCTAssertNil(sameTokenPendingPlan.focusSession)
        XCTAssertNil(existingEntryPlan.focusSession)
    }

    private static func controller(operations: FocusOperationRecorder) -> WMController {
        WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNativeFocusAdmissionTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations.values.append("activate") },
                focusSpecificWindow: { _, _, _ in operations.values.append("focus") },
                deactivateSameAppWindow: { _, _ in
                    operations.values.append("deactivate")
                    return false
                },
                activateAndFocusSameAppWindow: { _, _, _ in
                    operations.values.append("activate-and-focus")
                    return false
                },
                raiseWindow: { _ in operations.values.append("raise") },
                orderWindow: { _ in operations.values.append("order") }
            )
        )
    }

    private static func niriController(
        operations: FocusOperationRecorder
    ) async throws -> (controller: WMController, workspaceId: WorkspaceDescriptor.ID) {
        let controller = controller(operations: operations)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.motionPolicy.animationsEnabled = false
        controller.niriLayoutHandler.enableNiriLayout()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        return (controller, workspaceId)
    }

    private static func preparedCreate(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> AXEventHandler.PreparedCreate {
        AXEventHandler.PreparedCreate(
            windowId: UInt32(token.windowId),
            token: token,
            axRef: WindowAdmissionTestSupport.axRef(for: token),
            ruleEffects: .none,
            admissionHints: .none,
            appFullscreen: false,
            replacementMetadata: ManagedReplacementMetadata(
                bundleId: nil,
                workspaceId: workspaceId,
                mode: .tiling,
                role: nil,
                subrole: nil,
                title: nil,
                windowLevel: nil,
                parentWindowId: nil,
                frame: nil
            ),
            structuralReplacementMatch: nil
        )
    }

    private static func monitor(displayId: CGDirectDisplayID, x: CGFloat) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: x, y: 0, width: 1_600, height: 900),
            visibleFrame: CGRect(x: x, y: 0, width: 1_600, height: 900),
            hasNotch: false,
            name: "Test-\(displayId)"
        )
    }

    private static func snapshot(focus: FocusSessionSnapshot) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: focus,
            windows: []
        )
    }
}

@MainActor
private final class FocusOperationRecorder {
    var values: [String] = []
}
