// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
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

    func testResolveDiscoveryGenericFloatingUsesFrameInsteadOfSameAppWindow() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6101
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 500), pid: pid, windowId: 500, to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            origin: .discovery,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.primary.id)
        XCTAssertEqual(resolved.rung, .frame)
    }

    func testResolveDiscoveryFinderQuickLookUsesSameAppTiledWindow() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_127
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 501), pid: pid, windowId: 501, to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            allowsFloatingSpawnPlacement: true,
            origin: .discovery,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .floatingSpawn)
    }

    func testResolveFloatingPrefersNativeMonitorOverWorkingMonitor() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6102
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 510), pid: pid, windowId: 510, to: fixture.primaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            origin: .discovery,
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

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
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

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
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

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
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

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
            createPlacementContext: placementContext(),
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: resolved.workspaceId), fixture.primary.id)
        XCTAssertEqual(resolved.rung, .frame)
    }

    func testResolveLiveTiledPrefersCapturedInteractionWorkspace() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_107
        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                nativeSpaceMonitorId: fixture.secondary.id,
                focusedWorkspaceId: fixture.secondaryWorkspace,
                focusedMonitorId: fixture.secondary.id,
                interactionWorkspaceId: fixture.primaryWorkspace,
                interactionMonitorId: fixture.primary.id
            ),
            windowFrame: fixture.secondary.frame.insetBy(dx: 100, dy: 100),
            fallbackWorkspaceId: fixture.secondaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testResolveLiveGenericFloatingUsesCapturedInteractionInsteadOfSameAppWindow() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_108
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 570),
            pid: pid,
            windowId: 570,
            to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: fixture.primaryWorkspace,
                interactionMonitorId: fixture.primary.id
            ),
            windowFrame: fixture.primary.frame.insetBy(dx: 100, dy: 100),
            fallbackWorkspaceId: fixture.primaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testResolveLiveFinderQuickLookUsesSameAppWindowBeforeCapturedInteraction() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_128
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 571),
            pid: pid,
            windowId: 571,
            to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            allowsFloatingSpawnPlacement: true,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: fixture.primaryWorkspace,
                interactionMonitorId: fixture.primary.id
            ),
            windowFrame: fixture.primary.frame.insetBy(dx: 100, dy: 100),
            fallbackWorkspaceId: fixture.primaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .floatingSpawn)
    }

    func testResolveLiveFinderQuickLookPrefersNativeSpaceOverAppSpawn() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_124
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 572),
            pid: pid,
            windowId: 572,
            to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            allowsFloatingSpawnPlacement: true,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                nativeSpaceMonitorId: fixture.primary.id,
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.secondary.frame,
            fallbackWorkspaceId: fixture.secondaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .nativeSpace)
    }

    func testResolveLaterFloatingIgnoresInitialWorkspaceRule() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_125
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 573),
            pid: pid,
            windowId: 573,
            to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            workspaceName: "1",
            pid: pid,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                nativeSpaceMonitorId: fixture.secondary.id,
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.secondary.frame,
            fallbackWorkspaceId: fixture.secondaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testResolveLiveFinderQuickLookPendingFocusPrecedesNativeAppSpawnAndInteraction() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_126
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 574),
            pid: pid,
            windowId: 574,
            to: fixture.secondaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            pid: pid,
            placementMode: .floating,
            allowsFloatingSpawnPlacement: true,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                nativeSpaceMonitorId: fixture.secondary.id,
                pendingFocusedWorkspaceId: fixture.primaryWorkspace,
                pendingFocusedMonitorId: fixture.primary.id,
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.secondary.frame,
            fallbackWorkspaceId: fixture.secondaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .pendingFocusContext)
    }

    func testFloatingSpawnPlacementIsLimitedToFinderQuickLook() {
        let controller = makeController()
        let finderQuickLook = placementEvaluation(
            bundleId: "com.apple.finder",
            subrole: "Quick Look"
        )
        let otherFinderWindow = placementEvaluation(
            bundleId: "com.apple.finder",
            subrole: kAXStandardWindowSubrole as String
        )
        let otherAppQuickLook = placementEvaluation(
            bundleId: "com.example.viewer",
            subrole: "Quick Look"
        )

        XCTAssertTrue(controller.allowsFloatingSpawnPlacement(for: finderQuickLook, mode: .floating))
        XCTAssertFalse(controller.allowsFloatingSpawnPlacement(for: finderQuickLook, mode: .tiling))
        XCTAssertFalse(controller.allowsFloatingSpawnPlacement(for: otherFinderWindow, mode: .floating))
        XCTAssertFalse(controller.allowsFloatingSpawnPlacement(for: otherAppQuickLook, mode: .floating))
    }

    func testLiveFinderQuickLookUsesObservedAXSubrole() throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_FINDER_QUICK_LOOK_TESTS"] == "1" else {
            throw XCTSkip("Set OMNIWM_RUN_FINDER_QUICK_LOOK_TESTS=1 with a Finder Quick Look window open")
        }
        let finder = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == "com.apple.finder"
            }
        )
        let windows = try AXWindowEnumerationInspector.enumerateApplication(
            pid: finder.processIdentifier,
            timeout: 1,
            context: .init(
                appPolicy: finder.activationPolicy,
                bundleId: finder.bundleIdentifier,
                includeTitle: false
            )
        )
        let quickLook = try XCTUnwrap(
            windows.first {
                $0.role == kAXWindowRole as String && $0.subrole == "Quick Look"
            },
            "Open Finder Quick Look before running this integration test"
        )
        let controller = makeController()
        let evaluation = placementEvaluation(
            bundleId: finder.bundleIdentifier,
            subrole: quickLook.subrole
        )

        XCTAssertTrue(controller.allowsFloatingSpawnPlacement(for: evaluation, mode: .floating))
    }

    func testResolveLiveStandaloneFloatingPrefersCapturedInteractionWorkspace() throws {
        let fixture = try makeTwoMonitorFixture()
        let resolved = resolvePlacement(
            fixture,
            pid: 6_118,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                nativeSpaceMonitorId: fixture.secondary.id,
                interactionWorkspaceId: fixture.primaryWorkspace,
                interactionMonitorId: fixture.primary.id
            ),
            windowFrame: fixture.secondary.frame.insetBy(dx: 100, dy: 100),
            fallbackWorkspaceId: fixture.secondaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testResolveLivePendingFocusPrecedesInteractionWorkspace() throws {
        let fixture = try makeTwoMonitorFixture()
        let resolved = resolvePlacement(
            fixture,
            pid: 6_109,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                pendingFocusedWorkspaceId: fixture.secondaryWorkspace,
                pendingFocusedMonitorId: fixture.secondary.id,
                interactionWorkspaceId: fixture.primaryWorkspace,
                interactionMonitorId: fixture.primary.id
            ),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .pendingFocusContext)
    }

    func testResolveLiveKeepsExactCreateTimeWorkspaceAcrossVisibleWorkspaceChange() throws {
        let fixture = try makeTwoMonitorFixture()
        let laterWorkspace = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "7", createIfMissing: true)
        )
        XCTAssertTrue(
            fixture.controller.workspaceManager.setActiveWorkspace(
                laterWorkspace,
                on: fixture.secondary.id
            )
        )

        let resolved = resolvePlacement(
            fixture,
            pid: 6_110,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.secondary.id)?.id,
            laterWorkspace
        )
    }

    func testResolveLiveFallsBackFromMissingCapturedWorkspaceToCapturedMonitor() throws {
        let fixture = try makeTwoMonitorFixture()
        let resolved = resolvePlacement(
            fixture,
            pid: 6_111,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: WorkspaceDescriptor.ID(),
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionMonitor)
    }

    func testResolveLiveUsesConfirmedInteractionMonitorWithoutCapturedContext() throws {
        let fixture = try makeTwoMonitorFixture()
        XCTAssertTrue(fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondary.id))

        let resolved = resolvePlacement(
            fixture,
            pid: 6_119,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: placementContext(),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionMonitor)
    }

    func testResolveLiveDoesNotSynthesizeInteractionMonitorFromFocusedWindow() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let focused = manager.addWindow(
            axRef(6_120, 571),
            pid: 6_120,
            windowId: 571,
            to: fixture.secondaryWorkspace
        )
        _ = manager.confirmManagedFocus(
            focused,
            in: fixture.secondaryWorkspace,
            activateWorkspaceOnMonitor: false
        )
        XCTAssertTrue(manager.setInteractionMonitor(nil))

        let resolved = resolvePlacement(
            fixture,
            pid: 6_121,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: placementContext(),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .frame)
    }

    func testResolveWorkspaceRulePrecedesInteractionAcrossMonitors() throws {
        let fixture = try makeTwoMonitorFixture()
        let context = placementContext(
            interactionWorkspaceId: fixture.primaryWorkspace,
            interactionMonitorId: fixture.primary.id
        )
        let tiled = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: 6_112,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )
        let floating = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: 6_112,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(tiled.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(tiled.rung, .workspaceRule)
        XCTAssertEqual(floating.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(floating.rung, .workspaceRule)
    }

    func testResolveWorkspaceRulePrecedesPendingFocus() throws {
        let fixture = try makeTwoMonitorFixture()
        let resolved = resolvePlacement(
            fixture,
            workspaceName: "1",
            pid: 6_117,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                pendingFocusedWorkspaceId: fixture.secondaryWorkspace,
                pendingFocusedMonitorId: fixture.secondary.id,
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.secondary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(resolved.rung, .workspaceRule)
    }

    func testResolveLaterTiledWindowIgnoresInitialWorkspaceRule() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_129
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 575),
            pid: pid,
            windowId: 575,
            to: fixture.primaryWorkspace
        )

        let resolved = resolvePlacement(
            fixture,
            workspaceName: "1",
            pid: pid,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: fixture.primaryWorkspace
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testWorkspaceRuleAppliesOnlyWhileAppHasNoTrackedWindows() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_130
        let context = placementContext(
            interactionWorkspaceId: fixture.primaryWorkspace,
            interactionMonitorId: fixture.primary.id
        )
        let first = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: pid,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: fixture.primaryWorkspace
        )
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 576),
            pid: pid,
            windowId: 576,
            to: first.workspaceId,
            mode: .floating
        )
        let second = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: pid,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: fixture.primaryWorkspace
        )

        XCTAssertEqual(first.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(first.rung, .workspaceRule)
        XCTAssertEqual(second.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(second.rung, .interactionWorkspace)

        _ = fixture.controller.workspaceManager.removeWindow(pid: pid, windowId: 576)
        let afterLastWindowClosed = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: pid,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: fixture.primaryWorkspace
        )

        XCTAssertEqual(afterLastWindowClosed.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(afterLastWindowClosed.rung, .workspaceRule)
    }

    func testResolveUnknownWorkspaceRuleFallsThroughToInteraction() throws {
        let fixture = try makeTwoMonitorFixture()
        let resolved = resolvePlacement(
            fixture,
            workspaceName: "missing",
            pid: 6_113,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: placementContext(
                interactionWorkspaceId: fixture.secondaryWorkspace,
                interactionMonitorId: fixture.secondary.id
            ),
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testResolveContinuityPrecedesRuleAndInteraction() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_114
        _ = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 580),
            pid: pid,
            windowId: 580,
            to: fixture.secondaryWorkspace
        )
        let context = placementContext(
            nativeSpaceMonitorId: fixture.primary.id,
            focusedWorkspaceId: fixture.primaryWorkspace,
            focusedMonitorId: fixture.primary.id,
            interactionWorkspaceId: fixture.primaryWorkspace,
            interactionMonitorId: fixture.primary.id
        )

        let structural = resolvePlacement(
            fixture,
            workspaceName: "1",
            pid: pid,
            structuralReplacementWorkspaceId: fixture.secondaryWorkspace,
            placementMode: .tiling,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )
        let parent = resolvePlacement(
            fixture,
            workspaceName: "1",
            pid: pid,
            parentWindowId: 580,
            inheritTrackedParentWorkspace: true,
            placementMode: .floating,
            origin: .liveCreate,
            createPlacementContext: context,
            windowFrame: fixture.primary.frame,
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(structural.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(structural.rung, .structuralReplacement)
        XCTAssertEqual(parent.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(parent.rung, .trackedParent)
    }

    func testResolveExistingEntryMovesOnlyForExplicitRuleApply() throws {
        let fixture = try makeTwoMonitorFixture()
        let pid: pid_t = 6_115
        let token = fixture.controller.workspaceManager.addWindow(
            axRef(pid, 590),
            pid: pid,
            windowId: 590,
            to: fixture.primaryWorkspace
        )
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))

        let automatic = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
            createPlacementContext: nil,
            windowFrame: fixture.secondary.frame,
            existingEntry: entry,
            fallbackWorkspaceId: nil
        )
        let explicit = resolvePlacement(
            fixture,
            workspaceName: "6",
            pid: pid,
            placementMode: .tiling,
            origin: .discovery,
            createPlacementContext: nil,
            windowFrame: fixture.secondary.frame,
            existingEntry: entry,
            fallbackWorkspaceId: nil,
            context: .explicitRuleApply
        )

        XCTAssertEqual(automatic.workspaceId, fixture.primaryWorkspace)
        XCTAssertEqual(automatic.rung, .existingEntry)
        XCTAssertEqual(explicit.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(explicit.rung, .workspaceRule)
    }

    func testCreatePlacementTraceIncludesInteractionWorkspace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let event = NiriCreateFocusTraceEvent(
            kind: .createPlacementResolved(
                token: WindowToken(pid: 6_116, windowId: 600),
                workspaceId: workspaceId,
                rung: .interactionWorkspace,
                pendingWorkspaceId: nil,
                pendingMonitorId: nil,
                focusedWorkspaceId: nil,
                focusedMonitorId: nil,
                nativeSpaceMonitorId: nil,
                frameMonitorId: nil,
                interactionWorkspaceId: workspaceId,
                interactionMonitorId: nil
            )
        )

        XCTAssertTrue(event.description.contains("rung=interaction_workspace"))
        XCTAssertTrue(event.description.contains("interaction_workspace=\(workspaceId.uuidString)"))
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
        XCTAssertEqual(synthesized.interactionWorkspaceId, fixture.secondaryWorkspace)

        let resolved = fixture.controller.resolveWorkspaceForNewWindow(
            axRef: axRef(pid, 561),
            pid: pid,
            placementMode: .tiling,
            createPlacementContext: synthesized,
            windowFrame: CGRect(x: 200, y: 200, width: 600, height: 400),
            fallbackWorkspaceId: nil
        )

        XCTAssertEqual(resolved.workspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(resolved.rung, .interactionWorkspace)
    }

    func testRetainedAXFirstContextKeepsInitialInteractionWorkspace() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setInteractionMonitor(fixture.secondary.id))

        let first = fixture.controller.axEventHandler.retainedCreatePlacementContext(
            windowId: 601,
            controller: fixture.controller
        )
        XCTAssertTrue(manager.setInteractionMonitor(fixture.primary.id))
        let retained = fixture.controller.axEventHandler.retainedCreatePlacementContext(
            windowId: 601,
            controller: fixture.controller
        )

        XCTAssertEqual(first.interactionWorkspaceId, fixture.secondaryWorkspace)
        XCTAssertEqual(retained, first)
        fixture.controller.axEventHandler.discardCreatePlacementContext(windowId: 601)
    }

    func testRetainedAXFirstContextMergesLateNativeSpaceMonitorOnlyOnce() throws {
        let fixture = try makeTwoMonitorFixture()
        let manager = fixture.controller.workspaceManager
        let secondary = manager.addWindow(
            axRef(6_122, 603),
            pid: 6_122,
            windowId: 603,
            to: fixture.secondaryWorkspace
        )
        _ = manager.confirmManagedFocus(
            secondary,
            in: fixture.secondaryWorkspace,
            activateWorkspaceOnMonitor: false
        )

        let first = fixture.controller.axEventHandler.retainedCreatePlacementContext(
            windowId: 604,
            controller: fixture.controller
        )

        let primary = manager.addWindow(
            axRef(6_123, 605),
            pid: 6_123,
            windowId: 605,
            to: fixture.primaryWorkspace
        )
        _ = manager.confirmManagedFocus(
            primary,
            in: fixture.primaryWorkspace,
            activateWorkspaceOnMonitor: false
        )

        let merged = fixture.controller.axEventHandler.retainedCreatePlacementContext(
            windowId: 604,
            controller: fixture.controller,
            nativeSpaceMonitorId: fixture.primary.id
        )
        let retained = fixture.controller.axEventHandler.retainedCreatePlacementContext(
            windowId: 604,
            controller: fixture.controller,
            nativeSpaceMonitorId: fixture.secondary.id
        )

        XCTAssertNil(first.nativeSpaceMonitorId)
        XCTAssertEqual(merged.nativeSpaceMonitorId, fixture.primary.id)
        XCTAssertEqual(merged.pendingFocusedWorkspaceId, first.pendingFocusedWorkspaceId)
        XCTAssertEqual(merged.pendingFocusedMonitorId, first.pendingFocusedMonitorId)
        XCTAssertEqual(merged.focusedWorkspaceId, first.focusedWorkspaceId)
        XCTAssertEqual(merged.focusedMonitorId, first.focusedMonitorId)
        XCTAssertEqual(merged.interactionWorkspaceId, first.interactionWorkspaceId)
        XCTAssertEqual(merged.interactionMonitorId, first.interactionMonitorId)
        XCTAssertEqual(merged.createdAt, first.createdAt)
        XCTAssertEqual(retained, merged)
        fixture.controller.axEventHandler.discardCreatePlacementContext(windowId: 604)
    }

    func testCapturedContextPromotesDiscoveryRetryToLiveCreate() {
        let context = placementContext()

        XCTAssertEqual(
            AXEventHandler.effectivePlacementOrigin(
                .discovery,
                createPlacementContext: context
            ),
            .liveCreate
        )
        XCTAssertEqual(
            AXEventHandler.effectivePlacementOrigin(
                .discovery,
                createPlacementContext: nil
            ),
            .discovery
        )
    }

    func testExpiredCreateContextIsNotConsumed() throws {
        let fixture = try makeTwoMonitorFixture()
        let windowId: UInt32 = 602
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)
        fixture.controller.axEventHandler.createPlacementContextsByWindowId[windowId] = placementContext(
            interactionWorkspaceId: fixture.secondaryWorkspace,
            interactionMonitorId: fixture.secondary.id,
            createdAt: createdAt
        )

        XCTAssertNil(
            fixture.controller.axEventHandler.pendingCreatePlacementContext(
                for: Int(windowId),
                now: createdAt.addingTimeInterval(AXEventHandler.createPlacementContextTTL)
            )
        )
        XCTAssertNil(fixture.controller.axEventHandler.createPlacementContextsByWindowId[windowId])
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
            placementMode: .tiling,
            placementOrigin: .discovery,
            createPlacementContext: placementContext(),
            windowFrame: capturedFrame
        )

        XCTAssertEqual(workspaceId, fixture.secondaryWorkspace)
    }

    private func resolvePlacement(
        _ fixture: TwoMonitorFixture,
        workspaceName: String? = nil,
        pid: pid_t,
        parentWindowId: UInt32? = nil,
        inheritTrackedParentWorkspace: Bool = false,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID? = nil,
        placementMode: TrackedWindowMode,
        allowsFloatingSpawnPlacement: Bool = false,
        origin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        existingEntry: WindowState? = nil,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext = .automatic
    ) -> WorkspacePlacementResolution {
        PlacementResolver(workspaceManager: fixture.controller.workspaceManager).resolveWorkspacePlacement(
            workspaceName: workspaceName,
            axRef: axRef(pid, 10_000),
            pid: pid,
            parentWindowId: parentWindowId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            structuralReplacementWorkspaceId: structuralReplacementWorkspaceId,
            placementMode: placementMode,
            allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement,
            origin: origin,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            existingEntry: existingEntry,
            fallbackWorkspaceId: fallbackWorkspaceId,
            context: context
        )
    }

    private func placementEvaluation(
        bundleId: String?,
        subrole: String?
    ) -> WMController.WindowDecisionEvaluation {
        let token = WindowToken(pid: 6_130, windowId: 576)
        let facts = WindowRuleFacts(
            appName: "Placement",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: subrole,
                title: "Placement",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: nil
        )
        return WMController.WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: WindowDecision(
                disposition: .floating,
                source: .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
    }

    private func placementContext(
        nativeSpaceMonitorId: Monitor.ID? = nil,
        pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? = nil,
        pendingFocusedMonitorId: Monitor.ID? = nil,
        focusedWorkspaceId: WorkspaceDescriptor.ID? = nil,
        focusedMonitorId: Monitor.ID? = nil,
        interactionWorkspaceId: WorkspaceDescriptor.ID? = nil,
        interactionMonitorId: Monitor.ID? = nil,
        createdAt: Date = Date()
    ) -> WindowCreatePlacementContext {
        WindowCreatePlacementContext(
            nativeSpaceMonitorId: nativeSpaceMonitorId,
            pendingFocusedWorkspaceId: pendingFocusedWorkspaceId,
            pendingFocusedMonitorId: pendingFocusedMonitorId,
            focusedWorkspaceId: focusedWorkspaceId,
            focusedMonitorId: focusedMonitorId,
            interactionWorkspaceId: interactionWorkspaceId,
            interactionMonitorId: interactionMonitorId,
            createdAt: createdAt
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
