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

    private struct StackedAnimationFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let sourceMonitor: Monitor
        let neighborMonitor: Monitor
        let tokens: [WindowToken]
        let selectedToken: WindowToken
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

    func testVerticalUpMoveAnimationDoesNotBleedOntoMonitorAbove() throws {
        let fixture = try makeStackedAnimationFixture(neighborAbove: true, selectedIndex: 0)

        execute(.move(.up), on: fixture.controller)

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        try assertVerticalMoveAnimationContained(fixture)
    }

    func testVerticalDownMoveAnimationDoesNotBleedOntoMonitorBelow() throws {
        let fixture = try makeStackedAnimationFixture(neighborAbove: false, selectedIndex: 1)

        execute(.move(.down), on: fixture.controller)

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        try assertVerticalMoveAnimationContained(fixture)
    }

    func testVerticalUpExpelAnimationDoesNotBleedOntoMonitorAbove() throws {
        let fixture = try makeStackedAnimationFixture(
            neighborAbove: true,
            selectedIndex: 0,
            startAsSiblings: true
        )

        execute(.move(.up), on: fixture.controller)

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        try assertVerticalMoveAnimationContained(fixture)
    }

    func testVerticalDownExpelAnimationDoesNotBleedOntoMonitorBelow() throws {
        let fixture = try makeStackedAnimationFixture(
            neighborAbove: false,
            selectedIndex: 1,
            startAsSiblings: true
        )

        execute(.move(.down), on: fixture.controller)

        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        try assertVerticalMoveAnimationContained(fixture)
    }

    func testVerticalRapidPrimaryMoveRetargetStaysOnSourceMonitor() throws {
        let fixture = try makeStackedAnimationFixture(neighborAbove: true, selectedIndex: 0)

        execute(.move(.up), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        try assertVerticalMoveAnimationContained(fixture, sampleOffsets: [0])

        execute(.move(.down), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        try assertVerticalMoveAnimationContained(fixture, sampleOffsets: [0])

        execute(.move(.up), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 1)
        try assertVerticalMoveAnimationContained(fixture)

        let settledTime = fixture.controller.animationClock.now() + 2
        XCTAssertFalse(
            fixture.engine.tickAllWindowAnimations(
                in: fixture.workspaceId,
                at: settledTime
            )
        )
        XCTAssertFalse(
            fixture.controller.workspaceManager.animationDriver.tick(
                in: fixture.workspaceId,
                at: settledTime
            )
        )
        for token in fixture.tokens {
            XCTAssertNil(
                fixture.engine.findNode(for: token, in: fixture.workspaceId)?.moveYContainmentFrame
            )
        }
        try assertVerticalMoveAnimationContained(
            fixture,
            sampleOffsets: [0],
            requiresActiveContainment: false
        )
    }

    func testVerticalMixedAxisRetargetKeepsContainment() throws {
        let fixture = try makeStackedAnimationFixture(
            neighborAbove: true,
            selectedIndex: 0,
            windowCount: 3
        )

        execute(.move(.up), on: fixture.controller)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
        try assertVerticalMoveAnimationContained(fixture, sampleOffsets: [0])

        let selectedNode = try XCTUnwrap(
            fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId)
        )
        let selectedColumn = try XCTUnwrap(
            fixture.engine.findColumn(containing: selectedNode, in: fixture.workspaceId)
        )
        let selectedIndex = try XCTUnwrap(
            selectedColumn.windowNodes.firstIndex(where: { $0 === selectedNode })
        )
        let secondaryDirection: Direction = selectedIndex == 0 ? .right : .left

        execute(.move(secondaryDirection), on: fixture.controller)

        let movedIndex = try XCTUnwrap(
            selectedColumn.windowNodes.firstIndex(where: { $0 === selectedNode })
        )
        XCTAssertNotEqual(movedIndex, selectedIndex)
        for token in fixture.tokens {
            guard let window = fixture.engine.findNode(for: token, in: fixture.workspaceId),
                  window.moveYAnimation != nil
            else {
                continue
            }
            XCTAssertEqual(window.moveYContainmentFrame, fixture.sourceMonitor.frame)
        }
        try assertVerticalMoveAnimationContained(fixture)
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

    private func makeStackedAnimationFixture(
        neighborAbove: Bool,
        selectedIndex: Int,
        startAsSiblings: Bool = false,
        windowCount: Int = 2
    ) throws -> StackedAnimationFixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMNiriDirectionalOrientationAnimationTests"
        )
        controller.motionPolicy.animationsEnabled = false
        controller.settings.moveCrossesMonitorAtEdge = false

        let sourceMonitor = Monitor(
            id: .init(displayId: 47_410),
            displayId: 47_410,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 2_560),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 2_560),
            hasNotch: false,
            name: "Portrait Animation Source"
        )
        let neighborY: CGFloat = neighborAbove ? 2_560 : -1_080
        let neighborMonitor = Monitor(
            id: .init(displayId: 47_411),
            displayId: 47_411,
            frame: CGRect(x: 328, y: neighborY, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 328, y: neighborY, width: 1_920, height: 1_080),
            hasNotch: false,
            name: neighborAbove ? "Upper Animation Neighbor" : "Lower Animation Neighbor"
        )

        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, neighborMonitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "6", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let engine = try XCTUnwrap(controller.niriEngine)
        XCTAssertEqual(engine.monitor(for: sourceMonitor.id)?.orientation, .vertical)
        XCTAssertEqual(controller.workspaceManager.monitor(for: workspaceId)?.id, sourceMonitor.id)

        let tokens = (0 ..< windowCount).map { index in
            addWindow(
                pid: pid_t(474_010 + index),
                windowId: 474_110 + index,
                to: workspaceId,
                controller: controller
            )
        }
        var nodes: [NiriWindow] = []
        nodes.reserveCapacity(tokens.count)
        for token in tokens {
            let previousNode = nodes.last
            nodes.append(
                engine.addWindow(
                    token: token,
                    to: workspaceId,
                    afterSelection: previousNode?.id,
                    focusedToken: previousNode?.token
                )
            )
        }
        let firstNode = try XCTUnwrap(nodes.first)
        let secondNode = try XCTUnwrap(nodes.dropFirst().first)
        if startAsSiblings {
            controller.workspaceManager.withEngineMutationScope(
                in: workspaceId,
                label: "directional_animation_siblings"
            ) {
                guard let firstColumn = engine.findColumn(containing: firstNode, in: workspaceId),
                      let secondColumn = engine.findColumn(containing: secondNode, in: workspaceId)
                else {
                    XCTFail("Expected two Niri containers")
                    return
                }
                firstColumn.appendChild(secondNode)
                secondColumn.remove()
            }
        }
        let selectedNode = nodes[selectedIndex]
        let selectedToken = tokens[selectedIndex]

        controller.workspaceManager.withEngineMutationScope(
            in: workspaceId,
            label: "directional_animation_fixture"
        ) {
            engine.activateWindow(selectedNode.id, in: workspaceId)
        }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: selectedNode.id,
            focusedToken: selectedToken,
            in: workspaceId,
            onMonitor: sourceMonitor.id
        )

        let workingFrame = controller.insetWorkingFrame(for: sourceMonitor)
        let gap = controller.innerGap(for: sourceMonitor)
        _ = engine.calculateCombinedLayoutWithVisibility(
            in: workspaceId,
            monitor: sourceMonitor,
            gaps: LayoutGaps(
                horizontal: gap,
                vertical: gap,
                outer: controller.workspaceManager.outerGaps
            ),
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workingArea: WorkingAreaContext(
                workingFrame: workingFrame,
                fullscreenLayoutFrame: controller.fullscreenLayoutFrame(for: sourceMonitor),
                viewFrame: sourceMonitor.frame,
                scale: 2
            )
        )

        controller.motionPolicy.animationsEnabled = true
        return StackedAnimationFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            sourceMonitor: sourceMonitor,
            neighborMonitor: neighborMonitor,
            tokens: tokens,
            selectedToken: selectedToken
        )
    }

    private func assertVerticalMoveAnimationContained(
        _ fixture: StackedAnimationFixture,
        sampleOffsets: [TimeInterval] = [0, 1.0 / 120.0, 1.0 / 60.0, 0.05, 0.1, 0.2],
        requiresActiveContainment: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let state = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let driver = fixture.controller.workspaceManager.animationDriver
        let gap = fixture.controller.innerGap(for: fixture.sourceMonitor)
        let gaps = LayoutGaps(
            horizontal: gap,
            vertical: gap,
            outer: fixture.controller.workspaceManager.outerGaps
        )
        let area = WorkingAreaContext(
            workingFrame: fixture.controller.insetWorkingFrame(for: fixture.sourceMonitor),
            fullscreenLayoutFrame: fixture.controller.fullscreenLayoutFrame(for: fixture.sourceMonitor),
            viewFrame: fixture.sourceMonitor.frame,
            scale: 2
        )
        let startTime = fixture.controller.animationClock.now()
        var containedAnimationCount = 0
        var selectedWindowWasVisible = false

        for offset in sampleOffsets {
            let sampleTime = startTime + offset
            let layout = fixture.engine.calculateCombinedLayoutWithVisibility(
                in: fixture.workspaceId,
                monitor: fixture.sourceMonitor,
                gaps: gaps,
                state: state,
                workingArea: area,
                animationTime: sampleTime,
                viewOffsetOverride: driver.liveViewOffset(
                    in: fixture.workspaceId,
                    semanticOffset: state.viewOffset,
                    at: sampleTime
                ),
                settledVisibilityOffset: driver.settledVisibilityOffset(
                    in: fixture.workspaceId,
                    semanticOffset: state.viewOffset
                )
            )
            if layout.hiddenHandles[fixture.selectedToken] == nil {
                selectedWindowWasVisible = true
            }

            let neighborIsAbove =
                fixture.neighborMonitor.frame.minY >= fixture.sourceMonitor.frame.maxY
            for token in fixture.tokens where layout.hiddenHandles[token] == nil {
                let frame = try XCTUnwrap(layout.frames[token], file: file, line: line)
                if neighborIsAbove {
                    XCTAssertLessThanOrEqual(
                        frame.maxY,
                        fixture.sourceMonitor.frame.maxY,
                        file: file,
                        line: line
                    )
                } else {
                    XCTAssertGreaterThanOrEqual(
                        frame.minY,
                        fixture.sourceMonitor.frame.minY,
                        file: file,
                        line: line
                    )
                }
                XCTAssertFalse(
                    frame.intersects(fixture.neighborMonitor.frame),
                    file: file,
                    line: line
                )
            }
            for frame in layout.frames.values {
                XCTAssertFalse(
                    frame.intersects(fixture.neighborMonitor.frame),
                    file: file,
                    line: line
                )
            }
        }

        for token in fixture.tokens {
            if fixture.engine.findNode(for: token, in: fixture.workspaceId)?.moveYContainmentFrame
                == fixture.sourceMonitor.frame
            {
                containedAnimationCount += 1
            }
        }
        if requiresActiveContainment {
            XCTAssertGreaterThan(containedAnimationCount, 0, file: file, line: line)
        }
        XCTAssertTrue(selectedWindowWasVisible, file: file, line: line)
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
