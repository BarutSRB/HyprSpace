// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

enum ManagedWindowDestroyDisposition {
    case current
    case stale
    case waitingIdentityRebindTarget(
        retryGeneration: UInt64,
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity
    )
    case pendingIdentityRebindTarget(
        retryGeneration: UInt64,
        executionOwner: UInt64,
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity
    )
}

extension AXEventHandler {
    func isCreatedWindowDeferred(_ windowId: UInt32) -> Bool {
        deferredCreatedWindowIds.contains(windowId)
    }

    func isAdmissionQuarantined(windowId: Int, axRef: AXWindowRef) -> Bool {
        guard let quarantine = admissionQuarantineByWindowId[windowId] else { return false }
        guard CFEqual(quarantine.axRef.element, axRef.element)
            || isKnownAXIdentityAlias(windowId: windowId, axRef: axRef)
        else {
            admissionQuarantineByWindowId.removeValue(forKey: windowId)
            identityAliasesByWindowId.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    func resolveFullRescanIdentity(
        axRef: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        observedAliases: FullRescanWindowIdentityAliases?,
        failedPIDs: Set<pid_t> = [],
        sizeConstraints: WindowSizeConstraints? = nil
    ) -> FullRescanIdentityResolution {
        guard let controller,
              let existingEntry = controller.workspaceManager.entry(forWindowId: windowId)
        else {
            return .process(nil)
        }
        let isSameElement = CFEqual(existingEntry.axRef.element, axRef.element)
        let isKnownAlias = isKnownAXIdentityAlias(windowId: windowId, axRef: axRef)
            || observedAliases?.axRefs.contains(where: {
                CFEqual($0.element, existingEntry.axRef.element)
            }) == true
        if !isSameElement,
           !isKnownAlias,
           failedPIDs.contains(existingEntry.pid)
        {
            return .preserve(existingEntry.token)
        }
        let token = WindowToken(pid: pid, windowId: windowId)
        if existingEntry.token == token, isSameElement {
            return .process(existingEntry)
        }
        guard let windowId = UInt32(exactly: windowId) else {
            return .preserve(existingEntry.token)
        }
        let result = rekeyManagedWindowIdentity(
            from: existingEntry.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            sizeConstraints: sizeConstraints
        )
        guard let rekeyedEntry = result.committedEntry else {
            return .preserve(existingEntry.token)
        }
        return .process(rekeyedEntry)
    }

    func updateIdentityAliases(
        _ aliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
    ) {
        for (windowId, observedAliases) in aliasesByWindowId {
            var history = identityAliasesByWindowId[windowId] ?? .init()
            history.commit(observedAliases)
            identityAliasesByWindowId[windowId] = history
        }
    }

    func pruneIdentityAliases(retainingWindowIds: Set<Int>) {
        identityAliasesByWindowId = identityAliasesByWindowId.filter {
            retainingWindowIds.contains($0.key)
        }
    }

    func fullRescanIdentityDependencyPIDsByWindowId(
        entries: [WindowState]
    ) -> [Int: Set<pid_t>] {
        var result = identityAliasesByWindowId.reduce(into: [Int: Set<pid_t>]()) { result, element in
            if !element.value.pids.isEmpty {
                result[element.key] = element.value.pids
            }
        }
        for entry in entries {
            if let pid = AXWindowService.processIdentifier(entry.axRef) {
                result[entry.windowId, default: []].insert(pid)
            }
        }
        return result
    }

    func fullRescanTargetPIDsDepending(
        onTerminatedPID terminatedPID: pid_t,
        entries: [WindowState]
    ) -> Set<pid_t> {
        let dependencyPIDsByWindowId = fullRescanIdentityDependencyPIDsByWindowId(entries: entries)
        return Set(entries.compactMap { entry in
            guard entry.pid != terminatedPID,
                  dependencyPIDsByWindowId[entry.windowId]?.contains(terminatedPID) == true
            else {
                return nil
            }
            return entry.pid
        })
    }

    func managedWindowToken(_ token: WindowToken, matchesObservedPid pid: pid_t) -> Bool {
        if token.pid == pid { return true }
        guard let entry = controller?.workspaceManager.entry(for: token) else { return false }
        if AXWindowService.processIdentifier(entry.axRef) == pid { return true }
        if identityAliasesByWindowId[token.windowId]?.contains(pid: pid) == true { return true }
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        return windowInfoProvider(windowId)?.pid == pid
    }

    func isKnownAXIdentityAlias(windowId: Int, axRef: AXWindowRef) -> Bool {
        identityAliasesByWindowId[windowId]?.contains(axRef) == true
    }

    func canonicalObservedWindowToken(pid: pid_t, axRef: AXWindowRef) -> WindowToken {
        if let existingEntry = controller?.workspaceManager.entry(forWindowId: axRef.windowId) {
            let matchesElement = CFEqual(existingEntry.axRef.element, axRef.element)
            if matchesElement || isKnownAXIdentityAlias(windowId: axRef.windowId, axRef: axRef) {
                return existingEntry.token
            }
        }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return canonicalObservedWindowToken(pid: pid, axRef: axRef)
    }

    func managedWindowDestroyDisposition(
        windowId: Int,
        axRef: AXWindowRef
    ) -> ManagedWindowDestroyDisposition {
        if let entry = controller?.workspaceManager.entry(forWindowId: windowId),
           CFEqual(entry.axRef.element, axRef.element)
        {
            return .current
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           let state = admissionRetryStateByWindowId[admissionWindowId],
           !state.exhausted,
           case let .identityRebind(oldWindow, newWindow, _, _, _) = state.trigger,
           newWindow.token.windowId == windowId,
           !CFEqual(oldWindow.axRef.element, newWindow.axRef.element),
           CFEqual(newWindow.axRef.element, axRef.element)
        {
            switch state.executionPhase {
            case .waiting:
                return .waitingIdentityRebindTarget(
                    retryGeneration: state.generation,
                    oldWindow: oldWindow,
                    newWindow: newWindow
                )
            case let .running(executionOwner):
                return .pendingIdentityRebindTarget(
                    retryGeneration: state.generation,
                    executionOwner: executionOwner,
                    oldWindow: oldWindow,
                    newWindow: newWindow
                )
            }
        }
        return isCurrentAXIncarnation(windowId: windowId, axRef: axRef) ? .current : .stale
    }

    func cancelDestroyedWaitingManagedWindowIdentityRebind(
        windowId: UInt32,
        retryGeneration: UInt64,
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity,
        axRef: AXWindowRef
    ) -> Bool {
        guard let state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              state.generation == retryGeneration,
              state.executionPhase == .waiting,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              CFEqual(newWindow.axRef.element, axRef.element)
        else {
            return false
        }
        cancelCreatedWindowRetry(windowId: windowId)
        discardDeferredReplacementProtection(windowId: windowId)
        return true
    }

    func deferDestroyedPendingManagedWindowIdentityRebind(
        windowId: UInt32,
        retryGeneration: UInt64,
        executionOwner: UInt64,
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity,
        axRef: AXWindowRef
    ) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              state.generation == retryGeneration,
              state.executionPhase == .running(executionOwner),
              !state.identityRebindTargetDestroyed,
              case let .identityRebind(retryOld, retryNew, _, _, _) = state.trigger,
              retryOld.token == oldWindow.token,
              retryNew.token == newWindow.token,
              CFEqual(retryOld.axRef.element, oldWindow.axRef.element),
              CFEqual(retryNew.axRef.element, newWindow.axRef.element),
              CFEqual(newWindow.axRef.element, axRef.element)
        else {
            return false
        }
        state.identityRebindTargetDestroyed = true
        admissionRetryStateByWindowId[windowId] = state
        return true
    }

    func isCurrentAXIncarnation(windowId: Int, axRef: AXWindowRef) -> Bool {
        if let entry = controller?.workspaceManager.entry(forWindowId: windowId) {
            return CFEqual(entry.axRef.element, axRef.element)
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           let retryState = admissionRetryStateByWindowId[admissionWindowId]
        {
            guard let retryAXRef = retryState.axRef else { return false }
            return CFEqual(retryAXRef.element, axRef.element)
        }
        if let quarantine = admissionQuarantineByWindowId[windowId] {
            return CFEqual(quarantine.axRef.element, axRef.element)
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           deferredCreatedWindowIds.contains(admissionWindowId)
        {
            return false
        }
        if pendingCreatePlacementContext(for: windowId) != nil {
            return false
        }
        return true
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
        guard let windowElement = resolveFocusedWindowValue(pid: pid),
              CFGetTypeID(windowElement) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        return try? AXWindowRef(element: axElement)
    }
}
