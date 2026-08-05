// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct InvalidationDomain: OptionSet {
    let rawValue: UInt8

    static let workspace = InvalidationDomain(rawValue: 1 << 0)
    static let layout = InvalidationDomain(rawValue: 1 << 1)
    static let focus = InvalidationDomain(rawValue: 1 << 2)
    static let fullscreen = InvalidationDomain(rawValue: 1 << 3)

    static let layoutCommit: InvalidationDomain = [.workspace, .layout, .fullscreen]
    static let focusCommit: InvalidationDomain = .focus
}

struct InvalidationMarks: Equatable {
    var workspace: UInt64 = 0
    var layout: UInt64 = 0
    var focus: UInt64 = 0
    var fullscreen: UInt64 = 0

    mutating func record(_ seq: UInt64, domains: InvalidationDomain) {
        if domains.contains(.workspace) { workspace = seq }
        if domains.contains(.layout) { layout = seq }
        if domains.contains(.focus) { focus = seq }
        if domains.contains(.fullscreen) { fullscreen = seq }
    }

    func isCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        if domains.contains(.workspace), workspace > plannedSeq { return false }
        if domains.contains(.layout), layout > plannedSeq { return false }
        if domains.contains(.focus), focus > plannedSeq { return false }
        if domains.contains(.fullscreen), fullscreen > plannedSeq { return false }
        return true
    }

    func merged(with other: InvalidationMarks) -> InvalidationMarks {
        InvalidationMarks(
            workspace: max(workspace, other.workspace),
            layout: max(layout, other.layout),
            focus: max(focus, other.focus),
            fullscreen: max(fullscreen, other.fullscreen)
        )
    }
}

@MainActor
final class WorldStore {
    private let model = WindowModel()
    private let trace = ReconcileTraceRecorder()
    private let nowProvider: () -> Date
    private(set) var seq: UInt64 = 0
    private(set) var invariantViolationCounts: [String: Int] = [:]
    private(set) var focus = FocusSessionSnapshot()
    private(set) var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    private(set) var scratchpadToken: WindowToken?
    private(set) var monitorSessions: [Monitor.ID: MonitorSession] = [:]
    private(set) var spaceTopology = SpaceTopology()
    private(set) var niriEngine: NiriLayoutEngine?
    private(set) var dwindleEngine: DwindleLayoutEngine?
    private var activeLayoutResolver: ((WorkspaceDescriptor.ID) -> ActiveLayoutKind)?
    private(set) var epochMarks = InvalidationMarks()
    private var broadcastMarks = InvalidationMarks()
    private var workspaceMarks: [WorkspaceDescriptor.ID: InvalidationMarks] = [:]
    private var commitDepth = 0
    private var currentCommitEvent: WMEvent?

    var isEngineMutationSanctioned: Bool {
        commitDepth > 0
    }

    private func pushEngineSanction() {
        let sanctioned = isEngineMutationSanctioned
        niriEngine?.isMutationSanctioned = sanctioned
        dwindleEngine?.isMutationSanctioned = sanctioned
    }

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    @discardableResult
    func commit(
        _ event: WMEvent,
        monitors: [Monitor],
        snapshot: () -> ReconcileSnapshot,
        preMutate: () -> Void = {},
        resolvePlan: (ActionPlan, WindowToken?, ReconcileSnapshot) -> ActionPlan
    ) -> ReconcileTxn {
        commitDepth += 1
        pushEngineSanction()
        let previousCommitEvent = currentCommitEvent
        currentCommitEvent = event
        defer {
            commitDepth -= 1
            pushEngineSanction()
            currentCommitEvent = previousCommitEvent
        }
        seq &+= 1

        preMutate()
        applyWindowMutation(event, phase: .beforePlan, monitors: monitors)
        let existingEntry = event.token.flatMap { model.entry(for: $0) }
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let reducerSnapshot = snapshot()
        let plan = StateReducer.reduce(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: reducerSnapshot,
            monitors: monitors
        )
        let resolvedPlan = resolvePlan(plan, normalizedEvent.token, reducerSnapshot)
        applyWindowMutation(event, phase: .afterPlan, monitors: monitors)

        let committedSnapshot = snapshot()
        let invariantViolations = commitDepth == 1
            ? InvariantChecks.validate(snapshot: committedSnapshot)
            : []
        var tracedPlan = resolvedPlan
        if !invariantViolations.isEmpty {
            tracedPlan.notes.append(contentsOf: invariantViolations.map(\.traceNote))
            for violation in invariantViolations {
                invariantViolationCounts[violation.code, default: 0] += 1
            }
            assertionFailure(
                "Reconcile invariants violated after \(event.summary): "
                    + invariantViolations.map(\.code).joined(separator: ",")
            )
        }
        let txn = ReconcileTxn(
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent,
            plan: tracedPlan,
            snapshot: committedSnapshot,
            invariantViolations: invariantViolations
        )
        trace.append(transaction: txn)
        return txn
    }

