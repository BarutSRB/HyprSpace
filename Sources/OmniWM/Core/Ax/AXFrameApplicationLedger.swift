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
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.frame == rhs.frame
    }
}

struct AXFrameTerminalRefusal: Equatable {
    let pid: pid_t
    let windowId: Int
    let targetFrame: CGRect
    let observedFrame: CGRect
    let failureReason: AXFrameWriteFailureReason
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
}

@MainActor
final class AXFrameApplicationLedger {
    private struct AppliedFrameState {
        let frame: CGRect
        let convergedTargetFrame: CGRect?
    }

    private struct RecentFrameWriteFailure {
        let pid: pid_t
        var expectedWindow: AXWindowRef
        let reason: AXFrameWriteFailureReason
        let targetFrame: CGRect
        let observedFrame: CGRect?
        let settersSucceeded: Bool
    }

    private struct PendingFrameObserver {
        var windowId: Int
        let pid: pid_t
        var expectedWindow: AXWindowRef
        let targetFrame: CGRect
        let currentFrameHint: CGRect?
        var observers: [AXFrameApplicationTerminalObserver]
    }

    private var appliedFrameStates: [Int: AppliedFrameState] = [:]
    private var assumedAppliedWindowIds: Set<Int> = []
    private var pendingFrameWrites: [Int: CGRect] = [:]
    private var pendingFrameWindows: [Int: AXWindowRef] = [:]
    private var recentFrameWriteFailures: [Int: RecentFrameWriteFailure] = [:]
    private var retryBudgetByWindowId: [Int: Int] = [:]
    private var forceApplyWindowIds: Set<Int> = []
    private var pendingFrameRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var pendingFrameObserversByRequestId: [AXFrameRequestId: PendingFrameObserver] = [:]
    private var observerRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var rekeyedWindowIdsByPreviousId: [Int: Int] = [:]
    private var nextFrameApplicationRequestId: AXFrameRequestId = 1

    private static let maxAcceptedSizeSnap: CGFloat = 16

    private static func isBoundedAXTopLeftSizeConvergence(target: CGRect, observed: CGRect) -> Bool {
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
        let widthDelta = abs(observed.width - target.width)
        let heightDelta = abs(observed.height - target.height)
        guard widthDelta <= Self.maxAcceptedSizeSnap,
              heightDelta <= Self.maxAcceptedSizeSnap
        else {
            return false
        }
        return widthDelta >= FrameTolerance.frameWrite
            || heightDelta >= FrameTolerance.frameWrite
    }

    private func isStableSizeConvergence(
        priorFailure: RecentFrameWriteFailure,
        result: AXFrameApplyResult,
        observedFrame: CGRect
    ) -> Bool {
        guard priorFailure.pid == result.pid,
              sameAXWindowIdentity(priorFailure.expectedWindow, result.expectedWindow),
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
              Self.isBoundedAXTopLeftSizeConvergence(
                  target: priorFailure.targetFrame,
                  observed: priorObservedFrame
              )
        else {
            return false
        }
        return Self.isBoundedAXTopLeftSizeConvergence(
            target: result.targetFrame,
            observed: observedFrame
        )
    }

