// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

class NiriInteractionTestCase: XCTestCase {
    let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func addWindow(
        _ engine: NiriLayoutEngine,
        pid: pid_t,
        windowId: Int = 1,
        to workspaceId: WorkspaceDescriptor.ID,
        after node: NiriNode? = nil
    ) -> NiriWindow {
        engine.addWindow(
            token: WindowToken(pid: pid, windowId: windowId),
            to: workspaceId,
            afterSelection: node?.id
        )
    }

    func beginMove(
        _ engine: NiriLayoutEngine,
        window: NiriWindow,
        handle: WindowHandle? = nil,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var state = ViewportState()
        let frames = layout(engine, in: workspaceId, state: state)
        return engine.interactiveMoveBegin(
            windowId: window.id,
            windowHandle: handle ?? window.handle,
            startLocation: frames[window.token]?.center ?? .zero,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: 0,
            orientation: .horizontal
        )
    }

    func beginResize(
        _ engine: NiriLayoutEngine,
        window: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let frame = layout(engine, in: workspaceId)[window.token] ?? .zero
        return engine.interactiveResizeBegin(
            windowId: window.id,
            edges: .right,
            startLocation: CGPoint(x: frame.maxX, y: frame.midY),
            in: workspaceId,
            orientation: .horizontal
        )
    }

    func layout(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState = ViewportState()
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
    }

    func removeWindows(
        _ tokens: Set<WindowToken>,
        from engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NiriLayoutEngine.NiriRemovalResult {
        var state = ViewportState()
        return engine.removeWindows(
            tokens,
            in: workspaceId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            orientation: .horizontal,
            selectedNodeId: nil,
            removedNodeIds: []
        )
    }

    func windowOrder(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> [WindowToken] {
        engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
    }
}

final class NiriInteractionOwnershipTests: NiriInteractionTestCase {
    func testInteractiveMoveUpdateAndEndRemainOwnedByStartingWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_001, to: workspaceA)
        let target = addWindow(engine, pid: 1_001, windowId: 2, to: workspaceA, after: source)
        let foreignSource = addWindow(engine, pid: 1_002, to: workspaceB)
        _ = addWindow(engine, pid: 1_002, windowId: 2, to: workspaceB, after: foreignSource)
        var stateA = ViewportState()
        let framesA = layout(engine, in: workspaceA, state: stateA)
        _ = layout(engine, in: workspaceB)
        let sourceFrame = try XCTUnwrap(framesA[source.token])
        let targetFrame = try XCTUnwrap(framesA[target.token])
        let orderBefore = windowOrder(engine, in: workspaceA)
        let foreignOrderBefore = windowOrder(engine, in: workspaceB)

        XCTAssertTrue(
            engine.interactiveMoveBegin(
                windowId: source.id,
                windowHandle: source.handle,
                startLocation: sourceFrame.center,
                in: workspaceA,
                motion: .disabled,
                state: &stateA,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .horizontal
            )
        )
        let hoverTarget = try XCTUnwrap(
            engine.interactiveMoveUpdate(currentLocation: targetFrame.center)
        )
        guard case let .window(nodeId, _, insertPosition) = hoverTarget else {
            return XCTFail("Expected a window hover target")
        }
        XCTAssertEqual(nodeId, target.id)
        XCTAssertEqual(insertPosition, .swap)
        XCTAssertTrue(
            engine.interactiveMoveEnd(
                at: targetFrame.center,
                motion: .disabled,
                state: &stateA,
                workingFrame: workingFrame,
                gaps: 0
            )
        )
        XCTAssertNotEqual(windowOrder(engine, in: workspaceA), orderBefore)
        XCTAssertEqual(windowOrder(engine, in: workspaceB), foreignOrderBefore)
        XCTAssertNil(engine.interactiveMove)
    }