    func traceRecords() -> [ReconcileTraceRecord] {
        trace.snapshot()
    }

    func invariantViolationCountsDump() -> String {
        guard !invariantViolationCounts.isEmpty else { return "clean" }
        return invariantViolationCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    func noteInvalidation(workspaceId: WorkspaceDescriptor.ID?, domains: InvalidationDomain) {
        seq &+= 1
        epochMarks.record(seq, domains: domains)
        if let workspaceId {
            workspaceMarks[workspaceId, default: InvalidationMarks()].record(seq, domains: domains)
        } else {
            broadcastMarks.record(seq, domains: domains)
        }
    }

    func noteInvalidation(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        domains: InvalidationDomain
    ) {
        guard !workspaceIds.isEmpty else { return }
        seq &+= 1
        epochMarks.record(seq, domains: domains)
        for workspaceId in workspaceIds {
            workspaceMarks[workspaceId, default: InvalidationMarks()].record(seq, domains: domains)
        }
    }

    func invalidationMarks(for workspaceId: WorkspaceDescriptor.ID) -> InvalidationMarks {
        broadcastMarks.merged(with: workspaceMarks[workspaceId] ?? InvalidationMarks())
    }

    func isSeqCurrent(
        _ plannedSeq: UInt64,
        for workspaceId: WorkspaceDescriptor.ID,
        domains: InvalidationDomain
    ) -> Bool {
        invalidationMarks(for: workspaceId).isCurrent(plannedSeq, domains: domains)
    }

    func isSeqEpochCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        epochMarks.isCurrent(plannedSeq, domains: domains)
    }

    func removeInvalidationMarks<S: Sequence>(for workspaceIds: S) where S.Element == WorkspaceDescriptor.ID {
        for workspaceId in workspaceIds {
            workspaceMarks.removeValue(forKey: workspaceId)
        }
    }

    private enum MutationPhase {
        case beforePlan
        case afterPlan
    }

