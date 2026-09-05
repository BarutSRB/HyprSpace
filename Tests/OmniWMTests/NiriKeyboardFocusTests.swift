// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriKeyboardFocusTests: XCTestCase {
    private enum FocusOperation: Equatable {
        case activate(pid_t)
        case focus(WindowToken)
        case raise
    }

    private final class FocusRecorder {
        var operations: [FocusOperation] = []
    }

    @MainActor private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let windows: [NiriWindow]
        let gap: CGFloat
        let recorder: FocusRecorder

        var state: ViewportState {
            controller.workspaceManager.niriViewportState(for: workspaceId)
        }
    }

    func testPrimaryNavigationFocusesImmediatelyAndDefersRetryRaise() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            try withFixture(orientation: orientation) { fixture in
                let direction: Direction = orientation == .horizontal ? .left : .down

                XCTAssertTrue(fixture.controller.niriLayoutHandler.focusNeighbor(direction: direction))

                let target = fixture.windows[2].token
                let expected: [FocusOperation] = [.activate(target.pid), .focus(target)]
                XCTAssertEqual(fixture.recorder.operations, expected)
                XCTAssertEqual(fixture.state.selectedNodeId, fixture.windows[2].id)
                XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, target)
                XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertEqual(
                    fixture.controller.intentLedger.defersRetryRaise(for: request),
                    true
                )
            }
        }
    }

    func testSecondaryNavigationRetainsFullFronting() throws {
        try withFixture() { fixture in
            let controller = fixture.controller
            let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: fixture.workspaceId))
            let column = try XCTUnwrap(fixture.engine.column(of: fixture.windows[2]))
            var state = fixture.state
            XCTAssertTrue(controller.workspaceManager.withEngineMutationScope {
                fixture.engine.consumeWindow(
                    fixture.windows[3],
                    into: column,
                    enteringFrom: .right,
                    in: fixture.workspaceId,
                    motion: .disabled,
                    state: &state,
                    workingFrame: controller.insetWorkingFrame(for: monitor),
                    gaps: fixture.gap,
                    orientation: .horizontal
                )
            })
            state.activeColumnIndex = 2
            state.selectedNodeId = fixture.windows[2].id
            controller.workspaceManager.updateNiriViewportState(state, for: fixture.workspaceId)
            fixture.recorder.operations.removeAll()

            XCTAssertTrue(controller.niriLayoutHandler.focusNeighbor(direction: .down))

            let target = fixture.windows[3].token
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.windows[3].id)
            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target), .raise])
        }
    }

    func testOrdinaryFocusRetainsFullFronting() throws {
        try withFixture() { fixture in
            let target = fixture.windows[2].token

            fixture.controller.focusWindow(target)

            XCTAssertEqual(fixture.recorder.operations, [.activate(target.pid), .focus(target), .raise])
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, target)
        }
    }

    private func withFixture(
        selection: Int = 3,
        orientation: Monitor.Orientation = .horizontal,
        _ body: (Fixture) throws -> Void
    ) throws {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNiriKeyboardFocusTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append(.activate($0)) },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append(.focus(WindowToken(pid: pid, windowId: Int(windowId))))
                },
                raiseWindow: { _ in recorder.operations.append(.raise) }
            )
        )
        controller.settings.niriVisibleContainerCount = 3
        controller.settings.niriInfiniteLoop = false
        controller.settings.niriCenterFocusedColumn = .never
        controller.motionPolicy.animationsEnabled = true
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let monitor = Monitor(
            id: .init(displayId: 980_811),
            displayId: 980_811,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            hasNotch: false,
            name: "Keyboard Focus"
        )
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                orientation: orientation
            ),
            for: monitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        var windows: [NiriWindow] = []
        for index in 0 ..< 4 {
            let token = WindowToken(pid: 980_900 + pid_t(index), windowId: 981_000 + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            windows.append(engine.addWindow(token: token, to: workspaceId, afterSelection: windows.last?.id))
        }
        for (column, width) in zip(engine.columns(in: workspaceId), [834, 1_010, 938, 834]) {
            column.width = .fixed(CGFloat(width))
            column.cachedWidth = CGFloat(width)
        }
        let gap = controller.innerGap(for: monitor)
        let position = engine.columns(in: workspaceId).prefix(selection).reduce(CGFloat.zero) {
            $0 + $1.cachedWidth + gap
        }
        let state = ViewportState(
            activeColumnIndex: selection,
            viewOffset: 1_800 - position,
            selectedNodeId: windows[selection].id
        )
        controller.workspaceManager.updateNiriViewportState(state, for: workspaceId)
        var pending = state
        pending.springOffset(to: state.viewOffset)
        let startingOffset = 900 - position
        var previous = state
        previous.viewOffset = startingOffset
        controller.workspaceManager.animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: state,
            transition: pending.offsetTransition
        )

        controller.layoutRefreshController.layoutState.activeRefreshTask?.cancel()
        let blocker = Task { @MainActor in }
        controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [workspaceId]
        )
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
        defer {
            blocker.cancel()
            controller.layoutRefreshController.layoutState.activeRefreshTask = nil
            controller.layoutRefreshController.layoutState.activeRefresh = nil
            controller.layoutRefreshController.layoutState.pendingRefresh = nil
        }
        try body(Fixture(
            controller: controller,
            workspaceId: workspaceId,
            engine: engine,
            windows: windows,
            gap: gap,
            recorder: recorder
        ))
    }
}
