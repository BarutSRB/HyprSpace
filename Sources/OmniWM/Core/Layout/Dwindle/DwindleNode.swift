// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

typealias DwindleNodeId = UUID
typealias DwindleTileId = UUID

struct DwindleTileMember: Equatable {
    var token: WindowToken
    var isFullscreen: Bool
}

final class DwindleTile {
    let id: DwindleTileId
    private(set) var members: [DwindleTileMember]
    private(set) var activeIndex: Int

    init(token: WindowToken, fullscreen: Bool = false) {
        id = UUID()
        members = [DwindleTileMember(token: token, isFullscreen: fullscreen)]
        activeIndex = 0
    }

    var activeMember: DwindleTileMember {
        members[activeIndex]
    }

    var activeToken: WindowToken {
        activeMember.token
    }

    var isGrouped: Bool {
        members.count > 1
    }

    func memberIndex(for token: WindowToken) -> Int? {
        members.firstIndex { $0.token == token }
    }

    func member(for token: WindowToken) -> DwindleTileMember? {
        memberIndex(for: token).map { members[$0] }
    }

    @discardableResult
    func activate(_ token: WindowToken) -> Bool {
        guard let index = memberIndex(for: token), index != activeIndex else { return false }
        activeIndex = index
        return true
    }

    func insertAfterActive(_ member: DwindleTileMember) {
        let insertionIndex = activeIndex + 1
        members.insert(member, at: insertionIndex)
        activeIndex = insertionIndex
    }

    func remove(at index: Int) -> DwindleTileMember {
        precondition(members.count > 1 && members.indices.contains(index))
        let member = members.remove(at: index)
        if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = min(index, members.count - 1)
        }
        return member
    }

    @discardableResult
    func rekey(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard let index = memberIndex(for: oldToken) else { return false }
        members[index].token = newToken
        return true
    }

    @discardableResult
    func toggleFullscreen(for token: WindowToken) -> Bool {
        guard let index = memberIndex(for: token) else { return false }
        members[index].isFullscreen.toggle()
        return members[index].isFullscreen
    }

    func setFullscreen(_ fullscreen: Bool, for token: WindowToken) {
        guard let index = memberIndex(for: token) else { return }
        members[index].isFullscreen = fullscreen
    }

    @discardableResult
    func moveActive(offset: Int) -> Bool {
        let destination = activeIndex + offset
        guard members.indices.contains(destination) else { return false }
        members.swapAt(activeIndex, destination)
        activeIndex = destination
        return true
    }
}

struct DwindleTileSnapshot: Equatable {
    let id: DwindleTileId
    let members: [DwindleTileMember]
    let activeIndex: Int
    let tileFrame: CGRect?
    let contentFrame: CGRect?

    var activeToken: WindowToken {
        members[activeIndex].token
    }

    var isGrouped: Bool {
        members.count > 1
    }
}

enum DwindleWindowActivationOutcome: Equatable {
    case missing
    case selected
    case activated
}

enum DwindleOrientation: Equatable, Codable {
    case horizontal
    case vertical

    var perpendicular: DwindleOrientation {
        switch self {
        case .horizontal: .vertical
        case .vertical: .horizontal
        }
    }
}

extension Direction {
    var dwindleOrientation: DwindleOrientation {
        switch self {
        case .left,
             .right: .horizontal
        case .up,
             .down: .vertical
        }
    }

    var isPositive: Bool {
        switch self {
        case .right,
             .up: true
        case .left,
             .down: false
        }
    }
}

enum DwindleNodeKind {
    case split(orientation: DwindleOrientation, ratio: CGFloat)
    case leaf(tile: DwindleTile?)
}

struct CubicRectAnimation {
    let animation: CubicAnimation
    let fromFrame: CGRect
    let toFrame: CGRect

    func currentFrame(at time: TimeInterval) -> CGRect {
        let progress = CGFloat(animation.value(at: time))
        return CGRect(
            x: fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * progress,
            y: fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y) * progress,
            width: fromFrame.width + (toFrame.width - fromFrame.width) * progress,
            height: fromFrame.height + (toFrame.height - fromFrame.height) * progress
        )
    }

    func isComplete(at time: TimeInterval) -> Bool {
        animation.isComplete(at: time)
    }
}

final class DwindleNode {
    let id: DwindleNodeId
    weak var parent: DwindleNode?
    var children: [DwindleNode] = []
    var kind: DwindleNodeKind
    var cachedFrame: CGRect?
    var cachedContentFrame: CGRect?

    var cachedMinSize: CGSize?

    var frameAnimation: CubicRectAnimation?

