// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

typealias AXFrameApplicationTerminalObserver = @MainActor (AXFrameApplyResult) -> Void

struct AXFrameTerminalDelivery {
    let result: AXFrameApplyResult
    let observers: [AXFrameApplicationTerminalObserver]

    @MainActor
    func deliver() {
        for observer in observers {
            observer(result)
        }
    }
}

struct AXFrameRetryRequest: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?
    let components: AXFrameComponents
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents = .all,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.frame = frame
        self.currentFrameHint = currentFrameHint
        self.components = components
        self.traceRequestId = traceRequestId
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.frame == rhs.frame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.components == rhs.components
    }
}

struct AXFrameTerminalRefusal: Equatable {
    let pid: pid_t
    let windowId: Int
    let targetFrame: CGRect
    let observedFrame: CGRect
    let failureReason: AXFrameWriteFailureReason
    let requestId: AXFrameRequestId
    let traceRequestId: UInt64

    init(
        pid: pid_t,
        windowId: Int,
        targetFrame: CGRect,
        observedFrame: CGRect,
        failureReason: AXFrameWriteFailureReason,
        requestId: AXFrameRequestId = 0,
        traceRequestId: UInt64 = 0
    ) {
        self.pid = pid
        self.windowId = windowId
        self.targetFrame = targetFrame
        self.observedFrame = observedFrame
        self.failureReason = failureReason
        self.requestId = requestId
        self.traceRequestId = traceRequestId
    }
}

struct AXFrameEnqueueDecision {
    var request: AXFrameApplicationRequest?
    var deliveries: [AXFrameTerminalDelivery] = []
    var shouldCancelPendingRetry = false
}

struct AXFrameApplyOutcome {
    var deliveries: [AXFrameTerminalDelivery] = []
    var retries: [AXFrameRetryRequest] = []
    var terminalRefusals: [AXFrameTerminalRefusal] = []
    var terminalFailures: [AXFrameApplyResult] = []
    var stableSizeClamps: [AXFrameApplyResult] = []
}

struct AXFrameJobCancellationOutcome {
    var deliveries: [AXFrameTerminalDelivery] = []
    var terminalFailure: AXFrameApplyResult?
}

@MainActor
final class AXFrameApplicationLedger {
    private struct AppliedFrameState {
        let frame: CGRect
        let verifiedComponents: AXFrameComponents
        let convergedTargetFrame: CGRect?
    }

    private struct RecentFrameWriteFailure {
        let pid: pid_t
        var expectedWindow: AXWindowRef
        let reason: AXFrameWriteFailureReason
        let targetFrame: CGRect
        let observedFrame: CGRect?
        let settersSucceeded: Bool
        let components: AXFrameComponents
        var isTerminalRefusal = false
    }

    private struct PendingFrameObserver {
        var windowId: Int
        let pid: pid_t
        var expectedWindow: AXWindowRef
        var targetFrame: CGRect
        let currentFrameHint: CGRect?
        var components: AXFrameComponents
        var observers: [AXFrameApplicationTerminalObserver]
        var traceRequestId: UInt64
    }

    private struct PendingFrameWrite {
        var frame: CGRect
        var components: AXFrameComponents
        var verify: Bool
        var expectedWindow: AXWindowRef
        var requestId: AXFrameRequestId
        var traceRequestId: UInt64
    }

    private var appliedFrameStates: [Int: AppliedFrameState] = [:]
    private var pendingFrameWrites: [Int: PendingFrameWrite] = [:]
    private var recentFrameWriteFailures: [Int: RecentFrameWriteFailure] = [:]
    private var retryBudgetByWindowId: [Int: Int] = [:]
    private var forceApplyWindowIds: Set<Int> = []
    private var pendingFrameObserversByRequestId: [AXFrameRequestId: PendingFrameObserver] = [:]
    private var observerRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var rekeyedWindowIdsByPreviousId: [Int: Int] = [:]
    private var nextFrameApplicationRequestId: AXFrameRequestId = 1

    private static let maxAcceptedSizeSnap: CGFloat = 16

    private static func isAXTopLeftAnchoredSizeClamp(target: CGRect, observed: CGRect) -> Bool {
        guard !target.isNull,
              !observed.isNull,
              target.origin.x.isFinite,
              target.origin.y.isFinite,
              target.width.isFinite,
              target.height.isFinite,
              observed.origin.x.isFinite,
              observed.origin.y.isFinite,
              observed.width.isFinite,
              observed.height.isFinite,
              target.width > 1,
              target.height > 1,
              observed.width > 1,
              observed.height > 1,
              abs(observed.minX - target.minX) < FrameTolerance.frameWrite,
              abs(observed.maxY - target.maxY) < FrameTolerance.frameWrite
        else {
            return false
        }
        return abs(observed.width - target.width) >= FrameTolerance.frameWrite
            || abs(observed.height - target.height) >= FrameTolerance.frameWrite
    }

    private static func isBoundedAXTopLeftSizeConvergence(target: CGRect, observed: CGRect) -> Bool {
        isAXTopLeftAnchoredSizeClamp(target: target, observed: observed)
            && abs(observed.width - target.width) <= Self.maxAcceptedSizeSnap
            && abs(observed.height - target.height) <= Self.maxAcceptedSizeSnap
    }

