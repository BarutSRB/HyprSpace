// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit

private let multitouchTouchStride = 96
private let multitouchStateByteOffset = 20
private let multitouchPositionXByteOffset = 32
private let multitouchPositionYByteOffset = 36
private let multitouchTouchingState: Int32 = 4

@MainActor
final class MultitouchGestureSource {
    struct RawTouch: Sendable {
        let x: Float
        let y: Float
    }

    struct RawTouchBuffer: RandomAccessCollection, Sendable {
        private var inline = InlineArray<16, RawTouch>(repeating: RawTouch(x: 0, y: 0))
        private var overflow: [RawTouch] = []
        private(set) var count = 0

        var startIndex: Int {
            0
        }

        var endIndex: Int {
            count
        }

        init() {}

        init(_ touches: [RawTouch]) {
            for touch in touches {
                append(touch)
            }
        }

        mutating func append(_ touch: RawTouch) {
            if count < inline.count {
                inline[count] = touch
            } else {
                overflow.append(touch)
            }
            count += 1
        }

        subscript(index: Int) -> RawTouch {
            index < inline.count ? inline[index] : overflow[index - inline.count]
        }
    }

    struct RawFrame: Sendable {
        let touches: RawTouchBuffer
        let timestamp: Double

        init(touches: [RawTouch], timestamp: Double) {
            self.touches = RawTouchBuffer(touches)
            self.timestamp = timestamp
        }

        init(touches: consuming RawTouchBuffer, timestamp: Double) {
            self.touches = consume touches
            self.timestamp = timestamp
        }
    }

    enum LifecycleState: String, Sendable {
        case stopped
        case suspended
        case waiting
        case enumerating
        case running
        case retrying
        case exhausted
        case unavailable
    }

    enum RevalidationReason: String, CaseIterable, Hashable, Sendable {
        case startup
        case wake
        case unlock
        case arrival
        case removal
        case observerRecovery
    }

    enum TopologySignal: String, Sendable {
        case arrival
        case removal
    }

    enum TopologyObserverState: Equatable, Sendable {
        case stopped
        case monitoring
        case retrying(Int)
        case exhausted
    }

    enum OperationResult: Equatable, Sendable {
        case notAttempted
        case success
        case alreadyStopped(Int32)
        case alreadyUnregistered
        case status(Int32)
        case rejected
    }

    struct DiagnosticsSnapshot: Sendable {
        let state: LifecycleState
        let activeGeneration: UInt?
        let registeredDeviceCount: Int
        let lastEnumeration: MultitouchBinding.EnumerationOutcome?
        let lastRegister: OperationResult
        let lastStart: OperationResult
        let lastRunningCheck: OperationResult
        let lastStop: OperationResult
        let lastUnregister: OperationResult
        let retryReasons: [RevalidationReason]
        let retryEpisode: UInt64
        let retryAttempt: Int
        let maximumAttempts: Int
        let nextRetryDelay: Duration?
        let retryExhausted: Bool
        let topologyObserverState: TopologyObserverState
        let lastTopologySignal: TopologySignal?
        let lastRawCallbackTimestamp: Double?
        let lastRawCallbackGeneration: UInt?
        let lastAcceptedCallbackTimestamp: Double?
        let lastAcceptedCallbackGeneration: UInt?

