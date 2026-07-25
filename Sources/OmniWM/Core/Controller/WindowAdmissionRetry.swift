// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension AXEventHandler {
    var activeAdmissionRetryWindowIds: Set<Int> {
        Set(admissionRetryStateByWindowId.keys.map(Int.init))
    }

    func isOwnProcessPid(_ pid: pid_t) -> Bool {
        pid == getpid()
    }

    func deferAdmissionIfNeeded(
        evaluation: WMController.WindowDecisionEvaluation,
        axRef: AXWindowRef,
        token: WindowToken,
        trackedMode: TrackedWindowMode,
        existingEntry: WindowState?
    ) -> Bool {
        // Geometry gates entry only: a window already tracked keeps its slot, and of the tracked
        // ones only a promotion into tiling re-checks it.
        guard trackedMode == .tiling || existingEntry == nil else { return false }
        guard existingEntry?.mode != .tiling else { return false }
        guard let controller,
              controller.shouldDeferAdmission(
                  evaluation: evaluation,
                  axRef: axRef,
                  windowInfo: evaluation.facts.windowServer,
                  trackedMode: trackedMode
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
                reason: .degenerateGeometry
            )
        }
        return true
    }

    @discardableResult
    func scheduleCandidateAdmissionRetry(
        windowId: UInt32,
        pid: pid_t,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason
    ) -> Bool {
        let token = WindowToken(pid: pid, windowId: Int(windowId))
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .candidate(token: token, axRef: axRef)
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
        trigger: AdmissionRetryTrigger
    ) -> Bool {
        let state = normalizedAdmissionRetryState(windowId: windowId, observedAXRef: axRef)
        if let state,
           !state.exhausted,
           state.trigger.priority > trigger.priority
        {
            return true
        }
        guard isAdmissionRetryEligible(
            windowId: windowId,
            expectedToken: expectedToken,
            trigger: trigger
        ) else {
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            return false
        }
        let schedule = resolvedAdmissionRetrySchedule(
            state: state,
            expectedToken: expectedToken,
            axRef: axRef,
            reason: reason,
            trigger: trigger
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
            state.task?.cancel()
            admissionRetryStateByWindowId[windowId] = nil
            return nil
        }
        return state
    }

    private func resolvedAdmissionRetrySchedule(
        state: AdmissionRetryState?,
        expectedToken: WindowToken?,
        axRef: AXWindowRef?,
        reason: WindowAdmissionPendingReason,
        trigger: AdmissionRetryTrigger
    ) -> AdmissionRetrySchedule {
        let preservesPriorTrigger = state.map { $0.trigger.priority > trigger.priority } ?? false
        return AdmissionRetrySchedule(
            expectedToken: preservesPriorTrigger
                ? state?.expectedToken ?? expectedToken
                : expectedToken ?? state?.expectedToken,
            axRef: preservesPriorTrigger ? state?.axRef ?? axRef : axRef ?? state?.axRef,
            reason: preservesPriorTrigger ? state?.reason ?? reason : reason,
            trigger: preservesPriorTrigger ? state?.trigger ?? trigger : trigger
        )
    }

    private func updateExistingAdmissionRetry(
        _ state: AdmissionRetryState?,
        schedule: AdmissionRetrySchedule,
        windowId: UInt32
    ) -> Bool? {
        guard var state else { return nil }
        if state.exhausted {
            state.expectedToken = schedule.expectedToken
            state.axRef = schedule.axRef
            state.reason = schedule.reason
            state.trigger = schedule.trigger
            admissionRetryStateByWindowId[windowId] = state
            return false
        }
        switch state.executionPhase {
        case .waiting:
            guard state.task != nil else { return nil }
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
        let generation = state?.generation ?? nextAdmissionRetryGeneration
        admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: schedule.expectedToken,
            axRef: schedule.axRef,
            reason: schedule.reason,
            attempt: Self.createdWindowRetryLimit,
            generation: generation,
            trigger: schedule.trigger,
            exhausted: true,
            executionPhase: .waiting,
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
            exhausted: false,
            executionPhase: .waiting,
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
                  var state = self.admissionRetryStateByWindowId[windowId],
                  state.generation == generation
            else { return }
            let executionOwner = self.nextAdmissionRetryExecutionOwner
            self.nextAdmissionRetryExecutionOwner &+= 1
            state.executionPhase = .running(executionOwner)
            self.admissionRetryStateByWindowId[windowId] = state
            self.resumeAdmissionRetry(
                windowId: windowId,
                state: state,
                executionOwner: executionOwner
            )
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
        guard var state = admissionRetryStateByWindowId[windowId] else { return false }
        state.task?.cancel()
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
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

    func finishAdmissionRetryAfterTracking(windowId: UInt32) {
        finishAdmissionRetry(windowId: windowId)
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
        finishAdmissionRetry(windowId: windowId)
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
        return true
    }

    private func finishAdmissionRetry(windowId: UInt32) {
        guard let state = admissionRetryStateByWindowId.removeValue(forKey: windowId) else { return }
        state.task?.cancel()
        guard case let .focused(token, source, observationGeneration, callbackGeneration) = state.trigger else {
            return
        }
        handleAppActivation(
            pid: token.pid,
            source: source,
            origin: .retry,
            causalObservationGeneration: observationGeneration,
            callbackGeneration: callbackGeneration
        )
    }

    func cancelTrackedTilingPromotionRetry(windowId: Int) {
        guard let windowId = UInt32(exactly: windowId),
              let state = admissionRetryStateByWindowId[windowId],
              case .ruleReevaluation = state.trigger
        else {
            return
        }
        cancelCreatedWindowRetry(windowId: windowId)
    }

    func retireStaleFocusedAdmissionRetry(pid: pid_t, observationGeneration: UInt64) {
        let matchingWindowIds = admissionRetryStateByWindowId.compactMap { windowId, state -> UInt32? in
            guard case let .focused(token, _, generation, _) = state.trigger,
                  token.pid == pid,
                  generation == observationGeneration
            else {
                return nil
            }
            return windowId
        }
        for windowId in matchingWindowIds {
            cancelCreatedWindowRetry(windowId: windowId)
        }
    }

    func cleanupAdmissionStateForTerminatedApp(pid: pid_t) {
        let retryWindowIds = admissionRetryStateByWindowId.compactMap { windowId, state -> UInt32? in
            let triggerMatchesPID = switch state.trigger {
            case .create:
                false
            case let .candidate(token, _),
                 let .focused(token, _, _, _),
                 let .ruleReevaluation(token, _):
                token.pid == pid
            case let .identityRebind(oldWindow, newWindow, _, _, _):
                oldWindow.token.pid == pid || newWindow.token.pid == pid
            }
            guard state.expectedToken?.pid == pid
                || triggerMatchesPID
                || state.axRef.flatMap(AXWindowService.processIdentifier) == pid
            else {
                return nil
            }
            return windowId
        }
        for windowId in retryWindowIds {
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
        }

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

    func cancelCreatedWindowRetry(windowId: UInt32) {
        admissionRetryStateByWindowId.removeValue(forKey: windowId)?.task?.cancel()
    }

    func resetCreatedWindowRetryState() {
        for (_, state) in admissionRetryStateByWindowId {
            state.task?.cancel()
        }
        admissionRetryStateByWindowId.removeAll()
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
        case let .candidate(token, axRef):
            processCreatedWindow(
                windowId: windowId,
                fallbackToken: token,
                fallbackAXRef: axRef,
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

    private func finishRuleReevaluationRetry(
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
            admissionRetryStateByWindowId[windowId] = nil
        }
    }
}
