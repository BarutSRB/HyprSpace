// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    struct WorkspaceMoveResult {
        let newFocusNodeId: NodeId?

        let movedToken: WindowToken?

        let targetWorkspaceId: WorkspaceDescriptor.ID
    }

    func moveWindowToWorkspace(
        _ window: NiriWindow,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState
    ) -> WorkspaceMoveResult? {
        assertSanctionedMutation()
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceWorkspaceState = states[sourceWorkspaceId],
              let sourceColumn = findColumn(containing: window, in: sourceWorkspaceId)
        else {
            return nil
        }

        let targetWorkspaceState = ensureState(for: targetWorkspaceId)
        let targetRoot = targetWorkspaceState.root

        let fallbackSelection = fallbackSelectionOnRemoval(removing: window.id, in: sourceWorkspaceId)

        if targetWorkspaceState.nodesByToken[window.token] != nil {
            removeWindow(token: window.token, in: targetWorkspaceId)
        }
        precondition(targetWorkspaceState.nodesByToken[window.token] == nil)

        cancelInteractions(for: Set([window.id]), in: sourceWorkspaceId)

        window.detach()
        sourceWorkspaceState.unindex(window)

        let targetColumn: NiriContainer
        if let existingColumn = claimEmptyColumnIfWorkspaceEmpty(in: targetRoot) {
            targetColumn = existingColumn
        } else {
            let newColumn = NiriContainer()
            targetRoot.appendChild(newColumn)
            targetColumn = newColumn
        }
        copyContainerSizingState(from: sourceColumn, to: targetColumn)
        targetColumn.appendChild(window)
        targetWorkspaceState.index(window)

        cleanupEmptyColumn(sourceColumn, in: sourceWorkspaceId, state: &sourceState)

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = window.id

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedToken: window.token,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func moveColumnToWorkspace(
        _ column: NiriContainer,
        from sourceWorkspaceId: WorkspaceDescriptor.ID,
        to targetWorkspaceId: WorkspaceDescriptor.ID,
        sourceState: inout ViewportState,
        targetState: inout ViewportState,
        targetOrientation: Monitor.Orientation
    ) -> WorkspaceMoveResult? {
        assertSanctionedMutation()
        guard sourceWorkspaceId != targetWorkspaceId else { return nil }

        guard let sourceWorkspaceState = states[sourceWorkspaceId],
              columnIndex(of: column, in: sourceWorkspaceId) != nil
        else {
            return nil
        }

        let targetWorkspaceState = ensureState(for: targetWorkspaceId)
        let targetRoot = targetWorkspaceState.root
        let movedWindows = column.windowNodes

        for window in movedWindows where targetWorkspaceState.nodesByToken[window.token] != nil {
            removeWindow(token: window.token, in: targetWorkspaceId)
        }
        precondition(movedWindows.allSatisfy { targetWorkspaceState.nodesByToken[$0.token] == nil })

        removeEmptyColumnsIfWorkspaceEmpty(in: targetRoot)

        let allCols = columns(in: sourceWorkspaceId)
        var fallbackSelection: NodeId?
        if let colIdx = columnIndex(of: column, in: sourceWorkspaceId) {
            if colIdx > 0 {
                fallbackSelection = allCols[colIdx - 1].firstChild()?.id
            } else if allCols.count > 1 {
                fallbackSelection = allCols[1].firstChild()?.id
            }
        }

        cancelInteractions(for: Set(movedWindows.map(\.id)), in: sourceWorkspaceId)

        column.detach()
        targetRoot.appendChild(column)
        column.invalidateCachedPrimarySpan(orientation: targetOrientation)

        for window in movedWindows {
            sourceWorkspaceState.unindex(window)
            targetWorkspaceState.index(window)
        }

        sourceState.selectedNodeId = fallbackSelection

        targetState.selectedNodeId = column.firstChild()?.id

        let firstWindowToken = movedWindows.first?.token

        return WorkspaceMoveResult(
            newFocusNodeId: fallbackSelection,
            movedToken: firstWindowToken,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func removeWorkspaceState(_ workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        cancelInteractions(in: workspaceId)
        for niriMonitor in monitors.values {
            niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
        }
        states.removeValue(forKey: workspaceId)
        excludedTokensByWorkspace.removeValue(forKey: workspaceId)
    }
}
