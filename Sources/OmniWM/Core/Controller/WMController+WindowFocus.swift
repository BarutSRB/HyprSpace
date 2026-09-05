// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension WMController {
    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    func isOwnedWindow(windowNumber: Int) -> Bool {
        ownedWindowRegistry.contains(windowNumber: windowNumber)
    }

    var isSystemModalFocusActive: Bool {
        guard let systemModalFocusToken = workspaceManager.systemModalFocusToken else { return false }
        return systemModalFocusToken == workspaceManager.nativeManagedFocusToken
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        if isSystemModalFocusActive { return true }
        switch workspaceManager.nativeFocusOwner {
        case .external,
             .ownedSurface:
            return true
        case .managed,
             .none:
            return false
        }
    }

    private func canFocusWindow(
        pid: pid_t,
        windowId: Int
    ) -> Bool {
        guard !isLockScreenActive else { return false }
        if hasStartedServices, isFrontmostAppLockScreen() {
            return false
        }
        guard !workspaceManager.isAppHidden(pid: pid) else { return false }
        if let entry = workspaceManager.entry(forWindowId: windowId),
           workspaceManager.isAppHidden(pid: entry.pid)
        {
            return false
        }
        return focusPolicyEngine.evaluate(.windowFronting).allowsFocusChange
    }

    @discardableResult
    func performWindowFronting(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) -> Bool {
        guard canFocusWindow(pid: pid, windowId: windowId) else { return false }
        MainThreadAXSpanTrace.measure(.fronting, pid: pid, windowId: windowId) {
            windowFocusOperations.activateApp(pid)
            windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
            windowFocusOperations.raiseWindow(axRef.element)
        }
        return true
    }

    @discardableResult
    private func performWindowFocusOnly(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) -> Bool {
        guard canFocusWindow(pid: pid, windowId: windowId) else { return false }
        windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
        return true
    }

    func performWindowOrdering(windowId: Int) {
        if let entry = workspaceManager.entry(forWindowId: windowId),
           workspaceManager.isAppHidden(pid: entry.pid)
        {
            return
        }
        windowFocusOperations.orderWindow(UInt32(windowId))
    }

    func retryManagedFocusFronting(_ request: ManagedFocusRequest) {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              let entry = workspaceManager.entry(for: liveRequest.token),
              entry.workspaceId == request.workspaceId,
              !isManagedWindowSuppressedByMacOSHide(liveRequest.token)
        else {
            return
        }
        _ = applyManagedFocusRequest(
            liveRequest,
            entry: entry,
            validatesPointer: true,
            isRetry: true
        )
    }

    @discardableResult
    private func applyManagedFocusRequest(
        _ request: ManagedFocusRequest,
        entry: WindowState,
        validatesPointer: Bool,
        isRetry: Bool = false,
        preferredSameAppSourceToken: WindowToken? = nil
    ) -> Bool {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == entry.token,
              liveRequest.workspaceId == entry.workspaceId,
              workspaceManager.pendingManagedFocusMatches(
                  token: liveRequest.token,
                  workspaceId: liveRequest.workspaceId,
                  requestId: liveRequest.requestId
              )
        else {
            return false
        }

        if liveRequest.origin == .focusFollowsMouse {
            guard focusFollowsMouseEnabled else {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
            if validatesPointer,
               mouseEventHandler.hasLatestFocusFollowsMouseSample,
               mouseEventHandler.latestFocusFollowsMouseToken() != liveRequest.token
            {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
            guard focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange else {
                cancelManagedFocusRequestAndRestoreSource(liveRequest)
                return false
            }
        }

        let focusesWithoutRaise = liveRequest.origin == .focusFollowsMouse
            && !settings.raiseOnMouseFocus
        guard focusesWithoutRaise else {
            let applied = performWindowFronting(
                pid: entry.pid,
                windowId: entry.windowId,
                axRef: entry.axRef
            )
            if applied, case .awaitingSameAppActivation = liveRequest.phase {
                _ = intentLedger.completeSameAppActivationHandoff(
                    requestId: liveRequest.requestId
                )
            } else if !applied,
                      case let .awaitingSameAppActivation(sourceToken, _) = liveRequest.phase
            {
                cancelManagedFocusRequestAndRestoreSource(
                    liveRequest,
                    sourceToken: sourceToken
                )
            } else if !applied, liveRequest.origin == .focusFollowsMouse {
                cancelManagedFocusRequest(liveRequest)
            }
            return applied
        }
        guard canFocusWindow(pid: entry.pid, windowId: entry.windowId) else {
            cancelManagedFocusRequestAndRestoreSource(liveRequest)
            return false
        }
        if case .awaitingSameAppActivation = liveRequest.phase {
            return false
        }
        if let sourceToken = preferredSameAppSourceToken ?? workspaceManager.renderableFocusToken,
           sourceToken != liveRequest.token,
           sourceToken.pid == liveRequest.token.pid,
           let sourceEntry = workspaceManager.entry(for: sourceToken),
           sourceEntry.pid == entry.pid,
           isManagedWindowDisplayable(sourceToken),
           let sourceWindowId = UInt32(exactly: sourceEntry.windowId)
        {
            guard let stagedRequest = intentLedger.beginSameAppActivationHandoff(
                requestId: liveRequest.requestId,
                sourceToken: sourceToken,
                isRetry: isRetry
            ) else {
                return false
            }
            guard windowFocusOperations.deactivateSameAppWindow(entry.pid, sourceWindowId) else {
                cancelManagedFocusRequest(stagedRequest)
                return false
            }
            return false
        }
        return performWindowFocusOnly(
            pid: entry.pid,
            windowId: entry.windowId,
            axRef: entry.axRef
        )
    }

    func completeSameAppFocusHandoff(_ request: ManagedFocusRequest) {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              case let .awaitingSameAppActivation(sourceToken, isRetry) = liveRequest.phase,
              let entry = workspaceManager.entry(for: liveRequest.token),
              entry.workspaceId == liveRequest.workspaceId,
              workspaceManager.pendingManagedFocusMatches(
                  token: liveRequest.token,
                  workspaceId: liveRequest.workspaceId,
                  requestId: liveRequest.requestId
              )
        else {
            return
        }
        guard focusFollowsMouseEnabled,
              !mouseEventHandler.hasLatestFocusFollowsMouseSample
              || mouseEventHandler.latestFocusFollowsMouseToken() == liveRequest.token,
              focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              canFocusWindow(pid: entry.pid, windowId: entry.windowId)
        else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        let raisesWindow = settings.raiseOnMouseFocus
        if raisesWindow {
            windowFocusOperations.activateApp(entry.pid)
        }
        guard windowFocusOperations.activateAndFocusSameAppWindow(
            entry.pid,
            UInt32(entry.windowId),
            entry.axRef.element
        ) else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        if raisesWindow {
            windowFocusOperations.raiseWindow(entry.axRef.element)
        }
        guard let confirmationRequest = intentLedger.completeSameAppActivationHandoff(
            requestId: liveRequest.requestId
        ) else {
            cancelManagedFocusRequestAndRestoreSource(
                liveRequest,
                sourceToken: sourceToken
            )
            return
        }
        if isRetry {
            _ = axEventHandler.handleAppActivation(
                pid: confirmationRequest.token.pid,
                source: confirmationRequest.lastActivationSource ?? .focusedWindowChanged,
                origin: .retry
            )
        } else {
            axEventHandler.probeFocusedWindowAfterFronting(
                expectedToken: confirmationRequest.token,
                workspaceId: confirmationRequest.workspaceId
            )
        }
    }

    @discardableResult
    func cancelManagedFocusRequest(_ request: ManagedFocusRequest) -> ManagedFocusRequest? {
        cancelManagedFocusRequest(request, restoringSameAppSource: nil)
    }

    @discardableResult
    func cancelManagedFocusRequestAndRestoreSource(
        _ request: ManagedFocusRequest,
        sourceToken: WindowToken? = nil
    ) -> ManagedFocusRequest? {
        let resolvedSourceToken: WindowToken? = if let sourceToken {
            sourceToken
        } else if case let .awaitingSameAppActivation(sourceToken, _) = request.phase {
            sourceToken
        } else {
            nil
        }
        return cancelManagedFocusRequest(
            request,
            restoringSameAppSource: resolvedSourceToken
        )
    }

    @discardableResult
    private func cancelManagedFocusRequest(
        _ request: ManagedFocusRequest,
        restoringSameAppSource sourceToken: WindowToken?
    ) -> ManagedFocusRequest? {
        guard let liveRequest = intentLedger.activeManagedRequest(requestId: request.requestId),
              liveRequest.token == request.token,
              liveRequest.workspaceId == request.workspaceId,
              let canceledRequest = intentLedger.cancelManagedRequest(requestId: request.requestId)
        else {
            return nil
        }
        _ = workspaceManager.cancelManagedFocusRequest(
            matching: canceledRequest.token,
            workspaceId: canceledRequest.workspaceId,
            requestId: canceledRequest.requestId
        )
        abortScratchpadStacking(matching: canceledRequest.requestId)
        if let sourceToken {
            restoreSameAppFocusSource(sourceToken, canceledRequest: canceledRequest)
        }
        return canceledRequest
    }

    private func restoreSameAppFocusSource(
        _ sourceToken: WindowToken,
        canceledRequest: ManagedFocusRequest
    ) {
        guard sourceToken.pid == canceledRequest.token.pid,
              sourceToken != canceledRequest.token,
              workspaceManager.renderableFocusToken == sourceToken,
              !hasFrontmostOwnedWindow,
              let sourceEntry = workspaceManager.entry(for: sourceToken),
              isManagedWindowDisplayable(sourceToken),
              focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange,
              canFocusWindow(pid: sourceEntry.pid, windowId: sourceEntry.windowId)
        else {
            return
        }
        if hasStartedServices,
           axEventHandler.frontmostApplicationPIDProvider() != sourceEntry.pid
        {
            return
        }
        axEventHandler.noteMouseFocusIntent(token: sourceToken)
        _ = windowFocusOperations.activateAndFocusSameAppWindow(
            sourceEntry.pid,
            UInt32(sourceEntry.windowId),
            sourceEntry.axRef.element
        )
    }

    func activateNativeFullscreenPlaceholder(_ originalToken: WindowToken) {
        guard let record = workspaceManager.nativeFullscreenRecord(originalToken: originalToken) else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .activationRejected,
                    originalToken: originalToken,
                    reason: .recordLookupFailed
                )
            )
            return
        }
        guard record.transition == .suspended else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .activationRejected,
                    originalToken: originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    transition: .init(record.transition),
                    generation: record.transitionGeneration,
                    reason: .transitionPending
                )
            )
            return
        }
        let currentToken = record.currentToken
        guard let entry = workspaceManager.entry(for: currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .entryMissing)
            return
        }
        guard !isManagedWindowSuppressedByMacOSHide(currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .appHidden)
            return
        }
        guard workspaceManager.showsNativeFullscreenPlaceholder(for: currentToken) else {
            traceNativeFullscreenActivationRejected(record, reason: .placeholderUnavailable)
            return
        }
        guard !isLockScreenActive else {
            traceNativeFullscreenActivationRejected(record, reason: .lockScreen)
            return
        }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else {
                traceNativeFullscreenActivationRejected(record, reason: .lockScreen)
                return
            }
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationResolved,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: record.transitionGeneration,
                reason: .accepted
            )
        )
        selectNativeFullscreenPlaceholder(entry)
        performWindowFronting(pid: entry.pid, windowId: entry.windowId, axRef: entry.axRef)
    }

    private func traceNativeFullscreenActivationRejected(
        _ record: WorkspaceManager.NativeFullscreenRecord,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationRejected,
                originalToken: record.originalToken,
                currentToken: record.currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: record.transitionGeneration,
                reason: reason
            )
        )
    }

    @discardableResult
    private func selectNativeFullscreenPlaceholder(_ entry: WindowState) -> Bool {
        let token = entry.token
        let changed = workspaceManager.selectNativeFullscreenPlaceholder(
            token,
            in: entry.workspaceId,
            onMonitor: workspaceManager.monitorId(for: entry.workspaceId)
        )
        let workspaceId = workspaceManager.workspace(for: token) ?? entry.workspaceId
        if let activeRequest = intentLedger.activeManagedRequest {
            _ = cancelManagedFocusRequest(activeRequest)
        } else {
            _ = workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        intentLedger.discardPendingFocus(token)
        if changed {
            layoutRefreshController.requestImmediateRelayout(
                reason: .appActivationTransition,
                affectedWorkspaceIds: [workspaceId]
            )
        }
        return changed
    }

    func restoreQuakeTerminalFocus(to target: QuakeTerminalRestoreTarget) {
        switch target {
        case let .managed(token):
            guard workspaceManager.entry(for: token) != nil else { return }
            focusWindow(token)

        case let .external(target):
            if workspaceManager.entry(for: target.token) != nil {
                focusWindow(target.token)
                return
            }
            guard !isLockScreenActive else { return }
            if hasStartedServices {
                guard !isFrontmostAppLockScreen() else { return }
            }

            let pid = target.pid
            guard !workspaceManager.isAppHidden(pid: pid) else { return }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated
            else {
                return
            }

            let intent = intentLedger.registerActivateApp(pid: pid)
            deadlineWheel.schedule(intentId: intent.id, after: .seconds(1))
            if let axRef = AXWindowService.axWindowRef(for: UInt32(target.windowId), pid: pid) {
                performWindowFronting(
                    pid: pid,
                    windowId: target.windowId,
                    axRef: axRef
                )
            } else {
                windowFocusOperations.activateApp(pid)
            }
        }
    }

    @discardableResult
    func focusWindow(
        _ token: WindowToken,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ManagedFocusRequest? {
        guard origin != .focusFollowsMouse || focusFollowsMouseEnabled else { return nil }
        if origin == .focusFollowsMouse,
           mouseEventHandler.hasLatestFocusFollowsMouseSample,
           mouseEventHandler.latestFocusFollowsMouseToken() != token
        {
            return nil
        }
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        guard !isLockScreenActive else { return nil }
        if hasStartedServices {
            guard !isFrontmostAppLockScreen() else { return nil }
        }
        if isManagedWindowSuppressedByMacOSHide(token) {
            return nil
        }
        if isManagedWindowSuspendedForNativeFullscreen(token) {
            if workspaceManager.showsNativeFullscreenPlaceholder(for: token) {
                selectNativeFullscreenPlaceholder(entry)
            }
            return nil
        }
        if deferInactiveDwindleGroupFocus(entry, origin: origin) {
            return nil
        }

        let workspaceId = entry.workspaceId
        var promotedHandoffSourceToken: WindowToken?
        var supersededHandoff: (request: ManagedFocusRequest, sourceToken: WindowToken)?
        var preferredSameAppSourceToken: WindowToken?
        if let activeRequest = intentLedger.activeManagedRequest {
            switch activeRequest.phase {
            case let .awaitingSameAppActivation(sourceToken, _):
                if activeRequest.token == token {
                    promotedHandoffSourceToken = sourceToken
                } else if let canceledRequest = cancelManagedFocusRequest(activeRequest) {
                    supersededHandoff = (canceledRequest, sourceToken)
                }
            case .awaitingConfirmation:
                if activeRequest.token != token, activeRequest.token.pid == token.pid {
                    preferredSameAppSourceToken = activeRequest.token
                }
            }
        }
        let previousRequestId = intentLedger.activeManagedRequest?.requestId
        let request = intentLedger.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: origin
        )
        if let previousRequestId {
            abortScratchpadStacking(matching: previousRequestId)
        }
        _ = workspaceManager.beginManagedFocusRequest(
            request.token,
            in: request.workspaceId,
            onMonitor: workspaceManager.monitorId(for: request.workspaceId),
            requestId: request.requestId
        )
        recordNiriCreateFocusTrace(
            .pendingFocusStarted(
                requestId: request.requestId,
                token: request.token,
                workspaceId: request.workspaceId
            )
        )

        let applied = applyManagedFocusRequest(
            request,
            entry: entry,
            validatesPointer: false,
            preferredSameAppSourceToken: preferredSameAppSourceToken
        )
        if let promotedHandoffSourceToken,
           request.origin != .focusFollowsMouse,
           !applied
        {
            cancelManagedFocusRequestAndRestoreSource(
                request,
                sourceToken: promotedHandoffSourceToken
            )
        }
        let replacementIsStaged: Bool
        if case .some(.awaitingSameAppActivation) = intentLedger.activeManagedRequest(
            requestId: request.requestId
        )?.phase {
            replacementIsStaged = true
        } else {
            replacementIsStaged = false
        }
        if let supersededHandoff, !applied, !replacementIsStaged {
            cancelManagedFocusRequest(request)
            restoreSameAppFocusSource(
                supersededHandoff.sourceToken,
                canceledRequest: supersededHandoff.request
            )
        }
        if intentLedger.activeManagedRequest(requestId: request.requestId)?.phase == .awaitingConfirmation {
            axEventHandler.probeFocusedWindowAfterFronting(
                expectedToken: request.token,
                workspaceId: request.workspaceId
            )
        }
        return request
    }

    private func deferInactiveDwindleGroupFocus(
        _ entry: WindowState,
        origin: ManagedFocusOrigin
    ) -> Bool {
        let workspaceId = entry.workspaceId
        guard entry.mode == .tiling,
              entry.layoutReason == .standard,
              workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let monitorId = workspaceManager.monitorId(for: workspaceId),
              workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId,
              let snapshot = dwindleEngine?.tileSnapshot(for: entry.token, in: workspaceId),
              snapshot.members.count > 1,
              snapshot.activeToken != entry.token
        else {
            return false
        }

        if let activeRequest = intentLedger.activeManagedRequest {
            _ = cancelManagedFocusRequest(activeRequest)
        }
        return dwindleLayoutHandler.activateWindow(
            entry.token,
            in: workspaceId,
            origin: origin
        ) == .activated
    }

    func focusWindow(_ handle: WindowHandle) {
        focusWindow(handle.id)
    }

    func preferredKeyboardFocusFrame(for token: WindowToken) -> CGRect? {
        if let workspaceId = workspaceManager.entry(for: token)?.workspaceId {
            switch workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                if let node = niriEngine?.findNode(for: token, in: workspaceId) {
                    return node.renderedFrame ?? node.frame
                }
            case .dwindle:
                if let engine = dwindleEngine {
                    return engine.contentFrame(for: token, in: workspaceId)
                        ?? engine.findNode(for: token, in: workspaceId)?.cachedFrame
                }
            }
        }
        if let floatingState = workspaceManager.floatingState(for: token) {
            return floatingState.lastFrame
        }
        return nil
    }

    func recordNiriCreateFocusTrace(_ kind: NiriCreateFocusTraceEvent.Kind) {
        axEventHandler.recordNiriCreateFocusTrace(.init(kind: kind))
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
