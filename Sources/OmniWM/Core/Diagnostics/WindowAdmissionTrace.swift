// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import os
import Synchronization

enum WindowAdmissionTraceAction: String, Codable, Sendable {
    case processLaunched = "process_launched"
    case processTerminated = "process_terminated"
    case endpointCreated = "endpoint_created"
    case endpointDestroyed = "endpoint_destroyed"
    case enumerationStarted = "enumeration_started"
    case enumerationCompleted = "enumeration_completed"
    case enumerationEmpty = "enumeration_empty"
    case enumerationFailed = "enumeration_failed"
    case topLevelAccepted = "top_level_accepted"
    case topLevelRejected = "top_level_rejected"
    case fullRescanCandidate = "full_rescan_candidate"
    case fullRescanSelected = "full_rescan_selected"
    case fullRescanRejected = "full_rescan_rejected"
    case frontmostObserved = "frontmost_observed"
    case managedFocusObserved = "managed_focus_observed"
    case cgsCreated = "cgs_created"
    case cgsDestroyed = "cgs_destroyed"
    case classificationObserved = "classification_observed"
    case admissionPrepared = "admission_prepared"
    case admissionAlreadyTracked = "admission_already_tracked"
    case admissionReplaced = "admission_replaced"
    case admissionPending = "admission_pending"
    case admissionIgnored = "admission_ignored"
    case admissionRetryScheduled = "admission_retry_scheduled"
    case admissionRetryExhausted = "admission_retry_exhausted"
    case admissionTracked = "admission_tracked"
    case admissionDestroyed = "admission_destroyed"
    case admissionDisappeared = "admission_disappeared"
    case admissionQuarantined = "admission_quarantined"
    case terminalFrameRefusal = "terminal_frame_refusal"
}

struct WindowAdmissionTraceRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

struct WindowAdmissionTraceEvent: Sendable {
    let action: WindowAdmissionTraceAction
    let pid: pid_t?
    let windowId: Int?
    let bundleId: String?
    let axPid: pid_t?
    let windowServerPid: pid_t?
    let competingPid: pid_t?
    let role: String?
    let subrole: String?
    let reason: String?
    let outcome: String?
    let count: Int?
    let attempt: Int?
    let retryGeneration: UInt64?
    let callbackGeneration: UInt64?
    let manageable: Bool?
    let targetFrame: WindowAdmissionTraceRect?
    let observedFrame: WindowAdmissionTraceRect?
    let observation: WindowClassificationObservation?
    let classificationRulesSnapshot: WindowClassificationRulesSnapshot?
    let axRef: AXWindowRef?

    init(
        action: WindowAdmissionTraceAction,
        pid: pid_t? = nil,
        windowId: Int? = nil,
        bundleId: String? = nil,
        axPid: pid_t? = nil,
        windowServerPid: pid_t? = nil,
        competingPid: pid_t? = nil,
        role: String? = nil,
        subrole: String? = nil,
        reason: String? = nil,
        outcome: String? = nil,
        count: Int? = nil,
        attempt: Int? = nil,
        retryGeneration: UInt64? = nil,
        callbackGeneration: UInt64? = nil,
        manageable: Bool? = nil,
        targetFrame: CGRect? = nil,
        observedFrame: CGRect? = nil,
        observation: WindowClassificationObservation? = nil,
        classificationRulesSnapshot: WindowClassificationRulesSnapshot? = nil,
        axRef: AXWindowRef? = nil
    ) {
        self.action = action
        self.pid = pid
        self.windowId = windowId
        self.bundleId = bundleId.map(RuntimeTraceLimits.boundedString)
        self.axPid = axPid
        self.windowServerPid = windowServerPid
        self.competingPid = competingPid
        self.role = role.map(RuntimeTraceLimits.boundedString)
        self.subrole = subrole.map(RuntimeTraceLimits.boundedString)
        self.reason = reason.map(RuntimeTraceLimits.boundedString)
        self.outcome = outcome.map(RuntimeTraceLimits.boundedString)
        self.count = count
        self.attempt = attempt
        self.retryGeneration = retryGeneration
        self.callbackGeneration = callbackGeneration
        self.manageable = manageable
        self.targetFrame = targetFrame.map(WindowAdmissionTraceRect.init)
        self.observedFrame = observedFrame.map(WindowAdmissionTraceRect.init)
        self.observation = observation?.boundedForDiagnostics()
        self.classificationRulesSnapshot = classificationRulesSnapshot
        self.axRef = axRef
    }
}

