// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Dispatch
import Foundation
import os

enum FrameApplyTrace {
    struct Record: Sendable {
        let uptimeNs: UInt64
        let requestTraceId: UInt64
        let effectId: UInt64
        let effectKind: FrameEffectTraceKind
        let displayId: CGDirectDisplayID
        let parentTraceId: UInt64
        let relatedTraceId: UInt64
        let requestId: AXFrameRequestId
        let pid: pid_t
        let callbackGeneration: UInt64
        let lane: AppAXFrameLane
        let submissionId: UInt64
        let drainId: UInt64
        let windowId: Int
        let attempt: UInt8
        let outcome: String
        let target: CGRect?
        let hint: CGRect?
        let observed: CGRect?
        let confirmed: CGRect?
        let eventUptimeNs: UInt64
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Frame Apply Trace",
        capacity: 65_536
    ) { record in
        "scope=ax-ordinary+ax-park closing=excluded skylight-position=excluded"
            + " t_ns=\(record.uptimeNs) trace=\(record.requestTraceId) effect=\(record.effectId)"
            + " origin=\(record.effectKind.traceDescription) display=\(record.displayId)"
            + " parent=\(record.parentTraceId) related=\(record.relatedTraceId)"
            + " request=\(record.requestId) win=\(record.windowId) pid=\(record.pid)"
            + " context=\(record.callbackGeneration) lane=\(record.lane.traceDescription)"
            + " submission=\(record.submissionId) drain=\(record.drainId)"
            + " attempt=\(record.attempt) event=\(record.outcome)"
            + " target=\(TraceFormat.rect(record.target))"
            + " hint=\(TraceFormat.rect(record.hint))"
            + " observed=\(TraceFormat.rect(record.observed))"
            + " confirmed=\(TraceFormat.rect(record.confirmed))"
            + " cgs_t_ns=\(record.eventUptimeNs)"
    }

    static func recordResult(_ result: AXFrameApplyResult, lane: AppAXFrameLane = .ordinary) {
        guard shared.isActive else { return }
        FrameEffectObservationTracker.shared.noteWriteResult(result)
        let outcome: String = if let reason = result.writeResult.failureReason {
            "outcome=skip/\(reason.traceDescription)"
        } else {
            result.confirmedFrame != nil ? "outcome=confirmed" : "outcome=applied"
        }
        recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: outcome,
            target: result.targetFrame,
            hint: result.currentFrameHint,
            observed: result.writeResult.observedFrame,
            confirmed: result.confirmedFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId,
            lane: lane
        )
    }

    static func recordAcceptedSizeConvergence(_ result: AXFrameApplyResult) {
        guard shared.isActive else { return }
        if let confirmedFrame = result.confirmedFrame {
            FrameEffectObservationTracker.shared.updateAcceptedTarget(
                traceRequestId: result.traceRequestId,
                target: confirmedFrame
            )
        }
        recordEvent(
            pid: result.pid,
            windowId: result.windowId,
            outcome: "outcome=accepted-size-convergence",
            target: result.targetFrame,
            hint: result.currentFrameHint,
            observed: result.writeResult.observedFrame,
            confirmed: result.confirmedFrame,
            requestId: result.requestId,
            traceRequestId: result.traceRequestId
        )
    }

    static func recordEvent(
        pid: pid_t,
        windowId: Int,
        outcome: String,
        target: CGRect? = nil,
        hint: CGRect? = nil,
        observed: CGRect? = nil,
        confirmed: CGRect? = nil,
        requestId: AXFrameRequestId = 0,
        traceRequestId: UInt64 = 0,
        effectOrigin: FrameEffectTraceOrigin = .none,
        parentTraceId: UInt64 = 0,
        relatedTraceId: UInt64 = 0,
        callbackGeneration: UInt64 = 0,
        lane: AppAXFrameLane = .ordinary,
        submissionId: UInt64 = 0,
        drainId: UInt64 = 0,
        attempt: UInt8 = 0,
        eventUptimeNs: UInt64 = 0,
        uptimeNs: UInt64 = 0
    ) {
        guard shared.isActive else { return }
        let currentTraceRequestId = FrameEffectTraceContext.currentCaptureIdentifier(traceRequestId)
        let currentEffectId = FrameEffectTraceContext.currentCaptureIdentifier(effectOrigin.effectId)
        let currentEffectOrigin = currentEffectId == 0
            ? FrameEffectTraceOrigin.none
            : FrameEffectTraceOrigin(
                effectId: currentEffectId,
                displayId: effectOrigin.displayId,
                kind: effectOrigin.kind
            )
        shared.record(
            Record(
                uptimeNs: uptimeNs == 0 ? DispatchTime.now().uptimeNanoseconds : uptimeNs,
                requestTraceId: currentTraceRequestId,
                effectId: currentEffectOrigin.effectId,
                effectKind: currentEffectOrigin.kind,
                displayId: currentEffectOrigin.displayId,
                parentTraceId: FrameEffectTraceContext.currentCaptureIdentifier(parentTraceId),
                relatedTraceId: FrameEffectTraceContext.currentCaptureIdentifier(relatedTraceId),
                requestId: requestId,
                pid: pid,
                callbackGeneration: callbackGeneration,
                lane: lane,
                submissionId: submissionId,
                drainId: drainId,
                windowId: windowId,
                attempt: attempt,
                outcome: outcome,
                target: target,
                hint: hint,
                observed: observed,
                confirmed: confirmed,
                eventUptimeNs: eventUptimeNs
            )
        )
    }
}

