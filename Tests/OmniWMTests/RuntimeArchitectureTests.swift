// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class RuntimeArchitectureTests: XCTestCase {
    func testHyprlandDwindleBezierStartsAndEndsAtBounds() {
        let config = CubicConfig.hyprlandDwindle
        let startTime = 4.0
        let animation = CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: startTime,
            config: config
        )

        XCTAssertEqual(animation.value(at: startTime), 0.0, accuracy: 0.000001)
        XCTAssertEqual(animation.value(at: startTime + config.duration), 1.0, accuracy: 0.000001)
        XCTAssertTrue(animation.isComplete(at: startTime + config.duration))
    }

    func testHyprlandDwindleBezierIsMonotonicAndSnappy() {
        let config = CubicConfig.hyprlandDwindle
        let startTime = 9.0
        let animation = CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: startTime,
            config: config
        )
        var previous = -Double.infinity

        for step in 0 ... 40 {
            let time = startTime + config.duration * Double(step) / 40.0
            let value = animation.value(at: time)
            XCTAssertGreaterThanOrEqual(value + 0.000001, previous)
            previous = value
        }

        let quarterValue = animation.value(at: startTime + config.duration * 0.25)
        XCTAssertGreaterThan(quarterValue, 0.65)
        XCTAssertLessThan(quarterValue, 1.0)
    }

    func testDwindleRectAnimationRetargetsFromPresentedFrame() throws {
        let config = CubicConfig.hyprlandDwindle
        let node = DwindleNode(
            kind: .leaf(tile: DwindleTile(token: WindowToken(pid: 10, windowId: 20)))
        )
        let firstStart = CGRect(x: 10, y: 20, width: 320, height: 180)
        let firstTarget = CGRect(x: 200, y: 80, width: 480, height: 240)
        let secondTarget = CGRect(x: 60, y: 140, width: 360, height: 420)
        let retargetTime = config.duration * 0.35

        node.cachedFrame = firstTarget
        node.animateFrom(
            oldFrame: firstStart,
            newFrame: firstTarget,
            startTime: 0,
            config: config,
            animated: true
        )

        let visibleFrame = try XCTUnwrap(node.presentedFrame(at: retargetTime))
        node.cachedFrame = secondTarget
        node.animateFrom(
            oldFrame: visibleFrame,
            newFrame: secondTarget,
            startTime: retargetTime,
            config: config,
            animated: true
        )

        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: retargetTime)),
            equals: visibleFrame
        )
    }

    func testDwindleRectAnimationUsesSingleProgressForFrameComponents() throws {
        let config = CubicConfig.hyprlandDwindle
        let node = DwindleNode(
            kind: .leaf(tile: DwindleTile(token: WindowToken(pid: 11, windowId: 21)))
        )
        let startFrame = CGRect(x: 20, y: 40, width: 300, height: 200)
        let targetFrame = CGRect(x: 220, y: 160, width: 500, height: 440)
        let sampleTime = config.duration * 0.5
        let progress = CGFloat(CubicAnimation(
            from: 0.0,
            to: 1.0,
            startTime: 0,
            config: config
        ).value(at: sampleTime))

        node.cachedFrame = targetFrame
        node.animateFrom(
            oldFrame: startFrame,
            newFrame: targetFrame,
            startTime: 0,
            config: config,
            animated: true
        )

        let expectedFrame = CGRect(
            x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * progress,
            y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * progress,
            width: startFrame.width + (targetFrame.width - startFrame.width) * progress,
            height: startFrame.height + (targetFrame.height - startFrame.height) * progress
        )
        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: sampleTime)),
            equals: expectedFrame
        )

        node.tickAnimations(at: config.duration)
        XCTAssertFalse(node.hasActiveAnimations(at: config.duration))
        Self.assertFrame(
            try XCTUnwrap(node.presentedFrame(at: config.duration)),
            equals: targetFrame
        )
    }

    func testInvalidationMarksRejectOnlyRelevantDomains() {
        var marks = InvalidationMarks()
        marks.record(5, domains: .focus)
        XCTAssertTrue(marks.isCurrent(4, domains: .layoutCommit))
        XCTAssertFalse(marks.isCurrent(4, domains: .focusCommit))

        marks.record(6, domains: .layout)
        XCTAssertFalse(marks.isCurrent(5, domains: .layoutCommit))
        XCTAssertTrue(marks.isCurrent(6, domains: [.workspace, .layout, .focus, .fullscreen]))

        marks.record(7, domains: .fullscreen)
        XCTAssertFalse(marks.isCurrent(6, domains: .layoutCommit))
        XCTAssertTrue(marks.isCurrent(6, domains: .focusCommit))

        let merged = marks.merged(with: InvalidationMarks(workspace: 9, layout: 0, focus: 0, fullscreen: 0))
        XCTAssertFalse(merged.isCurrent(8, domains: .layoutCommit))
        XCTAssertTrue(merged.isCurrent(9, domains: [.workspace, .layout, .focus, .fullscreen]))
    }

    func testManagedFocusRequestCarriesRequestId() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let plan = StateReducer.reduce(
            event: .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: Self.snapshot(),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.token, token)
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.workspaceId, workspaceId)
        XCTAssertEqual(plan.focusSession?.pendingManagedFocus.requestId, 7)
        XCTAssertTrue(plan.mutatesRuntimeState)
    }

    func testIsSystemModalSurfaceClassification() {
        XCTAssertTrue(AXWindowService.isSystemModalSurface(role: kAXSheetRole as String, subrole: nil))
        XCTAssertTrue(AXWindowService.isSystemModalSurface(role: nil, subrole: kAXDialogSubrole as String))
        XCTAssertTrue(AXWindowService.isSystemModalSurface(role: nil, subrole: kAXSystemDialogSubrole as String))
        XCTAssertFalse(
            AXWindowService.isSystemModalSurface(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String
            )
        )
        XCTAssertFalse(AXWindowService.isSystemModalSurface(role: nil, subrole: nil))
    }

    func testSystemModalFocusChangedSetsToken() {
        let token = WindowToken(pid: 100, windowId: 42)
        let plan = StateReducer.reduce(
            event: .systemModalFocusChanged(token: token, source: .workspaceManager),
            existingEntry: nil,
            currentSnapshot: Self.snapshot(),
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.systemModalFocusToken, token)
    }

    func testSystemModalFocusChangedClearsToken() {
        let token = WindowToken(pid: 100, windowId: 42)
        let modalSnapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(systemModalFocusToken: token),
            windows: [],
            viewports: [:],
            layouts: [:]
        )

        let plan = StateReducer.reduce(
            event: .systemModalFocusChanged(token: nil, source: .workspaceManager),
            existingEntry: nil,
            currentSnapshot: modalSnapshot,
            monitors: []
        )

        XCTAssertNil(plan.focusSession?.systemModalFocusToken)
    }

    func testWindowRekeyRekeysSystemModalFocusToken() {
        let workspaceId = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 100, windowId: 42)
        let newToken = WindowToken(pid: 100, windowId: 43)
        let snapshot = Self.snapshot(
            systemModalFocusToken: oldToken,
            windows: [Self.window(token: oldToken, workspaceId: workspaceId)]
        )

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
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.systemModalFocusToken, newToken)
    }

    func testWindowRemovalClearsMatchingSystemModalFocusTokenOnly() {
        let workspaceId = WorkspaceDescriptor.ID()
        let modalToken = WindowToken(pid: 100, windowId: 42)
        let removedToken = WindowToken(pid: 100, windowId: 43)
        let matchingSnapshot = Self.snapshot(systemModalFocusToken: modalToken)
        let nonmatchingSnapshot = Self.snapshot(systemModalFocusToken: modalToken)

        let matchingPlan = StateReducer.reduce(
            event: .windowRemoved(token: modalToken, workspaceId: workspaceId, source: .workspaceManager),
            existingEntry: nil,
            currentSnapshot: matchingSnapshot,
            monitors: []
        )
        let nonmatchingPlan = StateReducer.reduce(
            event: .windowRemoved(token: removedToken, workspaceId: workspaceId, source: .workspaceManager),
            existingEntry: nil,
            currentSnapshot: nonmatchingSnapshot,
            monitors: []
        )

        XCTAssertNil(matchingPlan.focusSession?.systemModalFocusToken)
        XCTAssertEqual(nonmatchingPlan.focusSession?.systemModalFocusToken, modalToken)
    }

    @MainActor
    func testManagedFocusRequestCarriesOriginAndResistsPointerDowngrade() {
        let bridge = IntentLedger()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)

        let pointerRequest = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .pointerHover
        )
        XCTAssertEqual(pointerRequest.origin, .pointerHover)
        XCTAssertFalse(pointerRequest.origin.allowsMouseToFocusedWarp)

        let keyboardRequest = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .keyboardOrProgrammatic
        )
        XCTAssertEqual(keyboardRequest.requestId, pointerRequest.requestId)
        XCTAssertEqual(keyboardRequest.origin, .keyboardOrProgrammatic)
        XCTAssertTrue(keyboardRequest.origin.allowsMouseToFocusedWarp)

        let repeatedPointerRequest = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .pointerHover
        )
        XCTAssertEqual(repeatedPointerRequest.requestId, pointerRequest.requestId)
        XCTAssertEqual(repeatedPointerRequest.origin, .keyboardOrProgrammatic)
    }

    @MainActor
    func testConfirmedManagedFocusOriginControlsMouseWarpPolicy() throws {
        let bridge = IntentLedger()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let rekeyedToken = WindowToken(pid: 100, windowId: 43)

        _ = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .pointerHover
        )
        let pointerConfirmation = try XCTUnwrap(bridge.confirmManagedRequest(
            token: token,
            source: .focusedWindowChanged
        ))

        XCTAssertEqual(pointerConfirmation.origin, .pointerHover)
        XCTAssertFalse(bridge.allowsMouseToFocusedWarp(for: token))
        XCTAssertTrue(bridge.allowsMouseToFocusedWarp(for: rekeyedToken))

        bridge.rekeyManagedRequest(from: token, to: rekeyedToken)
        XCTAssertTrue(bridge.allowsMouseToFocusedWarp(for: token))
        XCTAssertFalse(bridge.allowsMouseToFocusedWarp(for: rekeyedToken))

        bridge.discardPendingFocus(rekeyedToken)
        XCTAssertTrue(bridge.allowsMouseToFocusedWarp(for: rekeyedToken))

        _ = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .pointerHover
        )
        _ = try XCTUnwrap(bridge.confirmManagedRequest(
            token: token,
            source: .focusedWindowChanged
        ))
        XCTAssertFalse(bridge.allowsMouseToFocusedWarp(for: token))

        _ = bridge.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .keyboardOrProgrammatic
        )
        XCTAssertTrue(bridge.allowsMouseToFocusedWarp(for: token))
        let keyboardConfirmation = try XCTUnwrap(bridge.confirmManagedRequest(
            token: token,
            source: .focusedWindowChanged
        ))

        XCTAssertEqual(keyboardConfirmation.origin, .keyboardOrProgrammatic)
        XCTAssertTrue(bridge.allowsMouseToFocusedWarp(for: token))
    }

    @MainActor
    func testPointerHoverManagedFocusDoesNotMoveMouseToFocusedWindowOnActivationConfirm() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .pointerHover,
            pid: 765_700,
            windowId: 765_800
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: fixture.requestId
        )

        XCTAssertTrue(warpedPoints.isEmpty)
    }

    @MainActor
    func testPointerHoverManagedFocusConfirmationPreservesSettledNiriViewport() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .pointerHover,
            pid: 765_710,
            windowId: 765_810
        )
        let controller = fixture.controller
        let workspaceId = fixture.entry.workspaceId
        let engine = try XCTUnwrap(controller.niriEngine)
        var now = ContinuousClock().now
        controller.intentLedger.clock = { now }

        for index in 1 ..< 3 {
            let pid = pid_t(765_710 + index)
            let windowId = 765_810 + index
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 700
        }

        let node = try XCTUnwrap(engine.findNode(for: fixture.entry.token, in: workspaceId))
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = node.id
            state.activeColumnIndex = 0
            state.jumpOffset(to: 300)
        }
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: workspaceId))

        controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: fixture.requestId
        )

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).viewOffset,
            300,
            accuracy: 0.001
        )
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: workspaceId))

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.jumpOffset(to: 300)
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).viewOffset,
            300,
            accuracy: 0.001
        )
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: workspaceId))

        now = now.advanced(by: .seconds(2))
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.jumpOffset(to: 300)
        }
        controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        XCTAssertNotEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).viewOffset,
            300,
            accuracy: 0.001
        )
    }

    @MainActor
    func testKeyboardManagedFocusStillMovesMouseToFocusedWindowOnActivationConfirm() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .keyboardOrProgrammatic,
            pid: 765_701,
            windowId: 765_801
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }
        fixture.controller.currentMouseLocation = { CGPoint(x: -10_000, y: -10_000) }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: fixture.requestId
        )

        XCTAssertEqual(warpedPoints.count, 1)
    }

    @MainActor
    func testHandsOffSurfaceFocusDoesNotActivateItsWorkspace() throws {
        let fixture = try Self.inactiveWorkspaceFocusFixture(
            policy: .handsOffSurface,
            pid: 765_760,
            windowId: 765_860
        )

        fixture.controller.axEventHandler.handleActivationFactsResolved(fixture.facts)

        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitorId)?.id,
            fixture.activeWorkspaceId
        )
        XCTAssertEqual(fixture.controller.workspaceManager.nonManagedFocusToken, fixture.token)
        XCTAssertNotEqual(fixture.controller.workspaceManager.focusedToken, fixture.token)
    }

    @MainActor
    func testFullPolicySurfaceFocusStillActivatesItsWorkspace() throws {
        let fixture = try Self.inactiveWorkspaceFocusFixture(
            policy: .full,
            pid: 765_761,
            windowId: 765_861
        )

        fixture.controller.axEventHandler.handleActivationFactsResolved(fixture.facts)

        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitorId)?.id,
            fixture.surfaceWorkspaceId
        )
    }

    @MainActor
    func testNiriPointerHoverConfirmedFocusDoesNotMoveMouseToFocusedWindowAfterAnimationSettles() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .pointerHover,
            pid: 765_702,
            windowId: 765_802
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }

        Self.confirmManagedNiriFocus(
            controller: fixture.controller,
            entry: fixture.entry,
            requestId: fixture.requestId
        )
        try Self.settleNiriAnimation(
            controller: fixture.controller,
            workspaceId: fixture.entry.workspaceId
        )

        XCTAssertTrue(warpedPoints.isEmpty)
    }

    @MainActor
    func testNiriKeyboardConfirmedFocusMovesMouseToFocusedWindowAfterAnimationSettles() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .keyboardOrProgrammatic,
            pid: 765_703,
            windowId: 765_803
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }
        fixture.controller.currentMouseLocation = { CGPoint(x: -10_000, y: -10_000) }

        Self.confirmManagedNiriFocus(
            controller: fixture.controller,
            entry: fixture.entry,
            requestId: fixture.requestId
        )
        try Self.settleNiriAnimation(
            controller: fixture.controller,
            workspaceId: fixture.entry.workspaceId
        )

        XCTAssertEqual(warpedPoints.count, 1)
    }

    @MainActor
    func testKeyboardManagedFocusDoesNotWarpWhenCursorInsideWindowOnActivationConfirm() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .keyboardOrProgrammatic,
            pid: 765_704,
            windowId: 765_804
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }
        let frame = try XCTUnwrap(fixture.controller.preferredKeyboardFocusFrame(for: fixture.entry.token))
        fixture.controller.currentMouseLocation = { frame.center }

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: fixture.requestId
        )

        XCTAssertTrue(warpedPoints.isEmpty)
    }

    @MainActor
    func testNiriKeyboardConfirmedFocusDoesNotWarpWhenCursorInsideWindowAfterAnimationSettles() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .keyboardOrProgrammatic,
            pid: 765_705,
            windowId: 765_805
        )
        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }
        let frame = try XCTUnwrap(fixture.controller.preferredKeyboardFocusFrame(for: fixture.entry.token))
        fixture.controller.currentMouseLocation = { frame.center }

        Self.confirmManagedNiriFocus(
            controller: fixture.controller,
            entry: fixture.entry,
            requestId: fixture.requestId
        )
        try Self.settleNiriAnimation(
            controller: fixture.controller,
            workspaceId: fixture.entry.workspaceId
        )

        XCTAssertTrue(warpedPoints.isEmpty)
    }

    @MainActor
    func testClickObservedManagedFocusDoesNotWarpWhenCursorInsideWindowWithoutManagedRequest() throws {
        let fixture = try Self.managedNiriActivationFixture(
            origin: .keyboardOrProgrammatic,
            pid: 765_706,
            windowId: 765_806
        )
        _ = fixture.controller.intentLedger.cancelManagedRequest(requestId: fixture.requestId)
        _ = fixture.controller.workspaceManager.cancelManagedFocusRequest(
            matching: fixture.entry.token,
            workspaceId: fixture.entry.workspaceId,
            requestId: fixture.requestId
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)

        var warpedPoints: [CGPoint] = []
        fixture.controller.warpMouseCursorPosition = { warpedPoints.append($0) }
        let frame = try XCTUnwrap(fixture.controller.preferredKeyboardFocusFrame(for: fixture.entry.token))
        fixture.controller.currentMouseLocation = { frame.center }
        fixture.controller.axEventHandler.noteMouseFocusIntent(token: fixture.entry.token)

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: fixture.entry,
            isWorkspaceActive: true,
            appFullscreen: false
        )

        XCTAssertTrue(warpedPoints.isEmpty)
    }

    @MainActor
    func testDwindlePointerHoverActivationFocusesImmediatelyWhenLayoutRefreshBlocked() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_702), windowId: 765_802),
            pid: 765_702,
            windowId: 765_802,
            to: workspaceId
        )
        _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.dwindleLayoutHandler.activateWindow(
            token,
            in: workspaceId,
            origin: .pointerHover,
            layoutRefresh: false
        )

        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
    }

    @MainActor
    func testNiriPointerHoverActivationFocusesImmediatelyWhenLayoutRefreshBlocked() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_703), windowId: 765_803),
            pid: 765_703,
            windowId: 765_803,
            to: workspaceId
        )
        let node = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil
        ))
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.niriLayoutHandler.activatePointerHoveredWindow(
            node,
            in: workspaceId
        )

        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
    }

    func testMouseMoveWindowIdPrefersRoutedFieldAndFallsBackToTopmostField() throws {
        let event = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 765_801)
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: 765_802
        )

        XCTAssertEqual(MouseEventHandler.eventWindowIdUnderPointer(event), 765_802)

        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: 0
        )

        XCTAssertEqual(MouseEventHandler.eventWindowIdUnderPointer(event), 765_801)

        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)

        XCTAssertNil(MouseEventHandler.eventWindowIdUnderPointer(event))
    }

    func testMouseMoveWindowIdRejectsValuesOutsideCGWindowIdRange() {
        XCTAssertNil(MouseEventHandler.normalizedEventWindowId(-1))
        XCTAssertNil(MouseEventHandler.normalizedEventWindowId(Int64(UInt32.max) + 1))
        XCTAssertNil(MouseEventHandler.normalizedEventWindowId(0))
        XCTAssertEqual(MouseEventHandler.normalizedEventWindowId(Int64(UInt32.max)), Int(UInt32.max))
    }

    func testAnnotatedMoveTapMakesSessionEventMasksMutuallyExclusive() {
        let moveBit: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        let annotatedMask = MouseEventHandler.sessionEventMask(annotatedMoveTapInstalled: true)
        let fallbackMask = MouseEventHandler.sessionEventMask(annotatedMoveTapInstalled: false)

        XCTAssertEqual(annotatedMask & moveBit, 0)
        XCTAssertNotEqual(fallbackMask & moveBit, 0)

        for type in [
            CGEventType.leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .scrollWheel
        ] {
            let bit: CGEventMask = 1 << type.rawValue
            XCTAssertNotEqual(annotatedMask & bit, 0)
            XCTAssertNotEqual(fallbackMask & bit, 0)
        }
    }

    @MainActor
    func testNiriFocusFollowsMouseDispatchFocusesHoveredWindowImmediately() throws {
        try assertNiriFocusFollowsMouseReveal(
            animationsEnabled: true,
            orientation: .horizontal
        )
    }

    @MainActor
    func testNiriFocusFollowsMouseRevealsPortraitWindowWithoutAnimations() throws {
        try assertNiriFocusFollowsMouseReveal(
            animationsEnabled: false,
            orientation: .vertical
        )
    }

    @MainActor
    private func assertNiriFocusFollowsMouseReveal(
        animationsEnabled: Bool,
        orientation: Monitor.Orientation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var focusedTokens: [WindowToken] = []
        var focusObservedPendingRelayout: [Bool] = []
        weak var focusController: WMController?
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                    focusObservedPendingRelayout.append(
                        focusController?.layoutRefreshController.layoutState.pendingRefresh != nil
                    )
                },
                raiseWindow: { _ in }
            )
        )
        focusController = controller
        controller.motionPolicy.animationsEnabled = animationsEnabled
        let displayId = controller.workspaceManager.monitors[0].displayId
        let monitorSize = switch orientation {
        case .horizontal:
            CGSize(width: 1_000, height: 800)
        case .vertical:
            CGSize(width: 800, height: 1_000)
        }
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(origin: .zero, size: monitorSize),
            visibleFrame: CGRect(origin: .zero, size: monitorSize),
            hasNotch: false,
            name: "Focus Follows Mouse Reveal"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        defer {
            controller.layoutRefreshController.stopScrollAnimation(for: displayId)
            controller.workspaceManager.animationDriver.removeMotions(for: [workspaceId])
        }
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        controller.workspaceManager.setGaps(to: 8)
        let workspaceMonitor = try XCTUnwrap(
            controller.workspaceManager.monitor(for: workspaceId),
            file: file,
            line: line
        )
        let engine = try XCTUnwrap(controller.niriEngine, file: file, line: line)
        let workingFrame = controller.insetWorkingFrame(for: workspaceMonitor)
        let gap = controller.innerGap(for: workspaceMonitor)
        let primarySpan = switch orientation {
        case .horizontal:
            workingFrame.width * 0.7
        case .vertical:
            workingFrame.height * 0.7
        }
        let tokens = (0 ..< 2).map { index in
            let pid = pid_t(765_704 + index)
            let windowId = 765_804 + index
            return controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
        }
        var nodes: [NiriWindow] = []
        for token in tokens {
            let node = engine.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: nodes.last?.id,
                focusedToken: nodes.last?.token
            )
            nodes.append(node)
        }
        for column in engine.columns(in: workspaceId) {
            switch orientation {
            case .horizontal:
                column.width = .fixed(primarySpan)
                column.cachedWidth = primarySpan
            case .vertical:
                column.height = .fixed(primarySpan)
                column.cachedHeight = primarySpan
            }
        }
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = nodes[0].id
            state.activeColumnIndex = 0
            state.jumpOffset(to: 0)
        }

        let primaryBounds: (CGRect) -> ClosedRange<CGFloat> = switch orientation {
        case .horizontal:
            { $0.minX ... $0.maxX }
        case .vertical:
            { $0.minY ... $0.maxY }
        }
        let framesBeforeHover = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            screenFrame: workspaceMonitor.frame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: orientation
        )
        let targetFrameBeforeHover = try XCTUnwrap(
            framesBeforeHover[tokens[1]],
            file: file,
            line: line
        )
        let viewportBounds = primaryBounds(workingFrame)
        let targetBoundsBeforeHover = primaryBounds(targetFrameBeforeHover)
        XCTAssertTrue(
            targetBoundsBeforeHover.overlaps(viewportBounds),
            file: file,
            line: line
        )
        XCTAssertTrue(
            targetBoundsBeforeHover.lowerBound < viewportBounds.lowerBound
                || targetBoundsBeforeHover.upperBound > viewportBounds.upperBound,
            file: file,
            line: line
        )
        let visibleTargetFrame = targetFrameBeforeHover.intersection(workingFrame)
        let visibleTargetBounds = primaryBounds(visibleTargetFrame)
        XCTAssertFalse(visibleTargetFrame.isNull, file: file, line: line)
        XCTAssertGreaterThan(visibleTargetFrame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(visibleTargetFrame.height, 0, file: file, line: line)
        XCTAssertLessThan(
            visibleTargetBounds.upperBound - visibleTargetBounds.lowerBound,
            targetBoundsBeforeHover.upperBound - targetBoundsBeforeHover.lowerBound,
            file: file,
            line: line
        )

        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: visibleTargetFrame.center,
            windowIdUnderPointer: tokens[1].windowId
        )

        XCTAssertEqual(focusedTokens, [tokens[1]], file: file, line: line)
        XCTAssertEqual(focusObservedPendingRelayout, [false], file: file, line: line)
        let stateAfterHover = controller.workspaceManager.niriViewportState(for: workspaceId)
        XCTAssertEqual(stateAfterHover.selectedNodeId, nodes[1].id, file: file, line: line)
        XCTAssertEqual(stateAfterHover.activeColumnIndex, 1, file: file, line: line)
        XCTAssertEqual(
            controller.intentLedger.activeManagedRequest?.origin,
            .pointerHover,
            file: file,
            line: line
        )

        let entry = try XCTUnwrap(
            controller.workspaceManager.entry(for: tokens[1]),
            file: file,
            line: line
        )
        let request = try XCTUnwrap(
            controller.intentLedger.activeManagedRequest,
            file: file,
            line: line
        )
        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            activeRequestId: request.requestId
        )
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            stateAfterHover,
            file: file,
            line: line
        )
        XCTAssertNil(controller.intentLedger.activeManagedRequest, file: file, line: line)

        let framesAfterHover = engine.calculateLayout(
            state: stateAfterHover,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            screenFrame: workspaceMonitor.frame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: orientation
        )
        let targetFrameAfterHover = try XCTUnwrap(
            framesAfterHover[tokens[1]],
            file: file,
            line: line
        )
        let targetBoundsAfterHover = primaryBounds(targetFrameAfterHover)
        XCTAssertGreaterThanOrEqual(
            targetBoundsAfterHover.lowerBound,
            viewportBounds.lowerBound - 0.5,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            targetBoundsAfterHover.upperBound,
            viewportBounds.upperBound + 0.5,
            file: file,
            line: line
        )

        if animationsEnabled {
            XCTAssertTrue(
                controller.workspaceManager.animationDriver.hasMotion(in: workspaceId),
                file: file,
                line: line
            )
            XCTAssertTrue(
                controller.niriLayoutHandler.hasScrollAnimation(for: workspaceId),
                file: file,
                line: line
            )
            XCTAssertNil(
                controller.layoutRefreshController.layoutState.pendingRefresh,
                file: file,
                line: line
            )
        } else {
            XCTAssertFalse(
                controller.workspaceManager.animationDriver.hasMotion(in: workspaceId),
                file: file,
                line: line
            )
            XCTAssertFalse(
                controller.niriLayoutHandler.hasScrollAnimation(for: workspaceId),
                file: file,
                line: line
            )
            let pendingRefresh = try XCTUnwrap(
                controller.layoutRefreshController.layoutState.pendingRefresh,
                file: file,
                line: line
            )
            XCTAssertEqual(pendingRefresh.kind, .immediateRelayout, file: file, line: line)
            XCTAssertEqual(pendingRefresh.reason, .layoutCommand, file: file, line: line)
            XCTAssertEqual(
                pendingRefresh.affectedWorkspaceIds,
                [workspaceId],
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func testFocusFollowsMouseUsesTopmostFloatingWindowIdOverTiledGeometry() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let overlapFrame = CGRect(
            x: monitor.visibleFrame.minX + 40,
            y: monitor.visibleFrame.minY + 40,
            width: 260,
            height: 180
        )
        let tiledToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_001), windowId: 766_101),
            pid: 766_001,
            windowId: 766_101,
            to: workspaceId
        )
        let tiledNode = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: tiledToken,
            to: workspaceId,
            afterSelection: nil
        ))
        tiledNode.frame = overlapFrame
        tiledNode.renderedFrame = overlapFrame

        let firstFloatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_002), windowId: 766_102),
            pid: 766_002,
            windowId: 766_102,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(frame: overlapFrame, for: firstFloatingToken)
        let topmostFloatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_003), windowId: 766_103),
            pid: 766_003,
            windowId: 766_103,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(frame: overlapFrame, for: topmostFloatingToken)

        controller.mouseEventHandler.dispatchMouseMoved(
            at: overlapFrame.center,
            windowIdUnderPointer: topmostFloatingToken.windowId
        )

        XCTAssertEqual(focusedTokens, [topmostFloatingToken])
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, topmostFloatingToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)

        let ignoredFloatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_008), windowId: 766_108),
            pid: 766_008,
            windowId: 766_108,
            to: workspaceId,
            mode: .floating
        )
        controller.mouseEventHandler.state.isMoving = true
        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = .distantPast

        controller.mouseEventHandler.dispatchMouseMoved(
            at: overlapFrame.center,
            windowIdUnderPointer: ignoredFloatingToken.windowId
        )

        XCTAssertEqual(focusedTokens, [topmostFloatingToken])
    }

    @MainActor
    func testFocusFollowsMouseUsesExactTiledWindowIdInsteadOfGeometryFallback() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let pointerFrame = CGRect(
            x: monitor.visibleFrame.minX + 40,
            y: monitor.visibleFrame.minY + 40,
            width: 260,
            height: 180
        )
        let geometricToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_004), windowId: 766_104),
            pid: 766_004,
            windowId: 766_104,
            to: workspaceId
        )
        let geometricNode = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: geometricToken,
            to: workspaceId,
            afterSelection: nil
        ))
        geometricNode.frame = pointerFrame
        geometricNode.renderedFrame = pointerFrame

        let authoritativeToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_005), windowId: 766_105),
            pid: 766_005,
            windowId: 766_105,
            to: workspaceId
        )
        let authoritativeNode = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: authoritativeToken,
            to: workspaceId,
            afterSelection: geometricNode.id
        ))
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_006), windowId: 766_106),
            pid: 766_006,
            windowId: 766_106,
            to: workspaceId
        )
        let peerNode = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: peerToken,
            to: workspaceId,
            afterSelection: authoritativeNode.id
        ))
        let authoritativeColumn = try XCTUnwrap(
            controller.niriEngine?.findColumn(containing: authoritativeNode, in: workspaceId)
        )
        var viewportState = ViewportState(selectedNodeId: authoritativeNode.id)
        controller.workspaceManager.withEngineMutationScope {
            XCTAssertTrue(
                controller.niriEngine?.consumeWindow(
                    peerNode,
                    into: authoritativeColumn,
                    enteringFrom: .right,
                    in: workspaceId,
                    motion: .disabled,
                    state: &viewportState,
                    workingFrame: monitor.visibleFrame,
                    gaps: CGFloat(controller.workspaceManager.gaps),
                    orientation: controller.settings.effectiveOrientation(for: monitor)
                ) == true
            )
            authoritativeColumn.displayMode = .tabbed
        }
        let authoritativeIndex = try XCTUnwrap(
            authoritativeColumn.windowNodes.firstIndex(where: { $0 === authoritativeNode })
        )
        controller.workspaceManager.withEngineMutationScope {
            authoritativeColumn.setActiveTileIdx(authoritativeIndex)
            controller.niriEngine?.updateTabbedColumnVisibility(column: authoritativeColumn)
        }
        authoritativeNode.frame = pointerFrame.offsetBy(dx: pointerFrame.width + 40, dy: 0)
        authoritativeNode.renderedFrame = authoritativeNode.frame

        controller.mouseEventHandler.dispatchMouseMoved(
            at: pointerFrame.center,
            windowIdUnderPointer: authoritativeToken.windowId
        )

        XCTAssertEqual(focusedTokens, [authoritativeToken])
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, authoritativeToken)

        let peerIndex = try XCTUnwrap(
            authoritativeColumn.windowNodes.firstIndex(where: { $0 === peerNode })
        )
        controller.workspaceManager.withEngineMutationScope {
            authoritativeColumn.setActiveTileIdx(peerIndex)
            controller.niriEngine?.updateTabbedColumnVisibility(column: authoritativeColumn)
        }
        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = .distantPast

        controller.mouseEventHandler.dispatchMouseMoved(
            at: pointerFrame.center,
            windowIdUnderPointer: authoritativeToken.windowId
        )

        XCTAssertEqual(focusedTokens, [authoritativeToken])
    }

    @MainActor
    func testFocusFollowsMouseDoesNotFallThroughForUntrackedWindowId() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let targetFrame = CGRect(
            x: monitor.visibleFrame.minX + 40,
            y: monitor.visibleFrame.minY + 40,
            width: 260,
            height: 180
        )
        let tiledToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_006), windowId: 766_106),
            pid: 766_006,
            windowId: 766_106,
            to: workspaceId
        )
        let tiledNode = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: tiledToken,
            to: workspaceId,
            afterSelection: nil
        ))
        tiledNode.frame = targetFrame
        tiledNode.renderedFrame = targetFrame

        controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            windowIdUnderPointer: 999_999
        )

        XCTAssertTrue(focusedTokens.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
    }

    @MainActor
    func testFocusFollowsMouseDoesNotFocusHiddenFloatingWindowId() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let floatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_007), windowId: 766_107),
            pid: 766_007,
            windowId: 766_107,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: monitor.id,
                reason: .scratchpad
            ),
            for: floatingToken
        )

        controller.mouseEventHandler.dispatchMouseMoved(
            at: monitor.visibleFrame.center,
            windowIdUnderPointer: floatingToken.windowId
        )

        XCTAssertTrue(focusedTokens.isEmpty)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
    }

    @MainActor
    func testFocusLockModifierSuppressesFocusFollowsMouseWhileHeld() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.settings.focusLockModifier = .option
        controller.niriLayoutHandler.enableNiriLayout()
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let targetFrame = CGRect(
            x: monitor.visibleFrame.minX + 24,
            y: monitor.visibleFrame.minY + 24,
            width: 240,
            height: 160
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_706), windowId: 765_806),
            pid: 765_706,
            windowId: 765_806,
            to: workspaceId
        )
        let node = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil
        ))
        node.frame = targetFrame
        node.renderedFrame = targetFrame
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            modifiersRawValue: CGEventFlags.maskAlternate.rawValue
        )
        XCTAssertTrue(focusedTokens.isEmpty, "Focus lock modifier held should suppress focus-follows-mouse")

        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center, modifiersRawValue: 0)
        XCTAssertEqual(focusedTokens.last, token, "Releasing the modifier should restore focus-follows-mouse")
    }

    @MainActor
    func testDwindleFocusFollowsMouseDispatchFocusesHoveredWindowImmediately() throws {
        var focusedTokens: [WindowToken] = []
        let settings = Self.settingsStore()
        settings.workspaceConfigurations = settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_705), windowId: 765_805),
            pid: 765_705,
            windowId: 765_805,
            to: workspaceId
        )
        _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: workspaceId, screen: monitor.visibleFrame)
        let targetFrame = try XCTUnwrap(frames[token])
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center)

        XCTAssertEqual(focusedTokens.last, token)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.origin, .pointerHover)

        let exactTiledToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_710), windowId: 765_810),
            pid: 765_710,
            windowId: 765_810,
            to: workspaceId
        )
        _ = engine.addWindow(token: exactTiledToken, to: workspaceId, activeWindowFrame: nil)
        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = .distantPast

        controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            windowIdUnderPointer: exactTiledToken.windowId
        )

        XCTAssertEqual(focusedTokens.last, exactTiledToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, exactTiledToken)

        let floatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_709), windowId: 765_809),
            pid: 765_709,
            windowId: 765_809,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(frame: targetFrame, for: floatingToken)
        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = .distantPast

        controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            windowIdUnderPointer: floatingToken.windowId
        )

        XCTAssertEqual(focusedTokens.last, floatingToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, floatingToken)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    @MainActor
    func testFocusLockModifierSuppressesDwindleFocusFollowsMouseWhileHeld() throws {
        var focusedTokens: [WindowToken] = []
        let settings = Self.settingsStore()
        settings.workspaceConfigurations = settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        settings.focusLockModifier = .option
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_707), windowId: 765_807),
            pid: 765_707,
            windowId: 765_807,
            to: workspaceId
        )
        _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
        let frames = engine.calculateLayout(for: workspaceId, screen: monitor.visibleFrame)
        let targetFrame = try XCTUnwrap(frames[token])
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: targetFrame.center,
            modifiersRawValue: CGEventFlags.maskAlternate.rawValue
        )
        XCTAssertTrue(focusedTokens.isEmpty, "Focus lock modifier held should suppress Dwindle focus-follows-mouse")

        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center, modifiersRawValue: 0)
        XCTAssertEqual(focusedTokens.last, token, "Releasing the modifier should restore Dwindle focus-follows-mouse")
    }

    @MainActor
    func testFocusFollowsMouseRetriesSameUnconfirmedHoveredWindowAfterDebounce() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let targetFrame = CGRect(
            x: monitor.visibleFrame.minX + 40,
            y: monitor.visibleFrame.minY + 40,
            width: 220,
            height: 150
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_706), windowId: 765_806),
            pid: 765_706,
            windowId: 765_806,
            to: workspaceId
        )
        let node = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil
        ))
        node.frame = targetFrame
        node.renderedFrame = targetFrame

        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center)
        try await Task.sleep(for: .milliseconds(120))
        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center)

        XCTAssertEqual(focusedTokens, [token, token])
        let request = try XCTUnwrap(controller.intentLedger.activeManagedRequest)
        _ = controller.workspaceManager.confirmManagedFocus(
            token,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId),
            activateWorkspaceOnMonitor: false,
            requestId: request.requestId
        )
        _ = controller.intentLedger.confirmManagedRequest(token: token, source: .focusedWindowChanged)

        try await Task.sleep(for: .milliseconds(120))
        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center)

        XCTAssertEqual(focusedTokens, [token, token])
    }

    @MainActor
    func testFocusFollowsMouseUsesPointerWorkspaceForFallbackAndEntryWorkspaceForExactId() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let leftMonitor = Monitor(
            id: .init(displayId: 10_001),
            displayId: 10_001,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            hasNotch: false,
            name: "Left"
        )
        let rightMonitor = Monitor(
            id: .init(displayId: 10_002),
            displayId: 10_002,
            frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            hasNotch: false,
            name: "Right"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let rightWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        XCTAssertEqual(controller.activeWorkspace()?.id, leftWorkspaceId)
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let targetFrame = CGRect(x: 1240, y: 40, width: 240, height: 160)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_707), windowId: 765_807),
            pid: 765_707,
            windowId: 765_807,
            to: rightWorkspaceId
        )
        let node = try XCTUnwrap(controller.niriEngine?.addWindow(
            token: token,
            to: rightWorkspaceId,
            afterSelection: nil
        ))
        node.frame = targetFrame
        node.renderedFrame = targetFrame

        controller.mouseEventHandler.dispatchMouseMoved(at: targetFrame.center)

        XCTAssertEqual(focusedTokens.last, token)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.workspaceId, rightWorkspaceId)

        let overhangingFrame = CGRect(x: 1100, y: 40, width: 240, height: 160)
        let floatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_708), windowId: 765_808),
            pid: 765_708,
            windowId: 765_808,
            to: leftWorkspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(frame: overhangingFrame, for: floatingToken)
        controller.mouseEventHandler.state.lastFocusFollowsMouseTime = .distantPast

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: 1240, y: 80),
            windowIdUnderPointer: floatingToken.windowId
        )

        XCTAssertEqual(focusedTokens.last, floatingToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.workspaceId, leftWorkspaceId)
    }

    func testManagedFocusCancelRejectsMismatchedRequestId() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 7
            )
        )

        let mismatchedPlan = StateReducer.reduce(
            event: .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: 8,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        let matchingPlan = StateReducer.reduce(
            event: .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertFalse(mismatchedPlan.mutatesRuntimeState)
        XCTAssertEqual(matchingPlan.focusSession?.pendingManagedFocus, .empty)
    }

    func testWorkspaceReassignClearsStalePendingManagedFocus() {
        let token = WindowToken(pid: 100, windowId: 42)
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceA,
                monitorId: nil,
                requestId: 7
            )
        )

        let movedPlan = StateReducer.reduce(
            event: .workspaceAssigned(
                token: token,
                from: workspaceA,
                to: workspaceB,
                monitorId: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        XCTAssertEqual(movedPlan.focusSession?.pendingManagedFocus, .empty)

        let sameWorkspacePlan = StateReducer.reduce(
            event: .workspaceAssigned(
                token: token,
                from: workspaceA,
                to: workspaceA,
                monitorId: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        XCTAssertNil(sameWorkspacePlan.focusSession)
    }

    func testWorkspaceReassignLeavesUnrelatedTokenPendingFocus() {
        let token = WindowToken(pid: 100, windowId: 42)
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceA,
                monitorId: nil,
                requestId: 7
            )
        )

        let otherToken = WindowToken(pid: 200, windowId: 7)
        let otherPlan = StateReducer.reduce(
            event: .workspaceAssigned(
                token: otherToken,
                from: workspaceA,
                to: workspaceB,
                monitorId: nil,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        XCTAssertNil(otherPlan.focusSession)
    }

    func testManagedFocusConfirmRequiresMatchingRequest() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let monitorId = Monitor.ID(displayId: 2)
        let previousMonitorId = Monitor.ID(displayId: 1)
        let nativeFullscreenOwner = WindowToken(pid: 200, windowId: 84)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: previousMonitorId,
                requestId: 7
            ),
            isNonManagedFocusActive: true,
            nonManagedFocusToken: nativeFullscreenOwner,
            interactionMonitorId: previousMonitorId
        )

        let mismatch = StateReducer.reduce(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                requestId: 8,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )
        let match = StateReducer.reduce(
            event: .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                requestId: 7,
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertFalse(mismatch.mutatesRuntimeState)
        XCTAssertEqual(snapshot.focusSession.nonManagedFocusToken, nativeFullscreenOwner)
        XCTAssertEqual(match.focusSession?.focusedToken, token)
        XCTAssertEqual(match.focusSession?.pendingManagedFocus, .empty)
        XCTAssertEqual(match.focusSession?.isNonManagedFocusActive, false)
        XCTAssertNil(match.focusSession?.nonManagedFocusToken)
        XCTAssertEqual(match.focusSession?.interactionMonitorId, monitorId)
        XCTAssertEqual(match.focusSession?.previousInteractionMonitorId, previousMonitorId)
    }

    func testManagedReplacementFocusTransactionRekeysAnchorAndProtectedTokens() {
        let workspaceId = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 77821, windowId: 4245)
        let tempToken = WindowToken(pid: 77821, windowId: 4707)
        let restoredToken = WindowToken(pid: 77821, windowId: 4245)
        var transaction = ReplacementFocusPayload(
            pid: 77821,
            workspaceId: workspaceId,
            anchorToken: oldToken,
            protectedTokens: [oldToken, tempToken],
            isBurstOpen: true
        )

        transaction.rekey(from: oldToken, to: tempToken)
        XCTAssertEqual(transaction.anchorToken, tempToken)
        XCTAssertTrue(transaction.protects(tempToken))
        XCTAssertFalse(transaction.protects(oldToken))

        transaction.rekey(from: tempToken, to: restoredToken)
        XCTAssertEqual(transaction.anchorToken, restoredToken)
        XCTAssertTrue(transaction.protects(restoredToken))
        XCTAssertFalse(transaction.protects(tempToken))
    }

    func testManagedReplacementFocusTransactionSuppressesOnlyUnprotectedSameWorkspaceTokens() {
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()
        let anchorToken = WindowToken(pid: 77821, windowId: 4245)
        let tempToken = WindowToken(pid: 77821, windowId: 4707)
        let unrelatedSameWorkspaceToken = WindowToken(pid: 77821, windowId: 3164)
        let otherPidToken = WindowToken(pid: 91438, windowId: 3164)
        let transaction = ReplacementFocusPayload(
            pid: 77821,
            workspaceId: workspaceId,
            anchorToken: anchorToken,
            protectedTokens: [anchorToken, tempToken],
            isBurstOpen: true
        )

        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: anchorToken, workspaceId: workspaceId))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: tempToken, workspaceId: workspaceId))
        XCTAssertTrue(transaction.suppressesUnrelatedActivation(
            token: unrelatedSameWorkspaceToken,
            workspaceId: workspaceId
        ))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(token: otherPidToken, workspaceId: workspaceId))
        XCTAssertFalse(transaction.suppressesUnrelatedActivation(
            token: unrelatedSameWorkspaceToken,
            workspaceId: otherWorkspaceId
        ))
    }

    @MainActor
    func testRejectedManagedFocusConfirmDoesNotInvalidateRuntimeThroughRestoreIntentRefresh() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_101),
            pid: getpid(),
            windowId: 9_101,
            to: workspaceId
        )

        _ = manager.beginManagedFocusRequest(token, in: workspaceId, requestId: 7)
        let before = manager.worldSeq
        let txn = manager.recordReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: 8,
                source: .workspaceManager
            )
        )

        XCTAssertFalse(txn.plan.mutatesRuntimeState)
        XCTAssertTrue(
            manager.isSeqCurrent(before, for: workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        )
    }

    func testPendingManagedFocusWithoutRequestIdIsInvariantViolation() {
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 100, windowId: 42)
        let snapshot = Self.snapshot(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                requestId: nil
            )
        )

        let codes = Set(InvariantChecks.validate(snapshot: snapshot).map(\.code))

        XCTAssertTrue(codes.contains("pending_focus_token_missing"))
        XCTAssertTrue(codes.contains("pending_focus_without_request"))
    }

    func testFocusInvariantTableCoversCorruptSnapshots() {
        let token = WindowToken(pid: 100, windowId: 42)
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()

        let duplicateCodes = Self.invariantCodes(
            windows: [
                Self.window(token: token, workspaceId: workspaceId),
                Self.window(token: token, workspaceId: workspaceId)
            ]
        )
        XCTAssertTrue(duplicateCodes.contains("duplicate_window_token"))

        let destroyedFocusedCodes = Self.invariantCodes(
            focusedToken: token,
            windows: [
                Self.window(token: token, workspaceId: workspaceId, lifecyclePhase: .destroyed)
            ]
        )
        XCTAssertTrue(destroyedFocusedCodes.contains("focused_token_destroyed"))

        let requestShapeCodes = Self.invariantCodes(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: nil,
                workspaceId: nil,
                monitorId: nil,
                requestId: 7
            )
        )
        XCTAssertTrue(requestShapeCodes.contains("pending_focus_request_without_token"))
        XCTAssertTrue(requestShapeCodes.contains("pending_focus_request_without_workspace"))

        let mismatchCodes = Self.invariantCodes(
            pendingManagedFocus: PendingManagedFocusSnapshot(
                token: token,
                workspaceId: otherWorkspaceId,
                monitorId: nil,
                requestId: 7
            ),
            windows: [
                Self.window(token: token, workspaceId: workspaceId)
            ]
        )
        XCTAssertTrue(mismatchCodes.contains("pending_focus_workspace_mismatch"))
    }

    @MainActor
    func testWorkspaceManagerDoesNotInvalidateForNoOpRuntimeSetters() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_001),
            pid: getpid(),
            windowId: 9_001,
            to: workspaceId,
            mode: .floating
        )

        let hiddenState = HiddenState(
            proportionalPosition: CGPoint(x: 0.25, y: 0.5),
            referenceMonitorId: nil,
            reason: .workspaceInactive
        )
        let allDomains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]
        manager.setHiddenState(hiddenState, for: token)
        let afterHiddenState = manager.worldSeq
        manager.setHiddenState(hiddenState, for: token)
        XCTAssertTrue(manager.isSeqCurrent(afterHiddenState, for: workspaceId, domains: allDomains))

        let floatingState = FloatingState(
            lastFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
            normalizedOrigin: CGPoint(x: 0.1, y: 0.2),
            referenceMonitorId: nil,
            restoreToFloating: true
        )
        manager.setFloatingState(floatingState, for: token)
        let afterFloatingState = manager.worldSeq
        manager.setFloatingState(floatingState, for: token)
        XCTAssertTrue(manager.isSeqCurrent(afterFloatingState, for: workspaceId, domains: allDomains))

        let constraints = WindowSizeConstraints.fixed(size: CGSize(width: 320, height: 240))
        let beforeConstraints = manager.worldSeq
        manager.setCachedConstraints(constraints, for: token)
        XCTAssertTrue(manager.isSeqCurrent(beforeConstraints, for: workspaceId, domains: allDomains))
        let afterConstraints = manager.worldSeq
        manager.setCachedConstraints(constraints, for: token)
        XCTAssertTrue(manager.isSeqCurrent(afterConstraints, for: workspaceId, domains: allDomains))
    }

    @MainActor
    func testWorkspaceManagerDoesNotGlobalInvalidateForMissingTokens() throws {
        let manager = Self.workspaceManager()
        let missingToken = WindowToken(pid: getpid(), windowId: 987_654)
        let before = manager.worldSeq

        manager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
                normalizedOrigin: CGPoint(x: 0.1, y: 0.2),
                referenceMonitorId: nil,
                restoreToFloating: true
            ),
            for: missingToken
        )
        manager.setManualLayoutOverride(.forceFloat, for: missingToken)
        manager.setCachedConstraints(.fixed(size: CGSize(width: 320, height: 240)), for: missingToken)
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: missingToken
        )
        XCTAssertFalse(manager.setScratchpadToken(missingToken))

        XCTAssertTrue(
            manager.isSeqEpochCurrent(before, domains: [.workspace, .layout, .focus, .fullscreen])
        )
    }

    @MainActor
    func testApplySessionPatchRejectsStaleLayoutSeq() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_101),
            pid: getpid(),
            windowId: 9_101,
            to: workspaceId
        )
        let staleSeq = manager.worldSeq
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: token
        )
        var viewportState = ViewportState()
        viewportState.activeColumnIndex = 4

        let changed = manager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: viewportState,
                plannedSeq: staleSeq
            )
        )

        XCTAssertFalse(changed)
        XCTAssertNotEqual(manager.niriViewportState(for: workspaceId).activeColumnIndex, 4)
    }

    @MainActor
    func testApplySessionPatchAppliesViewportButRejectsStaleRememberedFocus() throws {
        let manager = Self.workspaceManager()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let firstToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_201),
            pid: getpid(),
            windowId: 9_201,
            to: workspaceId
        )
        let secondToken = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 9_202),
            pid: getpid(),
            windowId: 9_202,
            to: workspaceId
        )
        let staleFocusSeq = manager.worldSeq
        _ = manager.beginManagedFocusRequest(firstToken, in: workspaceId, requestId: 7)
        var viewportState = ViewportState()
        viewportState.activeColumnIndex = 3

        let changed = manager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: secondToken,
                plannedSeq: staleFocusSeq
            )
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(manager.niriViewportState(for: workspaceId).activeColumnIndex, 3)
        XCTAssertEqual(manager.lastFocusedToken(in: workspaceId), firstToken)
    }

    func testPostLayoutActionForwardsAcceptedSeqsAndHonorsDomains() {
        let workspaceId = WorkspaceDescriptor.ID()
        let otherWorkspaceId = WorkspaceDescriptor.ID()
        let action = RefreshPostLayoutAction(
            workspaceSeqs: [
                workspaceId: 5,
                otherWorkspaceId: 7
            ],
            domains: .layoutCommit
        ) {}

        let forwarded = action.forwarded(
            by: [workspaceId: AcceptedSeq(after: 9, domains: .layoutCommit)],
            currentAtEntry: [workspaceId]
        )
        let notCurrentAtEntry = action.forwarded(
            by: [workspaceId: AcceptedSeq(after: 9, domains: .layoutCommit)],
            currentAtEntry: []
        )
        let focusAction = RefreshPostLayoutAction(
            workspaceSeqs: [workspaceId: 5],
            domains: .focusCommit
        ) {}
        let uncoveredDomainsNotForwarded = focusAction.forwarded(
            by: [workspaceId: AcceptedSeq(after: 9, domains: .layoutCommit)],
            currentAtEntry: [workspaceId]
        )
        let coveredDomainsForwarded = focusAction.forwarded(
            by: [workspaceId: AcceptedSeq(after: 9, domains: .layoutCommit.union(.focusCommit))],
            currentAtEntry: [workspaceId]
        )

        XCTAssertEqual(forwarded.workspaceSeqs[workspaceId], 9)
        XCTAssertEqual(forwarded.workspaceSeqs[otherWorkspaceId], 7)
        XCTAssertEqual(notCurrentAtEntry.workspaceSeqs[workspaceId], 5)
        XCTAssertEqual(uncoveredDomainsNotForwarded.workspaceSeqs[workspaceId], 5)
        XCTAssertEqual(coveredDomainsForwarded.workspaceSeqs[workspaceId], 9)
        XCTAssertTrue(action.hasWorkspace(in: [workspaceId]))
    }

    @MainActor
    func testPostLayoutActionRunsInvalidationContinuationInsteadOfStaleAction() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let plannedSeq = controller.workspaceManager.worldSeq
        var ranCurrentAction = false
        var ranInvalidatedAction = false
        let action = RefreshPostLayoutAction(
            workspaceSeqs: [workspaceId: plannedSeq],
            domains: .layoutCommit,
            action: { ranCurrentAction = true },
            invalidatedAction: { ranInvalidatedAction = true }
        )

        controller.workspaceManager.invalidateLayout(for: [workspaceId])
        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertFalse(ranCurrentAction)
        XCTAssertTrue(ranInvalidatedAction)
    }

    @MainActor
    func testWorkspaceTransitionPreservesInvalidatedFocusHandoff() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        var ranCurrentAction = false
        var ranInvalidatedAction = false

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [workspaceId],
            postLayoutGateWorkspaceIds: [workspaceId],
            postLayout: { ranCurrentAction = true },
            postLayoutInvalidated: { ranInvalidatedAction = true }
        )
        controller.workspaceManager.invalidateLayout(for: [workspaceId])

        for _ in 0 ..< 8 {
            if let task = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await task.value
            } else if controller.layoutRefreshController.layoutState.pendingRefresh == nil {
                break
            } else {
                await Task.yield()
            }
        }

        XCTAssertFalse(ranCurrentAction)
        XCTAssertTrue(ranInvalidatedAction)
    }

    @MainActor
    func testWorkspaceTransitionTrailingClosureRemainsPostLayoutAction() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }
        var ranPostLayout = false

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [workspaceId]
        ) {
            ranPostLayout = true
        }
        let action = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertTrue(ranPostLayout)
    }

    @MainActor
    func testAnimationLayoutPlanDoesNotScheduleFullSurfaceReconcile() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        controller.surfaceReconciler.reconcileNow()

        let animationPlan = WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: Self.layoutMonitorSnapshot(monitor),
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: workspaceId,
                plannedSeq: controller.workspaceManager.worldSeq
            ),
            diff: WorkspaceLayoutDiff(),
            isAnimationTick: true
        )

        XCTAssertNotNil(controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(animationPlan))
        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)

        var fullPlan = animationPlan
        fullPlan.isAnimationTick = false
        XCTAssertNotNil(controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(fullPlan))
        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        controller.surfaceReconciler.reconcileNow()
    }

    @MainActor
    func testAnimationSurfaceReconcilePreservesPendingFullWorkAndOrdering() {
        let controller = Self.controller()
        controller.surfaceReconciler.noteRestackOccurred()

        controller.surfaceReconciler.reconcileAnimationTick()

        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        XCTAssertTrue(controller.surfaceReconciler.forceOrderingOnNextReconcile)

        controller.surfaceReconciler.reconcileNow()

        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)
        XCTAssertFalse(controller.surfaceReconciler.forceOrderingOnNextReconcile)
    }

    @MainActor
    func testSurfaceReconcilerCleanupCancelsPendingReconcileAndOrdering() {
        let controller = Self.controller()
        controller.surfaceReconciler.noteRestackOccurred()

        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        XCTAssertTrue(controller.surfaceReconciler.forceOrderingOnNextReconcile)

        controller.surfaceReconciler.cleanup()

        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)
        XCTAssertFalse(controller.surfaceReconciler.forceOrderingOnNextReconcile)
        XCTAssertEqual(controller.surfaceReconciler.appliedScene, .empty)
    }

    @MainActor
    func testStoppedServiceReconcileDoesNotRepopulateWorkspaceBars() {
        let controller = Self.controller()
        controller.settings.workspaceBarEnabled = true
        controller.hasStartedServices = true
        let world = WorldView(controller: controller)

        XCTAssertFalse(SurfaceDerivation.derive(world: world).bars.isEmpty)
        XCTAssertFalse(SurfaceDerivation.derive(world: world).parkingEdgeMasks.isEmpty)
        controller.surfaceReconciler.reconcileNow()
        XCTAssertFalse(controller.surfaceReconciler.appliedScene.bars.isEmpty)
        XCTAssertFalse(controller.surfaceReconciler.appliedScene.parkingEdgeMasks.isEmpty)
        XCTAssertFalse(
            controller.ownedWindowRegistry.visibleSurfaceIDs(kind: .parkingEdgeMask).isEmpty
        )

        controller.hasStartedServices = false
        controller.surfaceReconciler.cleanup()

        XCTAssertTrue(SurfaceDerivation.derive(world: world).bars.isEmpty)
        XCTAssertTrue(SurfaceDerivation.derive(world: world).parkingEdgeMasks.isEmpty)
        XCTAssertTrue(controller.ownedWindowRegistry.visibleSurfaceIDs(kind: .parkingEdgeMask).isEmpty)
        controller.surfaceReconciler.reconcileNow()
        XCTAssertTrue(controller.surfaceReconciler.appliedScene.bars.isEmpty)
        XCTAssertTrue(controller.surfaceReconciler.appliedScene.parkingEdgeMasks.isEmpty)
    }

    @MainActor
    func testAnimationBorderDerivationReusesNonManagedFrameWithoutBoundsQuery() throws {
        let controller = Self.controller()
        controller.hasStartedServices = true
        controller.settings.bordersEnabled = true
        let token = WindowToken(pid: 765_019, windowId: 765_119)
        _ = controller.workspaceManager.enterNonManagedFocus(target: token)
        let previous = DesiredBorderSurface(
            token: token,
            frame: CGRect(x: 20, y: 30, width: 400, height: 300),
            config: BorderConfig.from(settings: controller.settings)
        )
        var boundsQueryCount = 0
        let world = WorldView(controller: controller, borderFrameResolver: { _ in
            boundsQueryCount += 1
            return nil
        })

        let derived = try XCTUnwrap(
            SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous)
        )

        XCTAssertEqual(derived, previous)
        XCTAssertEqual(boundsQueryCount, 0)
    }

    @MainActor
    func testVerifiedFrameApplySuccessUsesCurrentFullWindowToken() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_020), windowId: 765_120),
            pid: 765_020,
            windowId: 765_120,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(token, in: workspaceId))
        controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let reusedWindowIdResult = Self.frameResult(
            requestId: 1,
            pid: token.pid + 1,
            windowId: token.windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(token.pid + 1),
                windowId: token.windowId
            ),
            targetFrame: frame,
            currentFrameHint: nil
        )

        controller.surfaceReconciler.handleVerifiedFrameApplySuccess(reusedWindowIdResult)

        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)

        let focusedResult = Self.frameResult(
            requestId: 2,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(token.pid),
                windowId: token.windowId
            ),
            targetFrame: frame,
            currentFrameHint: nil
        )

        controller.surfaceReconciler.handleVerifiedFrameApplySuccess(focusedResult)
        controller.surfaceReconciler.handleVerifiedFrameApplySuccess(focusedResult)

        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        controller.surfaceReconciler.reconcileNow()
    }

    @MainActor
    func testServiceLifecycleForwardsOnlyObservedFrameSuccesses() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_021), windowId: 765_121),
            pid: 765_021,
            windowId: 765_121,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(token, in: workspaceId))
        controller.surfaceReconciler.reconcileNow()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
        let animationResult = AXFrameApplyResult(
            requestId: 1,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: nil,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )

        controller.serviceLifecycleManager.handleFrameApplySucceeded(animationResult)

        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)

        let unconfirmedResult = AXFrameApplyResult(
            requestId: 2,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: frame.offsetBy(dx: 20, dy: 0),
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: .verificationMismatch
            )
        )

        controller.serviceLifecycleManager.handleFrameApplySucceeded(unconfirmedResult)

        XCTAssertFalse(controller.surfaceReconciler.reconcileScheduled)

        let verifiedResult = Self.frameResult(
            requestId: 3,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: nil
        )
        controller.serviceLifecycleManager.handleFrameApplySucceeded(verifiedResult)

        XCTAssertTrue(controller.surfaceReconciler.reconcileScheduled)
        controller.surfaceReconciler.reconcileNow()
    }

    @MainActor
    func testAXManagerAcceptedFrameCallbackCarriesFullResult() {
        let controller = Self.controller()
        let frame = CGRect(x: 20, y: 30, width: 400, height: 300)
        let result = Self.frameResult(
            requestId: 3,
            pid: 765_022,
            windowId: 765_122,
            expectedWindow: AXWindowRef(
                element: AXUIElementCreateApplication(765_022),
                windowId: 765_122
            ),
            targetFrame: frame,
            currentFrameHint: nil
        )
        var received: AXFrameApplyResult?
        controller.axManager.onFrameApplySucceeded = { received = $0 }

        controller.axManager.handleAcceptedFrameApplySuccess(result)

        XCTAssertEqual(received, result)
    }

    @MainActor
    func testLayoutPlanAcceptedSeqIncludesAnimationDirectiveFocusMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_005), windowId: 765_105),
            pid: 765_005,
            windowId: 765_105,
            to: workspaceId
        )
        let plannedSeq = controller.workspaceManager.worldSeq

        let accepted = try XCTUnwrap(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                WorkspaceLayoutPlan(
                    workspaceId: workspaceId,
                    monitor: Self.layoutMonitorSnapshot(monitor),
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: workspaceId,
                        plannedSeq: plannedSeq
                    ),
                    diff: WorkspaceLayoutDiff(),
                    animationDirectives: [.activateWindow(token: token)]
                )
            )
        )

        XCTAssertEqual(accepted.after, controller.workspaceManager.worldSeq)
        XCTAssertFalse(
            controller.workspaceManager.isSeqCurrent(plannedSeq, for: workspaceId, domains: .focusCommit)
        )
        XCTAssertTrue(accepted.domains.contains(.focus))
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, token)
    }

    @MainActor
    func testLayoutPlanDoesNotActivateWindowOverFocusedSystemModal() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let modalToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_009), windowId: 765_109),
            pid: 765_009,
            windowId: 765_109,
            to: workspaceId,
            mode: .floating
        )
        let layoutToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_009), windowId: 765_110),
            pid: 765_009,
            windowId: 765_110,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                modalToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.workspaceManager.setSystemModalFocus(modalToken)
        let plannedSeq = controller.workspaceManager.worldSeq

        let accepted = controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: Self.layoutMonitorSnapshot(monitor),
                sessionPatch: WorkspaceSessionPatch(
                    workspaceId: workspaceId,
                    plannedSeq: plannedSeq
                ),
                diff: WorkspaceLayoutDiff(),
                animationDirectives: [.activateWindow(token: layoutToken)]
            )
        )

        XCTAssertNotNil(accepted)
        XCTAssertTrue(controller.shouldSuppressManagedFocusRecovery)
        XCTAssertEqual(controller.workspaceManager.focusedToken, modalToken)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(focusedTokens.isEmpty)
    }

    @MainActor
    func testLayoutPlanRejectsStaleFocusSeqBeforeApplyingEffects() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_007), windowId: 765_107),
            pid: 765_007,
            windowId: 765_107,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_008), windowId: 765_108),
            pid: 765_008,
            windowId: 765_108,
            to: workspaceId
        )
        let plannedSeq = controller.workspaceManager.worldSeq
        _ = controller.workspaceManager.beginManagedFocusRequest(firstToken, in: workspaceId, requestId: 7)

        let accepted = controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
            WorkspaceLayoutPlan(
                workspaceId: workspaceId,
                monitor: Self.layoutMonitorSnapshot(monitor),
                sessionPatch: WorkspaceSessionPatch(
                    workspaceId: workspaceId,
                    rememberedFocusToken: secondToken,
                    plannedSeq: plannedSeq
                ),
                diff: WorkspaceLayoutDiff(),
                animationDirectives: [.activateWindow(token: secondToken)]
            )
        )

        XCTAssertNil(accepted)
        XCTAssertEqual(controller.workspaceManager.pendingFocusedToken, firstToken)
        XCTAssertNotEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), secondToken)
    }

    @MainActor
    func testOverviewLayoutPlanSuppressesWindowActivationDirective() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_006), windowId: 765_106),
            pid: 765_006,
            windowId: 765_106,
            to: workspaceId
        )
        let plannedSeq = controller.workspaceManager.worldSeq

        let accepted = try XCTUnwrap(
            controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(
                WorkspaceLayoutPlan(
                    workspaceId: workspaceId,
                    monitor: Self.layoutMonitorSnapshot(monitor),
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: workspaceId,
                        plannedSeq: plannedSeq
                    ),
                    diff: WorkspaceLayoutDiff(),
                    animationDirectives: [.activateWindow(token: token)]
                ),
                suppressWindowActivation: true
            )
        )

        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertTrue(
            controller.workspaceManager.isSeqCurrent(plannedSeq, for: workspaceId, domains: .focusCommit)
        )
        XCTAssertEqual(accepted.after, controller.workspaceManager.worldSeq)
    }

    @MainActor
    func testOverviewMutationSuppressionSurvivesCallbackFreeFullRescanMerge() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.layoutRefreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .startup
        )
        defer { controller.layoutRefreshController.resetState() }

        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .overviewMutation,
            affectedWorkspaceIds: [workspaceId]
        )

        XCTAssertTrue(
            try XCTUnwrap(
                controller.layoutRefreshController.layoutState.activeRefresh
            ).suppressesWindowActivation
        )
    }

    @MainActor
    func testOverviewMutationSuppressionSurvivesWindowRemovalMergeAndFollowUp() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.motionPolicy.animationsEnabled = false
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_007), windowId: 765_107),
            pid: 765_007,
            windowId: 765_107,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        XCTAssertNil(engine.findNode(for: firstToken, in: workspaceId))
        XCTAssertFalse(controller.shouldSuppressManagedFocusRecovery)
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        controller.layoutRefreshController.layoutState.pendingRefresh = .init(
            kind: .windowRemoval,
            reason: .windowDestroyed,
            windowRemovalPayload: .init(
                workspaceId: workspaceId,
                layoutType: .niri,
                removedNodeId: nil,
                removedNiriColumn: false,
                niriOldFrames: [:],
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false
            )
        )

        var followUpToken: WindowToken?
        let addFollowUpWindow: @MainActor @Sendable () -> Void = {
            followUpToken = controller.workspaceManager.addWindow(
                AXWindowRef(
                    element: AXUIElementCreateApplication(765_008),
                    windowId: 765_108
                ),
                pid: 765_008,
                windowId: 765_108,
                to: workspaceId
            )
        }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .overviewMutation,
            affectedWorkspaceIds: [workspaceId],
            postLayout: addFollowUpWindow,
            postLayoutInvalidated: addFollowUpWindow,
            postLayoutDomains: .layoutCommit
        )

        let mergedRefresh = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.activeRefresh
        )
        XCTAssertEqual(mergedRefresh.kind, .windowRemoval)
        XCTAssertTrue(mergedRefresh.suppressesWindowActivation)
        XCTAssertEqual(mergedRefresh.followUpRefresh?.reason, .overviewMutation)
        XCTAssertTrue(
            try XCTUnwrap(mergedRefresh.followUpRefresh).suppressesWindowActivation
        )

        for _ in 0 ..< 8 {
            if let task = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await task.value
            } else if controller.layoutRefreshController.layoutState.pendingRefresh == nil {
                break
            } else {
                await Task.yield()
            }
        }

        let secondToken = try XCTUnwrap(followUpToken)
        XCTAssertNotNil(engine.findNode(for: firstToken, in: workspaceId))
        XCTAssertNotNil(engine.findNode(for: secondToken, in: workspaceId))
        XCTAssertTrue(focusedTokens.isEmpty)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    @MainActor
    func testLayoutCommandPostLayoutDefaultRejectsFocusInvalidation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_013), windowId: 765_113),
            pid: 765_013,
            windowId: 765_113,
            to: workspaceId
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        var didRun = false
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) {
            didRun = true
        }
        let action = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            .first)
        _ = controller.workspaceManager.rememberFocus(token, in: workspaceId)

        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertFalse(didRun)
    }

    @MainActor
    func testLayoutCommandPostLayoutRejectsLayoutInvalidation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_060), windowId: 765_160),
            pid: 765_060,
            windowId: 765_160,
            to: workspaceId
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        var didRun = false
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) {
            didRun = true
        }
        let action = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            .first)
        controller.workspaceManager.invalidateLayout(for: [workspaceId])

        action.runIfCurrent(using: controller.workspaceManager)

        XCTAssertFalse(didRun)
    }

    @MainActor
    func testResetStateDropsOldCancelledRefreshCompletion() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [workspaceId]
        )
        let task = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingDebounceTask)

        controller.layoutRefreshController.resetState()
        await task.value

        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefreshTask)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingDebounceTask)
    }

    @MainActor
    func testAXFrameLedgerIgnoresStaleResultsAfterNewerRequest() throws {
        let ledger = AXFrameApplicationLedger()
        let firstFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let secondFrame = CGRect(x: 40, y: 50, width: 360, height: 240)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        var firstResults: [AXFrameApplyResult] = []
        var secondResults: [AXFrameApplyResult] = []

        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: firstFrame,
            isRetry: false
        ) { result in
            firstResults.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)
        let secondDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: secondFrame,
            isRetry: false
        ) { result in
            secondResults.append(result)
        }
        let secondRequest = try XCTUnwrap(secondDecision.request)

        for delivery in secondDecision.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(firstResults.map(\.writeResult.failureReason), [.cancelled])

        let staleOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest)
        ])
        XCTAssertTrue(staleOutcome.deliveries.isEmpty)
        XCTAssertTrue(staleOutcome.retries.isEmpty)
        XCTAssertEqual(ledger.pendingFrameWrite(for: 10), secondFrame)

        let currentOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: secondRequest)
        ])
        XCTAssertEqual(currentOutcome.deliveries.count, 1)
        for delivery in currentOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(secondResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), secondFrame)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: 10))
    }

    @MainActor
    func testAXFrameLedgerPreservesPendingAllComponentsWhenPositionSupersedes() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let first = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            components: .all,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertEqual(try XCTUnwrap(first.request).components, .all)

        let second = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: CGRect(x: 40, y: 50, width: 300, height: 200),
            components: .position,
            isRetry: false,
            terminalObserver: nil
        )

        XCTAssertEqual(try XCTUnwrap(second.request).components, .all)
    }

    @MainActor
    func testAXFrameLedgerUnionsPendingPositionAndSizeComponents() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let first = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            components: .position,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertEqual(try XCTUnwrap(first.request).components, .position)

        let second = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: CGRect(x: 10, y: 20, width: 360, height: 240),
            components: .size,
            isRetry: false,
            terminalObserver: nil
        )

        XCTAssertEqual(try XCTUnwrap(second.request).components, .all)
    }

    @MainActor
    func testAXFrameLedgerPreservesVerificationAndCancelsSupersededObserver() throws {
        let ledger = AXFrameApplicationLedger()
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let firstFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let latestFrame = CGRect(x: 40, y: 50, width: 300, height: 200)
        var terminalResults: [AXFrameApplyResult] = []
        let first = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: firstFrame,
            components: .all,
            isRetry: false,
            verify: true,
            terminalObserver: { terminalResults.append($0) }
        )
        XCTAssertNotNil(first.request)

        let second = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: latestFrame,
            components: .position,
            isRetry: false,
            verify: false,
            terminalObserver: nil
        )
        let latestRequest = try XCTUnwrap(second.request)

        XCTAssertEqual(latestRequest.components, .all)
        XCTAssertTrue(latestRequest.verify)
        XCTAssertEqual(second.deliveries.count, 1)
        for delivery in second.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(terminalResults.map(\.targetFrame), [firstFrame])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])

        let outcome = ledger.handleFrameApplyResults([Self.frameResult(for: latestRequest)])
        for delivery in outcome.deliveries {
            delivery.deliver()
        }

        XCTAssertEqual(terminalResults.map(\.targetFrame), [firstFrame])
    }

    @MainActor
    func testAcceptedFrameApplyClearsOnlyItsSkyLightLiveOrigin() {
        let manager = AXManager()
        defer { manager.cleanup() }
        let pid: pid_t = 71037
        let firstWindow = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 10)
        let firstFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        manager.recordSkyLightMove(windowId: 10, origin: firstFrame.origin)
        manager.recordSkyLightMove(windowId: 20, origin: CGPoint(x: 50, y: 60))

        manager.handleAcceptedFrameApplySuccess(
            AXFrameApplyResult(
                pid: pid,
                windowId: 10,
                expectedWindow: firstWindow,
                targetFrame: firstFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    observedFrame: firstFrame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: .all
                )
            )
        )

        XCTAssertNil(manager.skyLightLivePosition(for: 10))
        XCTAssertEqual(manager.skyLightLivePosition(for: 20), CGPoint(x: 50, y: 60))
    }

    @MainActor
    func testAXManagerCleanupInvalidatesAnimationFrameComponentProvenance() {
        let manager = AXManager()
        let windowId = 10
        let frame = CGRect(x: 40, y: 50, width: 300, height: 200)
        let translatedFrame = frame.offsetBy(dx: 30, dy: 0)
        let resizedFrame = CGRect(
            x: translatedFrame.minX,
            y: translatedFrame.minY,
            width: translatedFrame.width + 20,
            height: translatedFrame.height
        )
        manager.confirmFrameWrite(for: windowId, frame: frame)
        manager.recordSkyLightMove(windowId: windowId, origin: translatedFrame.origin)

        XCTAssertEqual(
            manager.animationFrameComponents(for: windowId, targetFrame: translatedFrame),
            .position
        )
        XCTAssertEqual(
            manager.animationFrameComponents(for: windowId, targetFrame: resizedFrame),
            .all
        )

        manager.cleanup()

        XCTAssertNil(manager.lastAppliedFrame(for: windowId))
        XCTAssertNil(manager.skyLightLivePosition(for: windowId))
        XCTAssertEqual(
            manager.animationFrameComponents(for: windowId, targetFrame: translatedFrame),
            .all
        )
    }

    @MainActor
    func testAXFrameLedgerRekeysPendingRequestBeforeCompletion() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        var results: [AXFrameApplyResult] = []
        let decision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let request = try XCTUnwrap(decision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        let outcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: request)
        ])
        XCTAssertEqual(outcome.deliveries.count, 1)
        for delivery in outcome.deliveries {
            delivery.deliver()
        }

        XCTAssertEqual(results.map(\.windowId), [20])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
        XCTAssertFalse(ledger.hasPendingFrameWrite(for: 20))
    }

    @MainActor
    func testAXFrameLedgerRetriesRekeyCancelledOldIdCompletion() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let rekeyedWindow = AXWindowRef(element: window.element, windowId: 20)
        var results: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        let cancelledOldCompletion = Self.frameResult(for: firstRequest, failureReason: .cancelled)
        let cancelledOutcome = ledger.handleFrameApplyResults([cancelledOldCompletion])

        XCTAssertTrue(cancelledOutcome.deliveries.isEmpty)
        XCTAssertEqual(cancelledOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: getpid(),
                windowId: 20,
                expectedWindow: rekeyedWindow,
                frame: frame,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])

        let retryDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 20,
            expectedWindow: rekeyedWindow,
            frame: frame,
            isRetry: true,
            terminalObserver: nil
        )
        let retryRequest = try XCTUnwrap(retryDecision.request)
        let retryOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: retryRequest)
        ])
        for delivery in retryOutcome.deliveries {
            delivery.deliver()
        }

        XCTAssertEqual(results.map(\.requestId), [retryRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
    }

    @MainActor
    func testAXFrameLedgerTransfersObserverToRetryRequest() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        var results: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false
        ) { result in
            results.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        let failedOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest, failureReason: .staleElement)
        ])
        XCTAssertTrue(failedOutcome.deliveries.isEmpty)
        XCTAssertEqual(failedOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: getpid(),
                windowId: 10,
                expectedWindow: window,
                frame: frame,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])

        let retryDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: true,
            terminalObserver: nil
        )
        let retryRequest = try XCTUnwrap(retryDecision.request)

        let staleOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest)
        ])
        XCTAssertTrue(staleOutcome.deliveries.isEmpty)

        let retryOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: retryRequest)
        ])
        XCTAssertEqual(retryOutcome.deliveries.count, 1)
        for delivery in retryOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(results.map(\.requestId), [retryRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), frame)
    }

    @MainActor
    func testAXFrameLedgerTransfersObserverToSameTargetNonRetryReplacement() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        var firstResults: [AXFrameApplyResult] = []
        var secondResults: [AXFrameApplyResult] = []
        let firstDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false
        ) { result in
            firstResults.append(result)
        }
        let firstRequest = try XCTUnwrap(firstDecision.request)

        let failedOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: firstRequest, failureReason: .staleElement)
        ])
        XCTAssertEqual(failedOutcome.retries, [
            AXFrameRetryRequest(
                requestId: firstRequest.requestId,
                pid: getpid(),
                windowId: 10,
                expectedWindow: window,
                frame: frame,
                currentFrameHint: firstRequest.currentFrameHint
            )
        ])

        let secondDecision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false
        ) { result in
            secondResults.append(result)
        }
        let secondRequest = try XCTUnwrap(secondDecision.request)

        let currentOutcome = ledger.handleFrameApplyResults([
            Self.frameResult(for: secondRequest)
        ])
        XCTAssertEqual(currentOutcome.deliveries.count, 1)
        for delivery in currentOutcome.deliveries {
            delivery.deliver()
        }
        XCTAssertEqual(firstResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(secondResults.map(\.requestId), [secondRequest.requestId])
        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), frame)
    }

    @MainActor
    func testAXFrameLedgerOldIdCancelAndSuppressDoNotDestroyRekeyedState() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cancelLedger = AXFrameApplicationLedger()
        let cancelWindow = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let rekeyedCancelWindow = AXWindowRef(element: cancelWindow.element, windowId: 20)
        var cancelResults: [AXFrameApplyResult] = []
        let cancelDecision = cancelLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: cancelWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                cancelResults.append(result)
            }
        )
        let cancelRequest = try XCTUnwrap(cancelDecision.request)
        cancelLedger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(cancelLedger.cancelFrameJob(windowId: 10).isEmpty)
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(cancelLedger.hasPendingFrameWrite(for: 20))
        XCTAssertTrue(cancelResults.isEmpty)
        XCTAssertEqual(
            cancelLedger.handleFrameApplyResults([
                Self.frameResult(for: cancelRequest, failureReason: .cancelled)
            ]).retries,
            [AXFrameRetryRequest(
                requestId: cancelRequest.requestId,
                pid: getpid(),
                windowId: 20,
                expectedWindow: rekeyedCancelWindow,
                frame: frame,
                currentFrameHint: cancelRequest.currentFrameHint
            )]
        )

        let suppressLedger = AXFrameApplicationLedger()
        let suppressWindow = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 30)
        let suppressDecision = suppressLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 30,
            expectedWindow: suppressWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNotNil(suppressDecision.request)
        suppressLedger.rekeyWindowState(oldWindowId: 30, newWindowId: 40)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 40)
        XCTAssertTrue(suppressLedger.suppressFrameWrite(windowId: 30).isEmpty)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 40)
        XCTAssertTrue(suppressLedger.hasPendingFrameWrite(for: 40))
    }

    @MainActor
    func testAXFrameLedgerLiveIdCancelSuppressAndRemoveClearRekeyedState() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cancelLedger = AXFrameApplicationLedger()
        let cancelWindow = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        var cancelResults: [AXFrameApplyResult] = []
        let cancelDecision = cancelLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: cancelWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                cancelResults.append(result)
            }
        )
        let cancelRequest = try XCTUnwrap(cancelDecision.request)
        cancelLedger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        for delivery in cancelLedger.cancelFrameJob(windowId: 20) {
            delivery.deliver()
        }
        XCTAssertEqual(cancelLedger.resolvedWindowId(for: 10), 10)
        XCTAssertEqual(cancelResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertFalse(cancelLedger.hasPendingFrameWrite(for: 20))
        XCTAssertTrue(
            cancelLedger.handleFrameApplyResults([
                Self.frameResult(for: cancelRequest, failureReason: .cancelled)
            ]).deliveries.isEmpty
        )

        let suppressLedger = AXFrameApplicationLedger()
        let suppressWindow = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 30)
        let suppressDecision = suppressLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 30,
            expectedWindow: suppressWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: nil
        )
        XCTAssertNotNil(suppressDecision.request)
        suppressLedger.rekeyWindowState(oldWindowId: 30, newWindowId: 40)
        _ = suppressLedger.suppressFrameWrite(windowId: 40)
        XCTAssertEqual(suppressLedger.resolvedWindowId(for: 30), 30)
        XCTAssertFalse(suppressLedger.hasPendingFrameWrite(for: 40))

        let removeLedger = AXFrameApplicationLedger()
        let removeWindow = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 50)
        var removeResults: [AXFrameApplyResult] = []
        let removeDecision = removeLedger.prepareFrameApplication(
            pid: getpid(),
            windowId: 50,
            expectedWindow: removeWindow,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                removeResults.append(result)
            }
        )
        let removeRequest = try XCTUnwrap(removeDecision.request)
        removeLedger.rekeyWindowState(oldWindowId: 50, newWindowId: 60)
        for delivery in removeLedger.removeWindowState(windowId: 60) {
            delivery.deliver()
        }
        XCTAssertEqual(removeLedger.resolvedWindowId(for: 50), 50)
        XCTAssertEqual(removeResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertFalse(removeLedger.hasPendingFrameWrite(for: 60))
        XCTAssertTrue(
            removeLedger.handleFrameApplyResults([
                Self.frameResult(for: removeRequest)
            ]).deliveries.isEmpty
        )
    }

    @MainActor
    func testAXFrameLedgerOldWindowRemoveDoesNotRemoveRekeyedPendingState() throws {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let window = AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: 10)
        let rekeyedWindow = AXWindowRef(element: window.element, windowId: 20)
        var results: [AXFrameApplyResult] = []
        let decision = ledger.prepareFrameApplication(
            pid: getpid(),
            windowId: 10,
            expectedWindow: window,
            frame: frame,
            isRetry: false,
            terminalObserver: { result in
                results.append(result)
            }
        )
        let request = try XCTUnwrap(decision.request)

        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(ledger.removeWindowState(windowId: 10).isEmpty)

        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 20)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(ledger.hasPendingFrameWrite(for: 20))
        XCTAssertEqual(
            ledger.handleFrameApplyResults([
                Self.frameResult(for: request, failureReason: .cancelled)
            ]).retries,
            [AXFrameRetryRequest(
                requestId: request.requestId,
                pid: getpid(),
                windowId: 20,
                expectedWindow: rekeyedWindow,
                frame: frame,
                currentFrameHint: request.currentFrameHint
            )]
        )
    }

    @MainActor
    func testAXFrameLedgerClearsSettledRekeyAliasWhenNoPendingState() {
        let ledger = AXFrameApplicationLedger()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

        ledger.confirmFrameWrite(for: 10, frame: frame)
        ledger.rekeyWindowState(oldWindowId: 10, newWindowId: 20)
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
        XCTAssertEqual(ledger.resolvedWindowId(for: 10), 10)

        let updatedFrame = CGRect(x: 30, y: 40, width: 500, height: 300)
        ledger.confirmFrameWrite(for: 10, frame: updatedFrame)

        XCTAssertEqual(ledger.lastAppliedFrame(for: 10), updatedFrame)
        XCTAssertEqual(ledger.lastAppliedFrame(for: 20), frame)
    }

    @MainActor
    func testManagedRetirementRemovesWorldBeforeTerminalFrameObserverDelivery() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_011
        let windowId = 765_111
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            window,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []
        var worldOwnersDuringDelivery: [WindowToken?] = []

        controller.axManager.applyFramesParallel([
            .init(
                pid: pid,
                window: window,
                frame: CGRect(x: 10, y: 20, width: 300, height: 200)
            )
        ]) { result in
            terminalResults.append(result)
            worldOwnersDuringDelivery.append(
                controller.workspaceManager.entry(forWindowId: windowId)?.token
            )
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axEventHandler.handleRemoved(token: token)

        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
        XCTAssertEqual(worldOwnersDuringDelivery, [nil])
        XCTAssertNil(controller.workspaceManager.entry(forWindowId: windowId))
    }

    @MainActor
    func testLayoutInvalidationCancelsPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_001
        let windowId = 765_101
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [.init(pid: pid, window: axRef, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: token
        )

        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testFocusOnlyInvalidationDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_002
        let windowId = 765_102
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [.init(pid: pid, window: axRef, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        _ = controller.workspaceManager.beginManagedFocusRequest(token, in: workspaceId, requestId: 7)
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testPureLayoutInvalidationDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_008
        let windowId = 765_108
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [.init(pid: pid, window: axRef, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testSuppressedLayoutInvalidationDoesNotCancelPendingAXFrameObserverThroughControllerWiring() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 765_003
        let windowId = 765_103
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        var terminalResults: [AXFrameApplyResult] = []

        controller.axManager.applyFramesParallel(
            [.init(pid: pid, window: axRef, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        ) { result in
            terminalResults.append(result)
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(
                HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .workspaceInactive
                ),
                for: token
            )
        }
        XCTAssertTrue(terminalResults.isEmpty)

        controller.axManager.cancelPendingFrameJobs([(pid, windowId)])
        XCTAssertEqual(terminalResults.map(\.writeResult.failureReason), [.cancelled])
    }

    @MainActor
    func testPendingScratchpadRevealUsesLiveWorkspaceAfterReassignment() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let destinationWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        let pid: pid_t = 765_004
        let windowId = 765_104
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: sourceWorkspaceId,
            mode: .floating
        )
        let staleEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        controller.reassignManagedWindow(token, to: destinationWorkspaceId)

        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: staleEntry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: controller.workspaceManager.monitor(for: destinationWorkspaceId) ?? Monitor.fallback()
            )
        )
        controller.workspaceManager.setManualLayoutOverride(.forceFloat, for: token)
        controller.axManager.confirmFrameWrite(for: windowId, frame: targetFrame)
        XCTAssertEqual(controller.axManager.lastAppliedFrame(for: windowId), targetFrame)
        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                expectedWindow: staleEntry.axRef,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), hiddenState)
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: windowId))
    }

    @MainActor
    func testPendingScratchpadRevealSuccessActionRejectsStaleFocusSeq() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let pid: pid_t = 765_006
        let windowId = 765_106
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let focusToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 765_206),
            pid: pid,
            windowId: 765_206,
            to: workspaceId
        )
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        var didRun = false

        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: monitor,
                onSuccess: {
                    didRun = true
                }
            )
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(focusToken, in: workspaceId, requestId: 99)

        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                expectedWindow: entry.axRef,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertFalse(didRun)
    }

    @MainActor
    func testPendingScratchpadRevealSuccessActionRebasesLocalHiddenMutation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let pid: pid_t = 765_007
        let windowId = 765_107
        let targetFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        var didRun = false

        controller.workspaceManager.setScratchpadToken(token)
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let transactionId = try XCTUnwrap(
            controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: monitor,
                onSuccess: {
                    didRun = true
                }
            )
        )

        controller.layoutRefreshController.completePendingRevealTransaction(
            with: Self.frameResult(
                requestId: 1,
                pid: pid,
                windowId: windowId,
                expectedWindow: entry.axRef,
                targetFrame: targetFrame,
                currentFrameHint: nil
            ),
            transactionId: transactionId
        )

        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
        XCTAssertTrue(didRun)
    }

    @MainActor
    func testNiriFocusNeighborAcrossColumnsFocusesSelectedWindowAfterViewportCommit() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_009), windowId: 765_109),
            pid: 765_009,
            windowId: 765_109,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_010), windowId: 765_110),
            pid: 765_010,
            windowId: 765_110,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: firstNode.id,
            focusedToken: firstToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let forwardDirection: Direction = engine.monitorForWorkspace(workspaceId)?.orientation == .vertical
            ? .up
            : .right

        _ = controller.niriLayoutHandler.focusNeighbor(direction: forwardDirection)
        for _ in 0 ..< 40 where focusedTokens.last != secondToken {
            if let refreshTask = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await refreshTask.value
            } else {
                await Task.yield()
            }
        }

        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, secondNode.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), secondToken)
        XCTAssertEqual(focusedTokens.last, secondToken)
    }

    @MainActor
    func testNiriPostLayoutFocusAppliesSynchronously() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let selectedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_011), windowId: 765_111),
            pid: 765_011,
            windowId: 765_111,
            to: workspaceId
        )
        let staleLastFocusedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_012), windowId: 765_112),
            pid: 765_012,
            windowId: 765_112,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let selectedNode = engine.addWindow(
            token: selectedToken,
            to: workspaceId,
            afterSelection: nil
        )
        _ = engine.addWindow(
            token: staleLastFocusedToken,
            to: workspaceId,
            afterSelection: selectedNode.id,
            focusedToken: selectedToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedNode.id,
            focusedToken: selectedToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.niriLayoutHandler.activateNode(
            selectedNode,
            in: workspaceId,
            state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(in: workspaceId)

        XCTAssertEqual(focusedTokens.last, selectedToken)

        _ = controller.workspaceManager.rememberFocus(staleLastFocusedToken, in: workspaceId)

        XCTAssertEqual(focusedTokens.last, selectedToken)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), staleLastFocusedToken)
    }

    @MainActor
    func testNiriRapidFocusNavigationAppliesFinalSelectionSynchronously() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_030), windowId: 765_130),
            pid: 765_030,
            windowId: 765_130,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_031), windowId: 765_131),
            pid: 765_031,
            windowId: 765_131,
            to: workspaceId
        )
        let thirdToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_032), windowId: 765_132),
            pid: 765_032,
            windowId: 765_132,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        let thirdNode = engine.addWindow(
            token: thirdToken,
            to: workspaceId,
            afterSelection: secondNode.id,
            focusedToken: secondToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: firstNode.id,
            focusedToken: firstToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        let orientation = engine.monitorForWorkspace(workspaceId)?.orientation ?? .horizontal
        let forwardDirection: Direction = orientation == .vertical ? .up : .right
        let backwardDirection: Direction = orientation == .vertical ? .down : .left

        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        XCTAssertTrue(controller.niriLayoutHandler.focusNeighbor(direction: forwardDirection))
        XCTAssertTrue(controller.niriLayoutHandler.focusNeighbor(direction: forwardDirection))
        XCTAssertTrue(controller.niriLayoutHandler.focusNeighbor(direction: backwardDirection))

        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId, secondNode.id)
        XCTAssertEqual(thirdNode.token, thirdToken)
        XCTAssertEqual(focusedTokens, [secondToken, thirdToken, secondToken])
    }

    @MainActor
    func testDwindleFocusNeighborFocusesSelectedWindowSynchronously() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_040), windowId: 765_140),
            pid: 765_040,
            windowId: 765_140,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_041), windowId: 765_141),
            pid: 765_041,
            windowId: 765_141,
            to: workspaceId
        )
        let thirdToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_042), windowId: 765_142),
            pid: 765_042,
            windowId: 765_142,
            to: workspaceId
        )
        _ = engine.addWindow(token: firstToken, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: secondToken, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: thirdToken, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let firstLeaf = try XCTUnwrap(engine.findNode(for: firstToken, in: workspaceId))
        controller.workspaceManager.withEngineMutationScope {
            engine.setSelectedNode(firstLeaf, in: workspaceId)
        }

        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        XCTAssertTrue(controller.dwindleLayoutHandler.focusNeighbor(direction: .right))
        XCTAssertTrue(controller.dwindleLayoutHandler.focusNeighbor(direction: .right))
        XCTAssertTrue(controller.dwindleLayoutHandler.focusNeighbor(direction: .left))

        XCTAssertEqual(focusedTokens, [secondToken, thirdToken, secondToken])
        XCTAssertEqual(engine.selectedNode(in: workspaceId)?.windowToken, secondToken)
    }

    @MainActor
    func testDwindleActivateWindowFocusesSynchronouslyWhenLayoutRefreshBlocked() throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_050), windowId: 765_150),
            pid: 765_050,
            windowId: 765_150,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_051), windowId: 765_151),
            pid: 765_051,
            windowId: 765_151,
            to: workspaceId
        )
        _ = engine.addWindow(token: firstToken, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: secondToken, to: workspaceId, activeWindowFrame: nil)

        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }

        controller.dwindleLayoutHandler.activateWindow(firstToken, in: workspaceId, layoutRefresh: true)

        XCTAssertEqual(focusedTokens, [firstToken])
    }

    @MainActor
    func testNiriProtectedReplacementActivationPreservesViewportOffset() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_013), windowId: 765_113),
            pid: 765_013,
            windowId: 765_113,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_014), windowId: 765_114),
            pid: 765_014,
            windowId: 765_114,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = firstNode.id
        state.activeColumnIndex = 0
        state.viewOffset = -16.0

        controller.niriLayoutHandler.activateNode(
            secondNode,
            in: workspaceId,
            state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                preserveViewportAnchor: true,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )

        XCTAssertEqual(state.selectedNodeId, secondNode.id)
        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, -16.0, accuracy: 0.001)
        XCTAssertFalse(state.hasPendingOffsetAnimation)
    }

    @MainActor
    func testNiriTabLocalAddAtLeftEdgePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.leftEdge)
    }

    @MainActor
    func testNiriTabLocalAddInMiddlePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.middle)
    }

    @MainActor
    func testNiriTabLocalAddAtRightEdgePreservesViewportWithoutScroll() async throws {
        try await Self.assertNiriTabLocalAddPreservesViewport(.rightEdge)
    }

    @MainActor
    func testNiriMixedTabLocalAndNewColumnOnlyAnimatesTrueColumnAddition() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 3,
            pidBase: 765_300,
            windowBase: 765_400,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: 1
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let targetColumn = initialColumns[1]
        let selectedNode = try XCTUnwrap(targetColumn.windowNodes.first)
        let targetColumnX = state.columnX(
            at: 1,
            columns: initialColumns,
            gap: CGFloat(controller.workspaceManager.gaps)
        )
        let viewOrigin = targetColumnX - (monitor.visibleFrame.width - columnWidth) / 2
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 1
        state.viewOffset = viewOrigin - targetColumnX
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let newTabToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_303), windowId: 765_403),
            pid: 765_303,
            windowId: 765_403,
            to: workspaceId
        )
        let newColumnToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_304), windowId: 765_404),
            pid: 765_304,
            windowId: 765_404,
            to: workspaceId
        )
        var placements = Self.niriRestorePlacements(
            tokens: existingTokens,
            columnWidth: columnWidth,
            tabbedColumnIndex: 1,
            activeTabIndex: 1
        )
        placements[newTabToken] = Self.niriRestorePlacement(
            columnIndex: 1,
            tileIndex: 1,
            displayMode: .tabbed,
            activeTileIndex: 1,
            columnWidth: columnWidth
        )
        controller.workspaceManager.setNiriRestorePlacements(placements)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let newTabNode = try XCTUnwrap(engine.findNode(for: newTabToken, in: workspaceId))
        let newColumnNode = try XCTUnwrap(engine.findNode(for: newColumnToken, in: workspaceId))
        let newTabColumn = try XCTUnwrap(engine.column(of: newTabNode))

        XCTAssertFalse(newTabNode.hasMoveAnimationsRunning)
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newColumnToken))
        XCTAssertEqual(newTabColumn.activeWindow?.token, newTabToken)
        XCTAssertEqual(patchedState.selectedNodeId, newColumnNode.id)
    }

    @MainActor
    func testNiriLiveCreateInSelectedTabbedColumnCreatesNormalColumn() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 2,
            pidBase: 765_500,
            windowBase: 765_600,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: 0
        )

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let selectedNode = try XCTUnwrap(initialColumns[0].windowNodes.first)
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 0
        state.viewOffset = 0
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let newToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_502), windowId: 765_602),
            pid: 765_502,
            windowId: 765_602,
            to: workspaceId
        )

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let finalColumns = engine.columns(in: workspaceId)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceId))
        let newColumn = try XCTUnwrap(engine.column(of: newNode))

        XCTAssertEqual(finalColumns.count, initialColumns.count + 1)
        XCTAssertEqual(finalColumns[0].displayMode, .tabbed)
        XCTAssertEqual(finalColumns[0].windowNodes.map(\.token), [existingTokens[0]])
        XCTAssertEqual(newColumn.displayMode, .normal)
        XCTAssertEqual(newColumn.windowNodes.map(\.token), [newToken])
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertEqual(patchedState.selectedNodeId, newNode.id)
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newToken))
    }

    @MainActor
    func testNiriVisibleSameAppCreateDoesNotRekeyOrAutoTab() async throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let existingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_510), windowId: 765_610),
            pid: 765_510,
            windowId: 765_610,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_510,
                frame: frame
            )
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let existingNode = engine.addWindow(
            token: existingToken,
            to: workspaceId,
            afterSelection: nil
        )
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = existingNode.id
        state.activeColumnIndex = 0
        state.viewOffset = 0
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let newToken = WindowToken(pid: 765_510, windowId: 765_611)
        controller.axEventHandler.visibleWindowInfoProvider = {
            [
                Self.visibleWindowInfo(pid: existingToken.pid, windowId: existingToken.windowId, frame: frame),
                Self.visibleWindowInfo(pid: newToken.pid, windowId: newToken.windowId, frame: frame)
            ]
        }
        XCTAssertFalse(
            Self.rekeyStructuralManagedReplacementIfNeeded(
                controller.axEventHandler,
                token: newToken,
                windowId: UInt32(newToken.windowId),
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(newToken.pid),
                    windowId: newToken.windowId
                ),
                bundleId: Self.nativeTabBundleId(pid: newToken.pid),
                mode: .tiling,
                facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: frame)
            )
        )
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(newToken.pid), windowId: newToken.windowId),
            pid: newToken.pid,
            windowId: newToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: newToken.pid,
                frame: frame
            )
        )

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceId))
        let leaderColumn = try XCTUnwrap(engine.column(of: existingNode))
        let newColumn = try XCTUnwrap(engine.column(of: newNode))

        XCTAssertFalse(leaderColumn === newColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)
        XCTAssertEqual(leaderColumn.displayMode, .normal)
        XCTAssertEqual(newColumn.displayMode, .normal)
        XCTAssertTrue(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newToken))
    }

    @MainActor
    func testStructuralReplacementUsesCapturedWindowServerEvidenceWithoutLiveQueries() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_515), windowId: 765_615),
            pid: 765_515,
            windowId: 765_615,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_515,
                frame: frame
            )
        )
        let newToken = WindowToken(pid: oldToken.pid, windowId: 765_616)
        let newWindowInfo = Self.visibleWindowInfo(
            pid: newToken.pid,
            windowId: newToken.windowId,
            frame: frame
        )
        var visibleQueryCount = 0
        var windowQueryCount = 0
        controller.axEventHandler.visibleWindowInfoProvider = {
            visibleQueryCount += 1
            return []
        }
        controller.axEventHandler.windowInfoProvider = { _ in
            windowQueryCount += 1
            return nil
        }

        let match = controller.axEventHandler.structuralReplacementMatch(
            token: newToken,
            bundleId: Self.nativeTabBundleId(pid: newToken.pid),
            mode: .tiling,
            facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: frame),
            capturedWindowServerInfoByWindowId: [newToken.windowId: newWindowInfo],
            capturedWindowServerAuthoritativeWindowIds: [oldToken.windowId, newToken.windowId]
        )

        XCTAssertEqual(match?.token, oldToken)
        XCTAssertEqual(visibleQueryCount, 0)
        XCTAssertEqual(windowQueryCount, 0)
    }

    @MainActor
    func testStructuralReplacementRequiresCapturedWindowServerCoverageAndPIDAuthority() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let frame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_517), windowId: 765_617),
            pid: 765_517,
            windowId: 765_617,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_517,
                frame: frame
            )
        )
        let newToken = WindowToken(pid: oldToken.pid, windowId: 765_618)
        let newWindowInfo = Self.visibleWindowInfo(
            pid: newToken.pid,
            windowId: newToken.windowId,
            frame: frame
        )
        var visibleQueryCount = 0
        var windowQueryCount = 0
        controller.axEventHandler.visibleWindowInfoProvider = {
            visibleQueryCount += 1
            return []
        }
        controller.axEventHandler.windowInfoProvider = { _ in
            windowQueryCount += 1
            return nil
        }

        let match = controller.axEventHandler.structuralReplacementMatch(
            token: newToken,
            bundleId: Self.nativeTabBundleId(pid: newToken.pid),
            mode: .tiling,
            facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: frame),
            capturedWindowServerInfoByWindowId: [newToken.windowId: newWindowInfo],
            capturedWindowServerAuthoritativeWindowIds: [newToken.windowId]
        )
        let pidLimitedMatch = controller.axEventHandler.structuralReplacementMatch(
            token: newToken,
            bundleId: Self.nativeTabBundleId(pid: newToken.pid),
            mode: .tiling,
            facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: frame),
            capturedWindowServerInfoByWindowId: [newToken.windowId: newWindowInfo],
            capturedWindowServerAuthoritativeWindowIds: [oldToken.windowId, newToken.windowId],
            capturedWindowServerAuthoritativePIDs: []
        )

        XCTAssertNil(match)
        XCTAssertNil(pidLimitedMatch)
        XCTAssertEqual(visibleQueryCount, 0)
        XCTAssertEqual(windowQueryCount, 0)
    }

    @MainActor
    func testNiriNativeMacOSTabRekeysInvisibleSiblingWithoutOmniWMTab() async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        try Self.configureOrientation(.horizontal, for: workspaceId, controller: controller)
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let nativeFrame = CGRect(x: 160, y: 120, width: 720, height: 520)
        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_520), windowId: 765_620),
            pid: 765_520,
            windowId: 765_620,
            to: workspaceId
        )
        let oldToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_521), windowId: 765_621),
            pid: 765_521,
            windowId: 765_621,
            to: workspaceId,
            managedReplacementMetadata: Self.managedReplacementMetadata(
                workspaceId: workspaceId,
                pid: 765_521,
                frame: nativeFrame
            )
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_522), windowId: 765_622),
            pid: 765_522,
            windowId: 765_622,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: [leftToken, oldToken, rightToken],
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: -1
        )
        let oldHandle = try XCTUnwrap(controller.workspaceManager.handle(for: oldToken))
        _ = controller.workspaceManager.confirmManagedFocus(
            oldToken,
            in: workspaceId,
            activateWorkspaceOnMonitor: false
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let oldNode = try XCTUnwrap(engine.findNode(for: oldToken, in: workspaceId))
        let gap = CGFloat(controller.workspaceManager.gaps)
        let selectedColumnX = state.columnX(at: 1, columns: initialColumns, gap: gap)
        let viewOrigin = selectedColumnX - (monitor.visibleFrame.width - columnWidth) / 2
        state.selectedNodeId = oldNode.id
        state.activeColumnIndex = 1
        state.viewOffset = viewOrigin - selectedColumnX
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let newToken = WindowToken(pid: oldToken.pid, windowId: 765_623)
        controller.axEventHandler.visibleWindowInfoProvider = {
            [
                Self.visibleWindowInfo(pid: newToken.pid, windowId: newToken.windowId, frame: nativeFrame)
            ]
        }

        XCTAssertTrue(
            Self.rekeyStructuralManagedReplacementIfNeeded(
                controller.axEventHandler,
                token: newToken,
                windowId: UInt32(newToken.windowId),
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(newToken.pid),
                    windowId: newToken.windowId
                ),
                bundleId: Self.nativeTabBundleId(pid: newToken.pid),
                mode: .tiling,
                facts: Self.nativeTabFacts(pid: newToken.pid, windowId: newToken.windowId, frame: nativeFrame)
            )
        )
        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: newToken))
        XCTAssertTrue(controller.workspaceManager.handle(for: newToken) === oldHandle)
        XCTAssertEqual(controller.workspaceManager.focusedToken, newToken)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(
                activeWorkspaces: [workspaceId],
                useScrollAnimationPath: true
            )
        }
        let plan = try XCTUnwrap(plans.first)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState)
        let finalColumns = engine.columns(in: workspaceId)
        let newNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceId))
        let patchedViewOrigin = patchedState.viewPosPixels(columns: finalColumns, gap: gap)

        XCTAssertNil(engine.findNode(for: oldToken, in: workspaceId))
        XCTAssertEqual(newNode.id, oldNode.id)
        XCTAssertEqual(finalColumns.count, initialColumns.count)
        XCTAssertEqual(finalColumns[1].displayMode, .normal)
        XCTAssertEqual(finalColumns[1].windowNodes.map(\.token), [newToken])
        XCTAssertFalse(plan.animationDirectives.containsStartNiriScroll(for: workspaceId))
        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId))
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId))
        XCTAssertFalse(patchedState.hasPendingOffsetAnimation)
        XCTAssertEqual(patchedViewOrigin, viewOrigin, accuracy: 0.001)
        XCTAssertEqual(patchedState.selectedNodeId, newNode.id)
    }

    @MainActor
    func testBatchedLayoutBuildCommitsNiriViewportAndStampsPostBuildSeq() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        _ = Self.addNiriRuntimeWindows(
            count: 2,
            pidBase: 766_000,
            windowBase: 766_100,
            to: workspaceId,
            controller: controller
        )

        let selectionBeforeBatch = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        XCTAssertNil(selectionBeforeBatch)
        XCTAssertNotNil(controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId)

        let committedSeq = controller.workspaceManager.worldSeq
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            XCTAssertNil(plan.sessionPatch.viewportState)
            XCTAssertEqual(plan.sessionPatch.plannedSeq, committedSeq)
        }
    }

    @MainActor
    func testNiriRelayoutDoesNotReplaceFloatingWorkspaceMRUWithTiledSelection() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tiled = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_020), windowId: 766_120),
            pid: 766_020,
            windowId: 766_120,
            to: workspaceId
        )
        let floating = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_021), windowId: 766_121),
            pid: 766_021,
            windowId: 766_121,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.addWindow(token: tiled, to: workspaceId, afterSelection: nil)
        }
        _ = controller.workspaceManager.rememberFocus(tiled, in: workspaceId)
        _ = controller.workspaceManager.rememberFocus(floating, in: workspaceId)

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first { $0.workspaceId == workspaceId })

        XCTAssertEqual(plan.sessionPatch.rememberedFocusToken, tiled)
        XCTAssertNotNil(controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(plan))
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), tiled)
        XCTAssertEqual(controller.workspaceManager.lastFloatingFocusedToken(in: workspaceId), floating)
        XCTAssertEqual(
            controller.workspaceManager.resolveWorkspaceFocusToken(in: workspaceId),
            floating
        )
    }

    @MainActor
    func testNiriViewportOperationNormalizesDisplayRefreshRateFromEngineMonitor() throws {
        let fixture = try Self.niriRefreshRateFixture(displayId: 98_765)
        let controller = fixture.controller
        let workspaceId = fixture.workspaceId
        let monitor = fixture.monitor
        let engine = fixture.engine
        _ = Self.addNiriRuntimeWindows(
            count: 2,
            pidBase: 766_200,
            windowBase: 766_300,
            to: workspaceId,
            controller: controller
        )
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        controller.layoutRefreshController.layoutState.refreshRateByDisplay[monitor.displayId] = 120.0

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        XCTAssertFalse(plans.isEmpty)
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: workspaceId).displayRefreshRate, 120.0)
        XCTAssertEqual(engine.displayRefreshRate(in: workspaceId), 60.0)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { _ in }

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).displayRefreshRate,
            engine.displayRefreshRate(in: workspaceId)
        )
    }

    @MainActor
    func testApplySessionPatchNormalizesNiriViewportDisplayRefreshRate() throws {
        let fixture = try Self.niriRefreshRateFixture(displayId: 98_766)
        let controller = fixture.controller
        let workspaceId = fixture.workspaceId
        let engine = fixture.engine
        var viewportState = ViewportState()
        viewportState.activeColumnIndex = 3
        viewportState.viewOffset = 42.0
        viewportState.displayRefreshRate = 120.0

        let changed = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: viewportState,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let storedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        XCTAssertTrue(changed)
        XCTAssertEqual(storedState.activeColumnIndex, 3)
        XCTAssertEqual(storedState.viewOffset, 42.0)
        XCTAssertEqual(storedState.displayRefreshRate, engine.displayRefreshRate(in: workspaceId))
        XCTAssertEqual(engine.displayRefreshRate(in: workspaceId), 60.0)
    }

    @MainActor
    func testBatchedLayoutBuildLeavesDwindlePlansWithoutViewportAndStampsPostBuildSeq() throws {
        let settings = Self.settingsStore()
        settings.workspaceConfigurations = settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_010), windowId: 766_110),
            pid: 766_010,
            windowId: 766_110,
            to: workspaceId
        )
        _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
        }

        let committedSeq = controller.workspaceManager.worldSeq
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            XCTAssertNil(plan.sessionPatch.viewportState)
            XCTAssertEqual(plan.sessionPatch.plannedSeq, committedSeq)
        }
    }

    @MainActor
    func testDwindleRelayoutDoesNotReplaceFloatingWorkspaceMRUWithTiledSelection() throws {
        let settings = Self.settingsStore()
        settings.workspaceConfigurations = settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        let tiled = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_030), windowId: 766_130),
            pid: 766_030,
            windowId: 766_130,
            to: workspaceId
        )
        let floating = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(766_031), windowId: 766_131),
            pid: 766_031,
            windowId: 766_131,
            to: workspaceId,
            mode: .floating
        )
        _ = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.addWindow(token: tiled, to: workspaceId, activeWindowFrame: nil)
        }
        _ = controller.workspaceManager.rememberFocus(tiled, in: workspaceId)
        _ = controller.workspaceManager.rememberFocus(floating, in: workspaceId)

        let plans = controller.workspaceManager.withBatchedLayoutBuild {
            controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first { $0.workspaceId == workspaceId })

        XCTAssertEqual(plan.sessionPatch.rememberedFocusToken, tiled)
        XCTAssertNotNil(controller.layoutRefreshController.executeLayoutPlanReturningAcceptedSeq(plan))
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), tiled)
        XCTAssertEqual(controller.workspaceManager.lastFloatingFocusedToken(in: workspaceId), floating)
        XCTAssertEqual(
            controller.workspaceManager.resolveWorkspaceFocusToken(in: workspaceId),
            floating
        )
    }

    @MainActor
    func testInvariantChecksDistinguishesConsistentAndDivergentLayouts() {
        let ws1: WorkspaceDescriptor.ID = UUID()
        let ws2: WorkspaceDescriptor.ID = UUID()
        let token = WindowToken(pid: 1, windowId: 1)
        let nodeId = NodeId()
        let layout = LayoutTopology(
            columns: [.init(tiles: [.init(nodeId: nodeId, token: token, isFullscreen: false)])]
        )
        var viewport = ViewportState()
        viewport.selectedNodeId = nodeId

        XCTAssertTrue(
            InvariantChecks.validate(
                snapshot: Self.snapshot(
                    windows: [Self.window(token: token, workspaceId: ws1)],
                    viewports: [ws1: viewport],
                    layouts: [ws1: layout]
                )
            ).isEmpty
        )

        XCTAssertEqual(
            Set(InvariantChecks.validate(
                snapshot: Self.snapshot(windows: [], layouts: [ws1: layout])
            ).map(\.code)),
            ["layout_token_missing"]
        )

        XCTAssertEqual(
            Set(InvariantChecks.validate(
                snapshot: Self.snapshot(
                    windows: [Self.window(token: token, workspaceId: ws2)],
                    layouts: [ws1: layout]
                )
            ).map(\.code)),
            ["layout_token_wrong_workspace"]
        )

        var strayViewport = ViewportState()
        strayViewport.selectedNodeId = NodeId()
        XCTAssertEqual(
            Set(InvariantChecks.validate(
                snapshot: Self.snapshot(
                    windows: [Self.window(token: token, workspaceId: ws1)],
                    viewports: [ws1: strayViewport],
                    layouts: [ws1: layout]
                )
            ).map(\.code)),
            ["selection_unresolved"]
        )
    }

    @MainActor
    func testCrossWorkspaceMoveRecordsNoLayoutInvariantViolations() throws {
        let controller = Self.controller()
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let movingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(910_001), windowId: 910_101),
            pid: 910_001, windowId: 910_101, to: ws1
        )
        let sourceSibling = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(910_002), windowId: 910_102),
            pid: 910_002, windowId: 910_102, to: ws1
        )
        let targetSeed = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(910_003), windowId: 910_103),
            pid: 910_003, windowId: 910_103, to: ws2
        )
        let movingNode = engine.addWindow(token: movingToken, to: ws1, afterSelection: nil)
        _ = engine.addWindow(token: sourceSibling, to: ws1, afterSelection: movingNode.id)
        _ = engine.addWindow(token: targetSeed, to: ws2, afterSelection: nil)

        controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: ws1,
            targetWorkspaceId: ws2
        ) { sourceState, targetState in
            guard let moveResult = engine.moveWindowToWorkspace(
                movingNode, from: ws1, to: ws2, sourceState: &sourceState, targetState: &targetState
            ) else { return nil }
            return (moveResult, [movingToken])
        }

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(controller.workspaceManager.workspace(for: movingToken), ws2)
    }

    @MainActor
    func testReAdmittingExistingWindowToNewWorkspaceRemovesStaleNiriNode() throws {
        let controller = Self.controller()
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let movingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_001), windowId: 930_101),
            pid: 930_001, windowId: 930_101, to: ws1
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_002), windowId: 930_102),
            pid: 930_002, windowId: 930_102, to: ws1
        )
        let movingNode = engine.addWindow(token: movingToken, to: ws1, afterSelection: nil)
        _ = engine.addWindow(token: siblingToken, to: ws1, afterSelection: movingNode.id)

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_001), windowId: 930_101),
            pid: 930_001, windowId: 930_101, to: ws2
        )

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(controller.workspaceManager.workspace(for: movingToken), ws2)
        XCTAssertNil(engine.findNode(for: movingToken, in: ws1))
        XCTAssertNotNil(engine.findNode(for: siblingToken, in: ws1))
    }

    @MainActor
    func testWorkspaceAssignmentRemovesStaleNiriNode() throws {
        let controller = Self.controller()
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let movingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(931_001), windowId: 931_101),
            pid: 931_001, windowId: 931_101, to: ws1
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(931_002), windowId: 931_102),
            pid: 931_002, windowId: 931_102, to: ws1
        )
        let movingNode = engine.addWindow(token: movingToken, to: ws1, afterSelection: nil)
        _ = engine.addWindow(token: siblingToken, to: ws1, afterSelection: movingNode.id)

        controller.workspaceManager.setWorkspace(for: movingToken, to: ws2)

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(controller.workspaceManager.workspace(for: movingToken), ws2)
        XCTAssertNil(engine.findNode(for: movingToken, in: ws1))
        XCTAssertNotNil(engine.findNode(for: siblingToken, in: ws1))
    }

    @MainActor
    func testReAdmittingExistingTiledWindowAsFloatingRemovesNiriNode() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let floatingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(932_001), windowId: 932_101),
            pid: 932_001, windowId: 932_101, to: ws
        )
        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(932_002), windowId: 932_102),
            pid: 932_002, windowId: 932_102, to: ws
        )
        let floatingNode = engine.addWindow(token: floatingToken, to: ws, afterSelection: nil)
        _ = engine.addWindow(token: siblingToken, to: ws, afterSelection: floatingNode.id)

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(932_001), windowId: 932_101),
            pid: 932_001,
            windowId: 932_101,
            to: ws,
            mode: .floating
        )

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(controller.workspaceManager.entry(for: floatingToken)?.mode, .floating)
        XCTAssertNil(engine.findNode(for: floatingToken, in: ws))
        XCTAssertNotNil(engine.findNode(for: siblingToken, in: ws))
    }

    @MainActor
    func testAdmittingTokenWithNoModelEntryRemovesStaleNiriNode() throws {
        let controller = Self.controller()
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(940_002), windowId: 940_102),
            pid: 940_002, windowId: 940_102, to: ws1
        )
        _ = engine.addWindow(token: siblingToken, to: ws1, afterSelection: nil)

        let restoredToken = WindowToken(pid: 940_001, windowId: 940_101)
        _ = engine.addWindow(token: restoredToken, to: ws1, afterSelection: nil)

        let admittedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(940_001), windowId: 940_101),
            pid: 940_001, windowId: 940_101, to: ws2
        )

        XCTAssertEqual(admittedToken, restoredToken)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(controller.workspaceManager.workspace(for: restoredToken), ws2)
        XCTAssertNil(engine.findNode(for: restoredToken, in: ws1))
        XCTAssertNotNil(engine.findNode(for: siblingToken, in: ws1))
    }

    @MainActor
    func testAdmittingTokenAlreadyInTargetWorkspacePreservesNiriNode() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let restoredToken = WindowToken(pid: 941_001, windowId: 941_101)
        let restoredNode = engine.addWindow(token: restoredToken, to: ws, afterSelection: nil)

        let admittedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(941_001), windowId: 941_101),
            pid: 941_001, windowId: 941_101, to: ws
        )

        XCTAssertEqual(admittedToken, restoredToken)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertEqual(engine.findNode(for: restoredToken, in: ws)?.id, restoredNode.id)
    }

    @MainActor
    func testAdmittingTokenWithDuplicateNiriNodesKeepsTargetWorkspace() throws {
        let controller = Self.controller()
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(942_002), windowId: 942_102),
            pid: 942_002, windowId: 942_102, to: ws1
        )
        _ = engine.addWindow(token: siblingToken, to: ws1, afterSelection: nil)

        let dupToken = WindowToken(pid: 942_001, windowId: 942_101)
        _ = engine.addWindow(token: dupToken, to: ws1, afterSelection: nil)
        let dupNodeInTarget = engine.addWindow(token: dupToken, to: ws2, afterSelection: nil)

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(942_001), windowId: 942_101),
            pid: 942_001, windowId: 942_101, to: ws2
        )

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertNil(engine.findNode(for: dupToken, in: ws1))
        XCTAssertEqual(engine.findNode(for: dupToken, in: ws2)?.id, dupNodeInTarget.id)
    }

    @MainActor
    func testAdmittingRestoredNodeAsFloatingRemovesNiriNode() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let siblingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(944_002), windowId: 944_102),
            pid: 944_002, windowId: 944_102, to: ws
        )
        _ = engine.addWindow(token: siblingToken, to: ws, afterSelection: nil)

        let restoredToken = WindowToken(pid: 944_001, windowId: 944_101)
        _ = engine.addWindow(token: restoredToken, to: ws, afterSelection: nil)

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(944_001), windowId: 944_101),
            pid: 944_001, windowId: 944_101, to: ws, mode: .floating
        )

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertNil(engine.findNode(for: restoredToken, in: ws))
        XCTAssertNotNil(engine.findNode(for: siblingToken, in: ws))
    }

    @MainActor
    func testNiriTrailingColumnRemovalCorrectsViewportWhenClosingWindowOwnsFocus() async throws {
        try await Self.assertNiriTrailingColumnRemovalCorrectsViewport(focusTarget: .closing)
    }

    @MainActor
    func testNiriTrailingColumnRemovalCorrectsViewportAfterFocusMovesToNeighbor() async throws {
        try await Self.assertNiriTrailingColumnRemovalCorrectsViewport(focusTarget: .neighbor)
    }

    @MainActor
    func testNiriStackedTileRemovalPreservesViewport() async throws {
        let controller = Self.controller()
        let monitor = Monitor(
            id: .init(displayId: 98_801),
            displayId: 98_801,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Stacked Removal"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.motionPolicy.animationsEnabled = false
        controller.workspaceManager.setGaps(to: 8)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let tokens = Self.addNiriRuntimeWindows(
            count: 3,
            pidBase: 978_010,
            windowBase: 978_110,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        Self.seedNiriEngineColumns(
            tokens: tokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: 700,
            tabbedColumnIndex: -1
        )

        let selectedNode = try XCTUnwrap(engine.findNode(for: tokens[1], in: workspaceId))
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 1
        XCTAssertTrue(
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                engine.consumeWindowIntoColumn(
                    focusedColumn: engine.columns(in: workspaceId)[1],
                    in: workspaceId,
                    motion: .disabled,
                    state: &state,
                    workingFrame: monitor.visibleFrame,
                    gaps: 8,
                    orientation: .horizontal
                )
            }
        )

        let stackedColumns = engine.columns(in: workspaceId)
        XCTAssertEqual(stackedColumns.count, 2)
        XCTAssertEqual(stackedColumns[1].windowNodes.count, 2)
        XCTAssertEqual(Set(stackedColumns[1].windowNodes.map(\.token)), Set([tokens[1], tokens[2]]))
        let activePosition = state.columnX(at: 1, columns: stackedColumns, gap: 8)
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = 1
        state.viewOffset = -8 - activePosition
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedNode.id,
            focusedToken: tokens[1],
            in: workspaceId,
            onMonitor: monitor.id
        )
        let stateBeforeRemoval = controller.workspaceManager.niriViewportState(for: workspaceId)

        controller.axEventHandler.handleRemoved(token: tokens[2])
        try Self.assertScheduledNiriRemoval(
            controller,
            workspaceId: workspaceId,
            removedColumn: false
        )
        await Self.waitForRemovalRefresh(controller, removedToken: tokens[2])

        let finalColumns = engine.columns(in: workspaceId)
        let finalState = controller.workspaceManager.niriViewportState(for: workspaceId)
        XCTAssertEqual(finalColumns.count, 2)
        XCTAssertEqual(finalColumns[1].windowNodes.map(\.token), [tokens[1]])
        XCTAssertEqual(finalState.selectedNodeId, stateBeforeRemoval.selectedNodeId)
        XCTAssertEqual(finalState.activeColumnIndex, stateBeforeRemoval.activeColumnIndex)
        XCTAssertEqual(finalState.viewOffset, stateBeforeRemoval.viewOffset, accuracy: 0.001)
        XCTAssertFalse(finalState.hasPendingOffsetAnimation)
    }

    @MainActor
    func testFullRescanMergePreservesNiriColumnRemovalPayload() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .relayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        controller.layoutRefreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .startup
        )
        defer { controller.layoutRefreshController.resetState() }

        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: NodeId(),
            removedNiriColumn: true,
            niriOldFrames: [:],
            shouldRecoverFocus: false
        )

        let pending = try XCTUnwrap(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.windowRemovalPayloads.count, 1)
        XCTAssertTrue(try XCTUnwrap(pending.windowRemovalPayloads.first).removedNiriColumn)
    }

    @MainActor
    func testWindowRemovalRecordsNoLayoutInvariantViolations() async throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let closingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(920_001), windowId: 920_101),
            pid: 920_001, windowId: 920_101, to: ws
        )
        let sibling = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(920_002), windowId: 920_102),
            pid: 920_002, windowId: 920_102, to: ws
        )
        let closingNode = engine.addWindow(token: closingToken, to: ws, afterSelection: nil)
        _ = engine.addWindow(token: sibling, to: ws, afterSelection: closingNode.id, focusedToken: closingToken)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: nil,
            in: ws,
            onMonitor: controller.workspaceManager.monitorId(for: ws)
        )

        controller.axEventHandler.handleRemoved(token: closingToken)
        await Self.waitForRemovalRefresh(controller, removedToken: closingToken)

        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        XCTAssertNil(controller.workspaceManager.entry(for: closingToken))
    }

    @MainActor
    func testNativeFullscreenDestroyPreservesConsumedNiriColumn() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_001), windowId: 930_101),
            pid: 930_001, windowId: 930_101, to: ws
        )
        let peerToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_002), windowId: 930_102),
            pid: 930_002, windowId: 930_102, to: ws
        )
        let targetNode = engine.addWindow(token: targetToken, to: ws, afterSelection: nil)
        _ = engine.addWindow(token: peerToken, to: ws, afterSelection: targetNode.id, focusedToken: targetToken)

        var state = controller.workspaceManager.niriViewportState(for: ws)
        state.selectedNodeId = targetNode.id
        state.activeColumnIndex = 0
        let targetColumn = try XCTUnwrap(engine.column(of: targetNode))
        XCTAssertTrue(
            controller.workspaceManager.withEngineMutationScope(in: ws) {
                engine.consumeWindowIntoColumn(
                    focusedColumn: targetColumn,
                    in: ws,
                    motion: .disabled,
                    state: &state,
                    workingFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    gaps: CGFloat(controller.workspaceManager.gaps),
                    orientation: .horizontal
                )
            }
        )
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: ws,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: ws,
            onMonitor: controller.workspaceManager.monitorId(for: ws)
        )

        let consumedColumn = try XCTUnwrap(engine.column(of: targetNode))
        let consumedTokens = consumedColumn.windowNodes.map(\.token)
        XCTAssertEqual(engine.columns(in: ws).count, 1)
        XCTAssertEqual(consumedTokens.count, 2)
        XCTAssertTrue(consumedTokens.contains(targetToken))
        XCTAssertTrue(consumedTokens.contains(peerToken))
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(targetToken, in: ws))

        controller.axEventHandler.handleRemoved(token: targetToken)

        let record = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(record.transition, .suspended)
        XCTAssertTrue(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertEqual(engine.columns(in: ws).count, 1)
        XCTAssertEqual(consumedColumn.windowNodes.map(\.token), consumedTokens)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    @MainActor
    func testNativeFullscreenTransientDestroyDoesNotPublishOwnerLoss() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(930_003), windowId: 930_103),
            pid: 930_003,
            windowId: 930_103,
            to: workspaceId
        )
        _ = controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(token))
        var publishedOwnerLoss = false
        controller.workspaceManager.onSessionStateChanged = {
            if !controller.workspaceManager.isNonManagedFocusActive
                || controller.workspaceManager.nonManagedFocusToken != token
            {
                publishedOwnerLoss = true
            }
        }

        controller.axEventHandler.handleRemoved(token: token)

        XCTAssertFalse(publishedOwnerLoss)
        XCTAssertEqual(controller.workspaceManager.activeNativeFullscreenFocusOwnerToken, token)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenRecord(for: token)?.transition, .suspended)
    }

    @MainActor
    func testNativeFullscreenSpaceObservationSuspendsBeforeFocusObservation() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(931_001), windowId: 931_101),
            pid: 931_001, windowId: 931_101, to: ws
        )
        _ = controller.niriEngine?.addWindow(token: targetToken, to: ws, afterSelection: nil)

        let fullscreenSpaceId: UInt64 = 9_310
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "test-display",
                        spaceIds: [fullscreenSpaceId],
                        currentSpaceId: fullscreenSpaceId
                    )
                ],
                activeSpaceId: fullscreenSpaceId,
                fullscreenSpaceIds: [fullscreenSpaceId],
                windowSpace: [:]
            )
        )

        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))

        controller.spaceTracker.noteWindowSpace(
            windowId: targetToken.windowId,
            spaceId: fullscreenSpaceId
        )

        let record = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(record.transition, .suspended)
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: targetToken), .nativeFullscreen)
        XCTAssertTrue(controller.workspaceManager.observedState(for: targetToken)?.isNativeFullscreen == true)
    }

    @MainActor
    func testNativeFullscreenSuspendsOnSecondaryDisplayCurrentSpace() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(933_001), windowId: 933_101),
            pid: 933_001, windowId: 933_101, to: ws
        )
        _ = controller.niriEngine?.addWindow(token: targetToken, to: ws, afterSelection: nil)

        let primarySpaceId: UInt64 = 9_330
        let secondaryFullscreenSpaceId: UInt64 = 9_331
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "primary",
                        spaceIds: [primarySpaceId],
                        currentSpaceId: primarySpaceId
                    ),
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "secondary",
                        spaceIds: [secondaryFullscreenSpaceId],
                        currentSpaceId: secondaryFullscreenSpaceId
                    )
                ],
                activeSpaceId: primarySpaceId,
                fullscreenSpaceIds: [secondaryFullscreenSpaceId],
                windowSpace: [:]
            )
        )

        controller.spaceTracker.noteWindowSpace(
            windowId: targetToken.windowId,
            spaceId: secondaryFullscreenSpaceId
        )

        let record = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(record.transition, .suspended)
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: targetToken), .nativeFullscreen)
    }

    @MainActor
    func testNativeFullscreenDestroyUsesObservedFullscreenSpaceBeforeAXFallback() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(932_001), windowId: 932_101),
            pid: 932_001, windowId: 932_101, to: ws
        )
        let targetNode = engine.addWindow(token: targetToken, to: ws, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: ws,
            onMonitor: controller.workspaceManager.monitorId(for: ws)
        )
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                targetToken,
                in: ws,
                onMonitor: controller.workspaceManager.monitorId(for: ws)
            )
        )

        let fullscreenSpaceId: UInt64 = 9_320
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "test-display",
                        spaceIds: [fullscreenSpaceId],
                        currentSpaceId: fullscreenSpaceId
                    )
                ],
                activeSpaceId: fullscreenSpaceId,
                fullscreenSpaceIds: [fullscreenSpaceId],
                windowSpace: [targetToken.windowId: fullscreenSpaceId]
            )
        )

        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))

        controller.axEventHandler.handleRemoved(token: targetToken)

        let record = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(record.transition, .suspended)
        XCTAssertTrue(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    @MainActor
    func testNativeFullscreenCGSDestroyPreservesBeforeTopologyCleanup() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(933_001), windowId: 933_101),
            pid: 933_001, windowId: 933_101, to: ws
        )
        let targetNode = engine.addWindow(token: targetToken, to: ws, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: targetNode.id,
            focusedToken: targetToken,
            in: ws,
            onMonitor: controller.workspaceManager.monitorId(for: ws)
        )
        XCTAssertTrue(
            controller.workspaceManager.setManagedFocus(
                targetToken,
                in: ws,
                onMonitor: controller.workspaceManager.monitorId(for: ws)
            )
        )

        let fullscreenSpaceId: UInt64 = 9_330
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "test-display",
                        spaceIds: [fullscreenSpaceId],
                        currentSpaceId: fullscreenSpaceId
                    )
                ],
                activeSpaceId: fullscreenSpaceId,
                fullscreenSpaceIds: [fullscreenSpaceId],
                windowSpace: [targetToken.windowId: fullscreenSpaceId]
            )
        )

        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertTrue(controller.workspaceManager.isWindowOnObservedNativeFullscreenSpace(targetToken.windowId))

        controller.axEventHandler.handleCGSEvent(
            .destroyed(windowId: UInt32(targetToken.windowId), spaceId: fullscreenSpaceId)
        )

        let record = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(record.transition, .suspended)
        XCTAssertTrue(controller.workspaceManager.showsNativeFullscreenPlaceholder(for: targetToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertTrue(controller.workspaceManager.isWindowOnObservedNativeFullscreenSpace(targetToken.windowId))
        XCTAssertEqual(
            controller.workspaceManager.spaceTopology.spaceForWindow(targetToken.windowId),
            fullscreenSpaceId
        )

        controller.axEventHandler.handleCGSEvent(
            .closed(windowId: UInt32(targetToken.windowId))
        )

        XCTAssertNil(controller.workspaceManager.entry(for: targetToken))
        XCTAssertNil(controller.workspaceManager.spaceTopology.spaceForWindow(targetToken.windowId))
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    @MainActor
    func testNativeFullscreenTopologyRestoreClearsSuspension() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let targetToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(934_001), windowId: 934_101),
            pid: 934_001, windowId: 934_101, to: ws
        )
        _ = controller.niriEngine?.addWindow(token: targetToken, to: ws, afterSelection: nil)

        let fullscreenSpaceId: UInt64 = 9_340
        let normalSpaceId: UInt64 = 9_341
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    SpaceTopology.DisplaySpaces(
                        displayIdentifier: "test-display",
                        spaceIds: [fullscreenSpaceId, normalSpaceId],
                        currentSpaceId: fullscreenSpaceId
                    )
                ],
                activeSpaceId: fullscreenSpaceId,
                fullscreenSpaceIds: [fullscreenSpaceId],
                windowSpace: [:]
            )
        )

        controller.spaceTracker.noteWindowSpace(
            windowId: targetToken.windowId,
            spaceId: fullscreenSpaceId
        )

        let suspendedRecord = try XCTUnwrap(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(suspendedRecord.transition, .suspended)
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: targetToken), .nativeFullscreen)
        XCTAssertTrue(controller.workspaceManager.observedState(for: targetToken)?.isNativeFullscreen == true)

        controller.spaceTracker.noteWindowSpace(
            windowId: targetToken.windowId,
            spaceId: normalSpaceId
        )

        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: targetToken))
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: targetToken), .standard)
        XCTAssertTrue(controller.workspaceManager.observedState(for: targetToken)?.isNativeFullscreen == false)
        XCTAssertEqual(controller.workspaceManager.spaceTopology.spaceForWindow(targetToken.windowId), normalSpaceId)
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    @MainActor
    func testFloatDemotionHysteresisIgnoresTransientMisreadReasons() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        func tiledEntry(pid: pid_t, windowId: Int) throws -> WindowState {
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: ws
            )
            _ = controller.niriEngine?.addWindow(token: token, to: ws, afterSelection: nil)
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
            XCTAssertEqual(entry.mode, .tiling)
            return entry
        }

        func floatingDecision(_ reasons: [AXWindowHeuristicReason]) -> WindowDecision {
            WindowDecision(
                disposition: .floating,
                source: .heuristic,
                layoutDecisionKind: .fallbackLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                heuristicReasons: reasons,
                deferredReason: nil
            )
        }

        func demotionMode(_ reasons: [AXWindowHeuristicReason], _ entry: WindowState) -> TrackedWindowMode? {
            controller.trackedModePreservingAutomaticFallbackState(
                decision: floatingDecision(reasons),
                existingEntry: entry,
                context: .automatic
            )
        }

        let excludedReasons: [AXWindowHeuristicReason] = [
            .missingFullscreenButton,
            .nonStandardSubrole,
            .noButtonsOnNonStandardSubrole
        ]

        let controlEntry = try tiledEntry(pid: 940_002, windowId: 940_102)
        XCTAssertEqual(demotionMode([.accessoryWithoutClose], controlEntry), .tiling)

        var guardedEntries: [(AXWindowHeuristicReason, WindowState)] = []
        for (offset, reason) in excludedReasons.enumerated() {
            let entry = try tiledEntry(pid: pid_t(940_010 + offset), windowId: 940_110 + offset)
            XCTAssertEqual(demotionMode([reason], entry), .tiling)
            guardedEntries.append((reason, entry))
        }

        Thread.sleep(forTimeInterval: 0.35)

        XCTAssertEqual(
            demotionMode([.accessoryWithoutClose], controlEntry),
            .floating,
            "non-excluded reason demotes after the stability interval (control proves the harness flips)"
        )

        for (reason, entry) in guardedEntries {
            XCTAssertEqual(
                demotionMode([reason], entry),
                .tiling,
                "\(reason) must still not demote a tiled window after the stability interval elapses"
            )
        }
    }

    @MainActor
    func testAutomaticTransientWidgetDecisionPreservesModeWhileHelpTagEvicts() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let transientWidgetDecision = WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(WindowRuleEngine.transientWidgetSurfaceRuleName),
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
        let helpTagDecision = WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(WindowRuleEngine.helpTagSurfaceRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            heuristicReasons: [],
            deferredReason: nil
        )

        for (offset, mode) in [TrackedWindowMode.tiling, .floating].enumerated() {
            let pid = pid_t(940_100 + offset)
            let windowId = 940_200 + offset
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId,
                mode: mode
            )
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

            XCTAssertEqual(
                controller.trackedModePreservingAutomaticFallbackState(
                    decision: transientWidgetDecision,
                    existingEntry: entry,
                    context: .automatic
                ),
                mode
            )
            XCTAssertNil(
                controller.trackedModePreservingAutomaticFallbackState(
                    decision: helpTagDecision,
                    existingEntry: entry,
                    context: .automatic
                )
            )
        }
    }

    @MainActor
    func testTransientWidgetWindowServerResolutionUsesAtMostOneTargetedLookup() {
        let controller = Self.controller()
        let token = WindowToken(pid: 940_301, windowId: 940_302)
        let exactWindowInfo = WindowServerInfo(
            id: 940_302,
            pid: 940_301,
            level: 0,
            frame: .zero,
            tags: 5_369_504_898,
            attributes: 3,
            parentId: 940_300
        )
        let candidateFacts = AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXUnknownSubrole as String,
            title: nil,
            hasCloseButton: false,
            hasFullscreenButton: false,
            fullscreenButtonEnabled: false,
            hasZoomButton: false,
            hasMinimizeButton: false,
            appPolicy: .regular,
            bundleId: "org.example.widget-host",
            attributeFetchSucceeded: true
        )
        let ordinaryFacts = AXWindowFacts(
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: nil,
            hasCloseButton: true,
            hasFullscreenButton: true,
            fullscreenButtonEnabled: true,
            hasZoomButton: true,
            hasMinimizeButton: true,
            appPolicy: .regular,
            bundleId: "org.example.widget-host",
            attributeFetchSucceeded: true
        )
        let helpTagFacts = AXWindowFacts(
            role: kAXHelpTagRole as String,
            subrole: kAXUnknownSubrole as String,
            title: nil,
            hasCloseButton: false,
            hasFullscreenButton: false,
            fullscreenButtonEnabled: false,
            hasZoomButton: false,
            hasMinimizeButton: false,
            appPolicy: .regular,
            bundleId: WindowRuleEngine.cleanShotBundleId,
            attributeFetchSucceeded: true
        )
        var queryCount = 0
        controller.axEventHandler.windowInfoProvider = { _ in
            queryCount += 1
            return exactWindowInfo
        }

        XCTAssertNil(
            controller.resolveWindowServerInfoForDisposition(
                token: token,
                bundleId: ordinaryFacts.bundleId,
                axFacts: ordinaryFacts,
                preferredWindowInfo: nil
            )
        )
        XCTAssertEqual(queryCount, 0)
        XCTAssertNil(
            controller.resolveWindowServerInfoForDisposition(
                token: token,
                bundleId: helpTagFacts.bundleId,
                axFacts: helpTagFacts,
                preferredWindowInfo: nil
            )
        )
        XCTAssertEqual(queryCount, 0)
        XCTAssertEqual(
            controller.resolveWindowServerInfoForDisposition(
                token: token,
                bundleId: candidateFacts.bundleId,
                axFacts: candidateFacts,
                preferredWindowInfo: exactWindowInfo
            ),
            exactWindowInfo
        )
        XCTAssertEqual(queryCount, 0)
        XCTAssertEqual(
            controller.resolveWindowServerInfoForDisposition(
                token: token,
                bundleId: candidateFacts.bundleId,
                axFacts: candidateFacts,
                preferredWindowInfo: nil
            ),
            exactWindowInfo
        )
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(
            controller.resolveWindowServerInfoForDisposition(
                token: token,
                bundleId: WindowRuleEngine.cleanShotBundleId,
                axFacts: ordinaryFacts,
                preferredWindowInfo: nil
            ),
            exactWindowInfo
        )
        XCTAssertEqual(queryCount, 2)
    }

    @MainActor
    func testManualFloatUsesCurrentTiledSizeNotStaleFloatingFrame() throws {
        let controller = Self.controller()
        let ws = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let pid: pid_t = 943_001
        let windowId = 943_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: ws
        )
        _ = controller.niriEngine?.addWindow(token: token, to: ws, afterSelection: nil)

        let staleFrame = CGRect(x: 66, y: 32, width: 832, height: 640)
        controller.axManager.confirmFrameWrite(for: windowId, frame: staleFrame)
        XCTAssertTrue(controller.transitionWindowMode(for: token, to: .floating, applyFloatingFrame: false))
        XCTAssertTrue(controller.transitionWindowMode(for: token, to: .tiling, applyFloatingFrame: false))
        XCTAssertEqual(controller.workspaceManager.floatingState(for: token)?.restoreToFloating, true)

        let currentTiledFrame = CGRect(x: 300, y: 100, width: 1256, height: 1378)
        controller.axManager.confirmFrameWrite(for: windowId, frame: currentTiledFrame)

        XCTAssertTrue(controller.transitionWindowMode(for: token, to: .floating, applyFloatingFrame: false))

        let floatedSize = try XCTUnwrap(controller.workspaceManager.floatingState(for: token)?.lastFrame.size)
        XCTAssertEqual(
            floatedSize,
            currentTiledFrame.size,
            "manual float must keep the current tiled size, not replay the stale remembered floating size"
        )
        XCTAssertNotEqual(floatedSize, staleFrame.size)
    }

    @MainActor
    func testTilingToFloatingCancelsTransientNativeTitleBarDragOwnership() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(943_002), windowId: 943_102),
            pid: 943_002,
            windowId: 943_102,
            to: workspaceId
        )
        controller.mouseEventHandler.state.nativeTitleBarDrag = .init(token: token)
        controller.axManager.beginNativeTitleBarDrag(for: token)

        XCTAssertTrue(
            controller.transitionWindowMode(
                for: token,
                to: .floating,
                applyFloatingFrame: false,
                observedFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
                allowLiveFrameFallback: false
            )
        )

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, .floating)
        XCTAssertNil(controller.mouseEventHandler.state.nativeTitleBarDrag)
        XCTAssertFalse(controller.axManager.isNativeTitleBarDragActive(for: token))
    }

    @MainActor
    func testNiriFocusedRemovalPreferredRecoveryUsesLayoutRememberedToken() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let closingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_015), windowId: 765_115),
            pid: 765_015,
            windowId: 765_115,
            to: workspaceId
        )
        let selectedFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_016), windowId: 765_116),
            pid: 765_016,
            windowId: 765_116,
            to: workspaceId
        )
        let resolverFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_017), windowId: 765_117),
            pid: 765_017,
            windowId: 765_117,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: nil
        )
        let selectedFallbackNode = engine.addWindow(
            token: selectedFallbackToken,
            to: workspaceId,
            afterSelection: closingNode.id,
            focusedToken: closingToken
        )
        let resolverFallbackNode = engine.addWindow(
            token: resolverFallbackToken,
            to: workspaceId,
            afterSelection: selectedFallbackNode.id,
            focusedToken: closingToken
        )
        _ = controller.workspaceManager.setManagedFocus(
            closingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: nil,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.rememberFocus(resolverFallbackToken, in: workspaceId)

        controller.axEventHandler.handleRemoved(token: closingToken)
        await Self.waitForRemovalRefresh(controller, removedToken: closingToken)

        XCTAssertNil(controller.workspaceManager.entry(for: closingToken))
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            resolverFallbackNode.id
        )
        XCTAssertEqual(focusedTokens.last, resolverFallbackToken)
    }

    @MainActor
    func testNiriManagedReplacementProtectedRemovalResolvesFocusFallbackDuringValidation() async throws {
        var focusedTokens: [WindowToken] = []
        let controller = Self.controller(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusedTokens.append(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.omniwm.tests.tabs",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "tab",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 0, y: 0, width: 640, height: 420)
        )
        let closingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_018), windowId: 765_118),
            pid: 765_018,
            windowId: 765_118,
            to: workspaceId,
            managedReplacementMetadata: metadata
        )
        let selectedFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_019), windowId: 765_119),
            pid: 765_019,
            windowId: 765_119,
            to: workspaceId
        )
        let resolverFallbackToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_020), windowId: 765_120),
            pid: 765_020,
            windowId: 765_120,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let closingNode = engine.addWindow(
            token: closingToken,
            to: workspaceId,
            afterSelection: nil
        )
        let selectedFallbackNode = engine.addWindow(
            token: selectedFallbackToken,
            to: workspaceId,
            afterSelection: closingNode.id,
            focusedToken: closingToken
        )
        let resolverFallbackNode = engine.addWindow(
            token: resolverFallbackToken,
            to: workspaceId,
            afterSelection: selectedFallbackNode.id,
            focusedToken: closingToken
        )
        _ = controller.workspaceManager.setManagedFocus(
            closingToken,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: closingNode.id,
            focusedToken: nil,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.rememberFocus(resolverFallbackToken, in: workspaceId)

        controller.axEventHandler.handleRemoved(pid: closingToken.pid, winId: closingToken.windowId)
        await Self.waitForRemovalRefresh(controller, removedToken: closingToken)

        XCTAssertNil(controller.workspaceManager.entry(for: closingToken))
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            resolverFallbackNode.id
        )
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: workspaceId), resolverFallbackToken)
        XCTAssertEqual(focusedTokens.last, resolverFallbackToken)
    }

    private static func snapshot(
        focusedToken: WindowToken? = nil,
        pendingManagedFocus: PendingManagedFocusSnapshot = .empty,
        isNonManagedFocusActive: Bool = false,
        nonManagedFocusToken: WindowToken? = nil,
        systemModalFocusToken: WindowToken? = nil,
        interactionMonitorId: Monitor.ID? = nil,
        previousInteractionMonitorId: Monitor.ID? = nil,
        windows: [ReconcileWindowSnapshot] = [],
        viewports: [WorkspaceDescriptor.ID: ViewportState] = [:],
        layouts: [WorkspaceDescriptor.ID: LayoutTopology] = [:]
    ) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                focusedToken: focusedToken,
                pendingManagedFocus: pendingManagedFocus,
                focusLease: nil,
                isNonManagedFocusActive: isNonManagedFocusActive,
                nonManagedFocusToken: nonManagedFocusToken,
                systemModalFocusToken: systemModalFocusToken,
                interactionMonitorId: interactionMonitorId,
                previousInteractionMonitorId: previousInteractionMonitorId
            ),
            windows: windows,
            viewports: viewports,
            layouts: layouts
        )
    }

    private static func invariantCodes(
        focusedToken: WindowToken? = nil,
        pendingManagedFocus: PendingManagedFocusSnapshot = .empty,
        windows: [ReconcileWindowSnapshot] = []
    ) -> Set<String> {
        Set(
            InvariantChecks.validate(
                snapshot: snapshot(
                    focusedToken: focusedToken,
                    pendingManagedFocus: pendingManagedFocus,
                    windows: windows
                )
            ).map(\.code)
        )
    }

    private static func window(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        lifecyclePhase: WindowLifecyclePhase = .tiled
    ) -> ReconcileWindowSnapshot {
        ReconcileWindowSnapshot(
            token: token,
            workspaceId: workspaceId,
            mode: .tiling,
            lifecyclePhase: lifecyclePhase,
            observedState: .initial(workspaceId: workspaceId, monitorId: nil),
            desiredState: .initial(workspaceId: workspaceId, monitorId: nil, disposition: .tiling),
            restoreIntent: nil,
            interactionPolicy: .full
        )
    }

    private static func frameResult(
        for request: AXFrameApplicationRequest,
        failureReason: AXFrameWriteFailureReason? = nil
    ) -> AXFrameApplyResult {
        frameResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            expectedWindow: request.expectedWindow,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            components: request.components,
            failureReason: failureReason
        )
    }

    private static func frameResult(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents = .all,
        failureReason: AXFrameWriteFailureReason? = nil
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: failureReason == nil ? targetFrame : nil,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: failureReason,
                components: components
            )
        )
    }

    private static func layoutMonitorSnapshot(_ monitor: Monitor) -> LayoutMonitorSnapshot {
        LayoutMonitorSnapshot(
            monitorId: monitor.id,
            displayId: monitor.displayId,
            frame: monitor.frame,
            visibleFrame: monitor.visibleFrame,
            workingFrame: monitor.visibleFrame,
            fullscreenLayoutFrame: monitor.visibleFrame,
            scale: 1,
            orientation: monitor.autoOrientation
        )
    }

    private enum NiriRemovalFocusTarget {
        case closing
        case neighbor
    }

    @MainActor
    private static func assertScheduledNiriRemoval(
        _ controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        removedColumn: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let layoutState = controller.layoutRefreshController.layoutState
        let payloads = (layoutState.activeRefresh?.windowRemovalPayloads ?? [])
            + (layoutState.pendingRefresh?.windowRemovalPayloads ?? [])
        let payload = try XCTUnwrap(
            payloads.last { $0.workspaceId == workspaceId },
            file: file,
            line: line
        )
        XCTAssertNotNil(payload.removedNodeId, file: file, line: line)
        XCTAssertEqual(payload.removedNiriColumn, removedColumn, file: file, line: line)
    }

    @MainActor
    private static func assertNiriTrailingColumnRemovalCorrectsViewport(
        focusTarget: NiriRemovalFocusTarget,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let controller = Self.controller(file: file, line: line)
        let monitor = Monitor(
            id: .init(displayId: 98_800),
            displayId: 98_800,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Trailing Removal"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.motionPolicy.animationsEnabled = false
        controller.workspaceManager.setGaps(to: 8)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let tokens = Self.addNiriRuntimeWindows(
            count: 3,
            pidBase: 978_000,
            windowBase: 978_100,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine, file: file, line: line)
        Self.seedNiriEngineColumns(
            tokens: tokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: 700,
            tabbedColumnIndex: -1
        )

        let columns = engine.columns(in: workspaceId)
        let closingNode = try XCTUnwrap(
            engine.findNode(for: tokens[2], in: workspaceId),
            file: file,
            line: line
        )
        let neighborNode = try XCTUnwrap(
            engine.findNode(for: tokens[1], in: workspaceId),
            file: file,
            line: line
        )
        let selectedNode = focusTarget == .closing ? closingNode : neighborNode
        let selectedToken = focusTarget == .closing ? tokens[2] : tokens[1]
        let selectedColumnIndex = focusTarget == .closing ? 2 : 1
        let gap = CGFloat(controller.workspaceManager.gaps)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let totalSpan = state.totalSpan(
            containers: columns,
            gap: gap,
            sizeKeyPath: \.cachedWidth
        )
        let trailingOrigin = totalSpan - monitor.visibleFrame.width + gap
        let selectedColumnPosition = state.columnX(
            at: selectedColumnIndex,
            columns: columns,
            gap: gap
        )
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = selectedColumnIndex
        state.viewOffset = trailingOrigin - selectedColumnPosition
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        _ = controller.workspaceManager.setManagedFocus(
            selectedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedNode.id,
            focusedToken: selectedToken,
            in: workspaceId,
            onMonitor: monitor.id
        )

        controller.axEventHandler.handleRemoved(token: tokens[2])
        try Self.assertScheduledNiriRemoval(
            controller,
            workspaceId: workspaceId,
            removedColumn: true,
            file: file,
            line: line
        )
        await Self.waitForRemovalRefresh(controller, removedToken: tokens[2])

        let finalColumns = engine.columns(in: workspaceId)
        let finalState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let finalOrigin = finalState.viewPosPixels(columns: finalColumns, gap: gap)
        XCTAssertEqual(finalColumns.count, 2, file: file, line: line)
        XCTAssertNil(engine.findNode(for: tokens[2], in: workspaceId), file: file, line: line)
        XCTAssertEqual(finalState.selectedNodeId, neighborNode.id, file: file, line: line)
        XCTAssertEqual(finalOrigin, -gap, accuracy: 0.001, file: file, line: line)
        XCTAssertFalse(finalState.hasPendingOffsetAnimation, file: file, line: line)
        XCTAssertEqual(
            controller.workspaceManager.invariantViolationCountsDump(),
            "clean",
            file: file,
            line: line
        )
    }

    @MainActor
    private static func waitForRemovalRefresh(
        _ controller: WMController,
        removedToken: WindowToken
    ) async {
        for _ in 0 ..< 80 {
            if let refreshTask = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await refreshTask.value
                continue
            }
            if controller.workspaceManager.entry(for: removedToken) == nil,
               controller.layoutRefreshController.layoutState.pendingRefresh == nil
            {
                await Task.yield()
                if controller.layoutRefreshController.layoutState.activeRefreshTask == nil,
                   controller.layoutRefreshController.layoutState.pendingRefresh == nil
                {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum NiriTabLocalViewportPosition {
        case leftEdge
        case middle
        case rightEdge

        var targetColumnIndex: Int {
            switch self {
            case .leftEdge: 0
            case .middle: 2
            case .rightEdge: 4
            }
        }

        func viewOrigin(targetColumnX: CGFloat, columnWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
            switch self {
            case .leftEdge:
                targetColumnX
            case .middle:
                targetColumnX - (viewportWidth - columnWidth) / 2
            case .rightEdge:
                targetColumnX - (viewportWidth - columnWidth)
            }
        }
    }

    @MainActor
    private static func assertNiriTabLocalAddPreservesViewport(
        _ position: NiriTabLocalViewportPosition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let columnWidth: CGFloat = 320
        let controller = Self.controller(file: file, line: line)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        try Self.configureOrientation(
            .horizontal,
            for: workspaceId,
            controller: controller,
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true

        let existingTokens = Self.addNiriRuntimeWindows(
            count: 5,
            pidBase: 765_200,
            windowBase: 765_300,
            to: workspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine, file: file, line: line)
        Self.seedNiriEngineColumns(
            tokens: existingTokens,
            workspaceId: workspaceId,
            engine: engine,
            columnWidth: columnWidth,
            tabbedColumnIndex: position.targetColumnIndex
        )

        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId), file: file, line: line)
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let initialColumns = engine.columns(in: workspaceId)
        let targetColumn = initialColumns[position.targetColumnIndex]
        let selectedNode = try XCTUnwrap(targetColumn.windowNodes.first, file: file, line: line)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let targetColumnX = state.columnX(at: position.targetColumnIndex, columns: initialColumns, gap: gap)
        let viewOrigin = position.viewOrigin(
            targetColumnX: targetColumnX,
            columnWidth: columnWidth,
            viewportWidth: monitor.visibleFrame.width
        )
        state.selectedNodeId = selectedNode.id
        state.activeColumnIndex = position.targetColumnIndex
        state.viewOffset = viewOrigin - targetColumnX
        _ = controller.workspaceManager.applySessionPatch(
            WorkspaceSessionPatch(
                workspaceId: workspaceId,
                viewportState: state,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let newTabToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(765_205), windowId: 765_305),
            pid: 765_205,
            windowId: 765_305,
            to: workspaceId
        )
        var placements = Self.niriRestorePlacements(
            tokens: existingTokens,
            columnWidth: columnWidth,
            tabbedColumnIndex: position.targetColumnIndex,
            activeTabIndex: 1
        )
        placements[newTabToken] = Self.niriRestorePlacement(
            columnIndex: position.targetColumnIndex,
            tileIndex: 1,
            displayMode: .tabbed,
            activeTileIndex: 1,
            columnWidth: columnWidth
        )
        controller.workspaceManager.setNiriRestorePlacements(placements)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let plan = try XCTUnwrap(plans.first, file: file, line: line)
        let patchedState = try XCTUnwrap(plan.sessionPatch.viewportState, file: file, line: line)
        let finalColumns = engine.columns(in: workspaceId)
        let newTabNode = try XCTUnwrap(engine.findNode(for: newTabToken, in: workspaceId), file: file, line: line)
        let patchedViewOrigin = patchedState.viewPosPixels(columns: finalColumns, gap: gap)

        XCTAssertEqual(patchedViewOrigin, viewOrigin, accuracy: 0.001, file: file, line: line)
        XCTAssertFalse(patchedState.hasPendingOffsetAnimation, file: file, line: line)
        XCTAssertEqual(patchedState.selectedNodeId, newTabNode.id, file: file, line: line)
        XCTAssertEqual(
            finalColumns[position.targetColumnIndex].activeWindow?.token,
            newTabToken,
            file: file,
            line: line
        )
        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertFalse(plan.animationDirectives.containsStartNiriScroll(for: workspaceId), file: file, line: line)
        XCTAssertTrue(plan.animationDirectives.containsActivateWindow(newTabToken), file: file, line: line)
    }

    @MainActor
    private static func niriRefreshRateFixture(
        displayId: CGDirectDisplayID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        engine: NiriLayoutEngine
    ) {
        let controller = Self.controller(file: file, line: line)
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Refresh Rate Test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine, file: file, line: line)
        return (controller, workspaceId, monitor, engine)
    }

    @MainActor
    private static func addNiriRuntimeWindows(
        count: Int,
        pidBase: Int32,
        windowBase: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> [WindowToken] {
        (0 ..< count).map { index in
            let pid = pidBase + Int32(index)
            let windowId = windowBase + index
            return controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
        }
    }

    @MainActor
    func testMoveAtRightEdgeStaysOnSameMonitorWhenCrossDisabled() throws {
        let controller = Self.controller()
        let leftMonitor = Monitor(
            id: .init(displayId: 10_001), displayId: 10_001,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Left"
        )
        let rightMonitor = Monitor(
            id: .init(displayId: 10_002), displayId: 10_002,
            frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Right"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = false

        let engine = try XCTUnwrap(controller.niriEngine)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(823_001), windowId: 823_101),
            pid: 823_001, windowId: 823_101, to: leftWs
        )
        let node = engine.addWindow(token: token, to: leftWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: leftWs, onMonitor: leftMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: leftWs, onMonitor: leftMonitor.id, activateWorkspaceOnMonitor: true
        )

        controller.commandHandler.performCommand(.move(.right))

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), leftWs)
    }

    @MainActor
    func testMoveAtPrimaryEdgeReportsWorkspaceEdgeWhenCrossEnabled() throws {
        let controller = Self.controller()
        let wsId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true

        let engine = try XCTUnwrap(controller.niriEngine)
        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(821_001), windowId: 821_101),
            pid: 821_001, windowId: 821_101, to: wsId
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(821_002), windowId: 821_102),
            pid: 821_002, windowId: 821_102, to: wsId
        )
        let leftNode = engine.addWindow(token: leftToken, to: wsId, afterSelection: nil)
        let rightNode = engine.addWindow(
            token: rightToken, to: wsId, afterSelection: leftNode.id, focusedToken: leftToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: rightNode.id, focusedToken: rightToken, in: wsId,
            onMonitor: controller.workspaceManager.monitorId(for: wsId)
        )
        let forwardDirection: Direction = engine.monitorForWorkspace(wsId)?.orientation == .vertical
            ? .up
            : .right

        let outcome = controller.niriLayoutHandler.moveWindow(direction: forwardDirection)

        XCTAssertEqual(outcome, .atWorkspaceEdge)
        XCTAssertEqual(controller.workspaceManager.workspace(for: rightToken), wsId)
        XCTAssertEqual(engine.columns(in: wsId).count, 2)
    }

    @MainActor
    private static func horizontallyAdjacentUnequalMonitors() -> (left: Monitor, right: Monitor) {
        let left = Monitor(
            id: .init(displayId: 10_001), displayId: 10_001,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Left"
        )
        let right = Monitor(
            id: .init(displayId: 10_002), displayId: 10_002,
            frame: CGRect(x: 1200, y: 0, width: 1800, height: 800),
            visibleFrame: CGRect(x: 1200, y: 0, width: 1800, height: 800),
            hasNotch: false, name: "Right"
        )
        return (left, right)
    }

    @MainActor
    func testMoveCrossesToAdjacentMonitorAtRightEdgeWhenEnabled() throws {
        let controller = Self.controller()
        let (leftMonitor, rightMonitor) = Self.horizontallyAdjacentUnequalMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let rightWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true

        let engine = try XCTUnwrap(controller.niriEngine)
        let existingToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(822_900), windowId: 822_990),
            pid: 822_900, windowId: 822_990, to: rightWs
        )
        let existingNode = engine.addWindow(token: existingToken, to: rightWs, afterSelection: nil)
        let targetColumnWidth: CGFloat = 540
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: existingNode, in: rightWs))
        targetColumn.width = .fixed(targetColumnWidth)
        targetColumn.cachedWidth = targetColumnWidth
        targetColumn.hasManualSingleWindowWidthOverride = true
        existingNode.renderedFrame = rightMonitor.visibleFrame

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(822_001), windowId: 822_101),
            pid: 822_001, windowId: 822_101, to: leftWs
        )
        let node = engine.addWindow(token: token, to: leftWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: leftWs, onMonitor: leftMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: leftWs, onMonitor: leftMonitor.id, activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(controller.workspaceManager.focusedToken, token)

        controller.motionPolicy.animationsEnabled = false
        XCTAssertEqual(
            controller.commandHandler.performCommand(.setContainerPrimarySpan(.setProportion(50))),
            .executed
        )
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: node, in: leftWs))
        XCTAssertEqual(sourceColumn.width, .proportion(0.5))
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)

        XCTAssertEqual(controller.commandHandler.performCommand(.move(.right)), .executed)

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), rightWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: token, in: rightWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: rightWs))
        let existingColumn = try XCTUnwrap(engine.findColumn(containing: existingNode, in: rightWs))
        XCTAssertEqual(movedColumn.id, existingColumn.id)
        XCTAssertEqual(
            movedColumn.windowNodes.firstIndex(where: { $0.id == movedNode.id }),
            movedColumn.activeTileIdx
        )
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: rightWs).selectedNodeId, movedNode.id)
        XCTAssertEqual(controller.workspaceManager.interactionMonitorId, rightMonitor.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: rightWs), token)
        XCTAssertEqual(existingColumn.width, .fixed(targetColumnWidth))
        XCTAssertEqual(existingColumn.cachedWidth, targetColumnWidth, accuracy: 0.001)
        XCTAssertTrue(existingColumn.hasManualSingleWindowWidthOverride)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [rightWs])
        }
        XCTAssertFalse(plans.isEmpty)
        XCTAssertEqual(try XCTUnwrap(movedNode.renderedFrame?.width), targetColumnWidth, accuracy: 0.001)
    }

    @MainActor
    func testMoveCrossesIntoEmptyMonitorSelectsWindow() throws {
        let controller = Self.controller()
        let (leftMonitor, rightMonitor) = Self.horizontallyAdjacentUnequalMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let rightWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true

        let engine = try XCTUnwrap(controller.niriEngine)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(826_001), windowId: 826_101),
            pid: 826_001, windowId: 826_101, to: leftWs
        )
        let node = engine.addWindow(token: token, to: leftWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: leftWs, onMonitor: leftMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: leftWs, onMonitor: leftMonitor.id, activateWorkspaceOnMonitor: true
        )

        controller.motionPolicy.animationsEnabled = false
        XCTAssertEqual(
            controller.commandHandler.performCommand(.setContainerPrimarySpan(.setProportion(50))),
            .executed
        )
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: node, in: leftWs))
        XCTAssertEqual(sourceColumn.width, .proportion(0.5))
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)

        XCTAssertEqual(controller.commandHandler.performCommand(.move(.right)), .executed)

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), rightWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: token, in: rightWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: rightWs))
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: rightWs).selectedNodeId, movedNode.id)
        XCTAssertEqual(movedColumn.width, .proportion(0.5))
        XCTAssertTrue(movedColumn.hasManualSingleWindowWidthOverride)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [rightWs])
        }
        let targetWorkingFrame = controller.insetWorkingFrame(for: rightMonitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let expectedTargetWidth = (targetWorkingFrame.width - gap) * 0.5 - gap
        XCTAssertFalse(plans.isEmpty)
        XCTAssertEqual(try XCTUnwrap(movedNode.renderedFrame?.width), expectedTargetWidth, accuracy: 0.001)
    }

    @MainActor
    func testSummonRightAcrossNiriWorkspacesPreservesProportionalWidth() throws {
        let controller = Self.controller()
        let (leftMonitor, rightMonitor) = Self.horizontallyAdjacentUnequalMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let rightWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.motionPolicy.animationsEnabled = false

        let engine = try XCTUnwrap(controller.niriEngine)
        let sourceToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(827_001), windowId: 827_101),
            pid: 827_001, windowId: 827_101, to: leftWs
        )
        let sourceNode = engine.addWindow(token: sourceToken, to: leftWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: sourceNode.id, focusedToken: sourceToken, in: leftWs, onMonitor: leftMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            sourceToken, in: leftWs, onMonitor: leftMonitor.id, activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(
            controller.commandHandler.performCommand(.setContainerPrimarySpan(.setProportion(50))),
            .executed
        )
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: sourceNode, in: leftWs))
        XCTAssertEqual(sourceColumn.width, .proportion(0.5))
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)

        let anchorToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(827_002), windowId: 827_102),
            pid: 827_002, windowId: 827_102, to: rightWs
        )
        let anchorNode = engine.addWindow(token: anchorToken, to: rightWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: anchorNode.id, focusedToken: anchorToken, in: rightWs, onMonitor: rightMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            anchorToken, in: rightWs, onMonitor: rightMonitor.id, activateWorkspaceOnMonitor: true
        )

        XCTAssertTrue(
            controller.windowActionHandler.summonWindowRight(
                handle: WindowHandle(id: sourceToken),
                anchorToken: anchorToken,
                anchorWorkspaceId: rightWs
            )
        )

        XCTAssertEqual(controller.workspaceManager.workspace(for: sourceToken), rightWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: sourceToken, in: rightWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: rightWs))
        let anchorColumn = try XCTUnwrap(engine.findColumn(containing: anchorNode, in: rightWs))
        let columns = engine.columns(in: rightWs)
        XCTAssertNotEqual(movedColumn.id, anchorColumn.id)
        XCTAssertEqual(columns.firstIndex(where: { $0.id == movedColumn.id }), 1)
        XCTAssertEqual(movedColumn.width, .proportion(0.5))
        XCTAssertTrue(movedColumn.hasManualSingleWindowWidthOverride)

        let plans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [rightWs])
        }
        let targetWorkingFrame = controller.insetWorkingFrame(for: rightMonitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let expectedTargetWidth = (targetWorkingFrame.width - gap) * 0.5 - gap
        XCTAssertFalse(plans.isEmpty)
        XCTAssertEqual(try XCTUnwrap(movedNode.renderedFrame?.width), expectedTargetWidth, accuracy: 0.001)
    }

    @MainActor
    func testPostLayoutGateDroppedBySourceSeqButTargetOnlyGateSurvives() throws {
        let controller = Self.controller()
        let sourceWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let targetWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        let workspaceManager = controller.workspaceManager
        let plannedSeq = workspaceManager.worldSeq
        let domains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen]

        let bothGate = RefreshPostLayoutAction(
            workspaceSeqs: [sourceWs: plannedSeq, targetWs: plannedSeq],
            domains: domains,
            action: {}
        )
        let targetOnlyGate = RefreshPostLayoutAction(
            workspaceSeqs: [targetWs: plannedSeq],
            domains: domains,
            action: {}
        )
        XCTAssertTrue(bothGate.isCurrent(using: workspaceManager))
        XCTAssertTrue(targetOnlyGate.isCurrent(using: workspaceManager))

        workspaceManager.invalidateLayout(for: [sourceWs])

        XCTAssertFalse(bothGate.isCurrent(using: workspaceManager))
        XCTAssertTrue(targetOnlyGate.isCurrent(using: workspaceManager))
    }

    @MainActor
    private static func verticallyStackedMonitors() -> (lower: Monitor, upper: Monitor) {
        let lower = Monitor(
            id: .init(displayId: 10_001), displayId: 10_001,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Lower"
        )
        let upper = Monitor(
            id: .init(displayId: 10_002), displayId: 10_002,
            frame: CGRect(x: 0, y: 800, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 800, width: 1200, height: 800),
            hasNotch: false, name: "Upper"
        )
        return (lower, upper)
    }

    @MainActor
    func testMoveUpConsumesIntoXAlignedAnchorColumnAtVisualBottom() throws {
        let controller = Self.controller()
        let (lowerMonitor, upperMonitor) = Self.verticallyStackedMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([lowerMonitor, upperMonitor])
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws6 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true
        let engine = try XCTUnwrap(controller.niriEngine)

        let oneOnLower = controller.workspaceManager.monitor(for: ws1)?.id == lowerMonitor.id
        let sourceWs = oneOnLower ? ws1 : ws6
        let destWs = oneOnLower ? ws6 : ws1
        let sourceName = oneOnLower ? "1" : "6"
        XCTAssertEqual(controller.workspaceManager.monitor(for: sourceWs)?.id, lowerMonitor.id)
        XCTAssertEqual(controller.workspaceManager.monitor(for: destWs)?.id, upperMonitor.id)

        var destTokens: [WindowToken] = []
        for i in 0 ..< 3 {
            let pid = pid_t(841_001 + i)
            let windowId = 841_101 + i
            destTokens.append(controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: destWs
            ))
        }
        Self.seedNiriEngineColumns(
            tokens: destTokens, workspaceId: destWs, engine: engine, columnWidth: 360, tabbedColumnIndex: -1
        )
        let nodeA = try XCTUnwrap(engine.findNode(for: destTokens[0], in: destWs))
        let nodeB = try XCTUnwrap(engine.findNode(for: destTokens[1], in: destWs))
        let nodeC = try XCTUnwrap(engine.findNode(for: destTokens[2], in: destWs))

        _ = controller.workspaceManager.focusWorkspace(named: sourceName)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(841_900), windowId: 841_990),
            pid: 841_900, windowId: 841_990, to: sourceWs
        )
        let node = engine.addWindow(token: token, to: sourceWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: sourceWs, onMonitor: lowerMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: sourceWs, onMonitor: lowerMonitor.id, activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(controller.workspaceManager.focusedToken, token)

        nodeA.renderedFrame = CGRect(x: 20, y: 820, width: 360, height: 760)
        nodeB.renderedFrame = CGRect(x: 420, y: 820, width: 360, height: 760)
        nodeC.renderedFrame = CGRect(x: 820, y: 820, width: 360, height: 760)
        node.renderedFrame = CGRect(x: 420, y: 20, width: 360, height: 760)

        controller.motionPolicy.animationsEnabled = true
        controller.commandHandler.performCommand(.move(.up))

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), destWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: token, in: destWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: destWs))
        let anchorColumn = try XCTUnwrap(engine.findColumn(containing: nodeB, in: destWs))
        let nonAnchorA = try XCTUnwrap(engine.findColumn(containing: nodeA, in: destWs))
        XCTAssertEqual(movedColumn.id, anchorColumn.id)
        XCTAssertNotEqual(movedColumn.id, nonAnchorA.id)
        XCTAssertEqual(movedColumn.windowNodes.count, 2)
        XCTAssertEqual(movedColumn.windowNodes.firstIndex(where: { $0.id == movedNode.id }), 0)
        XCTAssertEqual(
            movedColumn.windowNodes.firstIndex(where: { $0.id == movedNode.id }),
            movedColumn.activeTileIdx
        )
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: destWs).selectedNodeId, movedNode.id)
        XCTAssertEqual(controller.workspaceManager.interactionMonitorId, upperMonitor.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: destWs), token)
        let mergedIdx = engine.columns(in: destWs).firstIndex { $0.id == movedColumn.id }
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: destWs).activeColumnIndex, mergedIdx)
        XCTAssertFalse(movedNode.hasMoveAnimationsRunning)
        XCTAssertEqual(movedNode.renderOffset(), .zero)
    }

    @MainActor
    func testMoveDownConsumesIntoXAlignedAnchorColumnAtVisualTop() throws {
        let controller = Self.controller()
        let (lowerMonitor, upperMonitor) = Self.verticallyStackedMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([lowerMonitor, upperMonitor])
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws6 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true
        let engine = try XCTUnwrap(controller.niriEngine)

        let oneOnUpper = controller.workspaceManager.monitor(for: ws1)?.id == upperMonitor.id
        let sourceWs = oneOnUpper ? ws1 : ws6
        let destWs = oneOnUpper ? ws6 : ws1
        let sourceName = oneOnUpper ? "1" : "6"
        XCTAssertEqual(controller.workspaceManager.monitor(for: sourceWs)?.id, upperMonitor.id)
        XCTAssertEqual(controller.workspaceManager.monitor(for: destWs)?.id, lowerMonitor.id)

        var destTokens: [WindowToken] = []
        for i in 0 ..< 3 {
            let pid = pid_t(842_001 + i)
            let windowId = 842_101 + i
            destTokens.append(controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: destWs
            ))
        }
        Self.seedNiriEngineColumns(
            tokens: destTokens, workspaceId: destWs, engine: engine, columnWidth: 360, tabbedColumnIndex: -1
        )
        let nodeA = try XCTUnwrap(engine.findNode(for: destTokens[0], in: destWs))
        let nodeB = try XCTUnwrap(engine.findNode(for: destTokens[1], in: destWs))
        let nodeC = try XCTUnwrap(engine.findNode(for: destTokens[2], in: destWs))

        _ = controller.workspaceManager.focusWorkspace(named: sourceName)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(842_900), windowId: 842_990),
            pid: 842_900, windowId: 842_990, to: sourceWs
        )
        let node = engine.addWindow(token: token, to: sourceWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: sourceWs, onMonitor: upperMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: sourceWs, onMonitor: upperMonitor.id, activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(controller.workspaceManager.focusedToken, token)

        nodeA.renderedFrame = CGRect(x: 20, y: 20, width: 360, height: 760)
        nodeB.renderedFrame = CGRect(x: 420, y: 20, width: 360, height: 760)
        nodeC.renderedFrame = CGRect(x: 820, y: 20, width: 360, height: 760)
        node.renderedFrame = CGRect(x: 420, y: 820, width: 360, height: 760)

        controller.motionPolicy.animationsEnabled = true
        controller.commandHandler.performCommand(.move(.down))

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), destWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: token, in: destWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: destWs))
        let anchorColumn = try XCTUnwrap(engine.findColumn(containing: nodeB, in: destWs))
        let nonAnchorC = try XCTUnwrap(engine.findColumn(containing: nodeC, in: destWs))
        XCTAssertEqual(movedColumn.id, anchorColumn.id)
        XCTAssertNotEqual(movedColumn.id, nonAnchorC.id)
        XCTAssertEqual(movedColumn.windowNodes.count, 2)
        XCTAssertEqual(
            movedColumn.windowNodes.firstIndex(where: { $0.id == movedNode.id }),
            movedColumn.windowNodes.count - 1
        )
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: destWs).selectedNodeId, movedNode.id)
        XCTAssertEqual(controller.workspaceManager.interactionMonitorId, lowerMonitor.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: destWs), token)
        XCTAssertFalse(movedNode.hasMoveAnimationsRunning)
        XCTAssertEqual(movedNode.renderOffset(), .zero)
    }

    @MainActor
    func testMoveCrossesRightToLeftConsumesIntoSpatialAnchorNotStripEnd() throws {
        let controller = Self.controller()
        let leftMonitor = Monitor(
            id: .init(displayId: 10_001), displayId: 10_001,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Left"
        )
        let rightMonitor = Monitor(
            id: .init(displayId: 10_002), displayId: 10_002,
            frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
            hasNotch: false, name: "Right"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        let leftWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let rightWs = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "6", createIfMissing: true))
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = true
        let engine = try XCTUnwrap(controller.niriEngine)

        var destTokens: [WindowToken] = []
        for i in 0 ..< 3 {
            let pid = pid_t(831_001 + i)
            let windowId = 831_101 + i
            destTokens.append(controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: leftWs
            ))
        }
        Self.seedNiriEngineColumns(
            tokens: destTokens, workspaceId: leftWs, engine: engine, columnWidth: 360, tabbedColumnIndex: -1
        )
        let nodeA = try XCTUnwrap(engine.findNode(for: destTokens[0], in: leftWs))
        let nodeB = try XCTUnwrap(engine.findNode(for: destTokens[1], in: leftWs))
        let nodeC = try XCTUnwrap(engine.findNode(for: destTokens[2], in: leftWs))

        _ = controller.workspaceManager.focusWorkspace(named: "6")
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(831_900), windowId: 831_990),
            pid: 831_900, windowId: 831_990, to: rightWs
        )
        let node = engine.addWindow(token: token, to: rightWs, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id, focusedToken: token, in: rightWs, onMonitor: rightMonitor.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token, in: rightWs, onMonitor: rightMonitor.id, activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(controller.workspaceManager.focusedToken, token)

        nodeA.renderedFrame = CGRect(x: 20, y: 20, width: 360, height: 760)
        nodeB.renderedFrame = CGRect(x: 420, y: 20, width: 360, height: 360)
        nodeC.renderedFrame = CGRect(x: 820, y: 420, width: 360, height: 360)
        node.renderedFrame = CGRect(x: 1220, y: 20, width: 360, height: 360)

        controller.motionPolicy.animationsEnabled = true
        controller.commandHandler.performCommand(.move(.left))

        XCTAssertEqual(controller.workspaceManager.workspace(for: token), leftWs)
        let movedNode = try XCTUnwrap(engine.findNode(for: token, in: leftWs))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: leftWs))
        let anchorColumn = try XCTUnwrap(engine.findColumn(containing: nodeB, in: leftWs))
        let stripEndColumn = try XCTUnwrap(engine.findColumn(containing: nodeC, in: leftWs))
        XCTAssertEqual(movedColumn.id, anchorColumn.id)
        XCTAssertNotEqual(movedColumn.id, stripEndColumn.id)
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: leftWs).selectedNodeId, movedNode.id)
        XCTAssertEqual(controller.workspaceManager.interactionMonitorId, leftMonitor.id)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: leftWs), token)

        let mergedIdx = engine.columns(in: leftWs).firstIndex { $0.id == movedColumn.id }
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: leftWs).activeColumnIndex, mergedIdx)
        XCTAssertNil(controller.workspaceManager.animationDriver.liveViewOffset(in: leftWs, semanticOffset: 0))
        XCTAssertFalse(movedNode.hasMoveAnimationsRunning)
        XCTAssertEqual(movedNode.renderOffset(), .zero)
    }

    @MainActor
    func testMovePreservesWrapAtInfiniteLoopEdgeWhenCrossDisabled() throws {
        let controller = Self.controller()
        let wsId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.settings.moveCrossesMonitorAtEdge = false

        let engine = try XCTUnwrap(controller.niriEngine)
        engine.isMutationSanctioned = true
        engine.updateConfiguration(infiniteLoop: true)
        let monitorId = try XCTUnwrap(controller.workspaceManager.monitorId(for: wsId))
        engine.updateMonitorSettings(engine.globalResolvedSettings(), for: monitorId)

        let leftToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(824_001), windowId: 824_101),
            pid: 824_001, windowId: 824_101, to: wsId
        )
        let rightToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(824_002), windowId: 824_102),
            pid: 824_002, windowId: 824_102, to: wsId
        )
        let leftNode = engine.addWindow(token: leftToken, to: wsId, afterSelection: nil)
        let rightNode = engine.addWindow(
            token: rightToken, to: wsId, afterSelection: leftNode.id, focusedToken: leftToken
        )
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: rightNode.id, focusedToken: rightToken, in: wsId,
            onMonitor: controller.workspaceManager.monitorId(for: wsId)
        )
        let forwardDirection: Direction = engine.monitorForWorkspace(wsId)?.orientation == .vertical
            ? .up
            : .right

        let outcome = controller.niriLayoutHandler.moveWindow(direction: forwardDirection)

        XCTAssertEqual(outcome, .movedWithinWorkspace)
        XCTAssertEqual(controller.workspaceManager.workspace(for: rightToken), wsId)
    }

    @MainActor
    private static func seedNiriEngineColumns(
        tokens: [WindowToken],
        workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        columnWidth: CGFloat,
        tabbedColumnIndex: Int
    ) {
        let wasSanctioned = engine.isMutationSanctioned
        engine.isMutationSanctioned = true
        defer { engine.isMutationSanctioned = wasSanctioned }

        var previousNode: NiriWindow?
        for token in tokens {
            previousNode = engine.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: previousNode?.id,
                focusedToken: previousNode?.token
            )
        }

        let columns = engine.columns(in: workspaceId)
        for (index, column) in columns.enumerated() {
            column.width = .fixed(columnWidth)
            column.cachedWidth = columnWidth
            column.displayMode = index == tabbedColumnIndex ? .tabbed : .normal
            column.setActiveTileIdx(0)
            engine.updateTabbedColumnVisibility(column: column)
        }
    }

    private static func niriRestorePlacements(
        tokens: [WindowToken],
        columnWidth: CGFloat,
        tabbedColumnIndex: Int,
        activeTabIndex: Int
    ) -> [WindowToken: PersistedNiriPlacement] {
        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let isTabbedColumn = index == tabbedColumnIndex
            placements[token] = niriRestorePlacement(
                columnIndex: index,
                tileIndex: 0,
                displayMode: isTabbedColumn ? .tabbed : .normal,
                activeTileIndex: isTabbedColumn ? activeTabIndex : 0,
                columnWidth: columnWidth
            )
        }
        return placements
    }

    private static func niriRestorePlacement(
        columnIndex: Int,
        tileIndex: Int,
        displayMode: ColumnDisplay,
        activeTileIndex: Int,
        columnWidth: CGFloat
    ) -> PersistedNiriPlacement {
        PersistedNiriPlacement(
            columnIndex: columnIndex,
            tileIndex: tileIndex,
            column: PersistedNiriColumnState(
                displayMode: displayMode,
                activeTileIndex: activeTileIndex,
                width: .fixed(columnWidth),
                presetWidthIndex: nil,
                isFullWidth: false,
                savedWidth: nil,
                hasManualSingleWindowWidthOverride: false
            ),
            window: PersistedNiriWindowState(
                sizingMode: .normal,
                height: .auto(weight: 1),
                savedHeight: nil,
                windowWidth: .auto(weight: 1)
            )
        )
    }

    @MainActor
    private static func rekeyStructuralManagedReplacementIfNeeded(
        _ handler: AXEventHandler,
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard let match = handler.structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        ) else {
            return false
        }
        return handler.rekeyStructuralManagedReplacement(
            match: match,
            token: token,
            windowId: windowId,
            axRef: axRef,
            bundleId: bundleId,
            mode: mode,
            facts: facts
        )
    }

    private static func managedReplacementMetadata(
        workspaceId: WorkspaceDescriptor.ID,
        pid: pid_t,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: nativeTabBundleId(pid: pid),
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "native-tab",
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
    }

    private static func nativeTabBundleId(pid: pid_t) -> String {
        "com.omniwm.tests.native-tabs.\(pid)"
    }

    private static func nativeTabFacts(
        pid: pid_t,
        windowId: Int,
        frame: CGRect
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Native Tabs",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "native-tab",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: nativeTabBundleId(pid: pid),
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: visibleWindowInfo(pid: pid, windowId: windowId, frame: frame)
        )
    }

    private static func visibleWindowInfo(
        pid: pid_t,
        windowId: Int,
        frame: CGRect
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(windowId),
            pid: pid,
            level: 0,
            frame: frame,
            tags: 1,
            attributes: 2,
            parentId: 0,
            title: nil
        )
    }

    private static func assertFrame(
        _ actual: CGRect,
        equals expected: CGRect,
        accuracy: CGFloat = 0.000001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    @MainActor
    private static func workspaceManager(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WorkspaceManager {
        WorkspaceManager(settings: settingsStore(file: file, line: line))
    }

    @MainActor
    private static func controller(
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> WMController {
        WMController(
            settings: settingsStore(file: file, line: line),
            windowFocusOperations: windowFocusOperations
        )
    }

    @MainActor
    private static func configureOrientation(
        _ orientation: Monitor.Orientation,
        for workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let monitor = try XCTUnwrap(
            controller.workspaceManager.monitor(for: workspaceId),
            file: file,
            line: line
        )
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                orientation: orientation
            ),
            for: monitor
        )
    }

    @MainActor
    private static func inactiveWorkspaceFocusFixture(
        policy: WindowInteractionPolicy,
        pid: pid_t,
        windowId: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (
        controller: WMController,
        token: WindowToken,
        facts: ActivationFacts,
        monitorId: Monitor.ID,
        activeWorkspaceId: WorkspaceDescriptor.ID,
        surfaceWorkspaceId: WorkspaceDescriptor.ID
    ) {
        let controller = Self.controller(file: file, line: line)
        let surfaceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true),
            file: file,
            line: line
        )
        let activeWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: surfaceWorkspaceId
        )
        controller.workspaceManager.setInteractionPolicy(policy, for: token)
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.hasStartedServices = true

        let monitorId = try XCTUnwrap(
            controller.workspaceManager.monitor(for: surfaceWorkspaceId)?.id,
            file: file,
            line: line
        )
        XCTAssertEqual(
            controller.workspaceManager.activeWorkspace(on: monitorId)?.id,
            activeWorkspaceId,
            file: file,
            line: line
        )

        let facts = ActivationFacts(
            pid: pid,
            source: .focusedWindowChanged,
            origin: .external,
            observationGeneration: 0,
            requestedAtSeq: 0,
            focusedWindow: FocusedWindowFact(
                axRef: axRef,
                isFullscreen: false,
                isSystemModalSurface: false
            )
        )
        return (controller, token, facts, monitorId, activeWorkspaceId, surfaceWorkspaceId)
    }

    @MainActor
    private static func managedNiriActivationFixture(
        origin: ManagedFocusOrigin,
        pid: pid_t,
        windowId: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (controller: WMController, entry: WindowState, requestId: UInt64) {
        let controller = Self.controller(file: file, line: line)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.setMoveMouseToFocusedWindow(true)

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId), file: file, line: line)
        let node = try XCTUnwrap(
            controller.niriEngine?.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: nil
            ),
            file: file,
            line: line
        )
        let targetFrame = CGRect(
            x: monitor.visibleFrame.midX - 100,
            y: monitor.visibleFrame.midY - 75,
            width: 200,
            height: 150
        )
        node.frame = targetFrame
        node.renderedFrame = targetFrame

        let request = controller.intentLedger.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: origin
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token), file: file, line: line)
        return (controller, entry, request.requestId)
    }

    @MainActor
    private static func confirmManagedNiriFocus(
        controller: WMController,
        entry: WindowState,
        requestId: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: entry.workspaceId,
                onMonitor: controller.workspaceManager.monitorId(for: entry.workspaceId),
                activateWorkspaceOnMonitor: false,
                requestId: requestId
            ),
            file: file,
            line: line
        )
        XCTAssertNotNil(
            controller.intentLedger.confirmManagedRequest(
                token: entry.token,
                source: .focusedWindowChanged
            ),
            file: file,
            line: line
        )
    }

    @MainActor
    private static func settleNiriAnimation(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId), file: file, line: line)
        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(workspaceId, on: monitor.displayId),
            file: file,
            line: line
        )
        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 0, displayId: monitor.displayId)
    }

    @MainActor
    private static func settingsStore(
        file _: StaticString = #filePath,
        line _: UInt = #line
    ) -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
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
        return settings
    }
}

private extension Array where Element == AnimationDirective {
    func containsStartNiriScroll(for workspaceId: WorkspaceDescriptor.ID) -> Bool {
        contains { directive in
            if case .startNiriScroll(let directiveWorkspaceId) = directive {
                return directiveWorkspaceId == workspaceId
            }
            return false
        }
    }

    func containsActivateWindow(_ token: WindowToken) -> Bool {
        contains { directive in
            if case .activateWindow(let directiveToken) = directive {
                return directiveToken == token
            }
            return false
        }
    }
}