struct WindowAdmissionTraceRecord: Codable, Equatable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let action: WindowAdmissionTraceAction
    let pid: pid_t?
    let windowId: Int?
    let bundleId: String?
    let axPid: pid_t?
    let windowServerPid: pid_t?
    let competingPid: pid_t?
    let processGeneration: UInt64?
    let windowGeneration: UInt64?
    let endpointGeneration: UInt64?
    let callbackGeneration: UInt64?
    let retryGeneration: UInt64?
    let role: String?
    let subrole: String?
    let reason: String?
    let outcome: String?
    let count: Int?
    let attempt: Int?
    let manageable: Bool?
    let targetFrame: WindowAdmissionTraceRect?
    let observedFrame: WindowAdmissionTraceRect?
    let observation: WindowClassificationObservation?
}

struct WindowAdmissionFinalizationTarget: Sendable {
    let action: WindowAdmissionTraceAction
    let pid: pid_t
    let windowId: Int?
    let bundleId: String?
    let reason: String
    let processGeneration: UInt64
    let windowGeneration: UInt64?
    let endpointGeneration: UInt64?
    let callbackGeneration: UInt64?
}

final class WindowAdmissionTrace: RuntimeTraceRecording, @unchecked Sendable {
    static let shared = WindowAdmissionTrace()

    let sectionTitle = "Window Admission Timeline"

    private struct ProcessState {
        var generation: UInt64
        var isLive: Bool
    }

    private struct WindowState {
        var generation: UInt64
        var isLive: Bool
        var ownerPID: pid_t?
        var ownerProcessGeneration: UInt64?
    }

    private struct EndpointState {
        var generation: UInt64
        var isLive: Bool
        var callbackGeneration: UInt64?
    }

    private struct StoredRulesSnapshot {
        let snapshot: WindowClassificationRulesSnapshot
        let estimatedBytes: Int
    }

    private struct State {
        var records: RingBuffer<WindowAdmissionTraceRecord>
        var nextSequence: UInt64 = 0
        var processes: [pid_t: ProcessState] = [:]
        var windows: [Int: WindowState] = [:]
        var endpoints: [pid_t: EndpointState] = [:]
        var finalizationTargets = WindowAdmissionFinalizationTargets()
        var rulesSnapshots: [UInt64: StoredRulesSnapshot] = [:]
        var rulesSnapshotReferenceCounts: [UInt64: Int] = [:]
        var rulesRevisionOrder: [UInt64] = []
        var rulesSnapshotStorageOrder: [UInt64] = []
    }

