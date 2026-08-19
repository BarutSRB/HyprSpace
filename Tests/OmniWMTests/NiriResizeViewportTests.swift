// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriResizeViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let workingFrame: CGRect
        let gap: CGFloat
        let columnSpan: CGFloat
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var trailingColumn: NiriContainer {
            columns[columns.count - 1]
        }

        var fullSpan: CGFloat {
            workingFrame.width - gap * 2
        }

        var rightAlignedOffset: CGFloat {
            -(workingFrame.width - gap - columnSpan)
        }

        func viewStart(sizeKeyPath: KeyPath<NiriContainer, CGFloat>) -> CGFloat {
            state.containerPosition(
                at: state.activeColumnIndex,
                containers: columns,
                gap: gap,
                sizeKeyPath: sizeKeyPath
            ) + state.viewOffset
        }
    }

    private func makeFixture(
        columnCount: Int,
        gap: CGFloat = 16,
        viewportWidth: CGFloat = 2_560,
        viewportHeight: CGFloat = 1_440
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)

        let workspaceId = WorkspaceDescriptor.ID()
        let workingFrame = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Resize viewport"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )

        for index in 0 ..< columnCount {
            _ = engine.addWindow(
                token: WindowToken(pid: 1, windowId: index + 1),
                to: workspaceId,
                afterSelection: nil
            )
        }

        let columnSpan = (viewportWidth - gap) * 0.5 - gap
        let columns = engine.columns(in: workspaceId)
        for column in columns {
            column.width = .proportion(0.5)
            column.cachedWidth = columnSpan
        }

        var state = ViewportState()
        let lastIndex = columns.count - 1
        state.activeColumnIndex = lastIndex
        state.selectedNodeId = columns[lastIndex].windowNodes.first?.id
        state.jumpOffset(to: -(viewportWidth - gap - columnSpan))

        return Fixture(
            engine: engine,
            workspaceId: workspaceId,
            workingFrame: workingFrame,
            gap: gap,
            columnSpan: columnSpan,
            state: state
        )
    }

    private func applyRelayoutViewportPasses(_ fixture: inout Fixture) -> Bool {
        let selectedId = fixture.state.selectedNodeId
        if let selectedId, let node = fixture.engine.findNode(by: selectedId, in: fixture.workspaceId) {
            fixture.engine.ensureSelectionVisible(
                node: node,
                in: fixture.workspaceId,
                motion: .enabled,
                state: &fixture.state,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            )
        }
        return fixture.engine.correctViewportAfterColumnRemoval(
            in: fixture.workspaceId,
            state: &fixture.state,
            motion: .enabled,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
    }

    func testFullPrimarySpanOnTrailingColumnSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            in: fixture.workspaceId,
            motion: .enabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )

        XCTAssertEqual(trailing.settledWidth, fixture.fullSpan, accuracy: 0.001)
        XCTAssertEqual(trailing.cachedWidth, fixture.columnSpan, accuracy: 0.001)
        XCTAssertEqual(fixture.state.viewOffset, -fixture.gap, accuracy: 0.001)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, -fixture.gap, accuracy: 0.001)
    }

    func testIncreasingTrailingColumnPrimarySpanSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.setContainerPrimarySpan(
            trailing,
            change: .adjustProportion(10),
            in: fixture.workspaceId,
            motion: .enabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )

        let grownSpan = (fixture.workingFrame.width - fixture.gap) * 0.6 - fixture.gap
        let expectedOffset = -(fixture.workingFrame.width - fixture.gap - grownSpan)
        XCTAssertEqual(trailing.settledWidth, grownSpan, accuracy: 0.001)
        XCTAssertEqual(fixture.state.viewOffset, expectedOffset, accuracy: 0.001)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, expectedOffset, accuracy: 0.001)
    }

    func testCyclingTrailingColumnPrimarySpanSurvivesRelayoutViewportPasses() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerPrimarySpan(
            trailing,
            forwards: true,
            in: fixture.workspaceId,
            motion: .enabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )

        let grownSpan = trailing.settledWidth
        XCTAssertGreaterThan(grownSpan, fixture.columnSpan)
        let offsetAfterResize = fixture.state.viewOffset
        XCTAssertEqual(
            fixture.viewStart(sizeKeyPath: \.settledWidth) + fixture.workingFrame.width - fixture.gap,
            fixture.state.containerPosition(
                at: fixture.state.activeColumnIndex,
                containers: fixture.columns,
                gap: fixture.gap,
                sizeKeyPath: \.settledWidth
            ) + grownSpan,
            accuracy: 0.001
        )

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, offsetAfterResize, accuracy: 0.001)
    }

    func testUntogglingFullPrimarySpanKeepsTrailingColumnRightAligned() throws {
        var fixture = makeFixture(columnCount: 3)
        let trailing = fixture.trailingColumn

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            in: fixture.workspaceId,
            motion: .disabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )
        XCTAssertEqual(trailing.cachedWidth, fixture.fullSpan, accuracy: 0.001)

        fixture.engine.toggleContainerFullPrimarySpan(
            trailing,
            in: fixture.workspaceId,
            motion: .enabled,
            state: &fixture.state,
            workingFrame: fixture.workingFrame,
            gaps: fixture.gap,
            orientation: .horizontal
        )

        XCTAssertEqual(trailing.settledWidth, fixture.columnSpan, accuracy: 0.001)
        XCTAssertEqual(trailing.cachedWidth, fixture.fullSpan, accuracy: 0.001)
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset, accuracy: 0.001)

        XCTAssertFalse(applyRelayoutViewportPasses(&fixture))
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset, accuracy: 0.001)
    }

    func testViewportClampStillCorrectsOffsetScrolledPastContent() throws {
        var fixture = makeFixture(columnCount: 3)
        fixture.state.jumpOffset(to: -fixture.gap)

        XCTAssertTrue(
            fixture.engine.correctViewportAfterColumnRemoval(
                in: fixture.workspaceId,
                state: &fixture.state,
                motion: .disabled,
                workingFrame: fixture.workingFrame,
                gaps: fixture.gap,
                orientation: .horizontal
            )
        )
        XCTAssertEqual(fixture.state.viewOffset, fixture.rightAlignedOffset, accuracy: 0.001)
    }
}
