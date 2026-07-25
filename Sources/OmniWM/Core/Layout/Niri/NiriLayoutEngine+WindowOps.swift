// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        orientation: Monitor.Orientation? = nil,
        motion: MotionSnapshot,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        allowEdgeWrap: Bool = true
    ) -> Bool {
        assertSanctionedMutation()
        let orientation = resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        if let step = direction.primaryStep(for: orientation) {
            return consumeOrExpelWindow(
                node,
                direction: step > 0 ? .right : .left,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                allowEdgeWrap: allowEdgeWrap
            )
        }

        guard let step = direction.secondaryStep(for: orientation) else { return false }
        return moveWindowWithinContainer(node, step: step)
    }

    func moveWindowWithinContainer(_ node: NiriWindow, step: Int) -> Bool {
        assertSanctionedMutation()
        guard let column = node.parent as? NiriContainer else {
            return false
        }

        let sibling = step > 0 ? node.nextSibling() : node.prevSibling()
        guard let targetSibling = sibling else {
            return false
        }

        let nodeIdx = column.windowNodes.firstIndex { $0 === node }
        let siblingIdx = column.windowNodes.firstIndex { $0 === targetSibling }

        node.swapWith(targetSibling)

        if column.displayMode == .tabbed, let nIdx = nodeIdx, let sIdx = siblingIdx {
            if nIdx == column.activeTileIdx {
                column.setActiveTileIdx(sIdx)
            } else if sIdx == column.activeTileIdx {
                column.setActiveTileIdx(nIdx)
            }
        }

        return true
    }
}
