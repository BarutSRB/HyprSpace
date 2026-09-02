// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct RestorePlanner {
    struct EventInput {
        let event: WMEvent
        let snapshot: ReconcileSnapshot
        let monitors: [Monitor]
    }

    struct EventPlan: Equatable {
        var refreshRestoreIntents: Bool = false
        var interactionMonitorId: Monitor.ID? = nil
        var previousInteractionMonitorId: Monitor.ID? = nil
        var notes: [String] = []
    }

    struct TopologyInput {
        let snapshot: ReconcileSnapshot
        let previousMonitors: [Monitor]
        let newMonitors: [Monitor]
        let visibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]
        let disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID]
        let runtimeOverrideReconnectPreferences: [Monitor.ID: WorkspaceDescriptor.ID]
        let interactionMonitorId: Monitor.ID?
        let previousInteractionMonitorId: Monitor.ID?
        let workspaceExists: (WorkspaceDescriptor.ID) -> Bool
        let homeMonitorId: (WorkspaceDescriptor.ID, [Monitor]) -> Monitor.ID?
        let effectiveMonitorId: (WorkspaceDescriptor.ID, [Monitor]) -> Monitor.ID?
    }

    struct TopologyPlan: Equatable {
        var previousMonitors: [Monitor] = []
        var newMonitors: [Monitor] = []
        var visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]
        var interactionMonitorId: Monitor.ID? = nil
        var previousInteractionMonitorId: Monitor.ID? = nil
        var refreshRestoreIntents: Bool = false
        var notes: [String] = []
    }

    struct PersistedHydrationInput {
        let token: WindowToken
        let metadata: ManagedReplacementMetadata
        let catalog: PersistedWindowRestoreCatalog
        let consumedEntries: Set<PersistedWindowRestoreConsumptionKey>
        let monitors: [Monitor]
        let workspaceIdForName: (String) -> WorkspaceDescriptor.ID?
    }

    struct PersistedHydrationPlan: Equatable {
        let persistedEntry: PersistedWindowRestoreEntry
        let workspaceId: WorkspaceDescriptor.ID
        let preferredMonitorId: Monitor.ID?
        let targetMode: TrackedWindowMode
        let floatingFrame: CGRect?
        let niriPlacement: PersistedNiriPlacement?
        let detachedNiriContainerSizingState: NiriContainerSizingState?
        let dwindlePlacement: PersistedDwindlePlacement?
        let consumedKey: PersistedWindowRestoreKey
        let consumedEntry: PersistedWindowRestoreConsumptionKey
    }

    struct FloatingRescueCandidate: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let currentFrame: CGRect?
        let targetFrame: CGRect
        let isScratchpadHidden: Bool
        let isWorkspaceInactiveHidden: Bool
    }

    struct FloatingRescueOperation: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let targetFrame: CGRect
    }

    struct FloatingRescuePlan: Equatable {
        var operations: [FloatingRescueOperation] = []

        var rescuedCount: Int {
            operations.count
        }
    }

    func planEvent(_ input: EventInput) -> EventPlan {
        var plan = EventPlan()

        switch input.event {
        case .topologyChanged:
            plan.refreshRestoreIntents = true
            plan.notes.append("restore_refresh=topology")
        case .activeSpaceChanged:
            plan.refreshRestoreIntents = true
            plan.notes.append("restore_refresh=active_space")
        case .systemWake:
            plan.refreshRestoreIntents = true
            plan.notes.append("restore_refresh=system_wake")
        case .systemSleep:
            plan.notes.append("restore_refresh=system_sleep")
        case .floatingGeometryUpdated,
             .appVisibilityInvalidated,
             .floatingStateChanged,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .hiddenApplicationsChanged,
             .hiddenStateChanged,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .manualLayoutOverrideChanged,
             .nativeFocusOwnerChanged,
             .nativeFullscreenPlaceholderSelected,
             .nativeFullscreenTransition,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .topLevelInventoryObserved,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .windowAdmitted,
             .windowAdmissionHintsChanged,
             .windowModeChanged,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .workspaceFocusCleared:
            break
        }

        let reconciled = reconcileInteractionMonitors(
            interactionMonitorId: input.snapshot.interactionMonitorId,
            previousInteractionMonitorId: input.snapshot.previousInteractionMonitorId,
            nativeManagedFocusToken: input.snapshot.nativeManagedFocusToken,
            windows: input.snapshot.windows,
            monitors: input.monitors
        )
        plan.interactionMonitorId = reconciled.interactionMonitorId
        plan.previousInteractionMonitorId = reconciled.previousInteractionMonitorId

        return plan
    }

    func planMonitorConfigurationChange(_ input: TopologyInput) -> TopologyPlan {
        let previousMonitorIds = Set(input.previousMonitors.map(\.id))
        let newMonitorIds = Set(input.newMonitors.map(\.id))
        let hasNewMonitor = !newMonitorIds.subtracting(previousMonitorIds).isEmpty

        let visibleSnapshots = input.visibleWorkspaceMap
            .compactMap { monitorId, workspaceId -> WorkspaceRestoreSnapshot? in
                guard let monitor = input.previousMonitors.first(where: { $0.id == monitorId }) else {
                    return nil
                }
                return WorkspaceRestoreSnapshot(
                    monitor: MonitorRestoreKey(monitor: monitor),
                    workspaceId: workspaceId
                )
            }

        let restoredAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: visibleSnapshots,
            monitors: input.newMonitors,
            workspaceExists: input.workspaceExists
        )

        var plan = TopologyPlan()
        plan.previousMonitors = input.previousMonitors
        plan.newMonitors = input.newMonitors
        plan.refreshRestoreIntents = true
        for monitor in Monitor.sortedByPosition(input.newMonitors) {
            guard let workspaceId = restoredAssignments[monitor.id] else { continue }
            guard input.effectiveMonitorId(workspaceId, input.newMonitors) == monitor.id else { continue }
            plan.visibleAssignments[monitor.id] = workspaceId
        }

        var disconnectedCache = input.disconnectedVisibleWorkspaceCache
        let survivingIds = Set(input.newMonitors.map(\.id))
        var migrations: [(removedMonitor: Monitor, workspaceId: WorkspaceDescriptor.ID)] = []

        for monitor in input.previousMonitors where !survivingIds.contains(monitor.id) {
            guard let workspaceId = input.visibleWorkspaceMap[monitor.id],
                  input.workspaceExists(workspaceId)
            else {
                continue
            }
            disconnectedCache[MonitorRestoreKey(monitor: monitor)] = workspaceId
            migrations.append((monitor, workspaceId))
        }

        migrations.sort { lhs, rhs in
            monitorSortKey(lhs.removedMonitor) < monitorSortKey(rhs.removedMonitor)
        }

        if hasNewMonitor, !disconnectedCache.isEmpty {
            let sortedCacheEntries = disconnectedCache.sorted { lhs, rhs in
                restoreKeySortKey(lhs.key) < restoreKeySortKey(rhs.key)
            }

            for (_, workspaceId) in sortedCacheEntries {
                guard input.workspaceExists(workspaceId),
                      let homeMonitorId = input.homeMonitorId(workspaceId, input.newMonitors),
                      plan.visibleAssignments[homeMonitorId] == nil
                else {
                    continue
                }
                plan.visibleAssignments[homeMonitorId] = workspaceId
            }
        }

        var winnerByFallbackMonitorId: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        for migration in migrations {
            guard input.workspaceExists(migration.workspaceId),
                  let fallbackMonitorId = input.effectiveMonitorId(migration.workspaceId, input.newMonitors),
                  winnerByFallbackMonitorId[fallbackMonitorId] == nil
            else {
                continue
            }
            winnerByFallbackMonitorId[fallbackMonitorId] = migration.workspaceId
        }

        for monitor in Monitor.sortedByPosition(input.newMonitors) {
            guard let workspaceId = winnerByFallbackMonitorId[monitor.id] else { continue }
            plan.visibleAssignments[monitor.id] = workspaceId
        }

        let fallbackAssignments = plan.visibleAssignments
        let sortedNewMonitors = Monitor.sortedByPosition(input.newMonitors)
        let validMonitorIds = Set(sortedNewMonitors.map(\.id))
        let confirmedFocusWorkspaceId: WorkspaceDescriptor.ID?
        switch input.snapshot.focusSession.nativeFocusOwner {
        case let .managed(token):
            confirmedFocusWorkspaceId = input.snapshot.windows.first(where: { $0.token == token })?.workspaceId
        case .external,
             .ownedSurface,
             .none:
            confirmedFocusWorkspaceId = nil
        }
        let prioritizesInteractionMonitor: Bool
        switch input.snapshot.focusSession.nativeFocusOwner {
        case .external,
             .ownedSurface:
            prioritizesInteractionMonitor = true
        case .managed,
             .none:
            prioritizesInteractionMonitor = false
        }
        let pendingFocusWorkspaceId = input.snapshot.focusSession.pendingManagedFocus.workspaceId
        var prioritizedAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
        var prioritizedWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        func reserve(_ workspaceId: WorkspaceDescriptor.ID?, on monitorId: Monitor.ID?) {
            guard let workspaceId,
                  let monitorId,
                  input.workspaceExists(workspaceId),
                  validMonitorIds.contains(monitorId),
                  prioritizedWorkspaceIds.insert(workspaceId).inserted
            else {
                return
            }
            guard prioritizedAssignments[monitorId] == nil else { return }
            prioritizedAssignments[monitorId] = workspaceId
        }

        reserve(
            confirmedFocusWorkspaceId,
            on: confirmedFocusWorkspaceId.flatMap {
                input.effectiveMonitorId($0, input.newMonitors)
            }
        )
        reserve(
            pendingFocusWorkspaceId,
            on: pendingFocusWorkspaceId.flatMap {
                input.effectiveMonitorId($0, input.newMonitors)
            }
        )
        for monitor in sortedNewMonitors {
            reserve(
                input.runtimeOverrideReconnectPreferences[monitor.id],
                on: monitor.id
            )
        }
        for monitor in sortedNewMonitors {
            guard prioritizedAssignments[monitor.id] == nil,
                  let workspaceId = fallbackAssignments[monitor.id],
                  input.workspaceExists(workspaceId),
                  input.effectiveMonitorId(workspaceId, input.newMonitors) == monitor.id,
                  prioritizedWorkspaceIds.insert(workspaceId).inserted
            else {
                continue
            }
            prioritizedAssignments[monitor.id] = workspaceId
        }
        plan.visibleAssignments = prioritizedAssignments

        disconnectedCache = disconnectedCache.filter { _, workspaceId in
            guard input.workspaceExists(workspaceId) else {
                return false
            }
            guard let homeMonitorId = input.homeMonitorId(workspaceId, input.newMonitors) else {
                return true
            }
            return plan.visibleAssignments[homeMonitorId] != workspaceId
        }
        plan.disconnectedVisibleWorkspaceCache = disconnectedCache

        let reconciled = reconcileTopologyInteractionMonitors(
            interactionMonitorId: input.interactionMonitorId,
            previousInteractionMonitorId: input.previousInteractionMonitorId,
            confirmedFocusWorkspaceId: confirmedFocusWorkspaceId,
            pendingFocusWorkspaceId: pendingFocusWorkspaceId,
            prioritizesInteractionMonitor: prioritizesInteractionMonitor,
            monitors: input.newMonitors,
            visibleAssignments: plan.visibleAssignments
        )
        plan.interactionMonitorId = reconciled.interactionMonitorId
        plan.previousInteractionMonitorId = reconciled.previousInteractionMonitorId
        plan.notes = [
            "visible_assignments=\(plan.visibleAssignments.count)",
            "disconnected_cache=\(plan.disconnectedVisibleWorkspaceCache.count)"
        ]

        return plan
    }

    private func reconcileTopologyInteractionMonitors(
        interactionMonitorId: Monitor.ID?,
        previousInteractionMonitorId: Monitor.ID?,
        confirmedFocusWorkspaceId: WorkspaceDescriptor.ID?,
        pendingFocusWorkspaceId: WorkspaceDescriptor.ID?,
        prioritizesInteractionMonitor: Bool,
        monitors: [Monitor],
        visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID]
    ) -> (interactionMonitorId: Monitor.ID?, previousInteractionMonitorId: Monitor.ID?) {
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        let validMonitorIds = Set(sortedMonitors.map(\.id))
        let confirmedFocusMonitorId = confirmedFocusWorkspaceId.flatMap { workspaceId in
            sortedMonitors.first(where: { visibleAssignments[$0.id] == workspaceId })?.id
        }
        let pendingFocusMonitorId = pendingFocusWorkspaceId.flatMap { workspaceId in
            sortedMonitors.first(where: { visibleAssignments[$0.id] == workspaceId })?.id
        }
        let connectedInteractionMonitorId = interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }
        let firstAssignedMonitorId = sortedMonitors.first(where: {
            visibleAssignments[$0.id] != nil
        })?.id
        let resolvedInteractionMonitorId = prioritizesInteractionMonitor
            ? connectedInteractionMonitorId
            ?? pendingFocusMonitorId
            ?? firstAssignedMonitorId
            ?? sortedMonitors.first?.id
            : confirmedFocusMonitorId
            ?? pendingFocusMonitorId
            ?? connectedInteractionMonitorId
            ?? firstAssignedMonitorId
            ?? sortedMonitors.first?.id

        let resolvedPreviousInteractionMonitorId: Monitor.ID?
        if let connectedInteractionMonitorId,
           connectedInteractionMonitorId != resolvedInteractionMonitorId
        {
            resolvedPreviousInteractionMonitorId = connectedInteractionMonitorId
        } else {
            resolvedPreviousInteractionMonitorId = previousInteractionMonitorId.flatMap {
                validMonitorIds.contains($0) && $0 != resolvedInteractionMonitorId ? $0 : nil
            }
        }

        return (resolvedInteractionMonitorId, resolvedPreviousInteractionMonitorId)
    }

    func planPersistedHydration(_ input: PersistedHydrationInput) -> PersistedHydrationPlan? {
        let matches = persistedHydrationMatches(
            token: input.token,
            metadata: input.metadata,
            catalog: input.catalog,
            consumedEntries: input.consumedEntries
        )

        guard matches.count == 1,
              let persistedEntry = matches.first,
              let workspaceId = input.workspaceIdForName(persistedEntry.restoreIntent.workspaceName)
        else {
            return nil
        }

        let preferredMonitor = resolvePersistedPreferredMonitor(
            persistedEntry.restoreIntent.preferredMonitor,
            fallbackWorkspaceId: workspaceId,
            monitors: input.monitors
        )

        let targetMode: TrackedWindowMode = persistedEntry.restoreIntent.restoreToFloating ? .floating : input.metadata
            .mode
        let floatingFrame = persistedEntry.restoreIntent.rescueEligible
            ? resolvedPersistedFloatingFrame(
                for: persistedEntry.restoreIntent,
                preferredMonitor: preferredMonitor
            )
            : nil

        return PersistedHydrationPlan(
            persistedEntry: persistedEntry,
            workspaceId: workspaceId,
            preferredMonitorId: preferredMonitor?.id,
            targetMode: targetMode,
            floatingFrame: floatingFrame,
            niriPlacement: persistedEntry.restoreIntent.niriPlacement,
            detachedNiriContainerSizingState: persistedEntry.restoreIntent.detachedNiriContainerSizingState,
            dwindlePlacement: persistedEntry.restoreIntent.dwindlePlacement,
            consumedKey: persistedEntry.key,
            consumedEntry: PersistedWindowRestoreConsumptionKey(entry: persistedEntry)
        )
    }

    private func persistedHydrationMatches(
        token: WindowToken,
        metadata: ManagedReplacementMetadata,
        catalog: PersistedWindowRestoreCatalog,
        consumedEntries: Set<PersistedWindowRestoreConsumptionKey>
    ) -> [PersistedWindowRestoreEntry] {
        let allHardMatches = catalog.entries.filter { entry in
            entry.identity?.matches(token: token, metadata: metadata) == true
        }
        let availableEntries = catalog.entries.filter { entry in
            !consumedEntries.contains(PersistedWindowRestoreConsumptionKey(entry: entry))
        }
        let availableHardMatches = allHardMatches.filter { entry in
            !consumedEntries.contains(PersistedWindowRestoreConsumptionKey(entry: entry))
        }

        if !availableHardMatches.isEmpty {
            return availableHardMatches
        }
        if !allHardMatches.isEmpty {
            return []
        }

        return availableEntries.filter { entry in
            entry.key.matches(metadata)
        }
    }

    func planFloatingRescue(_ candidates: [FloatingRescueCandidate]) -> FloatingRescuePlan {
        var plan = FloatingRescuePlan()

        for candidate in candidates {
            guard !candidate.isScratchpadHidden else { continue }

            let needsRescue = candidate.currentFrame.map {
                candidate.isWorkspaceInactiveHidden || !$0.approximatelyEqual(
                    to: candidate.targetFrame,
                    tolerance: FrameTolerance.frameWrite
                )
            } ?? true
            guard needsRescue else { continue }

            plan.operations.append(
                FloatingRescueOperation(
                    token: candidate.token,
                    pid: candidate.pid,
                    windowId: candidate.windowId,
                    workspaceId: candidate.workspaceId,
                    targetMonitor: candidate.targetMonitor,
                    targetFrame: candidate.targetFrame
                )
            )
        }

        return plan
    }

    private func resolvePersistedPreferredMonitor(
        _ preferredMonitor: DisplayFingerprint?,
        fallbackWorkspaceId _: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Monitor? {
        guard let preferredMonitor else {
            return monitors.first
        }

        if let displayUUID = preferredMonitor.displayUUID {
            var match: Monitor?
            for monitor in monitors where monitor.displayUUID == displayUUID {
                guard match == nil else {
                    match = nil
                    break
                }
                match = monitor
            }
            if let match {
                return match
            }
        } else if let exactRuntimeMonitor = monitors.first(where: {
            $0.displayUUID == nil &&
                $0.displayId == preferredMonitor.displayId &&
                Monitor.namesMatch($0.name, preferredMonitor.name)
        }) {
            return exactRuntimeMonitor
        }

        let bestFallback = monitors.min { lhs, rhs in
            let lhsScore = persistedMonitorMatchScore(
                fingerprint: preferredMonitor,
                monitor: lhs
            )
            let rhsScore = persistedMonitorMatchScore(
                fingerprint: preferredMonitor,
                monitor: rhs
            )
            if lhsScore.namePenalty != rhsScore.namePenalty {
                return lhsScore.namePenalty < rhsScore.namePenalty
            }
            if lhsScore.geometryDelta != rhsScore.geometryDelta {
                return lhsScore.geometryDelta < rhsScore.geometryDelta
            }
            return monitorSortKey(lhs) < monitorSortKey(rhs)
        }

        return bestFallback ?? monitors.first
    }

    private func persistedMonitorMatchScore(
        fingerprint: DisplayFingerprint,
        monitor: Monitor
    ) -> (namePenalty: Int, geometryDelta: CGFloat) {
        let namePenalty = fingerprint.name.localizedCaseInsensitiveCompare(monitor.name) == .orderedSame ? 0 : 1
        let anchorDistance = fingerprint.anchorPoint.distanceSquared(to: monitor.workspaceAnchorPoint)
        let widthDelta = abs(fingerprint.frameSize.width - monitor.frame.width)
        let heightDelta = abs(fingerprint.frameSize.height - monitor.frame.height)
        return (namePenalty, anchorDistance + widthDelta + heightDelta)
    }

    private func resolvedPersistedFloatingFrame(
        for intent: PersistedRestoreIntent,
        preferredMonitor: Monitor?
    ) -> CGRect? {
        guard let floatingFrame = intent.floatingFrame else { return nil }
        guard let preferredMonitor else { return floatingFrame }

        let currentFingerprint = DisplayFingerprint(monitor: preferredMonitor)
        let shouldUseNormalizedOrigin = intent.normalizedFloatingOrigin != nil
            && intent.preferredMonitor != currentFingerprint

        if shouldUseNormalizedOrigin,
           let normalizedFloatingOrigin = intent.normalizedFloatingOrigin
        {
            let origin = FloatingFrameGeometry.origin(
                from: normalizedFloatingOrigin,
                windowSize: floatingFrame.size,
                in: preferredMonitor.visibleFrame
            )
            return FloatingFrameGeometry.clamped(
                CGRect(origin: origin, size: floatingFrame.size),
                in: preferredMonitor.visibleFrame
            )
        }

        return FloatingFrameGeometry.clamped(floatingFrame, in: preferredMonitor.visibleFrame)
    }

    private func reconcileInteractionMonitors(
        interactionMonitorId: Monitor.ID?,
        previousInteractionMonitorId: Monitor.ID?,
        nativeManagedFocusToken: WindowToken?,
        windows: [ReconcileWindowSnapshot],
        monitors: [Monitor],
        visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    ) -> (interactionMonitorId: Monitor.ID?, previousInteractionMonitorId: Monitor.ID?) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceId = nativeManagedFocusToken.flatMap { token in
            windows.first(where: { $0.token == token })?.workspaceId
        }
        let focusedWorkspaceMonitorId = focusedWorkspaceId.flatMap { workspaceId in
            visibleAssignments.first(where: { $0.value == workspaceId })?.key
                ?? Monitor.sortedByPosition(monitors).first?.id
        }

        let resolvedInteractionMonitorId = interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? Monitor.sortedByPosition(monitors).first?.id

        let resolvedPreviousInteractionMonitorId = previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        return (resolvedInteractionMonitorId, resolvedPreviousInteractionMonitorId)
    }

    private func monitorSortKey(_ monitor: Monitor) -> (CGFloat, CGFloat, UInt32) {
        (monitor.frame.minX, -monitor.frame.maxY, monitor.displayId)
    }

    private func restoreKeySortKey(_ restoreKey: MonitorRestoreKey) -> (CGFloat, CGFloat, UInt32) {
        (restoreKey.anchorPoint.x, -restoreKey.anchorPoint.y, restoreKey.displayId)
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
