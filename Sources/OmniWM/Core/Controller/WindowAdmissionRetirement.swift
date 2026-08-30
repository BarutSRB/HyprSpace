// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension AXEventHandler {
    func clearTerminalFrameFailure(windowId: Int) {
        terminalFrameFailureStateByWindowId.removeValue(forKey: windowId)
    }

    func discardStaleManagedWindowIncarnation(_ entry: WindowState) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDisappeared,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: entry.managedReplacementMetadata?.bundleId,
                reason: "stale_ax_incarnation",
                axRef: entry.axRef
            )
        )
        retireManagedWindow(entry, reason: .staleIncarnation)
    }

    func retireManagedWindow(
        _ entry: WindowState,
        reason: ManagedWindowRetirementReason
    ) {
        guard let controller else { return }
        let token = entry.token
        let workspaceId = entry.workspaceId
        let layoutType = controller.workspaceManager.descriptor(for: workspaceId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        let ownsLiveFocus = controller.workspaceManager.focusedToken == token
            || controller.workspaceManager.nonManagedFocusToken == token
        let removesScratchpadResources = controller.workspaceManager.isScratchpadToken(token)
            || controller.workspaceManager.hiddenState(for: token)?.isScratchpad == true
        let policy = retirementPolicy(for: reason)

        var oldFrames: [WindowToken: CGRect] = [:]
        var removedNodeId: NodeId?
        var removedNiriColumn = false
        if layoutType != .dwindle, let engine = controller.niriEngine {
            oldFrames = engine.captureWindowFrames(in: workspaceId)
            let node = engine.findNode(for: token, in: workspaceId)
            removedNodeId = node?.id
            removedNiriColumn = node.flatMap { engine.column(of: $0) }?.windowNodes.count == 1
        }

        clearTerminalFrameFailure(windowId: token.windowId)
        cancelCreatedWindowRetry(windowId: token.windowId)
        cancelPostCreateLifecycleVerification(for: token)
        cancelSameAppCloseProbe(matchingFocusedToken: token, reason: policy.traceReason)
        if let request = controller.intentLedger.activeManagedRequest(for: token),
           case .awaitingSameAppActivation = request.phase
        {
            controller.cancelManagedFocusRequestAndRestoreSource(request)
        } else {
            clearManagedFocusState(matching: token, workspaceId: workspaceId)
        }
        controller.mouseEventHandler.discardNativeTitleBarDrag(for: token)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        finishDeferredReplacementAfterTracking(windowId: token.windowId)
        controller.axManager.removeWindowState(pid: token.pid, expectedWindow: entry.axRef)
        if removesScratchpadResources {
            controller.cleanupScratchpadWindowResources(for: token)
        }
        controller.clearManualWindowOverride(for: token)
        if policy.removesIdentityAliases {
            identityAliasesByWindowId.removeValue(forKey: token.windowId)
        }

        controller.layoutRefreshController.requestWindowRemoval(
            workspaceId: workspaceId,
            layoutType: layoutType,
            removedNodeId: removedNodeId,
            removedNiriColumn: removedNiriColumn,
            niriOldFrames: oldFrames,
            shouldRecoverFocus: policy.shouldRecoverFocus,
            allowsPreferredRecoveryToken: policy.allowsPreferredRecoveryToken
        )
        if case .terminalFrameRefusal = reason {
            if ownsLiveFocus {
                _ = controller.workspaceManager.enterNonManagedFocus(target: token)
            }
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }

    func retireManagedWindowFromAuthoritativeRescan(_ entry: WindowState) {
        let shouldRecoverFocus = controller?.workspaceManager.focusedToken == entry.token
        retireManagedWindow(
            entry,
            reason: .destroyed(
                shouldRecoverFocus: shouldRecoverFocus,
                allowsPreferredRecoveryToken: false
            )
        )
    }

    func handleTerminalFrameRefusal(_ refusal: AXFrameTerminalRefusal) {
        guard let controller,
              let entry = terminalRefusalEntry(refusal, controller: controller)
        else { return }
        WindowAdmissionTrace.record(
            .init(
                action: .terminalFrameRefusal,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: entry.managedReplacementMetadata?.bundleId,
                reason: refusal.failureReason.traceDescription,
                targetFrame: refusal.targetFrame,
                observedFrame: refusal.observedFrame,
                axRef: entry.axRef
            )
        )

        guard recordTerminalFrameFailure(for: entry) >= 2 else {
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
            controller.layoutRefreshController.requestRelayout(
                reason: .observedConstraintsChanged,
                affectedWorkspaceIds: [entry.workspaceId]
            )
            return
        }

        quarantineAfterTerminalFrameRefusal(entry)
        if let windowId = UInt32(exactly: refusal.windowId) {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .admissionRejected(
                        windowId: windowId,
                        pid: entry.pid,
                        reason: .terminalFrameRefusal
                    )
                )
            )
        }
    }

    private func retirementPolicy(
        for reason: ManagedWindowRetirementReason
    ) -> ManagedWindowRetirementPolicy {
        switch reason {
        case let .destroyed(shouldRecoverFocus, allowsPreferredRecoveryToken):
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: shouldRecoverFocus,
                allowsPreferredRecoveryToken: allowsPreferredRecoveryToken,
                traceReason: "focused_token_removed",
                removesIdentityAliases: true
            )
        case .staleIncarnation:
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false,
                traceReason: "stale_ax_incarnation",
                removesIdentityAliases: true
            )
        case .terminalFrameRefusal:
            return ManagedWindowRetirementPolicy(
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false,
                traceReason: "admission_quarantine",
                removesIdentityAliases: false
            )
        }
    }

    private func terminalRefusalEntry(
        _ refusal: AXFrameTerminalRefusal,
        controller: WMController
    ) -> WindowState? {
        guard isAdmissionRefusal(refusal.failureReason) else { return nil }
        guard WMController.isMeaningfulAdmissionFrame(refusal.targetFrame),
              !WMController.isMeaningfulAdmissionFrame(refusal.observedFrame)
        else {
            controller.adoptObservedMinimumAfterTerminalSizeWriteFailure(refusal)
            return nil
        }
        guard let entry = controller.workspaceManager.entry(forWindowId: refusal.windowId),
              entry.mode == .tiling,
              controller.workspaceManager.hiddenState(for: entry.token) == nil
        else { return nil }
        return entry
    }

    private func isAdmissionRefusal(_ reason: AXFrameWriteFailureReason) -> Bool {
        switch reason {
        case .sizeWriteFailed,
             .verificationMismatch:
            true
        default:
            false
        }
    }

    private func recordTerminalFrameFailure(for entry: WindowState) -> Int {
        if var state = terminalFrameFailureStateByWindowId[entry.windowId],
           CFEqual(state.axRef.element, entry.axRef.element)
        {
            state.count += 1
            terminalFrameFailureStateByWindowId[entry.windowId] = state
            return state.count
        }
        terminalFrameFailureStateByWindowId[entry.windowId] = TerminalFrameFailureState(
            axRef: entry.axRef,
            count: 1
        )
        return 1
    }

    private func quarantineAfterTerminalFrameRefusal(_ entry: WindowState) {
        admissionQuarantineByWindowId[entry.windowId] = AdmissionQuarantine(
            token: entry.token,
            axRef: entry.axRef
        )
        WindowAdmissionTrace.record(
            .init(
                action: .admissionQuarantined,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: entry.managedReplacementMetadata?.bundleId,
                reason: WindowAdmissionRejectionReason.terminalFrameRefusal.rawValue,
                axRef: entry.axRef
            )
        )
        retireManagedWindow(entry, reason: .terminalFrameRefusal)
    }
}
