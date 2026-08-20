// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriWorkspaceMonitorMoveTests: XCTestCase {
    func testReplacingDisplayRegistrationDropsDisplacedWorkspaceMotion() throws {
        let source = makeMonitor(
            displayId: 973_000,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_099,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let firstWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let secondWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))

        var firstState = manager.niriViewportState(for: firstWorkspaceId)
        firstState.springOffset(to: 100)
        manager.updateNiriViewportState(firstState, for: firstWorkspaceId)
        var secondState = manager.niriViewportState(for: secondWorkspaceId)
        secondState.springOffset(to: 200)
        manager.updateNiriViewportState(secondState, for: secondWorkspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: firstWorkspaceId,
            tokenBase: 973_700
        )
        XCTAssertTrue(manager.animationDriver.hasMotion(in: firstWorkspaceId))
        XCTAssertTrue(manager.animationDriver.hasMotion(in: secondWorkspaceId))
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: firstWorkspaceId)

        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(
                firstWorkspaceId,
                on: source.displayId
            )
        )
        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(
                secondWorkspaceId,
                on: source.displayId
            )
        )

        XCTAssertFalse(manager.animationDriver.hasMotion(in: firstWorkspaceId))
        XCTAssertTrue(manager.animationDriver.hasMotion(in: secondWorkspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: firstWorkspaceId)
        XCTAssertEqual(
            controller.niriLayoutHandler.scrollAnimationByDisplay[source.displayId],
            secondWorkspaceId
        )
    }

    func testStartingAnimationForInactiveWorkspaceDropsMotionAndRegistration() throws {
        let source = makeMonitor(
            displayId: 973_003,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_004,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let inactiveWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        var state = manager.niriViewportState(for: inactiveWorkspaceId)
        state.springOffset(to: 100)
        manager.updateNiriViewportState(state, for: inactiveWorkspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: inactiveWorkspaceId,
            tokenBase: 973_710
        )
        XCTAssertTrue(manager.animationDriver.hasMotion(in: inactiveWorkspaceId))
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: inactiveWorkspaceId)

        controller.layoutRefreshController.startScrollAnimation(for: inactiveWorkspaceId)

        XCTAssertFalse(manager.animationDriver.hasMotion(in: inactiveWorkspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: inactiveWorkspaceId)
        XCTAssertFalse(controller.niriLayoutHandler.hasScrollAnimation(for: inactiveWorkspaceId))
    }

    func testInactiveRegisteredOwnerTickDropsEveryMotionFamily() throws {
        let source = makeMonitor(
            displayId: 973_007,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_008,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let inactiveWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        var state = manager.niriViewportState(for: inactiveWorkspaceId)
        state.springOffset(to: 100)
        manager.updateNiriViewportState(state, for: inactiveWorkspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: inactiveWorkspaceId,
            tokenBase: 973_720
        )
        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(
                inactiveWorkspaceId,
                on: source.displayId
            )
        )
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: inactiveWorkspaceId)

        controller.niriLayoutHandler.tickScrollAnimation(targetTime: 1, displayId: source.displayId)

        XCTAssertFalse(manager.animationDriver.hasMotion(in: inactiveWorkspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: inactiveWorkspaceId)
        XCTAssertNil(controller.niriLayoutHandler.scrollAnimationByDisplay[source.displayId])
    }

    func testDisplayLinkCreationFailureDropsEveryMotionFamily() throws {
        let source = makeMonitor(
            displayId: 973_009,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_010,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        var state = manager.niriViewportState(for: workspaceId)
        state.springOffset(to: 100)
        manager.updateNiriViewportState(state, for: workspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: workspaceId,
            tokenBase: 973_730
        )
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: workspaceId)

        controller.layoutRefreshController.startScrollAnimation(for: workspaceId)

        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: workspaceId)
        XCTAssertNil(controller.niriLayoutHandler.scrollAnimationByDisplay[source.displayId])
    }

    func testCancelActiveAnimationsDropsEveryMotionFamily() throws {
        let source = makeMonitor(
            displayId: 973_011,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_012,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        var state = manager.niriViewportState(for: workspaceId)
        state.springOffset(to: 100)
        manager.updateNiriViewportState(state, for: workspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: workspaceId,
            tokenBase: 973_740
        )
        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(
                workspaceId,
                on: source.displayId
            )
        )
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: workspaceId)

        controller.niriLayoutHandler.cancelActiveAnimations(for: workspaceId)

        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: workspaceId)
        XCTAssertNil(controller.niriLayoutHandler.scrollAnimationByDisplay[source.displayId])
    }

    func testLostGestureTerminalFrameCommitsLiveOffsetAndDrainsRegistration() throws {
        let source = makeMonitor(
            displayId: 973_005,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_006,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let engine = NiriLayoutEngine()
        manager.niriEngine = engine
        manager.withEngineMutationScope(in: workspaceId) {
            engine.moveWorkspace(workspaceId, to: source.id, monitor: source)
        }
        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: source.id)?.id, workspaceId)
        let livenessClock = NiriGestureLivenessTestClock(time: 1)
        manager.animationDriver.gestureLivenessNow = { livenessClock.time }
        manager.animationDriver.beginGesture(
            in: workspaceId,
            isTrackpad: true,
            timestamp: 1
        )
        manager.animationDriver.updateGesture(
            in: workspaceId,
            delta: 60,
            timestamp: 1,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        XCTAssertTrue(
            controller.niriLayoutHandler.registerScrollAnimation(
                workspaceId,
                on: source.displayId
            )
        )
        livenessClock.time = 2

        controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: 2,
            displayId: source.displayId
        )

        XCTAssertEqual(manager.niriViewportState(for: workspaceId).viewOffset, 60, accuracy: 0.001)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        XCTAssertNil(controller.niriLayoutHandler.scrollAnimationByDisplay[source.displayId])
    }

    func testActualMoveRecomputesUnequalGeometryAndPreservesSemanticStateAndIdentity() throws {
        let source = makeMonitor(
            displayId: 973_001,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_002,
            name: "Destination",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let firstToken = WindowToken(pid: 973_101, windowId: 973_201)
        let secondToken = WindowToken(pid: 973_102, windowId: 973_202)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id
        )
        let firstColumn = try XCTUnwrap(engine.column(of: firstNode))
        let secondColumn = try XCTUnwrap(engine.column(of: secondNode))
        firstColumn.width = .proportion(0.5)
        firstColumn.height = .proportion(0.5)
        secondColumn.width = .fixed(240)
        secondColumn.height = .fixed(240)
        engine.moveWorkspace(workspaceId, to: source.id, monitor: source)

        var state = ViewportState()
        state.selectedNodeId = firstNode.id
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: source.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: source.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        XCTAssertEqual(firstColumn.cachedWidth, 300, accuracy: 0.001)
        XCTAssertEqual(firstColumn.cachedHeight, 200, accuracy: 0.001)
        XCTAssertEqual(secondColumn.cachedWidth, 240, accuracy: 0.001)
        XCTAssertEqual(secondColumn.cachedHeight, 240, accuracy: 0.001)
        XCTAssertTrue(
            firstColumn.animateWidthTo(
                newWidth: 450,
                clock: nil,
                config: .niriWindowResize,
                animated: true
            )
        )

        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let widthAnimation = try XCTUnwrap(firstColumn.widthAnimation)
        engine.moveWorkspace(workspaceId, to: destination.id, monitor: destination)

        XCTAssertTrue(engine.root(for: workspaceId) === root)
        XCTAssertTrue(engine.findNode(for: firstToken, in: workspaceId) === firstNode)
        XCTAssertTrue(engine.findNode(for: secondToken, in: workspaceId) === secondNode)
        XCTAssertTrue(engine.column(of: firstNode) === firstColumn)
        XCTAssertTrue(engine.column(of: secondNode) === secondColumn)
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), destination.id)
        XCTAssertEqual(firstColumn.cachedWidth, 0)
        XCTAssertEqual(firstColumn.cachedHeight, 0)
        XCTAssertEqual(secondColumn.cachedWidth, 0)
        XCTAssertEqual(secondColumn.cachedHeight, 0)
        XCTAssertFalse(firstColumn.widthAnimation === widthAnimation)
        XCTAssertNil(firstColumn.widthAnimation)
        XCTAssertNil(firstColumn.targetWidth)
        XCTAssertEqual(firstColumn.width, .proportion(0.5))
        XCTAssertEqual(firstColumn.height, .proportion(0.5))
        XCTAssertEqual(secondColumn.width, .fixed(240))
        XCTAssertEqual(secondColumn.height, .fixed(240))

        let destinationFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: destination.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )

        XCTAssertEqual(try XCTUnwrap(destinationFrames[firstToken]).width, 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(destinationFrames[secondToken]).width, 240, accuracy: 0.001)
        XCTAssertEqual(firstColumn.cachedWidth, 500, accuracy: 0.001)
        XCTAssertEqual(secondColumn.cachedWidth, 240, accuracy: 0.001)
    }

    func testSameOwnerMoveAndSyncPreserveCachesAndSizingAnimation() throws {
        let monitor = makeMonitor(
            displayId: 973_011,
            name: "Only",
            frame: CGRect(x: 0, y: 0, width: 900, height: 600)
        )
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = engine.addWindow(
            token: WindowToken(pid: 973_111, windowId: 973_211),
            to: workspaceId,
            afterSelection: nil
        )
        _ = engine.addWindow(
            token: WindowToken(pid: 973_112, windowId: 973_212),
            to: workspaceId,
            afterSelection: first.id
        )
        let column = try XCTUnwrap(engine.column(of: first))
        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        column.cachedWidth = 321
        column.cachedHeight = 654
        XCTAssertTrue(
            column.animateWidthTo(
                newWidth: 480,
                clock: nil,
                config: .niriWindowResize,
                animated: true
            )
        )
        let widthAnimation = try XCTUnwrap(column.widthAnimation)

        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )

        XCTAssertEqual(column.cachedWidth, 321)
        XCTAssertEqual(column.cachedHeight, 654)
        XCTAssertTrue(column.widthAnimation === widthAnimation)
        XCTAssertEqual(column.targetWidth, 480)
    }

    func testReconnectAttachmentInvalidatesBothAxesAndUsesTargetOrientation() throws {
        let source = makeMonitor(
            displayId: 973_021,
            name: "Landscape",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_022,
            name: "Portrait",
            frame: CGRect(x: 700, y: 0, width: 400, height: 1000)
        )
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let firstToken = WindowToken(pid: 973_121, windowId: 973_221)
        let secondToken = WindowToken(pid: 973_122, windowId: 973_222)
        let firstNode = engine.addWindow(
            token: firstToken,
            to: workspaceId,
            afterSelection: nil
        )
        let secondNode = engine.addWindow(
            token: secondToken,
            to: workspaceId,
            afterSelection: firstNode.id
        )
        let firstColumn = try XCTUnwrap(engine.column(of: firstNode))
        let secondColumn = try XCTUnwrap(engine.column(of: secondNode))
        firstColumn.width = .proportion(0.5)
        firstColumn.height = .proportion(0.5)
        secondColumn.width = .fixed(240)
        secondColumn.height = .fixed(240)
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: source)],
            orientations: [source.id: .horizontal]
        )

        var state = ViewportState()
        state.selectedNodeId = firstNode.id
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: source.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: source.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        XCTAssertEqual(firstColumn.cachedWidth, 300, accuracy: 0.001)
        XCTAssertEqual(firstColumn.cachedHeight, 200, accuracy: 0.001)

        let root = try XCTUnwrap(engine.root(for: workspaceId))
        engine.updateMonitors([destination], orientations: [destination.id: .vertical])
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: destination)],
            orientations: [destination.id: .vertical]
        )

        XCTAssertTrue(engine.root(for: workspaceId) === root)
        XCTAssertTrue(engine.findNode(for: firstToken, in: workspaceId) === firstNode)
        XCTAssertTrue(engine.findNode(for: secondToken, in: workspaceId) === secondNode)
        XCTAssertEqual(engine.monitor(for: destination.id)?.orientation, .vertical)
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), destination.id)
        XCTAssertEqual(firstColumn.cachedWidth, 0)
        XCTAssertEqual(firstColumn.cachedHeight, 0)
        XCTAssertEqual(secondColumn.cachedWidth, 0)
        XCTAssertEqual(secondColumn.cachedHeight, 0)

        let destinationFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: destination.visibleFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )

        XCTAssertEqual(try XCTUnwrap(destinationFrames[firstToken]).height, 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(destinationFrames[secondToken]).height, 240, accuracy: 0.001)
        XCTAssertEqual(firstColumn.cachedHeight, 500, accuracy: 0.001)
        XCTAssertEqual(secondColumn.cachedHeight, 240, accuracy: 0.001)
    }

    func testExplicitAndReturnHomeMovesCancelMotionWithoutResettingViewport() throws {
        let source = makeMonitor(
            displayId: 973_031,
            name: "Home",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_032,
            name: "Temporary",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let manager = makeManager(source: source, destination: destination)
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let replacementWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let destinationWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(
            manager.setActiveWorkspace(
                replacementWorkspaceId,
                on: source.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                destinationWorkspaceId,
                on: destination.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: source.id))

        let firstToken = addWindow(
            pid: 973_131,
            windowId: 973_231,
            workspaceId: workspaceId,
            manager: manager
        )
        let secondToken = addWindow(
            pid: 973_132,
            windowId: 973_232,
            workspaceId: workspaceId,
            manager: manager
        )
        let engine = NiriLayoutEngine()
        manager.niriEngine = engine
        var selectedNodeValue: NiriWindow?
        manager.withEngineMutationScope(in: workspaceId) {
            engine.moveWorkspace(workspaceId, to: source.id, monitor: source)
            let firstNode = engine.addWindow(
                token: firstToken,
                to: workspaceId,
                afterSelection: nil
            )
            selectedNodeValue = engine.addWindow(
                token: secondToken,
                to: workspaceId,
                afterSelection: firstNode.id
            )
        }
        let selectedNode = try XCTUnwrap(selectedNodeValue)

        var initialViewport = manager.niriViewportState(for: workspaceId)
        initialViewport.activeColumnIndex = 1
        initialViewport.selectedNodeId = selectedNode.id
        initialViewport.jumpOffset(to: -40)
        manager.updateNiriViewportState(initialViewport, for: workspaceId)
        var movingViewport = manager.niriViewportState(for: workspaceId)
        movingViewport.springOffset(to: -120)
        manager.updateNiriViewportState(movingViewport, for: workspaceId)
        XCTAssertTrue(manager.animationDriver.hasMotion(in: workspaceId))

        let moveOutcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: destination.id,
            force: true
        )

        XCTAssertEqual(moveOutcome.status, .executed)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        assertViewport(
            manager.niriViewportState(for: workspaceId),
            selectedNodeId: selectedNode.id,
            activeColumnIndex: 1,
            viewOffset: -120
        )
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), destination.id)

        var returnViewport = manager.niriViewportState(for: workspaceId)
        returnViewport.springOffset(to: -180)
        manager.updateNiriViewportState(returnViewport, for: workspaceId)
        XCTAssertTrue(manager.animationDriver.hasMotion(in: workspaceId))

        manager.applySettings()

        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        assertViewport(
            manager.niriViewportState(for: workspaceId),
            selectedNodeId: selectedNode.id,
            activeColumnIndex: 1,
            viewOffset: -180
        )
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, source.id)
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), source.id)
    }

    func testNonMigratingDisconnectCleanupDiscardsMotionWithoutResettingViewport() throws {
        let source = makeMonitor(
            displayId: 973_041,
            name: "Disconnecting",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destination = makeMonitor(
            displayId: 973_042,
            name: "Remaining",
            frame: CGRect(x: 700, y: 0, width: 1000, height: 700)
        )
        let controller = makeController(source: source, destination: destination)
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let selectedNodeId = NodeId()
        var initialViewport = manager.niriViewportState(for: workspaceId)
        initialViewport.activeColumnIndex = 2
        initialViewport.selectedNodeId = selectedNodeId
        initialViewport.jumpOffset(to: -60)
        manager.updateNiriViewportState(initialViewport, for: workspaceId)
        var movingViewport = manager.niriViewportState(for: workspaceId)
        movingViewport.springOffset(to: -140)
        manager.updateNiriViewportState(movingViewport, for: workspaceId)
        let engine = try XCTUnwrap(controller.niriEngine)
        let animations = try seedAnimationFamilies(
            controller: controller,
            workspaceId: workspaceId,
            tokenBase: 973_750
        )
        XCTAssertTrue(manager.animationDriver.hasMotion(in: workspaceId))
        assertAnimationFamiliesRunning(animations, engine: engine, workspaceId: workspaceId)
        XCTAssertTrue(
            controller.layoutRefreshController.niriHandler.registerScrollAnimation(
                workspaceId,
                on: source.displayId
            )
        )

        controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: source.displayId,
            migrateAnimations: false
        )

        XCTAssertNil(
            controller.layoutRefreshController.niriHandler
                .scrollAnimationByDisplay[source.displayId]
        )
        XCTAssertFalse(manager.animationDriver.hasMotion(in: workspaceId))
        assertAnimationFamiliesStopped(animations, engine: engine, workspaceId: workspaceId)
        assertViewport(
            manager.niriViewportState(for: workspaceId),
            selectedNodeId: selectedNodeId,
            activeColumnIndex: 2,
            viewOffset: -140
        )
    }

    private func assertViewport(
        _ state: ViewportState,
        selectedNodeId: NodeId,
        activeColumnIndex: Int,
        viewOffset: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.selectedNodeId, selectedNodeId, file: file, line: line)
        XCTAssertEqual(state.activeColumnIndex, activeColumnIndex, file: file, line: line)
        XCTAssertEqual(state.viewOffset, viewOffset, accuracy: 0.001, file: file, line: line)
    }

    private func makeManager(source: Monitor, destination: Monitor) -> WorkspaceManager {
        let manager = WorkspaceManager(settings: makeSettings(source: source, destination: destination))
        manager.applyMonitorConfigurationChange([source, destination])
        manager.applySettings()
        return manager
    }

    private func makeController(source: Monitor, destination: Monitor) -> WMController {
        let controller = WMController(settings: makeSettings(source: source, destination: destination))
        controller.workspaceManager.applyMonitorConfigurationChange([source, destination])
        controller.workspaceManager.applySettings()
        controller.niriEngine = NiriLayoutEngine()
        return controller
    }

    private func seedAnimationFamilies(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID,
        tokenBase: Int
    ) throws -> (window: NiriWindow, column: NiriContainer) {
        let engine = try XCTUnwrap(controller.niriEngine)
        let window = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.addWindow(
                token: WindowToken(pid: pid_t(tokenBase), windowId: tokenBase + 1),
                to: workspaceId,
                afterSelection: nil
            )
        }
        let column = try XCTUnwrap(engine.column(of: window))
        column.cachedWidth = 300
        column.animateMoveFrom(
            displacement: CGPoint(x: 50, y: 0),
            clock: nil,
            animated: true
        )
        _ = column.animateWidthTo(
            newWidth: 400,
            clock: nil,
            config: .niriWindowResize,
            animated: true
        )
        window.animateMoveFrom(
            displacement: CGPoint(x: 50, y: 0),
            clock: nil,
            animated: true
        )
        return (window, column)
    }

    private func assertAnimationFamiliesRunning(
        _ animations: (window: NiriWindow, column: NiriContainer),
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(animations.column.hasMoveAnimationRunning, file: file, line: line)
        XCTAssertTrue(animations.column.hasWidthAnimationRunning, file: file, line: line)
        XCTAssertTrue(animations.window.hasMoveAnimationsRunning, file: file, line: line)
        XCTAssertTrue(engine.hasAnyColumnAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertTrue(engine.hasAnyWindowAnimationsRunning(in: workspaceId), file: file, line: line)
    }

    private func assertAnimationFamiliesStopped(
        _ animations: (window: NiriWindow, column: NiriContainer),
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(animations.column.hasMoveAnimationRunning, file: file, line: line)
        XCTAssertFalse(animations.column.hasWidthAnimationRunning, file: file, line: line)
        XCTAssertFalse(animations.window.hasMoveAnimationsRunning, file: file, line: line)
        XCTAssertFalse(engine.hasAnyColumnAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertFalse(engine.hasAnyWindowAnimationsRunning(in: workspaceId), file: file, line: line)
        XCTAssertEqual(animations.column.cachedWidth, 400, file: file, line: line)
        XCTAssertNil(animations.column.targetWidth, file: file, line: line)
    }

    private func makeSettings(source: Monitor, destination: Monitor) -> SettingsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMNiriWorkspaceMonitorMoveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: source)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: source)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: destination)),
                layoutType: .niri
            )
        ]
        return settings
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        manager: WorkspaceManager
    ) -> WindowToken {
        manager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}

@MainActor
private final class NiriGestureLivenessTestClock {
    var time: TimeInterval

    init(time: TimeInterval) {
        self.time = time
    }
}
