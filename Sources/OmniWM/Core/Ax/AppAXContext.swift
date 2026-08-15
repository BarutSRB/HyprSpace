// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation

final class LockedWindowIdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    private var hardSuppressed = false

    func insert(_ id: Int) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func remove(_ id: Int) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardSuppressed || ids.contains(id)
    }

    func setHardSuppressed(_ hardSuppressed: Bool) {
        lock.lock()
        self.hardSuppressed = hardSuppressed
        lock.unlock()
    }

    func isHardSuppressed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardSuppressed
    }

    func moveIfPresent(from oldId: Int, to newId: Int) {
        lock.lock()
        if oldId != newId, ids.remove(oldId) != nil {
            ids.insert(newId)
        }
        lock.unlock()
    }

    func retainOnly(_ retainedIds: Set<Int>) {
        lock.lock()
        ids.formIntersection(retainedIds)
        lock.unlock()
    }
}

final class LockedWindowGenerationMap: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    private var generations: [Int: UInt64] = [:]

    func nextGeneration(for id: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let generation = nextGeneration
        nextGeneration &+= 1
        generations[id] = generation
        return generation
    }

    func isCurrent(_ generation: UInt64, for id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[id] == generation
    }

    func invalidateAndRemove(_ id: Int) {
        lock.lock()
        nextGeneration &+= 1
        generations.removeValue(forKey: id)
        lock.unlock()
    }

    func invalidateAndMoveValue(from oldId: Int, to newId: Int) {
        lock.lock()
        let generation = nextGeneration
        nextGeneration &+= 1
        if oldId != newId {
            generations.removeValue(forKey: oldId)
        }
        generations[newId] = generation
        lock.unlock()
    }

    func retainOnly(_ retainedIds: Set<Int>) {
        lock.lock()
        generations = generations.filter { retainedIds.contains($0.key) }
        lock.unlock()
    }
}

final class LockedClosingFrameGenerationMap: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    private var generations: [UUID: UInt64] = [:]

    func nextGeneration(for animationId: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let generation = nextGeneration
        nextGeneration &+= 1
        generations[animationId] = generation
        return generation
    }

    func isCurrent(_ generation: UInt64, for animationId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[animationId] == generation
    }

    func removeIfCurrent(_ generation: UInt64, for animationId: UUID) {
        lock.lock()
        if generations[animationId] == generation {
            generations.removeValue(forKey: animationId)
        }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        nextGeneration &+= 1
        generations.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

final class LockedGenerationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        generation &+= 1
        let currentGeneration = generation
        lock.unlock()
        return currentGeneration
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func performIfCurrent<T>(
        _ expectedGeneration: UInt64,
        _ body: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return nil }
        return try body()
    }
}

struct AppAXWindowNotificationSet: OptionSet, Sendable {
    let rawValue: UInt8

    static let destroyed = Self(rawValue: 1 << 0)
    static let miniaturized = Self(rawValue: 1 << 1)
    static let lifecycle: Self = [.destroyed, .miniaturized]
}

enum AppAXWindowNotification: CaseIterable, Hashable, Sendable {
    case destroyed
    case miniaturized

    var ownership: AppAXWindowNotificationSet {
        switch self {
        case .destroyed: .destroyed
        case .miniaturized: .miniaturized
        }
    }

    var name: CFString {
        switch self {
        case .destroyed: kAXUIElementDestroyedNotification as CFString
        case .miniaturized: kAXWindowMiniaturizedNotification as CFString
        }
    }
}

enum AppAXAlreadyRegisteredPolicy: Sendable {
    case adopt
    case reject
    case replace
}

enum AppAXWindowRebindSubscriptionOwnership: Equatable, Sendable {
    case unowned
    case destination
    case source
    case conflict
}

struct AppAXWindowSubscription: @unchecked Sendable {
    let windowId: Int
    let element: AXUIElement
    var notifications: AppAXWindowNotificationSet

    func owns(_ notification: AppAXWindowNotification) -> Bool {
        notifications.contains(notification.ownership)
    }
}

struct AppAXPendingNotificationRemoval: @unchecked Sendable {
    let element: AXUIElement
    let notification: AppAXWindowNotification
}

struct AppAXWindowNotificationInstallResult: @unchecked Sendable {
    let subscription: AppAXWindowSubscription?
    let newlyInstalled: AppAXWindowNotificationSet
    let pendingRemovals: [AppAXPendingNotificationRemoval]
}

struct AppAXWindowRebindBinding: @unchecked Sendable {
    let destinationWindowElement: AXUIElement?
    let destinationSubscription: AppAXWindowSubscription?
    let stagedSubscription: AppAXWindowSubscription?
    let newlyInstalledNotifications: AppAXWindowNotificationSet
    let requiresRetag: Bool
    let hasLifecycleObserver: Bool
}

struct AppAXSubscriptionCleanup: @unchecked Sendable {
    let subscriptions: [AppAXWindowSubscription]
}

struct AppAXWindowStateRemovalOutcome: Sendable {
    let removedCachedWindow: Bool
    let removedSubscription: Bool
}

enum AppAXWindowBindingResult: Equatable, Sendable {
    case bound
    case superseded
    case retryRequired
}

private struct AppAXWindowBindingSuperseded: Error {}

private func axCallbackObserverKey(_ observer: AXObserver) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
}

struct AppAXFrameWriteRequest: Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?
    let generation: UInt64
    let verify: Bool
}

struct AppAXClosingFrameWriteRequest: Sendable {
    let target: AXClosingFrameTarget
    let generation: UInt64
}

private final class AppAXContextCreationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppAXContext?, Error>?

    init(_ continuation: CheckedContinuation<AppAXContext?, Error>) {
        self.continuation = continuation
    }

    func takeContinuation() -> CheckedContinuation<AppAXContext?, Error>? {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }
}

@MainActor
final class AppAXContext {
    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    private nonisolated(unsafe) var thread: Thread?
    nonisolated var axThread: Thread? {
        thread
    }

    private var activeFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private var activeClosingFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private let frameWriteGenerations = LockedWindowGenerationMap()
    private let parkFrameWriteGenerations = LockedWindowGenerationMap()
    private let closingFrameWriteGenerations = LockedClosingFrameGenerationMap()
    private let windowBindingEpoch = LockedGenerationEpoch()
    private let frameWriteSuppression = LockedWindowIdSet()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let focusedWindowObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>
    private let pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    private let axObserverCallbackKey: UInt?
    private let focusedWindowObserverCallbackKey: UInt?
    let callbackGeneration: UInt64

    @MainActor static var contexts: [pid_t: AppAXContext] = [:]
    @MainActor private static var macOSHiddenPIDs: Set<pid_t> = []
    @MainActor private static var inFlightCreations: [pid_t: (
        generation: UInt64,
        task: Task<AppAXContext?, Error>
    )] = [:]

    private nonisolated init(
        _ nsApp: NSRunningApplication,
        _ axApp: ThreadGuardedValue<AXUIElement>,
        _ windows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ observer: ThreadGuardedValue<AXObserver?>,
        _ focusedWindowObserver: ThreadGuardedValue<AXObserver?>,
        _ subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        _ pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        _ axObserverCallbackKey: UInt?,
        _ focusedWindowObserverCallbackKey: UInt?,
        _ callbackGeneration: UInt64,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        pid = nsApp.processIdentifier
        self.axApp = axApp
        self.windows = windows
        axObserver = observer
        self.focusedWindowObserver = focusedWindowObserver
        self.subscribedWindows = subscribedWindows
        self.pendingNotificationRemovals = pendingNotificationRemovals
        self.axObserverCallbackKey = axObserverCallbackKey
        self.focusedWindowObserverCallbackKey = focusedWindowObserverCallbackKey
        self.callbackGeneration = callbackGeneration
        self.thread = thread
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        if let existing = contexts[pid] { return existing }
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        try Task.checkCancellation()

        if let inFlight = inFlightCreations[pid] {
            return try await inFlight.task.value
        }

        let generation = appAXCallbackGenerationRegistry.currentGeneration
        let task = Task<AppAXContext?, Error> { @MainActor in
            defer {
                if inFlightCreations[pid]?.generation == generation {
                    inFlightCreations.removeValue(forKey: pid)
                }
            }

            let context = try await createContext(nsApp, generation: generation)
            guard appAXCallbackGenerationRegistry.isCurrent(generation) else {
                context?.destroy()
                return nil
            }
            if let context {
                context.setMacOSAppHidden(macOSHiddenPIDs.contains(pid), for: [])
                contexts[pid] = context
            }
            return context
        }
        inFlightCreations[pid] = (generation: generation, task: task)

        return try await task.value
    }

