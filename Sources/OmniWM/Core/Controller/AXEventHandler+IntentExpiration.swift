// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func handleIntentExpired(_ intentId: IntentID) {
        guard let controller else { return }
        guard let intent = controller.intentLedger.openIntent(id: intentId) else { return }

        switch intent.kind {
        case .activateApp,
             .appRevealFocus,
             .replacementFocus:
            _ = controller.intentLedger.markExpired(id: intentId)

        case let .focusPolicyLease(owner):
            _ = controller.intentLedger.markExpired(id: intentId)
            controller.focusPolicyEngine.handleLeaseDeadlineExpired(owner: owner, intentId: intentId)

        case let .sameAppCloseProbe(payload):
            if hasPendingSameAppCloseHandoff(payload.focusedToken) {
                return
            }
            _ = controller.intentLedger.markExpired(id: intentId)
            handleSameAppCloseProbeDeadline(payload)

        case .focusWindow:
            guard let liveRequest = controller.intentLedger.activeManagedRequest(requestId: intentId) else {
                _ = controller.intentLedger.markExpired(id: intentId)
                return
            }
            controller.retryManagedFocusFronting(liveRequest)
            handleAppActivation(
                pid: liveRequest.token.pid,
                source: liveRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        }
    }
}
