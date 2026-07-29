// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum WorkspacePlacementRung: String, Sendable {
    case existingEntry = "existing_entry"
    case structuralReplacement = "structural_replacement"
    case trackedParent = "tracked_parent"
    case workspaceRule = "workspace_rule"
    case pendingFocusContext = "pending_focus_context"
    case interactionWorkspace = "interaction_workspace"
    case focusedContext = "focused_context"
    case nativeSpace = "native_space"
    case floatingSpawn = "floating_spawn"
    case liveManagedFocus = "live_managed_focus"
    case frame = "frame"
    case axFrame = "ax_frame"
    case interactionMonitor = "interaction_monitor"
    case fallbackWorkspace = "fallback_workspace"
    case defaultWorkspace = "default_workspace"
}

enum WorkspacePlacementOrigin: Equatable, Sendable {
    case liveCreate
    case discovery
}

struct WorkspacePlacementResolution: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let rung: WorkspacePlacementRung
}

@MainActor
final class PlacementResolver {
    private struct WorkspacePlacementTarget {
        let workspaceId: WorkspaceDescriptor.ID?
        let rung: WorkspacePlacementRung
    }

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.focusedToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    func resolveWorkspacePlacement(
        workspaceName: String?,
        axRef: AXWindowRef?,
        pid: pid_t?,
        parentWindowId: UInt32?,
        inheritTrackedParentWorkspace: Bool,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID?,
        placementMode: TrackedWindowMode,
        allowsFloatingSpawnPlacement: Bool,
        origin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        existingEntry: WindowState?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext
    ) -> WorkspacePlacementResolution {
        if context == .automatic, let existingEntry {
            return WorkspacePlacementResolution(workspaceId: existingEntry.workspaceId, rung: .existingEntry)
        }

        if existingEntry == nil,
           let structuralReplacementWorkspaceId,
           workspaceManager.descriptor(for: structuralReplacementWorkspaceId) != nil
        {
            return WorkspacePlacementResolution(
                workspaceId: structuralReplacementWorkspaceId,
                rung: .structuralReplacement
            )
        }

        if existingEntry == nil,
           inheritTrackedParentWorkspace,
           let parentWorkspaceId = workspaceForTrackedParentWindow(parentWindowId: parentWindowId, pid: pid)
        {
            return WorkspacePlacementResolution(workspaceId: parentWorkspaceId, rung: .trackedParent)
        }

        if let workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false),
           shouldApplyWorkspaceRule(pid: pid, context: context)
        {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: .workspaceRule)
        }

        if let existingEntry {
            return WorkspacePlacementResolution(workspaceId: existingEntry.workspaceId, rung: .existingEntry)
        }

        let placementTarget = createPlacementTarget(
            axRef: axRef,
            pid: pid,
            placementMode: placementMode,
            allowsFloatingSpawnPlacement: allowsFloatingSpawnPlacement,
            origin: origin,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            fallbackWorkspaceId: fallbackWorkspaceId
        )

        return defaultWorkspacePlacement(placementTarget: placementTarget)
    }

    private func workspaceForTrackedParentWindow(
        parentWindowId: UInt32?,
        pid _: pid_t?
    ) -> WorkspaceDescriptor.ID? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return workspaceManager.entry(forWindowId: Int(parentWindowId))?.workspaceId
    }

    private func shouldApplyWorkspaceRule(
        pid: pid_t?,
        context: WindowRuleReevaluationContext
    ) -> Bool {
        if context == .explicitRuleApply {
            return true
        }
        guard let pid else { return true }
        return !workspaceManager.hasEntries(forPid: pid)
    }

    func floatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
        let tiled = workspaceManager.entries(forPid: pid).filter { $0.mode == .tiling }
        guard !tiled.isEmpty else { return nil }

        if let focused = workspaceManager.focusedToken,
           let entry = tiled.first(where: { $0.token == focused }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        if let recent = workspaceManager.lastTiledFocusedToken,
           let entry = tiled.first(where: { $0.token == recent }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        let monitors = Set(tiled.compactMap { workspaceManager.monitorId(for: $0.workspaceId) })
        return monitors.count == 1 ? monitors.first : nil
    }

    private func defaultWorkspacePlacement(
        placementTarget: WorkspacePlacementTarget
    ) -> WorkspacePlacementResolution {
        if let workspaceId = placementTarget.workspaceId {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: placementTarget.rung)
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementResolution(workspaceId: workspace.id, rung: .defaultWorkspace)
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: .defaultWorkspace)
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return WorkspacePlacementResolution(workspaceId: createdWorkspaceId, rung: .defaultWorkspace)
        }
        fatal("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func createPlacementTarget(
        axRef: AXWindowRef?,
        pid: pid_t?,
        placementMode: TrackedWindowMode,
        allowsFloatingSpawnPlacement: Bool,
        origin: WorkspacePlacementOrigin,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspacePlacementTarget {
        let preferManagedFocusPlacement = placementMode == .tiling
        let nativeSpaceTarget: WorkspacePlacementTarget? = if let monitorId = createPlacementContext?
            .nativeSpaceMonitorId,
            let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .nativeSpace
            )
        } else {
            nil
        }
        let floatingSpawnTarget: WorkspacePlacementTarget? = if allowsFloatingSpawnPlacement,
                                                                !preferManagedFocusPlacement,
                                                                let pid,
                                                                let monitorId = floatingSpawnMonitorId(pid: pid),
                                                                let workspace = workspaceManager.activeWorkspaceOrFirst(
                                                                    on: monitorId
                                                                )
        {
            WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .floatingSpawn
            )
        } else {
            nil
        }

        if origin == .liveCreate {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId,
                rung: .pendingFocusContext
            ) {
                return target
            }

            if let floatingSpawnTarget {
                if let nativeSpaceTarget {
                    return nativeSpaceTarget
                }
                return floatingSpawnTarget
            }

            if let target = capturedInteractionPlacementTarget(createPlacementContext) {
                return target
            }

            if let target = liveInteractionPlacementTarget() {
                return target
            }
        } else if preferManagedFocusPlacement,
                  let target = managedFocusPlacementTarget(
                      createPlacementContext?.pendingFocusedWorkspaceId,
                      createPlacementContext?.pendingFocusedMonitorId,
                      rung: .pendingFocusContext
                  )
        {
            return target
        }

        if preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if let nativeSpaceTarget {
            return nativeSpaceTarget
        }

        if let floatingSpawnTarget {
            return floatingSpawnTarget
        }

        if preferManagedFocusPlacement,
           let target = liveManagedFocusPlacementTarget()
        {
            return target
        }

        if let monitor = monitorForPlacementFrame(windowFrame),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .frame
            )
        }

        if workspaceManager.monitors.count > 1,
           let axRef,
           let monitor = monitorForPlacementFrame(AXWindowService.framePreferFast(axRef)),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .axFrame
            )
        }

        if !preferManagedFocusPlacement {
            if origin == .discovery,
               let target = managedFocusPlacementTarget(
                   createPlacementContext?.pendingFocusedWorkspaceId,
                   createPlacementContext?.pendingFocusedMonitorId,
                   rung: .pendingFocusContext
               )
            {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if origin == .discovery,
           let target = capturedInteractionPlacementTarget(createPlacementContext)
        {
            return target
        }

        if let fallbackWorkspaceId,
           workspaceManager.descriptor(for: fallbackWorkspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: fallbackWorkspaceId,
                rung: .fallbackWorkspace
            )
        }

        return WorkspacePlacementTarget(
            workspaceId: nil,
            rung: .defaultWorkspace
        )
    }

    private func capturedInteractionPlacementTarget(
        _ context: WindowCreatePlacementContext?
    ) -> WorkspacePlacementTarget? {
        if let workspaceId = context?.interactionWorkspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                rung: .interactionWorkspace
            )
        }

        if let monitorId = context?.interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: .interactionMonitor
            )
        }

        return nil
    }

    private func liveInteractionPlacementTarget() -> WorkspacePlacementTarget? {
        guard let monitorId = workspaceManager.interactionMonitorId,
              let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        else {
            return nil
        }
        return WorkspacePlacementTarget(
            workspaceId: workspace.id,
            rung: .interactionMonitor
        )
    }

    private func liveManagedFocusPlacementTarget() -> WorkspacePlacementTarget? {
        guard !workspaceManager.isNonManagedFocusActive else { return nil }
        for token in [workspaceManager.focusedToken, workspaceManager.lastTiledFocusedToken] {
            guard let token,
                  let entry = workspaceManager.entry(for: token),
                  let target = managedFocusPlacementTarget(entry.workspaceId, nil, rung: .liveManagedFocus)
            else {
                continue
            }
            return target
        }
        return nil
    }

    private func managedFocusPlacementTarget(
        _ workspaceId: WorkspaceDescriptor.ID?,
        _ monitorId: Monitor.ID?,
        rung: WorkspacePlacementRung
    ) -> WorkspacePlacementTarget? {
        if let workspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                rung: rung
            )
        }

        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                rung: rung
            )
        }

        return nil
    }

    private func monitorForPlacementFrame(_ frame: CGRect?) -> Monitor? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: workspaceManager.monitors)
    }
}