    @MainActor
    static func shutdownAll() {
        appAXCallbackGenerationRegistry.advance()
        for (_, inFlight) in inFlightCreations {
            inFlight.task.cancel()
        }
        inFlightCreations.removeAll()
        for (_, context) in contexts {
            context.destroy()
        }
        macOSHiddenPIDs.removeAll()
    }

    @MainActor
    static func setMacOSAppHidden(_ hidden: Bool, pid: pid_t, windowIds: [Int]) {
        if hidden {
            macOSHiddenPIDs.insert(pid)
        } else {
            macOSHiddenPIDs.remove(pid)
        }
        contexts[pid]?.setMacOSAppHidden(hidden, for: windowIds)
    }

    @MainActor
    static func isMacOSAppHidden(pid: pid_t) -> Bool {
        macOSHiddenPIDs.contains(pid)
    }

    @MainActor
    private static func createContext(
        _ nsApp: NSRunningApplication,
        generation: UInt64
    ) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier
        guard let callbackGeneration = appAXCallbackGenerationRegistry.reserveCallbackGeneration(
            serviceGeneration: generation
        ) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = AppAXContextCreationState(continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                state.takeContinuation()?.resume(returning: nil)
            }

            let thread = Thread {
                $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                    let axApp = AXUIElementCreateApplication(pid)

                    var observer: AXObserver?
                    if AXObserverCreate(pid, axWindowNotificationCallback, &observer) != .success {
                        FallbackFiringRecorder.shared.note(.ax, "observerCreateFailed")
                    }

                    if let obs = observer {
                        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
                    } else {
                        FallbackFiringRecorder.shared.note(.ax, "observerRunLoopSourceSkipped")
                    }

                    var focusObserver: AXObserver?
                    if AXObserverCreate(pid, axFocusedWindowChangedCallback, &focusObserver) != .success {
                        FallbackFiringRecorder.shared.note(.ax, "focusObserverCreateFailed")
                    }

                    if let focusObs = focusObserver {
                        if AXObserverAddNotification(
                            focusObs,
                            axApp,
                            kAXFocusedWindowChangedNotification as CFString,
                            nil
                        ) != .success {
                            FallbackFiringRecorder.shared.note(.ax, "focusedWindowSubscribeFailed")
                        }
                        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
                    } else {
                        FallbackFiringRecorder.shared.note(.ax, "focusObserverRunLoopSourceSkipped")
                    }

                    let guardedAxApp = ThreadGuardedValue(axApp)
                    let guardedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let guardedObserver = ThreadGuardedValue(observer)
                    let guardedFocusedWindowObserver = ThreadGuardedValue(focusObserver)
                    let guardedSubscribedWindows = ThreadGuardedValue([Int: AppAXWindowSubscription]())
                    let guardedPendingNotificationRemovals = ThreadGuardedValue(
                        [AppAXPendingNotificationRemoval]()
                    )
                    let observerCallbackKey = observer.map(axCallbackObserverKey)
                    let focusedWindowObserverCallbackKey = focusObserver.map(axCallbackObserverKey)
                    let currentThread = Thread.current

                    scheduleOnMainRunLoop {
                        timeoutTask.cancel()

                        let context = AppAXContext(
                            nsApp,
                            guardedAxApp,
                            guardedWindows,
                            guardedObserver,
                            guardedFocusedWindowObserver,
                            guardedSubscribedWindows,
                            guardedPendingNotificationRemovals,
                            observerCallbackKey,
                            focusedWindowObserverCallbackKey,
                            callbackGeneration,
                            currentThread
                        )
                        guard let continuation = state.takeContinuation() else {
                            context.destroy()
                            return
                        }

                        let observerRegistered = observerCallbackKey.map {
                            appAXCallbackGenerationRegistry.register(
                                observerKey: $0,
                                serviceGeneration: generation,
                                callbackGeneration: callbackGeneration
                            )
                        } ?? true
                        let focusedObserverRegistered = focusedWindowObserverCallbackKey.map {
                            appAXCallbackGenerationRegistry.register(
                                observerKey: $0,
                                serviceGeneration: generation,
                                callbackGeneration: callbackGeneration
                            )
                        } ?? true
                        guard observerRegistered, focusedObserverRegistered else {
                            context.destroy()
                            continuation.resume(returning: nil)
                            return
                        }
                        WindowAdmissionTrace.record(
                            .init(
                                action: .endpointCreated,
                                pid: pid,
                                bundleId: nsApp.bundleIdentifier,
                                callbackGeneration: callbackGeneration
                            )
                        )
                        continuation.resume(returning: context)
                    }

                    let port = NSMachPort()
                    RunLoop.current.add(port, forMode: .default)

                    CFRunLoopRun()
                }
            }
            thread.name = "OmniWM-AX-\(nsApp.bundleIdentifier ?? "pid:\(pid)")"
            thread.start()
        }
    }

    nonisolated static func destroyNotificationRefcon(for windowId: Int) -> UnsafeMutableRawPointer? {
        guard windowId > 0 else { return nil }
        return UnsafeMutableRawPointer(bitPattern: windowId)
    }

    nonisolated static func destroyNotificationWindowId(
        from refcon: UnsafeMutableRawPointer?
    ) -> Int? {
        guard let refcon else { return nil }
        let windowId = Int(bitPattern: refcon)
        guard windowId > 0 else { return nil }
        return windowId
    }

    nonisolated static func handleWindowDestroyedCallback(
        pid: pid_t,
        element: AXUIElement,
        observerKey: UInt,
        callbackGeneration: UInt64?,
        refcon: UnsafeMutableRawPointer?
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX destroy callback without a valid windowId refcon")
            return
        }
        appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
            EventIntake.post(
                .axWindowDestroyed(
                    pid: pid,
                    axRef: AXWindowRef(element: element, windowId: windowId),
                    callbackGeneration: callbackGeneration
                )
            )
        }
    }

    nonisolated static func handleWindowMiniaturizedCallback(
        pid: pid_t,
        observerKey: UInt,
        callbackGeneration: UInt64?,
        refcon: UnsafeMutableRawPointer?
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX miniaturize callback without a valid windowId refcon")
            return
        }
        appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
            EventIntake.post(
                .axWindowMiniaturized(
                    pid: pid,
                    windowId: windowId,
                    callbackGeneration: callbackGeneration
                )
            )
        }
    }

    nonisolated static func installWindowNotifications(
        element: AXUIElement,
        windowId: Int,
        ownedSubscription: AppAXWindowSubscription?,
        addNotification: (AppAXWindowNotification, UnsafeMutableRawPointer?) -> AXError,
        removeNotification: (AppAXWindowNotification) -> AXError,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy = .adopt,
        checkCancellation: () throws -> Void = {},
        recordPendingRemovals: ([AppAXPendingNotificationRemoval]) -> Void = { _ in }
    ) throws -> AppAXWindowNotificationInstallResult {
        func failure(
            pendingRemovals: [AppAXPendingNotificationRemoval] = []
        ) -> AppAXWindowNotificationInstallResult {
            .init(subscription: nil, newlyInstalled: [], pendingRemovals: pendingRemovals)
        }

        guard let refcon = destroyNotificationRefcon(for: windowId) else {
            return failure()
        }
        let exactOwnership = ownedSubscription.flatMap { subscription in
            subscription.windowId == windowId && CFEqual(subscription.element, element)
                ? subscription
                : nil
        }
        if ownedSubscription != nil, exactOwnership == nil {
            return failure()
        }
        var installed = exactOwnership?.notifications ?? []
        var newlyInstalled: AppAXWindowNotificationSet = []

        func rollbackNewlyInstalledNotifications() -> [AppAXPendingNotificationRemoval] {
            var pending: [AppAXPendingNotificationRemoval] = []
            for rollbackNotification in AppAXWindowNotification.allCases.reversed()
                where newlyInstalled.contains(rollbackNotification.ownership)
            {
                let rollbackResult = removeNotification(rollbackNotification)
                if rollbackResult != .success, rollbackResult != .notificationNotRegistered {
                    pending.append(
                        .init(element: element, notification: rollbackNotification)
                    )
                }
            }
            return pending
        }

        func cancelInstallation(_ error: Error) throws -> Never {
            recordPendingRemovals(rollbackNewlyInstalledNotifications())
            throw error
        }

        for notification in AppAXWindowNotification.allCases where !installed.contains(notification.ownership) {
            do {
                try checkCancellation()
            } catch {
                try cancelInstallation(error)
            }
            var result = addNotification(notification, refcon)
            if result == .notificationAlreadyRegistered {
                switch alreadyRegisteredPolicy {
                case .adopt:
                    installed.insert(notification.ownership)
                    continue
                case .reject:
                    return failure(pendingRemovals: rollbackNewlyInstalledNotifications())
                case .replace:
                    break
                }
                let removeResult = removeNotification(notification)
                if removeResult != .success, removeResult != .notificationNotRegistered {
                    var pendingRemovals = [
                        AppAXPendingNotificationRemoval(element: element, notification: notification)
                    ]
                    pendingRemovals.append(contentsOf: rollbackNewlyInstalledNotifications())
                    return failure(pendingRemovals: pendingRemovals)
                }
                do {
                    try checkCancellation()
                } catch {
                    try cancelInstallation(error)
                }
                result = addNotification(notification, refcon)
            }
            guard result == .success else {
                var pendingRemovals: [AppAXPendingNotificationRemoval] = []
                if result == .notificationAlreadyRegistered {
                    pendingRemovals.append(.init(element: element, notification: notification))
                }
                pendingRemovals.append(contentsOf: rollbackNewlyInstalledNotifications())
                return failure(pendingRemovals: pendingRemovals)
            }
            installed.insert(notification.ownership)
            newlyInstalled.insert(notification.ownership)
        }

        do {
            try checkCancellation()
        } catch {
            try cancelInstallation(error)
        }

        return .init(
            subscription: .init(windowId: windowId, element: element, notifications: installed),
            newlyInstalled: newlyInstalled,
            pendingRemovals: []
        )
    }

    nonisolated static func removeOwnedWindowNotifications(
        _ subscription: AppAXWindowSubscription,
        removeNotification: (AppAXWindowNotification) -> AXError
    ) -> [AppAXPendingNotificationRemoval] {
        var pending: [AppAXPendingNotificationRemoval] = []
        for notification in AppAXWindowNotification.allCases where subscription.owns(notification) {
            let result = removeNotification(notification)
            if result != .success, result != .notificationNotRegistered {
                pending.append(.init(element: subscription.element, notification: notification))
            }
        }
        return pending
    }

    private nonisolated static func addWindowNotifications(
        observer: AXObserver,
        element: AXUIElement,
        windowId: Int,
        ownedSubscription: AppAXWindowSubscription?,
        alreadyRegisteredPolicy: AppAXAlreadyRegisteredPolicy = .adopt,
        checkCancellation: () throws -> Void,
        recordPendingRemovals: ([AppAXPendingNotificationRemoval]) -> Void
    ) throws -> AppAXWindowNotificationInstallResult {
        let result = try installWindowNotifications(
            element: element,
            windowId: windowId,
            ownedSubscription: ownedSubscription,
            addNotification: { notification, refcon in
                AXObserverAddNotification(observer, element, notification.name, refcon)
            },
            removeNotification: { notification in
                AXObserverRemoveNotification(observer, element, notification.name)
            },
            alreadyRegisteredPolicy: alreadyRegisteredPolicy,
            checkCancellation: checkCancellation,
            recordPendingRemovals: recordPendingRemovals
        )
        if result.subscription == nil {
            FallbackFiringRecorder.shared.note(.ax, "windowSubscribeFailed")
        }
        return result
    }

    private nonisolated static func removeWindowNotifications(
        observer: AXObserver,
        subscription: AppAXWindowSubscription
    ) -> [AppAXPendingNotificationRemoval] {
        removeOwnedWindowNotifications(subscription) { notification in
            AXObserverRemoveNotification(observer, subscription.element, notification.name)
        }
    }

    private nonisolated static func appendPendingNotificationRemovals(
        _ additions: [AppAXPendingNotificationRemoval],
        to state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    ) {
        guard !additions.isEmpty else { return }
        var pending = state.value
        for addition in additions where !pending.contains(where: {
            $0.notification == addition.notification && CFEqual($0.element, addition.element)
        }) {
            pending.append(addition)
        }
        state.value = pending
    }

    private nonisolated static func drainPendingNotificationRemovals(
        _ state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        observer: AXObserver,
        checkCancellation: () throws -> Void
    ) throws {
        var remaining: [AppAXPendingNotificationRemoval] = []
        for removal in state.value {
            try checkCancellation()
            let result = AXObserverRemoveNotification(
                observer,
                removal.element,
                removal.notification.name
            )
            if result != .success, result != .notificationNotRegistered {
                remaining.append(removal)
            }
        }
        state.value = remaining
    }

    nonisolated static func hasPendingNotificationRemoval(
        for element: AXUIElement,
        in pending: [AppAXPendingNotificationRemoval]
    ) -> Bool {
        pending.contains { CFEqual($0.element, element) }
    }

    private nonisolated static func ownedSubscription(
        for element: AXUIElement,
        windowId: Int,
        in subscriptions: [Int: AppAXWindowSubscription]
    ) -> AppAXWindowSubscription? {
        if let direct = subscriptions[windowId], CFEqual(direct.element, element) {
            return direct
        }
        return subscriptions.values.first {
            CFEqual($0.element, element)
        }
    }

    nonisolated static func rebindSubscriptionOwnership(
        _ subscription: AppAXWindowSubscription?,
        oldWindowId: Int,
        newWindowId: Int
    ) -> AppAXWindowRebindSubscriptionOwnership {
        guard let subscription else { return .unowned }
        if subscription.windowId == newWindowId { return .destination }
        if subscription.windowId == oldWindowId { return .source }
        return .conflict
    }

    private nonisolated static func sameSubscription(
        _ lhs: AppAXWindowSubscription?,
        _ rhs: AppAXWindowSubscription?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.windowId == rhs.windowId
                && lhs.notifications == rhs.notifications
                && CFEqual(lhs.element, rhs.element)
        default:
            false
        }
    }

    private nonisolated static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            CFEqual(lhs, rhs)
        default:
            false
        }
    }

    private nonisolated static func stageSubscriptionRemoval(
        _ subscription: AppAXWindowSubscription,
        in state: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    ) {
        appendPendingNotificationRemovals(
            AppAXWindowNotification.allCases.compactMap { notification in
                subscription.owns(notification)
                    ? AppAXPendingNotificationRemoval(
                        element: subscription.element,
                        notification: notification
                    )
                    : nil
            },
            to: state
        )
    }

    nonisolated static func removeExactWindowState(
        expectedWindow: AXWindowRef,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    ) -> AppAXWindowStateRemovalOutcome {
        let windowId = expectedWindow.windowId
        let cachedElement = windows[windowId]
        let subscription = subscribedWindows[windowId]
        let removesCachedWindow = cachedElement.map {
            CFEqual($0, expectedWindow.element)
        } == true
        let removesSubscription = subscription.map {
            CFEqual($0.element, expectedWindow.element)
        } == true
        if removesSubscription, let subscription {
            stageSubscriptionRemoval(subscription, in: pendingNotificationRemovals)
            subscribedWindows[windowId] = nil
        }
        if removesCachedWindow {
            windows[windowId] = nil
        }
        return .init(
            removedCachedWindow: removesCachedWindow,
            removedSubscription: removesSubscription
        )
    }

    nonisolated static func hasConflictingWindowIdentity(
        for element: AXUIElement,
        destinationWindowId: Int,
        permittedSourceWindowId: Int?,
        windows: [Int: AXUIElement],
        subscriptions: [Int: AppAXWindowSubscription]
    ) -> Bool {
        windows.contains { windowId, candidate in
            windowId != destinationWindowId
                && windowId != permittedSourceWindowId
                && CFEqual(candidate, element)
        } || subscriptions.contains { windowId, subscription in
            (windowId != destinationWindowId && windowId != permittedSourceWindowId)
                && CFEqual(subscription.element, element)
        }
    }

    private nonisolated static func cleanUpUnpublishedWindowRebind(
        _ binding: AppAXWindowRebindBinding,
        additionalSubscriptions: [AppAXWindowSubscription] = [],
        observer: AXObserver,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>
    ) {
        func removeIfUnadopted(_ unpublished: AppAXWindowSubscription) {
            var removable = unpublished
            if let current = ownedSubscription(
                for: unpublished.element,
                windowId: unpublished.windowId,
                in: subscribedWindows.value
            ) {
                removable.notifications.subtract(current.notifications)
            }
            guard !removable.notifications.isEmpty else { return }
            appendPendingNotificationRemovals(
                removeWindowNotifications(observer: observer, subscription: removable),
                to: pendingNotificationRemovals
            )
        }

        if !binding.newlyInstalledNotifications.isEmpty,
           var stagedSubscription = binding.stagedSubscription
        {
            stagedSubscription.notifications = binding.newlyInstalledNotifications
            removeIfUnadopted(stagedSubscription)
        }
        for subscription in additionalSubscriptions {
            removeIfUnadopted(subscription)
        }
    }

    private nonisolated static func shouldRemoveMissingWindow(windowId: Int) -> Bool {
        if let uintWindowId = UInt32(exactly: windowId),
           AXWindowService.hasPinnedAXElement(for: uintWindowId)
        {
            return false
        }
        return true
    }

    nonisolated static func replaceEnumeratedWindowCache(
        with newWindows: [Int: AXUIElement],
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        bindingGeneration: UInt64,
        windowBindingEpoch: LockedGenerationEpoch
    ) -> Bool {
        windowBindingEpoch.performIfCurrent(bindingGeneration) {
            windows.value = newWindows
        } != nil
    }

    nonisolated static func recordFinalEnumeratedWindow(
        _ window: AXEnumeratedWindow,
        in windows: inout [AXEnumeratedWindow],
        isFirstOccurrence: Bool
    ) {
        let windowId = window.axRef.windowId
        if isFirstOccurrence {
            windows.append(window)
        } else if let index = windows.firstIndex(where: { $0.axRef.windowId == windowId }) {
            windows[index] = window
        }
    }

    func getWindowsAsync(
        timeoutSeconds: TimeInterval = 0.5,
        includeTitle: Bool = false,
        includedWindowIds: Set<Int>? = nil
    ) async throws -> [AXEnumeratedWindow] {
        guard let thread else {
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationFailed,
                    pid: pid,
                    bundleId: nsApp.bundleIdentifier,
                    reason: "context_thread_unavailable",
                    callbackGeneration: callbackGeneration
                )
            )
            throw AXWindowEnumerationError.contextUnavailable
        }
        nonisolated(unsafe) let appThread = thread
        WindowAdmissionTrace.record(
            .init(
                action: .enumerationStarted,
                pid: pid,
                bundleId: nsApp.bundleIdentifier,
                callbackGeneration: callbackGeneration
            )
        )

        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let inspectionContext = AXWindowInspectionContext(
            appPolicy: nsApp.activationPolicy,
            bundleId: nsApp.bundleIdentifier,
            includeTitle: includeTitle
        )
        let enumerationCallbackGeneration = callbackGeneration
        let enumerationBindingGeneration = windowBindingEpoch.current()
        let results = try await appThread.runInLoop(timeout: timeout) { [
            pid,
            axApp,
            windows,
            axObserver,
            pendingNotificationRemovals,
            windowBindingEpoch,
            inspectionContext,
            includedWindowIds,
            enumerationCallbackGeneration,
            enumerationBindingGeneration
        ] job -> [AXEnumeratedWindow] in
            let observer = axObserver.value
            if let observer {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            let windowElements = try AXWindowEnumerationInspector.applicationWindowElements(
                axApp.value,
                deadline: deadline,
                checkCancellation: { try job.checkCancellation() }
            )
            if windowElements.isEmpty {
                WindowAdmissionTrace.record(
                    .init(
                        action: .enumerationEmpty,
                        pid: pid,
                        count: 0,
                        callbackGeneration: enumerationCallbackGeneration
                    )
                )
            }

            var results: [AXEnumeratedWindow] = []
            results.reserveCapacity(windowElements.count)
            var seenIds = Set<Int>(minimumCapacity: windowElements.count)
            var newWindows: [Int: AXUIElement] = Dictionary(minimumCapacity: windowElements.count)

            for element in windowElements {
                try job.checkCancellation()
                guard let windowId = try AXWindowEnumerationInspector.windowId(
                    for: element,
                    deadline: deadline,
                    checkCancellation: { try job.checkCancellation() }
                ) else {
                    continue
                }
                if let includedWindowIds, !includedWindowIds.contains(windowId) {
                    if let existingElement = windows[windowId] {
                        newWindows[windowId] = existingElement
                        seenIds.insert(windowId)
                    }
                    continue
                }
                guard let enumeratedWindow = try AXWindowEnumerationInspector.inspect(
                    element,
                    windowId: windowId,
                    deadline: deadline,
                    context: inspectionContext,
                    checkCancellation: { try job.checkCancellation() }
                ) else {
                    continue
                }
                if let resolvedElementPid = enumeratedWindow.axPid, resolvedElementPid != pid {
                    DiagnosticsEventRecorder.shared.recordLifecycle(
                        name: "ax.pidMismatch.expected=\(pid)",
                        pid: resolvedElementPid,
                        windowId: CGWindowID(windowId)
                    )
                }

                WindowAdmissionTrace.record(
                    .init(
                        action: .topLevelAccepted,
                        pid: pid,
                        windowId: windowId,
                        axPid: enumeratedWindow.axPid,
                        role: enumeratedWindow.role,
                        subrole: enumeratedWindow.subrole,
                        callbackGeneration: enumerationCallbackGeneration,
                        axRef: enumeratedWindow.axRef
                    )
                )
                newWindows[windowId] = element
                let isFirstOccurrence = seenIds.insert(windowId).inserted
                AppAXContext.recordFinalEnumeratedWindow(
                    enumeratedWindow,
                    in: &results,
                    isFirstOccurrence: isFirstOccurrence
                )
            }

            let existingWindowIds = Array(windows.value.keys)
            for existingId in existingWindowIds where !seenIds.contains(existingId) {
                let existingElement = windows[existingId]
                try job.checkCancellation()
                let shouldRemove = AppAXContext.shouldRemoveMissingWindow(
                    windowId: existingId
                )
                try job.checkCancellation()
                if shouldRemove {
                    WindowAdmissionTrace.record(
                        .init(
                            action: .admissionDisappeared,
                            pid: pid,
                            windowId: existingId,
                            reason: "missing_from_ax_windows",
                            callbackGeneration: enumerationCallbackGeneration,
                            axRef: existingElement.map {
                                AXWindowRef(element: $0, windowId: existingId)
                            }
                        )
                    )
                } else if let existingElement {
                    newWindows[existingId] = existingElement
                }
            }

            try job.performUnlessCancelled {
                guard AppAXContext.replaceEnumeratedWindowCache(
                    with: newWindows,
                    windows: windows,
                    bindingGeneration: enumerationBindingGeneration,
                    windowBindingEpoch: windowBindingEpoch
                ) else { throw CancellationError() }
            }
            if let observer {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            WindowAdmissionTrace.record(
                .init(
                    action: .enumerationCompleted,
                    pid: pid,
                    count: results.count,
                    callbackGeneration: enumerationCallbackGeneration
                )
            )
            return results
        }

        return results
    }

    func cancelFrameJob(for windowId: Int) {
        _ = frameWriteGenerations.nextGeneration(for: windowId)
    }

    func cancelParkFrameJob(for windowId: Int) {
        _ = parkFrameWriteGenerations.nextGeneration(for: windowId)
    }

    func invalidateWindowIdentity() {
        _ = windowBindingEpoch.advance()
    }

    nonisolated static func preservesCrossIdentitySubscription(
        _ subscription: AppAXWindowSubscription?,
        for window: AXWindowRef
    ) -> Bool {
        subscription.map {
            $0.windowId != window.windowId && CFEqual($0.element, window.element)
        } == true
    }

    nonisolated static func resolvedWindowBindingResult(
        hasObserver: Bool,
        readyCount: Int,
        targetCount: Int,
        retryRequired: Bool
    ) -> AppAXWindowBindingResult {
        if retryRequired { return .retryRequired }
        if !hasObserver || readyCount == targetCount { return .bound }
        return .superseded
    }

    func bindWindows(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: false,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }

    func reconcileWindowBindings(
        _ boundWindows: [Int: AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        updateWindowBindings(
            boundWindows,
            pruningUnboundState: true,
            timeoutSeconds: timeoutSeconds,
            completion: completion
        )
    }

    private func updateWindowBindings(
        _ boundWindows: [Int: AXWindowRef],
        pruningUnboundState: Bool,
        timeoutSeconds: TimeInterval,
        completion: @escaping @MainActor @Sendable (AppAXWindowBindingResult) -> Void
    ) {
        guard pruningUnboundState || !boundWindows.isEmpty else {
            completion(.bound)
            return
        }
        guard let thread else {
            completion(.retryRequired)
            return
        }
        let bindingGeneration = windowBindingEpoch.advance()
        nonisolated(unsafe) let appThread = thread
        appThread.runInLoopAsync { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals,
            windowBindingEpoch
        ] job in
            let result: AppAXWindowBindingResult
            do {
                result = try AppAXContext.performWindowBinding(
                    boundWindows,
                    bindingGeneration: bindingGeneration,
                    pruningUnboundState: pruningUnboundState,
                    timeoutSeconds: timeoutSeconds,
                    windows: windows,
                    windowBindingEpoch: windowBindingEpoch,
                    axObserver: axObserver,
                    subscribedWindows: subscribedWindows,
                    pendingNotificationRemovals: pendingNotificationRemovals,
                    job: job
                )
            } catch is AppAXWindowBindingSuperseded {
                result = .superseded
            } catch is CancellationError {
                result = .superseded
            } catch {
                result = .retryRequired
            }
            scheduleOnMainRunLoop {
                completion(result)
            }
        }
    }

    nonisolated static func performWindowBinding(
        _ boundWindows: [Int: AXWindowRef],
        bindingGeneration: UInt64,
        pruningUnboundState: Bool,
        timeoutSeconds: TimeInterval,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        windowBindingEpoch: LockedGenerationEpoch,
        axObserver: ThreadGuardedValue<AXObserver?>,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        pendingNotificationRemovals: ThreadGuardedValue<[AppAXPendingNotificationRemoval]>,
        job: RunLoopJob
    ) throws -> AppAXWindowBindingResult {
        guard windowBindingEpoch.isCurrent(bindingGeneration) else {
            return .superseded
        }
        let observer = axObserver.value
        var retryRequired = false
        if let observer {
            try drainPendingNotificationRemovals(
                pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            retryRequired = retryRequired || !pendingNotificationRemovals.value.isEmpty
        }
        if pruningUnboundState {
            try job.performUnlessCancelled {
                guard windowBindingEpoch.performIfCurrent(bindingGeneration, {
                    for (windowId, subscription) in subscribedWindows.value where boundWindows[windowId].map({
                        CFEqual($0.element, subscription.element)
                    }) != true {
                        if observer != nil {
                            stageSubscriptionRemoval(subscription, in: pendingNotificationRemovals)
                        }
                        subscribedWindows[windowId] = nil
                    }
                    for (windowId, element) in windows.value where boundWindows[windowId].map({
                        CFEqual($0.element, element)
                    }) != true {
                        windows[windowId] = nil
                    }
                    return true
                }) == true else {
                    throw AppAXWindowBindingSuperseded()
                }
            }
            if let observer {
                try drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
                retryRequired = !pendingNotificationRemovals.value.isEmpty
            }
        }
        var stagedSubscriptions: [Int: (
            subscription: AppAXWindowSubscription,
            newlyInstalled: AppAXWindowNotificationSet
        )] = [:]
        var subscriptionReadyCount = 0
        var committedSubscriptions = false
        defer {
            if !committedSubscriptions, let observer {
                for staged in stagedSubscriptions.values where !staged.newlyInstalled.isEmpty {
                    var rollback = staged.subscription
                    rollback.notifications = staged.newlyInstalled
                    appendPendingNotificationRemovals(
                        removeWindowNotifications(observer: observer, subscription: rollback),
                        to: pendingNotificationRemovals
                    )
                }
            }
        }
        if let observer {
            for window in boundWindows.values {
                try job.checkCancellation()
                guard windowBindingEpoch.isCurrent(bindingGeneration) else {
                    throw AppAXWindowBindingSuperseded()
                }
                guard !hasPendingNotificationRemoval(
                    for: window.element,
                    in: pendingNotificationRemovals.value
                ) else {
                    retryRequired = true
                    continue
                }
                let ownedSubscription = ownedSubscription(
                    for: window.element,
                    windowId: window.windowId,
                    in: subscribedWindows.value
                )
                if preservesCrossIdentitySubscription(ownedSubscription, for: window) {
                    continue
                }
                if ownedSubscription?.notifications == .lifecycle {
                    subscriptionReadyCount += 1
                    continue
                }
                AXUIElementSetMessagingTimeout(window.element, Float(timeoutSeconds))
                defer { AXUIElementSetMessagingTimeout(window.element, 0) }
                let installation = try addWindowNotifications(
                    observer: observer,
                    element: window.element,
                    windowId: window.windowId,
                    ownedSubscription: ownedSubscription,
                    alreadyRegisteredPolicy: ownedSubscription == nil ? .replace : .adopt,
                    checkCancellation: { try job.checkCancellation() },
                    recordPendingRemovals: {
                        appendPendingNotificationRemovals($0, to: pendingNotificationRemovals)
                    }
                )
                appendPendingNotificationRemovals(
                    installation.pendingRemovals,
                    to: pendingNotificationRemovals
                )
                guard let subscription = installation.subscription else {
                    retryRequired = true
                    continue
                }
                stagedSubscriptions[window.windowId] = (
                    subscription,
                    installation.newlyInstalled
                )
                subscriptionReadyCount += 1
                try job.checkCancellation()
            }
        }
        try job.performUnlessCancelled {
            guard windowBindingEpoch.performIfCurrent(bindingGeneration, {
                for window in boundWindows.values {
                    if let previous = subscribedWindows[window.windowId],
                       !CFEqual(previous.element, window.element)
                    {
                        stageSubscriptionRemoval(previous, in: pendingNotificationRemovals)
                        subscribedWindows[window.windowId] = nil
                    }
                    if let staged = stagedSubscriptions[window.windowId] {
                        subscribedWindows[window.windowId] = staged.subscription
                    }
                    windows[window.windowId] = window.element
                }
                return true
            }) == true else {
                throw AppAXWindowBindingSuperseded()
            }
        }
        committedSubscriptions = true
        if let observer {
            try drainPendingNotificationRemovals(
                pendingNotificationRemovals,
                observer: observer,
                checkCancellation: { try job.checkCancellation() }
            )
            retryRequired = retryRequired || !pendingNotificationRemovals.value.isEmpty
        }
        return resolvedWindowBindingResult(
            hasObserver: observer != nil,
            readyCount: subscriptionReadyCount,
            targetCount: boundWindows.count,
            retryRequired: retryRequired
        )
    }

    func rebindWindowAsync(
        oldWindowId: Int,
        newWindow: AXWindowRef,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> AppAXWindowRebindBinding? {
        guard let thread else { return nil }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        return try await appThread.runInLoop(
            timeout: timeout,
            onUndeliveredSuccess: { [
                axObserver,
                subscribedWindows,
                pendingNotificationRemovals
            ] binding in
                guard let binding,
                      let observer = axObserver.value
                else {
                    return
                }
                AppAXContext.cleanUpUnpublishedWindowRebind(
                    binding,
                    observer: observer,
                    subscribedWindows: subscribedWindows,
                    pendingNotificationRemovals: pendingNotificationRemovals
                )
            }
        ) { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] job in
            let observer = axObserver.value
            if let observer {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            let destinationWindowElement = windows[newWindow.windowId]
            let destinationSubscription = subscribedWindows[newWindow.windowId]
            func result(
                stagedSubscription: AppAXWindowSubscription? = nil,
                newlyInstalledNotifications: AppAXWindowNotificationSet = [],
                requiresRetag: Bool = false,
                hasLifecycleObserver: Bool
            ) -> AppAXWindowRebindBinding {
                .init(
                    destinationWindowElement: destinationWindowElement,
                    destinationSubscription: destinationSubscription,
                    stagedSubscription: stagedSubscription,
                    newlyInstalledNotifications: newlyInstalledNotifications,
                    requiresRetag: requiresRetag,
                    hasLifecycleObserver: hasLifecycleObserver
                )
            }
            guard let observer else {
                try job.checkCancellation()
                return result(hasLifecycleObserver: false)
            }
            guard !AppAXContext.hasPendingNotificationRemoval(
                for: newWindow.element,
                in: pendingNotificationRemovals.value
            ) else {
                return nil
            }
            let ownedSubscription = AppAXContext.ownedSubscription(
                for: newWindow.element,
                windowId: newWindow.windowId,
                in: subscribedWindows.value
            )
            switch AppAXContext.rebindSubscriptionOwnership(
                ownedSubscription,
                oldWindowId: oldWindowId,
                newWindowId: newWindow.windowId
            ) {
            case .source:
                try job.checkCancellation()
                return result(requiresRetag: true, hasLifecycleObserver: true)
            case .conflict:
                return nil
            case .unowned,
                 .destination:
                break
            }
            if let ownedSubscription, ownedSubscription.notifications == .lifecycle {
                try job.checkCancellation()
                return result(hasLifecycleObserver: true)
            }
            AXUIElementSetMessagingTimeout(newWindow.element, Float(timeoutSeconds))
            defer { AXUIElementSetMessagingTimeout(newWindow.element, 0) }
            let installation = try AppAXContext.addWindowNotifications(
                observer: observer,
                element: newWindow.element,
                windowId: newWindow.windowId,
                ownedSubscription: ownedSubscription,
                alreadyRegisteredPolicy: ownedSubscription == nil ? .reject : .adopt,
                checkCancellation: { try job.checkCancellation() },
                recordPendingRemovals: {
                    AppAXContext.appendPendingNotificationRemovals(
                        $0,
                        to: pendingNotificationRemovals
                    )
                }
            )
            AppAXContext.appendPendingNotificationRemovals(
                installation.pendingRemovals,
                to: pendingNotificationRemovals
            )
            guard let subscription = installation.subscription else { return nil }
            return result(
                stagedSubscription: subscription,
                newlyInstalledNotifications: installation.newlyInstalled,
                hasLifecycleObserver: true
            )
        }
    }

    func rollbackWindowRebind(_ binding: AppAXWindowRebindBinding, newWindow: AXWindowRef) {
        guard !binding.newlyInstalledNotifications.isEmpty,
              let thread
        else {
            return
        }
        nonisolated(unsafe) let appThread = thread
        appThread.runInLoopAsync { [
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] _ in
            guard let observer = axObserver.value else { return }
            AppAXContext.cleanUpUnpublishedWindowRebind(
                binding,
                observer: observer,
                subscribedWindows: subscribedWindows,
                pendingNotificationRemovals: pendingNotificationRemovals
            )
        }
    }

    func commitWindowRebindAsync(
        oldWindow: AXWindowRef,
        newWindow: AXWindowRef,
        binding: AppAXWindowRebindBinding,
        retireOldWindowState: Bool,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> Bool {
        guard let thread else { return false }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        return try await appThread.runInLoop(timeout: timeout) { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] job in
            let observer = axObserver.value
            var additionalUnpublishedSubscriptions: [AppAXWindowSubscription] = []
            var committedCache = false
            defer {
                if !committedCache, let observer {
                    AppAXContext.cleanUpUnpublishedWindowRebind(
                        binding,
                        additionalSubscriptions: additionalUnpublishedSubscriptions,
                        observer: observer,
                        subscribedWindows: subscribedWindows,
                        pendingNotificationRemovals: pendingNotificationRemovals
                    )
                }
            }
            if binding.hasLifecycleObserver {
                guard observer != nil else { return false }
                guard !AppAXContext.hasPendingNotificationRemoval(
                    for: newWindow.element,
                    in: pendingNotificationRemovals.value
                ) else {
                    return false
                }
            }
            if let observer {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            if binding.hasLifecycleObserver {
                guard !AppAXContext.hasPendingNotificationRemoval(
                    for: newWindow.element,
                    in: pendingNotificationRemovals.value
                ) else {
                    return false
                }
            }
            guard AppAXContext.sameElement(
                windows[newWindow.windowId],
                binding.destinationWindowElement
            ), AppAXContext.sameSubscription(
                subscribedWindows[newWindow.windowId],
                binding.destinationSubscription
            ) else {
                return false
            }
            let permittedSourceWindowId = binding.requiresRetag ? oldWindow.windowId : nil
            guard !AppAXContext.hasConflictingWindowIdentity(
                for: newWindow.element,
                destinationWindowId: newWindow.windowId,
                permittedSourceWindowId: permittedSourceWindowId,
                windows: windows.value,
                subscriptions: subscribedWindows.value
            ) else {
                return false
            }

            let destinationSubscription: AppAXWindowSubscription?
            if binding.hasLifecycleObserver {
                guard let observer else { return false }
                if binding.requiresRetag {
                    let sourceSubscription = AppAXContext.ownedSubscription(
                        for: newWindow.element,
                        windowId: oldWindow.windowId,
                        in: subscribedWindows.value
                    )
                    guard let sourceSubscription,
                          sourceSubscription.windowId == oldWindow.windowId
                    else {
                        return false
                    }
                    AppAXContext.stageSubscriptionRemoval(
                        sourceSubscription,
                        in: pendingNotificationRemovals
                    )
                    subscribedWindows[sourceSubscription.windowId] = nil
                    try AppAXContext.drainPendingNotificationRemovals(
                        pendingNotificationRemovals,
                        observer: observer,
                        checkCancellation: { try job.checkCancellation() }
                    )
                    guard !AppAXContext.hasPendingNotificationRemoval(
                        for: newWindow.element,
                        in: pendingNotificationRemovals.value
                    ) else {
                        return false
                    }
                }
                let installation = try AppAXContext.addWindowNotifications(
                    observer: observer,
                    element: newWindow.element,
                    windowId: newWindow.windowId,
                    ownedSubscription: nil,
                    alreadyRegisteredPolicy: .adopt,
                    checkCancellation: { try job.checkCancellation() },
                    recordPendingRemovals: {
                        AppAXContext.appendPendingNotificationRemovals(
                            $0,
                            to: pendingNotificationRemovals
                        )
                    }
                )
                AppAXContext.appendPendingNotificationRemovals(
                    installation.pendingRemovals,
                    to: pendingNotificationRemovals
                )
                guard let subscription = installation.subscription else { return false }
                destinationSubscription = subscription
                if !installation.newlyInstalled.isEmpty {
                    var installed = subscription
                    installed.notifications = installation.newlyInstalled
                    additionalUnpublishedSubscriptions.append(installed)
                }
            } else {
                destinationSubscription = nil
            }

            let cleanup = try AppAXContext.commitWindowRebindCache(
                oldWindow: oldWindow,
                newWindow: newWindow,
                destinationSubscription: destinationSubscription,
                retireOldWindowState: retireOldWindowState,
                binding: binding,
                windows: windows,
                subscribedWindows: subscribedWindows,
                job: job
            )
            committedCache = true
            for subscription in cleanup.subscriptions {
                AppAXContext.stageSubscriptionRemoval(
                    subscription,
                    in: pendingNotificationRemovals
                )
            }
            if let observer {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            return true
        }
    }

    nonisolated static func commitWindowRebindCache(
        oldWindow: AXWindowRef,
        newWindow: AXWindowRef,
        destinationSubscription: AppAXWindowSubscription?,
        retireOldWindowState: Bool,
        binding: AppAXWindowRebindBinding,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        subscribedWindows: ThreadGuardedValue<[Int: AppAXWindowSubscription]>,
        job: RunLoopJob
    ) throws -> AppAXSubscriptionCleanup {
        try job.performUnlessCancelled {
            guard sameElement(windows[newWindow.windowId], binding.destinationWindowElement),
                  sameSubscription(
                      subscribedWindows[newWindow.windowId],
                      binding.destinationSubscription
                  )
            else {
                throw AXWindowEnumerationError.subscriptionFailed
            }
            let oldWindowId = oldWindow.windowId
            let newWindowId = newWindow.windowId
            let previousDestinationSubscription = subscribedWindows[newWindowId]
            var retiredSubscriptions: [AppAXWindowSubscription] = []
            if let previousDestinationSubscription,
               !CFEqual(previousDestinationSubscription.element, newWindow.element)
            {
                retiredSubscriptions.append(previousDestinationSubscription)
            }
            if retireOldWindowState,
               oldWindowId != newWindowId,
               let oldSubscription = subscribedWindows[oldWindowId],
               CFEqual(oldSubscription.element, oldWindow.element),
               !CFEqual(oldSubscription.element, newWindow.element),
               !retiredSubscriptions.contains(where: {
                   CFEqual($0.element, oldSubscription.element)
               })
            {
                retiredSubscriptions.append(oldSubscription)
            }

            windows[newWindowId] = newWindow.element
            subscribedWindows[newWindowId] = destinationSubscription
            if retireOldWindowState, oldWindowId != newWindowId {
                if subscribedWindows[oldWindowId].map({
                    CFEqual($0.element, oldWindow.element)
                }) == true {
                    subscribedWindows[oldWindowId] = nil
                }
                if windows[oldWindowId].map({
                    CFEqual($0, oldWindow.element)
                        || (binding.requiresRetag && CFEqual($0, newWindow.element))
                }) == true {
                    windows[oldWindowId] = nil
                }
            }
            return AppAXSubscriptionCleanup(subscriptions: retiredSubscriptions)
        }
    }

    func prepareWindowRebind(from oldWindowId: Int, to newWindowId: Int) {
        frameWriteGenerations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)
        parkFrameWriteGenerations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)
        frameWriteSuppression.moveIfPresent(from: oldWindowId, to: newWindowId)
        _ = windowBindingEpoch.advance()
    }

    func prepareWindowRemoval(for windowId: Int) {
        frameWriteGenerations.invalidateAndRemove(windowId)
        parkFrameWriteGenerations.invalidateAndRemove(windowId)
        frameWriteSuppression.remove(windowId)
    }

    func retainFrameState(only windowIds: Set<Int>) {
        frameWriteGenerations.retainOnly(windowIds)
        parkFrameWriteGenerations.retainOnly(windowIds)
        frameWriteSuppression.retainOnly(windowIds)
    }

    nonisolated static func acceptsRefreshedFrameElement(
        cachedElement: AXUIElement,
        refreshedElement: AXUIElement,
        windowId: Int,
        requestGeneration: UInt64,
        generations: LockedWindowGenerationMap
    ) -> Bool {
        guard generations.isCurrent(requestGeneration, for: windowId) else { return false }
        guard CFEqual(cachedElement, refreshedElement) else {
            _ = generations.nextGeneration(for: windowId)
            return false
        }
        return generations.isCurrent(requestGeneration, for: windowId)
    }

    func removeWindowStateAsync(
        expectedWindow: AXWindowRef,
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> AppAXWindowStateRemovalOutcome {
        guard let thread else {
            return .init(removedCachedWindow: false, removedSubscription: false)
        }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        return try await appThread.runInLoop(timeout: timeout) { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] job in
            let outcome = try job.performUnlessCancelled {
                let outcome = AppAXContext.removeExactWindowState(
                    expectedWindow: expectedWindow,
                    windows: windows,
                    subscribedWindows: subscribedWindows,
                    pendingNotificationRemovals: pendingNotificationRemovals
                )
                return outcome
            }
            if let observer = axObserver.value {
                try AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: { try job.checkCancellation() }
                )
            }
            return outcome
        }
    }

    func removeWindowState(expectedWindow: AXWindowRef) {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread

        appThread.runInLoopAsync { [
            windows,
            axObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] _ in
            _ = AppAXContext.removeExactWindowState(
                expectedWindow: expectedWindow,
                windows: windows,
                subscribedWindows: subscribedWindows,
                pendingNotificationRemovals: pendingNotificationRemovals
            )
            if let observer = axObserver.value {
                try? AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: observer,
                    checkCancellation: {}
                )
            }
        }
    }

    func suppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            _ = frameWriteGenerations.nextGeneration(for: windowId)
            frameWriteSuppression.insert(windowId)
        }
    }

    func unsuppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            frameWriteSuppression.remove(windowId)
        }
    }

    func setMacOSAppHidden(_ hidden: Bool, for windowIds: [Int]) {
        frameWriteSuppression.setHardSuppressed(hidden)
        if hidden {
            closingFrameWriteGenerations.invalidateAll()
        }
        for windowId in windowIds {
            _ = frameWriteGenerations.nextGeneration(for: windowId)
            _ = parkFrameWriteGenerations.nextGeneration(for: windowId)
        }
    }

    func setClosingFramesBatch(_ frames: [AXClosingFrameTarget]) {
        guard let thread, !frames.isEmpty else { return }
        nonisolated(unsafe) let appThread = thread
        let requests = frames.map {
            AppAXClosingFrameWriteRequest(
                target: $0,
                generation: closingFrameWriteGenerations.nextGeneration(for: $0.animationId)
            )
        }
        let batchId = UUID()

        let batchJob = appThread.runInLoopAsync { [self] job in
            for request in requests {
                _ = applyClosingFrameWriteRequest(
                    request,
                    generations: closingFrameWriteGenerations,
                    isCancelled: {
                        job.isCancelled || frameWriteSuppression.isHardSuppressed()
                    }
                )
                closingFrameWriteGenerations.removeIfCurrent(
                    request.generation,
                    for: request.target.animationId
                )
            }

            scheduleOnMainRunLoop { [weak self] in
                self?.activeClosingFrameBatchJobs.removeValue(forKey: batchId)
            }
        }
        activeClosingFrameBatchJobs[batchId] = batchJob
    }

    func setFramesBatch(
        _ frames: [AXFrameApplicationRequest],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        setFrameBatch(
            frames,
            generations: frameWriteGenerations,
            suppression: frameWriteSuppression,
            hardSuppression: nil,
            forceVerification: false,
            completion: completion
        )
    }

    func setParkFramesBatch(
        _ frames: [AXFrameApplicationRequest],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        setFrameBatch(
            frames,
            generations: parkFrameWriteGenerations,
            suppression: nil,
            hardSuppression: frameWriteSuppression,
            forceVerification: true,
            completion: completion
        )
    }

    private func setFrameBatch(
        _ frames: [AXFrameApplicationRequest],
        generations: LockedWindowGenerationMap,
        suppression: LockedWindowIdSet?,
        hardSuppression: LockedWindowIdSet?,
        forceVerification: Bool,
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        guard let thread else {
            completion(
                frames.map {
                    AXFrameApplyResult(
                        requestId: $0.requestId,
                        pid: $0.pid,
                        windowId: $0.windowId,
                        expectedWindow: $0.expectedWindow,
                        targetFrame: $0.frame,
                        currentFrameHint: $0.currentFrameHint,
                        writeResult: .skipped(
                            targetFrame: $0.frame,
                            currentFrameHint: $0.currentFrameHint,
                            failureReason: .contextUnavailable
                        )
                    )
                }
            )
            return
        }
        nonisolated(unsafe) let appThread = thread
        let requests = frames.map {
            AppAXFrameWriteRequest(
                requestId: $0.requestId,
                pid: $0.pid,
                windowId: $0.windowId,
                expectedWindow: $0.expectedWindow,
                frame: $0.frame,
                currentFrameHint: $0.currentFrameHint,
                generation: generations.nextGeneration(for: $0.windowId),
                verify: forceVerification || $0.verify
            )
        }
        let batchId = UUID()
        let currentPid = pid

        let batchJob = appThread.runInLoopAsync { [self, axApp] job in
            let latencyActive = AXWriteLatencyTrace.shared.isActive
            let batchStart = latencyActive ? CACurrentMediaTime() : 0
            var slowestWriteMs = 0.0
            let enhancedUIKey = "AXEnhancedUserInterface" as CFString
            var wasEnabled = false
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp.value, enhancedUIKey, &value) == .success,
               let boolValue = value as? Bool
            {
                wasEnabled = boolValue
            }

            if wasEnabled {
                AXUIElementSetAttributeValue(axApp.value, enhancedUIKey, kCFBooleanFalse)
            }

            defer {
                if wasEnabled {
                    AXUIElementSetAttributeValue(axApp.value, enhancedUIKey, kCFBooleanTrue)
                }
            }

            var results: [AXFrameApplyResult] = []
            results.reserveCapacity(requests.count)

            for request in requests {
                if job.isCancelled {
                    results.append(
                        AXFrameApplyResult(
                            requestId: request.requestId,
                            pid: request.pid,
                            windowId: request.windowId,
                            expectedWindow: request.expectedWindow,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .cancelled
                            )
                        )
                    )
                    continue
                }
                if !generations.isCurrent(request.generation, for: request.windowId) {
                    results.append(
                        AXFrameApplyResult(
                            requestId: request.requestId,
                            pid: request.pid,
                            windowId: request.windowId,
                            expectedWindow: request.expectedWindow,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .cancelled
                            )
                        )
                    )
                    continue
                }
                if hardSuppression?.isHardSuppressed() == true
                    || suppression?.contains(request.windowId) == true
                {
                    results.append(
                        AXFrameApplyResult(
                            requestId: request.requestId,
                            pid: request.pid,
                            windowId: request.windowId,
                            expectedWindow: request.expectedWindow,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .suppressed
                            )
                        )
                    )
                    continue
                }
                let writeStart = latencyActive ? CACurrentMediaTime() : 0
                results.append(
                    applyFrameWriteRequest(
                        request,
                        pid: currentPid,
                        generations: generations
                    )
                )
                if latencyActive {
                    slowestWriteMs = max(slowestWriteMs, (CACurrentMediaTime() - writeStart) * 1000)
                }
            }

            if latencyActive {
                AXWriteLatencyTrace.shared.record(
                    AXWriteLatencyTrace.Record(
                        mediaTime: CACurrentMediaTime(),
                        pid: currentPid,
                        count: requests.count,
                        totalMs: (CACurrentMediaTime() - batchStart) * 1000,
                        slowestMs: slowestWriteMs,
                        enhancedUI: wasEnabled
                    )
                )
            }

            scheduleOnMainRunLoop { [weak self] in
                self?.activeFrameBatchJobs.removeValue(forKey: batchId)
                completion(results)
            }
        }
        activeFrameBatchJobs[batchId] = batchJob
    }

    func destroy() {
        if thread != nil {
            WindowAdmissionTrace.record(
                .init(
                    action: .endpointDestroyed,
                    pid: pid,
                    bundleId: nsApp.bundleIdentifier,
                    callbackGeneration: callbackGeneration
                )
            )
        }
        if let axObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: axObserverCallbackKey)
        }
        if let focusedWindowObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: focusedWindowObserverCallbackKey)
        }

        if AppAXContext.contexts[pid] === self {
            AppAXContext.contexts.removeValue(forKey: pid)
        }

        for (_, job) in activeFrameBatchJobs {
            job.cancel()
        }
        activeFrameBatchJobs = [:]
        for (_, job) in activeClosingFrameBatchJobs {
            job.cancel()
        }
        activeClosingFrameBatchJobs = [:]
        closingFrameWriteGenerations.invalidateAll()

        nonisolated(unsafe) let appThread = thread
        appThread?.runInLoopAsync { [
            windows,
            axApp,
            axObserver,
            focusedWindowObserver,
            subscribedWindows,
            pendingNotificationRemovals
        ] _ in
            let subscribed = subscribedWindows.valueIfExists ?? [:]
            if let obs = axObserver.valueIfExists.flatMap({ $0 }) {
                for (_, subscription) in subscribed {
                    _ = AppAXContext.removeWindowNotifications(
                        observer: obs,
                        subscription: subscription
                    )
                }
                try? AppAXContext.drainPendingNotificationRemovals(
                    pendingNotificationRemovals,
                    observer: obs,
                    checkCancellation: {}
                )
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
            if let focusObs = focusedWindowObserver.valueIfExists.flatMap({ $0 }) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
            }
            subscribedWindows.destroy()
            pendingNotificationRemovals.destroy()
            axObserver.destroy()
            focusedWindowObserver.destroy()
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil
    }

    static func garbageCollect() {
        for (_, context) in contexts {
            if context.nsApp.isTerminated {
                context.destroy()
            }
        }
    }
}

