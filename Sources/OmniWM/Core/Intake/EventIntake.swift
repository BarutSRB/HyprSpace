// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import os

enum IntakeEvent: Sendable {
    case activationFactsResolved(ActivationFacts)
    case focusedAdmissionRetryFactRequestSuperseded(FocusedAdmissionRetryExecution)
    case activeSpaceChanged
    case appActivated(pid: pid_t)
    case appDeactivated(pid: pid_t)
    case appHidden(pid: pid_t)
    case appLaunched(pid: pid_t)
    case appTerminated(pid: pid_t, frontmostPID: pid_t?)
    case appUnhidden(pid: pid_t)
    case axFocusedWindowChanged(pid: pid_t, callbackGeneration: UInt64?)
    case axWindowDestroyed(pid: pid_t, axRef: AXWindowRef, callbackGeneration: UInt64?)
    case axWindowMiniaturized(pid: pid_t, windowId: Int, callbackGeneration: UInt64?)
    case cgs(CGSWindowEvent)
    case display(DisplayConfigurationObserver.DisplayEvent)
    case hotkeyInvocation(HotkeyInvocation)
    case intentExpired(intentId: IntentID)
    case ipcCommand(IPCCommandIntake)
    case mouseDragged(button: MouseEventHandler.MouseButton, location: CGPoint)
    case mouseMoved(location: CGPoint, modifiersRawValue: UInt64, windowIdUnderPointer: Int?)
    case mouseScroll(MouseScrollIntake)
    case nativeFullscreenTransitionExpired(originalToken: WindowToken, generation: Int)
    case systemSleep
    case systemWake
    case windowConstraintsResolved(WindowConstraintsFact)
}

struct IPCCommandIntake: Sendable {
    let perform: @MainActor @Sendable (WMController) -> ExternalCommandResult
    let completion: @MainActor @Sendable (ExternalCommandResult) -> Void
}

struct MouseScrollIntake: Sendable {
    var location: CGPoint
    var deltaX: CGFloat
    var deltaY: CGFloat
    let momentumPhase: UInt32
    let phase: UInt32
    let modifiersRawValue: UInt64

    private static let axisEpsilon: CGFloat = 0.001

    var modifiers: CGEventFlags {
        CGEventFlags(rawValue: modifiersRawValue)
    }

    func matches(_ other: MouseScrollIntake) -> Bool {
        modifiersRawValue == other.modifiersRawValue
            && momentumPhase == other.momentumPhase
            && phase == other.phase
    }

    func canCoalesce(_ other: MouseScrollIntake) -> Bool {
        axisSignature == other.axisSignature
    }

    mutating func accumulate(_ other: MouseScrollIntake) {
        deltaX += other.deltaX
        deltaY += other.deltaY
        location = other.location
    }

    private var axisSignature: (Int, Int) {
        (Self.signedAxis(deltaX), Self.signedAxis(deltaY))
    }

    private static func signedAxis(_ delta: CGFloat) -> Int {
        guard abs(delta) > axisEpsilon else { return 0 }
        return delta > 0 ? 1 : -1
    }
}

struct StampedIntakeEvent: Sendable {
    let seq: UInt64
    let event: IntakeEvent
}

@MainActor
protocol EventIntakeSink: AnyObject {
    func handleIntakeEvent(_ stamped: StampedIntakeEvent)
}

@MainActor
final class EventIntake {
    struct EventCategoryPerformanceSnapshot: Equatable, Sendable {
        let acceptedEvents: UInt64
        let coalescedEvents: UInt64
        let deliveredEvents: UInt64
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let acceptedEvents: UInt64
        let coalescedEvents: UInt64
        let deliveredEvents: UInt64
        let drainBatches: UInt64
        let currentQueueDepth: Int
        let maximumQueueDepth: Int
        let maximumBatchSize: Int
        let cgsCreatedEvents: EventCategoryPerformanceSnapshot
        let cgsDestroyedEvents: EventCategoryPerformanceSnapshot
        let cgsFrameChangedEvents: EventCategoryPerformanceSnapshot
        let cgsTitleChangedEvents: EventCategoryPerformanceSnapshot
        let axLifecycleEvents: EventCategoryPerformanceSnapshot
        let axFocusedWindowChangedEvents: EventCategoryPerformanceSnapshot
    }

    private struct EventCategoryPerformanceCounters {
        var acceptedEvents: UInt64 = 0
        var coalescedEvents: UInt64 = 0
        var deliveredEvents: UInt64 = 0

