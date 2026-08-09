// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
extension AXEventHandler {
    func reassignFloatingWindowToContainingMonitor(
        entry: WindowState,
        frame: CGRect
    ) {
        guard let controller else { return }
        let token = entry.token
        guard controller.workspaceManager.hiddenState(for: token) == nil,
              !controller.workspaceManager.isScratchpadToken(token),
              let targetMonitor = frame.center.monitorApproximation(
                  in: controller.workspaceManager.monitors
              ),
              controller.workspaceManager.monitorId(for: entry.workspaceId) != targetMonitor.id,
              let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(
                  on: targetMonitor.id
              ),
              targetWorkspace.id != entry.workspaceId
        else {
            return
        }

        controller.reassignManagedWindow(token, to: targetWorkspace.id)
        controller.requestWorkspaceBarRefresh()
    }
}
