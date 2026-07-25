// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct TopologyTransitionPlan: Equatable {
    let previousMonitors: [Monitor]
    let newMonitors: [Monitor]
    var visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID]
    var disconnectedVisibleWorkspaceCache: [MonitorRestoreKey: WorkspaceDescriptor.ID]
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
    var refreshRestoreIntents: Bool
}

struct PersistedHydrationMutation: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let monitorId: Monitor.ID?
    let targetMode: TrackedWindowMode
    let floatingFrame: CGRect?
    let niriPlacement: PersistedNiriPlacement?
    let detachedNiriContainerSizingState: NiriContainerSizingState?
    let consumedKey: PersistedWindowRestoreKey
    let consumedEntry: PersistedWindowRestoreConsumptionKey
}

struct RestoreRefreshPlan: Equatable {
    var refreshRestoreIntents: Bool
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
}

enum ViewportPlan: Equatable {
    case set(workspaceId: WorkspaceDescriptor.ID, state: ViewportState)
    case remove(workspaceIds: Set<WorkspaceDescriptor.ID>)
}

struct ActionPlan: Equatable {
    var lifecyclePhase: WindowLifecyclePhase? = nil
    var observedState: ObservedWindowState? = nil
    var desiredState: DesiredWindowState? = nil
    var restoreIntent: RestoreIntent? = nil
    var focusSession: FocusSessionSnapshot? = nil
    var viewport: ViewportPlan? = nil
    var restoreRefresh: RestoreRefreshPlan? = nil
    var topologyTransition: TopologyTransitionPlan? = nil
    var persistedHydration: PersistedHydrationMutation? = nil
    var notes: [String] = []

    var isEmpty: Bool {
        !mutatesRuntimeState && notes.isEmpty
    }

    var mutatesRuntimeState: Bool {
        lifecyclePhase != nil
            || observedState != nil
            || desiredState != nil
            || restoreIntent != nil
            || focusSession != nil
            || viewport != nil
            || restoreRefresh != nil
            || topologyTransition != nil
            || persistedHydration != nil
    }

    var summary: String {
        var parts: [String] = []
        if let lifecyclePhase {
            parts.append("phase=\(lifecyclePhase.rawValue)")
        }
        if let desiredState {
            parts.append("desired=\(desiredState.summary)")
        }
        if let focusSession {
            parts.append("focus=\(describe(focusSession))")
        }
        if let viewport {
            switch viewport {
            case let .set(workspaceId, state):
                parts.append(
                    "viewport=\(workspaceId.uuidString):selected=\(state.selectedNodeId.map(String.init(describing:)) ?? "nil"),column=\(state.activeColumnIndex)"
                )
            case let .remove(workspaceIds):
                parts.append("viewport_removed=\(workspaceIds.count)")
            }
        }
        if let restoreRefresh {
            if restoreRefresh.refreshRestoreIntents {
                parts.append("restore_refresh=true")
            }
            parts.append(
                "interaction=\(String(describing: restoreRefresh.interactionMonitorId))->\(String(describing: restoreRefresh.previousInteractionMonitorId))"
            )
        }
        if let topologyTransition {
            parts.append(
                "topology=\(topologyTransition.previousMonitors.count)->\(topologyTransition.newMonitors.count)"
            )
            parts.append("visible_assignments=\(topologyTransition.visibleAssignments.count)")
        }
        if let persistedHydration {
            parts.append(
                "hydration=workspace=\(persistedHydration.workspaceId.uuidString),mode=\(persistedHydration.targetMode)"
            )
        }
        if !notes.isEmpty {
            parts.append(contentsOf: notes)
        }
        return parts.joined(separator: " ")
    }

    private func describe(_ focusSession: FocusSessionSnapshot) -> String {
        var parts: [String] = []
        parts.append("focused=\(focusSession.focusedToken.map(String.init(describing:)) ?? "nil")")
        parts.append("pending=\(focusSession.pendingManagedFocus.token.map(String.init(describing:)) ?? "nil")")
        if let requestId = focusSession.pendingManagedFocus.requestId {
            parts.append("request=\(requestId)")
        }
        if let leaseOwner = focusSession.focusLease?.owner.rawValue {
            parts.append("lease=\(leaseOwner)")
        }
        if focusSession.isNonManagedFocusActive {
            parts.append("non_managed=true")
        }
        return parts.joined(separator: ",")
    }
}
