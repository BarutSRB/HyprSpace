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

    func testProjectedTransferMatchesEquivalentVisibleViewportAndAnimation() throws {
        let projected = makeColumnFixture(includeHidden: true)
        let baseline = makeColumnFixture(includeHidden: false)
        configureColumnSpans(projected.engine, workspaceId: projected.workspaceId, width: 420)
        configureColumnSpans(baseline.engine, workspaceId: baseline.workspaceId, width: 420)
        installProjection(projected)
        installProjection(baseline)
        let animationTime = CACurrentMediaTime()
        projected.engine.animationClock = AnimationClock(time: animationTime)
        baseline.engine.animationClock = AnimationClock(time: animationTime)
        var projectedState = ViewportState(activeColumnIndex: 2, selectedNodeId: projected.b.id)
        var baselineState = ViewportState(activeColumnIndex: 1, selectedNodeId: baseline.b.id)
        projectedState.jumpOffset(to: 75)
        baselineState.jumpOffset(to: 75)

        XCTAssertTrue(
            projected.engine.consumeOrExpelWindow(
                projected.b,
                direction: .left,
                in: projected.workspaceId,
                motion: .enabled,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal,
                allowEdgeWrap: false
            )
        )
        XCTAssertTrue(
            baseline.engine.consumeOrExpelWindow(
                baseline.b,
                direction: .left,
                in: baseline.workspaceId,
                motion: .enabled,
                state: &baselineState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal,
                allowEdgeWrap: false
            )
        )

        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)
        XCTAssertEqual(projectedState.activeColumnIndex, baselineState.activeColumnIndex)
        XCTAssertEqual(
            try XCTUnwrap(projected.b.moveXAnimation).fromOffset,
            try XCTUnwrap(baseline.b.moveXAnimation).fromOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            projected.engine.columns(in: projected.workspaceId).map { $0.windowNodes.map(\.token) },
            [[projected.b.token, projected.a.token], [try XCTUnwrap(projected.hidden?.token)]]
        )
    }

    func testProjectedColumnMoveMatchesEquivalentVisibleViewportAndAnimation() throws {
        let projected = makeColumnFixture(includeHidden: true)
        let baseline = makeColumnFixture(includeHidden: false)
        configureColumnSpans(projected.engine, workspaceId: projected.workspaceId, width: 420)
        configureColumnSpans(baseline.engine, workspaceId: baseline.workspaceId, width: 420)
        installProjection(projected)
        installProjection(baseline)
        let projectedAColumn = try XCTUnwrap(
            projected.engine.findColumn(containing: projected.a, in: projected.workspaceId)
        )
        let projectedBColumn = try XCTUnwrap(
            projected.engine.findColumn(containing: projected.b, in: projected.workspaceId)
        )
        let baselineAColumn = try XCTUnwrap(
            baseline.engine.findColumn(containing: baseline.a, in: baseline.workspaceId)
        )
        let baselineBColumn = try XCTUnwrap(
            baseline.engine.findColumn(containing: baseline.b, in: baseline.workspaceId)
        )
        let hiddenColumn = try XCTUnwrap(
            projected.hidden.flatMap { projected.engine.findColumn(containing: $0, in: projected.workspaceId) }
        )
        let animationTime = CACurrentMediaTime()
        projected.engine.animationClock = AnimationClock(time: animationTime)
        baseline.engine.animationClock = AnimationClock(time: animationTime)
        var projectedState = ViewportState(activeColumnIndex: 2, selectedNodeId: projected.b.id)
        var baselineState = ViewportState(activeColumnIndex: 1, selectedNodeId: baseline.b.id)
        projectedState.jumpOffset(to: -40)
        baselineState.jumpOffset(to: -40)

        XCTAssertTrue(
            projected.engine.moveColumn(
                projectedBColumn,
                direction: .left,
                in: projected.workspaceId,
                motion: .enabled,
                state: &projectedState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
        XCTAssertTrue(
            baseline.engine.moveColumn(
                baselineBColumn,
                direction: .left,
                in: baseline.workspaceId,
                motion: .enabled,
                state: &baselineState,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )

        XCTAssertEqual(projectedState.viewOffset, baselineState.viewOffset, accuracy: 0.001)
        XCTAssertEqual(projectedState.activeColumnIndex, baselineState.activeColumnIndex)
        XCTAssertEqual(
            try XCTUnwrap(projectedBColumn.moveAnimation).fromOffset,
            try XCTUnwrap(baselineBColumn.moveAnimation).fromOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(projectedAColumn.moveAnimation).fromOffset,
            try XCTUnwrap(baselineAColumn.moveAnimation).fromOffset,
            accuracy: 0.001
        )
        XCTAssertNil(hiddenColumn.moveAnimation)
    }

    func testProjectedSingletonTabbedToggleDoesNotCreatePhantomAnimation() throws {
        let fixture = makeColumnFixture(includeHidden: true)
        let hidden = try XCTUnwrap(fixture.hidden)
        let column = try XCTUnwrap(
            fixture.engine.findColumn(containing: fixture.a, in: fixture.workspaceId)
        )
        var state = ViewportState(selectedNodeId: fixture.a.id)
        XCTAssertTrue(consume(
            hidden,
            into: column,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            state: &state
        ))
        let before = fixture.engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token]
        )

        XCTAssertTrue(
            fixture.engine.setColumnDisplay(
                .tabbed,
                for: column,
                in: fixture.workspaceId,
                motion: .enabled,
                orientation: .horizontal,
                gaps: gap
            )
        )
        let after = fixture.engine.calculateLayoutWithVisibility(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [hidden.token]
        )

        XCTAssertEqual(before.frames[fixture.a.token], after.frames[fixture.a.token])
        XCTAssertFalse(fixture.a.hasMoveAnimationsRunning)
        XCTAssertFalse(hidden.hasMoveAnimationsRunning)
        XCTAssertEqual(column.displayMode, .tabbed)
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

    func testDiscreteSecondarySizingMatchesEquivalentVisibleTree() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let projected = try makeMixedColumnFixture(orientation: orientation)
            let baseline = try makeVisibleMixedColumnFixture(orientation: orientation)
            projected.hidden.constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1100, height: 700),
                maxSize: .zero,
                isFixed: false
            )

            setSecondarySize(.fixed(73), for: projected.hidden, orientation: orientation)
            let hiddenSizing = secondarySize(of: projected.hidden, orientation: orientation)

            projected.engine.setWindowSecondarySpan(
                projected.a,
                change: .setProportion(70),
                in: projected.workspaceId,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )
            baseline.engine.setWindowSecondarySpan(
                baseline.a,
                change: .setProportion(70),
                in: baseline.workspaceId,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )

            let projectedFrames = layout(
                engine: projected.engine,
                workspaceId: projected.workspaceId,
                selectedWindow: projected.a,
                orientation: orientation
            )
            let baselineFrames = layout(
                engine: baseline.engine,
                workspaceId: baseline.workspaceId,
                selectedWindow: baseline.a,
                orientation: orientation
            )
            let projectedFrame = try XCTUnwrap(projectedFrames[projected.a.token])
            let baselineFrame = try XCTUnwrap(baselineFrames[baseline.a.token])
            XCTAssertEqual(
                secondarySpan(of: projectedFrame, orientation: orientation),
                secondarySpan(of: baselineFrame, orientation: orientation),
                accuracy: 0.001
            )
            XCTAssertEqual(secondarySize(of: projected.hidden, orientation: orientation), hiddenSizing)
        }
    }

    func testSecondaryPresetCyclePreservesHiddenSizing() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let projected = try makeMixedColumnFixture(orientation: orientation)
            projected.engine.presetWindowSecondarySpans = [.fixed(200), .proportion(0.5), .fixed(700)]
            setResolvedSecondarySpan(300, for: projected.a, orientation: orientation)
            setSecondarySize(.fixed(73), for: projected.hidden, orientation: orientation)
            let hiddenSizing = secondarySize(of: projected.hidden, orientation: orientation)

            projected.engine.toggleWindowSecondarySpan(
                projected.a,
                forwards: true,
                in: projected.workspaceId,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )
            XCTAssertEqual(secondarySize(of: projected.a, orientation: orientation), .preset(1))
            XCTAssertTrue(secondarySize(of: projected.b, orientation: orientation).isAuto)
            XCTAssertEqual(secondarySize(of: projected.hidden, orientation: orientation), hiddenSizing)
            let frame = try XCTUnwrap(layout(
                engine: projected.engine,
                workspaceId: projected.workspaceId,
                selectedWindow: projected.a,
                orientation: orientation
            )[projected.a.token])
            let expectedSpan: CGFloat = orientation == .horizontal ? 382 : 582
            XCTAssertEqual(secondarySpan(of: frame, orientation: orientation), expectedSpan, accuracy: 0.001)
        }
    }

    func testProjectedSingletonTabbedSecondarySizingHasNoTabInset() throws {
        let fixture = try makeMixedColumnFixture(orientation: .vertical)
        fixture.engine.renderStyle = NiriRenderStyle(tabIndicatorWidth: 50)
        fixture.column.displayMode = .tabbed
        _ = fixture.engine.calculateLayout(
            state: ViewportState(selectedNodeId: fixture.a.id),
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .vertical,
            excludedTokens: [fixture.hidden.token, fixture.b.token]
        )

        fixture.engine.setWindowSecondarySpan(
            fixture.a,
            change: .setProportion(50),
            in: fixture.workspaceId,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .vertical
        )

        let frame = try XCTUnwrap(layout(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            selectedWindow: fixture.a,
            orientation: .vertical
        )[fixture.a.token])
        XCTAssertEqual(frame.width, 582, accuracy: 0.001)
    }

    func testTabbedSecondaryResetPreservesExcludedMembers() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeMixedColumnFixture(orientation: orientation)
            fixture.column.displayMode = .tabbed
            setSecondarySize(.fixed(211), for: fixture.a, orientation: orientation)
            setSecondarySize(.fixed(223), for: fixture.b, orientation: orientation)
            setSecondarySize(.fixed(73), for: fixture.hidden, orientation: orientation)
            fixture.hidden.savedHeight = .fixed(61)
            let hiddenSizing = secondarySize(of: fixture.hidden, orientation: orientation)
            let hiddenSavedHeight = fixture.hidden.savedHeight

            fixture.engine.resetWindowSecondarySpan(
                fixture.hidden,
                in: fixture.workspaceId,
                orientation: orientation
            )
            XCTAssertEqual(secondarySize(of: fixture.a, orientation: orientation), .fixed(211))
            XCTAssertEqual(secondarySize(of: fixture.hidden, orientation: orientation), hiddenSizing)
            XCTAssertEqual(fixture.hidden.savedHeight, hiddenSavedHeight)

            fixture.engine.resetWindowSecondarySpan(
                fixture.a,
                in: fixture.workspaceId,
                orientation: orientation
            )
            XCTAssertEqual(secondarySize(of: fixture.a, orientation: orientation), .auto(weight: 1))
            XCTAssertEqual(secondarySize(of: fixture.b, orientation: orientation), .auto(weight: 1))
            XCTAssertEqual(secondarySize(of: fixture.hidden, orientation: orientation), hiddenSizing)
            XCTAssertEqual(fixture.hidden.savedHeight, hiddenSavedHeight)
        }
    }

    func testBalancePreservesHiddenOnlyColumnsAndExcludedMembers() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = try makeMixedColumnFixture(orientation: orientation)
            fixture.engine.visibleContainerCount = 2
            fixture.hidden.constraints = WindowSizeConstraints(
                minSize: CGSize(width: 1100, height: 700),
                maxSize: .zero,
                isFixed: false
            )
            let hiddenOnly = fixture.engine.addWindow(
                token: WindowToken(pid: 753, windowId: orientation == .horizontal ? 4 : 5),
                to: fixture.workspaceId,
                afterSelection: fixture.b.id
            )
            let hiddenOnlyColumn = try XCTUnwrap(
                fixture.engine.findColumn(containing: hiddenOnly, in: fixture.workspaceId)
            )
            _ = fixture.engine.calculateLayout(
                state: ViewportState(selectedNodeId: fixture.a.id),
                workspaceId: fixture.workspaceId,
                monitorFrame: workingFrame,
                gaps: (horizontal: gap, vertical: gap),
                orientation: orientation,
                excludedTokens: [fixture.hidden.token, hiddenOnly.token]
            )

            fixture.column.width = .fixed(333)
            fixture.column.height = .fixed(222)
            hiddenOnlyColumn.width = .fixed(487)
            hiddenOnlyColumn.height = .fixed(391)
            hiddenOnlyColumn.cachedWidth = 487
            hiddenOnlyColumn.cachedHeight = 391
            hiddenOnlyColumn.isFullWidth = true
            hiddenOnlyColumn.isFullHeight = true
            hiddenOnlyColumn.savedWidth = .fixed(478)
            hiddenOnlyColumn.savedHeight = .fixed(382)
            hiddenOnlyColumn.hasManualSingleWindowWidthOverride = true
            hiddenOnlyColumn.hasManualSingleWindowHeightOverride = true
            hiddenOnly.height = .fixed(173)
            hiddenOnly.windowWidth = .fixed(181)

            let hiddenOnlySizingState = try XCTUnwrap(
                fixture.engine.containerSizingState(for: hiddenOnly.token, in: fixture.workspaceId)
            )
            let hiddenOnlyCachedWidth = hiddenOnlyColumn.cachedWidth
            let hiddenOnlyCachedHeight = hiddenOnlyColumn.cachedHeight
            let hiddenOnlyWindowHeight = hiddenOnly.height
            let hiddenOnlyWindowWidth = hiddenOnly.windowWidth

            setSecondarySize(.auto(weight: 2), for: fixture.a, orientation: orientation)
            setSecondarySize(.auto(weight: 3), for: fixture.b, orientation: orientation)
            setSecondarySize(.auto(weight: 43), for: fixture.hidden, orientation: orientation)
            let mixedHiddenSizing = secondarySize(of: fixture.hidden, orientation: orientation)

            XCTAssertTrue(
                fixture.engine.balanceSizes(
                    in: fixture.workspaceId,
                    motion: .disabled,
                    workingFrame: workingFrame,
                    gaps: gap,
                    orientation: orientation
                )
            )

            XCTAssertEqual(
                try XCTUnwrap(fixture.engine.containerSizingState(for: hiddenOnly.token, in: fixture.workspaceId)),
                hiddenOnlySizingState
            )
            XCTAssertEqual(hiddenOnlyColumn.cachedWidth, hiddenOnlyCachedWidth)
            XCTAssertEqual(hiddenOnlyColumn.cachedHeight, hiddenOnlyCachedHeight)
            XCTAssertEqual(hiddenOnly.height, hiddenOnlyWindowHeight)
            XCTAssertEqual(hiddenOnly.windowWidth, hiddenOnlyWindowWidth)
            XCTAssertEqual(secondarySize(of: fixture.a, orientation: orientation), .auto(weight: 1))
            XCTAssertEqual(secondarySize(of: fixture.b, orientation: orientation), .auto(weight: 1))
            XCTAssertEqual(secondarySize(of: fixture.hidden, orientation: orientation), mixedHiddenSizing)

            switch orientation {
            case .horizontal:
                XCTAssertNotEqual(fixture.column.width, .fixed(333))
                XCTAssertEqual(fixture.column.cachedWidth, 582, accuracy: 0.001)
            case .vertical:
                XCTAssertNotEqual(fixture.column.height, .fixed(222))
                XCTAssertEqual(fixture.column.cachedHeight, 382, accuracy: 0.001)
            }
        }
    }

    func testBalanceReturnsFalseWhenEveryColumnIsExcluded() throws {
        let fixture = makeColumnFixture(includeHidden: true)
        let hidden = try XCTUnwrap(fixture.hidden)
        _ = fixture.engine.calculateLayout(
            state: ViewportState(selectedNodeId: fixture.a.id),
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal,
            excludedTokens: [fixture.a.token, hidden.token, fixture.b.token]
        )

        XCTAssertFalse(
            fixture.engine.balanceSizes(
                in: fixture.workspaceId,
                motion: .disabled,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        )
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

    private func makeMixedColumnFixture(
        orientation: Monitor.Orientation = .horizontal
    ) throws -> (
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
            state: &state,
            orientation: orientation
        ))
        XCTAssertTrue(consume(
            fixture.b,
            into: column,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            state: &state,
            orientation: orientation
        ))
        _ = fixture.engine.calculateLayout(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: orientation,
            excludedTokens: [hidden.token]
        )
        return (fixture.engine, fixture.workspaceId, column, fixture.a, hidden, fixture.b)
    }

    private func makeVisibleMixedColumnFixture(
        orientation: Monitor.Orientation
    ) throws -> (
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        column: NiriContainer,
        a: NiriWindow,
        b: NiriWindow
    ) {
        let fixture = makeColumnFixture(includeHidden: false)
        let column = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.a, in: fixture.workspaceId))
        var state = ViewportState(selectedNodeId: fixture.a.id)
        XCTAssertTrue(consume(
            fixture.b,
            into: column,
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            state: &state,
            orientation: orientation
        ))
        _ = fixture.engine.calculateLayout(
            state: state,
            workspaceId: fixture.workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: orientation,
            excludedTokens: []
        )
        return (fixture.engine, fixture.workspaceId, column, fixture.a, fixture.b)
    }

    private func layout(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        selectedWindow: NiriWindow,
        orientation: Monitor.Orientation
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: ViewportState(selectedNodeId: selectedWindow.id),
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: orientation,
            excludedTokens: engine.projectionExclusions(in: workspaceId)
        )
    }

    private func secondarySize(
        of window: NiriWindow,
        orientation: Monitor.Orientation
    ) -> WeightedSize {
        switch orientation {
        case .horizontal: window.height
        case .vertical: window.windowWidth
        }
    }

    private func setSecondarySize(
        _ size: WeightedSize,
        for window: NiriWindow,
        orientation: Monitor.Orientation
    ) {
        switch orientation {
        case .horizontal: window.height = size
        case .vertical: window.windowWidth = size
        }
    }

    private func setResolvedSecondarySpan(
        _ span: CGFloat,
        for window: NiriWindow,
        orientation: Monitor.Orientation
    ) {
        switch orientation {
        case .horizontal: window.resolvedHeight = span
        case .vertical: window.resolvedWidth = span
        }
    }

    private func secondarySpan(
        of frame: CGRect,
        orientation: Monitor.Orientation
    ) -> CGFloat {
        switch orientation {
        case .horizontal: frame.height
        case .vertical: frame.width
        }
    }

    private func consume(
        _ window: NiriWindow,
        into column: NiriContainer,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        orientation: Monitor.Orientation = .horizontal
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
            orientation: orientation
        )
    }
}
