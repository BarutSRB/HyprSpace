// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension AXEventHandler {
    var activeAdmissionRetryWindowIds: Set<Int> {
        Set(admissionRetryStateByWindowId.keys.map(Int.init))
    }

    func protectDeferredReplacement(
        windowId: UInt32,
        token: WindowToken,
        scope: RescanScope
    ) {
        let protectedScope = scope.merged(with: .targeted(
            appPIDs: [token.pid],
            nativeSpaceIds: []
        ))
        if var protection = deferredReplacementProtectionsByWindowId[windowId] {
            protection.protectedTokens.insert(token)
            protection.fallbackProtectedTokens.removeAll()
            protection.permitsPIDFallback = false
            protection.scope = protection.scope.merged(with: protectedScope)
            deferredReplacementProtectionsByWindowId[windowId] = protection
        } else {
            deferredReplacementProtectionsByWindowId[windowId] = DeferredReplacementProtection(
                protectedTokens: [token],
                scope: protectedScope,
                permitsPIDFallback: false
            )
        }
    }

    func recordDeferredReplacementAssessment(
        windowId: UInt32,
        scope: RescanScope
    ) {
        if var protection = deferredReplacementProtectionsByWindowId[windowId] {
            protection.fallbackProtectedTokens.removeAll()
            protection.permitsPIDFallback = false
            protection.scope = protection.scope.merged(with: scope)
            deferredReplacementProtectionsByWindowId[windowId] = protection
        } else {
            deferredReplacementProtectionsByWindowId[windowId] = DeferredReplacementProtection(
                protectedTokens: [],
                scope: scope,
                permitsPIDFallback: false
            )
        }
    }

    func protectMissingEntriesDuringUnsettledAdmission(
        candidates: Set<WindowToken>,
        scope: RescanScope
    ) -> Set<WindowToken> {
        guard !candidates.isEmpty else { return [] }
        let retryWindowIds = Set(
            admissionRetryStateByWindowId.compactMap { windowId, state in
                state.exhausted || !state.trigger.protectsMissingEntriesDuringAdmission
                    ? nil
                    : windowId
            }
        )
        let unsettledWindowIds = deferredCreatedWindowIds.union(retryWindowIds)
        var protectedTokens: Set<WindowToken> = []
        for windowId in unsettledWindowIds {
            let retryState = admissionRetryStateByWindowId[windowId]
            let existingProtection = deferredReplacementProtectionsByWindowId[windowId]
            let exactTokens = candidates.intersection(existingProtection?.protectedTokens ?? [])
            protectedTokens.formUnion(exactTokens)
            guard existingProtection?.permitsPIDFallback != false else { continue }
            let retainedFallbackTokens = candidates.intersection(
                existingProtection?.fallbackProtectedTokens ?? []
            )
            protectedTokens.formUnion(retainedFallbackTokens)
            var pids = Set(retainedFallbackTokens.map(\.pid))
            pids.formUnion(retryState?.trigger.protectionPIDs ?? [])
            if let expectedPID = retryState?.expectedToken?.pid {
                pids.insert(expectedPID)
            }
            if let axPID = retryState?.axRef.flatMap(AXWindowService.processIdentifier),
               axPID > 0
            {
                pids.insert(axPID)
            }
            pids.formUnion(identityAliasesByWindowId[Int(windowId)]?.pids ?? [])
            if pids.isEmpty, let windowInfo = resolveWindowInfo(windowId) {
                pids.insert(pid_t(windowInfo.pid))
            }
            let matchingTokens = Set(candidates.filter { pids.contains($0.pid) })
            if !matchingTokens.isEmpty {
                let protectedScope = scope.merged(with: .targeted(
                    appPIDs: Set(matchingTokens.map(\.pid)),
                    nativeSpaceIds: []
                ))
                if var protection = deferredReplacementProtectionsByWindowId[windowId] {
                    protection.fallbackProtectedTokens.formUnion(matchingTokens)
                    protection.scope = protection.scope.merged(with: protectedScope)
                    deferredReplacementProtectionsByWindowId[windowId] = protection
                } else {
                    deferredReplacementProtectionsByWindowId[windowId] =
                        DeferredReplacementProtection(
                            protectedTokens: [],
                            scope: protectedScope,
                            fallbackProtectedTokens: matchingTokens
                        )
                }
            }
            protectedTokens.formUnion(matchingTokens)
        }
        return protectedTokens
    }

    func rejectDeferredReplacement(windowId: UInt32) {
        guard let protection = deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
        else {
            return
        }
        guard !protection.protectedTokens.isEmpty
            || !protection.fallbackProtectedTokens.isEmpty
        else {
            return
        }
        controller?.layoutRefreshController.scheduleMissingConfirmation(scope: protection.scope)
    }

    func discardDeferredReplacementProtection(windowId: UInt32) {
        deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
    }

    func finishDeferredReplacementAfterTracking(windowId: UInt32) {
        guard let protection = deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId),
              let controller
        else {
            return
        }
        if protection.protectedTokens.union(protection.fallbackProtectedTokens).contains(where: {
            controller.workspaceManager.entry(for: $0) != nil
        }) {
            controller.layoutRefreshController.scheduleMissingConfirmation(scope: protection.scope)
        }
    }

    func finishDeferredReplacementAfterTracking(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        finishDeferredReplacementAfterTracking(windowId: windowId)
    }

    func isOwnProcessPid(_ pid: pid_t) -> Bool {
        pid == getpid()
    }

    func deferAdmissionIfNeeded(
        evaluation: WMController.WindowDecisionEvaluation,
        axRef: AXWindowRef,
        token: WindowToken,
        mode: TrackedWindowMode,
        existingEntry: WindowState?,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate
    ) -> Bool {
        let requiresValidation = existingEntry == nil
            || existingEntry?.mode == .floating && mode == .tiling
        guard requiresValidation else { return false }
        guard let controller,
              controller.shouldDeferAdmission(
                  evaluation: evaluation,
                  axRef: axRef,
                  mode: mode,
                  windowInfo: evaluation.facts.windowServer
              ),
              let windowId = UInt32(exactly: token.windowId)
        else {
            return false
        }
        if let existingEntry {
            _ = scheduleTrackedTilingPromotionRetry(
                token: existingEntry.token,
                axRef: axRef,
                reason: .degenerateGeometry
            )
        } else {
            _ = scheduleCandidateAdmissionRetry(
                windowId: windowId,
                pid: token.pid,
                axRef: axRef,
                reason: .degenerateGeometry,
                placementOrigin: placementOrigin
            )
        }
        return true
    }

    @discardableResult
    func scheduleCandidateAdmissionRetry(
        windowId: UInt32,
        pid: pid_t,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate
    ) -> Bool {
        let token = WindowToken(pid: pid, windowId: Int(windowId))
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .candidate(
                token: token,
                axRef: axRef,
                placementOrigin: placementOrigin
            )
        )
    }

    @discardableResult
    func scheduleTrackedTilingPromotionRetry(
        token: WindowToken,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason
    ) -> Bool {
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .ruleReevaluation(token: token, axRef: axRef)
        )
    }

    func scheduleAdmissionRetry(
        windowId: UInt32,
        expectedToken: WindowToken?,
        axRef: AXWindowRef? = nil,
        reason: WindowAdmissionPendingReason,
        trigger: AdmissionRetryTrigger,
        preparedSubscriptionRetainContribution: Int = 0
    ) -> Bool {
        assert(preparedSubscriptionRetainContribution >= 0)
        let state = normalizedAdmissionRetryState(windowId: windowId, observedAXRef: axRef)
        if var retainedState = state,
           !retainedState.exhausted,
           retainedState.trigger.priority > trigger.priority
        {
            retainedState.focusedAdmissionContinuation = latestFocusedAdmissionRetryContinuation(
                retainedState.focusedAdmissionContinuation
                    ?? retainedState.trigger.focusedAdmissionContinuation,
                trigger.focusedAdmissionContinuation
            )
            retainedState.preparedSubscriptionRetainCount += preparedSubscriptionRetainContribution
            admissionRetryStateByWindowId[windowId] = retainedState
            return true
        }
        guard isAdmissionRetryEligible(
            windowId: windowId,
            expectedToken: expectedToken,
            trigger: trigger
        ) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            return false
        }
        let schedule = resolvedAdmissionRetrySchedule(
            state: state,
            expectedToken: expectedToken,
            axRef: axRef,
            reason: reason,
            trigger: trigger,
            preparedSubscriptionRetainContribution: preparedSubscriptionRetainContribution
        )
        if let existingResult = updateExistingAdmissionRetry(
            state,
            schedule: schedule,
            windowId: windowId
        ) {
            return existingResult
        }
        return startNextAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
    }

    @discardableResult
    func retainFocusedAdmissionContinuation(
        _ continuation: FocusedAdmissionRetryContinuation,
        windowId: UInt32
    ) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              state.expectedToken.map({ $0 == continuation.token }) ?? true
        else {
            return false
        }
        state.focusedAdmissionContinuation = latestFocusedAdmissionRetryContinuation(
            state.focusedAdmissionContinuation ?? state.trigger.focusedAdmissionContinuation,
            continuation
        )
        admissionRetryStateByWindowId[windowId] = state
        return true
    }

    private func latestFocusedAdmissionRetryContinuation(
        _ current: FocusedAdmissionRetryContinuation?,
        _ incoming: FocusedAdmissionRetryContinuation?
    ) -> FocusedAdmissionRetryContinuation? {
        guard let current else { return incoming }
        guard let incoming else { return current }
        return incoming.observationGeneration >= current.observationGeneration ? incoming : current
    }

    private func isAdmissionRetryEligible(
        windowId: UInt32,
        expectedToken: WindowToken?,
        trigger: AdmissionRetryTrigger
    ) -> Bool {
        guard let controller else { return false }
        let existingEntry = controller.workspaceManager.entry(forWindowId: Int(windowId))
        let permitsTrackedEntry = switch trigger {
        case .ruleReevaluation:
            existingEntry?.token == expectedToken && existingEntry?.mode == .floating
        case let .identityRebind(oldWindow, _, _, _, _):
            existingEntry?.token == oldWindow.token
        case .create,
             .candidate,
             .focused:
            false
        }
        return (existingEntry == nil || permitsTrackedEntry)
            && !controller.isOwnedWindow(windowNumber: Int(windowId))
            && (expectedToken.map { !isOwnProcessPid($0.pid) } ?? true)
    }

    private func normalizedAdmissionRetryState(
        windowId: UInt32,
        observedAXRef: AXWindowRef?
    ) -> AdmissionRetryState? {
        guard let state = admissionRetryStateByWindowId[windowId] else { return nil }
        let relation = admissionIncarnationRelation(
            state.axRef,
            observedAXRef,
            windowId: Int(windowId)
        )
        guard relation != .replacement,
              relation != .bindsIdentity || !state.exhausted
        else {
            cancelCreatedWindowRetry(windowId: windowId)
            return nil
        }
        return state
    }

    private func resolvedAdmissionRetrySchedule(
        state: AdmissionRetryState?,
        expectedToken: WindowToken?,
        axRef: AXWindowRef?,
        reason: WindowAdmissionPendingReason,
        trigger: AdmissionRetryTrigger,
        preparedSubscriptionRetainContribution: Int
    ) -> AdmissionRetrySchedule {
        let preservesPriorTrigger = state.map { $0.trigger.priority > trigger.priority } ?? false
        let retainedFocusedContinuation = state.flatMap {
            $0.focusedAdmissionContinuation ?? $0.trigger.focusedAdmissionContinuation
        }
        let effectiveTrigger = preservesPriorTrigger ? state?.trigger ?? trigger : trigger
        let identityRebindSource: ManagedWindowIdentityRebindSource?
        if case let .identityRebind(oldWindow, _, _, _, _) = effectiveTrigger {
            identityRebindSource = state?.identityRebindSource
                ?? controller?.workspaceManager.handle(for: oldWindow.token).map {
                    let source = ManagedWindowIdentityRebindSource(
                        handle: $0,
                        requestOrder: nextAdmissionRetryGeneration
                    )
                    nextAdmissionRetryGeneration &+= 1
                    return source
                }
        } else {
            identityRebindSource = nil
        }
        return AdmissionRetrySchedule(
            expectedToken: preservesPriorTrigger
                ? state?.expectedToken ?? expectedToken
                : expectedToken ?? state?.expectedToken,
            axRef: preservesPriorTrigger ? state?.axRef ?? axRef : axRef ?? state?.axRef,
            reason: preservesPriorTrigger ? state?.reason ?? reason : reason,
            trigger: effectiveTrigger,
            identityRebindSource: identityRebindSource,
            focusedAdmissionContinuation: latestFocusedAdmissionRetryContinuation(
                retainedFocusedContinuation,
                trigger.focusedAdmissionContinuation
            ),
            preparedSubscriptionRetainCount: (state?.preparedSubscriptionRetainCount ?? 0)
                + preparedSubscriptionRetainContribution
        )
    }

    private func updateExistingAdmissionRetry(
        _ state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) -> Bool? {
        guard var state else { return nil }
        if state.exhausted {
            releasePreparedWindowSubscriptions(
                windowId,
                count: state.preparedSubscriptionRetainCount
            )
            state.expectedToken = schedule.expectedToken
            state.axRef = schedule.axRef
            state.reason = schedule.reason
            state.trigger = schedule.trigger
            state.identityRebindSource = schedule.identityRebindSource
            state.focusedAdmissionContinuation = schedule.focusedAdmissionContinuation
            state.preparedSubscriptionRetainCount = 0
            admissionRetryStateByWindowId[windowId] = state
            rejectDeferredReplacement(windowId: windowId)
            return false
        }
        switch state.executionPhase {
        case .waiting:
            guard state.task != nil else { return nil }
        case .queued:
            break
        case .running:
            guard schedule.trigger.priority >= state.trigger.priority else { return true }
            state.task?.cancel()
            let attempt = schedule.trigger.priority == state.trigger.priority
                ? state.attempt + 1
                : state.attempt
            guard attempt <= Self.createdWindowRetryLimit else {
                exhaustAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
                return false
            }
            scheduleAdmissionRetryTask(
                schedule: schedule,
                windowId: windowId,
                attempt: attempt
            )
            return true
        }
        state.expectedToken = schedule.expectedToken
        state.axRef = schedule.axRef
        state.reason = schedule.reason
        state.trigger = schedule.trigger
        state.identityRebindSource = schedule.identityRebindSource
        state.focusedAdmissionContinuation = schedule.focusedAdmissionContinuation
        state.preparedSubscriptionRetainCount = schedule.preparedSubscriptionRetainCount
        admissionRetryStateByWindowId[windowId] = state
        return !state.exhausted
    }

    private func startNextAdmissionRetry(
        state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) -> Bool {
        let attempt = (state?.attempt ?? 0) + 1
        guard attempt <= Self.createdWindowRetryLimit else {
            exhaustAdmissionRetry(state: state, schedule: schedule, windowId: windowId)
            return false
        }
        scheduleAdmissionRetryTask(
            schedule: schedule,
            windowId: windowId,
            attempt: attempt
        )
        return true
    }

    private func exhaustAdmissionRetry(
        state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) {
        state?.task?.cancel()
        if let state {
            completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
        }
        cancelSameAppCloseProbe(
            for: schedule.trigger,
            reason: "identity_rebind_retry_exhausted"
        )
        let generation = state?.generation ?? nextAdmissionRetryGeneration
        admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: schedule.expectedToken,
            axRef: schedule.axRef,
            reason: schedule.reason,
            attempt: Self.createdWindowRetryLimit,
            generation: generation,
            trigger: schedule.trigger,
            identityRebindSource: schedule.identityRebindSource,
            focusedAdmissionContinuation: schedule.focusedAdmissionContinuation,
            exhausted: true,
            executionPhase: .waiting,
            preparedSubscriptionRetainCount: 0,
            task: nil
        )
        discardCreatePlacementContext(windowId: windowId)
        WindowAdmissionTrace.record(
            .init(
                action: .admissionRetryExhausted,
                pid: schedule.expectedToken?.pid,
                windowId: Int(windowId),
                reason: schedule.reason.rawValue,
                attempt: Self.createdWindowRetryLimit,
                retryGeneration: generation,
                axRef: schedule.axRef
            )
        )
        recordNiriCreateFocusTrace(
            .init(
                kind: .admissionRejected(
                    windowId: windowId,
                    pid: schedule.expectedToken?.pid,
                    reason: .retryExhausted
                )
            )
        )
        rejectDeferredReplacement(windowId: windowId)
        if let source = schedule.identityRebindSource {
            resumeQueuedIdentityRebind(for: source.handle)
        }
    }

    private func scheduleAdmissionRetryTask(
        schedule: AdmissionRetrySchedule,
        windowId: UInt32,
        attempt: Int
    ) {
        let generation = nextAdmissionRetryGeneration
        nextAdmissionRetryGeneration &+= 1
        var state = AdmissionRetryState(
            expectedToken: schedule.expectedToken,
            axRef: schedule.axRef,
            reason: schedule.reason,
            attempt: attempt,
            generation: generation,
            trigger: schedule.trigger,
            identityRebindSource: schedule.identityRebindSource,
            focusedAdmissionContinuation: schedule.focusedAdmissionContinuation,
            exhausted: false,
            executionPhase: .waiting,
            preparedSubscriptionRetainCount: schedule.preparedSubscriptionRetainCount,
            task: nil
        )
        state.task = makeAdmissionRetryTask(windowId: windowId, generation: generation)
        admissionRetryStateByWindowId[windowId] = state
        recordAdmissionRetryScheduled(
            schedule,
            windowId: windowId,
            attempt: attempt,
            generation: generation
        )
    }

    private func makeAdmissionRetryTask(
        windowId: UInt32,
        generation: UInt64
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stabilizationRetryDelay)
            guard !Task.isCancelled,
                  let self,
                  let state = self.admissionRetryStateByWindowId[windowId],
                  state.generation == generation
            else { return }
            self.dispatchAdmissionRetry(windowId: windowId)
        }
    }

    private func recordAdmissionRetryScheduled(
        _ schedule: AdmissionRetrySchedule,
        windowId: UInt32,
        attempt: Int,
        generation: UInt64
    ) {
        WindowAdmissionTrace.record(
            .init(
                action: .admissionRetryScheduled,
                pid: schedule.expectedToken?.pid,
                windowId: Int(windowId),
                reason: schedule.reason.rawValue,
                attempt: attempt,
                retryGeneration: generation,
                axRef: schedule.axRef
            )
        )
        recordNiriCreateFocusTrace(
            .init(
                kind: .createRetryScheduled(
                    windowId: windowId,
                    pid: schedule.expectedToken?.pid,
                    reason: schedule.reason,
                    attempt: attempt
                )
            )
        )
    }

    func retryAdmissionAfterFrameChange(windowId: UInt32) -> Bool {
        dispatchAdmissionRetry(windowId: windowId)
    }

    @discardableResult
    private func dispatchAdmissionRetry(windowId: UInt32) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId] else { return false }
        if case .identityRebind = state.trigger {
            if case .running = state.executionPhase { return true }
            guard !state.exhausted, !state.identityRebindTargetDestroyed,
                  let source = state.identityRebindSource
            else { return false }
            state.task?.cancel()
            state.task = nil
            state.executionPhase = .queued
            admissionRetryStateByWindowId[windowId] = state
            guard activeIdentityRebindsByHandle[source.handle] == nil,
                  oldestIdentityRebind(for: source.handle)?.key == windowId
            else { return true }
            guard let entry = controller?.workspaceManager.entry(for: source.handle),
                  case let .identityRebind(_, newWindow, metadata, hints, constraints) = state.trigger
            else {
                cancelCreatedWindowRetry(windowId: windowId)
                rejectDeferredReplacement(windowId: windowId)
                requestTargetedFullRescan(for: state.trigger.protectionPIDs)
                return true
            }
            state.trigger = .identityRebind(
                oldWindow: AXManagedWindowIdentity(token: entry.token, axRef: entry.axRef),
                newWindow: newWindow,
                managedReplacementMetadata: metadata,
                admissionHints: hints,
                sizeConstraints: constraints
            )
        }
        state.task?.cancel()
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
        if let source = state.identityRebindSource {
            activeIdentityRebindsByHandle[source.handle] = executionOwner
        }
        state.executionPhase = .running(executionOwner)
        state.task = nil
        admissionRetryStateByWindowId[windowId] = state
        resumeAdmissionRetry(
            windowId: windowId,
            state: state,
            executionOwner: executionOwner
        )
        return true
    }

    private func oldestIdentityRebind(for handle: WindowHandle) -> (key: UInt32, value: AdmissionRetryState)? {
        var oldest: (key: UInt32, value: AdmissionRetryState)?
        var oldestOrder = UInt64.max
        for (windowId, state) in admissionRetryStateByWindowId {
            guard !state.exhausted, !state.identityRebindTargetDestroyed,
                  let source = state.identityRebindSource, source.handle === handle,
                  source.requestOrder < oldestOrder
            else { continue }
            oldest = (windowId, state)
            oldestOrder = source.requestOrder
        }
        return oldest
    }

    private func resumeQueuedIdentityRebind(for handle: WindowHandle) {
        guard activeIdentityRebindsByHandle[handle] == nil,
              let next = oldestIdentityRebind(for: handle),
              next.value.executionPhase == .queued
        else { return }
        dispatchAdmissionRetry(windowId: next.key)
    }

    private func finishIdentityRebindExecution(for handle: WindowHandle, executionOwner: UInt64) {
        guard activeIdentityRebindsByHandle[handle] == executionOwner else { return }
        activeIdentityRebindsByHandle.removeValue(forKey: handle)
        resumeQueuedIdentityRebind(for: handle)
    }

    func retryAdmissionAfterFrameChangeRequiresEarlyReturn(windowId: UInt32) -> Bool {
        guard admissionRetryStateByWindowId[windowId] != nil else { return false }
        let wasTrackedBeforeRetry = controller?.workspaceManager.entry(forWindowId: Int(windowId)) != nil
        return retryAdmissionAfterFrameChange(windowId: windowId) && !wasTrackedBeforeRetry
    }

    @discardableResult
    func finishAdmissionRetryAfterTracking(windowId: UInt32) -> Bool {
        finishAdmissionRetry(windowId: windowId)
    }

    func finishRuleReevaluationAfterTracking(
        windowId: UInt32,
        wasNewlyManaged: Bool
    ) {
        let completedSubscriptionIdentityTransition = finishAdmissionRetryAfterTracking(
            windowId: windowId
        )
        if wasNewlyManaged, !completedSubscriptionIdentityTransition {
            noteManagedWindowSubscriptionIdentityChanged()
        }
    }

    func finishAdmissionRetryAfterCollision(
        windowId: UInt32,
        token: WindowToken,
        axRef: AXWindowRef
    ) {
        guard let state = admissionRetryStateByWindowId[windowId],
              state.expectedToken.map({ $0 == token }) ?? true,
              state.axRef.map({ CFEqual($0.element, axRef.element) }) ?? true
        else {
            return
        }
        if case .identityRebind = state.trigger { return }
        _ = finishAdmissionRetry(windowId: windowId)
    }

    func ownsFocusedAdmissionRetryExecution(_ execution: FocusedAdmissionRetryExecution) -> Bool {
        guard let state = admissionRetryStateByWindowId[execution.windowId],
              state.generation == execution.generation,
              state.executionPhase == .running(execution.executionOwner),
              case let .focused(token, _, _, _) = state.trigger,
              token.windowId == Int(execution.windowId)
        else {
            return false
        }
        return true
    }

    func ownsFocusedAdmissionRetryExecution(
        _ execution: FocusedAdmissionRetryExecution,
        matching facts: ActivationFacts
    ) -> Bool {
        guard ownsFocusedAdmissionRetryExecution(execution),
              let state = admissionRetryStateByWindowId[execution.windowId],
              case let .focused(token, source, observationGeneration, callbackGeneration) = state.trigger
        else {
            return false
        }
        return facts.origin == .retry
            && facts.pid == token.pid
            && facts.source == source
            && facts.observationGeneration == observationGeneration
            && facts.callbackGeneration == callbackGeneration
    }

    @discardableResult
    func finishFocusedAdmissionRetryExecution(_ execution: FocusedAdmissionRetryExecution) -> Bool {
        guard ownsFocusedAdmissionRetryExecution(execution),
              let state = admissionRetryStateByWindowId.removeValue(forKey: execution.windowId)
        else {
            return false
        }
        state.task?.cancel()
        completeAdmissionRetrySubscriptionOwnership(
            windowId: execution.windowId,
            state: state
        )
        finishDeferredReplacementAfterTracking(windowId: execution.windowId)
        return true
    }

    private func finishAdmissionRetry(windowId: UInt32) -> Bool {
        guard var state = admissionRetryStateByWindowId[windowId] else {
            finishDeferredReplacementAfterTracking(windowId: windowId)
            return false
        }
        if let executionOwner = state.focusedAdmissionReplayExecutionOwner,
           state.executionPhase == .running(executionOwner)
        {
            return false
        }
        state.task?.cancel()
        let completedSubscriptionIdentityTransition = completeAdmissionRetrySubscriptionOwnership(
            windowId: windowId,
            state: state
        )
        state.preparedSubscriptionRetainCount = 0
        finishDeferredReplacementAfterTracking(windowId: windowId)
        guard let continuation = state.focusedAdmissionContinuation
            ?? state.trigger.focusedAdmissionContinuation
        else {
            admissionRetryStateByWindowId.removeValue(forKey: windowId)
            return completedSubscriptionIdentityTransition
        }
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
        state.task = nil
        state.trigger = .focused(
            token: continuation.token,
            source: continuation.source,
            observationGeneration: continuation.observationGeneration,
            callbackGeneration: continuation.callbackGeneration
        )
        state.identityRebindSource = nil
        state.focusedAdmissionContinuation = continuation
        state.executionPhase = .running(executionOwner)
        state.focusedAdmissionReplayExecutionOwner = executionOwner
        admissionRetryStateByWindowId[windowId] = state
        let execution = FocusedAdmissionRetryExecution(
            windowId: windowId,
            generation: state.generation,
            executionOwner: executionOwner
        )
        let factRequestIssued = handleAppActivation(
            pid: continuation.token.pid,
            source: continuation.source,
            origin: .retry,
            causalObservationGeneration: continuation.observationGeneration,
            callbackGeneration: continuation.callbackGeneration,
            focusedAdmissionRetryExecution: execution
        )
        if !factRequestIssued {
            finishFocusedAdmissionRetryExecution(execution)
        }
        return completedSubscriptionIdentityTransition
    }

    func hasLiveFocusedAdmissionContinuation(for token: WindowToken) -> Bool {
        guard let windowId = UInt32(exactly: token.windowId),
              let state = admissionRetryStateByWindowId[windowId],
              !state.exhausted,
              let continuation = state.focusedAdmissionContinuation
              ?? state.trigger.focusedAdmissionContinuation,
              continuation.token == token,
              isCurrentFocusedAdmissionContinuation(continuation)
        else {
            return false
        }
        switch state.executionPhase {
        case .waiting:
            return state.task != nil
        case .queued:
            return true
        case .running:
            return true
        }
    }

    func cancelTrackedTilingPromotionRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId),
              let state = admissionRetryStateByWindowId[windowId],
              case .ruleReevaluation = state.trigger
        else {
            return
        }
        cancelCreatedWindowRetry(windowId: windowId)
        finishDeferredReplacementAfterTracking(windowId: windowId)
    }

    func retireStaleFocusedAdmissionRetry(pid: pid_t, observationGeneration: UInt64) {
        for windowId in Array(admissionRetryStateByWindowId.keys) {
            guard var state = admissionRetryStateByWindowId[windowId],
                  let continuation = state.focusedAdmissionContinuation
                  ?? state.trigger.focusedAdmissionContinuation,
                  continuation.token.pid == pid,
                  continuation.observationGeneration == observationGeneration
            else {
                continue
            }
            if case .focused = state.trigger {
                cancelCreatedWindowRetry(windowId: windowId)
                finishDeferredReplacementAfterTracking(windowId: windowId)
            } else {
                state.focusedAdmissionContinuation = nil
                admissionRetryStateByWindowId[windowId] = state
            }
        }
    }

    func cleanupAdmissionStateForTerminatedApp(pid: pid_t) {
        let retryWindowIds = admissionRetryStateByWindowId.compactMap { windowId, state -> UInt32? in
            guard state.expectedToken?.pid == pid
                || state.trigger.protectionPIDs.contains(pid)
                || state.axRef.flatMap(AXWindowService.processIdentifier) == pid
                || identityAliasesByWindowId[Int(windowId)]?.contains(pid: pid) == true
                || resolveWindowInfo(windowId).map({ pid_t($0.pid) == pid }) == true
            else {
                return nil
            }
            return windowId
        }
        for windowId in retryWindowIds {
            cleanupAdmissionRetryForTerminatedApp(windowId: windowId, pid: pid)
        }
        pruneDeferredReplacementProtections(forTerminatedPID: pid)

        for windowId in Array(identityAliasesByWindowId.keys) {
            guard var history = identityAliasesByWindowId[windowId] else { continue }
            history.remove(pid: pid)
            if history.isEmpty {
                identityAliasesByWindowId.removeValue(forKey: windowId)
            } else {
                identityAliasesByWindowId[windowId] = history
            }
        }
    }

    private func cleanupAdmissionRetryForTerminatedApp(windowId: UInt32, pid: pid_t) {
        if WindowAdmissionTrace.shared.isActive,
           let state = admissionRetryStateByWindowId[windowId]
        {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionDisappeared,
                    pid: state.expectedToken?.pid ?? pid,
                    windowId: Int(windowId),
                    reason: "process_terminated",
                    attempt: state.attempt,
                    retryGeneration: state.generation,
                    axRef: state.axRef
                )
            )
        }
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        discardDeferredReplacementProtection(windowId: windowId)
    }

    private func pruneDeferredReplacementProtections(forTerminatedPID pid: pid_t) {
        for windowId in Array(deferredReplacementProtectionsByWindowId.keys) {
            guard var protection = deferredReplacementProtectionsByWindowId[windowId] else {
                continue
            }
            let containedTerminatedPID = protection.protectedTokens.contains { $0.pid == pid }
                || protection.fallbackProtectedTokens.contains { $0.pid == pid }
            guard containedTerminatedPID else { continue }
            protection.protectedTokens = protection.protectedTokens.filter { $0.pid != pid }
            protection.fallbackProtectedTokens = protection.fallbackProtectedTokens.filter {
                $0.pid != pid
            }
            if protection.protectedTokens.isEmpty,
               protection.fallbackProtectedTokens.isEmpty
            {
                deferredReplacementProtectionsByWindowId.removeValue(forKey: windowId)
            } else {
                deferredReplacementProtectionsByWindowId[windowId] = protection
            }
        }
    }

    @discardableResult
    func cancelCreatedWindowRetry(windowId: UInt32) -> Int {
        guard let state = admissionRetryStateByWindowId.removeValue(forKey: windowId) else { return 0 }
        state.task?.cancel()
        completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
        cancelSameAppCloseProbe(for: state.trigger, reason: "identity_rebind_retry_cancelled")
        if let source = state.identityRebindSource {
            resumeQueuedIdentityRebind(for: source.handle)
        }
        return state.preparedSubscriptionRetainCount
    }

    func cancelCreatedWindowRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId) else { return }
        cancelCreatedWindowRetry(windowId: windowId)
    }

    func resetCreatedWindowRetryState() {
        for (windowId, state) in admissionRetryStateByWindowId {
            state.task?.cancel()
            completeAdmissionRetrySubscriptionOwnership(windowId: windowId, state: state)
            cancelSameAppCloseProbe(for: state.trigger, reason: "identity_rebind_retry_reset")
        }
        admissionRetryStateByWindowId.removeAll()
        deferredReplacementProtectionsByWindowId.removeAll()
    }

    private func cancelSameAppCloseProbe(
        for trigger: AdmissionRetryTrigger,
        reason: String
    ) {
        guard case let .identityRebind(oldWindow, _, _, _, _) = trigger else { return }
        cancelSameAppCloseProbe(
            matchingFocusedToken: oldWindow.token,
            reason: reason
        )
    }

    @discardableResult
    private func completeAdmissionRetrySubscriptionOwnership(
        windowId: UInt32,
        state: AdmissionRetryState
    ) -> Bool {
        if releasePreparedWindowSubscriptions(
            windowId,
            count: state.preparedSubscriptionRetainCount
        ) {
            return true
        }
        guard case .identityRebind = state.trigger else { return false }
        noteManagedWindowSubscriptionIdentityChanged()
        return true
    }

    private func admissionIncarnationRelation(
        _ current: AXWindowRef?,
        _ observed: AXWindowRef?,
        windowId: Int
    ) -> AdmissionIncarnationRelation {
        switch (current, observed) {
        case (nil, nil),
             (_?, nil):
            .same
        case (nil, _?):
            .bindsIdentity
        case let (current?, observed?):
            if CFEqual(current.element, observed.element) {
                .same
            } else if identityAliasesByWindowId[windowId]?.contains(current, and: observed) == true {
                .same
            } else {
                .replacement
            }
        }
    }

    private func resumeAdmissionRetry(
        windowId: UInt32,
        state: AdmissionRetryState,
        executionOwner: UInt64
    ) {
        switch state.trigger {
        case .create:
            processCreatedWindow(windowId: windowId)
        case let .candidate(token, axRef, placementOrigin):
            processCreatedWindow(
                windowId: windowId,
                fallbackToken: token,
                fallbackAXRef: axRef,
                placementOrigin: placementOrigin,
                retryTrigger: state.trigger
            )
        case let .focused(token, source, observationGeneration, callbackGeneration):
            let execution = FocusedAdmissionRetryExecution(
                windowId: windowId,
                generation: state.generation,
                executionOwner: executionOwner
            )
            let factRequestIssued = handleAppActivation(
                pid: token.pid,
                source: source,
                origin: .retry,
                causalObservationGeneration: observationGeneration,
                callbackGeneration: callbackGeneration,
                focusedAdmissionRetryExecution: execution
            )
            if !factRequestIssued {
                finishFocusedAdmissionRetryExecution(execution)
            }
        case let .identityRebind(
            oldWindow,
            newWindow,
            managedReplacementMetadata,
            admissionHints,
            sizeConstraints
        ):
            guard let windowId = UInt32(exactly: newWindow.token.windowId) else { return }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if let source = state.identityRebindSource {
                        self.finishIdentityRebindExecution(for: source.handle, executionOwner: executionOwner)
                    }
                }
                await self.completeManagedWindowIdentityRebind(
                    from: oldWindow,
                    to: newWindow,
                    windowId: windowId,
                    retryGeneration: state.generation,
                    executionOwner: executionOwner,
                    managedReplacementMetadata: managedReplacementMetadata,
                    admissionHints: admissionHints,
                    sizeConstraints: sizeConstraints
                )
            }
            var activeState = state
            activeState.task = task
            admissionRetryStateByWindowId[windowId] = activeState
        case let .ruleReevaluation(token, axRef):
            let task = Task { @MainActor [weak self] in
                guard let self, let controller = self.controller else { return }
                let outcome = await controller.reevaluateWindowRules(for: [.window(token)])
                self.finishRuleReevaluationRetry(
                    windowId: windowId,
                    generation: state.generation,
                    executionOwner: executionOwner,
                    token: token,
                    axRef: axRef,
                    reason: state.reason,
                    stale: outcome.stale
                )
            }
            var activeState = state
            activeState.task = task
            admissionRetryStateByWindowId[windowId] = activeState
        }
    }

    func finishRuleReevaluationRetry(
        windowId: UInt32,
        generation: UInt64,
        executionOwner: UInt64,
        token: WindowToken,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason,
        stale: Bool
    ) {
        guard var state = admissionRetryStateByWindowId[windowId],
              state.generation == generation,
              state.executionPhase == .running(executionOwner),
              case let .ruleReevaluation(retryToken, retryAXRef) = state.trigger,
              retryToken == token,
              CFEqual(retryAXRef.element, axRef.element)
        else {
            return
        }
        state.task = nil
        state.executionPhase = .waiting
        if stale {
            admissionRetryStateByWindowId[windowId] = state
            _ = scheduleTrackedTilingPromotionRetry(token: token, axRef: axRef, reason: reason)
        } else {
            admissionRetryStateByWindowId[windowId] = state
            cancelCreatedWindowRetry(windowId: windowId)
            finishDeferredReplacementAfterTracking(windowId: windowId)
        }
    }
}
