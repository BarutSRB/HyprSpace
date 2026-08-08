// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

struct DwindleInteractiveResize {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let edges: ResizeEdge
    let startMouseLocation: CGPoint
    let innerGap: CGFloat

    let horizontalSplitId: DwindleNodeId?
    let horizontalChildId: DwindleNodeId?
    let horizontalOriginRatio: CGFloat?
    let horizontalAxisLength: CGFloat?

    let verticalSplitId: DwindleNodeId?
    let verticalChildId: DwindleNodeId?
    let verticalOriginRatio: CGFloat?
    let verticalAxisLength: CGFloat?

    var didChange = false
}

enum DwindleDropAction: Equatable {
    case swap(targetToken: WindowToken, frame: CGRect)
    case split(targetToken: WindowToken, direction: Direction, isOuterEdge: Bool, frame: CGRect)

    var targetToken: WindowToken {
        switch self {
        case let .swap(token, _): return token
        case let .split(token, _, _, _): return token
        }
    }

    var highlightFrame: CGRect {
        switch self {
        case let .swap(_, frame): return frame
        case let .split(_, _, _, frame): return frame
        }
    }
}

struct DwindleInteractiveMove {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let screenFrame: CGRect
    var currentHoverToken: WindowToken?
    var currentDropAction: DwindleDropAction?
    /// Tiling frames (node.cachedFrame, not content/gap-inset) for every window computed from
    /// the most recent tempState layout during this drag. Used by interactiveMoveUpdate so hover
    /// zones are based on the windows' *displayed* positions rather than their pre-drag positions.
    var dragTimeTilingFrames: [WindowToken: CGRect] = [:]
}

extension DwindleLayoutEngine {
    func interactiveMoveBegin(
        token: WindowToken,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard interactiveMove == nil, interactiveResize == nil else { return false }
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf else { return false }
        let rootFrame = states[workspaceId]?.root.cachedFrame ?? leaf.cachedFrame ?? .zero
        interactiveMove = DwindleInteractiveMove(
            token: token,
            workspaceId: workspaceId,
            startMouseLocation: startLocation,
            screenFrame: rootFrame
        )
        return true
    }

    private func resolveContainerTarget(
        from leaf: DwindleNode,
        direction: Direction
    ) -> (node: DwindleNode, frame: CGRect) {
        var current = leaf
        var currentFrame = leaf.cachedFrame ?? .zero

        while let parent = current.parent, let parentFrame = parent.cachedFrame {
            guard case let .split(orientation, _) = parent.kind else { break }

            let isPerpendicular: Bool = switch direction {
            case .left, .right: orientation == .vertical
            case .up, .down: orientation == .horizontal
            }

            let isOuterBoundary: Bool = switch direction {
            case .left: orientation == .horizontal && current.isFirstChild(of: parent)
            case .right: orientation == .horizontal && current.isSecondChild(of: parent)
            case .down: orientation == .vertical && current.isFirstChild(of: parent)
            case .up: orientation == .vertical && current.isSecondChild(of: parent)
            }

            if isPerpendicular || isOuterBoundary {
                current = parent
                currentFrame = parentFrame
            } else {
                break
            }
        }

        return (current, currentFrame)
    }