    func testInteractiveResizeUpdateAndEndRemainOwnedByStartingWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_003, to: workspaceA)
        _ = addWindow(engine, pid: 1_004, to: workspaceB)
        var stateA = ViewportState()
        let framesA = layout(engine, in: workspaceA, state: stateA)
        _ = layout(engine, in: workspaceB)
        let sourceFrame = try XCTUnwrap(framesA[source.token])
        let sourceWidthBefore = try XCTUnwrap(engine.columns(in: workspaceA).first?.cachedWidth)
        let foreignWidthBefore = try XCTUnwrap(engine.columns(in: workspaceB).first?.cachedWidth)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: source.id,
                edges: .right,
                startLocation: CGPoint(x: sourceFrame.maxX, y: sourceFrame.midY),
                in: workspaceA,
                orientation: .horizontal
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: sourceFrame.maxX + 100, y: sourceFrame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )
        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &stateA,
            workingFrame: workingFrame,
            gaps: 0
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(engine.columns(in: workspaceA).first?.cachedWidth),
            sourceWidthBefore
        )
        XCTAssertEqual(
            try XCTUnwrap(engine.columns(in: workspaceB).first?.cachedWidth),
            foreignWidthBefore
        )
        XCTAssertNil(engine.interactiveResize)
    }

    func testHorizontalInteractiveResizeUsesRenderedSingleWindowWidthWhenCacheIsEmpty() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 1_024, to: workspaceId)
        let frame = try XCTUnwrap(layout(engine, in: workspaceId)[window.token])
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        XCTAssertEqual(column.cachedWidth, 0)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .right,
                startLocation: CGPoint(x: frame.maxX, y: frame.midY),
                in: workspaceId,
                orientation: .horizontal
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frame.maxX - 120, y: frame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )

        let expectedWidth = frame.width - 120
        XCTAssertEqual(column.cachedWidth, expectedWidth, accuracy: 0.001)
        XCTAssertEqual(column.width, .fixed(expectedWidth))
        XCTAssertTrue(column.hasManualSingleWindowWidthOverride)
    }

    func testHorizontalInteractiveResizeCanonicalizesWidthStateAndTransfersIt() throws {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let targetWorkspace = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_025, to: sourceWorkspace)
        let sibling = addWindow(engine, pid: 1_025, windowId: 2, to: sourceWorkspace, after: source)
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: source, in: sourceWorkspace))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                sibling,
                into: sourceColumn,
                enteringFrom: .down,
                in: sourceWorkspace,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .horizontal
            )
        )
        let sourceFrame = try XCTUnwrap(layout(engine, in: sourceWorkspace)[source.token])
        sourceColumn.presetWidthIdx = 2
        sourceColumn.isFullWidth = true
        sourceColumn.savedWidth = .proportion(0.4)
        sourceColumn.hasManualSingleWindowWidthOverride = false
        let sourceAnimation = SpringAnimation(
            from: Double(sourceColumn.cachedWidth),
            to: Double(sourceColumn.cachedWidth + 100),
            startTime: 0,
            config: .niriWindowMovement,
            displayRefreshRate: 60
        )
        sourceColumn.widthAnimation = sourceAnimation
        sourceColumn.targetWidth = sourceColumn.cachedWidth + 100

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: source.id,
                edges: .right,
                startLocation: CGPoint(x: sourceFrame.maxX, y: sourceFrame.midY),
                in: sourceWorkspace,
                orientation: .horizontal
            )
        )
        XCTAssertTrue(sourceColumn.widthAnimation === sourceAnimation)
        XCTAssertEqual(sourceColumn.targetWidth, sourceColumn.cachedWidth + 100)
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: sourceFrame.maxX + 120, y: sourceFrame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )

        let resizedWidth = sourceColumn.cachedWidth
        XCTAssertEqual(sourceColumn.width, .fixed(resizedWidth))
        XCTAssertNil(sourceColumn.presetWidthIdx)
        XCTAssertFalse(sourceColumn.isFullWidth)
        XCTAssertNil(sourceColumn.savedWidth)
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)
        XCTAssertNil(sourceColumn.widthAnimation)
        XCTAssertNil(sourceColumn.targetWidth)

        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: 0
        )
        var targetState = ViewportState()
        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: sourceWorkspace,
                to: targetWorkspace,
                sourceState: &state,
                targetState: &targetState
            )
        )

        let targetColumn = try XCTUnwrap(engine.findColumn(containing: source, in: targetWorkspace))
        XCTAssertEqual(targetColumn.width, .fixed(resizedWidth))
        XCTAssertNil(targetColumn.presetWidthIdx)
        XCTAssertFalse(targetColumn.isFullWidth)
        XCTAssertNil(targetColumn.savedWidth)
        XCTAssertTrue(targetColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(targetColumn.cachedWidth, 0)
        XCTAssertNil(targetColumn.widthAnimation)
        XCTAssertNil(targetColumn.targetWidth)
        let targetFrame = try XCTUnwrap(layout(engine, in: targetWorkspace)[source.token])
        XCTAssertEqual(targetFrame.width, resizedWidth, accuracy: 0.001)
        XCTAssertTrue(engine.findColumn(containing: sibling, in: sourceWorkspace) === sourceColumn)
        XCTAssertEqual(sourceColumn.width, .fixed(resizedWidth))
        XCTAssertEqual(sourceColumn.cachedWidth, resizedWidth)
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)
    }
}

