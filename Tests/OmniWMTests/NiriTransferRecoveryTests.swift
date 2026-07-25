// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

private struct NiriColumnCollisionFixture {
    let engine: NiriLayoutEngine
    let sourceWorkspace: WorkspaceDescriptor.ID
    let targetWorkspace: WorkspaceDescriptor.ID
    let sharedToken: WindowToken
    let sourceOnlyToken: WindowToken
    let targetOnlyToken: WindowToken
    let sourceSharedNode: NiriWindow
    let sourceOnlyNode: NiriWindow
    let staleSharedNode: NiriWindow
    let targetOnlyNode: NiriWindow
    let sourceColumn: NiriContainer
}

@MainActor
final class NiriTransferRecoveryTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testFailedScopedRekeyIsRepairedBySyncWithoutMutatingForeignWorkspace() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 947, windowId: 1)
        let newToken = WindowToken(pid: 947, windowId: 2)
        let foreignToken = WindowToken(pid: 947, windowId: 3)
        let oldNode = engine.addWindow(token: oldToken, to: workspaceA, afterSelection: nil)
        let foreignNode = engine.addWindow(token: foreignToken, to: workspaceB, afterSelection: nil)
        let foreignRoot = try XCTUnwrap(engine.root(for: workspaceB))

        XCTAssertFalse(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceB))
        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceA) === oldNode)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
        XCTAssertEqual(engine.syncWindows([newToken], in: workspaceA, selectedNodeId: nil), [oldToken])

        let repairedNode = try XCTUnwrap(engine.findNode(for: newToken, in: workspaceA))
        XCTAssertNil(engine.findNode(for: oldToken, in: workspaceA))
        XCTAssertNil(oldNode.parent)
        assertSingleIndexedOccurrence(newToken, is: repairedNode, in: workspaceA, engine: engine)
        XCTAssertTrue(engine.root(for: workspaceB) === foreignRoot)
        XCTAssertTrue(engine.findNode(for: foreignToken, in: workspaceB) === foreignNode)
        XCTAssertEqual(foreignRoot.allWindows.count, 1)
        XCTAssertTrue(foreignRoot.allWindows.first === foreignNode)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testWindowTransferPrunesTargetDuplicateAndMovesSourceIdentity() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 944, windowId: 1)
        let nodeInA = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let staleNodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)
        var sourceState = ViewportState()
        var targetState = ViewportState()
        sourceState.selectedNodeId = nodeInA.id
        targetState.selectedNodeId = staleNodeInB.id

        let result = engine.moveWindowToWorkspace(
            nodeInA,
            from: workspaceA,
            to: workspaceB,
            sourceState: &sourceState,
            targetState: &targetState
        )

        XCTAssertNotNil(result)
        XCTAssertNil(engine.findNode(for: token, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === nodeInA)
        XCTAssertNil(staleNodeInB.parent)
        XCTAssertNil(sourceState.selectedNodeId)
        XCTAssertEqual(targetState.selectedNodeId, nodeInA.id)
        assertSelectionValid(targetState.selectedNodeId, in: workspaceB, engine: engine)
        assertSingleIndexedOccurrence(token, is: nodeInA, in: workspaceB, engine: engine)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
        XCTAssertTrue(engine.syncWindows([token], in: workspaceB, selectedNodeId: targetState.selectedNodeId).isEmpty)

        let removal = removeWindow(token, from: engine, in: workspaceB, state: &targetState)
        XCTAssertEqual(removal.removedTokens, [token])
        XCTAssertNil(engine.findNode(for: token, in: workspaceB))
        XCTAssertTrue(engine.root(for: workspaceB)?.allWindows.isEmpty == true)
        assertSelectionValid(targetState.selectedNodeId, in: workspaceB, engine: engine)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testWindowTransferPreservesDurableWidthStateAndInvalidatesTargetGeometry() throws {
        let fixture = try makeStackedColumnFixture(pid: 948)
        let targetWorkspace = WorkspaceDescriptor.ID()
        let sourceAnimation = SpringAnimation(
            from: 720,
            to: 760,
            startTime: 0,
            config: .niriWindowMovement,
            displayRefreshRate: 60
        )
        fixture.column.width = .proportion(0.5)
        fixture.column.presetWidthIdx = 1
        fixture.column.hasManualSingleWindowWidthOverride = true
        fixture.column.cachedWidth = 720
        fixture.column.widthAnimation = sourceAnimation
        fixture.column.targetWidth = 760
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            fixture.engine.moveWindowToWorkspace(
                fixture.first,
                from: fixture.workspaceId,
                to: targetWorkspace,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )

        let targetColumn = try XCTUnwrap(
            fixture.engine.findColumn(containing: fixture.first, in: targetWorkspace)
        )
        XCTAssertEqual(targetColumn.width, .proportion(0.5))
        XCTAssertEqual(targetColumn.presetWidthIdx, 1)
        XCTAssertFalse(targetColumn.isFullWidth)
        XCTAssertNil(targetColumn.savedWidth)
        XCTAssertTrue(targetColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(targetColumn.cachedWidth, 0)
        XCTAssertNil(targetColumn.widthAnimation)
        XCTAssertNil(targetColumn.targetWidth)

        XCTAssertTrue(
            fixture.engine.findColumn(containing: fixture.second, in: fixture.workspaceId)
                === fixture.column
        )
        XCTAssertEqual(fixture.column.width, .proportion(0.5))
        XCTAssertEqual(fixture.column.presetWidthIdx, 1)
        XCTAssertTrue(fixture.column.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(fixture.column.cachedWidth, 720)
        XCTAssertTrue(fixture.column.widthAnimation === sourceAnimation)
        XCTAssertEqual(fixture.column.targetWidth, 760)
        assertIndexMatchesTree(fixture.engine, in: fixture.workspaceId)
        assertIndexMatchesTree(fixture.engine, in: targetWorkspace)
    }

    func testWindowTransferPreservesFullWidthRestoreStateWhenRecoveringTargetDuplicate() throws {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let targetWorkspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 949, windowId: 1)
        let source = engine.addWindow(token: token, to: sourceWorkspace, afterSelection: nil)
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: source, in: sourceWorkspace))
        sourceColumn.width = .fixed(640)
        sourceColumn.presetWidthIdx = nil
        sourceColumn.isFullWidth = true
        sourceColumn.savedWidth = .fixed(640)
        sourceColumn.hasManualSingleWindowWidthOverride = true
        sourceColumn.cachedWidth = 1600
        sourceColumn.widthAnimation = SpringAnimation(
            from: 1200,
            to: 1600,
            startTime: 0,
            config: .niriWindowMovement,
            displayRefreshRate: 60
        )
        sourceColumn.targetWidth = 1600

        let staleTarget = engine.addWindow(token: token, to: targetWorkspace, afterSelection: nil)
        let targetRoot = try XCTUnwrap(engine.root(for: targetWorkspace))
        let claimedPlaceholder = NiriContainer()
        claimedPlaceholder.cachedWidth = 480
        claimedPlaceholder.widthAnimation = SpringAnimation(
            from: 400,
            to: 480,
            startTime: 0,
            config: .niriWindowMovement,
            displayRefreshRate: 60
        )
        claimedPlaceholder.targetWidth = 480
        targetRoot.appendChild(claimedPlaceholder)
        let redundantPlaceholder = NiriContainer()
        targetRoot.appendChild(redundantPlaceholder)
        var sourceState = ViewportState()
        var targetState = ViewportState()

        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                source,
                from: sourceWorkspace,
                to: targetWorkspace,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )

        let targetColumn = try XCTUnwrap(engine.findColumn(containing: source, in: targetWorkspace))
        XCTAssertTrue(targetColumn === claimedPlaceholder)
        XCTAssertNil(redundantPlaceholder.parent)
        XCTAssertNil(staleTarget.parent)
        XCTAssertEqual(targetColumn.width, .fixed(640))
        XCTAssertNil(targetColumn.presetWidthIdx)
        XCTAssertTrue(targetColumn.isFullWidth)
        XCTAssertEqual(targetColumn.savedWidth, .fixed(640))
        XCTAssertTrue(targetColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(targetColumn.cachedWidth, 0)
        XCTAssertNil(targetColumn.widthAnimation)
        XCTAssertNil(targetColumn.targetWidth)
        assertSingleIndexedOccurrence(token, is: source, in: targetWorkspace, engine: engine)
        assertIndexMatchesTree(engine, in: sourceWorkspace)
        assertIndexMatchesTree(engine, in: targetWorkspace)
    }

    func testNewContainerSizingPolicySelectsWorkspaceDefaultOrSourceState() throws {
        let defaultFixture = try makeStackedColumnFixture(pid: 950)
        defaultFixture.column.width = .proportion(2.0 / 3.0)
        defaultFixture.column.presetWidthIdx = 2
        defaultFixture.column.hasManualSingleWindowWidthOverride = true
        var defaultState = ViewportState()

        XCTAssertTrue(
            defaultFixture.engine.insertWindowInNewColumn(
                defaultFixture.first,
                insertIndex: 1,
                in: defaultFixture.workspaceId,
                motion: .disabled,
                state: &defaultState,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .horizontal,
                sizingPolicy: .workspaceDefault
            )
        )

        let defaultColumn = try XCTUnwrap(
            defaultFixture.engine.findColumn(containing: defaultFixture.first, in: defaultFixture.workspaceId)
        )
        XCTAssertEqual(defaultColumn.width, .proportion(0.5))
        XCTAssertEqual(defaultColumn.presetWidthIdx, 1)
        XCTAssertFalse(defaultColumn.hasManualSingleWindowWidthOverride)

        let inheritedFixture = try makeStackedColumnFixture(pid: 951)
        inheritedFixture.column.width = .proportion(2.0 / 3.0)
        inheritedFixture.column.presetWidthIdx = 2
        inheritedFixture.column.hasManualSingleWindowWidthOverride = true
        var inheritedState = ViewportState()

        XCTAssertTrue(
            inheritedFixture.engine.insertWindowInNewColumn(
                inheritedFixture.first,
                insertIndex: 1,
                in: inheritedFixture.workspaceId,
                motion: .disabled,
                state: &inheritedState,
                workingFrame: workingFrame,
                gaps: 0,
                orientation: .horizontal,
                sizingPolicy: .inheritSource
            )
        )

        let inheritedColumn = try XCTUnwrap(
            inheritedFixture.engine.findColumn(
                containing: inheritedFixture.first,
                in: inheritedFixture.workspaceId
            )
        )
        XCTAssertEqual(inheritedColumn.width, .proportion(2.0 / 3.0))
        XCTAssertEqual(inheritedColumn.presetWidthIdx, 2)
        XCTAssertTrue(inheritedColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(inheritedFixture.column.width, .proportion(2.0 / 3.0))
        XCTAssertEqual(inheritedFixture.column.presetWidthIdx, 2)
        XCTAssertTrue(inheritedFixture.column.hasManualSingleWindowWidthOverride)
    }

    func testColumnTransferPrunesOverlappingTargetTokenAndPreservesOtherTargetWindow() throws {
        let fixture = try makeColumnCollisionFixture()
        var sourceState = ViewportState()
        var targetState = ViewportState()
        sourceState.selectedNodeId = fixture.sourceSharedNode.id
        targetState.selectedNodeId = fixture.targetOnlyNode.id

        let result = fixture.engine.moveColumnToWorkspace(
            fixture.sourceColumn,
            from: fixture.sourceWorkspace,
            to: fixture.targetWorkspace,
            sourceState: &sourceState,
            targetState: &targetState,
            targetOrientation: .horizontal
        )

        XCTAssertNotNil(result)
        assertColumnTransfer(fixture, sourceState: sourceState, targetState: targetState)
        XCTAssertTrue(
            fixture.engine.syncWindows(
                [fixture.sharedToken, fixture.sourceOnlyToken, fixture.targetOnlyToken],
                in: fixture.targetWorkspace,
                selectedNodeId: targetState.selectedNodeId
            ).isEmpty
        )

        let removal = removeWindow(
            fixture.sharedToken,
            from: fixture.engine,
            in: fixture.targetWorkspace,
            state: &targetState
        )
        XCTAssertEqual(removal.removedTokens, [fixture.sharedToken])
        XCTAssertNil(fixture.engine.findNode(for: fixture.sharedToken, in: fixture.targetWorkspace))
        XCTAssertTrue(
            fixture.engine.findNode(for: fixture.sourceOnlyToken, in: fixture.targetWorkspace)
                === fixture.sourceOnlyNode
        )
        XCTAssertTrue(
            fixture.engine.findNode(for: fixture.targetOnlyToken, in: fixture.targetWorkspace)
                === fixture.targetOnlyNode
        )
        assertSelectionValid(targetState.selectedNodeId, in: fixture.targetWorkspace, engine: fixture.engine)
        assertIndexMatchesTree(fixture.engine, in: fixture.targetWorkspace)
    }

    func testRestoreDeduplicatesRepeatedTokenInputAndLeavesNoOrphan() throws {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let restoredWorkspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 946, windowId: 1)
        let sourceNode = engine.addWindow(token: token, to: sourceWorkspace, afterSelection: nil)
        let placements = engine.persistedPlacements(in: sourceWorkspace)

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [token, token], in: restoredWorkspace))

        let restoredNode = try XCTUnwrap(engine.findNode(for: token, in: restoredWorkspace))
        XCTAssertFalse(restoredNode === sourceNode)
        XCTAssertTrue(engine.findNode(for: token, in: sourceWorkspace) === sourceNode)
        assertSingleIndexedOccurrence(token, is: sourceNode, in: sourceWorkspace, engine: engine)
        assertSingleIndexedOccurrence(token, is: restoredNode, in: restoredWorkspace, engine: engine)
        assertIndexMatchesTree(engine, in: sourceWorkspace)
        assertIndexMatchesTree(engine, in: restoredWorkspace)

        var restoredState = ViewportState()
        restoredState.selectedNodeId = restoredNode.id
        XCTAssertTrue(
            engine.syncWindows([token], in: restoredWorkspace, selectedNodeId: restoredState.selectedNodeId).isEmpty
        )
        let removal = removeWindow(token, from: engine, in: restoredWorkspace, state: &restoredState)
        XCTAssertEqual(removal.removedTokens, [token])
        XCTAssertNil(engine.findNode(for: token, in: restoredWorkspace))
        XCTAssertTrue(engine.root(for: restoredWorkspace)?.allWindows.isEmpty == true)
        XCTAssertTrue(engine.findNode(for: token, in: sourceWorkspace) === sourceNode)
        assertSelectionValid(restoredState.selectedNodeId, in: restoredWorkspace, engine: engine)
        assertIndexMatchesTree(engine, in: sourceWorkspace)
        assertIndexMatchesTree(engine, in: restoredWorkspace)
    }

    private func makeColumnCollisionFixture() throws -> NiriColumnCollisionFixture {
        let engine = NiriLayoutEngine()
        let sourceWorkspace = WorkspaceDescriptor.ID()
        let targetWorkspace = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 945, windowId: 1)
        let sourceOnlyToken = WindowToken(pid: 945, windowId: 2)
        let targetOnlyToken = WindowToken(pid: 945, windowId: 3)
        let sourceSharedNode = engine.addWindow(token: sharedToken, to: sourceWorkspace, afterSelection: nil)
        let sourceOnlyNode = engine.addWindow(token: sourceOnlyToken, to: sourceWorkspace, afterSelection: nil)
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: sourceSharedNode, in: sourceWorkspace))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                sourceOnlyNode,
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
        let staleSharedNode = engine.addWindow(token: sharedToken, to: targetWorkspace, afterSelection: nil)
        let targetOnlyNode = engine.addWindow(token: targetOnlyToken, to: targetWorkspace, afterSelection: nil)
        return NiriColumnCollisionFixture(
            engine: engine,
            sourceWorkspace: sourceWorkspace,
            targetWorkspace: targetWorkspace,
            sharedToken: sharedToken,
            sourceOnlyToken: sourceOnlyToken,
            targetOnlyToken: targetOnlyToken,
            sourceSharedNode: sourceSharedNode,
            sourceOnlyNode: sourceOnlyNode,
            staleSharedNode: staleSharedNode,
            targetOnlyNode: targetOnlyNode,
            sourceColumn: sourceColumn
        )
    }

    private func makeStackedColumnFixture(pid: pid_t) throws -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        first: NiriWindow,
        second: NiriWindow,
        column: NiriContainer
    ) {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = engine.addWindow(
            token: WindowToken(pid: pid, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let second = engine.addWindow(
            token: WindowToken(pid: pid, windowId: 2),
            to: workspaceId,
            afterSelection: first.id
        )
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
        return (engine, workspaceId, first, second, column)
    }

    private func assertColumnTransfer(
        _ fixture: NiriColumnCollisionFixture,
        sourceState: ViewportState,
        targetState: ViewportState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let engine = fixture.engine
        XCTAssertNil(engine.findNode(for: fixture.sharedToken, in: fixture.sourceWorkspace), file: file, line: line)
        XCTAssertNil(engine.findNode(for: fixture.sourceOnlyToken, in: fixture.sourceWorkspace), file: file, line: line)
        XCTAssertTrue(
            engine.findNode(for: fixture.sharedToken, in: fixture.targetWorkspace) === fixture.sourceSharedNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findNode(for: fixture.sourceOnlyToken, in: fixture.targetWorkspace) === fixture.sourceOnlyNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findNode(for: fixture.targetOnlyToken, in: fixture.targetWorkspace) === fixture.targetOnlyNode,
            file: file,
            line: line
        )
        XCTAssertTrue(
            engine.findColumn(containing: fixture.sourceSharedNode, in: fixture.targetWorkspace)
                === fixture.sourceColumn,
            file: file,
            line: line
        )
        XCTAssertNil(fixture.staleSharedNode.parent, file: file, line: line)
        XCTAssertNil(sourceState.selectedNodeId, file: file, line: line)
        XCTAssertEqual(targetState.selectedNodeId, fixture.sourceSharedNode.id, file: file, line: line)
        assertSelectionValid(targetState.selectedNodeId, in: fixture.targetWorkspace, engine: engine)
        assertSingleIndexedOccurrence(
            fixture.sharedToken,
            is: fixture.sourceSharedNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertSingleIndexedOccurrence(
            fixture.sourceOnlyToken,
            is: fixture.sourceOnlyNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertSingleIndexedOccurrence(
            fixture.targetOnlyToken,
            is: fixture.targetOnlyNode,
            in: fixture.targetWorkspace,
            engine: engine
        )
        assertIndexMatchesTree(engine, in: fixture.sourceWorkspace)
        assertIndexMatchesTree(engine, in: fixture.targetWorkspace)
    }

    private func removeWindow(
        _ token: WindowToken,
        from engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> NiriLayoutEngine.NiriRemovalResult {
        engine.removeWindows(
            [token],
            in: workspaceId,
            state: &state,
            motion: .disabled,
            workingFrame: workingFrame,
            gaps: 0,
            orientation: .horizontal,
            selectedNodeId: state.selectedNodeId,
            removedNodeIds: []
        )
    }

    private func assertIndexMatchesTree(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let state = engine.states[workspaceId] else {
            XCTFail("missing workspace state", file: file, line: line)
            return
        }
        let treeWindows = state.root.allWindows
        XCTAssertEqual(treeWindows.count, state.nodesByToken.count, file: file, line: line)
        XCTAssertEqual(Set(treeWindows.map(\.token)), Set(state.nodesByToken.keys), file: file, line: line)
        for window in treeWindows {
            XCTAssertTrue(state.nodesByToken[window.token] === window, file: file, line: line)
        }
    }

    private func assertSingleIndexedOccurrence(
        _ token: WindowToken,
        is expectedNode: NiriWindow,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let state = engine.states[workspaceId] else {
            XCTFail("missing workspace state", file: file, line: line)
            return
        }
        let occurrences = state.root.allWindows.filter { $0.token == token }
        XCTAssertEqual(occurrences.count, 1, file: file, line: line)
        XCTAssertTrue(occurrences.first === expectedNode, file: file, line: line)
        XCTAssertTrue(state.nodesByToken[token] === expectedNode, file: file, line: line)
    }

    private func assertSelectionValid(
        _ nodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let nodeId else { return }
        XCTAssertNotNil(engine.findNode(by: nodeId, in: workspaceId), file: file, line: line)
    }
}