    private func applyWindowMutation(_ event: WMEvent, phase: MutationPhase, monitors: [Monitor]) {
        switch event {
        case let .windowAdmitted(token, workspaceId, _, mode, axRef, ruleEffects, admissionHints, metadata, _):
            guard phase == .beforePlan else { return }
            let resolvedAdmissionHints = canUpdateAdmissionHints(for: token)
                ? admissionHints
                : model.admissionHints(for: token) ?? admissionHints
            model.upsert(
                window: axRef,
                pid: token.pid,
                windowId: token.windowId,
                workspace: workspaceId,
                mode: mode,
                ruleEffects: ruleEffects,
                admissionHints: resolvedAdmissionHints,
                managedReplacementMetadata: metadata
            )
            reconcileNiriMembership(
                for: token,
                keeping: mode == .tiling ? workspaceId : nil,
                monitors: monitors
            )

        case let .windowRekeyed(from, to, workspaceId, _, _, newAXRef, metadata, _):
            guard phase == .beforePlan else { return }
            let previousSpaceId = from.windowId == to.windowId
                ? nil
                : spaceTopology.windowSpace.removeValue(forKey: from.windowId)
            if spaceTopology.windowSpace[to.windowId] == nil,
               let previousSpaceId,
               spaceTopology.isKnownSpace(previousSpaceId)
            {
                spaceTopology.windowSpace[to.windowId] = previousSpaceId
            }
            model.rekeyWindow(
                from: from,
                to: to,
                newAXRef: newAXRef,
                managedReplacementMetadata: metadata
            )
            _ = niriEngine?.rekeyWindow(from: from, to: to, in: workspaceId)
            _ = dwindleEngine?.rekeyWindow(from: from, to: to, in: workspaceId)

        case let .windowRemoved(token, _, _):
            guard phase == .afterPlan else { return }
            model.removeWindow(key: token)
            spaceTopology.windowSpace.removeValue(forKey: token.windowId)
            reconcileNiriMembership(for: token, keeping: nil, monitors: monitors)

        case let .workspaceAssigned(token, _, to, _, _):
            guard phase == .beforePlan else { return }
            updateWorkspace(for: token, workspace: to, monitors: monitors)

        case let .windowModeChanged(token, _, _, mode, _):
            guard phase == .beforePlan else { return }
            setMode(mode, for: token, monitors: monitors)

        case let .floatingGeometryUpdated(token, _, referenceMonitorId, frame, normalizedOrigin, restoreToFloating, _):
            guard phase == .beforePlan else { return }
            model.setFloatingState(
                .init(
                    lastFrame: frame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitorId,
                    restoreToFloating: restoreToFloating
                ),
                for: token
            )

        case let .floatingStateChanged(token, _, state, _):
            guard phase == .beforePlan else { return }
            model.setFloatingState(state, for: token)

        case let .manualLayoutOverrideChanged(token, _, layoutOverride, _):
            guard phase == .beforePlan else { return }
            model.setManualLayoutOverride(layoutOverride, for: token)

        case let .windowAdmissionHintsChanged(token, _, admissionHints, _):
            guard phase == .beforePlan, canUpdateAdmissionHints(for: token) else { return }
            model.setAdmissionHints(admissionHints, for: token)

        case let .niriPlacementsResolved(placements, _):
            guard phase == .beforePlan else { return }
            for (token, placement) in placements {
                guard let entry = model.entry(for: token), entry.mode == .tiling else { continue }
                var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
                restoreIntent.niriPlacement = placement
                restoreIntent.detachedNiriContainerSizingState = nil
                guard entry.restoreIntent != restoreIntent else { continue }
                model.setRestoreIntent(restoreIntent, for: token)
            }

        case let .hiddenStateChanged(token, _, _, hiddenState, _):
            guard phase == .beforePlan else { return }
            model.setHiddenState(hiddenState, for: token)

        case let .nativeFullscreenTransition(token, _, _, change, _):
            guard phase == .beforePlan else { return }
            switch change {
            case let .suspended(reason):
                model.setLayoutReason(reason, for: token)
            case .restored:
                model.restoreFromNativeState(for: token)
            }

        case let .managedReplacementMetadataChanged(token, _, _, metadata, _):
            guard phase == .beforePlan else { return }
            model.setManagedReplacementMetadata(metadata, for: token)

        case let .scratchpadChanged(token, _):
            guard phase == .beforePlan else { return }
            scratchpadToken = token

        case let .visibleWorkspacesChanged(sessions, _):
            guard phase == .beforePlan else { return }
            monitorSessions = sessions

        case let .spaceTopologyChanged(topology, _):
            guard phase == .beforePlan else { return }
            spaceTopology = topology

        case .activeSpaceChanged,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .nativeFullscreenPlaceholderSelected,
             .nonManagedFocusChanged,
             .nonManagedFocusTargetChanged,
             .selectionChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .workspaceFocusCleared:
            break
        }
    }

    private func assertInCommit(_ operation: StaticString) {
        assert(commitDepth > 0, "\(operation) must run inside WorldStore.commit")
    }

    private func canUpdateAdmissionHints(for token: WindowToken) -> Bool {
        guard let entry = model.entry(for: token) else { return true }
        guard entry.restoreIntent?.detachedNiriContainerSizingState == nil,
              entry.restoreIntent?.niriPlacement == nil
        else {
            return false
        }
        return niriEngine?.workspaceIds(containing: token).isEmpty ?? true
    }
}

