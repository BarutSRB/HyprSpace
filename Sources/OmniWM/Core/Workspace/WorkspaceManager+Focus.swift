// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum SessionSurfaceInvalidationScope: Equatable, Sendable {
    case full
    case border
}

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

    @discardableResult
    func recordExternalFocus(
        pid: pid_t? = nil,
        windowId: Int? = nil,
        verifiedManagedParentToken: WindowToken? = nil,
        preservePendingManagedFocus: Bool = false
    ) -> Bool {
        let exactToken: WindowToken? = if let pid, let windowId {
            WindowToken(pid: pid, windowId: windowId)
        } else {
            nil
        }
        let verifiedParent: WindowToken? = if let verifiedManagedParentToken,
                                              verifiedManagedParentToken != exactToken,
                                              verifiedManagedParentToken == selectedManagedToken,
                                              entry(for: verifiedManagedParentToken) != nil
        {
            verifiedManagedParentToken
        } else {
            nil
        }
        let changed = applyFocusReconcileEvent(
            .nativeFocusOwnerChanged(
                owner: .external(
                    pid: pid,
                    windowId: windowId,
                    verifiedManagedParentToken: verifiedParent
                ),
                preservePendingManagedFocus: preservePendingManagedFocus,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged(surfaceScope: .border)
        }
        return changed
    }

    @discardableResult
    func externalizeNativeFocus(matching token: WindowToken) -> Bool {
        guard nativeManagedFocusToken == token else { return false }
        return recordExternalFocus(pid: token.pid, windowId: token.windowId)
    }

    @discardableResult
    func recordOwnedSurfaceFocus() -> Bool {
        let changed = applyFocusReconcileEvent(
            .nativeFocusOwnerChanged(
                owner: .ownedSurface,
                preservePendingManagedFocus: false,
                source: .workspaceManager
            )
        )
        if changed {
            notifySessionStateChanged(surfaceScope: .border)
        }
        return changed
    }

    var externalFocusToken: WindowToken? {
        nativeFocusOwner.externalToken
    }

    var externalFocusIdentity: ExternalFocusIdentity? {
        nativeFocusOwner.externalIdentity
    }

    var borderFocusToken: WindowToken? {
        switch nativeFocusOwner {
        case let .managed(token):
            token
        case let .external(identity):
            if let externalToken = identity.exactToken,
               let parentToken = identity.verifiedManagedParentToken,
               parentToken != externalToken,
               parentToken == selectedManagedToken,
               entry(for: parentToken) != nil
            {
                parentToken
            } else {
                nil
            }
        case .ownedSurface,
             .none:
            nil
        }
    }

    func clearExternalFocusIdentity(matching token: WindowToken? = nil, pid: pid_t? = nil) {
        guard let current = externalFocusToken else { return }
        if let token, current != token { return }
        if let pid, current.pid != pid { return }
        let clearsNativeFullscreenOwner = activeNativeFullscreenFocusOwnerToken == current
        if applyFocusReconcileEvent(
            .nativeFocusOwnerChanged(
                owner: .external(pid: current.pid, windowId: nil),
                preservePendingManagedFocus: true,
                source: .workspaceManager
            )
        ) {
            notifySessionStateChanged(surfaceScope: .border)
        }
        if clearsNativeFullscreenOwner {
            _ = clearNativeFocusOwner()
        }
    }

    func suppressFocusBorder(for token: WindowToken) {
        guard suppressedFocusToken != token else { return }
        if applyFocusReconcileEvent(.suppressedFocusChanged(token: token, source: .workspaceManager)) {
            notifySessionStateChanged(surfaceScope: .border)
        }
    }

    func setSystemModalFocus(_ token: WindowToken?) {
        guard systemModalFocusToken != token else { return }
        if applyFocusReconcileEvent(
            .systemModalFocusChanged(token: token, source: .workspaceManager)
        ) {
            notifySessionStateChanged(surfaceScope: .border)
        }
    }
}
