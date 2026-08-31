// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension WorkspaceManager {
    func applySettings() {
        invalidateSettingsProjectionCaches()
        let visibleWorkspacesBeforeClear = activeVisibleWorkspaceMap()
        let overriddenWorkspaceIds = Set(
            sortedWorkspaces().compactMap { workspace in
                workspace.runtimeMonitorOverride == nil ? nil : workspace.id
            }
        )
        let unsafeWorkspaceIds = Set(
            overriddenWorkspaceIds.filter {
                runtimeMonitorOverrideClearIsUnsafe(
                    $0,
                    visibleWorkspaces: visibleWorkspacesBeforeClear
                )
            }
        )
        pendingRuntimeMonitorOverrideClearWorkspaceIds.formUnion(unsafeWorkspaceIds)
        pendingRuntimeMonitorOverrideClearWorkspaceIds = Set(
            pendingRuntimeMonitorOverrideClearWorkspaceIds.filter {
                descriptor(for: $0)?.runtimeMonitorOverride != nil
            }
        )

        let clearableWorkspaceIds = overriddenWorkspaceIds.subtracting(unsafeWorkspaceIds)
        pendingRuntimeMonitorOverrideClearWorkspaceIds.subtract(clearableWorkspaceIds)
        let visibleMonitorByWorkspace = visibleMonitorByWorkspace(
            in: clearableWorkspaceIds,
            visibleWorkspaces: visibleWorkspacesBeforeClear
        )
        let clearedWorkspaceIds = clearRuntimeMonitorOverrides(clearableWorkspaceIds)
        invalidateWorkspaceProjectionCaches()
        synchronizeConfiguredWorkspaces()
        _ = finishRuntimeMonitorOverrideClears(
            clearedWorkspaceIds,
            visibleMonitorByWorkspace: visibleMonitorByWorkspace,
            visibleWorkspacesBeforeClear: visibleWorkspacesBeforeClear
        )
    }

    func drainPendingRuntimeMonitorOverrideClears() {
        guard !isDrainingPendingRuntimeMonitorOverrideClears else { return }
        isDrainingPendingRuntimeMonitorOverrideClears = true
        defer { isDrainingPendingRuntimeMonitorOverrideClears = false }

        pendingRuntimeMonitorOverrideClearWorkspaceIds = Set(
            pendingRuntimeMonitorOverrideClearWorkspaceIds.filter {
                descriptor(for: $0)?.runtimeMonitorOverride != nil
            }
        )
        guard !pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty else { return }

        let visibleWorkspacesBeforeClear = activeVisibleWorkspaceMap()
        let clearableWorkspaceIds = Set(
            pendingRuntimeMonitorOverrideClearWorkspaceIds.filter {
                !runtimeMonitorOverrideClearIsUnsafe(
                    $0,
                    visibleWorkspaces: visibleWorkspacesBeforeClear
                )
            }
        )
        guard !clearableWorkspaceIds.isEmpty else { return }

        pendingRuntimeMonitorOverrideClearWorkspaceIds.subtract(clearableWorkspaceIds)
        let visibleMonitorByWorkspace = visibleMonitorByWorkspace(
            in: clearableWorkspaceIds,
            visibleWorkspaces: visibleWorkspacesBeforeClear
        )
        let clearedWorkspaceIds = clearRuntimeMonitorOverrides(clearableWorkspaceIds)
        invalidateWorkspaceProjectionCaches()
        guard let outcome = finishRuntimeMonitorOverrideClears(
            clearedWorkspaceIds,
            visibleMonitorByWorkspace: visibleMonitorByWorkspace,
            visibleWorkspacesBeforeClear: visibleWorkspacesBeforeClear
        ) else {
            return
        }
        onDeferredWorkspaceMonitorMove?(outcome)
    }

    func isWorkspaceMonitorMoveUnsafe(
        _ workspaceId: WorkspaceDescriptor.ID,
        sourceMonitorId: Monitor.ID,
        visibleWorkspaces: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> Bool {
        let managedFocusedEntry = nativeManagedFocusToken.flatMap { entry(for: $0) }
        let managedFocusedWorkspaceId = managedFocusedEntry?.workspaceId
        let transfersManagedFocus = managedFocusedWorkspaceId == workspaceId
        let pendingWorkspaceId = pendingFocusedWorkspaceId
        if transfersManagedFocus,
           let pendingWorkspaceId,
           pendingWorkspaceId != workspaceId
        {
            return true
        }
        if !transfersManagedFocus, pendingWorkspaceId == workspaceId {
            return true
        }
        if hasNativeFullscreenRecord(in: workspaceId)
            || entries(in: workspaceId).contains(where: { isAppHidden(pid: $0.pid) })
            || entries(in: workspaceId).contains(where: { $0.layoutReason != .standard })
        {
            return true
        }
        if entries(in: workspaceId).contains(where: {
            isScratchpadToken($0.token) && $0.hiddenState == nil
        }) {
            return true
        }
        guard transfersManagedFocus, let managedFocusedEntry else { return false }
        return visibleWorkspaces[sourceMonitorId] != workspaceId
            || interactionMonitorId != sourceMonitorId
            || isAppHidden(pid: managedFocusedEntry.pid)
            || managedFocusedEntry.layoutReason != .standard
            || managedFocusedEntry.hiddenState != nil
            || isScratchpadToken(managedFocusedEntry.token)
    }

    private func runtimeMonitorOverrideClearIsUnsafe(
        _ workspaceId: WorkspaceDescriptor.ID,
        visibleWorkspaces: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> Bool {
        guard let sourceMonitorId = monitorForWorkspace(workspaceId)?.id else {
            return true
        }
        return isWorkspaceMonitorMoveUnsafe(
            workspaceId,
            sourceMonitorId: sourceMonitorId,
            visibleWorkspaces: visibleWorkspaces
        )
    }

    private func finishRuntimeMonitorOverrideClears(
        _ clearedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        visibleMonitorByWorkspace: [WorkspaceDescriptor.ID: Monitor.ID],
        visibleWorkspacesBeforeClear: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> WorkspaceMonitorMoveOutcome? {
        let retainedWorkspaceIds = Set(
            clearedWorkspaceIds.filter { descriptor(for: $0) != nil }
        )
        pendingRuntimeMonitorOverrideClearWorkspaceIds = Set(
            pendingRuntimeMonitorOverrideClearWorkspaceIds.filter {
                descriptor(for: $0)?.runtimeMonitorOverride != nil
            }
        )
        _ = restoreClearedRuntimeOverrideVisibility(
            visibleMonitorByWorkspace: visibleMonitorByWorkspace
        )
        ensureVisibleWorkspaces()
        reconcileConfiguredVisibleWorkspaces(notify: retainedWorkspaceIds.isEmpty)
        guard !retainedWorkspaceIds.isEmpty else { return nil }

        let visibleWorkspacesAfterClear = activeVisibleWorkspaceMap()
        var affectedWorkspaceIds = retainedWorkspaceIds
        let changedMonitorIds = Set(visibleWorkspacesBeforeClear.keys)
            .union(visibleWorkspacesAfterClear.keys)
        for monitorId in changedMonitorIds where
            visibleWorkspacesBeforeClear[monitorId] != visibleWorkspacesAfterClear[monitorId]
        {
            if let workspaceId = visibleWorkspacesBeforeClear[monitorId] {
                affectedWorkspaceIds.insert(workspaceId)
            }
            if let workspaceId = visibleWorkspacesAfterClear[monitorId] {
                affectedWorkspaceIds.insert(workspaceId)
            }
        }
        let floatingRelocations = commitRuntimeMonitorOverrideClears(
            retainedWorkspaceIds,
            affectedWorkspaceIds: affectedWorkspaceIds
        )
        return WorkspaceMonitorMoveOutcome(
            status: .executed,
            affectedWorkspaces: affectedWorkspaceIds,
            floatingRelocations: floatingRelocations
        )
    }

    private func visibleMonitorByWorkspace(
        in workspaceIds: Set<WorkspaceDescriptor.ID>,
        visibleWorkspaces: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> [WorkspaceDescriptor.ID: Monitor.ID] {
        Dictionary(
            uniqueKeysWithValues: visibleWorkspaces.compactMap { monitorId, workspaceId in
                workspaceIds.contains(workspaceId) ? (workspaceId, monitorId) : nil
            }
        )
    }
}
