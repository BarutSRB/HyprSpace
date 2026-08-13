// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func handleAppHidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller else { return }
        guard !controller.workspaceManager.isAppHidden(pid: pid) else { return }
        let entries = controller.workspaceManager.entries(forPid: pid)
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
            controller.intentLedger.discardPendingFocus(activeRequest.token)
        }
        if controller.workspaceManager.renderableFocusToken?.pid == pid {
            _ = controller.workspaceManager.enterNonManagedFocus(
                preserveFocusedToken: true
            )
        }

        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
        controller.surfaceReconciler.noteWorldChanged()
    }

    func handleAppUnhidden(pid: pid_t, source: WMEventSource = .ax) {
        guard let controller else { return }
        guard controller.workspaceManager.isAppHidden(pid: pid) else { return }
        let entries = controller.workspaceManager.entries(forPid: pid)
        controller.workspaceManager.setAppHidden(false, pid: pid, source: source)
        controller.axManager.setMacOSAppHidden(
            false,
            pid: pid,
            entries: entries.map { (pid: $0.pid, windowId: $0.windowId) }
        )
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
        controller.surfaceReconciler.noteWorldChanged()
    }
}
