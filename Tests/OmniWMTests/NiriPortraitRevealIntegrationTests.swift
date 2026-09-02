// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriPortraitRevealIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let sourceMonitor: Monitor
        let adjacentMonitor: Monitor
    }

    func testTransitionToColumnUsesTheConfiguredPrimaryAxis() {
        let columns = (0 ..< 3).map { _ in NiriContainer() }
        for column in columns {
            column.cachedWidth = 400
            column.cachedHeight = 600
        }

        let scenarios: [(orientation: Monitor.Orientation, frame: CGRect, expectedOffset: CGFloat)] = [
            (.horizontal, CGRect(x: 0, y: 0, width: 1_000, height: 800), -300),
            (.vertical, CGRect(x: 0, y: 0, width: 1_000, height: 800), -100)
        ]

        for scenario in scenarios {
            var state = ViewportState()
            state.transitionToColumn(
                2,
                columns: columns,
                gap: 0,
                workingArea: scenario.frame,
                orientation: scenario.orientation,
                motion: .disabled,
                animate: false,
                centerMode: .always,
                scale: 1,
                viewFrame: scenario.frame
            )

            XCTAssertEqual(state.activeColumnIndex, 2)
            XCTAssertEqual(state.viewOffset, scenario.expectedOffset, accuracy: 0.001)
        }
    }

    func testWorkspaceBarWindowNavigationRevealsOffscreenPortraitTarget() async throws {
        let fixture = try await makeFixture(seed: 481_000, animationsEnabled: false)
        let windows = addExistingColumns(count: 3, seed: 481_100, to: fixture)
        let target = windows[2]
        installViewport(
            selected: windows[0],
            activeColumnIndex: 0,
            rememberedToken: windows[0].token,
            in: fixture
        )

        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).allSatisfy { $0.cachedHeight == 0 })
        XCTAssertTrue(fixture.controller.windowActionHandler.focusWindowFromBar(token: target.token))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(state.selectedNodeId, target.node.id)
        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertTrue(fixture.engine.columns(in: fixture.workspaceId).allSatisfy { $0.cachedHeight > 0 })
        try assertVisible(target.token, state: state, in: fixture)
    }

    func testWorkspaceBarWorkspaceFocusRelayoutRevealsRememberedPortraitTarget() async throws {
        let fixture = try await makeFixture(seed: 482_000, animationsEnabled: false)
        let windows = addExistingColumns(count: 3, seed: 482_100, to: fixture)
        let target = windows[2]
        primeLayout(fixture)
        installViewport(
            selected: target,
            activeColumnIndex: 0,
            rememberedToken: target.token,
            in: fixture
        )

        XCTAssertTrue(
            fixture.controller.windowActionHandler.focusWorkspaceFromBar(id: fixture.workspaceId)
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(state.selectedNodeId, target.node.id)
        XCTAssertEqual(state.activeColumnIndex, 2)
        try assertVisible(target.token, state: state, in: fixture)
    }

    func testPortraitNewWindowIsVisibleAfterFirstCompletedLayout() async throws {
        let scenarios: [(existingCount: Int, animationsEnabled: Bool)] = [
            (0, false),
            (0, true),
            (2, false),
            (2, true)
        ]

        for (index, scenario) in scenarios.enumerated() {
            let fixture = try await makeFixture(
                seed: 483_000 + index * 1_000,
                animationsEnabled: scenario.animationsEnabled
            )
            let existing = addExistingColumns(
                count: scenario.existingCount,
                seed: 483_100 + index * 1_000,
                to: fixture
            )
            if let first = existing.first {
                primeLayout(fixture)
                installViewport(
                    selected: first,
                    activeColumnIndex: 0,
                    rememberedToken: first.token,
                    in: fixture
                )
            }

            let newToken = WindowToken(
                pid: pid_t(483_500 + index),
                windowId: 483_600 + index
            )
            _ = WindowAdmissionTestSupport.track(
                newToken,
                in: fixture.workspaceId,
                controller: fixture.controller
            )

            let plans = fixture.controller.workspaceManager.withEngineMutationScope(
                in: fixture.workspaceId,
                label: "portrait_arrival_layout"
            ) {
                fixture.controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [fixture.workspaceId]
                )
            }
            let plan = try XCTUnwrap(plans.first)
            let state = try XCTUnwrap(plan.sessionPatch.viewportState)
            let newNode = try XCTUnwrap(
                fixture.engine.findNode(for: newToken, in: fixture.workspaceId)
            )
            let newColumn = try XCTUnwrap(
                fixture.engine.findColumn(containing: newNode, in: fixture.workspaceId)
            )
            let newColumnIndex = try XCTUnwrap(
                fixture.engine.columnIndex(of: newColumn, in: fixture.workspaceId)
            )

            XCTAssertEqual(state.selectedNodeId, newNode.id)
            XCTAssertEqual(state.activeColumnIndex, newColumnIndex)
            try assertVisible(
                newToken,
                state: state,
                in: fixture,
                allowsPrimaryEdgeOverlap: true
            )
        }
    }

    private func makeFixture(
        seed: Int,
        animationsEnabled: Bool
    ) async throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNiriPortraitRevealIntegrationTests-\(seed)"
        )
        controller.motionPolicy.animationsEnabled = animationsEnabled
        let sourceMonitor = Monitor(
            id: .init(displayId: CGDirectDisplayID(seed)),
            displayId: CGDirectDisplayID(seed),
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            hasNotch: false,
            name: "Portrait Source"
        )
        let adjacentMonitor = Monitor(
            id: .init(displayId: CGDirectDisplayID(seed + 1)),
            displayId: CGDirectDisplayID(seed + 1),
            frame: CGRect(x: 0, y: -900, width: 1_600, height: 900),
            visibleFrame: CGRect(x: 0, y: -900, width: 1_600, height: 900),
            hasNotch: false,
            name: "Adjacent Landscape"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, adjacentMonitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let adjacentWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: sourceMonitor.id)
        controller.workspaceManager.assignWorkspaceToMonitor(adjacentWorkspaceId, monitorId: adjacentMonitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: sourceMonitor.id))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(adjacentWorkspaceId, on: adjacentMonitor.id))
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.niriLayoutHandler.enableNiriLayout()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let engine = try XCTUnwrap(controller.niriEngine)

        XCTAssertEqual(engine.monitorForWorkspace(workspaceId)?.orientation, .vertical)
        XCTAssertEqual(controller.workspaceManager.monitor(for: workspaceId)?.id, sourceMonitor.id)

        return Fixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            sourceMonitor: sourceMonitor,
            adjacentMonitor: adjacentMonitor
        )
    }

    private func addExistingColumns(
        count: Int,
        seed: Int,
        to fixture: Fixture
    ) -> [(token: WindowToken, node: NiriWindow)] {
        var windows: [(token: WindowToken, node: NiriWindow)] = []
        windows.reserveCapacity(count)

        for index in 0 ..< count {
            let token = WindowToken(
                pid: pid_t(seed + index),
                windowId: seed + 100 + index
            )
            _ = WindowAdmissionTestSupport.track(
                token,
                in: fixture.workspaceId,
                controller: fixture.controller
            )
            let previous = windows.last
            let node = fixture.controller.workspaceManager.withEngineMutationScope(
                in: fixture.workspaceId,
                label: "portrait_fixture_window"
            ) {
                fixture.engine.addWindow(
                    token: token,
                    to: fixture.workspaceId,
                    afterSelection: previous?.node.id,
                    focusedToken: previous?.token
                )
            }
            windows.append((token, node))
        }

        return windows
    }

    private func primeLayout(_ fixture: Fixture) {
        let plans = fixture.controller.workspaceManager.withEngineMutationScope(
            in: fixture.workspaceId,
            label: "portrait_fixture_layout"
        ) {
            fixture.controller.niriLayoutHandler.layoutWithNiriEngine(
                activeWorkspaces: [fixture.workspaceId]
            )
        }

        XCTAssertFalse(plans.isEmpty)
        for column in fixture.engine.columns(in: fixture.workspaceId) {
            XCTAssertGreaterThan(column.cachedHeight, 0)
        }
    }

    private func installViewport(
        selected: (token: WindowToken, node: NiriWindow),
        activeColumnIndex: Int,
        rememberedToken: WindowToken,
        in fixture: Fixture
    ) {
        var state = ViewportState()
        state.selectedNodeId = selected.node.id
        state.activeColumnIndex = activeColumnIndex
        state.jumpOffset(to: 0)
        _ = fixture.controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: fixture.workspaceId,
                viewportState: state,
                rememberedFocusToken: rememberedToken,
                plannedSeq: fixture.controller.workspaceManager.worldSeq
            )
        )
    }

    private func assertVisible(
        _ token: WindowToken,
        state: ViewportState,
        in fixture: Fixture,
        allowsPrimaryEdgeOverlap: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let gap = fixture.controller.innerGap(for: fixture.sourceMonitor)
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.sourceMonitor)
        let layout = fixture.engine.calculateCombinedLayoutWithVisibility(
            in: fixture.workspaceId,
            monitor: fixture.sourceMonitor,
            gaps: LayoutGaps(
                horizontal: gap,
                vertical: gap
            ),
            state: state,
            workingArea: WorkingAreaContext(
                workingFrame: workingFrame,
                fullscreenLayoutFrame: fixture.controller.fullscreenLayoutFrame(
                    for: fixture.sourceMonitor
                ),
                viewFrame: fixture.sourceMonitor.frame,
                scale: 2
            )
        )
        let frame = try XCTUnwrap(layout.frames[token], file: file, line: line)
        let sourceIntersection = frame.intersection(workingFrame)
        let adjacentIntersection = frame.intersection(fixture.adjacentMonitor.frame)
        let sourceArea = sourceIntersection.width * sourceIntersection.height
        let adjacentArea = adjacentIntersection.width * adjacentIntersection.height

        XCTAssertNil(layout.hiddenHandles[token], file: file, line: line)
        XCTAssertFalse(sourceIntersection.isNull, file: file, line: line)
        XCTAssertGreaterThan(sourceArea, 0, file: file, line: line)
        XCTAssertTrue(
            workingFrame.contains(CGPoint(x: frame.midX, y: frame.midY)),
            file: file,
            line: line
        )
        if allowsPrimaryEdgeOverlap {
            XCTAssertGreaterThan(sourceArea, adjacentArea, file: file, line: line)
        } else {
            XCTAssertFalse(
                frame.intersects(fixture.adjacentMonitor.frame),
                "\(frame) intersects \(fixture.adjacentMonitor.frame)",
                file: file,
                line: line
            )
        }
    }
}