        var snapshot: EventCategoryPerformanceSnapshot {
            EventCategoryPerformanceSnapshot(
                acceptedEvents: acceptedEvents,
                coalescedEvents: coalescedEvents,
                deliveredEvents: deliveredEvents
            )
        }
    }

    private struct PerformanceCounters {
        var acceptedEvents: UInt64 = 0
        var coalescedEvents: UInt64 = 0
        var deliveredEvents: UInt64 = 0
        var drainBatches: UInt64 = 0
        var maximumQueueDepth = 0
        var maximumBatchSize = 0
        var cgsCreatedEvents = EventCategoryPerformanceCounters()
        var cgsDestroyedEvents = EventCategoryPerformanceCounters()
        var cgsFrameChangedEvents = EventCategoryPerformanceCounters()
        var cgsTitleChangedEvents = EventCategoryPerformanceCounters()
        var axLifecycleEvents = EventCategoryPerformanceCounters()
        var axFocusedWindowChangedEvents = EventCategoryPerformanceCounters()

        func snapshot(currentQueueDepth: Int) -> PerformanceSnapshot {
            PerformanceSnapshot(
                acceptedEvents: acceptedEvents,
                coalescedEvents: coalescedEvents,
                deliveredEvents: deliveredEvents,
                drainBatches: drainBatches,
                currentQueueDepth: currentQueueDepth,
                maximumQueueDepth: maximumQueueDepth,
                maximumBatchSize: maximumBatchSize,
                cgsCreatedEvents: cgsCreatedEvents.snapshot,
                cgsDestroyedEvents: cgsDestroyedEvents.snapshot,
                cgsFrameChangedEvents: cgsFrameChangedEvents.snapshot,
                cgsTitleChangedEvents: cgsTitleChangedEvents.snapshot,
                axLifecycleEvents: axLifecycleEvents.snapshot,
                axFocusedWindowChangedEvents: axFocusedWindowChangedEvents.snapshot
            )
        }

        mutating func recordAccepted(
            _ event: IntakeEvent,
            coalesced: Bool,
            queueDepth: Int
        ) {
            acceptedEvents &+= 1
            if coalesced {
                coalescedEvents &+= 1
            }
            maximumQueueDepth = max(maximumQueueDepth, queueDepth)
            guard let keyPath = EventIntake.performanceCategoryKeyPath(for: event) else { return }
            self[keyPath: keyPath].acceptedEvents &+= 1
            if coalesced {
                self[keyPath: keyPath].coalescedEvents &+= 1
            }
        }

        mutating func recordDelivered(_ event: IntakeEvent) {
            guard let keyPath = EventIntake.performanceCategoryKeyPath(for: event) else { return }
            self[keyPath: keyPath].deliveredEvents &+= 1
        }

        mutating func recordDrain(_ events: [StampedIntakeEvent]) {
            guard !events.isEmpty else { return }
            drainBatches &+= 1
            deliveredEvents &+= UInt64(events.count)
            maximumBatchSize = max(maximumBatchSize, events.count)
            for stamped in events {
                recordDelivered(stamped.event)
            }
        }
    }

    private struct Buffer {
        var isOpen = false
        var drainScheduled = false
        var nextSeq: UInt64 = 1
        var orderedEvents: [StampedIntakeEvent] = []
        var spareOrderedEvents: [StampedIntakeEvent] = []
        var pendingCGSFrameWindowIds: Set<UInt32> = []
        var openMouseMovedSeq: UInt64?
        var openLeftDraggedSeq: UInt64?
        var openRightDraggedSeq: UInt64?
        var openScrollSeq: UInt64?
        var performanceCounters: PerformanceCounters?

        mutating func closeMouseCoalescingWindows() {
            openMouseMovedSeq = nil
            openLeftDraggedSeq = nil
            openRightDraggedSeq = nil
            openScrollSeq = nil
        }

        mutating func closeMouseCoalescingWindows(keeping kept: WritableKeyPath<Buffer, UInt64?>) {
            let keptSeq = self[keyPath: kept]
            closeMouseCoalescingWindows()
            self[keyPath: kept] = keptSeq
        }
    }

    private nonisolated let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private weak var sink: EventIntakeSink?

    nonisolated var lastSeq: UInt64 {
        buffer.withLock { $0.nextSeq - 1 }
    }

