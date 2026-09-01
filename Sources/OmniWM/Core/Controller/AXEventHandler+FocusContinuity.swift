// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func verifiedSelectedManagedParentToken(
        for childToken: WindowToken,
        childWindowInfo: WindowServerInfo?
    ) -> WindowToken? {
        guard let controller,
              let childWindowInfo = WMController.exactWindowServerInfo(
                  childWindowInfo,
                  for: childToken
              ),
              childWindowInfo.parentId != 0,
              childWindowInfo.parentId != childWindowInfo.id,
              let selectedToken = controller.workspaceManager.selectedManagedToken,
              controller.workspaceManager.entry(for: selectedToken) != nil,
              let parentWindowInfo = resolveWindowInfo(childWindowInfo.parentId),
              parentWindowInfo.id == childWindowInfo.parentId
        else {
            return nil
        }
        let parentToken = WindowToken(
            pid: pid_t(parentWindowInfo.pid),
            windowId: Int(parentWindowInfo.id)
        )
        return parentToken == selectedToken ? parentToken : nil
    }

    func clearManagedFocusState(
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        preservesExternalFocusIdentity: Bool = false
    ) {
        guard let controller else { return }

        controller.intentLedger.discardPendingFocus(token)
        let canceledRequest = controller.intentLedger.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let canceledRequest {
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                requestId: canceledRequest.requestId
            )
            controller.abortScratchpadStacking(matching: canceledRequest.requestId)
        } else {
            _ = controller.workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        if !preservesExternalFocusIdentity {
            controller.workspaceManager.clearExternalFocusIdentity(matching: token)
        }
    }
}