extension WorldStore {
    func handle(for token: WindowToken) -> WindowHandle? {
        model.handle(for: token)
    }

    func entry(for token: WindowToken) -> WindowState? {
        model.entry(for: token)
    }

    func entry(for handle: WindowHandle) -> WindowState? {
        model.entry(for: handle)
    }

    func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
        model.entry(forPid: pid, windowId: windowId)
    }

    func entry(forWindowId windowId: Int) -> WindowState? {
        model.entry(forWindowId: windowId)
    }

    func entry(forWindowId windowId: Int, inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>) -> WindowState? {
        model.entry(forWindowId: windowId, inVisibleWorkspaces: visibleIds)
    }

    func entries(forPid pid: pid_t) -> [WindowState] {
        model.entries(forPid: pid)
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        model.hasEntries(forPid: pid)
    }

    func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
        model.windows(in: workspace)
    }

    func windows(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowState] {
        model.windows(in: workspace, mode: mode)
    }

    func allEntries() -> [WindowState] {
        model.allEntries()
    }

    func allEntries(mode: TrackedWindowMode) -> [WindowState] {
        model.allEntries(mode: mode)
    }

    func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
        model.workspace(for: token)
    }

    func mode(for token: WindowToken) -> TrackedWindowMode? {
        model.mode(for: token)
    }

    func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
        model.lifecyclePhase(for: token)
    }

    func observedState(for token: WindowToken) -> ObservedWindowState? {
        model.observedState(for: token)
    }

    func desiredState(for token: WindowToken) -> DesiredWindowState? {
        model.desiredState(for: token)
    }

    func restoreIntent(for token: WindowToken) -> RestoreIntent? {
        model.restoreIntent(for: token)
    }

    func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
        model.managedReplacementMetadata(for: token)
    }

    func floatingState(for token: WindowToken) -> FloatingState? {
        model.floatingState(for: token)
    }

    func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
        model.manualLayoutOverride(for: token)
    }

    func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
        model.admissionHints(for: token)
    }

    func setHeuristicReasons(_ reasons: [AXWindowHeuristicReason], for token: WindowToken) {
        model.setHeuristicReasons(reasons, for: token)
    }

    func hiddenState(for token: WindowToken) -> HiddenState? {
        model.hiddenState(for: token)
    }

    func isHiddenInCorner(_ token: WindowToken) -> Bool {
        model.isHiddenInCorner(token)
    }

    func layoutReason(for token: WindowToken) -> LayoutReason {
        model.layoutReason(for: token)
    }

    func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
        model.isNativeFullscreenSuspended(token)
    }

    func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
        model.cachedConstraints(for: token, maxAge: maxAge)
    }

    func observedMinSize(for token: WindowToken) -> CGSize? {
        model.observedMinSize(for: token)
    }
}

extension WorldStore {
    func applyWorkspaceMonitorMove(
        workspaceId: WorkspaceDescriptor.ID,
        targetMonitorId: Monitor.ID,
        monitorSessions: [Monitor.ID: MonitorSession],
        floatingStates: [WindowToken: FloatingState],
        transferInteraction: Bool,
        monitors: [Monitor]
    ) {
        assertInCommit("applyWorkspaceMonitorMove")
        self.monitorSessions = monitorSessions

        for entry in model.windows(in: workspaceId) {
            if let floatingState = floatingStates[entry.token] {
                model.setFloatingState(floatingState, for: entry.token)
            }

            var observedState = entry.observedState
            observedState.monitorId = targetMonitorId
            model.setObservedState(observedState, for: entry.token)

            var desiredState = entry.desiredState
            desiredState.monitorId = targetMonitorId
            if let floatingState = floatingStates[entry.token] {
                desiredState.floatingFrame = floatingState.lastFrame
            }
            model.setDesiredState(desiredState, for: entry.token)

            if let updatedEntry = model.entry(for: entry.token) {
                model.setRestoreIntent(
                    StateReducer.restoreIntent(for: updatedEntry, monitors: monitors),
                    for: entry.token
                )
            }
        }

        updateFocus {
            if $0.pendingManagedFocus.workspaceId == workspaceId {
                $0.pendingManagedFocus.monitorId = targetMonitorId
            }
            if transferInteraction {
                $0.previousInteractionMonitorId = $0.interactionMonitorId
                $0.interactionMonitorId = targetMonitorId
            }
        }
    }

