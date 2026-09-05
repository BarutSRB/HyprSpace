// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

private let axBoundaryObserverCallback: AXObserverCallback = { _, _, _, _ in }

private func axBoundaryErrorValue(_ error: AXError) -> AXValue? {
    var error = error
    return AXValueCreate(.axError, &error)
}

private final class AXBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class AXBoundaryValueBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class AXBoundaryConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class AXRebindCacheBox: @unchecked Sendable {
    var windows: ThreadGuardedValue<[Int: AXUIElement]>?
    var subscriptions: ThreadGuardedValue<[Int: AppAXWindowSubscription]>?
}

private actor AXBoundaryAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        isOpen = true
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
final class AXFullRescanBoundaryTests: XCTestCase {
    func testNotificationInstallationOwnershipMatrix() throws {
        struct Scenario {
            let name: String
            let ownsLifecycle: Bool
            let addResults: [AXError]
            let hasSubscription: Bool
            let newlyInstalled: AppAXWindowNotificationSet
            let removed: [AppAXWindowNotification]
        }

        let windowId = 71_001
        let element = AXUIElementCreateApplication(71_002)
        let scenarios = [
            Scenario(
                name: "exact owned",
                ownsLifecycle: true,
                addResults: [],
                hasSubscription: true,
                newlyInstalled: [],
                removed: []
            ),
            Scenario(
                name: "adopt existing",
                ownsLifecycle: false,
                addResults: [.notificationAlreadyRegistered, .notificationAlreadyRegistered],
                hasSubscription: true,
                newlyInstalled: [],
                removed: []
            ),
            Scenario(
                name: "preserve adopted bit on later failure",
                ownsLifecycle: false,
                addResults: [.notificationAlreadyRegistered, .cannotComplete],
                hasSubscription: false,
                newlyInstalled: [],
                removed: []
            ),
            Scenario(
                name: "rollback only newly installed bit",
                ownsLifecycle: false,
                addResults: [.success, .cannotComplete],
                hasSubscription: false,
                newlyInstalled: [],
                removed: [.destroyed]
            ),
            Scenario(
                name: "install exact refcon",
                ownsLifecycle: false,
                addResults: [.success, .success],
                hasSubscription: true,
                newlyInstalled: .lifecycle,
                removed: []
            )
        ]

        for scenario in scenarios {
            var addIndex = 0
            var refconWindowIds: [Int?] = []
            var removed: [AppAXWindowNotification] = []
            let owned = scenario.ownsLifecycle
                ? AppAXWindowSubscription(
                    windowId: windowId,
                    element: element,
                    notifications: .lifecycle
                )
                : nil

            let result = try AppAXContext.installWindowNotifications(
                element: element,
                windowId: windowId,
                ownedSubscription: owned,
                addNotification: { _, refcon in
                    refconWindowIds.append(AppAXContext.destroyNotificationWindowId(from: refcon))
                    guard addIndex < scenario.addResults.count else {
                        XCTFail("Unexpected add for \(scenario.name)")
                        return .failure
                    }
                    defer { addIndex += 1 }
                    return scenario.addResults[addIndex]
                },
                removeNotification: {
                    removed.append($0)
                    return .success
                }
            )

            XCTAssertEqual(result.subscription != nil, scenario.hasSubscription, scenario.name)
            XCTAssertEqual(result.subscription?.windowId, scenario.hasSubscription ? windowId : nil, scenario.name)
            XCTAssertEqual(
                result.subscription?.notifications,
                scenario.hasSubscription ? .lifecycle : nil,
                scenario.name
            )
            XCTAssertEqual(result.newlyInstalled, scenario.newlyInstalled, scenario.name)
            XCTAssertEqual(refconWindowIds, Array(repeating: windowId, count: scenario.addResults.count), scenario.name)
            XCTAssertEqual(removed, scenario.removed, scenario.name)
            XCTAssertTrue(result.pendingRemovals.isEmpty, scenario.name)
        }
    }

    func testReplacementRemovalFailureFlowsThroughPendingLedgerAndRetry() throws {
        let element = AXUIElementCreateApplication(71_003)
        let oldWindowId = 71_004
        let newWindowId = 71_005
        var registrations = Dictionary(
            uniqueKeysWithValues: AppAXWindowNotification.allCases.map { ($0, oldWindowId) }
        )
        var removalFails = true
        let addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError = {
            notification,
            refcon in
            guard registrations[notification] == nil else { return .notificationAlreadyRegistered }
            registrations[notification] = AppAXContext.destroyNotificationWindowId(from: refcon)
            return .success
        }
        let removeNotification: (AppAXWindowNotification) -> AXError = { notification in
            guard !removalFails else { return .cannotComplete }
            registrations[notification] = nil
            return .success
        }

        let failed = try AppAXContext.installWindowNotifications(
            element: element,
            windowId: newWindowId,
            ownedSubscription: nil,
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: .replace
        )

        XCTAssertNil(failed.subscription)
        XCTAssertEqual(failed.pendingRemovals.map(\.notification), [.destroyed])
        XCTAssertTrue(failed.pendingRemovals.first.map {
            CFEqual($0.element, element)
        } == true)
        XCTAssertEqual(registrations[.destroyed], oldWindowId)

        removalFails = false
        for pending in failed.pendingRemovals {
            XCTAssertEqual(removeNotification(pending.notification), .success)
        }
        let retried = try AppAXContext.installWindowNotifications(
            element: element,
            windowId: newWindowId,
            ownedSubscription: nil,
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: .replace
        )

        XCTAssertEqual(retried.subscription?.windowId, newWindowId)
        XCTAssertEqual(retried.subscription?.notifications, .lifecycle)
        XCTAssertEqual(registrations[.destroyed], newWindowId)
        XCTAssertEqual(registrations[.miniaturized], newWindowId)
    }

    func testRebindStageRejectsCrossIdAlreadyRegisteredCallbacksWithoutDeletingOwner() throws {
        let element = AXUIElementCreateApplication(71_036)
        let firstWindowId = 71_037
        let secondWindowId = 71_038
        var registrations: [AppAXWindowNotification: Int] = [:]
        var removed: [AppAXWindowNotification] = []
        let addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError = {
            notification,
            refcon in
            guard registrations[notification] == nil else {
                return .notificationAlreadyRegistered
            }
            registrations[notification] = AppAXContext.destroyNotificationWindowId(from: refcon)
            return .success
        }
        let removeNotification: (AppAXWindowNotification) -> AXError = { notification in
            removed.append(notification)
            registrations[notification] = nil
            return .success
        }

        let first = try AppAXContext.installWindowNotifications(
            element: element,
            windowId: firstWindowId,
            ownedSubscription: nil,
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: .reject
        )
        let second = try AppAXContext.installWindowNotifications(
            element: element,
            windowId: secondWindowId,
            ownedSubscription: nil,
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: .reject
        )

        XCTAssertEqual(first.subscription?.windowId, firstWindowId)
        XCTAssertEqual(first.newlyInstalled, .lifecycle)
        XCTAssertNil(second.subscription)
        XCTAssertEqual(second.newlyInstalled, [])
        XCTAssertTrue(second.pendingRemovals.isEmpty)
        XCTAssertEqual(registrations[.destroyed], firstWindowId)
        XCTAssertEqual(registrations[.miniaturized], firstWindowId)
        XCTAssertTrue(removed.isEmpty)

        guard let firstSubscription = first.subscription else {
            return XCTFail("Expected initial subscription")
        }
        XCTAssertTrue(
            AppAXContext.removeOwnedWindowNotifications(
                firstSubscription,
                removeNotification: removeNotification
            ).isEmpty
        )
        let retry = try AppAXContext.installWindowNotifications(
            element: element,
            windowId: secondWindowId,
            ownedSubscription: nil,
            addNotification: addNotification,
            removeNotification: removeNotification,
            alreadyRegisteredPolicy: .reject
        )
        XCTAssertEqual(retry.subscription?.windowId, secondWindowId)
        XCTAssertEqual(retry.newlyInstalled, .lifecycle)
        XCTAssertEqual(registrations[.destroyed], secondWindowId)
        XCTAssertEqual(registrations[.miniaturized], secondWindowId)
    }

