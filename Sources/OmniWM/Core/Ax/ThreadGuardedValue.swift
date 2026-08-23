// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@usableFromInline
final class ThreadGuardedValue<Value>: Sendable {
    @usableFromInline
    nonisolated(unsafe) var _value: Value?

    @usableFromInline
    let threadToken: AppThreadToken

    init(_ value: Value) {
        guard let token = appThreadToken else {
            fatalError("appThreadToken is not initialized - must be called from within app thread context")
        }
        threadToken = token
        _value = value
    }

    @inlinable
    var value: Value {
        get {
            #if DEBUG
                threadToken.checkEquals(appThreadToken)
                guard let v = _value else {
                    fatalError("Value is already destroyed")
                }
                return v
            #else
                return _value.unsafelyUnwrapped
            #endif
        }
        set(newValue) {
            #if DEBUG
                threadToken.checkEquals(appThreadToken)
            #endif
            _value = newValue
        }
    }

    @inlinable
    var valueIfExists: Value? {
        #if DEBUG
            threadToken.checkEquals(appThreadToken)
        #endif
        return _value
    }

    func destroy() {
        #if DEBUG
            threadToken.checkEquals(appThreadToken)
        #endif
        _value = nil
    }

    deinit {
        assert(_value == nil, "The Value must be explicitly destroyed on the appropriate thread before deinit")
    }

    @inlinable
    subscript<K: Hashable, V>(key: K) -> V? where Value == [K: V] {
        get {
            #if DEBUG
                threadToken.checkEquals(appThreadToken)
            #endif
            return _value?[key]
        }
        set {
            #if DEBUG
                threadToken.checkEquals(appThreadToken)
            #endif
            _value?[key] = newValue
        }
    }
}
