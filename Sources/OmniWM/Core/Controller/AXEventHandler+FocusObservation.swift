// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension AXEventHandler {
    func probeFocusedWindowAfterFronting(
        expectedToken: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID
    ) {
        let requestId = controller?.intentLedger.activeManagedRequest(for: expectedToken)?.requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requestId,
               self.controller?.intentLedger.activeManagedRequest(requestId: requestId) == nil
            {
                return
            }
            self.handleAppActivation(
                pid: expectedToken.pid,
                source: .focusedWindowChanged,
                origin: .probe
            )
        }
    }

    func acceptsActivationObservation(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        if origin == .external, source != .focusedWindowChanged {
            latestNativeActivationPID = pid
        }
        return !suppressBackgroundFocusObservationIfNeeded(
            pid: pid,
            source: source,
            origin: origin
        )
    }

    func acceptsActivationFacts(_ facts: ActivationFacts, observedToken: WindowToken?) -> Bool {
        !suppressBackgroundFocusObservationIfNeeded(
            pid: facts.pid,
            source: facts.source,
            origin: facts.origin,
            observedToken: observedToken,
            isSystemModalSurface: facts.focusedWindow?.isSystemModalSurface == true
        )
    }

    private func suppressBackgroundFocusObservationIfNeeded(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observedToken: WindowToken? = nil,
        isSystemModalSurface: Bool = false
    ) -> Bool {
        guard source == .focusedWindowChanged, origin == .external else { return false }
        let hasFocusAuthority = hasFocusAuthority(
            pid: pid,
            observedToken: observedToken,
            isSystemModalSurface: isSystemModalSurface
        )
        guard !hasFocusAuthority,
              let nativePID = latestNativeActivationPID,
              let frontmostPID = frontmostApplicationPIDProvider(),
              pidsRepresentSameManagedApplication(nativePID, frontmostPID),
              !focusObservation(
                  pid: pid,
                  observedToken: observedToken,
                  representsPID: frontmostPID
              )
        else {
            return false
        }
        return true
    }

    private func focusObservation(
        pid: pid_t,
        observedToken: WindowToken?,
        representsPID expectedPID: pid_t
    ) -> Bool {
        if pid == expectedPID {
            return true
        }
        if let observedToken,
           managedWindowTokenUsingCachedIdentity(observedToken, matchesObservedPid: pid),
           managedWindowTokenUsingCachedIdentity(observedToken, matchesObservedPid: expectedPID)
        {
            return true
        }
        return pidsRepresentSameManagedApplication(pid, expectedPID)
    }

    private func pidsRepresentSameManagedApplication(_ lhs: pid_t, _ rhs: pid_t) -> Bool {
        if lhs == rhs {
            return true
        }
        if let request = controller?.intentLedger.activeManagedRequest,
           managedWindowTokenUsingCachedIdentity(request.token, matchesObservedPid: lhs),
           managedWindowTokenUsingCachedIdentity(request.token, matchesObservedPid: rhs)
        {
            return true
        }
        if let focusedToken = controller?.workspaceManager.selectedManagedToken,
           managedWindowTokenUsingCachedIdentity(focusedToken, matchesObservedPid: lhs),
           managedWindowTokenUsingCachedIdentity(focusedToken, matchesObservedPid: rhs)
        {
            return true
        }
        return false
    }

    private func hasFocusAuthority(
        pid: pid_t,
        observedToken: WindowToken?,
        isSystemModalSurface: Bool
    ) -> Bool {
        if let observedToken {
            if controller?.intentLedger.activeManagedRequest?.token == observedToken
                || hasRecentMouseFocusIntent(for: observedToken)
            {
                return true
            }
            guard isSystemModalSurface else { return false }
        }
        if let request = controller?.intentLedger.activeManagedRequest,
           managedWindowTokenUsingCachedIdentity(request.token, matchesObservedPid: pid)
        {
            return true
        }
        return hasRecentMouseFocusIntent(forPID: pid)
    }

    func managedWindowTokenUsingCachedIdentity(
        _ token: WindowToken,
        matchesObservedPid pid: pid_t
    ) -> Bool {
        if token.pid == pid {
            return true
        }
        guard let entry = controller?.workspaceManager.entry(for: token) else { return false }
        if AXWindowService.processIdentifier(entry.axRef) == pid {
            return true
        }
        return identityAliasesByWindowId[token.windowId]?.contains(pid: pid) == true
    }
}

extension AXEventHandler {
    func noteUnmanagedPointerClick() {
        recentUnmanagedPointerClickExpiresAt = Date().addingTimeInterval(Self.mouseFocusIntentDuration)
    }

    func suppressesMouseWarp(for token: WindowToken) -> Bool {
        if let expiresAt = recentUnmanagedPointerClickExpiresAt {
            if expiresAt > Date() {
                return true
            }
            recentUnmanagedPointerClickExpiresAt = nil
        }
        return hasRecentMouseFocusIntent(for: token)
    }
}
