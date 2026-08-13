// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceNavigationHandler {
    weak var controller: WMController?

    private enum WorkspaceMoveFocusPolicy {
        case configured
        case alwaysFollow
    }

    init(controller: WMController) {
        self.controller = controller
    }

    private struct WindowTransferResult {
        let succeeded: Bool
        let newSourceFocusToken: WindowToken?
    }

    private func applySessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        viewportState: ViewportState? = nil,
        rememberedFocusToken: WindowToken? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: viewportState,
                rememberedFocusToken: rememberedFocusToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
    }

    private func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId)
    }

    private func commitWorkspaceSelection(
        nodeId: NodeId?,
        focusedToken: WindowToken?,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: focusedToken,
            in: workspaceId,
            onMonitor: monitorId
        )
    }

    private func interactionMonitorId(for controller: WMController) -> Monitor.ID? {
        controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?.id
    }

    private func finishWorkspaceMove(
        _ mutation: StructuralMutation,
        focusPolicy: WorkspaceMoveFocusPolicy = .configured
    ) {
        guard let controller else { return }
        let sourceWorkspaceId = mutation.sourceWorkspaceId
        let destinationWorkspaceId = mutation.destinationWorkspaceId

        if let sourceMonitor = controller.workspaceManager.monitor(for: sourceWorkspaceId) {
            controller.layoutRefreshController.stopScrollAnimation(for: sourceMonitor.displayId)
        }

        let gateWorkspaceIds: Set<WorkspaceDescriptor.ID>
        let postLayout: LayoutRefreshController.PostLayoutAction
        if focusPolicy == .alwaysFollow || controller.settings.focusFollowsWindowToMonitor {
            controller.isTransferringWindow = true
            defer { controller.isTransferringWindow = false }

            if let targetMonitor = controller.workspaceManager.monitorForWorkspace(destinationWorkspaceId) {
                _ = controller.workspaceManager.setActiveWorkspace(
                    destinationWorkspaceId,
                    on: targetMonitor.id
                )
            }

            let focusToken = mutation.selectedHandle.id
            gateWorkspaceIds = [destinationWorkspaceId]
            postLayout = { [weak controller] in
                guard let controller,
                      controller.activeWorkspace()?.id == destinationWorkspaceId,
                      controller.workspaceManager.entry(for: focusToken)?.workspaceId == destinationWorkspaceId
                else {
                    return
                }
                controller.focusWindow(focusToken)
            }
        } else {
            gateWorkspaceIds = [sourceWorkspaceId]
            postLayout = { [weak self, weak controller] in
                guard let controller,
                      controller.activeWorkspace()?.id == sourceWorkspaceId
                else {
                    return
                }
                if let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: sourceWorkspaceId),
                   controller.workspaceManager.entry(for: focusToken)?.workspaceId == sourceWorkspaceId
                {
                    controller.focusWindow(focusToken)
                } else if controller.workspaceManager.entries(in: sourceWorkspaceId).isEmpty {
                    self?.clearManagedFocusAfterEmptyWorkspaceSwitch()
                }
            }
        }

        let newestFocusIntentId = controller.intentLedger.newestFocusIntentId()
        let focusEpochSeq = controller.workspaceManager.worldSeq
        let postLayoutIfFocusStillCurrent: LayoutRefreshController.PostLayoutAction = { [weak controller] in
            guard let controller,
                  controller.intentLedger.newestFocusIntentId() == newestFocusIntentId,
                  controller.workspaceManager.isSeqEpochCurrent(focusEpochSeq, domains: .focus)
            else {
                return
            }
            postLayout()
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: mutation.affectedWorkspaceIds,
            reason: .workspaceTransition,
            postLayoutGateWorkspaceIds: gateWorkspaceIds,
            postLayout: postLayoutIfFocusStillCurrent,
            postLayoutInvalidated: postLayoutIfFocusStillCurrent
        )
    }

    private func recoverSourceFocus(
        after transfer: WindowTransferResult,
        from workspaceId: WorkspaceDescriptor.ID
    ) {
        controller?.recoverSourceFocusAfterMove(
            in: workspaceId,
            preferredToken: transfer.newSourceFocusToken
        )
    }

    private func restoreRememberedSelection(in workspaceId: WorkspaceDescriptor.ID) {
        guard let controller,
              let token = controller.workspaceManager.lastFocusedToken(in: workspaceId)
        else { return }

        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            guard let node = controller.niriEngine?.findNode(for: token, in: workspaceId) else { return }
            commitWorkspaceSelection(nodeId: node.id, focusedToken: token, in: workspaceId)
        case .dwindle:
            guard let engine = controller.dwindleEngine,
                  engine.findNode(for: token, in: workspaceId) != nil
            else { return }
            _ = controller.dwindleLayoutHandler.activateWindow(
                token,
                in: workspaceId,
                layoutRefresh: false,
                focusAfterLayout: false
            )
        }
    }

    private func transferredWindowNiriViewportState(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ViewportState? {
        guard let controller else { return nil }
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return nil }
        guard let engine = controller.niriEngine,
              let movedNode = engine.findNode(for: token, in: workspaceId),
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            return nil
        }

        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        state.selectedNodeId = movedNode.id
        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let orientation = controller.settings.effectiveOrientation(for: monitor)
        controller.workspaceManager.withEngineMutationScope {
            engine.activateWindow(movedNode.id, in: workspaceId)
            engine.ensureSelectionVisible(
                node: movedNode,
                in: workspaceId,
                motion: controller.motionPolicy.snapshot(),
                state: &state,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: orientation
            )
        }
        return state
    }

    private struct WorkspaceTransitionFocusHandoff {
        let focusToken: WindowToken?
        let shouldClearManagedFocus: Bool
    }

    private func resolveWorkspaceTransitionFocusHandoff(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceTransitionFocusHandoff {
        guard let controller else {
            return WorkspaceTransitionFocusHandoff(
                focusToken: nil,
                shouldClearManagedFocus: false
            )
        }
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: workspaceId)
        let shouldClearManagedFocus = focusToken == nil && controller.workspaceManager.entries(in: workspaceId).isEmpty
        return WorkspaceTransitionFocusHandoff(
            focusToken: focusToken,
            shouldClearManagedFocus: shouldClearManagedFocus
        )
    }

    private func clearManagedFocusAfterEmptyWorkspaceSwitch() {
        guard let controller else { return }
        let canceledRequest = controller.intentLedger.cancelManagedRequest()
        if let canceledRequest {
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: canceledRequest.token,
                workspaceId: canceledRequest.workspaceId,
                requestId: canceledRequest.requestId
            )
            controller.intentLedger.discardPendingFocus(canceledRequest.token)
        }
        _ = controller.workspaceManager.enterNonManagedFocus()
    }

    private func commitWorkspaceTransitionFocusHandoff(
        targetWorkspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor?,
        startScrollAnimation: Bool
    ) {
        guard let controller else { return }
        let handoff = resolveWorkspaceTransitionFocusHandoff(for: targetWorkspaceId)
        if let monitor {
            controller.layoutRefreshController.stopScrollAnimation(for: monitor.displayId)
        }
        controller.layoutRefreshController.commitWorkspaceTransition(
            reason: .workspaceTransition
        ) { [weak self, weak controller] in
            guard let controller else { return }
            if let focusToken = handoff.focusToken {
                controller.focusWindow(focusToken)
            } else if handoff.shouldClearManagedFocus {
                self?.clearManagedFocusAfterEmptyWorkspaceSwitch()
            }
            if startScrollAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: targetWorkspaceId)
            }
        }
    }

    func focusMonitorCyclic(previous: Bool) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        let targetMonitor: Monitor? = if previous {
            controller.workspaceManager.previousMonitor(from: currentMonitorId)
        } else {
            controller.workspaceManager.nextMonitor(from: currentMonitorId)
        }

        guard let target = targetMonitor else { return }
        switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func focusLastMonitor() {
        guard let controller else { return }
        guard let previousId = controller.workspaceManager.previousInteractionMonitorId else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard controller.workspaceManager.monitors.contains(where: { $0.id == previousId }) else { return }

        switchToMonitor(previousId, fromMonitor: currentMonitorId)
    }

    @discardableResult
    func focusMonitor(direction: Direction) -> Bool {
        guard let controller else { return false }
        guard let currentMonitorId = interactionMonitorId(for: controller) else { return false }
        guard let target = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return false }
        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: target.id)
        else { return false }

        let sourceFrame = controller.workspaceManager.focusedToken
            .flatMap { controller.preferredKeyboardFocusFrame(for: $0) }
        let dwindleEngine = controller.workspaceManager.activeLayoutKind(for: targetWorkspace.id) == .dwindle
            ? controller.dwindleEngine
            : nil
        let candidates = controller.workspaceManager.tiledEntries(in: targetWorkspace.id)
            .compactMap { entry -> (token: WindowToken, frame: CGRect)? in
                if controller.isManagedWindowSuppressedByMacOSHide(entry.token)
                    || dwindleEngine?.isInactiveGroupMember(entry.token, in: targetWorkspace.id) == true
                {
                    return nil
                }
                return controller.preferredKeyboardFocusFrame(for: entry.token).map {
                    (token: entry.token, frame: $0)
                }
            }
        guard !candidates.isEmpty else { return false }

        if let chosen = Self.spatialNeighborToken(
            from: sourceFrame,
            candidates: candidates,
            direction: direction,
            targetFrame: controller.insetWorkingFrame(for: target)
        ) {
            _ = controller.workspaceManager.rememberFocus(chosen, in: targetWorkspace.id)
        }
        return switchToMonitor(target.id, fromMonitor: currentMonitorId)
    }

    func moveWindowToMonitor(direction: Direction) {
        moveFocusedWindowToMonitor(direction: direction, focusPolicy: .configured)
    }

    func moveWindowAcrossMonitorAtEdge(direction: Direction) {
        moveFocusedWindowToMonitor(direction: direction, focusPolicy: .alwaysFollow)
    }

    private func moveFocusedWindowToMonitor(
        direction: Direction,
        focusPolicy: WorkspaceMoveFocusPolicy
    ) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let currentWsId = controller.workspaceManager.workspace(for: token) else { return }

        saveNiriViewportState(for: currentWsId)
        guard case let .changed(mutation) = moveWindowToMonitor(
            handle: WindowHandle(id: token),
            direction: direction
        ) else { return }
        finishWorkspaceMove(mutation, focusPolicy: focusPolicy)
    }

    func moveWindowToMonitor(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetMonitor = controller.workspaceManager.adjacentMonitor(
                  from: sourceMonitorId,
                  direction: direction
              ),
              let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id),
              targetWorkspace.id != sourceWorkspaceId
        else {
            return .unchanged
        }

        let targetIsNiri = controller.workspaceManager.activeLayoutKind(for: targetWorkspace.id) == .niri
        let anchorToken: WindowToken? = targetIsNiri ? Self.spatialNeighborToken(
            from: controller.preferredKeyboardFocusFrame(for: handle.id),
            candidates: controller.workspaceManager.tiledEntries(in: targetWorkspace.id)
                .filter { !controller.isManagedWindowSuppressedByMacOSHide($0.token) }
                .compactMap { entry in
                    controller.preferredKeyboardFocusFrame(for: entry.token).map { (token: entry.token, frame: $0) }
                },
            direction: direction,
            targetFrame: controller.insetWorkingFrame(for: targetMonitor)
        ) : nil

        let outcome = moveWindow(handle: handle, toWorkspaceId: targetWorkspace.id)
        guard case let .changed(mutation) = outcome else { return outcome }

        if targetIsNiri,
           controller.niriEngine?.findNode(for: handle, in: targetWorkspace.id) != nil
        {
            controller.niriLayoutHandler.consumeTransferredWindow(
                handle.id,
                in: targetWorkspace.id,
                enteringFrom: direction,
                anchorToken: anchorToken
            )
        }

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: mutation.sourceWorkspaceId,
                destinationWorkspaceId: mutation.destinationWorkspaceId,
                selectedHandle: mutation.selectedHandle,
                movedTokens: mutation.movedTokens,
                scrollWorkspaceId: nil
            )
        )
    }

    static func spatialNeighborToken(
        from sourceFrame: CGRect?,
        candidates: [(token: WindowToken, frame: CGRect)],
        direction: Direction,
        targetFrame: CGRect
    ) -> WindowToken? {
        func crossOverlaps(_ frame: CGRect) -> Bool {
            guard let sourceFrame else { return true }
            switch direction {
            case .left,
                 .right:
                return frame.maxY > sourceFrame.minY && frame.minY < sourceFrame.maxY
            case .up,
                 .down:
                return frame.maxX > sourceFrame.minX && frame.minX < sourceFrame.maxX
            }
        }
        func edgeDistance(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .left: targetFrame.maxX - frame.maxX
            case .right: frame.minX - targetFrame.minX
            case .up: frame.minY - targetFrame.minY
            case .down: targetFrame.maxY - frame.maxY
            }
        }
        func crossCenter(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .left,
                 .right: frame.midY
            case .up,
                 .down: frame.midX
            }
        }

        let anchor = sourceFrame.map(crossCenter) ?? crossCenter(targetFrame)
        return candidates.min { lhs, rhs in
            let lhsOverlap = crossOverlaps(lhs.frame) ? 0 : 1
            let rhsOverlap = crossOverlaps(rhs.frame) ? 0 : 1
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            let lhsEdge = edgeDistance(lhs.frame)
            let rhsEdge = edgeDistance(rhs.frame)
            if lhsEdge != rhsEdge { return lhsEdge < rhsEdge }
            return abs(crossCenter(lhs.frame) - anchor) < abs(crossCenter(rhs.frame) - anchor)
        }?.token
    }

    @discardableResult
    private func switchToMonitor(
        _ targetMonitorId: Monitor.ID,
        fromMonitor currentMonitorId: Monitor.ID
    ) -> Bool {
        guard let controller, targetMonitorId != currentMonitorId else { return false }

        guard let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: targetMonitorId)
        else {
            return false
        }

        _ = controller.workspaceManager.setInteractionMonitor(targetMonitorId)
        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWorkspace.id)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [targetWorkspace.id],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
        return true
    }

    func swapCurrentWorkspaceWithMonitor(direction: Direction) {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }
        guard let currentWsId = controller.activeWorkspace()?.id else { return }

        guard let targetMonitor = controller.workspaceManager.adjacentMonitor(
            from: currentMonitorId,
            direction: direction
        ) else { return }

        guard let targetWsId = controller.workspaceManager.activeWorkspace(on: targetMonitor.id)?.id
        else { return }

        saveNiriViewportState(for: currentWsId)
        restoreRememberedSelection(in: targetWsId)

        guard controller.workspaceManager.swapWorkspaces(
            currentWsId, on: currentMonitorId,
            with: targetWsId, on: targetMonitor.id
        ) else { return }

        controller.syncMonitorsToNiriEngine()

        let focusToken = controller.resolveAndSetWorkspaceFocusToken(for: targetWsId)

        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [currentWsId, targetWsId],
            reason: .workspaceTransition
        ) { [weak controller] in
            if let focusToken {
                controller?.focusWindow(focusToken)
            }
        }
    }

    func moveWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        force: Bool
    ) -> WorkspaceMonitorMoveOutcome? {
        guard let controller,
              let sourceMonitor = controller.workspaceManager.monitorForWorkspace(workspaceId),
              let targetMonitor = controller.workspaceManager.adjacentMonitor(
                  from: sourceMonitor.id,
                  direction: direction
              )
        else {
            return nil
        }

        let outcome = controller.workspaceManager.moveWorkspaceToMonitor(
            workspaceId,
            to: targetMonitor.id,
            force: force
        )
        controller.layoutRefreshController.commitWorkspaceMonitorTransition(outcome)
        return outcome
    }

    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func switchWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace,
           currentWorkspace.name == rawWorkspaceID
        {
            return
        }

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            controller.workspaceManager.monitorForWorkspace(targetWorkspaceId) != nil
        else {
            return
        }

        guard let result = controller.workspaceManager.focusWorkspace(named: rawWorkspaceID) else { return }

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: result.workspace.id,
            monitor: result.monitor,
            startScrollAnimation: false
        )
    }

    func switchWorkspaceRelative(
        isNext: Bool,
        wrapAround: Bool = true,
        monitorId explicitMonitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        guard let currentMonitorId = explicitMonitorId ?? interactionMonitorId(for: controller)
        else { return }
        let resolvedWorkspace = explicitMonitorId == nil
            ? controller.activeWorkspace()
            : controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId)
        guard let currentWorkspace = resolvedWorkspace else { return }

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            controller.workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }

        saveNiriViewportState(for: currentWorkspace.id)
        guard controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.focusedToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken, in: workspaceId)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId
            )
        }
    }

    func focusWorkspaceAnywhere(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
    }

    func focusWorkspaceAnywhere(rawWorkspaceID: String) {
        guard let controller else { return }
        let currentWorkspace = controller.activeWorkspace()

        guard let targetWsId = controller.workspaceManager.workspaceId(named: rawWorkspaceID) else { return }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return }

        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        let currentMonitorId = interactionMonitorId(for: controller)

        if let currentMonitorId, currentMonitorId != targetMonitor.id {
            if let currentTargetWs = controller.workspaceManager.activeWorkspace(on: targetMonitor.id) {
                saveNiriViewportState(for: currentTargetWs.id)
            }
        }

        guard controller.workspaceManager.setActiveWorkspace(targetWsId, on: targetMonitor.id) else { return }

        controller.syncMonitorsToNiriEngine()

        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: targetWsId,
            monitor: targetMonitor,
            startScrollAnimation: false
        )
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace {
            saveNiriViewportState(for: currentWorkspace.id)
        }

        guard controller.workspaceManager.setActiveWorkspace(prevWorkspace.id, on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: prevWorkspace.id,
            monitor: monitor,
            startScrollAnimation: false
        )
    }

    private func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID,
        requiredLayoutKind: ActiveLayoutKind? = nil
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager

        let existing: WorkspaceDescriptor? = if direction == .down {
            wm.nextWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        } else {
            wm.previousWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        }
        if let existing { return existing }

        guard let currentName = wm.descriptor(for: workspaceId)?.name,
              let currentNumber = Int(currentName)
        else { return nil }

        var candidateNumber = direction == .down ? currentNumber + 1 : currentNumber - 1
        while candidateNumber > 0 {
            let candidateName = String(candidateNumber)
            if wm.workspaceId(named: candidateName) == nil {
                let candidateLayoutKind: ActiveLayoutKind = controller.settings.layoutType(for: candidateName)
                    == .dwindle ? .dwindle : .niri
                guard requiredLayoutKind == nil || candidateLayoutKind == requiredLayoutKind else { return nil }
                guard let workspace = wm.createDynamicWorkspace(named: candidateName, on: monitorId) else {
                    return nil
                }
                controller.syncMonitorsToNiriEngine()
                return workspace
            }
            let delta = direction == .down ? 1 : -1
            let next = candidateNumber.addingReportingOverflow(delta)
            guard !next.overflow else { return nil }
            candidateNumber = next.partialValue
        }
        return nil
    }

    private func transferWindowFromSourceEngine(
        token: WindowToken,
        from sourceWsId: WorkspaceDescriptor.ID?,
        to targetWsId: WorkspaceDescriptor.ID
    ) -> WindowTransferResult {
        guard let controller else {
            return WindowTransferResult(succeeded: false, newSourceFocusToken: nil)
        }
        let sourceLayout: LayoutType = sourceWsId
            .flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
            .map { controller.settings.layoutType(for: $0) } ?? .defaultLayout
        let targetLayout: LayoutType = controller.workspaceManager.descriptor(for: targetWsId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let sourceIsDwindle = sourceLayout == .dwindle
        let targetIsDwindle = targetLayout == .dwindle
        var newSourceFocusToken: WindowToken?
        var movedWithNiri = false

        if controller.workspaceManager.windowMode(for: token) == .floating {
            controller.reassignManagedWindow(token, to: targetWsId)
            if let sourceWsId {
                recordLayoutOperation(.windowMovedToWorkspace(token: token, to: targetWsId), in: sourceWsId)
            }
            return WindowTransferResult(succeeded: true, newSourceFocusToken: nil)
        }

        if !sourceIsDwindle,
           !targetIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine,
           let windowNode = engine.findNode(for: token, in: sourceWsId)
        {
            let result = controller.workspaceManager.withBatchedWorkspaceMove(
                sourceWorkspaceId: sourceWsId,
                targetWorkspaceId: targetWsId
            ) { sourceState, targetState in
                guard let moveResult = engine.moveWindowToWorkspace(
                    windowNode,
                    from: sourceWsId,
                    to: targetWsId,
                    sourceState: &sourceState,
                    targetState: &targetState
                ) else { return nil }
                return (moveResult, [token])
            }
            if let result {
                if let newFocusId = result.newFocusNodeId,
                   let newFocusNode = engine.findNode(by: newFocusId, in: sourceWsId) as? NiriWindow
                {
                    newSourceFocusToken = newFocusNode.token
                }
                movedWithNiri = true
            }
        }

        if !movedWithNiri,
           !sourceIsDwindle,
           let sourceWsId,
           let engine = controller.niriEngine
        {
            controller.workspaceManager.withBatchedNiriSourceMutation(workspaceId: sourceWsId) { sourceState in
                if let currentNode = engine.findNode(for: token, in: sourceWsId),
                   sourceState.selectedNodeId == currentNode.id
                {
                    sourceState.selectedNodeId = engine.fallbackSelectionOnRemoval(
                        removing: currentNode.id,
                        in: sourceWsId
                    )
                }

                if targetIsDwindle, engine.findNode(for: token, in: sourceWsId) != nil {
                    controller.workspaceManager.captureDetachedNiriPlacement(for: token, in: sourceWsId)
                    engine.removeWindow(token: token, in: sourceWsId)
                }

                if let selectedId = sourceState.selectedNodeId,
                   engine.findNode(by: selectedId, in: sourceWsId) == nil
                {
                    sourceState.selectedNodeId = engine.validateSelection(selectedId, in: sourceWsId)
                }

                if let selectedId = sourceState.selectedNodeId,
                   let selectedNode = engine.findNode(by: selectedId, in: sourceWsId) as? NiriWindow
                {
                    newSourceFocusToken = selectedNode.token
                }
            }
        } else if sourceIsDwindle,
                  let sourceWsId,
                  let dwindleEngine = controller.dwindleEngine
        {
            newSourceFocusToken = controller.workspaceManager.withEngineMutationScope(in: sourceWsId) {
                dwindleEngine.removeWindow(token: token, from: sourceWsId)
                return dwindleEngine.selectedNode(in: sourceWsId)?.windowToken
            }
        }

        let succeeded: Bool
        if movedWithNiri {
            succeeded = true
        } else if sourceWsId == nil {
            succeeded = true
        } else if !sourceIsDwindle && !targetIsDwindle {
            succeeded = false
        } else {
            succeeded = true
        }

        if succeeded {
            if !movedWithNiri {
                controller.reassignManagedWindow(token, to: targetWsId)
            }
            if let sourceWsId {
                recordLayoutOperation(.windowMovedToWorkspace(token: token, to: targetWsId), in: sourceWsId)
            }
        }

        return WindowTransferResult(succeeded: succeeded, newSourceFocusToken: newSourceFocusToken)
    }

    func moveWindowToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveWindowToAdjacentWorkspace(
            handle: WindowHandle(id: token),
            direction: direction
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveColumnToAdjacentWorkspace(direction: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token) else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveColumnToAdjacentWorkspace(
            containing: WindowHandle(id: token),
            direction: direction
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveColumnToWorkspaceByIndex(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveColumnToWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func moveColumnToWorkspace(rawWorkspaceID: String) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let sourceWorkspaceId = controller.workspaceManager.workspace(for: token),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceID,
                  createIfMissing: false
              )
        else { return }

        saveNiriViewportState(for: sourceWorkspaceId)
        guard case let .changed(mutation) = moveColumn(
            containing: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    func moveFocusedWindow(toWorkspaceIndex index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
    }

    func moveFocusedWindow(toRawWorkspaceID rawWorkspaceID: String) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ) else { return }
        guard case let .changed(mutation) = moveWindow(
            handle: WindowHandle(id: token),
            toWorkspaceId: targetWorkspaceId
        ) else { return }

        finishWorkspaceMove(mutation)
    }

    @discardableResult
    func rebindFloatingWindow(
        handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID,
        onMonitor targetMonitor: Monitor
    ) -> Bool {
        guard let controller else { return false }
        let workspaceManager = controller.workspaceManager
        let token = handle.id
        guard let entry = workspaceManager.entry(for: token),
              workspaceManager.handle(for: token) === handle,
              entry.mode == .floating,
              entry.workspaceId != targetWorkspaceId,
              workspaceManager.descriptor(for: targetWorkspaceId) != nil,
              workspaceManager.monitor(byId: targetMonitor.id) != nil,
              workspaceManager.monitorId(for: entry.workspaceId) != targetMonitor.id,
              workspaceManager.monitorId(for: targetWorkspaceId) == targetMonitor.id,
              workspaceManager.activeWorkspaceOrFirst(on: targetMonitor.id)?.id == targetWorkspaceId
        else {
            return false
        }

        let sourceWorkspaceId = entry.workspaceId
        let activeRequest = controller.intentLedger.activeManagedRequest
        let matchingRequest = activeRequest?.token == token ? activeRequest : nil
        let hasNewerUnrelatedRequest = activeRequest.map { $0.token != token } ?? false
        let hasUnrelatedPendingFocus = workspaceManager.pendingFocusedToken.map { $0 != token } ?? false
        let shouldRehomeFocusedWindow = workspaceManager.focusedToken == token
            && !hasNewerUnrelatedRequest
            && !hasUnrelatedPendingFocus

        controller.reassignManagedWindow(token, to: targetWorkspaceId)
        guard workspaceManager.workspace(for: token) == targetWorkspaceId else { return false }

        _ = workspaceManager.resolveAndSetWorkspaceFocusToken(in: sourceWorkspaceId)

        if let matchingRequest {
            guard let retargetedRequest = controller.intentLedger.retargetManagedRequest(
                requestId: matchingRequest.requestId,
                token: token,
                to: targetWorkspaceId
            ) else {
                return true
            }
            if shouldRehomeFocusedWindow {
                _ = workspaceManager.rehomeManagedFocusRequest(
                    token,
                    in: targetWorkspaceId,
                    onMonitor: targetMonitor.id,
                    requestId: retargetedRequest.requestId
                )
            } else {
                _ = workspaceManager.beginManagedFocusRequest(
                    token,
                    in: targetWorkspaceId,
                    onMonitor: targetMonitor.id,
                    requestId: retargetedRequest.requestId
                )
            }
        } else if shouldRehomeFocusedWindow {
            _ = workspaceManager.setManagedFocus(
                token,
                in: targetWorkspaceId,
                onMonitor: targetMonitor.id
            )
        }

        return true
    }

    @discardableResult
    func moveWindow(
        handle: WindowHandle,
        toWorkspaceId targetWsId: WorkspaceDescriptor.ID
    ) -> StructuralMutationOutcome {
        guard let controller,
              controller.workspaceManager.descriptor(for: targetWsId) != nil,
              controller.workspaceManager.monitorForWorkspace(targetWsId) != nil
        else {
            return .unchanged
        }
        let token = handle.id

        guard let currentWorkspaceId = controller.workspaceManager.workspace(for: token),
              currentWorkspaceId != targetWsId
        else {
            return .unchanged
        }
        let transferResult = transferWindowFromSourceEngine(
            token: token,
            from: currentWorkspaceId,
            to: targetWsId
        )
        guard transferResult.succeeded else { return .unchanged }

        let targetViewportState = transferredWindowNiriViewportState(
            token: token,
            workspaceId: targetWsId
        )
        applySessionPatch(
            workspaceId: targetWsId,
            viewportState: targetViewportState,
            rememberedFocusToken: token
        )

        recoverSourceFocus(after: transferResult, from: currentWorkspaceId)

        return .changed(
            StructuralMutation(
                sourceWorkspaceId: currentWorkspaceId,
                destinationWorkspaceId: targetWsId,
                selectedHandle: handle,
                movedTokens: [token],
                scrollWorkspaceId: targetViewportState?.hasPendingOffsetAnimation == true ? targetWsId : nil
            )
        )
    }

    func moveWindow(
        handle: WindowHandle,
        toWorkspaceIndex index: Int
    ) -> StructuralMutationOutcome {
        guard let controller,
              let rawWorkspaceId = WorkspaceIDPolicy.rawID(from: max(0, index) + 1),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceId,
                  createIfMissing: false
              )
        else {
            return .unchanged
        }
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId)
    }

    func moveWindowToAdjacentWorkspace(
        handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .up || direction == .down,
              let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              canTransferWindow(handle, from: sourceWorkspaceId),
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetWorkspace = resolveOrCreateAdjacentWorkspace(
                  from: sourceWorkspaceId,
                  direction: direction,
                  on: sourceMonitorId
              )
        else {
            return .unchanged
        }
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspace.id)
    }

    private func canTransferWindow(
        _ handle: WindowHandle,
        from workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller else { return false }
        if controller.workspaceManager.windowMode(for: handle.id) == .floating {
            return true
        }
        switch controller.workspaceManager.activeLayoutKind(for: workspaceId) {
        case .niri:
            return controller.niriEngine?.findNode(for: handle, in: workspaceId) != nil
        case .dwindle:
            return controller.dwindleEngine?.findNode(for: handle.id, in: workspaceId) != nil
        }
    }

    func moveColumn(
        containing handle: WindowHandle,
        toWorkspaceId targetWorkspaceId: WorkspaceDescriptor.ID
    ) -> StructuralMutationOutcome {
        guard let controller,
              let engine = controller.niriEngine,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              sourceWorkspaceId != targetWorkspaceId,
              controller.workspaceManager.activeLayoutKind(for: sourceWorkspaceId) == .niri,
              controller.workspaceManager.activeLayoutKind(for: targetWorkspaceId) == .niri,
              let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId),
              let windowNode = engine.findNode(for: handle, in: sourceWorkspaceId),
              let column = engine.findColumn(containing: windowNode, in: sourceWorkspaceId)
        else {
            return .unchanged
        }

        let movedTokens = column.windowNodes.map(\.token)
        let targetWorkingFrame = controller.insetWorkingFrame(for: targetMonitor)
        let gaps = controller.innerGap(for: targetMonitor)
        let motion = controller.motionPolicy.snapshot()
        let orientation = controller.settings.effectiveOrientation(for: targetMonitor)
        guard let result = controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            { sourceState, targetState in
                guard let moveResult = engine.moveColumnToWorkspace(
                    column,
                    from: sourceWorkspaceId,
                    to: targetWorkspaceId,
                    sourceState: &sourceState,
                    targetState: &targetState,
                    targetOrientation: orientation
                ) else { return nil }
                engine.activateWindow(windowNode.id, in: targetWorkspaceId)
                targetState.selectedNodeId = windowNode.id
                engine.ensureSelectionVisible(
                    node: windowNode,
                    in: targetWorkspaceId,
                    motion: motion,
                    state: &targetState,
                    workingFrame: targetWorkingFrame,
                    gaps: gaps,
                    orientation: orientation
                )
                return (moveResult, movedTokens)
            }
        ) else {
            return .unchanged
        }

        recordLayoutOperation(.columnMovedToWorkspace(to: targetWorkspaceId), in: sourceWorkspaceId)
        applySessionPatch(workspaceId: targetWorkspaceId, rememberedFocusToken: handle.id)
        controller.recoverSourceFocusAfterMove(
            in: sourceWorkspaceId,
            preferredNodeId: result.newFocusNodeId
        )

        let targetState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
        return .changed(
            StructuralMutation(
                sourceWorkspaceId: sourceWorkspaceId,
                destinationWorkspaceId: targetWorkspaceId,
                selectedHandle: handle,
                movedTokens: movedTokens,
                scrollWorkspaceId: targetState.hasPendingOffsetAnimation ? targetWorkspaceId : nil
            )
        )
    }

    func moveColumn(
        containing handle: WindowHandle,
        toWorkspaceIndex index: Int
    ) -> StructuralMutationOutcome {
        guard let controller,
              let rawWorkspaceId = WorkspaceIDPolicy.rawID(from: max(0, index) + 1),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceId,
                  createIfMissing: false
              )
        else {
            return .unchanged
        }
        return moveColumn(containing: handle, toWorkspaceId: targetWorkspaceId)
    }

    func moveColumnToAdjacentWorkspace(
        containing handle: WindowHandle,
        direction: Direction
    ) -> StructuralMutationOutcome {
        guard direction == .up || direction == .down,
              let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              controller.workspaceManager.activeLayoutKind(for: sourceWorkspaceId) == .niri,
              let sourceNode = controller.niriEngine?.findNode(for: handle, in: sourceWorkspaceId),
              controller.niriEngine?.findColumn(containing: sourceNode, in: sourceWorkspaceId) != nil,
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetWorkspace = resolveOrCreateAdjacentWorkspace(
                  from: sourceWorkspaceId,
                  direction: direction,
                  on: sourceMonitorId,
                  requiredLayoutKind: .niri
              )
        else {
            return .unchanged
        }
        return moveColumn(containing: handle, toWorkspaceId: targetWorkspace.id)
    }

    func moveWindowToWorkspaceOnMonitor(
        handle: WindowHandle,
        workspaceIndex: Int,
        monitorDirection: Direction
    ) -> StructuralMutationOutcome {
        guard let rawWorkspaceId = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else {
            return .unchanged
        }
        return moveWindowToWorkspaceOnMonitor(
            handle: handle,
            rawWorkspaceId: rawWorkspaceId,
            monitorDirection: monitorDirection
        )
    }

    func moveWindowToWorkspaceOnMonitor(
        handle: WindowHandle,
        rawWorkspaceId: String,
        monitorDirection: Direction
    ) -> StructuralMutationOutcome {
        guard let controller,
              let sourceWorkspaceId = controller.workspaceManager.workspace(for: handle.id),
              let sourceMonitorId = controller.workspaceManager.monitorId(for: sourceWorkspaceId),
              let targetMonitor = controller.workspaceManager.adjacentMonitor(
                  from: sourceMonitorId,
                  direction: monitorDirection
              ),
              let targetWorkspaceId = controller.workspaceManager.workspaceId(
                  for: rawWorkspaceId,
                  createIfMissing: false
              ),
              controller.workspaceManager.monitorId(for: targetWorkspaceId) == targetMonitor.id
        else {
            return .unchanged
        }
        return moveWindow(handle: handle, toWorkspaceId: targetWorkspaceId)
    }

    func moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, workspaceIndex) + 1) else { return }
        moveWindowToWorkspaceOnMonitor(rawWorkspaceID: rawWorkspaceID, monitorDirection: monitorDirection)
    }

    func moveWindowToWorkspaceOnMonitor(rawWorkspaceID: String, monitorDirection: Direction) {
        guard let controller else { return }
        guard let token = controller.workspaceManager.focusedToken else { return }
        guard case let .changed(mutation) = moveWindowToWorkspaceOnMonitor(
            handle: WindowHandle(id: token),
            rawWorkspaceId: rawWorkspaceID,
            monitorDirection: monitorDirection
        ) else { return }

        finishWorkspaceMove(mutation)
    }
}
