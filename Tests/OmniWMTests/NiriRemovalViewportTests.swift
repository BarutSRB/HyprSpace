// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriRemovalViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let workingFrame: CGRect
        let orientation: Monitor.Orientation
        let gap: CGFloat
        var state: ViewportState
    }

    private func makeFixture(
        spans: [CGFloat],
        orientation: Monitor.Orientation,
        gap: CGFloat,
        viewportSpan: CGFloat,
        crossSpan: CGFloat,
        centerMode: CenterFocusedColumn = .never
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: centerMode)

        let workspaceId = WorkspaceDescriptor.ID()
        let workingFrame: CGRect = switch orientation {
        case .horizontal:
            CGRect(x: 0, y: 0, width: viewportSpan, height: crossSpan)
        case .vertical:
            CGRect(x: 0, y: 0, width: crossSpan, height: viewportSpan)
        }
        let monitor = Monitor(
            id: Monitor.ID(displayId: 9),
            displayId: 9,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Removal viewport"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: orientation]
        )

        var tokens: [WindowToken] = []
        for index in spans.indices {
            let token = WindowToken(pid: 1, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.append(token)
        }

        let columns = engine.columns(in: workspaceId)
        for (column, span) in zip(columns, spans) {
            switch orientation {
            case .horizontal:
                column.cachedWidth = span
            case .vertical:
                column.cachedHeight = span
            }
        }

        var state = ViewportState()
        let lastIdx = columns.count - 1
        state.activeColumnIndex = lastIdx
        state.selectedNodeId = columns[lastIdx].windowNodes.first?.id
        state.viewOffset = spans[lastIdx] - viewportSpan

        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            tokens: tokens,
            workingFrame: workingFrame,
            orientation: orientation,
            gap: gap,
            state: state
        )
    }

    private func primarySpanKeyPath(
        for orientation: Monitor.Orientation
    ) -> KeyPath<NiriContainer, CGFloat> {
        switch orientation {
        case .horizontal:
            \.cachedWidth
        case .vertical:
            \.cachedHeight
        }
    }

    private func viewOrigin(_ fixture: Fixture) -> CGFloat {
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let activePosition = fixture.state.containerPosition(
            at: fixture.state.activeColumnIndex,
            containers: columns,
            gap: fixture.gap,
            sizeKeyPath: primarySpanKeyPath(for: fixture.orientation)
        )
        return activePosition + fixture.state.viewOffset
    }

    private func focusColumn(at index: Int, in fixture: inout Fixture) {
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let node = columns[index].windowNodes[0]
        fixture.state.selectedNodeId = node.id
        fixture.engine.ensureSelectionVisible(
            node: node,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: fixture.orientation
        )
    }

    private func removeToken(
        at index: Int,
        from fixture: inout Fixture
    ) -> NiriLayoutEngine.NiriRemovalResult {
        fixture.engine.removeWindows(
            [fixture.tokens[index]],
            in: fixture.workspaceId,
            state: &fixture.state,
            motion: .disabled,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: fixture.orientation,
            selectedNodeId: fixture.state.selectedNodeId,
            removedNodeIds: []
        )
    }

    func testReportedTrailingRemovalCorrectsViewportAndRequestsRecalc() {
        var fixture = makeFixture(
            spans: [700, 700, 700],
            orientation: .horizontal,
            gap: 8,
            viewportSpan: 1440,
            crossSpan: 800
        )
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), 676, accuracy: 0.5)

        let result = removeToken(at: 2, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [2])
        XCTAssertTrue(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), -8, accuracy: 0.5)
    }

    func testRemovalLeftOfActiveColumnClampsReachableTrailingViewport() {
        var fixture = makeFixture(
            spans: [500, 500, 500],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800
        )
        XCTAssertEqual(viewOrigin(fixture), 500, accuracy: 0.5)

        let result = removeToken(at: 0, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [0])
        XCTAssertTrue(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), 0, accuracy: 0.5)
    }

    func testNearViewportWidthUsesReducedFitPaddingAfterRemoval() {
        var fixture = makeFixture(
            spans: [500, 995],
            orientation: .horizontal,
            gap: 8,
            viewportSpan: 1000,
            crossSpan: 800
        )
        focusColumn(at: 0, in: &fixture)
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), 505.5, accuracy: 0.5)

        let result = removeToken(at: 0, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [0])
        XCTAssertTrue(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), -2.5, accuracy: 0.5)
    }

    func testVerticalInRangeViewportIsNotRebasedByHorizontalGeometry() {
        var fixture = makeFixture(
            spans: [300, 300, 300],
            orientation: .vertical,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 600
        )
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), -100, accuracy: 0.5)

        let result = removeToken(at: 2, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [2])
        XCTAssertFalse(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), -100, accuracy: 0.5)
    }

    func testAlwaysCenteredSelectionStaysCenteredAfterTrailingRemoval() {
        var fixture = makeFixture(
            spans: [500, 500, 500],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800,
            centerMode: .always
        )
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), 250, accuracy: 0.5)

        let result = removeToken(at: 2, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [2])
        XCTAssertFalse(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), 250, accuracy: 0.5)
    }

    func testOverflowCenteredSelectionStaysCenteredAfterTrailingRemoval() {
        var fixture = makeFixture(
            spans: [700, 700, 700],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800,
            centerMode: .onOverflow
        )
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), 550, accuracy: 0.5)

        let result = removeToken(at: 2, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [2])
        XCTAssertFalse(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), 550, accuracy: 0.5)
    }

    func testOverflowCenteringUsesActivePairWithNarrowEdgeColumns() {
        var fixture = makeFixture(
            spans: [100, 600, 600, 100, 100],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800,
            centerMode: .onOverflow
        )
        focusColumn(at: 1, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), -100, accuracy: 0.5)

        let result = removeToken(at: 4, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [4])
        XCTAssertFalse(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), -100, accuracy: 0.5)
    }

    func testOverflowFitStateClampsAfterTrailingRemovalShrinksContent() {
        var fixture = makeFixture(
            spans: [400, 400, 400, 400],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800,
            centerMode: .onOverflow
        )
        focusColumn(at: 2, in: &fixture)
        XCTAssertEqual(viewOrigin(fixture), 600, accuracy: 0.5)

        let result = removeToken(at: 3, from: &fixture)

        XCTAssertEqual(result.removedColumnIndicesBefore, [3])
        XCTAssertTrue(result.viewportNeedsRecalc)
        XCTAssertEqual(viewOrigin(fixture), 200, accuracy: 0.5)
    }

    func testTileOnlyRemovalDoesNotMutateViewport() throws {
        var fixture = makeFixture(
            spans: [500, 500, 500],
            orientation: .horizontal,
            gap: 0,
            viewportSpan: 1000,
            crossSpan: 800,
            centerMode: .always
        )
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let stackedWindow = columns[1].windowNodes[0]
        XCTAssertTrue(
            fixture.engine.consumeWindow(
                stackedWindow,
                into: columns[0],
                enteringFrom: .right,
                in: fixture.workspaceId,
                motion: .disabled,
                state: &fixture.state,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: fixture.orientation
            )
        )
        for column in fixture.engine.columns(in: fixture.workspaceId) {
            column.cachedWidth = 500
        }
        fixture.state = ViewportState()
        let survivingWindow = try XCTUnwrap(
            fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId)
        )
        fixture.state.selectedNodeId = survivingWindow.id
        fixture.engine.ensureSelectionVisible(
            node: survivingWindow,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: fixture.orientation
        )
        XCTAssertEqual(viewOrigin(fixture), -250, accuracy: 0.5)
        let stateBeforeRemoval = fixture.state

        let result = removeToken(at: 1, from: &fixture)

        XCTAssertTrue(result.removedColumnIndicesBefore.isEmpty)
        XCTAssertFalse(result.viewportNeedsRecalc)
        XCTAssertEqual(fixture.state, stateBeforeRemoval)
    }
}
