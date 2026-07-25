// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriDirectionalOrientationTests: XCTestCase {
    private enum Topology: Equatable {
        case containers
        case siblings
        case tabbed
    }

    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let orientation: Monitor.Orientation
        let firstToken: WindowToken
        let secondToken: WindowToken
        let firstNode: NiriWindow
        let secondNode: NiriWindow
    }

    private struct BaseFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let orientation: Monitor.Orientation
    }

    private struct MixedMonitorFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let sourceMonitor: Monitor
        let targetMonitor: Monitor
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
    }

    func testVerticalSiblingFocusAndMoveUseLeftRight() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .siblings
        )
        var rendered = frames(for: fixture)

        XCTAssertEqual(fixture.orientation, .vertical)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midX)
        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        execute(.focus(.left), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)

        execute(.focus(.up), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.focus(.down), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)

        execute(.move(.right), on: fixture.controller)
        rendered = frames(for: fixture)
        try assertOrder(fixture.secondToken, fixture.firstToken, in: rendered, by: \.midX)
        execute(.move(.left), on: fixture.controller)
        rendered = frames(for: fixture)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midX)
    }

    func testVerticalRootFocusUsesUpForIncreasingRenderedY() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .containers
        )
        let rendered = frames(for: fixture)

        XCTAssertEqual(fixture.orientation, .vertical)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midY)
        execute(.focus(.up), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        execute(.focus(.down), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.focus(.left), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
    }

    func testVerticalLogicalMoveWindowCommandsRemainWithinContainer() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .siblings
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowUp),
            .executed
        )
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        var rendered = frames(for: fixture)
        XCTAssertGreaterThan(
            try XCTUnwrap(rendered[fixture.firstToken]).midX,
            try XCTUnwrap(rendered[fixture.secondToken]).midX
        )

        XCTAssertEqual(
            fixture.controller.commandHandler.handleHotkeyCommand(.moveWindowDown),
            .executed
        )
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        rendered = frames(for: fixture)
        XCTAssertGreaterThan(
            try XCTUnwrap(rendered[fixture.secondToken]).midX,
            try XCTUnwrap(rendered[fixture.firstToken]).midX
        )
    }

    func testVerticalPrimaryMoveConsumesExpelsAndReportsPhysicalEdge() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .containers
        )
        fixture.controller.settings.moveCrossesMonitorAtEdge = true

        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.moveWindow(direction: .down),
            .atWorkspaceEdge
        )
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        execute(.move(.down), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)

        execute(.move(.up), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        XCTAssertEqual(
            Set(fixture.engine.columns(in: fixture.workspaceId)[0].windowNodes.map(\.token)),
            Set([fixture.firstToken, fixture.secondToken])
        )
        assertSelection(fixture.firstNode, in: fixture)

        execute(.move(.down), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        let rendered = frames(for: fixture)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midY)
        assertSelection(fixture.firstNode, in: fixture)
    }

    func testVerticalConsumeToPreviousClearsLegacyColumnAnimation() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .containers
        )
        let targetColumn = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first)
        targetColumn.animateMoveFrom(
            displacement: CGPoint(x: 100, y: 0),
            clock: fixture.engine.animationClock,
            animated: true
        )
        XCTAssertTrue(targetColumn.hasMoveAnimationRunning)

        fixture.controller.motionPolicy.animationsEnabled = true
        fixture.controller.workspaceManager.withEngineMutationScope(
            in: fixture.workspaceId,
            label: "directional_animation"
        ) {
            fixture.engine.activateWindow(fixture.secondNode.id, in: fixture.workspaceId)
        }
        _ = fixture.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: fixture.secondNode.id,
            focusedToken: fixture.secondToken,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )

        execute(.move(.down), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        XCTAssertFalse(fixture.engine.hasAnyColumnAnimationsRunning(in: fixture.workspaceId))
    }

    func testVerticalTabbedFocusUsesLeftRight() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            topology: .tabbed
        )
        let column = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first)

        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        XCTAssertEqual(column.activeTileIdx, 1)
        execute(.focus(.left), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        XCTAssertEqual(column.activeTileIdx, 0)
    }

    func testPortraitForcedHorizontalRetainsHorizontalDirections() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            forcedOrientation: .horizontal,
            topology: .containers
        )
        let rendered = frames(for: fixture)

        XCTAssertEqual(fixture.monitor.autoOrientation, .vertical)
        XCTAssertEqual(fixture.orientation, .horizontal)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midX)
        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
    }

    func testHorizontalFocusAndMoveDirectionsRemainUnchanged() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 900),
            topology: .containers
        )
        var rendered = frames(for: fixture)

        XCTAssertEqual(fixture.orientation, .horizontal)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midX)
        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        execute(.focus(.left), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.move(.right), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)

        rendered = frames(for: fixture)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midY)
        execute(.focus(.up), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        execute(.focus(.down), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.move(.up), on: fixture.controller)
        rendered = frames(for: fixture)
        try assertOrder(fixture.secondToken, fixture.firstToken, in: rendered, by: \.midY)
    }
}