@discardableResult
func applyClosingFrameWriteRequest(
    _ request: AppAXClosingFrameWriteRequest,
    generations: LockedClosingFrameGenerationMap,
    isCancelled: () -> Bool = { false },
    writeFrame: (AXWindowRef, CGRect, CGRect?, Bool) -> AXFrameWriteResult = {
        AXWindowService.setFrame($0, frame: $1, currentFrameHint: $2, verify: $3)
    }
) -> Bool {
    guard !isCancelled(),
          generations.isCurrent(request.generation, for: request.target.animationId)
    else {
        return false
    }
    _ = writeFrame(
        request.target.expectedWindow,
        request.target.frame,
        request.target.currentFrameHint,
        false
    )
    return true
}

func applyFrameWriteRequest(
    _ request: AppAXFrameWriteRequest,
    pid: pid_t,
    generations: LockedWindowGenerationMap,
    writeFrame: (AXWindowRef, CGRect, CGRect?, Bool) -> AXFrameWriteResult = {
        AXWindowService.setFrame($0, frame: $1, currentFrameHint: $2, verify: $3)
    },
    refreshWindow: (UInt32, pid_t) -> AXWindowRef? = {
        AXWindowService.axWindowRef(for: $0, pid: $1)
    }
) -> AXFrameApplyResult {
    let targetFrame = request.frame
    let currentFrameHint = request.currentFrameHint
    let windowId = request.windowId

    let expectedWindow = request.expectedWindow
    guard generations.isCurrent(request.generation, for: windowId) else {
        return cancelledFrameApplyResult(for: request)
    }
    let initialResult = writeFrame(
        expectedWindow,
        targetFrame,
        currentFrameHint,
        request.verify
    )
    guard generations.isCurrent(request.generation, for: windowId) else {
        return cancelledFrameApplyResult(for: request)
    }
    if initialResult.shouldRetryAfterRefresh,
       generations.isCurrent(request.generation, for: windowId),
       let refreshedAXRef = refreshWindow(UInt32(windowId), pid)
    {
        guard AppAXContext.acceptsRefreshedFrameElement(
            cachedElement: expectedWindow.element,
            refreshedElement: refreshedAXRef.element,
            windowId: windowId,
            requestGeneration: request.generation,
            generations: generations
        ) else {
            return cancelledFrameApplyResult(for: request)
        }
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
        let retryResult = writeFrame(
            refreshedAXRef,
            targetFrame,
            currentFrameHint,
            request.verify
        )
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
        return AXFrameApplyResult(
            requestId: request.requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: expectedWindow,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: retryResult
        )
    }

    return AXFrameApplyResult(
        requestId: request.requestId,
        pid: pid,
        windowId: windowId,
        expectedWindow: expectedWindow,
        targetFrame: targetFrame,
        currentFrameHint: currentFrameHint,
        writeResult: initialResult
    )
}