    func setLifecyclePhase(_ phase: WindowLifecyclePhase, for token: WindowToken) {
        assertInCommit("setLifecyclePhase")
        model.setLifecyclePhase(phase, for: token)
    }

    func setObservedState(_ state: ObservedWindowState, for token: WindowToken) {
        assertInCommit("setObservedState")
        model.setObservedState(state, for: token)
    }

    func setDesiredState(_ state: DesiredWindowState, for token: WindowToken) {
        assertInCommit("setDesiredState")
        model.setDesiredState(state, for: token)
    }

    func setRestoreIntent(_ intent: RestoreIntent?, for token: WindowToken) {
        assertInCommit("setRestoreIntent")
        model.setRestoreIntent(intent, for: token)
    }

    func updateWorkspace(
        for token: WindowToken,
        workspace: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) {
        assertInCommit("updateWorkspace")
        model.updateWorkspace(for: token, workspace: workspace)
        reconcileNiriMembership(
            for: token,
            keeping: model.mode(for: token) == .tiling ? workspace : nil,
            monitors: monitors
        )
    }

    func setMode(_ mode: TrackedWindowMode, for token: WindowToken, monitors: [Monitor]) {
        assertInCommit("setMode")
        model.setMode(mode, for: token)
        reconcileNiriMembership(
            for: token,
            keeping: mode == .tiling ? model.workspace(for: token) : nil,
            monitors: monitors
        )
    }

    func setFloatingState(_ state: FloatingState?, for token: WindowToken) {
        assertInCommit("setFloatingState")
        model.setFloatingState(state, for: token)
    }

    func applyFocusSession(_ focusSession: FocusSessionSnapshot) {
        assertInCommit("applyFocusSession")
        recordInteractionMonitorWrites(
            previousInteraction: focus.interactionMonitorId,
            previousPrevious: focus.previousInteractionMonitorId,
            to: focusSession
        )
        focus = focusSession
    }

    @discardableResult
    func updateFocus<T>(_ mutate: (inout FocusSessionSnapshot) -> T) -> T {
        assertInCommit("updateFocus")
        let previousInteraction = focus.interactionMonitorId
        let previousPrevious = focus.previousInteractionMonitorId
        let result = mutate(&focus)
        recordInteractionMonitorWrites(
            previousInteraction: previousInteraction,
            previousPrevious: previousPrevious,
            to: focus
        )
        return result
    }

    private func recordInteractionMonitorWrites(
        previousInteraction: Monitor.ID?,
        previousPrevious: Monitor.ID?,
        to next: FocusSessionSnapshot
    ) {
        let interactionChanged = previousInteraction != next.interactionMonitorId
        let previousChanged = previousPrevious != next.previousInteractionMonitorId
        guard interactionChanged || previousChanged else { return }
        let reason = currentCommitEvent?.summary ?? "unknown"
        if interactionChanged {
            InteractionMonitorWriteRecorder.shared.record(
                field: .interaction,
                oldValue: previousInteraction,
                newValue: next.interactionMonitorId,
                reason: reason
            )
        }
        if previousChanged {
            InteractionMonitorWriteRecorder.shared.record(
                field: .previous,
                oldValue: previousPrevious,
                newValue: next.previousInteractionMonitorId,
                reason: reason
            )
        }
    }