extension NiriDirectionalOrientationTests {
    func testLandscapeForcedVerticalUsesLeftRightForSiblings() throws {
        let fixture = try makeFixture(
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 900),
            forcedOrientation: .vertical,
            topology: .siblings
        )
        var rendered = frames(for: fixture)

        XCTAssertEqual(fixture.monitor.autoOrientation, .horizontal)
        XCTAssertEqual(fixture.orientation, .vertical)
        try assertOrder(fixture.firstToken, fixture.secondToken, in: rendered, by: \.midX)
        execute(.focus(.right), on: fixture.controller)
        assertSelection(fixture.secondNode, in: fixture)
        execute(.focus(.left), on: fixture.controller)
        assertSelection(fixture.firstNode, in: fixture)
        execute(.move(.right), on: fixture.controller)
        rendered = frames(for: fixture)
        try assertOrder(fixture.secondToken, fixture.firstToken, in: rendered, by: \.midX)
    }

    func testVerticalRightEdgeMoveCrossesToRightHorizontalMonitor() throws {
        let fixture = try makeMixedMonitorFixture()

        XCTAssertEqual(
            fixture.engine.monitor(for: fixture.sourceMonitor.id)?.orientation,
            .vertical
        )
        XCTAssertEqual(
            fixture.engine.monitor(for: fixture.targetMonitor.id)?.orientation,
            .horizontal
        )
        execute(.move(.right), on: fixture.controller)
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: fixture.token),
            fixture.targetWorkspaceId
        )
        XCTAssertNil(fixture.engine.findNode(for: fixture.token, in: fixture.sourceWorkspaceId))
        XCTAssertNotNil(fixture.engine.findNode(for: fixture.token, in: fixture.targetWorkspaceId))
        XCTAssertEqual(
            fixture.controller.workspaceManager.interactionMonitorId,
            fixture.targetMonitor.id
        )
    }
}

extension NiriDirectionalOrientationTests {
    private func makeFixture(
        frame: CGRect,
        forcedOrientation: Monitor.Orientation? = nil,
        topology: Topology
    ) throws -> Fixture {
        let base = try makeBaseFixture(frame: frame, forcedOrientation: forcedOrientation)
        let firstToken = addWindow(
            pid: 474_001,
            windowId: 474_101,
            to: base.workspaceId,
            controller: base.controller
        )
        let secondToken = addWindow(
            pid: 474_002,
            windowId: 474_102,
            to: base.workspaceId,
            controller: base.controller
        )
        let firstNode = base.engine.addWindow(
            token: firstToken,
            to: base.workspaceId,
            afterSelection: nil
        )
        let secondNode = base.engine.addWindow(
            token: secondToken,
            to: base.workspaceId,
            afterSelection: firstNode.id,
            focusedToken: firstToken
        )
        configureTopology(topology, firstNode: firstNode, secondNode: secondNode, base: base)
        select(firstNode, token: firstToken, base: base)

        return Fixture(
            controller: base.controller,
            engine: base.engine,
            workspaceId: base.workspaceId,
            monitor: base.monitor,
            orientation: base.orientation,
            firstToken: firstToken,
            secondToken: secondToken,
            firstNode: firstNode,
            secondNode: secondNode
        )
    }