    nonisolated var hasPendingEvents: Bool {
        buffer.withLock { !$0.orderedEvents.isEmpty }
    }

    nonisolated func beginPerformanceCapture() {
        buffer.withLock { state in
            state.performanceCounters = PerformanceCounters(
                maximumQueueDepth: state.orderedEvents.count
            )
        }
    }

    nonisolated func performanceSnapshot() -> PerformanceSnapshot? {
        buffer.withLock { state in
            state.performanceCounters?.snapshot(currentQueueDepth: state.orderedEvents.count)
        }
    }

    nonisolated func endPerformanceCapture() -> PerformanceSnapshot? {
        buffer.withLock { state in
            let snapshot = state.performanceCounters?.snapshot(
                currentQueueDepth: state.orderedEvents.count
            )
            state.performanceCounters = nil
            return snapshot
        }
    }

    @discardableResult
    nonisolated static func post(_ event: IntakeEvent) -> Bool {
        activeIntake.withLock { $0 }?.enqueue(event) ?? false
    }

    nonisolated static func currentSeq() -> UInt64 {
        activeIntake.withLock { $0 }?.lastSeq ?? 0
    }

    func open(sink: EventIntakeSink) {
        self.sink = sink
        buffer.withLock { $0.isOpen = true }
        activeIntake.withLock { $0 = self }
    }

