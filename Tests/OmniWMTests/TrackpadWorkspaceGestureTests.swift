// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadWorkspaceGestureTests: XCTestCase {
    private final class GestureLivenessClock {
        var time: TimeInterval

        init(time: TimeInterval) {
            self.time = time
        }
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let ws1: WorkspaceDescriptor.ID
        let ws2: WorkspaceDescriptor.ID
        let ws3: WorkspaceDescriptor.ID
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadWorkspaceGestureTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFixture(
        workspaceSwipeEnabled: Bool = true,
        workspaceFingers: GestureFingerCount = .three,
        workspaceAxis: WorkspaceSwipeAxis = .vertical,
        scrollGestureEnabled: Bool = false,
        columnFingers: GestureFingerCount = .three,
        enableNiri: Bool = true,
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) throws -> Fixture {
        let controller = WMController(
            settings: makeSettings(),
            windowFocusOperations: windowFocusOperations
        )
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.settings.scrollGestureEnabled = scrollGestureEnabled
        controller.settings.gestureFingerCount = columnFingers
        controller.settings.workspaceSwipeEnabled = workspaceSwipeEnabled
        controller.settings.workspaceSwipeFingerCount = workspaceFingers
        controller.settings.workspaceSwipeAxis = workspaceAxis
        if enableNiri {
            controller.enableNiriLayout()
        }
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        let ws3 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "3", createIfMissing: true))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(ws1, on: monitor.id))
        return Fixture(controller: controller, monitor: monitor, ws1: ws1, ws2: ws2, ws3: ws3)
    }

    private func activeWorkspace(_ fixture: Fixture) -> WorkspaceDescriptor.ID? {
        fixture.controller.workspaceManager.activeWorkspaceOrFirst(on: fixture.monitor.id)?.id
    }

    private func addManagedWindow(
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        pid: pid_t,
        windowId: Int
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func addColumnGestureWindows(to fixture: Fixture) throws {
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(7_001 + index),
                windowId: 7_101 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }
    }

    private func beginCommittedColumnGesture(
        _ fixture: Fixture,
        location: CGPoint = CGPoint(x: 800, y: 450)
    ) -> TimeInterval {
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.8, y: 0.5, at: time, location: location)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: 3,
                x: 0.8 - 0.03 * CGFloat(step),
                y: 0.5,
                at: time,
                location: location
            )
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        for _ in 0 ..< 20 {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: 3,
                x: 0.68,
                y: 0.5,
                at: time,
                location: location
            )
        }
        return time
    }

    private func configureSecondMonitor(
        _ fixture: Fixture,
        workspaceNames: Set<String> = ["6", "7"]
    ) throws -> (monitor: Monitor, workspaceIds: [WorkspaceDescriptor.ID]) {
        let monitor = Monitor(
            id: .init(displayId: 2),
            displayId: 2,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "TestB"
        )
        let controller = fixture.controller
        controller.settings.workspaceConfigurations = controller.settings.workspaceConfigurations.map { configuration in
            var configuration = configuration
            configuration.monitorAssignment = workspaceNames.contains(configuration.name)
                ? .specificDisplay(OutputId(from: monitor))
                : .specificDisplay(OutputId(from: fixture.monitor))
            return configuration
        }
        controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, monitor])
        controller.workspaceManager.applySettings()
        let workspaceIds = try workspaceNames.sorted().map { name in
            try XCTUnwrap(controller.workspaceManager.workspaceId(for: name, createIfMissing: true))
        }
        return (monitor, workspaceIds)
    }

    private func withBlockedLayoutRefreshes<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = fixture.controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [fixture.ws1]
        )
        defer {
            blocker.cancel()
            refreshController.layoutState.activeRefreshTask = nil
            refreshController.layoutState.activeRefresh = nil
            refreshController.layoutState.pendingRefresh = nil
        }
        return try body()
    }

    private func touches(_ count: Int, x: CGFloat, y: CGFloat) -> [MouseEventHandler.GestureTouchSample] {
        (0 ..< count).map { _ in
            MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: CGPoint(x: x, y: y))
        }
    }

    private func sendFrame(
        _ fixture: Fixture,
        phase: NSEvent.Phase,
        fingers: Int,
        x: CGFloat,
        y: CGFloat,
        at timestamp: TimeInterval,
        location: CGPoint = CGPoint(x: 800, y: 450)
    ) {
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: timestamp,
            touches: phase == .ended || phase == .cancelled ? [] : touches(fingers, x: x, y: y)
        )
        fixture.controller.mouseEventHandler.receiveTapGestureEvent(snapshot)
    }

    private func performVerticalSwipe(
        _ fixture: Fixture,
        fingers: Int = 3,
        from startY: CGFloat = 0.2,
        totalUnits: CGFloat,
        startTime: TimeInterval,
        endPhase: NSEvent.Phase = .ended,
        location: CGPoint = CGPoint(x: 800, y: 450)
    ) -> TimeInterval {
        let steps = 8
        let stepNormalized = totalUnits / 500.0 / CGFloat(steps)
        var time = startTime
        sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: startY, at: time, location: location)
        for step in 1 ... steps {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: fingers,
                x: 0.5,
                y: startY + stepNormalized * CGFloat(step),
                at: time,
                location: location
            )
        }
        time += 0.01
        sendFrame(fixture, phase: endPhase, fingers: 0, x: 0, y: 0, at: time, location: location)
        return time
    }

    func testVerticalSwipeSwitchesToNextWorkspaceExactlyOnce() throws {
        let fixture = try makeFixture()
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testVerticalSwipeDownSwitchesToPreviousWithWrapAround() throws {
        let fixture = try makeFixture()
        let lastWorkspace = fixture.controller.workspaceManager.workspaces(on: fixture.monitor.id).last?.id
        XCTAssertNotEqual(lastWorkspace, fixture.ws1)
        _ = performVerticalSwipe(fixture, totalUnits: -220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), lastWorkspace)
    }

    func testInvertedDirectionFlipsVerticalMapping() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.gestureInvertDirection = false
        let lastWorkspace = fixture.controller.workspaceManager.workspaces(on: fixture.monitor.id).last?.id
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), lastWorkspace)
    }

    func testSlowDragBelowDistanceThresholdDoesNotSwitch() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 5 {
            time += 0.02
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.024 * CGFloat(step), at: time)
        }
        for _ in 0 ..< 10 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.32, at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testFastFlickBelowDistanceThresholdSwitchesOnRelease() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.04 * CGFloat(step), at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testCommitCrossingFrameContributesExactlyOneVelocitySample() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.02
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.03 * CGFloat(step), at: time)
        }
        time += 0.02
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testCancelledGestureNeverFires() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.04 * CGFloat(step), at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .cancelled, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testTerminalFrameClearsLatchesWhenPreconditionsFail() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .committed)

        fixture.controller.isEnabled = false
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)

        let handler = fixture.controller.mouseEventHandler
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        fixture.controller.isEnabled = true
        time += 0.01
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
    }

    func testClaimedSessionConsumesScrollAfterEligibilityChanges() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)

        fixture.controller.isEnabled = false
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        let handler = fixture.controller.mouseEventHandler
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
    }

    func testClaimedSessionConsumesPhaseLessScrollEvents() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler

        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testCompletedWorkspaceSwipeConsumesPhaseLessScrollTail() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)

        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testRapidSuccessiveSwipesRejectStaleFocusHandoff() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        let ws2Token = addManagedWindow(
            to: fixture.ws2,
            controller: fixture.controller,
            pid: 7_002,
            windowId: 7_102
        )
        let ws3Token = addManagedWindow(
            to: fixture.ws3,
            controller: fixture.controller,
            pid: 7_003,
            windowId: 7_103
        )
        XCTAssertTrue(manager.rememberFocus(ws2Token, in: fixture.ws2))
        XCTAssertTrue(manager.rememberFocus(ws3Token, in: fixture.ws3))

        try withBlockedLayoutRefreshes(fixture) {
            let firstEnd = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
            _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: firstEnd + 0.05)

            let actions = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            )
            XCTAssertEqual(actions.count, 2)
            XCTAssertFalse(actions[0].isCurrent(using: manager))
            XCTAssertTrue(actions[1].isCurrent(using: manager))
            for action in actions {
                action.runIfCurrent(using: manager)
            }

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws3)
            XCTAssertEqual(focusedWindowIds, [UInt32(ws3Token.windowId)])
        }
    }

    func testEmptyWorkspaceTargetClearsManagedFocusAfterLayout() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        XCTAssertFalse(manager.nativeFocusOwner.isExternal)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
            let action = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
            )
            XCTAssertTrue(action.isCurrent(using: manager))
            action.runIfCurrent(using: manager)

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
            XCTAssertEqual(manager.nativeFocusOwner, .none)
            XCTAssertNil(manager.pendingFocusedToken)
        }
    }

    func testEmptyWorkspaceTargetClearsManagedFocusWhenLayoutIsInvalidated() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let token = addManagedWindow(to: fixture.ws1, controller: fixture.controller, pid: 7_010, windowId: 7_110)
        XCTAssertTrue(manager.confirmManagedFocus(token, in: fixture.ws1, activateWorkspaceOnMonitor: false))
        XCTAssertEqual(manager.nativeFocusOwner, .managed(token))

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
            manager.invalidateLayout(for: [fixture.ws2])
            let action = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
            )
            XCTAssertFalse(action.isCurrent(using: manager))
            action.runIfCurrent(using: manager)

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
            XCTAssertEqual(manager.nativeFocusOwner, .none)
            XCTAssertNil(manager.pendingFocusedToken)
        }
    }

    func testRapidSwipeThroughEmptyWorkspaceRejectsStaleClear() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        let ws1Token = addManagedWindow(to: fixture.ws1, controller: fixture.controller, pid: 7_011, windowId: 7_111)
        let ws3Token = addManagedWindow(to: fixture.ws3, controller: fixture.controller, pid: 7_013, windowId: 7_113)
        XCTAssertTrue(manager.confirmManagedFocus(ws1Token, in: fixture.ws1, activateWorkspaceOnMonitor: false))
        XCTAssertTrue(manager.rememberFocus(ws3Token, in: fixture.ws3))

        try withBlockedLayoutRefreshes(fixture) {
            let firstEnd = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
            _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: firstEnd + 0.05)

            let actions = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            )
            XCTAssertEqual(actions.count, 2)
            XCTAssertFalse(actions[0].isCurrent(using: manager))
            XCTAssertTrue(actions[1].isCurrent(using: manager))
            for action in actions {
                action.runIfCurrent(using: manager)
            }

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws3)
            XCTAssertEqual(focusedWindowIds, [UInt32(ws3Token.windowId)])
            XCTAssertEqual(manager.pendingFocusedToken, ws3Token)
            XCTAssertEqual(manager.nativeFocusOwner, .managed(ws1Token))
        }
    }

    func testSharedCountHorizontalSwipeRoutesToColumnScroll() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.2 + 0.02 * CGFloat(step), y: 0.5, at: time)
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testSharedCountHorizontalSwipeAppliesAndFinalizesNiriViewport() throws {
        var finalOffsets: [TrackpadScrollStyle: CGFloat] = [:]
        var finalIndexes: [TrackpadScrollStyle: Int] = [:]
        var momentumViewportScale: CGFloat?

        for style in TrackpadScrollStyle.allCases {
            var focusedWindowIds: [UInt32] = []
            let fixture = try makeFixture(
                scrollGestureEnabled: true,
                windowFocusOperations: WindowFocusOperations(
                    activateApp: { _ in },
                    focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                    raiseWindow: { _ in }
                )
            )
            fixture.controller.settings.trackpadScrollStyle = style
            try addColumnGestureWindows(to: fixture)
            let manager = fixture.controller.workspaceManager
            let driver = manager.animationDriver
            let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
            if style == .momentum {
                let geometry = fixture.controller.niriInteractionGeometry(for: fixture.monitor, scale: 2)
                momentumViewportScale = geometry.workingFrame.width / fixture.monitor.visibleFrame.width
            }

            var time = beginCommittedColumnGesture(fixture)

            XCTAssertTrue(driver.trackpadGestureActive(in: fixture.ws1))
            XCTAssertNotEqual(
                driver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset),
                semanticOffset
            )

            time += 0.01
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
            XCTAssertFalse(driver.hasGesture(in: fixture.ws1))
            XCTAssertTrue(driver.hasMotion(in: fixture.ws1))
            XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
            let finalState = manager.niriViewportState(for: fixture.ws1)
            finalOffsets[style] = finalState.viewOffset
            finalIndexes[style] = finalState.activeColumnIndex
            XCTAssertEqual(focusedWindowIds, [UInt32(7_101 + finalState.activeColumnIndex)])
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        }

        let snapOffset = try XCTUnwrap(finalOffsets[.snap])
        let momentumOffset = try XCTUnwrap(finalOffsets[.momentum])
        XCTAssertEqual(finalIndexes[.snap], 2)
        XCTAssertEqual(finalIndexes[.momentum], 0)
        XCTAssertLessThan(snapOffset, 0)
        XCTAssertEqual(momentumOffset, 300 * (try XCTUnwrap(momentumViewportScale)), accuracy: 0.001)
        XCTAssertNotEqual(snapOffset, momentumOffset)
    }

    func testCancelledColumnGestureDoesNotFocusLandingWindow() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        try addColumnGestureWindows(to: fixture)
        var time = beginCommittedColumnGesture(fixture)

        time += 0.01
        sendFrame(fixture, phase: .cancelled, fingers: 0, x: 0, y: 0, at: time)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testDisabledColumnGestureAbortDoesNotFocusLandingWindow() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        try addColumnGestureWindows(to: fixture)
        var time = beginCommittedColumnGesture(fixture)

        fixture.controller.isEnabled = false
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testLostColumnGestureCommitsOffsetAndReleasesInputSession() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let driver = manager.animationDriver
        let livenessClock = GestureLivenessClock(time: 1)
        driver.gestureLivenessNow = { livenessClock.time }

        _ = beginCommittedColumnGesture(fixture)

        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        let expectedOffset = try XCTUnwrap(
            driver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId],
            fixture.ws1
        )
        focusOperationCount = 0
        livenessClock.time = 2

        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: 2,
            displayId: fixture.monitor.displayId
        )

        XCTAssertEqual(
            manager.niriViewportState(for: fixture.ws1).viewOffset,
            expectedOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(
            scrollVerdict(
                fixture,
                momentumPhase: 0,
                phase: CGScrollPhase.changed.rawValue
            )
        )
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertFalse(driver.hasMotion(in: fixture.ws1))
        XCTAssertNil(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId]
        )
        XCTAssertNil(
            fixture.controller.layoutRefreshController.layoutState.displayLinksByDisplay[fixture.monitor.displayId]
        )
    }

    func testDisplayLinkCreationFailureSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = nil
        fixture.controller.layoutRefreshController.displayLinkCreationAllowedForTests = { _ in false }
        focusOperationCount = 0

        sendFrame(fixture, phase: .began, fingers: 3, x: 0.8, y: 0.5, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.74, y: 0.5, at: 100.01)

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertNotEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, semanticOffset)
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)

        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.7, y: 0.5, at: 100.02)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.03)
    }

    func testInactiveWorkspaceAbortSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        _ = beginCommittedColumnGesture(fixture)
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0

        fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.ws1).viewOffset,
            expectedOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testMonitorLossSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0

        fixture.controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: fixture.monitor.displayId,
            migrateAnimations: false
        )

        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testResetSettlesGestureWithoutStartingPostResetRefresh() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0
        fixture.controller.hasStartedServices = false

        fixture.controller.layoutRefreshController.resetState()

        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testWorkspaceMonitorMoveSettlesGestureBeforeStateMutation() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        let target = try configureSecondMonitor(fixture)
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )

        let outcome = fixture.controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
            fixture.ws1,
            direction: .right,
            force: true
        )

        XCTAssertNotNil(outcome)
        XCTAssertEqual(manager.monitorForWorkspace(fixture.ws1)?.id, target.monitor.id)
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testRuntimeMonitorOverrideClearSettlesGestureBeforeMotionRemoval() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        let target = try configureSecondMonitor(fixture)
        try addColumnGestureWindows(to: fixture)
        XCTAssertNotNil(fixture.controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
            fixture.ws1,
            direction: .right,
            force: true
        ))
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(
            fixture,
            location: CGPoint(x: target.monitor.frame.midX, y: target.monitor.frame.midY)
        )
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )

        fixture.controller.updateWorkspaceConfig()

        XCTAssertEqual(manager.monitorForWorkspace(fixture.ws1)?.id, fixture.monitor.id)
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testViewportForgetSettlesGestureBeforeRemovingViewportState() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        manager.updateNiriViewportState(ViewportState(), for: fixture.ws1)
        _ = beginCommittedColumnGesture(fixture)

        XCTAssertNotNil(manager.reconcileSnapshot().viewports[fixture.ws1])

        manager.recordReconcileEvent(
            .viewportForgotten(workspaceIds: [fixture.ws1], source: .workspaceManager)
        )

        XCTAssertNil(manager.reconcileSnapshot().viewports[fixture.ws1])
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testExpiredGestureDoesNotReleaseNewerOrDifferentSession() throws {
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true
        )
        try addColumnGestureWindows(to: fixture)
        _ = beginCommittedColumnGesture(fixture)
        let handler = fixture.controller.mouseEventHandler
        let driver = fixture.controller.workspaceManager.animationDriver
        let expiredSessionID = try XCTUnwrap(driver.gestureSessionID(in: fixture.ws1))
        let newerSessionID = try XCTUnwrap(
            driver.beginGesture(in: fixture.ws1, isTrackpad: true, timestamp: 101)
        )
        handler.applyTrackpadViewportScrollDelta(
            1,
            engine: try XCTUnwrap(fixture.controller.niriEngine),
            wsId: fixture.ws1,
            monitor: fixture.monitor,
            orientation: .horizontal,
            timestamp: 101
        )
        XCTAssertNotEqual(expiredSessionID, newerSessionID)

        handler.handleExpiredViewportGesture(
            in: fixture.ws2,
            sessionID: newerSessionID
        )
        XCTAssertFalse(handler.terminateViewportGesture(
            in: fixture.ws1,
            sessionID: expiredSessionID,
            disposition: .settleLiveOffset
        ))

        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertEqual(handler.state.viewportGestureSessionID, newerSessionID)
        XCTAssertTrue(driver.hasGesture(in: fixture.ws1))
        fixture.controller.niriLayoutHandler.cancelActiveAnimations(for: fixture.ws1)
        handler.handleAppVisibilityChanged()
    }

    func testWorkspaceOnlyNiriGestureDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture()
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testDwindleWorkspaceGestureDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true, enableNiri: false)
        fixture.controller.settings.workspaceConfigurations = fixture.controller.settings.workspaceConfigurations.map {
            $0.with(layoutType: .dwindle)
        }
        fixture.controller.enableDwindleLayout()
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testDistinctWorkspaceFingerCountDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture(
            workspaceFingers: .four,
            scrollGestureEnabled: true,
            columnFingers: .three
        )
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testWorkspaceSwipeSeparatesSessionFromViewportPredicate() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        for step in 1 ... 6 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.06 * CGFloat(step), at: time)
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testOffAxisRejectionLatchesUntilFullLift() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.26, y: 0.5, at: time)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertTrue(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.26, y: 0.5 + 0.08 * CGFloat(step), at: time)
        }
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: time + 0.05)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    private func driveCommittedPartialLift(_ fixture: Fixture) -> TimeInterval {
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        for _ in 0 ..< 12 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        }
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 2, x: 0.5, y: 0.24, at: time)
        return time
    }

    private func scrollVerdict(
        _ fixture: Fixture,
        momentumPhase: UInt32,
        phase: UInt32
    ) -> Bool {
        fixture.controller.mouseEventHandler.receiveTapScrollWheel(
            at: CGPoint(x: 800, y: 450),
            deltaX: 0,
            deltaY: 8,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: []
        )
    }

    func testCommittedPartialLiftLatchesAndBlocksChainedGesture() throws {
        let fixture = try makeFixture(
            workspaceFingers: .three,
            scrollGestureEnabled: true,
            columnFingers: .two
        )
        var time = driveCommittedPartialLift(fixture)

        let handler = fixture.controller.mouseEventHandler
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertTrue(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        for step in 1 ... 6 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 2, x: 0.5 + 0.03 * CGFloat(step), y: 0.24, at: time)
        }
        XCTAssertEqual(handler.state.gesturePhase, .idle)

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
    }

    func testCommittedPartialLiftConsumesScrollAndMomentumTail() throws {
        let fixture = try makeFixture(
            workspaceFingers: .three,
            scrollGestureEnabled: true,
            columnFingers: .two
        )
        var time = driveCommittedPartialLift(fixture)
        let handler = fixture.controller.mouseEventHandler

        fixture.controller.isEnabled = false

        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)

        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.ended.rawValue))
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertFalse(handler.state.suppressTrackpadMomentumScroll)
    }

    func testCursorMonitorSwipeSwitchesThatMonitorOnly() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture)
        let monitorB = secondary.monitor
        let wsB1 = try XCTUnwrap(secondary.workspaceIds.first)
        let wsB2 = try XCTUnwrap(secondary.workspaceIds.last)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(wsB1, on: monitorB.id))
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100, location: CGPoint(x: 2400, y: 450))

        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: monitorB.id)?.id, wsB2)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.interactionMonitorId, monitorB.id)
    }

    func testDwindleWorkspaceSwipeSwitchesWorkspaces() throws {
        let fixture = try makeFixture(enableNiri: false)
        fixture.controller.settings.workspaceConfigurations = fixture.controller.settings.workspaceConfigurations.map {
            $0.with(layoutType: .dwindle)
        }
        fixture.controller.enableDwindleLayout()

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(fixture.controller.workspaceManager.activeLayoutKind(for: fixture.ws2), .dwindle)
    }

    func testSingleWorkspaceCursorMonitorSwipeDoesNotMutateInteraction() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture, workspaceNames: ["6"])
        let workspaceId = try XCTUnwrap(secondary.workspaceIds.first)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: secondary.monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))
        let interactionBefore = manager.interactionMonitorId

        _ = performVerticalSwipe(
            fixture,
            totalUnits: 220,
            startTime: 100,
            location: CGPoint(x: 2400, y: 450)
        )

        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: secondary.monitor.id)?.id, workspaceId)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.interactionMonitorId, interactionBefore)
    }

    func testCommandHandlerRelativeSwitchUsesInteractionMonitor() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture)
        let wsB1 = try XCTUnwrap(secondary.workspaceIds.first)
        let wsB2 = try XCTUnwrap(secondary.workspaceIds.last)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(wsB1, on: secondary.monitor.id))

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.switchWorkspaceNext),
            .executed
        )

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: secondary.monitor.id)?.id, wsB2)
        XCTAssertEqual(manager.interactionMonitorId, secondary.monitor.id)
    }

    func testCollidingConfigForcesVerticalAndPreservesStoredAxis() throws {
        let fixture = try makeFixture(workspaceAxis: .horizontal, scrollGestureEnabled: true)
        XCTAssertTrue(fixture.controller.settings.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(fixture.controller.settings.effectiveWorkspaceSwipeAxis, .vertical)
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(fixture.controller.settings.workspaceSwipeAxis, .horizontal)
    }

    func testColumnOnlyConfigDoesNotArmWithoutColumnContext() throws {
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            enableNiri: false
        )
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.2 + 0.05 * CGFloat(step), y: 0.5, at: time)
        }
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
    }

    func testHorizontalAxisSwipeWithDistinctCountsSwitches() throws {
        let fixture = try makeFixture(
            workspaceFingers: .four,
            workspaceAxis: .horizontal,
            scrollGestureEnabled: true,
            columnFingers: .three
        )
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.8, y: 0.5, at: time)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.8 - 0.055 * CGFloat(step), y: 0.5, at: time)
        }
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testWorkspaceGestureRecoversThroughRawSourceReplacementWithoutRestart() async throws {
        let fixture = try makeFixture()
        let harness = await installRecoveringMultitouchSource(fixture)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)

        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.2,
            at: 100,
            location: location
        )
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.24,
            at: 100.01,
            location: location
        )
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .committed)
        fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll = true

        harness.source.requestRevalidation(.wake)
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        let recoveredGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)

        XCTAssertNotEqual(recoveredGeneration, firstGeneration)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll)

        var timestamp = 101.0
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.2,
            at: timestamp,
            location: location
        )
        for step in 1 ... 8 {
            timestamp += 0.01
            sendRawFrame(
                harness.source,
                generation: recoveredGeneration,
                fingers: 3,
                x: 0.5,
                y: 0.2 + 0.055 * CGFloat(step),
                at: timestamp,
                location: location
            )
        }
        timestamp += 0.01
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 0,
            x: 0,
            y: 0,
            at: timestamp,
            location: location
        )

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertTrue(fixture.controller.mouseEventHandler.multitouchDiagnosticsSnapshot?.state == .running)
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    func testColumnGestureRecoversThroughRawSourceReplacementWithoutRestart() async throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(8_001 + index),
                windowId: 8_101 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }

        let harness = await installRecoveringMultitouchSource(fixture)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.8,
            y: 0.5,
            at: 200,
            location: location
        )
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 200.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll = true

        harness.source.requestRevalidation(.wake)
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        let recoveredGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)

        XCTAssertNotEqual(recoveredGeneration, firstGeneration)
        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll)

        var timestamp = 201.0
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 3,
            x: 0.8,
            y: 0.5,
            at: timestamp,
            location: location
        )
        for step in 1 ... 4 {
            timestamp += 0.01
            sendRawFrame(
                harness.source,
                generation: recoveredGeneration,
                fingers: 3,
                x: 0.8 - 0.03 * CGFloat(step),
                y: 0.5,
                at: timestamp,
                location: location
            )
        }
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        timestamp += 0.01
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 0,
            x: 0,
            y: 0,
            at: timestamp,
            location: location
        )

        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    func testCancelledPhaseSettlesCommittedGestureWithoutFlick() async throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(8_201 + index),
                windowId: 8_301 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }

        let harness = await installRecoveringMultitouchSource(fixture)
        let generation = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)
        sendRawFrame(harness.source, generation: generation, fingers: 3, x: 0.8, y: 0.5, at: 300, location: location)
        sendRawFrame(
            harness.source,
            generation: generation,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 300.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))

        fixture.controller.mouseEventHandler.receiveTapGestureEvent(
            MouseEventHandler.GestureEventSnapshot(
                location: location,
                phaseRawValue: NSEvent.Phase.cancelled.rawValue,
                timestamp: 300.02,
                touches: []
            )
        )

        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        sendRawFrame(harness.source, generation: generation, fingers: 0, x: 0, y: 0, at: 300.5, location: location)
        sendRawFrame(harness.source, generation: generation, fingers: 3, x: 0.8, y: 0.5, at: 301, location: location)
        sendRawFrame(
            harness.source,
            generation: generation,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 301.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    private func installRecoveringMultitouchSource(
        _ fixture: Fixture
    ) async -> (
        source: MultitouchGestureSource,
        backend: FakeMultitouchBackend,
        sleeper: ManualMultitouchSleeper
    ) {
        let device = FakeMultitouchBackend.device(pointer: 0xC1, registryId: 303)
        let backend = FakeMultitouchBackend()
        backend.enumerations = [
            FakeMultitouchBackend.enumeration([device]),
            FakeMultitouchBackend.enumeration([device])
        ]
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        fixture.controller.mouseEventHandler.installMultitouchSource(source)
        await drainMultitouchTasks()
        XCTAssertEqual(sleeper.pendingCount, 1)
        sleeper.resumeNext()
        await drainMultitouchTasks()
        XCTAssertEqual(source.diagnosticsSnapshot().state, .running)
        return (source, backend, sleeper)
    }

    private func cleanupRecoveringMultitouchSource(
        _ fixture: Fixture,
        harness: (
            source: MultitouchGestureSource,
            backend: FakeMultitouchBackend,
            sleeper: ManualMultitouchSleeper
        )
    ) async {
        fixture.controller.mouseEventHandler.cleanup()
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    private func sendRawFrame(
        _ source: MultitouchGestureSource,
        generation: UInt,
        fingers: Int,
        x: CGFloat,
        y: CGFloat,
        at timestamp: TimeInterval,
        location: CGPoint
    ) {
        source.handleRawFrame(
            MultitouchGestureSource.RawFrame(
                touches: (0 ..< fingers).map { _ in
                    MultitouchGestureSource.RawTouch(x: Float(x), y: Float(y))
                },
                timestamp: timestamp
            ),
            generation: generation,
            location: location
        )
    }
}