final class NiriInteractionLifecycleTests: NiriInteractionTestCase {
    func testMoveAndResizeBeginsAreMutuallyExclusive() {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 1_023, to: workspace)

        XCTAssertTrue(beginMove(engine, window: window, in: workspace))
        XCTAssertFalse(beginResize(engine, window: window, in: workspace))

        engine.interactiveMoveCancel()

        XCTAssertTrue(beginResize(engine, window: window, in: workspace))
        XCTAssertFalse(beginMove(engine, window: window, in: workspace))
    }

    func testWorkspaceRemovalClearsMoveAndPermitsMoveInAnotherWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_005, to: workspaceA)
        let next = addWindow(engine, pid: 1_006, to: workspaceB)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        XCTAssertFalse(beginMove(engine, window: next, in: workspaceB))

        engine.removeWorkspaceState(workspaceA)

        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: next, in: workspaceB))
    }

    func testWorkspaceRemovalClearsResizeAndPermitsResizeInAnotherWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_007, to: workspaceA)
        let next = addWindow(engine, pid: 1_008, to: workspaceB)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        XCTAssertFalse(beginResize(engine, window: next, in: workspaceB))

        engine.removeWorkspaceState(workspaceA)

        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: next, in: workspaceB))
    }

    func testSimpleRemovalClearsOnlyMatchingMoveAndResizeSessions() {
        let moveEngine = NiriLayoutEngine()
        let moveWorkspaceA = WorkspaceDescriptor.ID()
        let moveWorkspaceB = WorkspaceDescriptor.ID()
        let moveSource = addWindow(moveEngine, pid: 1_009, to: moveWorkspaceA)
        let unrelatedMoveWindow = addWindow(moveEngine, pid: 1_010, to: moveWorkspaceB)
        XCTAssertTrue(beginMove(moveEngine, window: moveSource, in: moveWorkspaceA))
        moveEngine.removeWindow(token: unrelatedMoveWindow.token, in: moveWorkspaceB)
        XCTAssertNotNil(moveEngine.interactiveMove)
        moveEngine.removeWindow(token: moveSource.token, in: moveWorkspaceA)
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspaceA = WorkspaceDescriptor.ID()
        let resizeWorkspaceB = WorkspaceDescriptor.ID()
        let resizeSource = addWindow(resizeEngine, pid: 1_011, to: resizeWorkspaceA)
        let unrelatedResizeWindow = addWindow(resizeEngine, pid: 1_012, to: resizeWorkspaceB)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeSource, in: resizeWorkspaceA))
        resizeEngine.removeWindow(token: unrelatedResizeWindow.token, in: resizeWorkspaceB)
        XCTAssertNotNil(resizeEngine.interactiveResize)
        resizeEngine.removeWindow(token: resizeSource.token, in: resizeWorkspaceA)
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testBatchRemovalClearsMatchingMoveAndResizeSessions() {
        let moveEngine = NiriLayoutEngine()
        let moveWorkspace = WorkspaceDescriptor.ID()
        let moveSource = addWindow(moveEngine, pid: 1_013, to: moveWorkspace)
        _ = addWindow(moveEngine, pid: 1_013, windowId: 2, to: moveWorkspace, after: moveSource)
        XCTAssertTrue(beginMove(moveEngine, window: moveSource, in: moveWorkspace))
        _ = removeWindows([moveSource.token], from: moveEngine, in: moveWorkspace)
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspace = WorkspaceDescriptor.ID()
        let resizeSource = addWindow(resizeEngine, pid: 1_014, to: resizeWorkspace)
        _ = addWindow(resizeEngine, pid: 1_014, windowId: 2, to: resizeWorkspace, after: resizeSource)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeSource, in: resizeWorkspace))
        _ = removeWindows([resizeSource.token], from: resizeEngine, in: resizeWorkspace)
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testWindowTransferClearsMatchingMoveSession() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_015, to: workspaceA)
        _ = addWindow(engine, pid: 1_015, windowId: 2, to: workspaceA, after: source)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceB))
    }

    func testWindowTransferClearsMatchingResizeSession() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_016, to: workspaceA)
        _ = addWindow(engine, pid: 1_016, windowId: 2, to: workspaceA, after: source)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceB))
    }

    func testColumnTransferClearsMatchingMoveSession() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_017, to: workspaceA)
        let column = try XCTUnwrap(engine.columns(in: workspaceA).first)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveColumnToWorkspace(
                column,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState,
                targetOrientation: .horizontal
            )
        )
        XCTAssertNil(engine.interactiveMove)
        XCTAssertTrue(beginMove(engine, window: source, in: workspaceB))
    }

    func testColumnTransferClearsMatchingResizeSession() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let source = addWindow(engine, pid: 1_018, to: workspaceA)
        let column = try XCTUnwrap(engine.columns(in: workspaceA).first)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveColumnToWorkspace(
                column,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState,
                targetOrientation: .horizontal
            )
        )
        XCTAssertNil(engine.interactiveResize)
        XCTAssertTrue(beginResize(engine, window: source, in: workspaceB))
    }

    func testSuccessfulRestoreCancelsMoveAndResizeButNoOpRestorePreservesThem() {
        let firstToken = WindowToken(pid: 1_020, windowId: 1)
        let secondToken = WindowToken(pid: 1_020, windowId: 2)
        let donor = NiriLayoutEngine()
        let donorWorkspace = WorkspaceDescriptor.ID()
        let donorFirst = donor.addWindow(token: firstToken, to: donorWorkspace, afterSelection: nil)
        _ = donor.addWindow(token: secondToken, to: donorWorkspace, afterSelection: donorFirst.id)
        let placements = donor.persistedPlacements(in: donorWorkspace)

        let moveEngine = NiriLayoutEngine()
        let moveWorkspace = WorkspaceDescriptor.ID()
        let moveWindow = moveEngine.addWindow(token: firstToken, to: moveWorkspace, afterSelection: nil)
        XCTAssertTrue(beginMove(moveEngine, window: moveWindow, in: moveWorkspace))
        XCTAssertFalse(moveEngine.restoreInitialPlacements(placements, matching: [firstToken], in: moveWorkspace))
        XCTAssertNotNil(moveEngine.interactiveMove)
        XCTAssertTrue(
            moveEngine.restoreInitialPlacements(placements, matching: [firstToken, secondToken], in: moveWorkspace)
        )
        XCTAssertNil(moveEngine.interactiveMove)

        let resizeEngine = NiriLayoutEngine()
        let resizeWorkspace = WorkspaceDescriptor.ID()
        let resizeWindow = resizeEngine.addWindow(token: firstToken, to: resizeWorkspace, afterSelection: nil)
        XCTAssertTrue(beginResize(resizeEngine, window: resizeWindow, in: resizeWorkspace))
        XCTAssertFalse(resizeEngine.restoreInitialPlacements(placements, matching: [firstToken], in: resizeWorkspace))
        XCTAssertNotNil(resizeEngine.interactiveResize)
        XCTAssertTrue(
            resizeEngine.restoreInitialPlacements(
                placements,
                matching: [firstToken, secondToken],
                in: resizeWorkspace
            )
        )
        XCTAssertNil(resizeEngine.interactiveResize)
    }

    func testRekeyKeepsInteractiveMoveHandleCurrent() throws {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 1_019, windowId: 1)
        let newToken = WindowToken(pid: 1_019, windowId: 101)
        let source = engine.addWindow(token: oldToken, to: workspace, afterSelection: nil)
        let target = addWindow(engine, pid: 1_019, windowId: 2, to: workspace, after: source)
        let moveHandle = source.handle
        XCTAssertTrue(beginMove(engine, window: source, handle: moveHandle, in: workspace))

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspace))

        XCTAssertEqual(source.token, newToken)
        XCTAssertEqual(moveHandle.token, newToken)
        XCTAssertEqual(engine.interactiveMove?.windowHandle.token, newToken)
        let targetFrame = try XCTUnwrap(layout(engine, in: workspace)[target.token])
        XCTAssertNotNil(
            engine.interactiveMoveUpdate(currentLocation: targetFrame.center)
        )
    }
}

