// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

extension WorkspaceManager {
    @discardableResult
    func beginManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil,
        requestId: UInt64
    ) -> Bool {
        applyManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            requestId: requestId,
            rehomeInteractionMonitor: false
        )
    }

    @discardableResult
    func rehomeManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID,
        requestId: UInt64
    ) -> Bool {
        applyManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: monitorId,
            requestId: requestId,
            rehomeInteractionMonitor: true
        )
    }

    private func applyManagedFocusRequest(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID?,
        requestId: UInt64,
        rehomeInteractionMonitor: Bool
    ) -> Bool {
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id }
        var changed = rememberFocus(token, in: workspaceId)
        var interactionChanged = false
        if rehomeInteractionMonitor, let normalizedMonitorId {
            interactionChanged = updateInteractionMonitor(
                normalizedMonitorId,
                preservePrevious: true,
                notify: false,
                drainRuntimeOverrides: false
            )
            changed = interactionChanged || changed
        }
        changed = applyFocusReconcileEvent(
            .managedFocusRequested(
                token: token,
                workspaceId: workspaceId,
                monitorId: normalizedMonitorId,
                requestId: requestId,
                source: .workspaceManager
            )
        ) || changed
        if interactionChanged {
            drainPendingRuntimeMonitorOverrideClears()
        }
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }
}
