// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import IOKit
@testable import OmniWM
import XCTest

@MainActor
final class MultitouchLifecycleTests: XCTestCase {
    private let deviceA = FakeMultitouchBackend.device(pointer: 0xA1, registryId: 101)
    private let deviceB = FakeMultitouchBackend.device(pointer: 0xB1, registryId: 202)

    func testProductionTopologyCriteriaUsesDigitizerDeviceUsages() throws {
        let criteria = MultitouchGestureSource.topologyCriteria
        XCTAssertEqual(criteria.count, 1)
        let criterion = try XCTUnwrap(criteria.first)
        XCTAssertNil(criterion.primaryUsage)
        XCTAssertEqual(
            criterion.deviceUsages,
            [.digitizers(.touchPad), .digitizers(.multiplePointDigitizer)]
        )
        XCTAssertNil(criterion.vendorID)
        XCTAssertNil(criterion.productID)
    }

    func testNilEnumerationNeverBecomesRunning() async {
        let harness = makeHarness([FakeMultitouchBackend.failedEnumeration(.unavailable)])
        harness.source.startLifecycle()
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertEqual(snapshot.lastEnumeration, .unavailable)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 1)
        XCTAssertTrue(harness.backend.registeredGenerations.isEmpty)
        await shutdown(harness)
    }

    func testEmptyEnumerationNeverBecomesRunning() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([])])
        harness.source.startLifecycle()
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertEqual(snapshot.lastEnumeration, .empty)
        XCTAssertTrue(harness.backend.registeredGenerations.isEmpty)
        await shutdown(harness)
    }

    func testDelayedDeviceAppearanceStartsOnBoundedRetry() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .retrying)
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.registeredDeviceCount, 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.start(101)), 1)
        XCTAssertEqual(harness.sleeper.pendingCount, 0)
        await shutdown(harness)
    }

    func testWakeWaitsThenReplacesSameDeviceSetOnce() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        harness.source.requestRevalidation(.wake)
        await drainMultitouchTasks()
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 0)
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertNotEqual(snapshot.activeGeneration, firstGeneration)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testWakeAndUnlockCoalesceIntoOneReplacement() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.requestRevalidation(.wake)
        harness.source.requestRevalidation(.unlock)
        await drainMultitouchTasks()
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()

        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testTopologyConvergenceAfterWakeDoesNotRepeatLifecycleReplacement() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA, deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.requestRevalidation(.wake)
        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)

        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)

        await runNext(harness)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 3)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        await shutdown(harness)
    }

    func testEventInterpreterWakeAndServiceUnlockReachInstalledSource() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        let controller = WindowAdmissionTestSupport.controller()
        controller.mouseEventHandler.installMultitouchSource(harness.source)
        await runNext(harness)
        let initialGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(seq: 1, event: .systemSleep))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .suspended)
        controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(seq: 2, event: .systemWake))
        await drainMultitouchTasks()
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        let wakeGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        XCTAssertNotEqual(wakeGeneration, initialGeneration)

        controller.serviceLifecycleManager.handleUnlockDetected()
        await drainMultitouchTasks()
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(1))
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        XCTAssertNotEqual(harness.source.diagnosticsSnapshot().activeGeneration, wakeGeneration)

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testArrivalRecoversSourceAfterEmptyStartup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastTopologySignal, .arrival)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        await shutdown(harness)
    }

    func testArrivalRetriesUntilMultitouchEnumerationConverges() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA, deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)

        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .milliseconds(250))

        await runNext(harness)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().registeredDeviceCount, 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 3)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        await shutdown(harness)
    }

    func testRemovalRebuildsChangedDeviceSet() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA, deviceB]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.receiveTopologySignal(.removal)
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.registeredDeviceCount, 1)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testSameCountReplacementUsesRegistryIds() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        harness.source.receiveTopologySignal(.arrival)
        await runNext(harness)

        XCTAssertNotEqual(harness.source.diagnosticsSnapshot().activeGeneration, firstGeneration)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testDuplicateTopologySignalsForceOneReplacementPerEpisode() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        let initialGeneration = harness.source.diagnosticsSnapshot().activeGeneration

        harness.source.receiveTopologySignal(.arrival)
        harness.source.receiveTopologySignal(.removal)
        harness.source.receiveTopologySignal(.arrival)
        await drainMultitouchTasks()
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()

        let replacementGeneration = harness.source.diagnosticsSnapshot().activeGeneration
        XCTAssertNotEqual(replacementGeneration, initialGeneration)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)

        harness.source.receiveTopologySignal(.removal)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().activeGeneration, replacementGeneration)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 3)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        await shutdown(harness)
    }

    func testTopologySignalAcceleratesLongRetryWithoutResettingAttemptBudget() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.receiveTopologySignal(.arrival)
        for _ in 0 ..< 5 {
            await runNext(harness)
        }

        let attempt = harness.source.diagnosticsSnapshot().retryAttempt
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .seconds(4))
        harness.source.receiveTopologySignal(.removal)
        await drainMultitouchTasks()

        XCTAssertEqual(harness.source.diagnosticsSnapshot().retryAttempt, attempt)
        XCTAssertEqual(harness.sleeper.requestedDurations.last, .milliseconds(100))
        XCTAssertEqual(harness.sleeper.pendingCount, 1)
        await shutdown(harness)
    }

    func testRetryCancellationOnSuspendAndShutdown() async {
        let suspended = makeHarness([FakeMultitouchBackend.enumeration([])])
        suspended.source.startLifecycle()
        await runNext(suspended)
        let suspendedEnumerationCount = suspended.backend.callCount(.enumerate)
        suspended.source.suspendForSleep()
        suspended.sleeper.resumeAll()
        await drainMultitouchTasks()
        XCTAssertEqual(suspended.source.diagnosticsSnapshot().state, .suspended)
        XCTAssertEqual(suspended.backend.callCount(.enumerate), suspendedEnumerationCount)
        await shutdown(suspended)

        let stopped = makeHarness([FakeMultitouchBackend.enumeration([])])
        stopped.source.startLifecycle()
        await runNext(stopped)
        let stoppedEnumerationCount = stopped.backend.callCount(.enumerate)
        stopped.source.shutdown()
        stopped.sleeper.resumeAll()
        await drainMultitouchTasks()
        XCTAssertEqual(stopped.source.diagnosticsSnapshot().state, .stopped)
        XCTAssertEqual(stopped.backend.callCount(.enumerate), stoppedEnumerationCount)
    }

    func testRetryExhaustionStopsScheduling() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([])])
        harness.source.startLifecycle()
        for _ in 0 ..< 7 {
            await runNext(harness)
        }

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .exhausted)
        XCTAssertEqual(snapshot.retryAttempt, 7)
        XCTAssertEqual(harness.backend.callCount(.enumerate), 7)
        XCTAssertEqual(harness.sleeper.pendingCount, 0)
        XCTAssertEqual(
            harness.sleeper.requestedDurations,
            [
                .milliseconds(100),
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
                .seconds(2),
                .seconds(4),
                .seconds(8)
            ]
        )
        await shutdown(harness)
    }

    func testStaleGenerationIsRejectedAfterReplacement() async throws {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        var snapshots: [MouseEventHandler.GestureEventSnapshot] = []
        var replacementCount = 0
        harness.source.onSnapshot = { snapshots.append($0) }
        harness.source.onSourceWillReplace = { replacementCount += 1 }
        harness.source.startLifecycle()
        await runNext(harness)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        harness.source.handleRawFrame(frame(count: 3, timestamp: 1), generation: firstGeneration, location: .zero)
        XCTAssertEqual(snapshots.last?.phaseRawValue, NSEvent.Phase.began.rawValue)

        harness.source.requestRevalidation(.wake)
        await runNext(harness)
        let secondGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        XCTAssertEqual(replacementCount, 1)

        let acceptedCount = snapshots.count
        harness.source.handleRawFrame(frame(count: 0, timestamp: 2), generation: firstGeneration, location: .zero)
        XCTAssertEqual(snapshots.count, acceptedCount)
        harness.source.handleRawFrame(frame(count: 3, timestamp: 3), generation: secondGeneration, location: .zero)
        XCTAssertEqual(snapshots.last?.phaseRawValue, NSEvent.Phase.began.rawValue)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastRawCallbackGeneration, secondGeneration)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastAcceptedCallbackGeneration, secondGeneration)
        await shutdown(harness)
    }

    func testStaleCallbackCannotRouteThroughNewSharedSource() async throws {
        let first = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        first.source.startLifecycle()
        await runNext(first)
        let staleGeneration = try XCTUnwrap(first.source.diagnosticsSnapshot().activeGeneration)

        let second = makeHarness([FakeMultitouchBackend.enumeration([deviceB])])
        var secondSnapshots = 0
        second.source.onSnapshot = { _ in secondSnapshots += 1 }
        second.source.startLifecycle()
        await runNext(second)
        XCTAssertTrue(MultitouchGestureSource.shared === second.source)

        MultitouchGestureSource.shared?.handleRawFrame(
            frame(count: 3, timestamp: 4),
            generation: staleGeneration,
            location: .zero
        )
        XCTAssertEqual(secondSnapshots, 0)
        await shutdown(first)
        await shutdown(second)
    }

    func testPartialStartFailureRollsBackEntireTransaction() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        harness.backend.startResults[202] = [-1]
        harness.source.startLifecycle()
        await runNext(harness)

        let snapshot = harness.source.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.state, .retrying)
        XCTAssertEqual(snapshot.registeredDeviceCount, 0)
        XCTAssertNil(snapshot.activeGeneration)
        XCTAssertEqual(snapshot.lastStart, .status(-1))
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.stop(202)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(101)), 1)
        XCTAssertEqual(harness.backend.callCount(.unregister(202)), 1)
        await shutdown(harness)
    }

    func testFailedStartTreatsNotOpenStopAsCompletedCleanup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.backend.startResults[101] = [-1, KERN_SUCCESS]
        harness.backend.stopResults[101] = [kIOReturnNotOpen]
        harness.source.startLifecycle()
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .alreadyStopped(kIOReturnNotOpen))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().registeredDeviceCount, 0)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        await shutdown(harness)
    }

    func testRemovalTreatsNotOpenStopAsCompletedCleanup() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceB])
        ])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.stopResults[101] = [kIOReturnNotOpen]

        harness.source.receiveTopologySignal(.removal)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .alreadyStopped(kIOReturnNotOpen))
        XCTAssertEqual(harness.backend.callCount(.register(202)), 1)
        await shutdown(harness)
    }

    func testMissingUnregisterCallbackIsIdempotentCleanup() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.unregisterResults[101] = [false]

        XCTAssertTrue(harness.source.shutdown())
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastUnregister, .alreadyUnregistered)
        XCTAssertNil(harness.source.diagnosticsSnapshot().activeGeneration)
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testCleanupFailureBlocksReregistrationUntilCleanupSucceeds() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]
        harness.source.startLifecycle()
        await runNext(harness)
        harness.source.requestRevalidation(.wake)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .retrying)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 1)
        await runNext(harness)

        XCTAssertEqual(harness.source.diagnosticsSnapshot().state, .running)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        let secondRegister = harness.backend.calls.lastIndex(of: .register(101))
        let successfulCleanupStop = harness.backend.calls.lastIndex(of: .stop(101))
        XCTAssertNotNil(secondRegister)
        XCTAssertNotNil(successfulCleanupStop)
        if let secondRegister, let successfulCleanupStop {
            XCTAssertGreaterThan(secondRegister, successfulCleanupStop)
        }
        await shutdown(harness)
    }

    func testSourceReplacementWaitsForOldShutdownCleanup() async {
        let old = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        old.backend.stopResults[101] = [-1, KERN_SUCCESS]
        let replacement = makeHarness([FakeMultitouchBackend.enumeration([deviceB])])
        let controller = WindowAdmissionTestSupport.controller()

        XCTAssertTrue(controller.mouseEventHandler.installMultitouchSource(old.source))
        await runNext(old)
        XCTAssertFalse(controller.mouseEventHandler.installMultitouchSource(replacement.source))
        XCTAssertEqual(controller.mouseEventHandler.multitouchDiagnosticsSnapshot?.lastStop, .status(-1))
        XCTAssertEqual(replacement.backend.callCount(.register(202)), 0)
        XCTAssertTrue(MultitouchGestureSource.shared === old.source)

        XCTAssertTrue(controller.mouseEventHandler.installMultitouchSource(replacement.source))
        await runNext(replacement)
        XCTAssertEqual(replacement.backend.callCount(.register(202)), 1)
        XCTAssertTrue(MultitouchGestureSource.shared === replacement.source)

        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        old.sleeper.resumeAll()
        replacement.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testFeatureReenableRetriesRetainedSourceAfterDisableCleanupFailure() async {
        let harness = makeHarness([
            FakeMultitouchBackend.enumeration([deviceA]),
            FakeMultitouchBackend.enumeration([deviceA])
        ])
        let controller = WindowAdmissionTestSupport.controller(prefix: "MultitouchDisableRecovery")
        controller.settings.scrollGestureEnabled = true
        controller.settings.workspaceSwipeEnabled = false
        controller.hasStartedServices = true
        let handler = controller.mouseEventHandler
        var replacementCreations = 0
        handler.multitouchSourceFactory = {
            replacementCreations += 1
            return MultitouchGestureSource(operations: nil)
        }

        XCTAssertTrue(handler.installMultitouchSource(harness.source))
        await runNext(harness)
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]

        controller.settings.scrollGestureEnabled = false
        handler.reconcileMultitouchSource()

        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .stopped)
        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.lastStop, .status(-1))
        XCTAssertTrue(MultitouchGestureSource.shared === harness.source)

        controller.settings.scrollGestureEnabled = true
        handler.reconcileMultitouchSource()
        await runNext(harness)

        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .running)
        XCTAssertEqual(harness.backend.callCount(.stop(101)), 2)
        XCTAssertEqual(harness.backend.callCount(.register(101)), 2)
        XCTAssertEqual(replacementCreations, 0)
        XCTAssertTrue(MultitouchGestureSource.shared === harness.source)

        controller.hasStartedServices = false
        controller.layoutRefreshController.resetState()
        handler.cleanup()
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testCleanupDiagnosticsPreserveFailureAcrossDevices() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA, deviceB])])
        harness.source.startLifecycle()
        await runNext(harness)
        harness.backend.stopResults[101] = [-1, KERN_SUCCESS]

        XCTAssertFalse(harness.source.shutdown())
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastStop, .status(-1))
        XCTAssertEqual(harness.source.diagnosticsSnapshot().lastUnregister, .success)
        XCTAssertTrue(harness.source.shutdown())
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testTopologyObserverExhaustionIsBoundedAndWakeRearmsIt() async {
        await assertTopologyObserverRearms(for: .wake)
    }

    func testTopologyObserverExhaustionIsBoundedAndUnlockRearmsIt() async {
        await assertTopologyObserverRearms(for: .unlock)
    }

    private func assertTopologyObserverRearms(for reason: MultitouchGestureSource.RevalidationReason) async {
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([deviceA])]
        let lifecycleSleeper = ManualMultitouchSleeper()
        let topologyMonitor = FakeTopologyMonitor()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: lifecycleSleeper),
            topologyMonitoringEnabled: true,
            topologyMonitoringOperations: topologyMonitor.operations()
        )
        let harness = (source: source, backend: backend, sleeper: lifecycleSleeper)

        source.startLifecycle()
        await runNext(harness)
        for _ in 0 ..< 6 {
            await drainMultitouchTasks()
            XCTAssertGreaterThan(topologyMonitor.sleeper.pendingCount, 0)
            topologyMonitor.sleeper.resumeNext()
        }
        await drainMultitouchTasks()

        XCTAssertEqual(topologyMonitor.streamCount, 7)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .exhausted)
        XCTAssertEqual(topologyMonitor.sleeper.pendingCount, 0)

        source.requestRevalidation(reason)
        await drainMultitouchTasks()
        XCTAssertEqual(topologyMonitor.streamCount, 8)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))

        source.shutdown()
        lifecycleSleeper.resumeAll()
        topologyMonitor.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testTopologyObserverNotificationResetsConsecutiveFailureBudget() async {
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([deviceA])]
        let lifecycleSleeper = ManualMultitouchSleeper()
        let topologyMonitor = FakeTopologyMonitor()
        topologyMonitor.signalsByStream = [[], [.arrival]]
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: lifecycleSleeper),
            topologyMonitoringEnabled: true,
            topologyMonitoringOperations: topologyMonitor.operations()
        )

        source.startLifecycle()
        await drainMultitouchTasks()
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))
        topologyMonitor.sleeper.resumeNext()
        await drainMultitouchTasks()

        XCTAssertEqual(topologyMonitor.streamCount, 2)
        XCTAssertEqual(source.diagnosticsSnapshot().lastTopologySignal, .arrival)
        XCTAssertEqual(source.diagnosticsSnapshot().topologyObserverState, .retrying(1))
        XCTAssertEqual(
            topologyMonitor.sleeper.requestedDurations,
            [.milliseconds(250), .milliseconds(250)]
        )

        source.shutdown()
        lifecycleSleeper.resumeAll()
        topologyMonitor.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testDiagnosticsFormatExposesLifecycleWithoutDeviceIdentity() async {
        let harness = makeHarness([FakeMultitouchBackend.enumeration([deviceA])])
        harness.source.startLifecycle()
        await runNext(harness)
        let formatted = harness.source.diagnosticsSnapshot().formatted()

        XCTAssertTrue(formatted.contains("state=running"))
        XCTAssertTrue(formatted.contains("registeredDevices=1"))
        XCTAssertTrue(formatted
            .contains("lastEnumeration=Optional(OmniWM.MultitouchBinding.EnumerationOutcome.success(1))"))
        XCTAssertTrue(formatted.contains("lastAcceptedCallbackTimestamp=nil"))
        XCTAssertFalse(formatted.contains("101"))
        await shutdown(harness)
    }

    private func makeHarness(
        _ enumerations: [MultitouchBinding.Enumeration]
    ) -> (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper) {
        let backend = FakeMultitouchBackend()
        backend.enumerations = enumerations
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        return (source, backend, sleeper)
    }

    private func runNext(
        _ harness: (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper)
    ) async {
        await drainMultitouchTasks()
        XCTAssertGreaterThan(harness.sleeper.pendingCount, 0)
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
    }

    private func shutdown(
        _ harness: (source: MultitouchGestureSource, backend: FakeMultitouchBackend, sleeper: ManualMultitouchSleeper)
    ) async {
        harness.source.shutdown()
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    private func frame(count: Int, timestamp: Double) -> MultitouchGestureSource.RawFrame {
        MultitouchGestureSource.RawFrame(
            touches: (0 ..< count).map { _ in MultitouchGestureSource.RawTouch(x: 0.5, y: 0.5) },
            timestamp: timestamp
        )
    }
}