    func interactiveMoveUpdate(currentLocation: CGPoint) -> DwindleDropAction? {
        guard let move = interactiveMove,
              let state = states[move.workspaceId]
        else { return nil }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let screen = state.root.cachedFrame ?? move.screenFrame

        // Prefer drag-time tiling frames (current tempState positions) so all zone detection
        // operates on where windows are *displayed*, not their stale pre-drag cachedFrames.
        let dragFrames = move.dragTimeTilingFrames

        let activeLeaves = state.leafByToken.compactMap { (tok, node) -> (WindowToken, DwindleNode, CGRect)? in
            guard tok != move.token else { return nil }
            let frame = dragFrames[tok] ?? node.cachedFrame
            guard let frame else { return nil }
            return (tok, node, frame)
        }

        guard !activeLeaves.isEmpty else {
            interactiveMove?.currentHoverToken = nil
            interactiveMove?.currentDropAction = nil
            return nil
        }

        var unionBox = activeLeaves[0].2
        for item in activeLeaves {
            unionBox = unionBox.union(item.2)
        }

        let action: DwindleDropAction
        let relScreenX = (currentLocation.x - screen.minX) / max(screen.width, 1)
        let relScreenY = (currentLocation.y - screen.minY) / max(screen.height, 1)

        let isOutsideUnion = currentLocation.x > unionBox.maxX || currentLocation.x < unionBox.minX || currentLocation.y > unionBox.maxY || currentLocation.y < unionBox.minY

        if isOutsideUnion && (currentLocation.x > unionBox.maxX || relScreenX > 0.85) {
            let targetToken = activeLeaves.max(by: { $0.2.maxX < $1.2.maxX })!.0
            let frame = CGRect(
                x: screen.midX,
                y: screen.minY,
                width: screen.width / 2,
                height: screen.height
            )
            action = .split(targetToken: targetToken, direction: .right, isOuterEdge: true, frame: frame)
        } else if isOutsideUnion && (currentLocation.x < unionBox.minX || relScreenX < 0.15) {
            let targetToken = activeLeaves.min(by: { $0.2.minX < $1.2.minX })!.0
            let frame = CGRect(
                x: screen.minX,
                y: screen.minY,
                width: screen.width / 2,
                height: screen.height
            )
            action = .split(targetToken: targetToken, direction: .left, isOuterEdge: true, frame: frame)
        } else if isOutsideUnion && (currentLocation.y > unionBox.maxY || relScreenY > 0.85) {
            let targetToken = activeLeaves.max(by: { $0.2.maxY < $1.2.maxY })!.0
            let frame = CGRect(
                x: screen.minX,
                y: screen.midY,
                width: screen.width,
                height: screen.height / 2
            )
            action = .split(targetToken: targetToken, direction: .up, isOuterEdge: true, frame: frame)
        } else if isOutsideUnion && (currentLocation.y < unionBox.minY || relScreenY < 0.15) {
            let targetToken = activeLeaves.min(by: { $0.2.minY < $1.2.minY })!.0
            let frame = CGRect(
                x: screen.minX,
                y: screen.minY,
                width: screen.width,
                height: screen.height / 2
            )
            action = .split(targetToken: targetToken, direction: .down, isOuterEdge: true, frame: frame)
        } else {
            let targetToken: WindowToken
            if let hit = hitTestFocusableWindow(point: currentLocation, in: move.workspaceId, at: now), hit != move.token {
                targetToken = hit
            } else {
                // Fall back to closest window by center distance using drag-time frames.
                targetToken = activeLeaves.min(by: {
                    let d0 = hypot($0.2.midX - currentLocation.x, $0.2.midY - currentLocation.y)
                    let d1 = hypot($1.2.midX - currentLocation.x, $1.2.midY - currentLocation.y)
                    return d0 < d1
                })!.0
            }

            guard let targetNode = findNode(for: targetToken, in: move.workspaceId) else {
                interactiveMove?.currentHoverToken = nil
                interactiveMove?.currentDropAction = nil
                return nil
            }

            // Use drag-time tiling frame for zone calculation so relX/relY reflect the
            // window's current displayed extent, not its stale pre-drag position.
            let targetFrame = dragFrames[targetToken] ?? targetNode.cachedFrame ?? .zero

            let relX = min(max((currentLocation.x - targetFrame.minX) / max(targetFrame.width, 1), 0), 1)
            let relY = min(max((currentLocation.y - targetFrame.minY) / max(targetFrame.height, 1), 0), 1)

            if relY > 0.70 {
                let frame = CGRect(
                    x: targetFrame.minX,
                    y: targetFrame.minY + targetFrame.height / 2,
                    width: targetFrame.width,
                    height: targetFrame.height / 2
                )
                action = .split(targetToken: targetToken, direction: .up, isOuterEdge: false, frame: frame)
            } else if relY < 0.30 {
                let frame = CGRect(
                    x: targetFrame.minX,
                    y: targetFrame.minY,
                    width: targetFrame.width,
                    height: targetFrame.height / 2
                )
                action = .split(targetToken: targetToken, direction: .down, isOuterEdge: false, frame: frame)
            } else if relX < 0.30 {
                let frame = CGRect(
                    x: targetFrame.minX,
                    y: targetFrame.minY,
                    width: targetFrame.width / 2,
                    height: targetFrame.height
                )
                action = .split(targetToken: targetToken, direction: .left, isOuterEdge: false, frame: frame)
            } else if relX > 0.70 {
                let frame = CGRect(
                    x: targetFrame.midX,
                    y: targetFrame.minY,
                    width: targetFrame.width / 2,
                    height: targetFrame.height
                )
                action = .split(targetToken: targetToken, direction: .right, isOuterEdge: false, frame: frame)
            } else {
                action = .swap(targetToken: targetToken, frame: targetFrame)
            }
        }

        interactiveMove?.currentHoverToken = action.targetToken
        interactiveMove?.currentDropAction = action
        return action
    }