final class FrameEffectObservationTracker: @unchecked Sendable {
    struct Pending: Equatable, Sendable {
        let traceRequestId: UInt64
        let requestId: AXFrameRequestId
        let pid: pid_t
        let windowId: Int
        let lane: AppAXFrameLane
        let attempt: UInt8
        var target: CGRect
        let startedNs: UInt64
        let deadlineNs: UInt64
        var mismatchCount: UInt8 = 0
        var lastEventNs: UInt64 = 0
        var lastSampleNs: UInt64 = 0
        var lastObserved: CGRect?
    }

    private struct State {
        var captureGeneration: UInt64 = 0
        var pendingByWindowId: [Int: Pending] = [:]
        var scheduledByWindowId: [Int: ScheduledObservation] = [:]
        var dirtyByWindowId: [Int: ObservationEvent] = [:]
        var nextScheduleToken: UInt64 = 1
    }

    private struct ObservationEvent: Equatable, Sendable {
        let traceRequestId: UInt64
        let eventNs: UInt64
    }

    private struct ScheduledObservation: Equatable, Sendable {
        let token: UInt64
        let traceRequestId: UInt64
        let eventNs: UInt64
    }

    enum ObservationWork: Equatable, Sendable {
        case none
        case sample
        case reschedule(UInt64)
    }

    private struct Completion {
        let pending: Pending?
        let outcome: String?
        let terminal: Bool
        let rescheduleToken: UInt64?
    }

    static let shared = FrameEffectObservationTracker()

    private let capacity: Int
    private let timeoutNs: UInt64
    private let maxMismatchCount: UInt8
    private let state = OSAllocatedUnfairLock(initialState: State())
    @MainActor private var timeoutTask: Task<Void, Never>?

    init(
        capacity: Int = 512,
        timeoutNs: UInt64 = 1_000_000_000,
        maxMismatchCount: UInt8 = 3
    ) {
        self.capacity = max(1, capacity)
        self.timeoutNs = timeoutNs
        self.maxMismatchCount = max(1, maxMismatchCount)
    }

    var pendingCount: Int {
        state.withLock { $0.pendingByWindowId.count }
    }

    var retainedStorageCapacity: Int {
        state.withLock {
            $0.pendingByWindowId.capacity
                + $0.scheduledByWindowId.capacity
                + $0.dirtyByWindowId.capacity
        }
    }

