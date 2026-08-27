// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.workspaceManager.clearNonManagedFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId)
        )
    }

    func handleAppDeactivated(pid: pid_t) {
        guard let controller else { return }
        let workspaceManager = controller.workspaceManager
        workspaceManager.clearNonManagedFocusTarget(pid: pid)

        guard !workspaceManager.isNonManagedFocusActive,
              let focusedToken = workspaceManager.focusedToken,
              focusedToken.pid == pid,
              let entry = workspaceManager.entry(for: focusedToken),
              entry.mode == .floating
        else { return }

        workspaceManager.suppressFocusBorder(for: focusedToken)
    }

    func handleAppHidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: .hidden,
                outcome: .rejected,
                reason: .controllerUnavailable,
                source: source
            )
            return
        }
        guard !controller.workspaceManager.isAppHidden(pid: pid) else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: .hidden,
                outcome: .duplicate,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                source: source
            )
            return
        }
        let entries = controller.workspaceManager.entries(forPid: pid)
        let affectedWorkspaceIds = Set(entries.map(\.workspaceId))
        controller.dwindleLayoutHandler.cancelPendingGroupReveals(pid: pid)
        for entry in entries {
            controller.layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
        }
        controller.mouseEventHandler.handleAppVisibilityChanged()
        for workspaceId in affectedWorkspaceIds {
            controller.layoutRefreshController.cancelActiveAnimations(for: workspaceId)
        }
        controller.layoutRefreshController.stopAllDwindleAnimations()
        controller.layoutRefreshController.cancelFrameAnimations(forPID: pid)
        controller.axManager.setMacOSAppHidden(
            true,
            pid: pid,
            entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
        )
        controller.workspaceManager.setAppHidden(true, pid: pid, source: source)

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId,
                requestId: activeRequest.requestId
            )
            controller.abortScratchpadStacking(matching: activeRequest.requestId)
            controller.intentLedger.discardPendingFocus(activeRequest.token)
        }
        if controller.workspaceManager.renderableFocusToken?.pid == pid {
            _ = controller.workspaceManager.enterNonManagedFocus(
                preserveFocusedToken: true
            )
        }
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )

        let activeAffectedWorkspaceIds = activeWorkspaceIds(
            in: affectedWorkspaceIds,
            controller: controller
        )
        if !activeAffectedWorkspaceIds.isEmpty {
            AppVisibilityTrace.record(
                .refresh,
                pid: pid,
                visibility: .hidden,
                outcome: .requested,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                managedWindowCount: entries.count,
                affectedWorkspaceCount: affectedWorkspaceIds.count,
                activeWorkspaceCount: activeAffectedWorkspaceIds.count,
                source: source
            )
            controller.layoutRefreshController.requestVisibilityRefresh(
                reason: .appHidden,
                affectedWorkspaceIds: activeAffectedWorkspaceIds
            )
        } else {
            AppVisibilityTrace.record(
                .refresh,
                pid: pid,
                visibility: .hidden,
                outcome: .skipped,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                managedWindowCount: entries.count,
                affectedWorkspaceCount: affectedWorkspaceIds.count,
                activeWorkspaceCount: 0,
                reason: .noActiveWorkspace,
                source: source
            )
        }
        controller.surfaceReconciler.noteWorldChanged()
    }

    func handleAppUnhidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: .visible,
                outcome: .rejected,
                reason: .controllerUnavailable,
                source: source
            )
            return
        }
        guard controller.workspaceManager.isAppHidden(pid: pid) else {
            AppVisibilityTrace.record(
                .stateTransition,
                pid: pid,
                visibility: .visible,
                outcome: .duplicate,
                generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
                source: source
            )
            return
        }
        let entries = controller.workspaceManager.entries(forPid: pid)
        let affectedWorkspaceIds = Set(entries.map(\.workspaceId))
        let revealIntent = controller.intentLedger.openAppRevealFocusIntent(pid: pid)
        controller.workspaceManager.setAppHidden(false, pid: pid, source: source)
        controller.axManager.setMacOSAppHidden(
            false,
            pid: pid,
            entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
        )
        controller.reconcileScratchpadMembersAfterAppUnhide(pid: pid)
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )
        let revealReady = revealIntent.flatMap { revealIntent in
            controller.intentLedger.drainAppRevealFocus(
                intentId: revealIntent.intent.id,
                pid: pid,
                appVisibilityGeneration: controller.workspaceManager.appVisibilityGeneration(for: pid)
            )
        } == .ready
        let completeReveal: LayoutRefreshController.PostLayoutAction?
        if revealReady, let revealIntentId = revealIntent?.intent.id {
            completeReveal = { [weak controller] in
                _ = controller?.windowActionHandler.completeAppRevealFocus(intentId: revealIntentId)
            }
        } else {
            completeReveal = nil
        }
        let activeAffectedWorkspaceIds = activeWorkspaceIds(
            in: affectedWorkspaceIds,
            controller: controller
        )
        AppVisibilityTrace.record(
            .refresh,
            pid: pid,
            visibility: .visible,
            outcome: .requested,
            generation: controller.workspaceManager.appVisibilityGeneration(for: pid),
            managedWindowCount: entries.count,
            affectedWorkspaceCount: affectedWorkspaceIds.count,
            activeWorkspaceCount: activeAffectedWorkspaceIds.count,
            source: source
        )
        controller.layoutRefreshController.requestVisibilityRefresh(
            reason: .appUnhidden,
            affectedWorkspaceIds: activeAffectedWorkspaceIds,
            postLayout: completeReveal,
            postLayoutInvalidated: completeReveal
        )
        controller.surfaceReconciler.noteWorldChanged()
    }

    private func activeWorkspaceIds(
        in workspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        Set(workspaceIds.filter { workspaceId in
            guard let monitorId = controller.workspaceManager.monitorId(for: workspaceId) else {
                return false
            }
            return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
        })
    }
}
