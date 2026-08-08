// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

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

extension DwindleLayoutEngine {
    func interactiveResizeBegin(
        token: WindowToken,
        edges: ResizeEdge,
        startLocation: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        innerGap: CGFloat
    ) -> Bool {
        guard interactiveResize == nil else { return false }
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf, !leaf.isFullscreen else { return false }

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

        var changed = false
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: .horizontal,
            wantFirstChild: resize.edges.contains(.right),
            splitId: resize.horizontalSplitId,
            childId: resize.horizontalChildId,
            originRatio: resize.horizontalOriginRatio,
            axisLength: resize.horizontalAxisLength,
            delta: currentLocation.x - resize.startMouseLocation.x
        ) {
            changed = true
        }
        if applyAxis(
            resize: resize,
            leaf: leaf,
            axis: .vertical,
            wantFirstChild: resize.edges.contains(.top),
            splitId: resize.verticalSplitId,
            childId: resize.verticalChildId,
            originRatio: resize.verticalOriginRatio,
            axisLength: resize.verticalAxisLength,
            delta: currentLocation.y - resize.startMouseLocation.y
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
        let didChange = interactiveResize?.didChange ?? false
        interactiveResize = nil
        return didChange
    }

    func clearInteractiveResize() {
        interactiveResize = nil
    }

    func cancelAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = root(for: workspaceId) else { return }
        clearAnimationsRecursive(root)
    }

    private func clearAnimationsRecursive(_ node: DwindleNode) {
        node.clearAnimations()
        for child in node.children {
            clearAnimationsRecursive(child)
        }
    }

    private func applyAxis(
        resize: DwindleInteractiveResize,
        leaf: DwindleNode,
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

    @discardableResult
    func handleExternalFrameChange(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrame: CGRect,
        newFrame: CGRect,
        innerGap: CGFloat
    ) -> Bool {
        guard let leaf = findNode(for: token, in: workspaceId), leaf.isLeaf, !leaf.isFullscreen else { return false }
        let deltaMinX = newFrame.minX - oldFrame.minX
        let deltaMaxX = newFrame.maxX - oldFrame.maxX
        let deltaMinY = newFrame.minY - oldFrame.minY
        let deltaMaxY = newFrame.maxY - oldFrame.maxY

        let deltaWidth = newFrame.width - oldFrame.width
        let deltaHeight = newFrame.height - oldFrame.height

        var changed = false

        if abs(deltaWidth) > 1.0 {
            let wantFirstChild = abs(deltaMaxX) > abs(deltaMinX)
            if let match = controllingSplit(from: leaf, orientation: .horizontal, wantFirstChild: wantFirstChild),
               let frame = match.split.cachedFrame, frame.width > 0 {
                let ratioDelta = 2 * (wantFirstChild ? deltaWidth : -deltaWidth) / frame.width
                let currentRatio = match.split.splitRatio ?? 0.5
                let newRatio = clampedRatioRespectingMinimums(currentRatio + ratioDelta, for: match.split, innerGap: innerGap)
                if newRatio != currentRatio {
                    match.split.kind = .split(orientation: .horizontal, ratio: newRatio)
                    changed = true
                }
            }
        }

        if abs(deltaHeight) > 1.0 {
            let wantFirstChild = abs(deltaMaxY) > abs(deltaMinY)
            if let match = controllingSplit(from: leaf, orientation: .vertical, wantFirstChild: wantFirstChild),
               let frame = match.split.cachedFrame, frame.height > 0 {
                let ratioDelta = 2 * (wantFirstChild ? deltaHeight : -deltaHeight) / frame.height
                let currentRatio = match.split.splitRatio ?? 0.5
                let newRatio = clampedRatioRespectingMinimums(currentRatio + ratioDelta, for: match.split, innerGap: innerGap)
                if newRatio != currentRatio {
                    match.split.kind = .split(orientation: .vertical, ratio: newRatio)
                    changed = true
                }
            }
        }

        return changed
    }
}