    @MainActor
    func beginCapture(generation: UInt64, startTimeoutTask: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        state.withLock { state in
            state.captureGeneration = generation & 0xFFFF_FFFF
            state.pendingByWindowId.removeAll(keepingCapacity: true)
            state.scheduledByWindowId.removeAll(keepingCapacity: true)
            state.dirtyByWindowId.removeAll(keepingCapacity: true)
        }
        guard startTimeoutTask else { return }
        timeoutTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.expire(nowNs: DispatchTime.now().uptimeNanoseconds)
            }
        }
    }

    @MainActor
    func endCapture() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = state.withLock { state in
            let pending = Array(state.pendingByWindowId.values)
            state.captureGeneration = 0
            state.pendingByWindowId.removeAll(keepingCapacity: false)
            state.scheduledByWindowId.removeAll(keepingCapacity: false)
            state.dirtyByWindowId.removeAll(keepingCapacity: false)
            return pending
        }
        for item in pending {
            record(item, outcome: "server-observation/end-capture", terminal: true)
        }
    }

    func register(
        traceRequestId: UInt64,
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        lane: AppAXFrameLane,
        attempt: UInt8,
        target: CGRect,
        startedNs: UInt64
    ) {
        guard traceRequestId != 0, lane.supportsFrameEffectTracing else { return }
        let (superseded, capacityEviction) = state.withLock { state -> (Pending?, Pending?) in
            guard state.captureGeneration == FrameEffectTraceContext.captureGeneration(of: traceRequestId) else {
                return (nil, nil)
            }
            let superseded = state.pendingByWindowId.removeValue(forKey: windowId)
            var capacityEviction: Pending?
            state.dirtyByWindowId.removeValue(forKey: windowId)
            if superseded == nil,
               state.pendingByWindowId.count >= capacity,
               let oldest = state.pendingByWindowId.min(by: { $0.value.startedNs < $1.value.startedNs })
            {
                capacityEviction = state.pendingByWindowId.removeValue(forKey: oldest.key)
                if let capacityEviction {
                    Self.clearObservationEvents(
                        windowId: oldest.key,
                        traceRequestId: capacityEviction.traceRequestId,
                        state: &state
                    )
                }
            }
            state.pendingByWindowId[windowId] = Pending(
                traceRequestId: traceRequestId,
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                lane: lane,
                attempt: attempt,
                target: target,
                startedNs: startedNs,
                deadlineNs: startedNs &+ timeoutNs
            )
            return (superseded, capacityEviction)
        }
        if let superseded {
            record(
                superseded,
                outcome: "server-observation/superseded",
                terminal: true,
                relatedTraceId: traceRequestId
            )
        }
        if let capacityEviction {
            record(capacityEviction, outcome: "server-observation/capacity", terminal: true)
        }
    }

    @discardableResult
    func noteFrameChanged(windowId: Int, eventNs: UInt64) -> UInt64? {
        state.withLock { state in
            guard let pending = state.pendingByWindowId[windowId] else { return nil }
            let event = ObservationEvent(
                traceRequestId: pending.traceRequestId,
                eventNs: eventNs
            )
            if state.scheduledByWindowId[windowId] != nil {
                state.dirtyByWindowId[windowId] = event
                return nil
            }
            return Self.schedule(event, windowId: windowId, state: &state)
        }
    }

    func prepareObservation(windowId: Int, token: UInt64) -> ObservationWork {
        state.withLock { state in
            guard let scheduled = state.scheduledByWindowId[windowId],
                  scheduled.token == token
            else {
                return .none
            }
            guard let pending = state.pendingByWindowId[windowId] else {
                state.scheduledByWindowId.removeValue(forKey: windowId)
                state.dirtyByWindowId.removeValue(forKey: windowId)
                return .none
            }
            guard pending.traceRequestId == scheduled.traceRequestId else {
                return Self.retireStaleSchedule(
                    windowId: windowId,
                    pending: pending,
                    state: &state
                )
            }
            return .sample
        }
    }

    func completeObservation(
        windowId: Int,
        token: UInt64,
        observed: CGRect?,
        sampledNs: UInt64
    ) -> UInt64? {
        let completion = state.withLock { state -> Completion in
            guard let scheduled = state.scheduledByWindowId[windowId],
                  scheduled.token == token
            else {
                return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: nil)
            }
            guard var pending = state.pendingByWindowId[windowId] else {
                state.scheduledByWindowId.removeValue(forKey: windowId)
                state.dirtyByWindowId.removeValue(forKey: windowId)
                return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: nil)
            }
            guard pending.traceRequestId == scheduled.traceRequestId else {
                let work = Self.retireStaleSchedule(
                    windowId: windowId,
                    pending: pending,
                    state: &state
                )
                let token: UInt64? = if case let .reschedule(token) = work { token } else { nil }
                return Completion(pending: nil, outcome: nil, terminal: false, rescheduleToken: token)
            }
            state.scheduledByWindowId.removeValue(forKey: windowId)
            pending.lastEventNs = scheduled.eventNs
            pending.lastSampleNs = sampledNs
            pending.lastObserved = observed
            if let observed,
               observed.approximatelyEqual(to: pending.target, tolerance: FrameTolerance.frameWrite)
            {
                state.pendingByWindowId.removeValue(forKey: windowId)
                state.dirtyByWindowId.removeValue(forKey: windowId)
                return Completion(
                    pending: pending,
                    outcome: "server-observation/match",
                    terminal: true,
                    rescheduleToken: nil
                )
            }
            pending.mismatchCount &+= 1
            let terminal = pending.mismatchCount >= maxMismatchCount
            let outcome = observed == nil
                ? "server-observation/unavailable"
                : "server-observation/mismatch"
            if terminal {
                state.pendingByWindowId.removeValue(forKey: windowId)
                state.dirtyByWindowId.removeValue(forKey: windowId)
                return Completion(
                    pending: pending,
                    outcome: outcome,
                    terminal: true,
                    rescheduleToken: nil
                )
            }
            state.pendingByWindowId[windowId] = pending
            var rescheduleToken: UInt64?
            if let dirty = state.dirtyByWindowId.removeValue(forKey: windowId),
               dirty.traceRequestId == pending.traceRequestId
            {
                rescheduleToken = Self.schedule(dirty, windowId: windowId, state: &state)
            }
            return Completion(
                pending: pending,
                outcome: outcome + "/sample",
                terminal: false,
                rescheduleToken: rescheduleToken
            )
        }
        if let pending = completion.pending, let outcome = completion.outcome {
            record(pending, outcome: outcome, terminal: completion.terminal)
        }
        return completion.rescheduleToken
    }

    func noteWriteResult(_ result: AXFrameApplyResult) {
        guard result.traceRequestId != 0 else { return }
        let writeResult = result.writeResult
        guard writeResult.sizeError != .success
            || writeResult.positionError != .success
            || writeResult.failureReason == .valueCreationFailed
            || writeResult.failureReason == .contextUnavailable
            || writeResult.failureReason == .cancelled
            || writeResult.failureReason == .suppressed
        else {
            return
        }
        remove(
            traceRequestId: result.traceRequestId,
            outcome: "server-observation/write-terminal"
        )
    }

    func updateAcceptedTarget(traceRequestId: UInt64, target: CGRect) {
        guard traceRequestId != 0 else { return }
        let matched = state.withLock { state -> Pending? in
            guard let entry = state.pendingByWindowId.first(where: {
                $0.value.traceRequestId == traceRequestId
            }) else { return nil }
            var pending = entry.value
            pending.target = target
            if let observed = pending.lastObserved,
               observed.approximatelyEqual(to: target, tolerance: FrameTolerance.frameWrite)
            {
                state.pendingByWindowId.removeValue(forKey: entry.key)
                Self.clearObservationEvents(
                    windowId: entry.key,
                    traceRequestId: traceRequestId,
                    state: &state
                )
                return pending
            } else {
                state.pendingByWindowId[entry.key] = pending
                return nil
            }
        }
        if let matched {
            record(matched, outcome: "server-observation/match-converged", terminal: true)
        }
    }

    func expire(nowNs: UInt64) {
        let expired = state.withLock { state in
            let windowIds = state.pendingByWindowId.compactMap { entry in
                entry.value.deadlineNs <= nowNs ? entry.key : nil
            }
            return windowIds.compactMap { windowId -> Pending? in
                guard let pending = state.pendingByWindowId.removeValue(forKey: windowId) else {
                    return nil
                }
                Self.clearObservationEvents(
                    windowId: windowId,
                    traceRequestId: pending.traceRequestId,
                    state: &state
                )
                return pending
            }
        }
        for pending in expired {
            record(pending, outcome: "server-observation/timeout", terminal: true, uptimeNs: nowNs)
        }
    }

    static func noteCGSFrameChanged(windowId: Int, eventNs: UInt64) {
        guard let token = shared.noteFrameChanged(windowId: windowId, eventNs: eventNs) else { return }
        scheduleObservation(windowId: windowId, token: token)
    }

    @MainActor
    private static func observeWindowServerFrame(windowId: Int, token: UInt64) {
        switch shared.prepareObservation(windowId: windowId, token: token) {
        case .none:
            return
        case let .reschedule(nextToken):
            scheduleObservation(windowId: windowId, token: nextToken)
            return
        case .sample:
            break
        }
        let observed = SkyLight.shared.getWindowBounds(UInt32(windowId)).map {
            ScreenCoordinateSpace.toAppKit(rect: $0)
        }
        let nextToken = shared.completeObservation(
            windowId: windowId,
            token: token,
            observed: observed,
            sampledNs: DispatchTime.now().uptimeNanoseconds
        )
        if let nextToken {
            scheduleObservation(windowId: windowId, token: nextToken)
        }
    }

    private static func scheduleObservation(windowId: Int, token: UInt64) {
        Task { @MainActor in
            await Task.yield()
            observeWindowServerFrame(windowId: windowId, token: token)
        }
    }

    private func remove(traceRequestId: UInt64, outcome: String) {
        let removed = state.withLock { state -> Pending? in
            guard let entry = state.pendingByWindowId.first(where: {
                $0.value.traceRequestId == traceRequestId
            }) else { return nil }
            let removed = state.pendingByWindowId.removeValue(forKey: entry.key)
            Self.clearObservationEvents(
                windowId: entry.key,
                traceRequestId: traceRequestId,
                state: &state
            )
            return removed
        }
        if let removed {
            record(removed, outcome: outcome, terminal: true)
        }
    }

    private static func schedule(
        _ event: ObservationEvent,
        windowId: Int,
        state: inout State
    ) -> UInt64 {
        var token = state.nextScheduleToken
        state.nextScheduleToken &+= 1
        if token == 0 {
            token = state.nextScheduleToken
            state.nextScheduleToken &+= 1
        }
        state.scheduledByWindowId[windowId] = ScheduledObservation(
            token: token,
            traceRequestId: event.traceRequestId,
            eventNs: event.eventNs
        )
        return token
    }

    private static func retireStaleSchedule(
        windowId: Int,
        pending: Pending,
        state: inout State
    ) -> ObservationWork {
        state.scheduledByWindowId.removeValue(forKey: windowId)
        guard let dirty = state.dirtyByWindowId.removeValue(forKey: windowId),
              dirty.traceRequestId == pending.traceRequestId
        else {
            return .none
        }
        return .reschedule(schedule(dirty, windowId: windowId, state: &state))
    }

    private static func clearObservationEvents(
        windowId: Int,
        traceRequestId: UInt64,
        state: inout State
    ) {
        if state.scheduledByWindowId[windowId]?.traceRequestId == traceRequestId {
            state.scheduledByWindowId.removeValue(forKey: windowId)
        }
        if state.dirtyByWindowId[windowId]?.traceRequestId == traceRequestId {
            state.dirtyByWindowId.removeValue(forKey: windowId)
        }
    }

    private func record(
        _ pending: Pending,
        outcome: String,
        terminal: Bool,
        relatedTraceId: UInt64 = 0,
        uptimeNs: UInt64 = 0
    ) {
        FrameApplyTrace.recordEvent(
            pid: pending.pid,
            windowId: pending.windowId,
            outcome: terminal ? outcome + "/terminal" : outcome,
            target: pending.target,
            observed: pending.lastObserved,
            requestId: pending.requestId,
            traceRequestId: pending.traceRequestId,
            relatedTraceId: relatedTraceId,
            lane: pending.lane,
            attempt: pending.attempt,
            eventUptimeNs: pending.lastEventNs,
            uptimeNs: uptimeNs == 0 ? pending.lastSampleNs : uptimeNs
        )
    }
}