    init(kind: DwindleNodeKind) {
        id = UUID()
        self.kind = kind
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true }
        return false
    }

    var isSplit: Bool {
        if case .split = kind { return true }
        return false
    }

    var windowToken: WindowToken? {
        if case let .leaf(tile) = kind { return tile?.activeToken }
        return nil
    }

    var isFullscreen: Bool {
        if case let .leaf(tile) = kind { return tile?.activeMember.isFullscreen == true }
        return false
    }

    var tile: DwindleTile? {
        if case let .leaf(tile) = kind { return tile }
        return nil
    }

    var splitOrientation: DwindleOrientation? {
        if case let .split(orientation, _) = kind { return orientation }
        return nil
    }

    var splitRatio: CGFloat? {
        if case let .split(_, ratio) = kind { return ratio }
        return nil
    }

    func firstChild() -> DwindleNode? {
        children.first
    }

    func secondChild() -> DwindleNode? {
        children.count > 1 ? children[1] : nil
    }

    func detach() {
        parent?.children.removeAll { $0.id == self.id }
        parent = nil
    }

    func appendChild(_ child: DwindleNode) {
        child.detach()
        child.parent = self
        children.append(child)
    }

    func insertChild(_ child: DwindleNode, at index: Int) {
        child.detach()
        child.parent = self
        children.insert(child, at: min(index, children.count))
    }

    func replaceChildren(first: DwindleNode, second: DwindleNode) {
        for child in children {
            child.parent = nil
        }
        children.removeAll()
        first.parent = self
        second.parent = self
        children = [first, second]
    }

    func descendToFirstLeaf() -> DwindleNode {
        var node = self
        while let first = node.firstChild() {
            node = first
        }
        return node
    }

    func isFirstChild(of parent: DwindleNode) -> Bool {
        parent.firstChild()?.id == id
    }

    func isSecondChild(of parent: DwindleNode) -> Bool {
        parent.secondChild()?.id == id
    }

    func clone() -> DwindleNode {
        let newNode = DwindleNode(kind: kind)
        newNode.cachedFrame = cachedFrame
        newNode.cachedContentFrame = cachedContentFrame
        newNode.cachedMinSize = cachedMinSize
        newNode.children = children.map { child in
            let childClone = child.clone()
            childClone.parent = newNode
            return childClone
        }
        return newNode
    }

    func sibling() -> DwindleNode? {
        guard let parent else { return nil }
        if isFirstChild(of: parent) {
            return parent.secondChild()
        } else {
            return parent.firstChild()
        }
    }

    func insertBefore(_ sibling: DwindleNode) {
        guard let parent = sibling.parent,
              let index = parent.children.firstIndex(where: { $0.id == sibling.id }) else { return }
        self.detach()
        self.parent = parent
        parent.children.insert(self, at: index)
    }

    func insertAfter(_ sibling: DwindleNode) {
        guard let parent = sibling.parent,
              let index = parent.children.firstIndex(where: { $0.id == sibling.id }) else { return }
        self.detach()
        self.parent = parent
        parent.children.insert(self, at: index + 1)
    }

    func collectAllLeaves() -> [DwindleNode] {
        var result: [DwindleNode] = []
        collectLeavesRecursive(into: &result)
        return result
    }

    private func collectLeavesRecursive(into result: inout [DwindleNode]) {
        if isLeaf {
            result.append(self)
        } else {
            for child in children {
                child.collectLeavesRecursive(into: &result)
            }
        }
    }

    func collectAllWindows() -> [WindowToken] {
        collectAllLeaves().flatMap { $0.tile?.members.map(\.token) ?? [] }
    }

    func animateFrom(
        oldFrame: CGRect,
        newFrame: CGRect,
        startTime: TimeInterval,
        config: CubicConfig,
        animated: Bool
    ) {
        guard animated else {
            clearAnimations()
            return
        }

        guard Self.frameChanged(oldFrame, newFrame, tolerance: 0.5) else {
            clearAnimations()
            return
        }

        frameAnimation = CubicRectAnimation(
            animation: CubicAnimation(
                from: 0.0,
                to: 1.0,
                startTime: startTime,
                config: config
            ),
            fromFrame: oldFrame,
            toFrame: newFrame
        )
    }

    private static func frameChanged(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > tolerance ||
            abs(lhs.origin.y - rhs.origin.y) > tolerance ||
            abs(lhs.width - rhs.width) > tolerance ||
            abs(lhs.height - rhs.height) > tolerance
    }

    func presentedFrame(at time: TimeInterval) -> CGRect? {
        frameAnimation?.currentFrame(at: time) ?? cachedContentFrame ?? cachedFrame
    }

    func tickAnimations(at time: TimeInterval) {
        if let anim = frameAnimation, anim.isComplete(at: time) {
            frameAnimation = nil
        }
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        if let anim = frameAnimation, !anim.isComplete(at: time) { return true }
        return false
    }

    func clearAnimations() {
        frameAnimation = nil
    }
}
