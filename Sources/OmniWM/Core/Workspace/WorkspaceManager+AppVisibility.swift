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
        let entries = allEntries()
        let affectedWorkspaceIds = Set(
            entries.lazy
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
        if AppVisibilityTrace.isActive {
            for pid in changedPIDs {
                let pidEntries = entries.filter { $0.pid == pid }
                AppVisibilityTrace.record(
                    .stateTransition,
                    pid: pid,
                    visibility: pids.contains(pid) ? .hidden : .visible,
                    outcome: .applied,
                    worldSequence: worldSeq,
                    generation: appVisibilityGeneration(for: pid),
                    managedWindowCount: pidEntries.count,
                    affectedWorkspaceCount: Set(pidEntries.map(\.workspaceId)).count,
                    source: source
                )
            }
        }
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
        if AppVisibilityTrace.isActive {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: isAppHidden(pid: pid) ? .hidden : .visible,
                outcome: .invalidated,
                worldSequence: worldSeq,
                generation: appVisibilityGeneration(for: pid),
                managedWindowCount: allEntries().lazy.filter { $0.pid == pid }.count,
                affectedWorkspaceCount: affectedWorkspaceIds.count,
                source: source
            )
        }
        return affectedWorkspaceIds
    }
}
