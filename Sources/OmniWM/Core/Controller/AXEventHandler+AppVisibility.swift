// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func handleAppHidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.insert(pid)

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

        for entry in controller.workspaceManager.entries(forPid: pid) {
            controller.workspaceManager.setLayoutReason(.macosHiddenApp, for: entry.token)
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appHidden)
    }

    func handleAppUnhidden(pid: pid_t) {
        guard let controller else { return }
        controller.hiddenAppPIDs.remove(pid)

        for entry in controller.workspaceManager.entries(forPid: pid) {
            if controller.workspaceManager.layoutReason(for: entry.token) == .macosHiddenApp {
                controller.workspaceManager.restoreFromNativeState(for: entry.token)
            }
        }
        controller.layoutRefreshController.requestVisibilityRefresh(reason: .appUnhidden)
    }
}
