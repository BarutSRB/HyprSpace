// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriProjectedViewportAnchorTests: XCTestCase {
    /// External focus (mouse click, Cmd+Tab) moves `selectedNodeId` before the viewport math runs.
    /// With a macOS-hidden column on the workspace that math goes through the projection, whose
    /// anchor must stay the durable `activeColumnIndex` that `viewOffset` is relative to. Otherwise
    /// the newly focused left column is drawn one column to the right and the left half is empty.
    func testExternalFocusWithHiddenColumnKeepsViewOrigin() throws {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: .never)

        let workspaceId = WorkspaceDescriptor.ID()
        let gap: CGFloat = 16
        let workingFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 7),
            displayId: 7,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Projected anchor"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: .horizontal]
        )

        let tokens = (1 ... 3).map { WindowToken(pid: 1, windowId: $0) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let columnSpan = (workingFrame.width - gap) * 0.5 - gap
        for column in engine.columns(in: workspaceId) {
            column.width = .proportion(0.5)
            column.cachedWidth = columnSpan
        }
        // The third column belongs to a macOS-hidden app: still in the tree, excluded from projection.
        engine.setProjectionExclusions([tokens[2]], in: workspaceId)

        let leftWindow = try XCTUnwrap(engine.findNode(for: tokens[0], in: workspaceId))
        let rightWindow = try XCTUnwrap(engine.findNode(for: tokens[1], in: workspaceId))

        // Settled on the right column with both visible columns on screen.
        var state = ViewportState()
        state.activeColumnIndex = 1
        state.selectedNodeId = rightWindow.id
        state.jumpOffset(to: -(columnSpan + gap * 2))
        let settledFrames = frames(engine: engine, workspaceId: workspaceId, state: state, gap: gap)
        let settledOrigin = viewOrigin(engine: engine, workspaceId: workspaceId, state: state, gap: gap)

        // Selection moves first (as in NiriLayoutHandler.activateNode); the anchor must not follow yet.
        state.selectedNodeId = leftWindow.id
        XCTAssertEqual(
            engine.projectedActiveColumnIndex(
                state: state,
                columns: engine.projectedColumns(in: workspaceId),
                in: workspaceId
            ),
            1
        )
        let transitionalFrames = frames(engine: engine, workspaceId: workspaceId, state: state, gap: gap)
        XCTAssertEqual(transitionalFrames[tokens[0]], settledFrames[tokens[0]])
        XCTAssertEqual(transitionalFrames[tokens[1]], settledFrames[tokens[1]])

        engine.ensureSelectionVisible(
            node: leftWindow,
            in: workspaceId,
            motion: .disabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gap,
            orientation: .horizontal
        )

        XCTAssertEqual(state.activeColumnIndex, 0)
        XCTAssertEqual(state.viewOffset, -gap, accuracy: 0.001)
        XCTAssertEqual(
            viewOrigin(engine: engine, workspaceId: workspaceId, state: state, gap: gap),
            settledOrigin,
            accuracy: 0.001
        )
        let focusedFrames = frames(engine: engine, workspaceId: workspaceId, state: state, gap: gap)
        XCTAssertEqual(focusedFrames[tokens[0]], settledFrames[tokens[0]])
        XCTAssertEqual(focusedFrames[tokens[1]], settledFrames[tokens[1]])
    }

    private func frames(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        gap: CGFloat
    ) -> [WindowToken: CGRect] {
        let monitorFrame = engine.monitorForWorkspace(workspaceId)?.frame ?? .zero
        return engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: monitorFrame,
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal
        )
    }

    private func viewOrigin(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        gap: CGFloat
    ) -> CGFloat {
        state.containerPosition(
            at: state.activeColumnIndex,
            containers: engine.columns(in: workspaceId),
            gap: gap,
            sizeKeyPath: \.cachedWidth
        ) + state.viewOffset
    }
}
