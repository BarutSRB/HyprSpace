// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriColumnTransferFeasibilityTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let gaps: CGFloat = 10

    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let windows: [NiriWindow]
        var state = ViewportState()
    }

    private func makeFixture(minHeights: [CGFloat]) -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        var windows: [NiriWindow] = []
        for (index, minHeight) in minHeights.enumerated() {
            let token = WindowToken(pid: 1, windowId: index + 1)
            let window = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            engine.updateWindowConstraints(
                for: token,
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: 1, height: minHeight),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: workspaceId,
                motion: .enabled
            )
            windows.append(window)
        }
        return Fixture(engine: engine, workspaceId: workspaceId, windows: windows)
    }

    private func consume(_ fixture: inout Fixture, window: NiriWindow, into column: NiriContainer) -> Bool {
        fixture.engine.consumeWindow(
            window,
            into: column,
            enteringFrom: .right,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )
    }

    func testConsumeBlockedWhenMinHeightsExceedWorkArea() {
        var fixture = makeFixture(minHeights: [500, 400])
        let targetColumn = fixture.engine.columns(in: fixture.workspaceId)[0]

        XCTAssertFalse(consume(&fixture, window: fixture.windows[1], into: targetColumn))
        XCTAssertEqual(targetColumn.windowNodes.count, 1)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, 2)
    }

    func testConsumeAllowedWhenMinHeightsFit() {
        var fixture = makeFixture(minHeights: [300, 400])
        let targetColumn = fixture.engine.columns(in: fixture.workspaceId)[0]

        XCTAssertTrue(consume(&fixture, window: fixture.windows[1], into: targetColumn))
        XCTAssertEqual(targetColumn.windowNodes.count, 2)
    }

    func testExactFitBoundaryWithinTolerance() {
        var exactFit = makeFixture(minHeights: [385, 385])
        let exactTarget = exactFit.engine.columns(in: exactFit.workspaceId)[0]
        XCTAssertTrue(consume(&exactFit, window: exactFit.windows[1], into: exactTarget))

        var overFit = makeFixture(minHeights: [386, 386])
        let overTarget = overFit.engine.columns(in: overFit.workspaceId)[0]
        XCTAssertFalse(consume(&overFit, window: overFit.windows[1], into: overTarget))
    }

    func testTabbedColumnAlwaysAccepts() {
        var fixture = makeFixture(minHeights: [700, 700])
        let targetColumn = fixture.engine.columns(in: fixture.workspaceId)[0]
        targetColumn.displayMode = .tabbed

        XCTAssertTrue(consume(&fixture, window: fixture.windows[1], into: targetColumn))
        XCTAssertEqual(targetColumn.windowNodes.count, 2)
    }

    func testConsumeWindowIntoColumnBlocked() {
        var fixture = makeFixture(minHeights: [500, 400])
        let targetColumn = fixture.engine.columns(in: fixture.workspaceId)[0]

        let consumed = fixture.engine.consumeWindowIntoColumn(
            focusedColumn: targetColumn,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertFalse(consumed)
        XCTAssertEqual(targetColumn.windowNodes.count, 1)
    }

    func testInsertWindowByMoveCrossColumnBlocked() {
        var fixture = makeFixture(minHeights: [500, 400])
        let sourceColumnCount = fixture.engine.columns(in: fixture.workspaceId).count

        let inserted = fixture.engine.insertWindowByMove(
            sourceWindowId: fixture.windows[1].id,
            targetWindowId: fixture.windows[0].id,
            position: .after,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertFalse(inserted)
        XCTAssertEqual(fixture.engine.columns(in: fixture.workspaceId).count, sourceColumnCount)
    }

    func testSwapBlockedWhenIncomingMinBreaksTargetColumn() {
        var fixture = makeFixture(minHeights: [500, 200, 600])
        let stackedColumn = fixture.engine.columns(in: fixture.workspaceId)[0]
        XCTAssertTrue(consume(&fixture, window: fixture.windows[1], into: stackedColumn))

        let swapped = fixture.engine.swapWindowsByMove(
            sourceWindowId: fixture.windows[2].id,
            targetWindowId: fixture.windows[1].id,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertFalse(swapped)
        XCTAssertTrue(stackedColumn.windowNodes.contains { $0 === fixture.windows[1] })
    }

    func testSwapAllowedWhenMinsRelieveBothColumns() {
        var fixture = makeFixture(minHeights: [500, 200, 50])
        let stackedColumn = fixture.engine.columns(in: fixture.workspaceId)[0]
        XCTAssertTrue(consume(&fixture, window: fixture.windows[1], into: stackedColumn))

        let swapped = fixture.engine.swapWindowsByMove(
            sourceWindowId: fixture.windows[2].id,
            targetWindowId: fixture.windows[1].id,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: .horizontal
        )

        XCTAssertTrue(swapped)
        XCTAssertTrue(stackedColumn.windowNodes.contains { $0 === fixture.windows[2] })
    }

    func testVerticalMonitorSumsMinWidths() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 9),
            displayId: 9,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Vertical"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .vertical]
        )

        var windows: [NiriWindow] = []
        for (index, minWidth) in [CGFloat(500), CGFloat(400)].enumerated() {
            let token = WindowToken(pid: 1, windowId: index + 1)
            let window = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            engine.updateWindowConstraints(
                for: token,
                constraints: WindowSizeConstraints(
                    minSize: CGSize(width: minWidth, height: 1),
                    maxSize: .zero,
                    isFixed: false
                ),
                in: workspaceId,
                motion: .enabled
            )
            windows.append(window)
        }
        let targetColumn = engine.columns(in: workspaceId)[0]

        XCTAssertFalse(
            engine.columnCanAcceptTransfer(
                targetColumn,
                adding: windows[1],
                in: workspaceId,
                workingFrame: frame,
                gaps: gaps,
                orientation: .vertical
            )
        )
        XCTAssertTrue(
            engine.columnCanAcceptTransfer(
                targetColumn,
                adding: windows[1],
                in: workspaceId,
                workingFrame: CGRect(x: 0, y: 0, width: 1000, height: 1200),
                gaps: gaps,
                orientation: .vertical
            )
        )
    }
}