final class NiriInteractionOrientationTests: NiriInteractionTestCase {
    func testHorizontalLeftResizeRebasesViewportByWidthDelta() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 1_031, to: workspaceId)
        let frame = try XCTUnwrap(layout(engine, in: workspaceId)[window.token])
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        var state = ViewportState()
        state.jumpOffset(to: 75)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .left,
                startLocation: CGPoint(x: frame.minX, y: frame.midY),
                in: workspaceId,
                orientation: .horizontal,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frame.minX + 100, y: frame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0),
                viewportState: { mutate in mutate(&state) }
            )
        )

        XCTAssertEqual(column.cachedWidth, frame.width - 100, accuracy: 0.001)
        XCTAssertEqual(state.viewOffset, -25, accuracy: 0.001)
    }

    func testHorizontalBeforeInsertionPreviewStaysBeforeTarget() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 1_035, to: workspaceId)
        let second = addWindow(engine, pid: 1_035, windowId: 2, to: workspaceId, after: first)
        let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspaceId))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                second,
                into: column,
                enteringFrom: .down,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .horizontal
            )
        )
        let frames = layout(engine, in: workspaceId, state: state)
        let targetFrame = try XCTUnwrap(frames[first.token])
        let dropFrame = try XCTUnwrap(
            engine.insertionDropzoneFrame(
                targetWindowId: first.id,
                position: .before,
                in: workspaceId,
                gaps: 0,
                orientation: .horizontal
            )
        )

        XCTAssertEqual(dropFrame.minY, targetFrame.minY, accuracy: 0.001)
    }

    func testPortraitInteractiveInsertKeepsBeginOrientationWhenMonitorChanges() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: .init(displayId: 41_031),
            displayId: 41_031,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Interaction Orientation"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .vertical]
        )
        let source = addWindow(engine, pid: 1_030, to: workspaceId)
        let target = addWindow(engine, pid: 1_030, windowId: 2, to: workspaceId, after: source)
        var state = ViewportState()
        let frames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let sourceFrame = try XCTUnwrap(frames[source.token])
        let targetFrame = try XCTUnwrap(frames[target.token])

        XCTAssertTrue(
            engine.interactiveMoveBegin(
                windowId: source.id,
                windowHandle: source.handle,
                startLocation: sourceFrame.center,
                isInsertMode: true,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .vertical
            )
        )

        let beforeLocation = CGPoint(
            x: targetFrame.minX + targetFrame.width * 0.25,
            y: targetFrame.midY
        )
        let hoverTarget = try XCTUnwrap(
            engine.interactiveMoveUpdate(currentLocation: beforeLocation)
        )
        guard case let .window(nodeId, _, insertPosition) = hoverTarget else {
            return XCTFail("Expected a window hover target")
        }
        XCTAssertEqual(nodeId, target.id)
        XCTAssertEqual(insertPosition, .before)

        let dropFrame = try XCTUnwrap(
            engine.insertionDropzoneFrame(
                targetWindowId: target.id,
                position: insertPosition,
                in: workspaceId,
                gaps: 0,
                orientation: .vertical
            )
        )
        XCTAssertEqual(dropFrame.height, targetFrame.height, accuracy: 0.001)
        XCTAssertLessThan(dropFrame.width, targetFrame.width)
        XCTAssertEqual(dropFrame.minX, targetFrame.minX, accuracy: 0.001)

        engine.updateMonitorOrientations([monitor.id: .horizontal])
        XCTAssertEqual(engine.monitor(for: monitor.id)?.orientation, .horizontal)
        XCTAssertEqual(engine.interactiveMove?.orientation, .vertical)
        XCTAssertTrue(
            engine.interactiveMoveEnd(
                at: beforeLocation,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: 0
            )
        )
        let movedFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        XCTAssertLessThan(
            try XCTUnwrap(movedFrames[source.token]).midX,
            try XCTUnwrap(movedFrames[target.token]).midX
        )
    }

    func testPortraitLeftResizeChangesRenderedWindowWidthWithoutRebasingViewport() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 1_032, to: workspaceId)
        let frames = engine.calculateLayout(
            state: ViewportState(),
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let frame = try XCTUnwrap(frames[window.token])
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        var state = ViewportState()
        state.jumpOffset(to: -140)

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .left,
                startLocation: CGPoint(x: frame.minX, y: frame.midY),
                in: workspaceId,
                orientation: .vertical,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frame.minX + 100, y: frame.midY),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0),
                viewportState: { mutate in mutate(&state) }
            )
        )

        XCTAssertEqual(window.windowWidth, .fixed(frame.width - 100))
        XCTAssertEqual(column.cachedWidth, 0, accuracy: 0.001)
        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(state.viewOffset, -140, accuracy: 0.001)
        let resizedFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(resizedFrames[window.token]).width,
            frame.width - 100,
            accuracy: 0.001
        )
    }

    func testPortraitExpandToAvailablePrimarySpanPreservesViewOrigin() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 1_033, to: workspaceId)
        let second = addWindow(engine, pid: 1_033, windowId: 2, to: workspaceId, after: first)
        let portraitFrame = CGRect(x: 0, y: 0, width: 900, height: 1600)
        var state = ViewportState()
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: portraitFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let columns = engine.columns(in: workspaceId)
        let targetColumn = try XCTUnwrap(columns.last)
        XCTAssertEqual(targetColumn.cachedHeight, 800, accuracy: 0.001)
        XCTAssertFalse(targetColumn.isFullHeight)
        for column in columns {
            column.cachedWidth = 300
        }
        state.activeColumnIndex = 1
        state.selectedNodeId = second.id
        state.jumpOffset(to: -100)
        let viewOriginBefore = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns,
            gap: 0,
            sizeKeyPath: \.cachedHeight
        ) + state.viewOffset

        engine.expandContainerToAvailablePrimarySpan(
            targetColumn,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )

        XCTAssertEqual(targetColumn.cachedHeight, 1600, accuracy: 0.001)
        XCTAssertTrue(targetColumn.isFullHeight)
        XCTAssertEqual(state.viewOffset, -100, accuracy: 0.001)
        let viewOriginAfter = state.containerPosition(
            at: state.activeColumnIndex,
            containers: columns,
            gap: 0,
            sizeKeyPath: \.cachedHeight
        ) + state.viewOffset
        XCTAssertEqual(viewOriginAfter, viewOriginBefore, accuracy: 0.001)
    }

    func testPortraitFullSpanBeforeActiveContainerRebasesViewOrigin() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 1_036, to: workspaceId)
        let second = addWindow(engine, pid: 1_036, windowId: 2, to: workspaceId, after: first)
        let portraitFrame = CGRect(x: 0, y: 0, width: 900, height: 1600)
        var state = ViewportState()
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: portraitFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let containers = engine.columns(in: workspaceId)
        let firstContainer = try XCTUnwrap(containers.first)
        state.activeColumnIndex = 1
        state.selectedNodeId = second.id
        state.jumpOffset(to: -100)
        let viewOriginBefore = state.containerPosition(
            at: state.activeColumnIndex,
            containers: containers,
            gap: 0,
            sizeKeyPath: \.cachedHeight
        ) + state.viewOffset

        engine.toggleContainerFullPrimarySpan(
            firstContainer,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )

        XCTAssertEqual(firstContainer.cachedHeight, 1600, accuracy: 0.001)
        XCTAssertEqual(state.viewOffset, -900, accuracy: 0.001)
        let viewOriginAfter = state.containerPosition(
            at: state.activeColumnIndex,
            containers: containers,
            gap: 0,
            sizeKeyPath: \.cachedHeight
        ) + state.viewOffset
        XCTAssertEqual(viewOriginAfter, viewOriginBefore, accuracy: 0.001)
    }

    func testPortraitFullSpanHonorsAlwaysCenterPolicy() throws {
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = .always
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 1_037, to: workspaceId)
        let second = addWindow(engine, pid: 1_037, windowId: 2, to: workspaceId, after: first)
        let portraitFrame = CGRect(x: 0, y: 0, width: 900, height: 1600)
        var state = ViewportState()
        _ = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: portraitFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let targetContainer = try XCTUnwrap(engine.column(of: second))
        state.activeColumnIndex = 1
        state.selectedNodeId = second.id
        state.jumpOffset(to: -100)

        engine.toggleContainerFullPrimarySpan(
            targetContainer,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )

        XCTAssertEqual(targetContainer.cachedHeight, 1600, accuracy: 0.001)
        XCTAssertEqual(state.viewOffset, 0, accuracy: 0.001)
    }

    func testPortraitColumnTransferReresolvesHeightForShorterTarget() throws {
        let engine = NiriLayoutEngine()
        let sourceWorkspaceId = WorkspaceDescriptor.ID()
        let targetWorkspaceId = WorkspaceDescriptor.ID()
        let movedWindow = addWindow(engine, pid: 1_034, to: sourceWorkspaceId)
        _ = addWindow(engine, pid: 1_035, to: targetWorkspaceId)
        let movedColumn = try XCTUnwrap(
            engine.findColumn(containing: movedWindow, in: sourceWorkspaceId)
        )
        movedColumn.height = .proportion(1)
        movedColumn.resolveAndCacheHeight(workingAreaHeight: 1_600, gaps: 0)
        XCTAssertEqual(movedColumn.cachedHeight, 1_600, accuracy: 0.001)

        var sourceState = ViewportState()
        var targetState = ViewportState()
        XCTAssertNotNil(
            engine.moveColumnToWorkspace(
                movedColumn,
                from: sourceWorkspaceId,
                to: targetWorkspaceId,
                sourceState: &sourceState,
                targetState: &targetState,
                targetOrientation: .vertical
            )
        )
        XCTAssertEqual(movedColumn.cachedHeight, 0, accuracy: 0.001)

        let targetFrame = CGRect(x: 0, y: 0, width: 900, height: 900)
        engine.ensureSelectionVisible(
            node: movedWindow,
            in: targetWorkspaceId,
            motion: .disabled,
            state: &targetState,
            workingFrame: targetFrame,
            gaps: 0,
            orientation: .vertical
        )

        XCTAssertEqual(movedColumn.cachedHeight, targetFrame.height, accuracy: 0.001)
        let frames = engine.calculateLayout(
            state: targetState,
            workspaceId: targetWorkspaceId,
            monitorFrame: targetFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
        let movedFrame = try XCTUnwrap(frames[movedWindow.token])
        XCTAssertGreaterThanOrEqual(movedFrame.minY, targetFrame.minY - 0.001)
        XCTAssertLessThanOrEqual(movedFrame.maxY, targetFrame.maxY + 0.001)
    }
}
