// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriProjectionCommandTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gap: CGFloat = 12

    func testViewportCommandsMatchEquivalentVisibleTree() throws {
        let projected = makeColumnFixture(includeHidden: true)
        let baseline = makeColumnFixture(includeHidden: false)
        configureColumnSpans(projected.engine, workspaceId: projected.workspaceId, width: 420)
        configureColumnSpans(baseline.engine, workspaceId: baseline.workspaceId, width: 420)
        installProjection(projected)
        installProjection(baseline)

        var projectedState = ViewportState(activeColumnIndex: 2, selectedNodeId: projected.b.id)
        var baselineState = ViewportState(activeColumnIndex: 1, selectedNodeId: baseline.b.id)
        projectedState.jumpOffset(to: 137)
        baselineState.jumpOffset(to: 137)

        XCTAssertEqual(
            projected.engine.centerColumn(
                in: projected.workspaceId,
                motion: .disabled,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            ),
            baseline.engine.centerColumn(
                in: baseline.workspaceId,
                motion: .disabled,
                state: &baselineState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)
        XCTAssertEqual(projectedState.activeColumnIndex, 2)

        projectedState.jumpOffset(to: -50)
        baselineState.jumpOffset(to: -50)
        XCTAssertEqual(
            projected.engine.centerVisibleColumns(
                in: projected.workspaceId,
                motion: .disabled,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            ),
            baseline.engine.centerVisibleColumns(
                in: baseline.workspaceId,
                motion: .disabled,
                state: &baselineState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)

        projectedState.jumpOffset(to: 300)
        baselineState.jumpOffset(to: 300)
        XCTAssertEqual(
            projected.engine.recoverSettledCoverage(
                in: projected.workspaceId,
                motion: .disabled,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            ),
            baseline.engine.recoverSettledCoverage(
                in: baseline.workspaceId,
                motion: .disabled,
                state: &baselineState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)
    }

    func testExpandAvailableSpanMatchesEquivalentVisibleTree() throws {
        let projected = makeColumnFixture(includeHidden: true)
        let baseline = makeColumnFixture(includeHidden: false)
        configureColumnSpans(projected.engine, workspaceId: projected.workspaceId, width: 360)
        configureColumnSpans(baseline.engine, workspaceId: baseline.workspaceId, width: 360)
        installProjection(projected)
        installProjection(baseline)
        let projectedColumn = try XCTUnwrap(projected.engine.findColumn(
            containing: projected.a,
            in: projected.workspaceId
        ))
        let baselineColumn = try XCTUnwrap(baseline.engine.findColumn(containing: baseline.a, in: baseline.workspaceId))
        var projectedState = ViewportState(activeColumnIndex: 0, selectedNodeId: projected.a.id)
        var baselineState = ViewportState(activeColumnIndex: 0, selectedNodeId: baseline.a.id)

        projected.engine.expandContainerToAvailablePrimarySpan(
            projectedColumn,
            in: projected.workspaceId,
            motion: .disabled,
            state: &projectedState,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .horizontal
        )
        baseline.engine.expandContainerToAvailablePrimarySpan(
            baselineColumn,
            in: baseline.workspaceId,
            motion: .disabled,
            state: &baselineState,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .horizontal
        )

        XCTAssertEqual(projectedColumn.cachedWidth, baselineColumn.cachedWidth, accuracy: 0.001)
        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)
    }

    func testStructuralCommandsSkipHiddenColumnsAndMembers() throws {
        let consumeFixture = makeColumnFixture(includeHidden: true)
        installProjection(consumeFixture)
        var consumeState = ViewportState(activeColumnIndex: 0, selectedNodeId: consumeFixture.a.id)
        XCTAssertTrue(
            consumeFixture.engine.consumeOrExpelWindow(
                consumeFixture.a,
                direction: .right,
                in: consumeFixture.workspaceId,
                motion: .disabled,
                state: &consumeState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal,
                allowEdgeWrap: false
            )
        )
        XCTAssertEqual(
            consumeFixture.engine.columns(in: consumeFixture.workspaceId).map { $0.windowNodes.map(\.token) },
            [[try XCTUnwrap(consumeFixture.hidden?.token)], [consumeFixture.a.token, consumeFixture.b.token]]
        )

        let moveFixture = makeColumnFixture(includeHidden: true)
        installProjection(moveFixture)
        let aColumn = try XCTUnwrap(moveFixture.engine.findColumn(
            containing: moveFixture.a,
            in: moveFixture.workspaceId
        ))
        var moveState = ViewportState(activeColumnIndex: 0, selectedNodeId: moveFixture.a.id)
        XCTAssertTrue(
            moveFixture.engine.moveColumn(
                aColumn,
                direction: .right,
                in: moveFixture.workspaceId,
                motion: .disabled,
                state: &moveState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(
            moveFixture.engine.columns(in: moveFixture.workspaceId).flatMap { $0.windowNodes.map(\.token) },
            [try XCTUnwrap(moveFixture.hidden?.token), moveFixture.b.token, moveFixture.a.token]
        )

        let mixed = try makeMixedColumnFixture()
        let visibleBefore = mixed.column.windowNodes.filter { $0 !== mixed.hidden }.map(\.token)
        XCTAssertTrue(
            mixed.engine.moveWindowWithinContainer(
                mixed.b,
                step: 1,
                in: mixed.workspaceId
            )
        )
        XCTAssertEqual(visibleBefore, [mixed.b.token, mixed.a.token])
        XCTAssertEqual(
            mixed.column.windowNodes.filter { $0 !== mixed.hidden }.map(\.token),
            [mixed.a.token, mixed.b.token]
        )
        XCTAssertTrue(mixed.column.windowNodes.contains(where: { $0 === mixed.hidden }))
    }

    func testExpelUsesVisibleMemberAndLeavesHiddenMemberRetained() throws {
        let fixture = try makeMixedColumnFixture()
        var state = ViewportState(activeColumnIndex: 0, selectedNodeId: fixture.a.id)

        XCTAssertTrue(
            fixture.engine.expelWindowFromColumn(
                focusedColumn: fixture.column,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(
            fixture.engine.columns(in: fixture.workspaceId).map { $0.windowNodes.map(\.token) },
            [[fixture.hidden.token, fixture.a.token], [fixture.b.token]]
        )
    }

    func testProjectedTabbedFallbackHasNoSingleTabInsetAndRejectsInactiveHit() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        let a = engine.addWindow(token: WindowToken(pid: 740, windowId: 1), to: workspaceId, afterSelection: nil)
        let hidden = engine.addWindow(token: WindowToken(pid: 741, windowId: 2), to: workspaceId, afterSelection: a.id)
        let b = engine.addWindow(token: WindowToken(pid: 742, windowId: 3), to: workspaceId, afterSelection: hidden.id)
        let column = try XCTUnwrap(engine.findColumn(containing: a, in: workspaceId))
        var state = ViewportState(selectedNodeId: hidden.id)
        XCTAssertTrue(consume(hidden, into: column, engine: engine, workspaceId: workspaceId, state: &state))
        XCTAssertTrue(consume(b, into: column, engine: engine, workspaceId: workspaceId, state: &state))
        column.displayMode = .tabbed
        column.setActiveTileIdx(try XCTUnwrap(column.windowNodes.firstIndex(where: { $0 === hidden })))
        engine.updateTabbedColumnVisibility(column: column)

        let twoVisible = engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token]
        )
        let aFrame = try XCTUnwrap(twoVisible.frames[a.token])
        let projectedActive = try XCTUnwrap(engine.projectedActiveWindow(in: column, workspaceId: workspaceId))
        XCTAssertTrue(
            engine.hitTestTiled(point: CGPoint(x: aFrame.midX, y: aFrame.midY), in: workspaceId) === projectedActive
        )
        let projectedInactive = projectedActive === a ? b : a
        XCTAssertFalse(
            engine.hitTestTiled(point: CGPoint(x: aFrame.midX, y: aFrame.midY), in: workspaceId) === projectedInactive
        )

        let oneVisible = engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token, b.token]
        )
        let singleFrame = try XCTUnwrap(oneVisible.frames[a.token])
        let columnFrame = try XCTUnwrap(column.frame)
        XCTAssertEqual(singleFrame.minX, columnFrame.minX + gap, accuracy: 0.001)
        XCTAssertEqual(singleFrame.width, columnFrame.width, accuracy: 0.001)
        XCTAssertEqual(column.displayMode, .tabbed)
    }

    func testInteractiveResizeIgnoresHiddenConstraintsAndWeights() throws {
        let constrained = try makeMixedColumnFixture()
        constrained.hidden.constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1100, height: 700),
            maxSize: .zero,
            isFixed: false
        )
        constrained.column.cachedWidth = 600
        XCTAssertTrue(
            constrained.engine.interactiveResizeBegin(
                windowId: constrained.a.id,
                edges: .right,
                startLocation: .zero,
                in: constrained.workspaceId,
                orientation: .horizontal
            )
        )
        XCTAssertTrue(
            constrained.engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: -400, y: 0),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: gap, vertical: gap)
            )
        )
        XCTAssertLessThan(constrained.column.cachedWidth, 1100)

        let projected = try makeMixedColumnFixture()
        let baseline = makeColumnFixture(includeHidden: false)
        let baselineColumn = try XCTUnwrap(
            baseline.engine.findColumn(containing: baseline.a, in: baseline.workspaceId)
        )
        var baselineState = ViewportState(selectedNodeId: baseline.a.id)
        XCTAssertTrue(
            consume(
                baseline.b,
                into: baselineColumn,
                engine: baseline.engine,
                workspaceId: baseline.workspaceId,
                state: &baselineState
            )
        )
        _ = baseline.engine.calculateLayout(
            state: baselineState,
            workspaceId: baseline.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .vertical,
            excludedTokens: []
        )
        projected.hidden.windowWidth = .auto(weight: 100)
        try resizeSecondaryWidth(
            engine: projected.engine,
            workspaceId: projected.workspaceId,
            window: projected.a
        )
        try resizeSecondaryWidth(
            engine: baseline.engine,
            workspaceId: baseline.workspaceId,
            window: baseline.a
        )
        XCTAssertEqual(projected.a.widthWeight, baseline.a.widthWeight, accuracy: 0.001)
    }

    private func resizeSecondaryWidth(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        window: NiriWindow
    ) throws {
        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .right,
                startLocation: .zero,
                in: workspaceId,
                orientation: .vertical
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: 120, y: 0),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: gap, vertical: gap)
            )
        )
    }

    private func makeColumnFixture(includeHidden: Bool) -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        a: NiriWindow,
        hidden: NiriWindow?,
        b: NiriWindow
    ) {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
        let workspaceId = WorkspaceDescriptor.ID()
        let monitor = Monitor(
            id: .init(displayId: includeHidden ? 80 : 81),
            displayId: includeHidden ? 80 : 81,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Projection"
        )
        _ = engine.ensureMonitor(for: monitor.id, monitor: monitor, orientation: .horizontal)
        engine.moveWorkspace(workspaceId, to: monitor.id, monitor: monitor)
        let a = engine.addWindow(token: WindowToken(pid: 750, windowId: 1), to: workspaceId, afterSelection: nil)
        let hidden = includeHidden
            ? engine.addWindow(token: WindowToken(pid: 751, windowId: 2), to: workspaceId, afterSelection: a.id)
            : nil
        let b = engine.addWindow(
            token: WindowToken(pid: 752, windowId: 3),
            to: workspaceId,
            afterSelection: hidden?.id ?? a.id
        )
        return (engine, workspaceId, a, hidden, b)
    }

    private func installProjection(
        _ fixture: (
            engine: NiriLayoutEngine,
            workspaceId: WorkspaceDescriptor.ID,
            a: NiriWindow,
            hidden: NiriWindow?,
            b: NiriWindow
        )
    ) {
        _ = fixture.engine.calculateLayout(
            state: ViewportState(selectedNodeId: fixture.a.id),
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: Set(fixture.hidden.map { [$0.token] } ?? [])
        )
    }

    private func configureColumnSpans(
        _ engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        width: CGFloat
    ) {
        for column in engine.columns(in: workspaceId) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
    }

    private func makeMixedColumnFixture() throws -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        column: NiriContainer,
        a: NiriWindow,
        hidden: NiriWindow,
        b: NiriWindow
    ) {
        let fixture = makeColumnFixture(includeHidden: true)
        let hidden = try XCTUnwrap(fixture.hidden)
        let column = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.a, in: fixture.workspaceId))
        var state = ViewportState(selectedNodeId: fixture.a.id)
        XCTAssertTrue(consume(
            hidden,
            into: column,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            state: &state
        ))
        XCTAssertTrue(consume(
            fixture.b,
            into: column,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            state: &state
        ))
        _ = fixture.engine.calculateLayout(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token]
        )
        return (fixture.engine, fixture.workspaceId, column, fixture.a, hidden, fixture.b)
    }

    private func consume(
        _ window: NiriWindow,
        into column: NiriContainer,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState
    ) -> Bool {
        engine.consumeWindow(
            window,
            into: column,
            enteringFrom: .right,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .horizontal
        )
    }
}
