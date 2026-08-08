// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum StateReducer {
    static func reduce(
        event: WMEvent,
        existingEntry: WindowState?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor]
    ) -> ActionPlan {
        var plan = ActionPlan()

        switch event {
        case let .windowAdmitted(_, workspaceId, monitorId, mode, _, _, _, _, _):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )

        case let .windowRekeyed(from, to, workspaceId, monitorId, _, _, _, _):
            plan.lifecyclePhase = .replacing
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.focusSession = rekeyedFocusSession(
                from: currentSnapshot.focusSession,
                oldToken: from,
                newToken: to
            )

        case let .windowRemoved(token, workspaceId, _):
            plan.lifecyclePhase = .destroyed
            plan.focusSession = removingFocusState(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId
            )

        case let .workspaceAssigned(token, _, workspaceId, monitorId, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            if let focusSession = reassigningFocusState(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId
            ) {
                plan.focusSession = focusSession
            }

        case let .windowModeChanged(token, workspaceId, monitorId, mode, _):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )
            var focusSession = currentSnapshot.focusSession
            if focusSession.reconcileRememberedFocus(afterModeChangeOf: token, in: workspaceId, to: mode) {
                plan.focusSession = focusSession
            }

        case let .floatingGeometryUpdated(_, workspaceId, referenceMonitorId, frame, _, restoreToFloating, _):
            plan.lifecyclePhase = .floating
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.observedState.monitorId
            )
            observedState.frame = frame
            plan.observedState = observedState

            var desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.desiredState.monitorId,
                mode: .floating
            )
            desiredState.floatingFrame = frame
            desiredState.rescueEligible = restoreToFloating
            plan.desiredState = desiredState

        case let .floatingStateChanged(_, _, state, _):
            plan.notes = ["floating_state=\(state != nil)"]

        case let .manualLayoutOverrideChanged(_, _, layoutOverride, _):
            plan.notes = ["manual_layout_override=\(layoutOverride.map(\.rawValue) ?? "cleared")"]

        case .windowAdmissionHintsChanged:
            break

        case let .niriPlacementsResolved(placements, _):
            plan.notes = ["niri_placements=\(placements.count)"]

        case let .layoutOperationPerformed(_, operation, _):
            plan.notes = ["layout_op=\(operation.summary)"]

        case let .scratchpadChanged(token, _):
            plan.notes = ["scratchpad=\(token != nil)"]

        case let .visibleWorkspacesChanged(sessions, _):
            plan.notes = ["visible_workspaces=\(sessions.count)"]

        case let .spaceTopologyChanged(topology, _):
            plan.notes = ["space_topology displays=\(topology.displays.count)"]

        case let .hiddenStateChanged(_, workspaceId, monitorId, hiddenState, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isVisible = hiddenState == nil
            plan.observedState = observedState
            if let hiddenState {
                plan.lifecyclePhase = hiddenState.offscreenSide == nil ? .hidden : .offscreen
            } else {
                plan.lifecyclePhase = lifecyclePhase(for: existingEntry?.mode ?? .tiling)
            }

        case let .nativeFullscreenTransition(_, workspaceId, monitorId, change, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isNativeFullscreen = change.isNativeFullscreenActive
            plan.observedState = observedState
            plan.lifecyclePhase = change.isNativeFullscreenActive
                ? .nativeFullscreen
                : lifecyclePhase(for: existingEntry?.mode ?? .tiling)

        case let .managedReplacementMetadataChanged(_, workspaceId, monitorId, _, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.notes = ["managed_replacement_metadata_changed"]

        case let .topologyChanged(displays, _):
            plan.notes = ["topology=\(displays.count)"]

        case .activeSpaceChanged:
            plan.notes = ["active_space_changed"]

        case let .focusLeaseChanged(lease, _):
            setFocusSession(
                updatingFocusLease(
                    in: currentSnapshot.focusSession,
                    lease: lease
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )
            if let lease {
                plan.notes = ["focus_lease=\(lease.owner.rawValue)", lease.reason].filter { !$0.isEmpty }
            } else {
                plan.notes = ["focus_lease=cleared"]
            }

        case let .managedFocusRequested(token, workspaceId, monitorId, requestId, _):
            setFocusSession(
                managedFocusRequested(
                    from: currentSnapshot.focusSession,
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId,
                    requestId: requestId
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )

        case let .managedFocusConfirmed(token, workspaceId, monitorId, requestId, _):
            var focusSession = managedFocusConfirmed(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId,
                requestId: requestId,
                mode: currentSnapshot.windows.first(where: { $0.token == token })?.mode
            )
            if focusSession.suppressedFocusToken == token {
                focusSession.suppressedFocusToken = nil
            }
            focusSession.nonManagedFocusToken = nil
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .managedFocusCancelled(token, workspaceId, requestId, _):
            setFocusSession(
                managedFocusCancelled(
                    from: currentSnapshot.focusSession,
                    token: token,
                    workspaceId: workspaceId,
                    requestId: requestId
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )

        case let .nonManagedFocusChanged(
            active,
            preserveFocusedToken,
            preservePendingManagedFocus,
            _
        ):
            setFocusSession(
                nonManagedFocusChanged(
                    from: currentSnapshot.focusSession,
                    active: active,
                    preserveFocusedToken: preserveFocusedToken,
                    preservePendingManagedFocus: preservePendingManagedFocus
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )

        case let .focusRemembered(token, workspaceId, mode, _):
            var focusSession = currentSnapshot.focusSession
            if focusSession.rememberFocus(token, in: workspaceId, mode: mode) {
                plan.focusSession = focusSession
            }

        case let .focusForgotten(workspaceIds, _):
            var focusSession = currentSnapshot.focusSession
            for workspaceId in workspaceIds {
                focusSession.lastTiledFocusedByWorkspace.removeValue(forKey: workspaceId)
                focusSession.lastFloatingFocusedByWorkspace.removeValue(forKey: workspaceId)
                focusSession.lastFocusedByWorkspace.removeValue(forKey: workspaceId)
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .nonManagedFocusTargetChanged(target, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.nonManagedFocusToken = target
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .suppressedFocusChanged(token, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.suppressedFocusToken = token
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .systemModalFocusChanged(token, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.systemModalFocusToken = token
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .workspaceFocusCleared(workspaceId, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.clearPendingManagedFocus(
                matching: nil,
                workspaceId: workspaceId,
                requestId: focusSession.pendingManagedFocus.requestId
            )
            if let focusedToken = focusSession.focusedToken,
               currentSnapshot.windows.first(where: { $0.token == focusedToken })?.workspaceId == workspaceId
            {
                focusSession.focusedToken = nil
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .nativeFullscreenPlaceholderSelected(token, _, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.focusedToken = token
            focusSession.isNonManagedFocusActive = true
            focusSession.clearPendingManagedFocus()
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .interactionMonitorChanged(monitorId, previousMonitorId, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.interactionMonitorId = monitorId
            focusSession.previousInteractionMonitorId = previousMonitorId
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)

        case let .viewportChanged(workspaceId, state, _):
            var viewport = state
            viewport.clearOffsetTransition()
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)

        case let .viewportCommitted(workspaceId, state, _):
            var viewport = state
            viewport.clearOffsetTransition()
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)

        case let .viewportForgotten(workspaceIds, _):
            let present = workspaceIds.filter { currentSnapshot.viewports[$0] != nil }
            if !present.isEmpty {
                plan.viewport = .remove(workspaceIds: present)
            }

        case let .selectionChanged(workspaceId, nodeId, _):
            var viewport = currentSnapshot.viewports[workspaceId] ?? ViewportState()
            viewport.selectedNodeId = nodeId
            setViewport(viewport, for: workspaceId, currentSnapshot: currentSnapshot, plan: &plan)

        case .systemSleep:
            plan.notes = ["system_sleep"]

        case .systemWake:
            plan.notes = ["system_wake"]

        case .userCommand:
            plan.notes = ["user_command"]
        }

        if plan.restoreIntent == nil, plan.mutatesRuntimeState, let existingEntry {
            let restoreIntent = restoreIntent(for: existingEntry, monitors: monitors)
            if existingEntry.restoreIntent != restoreIntent {
                plan.restoreIntent = restoreIntent
            }
        }

        return plan
    }

    static func restoreIntent(
        for entry: WindowState,
        monitors: [Monitor]
    ) -> RestoreIntent {
        let preferredMonitorId = entry.desiredState.monitorId
            ?? entry.observedState.monitorId
            ?? entry.floatingState?.referenceMonitorId
        let preferredMonitor = preferredMonitorId.flatMap { id in
            monitors.first { $0.id == id }
        }
        let floatingState = entry.floatingState
        let hasDetachedNiriPlacement = entry.restoreIntent?.detachedNiriContainerSizingState != nil
        let preservesNiriPlacement = hasDetachedNiriPlacement
            || (entry.mode == .tiling && entry.restoreIntent?.workspaceId == entry.workspaceId)
        let niriPlacement = preservesNiriPlacement ? entry.restoreIntent?.niriPlacement : nil
        return RestoreIntent(
            topologyProfile: TopologyProfile(monitors: monitors),
            workspaceId: entry.workspaceId,
            preferredMonitor: preferredMonitor.map(DisplayFingerprint.init),
            floatingFrame: entry.desiredState.floatingFrame ?? floatingState?.lastFrame,
            normalizedFloatingOrigin: floatingState?.normalizedOrigin,
            restoreToFloating: floatingState?.restoreToFloating ?? (entry.mode == .floating),
            rescueEligible: entry.desiredState.rescueEligible || floatingState?.restoreToFloating == true,
            niriPlacement: niriPlacement,
            detachedNiriContainerSizingState: entry.restoreIntent?.detachedNiriContainerSizingState
        )
    }

    static func replay(_ trace: [ReconcileTraceRecord]) -> [ActionPlan] {
        trace.map(\.plan)
    }

    private static func lifecyclePhase(for mode: TrackedWindowMode) -> WindowLifecyclePhase {
        switch mode {
        case .tiling:
            .tiled
        case .floating:
            .floating
        }
    }

    private static func baseObservedState(
        from entry: WindowState?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        var state = entry?.observedState ?? ObservedWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        return state
    }

    private static func baseDesiredState(
        from entry: WindowState?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode
    ) -> DesiredWindowState {
        var state = entry?.desiredState ?? DesiredWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: mode
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        state.disposition = mode
        state.rescueEligible = mode == .floating || state.rescueEligible
        return state
    }

    private static func updatingFocusLease(
        in focusSession: FocusSessionSnapshot,
        lease: FocusPolicyLease?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.focusLease = lease
        return focusSession
    }

    private static func managedFocusRequested(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: token,
            workspaceId: workspaceId,
            monitorId: monitorId,
            requestId: requestId
        )
        return focusSession
    }

    private static func managedFocusConfirmed(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64?,
        mode: TrackedWindowMode?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if let requestId {
            guard focusSession.pendingManagedFocus.requestId == requestId,
                  focusSession.pendingManagedFocus.token == token,
                  focusSession.pendingManagedFocus.workspaceId == workspaceId
            else {
                return focusSession
            }
        } else if focusSession.pendingManagedFocus != .empty {
            guard focusSession.pendingManagedFocus.requestId == nil,
                  focusSession.pendingManagedFocus.token == token,
                  focusSession.pendingManagedFocus.workspaceId == workspaceId
            else {
                return focusSession
            }
        }
        focusSession.focusedToken = token
        focusSession.pendingManagedFocus = .empty
        if mode != .floating {
            _ = focusSession.recordTiledFocus(token)
        }
        if focusSession.interactionMonitorId != monitorId {
            if let currentMonitorId = focusSession.interactionMonitorId,
               currentMonitorId != monitorId
            {
                focusSession.previousInteractionMonitorId = currentMonitorId
            }
            focusSession.interactionMonitorId = monitorId
        }
        focusSession.isNonManagedFocusActive = false
        return focusSession
    }

    private static func managedFocusCancelled(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        let matchesToken = token.map { focusSession.pendingManagedFocus.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { focusSession.pendingManagedFocus.workspaceId == $0 } ?? true
        let matchesRequest = requestId.map { focusSession.pendingManagedFocus.requestId == $0 }
            ?? (focusSession.pendingManagedFocus.requestId == nil)
        if matchesToken, matchesWorkspace, matchesRequest {
            focusSession.pendingManagedFocus = .empty
        }
        return focusSession
    }

    private static func setFocusSession(
        _ next: FocusSessionSnapshot,
        current: FocusSessionSnapshot,
        plan: inout ActionPlan
    ) {
        guard next != current else { return }
        plan.focusSession = next
    }

    private static func setViewport(
        _ next: ViewportState,
        for workspaceId: WorkspaceDescriptor.ID,
        currentSnapshot: ReconcileSnapshot,
        plan: inout ActionPlan
    ) {
        if let current = currentSnapshot.viewports[workspaceId], current == next {
            return
        }
        plan.viewport = .set(workspaceId: workspaceId, state: next)
    }

    private static func nonManagedFocusChanged(
        from focusSession: FocusSessionSnapshot,
        active: Bool,
        preserveFocusedToken: Bool,
        preservePendingManagedFocus: Bool
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if active, !preserveFocusedToken {
            focusSession.focusedToken = nil
        }
        if !preservePendingManagedFocus {
            focusSession.pendingManagedFocus = .empty
        }
        focusSession.isNonManagedFocusActive = active
        return focusSession
    }

    private static func rekeyedFocusSession(
        from focusSession: FocusSessionSnapshot,
        oldToken: WindowToken,
        newToken: WindowToken
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.focusedToken == oldToken {
            focusSession.focusedToken = newToken
        }
        if focusSession.pendingManagedFocus.token == oldToken {
            focusSession.pendingManagedFocus.token = newToken
        }
        focusSession.replaceRememberedFocus(from: oldToken, to: newToken)
        if focusSession.nonManagedFocusToken == oldToken {
            focusSession.nonManagedFocusToken = newToken
        }
        if focusSession.suppressedFocusToken == oldToken {
            focusSession.suppressedFocusToken = newToken
        }
        if focusSession.systemModalFocusToken == oldToken {
            focusSession.systemModalFocusToken = newToken
        }
        return focusSession
    }

    private static func removingFocusState(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.focusedToken == token {
            focusSession.focusedToken = nil
        }
        if focusSession.pendingManagedFocus.token == token {
            focusSession.pendingManagedFocus = .empty
        }
        if focusSession.systemModalFocusToken == token {
            focusSession.systemModalFocusToken = nil
        }
        if focusSession.suppressedFocusToken == token {
            focusSession.suppressedFocusToken = nil
        }
        focusSession.clearRememberedFocus(token, workspaceId: workspaceId)
        return focusSession
    }

    private static func reassigningFocusState(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> FocusSessionSnapshot? {
        guard focusSession.pendingManagedFocus.token == token,
              let pendingWorkspaceId = focusSession.pendingManagedFocus.workspaceId,
              pendingWorkspaceId != workspaceId
        else {
            return nil
        }
        var focusSession = focusSession
        focusSession.clearPendingManagedFocus()
        return focusSession
    }
}