    @discardableResult
    func interactiveMoveEnd(at location: CGPoint) -> (movedToken: WindowToken, targetToken: WindowToken)? {
        guard let move = interactiveMove else { return nil }
        let movedToken = move.token
        let wsId = move.workspaceId
        // NOTE: Do NOT use `defer` here — we must clear interactiveMove BEFORE calling
        // calculateLayout so it takes the real-state path (not the tempState clone path).

        let dropAction = move.currentDropAction ?? interactiveMoveUpdate(currentLocation: location)
        guard let dropAction,
              let movedNode = findNode(for: movedToken, in: wsId),
              let targetNode = findNode(for: dropAction.targetToken, in: wsId),
              let state = states[wsId]
        else {
            interactiveMove = nil
            return nil
        }
        assertSanctionedMutation()

        switch dropAction {
        case let .swap(targetToken, _):
            guard let tile1 = movedNode.tile, let tile2 = targetNode.tile else {
                interactiveMove = nil
                return nil
            }
            movedNode.kind = DwindleNodeKind.leaf(tile: tile2)
            targetNode.kind = DwindleNodeKind.leaf(tile: tile1)

            let currentCachedFrame = movedNode.cachedFrame
            movedNode.cachedFrame = targetNode.cachedFrame
            targetNode.cachedFrame = currentCachedFrame

            let currentContentFrame = movedNode.cachedContentFrame
            movedNode.cachedContentFrame = targetNode.cachedContentFrame
            targetNode.cachedContentFrame = currentContentFrame

            movedNode.clearAnimations()
            targetNode.clearAnimations()

            for member in tile1.members {
                state.leafByToken[member.token] = targetNode
            }
            for member in tile2.members {
                state.leafByToken[member.token] = movedNode
            }
            state.selectedNodeId = targetNode.id
            interactiveMove = nil
            return (movedToken, targetToken)

        case let .split(targetToken, direction, isOuterEdge, _):
            if movedNode.parent != nil {
                cleanupAfterRemoval(movedNode, state: state)
                state.leafByToken[movedToken] = movedNode
            }

            // After cleanupAfterRemoval, the old targetNode may have been "absorbed" into
            // its parent (parent.kind = sibling.kind, sibling abandoned). Re-fetch the canonical
            // node for targetToken so containerNode resolution uses the live, current node.
            let refreshedTargetNode = findNode(for: targetToken, in: wsId) ?? targetNode
            let containerNode = isOuterEdge ? resolveContainerTarget(from: refreshedTargetNode, direction: direction).node : refreshedTargetNode

            let isHorizontal = (direction == .left || direction == .right)
            let orientation: DwindleOrientation = isHorizontal ? .horizontal : .vertical
            let splitRatio = settings.defaultSplitRatio
            let newSplit = DwindleNode(kind: .split(orientation: orientation, ratio: splitRatio))

            if let targetParent = containerNode.parent {
                if let index = targetParent.children.firstIndex(where: { $0.id == containerNode.id }) {
                    targetParent.children[index] = newSplit
                    newSplit.parent = targetParent
                }
                containerNode.parent = newSplit
                movedNode.parent = newSplit

                if direction == .left || direction == .down {
                    newSplit.children = [movedNode, containerNode]
                } else {
                    newSplit.children = [containerNode, movedNode]
                }
            } else {
                let savedTarget = DwindleNode(kind: containerNode.kind)
                savedTarget.children = containerNode.children
                for child in savedTarget.children {
                    child.parent = savedTarget
                }
                if let tile = savedTarget.tile {
                    for member in tile.members {
                        state.leafByToken[member.token] = savedTarget
                    }
                }

                savedTarget.parent = state.root
                movedNode.parent = state.root

                state.root.kind = .split(orientation: orientation, ratio: splitRatio)
                if direction == .left || direction == .down {
                    state.root.children = [movedNode, savedTarget]
                } else {
                    state.root.children = [savedTarget, movedNode]
                }
            }

            movedNode.clearAnimations()
            targetNode.clearAnimations()
            state.selectedNodeId = movedNode.id
            // Clear move state FIRST so calculateLayout uses the real mutated state
            // (not the tempState clone it creates during active drags).
            let screenToUse = state.root.cachedFrame ?? move.screenFrame
            interactiveMove = nil
            _ = calculateLayout(for: wsId, screen: screenToUse)
            return (movedToken, targetToken)
        }
    }

