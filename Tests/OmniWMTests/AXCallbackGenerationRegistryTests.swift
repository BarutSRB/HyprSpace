// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Dispatch
@testable import OmniWM
import XCTest

final class AXCallbackGenerationRegistryTests: XCTestCase {
    func testRegisteredObserverRunsOnlyInItsGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        var callbackCount = 0

        registerObserver(1, in: registry, serviceGeneration: generation)
        XCTAssertTrue(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)
    }

    func testAdvanceRejectsRetiredObserversAndInFlightRegistration() {
        let registry = AXCallbackGenerationRegistry()
        let retiredGeneration = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: retiredGeneration)

        let currentGeneration = registry.advance()
        var callbackCount = 0

        XCTAssertFalse(registry.isCurrent(retiredGeneration))
        XCTAssertTrue(registry.isCurrent(currentGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertNil(registry.reserveCallbackGeneration(serviceGeneration: retiredGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 0)
    }

    func testNewGenerationAcceptsReplacementObserver() {
        let registry = AXCallbackGenerationRegistry()
        let retiredGeneration = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: retiredGeneration)

        let currentGeneration = registry.advance()
        var callbackCount = 0

        registerObserver(2, in: registry, serviceGeneration: currentGeneration)
        XCTAssertNil(registry.reserveCallbackGeneration(serviceGeneration: retiredGeneration))
        XCTAssertTrue(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)
    }

    func testUnregisterRejectsObserverWithoutAdvancingGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: generation)

        registry.unregister(observerKey: 1)

        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
        XCTAssertTrue(registry.isCurrent(generation))
    }

    func testAdvanceWaitsForAdmittedCallbackToLeaveGate() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        registerObserver(1, in: registry, serviceGeneration: generation)

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let advanceStarted = DispatchSemaphore(value: 0)
        let advanceFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            registry.performIfCurrent(observerKey: 1) {
                callbackEntered.signal()
                releaseCallback.wait()
            }
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            advanceStarted.signal()
            registry.advance()
            advanceFinished.signal()
        }
        XCTAssertEqual(advanceStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(advanceFinished.wait(timeout: .now() + 0.05), .timedOut)

        releaseCallback.signal()

        XCTAssertEqual(advanceFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
    }

    func testContextIncarnationsReceiveDistinctCallbackGenerationsWithinOneServiceGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let first = registerObserver(1, in: registry, serviceGeneration: serviceGeneration)
        registry.unregister(observerKey: 1)
        let second = registerObserver(2, in: registry, serviceGeneration: serviceGeneration)

        XCTAssertGreaterThan(second, first)
        XCTAssertNil(registry.generation(observerKey: 1))
        XCTAssertEqual(registry.generation(observerKey: 2), second)
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
        XCTAssertTrue(registry.performIfCurrent(observerKey: 2) {})
    }

    func testRetiredElementOverflowFailsClosedUntilObserverIsRecreated() {
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let observerKey: UInt = 3
        let windowId = 740_001
        let pid: pid_t = 740_000

        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let liveElement = AXUIElementCreateApplication(pid)
            let subscriptions = ThreadGuardedValue([
                windowId: AppAXWindowSubscription(
                    windowId: windowId,
                    element: liveElement,
                    notifications: .lifecycle
                )
            ])
            defer {
                registry.unregister(observerKey: observerKey)
                subscriptions.destroy()
            }
            _ = registerObserver(
                observerKey,
                in: registry,
                serviceGeneration: serviceGeneration,
                windowSubscriptions: subscriptions
            )

            for offset in 0 ... AXCallbackGenerationRegistry.retiredWindowElementLimit {
                registry.retireWindowElement(
                    observerKey: observerKey,
                    element: AXUIElementCreateApplication(pid_t(741_000 + offset))
                )
            }
            XCTAssertFalse(
                registry.performIfCurrentWindowNotification(
                    observerKey: observerKey,
                    windowId: windowId,
                    element: liveElement,
                    notification: .destroyed
                ) {}
            )

            registry.unregister(observerKey: observerKey)
            _ = registerObserver(
                observerKey,
                in: registry,
                serviceGeneration: serviceGeneration,
                windowSubscriptions: subscriptions
            )
            XCTAssertTrue(
                registry.performIfCurrentWindowNotification(
                    observerKey: observerKey,
                    windowId: windowId,
                    element: liveElement,
                    notification: .destroyed
                ) {}
            )
        }
    }

    @discardableResult
    private func registerObserver(
        _ observerKey: UInt,
        in registry: AXCallbackGenerationRegistry,
        serviceGeneration: UInt64,
        windowSubscriptions: ThreadGuardedValue<[Int: AppAXWindowSubscription]>? = nil
    ) -> UInt64 {
        guard let callbackGeneration = registry.reserveCallbackGeneration(
            serviceGeneration: serviceGeneration
        ) else {
            XCTFail("Expected callback generation")
            return 0
        }
        XCTAssertTrue(
            registry.register(
                observerKey: observerKey,
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration,
                windowSubscriptions: windowSubscriptions
            )
        )
        return callbackGeneration
    }
}