    private func reconcileNiriMembership(
        for token: WindowToken,
        keeping authoritativeWorkspaceId: WorkspaceDescriptor.ID?,
        monitors: [Monitor]
    ) {
        guard let engine = niriEngine else { return }
        let authoritativePlacement = authoritativeWorkspaceId.flatMap {
            engine.persistedPlacement(for: token, in: $0)
        }
        let staleWorkspaceIds = engine.workspaceIds(containing: token)
            .filter { $0 != authoritativeWorkspaceId }
            .sorted { $0.uuidString < $1.uuidString }
        if let authoritativeWorkspaceId,
           let authoritativePlacement,
           !staleWorkspaceIds.isEmpty
        {
            let placements = engine.persistedPlacementsInColumn(
                containing: token,
                in: authoritativeWorkspaceId
            )
            if placements.isEmpty {
                _ = storeNiriPlacement(
                    authoritativePlacement,
                    detached: false,
                    for: token,
                    monitors: monitors
                )
            } else {
                _ = storeNiriPlacements(
                    placements,
                    in: authoritativeWorkspaceId,
                    detachedToken: nil,
                    monitors: monitors
                )
            }
        } else if let staleWorkspaceId = staleWorkspaceIds.first {
            let placements = engine.persistedPlacementsInColumn(
                containing: token,
                in: staleWorkspaceId
            )
            if placements[token] != nil {
                _ = storeNiriPlacements(
                    placements,
                    in: staleWorkspaceId,
                    detachedToken: token,
                    monitors: monitors
                )
            } else if let placement = engine.persistedPlacement(for: token, in: staleWorkspaceId) {
                _ = storeNiriPlacement(
                    placement,
                    detached: true,
                    for: token,
                    monitors: monitors
                )
            }
        }
        for staleWorkspaceId in staleWorkspaceIds {
            repairViewportSelection(in: staleWorkspaceId, removing: token, engine: engine)
            engine.removeWindow(token: token, in: staleWorkspaceId)
        }
    }

    @discardableResult
    private func storeNiriPlacement(
        _ placement: PersistedNiriPlacement,
        detached: Bool,
        for token: WindowToken,
        monitors: [Monitor]
    ) -> Bool {
        guard let entry = model.entry(for: token) else { return false }
        var restoreIntent = StateReducer.restoreIntent(for: entry, monitors: monitors)
        restoreIntent.niriPlacement = placement
        if detached {
            restoreIntent.detachedNiriContainerSizingState = NiriContainerSizingState(
                width: placement.column.width,
                presetWidthIndex: placement.column.presetWidthIndex,
                isFullWidth: placement.column.isFullWidth,
                savedWidth: placement.column.savedWidth,
                hasManualSingleWindowWidthOverride: placement.column.hasManualSingleWindowWidthOverride,
                height: placement.column.height,
                isFullHeight: placement.column.isFullHeight,
                savedHeight: placement.column.savedHeight,
                hasManualSingleWindowHeightOverride: placement.column.hasManualSingleWindowHeightOverride
            )
        } else {
            restoreIntent.detachedNiriContainerSizingState = nil
        }
        guard entry.restoreIntent != restoreIntent else { return false }
        model.setRestoreIntent(restoreIntent, for: token)
        return true
    }

    @discardableResult
    private func storeNiriPlacements(
        _ placements: [WindowToken: PersistedNiriPlacement],
        in workspaceId: WorkspaceDescriptor.ID,
        detachedToken: WindowToken?,
        monitors: [Monitor]
    ) -> Bool {
        var changed = false
        for (token, placement) in placements {
            if token != detachedToken {
                guard let entry = model.entry(for: token),
                      entry.mode == .tiling,
                      entry.workspaceId == workspaceId
                else {
                    continue
                }
            }
            changed = storeNiriPlacement(
                placement,
                detached: token == detachedToken,
                for: token,
                monitors: monitors
            ) || changed
        }
        return changed
    }