    func interactiveMoveCancel() {
        interactiveMove = nil
    }

    func interactiveResizeBegin(
        token: WindowToken,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat
    ) -> Bool {
        guard interactiveResize == nil, interactiveMove == nil else { return false }
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf else { return false }

        let horizontal = resolveControllingSplit(from: leaf, edges: edges, axis: .horizontal)
        let vertical = resolveControllingSplit(from: leaf, edges: edges, axis: .vertical)

        guard horizontal != nil || vertical != nil else { return false }

        interactiveResize = DwindleInteractiveResize(
            token: token,
            workspaceId: workspaceId,
            edges: edges,
            startMouseLocation: startLocation,
            innerGap: innerGap,
            horizontalSplitId: horizontal?.split.id,
            horizontalChildId: horizontal?.child.id,
            horizontalOriginRatio: horizontal?.split.splitRatio,
            horizontalAxisLength: horizontal?.axisLength,
            verticalSplitId: vertical?.split.id,
            verticalChildId: vertical?.child.id,
            verticalOriginRatio: vertical?.split.splitRatio,
            verticalAxisLength: vertical?.axisLength
        )
        return true
    }

    func interactiveResizeUpdate(currentLocation: CGPoint) -> Bool {
        guard let resize = interactiveResize else { return false }
        guard let leaf = findNode(for: resize.token, in: resize.workspaceId), leaf.isLeaf else {
            clearInteractiveResize()
            return false
        }

        let deltaX = currentLocation.x - resize.startMouseLocation.x
        let deltaY = currentLocation.y - resize.startMouseLocation.y

        var changed = false
        assertSanctionedMutation()

        if updateAxisSplit(
            for: leaf,
            resize: resize,
            axis: .horizontal,
            wantFirstChild: resize.edges.contains(.right),
            splitId: resize.horizontalSplitId,
            childId: resize.horizontalChildId,
            originRatio: resize.horizontalOriginRatio,
            axisLength: resize.horizontalAxisLength,
            delta: deltaX
        ) {
            changed = true
        }

        if updateAxisSplit(
            for: leaf,
            resize: resize,
            axis: .vertical,
            wantFirstChild: resize.edges.contains(.top),
            splitId: resize.verticalSplitId,
            childId: resize.verticalChildId,
            originRatio: resize.verticalOriginRatio,
            axisLength: resize.verticalAxisLength,
            delta: deltaY
        ) {
            changed = true
        }

        if changed {
            interactiveResize?.didChange = true
        }
        return changed
    }