    func testRebindRetagRequiresExactSourceOwnerAndClearsSourceAlias() throws {
        let pid: pid_t = 71_066
        let oldWindow = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_067)
        let newWindow = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_068)
        let sourceSubscription = AppAXWindowSubscription(
            windowId: oldWindow.windowId,
            element: newWindow.element,
            notifications: .lifecycle
        )
        let unrelatedSubscription = AppAXWindowSubscription(
            windowId: 71_069,
            element: newWindow.element,
            notifications: .lifecycle
        )

        XCTAssertEqual(
            AppAXContext.rebindSubscriptionOwnership(
                sourceSubscription,
                oldWindowId: oldWindow.windowId,
                newWindowId: newWindow.windowId
            ),
            .source
        )
        XCTAssertEqual(
            AppAXContext.rebindSubscriptionOwnership(
                unrelatedSubscription,
                oldWindowId: oldWindow.windowId,
                newWindowId: newWindow.windowId
            ),
            .conflict
        )

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([oldWindow.windowId: newWindow.element])
            let subscriptions = ThreadGuardedValue([Int: AppAXWindowSubscription]())
            defer {
                windows.destroy()
                subscriptions.destroy()
            }
            let destinationSubscription = AppAXWindowSubscription(
                windowId: newWindow.windowId,
                element: newWindow.element,
                notifications: .lifecycle
            )
            let cleanup = try AppAXContext.commitWindowRebindCache(
                oldWindow: oldWindow,
                newWindow: newWindow,
                destinationSubscription: destinationSubscription,
                retireOldWindowState: true,
                binding: AppAXWindowRebindBinding(
                    destinationWindowElement: nil,
                    destinationSubscription: nil,
                    stagedSubscription: destinationSubscription,
                    newlyInstalledNotifications: .lifecycle,
                    requiresRetag: true,
                    hasLifecycleObserver: true
                ),
                windows: windows,
                subscribedWindows: subscriptions,
                job: RunLoopJob()
            )

            XCTAssertTrue(cleanup.subscriptions.isEmpty)
            XCTAssertNil(windows[oldWindow.windowId])
            XCTAssertTrue(windows[newWindow.windowId].map {
                CFEqual($0, newWindow.element)
            } == true)
        }
    }

    func testCancellationAfterFirstNotificationRetainsFailedRollback() {
        let windowId = 71_010
        let element = AXUIElementCreateApplication(71_011)
        var cancellationChecks = 0
        var added: [AppAXWindowNotification] = []
        var removed: [AppAXWindowNotification] = []
        var pending: [AppAXPendingNotificationRemoval] = []

        XCTAssertThrowsError(
            try AppAXContext.installWindowNotifications(
                element: element,
                windowId: windowId,
                ownedSubscription: nil,
                addNotification: { notification, _ in
                    added.append(notification)
                    return .success
                },
                removeNotification: { notification in
                    removed.append(notification)
                    return .cannotComplete
                },
                checkCancellation: {
                    cancellationChecks += 1
                    if cancellationChecks == 2 {
                        throw CancellationError()
                    }
                },
                recordPendingRemovals: { pending.append(contentsOf: $0) }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(added, [.destroyed])
        XCTAssertEqual(removed, [.destroyed])
        XCTAssertEqual(pending.map(\.notification), [.destroyed])
        XCTAssertTrue(pending.first.map { CFEqual($0.element, element) } == true)
    }

    func testAuthoritativeBindingPrunesOrphanStateAndPreservesExactWorldTarget() throws {
        let pid: pid_t = getpid()
        let exactWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 71_015
        )
        let orphanWindow = AXWindowRef(
            element: AXUIElementCreateApplication(.max),
            windowId: 71_016
        )
        let exactSubscription = AppAXWindowSubscription(
            windowId: exactWindow.windowId,
            element: exactWindow.element,
            notifications: .lifecycle
        )
        let orphanSubscription = AppAXWindowSubscription(
            windowId: orphanWindow.windowId,
            element: orphanWindow.element,
            notifications: .lifecycle
        )
        var observerStorage: AXObserver?
        XCTAssertEqual(AXObserverCreate(pid, axBoundaryObserverCallback, &observerStorage), .success)
        let createdObserver = try XCTUnwrap(observerStorage)

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([
                exactWindow.windowId: exactWindow.element,
                orphanWindow.windowId: orphanWindow.element
            ])
            let subscriptions = ThreadGuardedValue([
                exactWindow.windowId: exactSubscription,
                orphanWindow.windowId: orphanSubscription
            ])
            let pending = ThreadGuardedValue([
                AppAXPendingNotificationRemoval(
                    element: orphanWindow.element,
                    notification: .destroyed
                )
            ])
            let observer = ThreadGuardedValue<AXObserver?>(createdObserver)
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
                observer.destroy()
            }
            let epoch = LockedGenerationEpoch()

            let result = try AppAXContext.performWindowBinding(
                [exactWindow.windowId: exactWindow],
                bindingGeneration: epoch.advance(),
                pruningUnboundState: true,
                timeoutSeconds: 0,
                windows: windows,
                windowBindingEpoch: epoch,
                axObserver: observer,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                job: RunLoopJob()
            )

            XCTAssertEqual(result, .retryRequired)
            XCTAssertTrue(windows[exactWindow.windowId].map {
                CFEqual($0, exactWindow.element)
            } == true)
            XCTAssertTrue(subscriptions[exactWindow.windowId].map {
                CFEqual($0.element, exactWindow.element)
            } == true)
            XCTAssertNil(windows[orphanWindow.windowId])
            XCTAssertNil(subscriptions[orphanWindow.windowId])
            XCTAssertEqual(pending.value.map(\.notification), [.miniaturized])
            XCTAssertTrue(pending.value.allSatisfy {
                CFEqual($0.element, orphanWindow.element)
            })
        }
    }

    func testIncrementalBindingDoesNotPruneUnrelatedObservedState() throws {
        let pid: pid_t = 71_017
        let target = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_018)
        let observed = AXWindowRef(element: AXUIElementCreateApplication(pid + 1), windowId: 71_019)
        let staleTargetObservation = AXUIElementCreateApplication(pid + 2)

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([
                observed.windowId: observed.element,
                target.windowId: staleTargetObservation
            ])
            let subscriptions = ThreadGuardedValue([
                observed.windowId: AppAXWindowSubscription(
                    windowId: observed.windowId,
                    element: observed.element,
                    notifications: .lifecycle
                )
            ])
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            let observer = ThreadGuardedValue<AXObserver?>(nil)
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
                observer.destroy()
            }
            let epoch = LockedGenerationEpoch()

            let result = try AppAXContext.performWindowBinding(
                [target.windowId: target],
                bindingGeneration: epoch.advance(),
                pruningUnboundState: false,
                timeoutSeconds: 0,
                windows: windows,
                windowBindingEpoch: epoch,
                axObserver: observer,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                job: RunLoopJob()
            )

            XCTAssertEqual(result, .bound)
            XCTAssertTrue(windows[observed.windowId].map { CFEqual($0, observed.element) } == true)
            XCTAssertNotNil(subscriptions[observed.windowId])
            XCTAssertTrue(windows[target.windowId].map { CFEqual($0, target.element) } == true)
        }
    }

    func testStaleEnumerationPublishDoesNotCancelNewerWorldBinding() throws {
        let pid: pid_t = 71_062
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_063)
        let observation = AXUIElementCreateApplication(pid + 1)

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([Int: AXUIElement]())
            let subscriptions = ThreadGuardedValue([Int: AppAXWindowSubscription]())
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            let observer = ThreadGuardedValue<AXObserver?>(nil)
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
                observer.destroy()
            }
            let epoch = LockedGenerationEpoch()
            let enumerationGeneration = epoch.current()
            let bindingGeneration = epoch.advance()

            XCTAssertFalse(
                AppAXContext.replaceEnumeratedWindowCache(
                    with: [window.windowId: observation],
                    windows: windows,
                    bindingGeneration: enumerationGeneration,
                    windowBindingEpoch: epoch
                )
            )
            let result = try AppAXContext.performWindowBinding(
                [window.windowId: window],
                bindingGeneration: bindingGeneration,
                pruningUnboundState: false,
                timeoutSeconds: 0,
                windows: windows,
                windowBindingEpoch: epoch,
                axObserver: observer,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                job: RunLoopJob()
            )

            XCTAssertEqual(result, .bound)
            XCTAssertTrue(epoch.isCurrent(bindingGeneration))
            XCTAssertTrue(windows[window.windowId].map { CFEqual($0, window.element) } == true)
        }
    }

    func testDuplicateEnumerationWindowIdKeepsOnlyFinalElement() {
        let windowId = 71_016
        let firstElement = AXUIElementCreateApplication(71_017)
        let finalElement = AXUIElementCreateApplication(71_018)
        let geometry = WindowAdmissionGeometryEvidence(
            isSizeSettable: true,
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )
        var windows: [AXEnumeratedWindow] = []
        AppAXContext.recordFinalEnumeratedWindow(
            AXEnumeratedWindow(
                axRef: AXWindowRef(element: firstElement, windowId: windowId),
                axPid: 71_017,
                role: nil,
                subrole: nil,
                admissionGeometry: geometry
            ),
            in: &windows,
            isFirstOccurrence: true
        )
        AppAXContext.recordFinalEnumeratedWindow(
            AXEnumeratedWindow(
                axRef: AXWindowRef(element: finalElement, windowId: windowId),
                axPid: 71_018,
                role: nil,
                subrole: nil,
                admissionGeometry: geometry
            ),
            in: &windows,
            isFirstOccurrence: false
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.axPid, 71_018)
        XCTAssertTrue(windows.first.map { CFEqual($0.axRef.element, finalElement) } == true)
    }

    func testFrameGenerationCannotABAAfterRemovalAndReuse() {
        let generations = LockedWindowGenerationMap()
        let windowId = 71_024
        let first = generations.nextGeneration(for: windowId)
        generations.invalidateAndRemove(windowId)
        let replacement = generations.nextGeneration(for: windowId)

        XCTAssertNotEqual(first, replacement)
        XCTAssertFalse(generations.isCurrent(first, for: windowId))
        XCTAssertTrue(generations.isCurrent(replacement, for: windowId))
    }

    func testAuthoritativeFrameStateRetentionPrunesOnlyOrphans() {
        let generations = LockedWindowGenerationMap()
        let suppression = LockedWindowIdSet()
        let retainedWindowId = 71_064
        let orphanWindowId = 71_065
        let retainedGeneration = generations.nextGeneration(for: retainedWindowId)
        let orphanGeneration = generations.nextGeneration(for: orphanWindowId)
        suppression.insert(retainedWindowId)
        suppression.insert(orphanWindowId)

        generations.retainOnly([retainedWindowId])
        suppression.retainOnly([retainedWindowId])
        let replacementGeneration = generations.nextGeneration(for: orphanWindowId)

        XCTAssertTrue(generations.isCurrent(retainedGeneration, for: retainedWindowId))
        XCTAssertFalse(generations.isCurrent(orphanGeneration, for: orphanWindowId))
        XCTAssertNotEqual(orphanGeneration, replacementGeneration)
        XCTAssertTrue(generations.isCurrent(replacementGeneration, for: orphanWindowId))
        XCTAssertTrue(suppression.contains(retainedWindowId))
        XCTAssertFalse(suppression.contains(orphanWindowId))
    }

    func testRefreshedDifferentElementInvalidatesFrameRequest() {
        let generations = LockedWindowGenerationMap()
        let windowId = 71_025
        let cachedElement = AXUIElementCreateApplication(71_026)
        let replacementElement = AXUIElementCreateApplication(71_027)
        let requestGeneration = generations.nextGeneration(for: windowId)

        XCTAssertFalse(
            AppAXContext.acceptsRefreshedFrameElement(
                cachedElement: cachedElement,
                refreshedElement: replacementElement,
                windowId: windowId,
                requestGeneration: requestGeneration,
                generations: generations
            )
        )
        XCTAssertFalse(generations.isCurrent(requestGeneration, for: windowId))
    }

    func testRefreshedSameElementKeepsFrameRequestCurrent() {
        let generations = LockedWindowGenerationMap()
        let windowId = 71_028
        let element = AXUIElementCreateApplication(71_029)
        let requestGeneration = generations.nextGeneration(for: windowId)

        XCTAssertTrue(
            AppAXContext.acceptsRefreshedFrameElement(
                cachedElement: element,
                refreshedElement: element,
                windowId: windowId,
                requestGeneration: requestGeneration,
                generations: generations
            )
        )
        XCTAssertTrue(generations.isCurrent(requestGeneration, for: windowId))
    }

    func testFrameWriteUsesExpectedElementWithoutAppCacheEntry() {
        let pid: pid_t = 71_031
        let windowId = 71_032
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let target = CGRect(x: 10, y: 20, width: 640, height: 480)
        let generations = LockedWindowGenerationMap()
        let generation = generations.nextGeneration(for: windowId)
        let request = AppAXFrameWriteRequest(
            requestId: 1,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            frame: target,
            currentFrameHint: nil,
            generation: generation,
            verify: true
        )
        var writtenElements: [AXUIElement] = []
        var refreshed = false

        let result = applyFrameWriteRequest(
            request,
            pid: pid,
            generations: generations,
            writeFrame: { window, frame, _, components, _ in
                writtenElements.append(window.element)
                return AXFrameWriteResult(
                    observedFrame: frame,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: components
                )
            },
            refreshWindow: { _, _ in
                refreshed = true
                return nil
            }
        )

        XCTAssertNil(result.writeResult.failureReason)
        XCTAssertEqual(writtenElements.count, 1)
        XCTAssertTrue(writtenElements.first.map { CFEqual($0, expectedWindow.element) } == true)
        XCTAssertFalse(refreshed)
    }

    func testFrameRefreshMismatchNeverWritesReplacementElement() {
        let pid: pid_t = 71_033
        let windowId = 71_034
        let expectedWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let replacementWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )
        let target = CGRect(x: 10, y: 20, width: 640, height: 480)
        let generations = LockedWindowGenerationMap()
        let generation = generations.nextGeneration(for: windowId)
        let request = AppAXFrameWriteRequest(
            requestId: 2,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            frame: target,
            currentFrameHint: nil,
            generation: generation,
            verify: true
        )
        var writtenElements: [AXUIElement] = []

        let result = applyFrameWriteRequest(
            request,
            pid: pid,
            generations: generations,
            writeFrame: { window, frame, hint, components, _ in
                writtenElements.append(window.element)
                return .skipped(
                    targetFrame: frame,
                    currentFrameHint: hint,
                    failureReason: .staleElement,
                    components: components
                )
            },
            refreshWindow: { _, _ in replacementWindow }
        )

        XCTAssertEqual(result.writeResult.failureReason, .cancelled)
        XCTAssertEqual(writtenElements.count, 1)
        XCTAssertTrue(writtenElements.first.map { CFEqual($0, expectedWindow.element) } == true)
        XCTAssertFalse(writtenElements.contains { CFEqual($0, replacementWindow.element) })
        XCTAssertFalse(generations.isCurrent(generation, for: windowId))
    }

    func testFrameWriteRequestForwardsExplicitComponents() {
        let pid: pid_t = 71_035
        let windowId = 71_036
        let window = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let generations = LockedWindowGenerationMap()
        let request = AppAXFrameWriteRequest(
            requestId: 3,
            pid: pid,
            windowId: windowId,
            expectedWindow: window,
            frame: CGRect(x: 20, y: 30, width: 640, height: 480),
            currentFrameHint: nil,
            components: .position,
            generation: generations.nextGeneration(for: windowId),
            verify: false
        )
        var receivedComponents: AXFrameComponents = []

        let result = applyFrameWriteRequest(
            request,
            pid: pid,
            generations: generations,
            writeFrame: { _, frame, _, components, _ in
                receivedComponents = components
                return AXFrameWriteResult(
                    observedFrame: nil,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil,
                    components: components
                )
            }
        )

        XCTAssertEqual(receivedComponents, .position)
        XCTAssertEqual(result.writeResult.components, .position)
    }

    func testRapidBindingSupersessionReturnsSupersededWithoutPublishing() throws {
        let pid: pid_t = 71_058
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_059)

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([Int: AXUIElement]())
            let subscriptions = ThreadGuardedValue([Int: AppAXWindowSubscription]())
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            let observer = ThreadGuardedValue<AXObserver?>(nil)
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
                observer.destroy()
            }
            let epoch = LockedGenerationEpoch()
            let staleGeneration = epoch.advance()
            _ = epoch.advance()

            let result = try AppAXContext.performWindowBinding(
                [window.windowId: window],
                bindingGeneration: staleGeneration,
                pruningUnboundState: false,
                timeoutSeconds: 0,
                windows: windows,
                windowBindingEpoch: epoch,
                axObserver: observer,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                job: RunLoopJob()
            )

            XCTAssertEqual(result, .superseded)
            XCTAssertTrue(windows.value.isEmpty)
            XCTAssertTrue(subscriptions.value.isEmpty)
        }
    }

    func testCrossIdentityBindingReturnsSupersededAndPreservesPublishedOwner() throws {
        let pid: pid_t = getpid()
        let oldWindowId = 71_060
        let newWindow = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 71_061)
        let oldSubscription = AppAXWindowSubscription(
            windowId: oldWindowId,
            element: newWindow.element,
            notifications: .lifecycle
        )
        var observerStorage: AXObserver?
        XCTAssertEqual(AXObserverCreate(pid, axBoundaryObserverCallback, &observerStorage), .success)
        let createdObserver = try XCTUnwrap(observerStorage)

        try $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([newWindow.windowId: newWindow.element])
            let subscriptions = ThreadGuardedValue([oldWindowId: oldSubscription])
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            let observer = ThreadGuardedValue<AXObserver?>(createdObserver)
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
                observer.destroy()
            }
            let epoch = LockedGenerationEpoch()

            let result = try AppAXContext.performWindowBinding(
                [newWindow.windowId: newWindow],
                bindingGeneration: epoch.advance(),
                pruningUnboundState: false,
                timeoutSeconds: 0,
                windows: windows,
                windowBindingEpoch: epoch,
                axObserver: observer,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                job: RunLoopJob()
            )

            XCTAssertEqual(result, .superseded)
            XCTAssertTrue(subscriptions[oldWindowId].map {
                CFEqual($0.element, newWindow.element)
            } == true)
            XCTAssertNil(subscriptions[newWindow.windowId])
        }
    }

    func testExactRemovalPreservesInterposedSameIdIncarnation() {
        let pid: pid_t = 71_049
        let windowId = 71_050
        let retired = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let interposed = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )

        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([windowId: interposed.element])
            let subscription = AppAXWindowSubscription(
                windowId: windowId,
                element: interposed.element,
                notifications: .lifecycle
            )
            let subscriptions = ThreadGuardedValue([windowId: subscription])
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
            }

            let outcome = AppAXContext.removeExactWindowState(
                expectedWindow: retired,
                windows: windows,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                observerKey: nil
            )

            XCTAssertFalse(outcome.removedCachedWindow)
            XCTAssertFalse(outcome.removedSubscription)
            XCTAssertTrue(windows[windowId].map { CFEqual($0, interposed.element) } == true)
            XCTAssertTrue(subscriptions[windowId].map { CFEqual($0.element, interposed.element) } == true)
            XCTAssertTrue(pending.value.isEmpty)
        }
    }

    func testExactRemovalDistinguishesSubscriptionOnlyDivergence() {
        let pid: pid_t = 71_051
        let windowId = 71_052
        let cached = AXUIElementCreateApplication(pid)
        let subscribed = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )

        $appThreadToken.withValue(AppThreadToken(pid: pid)) {
            let windows = ThreadGuardedValue([windowId: cached])
            let subscription = AppAXWindowSubscription(
                windowId: windowId,
                element: subscribed.element,
                notifications: .lifecycle
            )
            let subscriptions = ThreadGuardedValue([windowId: subscription])
            let pending = ThreadGuardedValue([AppAXPendingNotificationRemoval]())
            defer {
                windows.destroy()
                subscriptions.destroy()
                pending.destroy()
            }

            let outcome = AppAXContext.removeExactWindowState(
                expectedWindow: subscribed,
                windows: windows,
                subscribedWindows: subscriptions,
                pendingNotificationRemovals: pending,
                observerKey: nil
            )

            XCTAssertFalse(outcome.removedCachedWindow)
            XCTAssertTrue(outcome.removedSubscription)
            XCTAssertTrue(windows[windowId].map { CFEqual($0, cached) } == true)
            XCTAssertNil(subscriptions[windowId])
            XCTAssertEqual(Set(pending.value.map(\.notification)), Set(AppAXWindowNotification.allCases))
        }
    }

    func testFullRescanRoutesEvidenceAndPreservedStateToPersistentContexts() {
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .regular,
                hasDiscoveryEvidence: true,
                hasContext: false,
                hasPreservedState: false
            ),
            .persistent
        )
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: true,
                hasPreservedState: false
            ),
            .persistent
        )
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: true
            ),
            .persistent
        )
    }

    func testFullRescanRoutesOnlyEvidenceFreeRegularAppsToOneShotProbes() {
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .regular,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: false
            ),
            .oneShot
        )
        XCTAssertNil(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: false
            )
        )
        XCTAssertNil(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .prohibited,
                hasDiscoveryEvidence: true,
                hasContext: true,
                hasPreservedState: true
            )
        )
    }

    func testCandidateManageabilityUsesCapturedGeometryEvidence() {
        let pid: pid_t = 72_001
        let windowId = 72_002
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .oneShot
        )

        XCTAssertTrue(candidate.isManageable)
    }

    func testCandidateFullscreenUsesCapturedEvidenceWithoutLiveAXFallback() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let explicitWindowed = candidate(
            pid: 72_013,
            windowId: 72_014,
            route: .persistent,
            isManageable: true,
            frame: screenFrame,
            fullscreenAttribute: false
        )
        let frameFallback = candidate(
            pid: 72_015,
            windowId: 72_016,
            route: .persistent,
            isManageable: true,
            frame: screenFrame,
            fullscreenAttribute: nil
        )

        XCTAssertFalse(explicitWindowed.isFullscreen(screenFrames: [screenFrame]))
        XCTAssertTrue(frameFallback.isFullscreen(screenFrames: [screenFrame]))
    }

    func testCandidateCapturedFramePrefersWindowServerEvidence() {
        let pid: pid_t = 72_019
        let axFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let windowServerFrame = CGRect(x: 30, y: 40, width: 900, height: 700)
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: 72_020
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: axFrame
                )
            ),
            logicalPID: pid,
            windowServerInfo: WindowServerInfo(
                id: 72_020,
                pid: pid,
                level: 0,
                frame: windowServerFrame
            ),
            windowServerOwnerPID: pid,
            enumerationRoute: .persistent
        )

        XCTAssertEqual(candidate.capturedFrame, windowServerFrame)
    }

    func testCapturedDecisionEvidenceEvaluatesWithoutAXReference() {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 72_021, windowId: 72_022)
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: .zero,
            isFixed: false
        )
        let evidence = AXWindowDecisionEvidence(
            facts: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: nil,
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "example.full-rescan",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: constraints
        )
        let windowInfo = WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: CGRect(x: 20, y: 30, width: 800, height: 600)
        )
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: windowInfo,
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: true,
                frame: windowInfo.frame
            )
        )

        XCTAssertEqual(evaluation.decision.disposition, .managed)
        XCTAssertEqual(evaluation.facts.sizeConstraints, constraints)
        XCTAssertEqual(evaluation.facts.windowServer, windowInfo)
        XCTAssertNil(controller.workspaceManager.cachedConstraints(for: token))
    }

    func testCapturedParentedEvidenceNeverUsesLiveWindowServerProvider() {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 86_312, windowId: 7_916)
        let evidence = AXWindowDecisionEvidence(
            facts: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXUnknownSubrole as String,
                title: "Extension",
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: false,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.google.Chrome",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: WindowSizeConstraints(
                minSize: CGSize(width: 100, height: 100),
                maxSize: .zero,
                isFixed: false
            )
        )
        let geometry = WindowAdmissionGeometryEvidence(
            isSizeSettable: true,
            frame: CGRect(x: 2_128, y: 126, width: 320, height: 425)
        )
        let exactWindowInfo = WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: geometry.frame ?? .zero,
            tags: 5_369_504_898,
            attributes: 3,
            parentId: 7_905
        )
        var queryCount = 0
        controller.axEventHandler.windowInfoProvider = { _ in
            queryCount += 1
            return exactWindowInfo
        }

        let missing = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: nil,
            admissionGeometry: geometry
        )
        let mismatched = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: WindowServerInfo(
                id: exactWindowInfo.id + 1,
                pid: exactWindowInfo.pid,
                level: 0,
                frame: exactWindowInfo.frame,
                tags: exactWindowInfo.tags,
                attributes: exactWindowInfo.attributes,
                parentId: exactWindowInfo.parentId
            ),
            admissionGeometry: geometry
        )
        let exact = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: exactWindowInfo,
            admissionGeometry: geometry
        )

        XCTAssertEqual(missing.decision.disposition, .undecided)
        XCTAssertEqual(missing.decision.deferredReason, .windowServerEvidenceMissing)
        XCTAssertEqual(mismatched.decision.disposition, .undecided)
        XCTAssertEqual(mismatched.decision.deferredReason, .windowServerEvidenceMissing)
        XCTAssertEqual(exact.decision.disposition, .unmanaged)
        XCTAssertEqual(queryCount, 0)
    }

    func testCapturedHelpTagEvidenceNeedsNoWindowServerLookupOrDeferral() {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 86_312, windowId: 7_918)
        let evidence = AXWindowDecisionEvidence(
            facts: AXWindowFacts(
                role: kAXHelpTagRole as String,
                subrole: kAXUnknownSubrole as String,
                title: nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: false,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: "com.google.Chrome",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: WindowSizeConstraints(
                minSize: CGSize(width: 100, height: 100),
                maxSize: .zero,
                isFixed: false
            )
        )
        let geometry = WindowAdmissionGeometryEvidence(
            isSizeSettable: true,
            frame: CGRect(x: 1_287, y: 1_403, width: 118, height: 22)
        )
        var queryCount = 0
        controller.axEventHandler.windowInfoProvider = { _ in
            queryCount += 1
            return WindowServerInfo(
                id: UInt32(token.windowId),
                pid: token.pid,
                level: 0,
                frame: geometry.frame ?? .zero,
                tags: 5_369_504_386,
                attributes: 3,
                parentId: 7_905
            )
        }

        let missing = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: nil,
            admissionGeometry: geometry
        )
        let mismatched = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: WindowServerInfo(
                id: UInt32(token.windowId + 1),
                pid: token.pid + 1,
                level: 7,
                frame: .zero,
                tags: UInt64.max,
                attributes: UInt32.max,
                parentId: 0
            ),
            admissionGeometry: geometry
        )

        for evaluation in [missing, mismatched] {
            XCTAssertEqual(evaluation.decision.disposition, .unmanaged)
            XCTAssertEqual(
                evaluation.decision.source,
                .builtInRule(WindowRuleEngine.externalSurfaceRuleName)
            )
            XCTAssertNil(evaluation.decision.deferredReason)
        }
        XCTAssertEqual(queryCount, 0)
    }

    func testFullscreenButtonEvidenceTreatsMissingSentinelsAsAbsent() throws {
        let noValue = try XCTUnwrap(axBoundaryErrorValue(.noValue))
        let unsupported = try XCTUnwrap(axBoundaryErrorValue(.attributeUnsupported))
        let values: [Any?] = [nil, kCFNull, NSNull(), noValue, unsupported]

        for value in values {
            guard case .absent = AXWindowService.fullscreenButtonEvidence(value) else {
                XCTFail("Expected absent fullscreen-button evidence")
                continue
            }
            XCTAssertFalse(AXWindowService.resolvedAttribute(value))
        }
    }

    func testConstraintBatchTreatsMissingSentinelsAsAbsent() throws {
        let noValue = try XCTUnwrap(axBoundaryErrorValue(.noValue))
        let values = [
            kCFNull as CFTypeRef,
            noValue as CFTypeRef,
            kAXDialogSubrole as CFTypeRef,
            kCFNull as CFTypeRef,
            kCFNull as CFTypeRef
        ] as CFArray
        let currentSize = CGSize(width: 420, height: 280)

        let inputs = AXWindowService.sizeConstraintInputs(from: values, currentSize: currentSize)

        XCTAssertFalse(inputs.hasGrowArea)
        XCTAssertFalse(inputs.hasZoomButton)
        XCTAssertEqual(inputs.subrole, kAXDialogSubrole as String)
        XCTAssertNil(inputs.minSize)
        XCTAssertNil(inputs.maxSize)
        XCTAssertEqual(AXWindowService.resolvedSizeConstraints(inputs), .fixed(size: currentSize))
    }

    func testFullscreenButtonEvidencePreservesFailures() throws {
        var point = CGPoint(x: 10, y: 20)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let values: [Any] = [
            try XCTUnwrap(axBoundaryErrorValue(.cannotComplete)),
            try XCTUnwrap(axBoundaryErrorValue(.invalidUIElement)),
            try XCTUnwrap(axBoundaryErrorValue(.failure)),
            pointValue,
            "unexpected"
        ]

        for value in values {
            let evidence = AXWindowService.fullscreenButtonEvidence(value)
            guard case .failed = evidence else {
                XCTFail("Expected failed fullscreen-button evidence")
                continue
            }
            XCTAssertFalse(evidence.succeeded)
            XCTAssertFalse(AXWindowService.resolvedAttribute(value))
        }
    }

    func testFullscreenButtonEvidenceAcceptsOnlyAXUIElement() {
        let element = AXUIElementCreateApplication(72_035)
        let evidence = AXWindowService.fullscreenButtonEvidence(element)

        guard case let .present(resolvedElement) = evidence else {
            return XCTFail("Expected present fullscreen-button evidence")
        }
        XCTAssertTrue(CFEqual(element, resolvedElement))
        XCTAssertTrue(evidence.succeeded)
        XCTAssertTrue(AXWindowService.resolvedAttribute(element))
    }

    func testMissingFullscreenButtonErrorWrapperClassifiesActivityMonitorShapeAsFloating() throws {
        let missingButton = try XCTUnwrap(axBoundaryErrorValue(.noValue))
        let presentButton = AXUIElementCreateApplication(72_036)
        let evidence = AXWindowService.fullscreenButtonEvidence(missingButton)
        let facts = AXWindowService.makeWindowFacts(
            AXWindowFactAttributeValues(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Activity Monitor",
                closeButton: presentButton,
                fullscreenButton: missingButton,
                fullscreenButtonEnabled: nil,
                zoomButton: presentButton,
                minimizeButton: presentButton
            ),
            appPolicy: .regular,
            bundleId: "com.apple.ActivityMonitor",
            attributeFetchSucceeded: evidence.succeeded
        )
        let engine = WindowRuleEngine()
        let decision = engine.decision(
            for: WindowRuleFacts(
                appName: "Activity Monitor",
                ax: facts,
                sizeConstraints: .fixed(size: CGSize(width: 800, height: 600)),
                windowServer: nil
            ),
            token: nil,
            appFullscreen: false
        )

        XCTAssertFalse(facts.hasFullscreenButton)
        XCTAssertTrue(facts.attributeFetchSucceeded)
        XCTAssertEqual(decision.disposition, .floating)
        XCTAssertEqual(decision.source, .heuristic)
        XCTAssertEqual(decision.heuristicReasons, [.missingFullscreenButton])
        XCTAssertNil(decision.deferredReason)
    }

    func testCapturedConstraintParserUsesObservedSizeForFixedWindow() {
        let size = CGSize(width: 420, height: 280)

        let constraints = AXWindowService.resolvedSizeConstraints(
            AXWindowConstraintInputs(
                hasGrowArea: false,
                hasZoomButton: false,
                subrole: kAXDialogSubrole as String,
                minSize: nil,
                maxSize: nil,
                currentSize: size
            )
        )

        XCTAssertEqual(constraints, .fixed(size: size))
    }

    func testCapturedConstraintParserPreservesExplicitBounds() {
        let minSize = CGSize(width: 320, height: 240)
        let maxSize = CGSize(width: 1_600, height: 1_200)

        let constraints = AXWindowService.resolvedSizeConstraints(
            AXWindowConstraintInputs(
                hasGrowArea: true,
                hasZoomButton: false,
                subrole: kAXStandardWindowSubrole as String,
                minSize: minSize,
                maxSize: maxSize,
                currentSize: CGSize(width: 800, height: 600)
            )
        )

        XCTAssertEqual(constraints.minSize, minSize)
        XCTAssertEqual(constraints.maxSize, maxSize)
        XCTAssertFalse(constraints.isFixed)
    }

    func testFullRescanInspectionRequestsTitlesOnlyForMatchingAppRules() {
        let matching = AXManager.fullRescanInspectionContext(
            activationPolicy: .regular,
            bundleId: "example.titled",
            appName: "Titled App",
            requiresTitleForApp: { $0 == "example.titled" && $1 == "Titled App" }
        )
        let nonmatching = AXManager.fullRescanInspectionContext(
            activationPolicy: .accessory,
            bundleId: "example.titled",
            appName: "Other App",
            requiresTitleForApp: { $0 == "example.titled" && $1 == "Titled App" }
        )

        XCTAssertTrue(matching.includeTitle)
        XCTAssertFalse(nonmatching.includeTitle)
        XCTAssertEqual(matching.bundleId, "example.titled")
        XCTAssertEqual(nonmatching.appPolicy, .accessory)
    }

    func testModeTransitionUsesCapturedFrameWithoutLiveAXRead() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_023
        let windowId = 72_024
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let capturedFrame = CGRect(x: 200, y: 200, width: 600, height: 400)

        XCTAssertTrue(
            controller.transitionWindowMode(
                for: token,
                to: .floating,
                applyFloatingFrame: false,
                observedFrame: capturedFrame
            )
        )

        XCTAssertEqual(
            controller.workspaceManager.floatingState(for: token)?.lastFrame,
            capturedFrame.offsetBy(dx: 50, dy: 50)
        )
    }

    func testFloatingSeedUsesCapturedFrameWithoutLiveAXRead() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_025
        let windowId = 72_026
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let capturedFrame = CGRect(x: 240, y: 180, width: 700, height: 500)

        controller.seedFloatingGeometryIfNeeded(for: token, observedFrame: capturedFrame)

        XCTAssertEqual(controller.workspaceManager.floatingState(for: token)?.lastFrame, capturedFrame)
    }

    func testFullRescanFloatingUpdatesSkipLiveFrameFallbackWhenCapturedFrameIsMissing() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let transitionPID: pid_t = 72_031
        let transitionWindowId = 72_032
        let transitionToken = controller.workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(transitionPID),
                windowId: transitionWindowId
            ),
            pid: transitionPID,
            windowId: transitionWindowId,
            to: workspaceId
        )

        XCTAssertTrue(
            controller.transitionWindowMode(
                for: transitionToken,
                to: .floating,
                applyFloatingFrame: false,
                observedFrame: nil,
                allowLiveFrameFallback: false
            )
        )
        XCTAssertNil(controller.workspaceManager.floatingState(for: transitionToken))

        let seedPID: pid_t = 72_033
        let seedWindowId = 72_034
        let seedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(seedPID), windowId: seedWindowId),
            pid: seedPID,
            windowId: seedWindowId,
            to: workspaceId,
            mode: .floating
        )

        controller.seedFloatingGeometryIfNeeded(
            for: seedToken,
            observedFrame: nil,
            allowLiveFrameFallback: false
        )

        XCTAssertNil(controller.workspaceManager.floatingState(for: seedToken))
    }

    func testFullRescanPreservesHiddenScratchpadsFromCapturedWindowServerOrPinnedEvidence() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let capturedPID: pid_t = 72_035
        let capturedWindowId = 72_036
        let capturedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(capturedPID), windowId: capturedWindowId),
            pid: capturedPID,
            windowId: capturedWindowId,
            to: workspaceId,
            mode: .floating
        )
        let pinnedPID: pid_t = 72_037
        let pinnedWindowId = 72_038
        let pinnedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pinnedPID), windowId: pinnedWindowId),
            pid: pinnedPID,
            windowId: pinnedWindowId,
            to: workspaceId,
            mode: .floating
        )
        for token in [capturedToken, pinnedToken] {
            controller.workspaceManager.setHiddenState(
                HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .scratchpad
                ),
                for: token
            )
        }
        var pinnedQueries: [UInt32] = []
        var seenKeys: Set<WindowToken> = []

        controller.layoutRefreshController.preserveScratchpadHiddenWindowsDuringFullRescan(
            controller.workspaceManager.allEntries(),
            windowServerInfoByWindowId: [
                capturedWindowId: WindowServerInfo(
                    id: UInt32(capturedWindowId),
                    pid: capturedPID,
                    level: 0,
                    frame: CGRect(x: -20_000, y: -20_000, width: 640, height: 480)
                )
            ],
            seenKeys: &seenKeys,
            hasPinnedAXElement: { windowId in
                pinnedQueries.append(windowId)
                return windowId == UInt32(pinnedWindowId)
            }
        )

        XCTAssertEqual(seenKeys, [capturedToken, pinnedToken])
        XCTAssertEqual(pinnedQueries, [UInt32(pinnedWindowId)])
        XCTAssertTrue(controller.workspaceManager.hiddenState(for: capturedToken)?.isScratchpad == true)
        XCTAssertTrue(controller.workspaceManager.hiddenState(for: pinnedToken)?.isScratchpad == true)
    }

    func testFullRescanDoesNotRevealScratchpadForMacOSHiddenApplication() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_039
        let windowId = 72_040
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let hiddenState = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        controller.workspaceManager.setAppHidden(true, pid: pid, source: .service)
        let visibleFrame = controller.workspaceManager.monitors.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        var seenKeys: Set<WindowToken> = []

        controller.layoutRefreshController.preserveScratchpadHiddenWindowsDuringFullRescan(
            controller.workspaceManager.allEntries(),
            windowServerInfoByWindowId: [
                windowId: WindowServerInfo(
                    id: UInt32(windowId),
                    pid: pid,
                    level: 0,
                    frame: visibleFrame
                )
            ],
            seenKeys: &seenKeys
        )

        XCTAssertEqual(seenKeys, [token])
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), hiddenState)
    }

    func testBoundedAsyncMapCapsConcurrencyAndPreservesInputOrder() async throws {
        let probe = AXBoundaryConcurrencyProbe()
        let inputs = Array(0 ..< 12)

        let output = try await boundedFullRescanMap(inputs, maxConcurrent: 4) { input in
            probe.enter()
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(20))
            return input
        }

        XCTAssertEqual(output, inputs)
        XCTAssertEqual(probe.maximum, 4)
    }

    func testGlobalFullRescanBatchesTrackedOffCensusEvidenceBeforeEnumeration() async {
        let manager = AXManager()
        defer { manager.cleanup() }
        let firstTrackedWindowId = Int(UInt32.max - 100)
        let secondTrackedWindowId = Int(UInt32.max - 101)
        let firstPID: pid_t = 2_147_483_500
        let secondPID: pid_t = 2_147_483_499
        var batches: [Set<UInt32>] = []
        manager.fullRescanWindowInfoProvider = { windowIds in
            batches.append(windowIds)
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return [
                UInt32(firstTrackedWindowId): WindowServerInfo(
                    id: UInt32(firstTrackedWindowId),
                    pid: firstPID,
                    level: 101,
                    frame: CGRect(x: 20, y: 30, width: 480, height: 302)
                ),
                UInt32(secondTrackedWindowId): WindowServerInfo(
                    id: UInt32(secondTrackedWindowId),
                    pid: secondPID,
                    level: 8,
                    frame: CGRect(x: 40, y: 50, width: 520, height: 320)
                )
            ]
        }

        let scan = Task { @MainActor in
            try await manager.fullRescanEnumerationSnapshot(
                scope: .all,
                preservingPIDsByWindowId: [
                    firstTrackedWindowId: firstPID,
                    secondTrackedWindowId: secondPID
                ]
            )
        }

        do {
            _ = try await scan.value
            XCTFail("Expected cancellation after exact evidence capture")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            batches,
            [[UInt32(firstTrackedWindowId), UInt32(secondTrackedWindowId)]]
        )
    }

    func testExactFullRescanWindowServerEvidenceRejectsPIDReuseAndQueryFailure() async throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let exactWindowId = 72_310
        let missingWindowId = 72_311
        let mismatchedWindowId = 72_312
        let exactPID: pid_t = 72_313
        let mismatchedPID: pid_t = 72_314
        var queryCount = 0
        manager.fullRescanWindowInfoProvider = { windowIds in
            queryCount += 1
            XCTAssertEqual(
                windowIds,
                [UInt32(exactWindowId), UInt32(missingWindowId), UInt32(mismatchedWindowId)]
            )
            return [
                UInt32(exactWindowId): WindowServerInfo(
                    id: UInt32(exactWindowId),
                    pid: exactPID,
                    level: 101,
                    frame: CGRect(x: 20, y: 30, width: 480, height: 302)
                ),
                UInt32(mismatchedWindowId): WindowServerInfo(
                    id: UInt32(mismatchedWindowId),
                    pid: mismatchedPID,
                    level: 101,
                    frame: CGRect(x: 40, y: 50, width: 520, height: 320)
                )
            ]
        }

        let partialResult = try await manager.queryFullRescanWindowServerEvidence(
            windowIds: [exactWindowId, missingWindowId, mismatchedWindowId],
            excludingWindowIds: [],
            expectedPIDsByWindowId: [
                exactWindowId: exactPID,
                missingWindowId: exactPID,
                mismatchedWindowId: exactPID
            ]
        )
        let partial = try XCTUnwrap(partialResult)

        XCTAssertEqual(Set(partial.keys), [exactWindowId])
        manager.fullRescanWindowInfoProvider = { _ in
            queryCount += 1
            return nil
        }
        let failedResult = try await manager.queryFullRescanWindowServerEvidence(
            windowIds: [exactWindowId],
            excludingWindowIds: [],
            expectedPIDsByWindowId: [exactWindowId: exactPID]
        )
        XCTAssertNil(failedResult)
        XCTAssertEqual(queryCount, 2)
    }

    func testTargetedFullRescanTreatsDistinctWindowServerOwnerAsDependency() async throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let logicalPID: pid_t = 2_147_483_498
        let ownerPID: pid_t = 2_147_483_497
        let windowId = 72_320
        var batches: [Set<UInt32>] = []
        manager.fullRescanWindowInfoProvider = { windowIds in
            batches.append(windowIds)
            return [
                UInt32(windowId): WindowServerInfo(
                    id: UInt32(windowId),
                    pid: ownerPID,
                    level: 0,
                    frame: CGRect(x: 20, y: 30, width: 480, height: 302)
                )
            ]
        }

        let snapshot = try await manager.fullRescanEnumerationSnapshot(
            scope: .targeted(appPIDs: [logicalPID], nativeSpaceIds: []),
            preservingPIDsByWindowId: [windowId: logicalPID],
            identityDependencyPIDsByWindowId: [:]
        )

        XCTAssertEqual(batches, [[UInt32(windowId)]])
        XCTAssertEqual(snapshot.failedPIDs, [logicalPID, ownerPID])
        XCTAssertEqual(snapshot.exactWindowIds, [windowId])
        XCTAssertEqual(snapshot.windowServerInfoByWindowId[windowId]?.pid, ownerPID)
        XCTAssertTrue(snapshot.authoritativeTargetPIDs.isEmpty)
    }

    func testBoundedAsyncMapStopsEnqueueingAfterCancellation() async {
        let started = DispatchSemaphore(value: 0)
        let gate = AXBoundaryAsyncGate()
        let startedCount = AXBoundaryCounter()
        let task = Task.detached {
            try await boundedFullRescanMap(Array(0 ..< 12), maxConcurrent: 4) { input in
                startedCount.increment()
                started.signal()
                await gate.wait()
                try Task.checkCancellation()
                return input
            }
        }

        for _ in 0 ..< 4 {
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        }
        task.cancel()
        await gate.releaseAll()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(startedCount.value, 4)
    }

    func testPromotionIncludesOnlySelectedOneShotWinners() {
        let windowId = 72_010
        let persistentPID: pid_t = 72_011
        let oneShotPID: pid_t = 72_012
        let persistent = candidate(
            pid: persistentPID,
            windowId: windowId,
            route: .persistent,
            isManageable: true
        )
        let losingProbe = candidate(
            pid: oneShotPID,
            windowId: windowId,
            route: .oneShot,
            isManageable: false
        )

        let selected = AXManager.selectFullRescanCandidates(
            [windowId: [losingProbe, persistent]],
            activationPolicyByPID: [persistentPID: .regular, oneShotPID: .regular],
            preservingPIDsByWindowId: [:]
        )
        let promotions = AXManager.oneShotPromotionCandidatesByPID(selected)

        XCTAssertEqual(selected.map(\.pid), [persistentPID])
        XCTAssertTrue(promotions.isEmpty)
    }

    func testFullRescanSelectionSortsWorkspaceRuleCandidatesByWindowId() {
        let pid: pid_t = 72_047
        let lowerWindowId = 72_048
        let higherWindowId = 72_049
        let selected = AXManager.selectFullRescanCandidates(
            [
                higherWindowId: [
                    candidate(
                        pid: pid,
                        windowId: higherWindowId,
                        route: .persistent,
                        isManageable: true
                    )
                ],
                lowerWindowId: [
                    candidate(
                        pid: pid,
                        windowId: lowerWindowId,
                        route: .persistent,
                        isManageable: true
                    )
                ]
            ],
            activationPolicyByPID: [pid: .regular],
            preservingPIDsByWindowId: [:]
        )

        XCTAssertEqual(selected.map(\.windowId), [lowerWindowId, higherWindowId])
    }

    func testOneShotPromotionBatchesAreDeterministicAndSerializedBySortedPID() async {
        let firstPID: pid_t = 72_039
        let secondPID: pid_t = 72_040
        let thirdPID: pid_t = 72_041
        let candidates = [
            candidate(pid: thirdPID, windowId: 72_042, route: .oneShot, isManageable: true),
            candidate(pid: firstPID, windowId: 72_043, route: .oneShot, isManageable: true),
            candidate(pid: secondPID, windowId: 72_044, route: .persistent, isManageable: true),
            candidate(pid: firstPID, windowId: 72_045, route: .oneShot, isManageable: true),
            candidate(pid: secondPID, windowId: 72_046, route: .oneShot, isManageable: true)
        ]
        var active = 0
        var maximumActive = 0
        var observedPIDs: [pid_t] = []
        var observedWindowIds: [[Int]] = []

        await AXManager.forEachOneShotPromotionBatch(candidates) { pid, batch in
            active += 1
            maximumActive = max(maximumActive, active)
            observedPIDs.append(pid)
            observedWindowIds.append(batch.map(\.windowId))
            await Task.yield()
            active -= 1
        }

        XCTAssertEqual(observedPIDs, [firstPID, secondPID, thirdPID])
        XCTAssertEqual(observedWindowIds, [[72_043, 72_045], [72_046], [72_042]])
        XCTAssertEqual(maximumActive, 1)
    }

    func testGenerationMoveInvalidatesLateOldWindowResult() {
        let generations = LockedWindowGenerationMap()
        let oldWindowId = 72_017
        let newWindowId = 72_018
        let inFlightGeneration = generations.nextGeneration(for: oldWindowId)

        generations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(generations.isCurrent(inFlightGeneration, for: oldWindowId))
        XCTAssertFalse(generations.isCurrent(inFlightGeneration, for: newWindowId))
    }

    func testGenerationMoveInvalidatesExistingDestinationResult() {
        let generations = LockedWindowGenerationMap()
        let oldWindowId = 72_027
        let newWindowId = 72_028
        _ = generations.nextGeneration(for: oldWindowId)
        _ = generations.nextGeneration(for: newWindowId)
        let destinationGeneration = generations.nextGeneration(for: newWindowId)

        generations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(generations.isCurrent(destinationGeneration, for: newWindowId))
    }

    func testSuppressionMoveRetainsNewWindowAndClearsOldWindow() {
        let suppression = LockedWindowIdSet()
        let oldWindowId = 72_029
        let newWindowId = 72_030
        suppression.insert(oldWindowId)

        suppression.moveIfPresent(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(suppression.contains(oldWindowId))
        XCTAssertTrue(suppression.contains(newWindowId))
    }

    func testTargetResolutionKeepsExplicitAppsWholeAndNativeSpaceAppsExact() throws {
        let explicitPID: pid_t = 72_200
        let resolvedPID: pid_t = 72_201
        let explicitDependencyPID: pid_t = 72_202
        let resolvedDependencyPID: pid_t = 72_203
        let explicitWindowId = 72_204
        let resolvedWindowId = 72_205
        let unrelatedResolvedWindowId = 72_206
        let nativeSpaceId: UInt64 = 72_207

        let resolution = try XCTUnwrap(
            AXManager.fullRescanTargetResolution(
                scope: .targeted(
                    appPIDs: [explicitPID],
                    nativeSpaceIds: [nativeSpaceId]
                ),
                resolvedTargetPIDs: [resolvedPID],
                resolvedTargetWindowIds: [resolvedWindowId],
                preservingPIDsByWindowId: [
                    explicitWindowId: explicitPID,
                    resolvedWindowId: resolvedPID,
                    unrelatedResolvedWindowId: resolvedPID
                ],
                ownerPIDByWindowId: [
                    explicitWindowId: explicitPID,
                    resolvedWindowId: resolvedPID,
                    unrelatedResolvedWindowId: resolvedPID
                ],
                identityDependencyPIDsByWindowId: [
                    explicitWindowId: [explicitDependencyPID],
                    resolvedWindowId: [resolvedDependencyPID],
                    unrelatedResolvedWindowId: [72_208]
                ]
            )
        )

        XCTAssertEqual(resolution.explicitAppPIDs, [explicitPID])
        XCTAssertEqual(resolution.resolvedTargetPIDs, [resolvedPID])
        XCTAssertEqual(resolution.resolvedTargetWindowIds, [resolvedWindowId])
        XCTAssertEqual(resolution.targetPIDs, [explicitPID, resolvedPID])
        XCTAssertEqual(resolution.relevantWindowIds, [explicitWindowId, resolvedWindowId])
        XCTAssertFalse(resolution.relevantWindowIds.contains(unrelatedResolvedWindowId))
        XCTAssertEqual(
            resolution.dependencyPIDs,
            [explicitDependencyPID, resolvedDependencyPID]
        )
        XCTAssertEqual(
            resolution.targetPIDsByDependencyPID[explicitDependencyPID],
            [explicitPID]
        )
        XCTAssertEqual(
            resolution.targetPIDsByDependencyPID[resolvedDependencyPID],
            [resolvedPID]
        )
        XCTAssertEqual(
            resolution.effectiveScope,
            .targeted(
                appPIDs: [
                    explicitPID,
                    resolvedPID,
                    explicitDependencyPID,
                    resolvedDependencyPID
                ],
                nativeSpaceIds: [nativeSpaceId]
            )
        )
    }

    func testAuthoritativeTargetsExcludeOnlyRootsWithFailedDependencies() {
        let firstTargetPID: pid_t = 72_210
        let secondTargetPID: pid_t = 72_211
        let failedDependencyPID: pid_t = 72_212
        let successfulDependencyPID: pid_t = 72_213

        let authoritative = AXManager.authoritativeFullRescanTargetPIDs(
            targetPIDs: [firstTargetPID, secondTargetPID],
            successfullyEnumeratedPIDs: [
                firstTargetPID,
                secondTargetPID,
                successfulDependencyPID
            ],
            failedPIDs: [failedDependencyPID],
            dependencyPIDs: [failedDependencyPID, successfulDependencyPID],
            targetPIDsByDependencyPID: [
                failedDependencyPID: [firstTargetPID],
                successfulDependencyPID: [secondTargetPID]
            ]
        )

        XCTAssertEqual(authoritative, [secondTargetPID])
    }

    func testTargetRootAlsoActsAsDependencyForSharedManagedIdentity() throws {
        let logicalPID: pid_t = 72_214
        let proxyPID: pid_t = 72_215
        let windowId = 72_216
        let resolution = try XCTUnwrap(
            AXManager.fullRescanTargetResolution(
                scope: .targeted(
                    appPIDs: [logicalPID, proxyPID],
                    nativeSpaceIds: []
                ),
                resolvedTargetPIDs: [],
                resolvedTargetWindowIds: [],
                preservingPIDsByWindowId: [windowId: logicalPID],
                ownerPIDByWindowId: [windowId: logicalPID],
                identityDependencyPIDsByWindowId: [windowId: [proxyPID]]
            )
        )

        XCTAssertEqual(resolution.dependencyPIDs, [proxyPID])
        XCTAssertEqual(resolution.targetPIDsByDependencyPID[proxyPID], [logicalPID])
        XCTAssertTrue(AXManager.authoritativeFullRescanTargetPIDs(
            targetPIDs: resolution.targetPIDs,
            successfullyEnumeratedPIDs: [logicalPID],
            failedPIDs: [proxyPID],
            dependencyPIDs: resolution.dependencyPIDs,
            targetPIDsByDependencyPID: resolution.targetPIDsByDependencyPID
        ).isEmpty)
    }

    func testScopedManagedWindowBindingPIDsAreExact() {
        let contextPID: pid_t = 72_220
        let sharedPID: pid_t = 72_221
        let windowPID: pid_t = 72_222
        let emptyScopedPID: pid_t = 72_223

        XCTAssertEqual(
            AXManager.managedWindowBindingPIDs(
                contextPIDs: [contextPID, sharedPID],
                windowPIDs: [sharedPID, windowPID],
                scopedPIDs: nil
            ),
            [contextPID, sharedPID, windowPID]
        )
        XCTAssertEqual(
            AXManager.managedWindowBindingPIDs(
                contextPIDs: [contextPID, sharedPID],
                windowPIDs: [sharedPID, windowPID],
                scopedPIDs: [sharedPID, emptyScopedPID]
            ),
            [sharedPID, emptyScopedPID]
        )
    }

    func testManagedWindowBindingRetryBackoffIsBounded() async {
        XCTAssertEqual(AXManager.managedWindowBindingRetryDelay(afterFailure: 1), .milliseconds(100))
        XCTAssertEqual(AXManager.managedWindowBindingRetryDelay(afterFailure: 2), .milliseconds(250))
        XCTAssertEqual(AXManager.managedWindowBindingRetryDelay(afterFailure: 3), .milliseconds(500))
        XCTAssertNil(AXManager.managedWindowBindingRetryDelay(afterFailure: 4))

        let manager = AXManager()
        defer { manager.cleanup() }
        let pid: pid_t = 910_321
        let windowId = 910_322
        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        let entry = WindowState(
            token: WindowToken(pid: pid, windowId: windowId),
            axRef: window,
            workspaceId: UUID(),
            mode: .tiling,
            managedReplacementMetadata: nil,
            ruleEffects: .none,
            admissionHints: .none
        )
        let retries = expectation(description: "bounded binding retries")
        retries.expectedFulfillmentCount = 3
        var retryCount = 0
        manager.managedWindowBindingRetryDelayProvider = {
            $0 <= 3 ? .zero : nil
        }
        var observedPIDs: [pid_t] = []
        manager.onManagedWindowBindingFailed = { [weak manager] failedPID in
            retryCount += 1
            observedPIDs.append(failedPID)
            manager?.reconcileManagedWindowBindings([entry], scopedPIDs: [failedPID])
            retries.fulfill()
        }

        manager.bindManagedWindows([entry])
        await fulfillment(of: [retries], timeout: 1)
        XCTAssertEqual(retryCount, 3)
        XCTAssertEqual(observedPIDs, [pid, pid, pid])
    }

    func testFailedTargetedEnumerationResubmitsPendingManagedWindowBindingRetry() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.axManager
        defer {
            manager.onManagedWindowBindingFailed = nil
            manager.cleanup()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 910_323
        let token = WindowToken(pid: pid, windowId: 910_324)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: pid,
            windowId: token.windowId,
            to: workspaceId
        )
        let retries = expectation(description: "binding retry survives failed targeted scan")
        retries.expectedFulfillmentCount = 2
        var observedPIDs: [pid_t] = []
        manager.managedWindowBindingRetryDelayProvider = {
            $0 <= 2 ? .zero : nil
        }
        manager.onManagedWindowBindingFailed = { failedPID in
            observedPIDs.append(failedPID)
            retries.fulfill()
            guard observedPIDs.count == 1 else { return }
            controller.layoutRefreshController.requestFullRescan(
                reason: .staleFullRescan,
                scope: .targeted(appPIDs: [failedPID], nativeSpaceIds: [])
            )
        }

        manager.bindManagedWindows(controller.workspaceManager.allEntries())

        await fulfillment(of: [retries], timeout: 2)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        XCTAssertEqual(observedPIDs, [pid, pid])
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    private func candidate(
        pid: pid_t,
        windowId: Int,
        route: FullRescanEnumerationRoute,
        isManageable: Bool,
        frame: CGRect? = nil,
        fullscreenAttribute: Bool? = nil
    ) -> FullRescanWindowCandidate {
        FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: isManageable,
                    frame: frame ?? (isManageable ? CGRect(x: 0, y: 0, width: 800, height: 600) : nil)
                ),
                fullscreenAttribute: fullscreenAttribute
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: route
        )
    }

    func testDeferredWindowInfoReadAllowsMainThreadProgress() async throws {
        let started = expectation(description: "background query entered")
        let gate = DispatchSemaphore(value: 0)
        let read = Task {
            try await SkyLight.performWindowInfoQuery {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
                return [77: WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero)]
            }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(Thread.isMainThread)
        gate.signal()
        let result = try await read.value
        XCTAssertEqual(result?[77]?.level, 8)
    }

    func testDeferredWindowInfoReadDiscardsCancelledInFlightResult() async {
        let started = expectation(description: "background query blocked")
        let gate = DispatchSemaphore(value: 0)
        let read = Task {
            try await SkyLight.performWindowInfoQuery {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return [77: WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero)]
            }
        }
        await fulfillment(of: [started], timeout: 1)
        read.cancel()
        gate.signal()
        do {
            _ = try await read.value
            XCTFail("Cancelled read must not publish evidence")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeferredFullRescanRejectsEvidenceReturnedAfterCancellation() async {
        let manager = AXManager()
        defer { manager.cleanup() }
        let entered = expectation(description: "rescan query entered")
        let gate = AXBoundaryAsyncGate()
        manager.fullRescanWindowInfoProvider = { ids in
            entered.fulfill()
            await gate.wait()
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, WindowServerInfo(id: $0, pid: 1234, level: 8, frame: .zero))
            })
        }
        let scan = Task {
            try await manager.fullRescanEnumerationSnapshot(
                scope: .targeted(appPIDs: [1234], nativeSpaceIds: []),
                preservingPIDsByWindowId: [77: 1234]
            )
        }
        await fulfillment(of: [entered], timeout: 1)
        scan.cancel()
        await gate.releaseAll()
        do {
            _ = try await scan.value
            XCTFail("Cancelled scan must not merge returned evidence")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeferredFullRescanCannotApplyAfterWindowChangesWorkspace() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let source = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let destination = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        let pid: pid_t = 2_147_483_497
        let windowId = 72_399
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: source, mode: .tiling
        )
        let refresh = controller.layoutRefreshController
        defer { refresh.resetState() }
        let entered = expectation(description: "inventory read awaiting result")
        let gate = AXBoundaryAsyncGate()
        controller.axManager.fullRescanWindowInfoProvider = { ids in
            entered.fulfill()
            await gate.wait()
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, WindowServerInfo(id: $0, pid: pid, level: 0, frame: .zero))
            })
        }
        refresh.beginPerformanceCapture()
        refresh.layoutState.pendingRefresh = .init(
            kind: .fullRescan, reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
        )
        refresh.startNextRefreshIfNeeded()
        await fulfillment(of: [entered], timeout: 1)
        let active = try XCTUnwrap(refresh.layoutState.activeRefreshTask)
        refresh.layoutState.inventoryStabilityHoldFullRescans = true
        controller.workspaceManager.setWorkspace(for: token, to: destination)
        await gate.releaseAll()
        await active.value
        XCTAssertEqual(refresh.performanceSnapshot()?.refreshesIncomplete, 1)
        XCTAssertEqual(refresh.performanceSnapshot()?.refreshesCompleted, 0)
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), destination)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertFalse(refresh.layoutState.didExecuteEffectPlan)
    }
}

