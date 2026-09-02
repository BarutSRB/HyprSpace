// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleInteractiveMove {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startLocation: CGPoint
    var targetToken: WindowToken?
}

extension DwindleLayoutEngine {
    func interactiveMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard interactiveResize == nil,
              interactiveMove == nil,
              let leaf = findNode(for: token, in: workspaceId),
              leaf.isLeaf,
              !isWindowFullscreen(token, in: workspaceId)
        else { return false }
        interactiveMove = DwindleInteractiveMove(token: token, workspaceId: workspaceId, startLocation: startLocation)
        return true
    }

    func interactiveMoveUpdate(currentLocation: CGPoint, at time: TimeInterval) -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        guard let source = findNode(for: move.token, in: move.workspaceId) else {
            interactiveMoveCancel()
            return nil
        }
        let target = hitTestFocusableWindow(point: currentLocation, in: move.workspaceId, at: time)
            .flatMap { candidate -> WindowToken? in
                guard let node = findNode(for: candidate, in: move.workspaceId),
                      node !== source,
                      !isWindowFullscreen(candidate, in: move.workspaceId)
                else { return nil }
                return candidate
            }
        interactiveMove?.targetToken = target
        return target
    }

    @discardableResult
    func interactiveMoveEnd() -> WindowToken? {
        guard let move = interactiveMove else { return nil }
        interactiveMove = nil
        guard let targetToken = move.targetToken,
              swapLeafTiles(of: move.token, and: targetToken, in: move.workspaceId)
        else { return nil }
        return targetToken
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }
}
