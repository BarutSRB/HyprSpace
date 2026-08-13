// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriHiddenAppProjectionTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gap: CGFloat = 12

    func testExcludedLayoutDiffProducesNoEffects() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 699, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: .unconstrained,
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            layoutReason: .standard
        )

        let diff = handler.layoutDiff(
            windows: [window],
            frames: [token: workingFrame],
            hiddenHandles: [token: .left],
            engine: engine,
            workspaceId: workspaceId,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: true,
            excludedTokens: [token],
            pendingParkWindowIds: [token.windowId]
        )

        XCTAssertTrue(diff.frameChanges.isEmpty)
        XCTAssertTrue(diff.visibilityChanges.isEmpty)
        XCTAssertTrue(diff.restoreChanges.isEmpty)
        XCTAssertTrue(diff.deferredHides.isEmpty)
    }

    func testExcludedMiddleColumnPreservesDurableTreeAndRestoresInPlace() throws {
        let fixture = makeThreeColumnFixture()
        let columnIds = fixture.engine.columns(in: fixture.workspaceId).map(\.id)

        let hiddenFrames = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: ViewportState(selectedNodeId: fixture.a.id),
            excludedTokens: [fixture.hidden.token]
        )

        XCTAssertNotNil(hiddenFrames[fixture.a.token])
        XCTAssertNil(hiddenFrames[fixture.hidden.token])
        XCTAssertNotNil(hiddenFrames[fixture.b.token])
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), columnIds)
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [fixture.a.token, fixture.hidden.token, fixture.b.token]
        )
        XCTAssertEqual(
            fixture.engine.persistedPlacements(in: fixture.workspaceId)[fixture.hidden.token]?.columnIndex,
            1
        )

        let restoredFrames = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: ViewportState(selectedNodeId: fixture.a.id),
            excludedTokens: []
        )

        XCTAssertEqual(Set(restoredFrames.keys), [fixture.a.token, fixture.hidden.token, fixture.b.token])
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).map(\.id), columnIds)
    }

    func testDefaultLayoutCallPreservesInstalledProjectionUntilExplicitlyCleared() {
        let fixture = makeThreeColumnFixture()
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: ViewportState(selectedNodeId: fixture.a.id),
            excludedTokens: [fixture.hidden.token]
        )

        let inheritedFrames = fixture.engine.calculateLayout(
            state: ViewportState(selectedNodeId: fixture.a.id),
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal
        )

        XCTAssertNil(inheritedFrames[fixture.hidden.token])
        XCTAssertNotNil(inheritedFrames[fixture.b.token])
    }

    func testMixedColumnSolvesOnlyVisibleWindowConstraints() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        let visible = engine.addWindow(
            token: WindowToken(pid: 710, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let hidden = engine.addWindow(
            token: WindowToken(pid: 711, windowId: 2),
            to: workspaceId,
            afterSelection: visible.id
        )
        let targetColumn = try XCTUnwrap(engine.findColumn(containing: visible, in: workspaceId))
        var state = ViewportState(selectedNodeId: visible.id)
        XCTAssertTrue(
            engine.consumeWindow(
                hidden,
                into: targetColumn,
                enteringFrom: .right,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        engine.updateWindowConstraints(
            for: hidden.token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 1100, height: 700),
                maxSize: .zero,
                isFixed: false
            ),
            in: workspaceId
        )

        let frames = layout(
            engine,
            workspaceId: workspaceId,
            state: state,
            excludedTokens: [hidden.token]
        )
        let visibleFrame = try XCTUnwrap(frames[visible.token])

        XCTAssertNil(frames[hidden.token])
        XCTAssertLessThan(visibleFrame.width, 1100)
        XCTAssertGreaterThan(visibleFrame.height, 700)
        XCTAssertEqual(Set(targetColumn.windowNodes.map(\.token)), [visible.token, hidden.token])
    }

    func testTabbedProjectionChoosesVisibleTabWithoutChangingDurableActiveTile() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        let visible = engine.addWindow(
            token: WindowToken(pid: 720, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let hidden = engine.addWindow(
            token: WindowToken(pid: 721, windowId: 2),
            to: workspaceId,
            afterSelection: visible.id
        )
        let column = try XCTUnwrap(engine.findColumn(containing: visible, in: workspaceId))
        var state = ViewportState(selectedNodeId: hidden.id)
        XCTAssertTrue(
            engine.consumeWindow(
                hidden,
                into: column,
                enteringFrom: .right,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        column.displayMode = .tabbed
        let hiddenStorageIndex = try XCTUnwrap(column.windowNodes.firstIndex(where: { $0 === hidden }))
        column.setActiveTileIdx(hiddenStorageIndex)
        engine.updateTabbedColumnVisibility(column: column)

        let result = engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token]
        )

        XCTAssertNotNil(result.frames[visible.token])
        XCTAssertNil(result.frames[hidden.token])
        XCTAssertNil(result.hiddenHandles[visible.token])
        XCTAssertNil(result.hiddenHandles[hidden.token])
        XCTAssertEqual(column.activeTileIdx, hiddenStorageIndex)
        XCTAssertTrue(visible.isHiddenInTabbedMode)
        XCTAssertTrue(engine.isProjectedFocusableWindow(visible, in: workspaceId))
        XCTAssertFalse(engine.isProjectedFocusableWindow(hidden, in: workspaceId))
        let visibleFrame = try XCTUnwrap(result.frames[visible.token])
        XCTAssertTrue(
            engine.hitTestFocusableWindow(
                point: CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
                in: workspaceId
            ) === visible
        )
    }

    func testNavigationSkipsExcludedMiddleColumnAndCommitsDurableIndex() throws {
        let fixture = makeThreeColumnFixture()
        var state = ViewportState(activeColumnIndex: 0, selectedNodeId: fixture.a.id)
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: [fixture.hidden.token]
        )

        let target = fixture.engine.focusTarget(
            direction: .right,
            currentSelection: fixture.a,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .horizontal
        ) as? NiriWindow

        XCTAssertTrue(try XCTUnwrap(target) === fixture.b)
        XCTAssertEqual(state.activeColumnIndex, 2)
    }

    func testProjectedSelectionReconcilesExcludedSelectedNodeToVisibleFallback() throws {
        let fixture = makeThreeColumnFixture()
        var state = ViewportState(activeColumnIndex: 1, selectedNodeId: fixture.hidden.id)
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: [fixture.hidden.token]
        )

        let nonmutatingSelection = try XCTUnwrap(
            fixture.engine.projectedSelectedWindow(state: state, in: fixture.workspaceId)
        )
        XCTAssertTrue(nonmutatingSelection === fixture.a)
        XCTAssertEqual(state.selectedNodeId, fixture.hidden.id)
        XCTAssertEqual(state.activeColumnIndex, 1)

        let reconciledSelection = try XCTUnwrap(
            fixture.engine.reconcileProjectedSelection(state: &state, in: fixture.workspaceId)
        )
        XCTAssertTrue(reconciledSelection === fixture.a)
        XCTAssertEqual(state.selectedNodeId, fixture.a.id)
        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertNotNil(fixture.engine.findNode(for: fixture.hidden.token, in: fixture.workspaceId))
    }

    func testGestureProjectionMapsVisibleSnapBackToDurableIndex() {
        let fixture = makeThreeColumnFixture()
        var state = ViewportState(activeColumnIndex: 0, selectedNodeId: fixture.a.id)
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: [fixture.hidden.token]
        )
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let projectedTarget = columns[0].cachedWidth + gap

        let selectedWindow = fixture.engine.endProjectedGesture(
            state: &state,
            in: fixture.workspaceId,
            currentOffset: Double(projectedTarget),
            projectedOffset: Double(projectedTarget),
            gap: gap,
            viewportSpan: workingFrame.width,
            orientation: .horizontal,
            motion: .disabled,
            centerMode: .always,
            workingArea: workingFrame
        )

        XCTAssertEqual(state.activeColumnIndex, 2)
        XCTAssertTrue(selectedWindow === fixture.b)
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: []
        )
        XCTAssertEqual(state.activeColumnIndex, 2)
    }

    func testVisibleColumnMovePersistsWhileAnotherAppIsExcluded() throws {
        let fixture = makeThreeColumnFixture()
        var state = ViewportState(activeColumnIndex: 0, selectedNodeId: fixture.a.id)
        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: [fixture.hidden.token]
        )
        let aColumn = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.a, in: fixture.workspaceId))

        XCTAssertTrue(
            fixture.engine.moveColumnToLast(
                aColumn,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(
            fixture.engine.persistedPlacements(in: fixture.workspaceId)[fixture.a.token]?.columnIndex,
            2
        )

        _ = layout(
            fixture.engine,
            workspaceId: fixture.workspaceId,
            state: state,
            excludedTokens: []
        )
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [fixture.hidden.token, fixture.b.token, fixture.a.token]
        )
    }

    private func makeThreeColumnFixture() -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        a: NiriWindow,
        hidden: NiriWindow,
        b: NiriWindow
    ) {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        let a = engine.addWindow(
            token: WindowToken(pid: 700, windowId: 1),
            to: workspaceId,
            afterSelection: nil
        )
        let hidden = engine.addWindow(
            token: WindowToken(pid: 701, windowId: 2),
            to: workspaceId,
            afterSelection: a.id
        )
        let b = engine.addWindow(
            token: WindowToken(pid: 702, windowId: 3),
            to: workspaceId,
            afterSelection: hidden.id
        )
        return (engine, workspaceId, a, hidden, b)
    }

    private func layout(
        _ engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        excludedTokens: Set<WindowToken>
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: excludedTokens
        )
    }
}