    @discardableResult
    func captureDetachedNiriPlacement(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Bool {
        assertInCommit("captureDetachedNiriPlacement")
        return captureNiriPlacements(
            for: token,
            in: workspaceId,
            detachedToken: token,
            monitors: monitors
        )
    }

    @discardableResult
    func captureLiveNiriPlacements(
        containing tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        monitors: [Monitor]
    ) -> Bool {
        assertInCommit("captureLiveNiriPlacements")
        guard let engine = niriEngine else { return false }
        var visitedTokens = Set<WindowToken>()
        var changed = false
        for token in tokens where visitedTokens.insert(token).inserted {
            let placements = engine.persistedPlacementsInColumn(
                containing: token,
                in: workspaceId
            )
            visitedTokens.formUnion(placements.keys)
            changed = storeNiriPlacements(
                placements,
                in: workspaceId,
                detachedToken: nil,
                monitors: monitors
            ) || changed
        }
        return changed
    }

    private func captureNiriPlacements(
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        detachedToken: WindowToken?,
        monitors: [Monitor]
    ) -> Bool {
        guard let engine = niriEngine else { return false }
        let placements = engine.persistedPlacementsInColumn(
            containing: token,
            in: workspaceId
        )
        guard !placements.isEmpty else { return false }
        return storeNiriPlacements(
            placements,
            in: workspaceId,
            detachedToken: detachedToken,
            monitors: monitors
        )
    }

    private func repairViewportSelection(
        in workspaceId: WorkspaceDescriptor.ID,
        removing token: WindowToken,
        engine: NiriLayoutEngine
    ) {
        guard let node = engine.findNode(for: token, in: workspaceId),
              var state = viewports[workspaceId],
              state.selectedNodeId == node.id
        else { return }
        state.selectedNodeId = engine.fallbackSelectionOnRemoval(removing: node.id, in: workspaceId)
        applyViewportPlan(.set(workspaceId: workspaceId, state: state))
    }

    func layoutTopology(for workspaceId: WorkspaceDescriptor.ID) -> LayoutTopology {
        switch activeLayoutResolver?(workspaceId) {
        case .dwindle:
            return LayoutTopology(dwindleFullscreenTokens: dwindleEngine?.fullscreenTokens(in: workspaceId) ?? [])
        case .niri,
             nil:
            return LayoutTopology(columns: niriEngine?.topologyColumns(in: workspaceId) ?? [])
        }
    }

    func installActiveLayoutResolver(_ resolver: ((WorkspaceDescriptor.ID) -> ActiveLayoutKind)?) {
        activeLayoutResolver = resolver
    }

    @discardableResult
    func installNiriEngine(_ engine: NiriLayoutEngine?, monitors: [Monitor]) -> Bool {
        let captured = if let current = niriEngine, current !== engine {
            captureNiriPlacements(from: current, monitors: monitors)
        } else {
            false
        }
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        niriEngine = engine
        return captured
    }

    private func captureNiriPlacements(
        from engine: NiriLayoutEngine,
        monitors: [Monitor]
    ) -> Bool {
        let entries = model.allEntries()
        let authoritativeWorkspaceIds = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.token, $0.workspaceId) }
        )
        var placements: [WindowToken: PersistedNiriPlacement] = [:]
        placements.reserveCapacity(entries.count)
        for workspaceId in engine.workspaceIds().sorted(by: { $0.uuidString < $1.uuidString }) {
            for (token, placement) in engine.persistedPlacements(in: workspaceId)
                where placements[token] == nil || authoritativeWorkspaceIds[token] == workspaceId
            {
                placements[token] = placement
            }
        }

        var captured = false
        for entry in entries {
            if let placement = placements[entry.token] {
                captured = storeNiriPlacement(
                    placement,
                    detached: true,
                    for: entry.token,
                    monitors: monitors
                ) || captured
            }
        }
        return captured
    }

    func installDwindleEngine(_ engine: DwindleLayoutEngine?) {
        engine?.isMutationSanctioned = isEngineMutationSanctioned
        dwindleEngine = engine
    }

    func applyViewportPlan(_ viewportPlan: ViewportPlan) {
        assertInCommit("applyViewportPlan")
        switch viewportPlan {
        case let .set(workspaceId, state):
            viewports[workspaceId] = state
        case let .remove(workspaceIds):
            for workspaceId in workspaceIds {
                viewports.removeValue(forKey: workspaceId)
            }
        }
    }

    func setCachedConstraints(_ constraints: WindowSizeConstraints, for token: WindowToken) {
        model.setCachedConstraints(constraints, for: token)
    }

    @discardableResult
    func setObservedMinSize(_ size: CGSize, for token: WindowToken) -> Bool {
        model.setObservedMinSize(size, for: token)
    }
}
