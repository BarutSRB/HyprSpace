// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension NiriLayoutEngine {
    func ensureMonitor(
        for monitorId: Monitor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation? = nil
    ) -> NiriMonitor {
        if let existing = monitors[monitorId] {
            if let orientation {
                existing.updateOrientation(orientation)
            }
            return existing
        }
        let niriMonitor = NiriMonitor(monitor: monitor, orientation: orientation)
        monitors[monitorId] = niriMonitor
        return niriMonitor
    }

    func monitor(for monitorId: Monitor.ID) -> NiriMonitor? {
        monitors[monitorId]
    }

    func updateMonitors(_ newMonitors: [Monitor], orientations: [Monitor.ID: Monitor.Orientation] = [:]) {
        assertSanctionedMutation()
        for monitor in newMonitors {
            if let niriMonitor = monitors[monitor.id] {
                let orientation = orientations[monitor.id]
                niriMonitor.updateOutputSize(monitor: monitor, orientation: orientation)
            }
        }

        let newIds = Set(newMonitors.map(\.id))
        monitors = monitors.filter { newIds.contains($0.key) }
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitors.removeValue(forKey: monitorId)
    }

    func updateMonitorOrientations(_ orientations: [Monitor.ID: Monitor.Orientation]) {
        assertSanctionedMutation()
        for (monitorId, orientation) in orientations {
            monitors[monitorId]?.updateOrientation(orientation)
        }
    }

    func updateMonitorSettings(_ settings: ResolvedNiriSettings, for monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitors[monitorId]?.resolvedSettings = settings
    }

    func globalResolvedSettings() -> ResolvedNiriSettings {
        ResolvedNiriSettings(
            visibleContainerCount: visibleContainerCount,
            centerFocusedColumn: centerFocusedColumn,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            singleWindowFit: singleWindowFit,
            infiniteLoop: infiniteLoop
        )
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> ResolvedNiriSettings {
        monitors[monitorId]?.resolvedSettings ?? globalResolvedSettings()
    }

    func effectiveSettings(in workspaceId: WorkspaceDescriptor.ID) -> ResolvedNiriSettings {
        guard let monitorId = monitorContaining(workspace: workspaceId) else {
            return globalResolvedSettings()
        }
        return effectiveSettings(for: monitorId)
    }

    func displayScale(in workspaceId: WorkspaceDescriptor.ID) -> CGFloat {
        monitorForWorkspace(workspaceId)?.scale ?? 2.0
    }

    func displayRefreshRate(in workspaceId: WorkspaceDescriptor.ID) -> Double {
        monitorForWorkspace(workspaceId)?.refreshRate ?? 60.0
    }

    func effectiveVisibleContainerCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        effectiveSettings(in: workspaceId).visibleContainerCount
    }

    func effectiveSingleWindowFit(in workspaceId: WorkspaceDescriptor.ID) -> SingleWindowFit {
        effectiveSettings(in: workspaceId).singleWindowFit
    }

    func effectiveInfiniteLoop(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        effectiveSettings(in: workspaceId).infiniteLoop
    }

    /// Reassign a single workspace without pruning unrelated workspaces
    /// that are omitted from the request.
    func moveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        to monitorId: Monitor.ID,
        monitor: Monitor
    ) {
        assertSanctionedMutation()
        let targetMonitor = ensureMonitor(for: monitorId, monitor: monitor)
        removeWorkspaceRootCopies(workspaceId, keepingMonitorId: targetMonitor.id)
        attachWorkspaceRootIfNeeded(workspaceId, to: targetMonitor)
    }

    /// Reconcile the authoritative full workspace-to-monitor assignment set
    /// during monitor sync and prune stale duplicate roots.
    func syncWorkspaceAssignments(
        _ assignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)],
        orientations: [Monitor.ID: Monitor.Orientation] = [:]
    ) {
        assertSanctionedMutation()
        var desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID] = [:]
        desiredOwners.reserveCapacity(assignments.count)

        for assignment in assignments {
            _ = ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor,
                orientation: orientations[assignment.monitor.id]
            )
            desiredOwners[assignment.workspaceId] = assignment.monitor.id
        }

        pruneStaleWorkspaceRootCopies(desiredOwners: desiredOwners)

        for assignment in assignments where desiredOwners[assignment.workspaceId] == assignment.monitor.id {
            let targetMonitor = monitors[assignment.monitor.id] ?? ensureMonitor(
                for: assignment.monitor.id,
                monitor: assignment.monitor,
                orientation: orientations[assignment.monitor.id]
            )
            attachWorkspaceRootIfNeeded(assignment.workspaceId, to: targetMonitor)
        }
    }

    func monitorContaining(workspace workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        for (monitorId, niriMonitor) in monitors {
            if niriMonitor.containsWorkspace(workspaceId) {
                return monitorId
            }
        }
        return nil
    }

    func monitorForWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> NiriMonitor? {
        for niriMonitor in monitors.values {
            if niriMonitor.containsWorkspace(workspaceId) {
                return niriMonitor
            }
        }
        return nil
    }

    private func attachWorkspaceRootIfNeeded(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitor: NiriMonitor
    ) {
        let state = ensureState(for: workspaceId)
        let root = state.root
        if let existing = targetMonitor.workspaceRoots[workspaceId], existing === root {
            return
        }
        if let previousMonitorId = state.attachedMonitorId, previousMonitorId != targetMonitor.id {
            rederiveAutomaticContainerSpans(in: root, for: targetMonitor)
        }
        state.attachedMonitorId = targetMonitor.id
        for column in root.columns {
            column.invalidateCachedPrimarySpan(orientation: .horizontal)
            column.invalidateCachedPrimarySpan(orientation: .vertical)
        }
        targetMonitor.workspaceRoots[workspaceId] = root
    }

    private func rederiveAutomaticContainerSpans(in root: NiriRoot, for monitor: NiriMonitor) {
        guard defaultContainerPrimarySpan == nil else { return }
        let reset = resolvedContainerResetPrimarySpan(for: monitor.id)
        switch monitor.orientation {
        case .horizontal:
            for column in root.columns
                where !column.isFullWidth && !column.hasManualSingleWindowWidthOverride
            {
                column.width = .proportion(reset.proportion)
                column.presetWidthIdx = reset.presetWidthIdx
                column.savedWidth = nil
                column.widthAnimation = nil
                column.targetWidth = nil
            }
        case .vertical:
            for column in root.columns
                where !column.isFullHeight && !column.hasManualSingleWindowHeightOverride
            {
                column.height = .proportion(reset.proportion)
                column.savedHeight = nil
            }
        }
    }

    private func pruneStaleWorkspaceRootCopies(
        desiredOwners: [WorkspaceDescriptor.ID: Monitor.ID]
    ) {
        for niriMonitor in monitors.values {
            let staleWorkspaceIds = Array(
                niriMonitor.workspaceRoots.keys.filter { workspaceId in
                    desiredOwners[workspaceId] != niriMonitor.id
                }
            )
            for workspaceId in staleWorkspaceIds {
                niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
            }
        }
    }

    private func removeWorkspaceRootCopies(
        _ workspaceId: WorkspaceDescriptor.ID,
        keepingMonitorId: Monitor.ID? = nil
    ) {
        for niriMonitor in monitors.values where niriMonitor.id != keepingMonitorId {
            niriMonitor.workspaceRoots.removeValue(forKey: workspaceId)
        }
    }
}