    private func makeBaseFixture(
        frame: CGRect,
        forcedOrientation: Monitor.Orientation?
    ) throws -> BaseFixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNiriDirectionalOrientationTests"
        )
        controller.motionPolicy.animationsEnabled = false
        controller.settings.focusCrossesMonitorAtEdge = false
        controller.settings.moveCrossesMonitorAtEdge = false
        let monitor = makeMonitor(frame: frame)
        if let forcedOrientation {
            controller.settings.updateOrientationSettings(
                MonitorOrientationSettings(
                    monitorName: monitor.name,
                    monitorDisplayId: monitor.displayId,
                    orientation: forcedOrientation
                ),
                for: monitor
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let orientation = try XCTUnwrap(engine.monitor(for: monitor.id)?.orientation)
        return BaseFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            monitor: monitor,
            orientation: orientation
        )
    }

    private func makeMonitor(frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: 47_400),
            displayId: 47_400,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Directional Orientation"
        )
    }

    private func mixedMonitors() -> (source: Monitor, target: Monitor) {
        let source = Monitor(
            id: .init(displayId: 47_401), displayId: 47_401,
            frame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
            hasNotch: false, name: "Portrait Source"
        )
        let target = Monitor(
            id: .init(displayId: 47_402), displayId: 47_402,
            frame: CGRect(x: 900, y: 350, width: 1_600, height: 900),
            visibleFrame: CGRect(x: 900, y: 350, width: 1_600, height: 900),
            hasNotch: false, name: "Landscape Target"
        )
        return (source, target)
    }

    private func makeMixedMonitorFixture() throws -> MixedMonitorFixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNiriDirectionalOrientationTests"
        )
        controller.motionPolicy.animationsEnabled = false
        controller.settings.moveCrossesMonitorAtEdge = true
        let (source, target) = mixedMonitors()
        controller.workspaceManager.applyMonitorConfigurationChange([source, target])
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let token = addWindow(
            pid: 474_003,
            windowId: 474_103,
            to: sourceWorkspaceId,
            controller: controller
        )
        let node = engine.addWindow(token: token, to: sourceWorkspaceId, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: token,
            in: sourceWorkspaceId,
            onMonitor: source.id
        )
        _ = controller.workspaceManager.confirmManagedFocus(
            token,
            in: sourceWorkspaceId,
            onMonitor: source.id,
            activateWorkspaceOnMonitor: true
        )
        return MixedMonitorFixture(
            controller: controller,
            engine: engine,
            sourceMonitor: source,
            targetMonitor: target,
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            token: token
        )
    }

    private func configureTopology(
        _ topology: Topology,
        firstNode: NiriWindow,
        secondNode: NiriWindow,
        base: BaseFixture
    ) {
        guard topology != .containers else { return }
        base.controller.workspaceManager.withEngineMutationScope(
            in: base.workspaceId,
            label: "directional_fixture"
        ) {
            guard let firstColumn = base.engine.findColumn(containing: firstNode, in: base.workspaceId),
                  let secondColumn = base.engine.findColumn(containing: secondNode, in: base.workspaceId)
            else {
                XCTFail("Expected two Niri containers")
                return
            }
            firstColumn.appendChild(secondNode)
            secondColumn.remove()
            if topology == .tabbed {
                firstColumn.displayMode = .tabbed
                firstColumn.setActiveTileIdx(0)
                base.engine.updateTabbedColumnVisibility(column: firstColumn)
            }
        }
    }

    private func select(
        _ node: NiriWindow,
        token: WindowToken,
        base: BaseFixture
    ) {
        base.controller.workspaceManager.withEngineMutationScope(
            in: base.workspaceId,
            label: "directional_selection"
        ) {
            base.engine.activateWindow(node.id, in: base.workspaceId)
        }
        _ = base.controller.workspaceManager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: token,
            in: base.workspaceId,
            onMonitor: base.monitor.id
        )
    }

    private func frames(for fixture: Fixture) -> [WindowToken: CGRect] {
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        return fixture.engine.calculateLayout(
            state: fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId),
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            screenFrame: fixture.monitor.frame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: fixture.orientation
        )
    }

    private func execute(_ command: HotkeyCommand, on controller: WMController) {
        XCTAssertEqual(controller.commandHandler.handleHotkeyCommand(command), .executed)
    }

    private func assertOrder(
        _ lower: WindowToken,
        _ upper: WindowToken,
        in frames: [WindowToken: CGRect],
        by midpoint: KeyPath<CGRect, CGFloat>
    ) throws {
        let lowerFrame = try XCTUnwrap(frames[lower])
        let upperFrame = try XCTUnwrap(frames[upper])
        XCTAssertLessThan(lowerFrame[keyPath: midpoint], upperFrame[keyPath: midpoint])
    }

    private func assertSelection(
        _ node: NiriWindow,
        in fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId).selectedNodeId,
            node.id,
            file: file,
            line: line
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}