    @discardableResult
    func interactiveResizeEnd() -> Bool {
        guard let resize = interactiveResize else { return false }
        defer { interactiveResize = nil }
        return resize.didChange
    }

    func interactiveResizeCancel() {
        interactiveResize = nil
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func cancelAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = states[workspaceId]?.root else { return }
        clearAnimationsRecursive(root)
    }

    private func clearAnimationsRecursive(_ node: DwindleNode) {
        node.clearAnimations()
        for child in node.children {
            clearAnimationsRecursive(child)
        }
    }

    private func updateAxisSplit(
        for leaf: DwindleNode,
        resize: DwindleInteractiveResize,
        axis: DwindleOrientation,
        wantFirstChild: Bool,
        splitId: DwindleNodeId?,
        childId: DwindleNodeId?,
        originRatio: CGFloat?,
        axisLength: CGFloat?,
        delta: CGFloat
    ) -> Bool {
        guard let splitId, let childId, let originRatio, let axisLength,
              let match = controllingSplit(from: leaf, orientation: axis, wantFirstChild: wantFirstChild),
              match.split.id == splitId,
              match.child.id == childId
        else {
            return false
        }

        let newRatio = clampedRatioRespectingMinimums(
            originRatio + 2 * delta / axisLength,
            for: match.split,
            innerGap: resize.innerGap
        )
        guard newRatio != match.split.splitRatio else { return false }
        match.split.kind = .split(orientation: axis, ratio: newRatio)
        return true
    }

    private func resolveControllingSplit(
        from leaf: DwindleNode,
        edges: ResizeEdge,
        axis: DwindleOrientation
    ) -> (split: DwindleNode, child: DwindleNode, axisLength: CGFloat)? {
        let wantFirstChild: Bool
        switch axis {
        case .horizontal:
            if edges.contains(.right) {
                wantFirstChild = true
            } else if edges.contains(.left) {
                wantFirstChild = false
            } else {
                return nil
            }
        case .vertical:
            if edges.contains(.top) {
                wantFirstChild = true
            } else if edges.contains(.bottom) {
                wantFirstChild = false
            } else {
                return nil
            }
        }

        guard let match = controllingSplit(from: leaf, orientation: axis, wantFirstChild: wantFirstChild),
              let frame = match.split.cachedFrame
        else {
            return nil
        }
        let axisLength = axis == .horizontal ? frame.width : frame.height
        guard axisLength.isFinite, axisLength > 0 else { return nil }
        return (match.split, match.child, axisLength)
    }

    private func controllingSplit(
        from leaf: DwindleNode,
        orientation: DwindleOrientation,
        wantFirstChild: Bool
    ) -> (split: DwindleNode, child: DwindleNode)? {
        var child = leaf
        var current = leaf.parent
        while let parent = current {
            if case let .split(splitOrientation, _) = parent.kind,
               splitOrientation == orientation,
               child.isFirstChild(of: parent) == wantFirstChild
            {
                return (parent, child)
            }
            child = parent
            current = parent.parent
        }
        return nil
    }

