// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Synchronization

final class AXCallbackGenerationRegistry: Sendable {
    private struct WindowElement: @unchecked Sendable {
        let value: AXUIElement
    }

    private struct ObserverState {
        let serviceGeneration: UInt64
        let callbackGeneration: UInt64
        let windowSubscriptions: ThreadGuardedValue<[Int: AppAXWindowSubscription]>?
        var retiredWindowElements: [WindowElement] = []
        var rejectsWindowNotifications = false
    }

    private struct State {
        var serviceGeneration: UInt64 = 1
        var nextCallbackGeneration: UInt64 = 1
        var observers: [UInt: ObserverState] = [:]
    }

    private let state = Mutex(State())

    static let retiredWindowElementLimit = 512

    var currentGeneration: UInt64 {
        state.withLock { $0.serviceGeneration }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.serviceGeneration == generation }
    }

    func reserveCallbackGeneration(serviceGeneration: UInt64) -> UInt64? {
        state.withLock {
            guard $0.serviceGeneration == serviceGeneration else { return nil }
            let generation = $0.nextCallbackGeneration
            $0.nextCallbackGeneration &+= 1
            return generation
        }
    }

    @discardableResult
    func register(
        observerKey: UInt,
        serviceGeneration: UInt64,
        callbackGeneration: UInt64,
        windowSubscriptions: ThreadGuardedValue<[Int: AppAXWindowSubscription]>? = nil
    ) -> Bool {
        state.withLock {
            guard $0.serviceGeneration == serviceGeneration else { return false }
            $0.observers[observerKey] = ObserverState(
                serviceGeneration: serviceGeneration,
                callbackGeneration: callbackGeneration,
                windowSubscriptions: windowSubscriptions
            )
            return true
        }
    }

    func unregister(observerKey: UInt) {
        _ = state.withLock { $0.observers.removeValue(forKey: observerKey) }
    }

    func generation(observerKey: UInt) -> UInt64? {
        state.withLock { $0.observers[observerKey]?.callbackGeneration }
    }

    func retireWindowElement(observerKey: UInt, element: AXUIElement) {
        let windowElement = WindowElement(value: element)
        state.withLock {
            guard var observer = $0.observers[observerKey],
                  observer.serviceGeneration == $0.serviceGeneration,
                  !observer.rejectsWindowNotifications,
                  !observer.retiredWindowElements.contains(where: {
                      CFEqual($0.value, windowElement.value)
                  })
            else {
                return
            }
            guard observer.retiredWindowElements.count < Self.retiredWindowElementLimit else {
                observer.retiredWindowElements.removeAll(keepingCapacity: false)
                observer.rejectsWindowNotifications = true
                $0.observers[observerKey] = observer
                return
            }
            observer.retiredWindowElements.append(windowElement)
            $0.observers[observerKey] = observer
        }
    }

    func rejectWindowNotifications(observerKey: UInt) {
        state.withLock {
            guard var observer = $0.observers[observerKey],
                  observer.serviceGeneration == $0.serviceGeneration
            else {
                return
            }
            observer.retiredWindowElements.removeAll(keepingCapacity: false)
            observer.rejectsWindowNotifications = true
            $0.observers[observerKey] = observer
        }
    }

    func allowsWindowRegistration(observerKey: UInt, element: AXUIElement) -> Bool {
        let windowElement = WindowElement(value: element)
        return state.withLock {
            guard let observer = $0.observers[observerKey],
                  observer.serviceGeneration == $0.serviceGeneration,
                  !observer.rejectsWindowNotifications
            else {
                return false
            }
            return !observer.retiredWindowElements.contains {
                CFEqual($0.value, windowElement.value)
            }
        }
    }

    @discardableResult
    func advance() -> UInt64 {
        state.withLock {
            $0.serviceGeneration &+= 1
            $0.observers.removeAll(keepingCapacity: false)
            return $0.serviceGeneration
        }
    }

    @discardableResult
    func performIfCurrent(observerKey: UInt, _ operation: () -> Void) -> Bool {
        state.withLock {
            guard let observer = $0.observers[observerKey],
                  observer.serviceGeneration == $0.serviceGeneration
            else {
                return false
            }
            operation()
            return true
        }
    }

    @discardableResult
    func performIfCurrentWindowNotification(
        observerKey: UInt,
        windowId: Int,
        element: AXUIElement,
        notification: AppAXWindowNotification,
        _ operation: () -> Void
    ) -> Bool {
        let windowElement = WindowElement(value: element)
        return state.withLock {
            guard let observer = $0.observers[observerKey],
                  observer.serviceGeneration == $0.serviceGeneration,
                  !observer.rejectsWindowNotifications,
                  !observer.retiredWindowElements.contains(where: {
                      CFEqual($0.value, windowElement.value)
                  }),
                  let subscription = observer.windowSubscriptions?[windowId],
                  subscription.owns(notification),
                  CFEqual(subscription.element, windowElement.value)
            else {
                return false
            }
            operation()
            return true
        }
    }
}

let appAXCallbackGenerationRegistry = AXCallbackGenerationRegistry()
