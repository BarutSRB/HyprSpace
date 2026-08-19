// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    struct NiriRemovalResult {
        let removedTokens: Set<WindowToken>
        let removedNodeIds: Set<NodeId>
        let removedColumnIndicesBefore: [Int]
        let activeIndexBefore: Int?
        let activeIndexAfter: Int?
        let finalSelectionId: NodeId?
        let viewportNeedsRecalc: Bool
        let fromIndexForVisibility: Int?
        let visibilityWasCorrected: Bool
    }

    private struct TileRemovalStep {
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndexBefore: Int?
        var fallbackSelectionId: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false
    }

    func updateWindowConstraints(
        for token: WindowToken,
        constraints: WindowSizeConstraints,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        assertSanctionedMutation()
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        let normalized = constraints.normalized()
        guard node.constraints != normalized else { return }
        node.constraints = normalized
        guard let column = node.parent as? NiriContainer else { return }
        if column.cachedHeight > 0 {
            column.cachedHeight = column.clampedToHeightBounds(column.cachedHeight)
        }
        let contentInset = tabContentInset(for: column)
        if let target = column.targetWidth {
            let clampedTarget = column.clampedToWidthBounds(
                target,
                contentInset: contentInset
            )
            if clampedTarget != target {
                column.animateWidthTo(
                    newWidth: clampedTarget,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate(in: workspaceId),
                    animated: true
                )
            }
        } else if column.cachedWidth > 0 {
            column.cachedWidth = column.clampedToWidthBounds(
                column.cachedWidth,
                contentInset: contentInset
            )
        }
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingState: NiriContainerSizingState? = nil
    ) -> NiriWindow {
        let state = ensureState(for: workspaceId)
        if let existing = state.nodesByToken[token] {
            return existing
        }
        let root = state.root

        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: root) {
            initializeNewContainerSizing(existingColumn, in: workspaceId, initialState: containerSizingState)
            let windowNode = NiriWindow(token: token)
            existingColumn.appendChild(windowNode)
            state.index(windowNode)
            return windowNode
        }

        let referenceColumn: NiriContainer? = if let focusedToken,
                                                 let focusedNode = state.nodesByToken[focusedToken],
                                                 let col = column(of: focusedNode)
        {
            col
        } else if let selId = selectedNodeId,
                  let selNode = root.findNode(by: selId),
                  let col = column(of: selNode)
        {
            col
        } else {
            root.columns.last
        }

        let newColumn = NiriContainer()
        initializeNewContainerSizing(newColumn, in: workspaceId, initialState: containerSizingState)
        if let refCol = referenceColumn {
            root.insertAfter(newColumn, reference: refCol)
        } else {
            root.appendChild(newColumn)
        }

        let windowNode = NiriWindow(token: token)
        newColumn.appendChild(windowNode)

        state.index(windowNode)

        return windowNode
    }

    func workspaceIds(containing token: WindowToken) -> [WorkspaceDescriptor.ID] {
        states.compactMap { $0.value.nodesByToken[token] != nil ? $0.key : nil }
    }

    func workspaceIds() -> [WorkspaceDescriptor.ID] {
        Array(states.keys)
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> NiriWindow? {
        states[workspaceId]?.nodesByToken[token]
    }

    func removeWindow(token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let node = state.nodesByToken[token],
              let column = node.parent as? NiriContainer else { return }

        cancelInteractions(for: Set([node.id]), in: workspaceId)
        column.adjustActiveTileIdxForRemoval(of: node)
        node.remove()
        state.unindex(node)
        if excludedTokensByWorkspace[workspaceId]?.remove(token) != nil,
           excludedTokensByWorkspace[workspaceId]?.isEmpty == true
        {
            excludedTokensByWorkspace.removeValue(forKey: workspaceId)
        }

        if column.displayMode == .tabbed, !column.children.isEmpty {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.children.isEmpty {
            let root = column.parent as? NiriRoot
            column.remove()

            if let root {
                for col in root.columns {
                    col.cachedWidth = 0
                }
            }
        }
    }

    @discardableResult
    func removeWindows(
        _ tokens: Set<WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        selectedNodeId: NodeId?,
        removedNodeIds externallyRemovedNodeIds: [NodeId]
    ) -> NiriRemovalResult {
        assertSanctionedMutation()
        guard !tokens.isEmpty,
              let workspaceState = states[workspaceId]
        else {
            return NiriRemovalResult(
                removedTokens: [],
                removedNodeIds: [],
                removedColumnIndicesBefore: [],
                activeIndexBefore: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
                activeIndexAfter: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
                finalSelectionId: nil,
                viewportNeedsRecalc: false,
                fromIndexForVisibility: nil,
                visibilityWasCorrected: false
            )
        }

        let root = workspaceState.root
        let activeIndexBefore = root.columns.isEmpty ? nil : state.activeColumnIndex
        let removalTokens = tokens.intersection(root.windowIdSet)
        guard !removalTokens.isEmpty else {
            return NiriRemovalResult(
                removedTokens: [],
                removedNodeIds: [],
                removedColumnIndicesBefore: [],
                activeIndexBefore: activeIndexBefore,
                activeIndexAfter: root.columns.isEmpty ? nil : state.activeColumnIndex,
                finalSelectionId: nil,
                viewportNeedsRecalc: false,
                fromIndexForVisibility: nil,
                visibilityWasCorrected: false
            )
        }

        let batchRemovedNodeIds = Set(externallyRemovedNodeIds).union(
            removalTokens.compactMap { workspaceState.nodesByToken[$0]?.id }
        )
        var remainingTokens = removalTokens
        var removedTokens: Set<WindowToken> = []
        var removedNodeIds: Set<NodeId> = []
        var removedColumnIndicesBefore: [Int] = []
        var latestFallback: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false

        while let window = root.allWindows.first(where: { remainingTokens.contains($0.token) }) {
            guard let column = column(of: window),
                  let columnIndex = columnIndex(of: column, in: workspaceId),
                  let tileIndex = column.windowNodes.firstIndex(where: { $0 === window })
            else {
                remainingTokens.remove(window.token)
                continue
            }

            let step = removeTileByIdx(
                columnIndex: columnIndex,
                tileIndex: tileIndex,
                in: workspaceId,
                state: &state,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                allRemovalTokens: removalTokens,
                allRemovalNodeIds: batchRemovedNodeIds
            )

            removedTokens.formUnion(step.removedTokens)
            removedNodeIds.formUnion(step.removedNodeIds)
            remainingTokens.subtract(step.removedTokens)
            if let removedColumnIndex = step.removedColumnIndexBefore {
                removedColumnIndicesBefore.append(removedColumnIndex)
            }
            if let fallback = step.fallbackSelectionId {
                latestFallback = fallback
            }
            viewportNeedsRecalc = viewportNeedsRecalc || step.viewportNeedsRecalc
            if fromIndexForVisibility == nil {
                fromIndexForVisibility = step.fromIndexForVisibility
            }
            visibilityWasCorrected = visibilityWasCorrected || step.visibilityWasCorrected
        }

        let currentSelection = state.selectedNodeId ?? selectedNodeId
        let finalSelection: NodeId?
        if let currentSelection,
           !batchRemovedNodeIds.contains(currentSelection),
           root.findNode(by: currentSelection) != nil
        {
            finalSelection = currentSelection
        } else {
            finalSelection = latestFallback
                ?? fallbackSelectionFromActiveColumn(
                    in: workspaceId,
                    activeIndex: state.activeColumnIndex,
                    excluding: batchRemovedNodeIds
                )
                ?? validateSelection(nil, in: workspaceId)
        }

        state.selectedNodeId = finalSelection

        if let finalSelection,
           !visibilityWasCorrected,
           let fromIndexForVisibility,
           let selectedNode = root.findNode(by: finalSelection),
           viewportNeedsRecalc
        {
            ensureSelectionVisible(
                node: selectedNode,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                fromContainerIndex: fromIndexForVisibility
            )
            visibilityWasCorrected = true
        }

        if !removedColumnIndicesBefore.isEmpty,
           correctViewportAfterColumnRemoval(
               in: workspaceId,
               state: &state,
               motion: motion,
               workingFrame: workingFrame,
               gaps: gaps,
               orientation: orientation
           )
        {
            viewportNeedsRecalc = true
        }

        return NiriRemovalResult(
            removedTokens: removedTokens,
            removedNodeIds: removedNodeIds.union(batchRemovedNodeIds),
            removedColumnIndicesBefore: removedColumnIndicesBefore,
            activeIndexBefore: activeIndexBefore,
            activeIndexAfter: columns(in: workspaceId).isEmpty ? nil : state.activeColumnIndex,
            finalSelectionId: finalSelection,
            viewportNeedsRecalc: viewportNeedsRecalc,
            fromIndexForVisibility: visibilityWasCorrected ? nil : fromIndexForVisibility,
            visibilityWasCorrected: visibilityWasCorrected
        )
    }

    private func removeTileByIdx(
        columnIndex: Int,
        tileIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        allRemovalTokens: Set<WindowToken>,
        allRemovalNodeIds: Set<NodeId>
    ) -> TileRemovalStep {
        let cols = columns(in: workspaceId)
        guard columnIndex >= 0, columnIndex < cols.count else { return TileRemovalStep() }

        let column = cols[columnIndex]
        let windows = column.windowNodes
        guard tileIndex >= 0, tileIndex < windows.count else { return TileRemovalStep() }

        if windows.count == 1 {
            return removeColumnByIdx(
                columnIndex,
                in: workspaceId,
                state: &state,
                motion: motion,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                allRemovalTokens: allRemovalTokens,
                allRemovalNodeIds: allRemovalNodeIds
            )
        }

        let node = windows[tileIndex]
        let removedToken = node.token
        let removedNodeId = node.id

        cancelInteractions(for: Set([removedNodeId]), in: workspaceId)

        column.adjustActiveTileIdxForRemoval(of: node)
        states[workspaceId]?.unindex(node)
        node.remove()

        if column.displayMode == .tabbed {
            column.clampActiveTileIdx()
            updateTabbedColumnVisibility(column: column)
        }

        if column.windowNodes.count == 1,
           let remaining = column.windowNodes.first,
           remaining.height.isAuto
        {
            remaining.height = .auto(weight: 1.0)
        }

        let fallback = fallbackSelectionInColumn(
            column,
            excluding: allRemovalNodeIds
        )

        return TileRemovalStep(
            removedTokens: [removedToken],
            removedNodeIds: [removedNodeId],
            fallbackSelectionId: fallback
        )
    }

    private func removeColumnByIdx(
        _ removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation,
        allRemovalTokens: Set<WindowToken>,
        allRemovalNodeIds: Set<NodeId>
    ) -> TileRemovalStep {
        let cols = columns(in: workspaceId)
        guard removedIdx >= 0, removedIdx < cols.count else { return TileRemovalStep() }

        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )

        let column = cols[removedIdx]
        let removedWindows = column.windowNodes
        let removedTokens = Set(removedWindows.map(\.token)).intersection(allRemovalTokens)
        let removedNodeIds = Set(removedWindows.map(\.id))
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, cols.count - 1))
        let postRemovalCount = cols.count - 1
        let primarySpan = switch orientation {
        case .horizontal: column.cachedWidth
        case .vertical: column.cachedHeight
        }
        let offset = primarySpan + gaps

        animateColumnsAroundRemoval(
            columns: cols,
            removedIdx: removedIdx,
            activeIdx: activeIdx,
            offset: offset,
            in: workspaceId,
            motion: motion,
            orientation: orientation
        )

        cancelInteractions(for: Set(removedWindows.map(\.id)), in: workspaceId)

        let pendingPreviousOffset = state.activatePrevColumnOnRemoval
        if removedIdx + 1 == activeIdx {
            state.activatePrevColumnOnRemoval = nil
        }
        if removedIdx == activeIdx {
            state.viewOffsetToRestore = nil
        }

        for window in removedWindows {
            states[workspaceId]?.unindex(window)
            window.detach()
        }
        column.remove()

        var fallbackSelectionId: NodeId?
        var viewportNeedsRecalc = false
        var fromIndexForVisibility: Int?
        var visibilityWasCorrected = false

        if postRemovalCount <= 0 {
            state.activeColumnIndex = 0
            state.activatePrevColumnOnRemoval = nil
            state.selectedNodeId = nil
        } else if removedIdx < activeIdx {
            state.activeColumnIndex = activeIdx - 1
            state.rebaseOffset(by: offset)
            state.activatePrevColumnOnRemoval = nil
            viewportNeedsRecalc = true
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
        } else if removedIdx == activeIdx,
                  let previousOffset = pendingPreviousOffset,
                  removedIdx > 0
        {
            state.activeColumnIndex = activeIdx - 1
            state.activatePrevColumnOnRemoval = nil
            state.jumpOffset(to: previousOffset)
            viewportNeedsRecalc = true
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
            if let fallbackSelectionId,
               let selectedNode = findNode(by: fallbackSelectionId, in: workspaceId)
            {
                state.selectedNodeId = fallbackSelectionId
                ensureSelectionVisible(
                    node: selectedNode,
                    in: workspaceId,
                    motion: motion,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps,
                    orientation: orientation,
                    fromContainerIndex: state.activeColumnIndex
                )
                visibilityWasCorrected = true
            }
        } else if removedIdx == activeIdx {
            state.activeColumnIndex = min(activeIdx, postRemovalCount - 1)
            state.activatePrevColumnOnRemoval = nil
            viewportNeedsRecalc = true
            fromIndexForVisibility = removedIdx
            fallbackSelectionId = fallbackSelectionFromActiveColumn(
                in: workspaceId,
                activeIndex: state.activeColumnIndex,
                excluding: allRemovalNodeIds
            )
        } else {
            state.activatePrevColumnOnRemoval = nil
        }

        return TileRemovalStep(
            removedTokens: removedTokens,
            removedNodeIds: removedNodeIds,
            removedColumnIndexBefore: removedIdx,
            fallbackSelectionId: fallbackSelectionId,
            viewportNeedsRecalc: viewportNeedsRecalc,
            fromIndexForVisibility: fromIndexForVisibility,
            visibilityWasCorrected: visibilityWasCorrected
        )
    }

    private func fallbackSelectionInColumn(
        _ column: NiriContainer,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        if let activeWindow = column.activeWindow,
           !removedNodeIds.contains(activeWindow.id)
        {
            return activeWindow.id
        }

        return column.windowNodes.first(where: { !removedNodeIds.contains($0.id) })?.id
    }

    private func fallbackSelectionFromActiveColumn(
        in workspaceId: WorkspaceDescriptor.ID,
        activeIndex: Int,
        excluding removedNodeIds: Set<NodeId>
    ) -> NodeId? {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return nil }
        let idx = activeIndex.clamped(to: 0 ... (cols.count - 1))
        return fallbackSelectionInColumn(cols[idx], excluding: removedNodeIds)
    }

    func correctViewportAfterColumnRemoval(
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        motion: MotionSnapshot,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> Bool {
        let cols = columns(in: workspaceId)
        guard !cols.isEmpty else { return false }

        let monitor = monitorForWorkspace(workspaceId)
        resolvePrimaryContainerSpans(
            in: workspaceId,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
        let sizeKeyPath = orientation.settledSpanKeyPath
        let viewportSpan: CGFloat = switch orientation {
        case .horizontal: workingFrame.width
        case .vertical: workingFrame.height
        }

        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... (cols.count - 1))
        state.activeColumnIndex = activeIdx
        let activePosition = state.containerPosition(
            at: activeIdx,
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePosition + state.viewOffset
        let settings = effectiveSettings(in: workspaceId)
        let scale = displayScale(in: workspaceId)
        if settings.centerFocusedColumn == .always
            || (cols.count == 1 && settings.alwaysCenterSingleColumn)
        {
            let targetOffset = state.computeVisibleOffset(
                containerIndex: activeIdx,
                containers: cols,
                gap: gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                currentViewStart: viewStart,
                centerMode: settings.centerFocusedColumn,
                alwaysCenterSingleColumn: settings.alwaysCenterSingleColumn,
                scale: scale,
                workingArea: workingFrame,
                viewFrame: monitor?.frame,
                orientation: orientation
            )
            let targetStart = activePosition + targetOffset
            guard abs(targetStart - viewStart) > 0.5 else { return false }
            state.animateToOffset(targetOffset, motion: motion, scale: scale)
            return true
        }

        let totalSpan = state.totalSpan(
            containers: cols,
            gap: gaps,
            sizeKeyPath: sizeKeyPath
        )
        let contentEdge = totalSpan - viewportSpan + gaps
        let clampedStart = viewStart.clamped(to: min(-gaps, contentEdge) ... max(-gaps, contentEdge))
        guard abs(clampedStart - viewStart) > 0.5 else { return false }

        if settings.centerFocusedColumn == .onOverflow {
            let centeredOffset = state.computeVisibleOffset(
                containerIndex: activeIdx,
                containers: cols,
                gap: gaps,
                viewportSpan: viewportSpan,
                sizeKeyPath: sizeKeyPath,
                currentViewStart: viewStart,
                centerMode: .always,
                scale: scale,
                workingArea: workingFrame,
                viewFrame: monitor?.frame,
                orientation: orientation
            )
            let centeredStart = activePosition + centeredOffset
            let activeSpan = cols[activeIdx][keyPath: sizeKeyPath]
            let previousPairOverflows = activeIdx > 0
                && cols[activeIdx - 1][keyPath: sizeKeyPath] + activeSpan + gaps * 3 > viewportSpan
            let nextPairOverflows = activeIdx + 1 < cols.count
                && activeSpan + cols[activeIdx + 1][keyPath: sizeKeyPath] + gaps * 3 > viewportSpan
            if previousPairOverflows || nextPairOverflows,
               abs(centeredStart - viewStart) <= 0.5
            {
                return false
            }
        }

        let fittedOffset = state.computeVisibleOffset(
            containerIndex: activeIdx,
            containers: cols,
            gap: gaps,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            currentViewStart: clampedStart,
            centerMode: .never,
            scale: scale,
            workingArea: workingFrame,
            viewFrame: monitor?.frame,
            orientation: orientation
        )
        let fittedStart = activePosition + fittedOffset
        guard abs(fittedStart - viewStart) > 0.5 else { return false }
        state.animateToOffset(
            fittedOffset,
            motion: motion,
            scale: scale
        )
        return true
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.nodesByToken[newToken] == nil,
              let node = state.nodesByToken.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        state.index(node)

        if var move = interactiveMove,
           move.workspaceId == workspaceId,
           move.windowId == node.id
        {
            move.windowToken = newToken
            interactiveMove = move
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil,
        containerSizingStates: [WindowToken: NiriContainerSizingState]? = nil
    ) -> Set<WindowToken> {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)

        let currentIdSet = Set(tokens)

        var removedHandles = Set<WindowToken>()

        for window in state.root.allWindows {
            if !currentIdSet.contains(window.token) {
                removedHandles.insert(window.token)
                removeWindow(token: window.token, in: workspaceId)
            }
        }

        for token in tokens {
            if state.nodesByToken[token] == nil {
                _ = addWindow(
                    token: token,
                    to: workspaceId,
                    afterSelection: selectedNodeId,
                    focusedToken: focusedToken,
                    containerSizingState: containerSizingStates?[token]
                )
            }
        }

        return removedHandles
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = root(for: workspaceId),
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let root = root(for: workspaceId),
              let removingNode = root.findNode(by: removingNodeId)
        else {
            return nil
        }

        if let nextSibling = removingNode.nextSibling() {
            return nextSibling.id
        }

        if let prevSibling = removingNode.prevSibling() {
            return prevSibling.id
        }

        let cols = columns(in: workspaceId)
        if let currentCol = column(of: removingNode),
           let currentIdx = cols.firstIndex(where: { $0 === currentCol })
        {
            if currentIdx > 0, let window = cols[currentIdx - 1].firstChild() {
                return window.id
            }
            if currentIdx < cols.count - 1, let window = cols[currentIdx + 1].firstChild() {
                return window.id
            }
        }

        for col in cols {
            if col.id != column(of: removingNode)?.id {
                if let firstWindow = col.firstChild() {
                    return firstWindow.id
                }
            }
        }

        return nil
    }

    func updateFocusTimestamp(for nodeId: NodeId, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node = findNode(by: nodeId, in: workspaceId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let node = states[workspaceId]?.nodesByToken[token] else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(states.values.flatMap(\.root.allWindows))
        }

        let candidates = allWindows.filter { window in
            guard window.id != excludingNodeId, window.lastFocusedTime != nil else { return false }
            if let workspaceId {
                return !isExcludedFromProjection(window.token, in: workspaceId)
            }
            return !excludedTokensByWorkspace.values.contains { $0.contains(window.token) }
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }
}
