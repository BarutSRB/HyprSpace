// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

final class EventIntakeReplayTests: XCTestCase {
    @MainActor
    private final class RecordingSink: EventIntakeSink {
        var received: [StampedIntakeEvent] = []

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            received.append(stamped)
        }
    }

    @MainActor
    private final class ReentrantSink: EventIntakeSink {
        let intake: EventIntake
        var received: [StampedIntakeEvent] = []
        var didReenter = false

        init(intake: EventIntake) {
            self.intake = intake
        }

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            received.append(stamped)
            guard !didReenter else { return }
            didReenter = true
            intake.enqueue(.appHidden(pid: 3))
        }
    }

    @MainActor
    private final class ClosingSink: EventIntakeSink {
        let intake: EventIntake
        var received: [StampedIntakeEvent] = []
        var didClose = false

        init(intake: EventIntake) {
            self.intake = intake
        }

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            received.append(stamped)
            guard !didClose else { return }
            didClose = true
            intake.close()
        }
    }

    @MainActor
    func testIntakeStampsMonotonicallyAndPreservesOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.appActivated(pid: 1))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.appDeactivated(pid: 1))
        intake.drainNow()
        intake.enqueue(.appHidden(pid: 1))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 4)
        let seqs = sink.received.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
        guard case .appActivated = sink.received[0].event,
              case .cgs(.frameChanged) = sink.received[1].event,
              case .appDeactivated = sink.received[2].event,
              case .appHidden = sink.received[3].event
        else {
            return XCTFail("Events drained out of order: \(sink.received)")
        }
    }

    @MainActor
    func testReentrantEnqueuePreservesBothBatches() {
        let intake = EventIntake()
        let sink = ReentrantSink(intake: intake)
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.appActivated(pid: 1))
        intake.enqueue(.appDeactivated(pid: 2))
        intake.drainNow()
        intake.drainNow()

        XCTAssertEqual(sink.received.map(\.seq), [1, 2, 3])
        guard case .appActivated = sink.received[0].event,
              case .appDeactivated = sink.received[1].event,
              case .appHidden = sink.received[2].event
        else {
            return XCTFail("Reentrant enqueue lost or reordered a batch: \(sink.received)")
        }
    }

    @MainActor
    func testCloseDuringDrainFinishesDetachedBatchAndRejectsNewEvents() {
        let intake = EventIntake()
        let sink = ClosingSink(intake: intake)
        intake.open(sink: sink)

        intake.enqueue(.appActivated(pid: 1))
        intake.enqueue(.appDeactivated(pid: 2))
        intake.drainNow()

        XCTAssertEqual(sink.received.map(\.seq), [1, 2])
        XCTAssertFalse(intake.enqueue(.appHidden(pid: 3)))
        XCTAssertFalse(intake.hasPendingEvents)
    }

    @MainActor
    func testWindowConstraintsResolvedDrainsInOrderWithoutCoalescing() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        let fact = WindowConstraintsFact(
            token: WindowToken(pid: 42, windowId: 7),
            constraints: .fixed(size: CGSize(width: 320, height: 240))
        )
        intake.enqueue(.appActivated(pid: 42))
        intake.enqueue(.windowConstraintsResolved(fact))
        intake.enqueue(.windowConstraintsResolved(fact))
        intake.drainNow()

        let resolvedTokens = sink.received.compactMap { stamped -> WindowToken? in
            if case let .windowConstraintsResolved(resolved) = stamped.event {
                return resolved.token
            }
            return nil
        }
        XCTAssertEqual(resolvedTokens, [fact.token, fact.token])
        XCTAssertEqual(sink.received.count, 3)
    }

    @MainActor
    func testCGSFrameEventsCoalescePerWindowAndClearOnDestroy() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.cgs(.frameChanged(windowId: 8)))
        intake.enqueue(.cgs(.destroyed(windowId: 7, spaceId: 1)))
        intake.drainNow()

        let frames = sink.received.compactMap { stamped -> UInt32? in
            if case let .cgs(.frameChanged(windowId)) = stamped.event {
                return windowId
            }
            return nil
        }
        XCTAssertEqual(frames, [8])
        XCTAssertEqual(sink.received.count, 2)
    }

    @MainActor
    func testCGSFrameBurstForLiveWindowDeliversOnce() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        for _ in 0 ..< 32 {
            intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        }
        intake.drainNow()

        let frameWindowIds = sink.received.compactMap { stamped -> UInt32? in
            if case let .cgs(.frameChanged(windowId)) = stamped.event {
                return windowId
            }
            return nil
        }
        XCTAssertEqual(frameWindowIds, [7])
        XCTAssertEqual(sink.received.count, 1)
    }

    @MainActor
    func testPerformanceCategoriesCountMixedCGSAndAXBurstExactly() throws {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(9_001),
            windowId: 9_002
        )

        intake.beginPerformanceCapture()
        intake.enqueue(.cgs(.created(windowId: 1, spaceId: 11)))
        intake.enqueue(.cgs(.destroyed(windowId: 2, spaceId: 12)))
        intake.enqueue(.cgs(.closed(windowId: 3)))
        for _ in 0 ..< 5 {
            intake.enqueue(.cgs(.frameChanged(windowId: 4)))
        }
        for _ in 0 ..< 7 {
            intake.enqueue(.cgs(.titleChanged(windowId: 5)))
        }
        for _ in 0 ..< 2 {
            intake.enqueue(.axFocusedWindowChanged(pid: 9_001, callbackGeneration: nil))
        }
        intake.enqueue(
            .axWindowDestroyed(
                pid: 9_001,
                axRef: axRef,
                callbackGeneration: nil
            )
        )
        for _ in 0 ..< 2 {
            intake.enqueue(
                .axWindowMiniaturized(
                    pid: 9_001,
                    windowId: axRef.windowId,
                    callbackGeneration: nil
                )
            )
        }

        let queued = try XCTUnwrap(intake.performanceSnapshot())
        XCTAssertEqual(queued.acceptedEvents, 20)
        XCTAssertEqual(queued.coalescedEvents, 4)
        XCTAssertEqual(queued.deliveredEvents, 0)
        XCTAssertEqual(queued.currentQueueDepth, 16)
        XCTAssertEqual(queued.maximumQueueDepth, 16)

        intake.drainNow()

        let snapshot = try XCTUnwrap(intake.endPerformanceCapture())
        XCTAssertEqual(snapshot.acceptedEvents, 20)
        XCTAssertEqual(snapshot.coalescedEvents, 4)
        XCTAssertEqual(snapshot.deliveredEvents, 16)
        XCTAssertEqual(snapshot.drainBatches, 1)
        XCTAssertEqual(snapshot.currentQueueDepth, 0)
        XCTAssertEqual(snapshot.maximumQueueDepth, 16)
        XCTAssertEqual(snapshot.maximumBatchSize, 16)
        XCTAssertEqual(
            snapshot.cgsCreatedEvents,
            .init(acceptedEvents: 1, coalescedEvents: 0, deliveredEvents: 1)
        )
        XCTAssertEqual(
            snapshot.cgsDestroyedEvents,
            .init(acceptedEvents: 2, coalescedEvents: 0, deliveredEvents: 2)
        )
        XCTAssertEqual(
            snapshot.cgsFrameChangedEvents,
            .init(acceptedEvents: 5, coalescedEvents: 4, deliveredEvents: 1)
        )
        XCTAssertEqual(
            snapshot.cgsTitleChangedEvents,
            .init(acceptedEvents: 7, coalescedEvents: 0, deliveredEvents: 7)
        )
        XCTAssertEqual(
            snapshot.axLifecycleEvents,
            .init(acceptedEvents: 3, coalescedEvents: 0, deliveredEvents: 3)
        )
        XCTAssertEqual(
            snapshot.axFocusedWindowChangedEvents,
            .init(acceptedEvents: 2, coalescedEvents: 0, deliveredEvents: 2)
        )
    }

    @MainActor
    func testMouseMovedCoalescesLatestPayloadInPlace() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 10, y: 10),
                modifiersRawValue: 1,
                windowIdUnderPointer: 7
            )
        )
        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 20, y: 20),
                modifiersRawValue: 2,
                windowIdUnderPointer: 8
            )
        )
        intake.enqueue(.appActivated(pid: 1))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 2)
        guard case let .mouseMoved(
            location,
            modifiersRawValue,
            windowIdUnderPointer
        ) = sink.received[0].event else {
            return XCTFail("Expected coalesced mouseMoved first: \(sink.received)")
        }
        XCTAssertEqual(location, CGPoint(x: 20, y: 20))
        XCTAssertEqual(modifiersRawValue, 2)
        XCTAssertEqual(windowIdUnderPointer, 8)
        guard case .appActivated = sink.received[1].event else {
            return XCTFail("Expected appActivated second: \(sink.received)")
        }
    }

    @MainActor
    func testNonCoalescibleEventBarsDraggedCoalescingAcrossIt() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        let invocation = HotkeyInvocation(
            command: .focusPrevious,
            trigger: PhysicalHotkeyTrigger(keyCode: 46, modifiers: 0, isRepeat: false)
        )
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.hotkeyInvocation(invocation))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(_, firstLocation) = sink.received[0].event,
              case let .hotkeyInvocation(receivedInvocation) = sink.received[1].event,
              case let .mouseDragged(_, secondLocation) = sink.received[2].event
        else {
            return XCTFail("Expected dragged, command, dragged in order: \(sink.received)")
        }
        XCTAssertEqual(receivedInvocation, invocation)
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testDraggedCoalescesToLatestLocationWithoutBarrier() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 1)
        guard case let .mouseDragged(_, location) = sink.received[0].event else {
            return XCTFail("Expected a single coalesced mouseDragged: \(sink.received)")
        }
        XCTAssertEqual(location, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testMovedDraggedMovedDrainsInArrivalOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 10, y: 10),
                modifiersRawValue: 0,
                windowIdUnderPointer: nil
            )
        )
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 30, y: 30),
                modifiersRawValue: 0,
                windowIdUnderPointer: nil
            )
        )
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseMoved(firstLocation, _, _) = sink.received[0].event,
              case let .mouseDragged(_, draggedLocation) = sink.received[1].event,
              case let .mouseMoved(lastLocation, _, _) = sink.received[2].event
        else {
            return XCTFail("Expected moved, dragged, moved in order: \(sink.received)")
        }
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(draggedLocation, CGPoint(x: 20, y: 20))
        XCTAssertEqual(lastLocation, CGPoint(x: 30, y: 30))
    }

    @MainActor
    func testAlternatingDragButtonsDrainInArrivalOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.mouseDragged(button: .right, location: CGPoint(x: 20, y: 20)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 30, y: 30)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(firstButton, firstLocation) = sink.received[0].event,
              case let .mouseDragged(secondButton, secondLocation) = sink.received[1].event,
              case let .mouseDragged(thirdButton, thirdLocation) = sink.received[2].event
        else {
            return XCTFail("Expected left, right, left drags in order: \(sink.received)")
        }
        XCTAssertEqual(firstButton, .left)
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondButton, .right)
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
        XCTAssertEqual(thirdButton, .left)
        XCTAssertEqual(thirdLocation, CGPoint(x: 30, y: 30))
    }

    @MainActor
    func testCGSFrameChangedBarsDraggedCoalescingAcrossIt() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(_, firstLocation) = sink.received[0].event,
              case .cgs(.frameChanged) = sink.received[1].event,
              case let .mouseDragged(_, secondLocation) = sink.received[2].event
        else {
            return XCTFail("Expected dragged, frameChanged, dragged in order: \(sink.received)")
        }
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testScrollAccumulatesSameAxisAndSplitsOnFlip() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseScroll(scroll(deltaY: 5)))
        intake.enqueue(.mouseScroll(scroll(deltaY: 3)))
        intake.enqueue(.mouseScroll(scroll(deltaY: -2)))
        intake.drainNow()

        let deltas = sink.received.compactMap { stamped -> CGFloat? in
            if case let .mouseScroll(payload) = stamped.event {
                return payload.deltaY
            }
            return nil
        }
        XCTAssertEqual(deltas, [8, -2])
    }

    @MainActor
    func testNativeFullscreenTimeoutPostsBeforeApplyingExpiry() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNativeFullscreenExpiryPostingTests")
        let sink = RecordingSink()
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: sink)
        defer {
            controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
            controller.eventIntake.close()
        }

        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 981_401, windowId: 981_402)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId))
        let generation = try XCTUnwrap(
            controller.workspaceManager.nativeFullscreenRecord(for: token)?.transitionGeneration
        )
        controller.workspaceManager.cancelNativeFullscreenTransitionTimeout(originalToken: token)

        XCTAssertTrue(
            controller.workspaceManager.postNativeFullscreenTransitionExpiry(
                originalToken: token,
                generation: generation
            )
        )
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenRecord(for: token)?.transition, .enterRequested)
        XCTAssertTrue(sink.received.isEmpty)

        controller.eventIntake.drainNow()

        XCTAssertEqual(sink.received.count, 1)
        let stamped = try XCTUnwrap(sink.received.first)
        XCTAssertGreaterThan(stamped.seq, 0)
        guard case let .nativeFullscreenTransitionExpired(originalToken, receivedGeneration) = stamped.event else {
            return XCTFail("Expected native fullscreen transition expiry")
        }
        XCTAssertEqual(originalToken, token)
        XCTAssertEqual(receivedGeneration, generation)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenRecord(for: token)?.transition, .enterRequested)

        controller.eventInterpreter.handleIntakeEvent(stamped)

        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: token))
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.layoutReason, .standard)
    }

    @MainActor
    func testNativeFullscreenRekeyAndSuspensionPrecedeLaterExpiry() throws {
        try assertNativeFullscreenExpiryOrdering(expiryFirst: false)
    }

    @MainActor
    func testNativeFullscreenExpiryPrecedesLaterRekeyAndSuspension() throws {
        try assertNativeFullscreenExpiryOrdering(expiryFirst: true)
    }

    @MainActor
    func testRestartReconciliationRetiresMissingApplicationBeforeTimeoutResume() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMRestartTerminationCleanupTests")
        defer {
            controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
            controller.eventIntake.close()
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            controller.nativeFullscreenPlaceholderManager.removeAll()
        }

        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let liveToken = WindowToken(pid: 981_701, windowId: 981_801)
        let livePendingToken = WindowToken(pid: liveToken.pid, windowId: 981_805)
        let deadToken = WindowToken(pid: 981_702, windowId: 981_802)
        _ = WindowAdmissionTestSupport.track(liveToken, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(livePendingToken, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(deadToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.requestNativeFullscreenEnter(livePendingToken, in: workspaceId)
        )
        XCTAssertTrue(
            controller.workspaceManager.markNativeFullscreenSuspended(
                liveToken,
                ownsNonManagedFocus: false
            )
        )
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(deadToken))
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenExit(deadToken))
        XCTAssertEqual(controller.workspaceManager.activeNativeFullscreenFocusOwnerToken, deadToken)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenTransitionTimeoutCount, 2)

        controller.hasStartedServices = false
        controller.eventIntake.close()
        controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
        controller.surfaceReconciler.cleanup()
        controller.nativeFullscreenPlaceholderManager.removeAll()

        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        NativeFullscreenPlaceholderTrace.shared.beginCapture()
        defer { NativeFullscreenPlaceholderTrace.shared.endCapture() }
        controller.serviceLifecycleManager.reconcileStoppedApplicationTerminationsAndResumeTimeouts(
            liveApplicationPIDs: [liveToken.pid]
        )

        XCTAssertNil(controller.workspaceManager.entry(for: deadToken))
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: deadToken))
        XCTAssertFalse(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertNil(controller.workspaceManager.nonManagedFocusToken)
        XCTAssertNil(controller.workspaceManager.activeNativeFullscreenFocusOwnerToken)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenTransitionTimeoutCount, 1)
        XCTAssertNotNil(controller.workspaceManager.entry(for: liveToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: livePendingToken))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: liveToken)?.transition,
            .suspended
        )
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: livePendingToken)?.transition,
            .enterRequested
        )
        XCTAssertEqual(controller.workspaceManager.workspace(for: liveToken), workspaceId)
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: liveToken), .nativeFullscreen)
        XCTAssertEqual(
            WorldView(controller: controller).nativeFullscreenPlaceholders().map(\.originalToken),
            [liveToken, livePendingToken]
        )
        XCTAssertFalse(controller.eventIntake.hasPendingEvents)
        let trace = NativeFullscreenPlaceholderTrace.shared.dump()
        let removal = try XCTUnwrap(trace.range(of: "op=record_removed original=981702:981802"))
        let schedule = try XCTUnwrap(trace.range(of: "op=deadline_scheduled original=981701:981805"))
        XCTAssertLessThan(removal.lowerBound, schedule.lowerBound)
        XCTAssertFalse(trace.contains("op=deadline_scheduled original=981702:981802"))
    }

    @MainActor
    func testRestartReconciliationPreservesLiveNativeFullscreenFocusOwner() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMRestartLiveFullscreenTests")
        defer {
            controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
            controller.eventIntake.close()
            controller.layoutRefreshController.resetState()
        }

        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let liveToken = WindowToken(pid: 981_703, windowId: 981_803)
        let deadToken = WindowToken(pid: 981_704, windowId: 981_804)
        _ = WindowAdmissionTestSupport.track(liveToken, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(deadToken, in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(liveToken))
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(deadToken, in: workspaceId))
        controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()

        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.serviceLifecycleManager.reconcileStoppedApplicationTerminationsAndResumeTimeouts(
            liveApplicationPIDs: [liveToken.pid]
        )

        XCTAssertNil(controller.workspaceManager.entry(for: deadToken))
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: deadToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: liveToken))
        XCTAssertEqual(
            controller.workspaceManager.nativeFullscreenRecord(for: liveToken)?.transition,
            .suspended
        )
        XCTAssertTrue(controller.workspaceManager.isNonManagedFocusActive)
        XCTAssertEqual(controller.workspaceManager.nonManagedFocusToken, liveToken)
        XCTAssertEqual(controller.workspaceManager.activeNativeFullscreenFocusOwnerToken, liveToken)
        XCTAssertFalse(controller.eventIntake.hasPendingEvents)
    }

    private func scroll(deltaY: CGFloat) -> MouseScrollIntake {
        MouseScrollIntake(
            location: .zero,
            deltaX: 0,
            deltaY: deltaY,
            momentumPhase: 0,
            phase: 0,
            modifiersRawValue: 0
        )
    }

    private final class FakeWindowSystem {
        var focusedWindowIdByPid: [pid_t: Int] = [:]
        var staleFocusedWindowIds: [Int] = []
    }

    @MainActor
    private func assertNativeFullscreenExpiryOrdering(
        expiryFirst: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNativeFullscreenExpiryOrderingTests")
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer {
            controller.workspaceManager.cancelNativeFullscreenTransitionTimeouts()
            controller.eventIntake.close()
        }

        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true),
            file: file,
            line: line
        )
        let originalToken = WindowToken(pid: 981_501, windowId: 981_601)
        let replacementToken = WindowToken(pid: originalToken.pid, windowId: originalToken.windowId + 1)
        _ = WindowAdmissionTestSupport.track(originalToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.workspaceManager.requestNativeFullscreenEnter(originalToken, in: workspaceId),
            file: file,
            line: line
        )
        let generation = try XCTUnwrap(
            controller.workspaceManager.nativeFullscreenRecord(for: originalToken)?.transitionGeneration,
            file: file,
            line: line
        )
        let replacementEvent = IntakeEvent.ipcCommand(
            IPCCommandIntake(
                perform: { controller in
                    guard controller.workspaceManager.rekeyWindow(
                        from: originalToken,
                        to: replacementToken,
                        newAXRef: WindowAdmissionTestSupport.axRef(for: replacementToken)
                    ) != nil,
                        controller.workspaceManager.markNativeFullscreenSuspended(
                            replacementToken,
                            ownsNonManagedFocus: false
                        )
                    else {
                        return .notFound
                    }
                    return .executed
                },
                completion: { _ in }
            )
        )
        let expiryEvent = IntakeEvent.nativeFullscreenTransitionExpired(
            originalToken: originalToken,
            generation: generation
        )

        if expiryFirst {
            XCTAssertTrue(controller.eventIntake.enqueue(expiryEvent), file: file, line: line)
            XCTAssertTrue(controller.eventIntake.enqueue(replacementEvent), file: file, line: line)
        } else {
            XCTAssertTrue(controller.eventIntake.enqueue(replacementEvent), file: file, line: line)
            XCTAssertTrue(controller.eventIntake.enqueue(expiryEvent), file: file, line: line)
        }
        controller.eventIntake.drainNow()

        let expectedOriginalToken = expiryFirst ? replacementToken : originalToken
        let record = try XCTUnwrap(
            controller.workspaceManager.nativeFullscreenRecord(originalToken: expectedOriginalToken),
            file: file,
            line: line
        )
        XCTAssertEqual(record.originalToken, expectedOriginalToken, file: file, line: line)
        XCTAssertEqual(record.currentToken, replacementToken, file: file, line: line)
        XCTAssertEqual(record.transition, .suspended, file: file, line: line)
        XCTAssertEqual(controller.workspaceManager.nativeFullscreenTransitionTimeoutCount, 0, file: file, line: line)
        if expiryFirst {
            XCTAssertNil(
                controller.workspaceManager.nativeFullscreenRecord(originalToken: originalToken),
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private struct ReplayScenario {
        let controller: WMController
        let system: FakeWindowSystem
        let tokenA: WindowToken
        let tokenB: WindowToken
        let workspaceId: WorkspaceDescriptor.ID

        func drainToQuiescence() {
            var iterations = 0
            while controller.eventIntake.hasPendingEvents, iterations < 64 {
                controller.eventIntake.drainNow()
                iterations += 1
            }
        }

        func committedState() -> String {
            let focused = controller.workspaceManager.focusedToken?.windowId ?? -1
            let intents = controller.intentLedger.entries
                .filter { $0.kind.isFocusWindow }
                .map { intent in
                    "\(intent.kind.focusTargetToken?.windowId ?? -1):\(intent.phase)"
                }
                .joined(separator: ",")
            return "focused=\(focused) intents=[\(intents)]"
        }

        func tearDown() {
            controller.deadlineWheel.stop()
            controller.eventIntake.close()
        }
    }

    @MainActor
    func testStaleActivationFactsCannotCancelNewerFocusIntent() throws {
        let pid: pid_t = 100
        let staleFacts = IntakeEvent.activationFactsResolved(
            ActivationFacts(
                pid: pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 42),
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )
        let observationStream: [IntakeEvent] = [
            .cgs(.frontAppChanged(pid: pid)),
            .axFocusedWindowChanged(pid: pid, callbackGeneration: nil)
        ]

        var outcomes: [String] = []
        for events in Self.interleavings([staleFacts], observationStream) {
            let scenario = try makeScenario(pid: pid)
            for event in events {
                scenario.controller.eventIntake.enqueue(event)
            }
            scenario.drainToQuiescence()
            XCTAssertEqual(scenario.controller.workspaceManager.focusedToken, scenario.tokenB)
            outcomes.append(scenario.committedState())
            scenario.tearDown()
        }

        XCTAssertEqual(Set(outcomes).count, 1, "Interleavings diverged: \(outcomes)")
    }

    @MainActor
    func testStaleFocusEchoOfConfirmedIntentDoesNotPreemptNewerIntent() throws {
        let pid: pid_t = 100
        let echoStream: [IntakeEvent] = [
            .axFocusedWindowChanged(pid: pid, callbackGeneration: nil),
            .axFocusedWindowChanged(pid: pid, callbackGeneration: nil)
        ]
        let hintStream: [IntakeEvent] = [
            .cgs(.frontAppChanged(pid: pid))
        ]

        var outcomes: [String] = []
        for events in Self.interleavings(echoStream, hintStream) {
            let scenario = try makeScenario(pid: pid)
            scenario.system.staleFocusedWindowIds = [scenario.tokenA.windowId]
            for event in events {
                scenario.controller.eventIntake.enqueue(event)
            }
            scenario.drainToQuiescence()
            XCTAssertEqual(scenario.controller.workspaceManager.focusedToken, scenario.tokenB)
            let newestIntentForB = scenario.controller.intentLedger.entries
                .last { $0.kind.focusTargetToken == scenario.tokenB }
            XCTAssertEqual(newestIntentForB?.phase, .confirmed)
            outcomes.append(scenario.committedState())
            scenario.tearDown()
        }

        XCTAssertEqual(Set(outcomes).count, 1, "Interleavings diverged: \(outcomes)")
    }

    @MainActor
    func testSystemModalFocusSuppressesBorderAndClearsOnNormalFocus() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller
        let system = scenario.system

        var reportSystemModal = true
        controller.factResolver.factProvider = { pid in
            guard let windowId = system.focusedWindowIdByPid[pid] else { return nil }
            return FocusedWindowFact(
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                isFullscreen: false,
                isSystemModalSurface: reportSystemModal
            )
        }

        system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()

        XCTAssertEqual(controller.workspaceManager.systemModalFocusToken, scenario.tokenB)
        XCTAssertEqual(WorldView(controller: controller).systemModalFocusToken, scenario.tokenB)
        XCTAssertTrue(controller.shouldSuppressManagedFocusRecovery)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: WorldView(controller: controller)))

        reportSystemModal = false
        system.focusedWindowIdByPid[pid] = scenario.tokenA.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()

        XCTAssertNil(controller.workspaceManager.systemModalFocusToken)
    }

    @MainActor
    func testStaleSystemModalFocusTokenDoesNotSuppressDifferentRenderableToken() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller
        let system = scenario.system

        system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()

        controller.workspaceManager.setSystemModalFocus(scenario.tokenA)
        let world = WorldView(controller: controller, borderFrameResolver: { windowId in
            windowId == scenario.tokenB.windowId ? CGRect(x: 0, y: 0, width: 200, height: 150) : nil
        })

        XCTAssertEqual(controller.workspaceManager.renderableFocusToken, scenario.tokenB)
        XCTAssertEqual(world.systemModalFocusToken, scenario.tokenA)
        XCTAssertFalse(controller.shouldSuppressManagedFocusRecovery)
        XCTAssertNotNil(SurfaceDerivation.deriveBorder(world: world))
    }

    @MainActor
    func testDisabledBorderConfigYieldsNoBorder() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller

        scenario.system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()

        let frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        let enabledWorld = WorldView(controller: controller, borderFrameResolver: { _ in frame })
        let border = try XCTUnwrap(SurfaceDerivation.deriveBorder(world: enabledWorld))
        XCTAssertEqual(border.windowId, scenario.tokenB.windowId)
        XCTAssertEqual(border.frame, frame)

        controller.settings.bordersEnabled = false
        let disabledWorld = WorldView(controller: controller, borderFrameResolver: { _ in frame })
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: disabledWorld))
    }

    @MainActor
    func testZeroSizedBorderFrameYieldsNoBorder() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller

        scenario.system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()

        let world = WorldView(controller: controller, borderFrameResolver: { _ in .zero })
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
    }

    @MainActor
    private func makeScenario(pid: pid_t) throws -> ReplayScenario {
        let system = FakeWindowSystem()
        let controller = WMController(
            settings: Self.settingsStore(),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    system.focusedWindowIdByPid[pid] = Int(windowId)
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let tokenA = try addNiriWindow(controller, pid: pid, windowId: 42, workspaceId: workspaceId)
        let tokenB = try addNiriWindow(controller, pid: pid, windowId: 43, workspaceId: workspaceId)

        controller.factResolver.factProvider = { pid in
            let windowId: Int?
            if system.staleFocusedWindowIds.isEmpty {
                windowId = system.focusedWindowIdByPid[pid]
            } else {
                windowId = system.staleFocusedWindowIds.removeFirst()
            }
            guard let windowId else { return nil }
            return FocusedWindowFact(
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                isFullscreen: false,
                isSystemModalSurface: false
            )
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)

        let scenario = ReplayScenario(
            controller: controller,
            system: system,
            tokenA: tokenA,
            tokenB: tokenB,
            workspaceId: workspaceId
        )

        controller.focusWindow(tokenA)
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid, callbackGeneration: nil))
        scenario.drainToQuiescence()
        XCTAssertEqual(controller.workspaceManager.focusedToken, tokenA)

        controller.focusWindow(tokenB)
        return scenario
    }

    @MainActor
    private func addNiriWindow(
        _ controller: WMController,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) throws -> WindowToken {
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let node = try XCTUnwrap(
            controller.niriEngine?.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: nil
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        node.frame = frame
        node.renderedFrame = frame
        return token
    }

    private static func interleavings(_ a: [IntakeEvent], _ b: [IntakeEvent]) -> [[IntakeEvent]] {
        if a.isEmpty { return [b] }
        if b.isEmpty { return [a] }
        var result: [[IntakeEvent]] = []
        for merged in interleavings(Array(a.dropFirst()), b) {
            result.append([a[0]] + merged)
        }
        for merged in interleavings(a, Array(b.dropFirst())) {
            result.append([b[0]] + merged)
        }
        return result
    }

    @MainActor
    private static func settingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMReplayTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