    private func isStableSizeClamp(
        priorFailure: RecentFrameWriteFailure?,
        result: AXFrameApplyResult,
        observedFrame: CGRect
    ) -> Bool {
        guard let priorFailure,
              priorFailure.pid == result.pid,
              sameAXWindowIdentity(priorFailure.expectedWindow, result.expectedWindow),
              priorFailure.components == .all,
              result.writeResult.components == .all,
              priorFailure.reason == .verificationMismatch,
              result.writeResult.failureReason == .verificationMismatch,
              priorFailure.settersSucceeded,
              result.writeResult.sizeError == .success,
              result.writeResult.positionError == .success,
              priorFailure.targetFrame.approximatelyEqual(
                  to: result.targetFrame,
                  tolerance: FrameTolerance.frameWrite
              ),
              let priorObservedFrame = priorFailure.observedFrame,
              priorObservedFrame.approximatelyEqual(
                  to: observedFrame,
                  tolerance: FrameTolerance.frameWrite
              ),
              Self.isAXTopLeftAnchoredSizeClamp(
                  target: priorFailure.targetFrame,
                  observed: priorObservedFrame
              )
        else {
            return false
        }
        return Self.isAXTopLeftAnchoredSizeClamp(
            target: result.targetFrame,
            observed: observedFrame
        )
    }

    func forceApplyNextFrame(for windowId: Int) {
        forceApplyWindowIds.insert(windowId)
    }

    func invalidateAppliedFrame(for windowId: Int) {
        appliedFrameStates.removeValue(forKey: windowId)
        recentFrameWriteFailures[windowId]?.isTerminalRefusal = false
    }

    func invalidateAllAppliedFrames() {
        appliedFrameStates.removeAll(keepingCapacity: true)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        appliedFrameStates[windowId]?.frame
    }

    func trustedVerifiedSize(for windowId: Int) -> CGSize? {
        guard let state = appliedFrameStates[windowId],
              state.verifiedComponents.contains(.size)
        else {
            return nil
        }
        return state.frame.size
    }

    private func enforcedSizeClamp(for windowId: Int, targetFrame: CGRect) -> CGRect? {
        guard let failure = recentFrameWriteFailures[windowId],
              failure.isTerminalRefusal,
              failure.components.contains(.size),
              let observedFrame = failure.observedFrame,
              Self.isAXTopLeftAnchoredSizeClamp(target: failure.targetFrame, observed: observedFrame),
              axFrameMatches(targetFrame, target: failure.targetFrame, components: .size)
        else {
            return nil
        }
        return observedFrame
    }

    func enforcedSizePlacement(for windowId: Int, targetFrame: CGRect) -> CGRect? {
        guard let clamp = enforcedSizeClamp(for: windowId, targetFrame: targetFrame) else {
            return nil
        }
        return CGRect(
            x: targetFrame.minX,
            y: targetFrame.maxY - clamp.height,
            width: clamp.width,
            height: clamp.height
        )
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        recentFrameWriteFailures[windowId]?.reason
    }

    func hasTerminalRefusal(for windowId: Int) -> Bool {
        recentFrameWriteFailures[windowId]?.isTerminalRefusal == true
    }

    func recentFrameWriteFailureComponents(for windowId: Int) -> AXFrameComponents? {
        recentFrameWriteFailures[windowId]?.components
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        pendingFrameWrites[windowId]?.frame
    }