private func cancelledFrameApplyResult(for request: AppAXFrameWriteRequest) -> AXFrameApplyResult {
    AXFrameApplyResult(
        requestId: request.requestId,
        pid: request.pid,
        windowId: request.windowId,
        expectedWindow: request.expectedWindow,
        targetFrame: request.frame,
        currentFrameHint: request.currentFrameHint,
        writeResult: .skipped(
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            failureReason: .cancelled
        )
    )
}

private func axWindowNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let notificationName = notification as String
    let observerKey = axCallbackObserverKey(observer)
    let callbackGeneration = appAXCallbackGenerationRegistry.generation(observerKey: observerKey)

    var pid: pid_t = 0
    let pidStatus = AXUIElementGetPid(element, &pid)
    RawAXNotificationTrace.record(
        name: notificationName,
        pid: pid,
        windowId: refcon.map { Int(bitPattern: $0) },
        callbackGeneration: callbackGeneration
    )

    let isDestroyed = notificationName == (kAXUIElementDestroyedNotification as String)
    let isMiniaturized = notificationName == (kAXWindowMiniaturizedNotification as String)
    guard isDestroyed || isMiniaturized else { return }
    guard pidStatus == .success else { return }

    DiagnosticsEventRecorder.shared.recordLifecycle(name: notificationName, pid: pid)
    if isDestroyed {
        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            element: element,
            observerKey: observerKey,
            callbackGeneration: callbackGeneration,
            refcon: refcon
        )
    } else {
        AppAXContext.handleWindowMiniaturizedCallback(
            pid: pid,
            observerKey: observerKey,
            callbackGeneration: callbackGeneration,
            refcon: refcon
        )
    }
}

private func axFocusedWindowChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    guard (notification as String) == (kAXFocusedWindowChangedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    let observerKey = axCallbackObserverKey(observer)
    let callbackGeneration = appAXCallbackGenerationRegistry.generation(observerKey: observerKey)
    RawAXNotificationTrace.record(
        name: kAXFocusedWindowChangedNotification as String,
        pid: pid,
        windowId: nil,
        callbackGeneration: callbackGeneration
    )
    DiagnosticsEventRecorder.shared.recordLifecycle(name: kAXFocusedWindowChangedNotification as String, pid: pid)

    appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
        EventIntake.post(
            .axFocusedWindowChanged(
                pid: pid,
                callbackGeneration: callbackGeneration
            )
        )
    }
}

private func scheduleOnMainRunLoop(_ work: @escaping @MainActor () -> Void) {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            work()
        }
    }
    CFRunLoopWakeUp(mainRunLoop)
}
