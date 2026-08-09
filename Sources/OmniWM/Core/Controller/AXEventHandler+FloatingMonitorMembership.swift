// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

@MainActor
extension AXEventHandler {
    func updateFloatingWindowGeometryAndMonitorMembership(
        entry: WindowState,
        frame: CGRect
    ) {
        guard let controller else { return }
        let token = entry.token
        guard controller.workspaceManager.hiddenState(for: token) == nil else {
            return
        }

        let center = frame.center
        guard WMController.isMeaningfulAdmissionFrame(frame),
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              center.x.isFinite,
              center.y.isFinite,
              let targetMonitor = center.monitorApproximation(
                  in: controller.workspaceManager.monitors
              )
        else {
            return
        }

        controller.workspaceManager.updateFloatingGeometry(
            frame: frame,
            for: token,
            referenceMonitor: targetMonitor
        )
        guard !controller.workspaceManager.isScratchpadToken(token),
              controller.workspaceManager.monitorId(for: entry.workspaceId) != targetMonitor.id,
              let targetWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(
                  on: targetMonitor.id
              ),
              let handle = controller.workspaceManager.handle(for: token),
              targetWorkspace.id != entry.workspaceId
        else {
            return
        }

        controller.workspaceNavigationHandler.rebindFloatingWindow(
            handle: handle,
            toWorkspaceId: targetWorkspace.id,
            onMonitor: targetMonitor
        )
    }
}
