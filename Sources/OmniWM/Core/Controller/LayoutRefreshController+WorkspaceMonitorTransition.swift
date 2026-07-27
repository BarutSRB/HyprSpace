// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension LayoutRefreshController {
    struct ScheduledWorkspaceMonitorRelocation: Equatable {
        let relocation: WorkspaceFloatingRelocation
        let allowsTerminalRecovery: Bool

        var workspaceId: WorkspaceDescriptor.ID {
            relocation.workspaceId
        }

        var token: WindowToken {
            relocation.token
        }

        var frame: CGRect {
            relocation.frame
        }
    }

    func applyRefreshMetadata(_ refresh: ScheduledRefresh, to plan: inout EffectPlan) {
        applyWorkspaceMonitorRelocations(
            refresh.workspaceMonitorRelocations,
            reconcileDurableState: refresh.reconcilesWorkspaceMonitorState,
            to: &plan
        )
        if !refresh.postLayoutActions.isEmpty {
            plan.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        }
        if refresh.suppressesWindowActivation {
            plan.effects.suppressWindowActivation = true
        }
    }

    func commitWorkspaceMonitorTransition(_ outcome: WorkspaceMonitorMoveOutcome) {
        guard outcome.status == .executed, !outcome.affectedWorkspaces.isEmpty else { return }
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .workspaceTransition,
                affectedWorkspaceIds: outcome.affectedWorkspaces,
                workspaceMonitorRelocations: outcome.floatingRelocations.map {
                    ScheduledWorkspaceMonitorRelocation(
                        relocation: $0,
                        allowsTerminalRecovery: true
                    )
                },
                suppressesWindowActivation: true
            )
        )
    }

    func applyWorkspaceMonitorRelocations(
        _ relocations: [WindowToken: ScheduledWorkspaceMonitorRelocation],
        reconcileDurableState: Bool = false,
        to plan: inout EffectPlan
    ) {
        guard let controller, reconcileDurableState || !relocations.isEmpty else { return }
        let relocationsByWorkspace = Dictionary(grouping: relocations.values, by: \.workspaceId)

        for index in plan.workspacePlans.indices {
            guard plan.workspacePlans[index].isActiveWorkspace else { continue }
            let workspaceId = plan.workspacePlans[index].workspaceId
            let monitorId = plan.workspacePlans[index].monitor.monitorId
            var frameChangesByToken: [WindowToken: LayoutFrameChange] = [:]

            if reconcileDurableState,
               let monitor = controller.workspaceManager.monitor(byId: monitorId)
            {
                for entry in controller.workspaceManager.floatingEntries(in: workspaceId) {
                    let isInactiveNativeSpace = controller.workspaceManager.spaceTopology
                        .isWindowOnKnownInactiveSpace(entry.windowId)
                    guard entry.layoutReason == .standard,
                          entry.hiddenState == nil,
                          entry.desiredState.monitorId == monitorId,
                          !isInactiveNativeSpace,
                          let frame = controller.workspaceManager.resolvedFloatingFrame(
                              for: entry.token,
                              preferredMonitor: monitor
                          ),
                          entry.observedState.frame != frame
                    else {
                        continue
                    }
                    frameChangesByToken[entry.token] = LayoutFrameChange(
                        token: entry.token,
                        frame: frame,
                        forceApply: false
                    )
                }
            }

            for relocation in relocationsByWorkspace[workspaceId] ?? [] {
                guard let entry = controller.workspaceManager.entry(for: relocation.token),
                      let floatingState = entry.floatingState
                else {
                    continue
                }
                guard entry.workspaceId == workspaceId,
                      entry.mode == .floating,
                      entry.layoutReason == .standard,
                      entry.hiddenState == nil,
                      floatingState.lastFrame == relocation.frame,
                      floatingState.referenceMonitorId == monitorId
                else {
                    continue
                }
                frameChangesByToken[relocation.token] = LayoutFrameChange(
                    token: relocation.token,
                    frame: relocation.frame,
                    forceApply: true,
                    allowsTerminalRecovery: relocation.allowsTerminalRecovery
                )
            }

            guard !frameChangesByToken.isEmpty else { continue }
            plan.workspacePlans[index].diff.frameChanges.removeAll {
                frameChangesByToken[$0.token] != nil
            }
            plan.workspacePlans[index].diff.frameChanges.append(
                contentsOf: frameChangesByToken.values
                    .sorted {
                        if $0.token.pid != $1.token.pid {
                            return $0.token.pid < $1.token.pid
                        }
                        return $0.token.windowId < $1.token.windowId
                    }
            )
        }
    }

    func mergedWorkspaceMonitorRelocations(
        _ existing: [WindowToken: ScheduledWorkspaceMonitorRelocation],
        _ incoming: [WindowToken: ScheduledWorkspaceMonitorRelocation]
    ) -> [WindowToken: ScheduledWorkspaceMonitorRelocation] {
        existing.merging(incoming) { _, incoming in incoming }
    }

    func handleWorkspaceMonitorRelocationTerminalResult(
        _ result: AXFrameApplyResult,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID
    ) {
        guard result.confirmedFrame == nil,
              let failureReason = result.writeResult.failureReason
        else {
            return
        }

        switch failureReason {
        case .cancelled,
             .suppressed:
            return
        default:
            break
        }

        guard let relocation = currentWorkspaceMonitorRelocation(
            matching: result,
            workspaceId: workspaceId,
            monitorId: monitorId
        ) else {
            return
        }
        enqueueRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .workspaceTransition,
                affectedWorkspaceIds: [relocation.workspaceId],
                workspaceMonitorRelocations: [
                    ScheduledWorkspaceMonitorRelocation(
                        relocation: relocation,
                        allowsTerminalRecovery: false
                    )
                ],
                suppressesWindowActivation: true
            )
        )
    }

    private func currentWorkspaceMonitorRelocation(
        matching result: AXFrameApplyResult,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID
    ) -> WorkspaceFloatingRelocation? {
        guard let controller else { return nil }
        let workspaceManager = controller.workspaceManager
        let token = WindowToken(pid: result.pid, windowId: result.windowId)
        guard let entry = workspaceManager.entry(for: token),
              entry.pid == result.pid,
              entry.windowId == result.windowId,
              sameAXWindowIdentity(entry.axRef, result.expectedWindow),
              entry.workspaceId == workspaceId,
              entry.mode == .floating,
              entry.layoutReason == .standard,
              entry.hiddenState == nil,
              !workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId),
              let floatingState = entry.floatingState,
              let monitor = workspaceManager.monitorForWorkspace(workspaceId),
              monitor.id == monitorId,
              workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId,
              entry.desiredState.workspaceId == workspaceId,
              entry.desiredState.monitorId == monitorId,
              entry.desiredState.floatingFrame == result.targetFrame,
              floatingState.referenceMonitorId == monitorId,
              floatingState.lastFrame == result.targetFrame,
              let resolvedFrame = workspaceManager.resolvedFloatingFrame(
                  for: entry.token,
                  preferredMonitor: monitor
              ),
              resolvedFrame == result.targetFrame
        else {
            return nil
        }

        if let observedFrame = entry.observedState.frame,
           observedFrame.approximatelyEqual(
               to: resolvedFrame,
               tolerance: FrameTolerance.frameWrite
           )
        {
            return nil
        }

        return WorkspaceFloatingRelocation(
            workspaceId: entry.workspaceId,
            token: entry.token,
            frame: resolvedFrame
        )
    }

    func applyWorkspaceMonitorRelocationFrameUpdates(
        _ frameUpdates: [AXFrameApplicationTarget],
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        controller: WMController
    ) {
        guard !frameUpdates.isEmpty else { return }
        let axManager = controller.axManager
        for update in frameUpdates where axManager.skyLightLivePosition(for: update.windowId) != nil {
            axManager.forceApplyNextFrame(for: update.windowId)
        }
        axManager.applyFramesParallel(
            frameUpdates,
            terminalObserver: { [weak self] result in
                self?.handleWorkspaceMonitorRelocationTerminalResult(
                    result,
                    workspaceId: workspaceId,
                    monitorId: monitorId
                )
            },
            verify: true
        )
        axManager.clearSkyLightLivePositions()
    }

    func mergeFollowUp(
        into refresh: inout ScheduledRefresh,
        kind: ScheduledRefreshKind,
        reason: RefreshReason,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
        workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation] = [:],
        reconcilesWorkspaceMonitorState: Bool = false,
        suppressesWindowActivation: Bool = false
    ) {
        refresh.followUpRefresh = mergeFollowUpRefresh(
            refresh.followUpRefresh,
            with: .init(
                kind: kind,
                reason: reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                workspaceMonitorRelocations: workspaceMonitorRelocations,
                reconcilesWorkspaceMonitorState: reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: suppressesWindowActivation || reason == .overviewMutation
            )
        )
    }

    func mergeFollowUpRefresh(
        _ existing: FollowUpRefresh?,
        with incoming: FollowUpRefresh?
    ) -> FollowUpRefresh? {
        switch (existing, incoming) {
        case (nil, nil):
            return nil
        case let (value?, nil),
             let (nil, value?):
            return value
        case let (existing?, incoming?):
            let suppressesWindowActivation = existing.suppressesWindowActivation
                || incoming.suppressesWindowActivation
            var merged = incoming
            merged.suppressesWindowActivation = suppressesWindowActivation
            merged.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                existing.affectedWorkspaceIds,
                incoming.affectedWorkspaceIds
            )
            merged.workspaceMonitorRelocations = mergedWorkspaceMonitorRelocations(
                existing.workspaceMonitorRelocations,
                incoming.workspaceMonitorRelocations
            )
            merged.reconcilesWorkspaceMonitorState = existing.reconcilesWorkspaceMonitorState
                || incoming.reconcilesWorkspaceMonitorState
            if existing.kind == .immediateRelayout || incoming.kind == .immediateRelayout {
                if incoming.kind == .immediateRelayout {
                    return merged
                }
                var kept = existing
                kept.suppressesWindowActivation = suppressesWindowActivation
                kept.affectedWorkspaceIds = mergedAffectedWorkspaceIds(
                    existing.affectedWorkspaceIds,
                    incoming.affectedWorkspaceIds
                )
                kept.workspaceMonitorRelocations = merged.workspaceMonitorRelocations
                kept.reconcilesWorkspaceMonitorState = merged.reconcilesWorkspaceMonitorState
                return kept
            }
            return merged
        }
    }

    func mergedAffectedWorkspaceIds(
        _ existing: Set<WorkspaceDescriptor.ID>,
        _ incoming: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        guard !existing.isEmpty, !incoming.isEmpty else { return [] }
        return existing.union(incoming)
    }
}