    private static let defaultCapacity = 4096
    private let active = Atomic<Bool>(false)
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int = WindowAdmissionTrace.defaultCapacity) {
        state = OSAllocatedUnfairLock(initialState: State(records: RingBuffer(capacity: capacity)))
    }

    var isActive: Bool {
        active.load(ordering: .relaxed)
    }

    static func record(_ make: @autoclosure () -> WindowAdmissionTraceEvent) {
        shared.record(make())
    }

    func record(_ make: @autoclosure () -> WindowAdmissionTraceEvent) {
        guard active.load(ordering: .relaxed) else { return }
        let event = make()
        guard active.load(ordering: .relaxed) else { return }
        let timestamp = Date()
        state.withLock { state in
            guard active.load(ordering: .relaxed) else { return }
            let processGeneration = processGeneration(for: event, state: &state)
            let endpointGeneration = endpointGeneration(for: event, state: &state)
            let windowGeneration = windowGeneration(
                for: event,
                processGeneration: processGeneration,
                allowMutation: event.callbackGeneration == nil || endpointGeneration != nil,
                state: &state
            )
            let record = WindowAdmissionTraceRecord(
                sequence: state.nextSequence,
                timestamp: timestamp,
                action: event.action,
                pid: event.pid,
                windowId: event.windowId,
                bundleId: event.bundleId,
                axPid: event.axPid,
                windowServerPid: event.windowServerPid,
                competingPid: event.competingPid,
                processGeneration: processGeneration,
                windowGeneration: windowGeneration,
                endpointGeneration: endpointGeneration,
                callbackGeneration: event.callbackGeneration,
                retryGeneration: event.retryGeneration,
                role: event.role,
                subrole: event.subrole,
                reason: event.reason,
                outcome: event.outcome,
                count: event.count,
                attempt: event.attempt,
                manageable: event.manageable,
                targetFrame: event.targetFrame,
                observedFrame: event.observedFrame,
                observation: event.observation
            )
            state.nextSequence &+= 1
            let evicted = state.records.append(record)
            updateRulesSnapshots(event: event, evicted: evicted, state: &state)
            updateTargets(event: event, record: record, state: &state)
            pruneAuxiliaryState(&state)
        }
    }

    func beginCapture() {
        state.withLock { state in
            state = State(records: RingBuffer(capacity: state.records.capacity))
        }
        active.store(true, ordering: .relaxed)
    }

    func endCapture() {
        active.store(false, ordering: .relaxed)
        state.withLock { _ in }
    }

    func releaseStorage() {
        state.withLock { state in
            state = State(records: RingBuffer(capacity: state.records.capacity))
        }
    }

    func dump() -> String {
        var lines: [String] = []
        forEachLine {
            lines.append($0)
            return true
        }
        return lines.joined(separator: "\n")
    }

    func forEachLine(_ body: (String) -> Bool) {
        let snapshot = state.withLock { state in
            (
                records: state.records.snapshot(),
                rulesSnapshots: state.rulesRevisionOrder.compactMap { revision in
                    state.rulesSnapshots[revision]?.snapshot
                },
                referencedRulesSnapshotCount: state.rulesSnapshotReferenceCounts.count,
                omittedRulesSnapshotCount: state.rulesSnapshotReferenceCounts.count
                    - state.rulesSnapshots.count
            )
        }
        guard !snapshot.records.isEmpty else {
            _ = body("none")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedSnapshots = snapshot.rulesSnapshots.map { rulesSnapshot in
            rulesSnapshot.encodedLine(using: encoder)
        }
        var selectedLines: [String] = []
        var selectedBytes = 0
        for line in encodedSnapshots.reversed() {
            let candidateCount = selectedLines.count + 1
            let omittedCount = snapshot.omittedRulesSnapshotCount
                + encodedSnapshots.count
                - candidateCount
            let markerBytes = omittedCount > 0
                ? rulesTruncationMarker(omittedCount: omittedCount).utf8.count + 1
                : 0
            let lineBytes = line.utf8.count + 1
            guard selectedBytes + lineBytes + markerBytes
                <= RuntimeTraceLimits.cumulativeRulesSnapshotBytes
            else {
                continue
            }
            selectedLines.append(line)
            selectedBytes += lineBytes
        }
        for line in selectedLines.reversed() {
            guard body(line) else { return }
        }
        let omittedCount = snapshot.referencedRulesSnapshotCount - selectedLines.count
        if omittedCount > 0 {
            let marker = rulesTruncationMarker(
                omittedCount: omittedCount
            )
            guard body(marker) else { return }
        }
        for record in snapshot.records {
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8)
            else { continue }
            guard body(line) else { return }
        }
    }

    private func rulesTruncationMarker(omittedCount: Int) -> String {
        "{\"kind\":\"rules_snapshots_truncated\",\"omittedCount\":\(omittedCount)}"
    }

    func recordsSnapshot() -> [WindowAdmissionTraceRecord] {
        state.withLock { $0.records.snapshot() }
    }

    func finalizationTarget(excludingPID excludedPID: pid_t) -> WindowAdmissionFinalizationTarget? {
        state.withLock { state in
            state.finalizationTargets.prioritized
                .first { target in
                    guard target.pid != excludedPID,
                          let process = state.processes[target.pid],
                          process.isLive,
                          process.generation == target.processGeneration
                    else {
                        return false
                    }
                    if let windowId = target.windowId {
                        guard let window = state.windows[windowId],
                              window.isLive,
                              target.windowGeneration == window.generation
                        else {
                            return false
                        }
                    }
                    if let endpointGeneration = target.endpointGeneration {
                        guard let endpoint = state.endpoints[target.pid],
                              endpoint.isLive,
                              endpoint.generation == endpointGeneration
                        else {
                            return false
                        }
                        if let callbackGeneration = target.callbackGeneration,
                           endpoint.callbackGeneration != callbackGeneration
                        {
                            return false
                        }
                    } else if target.callbackGeneration != nil {
                        return false
                    }
                    return true
                }
        }
    }

    private func processGeneration(for event: WindowAdmissionTraceEvent, state: inout State) -> UInt64? {
        guard let pid = event.pid else { return nil }
        var process = state.processes[pid] ?? ProcessState(generation: 1, isLive: true)
        switch event.action {
        case .processLaunched:
            if state.processes[pid] != nil, !process.isLive {
                process.generation &+= 1
            }
            process.isLive = true
        case .processTerminated:
            process.isLive = false
        default:
            break
        }
        state.processes[pid] = process
        return process.generation
    }

    private func windowGeneration(
        for event: WindowAdmissionTraceEvent,
        processGeneration: UInt64?,
        allowMutation: Bool,
        state: inout State
    ) -> UInt64? {
        guard let windowId = event.windowId else { return nil }
        guard allowMutation else { return state.windows[windowId]?.generation }
        let existing = state.windows[windowId]
        let establishesOwner = establishesWindowOwner(event.action)
        var window = existing ?? WindowState(
            generation: 1,
            isLive: true,
            ownerPID: establishesOwner ? event.pid : nil,
            ownerProcessGeneration: establishesOwner ? processGeneration : nil
        )
        switch event.action {
        case .cgsCreated:
            if existing != nil {
                window.generation &+= 1
            }
            window.isLive = true
            window.ownerPID = nil
            window.ownerProcessGeneration = nil
        case .cgsDestroyed,
             .admissionDestroyed,
             .admissionDisappeared:
            guard matchesWindowOwner(
                eventPID: event.pid,
                processGeneration: processGeneration,
                window: window
            ) else {
                return window.generation
            }
            window.isLive = false
            if window.ownerPID == nil {
                window.ownerPID = event.pid
                window.ownerProcessGeneration = processGeneration
            }
        default:
            if event.axRef != nil {
                let ownerChanged = establishesOwner
                    && window.ownerPID != nil
                    && !matchesWindowOwner(
                        eventPID: event.pid,
                        processGeneration: processGeneration,
                        window: window
                    )
                if !window.isLive || ownerChanged {
                    window.generation &+= 1
                }
                window.isLive = true
            }
            if establishesOwner, window.ownerPID == nil || event.axRef != nil {
                window.ownerPID = event.pid ?? window.ownerPID
                window.ownerProcessGeneration = processGeneration ?? window.ownerProcessGeneration
            }
        }
        state.windows[windowId] = window
        return window.generation
    }

    private func matchesWindowOwner(
        eventPID: pid_t?,
        processGeneration: UInt64?,
        window: WindowState
    ) -> Bool {
        guard let eventPID, let ownerPID = window.ownerPID else { return true }
        guard eventPID == ownerPID else { return false }
        guard let processGeneration, let ownerProcessGeneration = window.ownerProcessGeneration else {
            return true
        }
        return processGeneration == ownerProcessGeneration
    }

    private func establishesWindowOwner(_ action: WindowAdmissionTraceAction) -> Bool {
        switch action {
        case .frontmostObserved,
             .managedFocusObserved,
             .fullRescanSelected,
             .admissionPrepared,
             .admissionAlreadyTracked,
             .admissionReplaced,
             .admissionPending,
             .admissionRetryScheduled,
             .admissionRetryExhausted,
             .admissionTracked,
             .admissionQuarantined,
             .terminalFrameRefusal:
            true
        default:
            false
        }
    }

    private func updateRulesSnapshots(
        event: WindowAdmissionTraceEvent,
        evicted: WindowAdmissionTraceRecord?,
        state: inout State
    ) {
        if let revision = evicted?.observation?.rulesRevision,
           let count = state.rulesSnapshotReferenceCounts[revision]
        {
            if count == 1 {
                state.rulesSnapshotReferenceCounts.removeValue(forKey: revision)
                state.rulesSnapshots.removeValue(forKey: revision)
                state.rulesRevisionOrder.removeAll { $0 == revision }
                state.rulesSnapshotStorageOrder.removeAll { $0 == revision }
            } else {
                state.rulesSnapshotReferenceCounts[revision] = count - 1
            }
        }
        guard let observation = event.observation else { return }
        let revision = observation.rulesRevision
        if state.rulesSnapshotReferenceCounts[revision] == nil {
            state.rulesRevisionOrder.append(revision)
        }
        state.rulesSnapshotReferenceCounts[revision, default: 0] += 1
        if state.rulesSnapshots[revision] == nil,
           let snapshot = event.classificationRulesSnapshot
        {
            state.rulesSnapshots[revision] = StoredRulesSnapshot(
                snapshot: snapshot,
                estimatedBytes: snapshot.estimatedDiagnosticBytes
            )
            state.rulesSnapshotStorageOrder.append(revision)
        }
        enforceRulesSnapshotBudget(&state)
    }

    private func enforceRulesSnapshotBudget(_ state: inout State) {
        var storedBytes = state.rulesSnapshots.values.reduce(0) { $0 + $1.estimatedBytes }
        while storedBytes > RuntimeTraceLimits.cumulativeRulesSnapshotBytes {
            guard let oldestRevision = state.rulesSnapshotStorageOrder.first(where: {
                state.rulesSnapshots[$0] != nil
            }),
                let removed = state.rulesSnapshots.removeValue(forKey: oldestRevision)
            else { return }
            storedBytes -= removed.estimatedBytes
            state.rulesSnapshotStorageOrder.removeAll { $0 == oldestRevision }
        }
    }

    private func endpointGeneration(for event: WindowAdmissionTraceEvent, state: inout State) -> UInt64? {
        guard let pid = event.pid, usesEndpoint(event) else { return nil }
        guard state.endpoints[pid] != nil || event.action == .endpointCreated else { return nil }
        var endpoint = state.endpoints[pid] ?? EndpointState(
            generation: 1,
            isLive: true,
            callbackGeneration: event.callbackGeneration
        )
        switch event.action {
        case .endpointCreated:
            if let existing = state.endpoints[pid],
               let incomingGeneration = event.callbackGeneration,
               let currentGeneration = existing.callbackGeneration
            {
                if incomingGeneration == currentGeneration {
                    return existing.isLive ? existing.generation : nil
                }
                guard incomingGeneration > currentGeneration else { return nil }
            }
            if state.endpoints[pid] != nil {
                endpoint.generation &+= 1
            }
            endpoint.isLive = true
            endpoint.callbackGeneration = event.callbackGeneration
        case .endpointDestroyed:
            if endpoint.callbackGeneration == nil {
                endpoint.callbackGeneration = event.callbackGeneration
            }
            guard endpoint.isLive,
                  callbackMatches(event.callbackGeneration, endpoint.callbackGeneration)
            else { return nil }
            endpoint.isLive = false
        default:
            if endpoint.callbackGeneration == nil {
                endpoint.callbackGeneration = event.callbackGeneration
            }
            guard endpoint.isLive,
                  callbackMatches(event.callbackGeneration, endpoint.callbackGeneration)
            else { return nil }
        }
        state.endpoints[pid] = endpoint
        return endpoint.generation
    }

    private func updateTargets(
        event: WindowAdmissionTraceEvent,
        record: WindowAdmissionTraceRecord,
        state: inout State
    ) {
        guard let pid = event.pid,
              let processGeneration = record.processGeneration
        else { return }
        guard event.action != .processTerminated else {
            state.finalizationTargets.clear(for: pid)
            return
        }
        guard let process = state.processes[pid],
              process.isLive,
              process.generation == processGeneration,
              event.callbackGeneration == nil || record.endpointGeneration != nil,
              windowLifecycleEventMatchesOwner(
                  event,
                  processGeneration: processGeneration,
                  state: state
              ),
              event.action != .admissionDisappeared || event.reason != "process_terminated"
        else {
            return
        }
        let candidate = WindowAdmissionFinalizationTarget(
            action: event.action,
            pid: pid,
            windowId: event.windowId,
            bundleId: event.bundleId,
            reason: event.reason ?? event.action.rawValue,
            processGeneration: processGeneration,
            windowGeneration: record.windowGeneration,
            endpointGeneration: record.endpointGeneration,
            callbackGeneration: event.callbackGeneration
        )
        state.finalizationTargets.update(action: event.action, candidate: candidate, count: event.count)
    }

    private func windowLifecycleEventMatchesOwner(
        _ event: WindowAdmissionTraceEvent,
        processGeneration: UInt64,
        state: State
    ) -> Bool {
        switch event.action {
        case .cgsDestroyed,
             .admissionDestroyed,
             .admissionDisappeared:
            guard let windowId = event.windowId, let window = state.windows[windowId] else {
                return true
            }
            return matchesWindowOwner(
                eventPID: event.pid,
                processGeneration: processGeneration,
                window: window
            )
        default:
            return true
        }
    }

    private func pruneAuxiliaryState(_ state: inout State) {
        let limit = state.records.capacity + 256
        guard state.windows.count > limit
            || state.endpoints.count > limit
        else { return }
        let records = state.records.snapshot()
        let pids = Set(records.compactMap(\.pid))
        let windowIds = Set(records.compactMap(\.windowId))
        state.windows = state.windows.filter { windowIds.contains($0.key) }
        state.endpoints = state.endpoints.filter { pids.contains($0.key) }
    }
}

private func usesEndpoint(_ event: WindowAdmissionTraceEvent) -> Bool {
    event.callbackGeneration != nil || event.action == .endpointCreated || event.action == .endpointDestroyed
}

private func callbackMatches(_ eventGeneration: UInt64?, _ currentGeneration: UInt64?) -> Bool {
    eventGeneration == nil || eventGeneration == currentGeneration
}