    func handleExternalFrameChange(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrame: CGRect,
        newFrame: CGRect,
        innerGap: CGFloat
    ) -> Bool {
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf else { return false }

        let deltaMinX = newFrame.minX - oldFrame.minX
        let deltaMaxX = newFrame.maxX - oldFrame.maxX
        let deltaMinY = newFrame.minY - oldFrame.minY
        let deltaMaxY = newFrame.maxY - oldFrame.maxY

        let isHorizontalMove = abs(deltaMinX) > 0.5 && abs(deltaMaxX) > 0.5 && abs(deltaMinX - deltaMaxX) < 2.0
        let isVerticalMove = abs(deltaMinY) > 0.5 && abs(deltaMaxY) > 0.5 && abs(deltaMinY - deltaMaxY) < 2.0
        let isSizeUnchanged = abs(newFrame.width - oldFrame.width) < 2.0 && abs(newFrame.height - oldFrame.height) < 2.0
        let isPureTranslation = (isHorizontalMove || isVerticalMove) && isSizeUnchanged

        if isPureTranslation {
            let now = animationClock?.now() ?? CACurrentMediaTime()
            let newCenter = CGPoint(x: newFrame.midX, y: newFrame.midY)
            if let targetToken = hitTestFocusableWindow(point: newCenter, in: workspaceId, at: now),
               targetToken != token,
               let targetNode = findNode(for: targetToken, in: workspaceId),
               let tile1 = leaf.tile,
               let tile2 = targetNode.tile,
               let state = states[workspaceId]
            {
                leaf.kind = DwindleNodeKind.leaf(tile: tile2)
                targetNode.kind = DwindleNodeKind.leaf(tile: tile1)

                let currentCachedFrame = leaf.cachedFrame
                leaf.cachedFrame = targetNode.cachedFrame
                targetNode.cachedFrame = currentCachedFrame

                let currentContentFrame = leaf.cachedContentFrame
                leaf.cachedContentFrame = targetNode.cachedContentFrame
                targetNode.cachedContentFrame = currentContentFrame

                leaf.clearAnimations()
                targetNode.clearAnimations()

                for member in tile1.members {
                    state.leafByToken[member.token] = targetNode
                }
                for member in tile2.members {
                    state.leafByToken[member.token] = leaf
                }

                state.selectedNodeId = targetNode.id
                return true
            } else {
                leaf.cachedFrame = newFrame
                return true
            }
        }

        var changed = false

        let deltaWidth = newFrame.width - oldFrame.width
        if abs(deltaWidth) > 0.5 {
            var current = leaf
            while let parent = current.parent {
                if case let .split(orientation, _) = parent.kind,
                   orientation == .horizontal,
                   let parentFrame = parent.cachedFrame, parentFrame.width > 0,
                   let ratio = parent.splitRatio
                {
                    let isFirst = current.isFirstChild(of: parent)
                    let sign: CGFloat = isFirst ? 1.0 : -1.0
                    let candidate = ratio + sign * (2.0 * deltaWidth / parentFrame.width)
                    let updated = clampedRatioRespectingMinimums(candidate, for: parent, innerGap: innerGap)
                    if updated != ratio {
                        parent.kind = .split(orientation: .horizontal, ratio: updated)
                        changed = true
                    }
                    break
                }
                current = parent
            }
        }

        let deltaHeight = newFrame.height - oldFrame.height
        if abs(deltaHeight) > 0.5 {
            var current = leaf
            while let parent = current.parent {
                if case let .split(orientation, _) = parent.kind,
                   orientation == .vertical,
                   let parentFrame = parent.cachedFrame, parentFrame.height > 0,
                   let ratio = parent.splitRatio
                {
                    let isFirst = current.isFirstChild(of: parent)
                    let sign: CGFloat = isFirst ? 1.0 : -1.0
                    let candidate = ratio + sign * (2.0 * deltaHeight / parentFrame.height)
                    let updated = clampedRatioRespectingMinimums(candidate, for: parent, innerGap: innerGap)
                    if updated != ratio {
                        parent.kind = .split(orientation: .vertical, ratio: updated)
                        changed = true
                    }
                    break
                }
                current = parent
            }
        }

        if changed {
            leaf.cachedFrame = newFrame
        }

        return changed
    }
}
