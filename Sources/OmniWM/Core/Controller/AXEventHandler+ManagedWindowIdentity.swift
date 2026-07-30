// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
extension AXEventHandler {
    @discardableResult
    func rekeyManagedWindowIdentity(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        admissionHints: ManagedWindowAdmissionHints? = nil,
        sizeConstraints: WindowSizeConstraints? = nil
    ) -> ManagedWindowIdentityRebindResult {
        guard let controller else { return .rejected }
        guard let oldEntry = controller.workspaceManager.entry(for: oldToken),
              oldToken == newToken || controller.workspaceManager.entry(for: newToken) == nil
        else {
            return .rejected
        }
        if let collision = controller.workspaceManager.entry(forWindowId: newToken.windowId),
           collision.token != oldToken
        {
            return .rejected
        }
        let oldWindow = AXManagedWindowIdentity(token: oldToken, axRef: oldEntry.axRef)
        let newWindow = AXManagedWindowIdentity(token: newToken, axRef: axRef)
        let changesRuntimeIdentity = oldToken != newToken
            || !CFEqual(oldEntry.axRef.element, axRef.element)
        let requiresAcknowledgement = changesRuntimeIdentity
            && (controller.hasStartedServices || oldToken.pid != newToken.pid)
        if requiresAcknowledgement {
            let scheduled = scheduleManagedWindowIdentityRebind(
                from: oldWindow,
                to: newWindow,
                managedReplacementMetadata: managedReplacementMetadata,
                admissionHints: admissionHints,
                sizeConstraints: sizeConstraints
            )
            return scheduled ? .pending : .rejected
        }
        guard let entry = commitManagedWindowIdentityRebind(
            from: oldToken,
            to: newToken,
            axRef: axRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) else { return .rejected }
        if let sizeConstraints {
            controller.workspaceManager.setCachedConstraints(sizeConstraints, for: newToken)
        }

        if changesRuntimeIdentity {
            controller.axManager.commitFrameApplicationStateForRebind(
                from: oldWindow,
                to: newWindow
            )
            bindCurrentManagedWindows(afterRebinding: oldWindow, to: newWindow)
        }
        finishManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            entry: entry,
            windowId: windowId,
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints
        )
        return .committed(entry)
    }

    func completeManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?,
        sizeConstraints: WindowSizeConstraints? = nil
    ) async {
        guard let controller else { return }
        var requiresBindingRefresh = false
        defer {
            if requiresBindingRefresh {
                bindCurrentManagedWindows(afterRebinding: oldWindow, to: newWindow)
            }
        }
        guard controller.hasStartedServices else {
            retryManagedWindowIdentityRebind(
                from: oldWindow,
                to: newWindow,
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner,
                managedReplacementMetadata: managedReplacementMetadata,
                admissionHints: admissionHints,
                sizeConstraints: sizeConstraints
            )
            return
        }

        let acknowledgement: AXManagedWindowRebindAcknowledgement?
        if let provider = managedWindowIdentityRebindAcknowledgementProvider {
            guard await provider(oldWindow, newWindow) else {
                retryManagedWindowIdentityRebind(
                    from: oldWindow,
                    to: newWindow,
                    windowId: windowId,
                    retryGeneration: retryGeneration,
                    executionOwner: executionOwner,
                    managedReplacementMetadata: managedReplacementMetadata,
                    admissionHints: admissionHints,
                    sizeConstraints: sizeConstraints
                )
                return
            }
            acknowledgement = nil
        } else {
            guard let acknowledged = await controller.axManager.rebindWindowAsync(
                from: oldWindow,
                to: newWindow
            ) else {
                retryManagedWindowIdentityRebind(
                    from: oldWindow,
                    to: newWindow,
                    windowId: windowId,
                    retryGeneration: retryGeneration,
                    executionOwner: executionOwner,
                    managedReplacementMetadata: managedReplacementMetadata,
                    admissionHints: admissionHints,
                    sizeConstraints: sizeConstraints
                )
                return
            }
            acknowledgement = acknowledged
        }

        guard isCurrentManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            windowId: windowId,
            retryGeneration: retryGeneration,
            executionOwner: executionOwner,
            acknowledgement: acknowledgement
        ) else {
            if let acknowledgement {
                controller.axManager.rollbackWindowRebind(
                    acknowledgement,
                    newWindow: newWindow
                )
            }
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }

        guard commitManagedWindowIdentityRebind(
            from: oldWindow.token,
            to: newWindow.token,
            axRef: newWindow.axRef,
            managedReplacementMetadata: managedReplacementMetadata
        ) != nil else {
            if let acknowledgement {
                controller.axManager.rollbackWindowRebind(
                    acknowledgement,
                    newWindow: newWindow
                )
            }
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        controller.axManager.commitFrameApplicationStateForRebind(
            from: oldWindow,
            to: newWindow,
            acknowledgement: acknowledgement
        )
        requiresBindingRefresh = true
        guard currentManagedWindowIdentityRebindEntry(
            from: oldWindow,
            to: newWindow,
            windowId: windowId,
            retryGeneration: retryGeneration,
            executionOwner: executionOwner,
            acknowledgement: acknowledgement
        ) != nil else {
            if let acknowledgement {
                controller.axManager.rollbackWindowRebind(
                    acknowledgement,
                    newWindow: newWindow
                )
            }
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        if let sizeConstraints {
            controller.workspaceManager.setCachedConstraints(sizeConstraints, for: newWindow.token)
        }

        let finalized = if let provider = managedWindowIdentityRebindFinalizationProvider {
            await provider(oldWindow, newWindow)
        } else {
            await controller.axManager.finalizeWindowRebindContextState(
                from: oldWindow,
                to: newWindow,
                acknowledgement: acknowledgement
            )
        }
        guard finalized else {
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        guard let currentEntry = currentManagedWindowIdentityRebindEntry(
            from: oldWindow,
            to: newWindow,
            windowId: windowId,
            retryGeneration: retryGeneration,
            executionOwner: executionOwner,
            acknowledgement: acknowledgement
        ) else {
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        finishManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            entry: currentEntry,
            windowId: windowId,
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints
        )
    }

    private func bindCurrentManagedWindows(
        afterRebinding oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) {
        guard let controller else { return }
        controller.axManager.bindManagedWindows(
            controller.workspaceManager.entries(forPid: oldWindow.token.pid)
        )
        if oldWindow.token.pid != newWindow.token.pid {
            controller.axManager.bindManagedWindows(
                controller.workspaceManager.entries(forPid: newWindow.token.pid)
            )
        }
    }

    private func isCurrentManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) -> Bool {
        guard let controller,
              controller.hasStartedServices,
              !Task.isCancelled,
              newWindow.token.windowId == Int(windowId),
              let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner),
              !state.identityRebindTargetDestroyed,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              let oldEntry = controller.workspaceManager.entry(for: oldWindow.token),
              CFEqual(oldEntry.axRef.element, oldWindow.axRef.element),
              oldWindow.token == newWindow.token
              || controller.workspaceManager.entry(for: newWindow.token) == nil,
              isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        else {
            return false
        }
        if let collision = controller.workspaceManager.entry(forWindowId: newWindow.token.windowId),
           collision.token != oldWindow.token
        {
            return false
        }
        if let acknowledgement,
           !controller.axManager.isCurrentWindowRebindAcknowledgement(
               acknowledgement,
               from: oldWindow,
               to: newWindow
           )
        {
            return false
        }
        return true
    }

    private func currentManagedWindowIdentityRebindEntry(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) -> WindowState? {
        guard let controller,
              controller.hasStartedServices,
              !Task.isCancelled,
              newWindow.token.windowId == Int(windowId),
              let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner),
              !state.identityRebindTargetDestroyed,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              let entry = controller.workspaceManager.entry(for: newWindow.token),
              CFEqual(entry.axRef.element, newWindow.axRef.element),
              controller.workspaceManager.entry(forWindowId: newWindow.token.windowId)?.token == newWindow.token,
              isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        else {
            return nil
        }
        if let acknowledgement,
           !controller.axManager.isCurrentWindowRebindAcknowledgement(
               acknowledgement,
               from: oldWindow,
               to: newWindow
           )
        {
            return nil
        }
        return entry
    }

    private func retryManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?,
        sizeConstraints: WindowSizeConstraints?
    ) {
        guard let controller else { return }
        guard var state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner)
        else {
            return
        }
        if state.identityRebindTargetDestroyed {
            cancelCreatedWindowRetry(windowId: windowId)
            discardDeferredReplacementProtection(windowId: windowId)
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        if controller.hasStartedServices,
           !isManagedWindowIdentityRebindTargetAlive(pid: newWindow.token.pid)
        {
            retireStaleManagedWindowIdentityRebind(
                windowId: windowId,
                retryGeneration: retryGeneration,
                executionOwner: executionOwner
            )
            requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
            return
        }
        state.task = nil
        state.executionPhase = .waiting
        admissionRetryStateByWindowId[windowId] = state
        _ = scheduleManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints,
            sizeConstraints: sizeConstraints
        )
    }

    private func isManagedWindowIdentityRebindTargetAlive(pid: pid_t) -> Bool {
        if let provider = managedWindowIdentityRebindTargetIsAliveProvider {
            return provider(pid)
        }
        return NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    private func retireStaleManagedWindowIdentityRebind(
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64
    ) {
        guard let state = admissionRetryStateByWindowId[windowId],
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner)
        else {
            return
        }
        cancelCreatedWindowRetry(windowId: windowId)
        discardDeferredReplacementProtection(windowId: windowId)
    }

    private func finishManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        entry: WindowState,
        windowId: UInt32,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?
    ) {
        guard let controller else { return }
        if let admissionHints {
            _ = controller.workspaceManager.updateAdmissionHints(admissionHints, for: newWindow.token)
        }
        if let workspaceId = managedReplacementMetadata?.workspaceId {
            rekeyManagedReplacementFocusTransaction(
                from: oldWindow.token,
                to: newWindow.token,
                workspaceId: workspaceId
            )
        }

        finishAdmissionRetryAfterTracking(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        cancelPostCreateLifecycleVerification(for: oldWindow.token)
        cancelSameAppCloseProbe(matchingFocusedToken: oldWindow.token, reason: "identity_rebind")
        clearTerminalFrameFailure(windowId: oldWindow.token.windowId)
        admissionQuarantineByWindowId.removeValue(forKey: oldWindow.token.windowId)
        identityAliasesByWindowId.removeValue(forKey: oldWindow.token.windowId)
        AXWindowService.invalidateCachedTitles(windowIds: [UInt32(oldWindow.token.windowId), windowId])
        scheduleWindowRuleReevaluationIfNeeded(targets: [.window(entry.token)])
        WindowAdmissionTrace.record(
            .init(
                action: .admissionReplaced,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier,
                competingPid: oldWindow.token.pid,
                reason: managedReplacementMetadata == nil
                    ? "identity_rekeyed"
                    : "structural_managed_replacement",
                outcome: "oldWindowId=\(oldWindow.token.windowId)",
                axRef: newWindow.axRef
            )
        )
        controller.requestWorkspaceBarRefresh()
        controller.surfaceReconciler.noteRestackOccurred()
    }

    private func commitManagedWindowIdentityRebind(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata?
    ) -> WindowState? {
        guard let controller else { return nil }
        let focusTransactionIds = controller.dwindleLayoutHandler
            .currentPendingGroupRevealFocusTransactionIds(for: oldToken)
        return controller.withRuntimeFrameJobCancellationSuppressed {
            guard let entry = controller.workspaceManager.rekeyWindow(
                from: oldToken,
                to: newToken,
                newAXRef: axRef,
                managedReplacementMetadata: managedReplacementMetadata
            )
            else {
                return nil
            }

            controller.intentLedger.rekeyManagedRequest(from: oldToken, to: newToken)
            controller.rekeyScratchpadWindowResources(from: oldToken, to: newToken, axRef: axRef)
            controller.layoutRefreshController.rekeyPendingRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry
            )
            controller.layoutRefreshController.rekeyNativeFullscreenRestoredFrameApply(
                from: oldToken,
                to: newToken
            )
            controller.dwindleLayoutHandler.rekeyPendingGroupRevealTransaction(
                from: oldToken,
                to: newToken,
                entry: entry,
                rebasingFocusTransactionIds: focusTransactionIds
            )
            return entry
        }
    }

    @discardableResult
    private func scheduleManagedWindowIdentityRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?,
        sizeConstraints: WindowSizeConstraints?
    ) -> Bool {
        guard let windowId = UInt32(exactly: newWindow.token.windowId) else { return false }
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: newWindow.token,
            axRef: newWindow.axRef,
            reason: .factsDeferred,
            trigger: .identityRebind(
                oldWindow: oldWindow,
                newWindow: newWindow,
                managedReplacementMetadata: managedReplacementMetadata,
                admissionHints: admissionHints,
                sizeConstraints: sizeConstraints
            )
        )
    }
}
