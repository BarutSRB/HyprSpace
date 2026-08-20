// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class AppAXNotificationRemovalTests: XCTestCase {
    func testPermanentRemovalFailureStopsAfterBoundedAttempts() throws {
        let element = AXUIElementCreateApplication(730_001)
        var abandoned: [AXUIElement] = []
        var pending = [
            AppAXPendingNotificationRemoval(element: element, notification: .destroyed)
        ]

        for expectedAttempts in UInt8(1) ... UInt8(2) {
            pending = try AppAXContext.retryPendingNotificationRemovals(
                pending,
                checkCancellation: {},
                removeNotification: { _, _ in .cannotComplete },
                recordAbandonedElement: { abandoned.append($0) }
            )
            XCTAssertEqual(pending.first?.attempts, expectedAttempts)
            XCTAssertTrue(abandoned.isEmpty)
        }
        pending = try AppAXContext.retryPendingNotificationRemovals(
            pending,
            checkCancellation: {},
            removeNotification: { _, _ in .cannotComplete },
            recordAbandonedElement: { abandoned.append($0) }
        )

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertTrue(CFEqual(abandoned[0], element))
    }

    func testInvalidElementRemovalIsNotRetried() throws {
        let pending = [
            AppAXPendingNotificationRemoval(
                element: AXUIElementCreateApplication(730_002),
                notification: .miniaturized
            )
        ]

        let remaining = try AppAXContext.retryPendingNotificationRemovals(
            pending,
            checkCancellation: {},
            removeNotification: { _, _ in .invalidUIElement }
        )

        XCTAssertTrue(remaining.isEmpty)
    }

    func testPendingRemovalCollectionRetainsOnlyNewestBoundedEntries() {
        let additions = (0 ... AppAXContext.pendingNotificationRemovalLimit).map { index in
            AppAXPendingNotificationRemoval(
                element: AXUIElementCreateApplication(pid_t(731_000 + index)),
                notification: .destroyed
            )
        }

        let pending = AppAXContext.mergePendingNotificationRemovals(additions, into: [])

        XCTAssertEqual(pending.count, AppAXContext.pendingNotificationRemovalLimit)
        XCTAssertFalse(CFEqual(pending[0].element, additions[0].element))
    }

    func testFailedRemovalRejectsLateCallbacksAfterWindowIdReuse() throws {
        let pid: pid_t = 732_000
        let observerKey: UInt = 73_200
        let windowId = 732_001
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let callbackGeneration = try XCTUnwrap(
            registry.reserveCallbackGeneration(serviceGeneration: serviceGeneration)
        )

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let retiredElement = AXUIElementCreateApplication(pid)
            let replacementElement = AXUIElementCreateApplication(pid + 1)
            let subscriptions = ThreadGuardedValue([
                windowId: AppAXWindowSubscription(
                    windowId: windowId,
                    element: replacementElement,
                    notifications: .lifecycle
                )
            ])
            defer {
                registry.unregister(observerKey: observerKey)
                subscriptions.destroy()
            }
            XCTAssertTrue(
                registry.register(
                    observerKey: observerKey,
                    serviceGeneration: serviceGeneration,
                    callbackGeneration: callbackGeneration,
                    windowSubscriptions: subscriptions
                )
            )

            var pending = [
                AppAXPendingNotificationRemoval(
                    element: retiredElement,
                    notification: .destroyed
                )
            ]
            for _ in 0 ..< Int(AppAXContext.pendingNotificationRemovalAttemptLimit) {
                pending = try AppAXContext.retryPendingNotificationRemovals(
                    pending,
                    checkCancellation: {},
                    removeNotification: { _, _ in .cannotComplete },
                    recordAbandonedElement: {
                        registry.retireWindowElement(observerKey: observerKey, element: $0)
                    }
                )
            }
            XCTAssertTrue(pending.isEmpty)

            var deliveredEvents = 0
            let refcon = try XCTUnwrap(AppAXContext.destroyNotificationRefcon(for: windowId))
            AppAXContext.handleWindowDestroyedCallback(
                pid: pid,
                element: retiredElement,
                observerKey: observerKey,
                callbackGeneration: callbackGeneration,
                refcon: refcon,
                registry: registry,
                postEvent: { _ in deliveredEvents += 1 }
            )
            AppAXContext.handleWindowMiniaturizedCallback(
                pid: pid,
                element: retiredElement,
                observerKey: observerKey,
                callbackGeneration: callbackGeneration,
                refcon: refcon,
                registry: registry,
                postEvent: { _ in deliveredEvents += 1 }
            )
            XCTAssertEqual(deliveredEvents, 0)
            XCTAssertFalse(
                registry.allowsWindowRegistration(
                    observerKey: observerKey,
                    element: retiredElement
                )
            )

            AppAXContext.handleWindowDestroyedCallback(
                pid: pid + 1,
                element: replacementElement,
                observerKey: observerKey,
                callbackGeneration: callbackGeneration,
                refcon: refcon,
                registry: registry,
                postEvent: { _ in deliveredEvents += 1 }
            )
            AppAXContext.handleWindowMiniaturizedCallback(
                pid: pid + 1,
                element: replacementElement,
                observerKey: observerKey,
                callbackGeneration: callbackGeneration,
                refcon: refcon,
                registry: registry,
                postEvent: { _ in deliveredEvents += 1 }
            )
            XCTAssertEqual(deliveredEvents, 2)
        }
    }
}
