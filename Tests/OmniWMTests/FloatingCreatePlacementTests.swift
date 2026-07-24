// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FloatingCreatePlacementTests: XCTestCase {
    func testTiledFocusConfirmationSetsLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 5001, windowId: 11)
        let plan = StateReducer.reduce(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(
                FocusSessionSnapshot(),
                [reconcileWindow(token, workspaceId, mode: .tiling)]
            ),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.focusedToken, token)
        XCTAssertEqual(plan.focusSession?.lastTiledFocusedToken, token)
    }

    func testFloatingFocusConfirmationDoesNotSetLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 5001, windowId: 12)
        let plan = StateReducer.reduce(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(
                FocusSessionSnapshot(),
                [reconcileWindow(token, workspaceId, mode: .floating)]
            ),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.focusedToken, token)
        XCTAssertNil(plan.focusSession?.lastTiledFocusedToken)
    }

    func testRejectedFocusConfirmationDoesNotSetLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 5001, windowId: 13)
        let plan = StateReducer.reduce(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 99,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(
                FocusSessionSnapshot(),
                [reconcileWindow(token, workspaceId, mode: .tiling)]
            ),
            monitors: []
        )

        XCTAssertNotEqual(plan.focusSession?.focusedToken, token)
        XCTAssertNotEqual(plan.focusSession?.lastTiledFocusedToken, token)
    }

    func testWindowRemovedClearsLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 5001, windowId: 14)
        var focus = FocusSessionSnapshot()
        focus.focusedToken = token
        focus.lastTiledFocusedToken = token

        let plan = StateReducer.reduce(
            event: .windowRemoved(token: token, workspaceId: workspaceId, source: .workspaceManager),
            existingEntry: nil,
            currentSnapshot: snapshot(focus, [reconcileWindow(token, workspaceId, mode: .tiling)]),
            monitors: []
        )

        XCTAssertNil(plan.focusSession?.lastTiledFocusedToken)
    }

    func testWindowRekeyedUpdatesLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 5001, windowId: 15)
        let newToken = WindowToken(pid: 5001, windowId: 16)
        var focus = FocusSessionSnapshot()
        focus.lastTiledFocusedToken = oldToken

        let plan = StateReducer.reduce(
            event: .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: workspaceId,
                monitorId: nil,
                reason: .manualRekey,
                newAXRef: AXWindowRef(element: AXUIElementCreateApplication(oldToken.pid), windowId: newToken.windowId),
                managedReplacementMetadata: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(focus, [reconcileWindow(oldToken, workspaceId, mode: .tiling)]),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.lastTiledFocusedToken, newToken)
    }

    func testTiledToFloatingModeChangeClearsAndDoesNotResurrectLastTiledFocusedToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 5001, windowId: 17)
        var focus = FocusSessionSnapshot()
        focus.focusedToken = token
        focus.lastTiledFocusedToken = token

        let toFloating = StateReducer.reduce(
            event: .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .floating,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(focus, [reconcileWindow(token, workspaceId, mode: .floating)]),
            monitors: []
        )
        XCTAssertNil(toFloating.focusSession?.lastTiledFocusedToken)

        var clearedFocus = focus
        clearedFocus.lastTiledFocusedToken = nil
        let backToTiling = StateReducer.reduce(
            event: .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot(clearedFocus, [reconcileWindow(token, workspaceId, mode: .tiling)]),
            monitors: []
        )
        XCTAssertNil(backToTiling.focusSession?.lastTiledFocusedToken)
    }

    func testFloatingSpawnResolvesToSecondaryWhereAppIsTiled() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6001
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 100), pid: pid, windowId: 100, to: fixture.secondaryWorkspace
        )

        XCTAssertEqual(fixture.controller.testFloatingSpawnMonitorId(pid: pid), fixture.secondary.id)
    }

    func testFloatingSpawnExcludesAppFloatingWindows() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6002
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 200), pid: pid, windowId: 200, to: fixture.secondaryWorkspace
        )
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 201), pid: pid, windowId: 201, to: fixture.primaryWorkspace, mode: .floating
        )

        XCTAssertEqual(fixture.controller.testFloatingSpawnMonitorId(pid: pid), fixture.secondary.id)
    }

    func testFloatingSpawnMultiMonitorTracksMostRecentlyFocusedTiled() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 6003
        let onPrimary = manager.addWindow(axRef(pid, 300), pid: pid, windowId: 300, to: fixture.primaryWorkspace)
        let onSecondary = manager.addWindow(axRef(pid, 301), pid: pid, windowId: 301, to: fixture.secondaryWorkspace)
        let floating = manager.addWindow(
            axRef(pid, 302), pid: pid, windowId: 302, to: fixture.primaryWorkspace, mode: .floating
        )

        confirmTiledThenFloat(
            manager,
            tiled: onSecondary,
            on: fixture.secondaryWorkspace,
            floating: floating,
            on: fixture.primaryWorkspace
        )
        XCTAssertEqual(manager.lastTiledFocusedToken, onSecondary)
        XCTAssertEqual(fixture.controller.testFloatingSpawnMonitorId(pid: pid), fixture.secondary.id)

        confirmTiledThenFloat(
            manager,
            tiled: onPrimary,
            on: fixture.primaryWorkspace,
            floating: floating,
            on: fixture.primaryWorkspace
        )
        XCTAssertEqual(manager.lastTiledFocusedToken, onPrimary)
        XCTAssertEqual(fixture.controller.testFloatingSpawnMonitorId(pid: pid), fixture.primary.id)
    }

    func testFloatingSpawnMultiMonitorNoRecencyReturnsNil() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 6004
        _ = manager.addWindow(axRef(pid, 400), pid: pid, windowId: 400, to: fixture.primaryWorkspace)
        _ = manager.addWindow(axRef(pid, 401), pid: pid, windowId: 401, to: fixture.secondaryWorkspace)

        XCTAssertNil(fixture.controller.testFloatingSpawnMonitorId(pid: pid))
    }

    func testResolveFloatingPlacesOnTiledSecondaryWhenNativeNil() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6101
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 500), pid: pid, windowId: 500, to: fixture.secondaryWorkspace
        )

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 501),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: false,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.secondary.id)
        XCTAssertEqual(resolved.rung, .floatingSpawn)
    }

    func testResolveFloatingPrefersNativeMonitorOverWorkingMonitor() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6102
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 510), pid: pid, windowId: 510, to: fixture.primaryWorkspace
        )

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 511),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: false,
            createPlacementContext: placementContext(nativeSpaceMonitorId: fixture.secondary.id),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.secondary.id)
        XCTAssertEqual(resolved.rung, .nativeSpace)
    }

    func testResolveTiledPrefersFocusedContextOverFrame() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6103

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 521),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: true,
            createPlacementContext: placementContext(
                focusedWorkspaceId: fixture.secondaryWorkspace,
                focusedMonitorId: fixture.secondary.id
            ),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .focusedContext)
    }

    func testResolveTiledPrefersNativeSpaceOverFrame() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6104

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 531),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: true,
            createPlacementContext: placementContext(nativeSpaceMonitorId: fixture.secondary.id),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.secondary.id)
        XCTAssertEqual(resolved.rung, .nativeSpace)
    }

    func testResolveTiledPrefersLiveFocusRecencyOverFrame() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 6105
        let tiled = manager.addWindow(axRef(pid, 540), pid: pid, windowId: 540, to: fixture.secondaryWorkspace)
        _ = manager.confirmManagedFocus(tiled, in: fixture.secondaryWorkspace, activateWorkspaceOnMonitor: false)

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 541),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: true,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .liveManagedFocus)
    }

    func testResolveTiledFallsBackToFrameWhenNoSignal() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6106
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 550), pid: pid, windowId: 550, to: fixture.secondaryWorkspace
        )

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 551),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: true,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.primary.id)
        XCTAssertEqual(resolved.rung, .frame)
    }

    func testSynthesizedContextOnAXFirstAdmissionResolvesFocusedWorkspace() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let pid: pid_t = 6107
        let tiled = manager.addWindow(axRef(pid, 560), pid: pid, windowId: 560, to: fixture.secondaryWorkspace)
        _ = manager.confirmManagedFocus(tiled, in: fixture.secondaryWorkspace, activateWorkspaceOnMonitor: false)

        let synthesized = fixture.controller.axEventHandler.liveCreatePlacementContext(
            controller: fixture.controller
        )
        XCTAssertNil(synthesized.nativeSpaceMonitorId)
        XCTAssertEqual(synthesized.focusedWorkspaceId, fixture.secondaryWorkspace)

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 561),
            pid: pid,
            restrictWorkspaceRuleToPlacementMonitor: true,
            createPlacementContext: synthesized,
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .focusedContext)
    }

    func testFullRescanPlacementUsesCapturedAXFrameWithoutAXReference() throws {
        let fixture = try makeTwoMonitorFixture()
        let token = WindowToken(pid: 6_108, windowId: 562)
        let capturedFrame = CGRect(x: 2_000, y: 1_400, width: 600, height: 400)
        let evaluation = fixture.controller.evaluateWindowDisposition(
            token: token,
            evidence: .unavailable(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                appPolicy: .regular,
                bundleId: "example.full-rescan-placement"
            ),
            appFullscreen: false,
            windowInfo: nil,
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: true,
                frame: capturedFrame
            )
        )

        let workspaceId = fixture.controller.resolvedWorkspaceId(
            for: evaluation,
            axRef: nil,
            existingEntry: nil,
            fallbackWorkspaceId: fixture.primaryWorkspace,
            createPlacementContext: placementContext(),
            windowFrame: capturedFrame
        )

        XCTAssertEqual(workspaceId, fixture.secondaryWorkspace)
    }

    private func placementContext(
        nativeSpaceMonitorId: Monitor.ID? = nil,
        focusedWorkspaceId: WorkspaceDescriptor.ID? = nil,
        focusedMonitorId: Monitor.ID? = nil
    ) -> WindowCreatePlacementContext {
        WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            pendingFocusedWorkspaceId: nil,
            pendingFocusedMonitorId: nil,
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedMonitorId,
            interactionMonitorId: nil,
            createdAt: Date()
        )
    }

    private func confirmTiledThenFloat(
        _ manager: WorkspaceManager,
        tiled: WindowToken,
        on tiledWorkspace: WorkspaceDescriptor.ID,
        floating: WindowToken,
        on floatingWorkspace: WorkspaceDescriptor.ID
    ) {
        _ = manager.confirmManagedFocus(tiled, in: tiledWorkspace, activateWorkspaceOnMonitor: false)
        _ = manager.confirmManagedFocus(floating, in: floatingWorkspace, activateWorkspaceOnMonitor: false)
    }

    private struct TwoMonitorFixture {
        let controller: WMController
        let primary: Monitor
        let secondary: Monitor
        let primaryWorkspace: WorkspaceDescriptor.ID
        let secondaryWorkspace: WorkspaceDescriptor.ID
    }

    private func makeTwoMonitorFixture() throws -> TwoMonitorFixture {
        let controller = makeController()
        let primaryDisplayId = CGMainDisplayID()
        let primary = makeMonitor(
            primaryDisplayId,
            "Primary",
            CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        let secondary = makeMonitor(
            primaryDisplayId &+ 1,
            "Secondary",
            CGRect(x: 1800, y: 1169, width: 1920, height: 1080)
        )
        controller.workspaceManager.applyMonitorConfigurationChange([primary, secondary])

        let primaryWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let secondaryWorkspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )

        XCTAssertEqual(controller.workspaceManager.monitorId(for: primaryWorkspace), primary.id)
        XCTAssertEqual(controller.workspaceManager.monitorId(for: secondaryWorkspace), secondary.id)

        return TwoMonitorFixture(
            controller: controller,
            primary: primary,
            secondary: secondary,
            primaryWorkspace: primaryWorkspace,
            secondaryWorkspace: secondaryWorkspace
        )
    }

    private func makeController() -> WMController {
        WMController(
            settings: makeSettings(),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFloatingPlacementTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    private func makeMonitor(_ displayId: CGDirectDisplayID, _ name: String, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func axRef(_ pid: pid_t, _ windowId: Int) -> AXWindowRef {
        AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
    }

    private func reconcileWindow(
        _ token: WindowToken,
        _ workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> ReconcileWindowSnapshot {
        ReconcileWindowSnapshot(
            token: token,
            workspaceId: workspaceId,
            mode: mode,
            lifecyclePhase: mode == .floating ? .floating : .tiled,
            observedState: .initial(workspaceId: workspaceId, monitorId: nil),
            desiredState: .initial(workspaceId: workspaceId, monitorId: nil, disposition: mode),
            restoreIntent: nil
        )
    }

    private func snapshot(
        _ focusSession: FocusSessionSnapshot,
        _ windows: [ReconcileWindowSnapshot]
    ) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: focusSession,
            windows: windows,
            viewports: [:],
            layouts: [:]
        )
    }
}
