// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        guard let controller else { return }

        cleanupAdmissionStateForTerminatedApp(pid: pid)
        admissionQuarantineByWindowId = admissionQuarantineByWindowId.filter { $0.value.token.pid != pid }
        terminalFrameFailureStateByWindowId = terminalFrameFailureStateByWindowId.filter { windowId, _ in
            controller.workspaceManager.entry(forWindowId: windowId)?.pid != pid
        }
        clearManagedReplacementFocusTransactions(pid: pid, reason: "app_terminated")
        let entries = controller.workspaceManager.entries(forPid: pid)
        for entry in entries {
            clearManagedFocusState(
                matching: entry.token,
                workspaceId: controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId
            )
        }

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            clearManagedFocusState(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId
            )
        }

        controller.workspaceManager.clearNonManagedFocusTarget(pid: pid)
    }

    func handleAppTerminationFocusActivation(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        callbackGeneration: UInt64?
    ) -> Bool {
        guard origin == .external, let controller else { return false }

        if let open = controller.intentLedger.openAppTerminationFocusRecovery() {
            if pid == open.payload.preferredTiledToken.pid {
                return false
            }
            if hasExplicitFocusIntent(forPID: pid) {
                cancelAppTerminationFocusRecovery(open.intent.id)
                return false
            }
            if pid == open.payload.departingToken.pid {
                return true
            }

            switch open.payload.phase {
            case let .verifying(candidatePID, _, _):
                guard pid == candidatePID else {
                    cancelAppTerminationFocusRecovery(open.intent.id)
                    return false
                }
                return true

            case let .recovering(fallbackPID):
                guard let fallbackPID else {
                    controller.intentLedger.updateAppTerminationFocusRecovery(id: open.intent.id) {
                        $0.phase = .recovering(fallbackPID: pid)
                    }
                    return true
                }
                guard pid == fallbackPID else {
                    cancelAppTerminationFocusRecovery(open.intent.id)
                    return false
                }
                return true

            case let .retiring(fallbackPID):
                guard fallbackPID == nil || pid == fallbackPID else {
                    cancelAppTerminationFocusRecovery(open.intent.id)
                    return false
                }
                return true
            }
        }

        guard let departingToken = controller.workspaceManager.focusedToken,
              departingToken.pid != pid,
              let departingEntry = controller.workspaceManager.entry(for: departingToken),
              departingEntry.mode == .floating,
              departingEntry.interactionPolicy.mayFocus,
              let monitorId = controller.workspaceManager.monitorId(for: departingEntry.workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitorId)?.id == departingEntry.workspaceId,
              let preferredTiledToken = controller.workspaceManager.preferredFocusToken(
                  in: departingEntry.workspaceId
              ),
              preferredTiledToken != departingToken,
              preferredTiledToken.pid != departingToken.pid,
              preferredTiledToken.pid != pid,
              controller.intentLedger.activeManagedRequest == nil,
              !hasRecentMouseFocusIntent(forPID: pid)
        else {
            return false
        }

        let intent = controller.intentLedger.registerAppTerminationFocusRecovery(
            AppTerminationFocusRecoveryPayload(
                departingToken: departingToken,
                workspaceId: departingEntry.workspaceId,
                preferredTiledToken: preferredTiledToken,
                phase: .verifying(
                    candidatePID: pid,
                    source: source,
                    callbackGeneration: callbackGeneration
                )
            )
        )
        controller.deadlineWheel.schedule(intentId: intent.id, after: .zero)
        return true
    }

    func beginAppTerminationFocusRecovery(
        pid: pid_t,
        fallbackPID: pid_t?
    ) -> (workspaceId: WorkspaceDescriptor.ID, preferredToken: WindowToken)? {
        guard let controller else { return nil }

        if let open = controller.intentLedger.openAppTerminationFocusRecovery(),
           open.payload.departingToken.pid == pid
        {
            guard !open.payload.terminationHandled else { return nil }
            let resolvedFallbackPID = appTerminationFallbackPID(
                fallbackPID,
                payload: open.payload
            ) ?? appTerminationFallbackPID(
                open.payload.phase.candidatePID,
                payload: open.payload
            )
            let payload = AppTerminationFocusRecoveryPayload(
                departingToken: open.payload.departingToken,
                workspaceId: open.payload.workspaceId,
                preferredTiledToken: open.payload.preferredTiledToken,
                phase: .recovering(fallbackPID: resolvedFallbackPID),
                terminationHandled: true
            )
            let intent = controller.intentLedger.registerAppTerminationFocusRecovery(payload)
            controller.deadlineWheel.schedule(
                intentId: intent.id,
                after: Self.appTerminationFocusRecoveryTimeout
            )
            return (payload.workspaceId, payload.preferredTiledToken)
        }

        guard let departingToken = controller.workspaceManager.focusedToken,
              departingToken.pid == pid,
              let departingEntry = controller.workspaceManager.entry(for: departingToken),
              departingEntry.mode == .floating,
              departingEntry.interactionPolicy.mayFocus,
              let preferredTiledToken = controller.workspaceManager.preferredFocusToken(
                  in: departingEntry.workspaceId
              ),
              preferredTiledToken != departingToken,
              preferredTiledToken.pid != departingToken.pid
        else {
            return nil
        }

        let payload = AppTerminationFocusRecoveryPayload(
            departingToken: departingToken,
            workspaceId: departingEntry.workspaceId,
            preferredTiledToken: preferredTiledToken,
            phase: .recovering(
                fallbackPID: appTerminationFallbackPID(
                    fallbackPID,
                    departingToken: departingToken,
                    preferredTiledToken: preferredTiledToken
                )
            ),
            terminationHandled: true
        )
        let intent = controller.intentLedger.registerAppTerminationFocusRecovery(payload)
        controller.deadlineWheel.schedule(
            intentId: intent.id,
            after: Self.appTerminationFocusRecoveryTimeout
        )
        return (payload.workspaceId, payload.preferredTiledToken)
    }

    func handleAppTerminationFocusRecoveryDeadline(
        intentId: IntentID,
        payload: AppTerminationFocusRecoveryPayload
    ) {
        guard let controller,
              controller.intentLedger.openAppTerminationFocusRecovery()?.intent.id == intentId
        else {
            return
        }

        switch payload.phase {
        case let .verifying(candidatePID, source, callbackGeneration):
            if hasExplicitFocusIntent(forPID: candidatePID) {
                _ = controller.intentLedger.markExpired(id: intentId)
                handleAppActivation(
                    pid: candidatePID,
                    source: source,
                    origin: .appTerminationProbe,
                    callbackGeneration: callbackGeneration
                )
                return
            }
            if applicationIsTerminatedProvider(payload.departingToken.pid) {
                let recoveryPayload = AppTerminationFocusRecoveryPayload(
                    departingToken: payload.departingToken,
                    workspaceId: payload.workspaceId,
                    preferredTiledToken: payload.preferredTiledToken,
                    phase: .recovering(fallbackPID: candidatePID)
                )
                let recoveryIntent = controller.intentLedger.registerAppTerminationFocusRecovery(
                    recoveryPayload
                )
                controller.deadlineWheel.schedule(
                    intentId: recoveryIntent.id,
                    after: Self.appTerminationFocusRecoveryTimeout
                )
                if !EventIntake.post(
                    .appTerminated(
                        pid: payload.departingToken.pid,
                        frontmostPID: candidatePID
                    )
                ) {
                    cancelAppTerminationFocusRecovery(recoveryIntent.id)
                }
                return
            }

            _ = controller.intentLedger.markExpired(id: intentId)
            handleAppActivation(
                pid: candidatePID,
                source: source,
                origin: .appTerminationProbe,
                callbackGeneration: callbackGeneration
            )

        case let .recovering(fallbackPID):
            _ = controller.intentLedger.markExpired(id: intentId)
            guard let fallbackPID,
                  frontmostApplicationPIDProvider() == fallbackPID
            else {
                return
            }
            if let activeRequest = controller.intentLedger.activeManagedRequest,
               activeRequest.token != payload.preferredTiledToken,
               activeRequest.token.pid != fallbackPID
            {
                return
            }
            handleAppActivation(
                pid: fallbackPID,
                source: .workspaceDidActivateApplication,
                origin: .external
            )

        case .retiring:
            _ = controller.intentLedger.markExpired(id: intentId)
        }
    }

    func completeAppTerminationFocusRecoveryIfNeeded(_ token: WindowToken) {
        guard let controller,
              let open = controller.intentLedger.openAppTerminationFocusRecovery(),
              open.payload.preferredTiledToken == token
        else {
            return
        }
        let fallbackPID = open.payload.phase.fallbackPID
        controller.intentLedger.updateAppTerminationFocusRecovery(id: open.intent.id) {
            $0.phase = .retiring(fallbackPID: fallbackPID)
        }
        controller.deadlineWheel.schedule(intentId: open.intent.id, after: .zero)
    }

    func preservesAppTerminationRecoveryViewport(for token: WindowToken) -> Bool {
        controller?.intentLedger.openAppTerminationFocusRecovery()?.payload.preferredTiledToken == token
    }

    private func hasExplicitFocusIntent(forPID pid: pid_t) -> Bool {
        hasRecentMouseFocusIntent(forPID: pid)
            || controller?.intentLedger.activeManagedRequest?.token.pid == pid
    }

    private func appTerminationFallbackPID(
        _ pid: pid_t?,
        payload: AppTerminationFocusRecoveryPayload
    ) -> pid_t? {
        appTerminationFallbackPID(
            pid,
            departingToken: payload.departingToken,
            preferredTiledToken: payload.preferredTiledToken
        )
    }

    private func appTerminationFallbackPID(
        _ pid: pid_t?,
        departingToken: WindowToken,
        preferredTiledToken: WindowToken
    ) -> pid_t? {
        guard let pid,
              pid != departingToken.pid,
              pid != preferredTiledToken.pid
        else {
            return nil
        }
        return pid
    }

    private func cancelAppTerminationFocusRecovery(_ intentId: IntentID) {
        guard let controller else { return }
        _ = controller.intentLedger.cancel(id: intentId)
        controller.deadlineWheel.cancel(intentId: intentId)
    }
}

private extension AppTerminationFocusRecoveryPhase {
    var candidatePID: pid_t? {
        guard case let .verifying(candidatePID, _, _) = self else { return nil }
        return candidatePID
    }

    var fallbackPID: pid_t? {
        switch self {
        case .verifying:
            nil
        case let .recovering(fallbackPID),
             let .retiring(fallbackPID):
            fallbackPID
        }
    }
}