    func stateDump() -> String {
        let windowIds = Set(appliedFrameStates.keys)
            .union(pendingFrameWrites.keys)
            .union(recentFrameWriteFailures.keys)
            .union(retryBudgetByWindowId.keys)
        guard !windowIds.isEmpty else { return "none" }
        return windowIds.sorted()
            .map { windowId in
                var parts = ["win=\(windowId)"]
                if let state = appliedFrameStates[windowId] {
                    parts.append("lastApplied=\(TraceFormat.rect(state.frame))")
                    parts.append("verifiedComponents=\(state.verifiedComponents.rawValue)")
                    if let target = state.convergedTargetFrame {
                        parts.append("convergedTarget=\(TraceFormat.rect(target))")
                    }
                }
                if let pending = pendingFrameWrites[windowId] {
                    parts.append("pending=\(TraceFormat.rect(pending.frame))")
                }
                if let failure = recentFrameWriteFailures[windowId] {
                    parts.append("failure=\(failure.reason.traceDescription)")
                    if failure.isTerminalRefusal {
                        parts.append("refusedTarget=\(TraceFormat.rect(failure.targetFrame))")
                    }
                }
                if let retry = retryBudgetByWindowId[windowId] { parts.append("retryBudget=\(retry)") }
                return parts.joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private func frameWithinConvergence(
        state: AppliedFrameState,
        target: CGRect,
        components: AXFrameComponents
    ) -> Bool {
        axFrameMatches(state.frame, target: target, components: components)
            || (components == .all
                && state.convergedTargetFrame?.approximatelyEqual(
                    to: target,
                    tolerance: FrameTolerance.frameWrite
                ) == true)
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        if pendingFrameWrites[windowId] != nil {
            return true
        }
        guard let observedFrame else {
            if appliedFrameStates[windowId]?.convergedTargetFrame != nil {
                appliedFrameStates.removeValue(forKey: windowId)
            }
            return false
        }
        guard let appliedState = appliedFrameStates[windowId] else {
            return false
        }
        guard observedFrame.approximatelyEqual(
            to: appliedState.frame,
            tolerance: FrameTolerance.frameWrite
        ) else {
            appliedFrameStates.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    func rekeyWindowState(oldWindowId: Int, newWindowId: Int) {
        guard oldWindowId != newWindowId else { return }
        rekeyedWindowIdsByPreviousId[oldWindowId] = newWindowId
        let remappedWindowIds = rekeyedWindowIdsByPreviousId.compactMap { previousWindowId, mappedWindowId in
            mappedWindowId == oldWindowId ? previousWindowId : nil
        }
        for previousWindowId in remappedWindowIds {
            rekeyedWindowIdsByPreviousId[previousWindowId] = newWindowId
        }

        if let state = appliedFrameStates.removeValue(forKey: oldWindowId) {
            appliedFrameStates[newWindowId] = state
        }

        if var pending = pendingFrameWrites.removeValue(forKey: oldWindowId) {
            pending.expectedWindow = AXWindowRef(
                element: pending.expectedWindow.element,
                windowId: newWindowId
            )
            pendingFrameWrites[newWindowId] = pending
        }

        if var failure = recentFrameWriteFailures.removeValue(forKey: oldWindowId) {
            failure.expectedWindow = AXWindowRef(
                element: failure.expectedWindow.element,
                windowId: newWindowId
            )
            recentFrameWriteFailures[newWindowId] = failure
        }

        if let retryBudget = retryBudgetByWindowId.removeValue(forKey: oldWindowId) {
            retryBudgetByWindowId[newWindowId] = retryBudget
        }

        if forceApplyWindowIds.remove(oldWindowId) != nil {
            forceApplyWindowIds.insert(newWindowId)
        }

        if let requestId = observerRequestIdByWindowId.removeValue(forKey: oldWindowId) {
            observerRequestIdByWindowId[newWindowId] = requestId
            if var pendingObserver = pendingFrameObserversByRequestId[requestId] {
                pendingObserver.windowId = newWindowId
                pendingObserver.expectedWindow = AXWindowRef(
                    element: pendingObserver.expectedWindow.element,
                    windowId: newWindowId
                )
                pendingFrameObserversByRequestId[requestId] = pendingObserver
            }
        }
        clearSettledRekeyMappings(to: newWindowId)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        appliedFrameStates[windowId] = AppliedFrameState(
            frame: frame,
            verifiedComponents: .all,
            convergedTargetFrame: nil
        )
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        clearSettledRekeyMappings(to: windowId)
    }

    func removeWindowState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        pruneRekeyMappingsAfterRemovingWindowState(for: windowId)
        return deliveries
    }

    func cancelFrameJob(windowId: Int) -> [AXFrameTerminalDelivery] {
        cancelFrameJob(pid: nil, windowId: windowId).deliveries
    }

    func cancelFrameJob(pid: pid_t, windowId: Int) -> AXFrameJobCancellationOutcome {
        cancelFrameJob(pid: Optional(pid), windowId: windowId)
    }

    private func cancelFrameJob(pid: pid_t?, windowId: Int) -> AXFrameJobCancellationOutcome {
        let pending = pendingFrameWrites[windowId]
        let requestId = pending?.requestId
        let traceRequestId = pending?.traceRequestId ?? 0
        let targetFrame = pending?.frame
        let components = pending?.components ?? .all
        let expectedWindow = pending?.expectedWindow
        let currentFrameHint = appliedFrameStates[windowId]?.frame
        let deliveries = cancelObserver(for: windowId)
        let terminalFailure: AXFrameApplyResult? = if let pid,
                                                      let requestId,
                                                      let targetFrame,
                                                      let expectedWindow
        {
            AXFrameApplyResult(
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                targetFrame: targetFrame,
                currentFrameHint: currentFrameHint,
                writeResult: .skipped(
                    targetFrame: targetFrame,
                    currentFrameHint: currentFrameHint,
                    failureReason: .cancelled,
                    observedFrame: currentFrameHint,
                    components: components
                ),
                traceRequestId: traceRequestId
            )
        } else {
            nil
        }
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return AXFrameJobCancellationOutcome(
            deliveries: deliveries,
            terminalFailure: terminalFailure
        )
    }

    func suppressFrameWrite(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return deliveries
    }

    func prepareFrameApplication(
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        components: AXFrameComponents = .all,
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: AXFrameApplicationTerminalObserver?,
        traceOrigin: FrameEffectTraceOrigin = .none,
        parentTraceRequestId: UInt64 = 0
    ) -> AXFrameEnqueueDecision {
        let traceRequestId = traceOrigin.effectId != 0 || parentTraceRequestId != 0
            ? FrameEffectTraceContext.makeRequestTraceId(parentTraceId: parentTraceRequestId)
            : 0
        let cachedState = appliedFrameStates[windowId]
        let cachedFrame = cachedState?.frame
        let pendingWrite = pendingFrameWrites[windowId]
        let pendingFrame = pendingWrite?.frame
        let pendingComponents = pendingWrite?.components
        let pendingVerify = pendingWrite?.verify
        let pendingWindow = pendingWrite?.expectedWindow
        var effectiveComponents = components
        if let pendingComponents,
           let pendingWindow,
           sameAXWindowIdentity(pendingWindow, expectedWindow)
        {
            effectiveComponents.formUnion(pendingComponents)
        }
        let effectiveVerify = verify
            || (pendingWindow.map { sameAXWindowIdentity($0, expectedWindow) } == true
                && pendingVerify == true)
        let hasRecentFailure = recentFrameWriteFailures[windowId] != nil
        let shouldForceApply = forceApplyWindowIds.remove(windowId) != nil
        let shouldReverifyAssumedFrame = effectiveVerify
            && cachedState?.verifiedComponents.contains(effectiveComponents) != true
        if !shouldForceApply {
            if let pendingFrame,
               let pendingWindow,
               sameAXWindowIdentity(pendingWindow, expectedWindow),
               pendingComponents == effectiveComponents,
               pendingVerify == effectiveVerify,
               pendingFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
            {
                if let terminalObserver,
                   !isRetry,
                   appendPendingFrameObserver(
                       terminalObserver,
                       for: windowId,
                       expectedWindow: expectedWindow,
                       targetFrame: frame,
                       components: effectiveComponents
                   )
                {
                    if traceRequestId != 0 {
                        recordTraceDecision(
                            traceRequestId: traceRequestId,
                            effectOrigin: traceOrigin,
                            parentTraceRequestId: parentTraceRequestId,
                            requestId: 0,
                            pid: pid,
                            windowId: windowId,
                            frame: frame,
                            outcome: "ledger-coalesced/pending",
                            relatedTraceRequestId: pendingFrameWrites[windowId]?.traceRequestId ?? 0
                        )
                    }
                    return AXFrameEnqueueDecision()
                }
                if terminalObserver == nil || isRetry {
                    if traceRequestId != 0 {
                        recordTraceDecision(
                            traceRequestId: traceRequestId,
                            effectOrigin: traceOrigin,
                            parentTraceRequestId: parentTraceRequestId,
                            requestId: 0,
                            pid: pid,
                            windowId: windowId,
                            frame: frame,
                            outcome: "ledger-coalesced/pending",
                            relatedTraceRequestId: pendingFrameWrites[windowId]?.traceRequestId ?? 0
                        )
                    }
                    return AXFrameEnqueueDecision()
                }
            } else if pendingFrame == nil,
                      let refusal = rememberedTerminalRefusal(
                          windowId: windowId,
                          expectedWindow: expectedWindow,
                          frame: frame,
                          components: effectiveComponents
                      )
            {
                let refusedRequestId = terminalObserver == nil ? 0 : makeNextFrameApplicationRequestId()
                recordTraceDecision(
                    traceRequestId: traceRequestId,
                    effectOrigin: traceOrigin,
                    parentTraceRequestId: parentTraceRequestId,
                    requestId: refusedRequestId,
                    pid: pid,
                    windowId: windowId,
                    frame: frame,
                    outcome: "ledger-refused/\(refusal.reason.traceDescription)"
                )
                guard let terminalObserver else { return AXFrameEnqueueDecision() }
                return AXFrameEnqueueDecision(
                    deliveries: [
                        AXFrameTerminalDelivery(
                            result: refusedFrameApplyResult(
                                requestId: refusedRequestId,
                                pid: pid,
                                windowId: windowId,
                                expectedWindow: expectedWindow,
                                frame: frame,
                                currentFrameHint: cachedFrame,
                                refusal: refusal,
                                traceRequestId: traceRequestId
                            ),
                            observers: [terminalObserver]
                        )
                    ]
                )
            } else if pendingFrame == nil,
                      let cachedState,
                      frameWithinConvergence(state: cachedState, target: frame, components: effectiveComponents),
                      !hasRecentFailure,
                      !shouldReverifyAssumedFrame
            {
                if let terminalObserver {
                    let noOpRequestId = makeNextFrameApplicationRequestId()
                    if traceRequestId != 0 {
                        recordTraceDecision(
                            traceRequestId: traceRequestId,
                            effectOrigin: traceOrigin,
                            parentTraceRequestId: parentTraceRequestId,
                            requestId: noOpRequestId,
                            pid: pid,
                            windowId: windowId,
                            frame: frame,
                            outcome: "ledger-noop/applied/terminal"
                        )
                    }
                    return AXFrameEnqueueDecision(
                        deliveries: [
                            AXFrameTerminalDelivery(
                                result: successfulNoOpFrameApplyResult(
                                    requestId: noOpRequestId,
                                    pid: pid,
                                    windowId: windowId,
                                    expectedWindow: expectedWindow,
                                    frame: frame,
                                    currentFrameHint: cachedFrame,
                                    observedFrame: cachedState.frame,
                                    components: effectiveComponents,
                                    traceRequestId: traceRequestId
                                ),
                                observers: [terminalObserver]
                            )
                        ]
                    )
                }
                if traceRequestId != 0 {
                    recordTraceDecision(
                        traceRequestId: traceRequestId,
                        effectOrigin: traceOrigin,
                        parentTraceRequestId: parentTraceRequestId,
                        requestId: 0,
                        pid: pid,
                        windowId: windowId,
                        frame: frame,
                        outcome: "ledger-noop/applied/terminal"
                    )
                }
                return AXFrameEnqueueDecision()
            }
        }

        var deliveries: [AXFrameTerminalDelivery] = []
        if !isRetry,
           let requestId = observerRequestIdByWindowId[windowId],
           let pendingObserver = pendingFrameObserversByRequestId[requestId],
           (!pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
               || pendingObserver.components != effectiveComponents
               || !sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow))
        {
            deliveries.append(contentsOf: discardPendingFrameObserver(for: windowId))
        }

        let existingObserverRequestId = observerRequestIdByWindowId[windowId]
        let requestId = makeNextFrameApplicationRequestId()
        if let cachedState, cachedState.convergedTargetFrame != nil {
            appliedFrameStates[windowId] = AppliedFrameState(
                frame: cachedState.frame,
                verifiedComponents: cachedState.verifiedComponents,
                convergedTargetFrame: nil
            )
        }
        pendingFrameWrites[windowId] = PendingFrameWrite(
            frame: frame,
            components: effectiveComponents,
            verify: effectiveVerify,
            expectedWindow: expectedWindow,
            requestId: requestId,
            traceRequestId: traceRequestId
        )
        if !isRetry,
           !retainsTerminalSizeRefusal(
               windowId: windowId,
               components: effectiveComponents,
               enforcedSizeTarget: shouldForceApply ? nil : frame
           )
        {
            recentFrameWriteFailures.removeValue(forKey: windowId)
        }
        if let existingObserverRequestId,
           var pendingObserver = pendingFrameObserversByRequestId[existingObserverRequestId],
           sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow),
           (pendingObserver.targetFrame.approximatelyEqual(
               to: frame,
               tolerance: FrameTolerance.frameWrite
           ) && pendingObserver.components == effectiveComponents)
        {
            pendingFrameObserversByRequestId.removeValue(forKey: existingObserverRequestId)
            pendingObserver.windowId = windowId
            pendingObserver.targetFrame = frame
            pendingObserver.components = effectiveComponents
            pendingObserver.traceRequestId = traceRequestId
            if let terminalObserver {
                pendingObserver.observers.append(terminalObserver)
            }
            pendingFrameObserversByRequestId[requestId] = pendingObserver
            observerRequestIdByWindowId[windowId] = requestId
        } else if let terminalObserver {
            pendingFrameObserversByRequestId[requestId] = PendingFrameObserver(
                windowId: windowId,
                pid: pid,
                expectedWindow: expectedWindow,
                targetFrame: frame,
                currentFrameHint: cachedFrame,
                components: effectiveComponents,
                observers: [terminalObserver],
                traceRequestId: traceRequestId
            )
            observerRequestIdByWindowId[windowId] = requestId
        }
        if !isRetry {
            retryBudgetByWindowId[windowId] = 1
        }
        if traceRequestId != 0 {
            recordTraceDecision(
                traceRequestId: traceRequestId,
                effectOrigin: traceOrigin,
                parentTraceRequestId: parentTraceRequestId,
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                frame: frame,
                outcome: isRetry ? "ledger-prepared/retry" : "ledger-prepared"
            )
        }
        return AXFrameEnqueueDecision(
            request: AXFrameApplicationRequest(
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                frame: frame,
                currentFrameHint: cachedFrame,
                components: effectiveComponents,
                verify: effectiveVerify,
                traceRequestId: traceRequestId
            ),
            deliveries: deliveries,
            shouldCancelPendingRetry: !isRetry
        )
    }

    func handleFrameApplyResults(
        _ results: [AXFrameApplyResult],
        onAcceptedSuccess: (AXFrameApplyResult) -> Void = { _ in }
    ) -> AXFrameApplyOutcome {
        var outcome = AXFrameApplyOutcome()
        for result in results {
            let resolvedWindowId = resolveWindowId(for: result.windowId)
            let resultResolvedThroughRekey = resolvedWindowId != result.windowId
            let resolvedResult = resolvedWindowId == result.windowId ? result : result.rekeyed(to: resolvedWindowId)
            guard let resolvedPending = pendingFrameWrites[resolvedWindowId],
                  resolvedPending.requestId == resolvedResult.requestId,
                  sameAXWindowIdentity(resolvedPending.expectedWindow, resolvedResult.expectedWindow),
                  resolvedPending.components == resolvedResult.writeResult.components,
                  resolvedPending.frame.approximatelyEqual(
                      to: resolvedResult.targetFrame,
                      tolerance: FrameTolerance.frameWrite
                  )
            else {
                continue
            }

            pendingFrameWrites.removeValue(forKey: resolvedWindowId)

            if let confirmedFrame = resolvedResult.confirmedFrame {
                let priorState = appliedFrameStates[resolvedWindowId]
                let verifiedComponents: AXFrameComponents
                let appliedFrame: CGRect
                if resolvedResult.writeResult.observedFrame != nil {
                    verifiedComponents = .all
                    appliedFrame = confirmedFrame
                } else {
                    var retained = priorState?.verifiedComponents ?? []
                    retained.subtract(resolvedResult.writeResult.components)
                    verifiedComponents = retained
                    var composedFrame = confirmedFrame
                    if !resolvedResult.writeResult.components.contains(.position), let priorState {
                        composedFrame.origin = priorState.frame.origin
                    }
                    if !resolvedResult.writeResult.components.contains(.size), let priorState {
                        composedFrame.size = priorState.frame.size
                    }
                    appliedFrame = composedFrame
                }
                appliedFrameStates[resolvedWindowId] = AppliedFrameState(
                    frame: appliedFrame,
                    verifiedComponents: verifiedComponents,
                    convergedTargetFrame: nil
                )
                let observedRefusedSize = observedFrameShowsRefusedSize(
                    windowId: resolvedWindowId,
                    result: resolvedResult
                )
                if observedRefusedSize || !retainsTerminalSizeRefusal(
                    windowId: resolvedWindowId,
                    components: resolvedResult.writeResult.components
                ) {
                    recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                }
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                onAcceptedSuccess(resolvedResult)
                outcome.deliveries.append(contentsOf: notifyPendingFrameObserver(with: resolvedResult))
                clearSettledRekeyMappings(to: resolvedWindowId)
                continue
            }

            let priorFailure = recentFrameWriteFailures[resolvedWindowId]
            if let failureReason = resolvedResult.writeResult.failureReason {
                recentFrameWriteFailures[resolvedWindowId] = RecentFrameWriteFailure(
                    pid: resolvedResult.pid,
                    expectedWindow: resolvedResult.expectedWindow,
                    reason: failureReason,
                    targetFrame: resolvedResult.targetFrame,
                    observedFrame: resolvedResult.writeResult.observedFrame,
                    settersSucceeded: resolvedResult.writeResult.sizeError == .success
                        && resolvedResult.writeResult.positionError == .success,
                    components: resolvedResult.writeResult.components,
                    isTerminalRefusal: priorFailure.map {
                        $0.isTerminalRefusal && repeatsRefusedOutcome($0, result: resolvedResult)
                    } ?? false
                )
            }

            let remainingRetries = retryBudgetByWindowId[resolvedWindowId] ?? 0
            guard remainingRetries > 0,
                  shouldRetryFrameWrite(
                      after: resolvedResult,
                      resultResolvedThroughRekey: resultResolvedThroughRekey
                  )
            else {
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                if let failureReason = resolvedResult.writeResult.failureReason,
                   priorFailure?.reason == failureReason,
                   let observedFrame = resolvedResult.writeResult.observedFrame
                {
                    let stableSizeClamp = isStableSizeClamp(
                        priorFailure: priorFailure,
                        result: resolvedResult,
                        observedFrame: observedFrame
                    )
                    if stableSizeClamp,
                       observedFrame.width >= resolvedResult.targetFrame.width - FrameTolerance.frameWrite,
                       observedFrame.height >= resolvedResult.targetFrame.height - FrameTolerance.frameWrite,
                       observedFrame.width > resolvedResult.targetFrame.width + FrameTolerance.frameWrite
                       || observedFrame.height > resolvedResult.targetFrame.height + FrameTolerance.frameWrite
                    {
                        outcome.stableSizeClamps.append(resolvedResult)
                    }
                    if stableSizeClamp,
                       let priorFailure,
                       let priorObservedFrame = priorFailure.observedFrame,
                       Self.isBoundedAXTopLeftSizeConvergence(
                           target: priorFailure.targetFrame,
                           observed: priorObservedFrame
                       ),
                       Self.isBoundedAXTopLeftSizeConvergence(
                           target: resolvedResult.targetFrame,
                           observed: observedFrame
                       )
                    {
                        appliedFrameStates[resolvedWindowId] = AppliedFrameState(
                            frame: observedFrame,
                            verifiedComponents: .all,
                            convergedTargetFrame: resolvedResult.targetFrame
                        )
                        let acceptedResult = acceptedSizeConvergenceResult(
                            resolvedResult,
                            observedFrame: observedFrame
                        )
                        recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                        FrameApplyTrace.recordAcceptedSizeConvergence(acceptedResult)
                        onAcceptedSuccess(acceptedResult)
                        outcome.deliveries.append(
                            contentsOf: notifyPendingFrameObserver(with: acceptedResult)
                        )
                        clearSettledRekeyMappings(to: resolvedWindowId)
                        continue
                    }
                    recentFrameWriteFailures[resolvedWindowId]?.isTerminalRefusal = true
                    outcome.terminalRefusals.append(
                        AXFrameTerminalRefusal(
                            pid: resolvedResult.pid,
                            windowId: resolvedWindowId,
                            targetFrame: resolvedResult.targetFrame,
                            observedFrame: observedFrame,
                            failureReason: failureReason,
                            requestId: resolvedResult.requestId,
                            traceRequestId: resolvedResult.traceRequestId
                        )
                    )
                }
                let deliveries = notifyPendingFrameObserver(with: resolvedResult)
                outcome.deliveries.append(contentsOf: deliveries)
                outcome.terminalFailures.append(resolvedResult)
                clearSettledRekeyMappings(to: resolvedWindowId)
                continue
            }

            retryBudgetByWindowId[resolvedWindowId] = remainingRetries - 1
            forceApplyWindowIds.insert(resolvedWindowId)

            outcome.retries.append(
                AXFrameRetryRequest(
                    requestId: resolvedResult.requestId,
                    pid: resolvedResult.pid,
                    windowId: resolvedWindowId,
                    expectedWindow: resolvedResult.expectedWindow,
                    frame: resolvedResult.targetFrame,
                    currentFrameHint: resolvedResult.currentFrameHint,
                    components: resolvedResult.writeResult.components,
                    traceRequestId: resolvedResult.traceRequestId
                )
            )
        }
        return outcome
    }

    func resolvedWindowId(for windowId: Int) -> Int {
        resolveWindowId(for: windowId)
    }

    func cancelAllPendingFrameState() -> [AXFrameTerminalDelivery] {
        let deliveries = pendingFrameObserversByRequestId.map { requestId, pendingObserver in
            let currentFrameHint = pendingFrameWrites[pendingObserver.windowId]?.frame
                ?? appliedFrameStates[pendingObserver.windowId]?.frame
                ?? pendingObserver.currentFrameHint
            return AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    expectedWindow: pendingObserver.expectedWindow,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint,
                        components: pendingObserver.components
                    ),
                    traceRequestId: pendingObserver.traceRequestId
                ),
                observers: pendingObserver.observers
            )
        }

        pendingFrameObserversByRequestId.removeAll()
        observerRequestIdByWindowId.removeAll()
        pendingFrameWrites.removeAll()
        recentFrameWriteFailures.removeAll()
        retryBudgetByWindowId.removeAll()
        forceApplyWindowIds.removeAll()
        rekeyedWindowIdsByPreviousId.removeAll()

        return deliveries
    }

    private func cancelObserver(for windowId: Int) -> [AXFrameTerminalDelivery] {
        guard let requestId = observerRequestIdByWindowId.removeValue(forKey: windowId),
              let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: requestId)
        else {
            return []
        }
        let currentFrameHint = pendingFrameWrites[windowId]?.frame ?? appliedFrameStates[windowId]?.frame
        return [
            AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    expectedWindow: pendingObserver.expectedWindow,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint,
                        components: pendingObserver.components
                    ),
                    traceRequestId: pendingObserver.traceRequestId
                ),
                observers: pendingObserver.observers
            )
        ]
    }

    private func notifyPendingFrameObserver(with result: AXFrameApplyResult) -> [AXFrameTerminalDelivery] {
        guard let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: result.requestId) else {
            return []
        }
        if observerRequestIdByWindowId[pendingObserver.windowId] == result.requestId {
            observerRequestIdByWindowId.removeValue(forKey: pendingObserver.windowId)
        }
        let deliveredResult = pendingObserver.windowId == result.windowId
            ? result
            : result.rekeyed(to: pendingObserver.windowId)
        return [
            AXFrameTerminalDelivery(
                result: deliveredResult,
                observers: pendingObserver.observers
            )
        ]
    }

    private func shouldRetryFrameWrite(
        after result: AXFrameApplyResult,
        resultResolvedThroughRekey: Bool
    ) -> Bool {
        guard let failureReason = result.writeResult.failureReason else { return false }
        switch failureReason {
        case .cancelled:
            return resultResolvedThroughRekey
        case .suppressed:
            return false
        default:
            return true
        }
    }

    private func makeNextFrameApplicationRequestId() -> AXFrameRequestId {
        defer { nextFrameApplicationRequestId += 1 }
        return nextFrameApplicationRequestId
    }

    private func appendPendingFrameObserver(
        _ observer: @escaping AXFrameApplicationTerminalObserver,
        for windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        components: AXFrameComponents
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              var pendingObserver = pendingFrameObserversByRequestId[requestId],
              sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow),
              pendingObserver.components == components,
              pendingObserver.targetFrame.approximatelyEqual(to: targetFrame, tolerance: FrameTolerance.frameWrite)
        else {
            return false
        }

        pendingObserver.observers.append(observer)
        pendingFrameObserversByRequestId[requestId] = pendingObserver
        return true
    }

    private func discardPendingFrameObserver(for windowId: Int) -> [AXFrameTerminalDelivery] {
        cancelObserver(for: windowId)
    }

    private func successfulNoOpFrameApplyResult(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        observedFrame: CGRect,
        components: AXFrameComponents,
        traceRequestId: UInt64
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: AXWindowService.frameWriteOrder(
                    currentFrame: currentFrameHint,
                    targetFrame: frame
                ),
                sizeError: .success,
                positionError: .success,
                failureReason: nil,
                components: components
            ),
            traceRequestId: traceRequestId
        )
    }

    private func retainsTerminalSizeRefusal(
        windowId: Int,
        components: AXFrameComponents,
        enforcedSizeTarget: CGRect? = nil
    ) -> Bool {
        guard let failure = recentFrameWriteFailures[windowId], failure.isTerminalRefusal else {
            return false
        }
        guard components.contains(.size) else { return true }
        guard let enforcedSizeTarget else { return false }
        return enforcedSizeClamp(for: windowId, targetFrame: enforcedSizeTarget) != nil
    }

    private func observedFrameShowsRefusedSize(windowId: Int, result: AXFrameApplyResult) -> Bool {
        guard let failure = recentFrameWriteFailures[windowId],
              failure.isTerminalRefusal,
              let observedFrame = result.writeResult.observedFrame,
              sameAXWindowIdentity(failure.expectedWindow, result.expectedWindow)
        else {
            return false
        }
        return axFrameMatches(observedFrame, target: failure.targetFrame, components: .size)
    }

    private func repeatsRefusedOutcome(
        _ failure: RecentFrameWriteFailure,
        result: AXFrameApplyResult
    ) -> Bool {
        guard failure.reason == result.writeResult.failureReason,
              failure.components == result.writeResult.components,
              sameAXWindowIdentity(failure.expectedWindow, result.expectedWindow),
              axFrameMatches(result.targetFrame, target: failure.targetFrame, components: .size),
              let priorObservedFrame = failure.observedFrame,
              let observedFrame = result.writeResult.observedFrame
        else {
            return false
        }
        return axFrameMatches(observedFrame, target: priorObservedFrame, components: .size)
            && Self.isAXTopLeftAnchoredSizeClamp(target: result.targetFrame, observed: observedFrame)
    }

    private func rememberedTerminalRefusal(
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        components: AXFrameComponents
    ) -> RecentFrameWriteFailure? {
        guard let failure = recentFrameWriteFailures[windowId],
              failure.isTerminalRefusal,
              failure.components == components,
              sameAXWindowIdentity(failure.expectedWindow, expectedWindow),
              failure.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
        else {
            return nil
        }
        return failure
    }

    private func refusedFrameApplyResult(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        refusal: RecentFrameWriteFailure,
        traceRequestId: UInt64
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: currentFrameHint,
            writeResult: .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: refusal.reason,
                observedFrame: refusal.observedFrame,
                components: refusal.components
            ),
            traceRequestId: traceRequestId
        )
    }

    private func acceptedSizeConvergenceResult(
        _ result: AXFrameApplyResult,
        observedFrame: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: result.requestId,
            pid: result.pid,
            windowId: result.windowId,
            expectedWindow: result.expectedWindow,
            targetFrame: result.targetFrame,
            currentFrameHint: result.currentFrameHint,
            writeResult: AXFrameWriteResult(
                observedFrame: observedFrame,
                writeOrder: result.writeResult.writeOrder,
                sizeError: result.writeResult.sizeError,
                positionError: result.writeResult.positionError,
                failureReason: nil,
                components: result.writeResult.components
            ),
            traceRequestId: result.traceRequestId
        )
    }

    private func recordTraceDecision(
        traceRequestId: UInt64,
        effectOrigin: FrameEffectTraceOrigin,
        parentTraceRequestId: UInt64,
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        frame: CGRect,
        outcome: String,
        relatedTraceRequestId: UInt64 = 0
    ) {
        guard traceRequestId != 0 else { return }
        FrameApplyTrace.recordEvent(
            pid: pid,
            windowId: windowId,
            outcome: outcome,
            target: frame,
            requestId: requestId,
            traceRequestId: traceRequestId,
            effectOrigin: effectOrigin,
            parentTraceId: parentTraceRequestId,
            relatedTraceId: relatedTraceRequestId
        )
    }

    private func resolveWindowId(for windowId: Int) -> Int {
        var resolvedWindowId = windowId
        var visitedWindowIds: Set<Int> = []
        while let rekeyedWindowId = rekeyedWindowIdsByPreviousId[resolvedWindowId],
              visitedWindowIds.insert(resolvedWindowId).inserted
        {
            resolvedWindowId = rekeyedWindowId
        }
        return resolvedWindowId
    }

    private func hasUnsettledFrameState(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
            || retryBudgetByWindowId[windowId] != nil
            || observerRequestIdByWindowId[windowId] != nil
    }

    private func clearSettledRekeyMappings(to windowId: Int) {
        guard !rekeyedWindowIdsByPreviousId.isEmpty,
              !hasUnsettledFrameState(for: windowId),
              rekeyedWindowIdsByPreviousId.values.contains(windowId)
        else { return }
        rekeyedWindowIdsByPreviousId = rekeyedWindowIdsByPreviousId.filter { _, mappedWindowId in
            mappedWindowId != windowId
        }
    }

    private func pruneRekeyMappingsAfterRemovingWindowState(for windowId: Int) {
        rekeyedWindowIdsByPreviousId = rekeyedWindowIdsByPreviousId.filter { previousWindowId, mappedWindowId in
            if mappedWindowId == windowId {
                return false
            }
            if previousWindowId == windowId {
                return hasUnsettledFrameState(for: mappedWindowId)
            }
            return true
        }
    }
}