    func close() {
        activeIntake.withLock { active in
            if active === self {
                active = nil
            }
        }
        let dropped = buffer.withLock { state -> [StampedIntakeEvent] in
            var dropped: [StampedIntakeEvent] = []
            swap(&dropped, &state.orderedEvents)
            state.isOpen = false
            state.drainScheduled = false
            state.orderedEvents.removeAll(keepingCapacity: false)
            state.spareOrderedEvents.removeAll(keepingCapacity: false)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: false)
            state.closeMouseCoalescingWindows()
            return dropped
        }
        sink = nil
        completeDroppedCommands(dropped)
    }

    @discardableResult
    nonisolated func enqueue(_ event: IntakeEvent) -> Bool {
        let (didEnqueue, shouldScheduleDrain) = buffer.withLock { state -> (Bool, Bool) in
            guard state.isOpen else { return (false, false) }
            if state.performanceCounters == nil {
                stampAndCoalesce(event, into: &state)
            } else {
                let sequenceBefore = state.nextSeq
                stampAndCoalesce(event, into: &state)
                let wasCoalesced = state.nextSeq == sequenceBefore
                let queueDepth = state.orderedEvents.count
                state.performanceCounters?.recordAccepted(
                    event,
                    coalesced: wasCoalesced,
                    queueDepth: queueDepth
                )
            }
            guard !state.drainScheduled else { return (true, false) }
            state.drainScheduled = true
            return (true, true)
        }
        if shouldScheduleDrain {
            scheduleDrain()
        }
        return didEnqueue
    }

    func drainNow() {
        drainPendingEventsOnMainRunLoop()
    }

    private func completeDroppedCommands(_ dropped: [StampedIntakeEvent]) {
        for stamped in dropped {
            if case let .ipcCommand(intake) = stamped.event {
                intake.completion(.ignoredDisabled)
            }
        }
    }

    private nonisolated func stampAndCoalesce(_ event: IntakeEvent, into state: inout Buffer) {
        switch event {
        case let .cgs(.frameChanged(windowId)):
            state.closeMouseCoalescingWindows()
            guard state.pendingCGSFrameWindowIds.insert(windowId).inserted else { return }

        case let .cgs(.closed(windowId)),
             let .cgs(.destroyed(windowId, _)):
            removePendingCGSFrameEvents(windowId: windowId, state: &state)
            state.closeMouseCoalescingWindows()

        case let .mouseDragged(button, _):
            switch button {
            case .left:
                state.closeMouseCoalescingWindows(keeping: \.openLeftDraggedSeq)
                if let openSeq = state.openLeftDraggedSeq,
                   updatePendingEvent(seq: openSeq, in: &state, to: event)
                {
                    return
                }
                state.openLeftDraggedSeq = state.nextSeq
            case .right:
                state.closeMouseCoalescingWindows(keeping: \.openRightDraggedSeq)
                if let openSeq = state.openRightDraggedSeq,
                   updatePendingEvent(seq: openSeq, in: &state, to: event)
                {
                    return
                }
                state.openRightDraggedSeq = state.nextSeq
            }

        case let .mouseMoved(location, modifiersRawValue, windowIdUnderPointer):
            state.closeMouseCoalescingWindows(keeping: \.openMouseMovedSeq)
            if let openSeq = state.openMouseMovedSeq,
               updatePendingEvent(
                   seq: openSeq,
                   in: &state,
                   to: .mouseMoved(
                       location: location,
                       modifiersRawValue: modifiersRawValue,
                       windowIdUnderPointer: windowIdUnderPointer
                   )
               )
            {
                return
            }
            state.openMouseMovedSeq = state.nextSeq

        case let .mouseScroll(payload):
            state.closeMouseCoalescingWindows(keeping: \.openScrollSeq)
            if let openSeq = state.openScrollSeq,
               let index = state.orderedEvents.lastIndex(where: { $0.seq == openSeq }),
               case let .mouseScroll(existing) = state.orderedEvents[index].event
            {
                if existing.matches(payload), existing.canCoalesce(payload) {
                    var merged = existing
                    merged.accumulate(payload)
                    state.orderedEvents[index] = StampedIntakeEvent(seq: openSeq, event: .mouseScroll(merged))
                    return
                }
                state.closeMouseCoalescingWindows()
            }
            state.openScrollSeq = state.nextSeq

        default:
            state.closeMouseCoalescingWindows()
        }

        state.orderedEvents.append(StampedIntakeEvent(seq: state.nextSeq, event: event))
        state.nextSeq += 1
    }

    private nonisolated func updatePendingEvent(
        seq: UInt64,
        in state: inout Buffer,
        to event: IntakeEvent
    ) -> Bool {
        guard let index = state.orderedEvents.lastIndex(where: { $0.seq == seq }) else { return false }
        state.orderedEvents[index] = StampedIntakeEvent(seq: seq, event: event)
        return true
    }

    nonisolated func removePendingMouseEvents() {
        buffer.withLock { state in
            state.closeMouseCoalescingWindows()
            state.orderedEvents.removeAll { stamped in
                switch stamped.event {
                case .mouseDragged,
                     .mouseMoved,
                     .mouseScroll:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private nonisolated func removePendingCGSFrameEvents(windowId: UInt32, state: inout Buffer) {
        guard state.pendingCGSFrameWindowIds.remove(windowId) != nil else { return }
        state.orderedEvents.removeAll { stamped in
            if case let .cgs(.frameChanged(pendingWindowId)) = stamped.event {
                return pendingWindowId == windowId
            }
            return false
        }
    }

    private nonisolated func scheduleDrain() {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.drainPendingEventsOnMainRunLoop()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func drainPendingEventsOnMainRunLoop() {
        var events = buffer.withLock { state -> [StampedIntakeEvent] in
            var events: [StampedIntakeEvent] = []
            swap(&events, &state.spareOrderedEvents)
            events.removeAll(keepingCapacity: true)
            swap(&events, &state.orderedEvents)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: true)
            state.closeMouseCoalescingWindows()
            state.drainScheduled = false
            state.performanceCounters?.recordDrain(events)
            return events
        }
        defer {
            events.removeAll(keepingCapacity: true)
            recycleDrainedEvents(events)
        }
        guard let sink else { return }
        for stamped in events {
            sink.handleIntakeEvent(stamped)
        }
    }

    private nonisolated func recycleDrainedEvents(_ events: [StampedIntakeEvent]) {
        buffer.withLock { state in
            guard state.isOpen,
                  events.capacity > state.spareOrderedEvents.capacity
            else { return }
            state.spareOrderedEvents = events
        }
    }

    private nonisolated static func performanceCategoryKeyPath(
        for event: IntakeEvent
    ) -> WritableKeyPath<PerformanceCounters, EventCategoryPerformanceCounters>? {
        switch event {
        case .cgs(.created):
            \.cgsCreatedEvents
        case .cgs(.destroyed),
             .cgs(.closed):
            \.cgsDestroyedEvents
        case .cgs(.frameChanged):
            \.cgsFrameChangedEvents
        case .cgs(.titleChanged):
            \.cgsTitleChangedEvents
        case .axWindowDestroyed,
             .axWindowMiniaturized:
            \.axLifecycleEvents
        case .axFocusedWindowChanged:
            \.axFocusedWindowChangedEvents
        default:
            nil
        }
    }
}

private let activeIntake = OSAllocatedUnfairLock<EventIntake?>(initialState: nil)