        func formatted() -> String {
            [
                "state=\(state.rawValue)",
                "activeGeneration=\(String(describing: activeGeneration))",
                "registeredDevices=\(registeredDeviceCount)",
                "lastEnumeration=\(String(describing: lastEnumeration))",
                "lastRegister=\(String(describing: lastRegister))",
                "lastStart=\(String(describing: lastStart))",
                "lastRunningCheck=\(String(describing: lastRunningCheck))",
                "lastStop=\(String(describing: lastStop))",
                "lastUnregister=\(String(describing: lastUnregister))",
                "retryReasons=\(retryReasons.map(\.rawValue).joined(separator: ","))",
                "retryEpisode=\(retryEpisode)",
                "retryAttempt=\(retryAttempt)/\(maximumAttempts)",
                "nextRetryDelay=\(String(describing: nextRetryDelay))",
                "retryExhausted=\(retryExhausted)",
                "topologyObserver=\(String(describing: topologyObserverState))",
                "lastTopologySignal=\(String(describing: lastTopologySignal?.rawValue))",
                "lastRawCallbackTimestamp=\(String(describing: lastRawCallbackTimestamp))",
                "lastRawCallbackGeneration=\(String(describing: lastRawCallbackGeneration))",
                "lastAcceptedCallbackTimestamp=\(String(describing: lastAcceptedCallbackTimestamp))",
                "lastAcceptedCallbackGeneration=\(String(describing: lastAcceptedCallbackGeneration))"
            ].joined(separator: "\n")
        }
    }

    struct LifecycleOperations {
        let enumerate: () -> MultitouchBinding.Enumeration
        let register: (
            MultitouchBinding.DeviceRef,
            MultitouchBinding.ContactCallback,
            UnsafeMutableRawPointer
        ) -> Bool
        let start: (MultitouchBinding.DeviceRef) -> Int32
        let isRunning: (MultitouchBinding.DeviceRef) -> Bool
        let stop: (MultitouchBinding.DeviceRef) -> Int32
        let unregister: (MultitouchBinding.DeviceRef, MultitouchBinding.ContactCallback) -> Bool
        let sleep: @MainActor (Duration) async throws -> Void

        init(
            enumerate: @escaping () -> MultitouchBinding.Enumeration,
            register: @escaping (
                MultitouchBinding.DeviceRef,
                MultitouchBinding.ContactCallback,
                UnsafeMutableRawPointer
            ) -> Bool,
            start: @escaping (MultitouchBinding.DeviceRef) -> Int32,
            isRunning: @escaping (MultitouchBinding.DeviceRef) -> Bool,
            stop: @escaping (MultitouchBinding.DeviceRef) -> Int32,
            unregister: @escaping (MultitouchBinding.DeviceRef, MultitouchBinding.ContactCallback) -> Bool,
            sleep: @escaping @MainActor (Duration) async throws -> Void
        ) {
            self.enumerate = enumerate
            self.register = register
            self.start = start
            self.isRunning = isRunning
            self.stop = stop
            self.unregister = unregister
            self.sleep = sleep
        }

        init(binding: MultitouchBinding) {
            enumerate = { binding.enumerateDevices() }
            register = { binding.register($0, callback: $1, refcon: $2) }
            start = { binding.start($0) }
            isRunning = { binding.isRunning($0) }
            stop = { binding.stop($0) }
            unregister = { binding.unregister($0, callback: $1) }
            sleep = { try await Task.sleep(for: $0) }
        }
    }

    struct TopologyMonitoringOperations {
        typealias Notifications = AsyncThrowingStream<TopologySignal, any Error>

        let notifications: @MainActor () async -> Notifications
        let sleep: @MainActor (Duration) async throws -> Void
    }

    private struct Registration {
        let device: MultitouchBinding.Device
        var startAttempted: Bool
        var registered: Bool
    }

    private enum EpisodeReplacementState {
        case notRequested
        case pending
        case completed
    }

    nonisolated(unsafe) weak static var shared: MultitouchGestureSource?

    var onSnapshot: ((MouseEventHandler.GestureEventSnapshot) -> Void)?
    var onSourceWillReplace: (() -> Void)?

    private static var nextRegistrationGeneration: UInt = 0
    static let topologyCriteria = [
        HIDDeviceManager.DeviceMatchingCriteria(deviceUsages: [
            .digitizers(.touchPad),
            .digitizers(.multiplePointDigitizer)
        ])
    ]

    private let operations: LifecycleOperations?
    private let topologyMonitoringOperations: TopologyMonitoringOperations?
    private let coalescingDelay: Duration
    private let wakeSettlingDelay: Duration
    private let retryDelays: [Duration]

