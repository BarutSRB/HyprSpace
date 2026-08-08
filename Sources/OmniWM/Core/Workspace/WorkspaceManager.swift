// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceManager {
    typealias NativeFullscreenTransition = WorkspaceNativeFullscreenTransition
    typealias NativeFullscreenRecord = WorkspaceNativeFullscreenRecord

    private struct MonitorResolutionContext {
        let monitors: [Monitor]
        let sortedMonitors: [Monitor]
        let topologyProfile: TopologyProfile
        let configuredWorkspaceNames: Set<String>
        let monitorDescriptionByWorkspaceName: [String: MonitorDescription]
    }

    private(set) var monitors: [Monitor] = Monitor.current() {
        didSet { rebuildMonitorIndexes() }
    }

    private var _monitorsById: [Monitor.ID: Monitor] = [:]
    private var _monitorsByName: [String: [Monitor]] = [:]
    let settings: SettingsStore

    private var workspacesById: [WorkspaceDescriptor.ID: WorkspaceDescriptor] = [:]
    private var workspaceIdByName: [String: WorkspaceDescriptor.ID] = [:]
    private var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID] = [:]

    private(set) var gaps: Double = 8
    private(set) var outerGaps: LayoutGaps.OuterGaps = .zero
    private let world = WorldStore()
    private let restorePlanner = RestorePlanner()
    let animationDriver = AnimationDriver()
    private var nativeFullscreenRecordsByOriginalToken: [WindowToken: NativeFullscreenRecord] = [:]
    private var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    var pendingRuntimeMonitorOverrideClearWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
    var isDrainingPendingRuntimeMonitorOverrideClears = false
    private lazy var persistedRestoreCatalogStore = PersistedRestoreCatalogStore(
        bootCatalog: settings.loadPersistedWindowRestoreCatalog(),
        buildSnapshot: { [unowned self] in self.persistedWindowRestoreCatalogBuildSnapshot() },
        save: { [unowned self] in self.settings.savePersistedWindowRestoreCatalog($0) }
    )
    var persistedRestoreBundleIdProvider: ((pid_t) -> String?)?

    private var _cachedSortedMonitors: [Monitor]?
    private var _cachedTopologyProfile: TopologyProfile?
    private var _cachedConfiguredWorkspaceNames: [String]?
    private var _cachedConfiguredWorkspaceNameSet: Set<String>?
    private var _cachedMonitorDescriptionByWorkspaceName: [String: MonitorDescription]?
    private var _cachedSortedWorkspaces: [WorkspaceDescriptor]?
    private var _cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    private var _cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    private var _cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    private var _cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?

    var onGapsChanged: (() -> Void)?
    var onSessionStateChanged: (() -> Void)?
    var onRuntimeInvalidation: ((WorkspaceDescriptor.ID?, InvalidationDomain) -> Void)?
    var onWindowPresenceObserved: ((WindowHandle) -> Void)?
    var onWindowRemoved: ((WindowState) -> Void)?
    var onDeferredWorkspaceMonitorMove: ((WorkspaceMonitorMoveOutcome) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        if monitors.isEmpty {
            monitors = [Monitor.fallback()]
        }
        rebuildMonitorIndexes()
        world.installActiveLayoutResolver { [unowned self] workspaceId in
            self.activeLayoutKind(for: workspaceId)
        }
        applySettings()
        reconcileInteractionMonitorState(notify: false)
    }

    func activeLayoutKind(for workspaceId: WorkspaceDescriptor.ID) -> ActiveLayoutKind {
        guard let descriptor = workspacesById[workspaceId] else { return .niri }
        return settings.layoutType(for: descriptor.name) == .dwindle ? .dwindle : .niri
    }

    func reconcileSnapshot() -> ReconcileSnapshot {
        let windowSnapshots = world.allEntries()
            .sorted {
                if $0.workspaceId != $1.workspaceId {
                    return $0.workspaceId.uuidString < $1.workspaceId.uuidString
                }
                if $0.pid != $1.pid {
                    return $0.pid < $1.pid
                }
                return $0.windowId < $1.windowId
            }
            .map { entry in
                ReconcileWindowSnapshot(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    mode: entry.mode,
                    lifecyclePhase: entry.lifecyclePhase,
                    observedState: entry.observedState,
                    desiredState: entry.desiredState,
                    restoreIntent: entry.restoreIntent,
                    interactionPolicy: entry.interactionPolicy
                )
            }

        var layouts: [WorkspaceDescriptor.ID: LayoutTopology] = [:]
        for workspaceId in Set(windowSnapshots.map(\.workspaceId)) {
            let topology = world.layoutTopology(for: workspaceId)
            if topology.hasColumns || !topology.dwindleFullscreenTokens.isEmpty {
                layouts[workspaceId] = topology
            }
        }

        return ReconcileSnapshot(
            topologyProfile: currentTopologyProfile(),
            focusSession: world.focus,
            windows: windowSnapshots,
            viewports: world.viewports,
            layouts: layouts
        )
    }

    func reconcileSnapshotDump() -> String {
        ReconcileDebugDump.snapshot(reconcileSnapshot())
    }

    func reconcileTraceDump(limit: Int? = nil) -> String {
        ReconcileDebugDump.trace(world.traceRecords(), limit: limit)
    }

    func invariantViolationCountsDump() -> String {
        world.invariantViolationCountsDump()
    }

    var worldSeq: UInt64 {
        world.seq
    }

    func isSeqEpochCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        world.isSeqEpochCurrent(plannedSeq, domains: domains)
    }

    func isSeqCurrent(
        _ plannedSeq: UInt64,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: InvalidationDomain
    ) -> Bool {
        guard workspacesById[workspaceId] != nil else { return false }
        return world.isSeqCurrent(plannedSeq, for: workspaceId, domains: domains)
    }

    @discardableResult
    func recordReconcileEvent(_ event: WMEvent) -> ReconcileTxn {
        let previousFocus = world.focus
        let viewportWorkspaceId = viewportWorkspaceId(for: event)
        let previousViewport = viewportWorkspaceId.flatMap { world.viewports[$0] }
        let txn = world.commit(
            event,
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            resolvePlan: { plan, token, snapshot in
                var plan = plan
                let restoreEventPlan = self.restorePlanner.planEvent(
                    .init(
                        event: event,
                        snapshot: snapshot,
                        monitors: self.monitors
                    )
                )
                if let restoreRefresh = self.plannedRestoreRefresh(
                    from: restoreEventPlan,
                    snapshot: snapshot
                ) {
                    plan.restoreRefresh = restoreRefresh
                }
                if let token, let persistedHydration = self.plannedPersistedHydrationMutation(for: token) {
                    plan = self.mergePersistedHydration(
                        persistedHydration,
                        into: plan,
                        existingEntry: self.world.entry(for: token)
                    )
                }
                if !restoreEventPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: restoreEventPlan.notes)
                }
                return self.applyActionPlan(plan, to: token)
            }
        )
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            noteInvalidation(for: event)
        }
        noteAuxiliaryFocusInvalidationIfNeeded(for: event, previousFocus: previousFocus, plan: txn.plan)
        if let viewportWorkspaceId {
            noteViewportInvalidationIfNeeded(
                for: viewportWorkspaceId,
                previousViewport: previousViewport,
                pendingOffsetAnimation: viewportEventState(for: event)?.hasPendingOffsetAnimation == true
            )
            if let eventState = viewportEventState(for: event) {
                animationDriver.reconcileViewportCommit(
                    workspaceId: viewportWorkspaceId,
                    previous: previousViewport,
                    next: world.viewports[viewportWorkspaceId] ?? eventState,
                    transition: eventState.offsetTransition
                )
            }
        }
        if case let .viewportForgotten(workspaceIds, _) = event {
            animationDriver.removeMotions(for: workspaceIds)
        }
        return txn
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        recordReconcileEvent(
            .layoutOperationPerformed(workspaceId: workspaceId, operation: operation, source: source)
        )
    }

    private func viewportWorkspaceId(for event: WMEvent) -> WorkspaceDescriptor.ID? {
        switch event {
        case let .selectionChanged(workspaceId, _, _),
             let .viewportChanged(workspaceId, _, _):
            workspaceId
        case let .viewportCommitted(workspaceId, _, _):
            workspaceId
        default:
            nil
        }
    }

    private func viewportEventState(for event: WMEvent) -> ViewportState? {
        switch event {
        case let .viewportChanged(_, state, _):
            state
        case let .viewportCommitted(_, state, _):
            state
        default:
            nil
        }
    }

    private func noteViewportInvalidationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        previousViewport: ViewportState?,
        pendingOffsetAnimation: Bool
    ) {
        guard let nextViewport = world.viewports[workspaceId],
              niriViewportChangeRequiresInvalidation(
                  previous: previousViewport,
                  next: nextViewport,
                  pendingOffsetAnimation: pendingOffsetAnimation
              )
        else {
            return
        }
        noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout])
    }

    private func auxiliaryFocusStateChanged(from previous: FocusSessionSnapshot) -> Bool {
        let current = world.focus
        return current.lastTiledFocusedByWorkspace != previous.lastTiledFocusedByWorkspace
            || current.lastFloatingFocusedByWorkspace != previous.lastFloatingFocusedByWorkspace
            || current.lastFocusedByWorkspace != previous.lastFocusedByWorkspace
            || current.lastTiledFocusedToken != previous.lastTiledFocusedToken
            || current.nonManagedFocusToken != previous.nonManagedFocusToken
            || current.suppressedFocusToken != previous.suppressedFocusToken
            || current.systemModalFocusToken != previous.systemModalFocusToken
    }

    private func noteAuxiliaryFocusInvalidationIfNeeded(
        for event: WMEvent,
        previousFocus: FocusSessionSnapshot,
        plan: ActionPlan
    ) {
        switch event {
        case .managedFocusConfirmed,
             .windowModeChanged,
             .windowRekeyed,
             .windowRemoved:
            guard auxiliaryFocusStateChanged(from: previousFocus) else { return }
            let workspaceId = focusInvalidationWorkspaceId(for: world.focus)
            noteFocusInvalidation(previousWorkspaceId: workspaceId, currentWorkspaceId: workspaceId)
        case .nonManagedFocusTargetChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged:
            guard plan.focusSession != nil else { return }
            let workspaceId = focusInvalidationWorkspaceId(for: world.focus)
            noteFocusInvalidation(previousWorkspaceId: workspaceId, currentWorkspaceId: workspaceId)
        case .nativeFullscreenPlaceholderSelected,
             .workspaceFocusCleared:
            guard plan.focusSession != nil else { return }
            noteFocusInvalidation(
                previousWorkspaceId: focusInvalidationWorkspaceId(for: previousFocus),
                currentWorkspaceId: focusInvalidationWorkspaceId(for: world.focus)
            )
        default:
            break
        }
    }

    @discardableResult
    private func recordTopologyChange(to newMonitors: [Monitor]) -> ReconcileTxn {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        let snapshot = reconcileSnapshot()
        let topologyResolutionContext = monitorResolutionContext(for: normalizedMonitors)
        let runtimeOverrideReconnectPreferences = runtimeOverrideReconnectAssignments(
            previousMonitors: monitors,
            newMonitors: normalizedMonitors
        )
        let topologyPlan = restorePlanner.planMonitorConfigurationChange(
            .init(
                snapshot: snapshot,
                previousMonitors: monitors,
                newMonitors: normalizedMonitors,
                visibleWorkspaceMap: activeVisibleWorkspaceMap(),
                disconnectedVisibleWorkspaceCache: disconnectedVisibleWorkspaceCache,
                runtimeOverrideReconnectPreferences: runtimeOverrideReconnectPreferences,
                interactionMonitorId: world.focus.interactionMonitorId,
                previousInteractionMonitorId: world.focus.previousInteractionMonitorId,
                workspaceExists: { [weak self] workspaceId in
                    self?.descriptor(for: workspaceId) != nil
                },
                homeMonitorId: { [weak self] workspaceId, monitors in
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.homeMonitor(for: workspaceId, context: context)?.id
                },
                effectiveMonitorId: { [weak self] workspaceId, monitors in
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.effectiveMonitor(for: workspaceId, context: context)?.id
                }
            )
        )
        let event = WMEvent.topologyChanged(
            displays: topologyResolutionContext.topologyProfile.displays,
            source: .workspaceManager
        )

        let txn = world.commit(
            event,
            monitors: normalizedMonitors,
            snapshot: { self.reconcileSnapshot() },
            resolvePlan: { plan, _, _ in
                var plan = plan
                plan.topologyTransition = TopologyTransitionPlan(
                    previousMonitors: topologyPlan.previousMonitors,
                    newMonitors: topologyPlan.newMonitors,
                    visibleAssignments: topologyPlan.visibleAssignments,
                    disconnectedVisibleWorkspaceCache: topologyPlan.disconnectedVisibleWorkspaceCache,
                    interactionMonitorId: topologyPlan.interactionMonitorId,
                    previousInteractionMonitorId: topologyPlan.previousInteractionMonitorId,
                    refreshRestoreIntents: topologyPlan.refreshRestoreIntents
                )
                plan.notes.append("restore_refresh=topology")
                if !topologyPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: topologyPlan.notes)
                }
                return self.applyActionPlan(plan, to: nil)
            }
        )
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            noteInvalidation(for: event)
        }
        return txn
    }

    private func eventRequiresRuntimeInvalidation(_ event: WMEvent) -> Bool {
        switch event {
        case .activeSpaceChanged,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged:
            return true
        case .floatingGeometryUpdated,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .hiddenStateChanged,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .nativeFullscreenPlaceholderSelected,
             .nativeFullscreenTransition,
             .niriPlacementsResolved,
             .nonManagedFocusChanged,
             .nonManagedFocusTargetChanged,
             .scratchpadChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
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
            return false
        }
    }

    private func applyActionPlan(
        _ plan: ActionPlan,
        to token: WindowToken?
    ) -> ActionPlan {
        var resolvedPlan = plan
        resolvedPlan.restoreIntent = nil

        if let restoreRefresh = plan.restoreRefresh {
            applyRestoreRefresh(restoreRefresh)
        }

        if let focusSession = plan.focusSession {
            world.applyFocusSession(focusSession)
        }

        if let viewportPlan = plan.viewport {
            world.applyViewportPlan(viewportPlan)
        }

        if let topologyTransition = plan.topologyTransition {
            applyTopologyTransition(topologyTransition)
            notifySessionStateChanged()
        }

        guard let token else {
            if resolvedPlan.restoreRefresh?.refreshRestoreIntents == true || resolvedPlan.topologyTransition != nil {
                schedulePersistedWindowRestoreCatalogSave()
            }
            return resolvedPlan
        }

        if let persistedHydration = plan.persistedHydration {
            _ = applyPersistedHydrationMutation(persistedHydration, to: token)
        }

        if let lifecyclePhase = plan.lifecyclePhase {
            world.setLifecyclePhase(lifecyclePhase, for: token)
        }
        if let observedState = plan.observedState {
            world.setObservedState(observedState, for: token)
        }
        if let desiredState = plan.desiredState {
            world.setDesiredState(desiredState, for: token)
        }
        if let entry = world.entry(for: token) {
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            if entry.restoreIntent != restoreIntent {
                world.setRestoreIntent(restoreIntent, for: token)
                resolvedPlan.restoreIntent = restoreIntent
            }
        }
        if !resolvedPlan.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return resolvedPlan
    }

    @discardableResult
    private func applyFocusReconcileEvent(_ event: WMEvent) -> Bool {
        let previousFocusSession = world.focus
        recordReconcileEvent(event)
        return world.focus != previousFocusSession
    }

    private func plannedRestoreRefresh(
        from eventPlan: RestorePlanner.EventPlan,
        snapshot: ReconcileSnapshot
    ) -> RestoreRefreshPlan? {
        let hasInteractionChange = eventPlan.interactionMonitorId != snapshot.interactionMonitorId
            || eventPlan.previousInteractionMonitorId != snapshot.previousInteractionMonitorId
        guard eventPlan.refreshRestoreIntents || hasInteractionChange else {
            return nil
        }

        return RestoreRefreshPlan(
            refreshRestoreIntents: eventPlan.refreshRestoreIntents,
            interactionMonitorId: eventPlan.interactionMonitorId,
            previousInteractionMonitorId: eventPlan.previousInteractionMonitorId
        )
    }

    private func refreshRestoreIntentsForAllEntries() {
        for entry in world.allEntries() {
            world.setRestoreIntent(
                StateReducer.restoreIntent(for: entry, monitors: monitors),
                for: entry.token
            )
        }
    }

    private func applyRestoreRefresh(_ plan: RestoreRefreshPlan) {
        if plan.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
            schedulePersistedWindowRestoreCatalogSave()
        }

        let previousWorkspaceId = world.focus.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let nextWorkspaceId = plan.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let interactionChanged = world.focus.interactionMonitorId != plan.interactionMonitorId
            || world.focus.previousInteractionMonitorId != plan.previousInteractionMonitorId
        world.updateFocus {
            $0.interactionMonitorId = plan.interactionMonitorId
            $0.previousInteractionMonitorId = plan.previousInteractionMonitorId
        }
        if interactionChanged {
            noteFocusInvalidation(
                previousWorkspaceId: previousWorkspaceId,
                currentWorkspaceId: nextWorkspaceId
            )
        }
    }

    private func applyTopologyTransition(_ transition: TopologyTransitionPlan) {
        replaceMonitorsForTopologyTransition(with: transition.newMonitors)
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
            guard let workspaceId = transition.visibleAssignments[monitor.id] else { continue }
            _ = setActiveWorkspaceInternal(
                workspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false,
                context: context
            )
        }

        reconcileConfiguredVisibleWorkspaces(notify: false)
        disconnectedVisibleWorkspaceCache = transition.disconnectedVisibleWorkspaceCache
        world.updateFocus {
            $0.interactionMonitorId = transition.interactionMonitorId
            $0.previousInteractionMonitorId = transition.previousInteractionMonitorId
            if let pendingWorkspaceId = $0.pendingManagedFocus.workspaceId,
               let pendingMonitorId = effectiveMonitor(for: pendingWorkspaceId, context: context)?.id
            {
                $0.pendingManagedFocus.monitorId = pendingMonitorId
            }
        }
        reconcileInteractionMonitorState(notify: false)
        refreshWindowMonitorReferencesForAllEntries()
        if transition.refreshRestoreIntents {
            refreshRestoreIntentsForAllEntries()
        }
    }

    private func replaceMonitorsForTopologyTransition(with newMonitors: [Monitor]) {
        monitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors

        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        commitMonitorSessions(world.monitorSessions.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        })
        invalidateWorkspaceProjectionCaches()
    }

    private func refreshWindowMonitorReferencesForAllEntries() {
        let context = monitorResolutionContext()
        for entry in world.allEntries() {
            let currentMonitorId = monitorId(for: entry.workspaceId, context: context)
            if entry.observedState.monitorId != currentMonitorId {
                var observedState = entry.observedState
                observedState.monitorId = currentMonitorId
                world.setObservedState(observedState, for: entry.token)
            }
            if entry.desiredState.monitorId != currentMonitorId {
                var desiredState = entry.desiredState
                desiredState.monitorId = currentMonitorId
                world.setDesiredState(desiredState, for: entry.token)
            }
        }
    }

    private func plannedPersistedHydrationMutation(for token: WindowToken) -> PersistedHydrationMutation? {
        guard let entry = world.entry(for: token),
              entry.hiddenState == nil,
              let metadata = persistedRestoreMetadata(for: entry),
              let hydrationPlan = restorePlanner.planPersistedHydration(
                  .init(
                      token: token,
                      metadata: metadata,
                      catalog: persistedRestoreCatalogStore.bootCatalog,
                      consumedEntries: persistedRestoreCatalogStore.consumedBootEntries,
                      monitors: monitors,
                      workspaceIdForName: { [weak self] workspaceName in
                          self?.workspaceId(for: workspaceName, createIfMissing: false)
                      }
                  )
              )
        else {
            return nil
        }

        return PersistedHydrationMutation(
            workspaceId: hydrationPlan.workspaceId,
            monitorId: hydrationPlan.preferredMonitorId ?? effectiveMonitor(for: hydrationPlan.workspaceId)?.id,
            targetMode: hydrationPlan.targetMode,
            floatingFrame: hydrationPlan.floatingFrame,
            niriPlacement: hydrationPlan.niriPlacement,
            detachedNiriContainerSizingState: hydrationPlan.detachedNiriContainerSizingState,
            consumedKey: hydrationPlan.consumedKey,
            consumedEntry: hydrationPlan.consumedEntry
        )
    }

    private func mergePersistedHydration(
        _ hydration: PersistedHydrationMutation,
        into plan: ActionPlan,
        existingEntry: WindowState?
    ) -> ActionPlan {
        var mergedPlan = plan
        let monitorId = hydration.monitorId

        var observedState = mergedPlan.observedState
            ?? existingEntry?.observedState
            ?? ObservedWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId
            )
        observedState.workspaceId = hydration.workspaceId
        observedState.monitorId = monitorId ?? observedState.monitorId
        mergedPlan.observedState = observedState

        var desiredState = mergedPlan.desiredState
            ?? existingEntry?.desiredState
            ?? DesiredWindowState.initial(
                workspaceId: hydration.workspaceId,
                monitorId: monitorId,
                disposition: hydration.targetMode
            )
        desiredState.workspaceId = hydration.workspaceId
        desiredState.monitorId = monitorId ?? desiredState.monitorId
        desiredState.disposition = hydration.targetMode
        if let floatingFrame = hydration.floatingFrame {
            desiredState.floatingFrame = floatingFrame
            desiredState.rescueEligible = true
        } else if hydration.targetMode == .floating {
            desiredState.rescueEligible = true
        }
        mergedPlan.desiredState = desiredState
        mergedPlan.lifecyclePhase = hydration.targetMode == .floating ? .floating : .tiled
        mergedPlan.persistedHydration = hydration
        mergedPlan.notes.append("persisted_hydration")
        return mergedPlan
    }

    @discardableResult
    private func applyPersistedHydrationMutation(
        _ hydration: PersistedHydrationMutation,
        to token: WindowToken
    ) -> Bool {
        guard let entry = world.entry(for: token) else {
            return false
        }

        if entry.workspaceId != hydration.workspaceId {
            world.updateWorkspace(for: token, workspace: hydration.workspaceId, monitors: monitors)
        }

        let focusChanged = applyWindowModeMutationWithoutReconcile(
            hydration.targetMode,
            for: token,
            workspaceId: hydration.workspaceId
        )

        if let entry = world.entry(for: token) {
            var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            restoreIntent.niriPlacement = hydration.niriPlacement
            restoreIntent.detachedNiriContainerSizingState = hydration.detachedNiriContainerSizingState
            world.setRestoreIntent(restoreIntent, for: token)
        }

        if let floatingFrame = hydration.floatingFrame {
            let referenceMonitor = hydration.monitorId.flatMap(monitor(byId:))
            let referenceVisibleFrame = referenceMonitor?.visibleFrame ?? floatingFrame
            let normalizedOrigin = normalizedFloatingOrigin(
                for: floatingFrame,
                in: referenceVisibleFrame
            )
            world.setFloatingState(
                .init(
                    lastFrame: floatingFrame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitor?.id,
                    restoreToFloating: true
                ),
                for: token
            )
        }

        persistedRestoreCatalogStore.noteConsumed(hydration.consumedEntry)
        if focusChanged {
            notifySessionStateChanged()
        }
        return true
    }

    @discardableResult
    private func applyWindowModeMutationWithoutReconcile(
        _ mode: TrackedWindowMode,
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        world.setMode(mode, for: token, monitors: monitors)
        let previousWorkspaceId = focusInvalidationWorkspaceId(for: world.focus)
        guard world.updateFocus({
            $0.reconcileRememberedFocus(afterModeChangeOf: token, in: workspaceId, to: mode)
        }) else {
            return false
        }
        noteFocusInvalidation(
            previousWorkspaceId: previousWorkspaceId,
            currentWorkspaceId: focusInvalidationWorkspaceId(for: world.focus)
        )
        return true
    }

    func flushPersistedWindowRestoreCatalogNow() {
        persistedRestoreCatalogStore.flushNow()
    }

    private func schedulePersistedWindowRestoreCatalogSave() {
        persistedRestoreCatalogStore.scheduleSave()
    }

    private func persistedRestoreMetadata(for entry: WindowState) -> ManagedReplacementMetadata? {
        let bundleId = entry.managedReplacementMetadata?.bundleId
            ?? persistedRestoreBundleIdProvider?(entry.pid)
        guard bundleId != nil || entry.managedReplacementMetadata != nil else {
            return nil
        }

        let fallback = ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: entry.observedState.frame ?? entry.desiredState.floatingFrame ?? entry.floatingState?.lastFrame,
            transientWindowServerEvidence: entry.managedReplacementMetadata?.transientWindowServerEvidence ?? false,
            degradedWindowServerChildEvidence: entry.managedReplacementMetadata?
                .degradedWindowServerChildEvidence ?? false
        )

        guard let metadata = entry.managedReplacementMetadata else {
            return fallback
        }

        var merged = fallback.mergingNonNilValues(from: metadata)
        merged.workspaceId = entry.workspaceId
        merged.mode = entry.mode
        return merged
    }

    private func persistedWindowRestoreCatalogBuildSnapshot() -> PersistedWindowRestoreCatalogBuildSnapshot {
        let context = monitorResolutionContext()
        let topologyProfile = context.topologyProfile
        var snapshotEntries: [PersistedWindowRestoreCatalogBuildEntry] = []

        for entry in world.allEntries() {
            guard let metadata = persistedRestoreMetadata(for: entry),
                  let restoreIntent = entry.restoreIntent,
                  let workspaceName = descriptor(for: entry.workspaceId)?.name
            else {
                continue
            }

            let preferredMonitor: DisplayFingerprint?
            if configuredMonitorDescription(for: workspaceName, context: context) != nil {
                preferredMonitor = homeMonitor(for: entry.workspaceId, context: context).map(DisplayFingerprint.init)
            } else {
                preferredMonitor = monitor(for: entry.workspaceId, context: context).map(DisplayFingerprint.init)
                    ?? restoreIntent.preferredMonitor
            }

            snapshotEntries.append(
                PersistedWindowRestoreCatalogBuildEntry(
                    token: entry.token,
                    metadata: metadata,
                    workspaceName: workspaceName,
                    topologyProfile: topologyProfile,
                    preferredMonitor: preferredMonitor,
                    floatingFrame: restoreIntent.floatingFrame,
                    normalizedFloatingOrigin: restoreIntent.normalizedFloatingOrigin,
                    restoreToFloating: restoreIntent.restoreToFloating,
                    rescueEligible: restoreIntent.rescueEligible,
                    niriPlacement: restoreIntent.niriPlacement,
                    detachedNiriContainerSizingState: restoreIntent.detachedNiriContainerSizingState
                )
            )
        }

        return PersistedWindowRestoreCatalogBuildSnapshot(entries: snapshotEntries)
    }

    func monitor(byId id: Monitor.ID) -> Monitor? {
        _monitorsById[id]
    }

    func monitor(named name: String) -> Monitor? {
        guard let matches = _monitorsByName[name], matches.count == 1 else { return nil }
        return matches[0]
    }

    func monitors(named name: String) -> [Monitor] {
        _monitorsByName[name] ?? []
    }

    var interactionMonitorId: Monitor.ID? {
        world.focus.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        world.focus.previousInteractionMonitorId
    }

    var focusedToken: WindowToken? {
        world.focus.focusedToken
    }

    var lastTiledFocusedToken: WindowToken? {
        world.focus.lastTiledFocusedToken
    }

    func mostRecentlyFocusedTiledToken(excluding token: WindowToken) -> WindowToken? {
        world.focus.tiledFocusHistory.first { candidate in
            candidate != token && (windowMode(for: candidate) ?? .tiling) == .tiling && entry(for: candidate) != nil
        }
    }

    var focusedHandle: WindowHandle? {
        focusedToken.flatMap { world.handle(for: $0) }
    }

    var pendingFocusedToken: WindowToken? {
        world.focus.pendingManagedFocus.token
    }

    var pendingFocusedHandle: WindowHandle? {
        pendingFocusedToken.flatMap { world.handle(for: $0) }
    }

    var pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? {
        world.focus.pendingManagedFocus.workspaceId
    }

    var pendingFocusedMonitorId: Monitor.ID? {
        world.focus.pendingManagedFocus.monitorId
    }

    var isNonManagedFocusActive: Bool {
        world.focus.isNonManagedFocusActive
    }

    var isAppFullscreenActive: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains { $0.transition == .suspended }
    }

    var hasNativeFullscreenLifecycleContext: Bool {
        !nativeFullscreenRecordsByOriginalToken.isEmpty
    }

    func scratchpadToken() -> WindowToken? {
        world.scratchpadToken
    }

    @discardableResult
    func setScratchpadToken(_ token: WindowToken?) -> Bool {
        updateScratchpadToken(token, notify: true)
    }

    @discardableResult
    func clearScratchpadIfMatches(_ token: WindowToken) -> Bool {
        clearScratchpadToken(matching: token, notify: true)
    }

    func isScratchpadToken(_ token: WindowToken) -> Bool {
        world.scratchpadToken == token
    }

    var hasPendingNativeFullscreenTransition: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.transition == .enterRequested
        }
    }

    @discardableResult
    func setInteractionMonitor(_ monitorId: Monitor.ID?, preservePrevious: Bool = true) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        return updateInteractionMonitor(normalizedMonitorId, preservePrevious: preservePrevious, notify: true)
    }

    @discardableResult
    func setManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: nil) else {
            return false
        }
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: nil,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    @discardableResult
    func beginManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        requestId: UInt64
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        changed = applyFocusReconcileEvent(
            .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func selectNativeFullscreenPlaceholder(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = applyFocusReconcileEvent(
            .nativeFullscreenPlaceholderSelected(
                token: token,
                workspaceId: workspaceId,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    @discardableResult
    func confirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        activateWorkspaceOnMonitor: Bool,
        requestId: UInt64? = nil
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        guard canConfirmManagedFocus(token, in: workspaceId, requestId: requestId) else {
            return false
        }
        var changed = false

        if activateWorkspaceOnMonitor,
           let normalizedMonitorId,
           let monitor = monitor(byId: normalizedMonitorId)
        {
            changed = setActiveWorkspaceInternal(
                workspaceId,
                on: normalizedMonitorId,
                anchorPoint: monitor.workspaceAnchorPoint,
                updateInteractionMonitor: false,
                notify: false
            ) || changed
        }

        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }

        changed = rememberFocus(token, in: workspaceId) || changed
        changed = applyFocusReconcileEvent(
            .managedFocusConfirmed(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed

        if changed {
            notifySessionStateChanged()
        }

        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    func canConfirmManagedFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64?
    ) -> Bool {
        if let requestId {
            return pendingManagedFocusMatches(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId
            )
        }
        let request = world.focus.pendingManagedFocus
        guard request != .empty else {
            return true
        }
        return request.requestId == nil
            && request.token == token
            && request.workspaceId == workspaceId
    }

    @discardableResult
    func cancelManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        requestId: UInt64?
    ) -> Bool {
        let changed = applyFocusReconcileEvent(
            .managedFocusCancelled(
                token: token,
                workspaceId: workspaceId,
                requestId: requestId,
                source: .workspaceManager
            )
        )

        if changed {
            notifySessionStateChanged()
        }

        drainPendingRuntimeMonitorOverrideClears()
        return changed
    }

    @discardableResult
    func cancelCurrentManagedFocusRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> Bool {
        let request = world.focus.pendingManagedFocus
        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace, request != .empty else {
            return false
        }
        return cancelManagedFocusRequest(
            matching: token,
            workspaceId: workspaceId,
            requestId: request.requestId
        )
    }

    @discardableResult
    func exitNonManagedFocus() -> Bool {
        let changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: false,
                preserveFocusedToken: true,
                preservePendingManagedFocus: false,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    func nativeFullscreenRecord(for token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return nativeFullscreenRecordsByOriginalToken[originalToken]
    }

    func hasNativeFullscreenRecord(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.workspaceId == workspaceId
        }
    }

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        var changed = rememberFocus(token, in: workspaceId)
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            exitRequestedByCommand: false,
            transition: .enterRequested
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .enterRequested {
            record.transition = .enterRequested
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed || existing == nil
    }

    @discardableResult
    func markNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }

        var changed = rememberFocus(token, in: entry.workspaceId)
        let workspaceId = workspace(for: token) ?? entry.workspaceId
        let originalToken = nativeFullscreenOriginalToken(for: token) ?? token
        let existing = nativeFullscreenRecordsByOriginalToken[originalToken]
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            exitRequestedByCommand: false,
            transition: .suspended
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.exitRequestedByCommand {
            record.exitRequestedByCommand = false
            changed = true
        }
        if record.transition != .suspended {
            record.transition = .suspended
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        if layoutReason(for: token) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: token)
            changed = true
        }
        changed = enterNonManagedFocus() || changed
        return changed
    }

    @discardableResult
    func requestNativeFullscreenExit(
        _ token: WindowToken,
        initiatedByCommand: Bool
    ) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        if existing == nil, entry(for: token) == nil {
            return false
        }

        let originalToken = existing?.originalToken ?? token
        let workspaceId = existing?.workspaceId ?? workspace(for: token)
        guard let workspaceId else { return false }

        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            exitRequestedByCommand: initiatedByCommand,
            transition: .exitRequested
        )

        var changed = existing == nil
        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.exitRequestedByCommand != initiatedByCommand {
            record.exitRequestedByCommand = initiatedByCommand
            changed = true
        }
        if record.transition != .exitRequested {
            record.transition = .exitRequested
            changed = true
        }
        if changed {
            upsertNativeFullscreenRecord(record)
        }

        return changed
    }

    @discardableResult
    func restoreNativeFullscreenRecord(for token: WindowToken) -> Bool {
        let record = nativeFullscreenRecord(for: token)
        let resolvedToken = record?.currentToken ?? token
        if let record {
            _ = removeNativeFullscreenRecord(originalToken: record.originalToken)
        }
        let restored = restoreFromNativeState(
            for: resolvedToken,
            drainPendingRuntimeMonitorOverrides: false
        )
        _ = exitNonManagedFocus()
        drainPendingRuntimeMonitorOverrideClears()
        return restored
    }

    func reconcileNativeFullscreenWithTopology() {
        let topology = world.spaceTopology
        guard topology.isPopulated else { return }
        for entry in world.allEntries() where entry.mode == .tiling {
            reconcileNativeFullscreenWithTopology(for: entry.token)
        }
    }

    @discardableResult
    func reconcileNativeFullscreenWithTopology(for token: WindowToken) -> Bool {
        let topology = world.spaceTopology
        guard topology.isPopulated,
              let entry = entry(for: token),
              entry.mode == .tiling,
              entry.windowId > 0,
              let spaceId = topology.spaceForWindow(entry.windowId)
        else {
            return false
        }

        let onFullscreenSpace = topology.isFullscreenSpace(spaceId)
        let isSuspended = entry.layoutReason == .nativeFullscreen
        if onFullscreenSpace, !isSuspended, topology.isCurrentSpace(spaceId) {
            return markNativeFullscreenSuspended(entry.token)
        }
        if !onFullscreenSpace, isSuspended {
            return restoreNativeFullscreenRecord(for: entry.token)
        }
        return false
    }

    func isWindowOnObservedNativeFullscreenSpace(_ windowId: Int) -> Bool {
        world.spaceTopology.isWindowOnFullscreenSpace(windowId)
    }

    func nativeFullscreenCommandTarget(frontmostToken: WindowToken?) -> WindowToken? {
        if let frontmostToken,
           let record = nativeFullscreenRecord(for: frontmostToken),
           record.currentToken == frontmostToken,
           record.transition == .suspended || record.transition == .exitRequested
        {
            return record.currentToken
        }

        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter {
            $0.transition == .suspended || $0.transition == .exitRequested
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].currentToken
    }

    @discardableResult
    func rememberFocus(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        let mode = windowMode(for: token) ?? .tiling
        let modeSpecificChanged = switch mode {
        case .tiling:
            world.focus.lastTiledFocusedByWorkspace[workspaceId] != token
        case .floating:
            world.focus.lastFloatingFocusedByWorkspace[workspaceId] != token
        }
        let changed = world.focus.lastFocusedByWorkspace[workspaceId] != token
            || modeSpecificChanged
        guard changed else { return false }
        recordReconcileEvent(
            .focusRemembered(
                token: token,
                workspaceId: workspaceId,
                mode: mode,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func syncWorkspaceFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> Bool {
        rememberFocus(token, in: workspaceId)
    }

    @discardableResult
    func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        var changed = false

        if let nodeId {
            let currentSelection = niriViewportState(for: workspaceId).selectedNodeId
            if currentSelection != nodeId {
                recordReconcileEvent(
                    .selectionChanged(
                        workspaceId: workspaceId,
                        nodeId: nodeId,
                        source: .workspaceManager
                    )
                )
                changed = true
            }
        }

        if let focusedToken {
            changed = syncWorkspaceFocus(
                focusedToken,
                in: workspaceId,
                onMonitor: monitorId
            ) || changed
        }

        return changed
    }

    @discardableResult
    func applySessionPatch(_ patch: WorkspaceSessionPatch) -> Bool {
        guard isSeqCurrent(
            patch.plannedSeq,
            for: patch.workspaceId,
            domains: .layoutCommit
        ) else {
            return false
        }

        var changed = false

        if var viewportState = patch.viewportState {
            normalizeNiriRefreshRate(&viewportState, for: patch.workspaceId)
            recordReconcileEvent(
                .viewportCommitted(
                    workspaceId: patch.workspaceId,
                    state: viewportState,
                    source: .workspaceManager
                )
            )
            changed = true
        }

        if let rememberedFocusToken = patch.rememberedFocusToken {
            if isSeqCurrent(
                patch.plannedSeq,
                for: patch.workspaceId,
                domains: .focusCommit
            ) {
                changed = rememberFocus(rememberedFocusToken, in: patch.workspaceId) || changed
            }
        }

        return changed
    }

    func lastFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        world.focus.lastTiledFocusedByWorkspace[workspaceId]
    }

    func lastFloatingFocusedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        world.focus.lastFloatingFocusedByWorkspace[workspaceId]
    }

    func preferredFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let pendingToken = eligibleFocusCandidate(
            world.focus.pendingManagedFocus.token,
            in: workspaceId,
            mode: .tiling
        ),
            world.focus.pendingManagedFocus.workspaceId == workspaceId
        {
            return pendingToken
        }

        if let remembered = eligibleFocusCandidate(
            world.focus.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }

        if let confirmed = eligibleFocusCandidate(
            world.focus.focusedToken,
            in: workspaceId,
            mode: .tiling
        ) {
            return confirmed
        }

        return tiledEntries(in: workspaceId).first {
            isFocusResolutionEligible($0, in: workspaceId, mode: .tiling)
        }?.token
    }

    func resolveWorkspaceFocusToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        if let mostRecent = world.focus.lastFocusedByWorkspace[workspaceId],
           let mode = windowMode(for: mostRecent),
           let remembered = eligibleFocusCandidate(mostRecent, in: workspaceId, mode: mode)
        {
            return remembered
        }

        if let remembered = eligibleFocusCandidate(
            world.focus.lastTiledFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .tiling
        ) {
            return remembered
        }
        if let preferredTiled = preferredFocusToken(in: workspaceId) {
            return preferredTiled
        }
        if let rememberedFloating = eligibleFocusCandidate(
            world.focus.lastFloatingFocusedByWorkspace[workspaceId],
            in: workspaceId,
            mode: .floating
        ) {
            return rememberedFloating
        }
        if let confirmed = eligibleFocusCandidate(
            world.focus.focusedToken,
            in: workspaceId,
            mode: .floating
        ) {
            return confirmed
        }
        return floatingEntries(in: workspaceId).first {
            isFocusResolutionEligible($0, in: workspaceId, mode: .floating)
        }?.token
    }

    @discardableResult
    func resolveAndSetWorkspaceFocusToken(
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor _: Monitor.ID? = nil
    ) -> WindowToken? {
        if let token = resolveWorkspaceFocusToken(in: workspaceId) {
            _ = rememberFocus(token, in: workspaceId)
            return token
        }

        let focus = world.focus
        let clearsPending = focus.pendingManagedFocus != .empty
            && focus.pendingManagedFocus.workspaceId == workspaceId
        let clearsFocused = focus.focusedToken.flatMap { entry(for: $0)?.workspaceId } == workspaceId
        if clearsPending || clearsFocused,
           applyFocusReconcileEvent(.workspaceFocusCleared(workspaceId: workspaceId, source: .workspaceManager))
        {
            notifySessionStateChanged()
        }

        return nil
    }

    @discardableResult
    func enterNonManagedFocus(
        preserveFocusedToken: Bool = false,
        preservePendingManagedFocus: Bool = false,
        target: WindowToken? = nil
    ) -> Bool {
        var changed = applyFocusReconcileEvent(
            .nonManagedFocusChanged(
                active: true,
                preserveFocusedToken: preserveFocusedToken,
                preservePendingManagedFocus: preservePendingManagedFocus,
                source: .workspaceManager
            )
        )
        if world.focus.nonManagedFocusToken != target {
            changed = applyFocusReconcileEvent(
                .nonManagedFocusTargetChanged(target: target, source: .workspaceManager)
            ) || changed
        }
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    var nonManagedFocusToken: WindowToken? {
        world.focus.nonManagedFocusToken
    }

    var suppressedFocusToken: WindowToken? {
        world.focus.suppressedFocusToken
    }

    var systemModalFocusToken: WindowToken? {
        world.focus.systemModalFocusToken
    }

    var renderableFocusToken: WindowToken? {
        if world.focus.isNonManagedFocusActive {
            return world.focus.nonManagedFocusToken
        }
        return world.focus.focusedToken
    }

    func clearNonManagedFocusTarget(matching token: WindowToken? = nil, pid: pid_t? = nil) {
        guard let current = world.focus.nonManagedFocusToken else { return }
        if let token, current != token { return }
        if let pid, current.pid != pid { return }
        if applyFocusReconcileEvent(.nonManagedFocusTargetChanged(target: nil, source: .workspaceManager)) {
            notifySessionStateChanged()
        }
    }

    func suppressFocusBorder(for token: WindowToken) {
        guard world.focus.suppressedFocusToken != token else { return }
        if applyFocusReconcileEvent(.suppressedFocusChanged(token: token, source: .workspaceManager)) {
            notifySessionStateChanged()
        }
    }

    func setSystemModalFocus(_ token: WindowToken?) {
        guard world.focus.systemModalFocusToken != token else { return }
        if applyFocusReconcileEvent(
            .systemModalFocusChanged(token: token, source: .workspaceManager)
        ) {
            notifySessionStateChanged()
        }
    }

    private func focusInvalidationWorkspaceId(for focus: FocusSessionSnapshot) -> WorkspaceDescriptor.ID? {
        focus.pendingManagedFocus.workspaceId
            ?? focus.focusedToken.flatMap { world.entry(for: $0)?.workspaceId }
    }

    private func noteFocusInvalidation(
        previousWorkspaceId: WorkspaceDescriptor.ID?,
        currentWorkspaceId: WorkspaceDescriptor.ID?
    ) {
        if let currentWorkspaceId {
            noteInvalidation(workspaceId: currentWorkspaceId, domains: .focus)
        }
        if let previousWorkspaceId, previousWorkspaceId != currentWorkspaceId {
            noteInvalidation(workspaceId: previousWorkspaceId, domains: .focus)
        }
        if previousWorkspaceId == nil, currentWorkspaceId == nil {
            noteInvalidation(workspaceId: nil, domains: .focus)
        }
    }

    func pendingManagedFocusMatches(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        requestId: UInt64
    ) -> Bool {
        let request = world.focus.pendingManagedFocus
        return request.token == token
            && request.workspaceId == workspaceId
            && request.requestId == requestId
    }

    private func eligibleFocusCandidate(
        _ token: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        guard let token,
              let entry = entry(for: token),
              isFocusResolutionEligible(entry, in: workspaceId, mode: mode)
        else {
            return nil
        }
        return token
    }

    private func isFocusResolutionEligible(
        _ entry: WindowState,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        guard entry.workspaceId == workspaceId,
              entry.mode == mode
        else {
            return false
        }

        guard let hiddenState = entry.hiddenState else {
            return true
        }

        return hiddenState.workspaceInactive
    }

    @discardableResult
    private func updateScratchpadToken(_ token: WindowToken?, notify: Bool) -> Bool {
        let previousToken = world.scratchpadToken
        guard previousToken != token else { return false }
        let previousWorkspaceId = previousToken.flatMap { world.entry(for: $0)?.workspaceId }
        let nextWorkspaceId = token.flatMap { world.entry(for: $0)?.workspaceId }
        if token != nil, nextWorkspaceId == nil {
            return false
        }
        recordReconcileEvent(.scratchpadChanged(token: token, source: .workspaceManager))
        let affectedWorkspaceIds = Set([previousWorkspaceId, nextWorkspaceId].compactMap { $0 })
        for workspaceId in affectedWorkspaceIds {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
        }
        if notify {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }

    @discardableResult
    private func clearScratchpadToken(matching token: WindowToken, notify: Bool) -> Bool {
        guard world.scratchpadToken == token else { return false }
        return updateScratchpadToken(nil, notify: notify)
    }

    private func normalizedFloatingOrigin(
        for frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(1, visibleFrame.width - frame.width)
        let availableHeight = max(1, visibleFrame.height - frame.height)
        let normalizedX = (frame.origin.x - visibleFrame.minX) / availableWidth
        let normalizedY = (frame.origin.y - visibleFrame.minY) / availableHeight
        return CGPoint(
            x: min(max(0, normalizedX), 1),
            y: min(max(0, normalizedY), 1)
        )
    }

    private func floatingOrigin(
        from normalizedOrigin: CGPoint,
        windowSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(0, visibleFrame.width - windowSize.width)
        let availableHeight = max(0, visibleFrame.height - windowSize.height)
        return CGPoint(
            x: visibleFrame.minX + min(max(0, normalizedOrigin.x), 1) * availableWidth,
            y: visibleFrame.minY + min(max(0, normalizedOrigin.y), 1) * availableHeight
        )
    }

    private func clampedFloatingFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), maxX >= visibleFrame.minX ? maxX : visibleFrame.minX)
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), maxY >= visibleFrame.minY ? maxY : visibleFrame.minY)
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
    }

    private func rebuildMonitorIndexes() {
        _cachedSortedMonitors = nil
        _cachedTopologyProfile = nil
        _monitorsById = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        var byName: [String: [Monitor]] = [:]
        for monitor in monitors {
            byName[monitor.name, default: []].append(monitor)
        }
        for key in byName.keys {
            byName[key] = Monitor.sortedByPosition(byName[key] ?? [])
        }
        _monitorsByName = byName
        invalidateWorkspaceProjectionCaches()
    }

    func invalidateSettingsProjectionCaches() {
        _cachedConfiguredWorkspaceNames = nil
        _cachedConfiguredWorkspaceNameSet = nil
        _cachedMonitorDescriptionByWorkspaceName = nil
    }

    func invalidateWorkspaceProjectionCaches() {
        _cachedWorkspaceIdsByMonitor = nil
        _cachedVisibleWorkspaceIds = nil
        _cachedVisibleWorkspaceMap = nil
        _cachedMonitorIdByVisibleWorkspace = nil
    }

    func sortedMonitors() -> [Monitor] {
        if let cached = _cachedSortedMonitors {
            return cached
        }
        let sorted = Monitor.sortedByPosition(monitors)
        _cachedSortedMonitors = sorted
        return sorted
    }

    private func currentTopologyProfile() -> TopologyProfile {
        if let cached = _cachedTopologyProfile {
            return cached
        }
        let profile = TopologyProfile(sortedMonitors: sortedMonitors())
        _cachedTopologyProfile = profile
        return profile
    }

    private func configuredWorkspaceNames() -> [String] {
        if let cached = _cachedConfiguredWorkspaceNames {
            return cached
        }
        let names = settings.configuredWorkspaceNames()
        _cachedConfiguredWorkspaceNames = names
        return names
    }

    private func configuredWorkspaceNameSet() -> Set<String> {
        if let cached = _cachedConfiguredWorkspaceNameSet {
            return cached
        }
        let names = Set(configuredWorkspaceNames())
        _cachedConfiguredWorkspaceNameSet = names
        return names
    }

    private func monitorDescriptionByWorkspaceName() -> [String: MonitorDescription] {
        if let cached = _cachedMonitorDescriptionByWorkspaceName {
            return cached
        }
        var descriptions: [String: MonitorDescription] = [:]
        for configuration in settings.workspaceConfigurations {
            descriptions[configuration.name] = configuration.monitorAssignment.toMonitorDescription()
        }
        _cachedMonitorDescriptionByWorkspaceName = descriptions
        return descriptions
    }

    private func monitorResolutionContext() -> MonitorResolutionContext {
        MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: sortedMonitors(),
            topologyProfile: currentTopologyProfile(),
            configuredWorkspaceNames: configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: monitorDescriptionByWorkspaceName()
        )
    }

    private func monitorResolutionContext(for monitors: [Monitor]) -> MonitorResolutionContext {
        if monitors == self.monitors {
            return monitorResolutionContext()
        }
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        return MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: sortedMonitors,
            topologyProfile: TopologyProfile(sortedMonitors: sortedMonitors),
            configuredWorkspaceNames: configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: monitorDescriptionByWorkspaceName()
        )
    }

    private func workspaceIdsByMonitor() -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        if let cached = _cachedWorkspaceIdsByMonitor {
            return cached
        }

        let context = monitorResolutionContext()
        var workspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]] = [:]
        for workspace in sortedWorkspaces() {
            guard let monitorId = effectiveMonitor(for: workspace.id, context: context)?.id else { continue }
            workspaceIdsByMonitor[monitorId, default: []].append(workspace.id)
        }

        _cachedWorkspaceIdsByMonitor = workspaceIdsByMonitor
        return workspaceIdsByMonitor
    }

    private func visibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        if let cached = _cachedVisibleWorkspaceMap {
            return cached
        }

        let visibleWorkspaceMap = activeVisibleWorkspaceMap(from: world.monitorSessions)
        _cachedVisibleWorkspaceMap = visibleWorkspaceMap
        _cachedMonitorIdByVisibleWorkspace = Dictionary(
            uniqueKeysWithValues: visibleWorkspaceMap.map { ($0.value, $0.key) }
        )
        _cachedVisibleWorkspaceIds = Set(visibleWorkspaceMap.values)
        return visibleWorkspaceMap
    }

    var workspaces: [WorkspaceDescriptor] {
        sortedWorkspaces()
    }

    func descriptor(for id: WorkspaceDescriptor.ID) -> WorkspaceDescriptor? {
        workspacesById[id]
    }

    func workspaceId(for name: String, createIfMissing: Bool) -> WorkspaceDescriptor.ID? {
        if let existing = workspaceIdByName[name] {
            return existing
        }
        guard createIfMissing else { return nil }
        guard configuredWorkspaceNameSet().contains(name) else { return nil }
        return createWorkspace(named: name)
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceIdByName[name]
    }

    func createDynamicWorkspace(
        named name: String,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        if let existingId = workspaceIdByName[name] {
            return descriptor(for: existingId)
        }
        guard let monitor = monitor(byId: monitorId),
              let workspaceId = createWorkspace(
                  named: name,
                  assignedMonitorPoint: monitor.workspaceAnchorPoint,
                  requiresConfiguration: false
              )
        else {
            return nil
        }
        return descriptor(for: workspaceId)
    }

    func workspaces(on monitorId: Monitor.ID) -> [WorkspaceDescriptor] {
        workspaceIdsByMonitor()[monitorId]?.compactMap(descriptor(for:)) ?? []
    }

    func primaryWorkspace() -> WorkspaceDescriptor? {
        let monitor = monitors.first(where: { $0.isMain }) ?? monitors.first
        guard let monitor else { return nil }
        return activeWorkspaceOrFirst(on: monitor.id)
    }

    func activeWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let mon = monitor(byId: monitorId) else { return nil }
        guard let workspaceId = visibleWorkspaceId(on: mon.id) else { return nil }
        return descriptor(for: workspaceId)
    }

    func previousWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let monitor = monitor(byId: monitorId) else { return nil }
        guard let prevId = previousVisibleWorkspaceId(on: monitor.id) else { return nil }
        guard prevId != visibleWorkspaceId(on: monitor.id) else { return nil }
        return descriptor(for: prevId)
    }

    func nextWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: 1, wrapAround: wrapAround)
    }

    func previousWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(on: monitorId, from: workspaceId, offset: -1, wrapAround: wrapAround)
    }

    func activeWorkspaceOrFirst(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitorId) {
            return active
        }
        guard let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitorId) else { return nil }
        return descriptor(for: defaultWorkspaceId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        if let cached = _cachedVisibleWorkspaceIds {
            return cached
        }
        return Set(visibleWorkspaceMap().values)
    }

    private func adjacentWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        offset: Int,
        wrapAround: Bool
    ) -> WorkspaceDescriptor? {
        let ordered = workspaces(on: monitorId)
        guard ordered.count > 1 else { return nil }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == workspaceId }) else { return nil }

        let targetIdx = currentIdx + offset
        if wrapAround {
            let wrappedIdx = (targetIdx % ordered.count + ordered.count) % ordered.count
            return ordered[wrappedIdx]
        }
        guard ordered.indices.contains(targetIdx) else { return nil }
        return ordered[targetIdx]
    }

    func focusWorkspace(named name: String) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let workspaceId = workspaceId(for: name, createIfMissing: false) else { return nil }
        return focusWorkspace(id: workspaceId)
    }

    func focusWorkspace(id workspaceId: WorkspaceDescriptor.ID) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId),
              let resolvedMonitor = monitorForWorkspace(workspaceId)
        else {
            return nil
        }
        return (workspace, resolvedMonitor)
    }

    func applyMonitorConfigurationChange(_ newMonitors: [Monitor]) {
        _ = recordTopologyChange(to: newMonitors)
    }

    func setGaps(to size: Double) {
        let clamped = max(0, min(64, size))
        guard clamped != gaps else { return }
        gaps = clamped
        noteInvalidation(workspaceId: nil, domains: [.workspace, .layout])
        onGapsChanged?()
    }

    func setOuterGaps(left: Double, right: Double, top: Double, bottom: Double) {
        let newGaps = LayoutGaps.OuterGaps(
            left: max(0, CGFloat(left)),
            right: max(0, CGFloat(right)),
            top: max(0, CGFloat(top)),
            bottom: max(0, CGFloat(bottom))
        )
        if outerGaps.left == newGaps.left,
           outerGaps.right == newGaps.right,
           outerGaps.top == newGaps.top,
           outerGaps.bottom == newGaps.bottom
        {
            return
        }
        outerGaps = newGaps
        noteInvalidation(workspaceId: nil, domains: [.workspace, .layout])
        onGapsChanged?()
    }

    func invalidateLayout(for workspaceIds: Set<WorkspaceDescriptor.ID>) {
        for workspaceId in workspaceIds {
            noteInvalidation(workspaceId: workspaceId, domains: .layout)
        }
    }

    private func monitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let monitorId = workspaceMonitorId(for: workspaceId, context: context) else { return nil }
        return monitor(byId: monitorId)
    }

    private func monitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        monitor(for: workspaceId, context: context)?.id
    }

    @discardableResult
    func addWindow(
        _ ax: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        to workspace: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowToken {
        let token = WindowToken(pid: pid, windowId: windowId)
        if let existingEntry = world.entry(forWindowId: windowId), existingEntry.token != token {
            Log.reconcile.fault(
                "WorkspaceManager rejected duplicate windowId=\(windowId) existing=\(existingEntry.pid):\(existingEntry.windowId) proposed=\(pid):\(windowId)"
            )
            return existingEntry.token
        }
        if let originalToken = nativeFullscreenOriginalToken(for: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
        recordReconcileEvent(
            .windowAdmitted(
                token: token,
                workspaceId: workspace,
                monitorId: monitorId(for: workspace),
                mode: mode,
                axRef: ax,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                managedReplacementMetadata: managedReplacementMetadata,
                source: .workspaceManager
            )
        )
        if let handle = world.handle(for: token) {
            onWindowPresenceObserved?(handle)
        }
        return token
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil
    ) -> WindowState? {
        guard let existingEntry = world.entry(for: oldToken),
              oldToken == newToken || world.entry(for: newToken) == nil
        else {
            return nil
        }
        if oldToken != newToken,
           let collision = world.entry(forWindowId: newToken.windowId),
           collision.token != oldToken
        {
            return nil
        }

        if let originalToken = nativeFullscreenOriginalToken(for: oldToken),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken]
        {
            record.currentToken = newToken
            record.workspaceId = existingEntry.workspaceId
            upsertNativeFullscreenRecord(record)
        }

        let previousFocus = world.focus
        recordReconcileEvent(
            .windowRekeyed(
                from: oldToken,
                to: newToken,
                workspaceId: existingEntry.workspaceId,
                monitorId: monitorId(for: existingEntry.workspaceId),
                reason: managedReplacementMetadata == nil ? .manualRekey : .managedReplacement,
                newAXRef: newAXRef,
                managedReplacementMetadata: managedReplacementMetadata,
                source: .workspaceManager
            )
        )

        let focusChanged = auxiliaryFocusStateChanged(from: previousFocus)
        let scratchpadChanged = world.scratchpadToken == oldToken
        if scratchpadChanged {
            _ = updateScratchpadToken(newToken, notify: false)
        }

        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }

        return world.entry(for: newToken)
    }

    func entries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        world.windows(in: workspace)
    }

    func tiledEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        world.windows(in: workspace, mode: .tiling)
    }

    func barVisibleEntries(
        in workspace: WorkspaceDescriptor.ID,
        showFloatingWindows: Bool = false
    ) -> [WindowState] {
        var entries = tiledEntries(in: workspace)
        if showFloatingWindows {
            entries.append(contentsOf: barVisibleFloatingEntries(in: workspace))
        }
        return entries
    }

    func hasTiledOccupancy(in workspace: WorkspaceDescriptor.ID) -> Bool {
        !tiledEntries(in: workspace).isEmpty
    }

    func floatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        world.windows(in: workspace, mode: .floating)
    }

    private func barVisibleFloatingEntries(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        floatingEntries(in: workspace).filter {
            !isScratchpadToken($0.token) && hiddenState(for: $0.token)?.isScratchpad != true
        }
    }

    func handle(for token: WindowToken) -> WindowHandle? {
        world.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowState? {
        world.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        world.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        world.entry(forPid: pid, windowId: windowId)
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        world.entries(forPid: pid)
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        world.hasEntries(forPid: pid)
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        world.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces: Bool) -> WindowState? {
        guard inVisibleWorkspaces else {
            return world.entry(forWindowId: windowId)
        }
        return world.entry(forWindowId: windowId, inVisibleWorkspaces: visibleWorkspaceIds())
    }

    func allEntries() -> [WindowState] {
        world.allEntries()
    }

    func allTiledEntries() -> [WindowState] {
        world.allEntries(mode: .tiling)
    }

    func allFloatingEntries() -> [WindowState] {
        world.allEntries(mode: .floating)
    }

    func windowMode(for token: WindowToken) -> TrackedWindowMode? {
        world.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        world.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        world.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        world.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        world.restoreIntent(for: token)
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        world.admissionHints(for: token)
    }

    func setInteractionPolicy(_ policy: WindowInteractionPolicy, for token: WindowToken) {
        world.setInteractionPolicy(policy, for: token)
    }

    func setNiriRestorePlacements(_ placements: [WindowToken: PersistedNiriPlacement]) {
        let changedPlacements = placements.filter { token, placement in
            guard let entry = world.entry(for: token), entry.mode == .tiling else { return false }
            let restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
            return restoreIntent.niriPlacement != placement
                || restoreIntent.detachedNiriContainerSizingState != nil
        }
        guard !changedPlacements.isEmpty else { return }
        recordReconcileEvent(
            .niriPlacementsResolved(
                placements: changedPlacements,
                source: .workspaceManager
            )
        )
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        world.managedReplacementMetadata(for: token)
    }

    @discardableResult
    func setManagedReplacementMetadata(
        _ metadata: ManagedReplacementMetadata?,
        for token: WindowToken
    ) -> Bool {
        guard let entry = world.entry(for: token) else {
            return false
        }
        guard world.managedReplacementMetadata(for: token) != metadata else {
            return false
        }
        recordReconcileEvent(
            .managedReplacementMetadataChanged(
                token: token,
                workspaceId: entry.workspaceId,
                monitorId: monitorId(for: entry.workspaceId),
                metadata: metadata,
                source: .workspaceManager
            )
        )
        return true
    }

    @discardableResult
    func updateManagedReplacementTitle(
        _ title: String,
        for token: WindowToken
    ) -> Bool {
        guard var metadata = world.managedReplacementMetadata(for: token) else {
            return false
        }
        guard metadata.title != title else {
            return false
        }
        metadata.title = title
        return setManagedReplacementMetadata(metadata, for: token)
    }

    @discardableResult
    func setWindowMode(_ mode: TrackedWindowMode, for token: WindowToken) -> Bool {
        guard let entry = entry(for: token) else { return false }
        let oldMode = entry.mode
        guard oldMode != mode else { return false }

        let workspaceId = entry.workspaceId
        let previousFocus = world.focus
        recordReconcileEvent(
            .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                mode: mode,
                source: .workspaceManager
            )
        )
        if auxiliaryFocusStateChanged(from: previousFocus) {
            notifySessionStateChanged()
        }
        return true
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        world.floatingState(for: token)
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        guard let entry = world.entry(for: token) else { return }
        guard world.floatingState(for: token) != state else { return }
        recordReconcileEvent(
            .floatingStateChanged(
                token: token,
                workspaceId: entry.workspaceId,
                state: state,
                source: .workspaceManager
            )
        )
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        world.manualLayoutOverride(for: token)
    }

    func setManualLayoutOverride(_ override: ManualWindowOverride?, for token: WindowToken) {
        guard let entry = world.entry(for: token) else { return }
        guard world.manualLayoutOverride(for: token) != override else { return }
        recordReconcileEvent(
            .manualLayoutOverrideChanged(
                token: token,
                workspaceId: entry.workspaceId,
                layoutOverride: override,
                source: .workspaceManager
            )
        )
    }

    @discardableResult
    func updateAdmissionHints(
        _ admissionHints: ManagedWindowAdmissionHints,
        for token: WindowToken
    ) -> Bool {
        guard let entry = world.entry(for: token), entry.admissionHints != admissionHints else { return false }
        recordReconcileEvent(
            .windowAdmissionHintsChanged(
                token: token,
                workspaceId: entry.workspaceId,
                admissionHints: admissionHints,
                source: .workspaceManager
            )
        )
        return world.admissionHints(for: token) == admissionHints
    }

    func updateFloatingGeometry(
        frame: CGRect,
        for token: WindowToken,
        referenceMonitor: Monitor? = nil,
        restoreToFloating: Bool = true
    ) {
        guard let entry = entry(for: token) else { return }

        let resolvedReferenceMonitor = referenceMonitor
            ?? frame.center.monitorApproximation(in: monitors)
            ?? monitor(for: entry.workspaceId)
        let referenceVisibleFrame = resolvedReferenceMonitor?.visibleFrame ?? frame
        let normalizedOrigin = normalizedFloatingOrigin(
            for: frame,
            in: referenceVisibleFrame
        )

        let state = FloatingState(
            lastFrame: frame,
            normalizedOrigin: normalizedOrigin,
            referenceMonitorId: resolvedReferenceMonitor?.id,
            restoreToFloating: restoreToFloating
        )
        guard world.floatingState(for: token) != state else { return }

        recordReconcileEvent(
            .floatingGeometryUpdated(
                token: token,
                workspaceId: entry.workspaceId,
                referenceMonitorId: resolvedReferenceMonitor?.id,
                frame: frame,
                normalizedOrigin: normalizedOrigin,
                restoreToFloating: restoreToFloating,
                source: .workspaceManager
            )
        )
    }

    func resolvedFloatingFrame(
        for token: WindowToken,
        preferredMonitor: Monitor? = nil
    ) -> CGRect? {
        guard let entry = entry(for: token),
              let floatingState = floatingState(for: token)
        else {
            return nil
        }

        let targetMonitor = preferredMonitor
            ?? monitor(for: entry.workspaceId)
            ?? floatingState.referenceMonitorId.flatMap { monitor(byId: $0) }
        let visibleFrame = targetMonitor?.visibleFrame ?? floatingState.lastFrame

        if let targetMonitor,
           floatingState.referenceMonitorId == targetMonitor.id || floatingState.normalizedOrigin == nil
        {
            return clampedFloatingFrame(floatingState.lastFrame, in: visibleFrame)
        }

        let origin = floatingOrigin(
            from: floatingState.normalizedOrigin ?? .zero,
            windowSize: floatingState.lastFrame.size,
            in: visibleFrame
        )
        return clampedFloatingFrame(
            CGRect(origin: origin, size: floatingState.lastFrame.size),
            in: visibleFrame
        )
    }

    @discardableResult
    func removeWindow(pid: pid_t, windowId: Int) -> WindowState? {
        guard let entry = world.entry(forPid: pid, windowId: windowId) else { return nil }
        let removedEntry = removeTrackedWindow(entry)
        schedulePersistedWindowRestoreCatalogSave()
        return removedEntry
    }

    @discardableResult
    func removeWindowsForApp(pid: pid_t) -> Set<WorkspaceDescriptor.ID> {
        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
        let entriesToRemove = entries(forPid: pid)

        for entry in entriesToRemove {
            affectedWorkspaces.insert(entry.workspaceId)
            _ = removeTrackedWindow(entry)
        }

        if !entriesToRemove.isEmpty {
            schedulePersistedWindowRestoreCatalogSave()
        }

        return affectedWorkspaces
    }

    @discardableResult
    private func removeTrackedWindow(_ entry: WindowState) -> WindowState {
        let previousFocus = world.focus
        recordReconcileEvent(
            .windowRemoved(
                token: entry.token,
                workspaceId: entry.workspaceId,
                source: .workspaceManager
            )
        )
        _ = removeNativeFullscreenRecord(containing: entry.token)
        let focusChanged = auxiliaryFocusStateChanged(from: previousFocus)
        let scratchpadChanged = clearScratchpadToken(matching: entry.token, notify: false)
        if focusChanged || scratchpadChanged {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        onWindowRemoved?(entry)
        return entry
    }

    func setWorkspace(for token: WindowToken, to workspace: WorkspaceDescriptor.ID) {
        let previousWorkspace = world.workspace(for: token)
        guard previousWorkspace != workspace else { return }
        if let originalToken = nativeFullscreenOriginalToken(for: token),
           var record = nativeFullscreenRecordsByOriginalToken[originalToken],
           record.currentToken == token,
           record.workspaceId != workspace
        {
            record.workspaceId = workspace
            upsertNativeFullscreenRecord(record)
        }
        recordReconcileEvent(
            .workspaceAssigned(
                token: token,
                from: previousWorkspace,
                to: workspace,
                monitorId: monitorId(for: workspace),
                source: .workspaceManager
            )
        )
        if world.scratchpadToken == token,
           previousWorkspace.map(pendingRuntimeMonitorOverrideClearWorkspaceIds.contains) == true
        {
            drainPendingRuntimeMonitorOverrideClears()
        }
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        world.workspace(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        world.isHiddenInCorner(token)
    }

    func setHiddenState(_ state: HiddenState?, for token: WindowToken) {
        guard world.hiddenState(for: token) != state else { return }
        guard let workspaceId = workspace(for: token) else { return }
        recordReconcileEvent(
            .hiddenStateChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                hiddenState: state,
                source: .workspaceManager
            )
        )
        drainPendingRuntimeMonitorOverrideClears()
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        world.hiddenState(for: token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        world.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        world.isNativeFullscreenSuspended(token)
    }

    func setLayoutReason(_ reason: LayoutReason, for token: WindowToken) {
        guard world.layoutReason(for: token) != reason else { return }
        guard let workspaceId = workspace(for: token) else { return }
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .suspended(reason),
                source: .workspaceManager
            )
        )
    }

    @discardableResult
    func restoreFromNativeState(
        for token: WindowToken,
        drainPendingRuntimeMonitorOverrides: Bool = true
    ) -> Bool {
        guard let entry = world.entry(for: token),
              entry.layoutReason != .standard,
              let workspaceId = workspace(for: token)
        else {
            return false
        }
        recordReconcileEvent(
            .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId(for: workspaceId),
                change: .restored,
                source: .workspaceManager
            )
        )
        if drainPendingRuntimeMonitorOverrides, nativeFullscreenRecord(for: token) == nil {
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }

    func showsNativeFullscreenPlaceholder(for token: WindowToken) -> Bool {
        guard layoutReason(for: token) == .nativeFullscreen else { return false }
        guard let record = nativeFullscreenRecord(for: token) else { return false }
        guard record.currentToken == token else { return false }
        return record.transition != .enterRequested
    }

    private func nativeFullscreenOriginalToken(for token: WindowToken) -> WindowToken? {
        if nativeFullscreenRecordsByOriginalToken[token] != nil {
            return token
        }
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    @discardableResult
    private func upsertNativeFullscreenRecord(_ record: NativeFullscreenRecord) -> NativeFullscreenRecord {
        if let previous = nativeFullscreenRecordsByOriginalToken[record.originalToken] {
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
            if previous != record {
                noteInvalidation(workspaceId: previous.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
                if previous.workspaceId != record.workspaceId {
                    noteInvalidation(
                        workspaceId: record.workspaceId,
                        domains: [.workspace, .layout, .focus, .fullscreen]
                    )
                }
            }
        } else {
            noteInvalidation(workspaceId: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
        return record
    }

    @discardableResult
    private func removeNativeFullscreenRecord(originalToken: WindowToken) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        noteInvalidation(workspaceId: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        return record
    }

    @discardableResult
    private func removeNativeFullscreenRecord(containing token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(for: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(originalToken: originalToken)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        world.cachedConstraints(for: token, maxAge: maxAge)
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        guard world.entry(for: token) != nil else { return }
        let normalized = constraints.normalized()
        world.setCachedConstraints(normalized, for: token)
    }

    func observedMinSize(for token: WindowToken) -> CGSize? {
        world.observedMinSize(for: token)
    }

    @discardableResult
    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        world.setObservedMinSize(size, for: token)
    }

    @discardableResult
    func moveWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitorId: Monitor.ID,
        force: Bool = false
    ) -> WorkspaceMonitorMoveOutcome {
        let unchangedOutcome: (WorkspaceMonitorMoveOutcome.Status) -> WorkspaceMonitorMoveOutcome = { status in
            WorkspaceMonitorMoveOutcome(
                status: status,
                affectedWorkspaces: [],
                floatingRelocations: []
            )
        }

        guard var workspace = descriptor(for: workspaceId),
              let targetMonitor = monitor(byId: targetMonitorId)
        else {
            return unchangedOutcome(.notFound)
        }

        let context = monitorResolutionContext()
        guard let sourceMonitorId = resolvedWorkspaceMonitorId(for: workspaceId, context: context) else {
            return unchangedOutcome(.notFound)
        }
        guard sourceMonitorId != targetMonitor.id else {
            return unchangedOutcome(.executed)
        }

        let isConfigured = context.configuredWorkspaceNames.contains(workspace.name)
        let homeMonitorId = homeMonitorId(for: workspaceId, context: context)
        if isConfigured, homeMonitorId != targetMonitor.id, !force {
            return unchangedOutcome(.conflict)
        }

        let visibleBefore = activeVisibleWorkspaceMap()
        let movedWorkspaceWasVisible = visibleBefore[sourceMonitorId] == workspaceId
        let managedFocusedEntry = world.focus.isNonManagedFocusActive
            ? nil
            : world.focus.focusedToken.flatMap { world.entry(for: $0) }
        let managedFocusedWorkspaceId = managedFocusedEntry?.workspaceId
        let transfersManagedFocus = managedFocusedWorkspaceId == workspaceId
        guard !isWorkspaceMonitorMoveUnsafe(
            workspaceId,
            sourceMonitorId: sourceMonitorId,
            visibleWorkspaces: visibleBefore
        ) else {
            return unchangedOutcome(.stateConflict)
        }

        let destinationWorkspaceId = visibleBefore[targetMonitor.id]
        let destinationIsProtected = targetMonitor.id == world.focus.interactionMonitorId
            || destinationWorkspaceId.map {
                $0 == managedFocusedWorkspaceId
                    || $0 == world.focus.pendingManagedFocus.workspaceId
            } ?? false
        let makesMovedWorkspaceVisible = transfersManagedFocus || !destinationIsProtected
        let sourceReplacementWorkspaceId = movedWorkspaceWasVisible
            ? sourceReplacementWorkspaceId(
                for: workspaceId,
                on: sourceMonitorId,
                context: context
            )
            : nil

        var nextMonitorSessions = world.monitorSessions
        for monitorId in Array(nextMonitorSessions.keys) where monitorId != targetMonitor.id {
            guard var session = nextMonitorSessions[monitorId],
                  session.previousVisibleWorkspaceId == workspaceId
            else {
                continue
            }
            session.previousVisibleWorkspaceId = nil
            if session.visibleWorkspaceId == nil {
                nextMonitorSessions.removeValue(forKey: monitorId)
            } else {
                nextMonitorSessions[monitorId] = session
            }
        }
        if movedWorkspaceWasVisible {
            var sourceSession = nextMonitorSessions[sourceMonitorId] ?? MonitorSession()
            sourceSession.visibleWorkspaceId = sourceReplacementWorkspaceId
            sourceSession.previousVisibleWorkspaceId = nil
            if sourceSession.visibleWorkspaceId == nil {
                nextMonitorSessions.removeValue(forKey: sourceMonitorId)
            } else {
                nextMonitorSessions[sourceMonitorId] = sourceSession
            }
        }
        if makesMovedWorkspaceVisible {
            var targetSession = nextMonitorSessions[targetMonitor.id] ?? MonitorSession()
            targetSession.visibleWorkspaceId = workspaceId
            targetSession.previousVisibleWorkspaceId = destinationWorkspaceId
            nextMonitorSessions[targetMonitor.id] = targetSession
        }

        let floatingStates = translatedFloatingStates(in: workspaceId, to: targetMonitor)
        let floatingRelocations = floatingStates.compactMap { token, state -> WorkspaceFloatingRelocation? in
            guard world.entry(for: token)?.hiddenState == nil else { return nil }
            return WorkspaceFloatingRelocation(
                workspaceId: workspaceId,
                token: token,
                frame: state.lastFrame
            )
        }.sorted {
            if $0.token.pid != $1.token.pid {
                return $0.token.pid < $1.token.pid
            }
            return $0.token.windowId < $1.token.windowId
        }

        workspace.assignedMonitorPoint = targetMonitor.workspaceAnchorPoint
        workspace.runtimeMonitorOverride = homeMonitorId == targetMonitor.id
            ? nil
            : OutputId(from: targetMonitor)

        animationDriver.removeMotions(for: [workspaceId])
        world.commit(
            .userCommand(
                workspaceId: workspaceId,
                label: "workspace_monitor_move",
                source: .command
            ),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: {
                self.workspacesById[workspaceId] = workspace
                self.pendingRuntimeMonitorOverrideClearWorkspaceIds.remove(workspaceId)
                self._cachedSortedWorkspaces = nil
                self.world.applyWorkspaceMonitorMove(
                    workspaceId: workspaceId,
                    targetMonitorId: targetMonitor.id,
                    monitorSessions: nextMonitorSessions,
                    floatingStates: floatingStates,
                    transferInteraction: transfersManagedFocus,
                    monitors: self.monitors
                )
                self.world.niriEngine?.moveWorkspace(
                    workspaceId,
                    to: targetMonitor.id,
                    monitor: targetMonitor
                )
                self.invalidateWorkspaceProjectionCaches()
            },
            resolvePlan: { plan, _, _ in plan }
        )

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [workspaceId]
        if let sourceReplacementWorkspaceId {
            affectedWorkspaces.insert(sourceReplacementWorkspaceId)
        }
        noteInvalidation(
            workspaceIds: affectedWorkspaces,
            domains: [.workspace, .layout, .focus]
        )
        schedulePersistedWindowRestoreCatalogSave()
        notifySessionStateChanged()

        return WorkspaceMonitorMoveOutcome(
            status: .executed,
            affectedWorkspaces: affectedWorkspaces,
            floatingRelocations: makesMovedWorkspaceVisible ? floatingRelocations : []
        )
    }

    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID
    ) -> Bool {
        guard let monitor1 = monitor(byId: monitor1Id),
              let monitor2 = monitor(byId: monitor2Id),
              monitor1Id != monitor2Id else { return false }

        guard isValidAssignment(workspaceId: workspace1Id, monitorId: monitor2.id),
              isValidAssignment(workspaceId: workspace2Id, monitorId: monitor1.id) else { return false }

        let previousWorkspace1 = visibleWorkspaceId(on: monitor1.id)
        let previousWorkspace2 = visibleWorkspaceId(on: monitor2.id)

        updateMonitorSession(monitor1.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace1
            session.visibleWorkspaceId = workspace2Id
        }
        updateWorkspace(workspace2Id) { workspace in
            workspace.assignedMonitorPoint = monitor1.workspaceAnchorPoint
        }

        updateMonitorSession(monitor2.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace2
            session.visibleWorkspaceId = workspace1Id
        }
        updateWorkspace(workspace1Id) { workspace in
            workspace.assignedMonitorPoint = monitor2.workspaceAnchorPoint
        }

        noteInvalidation(workspaceId: workspace1Id, domains: [.workspace, .layout, .focus])
        noteInvalidation(workspaceId: workspace2Id, domains: [.workspace, .layout, .focus])
        notifySessionStateChanged()
        return true
    }

    func setActiveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        updateInteractionMonitor: Bool = true
    ) -> Bool {
        guard let monitor = monitor(byId: monitorId) else { return false }
        return setActiveWorkspaceInternal(
            workspaceId,
            on: monitor.id,
            anchorPoint: monitor.workspaceAnchorPoint,
            updateInteractionMonitor: updateInteractionMonitor
        )
    }

    func assignWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitor.id) else { return }
        updateWorkspace(workspaceId) { $0.assignedMonitorPoint = monitor.workspaceAnchorPoint }
    }

    var niriEngine: NiriLayoutEngine? {
        get { world.niriEngine }
        set {
            let captured: Bool
            if let current = world.niriEngine, current !== newValue {
                captured = withEngineMutationScope(label: "niri_engine_replaced", source: .workspaceManager) {
                    world.installNiriEngine(newValue, monitors: monitors)
                }
            } else {
                captured = world.installNiriEngine(newValue, monitors: monitors)
            }
            if captured {
                schedulePersistedWindowRestoreCatalogSave()
            }
        }
    }

    @discardableResult
    func captureDetachedNiriPlacement(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let captured = world.captureDetachedNiriPlacement(
            for: token,
            in: workspaceId,
            monitors: monitors
        )
        if captured {
            schedulePersistedWindowRestoreCatalogSave()
        }
        return captured
    }

    var dwindleEngine: DwindleLayoutEngine? {
        get { world.dwindleEngine }
        set { world.installDwindleEngine(newValue) }
    }

    func layoutTopology(for workspaceId: WorkspaceDescriptor.ID) -> LayoutTopology {
        world.layoutTopology(for: workspaceId)
    }

    func niriViewportState(for workspaceId: WorkspaceDescriptor.ID) -> ViewportState {
        world.viewports[workspaceId] ?? ViewportState()
    }

    private func normalizeNiriRefreshRate(
        _ state: inout ViewportState,
        for workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let refreshRate = niriEngine?.monitorForWorkspace(workspaceId)?.refreshRate else { return }
        state.displayRefreshRate = refreshRate
    }

    func updateNiriViewportState(
        _ state: ViewportState,
        for workspaceId: WorkspaceDescriptor.ID
    ) {
        var state = state
        normalizeNiriRefreshRate(&state, for: workspaceId)
        recordReconcileEvent(
            .viewportChanged(
                workspaceId: workspaceId,
                state: state,
                source: .workspaceManager
            )
        )
    }

    private func niriViewportChangeRequiresInvalidation(
        previous: ViewportState?,
        next: ViewportState,
        pendingOffsetAnimation: Bool
    ) -> Bool {
        guard let previous else {
            return next.selectedNodeId != nil || !pendingOffsetAnimation
        }
        if previous.selectedNodeId != next.selectedNodeId {
            return true
        }
        if previous.activeColumnIndex != next.activeColumnIndex {
            return true
        }
        if previous.viewOffset != next.viewOffset {
            return true
        }
        if previous.viewOffsetToRestore != next.viewOffsetToRestore {
            return true
        }
        if previous.activatePrevColumnOnRemoval != next.activatePrevColumnOnRemoval {
            return true
        }
        return false
    }

    @discardableResult
    func withEngineMutationScope<T>(
        in workspaceId: WorkspaceDescriptor.ID? = nil,
        label: String = "engine_mutation",
        source: WMEventSource = .command,
        _ body: () -> T
    ) -> T {
        var result: T?
        world.commit(
            .userCommand(workspaceId: workspaceId, label: label, source: source),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: { result = body() },
            resolvePlan: { plan, _, _ in plan }
        )
        return result!
    }

    @discardableResult
    func withBatchedLayoutBuild(_ build: () -> [WorkspaceLayoutPlan]) -> [WorkspaceLayoutPlan] {
        var plans: [WorkspaceLayoutPlan] = []
        world.commit(
            .userCommand(workspaceId: nil, label: "layout_build", source: .layoutRefresh),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: {
                plans = build()
                for index in plans.indices {
                    guard let viewportState = plans[index].sessionPatch.viewportState else { continue }
                    self.applyViewportInBatch(viewportState, for: plans[index].workspaceId)
                    plans[index].sessionPatch.viewportState = nil
                }
                let committedSeq = self.world.seq
                for index in plans.indices {
                    plans[index].sessionPatch.plannedSeq = committedSeq
                }
            },
            resolvePlan: { plan, _, _ in plan }
        )
        return plans
    }

    @discardableResult
    func withBatchedWorkspaceMove(
        sourceWorkspaceId: WorkspaceDescriptor.ID,
        targetWorkspaceId: WorkspaceDescriptor.ID,
        _ engineMove: (inout ViewportState, inout ViewportState)
            -> (result: NiriLayoutEngine.WorkspaceMoveResult, tokens: [WindowToken])?
    ) -> NiriLayoutEngine.WorkspaceMoveResult? {
        var sourceState = niriViewportState(for: sourceWorkspaceId)
        var targetState = niriViewportState(for: targetWorkspaceId)
        var captured: NiriLayoutEngine.WorkspaceMoveResult?
        world.commit(
            .userCommand(workspaceId: nil, label: "workspace_move", source: .command),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: {
                guard let moved = engineMove(&sourceState, &targetState) else { return }
                captured = moved.result
                self.normalizeNiriRefreshRate(&sourceState, for: sourceWorkspaceId)
                self.normalizeNiriRefreshRate(&targetState, for: targetWorkspaceId)
                self.applyViewportInBatch(sourceState, for: sourceWorkspaceId)
                self.applyViewportInBatch(targetState, for: targetWorkspaceId)
                for token in moved.tokens {
                    self.setWorkspace(for: token, to: targetWorkspaceId)
                }
                _ = self.world.captureLiveNiriPlacements(
                    containing: moved.tokens,
                    in: targetWorkspaceId,
                    monitors: self.monitors
                )
            },
            resolvePlan: { plan, _, _ in plan }
        )
        return captured
    }

    func withBatchedNiriSourceMutation(
        workspaceId: WorkspaceDescriptor.ID,
        _ engineMutation: (inout ViewportState) -> Void
    ) {
        var sourceState = niriViewportState(for: workspaceId)
        world.commit(
            .userCommand(workspaceId: nil, label: "niri_source_mutation", source: .command),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: {
                engineMutation(&sourceState)
                self.normalizeNiriRefreshRate(&sourceState, for: workspaceId)
                self.applyViewportInBatch(sourceState, for: workspaceId)
            },
            resolvePlan: { plan, _, _ in plan }
        )
    }

    private func applyViewportInBatch(_ state: ViewportState, for workspaceId: WorkspaceDescriptor.ID) {
        let previous = world.viewports[workspaceId]
        var committed = state
        committed.clearOffsetTransition()
        if previous != committed {
            world.applyViewportPlan(.set(workspaceId: workspaceId, state: committed))
        }
        noteViewportInvalidationIfNeeded(
            for: workspaceId,
            previousViewport: previous,
            pendingOffsetAnimation: state.hasPendingOffsetAnimation
        )
        animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous,
            next: world.viewports[workspaceId] ?? committed,
            transition: state.offsetTransition
        )
    }

    func withNiriViewportState(
        for workspaceId: WorkspaceDescriptor.ID,
        _ mutate: (inout ViewportState) -> Void
    ) {
        var state = niriViewportState(for: workspaceId)
        withEngineMutationScope(in: workspaceId, label: "viewport_mutation") {
            mutate(&state)
        }
        updateNiriViewportState(state, for: workspaceId)
    }

    func garbageCollectUnusedWorkspaces(focusedWorkspaceId: WorkspaceDescriptor.ID?) {
        let configured = configuredWorkspaceNameSet()
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspacesById {
            if configured.contains(workspace.name) {
                continue
            }
            if focusedWorkspaceId == id {
                continue
            }
            if !world.windows(in: id).isEmpty {
                continue
            }
            toRemove.append(id)
        }

        removeWorkspaces(toRemove)
    }

    func sortedWorkspaces() -> [WorkspaceDescriptor] {
        if let cached = _cachedSortedWorkspaces {
            return cached
        }
        let sorted = workspacesById.values.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        _cachedSortedWorkspaces = sorted
        return sorted
    }

    func clearRuntimeMonitorOverrides(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        let context = monitorResolutionContext()
        var cleared: Set<WorkspaceDescriptor.ID> = []
        for workspaceId in workspaceIds {
            guard var workspace = workspacesById[workspaceId],
                  workspace.runtimeMonitorOverride != nil
            else {
                continue
            }
            workspace.runtimeMonitorOverride = nil
            if let homeMonitor = homeMonitor(for: workspaceId, context: context) {
                workspace.assignedMonitorPoint = homeMonitor.workspaceAnchorPoint
            }
            workspacesById[workspaceId] = workspace
            cleared.insert(workspaceId)
        }
        if !cleared.isEmpty {
            _cachedSortedWorkspaces = nil
        }
        return cleared
    }

    func commitRuntimeMonitorOverrideClears(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> [WorkspaceFloatingRelocation] {
        let context = monitorResolutionContext()
        let moves: [(
            workspaceId: WorkspaceDescriptor.ID,
            targetMonitor: Monitor,
            floatingStates: [WindowToken: FloatingState]
        )] = workspaceIds.sorted { $0.uuidString < $1.uuidString }.compactMap { workspaceId in
            guard let targetMonitor = effectiveMonitor(for: workspaceId, context: context) else {
                return nil
            }
            return (
                workspaceId,
                targetMonitor,
                translatedFloatingStates(in: workspaceId, to: targetMonitor)
            )
        }
        let visibleWorkspaces = Set(activeVisibleWorkspaceMap().values)
        let floatingRelocations = moves.flatMap { move -> [WorkspaceFloatingRelocation] in
            guard visibleWorkspaces.contains(move.workspaceId) else { return [] }
            return move.floatingStates.compactMap { token, state in
                guard world.entry(for: token)?.hiddenState == nil else { return nil }
                return WorkspaceFloatingRelocation(
                    workspaceId: move.workspaceId,
                    token: token,
                    frame: state.lastFrame
                )
            }
        }.sorted {
            if $0.token.pid != $1.token.pid {
                return $0.token.pid < $1.token.pid
            }
            return $0.token.windowId < $1.token.windowId
        }

        animationDriver.removeMotions(for: moves.lazy.map(\.workspaceId))
        world.commit(
            .userCommand(
                workspaceId: nil,
                label: "workspace_monitor_overrides_cleared",
                source: .workspaceManager
            ),
            monitors: monitors,
            snapshot: { self.reconcileSnapshot() },
            preMutate: {
                for move in moves {
                    let transfersManagedFocus = self.world.focus.focusedToken
                        .flatMap { self.world.entry(for: $0)?.workspaceId } == move.workspaceId
                        && !self.world.focus.isNonManagedFocusActive
                    self.world.applyWorkspaceMonitorMove(
                        workspaceId: move.workspaceId,
                        targetMonitorId: move.targetMonitor.id,
                        monitorSessions: self.world.monitorSessions,
                        floatingStates: move.floatingStates,
                        transferInteraction: transfersManagedFocus,
                        monitors: self.monitors
                    )
                    self.world.niriEngine?.moveWorkspace(
                        move.workspaceId,
                        to: move.targetMonitor.id,
                        monitor: move.targetMonitor
                    )
                }
            },
            resolvePlan: { plan, _, _ in plan }
        )
        noteInvalidation(
            workspaceIds: affectedWorkspaceIds,
            domains: [.workspace, .layout, .focus]
        )
        schedulePersistedWindowRestoreCatalogSave()
        notifySessionStateChanged()
        return floatingRelocations
    }

    func synchronizeConfiguredWorkspaces() {
        let configuredNames = configuredWorkspaceNames()
        let configuredSet = Set(configuredNames)

        for name in configuredNames {
            _ = workspaceId(for: name, createIfMissing: true)
        }

        let toRemove = workspacesById.compactMap { workspaceId, workspace -> WorkspaceDescriptor.ID? in
            guard !configuredSet.contains(workspace.name) else { return nil }
            guard world.windows(in: workspaceId).isEmpty else { return nil }
            return workspaceId
        }
        removeWorkspaces(toRemove)
    }

    private func removeWorkspaces(_ ids: [WorkspaceDescriptor.ID]) {
        guard !ids.isEmpty else { return }

        let toRemove = Set(ids)
        for id in toRemove {
            noteInvalidation(workspaceId: id, domains: [.workspace, .layout, .focus])
        }
        let rememberedIds = toRemove.filter {
            world.focus.lastTiledFocusedByWorkspace[$0] != nil
                || world.focus.lastFloatingFocusedByWorkspace[$0] != nil
                || world.focus.lastFocusedByWorkspace[$0] != nil
        }
        if !rememberedIds.isEmpty {
            recordReconcileEvent(.focusForgotten(workspaceIds: rememberedIds, source: .workspaceManager))
        }
        let viewportIds = toRemove.filter { world.viewports[$0] != nil }
        if !viewportIds.isEmpty {
            recordReconcileEvent(.viewportForgotten(workspaceIds: viewportIds, source: .workspaceManager))
        }
        for id in ids {
            workspacesById.removeValue(forKey: id)
        }
        pendingRuntimeMonitorOverrideClearWorkspaceIds.subtract(toRemove)
        withEngineMutationScope(label: "workspace_removed_engine_cleanup", source: .workspaceManager) {
            for id in toRemove {
                niriEngine?.removeWorkspaceState(id)
                dwindleEngine?.removeLayout(for: id)
            }
        }
        world.removeInvalidationMarks(for: ids)
        animationDriver.removeMotions(for: ids)

        _cachedSortedWorkspaces = nil
        workspaceIdByName = workspaceIdByName.filter { !toRemove.contains($0.value) }
        invalidateWorkspaceProjectionCaches()

        for monitorId in world.monitorSessions.keys {
            updateMonitorSession(monitorId) { session in
                if let visibleWorkspaceId = session.visibleWorkspaceId,
                   toRemove.contains(visibleWorkspaceId)
                {
                    session.visibleWorkspaceId = nil
                }
                if let previousVisibleWorkspaceId = session.previousVisibleWorkspaceId,
                   toRemove.contains(previousVisibleWorkspaceId)
                {
                    session.previousVisibleWorkspaceId = nil
                }
            }
        }
        reconcileConfiguredVisibleWorkspaces()
    }

    func restoreClearedRuntimeOverrideVisibility(
        visibleMonitorByWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]
    ) -> Bool {
        guard !visibleMonitorByWorkspace.isEmpty else { return false }
        let context = monitorResolutionContext()
        var sessions = world.monitorSessions
        let managedFocusedWorkspaceId = world.focus.isNonManagedFocusActive
            ? nil
            : world.focus.focusedToken.flatMap { world.entry(for: $0)?.workspaceId }

        for workspaceId in visibleMonitorByWorkspace.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let sourceMonitorId = visibleMonitorByWorkspace[workspaceId],
                  sessions[sourceMonitorId]?.visibleWorkspaceId == workspaceId,
                  let targetMonitorId = effectiveMonitor(for: workspaceId, context: context)?.id,
                  targetMonitorId != sourceMonitorId
            else {
                continue
            }

            let sourceReplacementWorkspaceId = sourceReplacementWorkspaceId(
                for: workspaceId,
                on: sourceMonitorId,
                context: context
            )
            var sourceSession = sessions[sourceMonitorId] ?? MonitorSession()
            sourceSession.visibleWorkspaceId = sourceReplacementWorkspaceId
            sourceSession.previousVisibleWorkspaceId = nil
            if sourceSession.visibleWorkspaceId == nil {
                sessions.removeValue(forKey: sourceMonitorId)
            } else {
                sessions[sourceMonitorId] = sourceSession
            }

            let destinationWorkspaceId = sessions[targetMonitorId]?.visibleWorkspaceId
            let destinationIsProtected = targetMonitorId == world.focus.interactionMonitorId
                || destinationWorkspaceId.map {
                    $0 == managedFocusedWorkspaceId
                        || $0 == world.focus.pendingManagedFocus.workspaceId
                } ?? false
            if managedFocusedWorkspaceId == workspaceId || !destinationIsProtected {
                var targetSession = sessions[targetMonitorId] ?? MonitorSession()
                targetSession.previousVisibleWorkspaceId = targetSession.visibleWorkspaceId
                targetSession.visibleWorkspaceId = workspaceId
                sessions[targetMonitorId] = targetSession
            }
        }

        guard sessions != world.monitorSessions else { return false }
        commitMonitorSessions(sessions)
        return true
    }

    private func pruneRestoredDisconnectedVisibleWorkspaces() {
        let context = monitorResolutionContext()
        disconnectedVisibleWorkspaceCache = disconnectedVisibleWorkspaceCache.filter { _, workspaceId in
            guard descriptor(for: workspaceId) != nil else { return false }
            guard let homeMonitorId = homeMonitorId(for: workspaceId, context: context) else { return true }
            return visibleWorkspaceId(on: homeMonitorId) != workspaceId
        }
    }

    func reconcileConfiguredVisibleWorkspaces(notify: Bool = true) {
        var changed = false
        let context = monitorResolutionContext()

        for monitor in context.sortedMonitors {
            let assigned = workspaces(on: monitor.id)
            guard !assigned.isEmpty else {
                if visibleWorkspaceId(on: monitor.id) != nil || previousVisibleWorkspaceId(on: monitor.id) != nil {
                    updateMonitorSession(monitor.id) { session in
                        session.visibleWorkspaceId = nil
                        session.previousVisibleWorkspaceId = nil
                    }
                    changed = true
                }
                continue
            }

            if let currentVisibleId = visibleWorkspaceId(on: monitor.id),
               assigned.contains(where: { $0.id == currentVisibleId })
            {
                continue
            }

            guard let defaultWorkspaceId = assigned.first?.id else { continue }
            if setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint,
                notify: false,
                context: context
            ) {
                changed = true
            }
        }

        if notify, changed {
            notifySessionStateChanged()
        }
    }

    func ensureVisibleWorkspaces() {
        let currentMonitorIds = Set(monitors.map(\.id))
        let expectedVisibleMonitorIds = expectedVisibleMonitorIds()
        let previousMonitorSessions = world.monitorSessions
        commitMonitorSessions(previousMonitorSessions.filter {
            currentMonitorIds.contains($0.key) && expectedVisibleMonitorIds.contains($0.key)
        })

        let currentVisibleMonitorIds = Set(activeVisibleWorkspaceMap(from: world.monitorSessions).keys)
        if currentVisibleMonitorIds != expectedVisibleMonitorIds {
            rearrangeWorkspacesOnMonitors(previousMonitorSessions: previousMonitorSessions)
        }
    }

    private func rearrangeWorkspacesOnMonitors(
        previousMonitorSessions: [Monitor.ID: MonitorSession]
    ) {
        let context = monitorResolutionContext()
        let oldForward = activeVisibleWorkspaceMap(from: previousMonitorSessions)
        var oldMonitorById: [Monitor.ID: Monitor] = [:]

        for monitor in monitors {
            oldMonitorById[monitor.id] = monitor
        }
        let visibleSnapshots = oldForward.compactMap { monitorId, workspaceId -> WorkspaceRestoreSnapshot? in
            guard let monitor = oldMonitorById[monitorId] else { return nil }
            return WorkspaceRestoreSnapshot(
                monitor: MonitorRestoreKey(monitor: monitor),
                workspaceId: workspaceId
            )
        }
        let restoredAssignments = resolveWorkspaceRestoreAssignments(
            snapshots: visibleSnapshots,
            monitors: monitors,
            workspaceExists: { descriptor(for: $0) != nil }
        )

        commitMonitorSessions(world.monitorSessions.mapValues { session in
            var pruned = session
            pruned.visibleWorkspaceId = nil
            return pruned
        })

        for newMonitor in context.sortedMonitors {
            if let existingWorkspaceId = restoredAssignments[newMonitor.id],
               workspaceMonitorId(for: existingWorkspaceId, context: context) == newMonitor.id,
               setActiveWorkspaceInternal(
                   existingWorkspaceId,
                   on: newMonitor.id,
                   anchorPoint: newMonitor.workspaceAnchorPoint,
                   notify: false,
                   context: context
               )
            {
                continue
            }
            if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: newMonitor.id) {
                _ = setActiveWorkspaceInternal(
                    defaultWorkspaceId,
                    on: newMonitor.id,
                    anchorPoint: newMonitor.workspaceAnchorPoint,
                    notify: false,
                    context: context
                )
            }
        }

        notifySessionStateChanged()
    }

    private func defaultVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        let assigned = workspaces(on: monitorId)
        guard !assigned.isEmpty else { return nil }
        return assigned.first?.id
    }

    private func expectedVisibleMonitorIds() -> Set<Monitor.ID> {
        Set(monitors.compactMap { monitor in
            defaultVisibleWorkspaceId(on: monitor.id) == nil ? nil : monitor.id
        })
    }

    private func replaceVisibleWorkspaceIfNeeded(on monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        if let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitor.id) {
            _ = setActiveWorkspaceInternal(
                defaultWorkspaceId,
                on: monitor.id,
                anchorPoint: monitor.workspaceAnchorPoint
            )
        } else {
            updateMonitorSession(monitor.id) { session in
                session.visibleWorkspaceId = nil
                session.previousVisibleWorkspaceId = nil
            }
            notifySessionStateChanged()
        }
    }

    private func sourceReplacementWorkspaceId(
        for movedWorkspaceId: WorkspaceDescriptor.ID,
        on sourceMonitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> WorkspaceDescriptor.ID? {
        let isEligible: (WorkspaceDescriptor.ID) -> Bool = { workspaceId in
            guard workspaceId != movedWorkspaceId,
                  self.effectiveMonitor(for: workspaceId, context: context)?.id == sourceMonitorId
            else {
                return false
            }
            guard let visibleMonitorId = self.monitorIdShowingWorkspace(workspaceId) else {
                return true
            }
            return visibleMonitorId == sourceMonitorId
        }

        if let previousWorkspaceId = previousVisibleWorkspaceId(on: sourceMonitorId),
           isEligible(previousWorkspaceId)
        {
            return previousWorkspaceId
        }
        return sortedWorkspaces().first { isEligible($0.id) }?.id
    }

    func resolvedWorkspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    private func resolvedWorkspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        return monitorIdShowingWorkspace(workspaceId)
            ?? effectiveMonitor(for: workspaceId, context: context)?.id
    }

    private func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId)
    }

    private func workspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId, context: context)
    }

    private func configuredMonitorDescription(
        for workspaceName: String,
        context: MonitorResolutionContext
    ) -> MonitorDescription? {
        context.monitorDescriptionByWorkspaceName[workspaceName]
    }

    private func homeMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        homeMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    private func homeMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        guard let description = configuredMonitorDescription(for: workspace.name, context: context) else { return nil }
        return description.resolveMonitor(sortedMonitors: context.sortedMonitors)
    }

    private func homeMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        homeMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    private func homeMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        homeMonitor(for: workspaceId, context: context)?.id
    }

    private func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        effectiveMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    private func effectiveMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        if let runtimeOverride = descriptor(for: workspaceId)?.runtimeMonitorOverride,
           let monitor = runtimeOverride.resolveMonitor(in: context.sortedMonitors)
        {
            return monitor
        }

        if let home = homeMonitor(for: workspaceId, context: context) {
            return home
        }

        guard !context.sortedMonitors.isEmpty else { return nil }
        guard let workspace = descriptor(for: workspaceId) else { return nil }

        let anchorPoint = workspace.assignedMonitorPoint
            ?? monitorIdShowingWorkspace(workspaceId).flatMap { monitor(byId: $0)?.workspaceAnchorPoint }
        guard let anchorPoint else { return context.sortedMonitors.first }

        return context.sortedMonitors.min { lhs, rhs in
            let lhsDistance = lhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            let rhsDistance = rhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return monitorSortKey(lhs) < monitorSortKey(rhs)
        }
    }

    private func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: monitorResolutionContext())
    }

    private func isValidAssignment(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> Bool {
        guard descriptor(for: workspaceId) != nil else { return false }
        return effectiveMonitor(for: workspaceId, context: context)?.id == monitorId
    }

    private func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true,
        context: MonitorResolutionContext? = nil
    ) -> Bool {
        let resolutionContext = context ?? monitorResolutionContext()
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: resolutionContext) else {
            return false
        }
        let effectiveAnchorPoint = anchorPoint ?? monitor(byId: monitorId)?.workspaceAnchorPoint
        var workspaceVisibilityChanged = false

        if let prevMonitorId = monitorIdShowingWorkspace(workspaceId),
           prevMonitorId != monitorId
        {
            updateMonitorSession(prevMonitorId) { session in
                session.previousVisibleWorkspaceId = workspaceId
                session.visibleWorkspaceId = nil
            }
            workspaceVisibilityChanged = true
        }

        let previousWorkspaceOnMonitor = visibleWorkspaceId(on: monitorId)
        if previousWorkspaceOnMonitor != workspaceId {
            updateMonitorSession(monitorId) { session in
                if let previousWorkspaceOnMonitor {
                    session.previousVisibleWorkspaceId = previousWorkspaceOnMonitor
                }
                session.visibleWorkspaceId = workspaceId
            }
            workspaceVisibilityChanged = true
        }

        updateWorkspace(workspaceId) { workspace in
            workspace.assignedMonitorPoint = effectiveAnchorPoint
        }

        if updateInteractionMonitor {
            let interactionChanged = self.updateInteractionMonitor(monitorId, preservePrevious: true, notify: false)
            if workspaceVisibilityChanged || interactionChanged {
                noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
                if let previousWorkspaceOnMonitor {
                    noteInvalidation(workspaceId: previousWorkspaceOnMonitor, domains: [.workspace, .layout, .focus])
                }
            }
            if notify, workspaceVisibilityChanged || interactionChanged {
                notifySessionStateChanged()
            }
        } else if workspaceVisibilityChanged {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
            if let previousWorkspaceOnMonitor {
                noteInvalidation(workspaceId: previousWorkspaceOnMonitor, domains: [.workspace, .layout, .focus])
            }
            if notify {
                notifySessionStateChanged()
            }
        }

        if workspaceVisibilityChanged {
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }

    private func updateWorkspace(_ workspaceId: WorkspaceDescriptor.ID, update: (inout WorkspaceDescriptor) -> Void) {
        guard var workspace = workspacesById[workspaceId] else { return }
        let previousWorkspace = workspace
        let oldName = workspace.name
        update(&workspace)
        workspacesById[workspaceId] = workspace
        if workspace.name != oldName {
            workspaceIdByName.removeValue(forKey: oldName)
            workspaceIdByName[workspace.name] = workspaceId
            _cachedSortedWorkspaces = nil
        }
        invalidateWorkspaceProjectionCaches()
        if previousWorkspace != workspace {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout])
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    private func createWorkspace(
        named name: String,
        assignedMonitorPoint: CGPoint? = nil,
        requiresConfiguration: Bool = true
    ) -> WorkspaceDescriptor.ID? {
        guard let rawID = WorkspaceIDPolicy.normalizeRawID(name) else { return nil }
        guard !requiresConfiguration || configuredWorkspaceNameSet().contains(rawID) else { return nil }
        let workspace = WorkspaceDescriptor(name: rawID, assignedMonitorPoint: assignedMonitorPoint)
        workspacesById[workspace.id] = workspace
        workspaceIdByName[workspace.name] = workspace.id
        _cachedSortedWorkspaces = nil
        invalidateWorkspaceProjectionCaches()
        noteInvalidation(workspaceId: workspace.id, domains: [.workspace, .layout, .focus])
        return workspace.id
    }

    private func visibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        visibleWorkspaceMap()[monitorId]
    }

    private func previousVisibleWorkspaceId(on monitorId: Monitor.ID) -> WorkspaceDescriptor.ID? {
        world.monitorSessions[monitorId]?.previousVisibleWorkspaceId
    }

    private func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        if let cached = _cachedMonitorIdByVisibleWorkspace {
            return cached[workspaceId]
        }
        _ = visibleWorkspaceMap()
        return _cachedMonitorIdByVisibleWorkspace?[workspaceId]
    }

    func activeVisibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        visibleWorkspaceMap()
    }

    private func activeVisibleWorkspaceMap(
        from monitorSessions: [Monitor.ID: MonitorSession]
    ) -> [Monitor.ID: WorkspaceDescriptor.ID] {
        Dictionary(uniqueKeysWithValues: monitorSessions.compactMap { monitorId, session in
            guard let visibleWorkspaceId = session.visibleWorkspaceId else { return nil }
            return (monitorId, visibleWorkspaceId)
        })
    }

    private func updateMonitorSession(
        _ monitorId: Monitor.ID,
        _ mutate: (inout MonitorSession) -> Void
    ) {
        var sessions = world.monitorSessions
        var monitorSession = sessions[monitorId] ?? MonitorSession()
        mutate(&monitorSession)
        if monitorSession.visibleWorkspaceId == nil, monitorSession.previousVisibleWorkspaceId == nil {
            sessions.removeValue(forKey: monitorId)
        } else {
            sessions[monitorId] = monitorSession
        }
        commitMonitorSessions(sessions)
    }

    private func commitMonitorSessions(_ sessions: [Monitor.ID: MonitorSession]) {
        guard sessions != world.monitorSessions else { return }
        recordReconcileEvent(.visibleWorkspacesChanged(sessions: sessions, source: .workspaceManager))
        invalidateWorkspaceProjectionCaches()
    }

    var spaceTopology: SpaceTopology {
        world.spaceTopology
    }

    func commitSpaceTopology(_ topology: SpaceTopology) {
        guard topology != world.spaceTopology else { return }
        recordReconcileEvent(.spaceTopologyChanged(topology: topology, source: .service))
    }

    @discardableResult
    private func updateInteractionMonitor(
        _ monitorId: Monitor.ID?,
        preservePrevious: Bool,
        notify: Bool
    ) -> Bool {
        guard world.focus.interactionMonitorId != monitorId else { return false }
        let previousWorkspaceId = world.focus.interactionMonitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        let nextWorkspaceId = monitorId
            .flatMap { activeWorkspace(on: $0)?.id }
        var previousMonitorId = world.focus.previousInteractionMonitorId
        if preservePrevious, let currentMonitorId = world.focus.interactionMonitorId {
            previousMonitorId = currentMonitorId
        }
        recordReconcileEvent(
            .interactionMonitorChanged(
                monitorId: monitorId,
                previousMonitorId: previousMonitorId,
                source: .workspaceManager
            )
        )
        noteFocusInvalidation(
            previousWorkspaceId: previousWorkspaceId,
            currentWorkspaceId: nextWorkspaceId
        )
        if notify {
            notifySessionStateChanged()
        }
        drainPendingRuntimeMonitorOverrideClears()
        return true
    }

    private func reconcileInteractionMonitorState(notify: Bool = true) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceMonitorId = world.focus.focusedToken
            .flatMap { entry(for: $0)?.workspaceId }
            .flatMap { monitorId(for: $0) }
        let newInteractionMonitorId = world.focus.interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? monitors.first?.id
        let newPreviousInteractionMonitorId = world.focus.previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        let changed = world.focus.interactionMonitorId != newInteractionMonitorId
            || world.focus.previousInteractionMonitorId != newPreviousInteractionMonitorId
        guard changed else { return }

        recordReconcileEvent(
            .interactionMonitorChanged(
                monitorId: newInteractionMonitorId,
                previousMonitorId: newPreviousInteractionMonitorId,
                source: .workspaceManager
            )
        )
        if notify {
            notifySessionStateChanged()
        }
    }

    private func notifySessionStateChanged() {
        onSessionStateChanged?()
    }
}