final class AXRunLoopTimeoutBoundaryTests: XCTestCase {
    func testStartedBodyRemainsTimeBounded() async {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cacheMutation = AXBoundaryCounter()

        do {
            _ = try await thread.runInLoop(timeout: .milliseconds(250)) { job in
                defer { finished.signal() }
                started.signal()
                release.wait()
                try job.checkCancellation()
                cacheMutation.increment()
                return true
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cacheMutation.value, 0)
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testTimedOutSuccessfulBodyRunsUndeliveredSuccessExactlyOnce() async {
        let ready = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let undelivered = DispatchSemaphore(value: 0)
        let hookCount = AXBoundaryCounter()
        let deliveredValue = AXBoundaryValueBox<Int?>(nil)
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)

        do {
            _ = try await thread.runInLoop(
                timeout: .milliseconds(250),
                onUndeliveredSuccess: { value in
                    hookCount.increment()
                    deliveredValue.value = value
                    undelivered.signal()
                }
            ) { _ in
                defer { finished.signal() }
                started.signal()
                release.wait()
                return 469_091
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(undelivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(hookCount.value, 1)
        XCTAssertEqual(deliveredValue.value, 469_091)
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testTimedOutRebindCommitCannotMutateCachesAfterBodyRelease() async {
        let ready = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let unchanged = AXBoundaryCounter()
        let cacheBox = AXRebindCacheBox()
        let pid: pid_t = 469_100
        let oldWindowId = 469_101
        let newWindowId = 469_102
        let oldWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: newWindowId
        )
        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                cacheBox.windows = ThreadGuardedValue([oldWindowId: oldWindow.element])
                cacheBox.subscriptions = ThreadGuardedValue([
                    oldWindowId: AppAXWindowSubscription(
                        windowId: oldWindowId,
                        element: oldWindow.element,
                        notifications: .lifecycle
                    )
                ])
                let port = NSMachPort()
                RunLoop.current.add(port, forMode: .default)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)

        do {
            _ = try await thread.runInLoop(timeout: .milliseconds(250)) { job in
                guard let windows = cacheBox.windows,
                      let subscriptions = cacheBox.subscriptions
                else {
                    throw CancellationError()
                }
                defer {
                    if windows[newWindowId] == nil,
                       subscriptions[newWindowId] == nil,
                       windows[oldWindowId].map({ CFEqual($0, oldWindow.element) }) == true,
                       subscriptions[oldWindowId].map({ CFEqual($0.element, oldWindow.element) }) == true
                    {
                        unchanged.increment()
                    }
                    finished.signal()
                }
                started.signal()
                release.wait()
                _ = try AppAXContext.commitWindowRebindCache(
                    oldWindow: oldWindow,
                    newWindow: newWindow,
                    destinationSubscription: AppAXWindowSubscription(
                        windowId: newWindowId,
                        element: newWindow.element,
                        notifications: .lifecycle
                    ),
                    retireOldWindowState: true,
                    binding: AppAXWindowRebindBinding(
                        destinationWindowElement: nil,
                        destinationSubscription: nil,
                        stagedSubscription: AppAXWindowSubscription(
                            windowId: newWindowId,
                            element: newWindow.element,
                            notifications: .lifecycle
                        ),
                        newlyInstalledNotifications: .lifecycle,
                        requiresRetag: false,
                        hasLifecycleObserver: true
                    ),
                    windows: windows,
                    subscribedWindows: subscriptions,
                    job: job
                )
                return true
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(unchanged.value, 1)
        thread.runInLoopAsync { _ in
            cacheBox.windows?.destroy()
            cacheBox.subscriptions?.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testRebindCachePublishesWithoutLifecycleObserver() async throws {
        let ready = DispatchSemaphore(value: 0)
        let cacheBox = AXRebindCacheBox()
        let pid: pid_t = 469_110
        let oldWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 469_111
        )
        let newWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: 469_112
        )
        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                cacheBox.windows = ThreadGuardedValue([oldWindow.windowId: oldWindow.element])
                cacheBox.subscriptions = ThreadGuardedValue([:])
                let port = NSMachPort()
                RunLoop.current.add(port, forMode: .default)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)

        let committed = try await thread.runInLoop(timeout: .seconds(1)) { job in
            guard let windows = cacheBox.windows,
                  let subscriptions = cacheBox.subscriptions
            else {
                return false
            }
            let cleanup = try AppAXContext.commitWindowRebindCache(
                oldWindow: oldWindow,
                newWindow: newWindow,
                destinationSubscription: nil,
                retireOldWindowState: true,
                binding: AppAXWindowRebindBinding(
                    destinationWindowElement: nil,
                    destinationSubscription: nil,
                    stagedSubscription: nil,
                    newlyInstalledNotifications: [],
                    requiresRetag: false,
                    hasLifecycleObserver: false
                ),
                windows: windows,
                subscribedWindows: subscriptions,
                job: job
            )
            return cleanup.subscriptions.isEmpty
                && windows[oldWindow.windowId] == nil
                && subscriptions[oldWindow.windowId] == nil
                && windows[newWindow.windowId].map({ CFEqual($0, newWindow.element) }) == true
                && subscriptions[newWindow.windowId] == nil
        }

        XCTAssertTrue(committed)
        thread.runInLoopAsync { _ in
            cacheBox.windows?.destroy()
            cacheBox.subscriptions?.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testRebindCachePreservesInterposedSourceIncarnation() async throws {
        let ready = DispatchSemaphore(value: 0)
        let cacheBox = AXRebindCacheBox()
        let pid: pid_t = 469_120
        let oldWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 469_121
        )
        let interposedSource = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: oldWindow.windowId
        )
        let newWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 2),
            windowId: 469_122
        )
        let interposedSubscription = AppAXWindowSubscription(
            windowId: interposedSource.windowId,
            element: interposedSource.element,
            notifications: .lifecycle
        )
        let destinationSubscription = AppAXWindowSubscription(
            windowId: newWindow.windowId,
            element: newWindow.element,
            notifications: .lifecycle
        )
        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                cacheBox.windows = ThreadGuardedValue([
                    oldWindow.windowId: interposedSource.element
                ])
                cacheBox.subscriptions = ThreadGuardedValue([
                    oldWindow.windowId: interposedSubscription
                ])
                let port = NSMachPort()
                RunLoop.current.add(port, forMode: .default)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)

        let preserved = try await thread.runInLoop(timeout: .seconds(1)) { job in
            guard let windows = cacheBox.windows,
                  let subscriptions = cacheBox.subscriptions
            else {
                return false
            }
            let cleanup = try AppAXContext.commitWindowRebindCache(
                oldWindow: oldWindow,
                newWindow: newWindow,
                destinationSubscription: destinationSubscription,
                retireOldWindowState: true,
                binding: AppAXWindowRebindBinding(
                    destinationWindowElement: nil,
                    destinationSubscription: nil,
                    stagedSubscription: destinationSubscription,
                    newlyInstalledNotifications: .lifecycle,
                    requiresRetag: false,
                    hasLifecycleObserver: true
                ),
                windows: windows,
                subscribedWindows: subscriptions,
                job: job
            )
            return cleanup.subscriptions.isEmpty
                && windows[oldWindow.windowId].map({
                    CFEqual($0, interposedSource.element)
                }) == true
                && subscriptions[oldWindow.windowId].map({
                    CFEqual($0.element, interposedSource.element)
                        && $0.notifications == .lifecycle
                }) == true
                && windows[newWindow.windowId].map({ CFEqual($0, newWindow.element) }) == true
                && subscriptions[newWindow.windowId].map({
                    CFEqual($0.element, destinationSubscription.element)
                }) == true
        }

        XCTAssertTrue(preserved)
        thread.runInLoopAsync { _ in
            cacheBox.windows?.destroy()
            cacheBox.subscriptions?.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