    private var registrations: [Registration] = []
    private var deviceList: CFArray?
    private var activeGeneration: UInt = 0
    private var previousActiveCount = 0
    private var topologyTask: Task<Void, Never>?
    private var revalidationTask: Task<Void, Never>?
    private var episodeActive = false
    private var episodeReasons: Set<RevalidationReason> = []
    private var episodeBaselineDeviceIds: Set<UInt64> = []
    private var retryEpisode: UInt64 = 0
    private var retryAttempt = 0
    private var nextRetryDelay: Duration?
    private var retryExhausted = false
    private var wakeSettlingArmed = false
    private var episodeReplacementState: EpisodeReplacementState = .notRequested
    private var revalidationSchedule: UInt64 = 0

    private var state: LifecycleState = .stopped
    private var topologyObserverState: TopologyObserverState = .stopped
    private var lastTopologySignal: TopologySignal?
    private var lastEnumeration: MultitouchBinding.EnumerationOutcome?
    private var lastRegister: OperationResult = .notAttempted
    private var lastStart: OperationResult = .notAttempted
    private var lastRunningCheck: OperationResult = .notAttempted
    private var lastStop: OperationResult = .notAttempted
    private var lastUnregister: OperationResult = .notAttempted
    private var lastRawCallbackTimestamp: Double?
    private var lastRawCallbackGeneration: UInt?
    private var lastAcceptedCallbackTimestamp: Double?
    private var lastAcceptedCallbackGeneration: UInt?