extension WorkspaceManager {
    private func noteInvalidation(for event: WMEvent) {
        switch event {
        case let .windowAdmitted(_, workspaceId, _, _, _, _, _, _, _),
             let .windowModeChanged(_, workspaceId, _, _, _),
             let .hiddenStateChanged(_, workspaceId, _, _, _),
             let .managedReplacementMetadataChanged(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])

        case let .floatingGeometryUpdated(_, workspaceId, _, _, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout])

        case let .floatingStateChanged(_, workspaceId, _, _),
             let .manualLayoutOverrideChanged(_, workspaceId, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .layout)

        case .niriPlacementsResolved:
            break

        case .windowAdmissionHintsChanged:
            break

        case let .windowRekeyed(_, _, workspaceId, _, _, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])

        case let .workspaceAssigned(_, fromWorkspaceId, toWorkspaceId, _, _):
            noteInvalidation(workspaceId: toWorkspaceId, domains: [.workspace, .layout, .focus])
            if let fromWorkspaceId {
                noteInvalidation(workspaceId: fromWorkspaceId, domains: [.workspace, .layout, .focus])
            }

        case let .windowRemoved(token, workspaceId, _):
            noteInvalidation(
                workspaceId: workspaceId ?? world.entry(for: token)?.workspaceId,
                domains: [.workspace, .layout, .focus, .fullscreen]
            )

        case let .nativeFullscreenTransition(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])

        case let .managedFocusRequested(_, workspaceId, _, _, _),
             let .managedFocusConfirmed(_, workspaceId, _, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .focus)

        case let .managedFocusCancelled(token, workspaceId, _, _):
            noteInvalidation(
                workspaceId: workspaceId ?? token.flatMap { world.entry(for: $0)?.workspaceId },
                domains: .focus
            )

        case let .focusRemembered(_, workspaceId, _, _):
            noteInvalidation(workspaceId: workspaceId, domains: .focus)

        case .focusForgotten,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .nativeFullscreenPlaceholderSelected,
             .nonManagedFocusTargetChanged,
             .scratchpadChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .workspaceFocusCleared:
            break

        case .focusLeaseChanged,
             .nonManagedFocusChanged:
            noteInvalidation(workspaceId: nil, domains: .focus)

        case .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake:
            noteInvalidation(workspaceId: nil, domains: [.workspace, .layout, .focus, .fullscreen])
        }
    }

    private func noteInvalidation(
        workspaceId: WorkspaceDescriptor.ID?,
        domains: InvalidationDomain
    ) {
        world.noteInvalidation(workspaceId: workspaceId, domains: domains)
        onRuntimeInvalidation?(workspaceId, domains)
    }

    private func noteInvalidation(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain
    ) {
        world.noteInvalidation(workspaceIds: workspaceIds, domains: domains)
        for workspaceId in workspaceIds {
            onRuntimeInvalidation?(workspaceId, domains)
        }
    }
}

private extension CGPoint {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }
}
