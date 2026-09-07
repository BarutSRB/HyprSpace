// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor final class DwindleLayoutHandler {
    struct AnimationSession {
        let workspaceId: WorkspaceDescriptor.ID
        let engineIdentifier: ObjectIdentifier
        let geometry: DwindleAnimationGeometryContext
        let targetFrames: [WindowToken: CGRect]
        let plannedSeq: UInt64
    }

    private struct PendingGroupRevealTransaction {
        let id: UInt64
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        var workspaceId: WorkspaceDescriptor.ID
        let tileId: DwindleTileId
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        var hides: [LayoutDeferredHide]
        let preserveWorkspaceInactive: Bool
        var refreshOverviewOnSuccess: Bool
        var focusOriginOnSuccess: ManagedFocusOrigin?
        var focusPlannedSeq: UInt64?
    }

    weak var controller: WMController?

    var dwindleAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]
    private(set) var animationSessionByDisplay: [CGDirectDisplayID: AnimationSession] = [:]
    private var staleRelayoutWorkspaceByDisplay: [CGDirectDisplayID: WorkspaceDescriptor.ID] = [:]
    private var nextPendingGroupRevealTransactionId: UInt64 = 1
    private var pendingGroupRevealTransactionsByWindowId: [Int: PendingGroupRevealTransaction] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func canAcceptAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot
    ) -> Bool {
        switch disposition {
        case let .clear(engineIdentifier, geometry):
            guard let controller,
                  let engine = controller.dwindleEngine,
                  let currentMonitor = controller.workspaceManager.monitor(byId: monitor.monitorId),
                  let currentGeometry = geometryContext(
                      monitor: currentMonitor,
                      settings: controller.resolvedDwindleSettings(for: currentMonitor)
                  )
            else {
                return false
            }
            return ObjectIdentifier(engine) == engineIdentifier
                && geometry == currentGeometry
                && geometry == geometryContext(monitor: monitor, settings: geometry.settings)
        case let .replace(candidate):
            guard let controller,
                  let engine = controller.dwindleEngine,
                  let currentMonitor = controller.workspaceManager.monitor(byId: monitor.monitorId),
                  let currentGeometry = geometryContext(
                      monitor: currentMonitor,
                      settings: controller.resolvedDwindleSettings(for: currentMonitor)
                  ),
                  candidate.workspaceId == workspaceId,
                  candidate.engineIdentifier == ObjectIdentifier(engine),
                  candidate.geometry == currentGeometry,
                  candidate.geometry == geometryContext(monitor: monitor, settings: candidate.geometry.settings)
            else {
                return false
            }
            return true
        }
    }

    func acceptAnimationTarget(
        _ disposition: DwindleAnimationTargetDisposition,
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        plannedSeq: UInt64
    ) -> Set<CGDirectDisplayID> {
        clearStaleRelayoutState(for: workspaceId)
        switch disposition {
        case .clear:
            return removeAnimationState(for: workspaceId)
        case let .replace(candidate):
            guard controller?.workspaceManager.activeWorkspaceOrFirst(
                on: candidate.geometry.monitorId
            )?.id == workspaceId else {
                controller?.dwindleEngine?.cancelAnimations(in: workspaceId)
                return removeAnimationState(for: workspaceId)
            }
            var detachedDisplayIds: Set<CGDirectDisplayID> = []
            let previousDisplayIds = animationSessionByDisplay.compactMap { registeredDisplayId, session in
                session.workspaceId == workspaceId && registeredDisplayId != displayId
                    ? registeredDisplayId
                    : nil
            }
            for registeredDisplayId in previousDisplayIds {
                animationSessionByDisplay.removeValue(forKey: registeredDisplayId)
                if dwindleAnimationByDisplay[registeredDisplayId]?.0 == workspaceId {
                    dwindleAnimationByDisplay.removeValue(forKey: registeredDisplayId)
                }
                detachedDisplayIds.insert(registeredDisplayId)
            }
            animationSessionByDisplay[displayId] = AnimationSession(
                workspaceId: workspaceId,
                engineIdentifier: candidate.engineIdentifier,
                geometry: candidate.geometry,
                targetFrames: candidate.targetFrames,
                plannedSeq: plannedSeq
            )
            return detachedDisplayIds
        }
    }

    func suspendStaleAnimation(
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) -> Bool {
        animationSessionByDisplay.removeValue(forKey: displayId)
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            dwindleAnimationByDisplay.removeValue(forKey: displayId)
        }
        let wasAlreadyStale = staleRelayoutWorkspaceByDisplay.values.contains(workspaceId)
        staleRelayoutWorkspaceByDisplay[displayId] = workspaceId
        return !wasAlreadyStale
    }

    func removeAnimationState(for displayId: CGDirectDisplayID) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds: Set<WorkspaceDescriptor.ID> = []
        if let workspaceId = animationSessionByDisplay.removeValue(forKey: displayId)?.workspaceId {
            workspaceIds.insert(workspaceId)
        }
        if let workspaceId = dwindleAnimationByDisplay.removeValue(forKey: displayId)?.0 {
            workspaceIds.insert(workspaceId)
        }
        if let workspaceId = staleRelayoutWorkspaceByDisplay.removeValue(forKey: displayId) {
            workspaceIds.insert(workspaceId)
        }
        return workspaceIds
    }

    func removeAllAnimationState() -> (workspaceIds: Set<WorkspaceDescriptor.ID>, displayIds: Set<CGDirectDisplayID>) {
        let workspaceIds = Set(animationSessionByDisplay.values.map(\.workspaceId))
            .union(dwindleAnimationByDisplay.values.map(\.0))
            .union(staleRelayoutWorkspaceByDisplay.values)
        let displayIds = Set(animationSessionByDisplay.keys)
            .union(dwindleAnimationByDisplay.keys)
            .union(staleRelayoutWorkspaceByDisplay.keys)
        animationSessionByDisplay.removeAll(keepingCapacity: true)
        dwindleAnimationByDisplay.removeAll(keepingCapacity: true)
        staleRelayoutWorkspaceByDisplay.removeAll(keepingCapacity: true)
        return (workspaceIds, displayIds)
    }

    private func removeAnimationState(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> Set<CGDirectDisplayID> {
        var displayIds: Set<CGDirectDisplayID> = []
        let sessionDisplayIds = animationSessionByDisplay.compactMap { displayId, session in
            session.workspaceId == workspaceId ? displayId : nil
        }
        for displayId in sessionDisplayIds {
            animationSessionByDisplay.removeValue(forKey: displayId)
            displayIds.insert(displayId)
        }
        let registrationDisplayIds = dwindleAnimationByDisplay.compactMap { displayId, registration in
            registration.0 == workspaceId ? displayId : nil
        }
        for displayId in registrationDisplayIds {
            dwindleAnimationByDisplay.removeValue(forKey: displayId)
            displayIds.insert(displayId)
        }
        clearStaleRelayoutState(for: workspaceId)
        return displayIds
    }

    private func clearStaleRelayoutState(for workspaceId: WorkspaceDescriptor.ID) {
        let displayIds = staleRelayoutWorkspaceByDisplay.compactMap { displayId, staleWorkspaceId in
            staleWorkspaceId == workspaceId ? displayId : nil
        }
        for displayId in displayIds {
            staleRelayoutWorkspaceByDisplay.removeValue(forKey: displayId)
        }
    }

    func registerDwindleAnimation(
        _ workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        on displayId: CGDirectDisplayID
    ) -> Bool {
        guard animationSessionByDisplay[displayId]?.workspaceId == workspaceId else {
            return false
        }
        if dwindleAnimationByDisplay[displayId]?.0 == workspaceId {
            return false
        }
        if let displacedWorkspaceId = dwindleAnimationByDisplay[displayId]?.0 {
            controller?.dwindleEngine?.cancelAnimations(in: displacedWorkspaceId)
        }
        dwindleAnimationByDisplay[displayId] = (workspaceId, monitor)
        return true
    }

    func hasDwindleAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        dwindleAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    func animationDisplayIds(for workspaceId: WorkspaceDescriptor.ID) -> Set<CGDirectDisplayID> {
        let sessionDisplayIds = animationSessionByDisplay.compactMap { displayId, session in
            session.workspaceId == workspaceId ? displayId : nil
        }
        let registrationDisplayIds = dwindleAnimationByDisplay.compactMap { displayId, registration in
            registration.0 == workspaceId ? displayId : nil
        }
        return Set(sessionDisplayIds).union(registrationDisplayIds)
    }

    private func isAnimationSessionCurrent(
        _ session: AnimationSession,
        displayId: CGDirectDisplayID,
        engine: DwindleLayoutEngine,
        snapshot: DwindleWorkspaceSnapshot
    ) -> Bool {
        guard let controller,
              session.workspaceId == snapshot.workspaceId,
              session.geometry.displayId == displayId,
              session.engineIdentifier == ObjectIdentifier(engine),
              session.geometry == geometryContext(
                  monitor: snapshot.monitor,
                  settings: snapshot.settings
              )
        else {
            return false
        }
        return session.plannedSeq == 0
            || controller.workspaceManager.isSeqCurrent(
                session.plannedSeq,
                for: snapshot.workspaceId,
                domains: .layoutCommit
            )
    }

    @discardableResult
    func applyFramesOnDemand(workspaceId wsId: WorkspaceDescriptor.ID, monitor: Monitor) -> Bool {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.dwindleEngine,
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: wsId,
                  monitor: monitor,
                  resolveConstraints: false,
                  isActiveWorkspace: activeWorkspaceId == wsId
              )
        else {
            return false
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine
        )
        return controller.layoutRefreshController.executeLayoutPlan(plan)
    }

    func refreshEngineConstraints(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let refreshInput = controller.layoutRefreshController.buildRefreshInput(
                  workspaceId: workspaceId,
                  monitor: monitor,
                  resolveConstraints: true,
                  isActiveWorkspace: activeWorkspaceId == workspaceId
              )
        else {
            return
        }

        controller.workspaceManager.withEngineMutationScope {
            for window in refreshInput.windows {
                engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
            }
        }
    }

    func tickDwindleAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, animationMonitor) = dwindleAnimationByDisplay[displayId] else { return }
        guard let controller else {
            _ = removeAnimationState(for: displayId)
            return
        }
        guard let engine = controller.dwindleEngine else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitor(byId: animationMonitor.id) else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            return
        }

        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: false,
            isActiveWorkspace: true
        ) else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return
        }
        guard let session = animationSessionByDisplay[displayId],
              isAnimationSessionCurrent(
                  session,
                  displayId: displayId,
                  engine: engine,
                  snapshot: snapshot
              )
        else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return
        }

        engine.tickAnimations(at: targetTime, in: wsId)
        let animationsOngoing = engine.hasActiveAnimations(in: wsId, at: targetTime)
        let plan = buildAnimationPlan(
            snapshot: snapshot,
            engine: engine,
            session: session,
            targetTime: targetTime,
            isAnimationTick: animationsOngoing
        )
        let didExecute = controller.layoutRefreshController.executeLayoutPlan(plan)
        guard didExecute else {
            controller.layoutRefreshController.suspendStaleDwindleAnimation(
                workspaceId: wsId,
                displayId: displayId
            )
            return
        }

        if !animationsOngoing {
            controller.layoutRefreshController.stopDwindleAnimation(for: displayId)
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }

    func layoutWithDwindleEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .dwindle else { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: true,
                isActiveWorkspace: isActiveWorkspace
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine
                )
            )
        }

        return plans
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId, source: source)
    }

    // MARK: - Layout Capability Commands

    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        var didMove = false
        withDwindleContext { engine, wsId in
            if focusGroupMember(
                direction: direction,
                wraps: false,
                engine: engine,
                workspaceId: wsId
            ) {
                didMove = true
                return
            }
            let previousSelection = engine.selectedNode(in: wsId)
            guard let token = engine.moveFocus(direction: direction, in: wsId) else { return }
            guard !controller.isManagedWindowSuppressedByMacOSHide(token) else {
                engine.setSelectedNode(previousSelection, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
                return
            }
            didMove = true
            if controller.workspaceManager.hiddenState(for: token) != nil {
                commitGroupSelection(token, workspaceId: wsId, focusAfterLayout: true)
                return
            }
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: nil,
                    rememberedFocusToken: token,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            controller.focusWindow(token)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return didMove
    }

    func wrapGroupFocus(direction: Direction) -> Bool {
        var didMove = false
        withDwindleContext { engine, workspaceId in
            didMove = focusGroupMember(
                direction: direction,
                wraps: true,
                engine: engine,
                workspaceId: workspaceId
            )
        }
        return didMove
    }

    @discardableResult
    func activateWindow(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic,
        layoutRefresh: Bool = true,
        focusAfterLayout: Bool = true
    ) -> DwindleWindowActivationOutcome {
        guard let controller,
              let engine = controller.dwindleEngine,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              !controller.isManagedWindowSuppressedByMacOSHide(token)
        else {
            return .missing
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(token, in: workspaceId)
        }
        guard outcome != .missing else { return .missing }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )

        let requiresLayout = outcome == .activated || controller.workspaceManager.hiddenState(for: token) != nil
        if requiresLayout, layoutRefresh {
            let postLayout: LayoutRefreshController.PostLayoutAction = { [weak self] in
                self?.completeGroupSelectionAfterReveal(
                    token,
                    workspaceId: workspaceId,
                    focusAfterLayout: focusAfterLayout,
                    focusOrigin: origin
                )
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [workspaceId],
                postLayout: postLayout
            )
        } else {
            if focusAfterLayout {
                controller.focusWindow(token, origin: origin)
            }
            if layoutRefresh {
                controller.surfaceReconciler.noteWorldChanged()
            }
        }
        return outcome
    }

    func moveWindow(direction: Direction) -> WindowMoveOutcome {
        var outcome = WindowMoveOutcome.blocked
        withDwindleContext { engine, workspaceId in
            guard let token = engine.projectedActiveToken(in: workspaceId) else { return }
            let sourceIsGrouped: Bool
            if let snapshot = engine.tileSnapshot(for: token, in: workspaceId) {
                sourceIsGrouped = snapshot.isGrouped
            } else {
                return
            }
            guard groupMembershipMutationIsAllowed(
                for: token,
                engine: engine,
                workspaceId: workspaceId,
                requiresAllMembers: !sourceIsGrouped
            )
            else {
                return
            }

            let moved: Bool
            if sourceIsGrouped {
                moved = engine.ungroupWindow(token, direction: direction, in: workspaceId)
            } else {
                guard engine.tileCount(in: workspaceId) == 1
                    || engine.tileFrame(for: token, in: workspaceId) != nil
                else {
                    return
                }
                guard let neighbor = engine.findGeometricNeighbor(
                    from: token,
                    direction: direction,
                    in: workspaceId
                ) else {
                    outcome = .atWorkspaceEdge
                    return
                }
                guard groupMembershipMutationIsAllowed(
                    for: neighbor,
                    engine: engine,
                    workspaceId: workspaceId
                ) else {
                    return
                }
                moved = engine.groupWindow(token, into: neighbor, in: workspaceId)
            }
            guard moved else {
                return
            }

            outcome = .movedWithinWorkspace
            recordLayoutOperation(.groupMembershipChanged(token: token), in: workspaceId)
            commitGroupSelection(token, workspaceId: workspaceId, focusAfterLayout: true)
        }
        return outcome
    }

    @discardableResult
    func moveGroupMember(direction: Direction) -> Bool {
        var didMove = false
        withDwindleContext { engine, workspaceId in
            guard let token = engine.projectedActiveToken(in: workspaceId),
                  let destinationToken = groupMemberReorderDestination(
                      direction: direction,
                      engine: engine,
                      workspaceId: workspaceId
                  ),
                  groupMembershipMutationIsAllowed(
                      for: token,
                      engine: engine,
                      workspaceId: workspaceId,
                      requiresAllMembers: false
                  ),
                  groupMemberActivationIsAllowed(
                      destinationToken,
                      workspaceId: workspaceId
                  ),
                  engine.moveGroupMember(token, direction: direction, in: workspaceId)
            else {
                return
            }

            didMove = true
            recordLayoutOperation(.groupMemberMoved(token: token), in: workspaceId)
            updateRememberedGroupMember(token, workspaceId: workspaceId)
            controller?.surfaceReconciler.noteWorldChanged()
        }
        return didMove
    }

    private func groupMemberReorderDestination(
        direction: Direction,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let offset = groupMemberOffset(for: direction),
              let token = engine.projectedActiveToken(in: workspaceId),
              let snapshot = engine.tileSnapshot(for: token, in: workspaceId),
              let activeIndex = snapshot.members.firstIndex(where: { $0.token == token })
        else {
            return nil
        }
        let visibleMembers = snapshot.members.filter {
            groupMemberActivationIsAllowed($0.token, workspaceId: workspaceId)
        }
        guard let visibleIndex = visibleMembers.firstIndex(
            where: { $0.token == snapshot.members[activeIndex].token }
        ), visibleMembers.indices.contains(visibleIndex + offset)
        else {
            return nil
        }
        return visibleMembers[visibleIndex + offset].token
    }

    private func focusGroupMember(
        direction: Direction,
        wraps: Bool,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let offset = groupMemberOffset(for: direction),
              let activeToken = engine.projectedActiveToken(in: workspaceId),
              let snapshot = engine.tileSnapshot(for: activeToken, in: workspaceId),
              let activeIndex = snapshot.members.firstIndex(where: { $0.token == activeToken }),
              snapshot.members.count > 1
        else {
            return false
        }

        for distance in 1 ..< snapshot.members.count {
            let candidateIndex = activeIndex + offset * distance
            let index: Int
            if wraps {
                index = (
                    candidateIndex % snapshot.members.count + snapshot.members.count
                ) % snapshot.members.count
            } else {
                guard snapshot.members.indices.contains(candidateIndex) else { break }
                index = candidateIndex
            }

            let token = snapshot.members[index].token
            guard groupMemberActivationIsAllowed(token, workspaceId: workspaceId) else {
                continue
            }
            guard engine.activateWindowOutcome(token, in: workspaceId) == .activated else {
                return false
            }

            recordLayoutOperation(.tabActivated(token: token), in: workspaceId)
            commitGroupSelection(token, workspaceId: workspaceId, focusAfterLayout: true)
            return true
        }
        return false
    }

    private func groupMemberOffset(for direction: Direction) -> Int? {
        switch direction {
        case .up:
            -1
        case .down:
            1
        case .left,
             .right:
            nil
        }
    }

    func desiredTabRailInfos() -> [TabRailInfo] {
        guard let controller, let engine = controller.dwindleEngine else { return [] }

        var infos: [TabRailInfo] = []
        for monitor in controller.workspaceManager.monitors {
            guard let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id),
                  controller.workspaceManager.activeLayoutKind(for: workspace.id) == .dwindle
            else {
                continue
            }

            let presentationTime = controller.animationClock.now()
            let scale = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor).scale
            for snapshot in engine.groupedTileSnapshots(in: workspace.id) {
                let presentedFrame = presentedTileFrame(
                    tileFrame: snapshot.tileFrame,
                    contentFrame: snapshot.contentFrame,
                    activeToken: snapshot.activeToken,
                    engine: engine,
                    workspaceId: workspace.id,
                    at: presentationTime,
                    scale: scale
                )
                let frame = presentedFrame ?? snapshot.tileFrame ?? .zero
                let visibleFrame = presentedFrame?.intersection(monitor.visibleFrame) ?? .null

                var tabs: [TabRailTabInfo] = []
                tabs.reserveCapacity(snapshot.members.count)
                for (index, member) in snapshot.members.enumerated() {
                    let entry = controller.workspaceManager.entry(for: member.token)
                    let appName: String?
                    if let entry, controller.appInfoCache.hasCachedInfo(for: entry.pid) {
                        appName = controller.appInfoCache.name(for: entry.pid)
                    } else {
                        appName = nil
                    }
                    let title = entry?.managedReplacementMetadata?.title
                        ?? entry.flatMap { entry in
                            UInt32(exactly: entry.windowId).flatMap {
                                AXWindowService.titlePreferFast(windowId: $0)
                            }
                        }
                    tabs.append(
                        TabRailTabInfo(
                            visualIndex: index,
                            token: member.token,
                            windowId: entry?.windowId,
                            appName: appName,
                            title: title,
                            isActive: index == snapshot.activeIndex
                        )
                    )
                }

                infos.append(
                    TabRailInfo(
                        workspaceId: workspace.id,
                        owner: .dwindleTile(snapshot.id),
                        plannedSeq: controller.workspaceManager.worldSeq,
                        tileFrame: frame,
                        visibleTileFrame: visibleFrame,
                        tabCount: tabs.count,
                        activeVisualIndex: snapshot.activeIndex,
                        activeWindowId: controller.workspaceManager.entry(for: snapshot.activeToken)?.windowId,
                        tabs: tabs
                    )
                )
            }
        }
        return infos
    }

    func dwindleTabRailGeometryCommands(
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        monitor: LayoutMonitorSnapshot,
        targetTime: TimeInterval
    ) -> [TabRailGeometryCommand] {
        var commands: [TabRailGeometryCommand] = []
        engine.forEachGroupedTileGeometry(in: workspaceId) { geometry in
            let key = TabRailKey(workspaceId: workspaceId, owner: .dwindleTile(geometry.id))
            guard let frame = presentedTileFrame(
                tileFrame: geometry.tileFrame,
                contentFrame: geometry.contentFrame,
                activeToken: geometry.activeToken,
                engine: engine,
                workspaceId: workspaceId,
                at: targetTime,
                scale: monitor.scale
            ) else {
                commands.append(
                    TabRailGeometryCommand(
                        key: key,
                        tileFrame: .zero,
                        visibleTileFrame: .null
                    )
                )
                return
            }
            commands.append(
                TabRailGeometryCommand(
                    key: key,
                    tileFrame: frame,
                    visibleTileFrame: frame.intersection(monitor.visibleFrame)
                )
            )
        }
        return commands
    }

    func presentedTileFrame(
        tileFrame: CGRect?,
        contentFrame: CGRect?,
        activeToken: WindowToken,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        at targetTime: TimeInterval,
        scale: CGFloat
    ) -> CGRect? {
        guard let tileFrame,
              let contentFrame,
              let presentedContentFrame = engine.presentedFrame(
                  for: activeToken,
                  in: workspaceId,
                  at: targetTime
              )
        else {
            return nil
        }
        let left = max(0, contentFrame.minX - tileFrame.minX)
        let right = max(0, tileFrame.maxX - contentFrame.maxX)
        let bottom = max(0, contentFrame.minY - tileFrame.minY)
        let top = max(0, tileFrame.maxY - contentFrame.maxY)
        let frame = CGRect(
            x: presentedContentFrame.minX - left,
            y: presentedContentFrame.minY - bottom,
            width: presentedContentFrame.width + left + right,
            height: presentedContentFrame.height + bottom + top
        ).roundedToPhysicalPixels(scale: max(scale, 1))
        guard !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return frame
    }

    func selectGroupMember(
        info: TabRailInfo,
        visualIndex: Int,
        expectedToken: WindowToken?
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              case let .dwindleTile(tileId) = info.owner,
              controller.workspaceManager.activeLayoutKind(for: info.workspaceId) == .dwindle,
              controller.workspaceManager.isSeqCurrent(
                  info.plannedSeq,
                  for: info.workspaceId,
                  domains: .layoutCommit
              ),
              info.tabs.indices.contains(visualIndex),
              let token = expectedToken ?? info.tabs[visualIndex].token,
              let snapshot = engine.tileSnapshot(for: token, in: info.workspaceId),
              snapshot.id == tileId,
              snapshot.members.contains(where: { $0.token == token }),
              groupMemberActivationIsAllowed(token, workspaceId: info.workspaceId)
        else {
            return
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(token, in: info.workspaceId)
        }
        guard outcome != .missing else { return }
        if outcome == .activated {
            recordLayoutOperation(.tabActivated(token: token), in: info.workspaceId, source: .mouse)
            commitGroupSelection(
                token,
                workspaceId: info.workspaceId,
                focusAfterLayout: true,
                focusOrigin: .pointerHover
            )
        } else {
            updateRememberedGroupMember(token, workspaceId: info.workspaceId)
            controller.focusWindow(token, origin: .pointerHover)
            controller.surfaceReconciler.noteWorldChanged()
        }
    }

    private func groupMembershipMutationIsAllowed(
        for token: WindowToken,
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        requiresAllMembers: Bool = true
    ) -> Bool {
        guard let snapshot = engine.tileSnapshot(for: token, in: workspaceId)
        else {
            return false
        }
        guard requiresAllMembers else {
            return groupMemberActivationIsAllowed(token, workspaceId: workspaceId)
        }
        return snapshot.members.allSatisfy { member in
            groupMemberActivationIsAllowed(member.token, workspaceId: workspaceId)
        }
    }

    private func groupMemberActivationIsAllowed(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }
        return entry.workspaceId == workspaceId
            && entry.mode == .tiling
            && entry.layoutReason == .standard
            && !controller.isManagedWindowSuppressedByMacOSHide(token)
            && !controller.isManagedWindowSuspendedForNativeFullscreen(token)
    }

    private func commitGroupSelection(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterLayout: Bool,
        focusOrigin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) {
        guard let controller else { return }
        updateRememberedGroupMember(token, workspaceId: workspaceId)
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [workspaceId]
        ) { [weak self] in
            self?.completeGroupSelectionAfterReveal(
                token,
                workspaceId: workspaceId,
                focusAfterLayout: focusAfterLayout,
                focusOrigin: focusOrigin
            )
        }
    }

    private func completeGroupSelectionAfterReveal(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterLayout: Bool,
        focusOrigin: ManagedFocusOrigin
    ) {
        guard let controller else { return }
        if deferGroupSelectionCompletion(
            token,
            workspaceId: workspaceId,
            focusAfterReveal: focusAfterLayout,
            focusOrigin: focusOrigin
        ) {
            return
        }
        guard controller.dwindleEngine?.tileSnapshot(for: token, in: workspaceId)?.activeToken == token
        else {
            return
        }
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: [workspaceId],
            selectedToken: token
        )
        if focusAfterLayout {
            controller.focusWindow(token, origin: focusOrigin)
        }
    }

    func beginPendingGroupRevealTransaction(
        for entry: WindowState,
        targetFrame: CGRect,
        monitor: Monitor,
        hides: [LayoutDeferredHide],
        preserveWorkspaceInactive: Bool
    ) -> UInt64? {
        guard let controller,
              let engine = controller.dwindleEngine,
              let tile = engine.tileSnapshot(for: entry.token, in: entry.workspaceId),
              tile.activeToken == entry.token,
              !hides.isEmpty
        else {
            return nil
        }

        let transactionId = nextPendingGroupRevealTransactionId
        nextPendingGroupRevealTransactionId &+= 1
        let existingTransaction = pendingGroupRevealTransactionsByWindowId[entry.windowId]
        pendingGroupRevealTransactionsByWindowId[entry.windowId] = .init(
            id: transactionId,
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            tileId: tile.id,
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hides: hides,
            preserveWorkspaceInactive: preserveWorkspaceInactive,
            refreshOverviewOnSuccess: existingTransaction?.refreshOverviewOnSuccess ?? false,
            focusOriginOnSuccess: existingTransaction?.focusOriginOnSuccess,
            focusPlannedSeq: existingTransaction?.focusPlannedSeq
        )
        return transactionId
    }

    func deferGroupSelectionCompletion(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterReveal: Bool,
        focusOrigin: ManagedFocusOrigin
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              var transaction = pendingGroupRevealTransactionsByWindowId[entry.windowId],
              transaction.token == token,
              transaction.workspaceId == workspaceId
        else {
            return false
        }

        transaction.refreshOverviewOnSuccess = true
        if focusAfterReveal {
            transaction.focusOriginOnSuccess = transaction.focusOriginOnSuccess?
                .merged(with: focusOrigin) ?? focusOrigin
            transaction.focusPlannedSeq = controller.workspaceManager.worldSeq
        }
        pendingGroupRevealTransactionsByWindowId[entry.windowId] = transaction
        return true
    }

    func completePendingGroupRevealTransaction(
        with result: AXFrameApplyResult,
        transactionId: UInt64
    ) {
        guard let transactionKey = pendingGroupRevealTransactionKey(
            for: result.windowId,
            transactionId: transactionId
        ),
            let transaction = pendingGroupRevealTransactionsByWindowId.removeValue(
                forKey: transactionKey
            ),
            transaction.targetFrame.approximatelyEqual(
                to: result.targetFrame,
                tolerance: FrameTolerance.frameWrite
            )
        else {
            return
        }

        guard result.writeResult.isVerifiedSuccess else {
            rollbackPendingGroupReveal(transaction)
            return
        }
        finalizePendingGroupReveal(transaction)
    }

    func pendingGroupRevealTransactionId(for windowId: Int) -> UInt64? {
        pendingGroupRevealTransactionsByWindowId[windowId]?.id
    }

    func resetPendingGroupReveals() {
        pendingGroupRevealTransactionsByWindowId.removeAll()
        nextPendingGroupRevealTransactionId = 1
    }

    func cancelPendingGroupReveals(pid: pid_t) {
        pendingGroupRevealTransactionsByWindowId = pendingGroupRevealTransactionsByWindowId.filter {
            $0.value.pid != pid
        }
    }

    func currentPendingGroupRevealFocusTransactionIds(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Set<UInt64> {
        guard let controller else { return [] }
        var transactionIds: Set<UInt64> = []
        for transaction in pendingGroupRevealTransactionsByWindowId.values
            where transaction.workspaceId == workspaceId
        {
            guard let plannedSeq = transaction.focusPlannedSeq,
                  controller.workspaceManager.isSeqCurrent(
                      plannedSeq,
                      for: workspaceId,
                      domains: .focusCommit
                  )
            else {
                continue
            }
            transactionIds.insert(transaction.id)
        }
        return transactionIds
    }

    func currentPendingGroupRevealFocusTransactionIds(for token: WindowToken) -> Set<UInt64> {
        guard let workspaceId = controller?.workspaceManager.entry(for: token)?.workspaceId else { return [] }
        return currentPendingGroupRevealFocusTransactionIds(in: workspaceId)
    }

    func rekeyPendingGroupRevealTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        entry: WindowState,
        rebasingFocusTransactionIds: Set<UInt64>
    ) {
        guard oldToken != newToken else { return }
        let keys = Array(pendingGroupRevealTransactionsByWindowId.keys)
        for key in keys {
            guard var transaction = pendingGroupRevealTransactionsByWindowId.removeValue(forKey: key)
            else {
                continue
            }
            let transactionKey: Int
            if transaction.token == oldToken {
                transaction.token = newToken
                transaction.pid = entry.pid
                transaction.windowId = entry.windowId
                transaction.workspaceId = entry.workspaceId
                transactionKey = entry.windowId
            } else {
                transactionKey = key
            }
            transaction.hides = transaction.hides.map { change in
                LayoutDeferredHide(
                    token: change.token == oldToken ? newToken : change.token,
                    side: change.side,
                    revealToken: change.revealToken == oldToken ? newToken : change.revealToken
                )
            }
            if rebasingFocusTransactionIds.contains(transaction.id), let controller {
                transaction.focusPlannedSeq = controller.workspaceManager.worldSeq
            }
            if let existing = pendingGroupRevealTransactionsByWindowId[transactionKey],
               existing.id > transaction.id
            {
                continue
            }
            pendingGroupRevealTransactionsByWindowId[transactionKey] = transaction
        }
    }

    private func pendingGroupRevealTransactionKey(
        for windowId: Int,
        transactionId: UInt64
    ) -> Int? {
        if pendingGroupRevealTransactionsByWindowId[windowId]?.id == transactionId {
            return windowId
        }
        return pendingGroupRevealTransactionsByWindowId.first {
            $0.value.id == transactionId
        }?.key
    }

    private func finalizePendingGroupReveal(
        _ transaction: PendingGroupRevealTransaction
    ) {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: transaction.workspaceId) == .dwindle,
              controller.workspaceManager.visibleWorkspaceIds().contains(transaction.workspaceId),
              let engine = controller.dwindleEngine,
              let revealTile = engine.tileSnapshot(for: transaction.token, in: transaction.workspaceId),
              revealTile.id == transaction.tileId,
              revealTile.activeToken == transaction.token,
              let revealEntry = controller.workspaceManager.entry(for: transaction.token),
              revealEntry.workspaceId == transaction.workspaceId,
              revealEntry.layoutReason == .standard,
              !controller.workspaceManager.isAppHidden(pid: revealEntry.pid)
        else {
            return
        }

        let shouldFocusAfterReveal = transaction.focusOriginOnSuccess != nil
            && transaction.focusPlannedSeq.map {
                controller.workspaceManager.isSeqCurrent(
                    $0,
                    for: transaction.workspaceId,
                    domains: .focusCommit
                )
            } == true
        var hiddenEntries: [(entry: WindowState, side: HideSide)] = []
        hiddenEntries.reserveCapacity(transaction.hides.count)
        for change in transaction.hides {
            guard engine.isInactiveGroupMember(change.token, in: transaction.workspaceId),
                  engine.tileSnapshot(for: change.token, in: transaction.workspaceId)?.id == revealTile.id,
                  let entry = controller.workspaceManager.entry(for: change.token),
                  entry.workspaceId == transaction.workspaceId,
                  entry.layoutReason != .nativeFullscreen,
                  !controller.workspaceManager.isAppHidden(pid: entry.pid)
            else {
                continue
            }
            hiddenEntries.append((entry, change.side))
        }

        let monitor = controller.workspaceManager.monitor(byId: transaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: transaction.workspaceId)
            ?? Monitor.fallback()
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: transaction.token)
            controller.layoutRefreshController.applyLayoutTransientHides(
                hiddenEntries,
                monitor: monitor,
                isAnimationTick: false,
                preserveWorkspaceInactive: transaction.preserveWorkspaceInactive
            )
        }
        controller.axManager.clearParkPending(for: transaction.windowId, pid: transaction.pid)
        controller.surfaceReconciler.noteWorldChanged()
        if transaction.refreshOverviewOnSuccess {
            controller.windowActionHandler.refreshOverviewProjection(
                affectedWorkspaceIds: [transaction.workspaceId],
                selectedToken: transaction.token
            )
        }
        if shouldFocusAfterReveal, let focusOrigin = transaction.focusOriginOnSuccess {
            controller.focusWindow(transaction.token, origin: focusOrigin)
        }
    }

    private func rollbackPendingGroupReveal(
        _ transaction: PendingGroupRevealTransaction
    ) {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: transaction.workspaceId) == .dwindle,
              controller.workspaceManager.visibleWorkspaceIds().contains(transaction.workspaceId),
              let engine = controller.dwindleEngine,
              let revealTile = engine.tileSnapshot(for: transaction.token, in: transaction.workspaceId),
              revealTile.id == transaction.tileId,
              revealTile.activeToken == transaction.token,
              let rollbackToken = transaction.hides.lazy.map(\.token).first(where: {
                  engine.tileSnapshot(for: $0, in: transaction.workspaceId)?.id == transaction.tileId
                      && controller.workspaceManager.entry(for: $0)?.layoutReason == .standard
                      && !controller.workspaceManager.isAppHidden($0)
              })
        else {
            return
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(rollbackToken, in: transaction.workspaceId)
        }
        guard outcome == .activated else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: transaction.workspaceId,
                viewportState: nil,
                rememberedFocusToken: rollbackToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: [transaction.workspaceId],
            selectedToken: rollbackToken
        )
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [transaction.workspaceId]
        )
    }

    private func updateRememberedGroupMember(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: token,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    func swapWindow(direction: Direction) -> WindowMoveOutcome {
        guard let controller else { return .blocked }
        var outcome = WindowMoveOutcome.blocked
        withDwindleContext { engine, wsId in
            outcome = engine.swapWindowOutcome(direction: direction, in: wsId)
            guard outcome == .movedWithinWorkspace else { return }
            recordLayoutOperation(.windowsSwapped, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return outcome
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let token = engine.toggleFullscreen(in: wsId) {
                recordLayoutOperation(.fullscreenToggled(token: token), in: wsId)
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.cycleSplitRatio(forward: forward, in: wsId) {
                recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.balanceSizes(in: wsId) {
                recordLayoutOperation(.sizesBalanced, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    // MARK: - Layout Engine Configuration

    func enableDwindleLayout() {
        guard let controller else { return }
        let engine = DwindleLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        innerGap: CGFloat? = nil
    ) {
        guard let controller, let engine = controller.dwindleEngine else { return }
        controller.workspaceManager.withEngineMutationScope {
            if let v = smartSplit { engine.settings.smartSplit = v }
            if let v = defaultSplitRatio { engine.settings.defaultSplitRatio = v }
            if let v = splitWidthMultiplier { engine.settings.splitWidthMultiplier = v }
            if let v = singleWindowFit { engine.settings.singleWindowFit = v }
            if let v = innerGap { engine.settings.innerGap = v }
        }
        controller.workspaceManager.invalidateAllLayouts()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func withDwindleContext(
        perform: (DwindleLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let wsId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else { return }
        controller.workspaceManager.withEngineMutationScope {
            applyResolvedSettings(controller.resolvedDwindleSettings(for: monitor), to: engine)
            perform(engine, wsId)
        }
    }

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        isActiveWorkspace: Bool
    ) -> DwindleWorkspaceSnapshot? {
        guard let controller else { return nil }

        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: resolveConstraints,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }
        return DwindleWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            excludedTokens: refreshInput.excludedTokens,
            plannedSeq: refreshInput.plannedSeq,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            preferredHideSide: controller.layoutRefreshController.preferredHideSide(for: monitor),
            settings: controller.resolvedDwindleSettings(for: monitor, scale: refreshInput.monitor.scale),
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)
        engine.setExcludedTokens(
            snapshot.excludedTokens,
            authoritativeTokens: Set(snapshot.windows.lazy.map(\.token)),
            in: snapshot.workspaceId
        )

        let now = controller?.animationClock.now() ?? CACurrentMediaTime()
        var previousTargetFrames = engine.currentFrames(in: snapshot.workspaceId)
        var oldFrames = engine.presentedFrames(in: snapshot.workspaceId, at: now)
        engine.consumePendingMovementFrameSeeds(
            in: snapshot.workspaceId,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargetFrames
        )
        let windowTokens = snapshot.windows.map(\.token)
        restoreInitialDwindlePlacementsIfNeeded(
            windowTokens: windowTokens,
            engine: engine,
            workspaceId: snapshot.workspaceId
        )
        let removedTokens = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken,
            bootstrapScreen: snapshot.monitor.workingFrame,
            bootstrapBorderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            bootstrapFullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let newFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            borderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )
        if !removedTokens.isEmpty {
            controller?.windowActionHandler.refreshOverviewProjection(
                affectedWorkspaceIds: [snapshot.workspaceId],
                selectedToken: engine.projectedActiveToken(in: snapshot.workspaceId)
            )
        }

        let rememberedFocusToken = engine.projectedActiveToken(in: snapshot.workspaceId)

        engine.animateWindowMovements(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargetFrames,
            newFrames: newFrames,
            in: snapshot.workspaceId,
            startTime: now,
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        )

        let animationsActive = snapshot.isActiveWorkspace
            && engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        if !snapshot.isActiveWorkspace {
            engine.cancelAnimations(in: snapshot.workspaceId)
        }
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: newFrames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: true,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? [],
            animationTime: animationsActive ? now : nil
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startDwindleAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []
        let targetDisposition: DwindleAnimationTargetDisposition = if animationsActive {
            .replace(
                DwindleAnimationTargetCandidate(
                    workspaceId: snapshot.workspaceId,
                    engineIdentifier: ObjectIdentifier(engine),
                    geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings),
                    targetFrames: newFrames
                )
            )
        } else {
            .clear(
                engineIdentifier: ObjectIdentifier(engine),
                geometry: geometryContext(monitor: snapshot.monitor, settings: snapshot.settings)
            )
        }

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            dwindleRestorePlacements: engine.persistedPlacements(in: snapshot.workspaceId),
            animationDirectives: directives,
            dwindleAnimationTargetDisposition: targetDisposition,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func restoreInitialDwindlePlacementsIfNeeded(
        windowTokens: [WindowToken],
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        var placements: [WindowToken: PersistedDwindlePlacement] = [:]
        for token in windowTokens {
            if let placement = controller.workspaceManager.restoreIntent(for: token)?.dwindlePlacement {
                placements[token] = placement
            }
        }
        engine.restoreInitialPlacements(placements, matching: windowTokens, in: workspaceId)
    }

    private func buildOnDemandLayoutPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine
    ) -> WorkspaceLayoutPlan {
        let frames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            borderSafeFillScreen: snapshot.monitor.borderSafeFillFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame,
            calculationSettings: calculationSettings(snapshot.settings, from: engine)
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: true,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? []
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func buildAnimationPlan(
        snapshot: DwindleWorkspaceSnapshot,
        engine: DwindleLayoutEngine,
        session: AnimationSession,
        targetTime: TimeInterval,
        isAnimationTick: Bool
    ) -> WorkspaceLayoutPlan {
        var diff = layoutDiff(
            windows: snapshot.windows,
            frames: session.targetFrames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: !isAnimationTick,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? [],
            animationTime: targetTime
        )
        if let axManager = controller?.axManager {
            for index in diff.frameChanges.indices {
                diff.frameChanges[index] = isAnimationTick
                    ? axManager.animationFrameChange(diff.frameChanges[index])
                    : axManager.enforcedSizeFrameChange(diff.frameChanges[index])
            }
        }
        diff.tabRailGeometryCommands = dwindleTabRailGeometryCommands(
            engine: engine,
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            targetTime: targetTime
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                plannedSeq: snapshot.plannedSeq
            ),
            diff: diff,
            isAnimationTick: isAnimationTick,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        preferredHideSide: HideSide,
        canRestoreHiddenWorkspaceWindows: Bool,
        scale: CGFloat,
        reassertHidden: Bool,
        pendingParkWindowIds: Set<Int>,
        animationTime: TimeInterval? = nil
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let effectiveScale = max(scale, 1.0)
        let excludedTokens = engine.excludedTokens(in: workspaceId)
        for window in windows {
            let token = window.token
            let targetFrame = frames[token]
            let frame = if let animationTime, targetFrame != nil {
                engine.presentedFrame(for: token, in: workspaceId, at: animationTime) ?? targetFrame
            } else {
                targetFrame
            }
            if window.isNativeFullscreenSuspended {
                if let originalToken = window.nativeFullscreenOriginalToken {
                    let roundedFrame = frame?.roundedToPhysicalPixels(scale: effectiveScale)
                    let validFrame = roundedFrame.map {
                        !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1
                    } == true
                    diff.nativeFullscreenSlots[originalToken] =
                        NativeFullscreenSlotProjection(
                            currentToken: token,
                            frame: validFrame ? roundedFrame ?? .zero : .zero,
                            visible: canRestoreHiddenWorkspaceWindows
                                && !excludedTokens.contains(token)
                                && engine.activeTileMember(containing: token, in: workspaceId) == token
                                && validFrame
                        )
                }
                continue
            }
            if excludedTokens.contains(token) {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if engine.isInactiveGroupMember(token, in: workspaceId) {
                let side = previousOffscreenSide ?? preferredHideSide
                if previousOffscreenSide == nil,
                   let revealToken = engine.activeTileMember(containing: token, in: workspaceId),
                   let revealWindow = windows.first(where: { $0.token == revealToken }),
                   revealWindow.hiddenState?.offscreenSide != nil,
                   frames[revealToken] != nil
                {
                    diff.deferredHides.append(
                        LayoutDeferredHide(
                            token: token,
                            side: side,
                            revealToken: revealToken
                        )
                    )
                    continue
                }
                if previousOffscreenSide != side || reassertHidden
                    || pendingParkWindowIds.contains(token.windowId)
                {
                    diff.visibilityChanges.append(.hide(token, side: side))
                }
                continue
            }

            if previousOffscreenSide != nil, frame != nil {
                diff.visibilityChanges.append(.show(token))
            }

            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: token, hiddenState: hiddenState)
                )
            }
            guard let frame = frame?.roundedToPhysicalPixels(scale: effectiveScale) else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: engine.isWindowFullscreen(token, in: workspaceId)
                )
            )
        }
        return diff
    }

    private func geometryContext(
        monitor: LayoutMonitorSnapshot,
        settings: ResolvedDwindleSettings
    ) -> DwindleAnimationGeometryContext {
        DwindleAnimationGeometryContext(
            monitorId: monitor.monitorId,
            displayId: monitor.displayId,
            workingFrame: monitor.workingFrame,
            borderSafeFillFrame: monitor.borderSafeFillFrame,
            fullscreenLayoutFrame: monitor.fullscreenLayoutFrame,
            scale: monitor.scale,
            settings: settings,
            tabRailWidth: TabRailManager.tabIndicatorWidth
        )
    }

    private func geometryContext(
        monitor: Monitor,
        settings: ResolvedDwindleSettings
    ) -> DwindleAnimationGeometryContext? {
        guard let controller else { return nil }
        return geometryContext(
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor),
            settings: settings
        )
    }

    private func applyResolvedSettings(
        _ settings: ResolvedDwindleSettings,
        to engine: DwindleLayoutEngine
    ) {
        engine.settings.smartSplit = settings.smartSplit
        engine.settings.defaultSplitRatio = settings.defaultSplitRatio
        engine.settings.splitWidthMultiplier = settings.splitWidthMultiplier
        engine.settings.singleWindowFit = settings.singleWindowFit
        engine.settings.innerGap = settings.innerGap
        engine.tabRailWidth = TabRailManager.tabIndicatorWidth
    }

    private func calculationSettings(
        _ resolved: ResolvedDwindleSettings,
        from engine: DwindleLayoutEngine
    ) -> DwindleSettings {
        var settings = engine.settings
        settings.smartSplit = resolved.smartSplit
        settings.defaultSplitRatio = resolved.defaultSplitRatio
        settings.splitWidthMultiplier = resolved.splitWidthMultiplier
        settings.singleWindowFit = resolved.singleWindowFit
        settings.innerGap = resolved.innerGap
        return settings
    }
}

extension DwindleLayoutHandler: LayoutSizable {}