    func forceApplyNextFrame(for windowId: Int) {
        forceApplyWindowIds.insert(windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        appliedFrameStates[windowId]?.frame
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        recentFrameWriteFailures[windowId]?.reason
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        pendingFrameWrites[windowId]
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
                    if let target = state.convergedTargetFrame {
                        parts.append("convergedTarget=\(TraceFormat.rect(target))")
                    }
                }
                if let pending = pendingFrameWrites[windowId] { parts.append("pending=\(TraceFormat.rect(pending))") }
                if let failure = recentFrameWriteFailures[windowId] {
                    parts.append("failure=\(failure.reason.traceDescription)")
                }
                if let retry = retryBudgetByWindowId[windowId] { parts.append("retryBudget=\(retry)") }
                return parts.joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private func frameWithinConvergence(state: AppliedFrameState, target: CGRect) -> Bool {
        state.frame.approximatelyEqual(to: target, tolerance: FrameTolerance.frameWrite)
            || state.convergedTargetFrame?.approximatelyEqual(
                to: target,
                tolerance: FrameTolerance.frameWrite
            ) == true
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
            if appliedState.convergedTargetFrame != nil {
                appliedFrameStates.removeValue(forKey: windowId)
            }
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

        if assumedAppliedWindowIds.remove(oldWindowId) != nil {
            assumedAppliedWindowIds.insert(newWindowId)
        }

        if let frame = pendingFrameWrites.removeValue(forKey: oldWindowId) {
            pendingFrameWrites[newWindowId] = frame
        }
        if let window = pendingFrameWindows.removeValue(forKey: oldWindowId) {
            pendingFrameWindows[newWindowId] = AXWindowRef(
                element: window.element,
                windowId: newWindowId
            )
        }

        if let requestId = pendingFrameRequestIdByWindowId.removeValue(forKey: oldWindowId) {
            pendingFrameRequestIdByWindowId[newWindowId] = requestId
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
            convergedTargetFrame: nil
        )
        assumedAppliedWindowIds.remove(windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        clearSettledRekeyMappings(to: windowId)
    }

    func removeWindowState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        assumedAppliedWindowIds.remove(windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameWindows.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        pruneRekeyMappingsAfterRemovingWindowState(for: windowId)
        return deliveries
    }

    func cancelFrameJob(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameWindows.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return deliveries
    }

    func suppressFrameWrite(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        assumedAppliedWindowIds.remove(windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameWindows.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
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
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: AXFrameApplicationTerminalObserver?
    ) -> AXFrameEnqueueDecision {
        let cachedState = appliedFrameStates[windowId]
        let cachedFrame = cachedState?.frame
        let pendingFrame = pendingFrameWrites[windowId]
        let hasRecentFailure = recentFrameWriteFailures[windowId] != nil
        let shouldForceApply = forceApplyWindowIds.remove(windowId) != nil
        let shouldReverifyAssumedFrame = verify && assumedAppliedWindowIds.contains(windowId)
        if !shouldForceApply {
            if let pendingFrame,
               let pendingWindow = pendingFrameWindows[windowId],
               sameAXWindowIdentity(pendingWindow, expectedWindow),
               pendingFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
            {
                if let terminalObserver,
                   !isRetry,
                   appendPendingFrameObserver(
                       terminalObserver,
                       for: windowId,
                       expectedWindow: expectedWindow,
                       targetFrame: frame
                   )
                {
                    return AXFrameEnqueueDecision()
                }
                if terminalObserver == nil || isRetry {
                    return AXFrameEnqueueDecision()
                }
            } else if let cachedState,
                      frameWithinConvergence(state: cachedState, target: frame),
                      !hasRecentFailure,
                      !shouldReverifyAssumedFrame
            {
                if let terminalObserver {
                    return AXFrameEnqueueDecision(
                        deliveries: [
                            AXFrameTerminalDelivery(
                                result: successfulNoOpFrameApplyResult(
                                    requestId: makeNextFrameApplicationRequestId(),
                                    pid: pid,
                                    windowId: windowId,
                                    expectedWindow: expectedWindow,
                                    frame: frame,
                                    currentFrameHint: cachedFrame,
                                    observedFrame: cachedState.frame
                                ),
                                observers: [terminalObserver]
                            )
                        ]
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
               || !sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow))
        {
            deliveries.append(contentsOf: discardPendingFrameObserver(for: windowId))
        }

        let existingObserverRequestId = observerRequestIdByWindowId[windowId]
        let requestId = makeNextFrameApplicationRequestId()
        if let cachedState, cachedState.convergedTargetFrame != nil {
            appliedFrameStates[windowId] = AppliedFrameState(
                frame: cachedState.frame,
                convergedTargetFrame: nil
            )
        }
        pendingFrameWrites[windowId] = frame
        pendingFrameWindows[windowId] = expectedWindow
        pendingFrameRequestIdByWindowId[windowId] = requestId
        if !isRetry {
            recentFrameWriteFailures.removeValue(forKey: windowId)
        }
        if let existingObserverRequestId,
           var pendingObserver = pendingFrameObserversByRequestId[existingObserverRequestId],
           pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite),
           sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow)
        {
            pendingFrameObserversByRequestId.removeValue(forKey: existingObserverRequestId)
            pendingObserver.windowId = windowId
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
                observers: [terminalObserver]
            )
            observerRequestIdByWindowId[windowId] = requestId
        }
        if !isRetry {
            retryBudgetByWindowId[windowId] = 1
        }
        return AXFrameEnqueueDecision(
            request: AXFrameApplicationRequest(
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                expectedWindow: expectedWindow,
                frame: frame,
                currentFrameHint: cachedFrame,
                verify: verify
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
            guard pendingFrameRequestIdByWindowId[resolvedWindowId] == resolvedResult.requestId,
                  let pendingFrame = pendingFrameWrites[resolvedWindowId],
                  let pendingWindow = pendingFrameWindows[resolvedWindowId],
                  sameAXWindowIdentity(pendingWindow, resolvedResult.expectedWindow),
                  pendingFrame.approximatelyEqual(to: resolvedResult.targetFrame, tolerance: FrameTolerance.frameWrite)
            else {
                continue
            }

            pendingFrameWrites.removeValue(forKey: resolvedWindowId)
            pendingFrameWindows.removeValue(forKey: resolvedWindowId)
            pendingFrameRequestIdByWindowId.removeValue(forKey: resolvedWindowId)

            if let confirmedFrame = resolvedResult.confirmedFrame {
                appliedFrameStates[resolvedWindowId] = AppliedFrameState(
                    frame: confirmedFrame,
                    convergedTargetFrame: nil
                )
                if resolvedResult.writeResult.observedFrame == nil {
                    assumedAppliedWindowIds.insert(resolvedWindowId)
                } else {
                    assumedAppliedWindowIds.remove(resolvedWindowId)
                }
                recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
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
                        && resolvedResult.writeResult.positionError == .success
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
                    if failureReason == .verificationMismatch,
                       let priorFailure,
                       isStableSizeConvergence(
                           priorFailure: priorFailure,
                           result: resolvedResult,
                           observedFrame: observedFrame
                       )
                    {
                        appliedFrameStates[resolvedWindowId] = AppliedFrameState(
                            frame: observedFrame,
                            convergedTargetFrame: resolvedResult.targetFrame
                        )
                        let acceptedResult = acceptedSizeConvergenceResult(
                            resolvedResult,
                            observedFrame: observedFrame
                        )
                        assumedAppliedWindowIds.remove(resolvedWindowId)
                        recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                        FrameApplyTrace.recordAcceptedSizeConvergence(acceptedResult)
                        onAcceptedSuccess(acceptedResult)
                        outcome.deliveries.append(
                            contentsOf: notifyPendingFrameObserver(with: acceptedResult)
                        )
                        clearSettledRekeyMappings(to: resolvedWindowId)
                        continue
                    }
                    outcome.terminalRefusals.append(
                        AXFrameTerminalRefusal(
                            pid: resolvedResult.pid,
                            windowId: resolvedWindowId,
                            targetFrame: resolvedResult.targetFrame,
                            observedFrame: observedFrame,
                            failureReason: failureReason
                        )
                    )
                }
                outcome.deliveries.append(contentsOf: notifyPendingFrameObserver(with: resolvedResult))
                clearSettledRekeyMappings(to: resolvedWindowId)
                continue
            }

            retryBudgetByWindowId[resolvedWindowId] = remainingRetries - 1
            forceApplyWindowIds.insert(resolvedWindowId)

            outcome.retries.append(
                AXFrameRetryRequest(
                    pid: resolvedResult.pid,
                    windowId: resolvedWindowId,
                    expectedWindow: resolvedResult.expectedWindow,
                    frame: resolvedResult.targetFrame
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
            let currentFrameHint = pendingFrameWrites[pendingObserver.windowId]
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
                        observedFrame: currentFrameHint
                    )
                ),
                observers: pendingObserver.observers
            )
        }

        pendingFrameObserversByRequestId.removeAll()
        observerRequestIdByWindowId.removeAll()
        pendingFrameWrites.removeAll()
        pendingFrameWindows.removeAll()
        pendingFrameRequestIdByWindowId.removeAll()
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
        let currentFrameHint = pendingFrameWrites[windowId] ?? appliedFrameStates[windowId]?.frame
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
                        observedFrame: currentFrameHint
                    )
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
        targetFrame: CGRect
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              var pendingObserver = pendingFrameObserversByRequestId[requestId],
              sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow),
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
        observedFrame: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: frame,
            currentFrameHint: currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: frame,
                observedFrame: observedFrame,
                writeOrder: AXWindowService.frameWriteOrder(
                    currentFrame: currentFrameHint,
                    targetFrame: frame
                ),
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
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
                targetFrame: result.targetFrame,
                observedFrame: observedFrame,
                writeOrder: result.writeResult.writeOrder,
                sizeError: result.writeResult.sizeError,
                positionError: result.writeResult.positionError,
                failureReason: nil
            )
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
