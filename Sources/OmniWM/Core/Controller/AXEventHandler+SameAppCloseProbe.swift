// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func sameAppFocusCausality(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        focusedToken: WindowToken?
    ) -> SameAppFocusCausality? {
        guard source == .focusedWindowChanged,
              origin == .external,
              let focusedToken,
              let entry = controller?.workspaceManager.entry(for: focusedToken),
              managedWindowToken(focusedToken, matchesObservedPid: pid)
        else {
            return nil
        }
        return SameAppFocusCausality(
            focusedToken: focusedToken,
            workspaceId: entry.workspaceId
        )
    }

    func hasPendingManagedReplacementDestroy(_ token: WindowToken) -> Bool {
        guard let workspaceId = controller?.workspaceManager.entry(for: token)?.workspaceId else {
            return false
        }
        return hasPendingManagedReplacementDestroy(token, workspaceId: workspaceId)
    }

    func hasPendingManagedIdentityRebind(
        from token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        admissionRetryStateByWindowId.values.contains { state in
            guard !state.exhausted,
                  !state.identityRebindTargetDestroyed,
                  case let .identityRebind(oldWindow, _, metadata, _, _) = state.trigger
            else {
                return false
            }
            return oldWindow.token == token && metadata?.workspaceId == workspaceId
        }
    }

    func hasPendingSameAppCloseHandoff(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        hasPendingManagedReplacementDestroy(token, workspaceId: workspaceId)
            || hasPendingManagedIdentityRebind(from: token, workspaceId: workspaceId)
    }

    func hasPendingSameAppCloseHandoff(_ token: WindowToken) -> Bool {
        guard let workspaceId = controller?.workspaceManager.entry(for: token)?.workspaceId else {
            return false
        }
        return hasPendingSameAppCloseHandoff(token, workspaceId: workspaceId)
    }

    func preservesSameAppFocusCausality(_ causality: SameAppFocusCausality) -> Bool {
        if hasPendingSameAppCloseHandoff(
            causality.focusedToken,
            workspaceId: causality.workspaceId
        ) {
            return true
        }
        guard let controller else { return false }
        if let intent = controller.intentLedger.openReplacementFocusIntent(
            pid: causality.focusedToken.pid,
            workspaceId: causality.workspaceId
        ), case let .replacementFocus(payload) = intent.kind {
            if payload.anchorToken != causality.focusedToken {
                return controller.workspaceManager.entry(for: payload.anchorToken)?.workspaceId
                    == causality.workspaceId
            }
            if !payload.isBurstOpen {
                return false
            }
        }
        return controller.workspaceManager.entry(for: causality.focusedToken)?.workspaceId
            == causality.workspaceId
    }

    func deferSameAppCloseProbe(
        focusedToken: WindowToken,
        focusedWorkspaceId: WorkspaceDescriptor.ID,
        observedToken: WindowToken,
        source: ActivationEventSource,
        observationGeneration: UInt64
    ) {
        guard let controller else { return }
        if let open = controller.intentLedger.openSameAppCloseProbe(),
           open.payload.focusedToken == focusedToken,
           open.payload.observedToken == observedToken
        {
            controller.intentLedger.updateSameAppCloseProbe(id: open.intent.id) { payload in
                payload.observationGeneration = observationGeneration
            }
            if hasPendingSameAppCloseHandoff(focusedToken, workspaceId: focusedWorkspaceId) {
                controller.deadlineWheel.cancel(intentId: open.intent.id)
            }
            return
        }

        cancelSameAppCloseProbe()
        let intent = controller.intentLedger.registerSameAppCloseProbe(
            SameAppCloseProbePayload(
                focusedToken: focusedToken,
                observedToken: observedToken,
                source: source,
                observationGeneration: observationGeneration
            )
        )
        if !hasPendingSameAppCloseHandoff(focusedToken, workspaceId: focusedWorkspaceId) {
            controller.deadlineWheel.schedule(intentId: intent.id, after: Self.sameAppCloseProbeDelay)
        }
    }

    func sameAppCloseProbePayload(
        matchingFocusedToken token: WindowToken
    ) -> SameAppCloseProbePayload? {
        guard let open = controller?.intentLedger.openSameAppCloseProbe(),
              open.payload.focusedToken == token
        else {
            return nil
        }
        return open.payload
    }

    func handleSameAppCloseProbeDeadline(
        _ payload: SameAppCloseProbePayload,
        focusedToken: WindowToken? = nil
    ) {
        guard let controller else { return }
        let focusedToken = focusedToken ?? payload.focusedToken
        guard controller.workspaceManager.focusedToken == focusedToken,
              controller.workspaceManager.entry(for: focusedToken) != nil,
              controller.intentLedger.activeManagedRequest == nil
        else {
            return
        }
        handleAppActivation(
            pid: payload.observedToken.pid,
            source: payload.source,
            origin: .probe,
            causalObservationGeneration: payload.observationGeneration
        )
    }

    @discardableResult
    func cancelSameAppCloseProbe(
        matchingFocusedToken token: WindowToken? = nil,
        reason _: String = "cancel"
    ) -> SameAppCloseProbePayload? {
        guard let controller,
              let open = controller.intentLedger.openSameAppCloseProbe()
        else {
            return nil
        }
        if let token, open.payload.focusedToken != token {
            return nil
        }
        _ = controller.intentLedger.cancel(id: open.intent.id)
        controller.deadlineWheel.cancel(intentId: open.intent.id)
        return open.payload
    }

    func holdSameAppCloseProbe(matchingFocusedToken token: WindowToken) {
        guard let controller,
              let open = controller.intentLedger.openSameAppCloseProbe(),
              open.payload.focusedToken == token
        else {
            return
        }
        controller.deadlineWheel.cancel(intentId: open.intent.id)
    }
}
