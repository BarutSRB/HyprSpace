// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FloatingMonitorRebindFocusTests: XCTestCase {
    private final class FocusRecorder {
        var focusedTokens: [WindowToken] = []
    }

    private final class SessionRecorder {
        var changeCount = 0
    }

    private struct Fixture {
        let controller: WMController
        let sourceMonitor: Monitor
        let targetMonitor: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let inactiveTargetWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let focusRecorder: FocusRecorder
    }

    func testFocusedFloatingRebindTransfersFocusSessionWithoutRefocusing() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.deadlineWheel.stop() }
        let manager = controller.workspaceManager
        let sourceFallback = addFloatingWindow(
            pid: 489_001,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let moving = addFloatingWindow(
            pid: 489_001,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let targetFallback = addFloatingWindow(
            pid: 489_001,
            windowId: 3,
            to: fixture.targetWorkspaceId,
            controller: controller
        )

        _ = manager.rememberFocus(targetFallback, in: fixture.targetWorkspaceId)
        _ = manager.rememberFocus(sourceFallback, in: fixture.sourceWorkspaceId)
        XCTAssertTrue(
            manager.setManagedFocus(
                moving,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id
            )
        )
        controller.layoutRefreshController.resetState()
        fixture.focusRecorder.focusedTokens.removeAll()
        let sessionRecorder = SessionRecorder()
        manager.onSessionStateChanged = {
            sessionRecorder.changeCount += 1
        }

        rebind(moving, fixture: fixture)

        XCTAssertEqual(manager.workspace(for: moving), fixture.targetWorkspaceId)
        XCTAssertEqual(manager.focusedToken, moving)
        XCTAssertEqual(manager.interactionMonitorId, fixture.targetMonitor.id)
        XCTAssertEqual(manager.previousInteractionMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.sourceWorkspaceId), sourceFallback)
        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: fixture.sourceWorkspaceId), sourceFallback)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.targetWorkspaceId), moving)
        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: fixture.targetWorkspaceId), moving)
        XCTAssertNil(manager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertGreaterThan(sessionRecorder.changeCount, 0)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")

        controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: false)
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.targetMonitor.id)?.id,
            fixture.inactiveTargetWorkspaceId
        )
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.sourceMonitor.id)?.id,
            fixture.sourceWorkspaceId
        )
        controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        XCTAssertEqual(
            manager.activeWorkspace(on: fixture.targetMonitor.id)?.id,
            fixture.targetWorkspaceId
        )
        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: fixture.targetWorkspaceId), moving)
    }

    func testFloatingRebindRetargetsMatchingPendingFocusRequest() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.deadlineWheel.stop() }
        let manager = controller.workspaceManager
        let sourceFallback = addFloatingWindow(
            pid: 489_002,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let moving = addFloatingWindow(
            pid: 489_002,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let targetFallback = addFloatingWindow(
            pid: 489_002,
            windowId: 3,
            to: fixture.targetWorkspaceId,
            controller: controller
        )

        _ = manager.rememberFocus(targetFallback, in: fixture.targetWorkspaceId)
        _ = manager.rememberFocus(sourceFallback, in: fixture.sourceWorkspaceId)
        let request = controller.intentLedger.beginManagedRequest(
            token: moving,
            workspaceId: fixture.sourceWorkspaceId,
            origin: .pointerHover
        )
        let retriedRequest = try XCTUnwrap(
            controller.intentLedger.recordRetry(
                requestId: request.requestId,
                source: .workspaceDidActivateApplication,
                retryLimit: 2
            )
        )
        let intentBeforeRebind = try XCTUnwrap(
            controller.intentLedger.intent(id: request.requestId)
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                moving,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id,
                requestId: request.requestId
            )
        )
        controller.layoutRefreshController.resetState()

        rebind(moving, fixture: fixture)

        let retargeted = try XCTUnwrap(controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(retargeted.requestId, request.requestId)
        XCTAssertEqual(retargeted.token, moving)
        XCTAssertEqual(retargeted.workspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(retargeted.origin, .pointerHover)
        XCTAssertEqual(retargeted.retryCount, retriedRequest.retryCount)
        XCTAssertEqual(retargeted.lastActivationSource, retriedRequest.lastActivationSource)
        let intentAfterRebind = try XCTUnwrap(
            controller.intentLedger.intent(id: request.requestId)
        )
        XCTAssertEqual(intentAfterRebind.issuedAtSeq, intentBeforeRebind.issuedAtSeq)
        XCTAssertEqual(manager.pendingFocusedToken, moving)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.targetMonitor.id)
        XCTAssertNil(manager.focusedToken)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.sourceWorkspaceId), sourceFallback)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.targetWorkspaceId), moving)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")

        XCTAssertNotNil(
            controller.intentLedger.confirmManagedRequest(
                token: moving,
                source: .focusedWindowChanged
            )
        )
        XCTAssertTrue(
            manager.confirmManagedFocus(
                moving,
                in: fixture.targetWorkspaceId,
                onMonitor: fixture.targetMonitor.id,
                activateWorkspaceOnMonitor: false,
                requestId: request.requestId
            )
        )
        XCTAssertEqual(manager.focusedToken, moving)
        XCTAssertNil(manager.pendingFocusedToken)
        XCTAssertEqual(manager.interactionMonitorId, fixture.targetMonitor.id)
    }

    func testFocusedFloatingRebindRetargetsMatchingRequestAtomically() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        defer {
            manager.onSessionStateChanged = nil
            controller.deadlineWheel.stop()
        }
        let moving = addFloatingWindow(
            pid: 489_009,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let newerTarget = addFloatingWindow(
            pid: 489_009,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                moving,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id
            )
        )
        let request = controller.intentLedger.beginManagedRequest(
            token: moving,
            workspaceId: fixture.sourceWorkspaceId,
            origin: .pointerHover
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                moving,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id,
                requestId: request.requestId
            )
        )
        fixture.focusRecorder.focusedTokens.removeAll()

        var notificationStates: [(
            interactionMonitorId: Monitor.ID?,
            pendingToken: WindowToken?,
            pendingWorkspaceId: WorkspaceDescriptor.ID?
        )] = []
        var injectedNewerRequest = false
        var newerRequest: ManagedFocusRequest?
        manager.onSessionStateChanged = {
            notificationStates.append((
                interactionMonitorId: manager.interactionMonitorId,
                pendingToken: manager.pendingFocusedToken,
                pendingWorkspaceId: manager.pendingFocusedWorkspaceId
            ))
            guard !injectedNewerRequest else { return }
            injectedNewerRequest = true
            _ = manager.setInteractionMonitor(fixture.sourceMonitor.id)
            let request = controller.intentLedger.beginManagedRequest(
                token: newerTarget,
                workspaceId: fixture.sourceWorkspaceId
            )
            newerRequest = request
            _ = manager.beginManagedFocusRequest(
                newerTarget,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id,
                requestId: request.requestId
            )
        }

        rebind(moving, fixture: fixture)

        let firstNotification = try XCTUnwrap(notificationStates.first)
        let injectedRequest = try XCTUnwrap(newerRequest)
        XCTAssertEqual(firstNotification.interactionMonitorId, fixture.targetMonitor.id)
        XCTAssertEqual(firstNotification.pendingToken, moving)
        XCTAssertEqual(firstNotification.pendingWorkspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, injectedRequest.requestId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, newerTarget)
        XCTAssertEqual(manager.pendingFocusedToken, newerTarget)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, fixture.sourceWorkspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")
    }

    func testBackgroundFloatingRebindDoesNotStealFocusAndSchedulesSurfaceReconcile() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let focused = addFloatingWindow(
            pid: 489_004,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let moving = addFloatingWindow(
            pid: 489_004,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let targetFallback = addFloatingWindow(
            pid: 489_004,
            windowId: 3,
            to: fixture.targetWorkspaceId,
            controller: controller
        )

        _ = manager.rememberFocus(targetFallback, in: fixture.targetWorkspaceId)
        XCTAssertTrue(
            manager.setManagedFocus(
                focused,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id
            )
        )
        controller.surfaceReconciler.cleanup()
        controller.layoutRefreshController.resetState()
        fixture.focusRecorder.focusedTokens.removeAll()
        let sourceProjectionBefore = projection(on: fixture.sourceMonitor, fixture: fixture)
        XCTAssertTrue(
            sourceProjectionBefore.items
                .first { $0.id == fixture.sourceWorkspaceId }?
                .floatingWindows.contains { $0.id == moving } == true
        )

        rebind(moving, fixture: fixture)

        XCTAssertEqual(manager.workspace(for: moving), fixture.targetWorkspaceId)
        XCTAssertEqual(manager.focusedToken, focused)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.targetWorkspaceId), targetFallback)
        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: fixture.targetWorkspaceId), targetFallback)
        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        let sourceProjectionAfter = projection(on: fixture.sourceMonitor, fixture: fixture)
        let targetProjectionAfter = projection(on: fixture.targetMonitor, fixture: fixture)
        XCTAssertFalse(
            sourceProjectionAfter.items
                .first { $0.id == fixture.sourceWorkspaceId }?
                .floatingWindows.contains { $0.id == moving } == true
        )
        XCTAssertTrue(
            targetProjectionAfter.items
                .first { $0.id == fixture.targetWorkspaceId }?
                .floatingWindows.contains { $0.id == moving } == true
        )
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")
    }

    func testBackgroundDwindleRebindPreservesValidSourceFloatingMRU() throws {
        let fixture = try makeFixture(sourceLayout: .dwindle)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let tiled = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(489_008), windowId: 1),
            pid: 489_008,
            windowId: 1,
            to: fixture.sourceWorkspaceId
        )
        manager.withEngineMutationScope(in: fixture.sourceWorkspaceId) {
            _ = engine.addWindow(
                token: tiled,
                to: fixture.sourceWorkspaceId,
                activeWindowFrame: nil
            )
        }
        let rememberedFloating = addFloatingWindow(
            pid: 489_008,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let moving = addFloatingWindow(
            pid: 489_008,
            windowId: 3,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                rememberedFloating,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id
            )
        )
        XCTAssertEqual(engine.selectedNode(in: fixture.sourceWorkspaceId)?.windowToken, tiled)

        rebind(moving, fixture: fixture)

        XCTAssertEqual(manager.workspace(for: moving), fixture.targetWorkspaceId)
        XCTAssertEqual(manager.focusedToken, rememberedFloating)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(
            manager.lastFloatingFocusedToken(in: fixture.sourceWorkspaceId),
            rememberedFloating
        )
        XCTAssertEqual(
            manager.resolveWorkspaceFocusToken(in: fixture.sourceWorkspaceId),
            rememberedFloating
        )
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")
    }

    func testFloatingMembershipUsesCenterForResizeBoundaryAndOffscreenFrames() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let resized = addFloatingWindow(
            pid: 489_005,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        let boundary = addFloatingWindow(
            pid: 489_005,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        let offscreen = addFloatingWindow(
            pid: 489_005,
            windowId: 3,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        let preseededTargetGeometry = addFloatingWindow(
            pid: 489_005,
            windowId: 4,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )

        rebind(
            resized,
            frame: CGRect(x: 1_300, y: 120, width: 400, height: 480),
            fixture: fixture
        )
        XCTAssertEqual(manager.workspace(for: resized), fixture.sourceWorkspaceId)
        rebind(
            resized,
            frame: CGRect(x: 1_300, y: 120, width: 800, height: 480),
            fixture: fixture
        )
        XCTAssertEqual(manager.workspace(for: resized), fixture.targetWorkspaceId)
        XCTAssertEqual(manager.floatingState(for: resized)?.referenceMonitorId, fixture.targetMonitor.id)

        rebind(
            boundary,
            frame: CGRect(x: 1_500, y: 120, width: 200, height: 480),
            fixture: fixture
        )
        XCTAssertEqual(manager.workspace(for: boundary), fixture.targetWorkspaceId)

        rebind(
            offscreen,
            frame: CGRect(x: 4_000, y: 120, width: 640, height: 480),
            fixture: fixture
        )
        XCTAssertEqual(manager.workspace(for: offscreen), fixture.targetWorkspaceId)
        XCTAssertEqual(manager.floatingState(for: offscreen)?.referenceMonitorId, fixture.targetMonitor.id)

        let targetFrame = CGRect(x: 1_900, y: 120, width: 640, height: 480)
        manager.updateFloatingGeometry(
            frame: targetFrame,
            for: preseededTargetGeometry,
            referenceMonitor: fixture.targetMonitor
        )
        XCTAssertEqual(manager.workspace(for: preseededTargetGeometry), fixture.sourceWorkspaceId)
        rebind(preseededTargetGeometry, frame: targetFrame, fixture: fixture)
        XCTAssertEqual(manager.workspace(for: preseededTargetGeometry), fixture.targetWorkspaceId)
    }

    func testInvalidHiddenAndScratchpadFramesDoNotRebindMembership() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let invalid = addFloatingWindow(
            pid: 489_006,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        let hidden = addFloatingWindow(
            pid: 489_006,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )
        let scratchpad = addFloatingWindow(
            pid: 489_006,
            windowId: 3,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )

        rebind(invalid, frame: .zero, fixture: fixture)
        rebind(
            invalid,
            frame: CGRect(x: CGFloat.nan, y: 120, width: 640, height: 480),
            fixture: fixture
        )
        XCTAssertEqual(manager.workspace(for: invalid), fixture.sourceWorkspaceId)
        XCTAssertNil(manager.floatingState(for: invalid))

        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.sourceMonitor.id,
                reason: .workspaceInactive
            ),
            for: hidden
        )
        rebind(hidden, fixture: fixture)
        XCTAssertEqual(manager.workspace(for: hidden), fixture.sourceWorkspaceId)
        XCTAssertNil(manager.floatingState(for: hidden))
        manager.setHiddenState(nil, for: hidden)
        rebind(hidden, fixture: fixture)
        XCTAssertEqual(manager.workspace(for: hidden), fixture.targetWorkspaceId)

        XCTAssertTrue(manager.setScratchpadToken(scratchpad))
        rebind(scratchpad, fixture: fixture)
        XCTAssertEqual(manager.workspace(for: scratchpad), fixture.sourceWorkspaceId)
        XCTAssertEqual(
            manager.floatingState(for: scratchpad)?.referenceMonitorId,
            fixture.targetMonitor.id
        )
        XCTAssertTrue(manager.setScratchpadToken(nil))
        rebind(scratchpad, fixture: fixture)
        XCTAssertEqual(manager.workspace(for: scratchpad), fixture.targetWorkspaceId)
    }

    func testReboundFloatingWindowRemainsCoherentAfterTargetMonitorRemoval() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let moving = addFloatingWindow(
            pid: 489_007,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: fixture.controller
        )

        rebind(moving, fixture: fixture)
        manager.applyMonitorConfigurationChange([fixture.sourceMonitor])

        let entry = try XCTUnwrap(manager.entry(for: moving))
        let resolvedFrame = try XCTUnwrap(
            manager.resolvedFloatingFrame(
                for: moving,
                preferredMonitor: fixture.sourceMonitor
            )
        )
        XCTAssertEqual(entry.workspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(entry.observedState.monitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.monitorId(for: fixture.targetWorkspaceId), fixture.sourceMonitor.id)
        XCTAssertTrue(resolvedFrame.origin.x.isFinite)
        XCTAssertTrue(resolvedFrame.origin.y.isFinite)
        XCTAssertTrue(resolvedFrame.width.isFinite)
        XCTAssertTrue(resolvedFrame.height.isFinite)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")
    }

    func testFloatingRebindDoesNotOverrideNewerUnrelatedFocusRequest() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.deadlineWheel.stop() }
        let manager = controller.workspaceManager
        let moving = addFloatingWindow(
            pid: 489_003,
            windowId: 1,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let newerTarget = addFloatingWindow(
            pid: 489_003,
            windowId: 2,
            to: fixture.sourceWorkspaceId,
            controller: controller
        )
        let targetFallback = addFloatingWindow(
            pid: 489_003,
            windowId: 3,
            to: fixture.targetWorkspaceId,
            controller: controller
        )

        _ = manager.rememberFocus(targetFallback, in: fixture.targetWorkspaceId)
        XCTAssertTrue(
            manager.setManagedFocus(
                moving,
                in: fixture.sourceWorkspaceId,
                onMonitor: fixture.sourceMonitor.id
            )
        )
        let superseded = controller.intentLedger.beginManagedRequest(
            token: moving,
            workspaceId: fixture.sourceWorkspaceId,
            origin: .pointerHover
        )
        _ = manager.beginManagedFocusRequest(
            moving,
            in: fixture.sourceWorkspaceId,
            onMonitor: fixture.sourceMonitor.id,
            requestId: superseded.requestId
        )
        let newer = controller.intentLedger.beginManagedRequest(
            token: newerTarget,
            workspaceId: fixture.sourceWorkspaceId
        )
        _ = manager.beginManagedFocusRequest(
            newerTarget,
            in: fixture.sourceWorkspaceId,
            onMonitor: fixture.sourceMonitor.id,
            requestId: newer.requestId
        )
        controller.layoutRefreshController.resetState()
        fixture.focusRecorder.focusedTokens.removeAll()

        rebind(moving, fixture: fixture)

        XCTAssertEqual(manager.workspace(for: moving), fixture.targetWorkspaceId)
        XCTAssertEqual(controller.intentLedger.intent(id: superseded.requestId)?.phase, .superseded)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, newer.requestId)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, newerTarget)
        XCTAssertEqual(
            controller.intentLedger.activeManagedRequest?.workspaceId,
            fixture.sourceWorkspaceId
        )
        XCTAssertEqual(manager.pendingFocusedToken, newerTarget)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, fixture.sourceWorkspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.focusedToken, moving)
        XCTAssertEqual(manager.interactionMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(manager.lastFloatingFocusedToken(in: fixture.targetWorkspaceId), targetFallback)
        XCTAssertEqual(manager.resolveWorkspaceFocusToken(in: fixture.targetWorkspaceId), targetFallback)
        XCTAssertTrue(fixture.focusRecorder.focusedTokens.isEmpty)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(manager.invariantViolationCountsDump(), "clean")
    }

    private func rebind(
        _ token: WindowToken,
        frame: CGRect? = nil,
        fixture: Fixture
    ) {
        guard let entry = fixture.controller.workspaceManager.entry(for: token) else {
            return XCTFail("Expected tracked floating entry")
        }
        let targetFrame = frame ?? CGRect(
            x: fixture.targetMonitor.frame.minX + 120,
            y: fixture.targetMonitor.frame.minY + 120,
            width: 640,
            height: 480
        )
        fixture.controller.axEventHandler.updateFloatingWindowGeometryAndMonitorMembership(
            entry: entry,
            frame: targetFrame
        )
    }

    private func makeFixture(sourceLayout: LayoutType = .niri) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingMonitorRebindFocusTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let targetFrame = CGRect(x: 1600, y: 0, width: 1600, height: 900)
        let sourceMonitor = Monitor(
            id: .init(displayId: 489_010),
            displayId: 489_010,
            frame: sourceFrame,
            visibleFrame: sourceFrame,
            hasNotch: false,
            name: "Floating Rebind Source"
        )
        let targetMonitor = Monitor(
            id: .init(displayId: 489_011),
            displayId: 489_011,
            frame: targetFrame,
            visibleFrame: targetFrame,
            hasNotch: false,
            name: "Floating Rebind Target"
        )
        let settings = SettingsStore(
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
        settings.animationsEnabled = false
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: sourceLayout
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: targetMonitor)),
                layoutType: .niri
            )
        ]

        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.focusedTokens.append(
                        WindowToken(pid: pid, windowId: Int(windowId))
                    )
                },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, targetMonitor])
        controller.workspaceManager.applySettings()

        let sourceWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let inactiveTargetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(named: "2")
        )
        let targetWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "3"))
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                inactiveTargetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                targetWorkspaceId,
                on: targetMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            controller.workspaceManager.setActiveWorkspace(
                sourceWorkspaceId,
                on: sourceMonitor.id
            )
        )
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            sourceMonitor: sourceMonitor,
            targetMonitor: targetMonitor,
            sourceWorkspaceId: sourceWorkspaceId,
            inactiveTargetWorkspaceId: inactiveTargetWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            focusRecorder: focusRecorder
        )
    }

    private func projection(
        on monitor: Monitor,
        fixture: Fixture
    ) -> WorkspaceBarProjection {
        let controller = fixture.controller
        return WorkspaceBarDataSource.workspaceBarProjection(
            for: monitor,
            options: WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false,
                hideEmptyWorkspaces: false,
                showFloatingWindows: true,
                excludedBundleIDs: []
            ),
            workspaceManager: controller.workspaceManager,
            appInfoCache: controller.appInfoCache,
            iconResolver: controller.workspaceBarIconResolver,
            focusedToken: controller.workspaceManager.focusedToken,
            settings: controller.settings
        )
    }

    private func addFloatingWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
    }
}