    init() {
        operations = MultitouchBinding().map(LifecycleOperations.init(binding:))
        topologyMonitoringOperations = Self.liveTopologyMonitoringOperations
        coalescingDelay = .milliseconds(100)
        wakeSettlingDelay = .seconds(1)
        retryDelays = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8)
        ]
    }

    init(
        operations: LifecycleOperations?,
        topologyMonitoringEnabled: Bool = false,
        topologyMonitoringOperations: TopologyMonitoringOperations? = nil,
        coalescingDelay: Duration = .milliseconds(100),
        wakeSettlingDelay: Duration = .seconds(1),
        retryDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8)
        ]
    ) {
        self.operations = operations
        self.topologyMonitoringOperations = topologyMonitoringEnabled
            ? topologyMonitoringOperations ?? Self.liveTopologyMonitoringOperations
            : nil
        self.coalescingDelay = coalescingDelay
        self.wakeSettlingDelay = wakeSettlingDelay
        self.retryDelays = retryDelays
    }

    deinit {
        topologyTask?.cancel()
        revalidationTask?.cancel()
    }

    @discardableResult
    func startLifecycle() -> Bool {
        guard state == .stopped else { return MultitouchGestureSource.shared === self }
        if let current = MultitouchGestureSource.shared, current !== self {
            guard current.shutdown() else { return false }
        }
        MultitouchGestureSource.shared = self
        guard operations != nil else {
            state = .unavailable
            return true
        }
        state = .waiting
        startTopologyMonitoring()
        requestRevalidation(.startup)
        return true
    }

    func suspendForSleep() {
        guard state != .stopped else { return }
        cancelRevalidation()
        invalidateActiveGeneration()
        _ = teardownRegistrations(resetGestureState: true)
        state = .suspended
    }

    func requestRevalidation(_ reason: RevalidationReason) {
        guard operations != nil, state != .stopped, state != .unavailable else { return }
        if state == .suspended, reason != .wake, reason != .unlock {
            return
        }
        if topologyObserverState == .exhausted,
           reason == .startup || reason == .wake || reason == .unlock
        {
            startTopologyMonitoring()
        }
        if !episodeActive {
            episodeActive = true
            episodeReasons.removeAll(keepingCapacity: true)
            episodeBaselineDeviceIds = Set(registrations.map(\.device.registryId))
            retryEpisode &+= 1
            retryAttempt = 0
            retryExhausted = false
            episodeReplacementState = .notRequested
        }
        let introducedWakeSettling = (reason == .wake || reason == .unlock)
            && !episodeReasons.contains(.wake)
            && !episodeReasons.contains(.unlock)
        episodeReasons.insert(reason)
        let requestsReplacement = reason == .wake || reason == .unlock || reason == .arrival || reason == .removal
        if requestsReplacement, episodeReplacementState == .notRequested {
            episodeReplacementState = .pending
        }
        if introducedWakeSettling, retryAttempt == 0, revalidationTask != nil, !wakeSettlingArmed {
            revalidationTask?.cancel()
            revalidationTask = nil
            scheduleRevalidation(after: wakeSettlingDelay, settlesWake: true)
            return
        }
        let isTopologySignal = reason == .arrival || reason == .removal
        if isTopologySignal,
           revalidationTask != nil,
           !wakeSettlingArmed,
           let nextRetryDelay,
           nextRetryDelay > coalescingDelay
        {
            revalidationTask?.cancel()
            revalidationTask = nil
            scheduleRevalidation(after: coalescingDelay)
            return
        }
        guard revalidationTask == nil else { return }
        let needsWakeSettling = episodeReasons.contains(.wake) || episodeReasons.contains(.unlock)
        scheduleRevalidation(
            after: needsWakeSettling ? wakeSettlingDelay : coalescingDelay,
            settlesWake: needsWakeSettling
        )
    }

    @discardableResult
    func shutdown() -> Bool {
        revalidationTask?.cancel()
        revalidationTask = nil
        revalidationSchedule &+= 1
        topologyTask?.cancel()
        topologyTask = nil
        episodeActive = false
        episodeReasons.removeAll(keepingCapacity: false)
        episodeBaselineDeviceIds.removeAll(keepingCapacity: false)
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
        invalidateActiveGeneration()
        let cleanedUp = teardownRegistrations(resetGestureState: true)
        topologyObserverState = .stopped
        state = .stopped
        if cleanedUp, MultitouchGestureSource.shared === self {
            MultitouchGestureSource.shared = nil
        }
        return cleanedUp
    }

    func start() {
        startLifecycle()
    }

    func stop() {
        shutdown()
    }

    func restart() {
        if state == .stopped {
            startLifecycle()
        } else {
            requestRevalidation(.wake)
        }
    }

    func receiveTopologySignal(_ signal: TopologySignal) {
        lastTopologySignal = signal
        requestRevalidation(signal == .arrival ? .arrival : .removal)
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            state: state,
            activeGeneration: activeGeneration == 0 ? nil : activeGeneration,
            registeredDeviceCount: registrations.filter(\.registered).count,
            lastEnumeration: lastEnumeration,
            lastRegister: lastRegister,
            lastStart: lastStart,
            lastRunningCheck: lastRunningCheck,
            lastStop: lastStop,
            lastUnregister: lastUnregister,
            retryReasons: episodeReasons.sorted { $0.rawValue < $1.rawValue },
            retryEpisode: retryEpisode,
            retryAttempt: retryAttempt,
            maximumAttempts: retryDelays.count + 1,
            nextRetryDelay: nextRetryDelay,
            retryExhausted: retryExhausted,
            topologyObserverState: topologyObserverState,
            lastTopologySignal: lastTopologySignal,
            lastRawCallbackTimestamp: lastRawCallbackTimestamp,
            lastRawCallbackGeneration: lastRawCallbackGeneration,
            lastAcceptedCallbackTimestamp: lastAcceptedCallbackTimestamp,
            lastAcceptedCallbackGeneration: lastAcceptedCallbackGeneration
        )
    }

    func handleRawFrame(
        _ frame: RawFrame,
        generation: UInt
    ) {
        guard recordAndAccept(frame, generation: generation) else { return }
        emitSnapshot(frame, location: NSEvent.mouseLocation)
    }

    func handleRawFrame(
        _ frame: RawFrame,
        generation: UInt,
        location: CGPoint
    ) {
        guard recordAndAccept(frame, generation: generation) else { return }
        emitSnapshot(frame, location: location)
    }

    private func recordAndAccept(_ frame: RawFrame, generation: UInt) -> Bool {
        lastRawCallbackTimestamp = frame.timestamp
        lastRawCallbackGeneration = generation
        guard state == .running, generation != 0, generation == activeGeneration else { return false }
        lastAcceptedCallbackTimestamp = frame.timestamp
        lastAcceptedCallbackGeneration = generation
        return true
    }

    private func emitSnapshot(_ frame: RawFrame, location: CGPoint) {
        let result = MultitouchGestureSource.makeSnapshot(
            frame: frame,
            location: location,
            previousActiveCount: previousActiveCount
        )
        previousActiveCount = result.activeCount
        if let snapshot = result.snapshot {
            onSnapshot?(snapshot)
        }
    }

    static func makeSnapshot(
        frame: RawFrame,
        location: CGPoint,
        previousActiveCount: Int
    ) -> (snapshot: MouseEventHandler.GestureEventSnapshot?, activeCount: Int) {
        let activeCount = frame.touches.count
        if activeCount == 0 {
            guard previousActiveCount > 0 else { return (nil, 0) }
            let snapshot = MouseEventHandler.GestureEventSnapshot(
                location: location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: frame.timestamp,
                touches: []
            )
            return (snapshot, 0)
        }

        let phase: NSEvent.Phase = previousActiveCount == 0 ? .began : .changed
        let touches = frame.touches.map { touch in
            MouseEventHandler.GestureTouchSample(
                phase: .moved,
                normalizedPosition: normalizedPosition(x: touch.x, y: touch.y)
            )
        }
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: frame.timestamp,
            touches: touches
        )
        return (snapshot, activeCount)
    }

    private func scheduleRevalidation(after delay: Duration, settlesWake: Bool = false) {
        guard episodeActive, revalidationTask == nil, let operations else { return }
        nextRetryDelay = delay
        wakeSettlingArmed = settlesWake
        if activeGeneration == 0 {
            state = retryAttempt == 0 ? .waiting : .retrying
        }
        let episode = retryEpisode
        revalidationSchedule &+= 1
        let schedule = revalidationSchedule
        revalidationTask = Task { @MainActor [weak self] in
            do {
                try await operations.sleep(delay)
            } catch {
                guard let self, revalidationSchedule == schedule else { return }
                revalidationTask = nil
                nextRetryDelay = nil
                wakeSettlingArmed = false
                if !Task.isCancelled {
                    episodeActive = false
                    retryExhausted = true
                    episodeReplacementState = .notRequested
                    state = activeGeneration == 0 ? .exhausted : .running
                }
                return
            }
            guard !Task.isCancelled,
                  let self,
                  episodeActive,
                  retryEpisode == episode,
                  revalidationSchedule == schedule
            else { return }
            revalidationTask = nil
            nextRetryDelay = nil
            wakeSettlingArmed = false
            retryAttempt += 1
            if activeGeneration == 0 {
                state = .enumerating
            }
            if revalidate() {
                finishRevalidation()
                return
            }
            guard retryAttempt <= retryDelays.count else {
                episodeActive = false
                wakeSettlingArmed = false
                retryExhausted = true
                episodeReplacementState = .notRequested
                state = activeGeneration == 0 ? .exhausted : .running
                return
            }
            scheduleRevalidation(after: retryDelays[retryAttempt - 1])
        }
    }

    private func revalidate() -> Bool {
        guard let operations else { return false }
        if activeGeneration == 0, !registrations.isEmpty {
            guard teardownRegistrations(resetGestureState: false) else { return false }
        }

        let enumeration = operations.enumerate()
        lastEnumeration = enumeration.outcome
        guard case .success = enumeration.outcome, !enumeration.devices.isEmpty else {
            invalidateActiveGeneration()
            _ = teardownRegistrations(resetGestureState: true)
            return false
        }

        let discoveredIds = Set(enumeration.devices.map(\.registryId))
        let registeredIds = Set(registrations.map(\.device.registryId))
        let forceReplacement = episodeReplacementState == .pending
        let awaitingTopologyChange = episodeReasons.contains(.arrival) || episodeReasons.contains(.removal)
        let topologyConverged = !awaitingTopologyChange || discoveredIds != episodeBaselineDeviceIds
        if activeGeneration != 0, discoveredIds == registeredIds, !forceReplacement {
            let allRunning = registrations.allSatisfy { operations.isRunning($0.device.ref) }
            lastRunningCheck = allRunning ? .success : .rejected
            if allRunning {
                state = .running
                return topologyConverged
            }
        }

        invalidateActiveGeneration()
        guard teardownRegistrations(resetGestureState: true) else { return false }
        guard register(enumeration: enumeration) else { return false }
        return topologyConverged
    }

    private func register(enumeration: MultitouchBinding.Enumeration) -> Bool {
        guard let operations else { return false }
        let generation = Self.allocateRegistrationGeneration()
        guard let refcon = UnsafeMutableRawPointer(bitPattern: generation) else {
            lastRegister = .rejected
            return false
        }

        var candidates: [Registration] = []
        candidates.reserveCapacity(enumeration.devices.count)
        for device in enumeration.devices {
            let registered = operations.register(device.ref, Self.contactCallback, refcon)
            lastRegister = registered ? .success : .rejected
            guard registered else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
            candidates.append(Registration(device: device, startAttempted: false, registered: true))

            candidates[candidates.count - 1].startAttempted = true
            let startStatus = operations.start(device.ref)
            lastStart = startStatus == KERN_SUCCESS ? .success : .status(startStatus)
            guard startStatus == KERN_SUCCESS else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
            let running = operations.isRunning(device.ref)
            lastRunningCheck = running ? .success : .rejected
            guard running else {
                _ = cleanup(&candidates)
                retainIncompleteCleanup(candidates, list: enumeration.list)
                return false
            }
        }

        registrations = candidates
        deviceList = enumeration.list
        activeGeneration = generation
        if episodeReplacementState == .pending {
            episodeReplacementState = .completed
        }
        state = .running
        return true
    }

    private func retainIncompleteCleanup(_ candidates: [Registration], list: CFArray?) {
        let incomplete = candidates.filter { $0.startAttempted || $0.registered }
        guard !incomplete.isEmpty else { return }
        registrations = incomplete
        deviceList = list
    }

    private func teardownRegistrations(resetGestureState: Bool) -> Bool {
        if resetGestureState, !registrations.isEmpty || previousActiveCount > 0 {
            onSourceWillReplace?()
            previousActiveCount = 0
        }
        let succeeded = cleanup(&registrations)
        guard succeeded else { return false }
        registrations.removeAll(keepingCapacity: false)
        deviceList = nil
        return true
    }

    private func cleanup(_ registrations: inout [Registration]) -> Bool {
        guard let operations else { return registrations.isEmpty }
        var succeeded = true
        var stopResult: OperationResult = .notAttempted
        var stopFailure: OperationResult?
        var unregisterResult: OperationResult = .notAttempted
        for index in registrations.indices where registrations[index].startAttempted {
            let status = operations.stop(registrations[index].device.ref)
            let stopped = status == KERN_SUCCESS || status == kIOReturnNotOpen
            let result: OperationResult = if status == KERN_SUCCESS {
                .success
            } else if status == kIOReturnNotOpen {
                .alreadyStopped(status)
            } else {
                .status(status)
            }
            if stopResult == .notAttempted {
                stopResult = result
            } else if stopResult == .success, result != .success {
                stopResult = result
            }
            if stopped {
                registrations[index].startAttempted = false
            } else {
                succeeded = false
                if stopFailure == nil {
                    stopFailure = result
                }
            }
        }
        for index in registrations.indices where registrations[index].registered {
            let unregistered = operations.unregister(registrations[index].device.ref, Self.contactCallback)
            let result: OperationResult = unregistered ? .success : .alreadyUnregistered
            if unregisterResult == .notAttempted {
                unregisterResult = result
            } else if unregisterResult == .success, result != .success {
                unregisterResult = result
            }
            registrations[index].registered = false
        }
        lastStop = stopFailure ?? stopResult
        lastUnregister = unregisterResult
        return succeeded
    }

    private func invalidateActiveGeneration() {
        activeGeneration = 0
    }

    private func finishRevalidation() {
        episodeActive = false
        retryAttempt = 0
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
    }

    private func cancelRevalidation() {
        revalidationTask?.cancel()
        revalidationTask = nil
        revalidationSchedule &+= 1
        episodeActive = false
        episodeReasons.removeAll(keepingCapacity: true)
        episodeBaselineDeviceIds.removeAll(keepingCapacity: true)
        retryAttempt = 0
        nextRetryDelay = nil
        retryExhausted = false
        wakeSettlingArmed = false
        episodeReplacementState = .notRequested
    }

    private static var liveTopologyMonitoringOperations: TopologyMonitoringOperations {
        let manager = HIDDeviceManager()
        return TopologyMonitoringOperations(
            notifications: {
                let notifications = await manager.monitorNotifications(matchingCriteria: topologyCriteria)
                return topologySignals(from: notifications)
            },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    private static func topologySignals(
        from notifications: AsyncThrowingStream<HIDDeviceManager.Notification, any Error>
    ) -> TopologyMonitoringOperations.Notifications {
        TopologyMonitoringOperations.Notifications { continuation in
            let task = Task {
                do {
                    for try await notification in notifications {
                        switch notification {
                        case .deviceMatched:
                            continuation.yield(.arrival)
                        case .deviceRemoved:
                            continuation.yield(.removal)
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startTopologyMonitoring() {
        guard let topologyMonitoringOperations, topologyTask == nil else { return }
        let observerRetryDelays = retryDelays
        topologyObserverState = .monitoring
        topologyTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let notifications = await topologyMonitoringOperations.notifications()
                    for try await signal in notifications {
                        guard !Task.isCancelled, let self else { return }
                        failures = 0
                        topologyObserverState = .monitoring
                        receiveTopologySignal(signal)
                    }
                    guard !Task.isCancelled else { return }
                } catch {
                    guard !Task.isCancelled else { return }
                }

                failures += 1
                let retryDelay: Duration
                do {
                    guard let self else { return }
                    self.requestRevalidation(.observerRecovery)
                    guard failures <= observerRetryDelays.count else {
                        self.topologyObserverState = .exhausted
                        self.topologyTask = nil
                        return
                    }
                    self.topologyObserverState = .retrying(failures)
                    retryDelay = observerRetryDelays[failures - 1]
                }
                do {
                    try await topologyMonitoringOperations.sleep(retryDelay)
                } catch {
                    return
                }
            }
        }
    }

    private static func allocateRegistrationGeneration() -> UInt {
        repeat {
            nextRegistrationGeneration &+= 1
        } while nextRegistrationGeneration == 0
        return nextRegistrationGeneration
    }

    private static func normalizedPosition(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static let contactCallback: MultitouchBinding.ContactCallback = { _, fingers, count, timestamp, _, refcon in
        let generation = refcon.map(UInt.init(bitPattern:)) ?? 0
        let frame = MultitouchGestureSource.buildRawFrame(fingers: fingers, count: count, timestamp: timestamp)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MultitouchGestureSource.shared?.handleRawFrame(frame, generation: generation)
            }
        }
        return 0
    }

    private nonisolated static func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double
    ) -> RawFrame {
        guard let fingers, count > 0 else { return RawFrame(touches: [], timestamp: timestamp) }
        var touches = RawTouchBuffer()
        for index in 0 ..< Int(count) {
            let base = index * multitouchTouchStride
            let state = fingers.load(fromByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            guard state == multitouchTouchingState else { continue }
            let x = fingers.load(fromByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            let y = fingers.load(fromByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            touches.append(RawTouch(x: x, y: y))
        }
        return RawFrame(touches: touches, timestamp: timestamp)
    }
}
