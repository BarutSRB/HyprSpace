// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension WorkspaceManager {
    func isAppHidden(_ token: WindowToken) -> Bool {
        isAppHidden(pid: token.pid)
    }

    @discardableResult
    func setAppHidden(
        _ hidden: Bool,
        pid: pid_t,
        source: WMEventSource
    ) -> Set<WorkspaceDescriptor.ID> {
        var pids = hiddenAppPIDs
        if hidden {
            pids.insert(pid)
        } else {
            pids.remove(pid)
        }
        return replaceHiddenAppPIDs(pids, source: source)
    }

    @discardableResult
    func replaceHiddenAppPIDs(
        _ pids: Set<pid_t>,
        source: WMEventSource
    ) -> Set<WorkspaceDescriptor.ID> {
        let changedPIDs = hiddenAppPIDs.symmetricDifference(pids)
        guard !changedPIDs.isEmpty else { return [] }
        let affectedWorkspaceIds = Set(
            allEntries().lazy
                .filter { changedPIDs.contains($0.pid) }
                .map(\.workspaceId)
        )
        let txn = recordReconcileEvent(
            .hiddenApplicationsChanged(
                pids: pids,
                affectedWorkspaceIds: affectedWorkspaceIds,
                source: source
            )
        )
        if txn.plan.focusSession != nil {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return affectedWorkspaceIds
    }

    @discardableResult
    func invalidateAppVisibility(
        for pid: pid_t,
        source: WMEventSource
    ) -> Set<WorkspaceDescriptor.ID> {
        let affectedWorkspaceIds = Set(
            allEntries().lazy
                .filter { $0.pid == pid }
                .map(\.workspaceId)
        )
        recordReconcileEvent(
            .appVisibilityInvalidated(
                pid: pid,
                affectedWorkspaceIds: affectedWorkspaceIds,
                source: source
            )
        )
        return affectedWorkspaceIds
    }
}
