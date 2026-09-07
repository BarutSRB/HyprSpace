// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriWorkspaceIsolationTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testSyncRemovalAffectsOnlyRequestedRootWhenDuplicateAddedToRequestedRootFirst() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 930, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)

        let removed = engine.syncWindows([], in: workspaceA, selectedNodeId: nil)

        XCTAssertEqual(removed, [token])
        XCTAssertNil(engine.findNode(for: token, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === nodeInB)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testSyncRemovalAffectsOnlyRequestedRootWhenDuplicateAddedToOtherRootFirst() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 930, windowId: 2)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)
        _ = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)

        let removed = engine.syncWindows([], in: workspaceA, selectedNodeId: nil)

        XCTAssertEqual(removed, [token])
        XCTAssertNil(engine.findNode(for: token, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === nodeInB)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testBatchRemovalPreservesOtherRootNodeAndIndex() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 931, windowId: 1)
        let localToken = WindowToken(pid: 931, windowId: 2)
        _ = engine.addWindow(token: sharedToken, to: workspaceA, afterSelection: nil)
        _ = engine.addWindow(token: localToken, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: sharedToken, to: workspaceB, afterSelection: nil)

        let result = removeWindowsBatch(engine, tokens: [sharedToken], in: workspaceA)

        XCTAssertEqual(result.removedTokens, [sharedToken])
        XCTAssertNil(engine.findNode(for: sharedToken, in: workspaceA))
        XCTAssertNotNil(engine.findNode(for: localToken, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceB) === nodeInB)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testWorkspaceDeletionPreservesOtherRootNodeAndIndex() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 932, windowId: 1)
        _ = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)

        engine.removeWorkspaceState(workspaceA)

        XCTAssertNil(engine.root(for: workspaceA))
        XCTAssertNil(engine.states[workspaceA])
        XCTAssertTrue(engine.findNode(for: token, in: workspaceB) === nodeInB)
        XCTAssertEqual(engine.workspaceIds(containing: token), [workspaceB])
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testFocusedForeignDuplicateCannotCreateOrphanColumn() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let foreignToken = WindowToken(pid: 933, windowId: 1)
        let newToken = WindowToken(pid: 933, windowId: 2)
        let nodeInB = engine.addWindow(token: foreignToken, to: workspaceB, afterSelection: nil)

        let newNode = engine.addWindow(
            token: newToken,
            to: workspaceA,
            afterSelection: nil,
            focusedToken: foreignToken
        )

        XCTAssertNotNil(engine.findColumn(containing: newNode, in: workspaceA))
        XCTAssertEqual(engine.columns(in: workspaceA).count, 1)
        XCTAssertEqual(engine.columns(in: workspaceB).count, 1)
        XCTAssertTrue(engine.columns(in: workspaceB).first?.windowNodes.first === nodeInB)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testScopedRekeyRenamesLocallyAndLeavesForeignOldTokenDuplicateUntouched() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 934, windowId: 1)
        let newToken = WindowToken(pid: 934, windowId: 2)
        let nodeInA = engine.addWindow(token: oldToken, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: oldToken, to: workspaceB, afterSelection: nil)

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceA))

        XCTAssertTrue(engine.findNode(for: newToken, in: workspaceA) === nodeInA)
        XCTAssertNil(engine.findNode(for: oldToken, in: workspaceA))
        XCTAssertTrue(engine.findNode(for: oldToken, in: workspaceB) === nodeInB)
        XCTAssertEqual(nodeInB.token, oldToken)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testScopedRekeyCollisionCheckIsWorkspaceLocalForForeignNewTokenDuplicate() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let oldToken = WindowToken(pid: 935, windowId: 1)
        let newToken = WindowToken(pid: 935, windowId: 2)
        let nodeInA = engine.addWindow(token: oldToken, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: newToken, to: workspaceB, afterSelection: nil)

        XCTAssertTrue(engine.rekeyWindow(from: oldToken, to: newToken, in: workspaceA))

        XCTAssertTrue(engine.findNode(for: newToken, in: workspaceA) === nodeInA)
        XCTAssertTrue(engine.findNode(for: newToken, in: workspaceB) === nodeInB)
        XCTAssertEqual(Set(engine.workspaceIds(containing: newToken)), [workspaceA, workspaceB])
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testConstraintsUpdateAffectsOnlyRequestedWorkspace() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 936, windowId: 1)
        let nodeInA = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: .zero,
            isFixed: false
        )

        engine.updateWindowConstraints(for: token, constraints: constraints, in: workspaceA, motion: .enabled)

        XCTAssertEqual(nodeInA.constraints.minSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(nodeInB.constraints, .unconstrained)
    }

    func testDuplicateFullscreenQueriesAreWorkspaceLocal() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 937, windowId: 1)
        let nodeInA = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)

        nodeInA.sizingMode = .fullscreen
        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspaceA))
        XCTAssertFalse(engine.isWindowFullscreen(token, in: workspaceB))

        nodeInA.sizingMode = .normal
        nodeInB.sizingMode = .fullscreen
        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspaceB))
        XCTAssertFalse(engine.isWindowFullscreen(token, in: workspaceA))
    }

    func testRestorePreservesIndependentRootIndexes() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let workspaceC = WorkspaceDescriptor.ID()
        let token1 = WindowToken(pid: 938, windowId: 1)
        let token2 = WindowToken(pid: 938, windowId: 2)
        let node1InA = engine.addWindow(token: token1, to: workspaceA, afterSelection: nil)
        _ = engine.addWindow(token: token2, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token1, to: workspaceB, afterSelection: nil)
        let sourceColumn = engine.column(of: node1InA)
        sourceColumn?.height = .fixed(720)
        sourceColumn?.isFullHeight = true
        sourceColumn?.savedHeight = .proportion(0.6)
        sourceColumn?.hasManualSingleWindowHeightOverride = true
        node1InA.windowWidth = .fixed(420)
        let placements = engine.persistedPlacements(in: workspaceA)

        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [token1, token2], in: workspaceC))

        XCTAssertTrue(engine.findNode(for: token1, in: workspaceA) === node1InA)
        XCTAssertTrue(engine.findNode(for: token1, in: workspaceB) === nodeInB)
        let nodeInC = engine.findNode(for: token1, in: workspaceC)
        let restoredColumn = nodeInC.flatMap { engine.column(of: $0) }
        XCTAssertNotNil(nodeInC)
        XCTAssertFalse(nodeInC === node1InA)
        XCTAssertNotNil(engine.findNode(for: token2, in: workspaceC))
        XCTAssertEqual(restoredColumn?.height, .fixed(720))
        XCTAssertEqual(restoredColumn?.isFullHeight, true)
        XCTAssertEqual(restoredColumn?.savedHeight, .proportion(0.6))
        XCTAssertEqual(restoredColumn?.hasManualSingleWindowHeightOverride, true)
        XCTAssertEqual(nodeInC?.windowWidth, .fixed(420))
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
        assertIndexMatchesTree(engine, in: workspaceC)
    }

    func testFocusRecoveryResolvesWithinRequestedRootOnly() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 939, windowId: 1)
        let localToken = WindowToken(pid: 939, windowId: 2)
        let sharedNodeInA = engine.addWindow(token: sharedToken, to: workspaceA, afterSelection: nil)
        let localNodeInA = engine.addWindow(token: localToken, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: sharedToken, to: workspaceB, afterSelection: nil)

        XCTAssertEqual(
            engine.fallbackSelectionOnRemoval(removing: sharedNodeInA.id, in: workspaceA),
            localNodeInA.id
        )
        XCTAssertEqual(engine.validateSelection(nil, in: workspaceB), nodeInB.id)
        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceB) === nodeInB)
        XCTAssertEqual(engine.columns(in: workspaceB).count, 1)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testActivationCannotMutateAnotherRoot() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let sharedToken = WindowToken(pid: 940, windowId: 1)
        let localToken = WindowToken(pid: 940, windowId: 2)
        _ = engine.addWindow(token: sharedToken, to: workspaceA, afterSelection: nil)
        let localNodeInA = engine.addWindow(token: localToken, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: sharedToken, to: workspaceB, afterSelection: nil)
        let columnInB = try XCTUnwrap(engine.findColumn(containing: nodeInB, in: workspaceB))
        let activeIdxBefore = columnInB.activeTileIdx

        engine.activateWindow(localNodeInA.id, in: workspaceA)

        XCTAssertTrue(engine.findNode(for: sharedToken, in: workspaceB) === nodeInB)
        XCTAssertEqual(columnInB.activeTileIdx, activeIdxBefore)

        engine.activateWindow(nodeInB.id, in: workspaceA)

        XCTAssertEqual(columnInB.activeTileIdx, activeIdxBefore)
        XCTAssertEqual(engine.columns(in: workspaceB).count, 1)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testActivateWindowReconcilesTabbedVisibility() throws {
        let engine = NiriLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = engine.addWindow(
            token: WindowToken(pid: 940, windowId: 11),
            to: workspace,
            afterSelection: nil
        )
        let second = engine.addWindow(
            token: WindowToken(pid: 940, windowId: 12),
            to: workspace,
            afterSelection: first.id
        )
        let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspace))
        let secondColumn = try XCTUnwrap(engine.findColumn(containing: second, in: workspace))
        second.detach()
        secondColumn.remove()
        column.appendChild(second)
        column.displayMode = .tabbed
        column.setActiveTileIdx(0)
        engine.updateTabbedColumnVisibility(column: column)

        XCTAssertFalse(first.isHiddenInTabbedMode)
        XCTAssertTrue(second.isHiddenInTabbedMode)

        engine.activateWindow(second.id, in: workspace)

        XCTAssertEqual(column.activeTileIdx, 1)
        XCTAssertTrue(first.isHiddenInTabbedMode)
        XCTAssertFalse(second.isHiddenInTabbedMode)

        column.displayMode = .normal
        first.isHiddenInTabbedMode = true
        engine.activateWindow(first.id, in: workspace)

        XCTAssertFalse(first.isHiddenInTabbedMode)
        XCTAssertFalse(second.isHiddenInTabbedMode)
    }

    func testFullscreenToggleCannotMutateAnotherRoot() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 941, windowId: 1)
        let nodeInA = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let nodeInB = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)
        var state = ViewportState()

        engine.toggleFullscreen(nodeInA, motion: .disabled, state: &state)

        XCTAssertTrue(nodeInA.isFullscreen)
        XCTAssertFalse(nodeInB.isFullscreen)
        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspaceA))
        XCTAssertFalse(engine.isWindowFullscreen(token, in: workspaceB))
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testSameWorkspaceDuplicateAddIsIdempotent() {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 942, windowId: 1)

        let first = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)
        let second = engine.addWindow(token: token, to: workspaceA, afterSelection: nil)

        XCTAssertTrue(first === second)
        XCTAssertEqual(engine.columns(in: workspaceA).count, 1)
        XCTAssertEqual(engine.root(for: workspaceA)?.allWindows.count, 1)

        _ = engine.addWindow(token: token, to: workspaceB, afterSelection: nil)

        XCTAssertEqual(Set(engine.workspaceIds(containing: token)), [workspaceA, workspaceB])
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)
    }

    func testTreeIndexInvariantHoldsAcrossMutationFamilies() throws {
        let engine = NiriLayoutEngine()
        let workspaceA = WorkspaceDescriptor.ID()
        let workspaceB = WorkspaceDescriptor.ID()
        let workspaceC = WorkspaceDescriptor.ID()
        let token1 = WindowToken(pid: 943, windowId: 1)
        let token2 = WindowToken(pid: 943, windowId: 2)
        let token3 = WindowToken(pid: 943, windowId: 3)

        _ = engine.addWindow(token: token1, to: workspaceA, afterSelection: nil)
        _ = engine.addWindow(token: token2, to: workspaceA, afterSelection: nil)
        _ = engine.addWindow(token: token1, to: workspaceB, afterSelection: nil)
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)

        XCTAssertTrue(engine.rekeyWindow(from: token2, to: token3, in: workspaceA))
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)

        let movedNode = try XCTUnwrap(engine.findNode(for: token3, in: workspaceA))
        var sourceState = ViewportState()
        var targetState = ViewportState()
        XCTAssertNotNil(
            engine.moveWindowToWorkspace(
                movedNode,
                from: workspaceA,
                to: workspaceB,
                sourceState: &sourceState,
                targetState: &targetState
            )
        )
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)

        XCTAssertEqual(engine.syncWindows([token1], in: workspaceB, selectedNodeId: nil), [token3])
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)

        XCTAssertEqual(removeWindowsBatch(engine, tokens: [token1], in: workspaceA).removedTokens, [token1])
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceB)

        let placements = engine.persistedPlacements(in: workspaceB)
        XCTAssertTrue(engine.restoreInitialPlacements(placements, matching: [token1], in: workspaceC))
        assertIndexMatchesTree(engine, in: workspaceB)
        assertIndexMatchesTree(engine, in: workspaceC)

        engine.removeWindow(token: token1, in: workspaceC)
        assertIndexMatchesTree(engine, in: workspaceC)

        engine.removeWorkspaceState(workspaceB)
        XCTAssertNil(engine.states[workspaceB])
        assertIndexMatchesTree(engine, in: workspaceA)
        assertIndexMatchesTree(engine, in: workspaceC)
    }
}

extension NiriWorkspaceIsolationTests {
    @discardableResult
    private func removeWindowsBatch(
        _ engine: NiriLayoutEngine,
        tokens: Set<WindowToken>,
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
}
