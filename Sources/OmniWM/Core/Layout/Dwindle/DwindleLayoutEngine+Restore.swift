// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension DwindleLayoutEngine {
    private struct PlacedToken {
        let token: WindowToken
        let placement: PersistedDwindlePlacement
        let order: Int
    }

    func persistedPlacements(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: PersistedDwindlePlacement] {
        guard let root = root(for: workspaceId) else { return [:] }
        var placements: [WindowToken: PersistedDwindlePlacement] = [:]
        collectPlacements(from: root, steps: [], into: &placements)
        return placements
    }

    private func collectPlacements(
        from node: DwindleNode,
        steps: [PersistedDwindleSplitStep],
        into placements: inout [WindowToken: PersistedDwindlePlacement]
    ) {
        switch node.kind {
        case let .split(orientation, ratio):
            for (childIndex, child) in node.children.enumerated() {
                let step = PersistedDwindleSplitStep(orientation: orientation, ratio: ratio, childIndex: childIndex)
                collectPlacements(from: child, steps: steps + [step], into: &placements)
            }
        case let .leaf(tile):
            guard let tile else { return }
            for (memberIndex, member) in tile.members.enumerated() {
                placements[member.token] = PersistedDwindlePlacement(
                    steps: steps,
                    memberIndex: memberIndex,
                    isActiveMember: member.token == tile.activeToken
                )
            }
        }
    }

    @discardableResult
    func restoreInitialPlacements(
        _ placements: [WindowToken: PersistedDwindlePlacement],
        matching tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard !placements.isEmpty, !tokens.isEmpty else { return false }

        let state = ensureState(for: workspaceId)
        let currentTokens = Set(state.leafByToken.keys)
        var seenTokens = Set<WindowToken>()
        var placedTokens: [PlacedToken] = []
        for token in tokens where seenTokens.insert(token).inserted {
            guard let placement = placements[token], placement.memberIndex >= 0 else { continue }
            placedTokens.append(PlacedToken(token: token, placement: placement, order: placedTokens.count))
        }
        let placedTokenSet = Set(placedTokens.map(\.token))
        guard !placedTokens.isEmpty,
              !placedTokenSet.subtracting(currentTokens).isEmpty,
              currentTokens.isSubset(of: placedTokenSet),
              let restoredRoot = buildRestoredTree(from: placedTokens, previousLeaves: state.leafByToken)
        else { return false }

        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
        if interactiveMove?.workspaceId == workspaceId {
            interactiveMoveCancel()
        }

        let root = state.root
        for child in root.children {
            child.parent = nil
        }
        root.children.removeAll()
        root.kind = restoredRoot.kind
        if restoredRoot.children.count == 2 {
            root.replaceChildren(first: restoredRoot.children[0], second: restoredRoot.children[1])
        }
        root.cachedContentFrame = nil
        root.clearAnimations()

        state.leafByToken.removeAll(keepingCapacity: true)
        state.tileCount = 0
        indexLeaves(from: root, into: state)
        state.selectedNodeId = nil
        state.preselection = nil
        state.pendingMovementFrameSeeds.removeAll()
        return true
    }

    private func buildRestoredTree(
        from placedTokens: [PlacedToken],
        previousLeaves: [WindowToken: DwindleNode]
    ) -> DwindleNode? {
        let scratchRoot = DwindleNode(kind: .leaf(tile: nil))
        var membersByLeaf: [DwindleNodeId: [PlacedToken]] = [:]

        for placed in placedTokens {
            var node = scratchRoot
            for step in placed.placement.steps {
                if node.isLeaf {
                    guard membersByLeaf[node.id] == nil, (0 ... 1).contains(step.childIndex) else { return nil }
                    node.kind = .split(orientation: step.orientation, ratio: step.ratio)
                    node.replaceChildren(
                        first: DwindleNode(kind: .leaf(tile: nil)),
                        second: DwindleNode(kind: .leaf(tile: nil))
                    )
                }
                guard node.children.indices.contains(step.childIndex) else { return nil }
                node = node.children[step.childIndex]
            }
            guard node.isLeaf else { return nil }
            membersByLeaf[node.id, default: []].append(placed)
        }

        guard pruneEmptyLeaves(in: scratchRoot, membersByLeaf: &membersByLeaf) else { return nil }
        materializeTiles(in: scratchRoot, membersByLeaf: membersByLeaf, previousLeaves: previousLeaves)
        return scratchRoot
    }

    private func pruneEmptyLeaves(
        in node: DwindleNode,
        membersByLeaf: inout [DwindleNodeId: [PlacedToken]]
    ) -> Bool {
        guard node.children.count == 2 else {
            return membersByLeaf[node.id] != nil
        }
        let first = node.children[0]
        let second = node.children[1]
        let firstHasMembers = pruneEmptyLeaves(in: first, membersByLeaf: &membersByLeaf)
        let secondHasMembers = pruneEmptyLeaves(in: second, membersByLeaf: &membersByLeaf)
        if firstHasMembers, secondHasMembers {
            return true
        }
        guard let survivor = firstHasMembers ? first : (secondHasMembers ? second : nil) else { return false }
        node.kind = survivor.kind
        if survivor.children.count == 2 {
            node.replaceChildren(first: survivor.children[0], second: survivor.children[1])
        } else {
            for child in node.children {
                child.parent = nil
            }
            node.children.removeAll()
            membersByLeaf[node.id] = membersByLeaf.removeValue(forKey: survivor.id)
        }
        return true
    }

    private func materializeTiles(
        in node: DwindleNode,
        membersByLeaf: [DwindleNodeId: [PlacedToken]],
        previousLeaves: [WindowToken: DwindleNode]
    ) {
        guard node.isLeaf else {
            for child in node.children {
                materializeTiles(in: child, membersByLeaf: membersByLeaf, previousLeaves: previousLeaves)
            }
            return
        }
        let members = (membersByLeaf[node.id] ?? []).sorted { lhs, rhs in
            if lhs.placement.memberIndex != rhs.placement.memberIndex {
                return lhs.placement.memberIndex < rhs.placement.memberIndex
            }
            return lhs.order < rhs.order
        }
        guard let first = members.first else { return }

        func wasFullscreen(_ token: WindowToken) -> Bool {
            previousLeaves[token]?.tile?.member(for: token)?.isFullscreen == true
        }

        let tile = DwindleTile(token: first.token, fullscreen: wasFullscreen(first.token))
        for member in members.dropFirst() {
            tile.insertAfterActive(DwindleTileMember(token: member.token, isFullscreen: wasFullscreen(member.token)))
        }
        let activeToken = members.first(where: \.placement.isActiveMember)?.token ?? first.token
        tile.activate(activeToken)
        node.kind = .leaf(tile: tile)
    }

    private func indexLeaves(from node: DwindleNode, into state: DwindleWorkspaceState) {
        if let tile = node.tile {
            state.tileCount += 1
            for member in tile.members {
                state.leafByToken[member.token] = node
            }
        }
        for child in node.children {
            indexLeaves(from: child, into: state)
        }
    }
}
