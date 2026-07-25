// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NiriPortraitSizingTests: NiriInteractionTestCase {
    private let portraitFrame = CGRect(x: 0, y: 0, width: 900, height: 1600)

    private func portraitLayout(
        _ engine: NiriLayoutEngine,
        in workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> [WindowToken: CGRect] {
        engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: portraitFrame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )
    }

    private func makeTwoWindowRow()
        throws -> (
            engine: NiriLayoutEngine,
            workspaceId: WorkspaceDescriptor.ID,
            first: NiriWindow,
            second: NiriWindow,
            column: NiriContainer,
            state: ViewportState
        )
    {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 2_001, to: workspaceId)
        let second = addWindow(engine, pid: 2_001, windowId: 2, to: workspaceId, after: first)
        let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspaceId))
        var state = ViewportState()
        XCTAssertTrue(
            engine.consumeWindow(
                second,
                into: column,
                enteringFrom: .right,
                in: workspaceId,
                motion: .disabled,
                state: &state,
                workingFrame: portraitFrame,
                gaps: 0,
                orientation: .vertical
            )
        )
        state.selectedNodeId = first.id
        return (engine, workspaceId, first, second, column, state)
    }

    func testPortraitHorizontalResizeChangesRenderedSiblingWidths() throws {
        var fixture = try makeTwoWindowRow()
        fixture.state.jumpOffset(to: -120)
        let framesBefore = portraitLayout(
            fixture.engine,
            in: fixture.workspaceId,
            state: fixture.state
        )
        let firstBefore = try XCTUnwrap(framesBefore[fixture.first.token])
        let secondBefore = try XCTUnwrap(framesBefore[fixture.second.token])

        XCTAssertTrue(
            fixture.engine.interactiveResizeBegin(
                windowId: fixture.first.id,
                edges: .right,
                startLocation: CGPoint(x: firstBefore.maxX, y: firstBefore.midY),
                in: fixture.workspaceId,
                orientation: .vertical,
                viewOffset: fixture.state.viewOffset
            )
        )
        XCTAssertTrue(
            fixture.engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: firstBefore.maxX + 100, y: firstBefore.midY),
                monitorFrame: portraitFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0),
                viewportState: { mutate in mutate(&fixture.state) }
            )
        )

        let framesAfter = portraitLayout(
            fixture.engine,
            in: fixture.workspaceId,
            state: fixture.state
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(framesAfter[fixture.first.token]).width,
            firstBefore.width
        )
        XCTAssertLessThan(
            try XCTUnwrap(framesAfter[fixture.second.token]).width,
            secondBefore.width
        )
        XCTAssertEqual(fixture.column.cachedWidth, 0, accuracy: 0.001)
        XCTAssertEqual(fixture.state.viewOffset, -120, accuracy: 0.001)
    }

    func testPortraitBottomResizeChangesRenderedRowHeightAndRebasesViewport() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 2_002, to: workspaceId)
        _ = addWindow(engine, pid: 2_002, windowId: 2, to: workspaceId, after: first)
        let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspaceId))
        var state = ViewportState()
        state.jumpOffset(to: 80)
        let frameBefore = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[first.token]
        )

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: first.id,
                edges: .bottom,
                startLocation: CGPoint(x: frameBefore.midX, y: frameBefore.minY),
                in: workspaceId,
                orientation: .vertical,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frameBefore.midX, y: frameBefore.minY + 200),
                monitorFrame: portraitFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0),
                viewportState: { mutate in mutate(&state) }
            )
        )

        let frameAfter = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[first.token]
        )
        XCTAssertEqual(column.height, .fixed(frameBefore.height - 200))
        XCTAssertEqual(column.cachedHeight, frameBefore.height - 200, accuracy: 0.001)
        XCTAssertEqual(frameAfter.height, frameBefore.height - 200, accuracy: 0.001)
        XCTAssertEqual(state.viewOffset, -120, accuracy: 0.001)
        engine.interactiveResizeEnd(
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0
        )
        XCTAssertNil(engine.interactiveResize)
    }

    func testPortraitSingleWindowPrimarySizingChangesRenderedHeight() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 2_004, to: workspaceId)
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        var state = ViewportState()
        _ = portraitLayout(engine, in: workspaceId, state: state)

        engine.setContainerPrimarySpan(
            column,
            change: .setProportion(50),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        var frame = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[window.token]
        )
        XCTAssertEqual(frame.height, 800, accuracy: 0.001)
        XCTAssertEqual(frame.midY, portraitFrame.midY, accuracy: 0.001)

        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[window.token]).height,
            1600,
            accuracy: 0.001
        )
        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        frame = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[window.token]
        )

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .bottom,
                startLocation: CGPoint(x: frame.midX, y: frame.minY),
                in: workspaceId,
                orientation: .vertical,
                viewOffset: state.viewOffset
            )
        )
        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frame.midX, y: frame.minY + 100),
                monitorFrame: portraitFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0),
                viewportState: { mutate in mutate(&state) }
            )
        )
        let resizedFrame = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[window.token]
        )
        XCTAssertEqual(resizedFrame.height, 700, accuracy: 0.001)
        XCTAssertEqual(resizedFrame.midY, portraitFrame.midY, accuracy: 0.001)
    }

    func testPortraitSingleWindowExplicitFullProportionOverridesFitAndBalanceRestoresFit() throws {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = SingleWindowFit(mode: .custom, width: 600, height: 1000)
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 2_005, to: workspaceId)
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        var state = ViewportState()

        engine.setContainerPrimarySpan(
            column,
            change: .setProportion(100),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )

        XCTAssertTrue(column.hasManualSingleWindowHeightOverride)
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[window.token]).height,
            portraitFrame.height,
            accuracy: 0.001
        )

        XCTAssertTrue(
            engine.balanceSizes(
                in: workspaceId,
                motion: .disabled,
                workingFrame: portraitFrame,
                gaps: 0,
                orientation: .vertical
            )
        )
        let balancedFrame = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: state)[window.token]
        )

        XCTAssertFalse(column.hasManualSingleWindowHeightOverride)
        XCTAssertEqual(balancedFrame.width, 600, accuracy: 0.001)
        XCTAssertEqual(balancedFrame.height, 1000, accuracy: 0.001)
    }

    func testPortraitSingleWindowPresetWidthResolvesOnceAndUsesAxisSpecificGaps() throws {
        let engine = NiriLayoutEngine()
        engine.presetWindowSecondarySpans = [.proportion(0.5)]
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 2_006, to: workspaceId)
        window.windowWidth = .preset(0)

        let frame = try XCTUnwrap(
            engine.calculateLayout(
                state: ViewportState(),
                workspaceId: workspaceId,
                monitorFrame: portraitFrame,
                gaps: (horizontal: 20, vertical: 40),
                orientation: .vertical
            )[window.token]
        )

        XCTAssertEqual(frame.width, 420, accuracy: 0.001)
        XCTAssertEqual(frame.height, 740, accuracy: 0.001)
        XCTAssertEqual(frame.midX, portraitFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, portraitFrame.midY, accuracy: 0.001)
    }

    func testPortraitSingleWindowResizeKeepsFixedPixelBaselineAfterTopologyChange() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let window = addWindow(engine, pid: 2_007, to: workspaceId)
        let frame = try XCTUnwrap(
            portraitLayout(engine, in: workspaceId, state: ViewportState())[window.token]
        )

        XCTAssertTrue(
            engine.interactiveResizeBegin(
                windowId: window.id,
                edges: .left,
                startLocation: CGPoint(x: frame.minX, y: frame.midY),
                in: workspaceId,
                orientation: .vertical
            )
        )
        _ = addWindow(engine, pid: 2_007, windowId: 2, to: workspaceId, after: window)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)

        XCTAssertTrue(
            engine.interactiveResizeUpdate(
                currentLocation: CGPoint(x: frame.minX + 100, y: frame.midY),
                monitorFrame: portraitFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )
        XCTAssertEqual(window.windowWidth, .fixed(frame.width - 100))
    }

    func testPortraitPrimarySizingCommandsChangeRenderedRowHeight() throws {
        let engine = NiriLayoutEngine()
        engine.presetContainerPrimarySpans = [.proportion(0.25), .proportion(0.5), .proportion(0.75)]
        let workspaceId = WorkspaceDescriptor.ID()
        let first = addWindow(engine, pid: 2_003, to: workspaceId)
        _ = addWindow(engine, pid: 2_003, windowId: 2, to: workspaceId, after: first)
        let column = try XCTUnwrap(engine.findColumn(containing: first, in: workspaceId))
        var state = ViewportState()
        _ = portraitLayout(engine, in: workspaceId, state: state)
        let horizontalWidth = column.width

        engine.setContainerPrimarySpan(
            column,
            change: .setProportion(50),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            800,
            accuracy: 0.001
        )
        XCTAssertEqual(column.width, horizontalWidth)

        engine.setWindowPrimarySpan(
            first,
            change: .setProportion(75),
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            1200,
            accuracy: 0.001
        )

        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertTrue(column.isFullHeight)
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            1600,
            accuracy: 0.001
        )

        engine.toggleContainerFullPrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        engine.expandContainerToAvailablePrimarySpan(
            column,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertTrue(column.isFullHeight)
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            1600,
            accuracy: 0.001
        )

        engine.toggleContainerPrimarySpan(
            column,
            forwards: true,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertFalse(column.isFullHeight)
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            400,
            accuracy: 0.001
        )

        engine.toggleWindowPrimarySpan(
            first,
            forwards: true,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(portraitLayout(engine, in: workspaceId, state: state)[first.token]).height,
            800,
            accuracy: 0.001
        )
    }

    func testPortraitSecondarySizingCommandsChangeRenderedWindowWidths() throws {
        let fixture = try makeTwoWindowRow()
        fixture.engine.presetWindowSecondarySpans = [
            .proportion(0.25),
            .proportion(0.5),
            .proportion(0.75)
        ]
        _ = portraitLayout(
            fixture.engine,
            in: fixture.workspaceId,
            state: fixture.state
        )
        let horizontalHeight = fixture.first.height

        fixture.engine.setWindowSecondarySpan(
            fixture.first,
            change: .setFixed(300),
            in: fixture.workspaceId,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(
                portraitLayout(
                    fixture.engine,
                    in: fixture.workspaceId,
                    state: fixture.state
                )[fixture.first.token]
            ).width,
            300,
            accuracy: 0.001
        )

        fixture.engine.toggleWindowSecondarySpan(
            fixture.first,
            forwards: true,
            in: fixture.workspaceId,
            workingFrame: portraitFrame,
            gaps: 0,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(
                portraitLayout(
                    fixture.engine,
                    in: fixture.workspaceId,
                    state: fixture.state
                )[fixture.first.token]
            ).width,
            450,
            accuracy: 0.001
        )
        XCTAssertEqual(fixture.first.height, horizontalHeight)

        fixture.engine.resetWindowSecondarySpan(
            fixture.first,
            in: fixture.workspaceId,
            orientation: .vertical
        )
        XCTAssertEqual(
            try XCTUnwrap(
                portraitLayout(
                    fixture.engine,
                    in: fixture.workspaceId,
                    state: fixture.state
                )[fixture.first.token]
            ).width,
            450,
            accuracy: 0.001
        )
    }

    func testPortraitBalanceResetsRenderedPrimaryAndSecondarySpans() throws {
        let fixture = try makeTwoWindowRow()
        fixture.engine.visibleContainerCount = 2
        fixture.column.width = .fixed(700)
        fixture.column.height = .fixed(300)
        fixture.column.cachedHeight = 300
        fixture.first.height = .fixed(250)
        fixture.first.windowWidth = .auto(weight: 2)
        fixture.second.windowWidth = .auto(weight: 1)

        XCTAssertTrue(
            fixture.engine.balanceSizes(
                in: fixture.workspaceId,
                motion: .disabled,
                workingFrame: portraitFrame,
                gaps: 0,
                orientation: .vertical
            )
        )

        let frames = portraitLayout(
            fixture.engine,
            in: fixture.workspaceId,
            state: fixture.state
        )
        XCTAssertEqual(try XCTUnwrap(frames[fixture.first.token]).height, 800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames[fixture.first.token]).width, 450, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames[fixture.second.token]).width, 450, accuracy: 0.001)
        XCTAssertEqual(fixture.column.width, .fixed(700))
        XCTAssertEqual(fixture.first.height, .fixed(250))
    }
}
