// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import os

struct RingBuffer<Element> {
    let capacity: Int
    private var storage: ContiguousArray<Element?>
    private var nextIndex = 0
    private(set) var size = 0
    private(set) var evictionCount: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = []
    }

    var isEmpty: Bool {
        size == 0
    }

    var isStoragePrepared: Bool {
        !storage.isEmpty
    }

    mutating func prepareStorage() {
        guard storage.isEmpty else { return }
        storage = ContiguousArray(repeating: nil, count: capacity)
    }

    @discardableResult
    mutating func append(_ element: Element) -> Element? {
        prepareStorage()
        let evicted = storage[nextIndex]
        storage[nextIndex] = element
        nextIndex = (nextIndex + 1) % capacity
        if size < capacity {
            size += 1
        } else if evicted != nil {
            evictionCount &+= 1
        }
        return evicted
    }

    func snapshot() -> [Element] {
        guard size > 0 else { return [] }
        let start = size < capacity ? 0 : nextIndex
        var result: [Element] = []
        result.reserveCapacity(size)
        for offset in 0 ..< size {
            if let element = storage[(start + offset) % capacity] {
                result.append(element)
            }
        }
        return result
    }

    mutating func removeAll() {
        for index in storage.indices {
            storage[index] = nil
        }
        nextIndex = 0
        size = 0
        evictionCount = 0
    }

    mutating func releaseStorage() {
        storage = []
        nextIndex = 0
        size = 0
        evictionCount = 0
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

final class LockedRingBuffer<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private let state: OSAllocatedUnfairLock<RingBuffer<Element>>
    private let spare: OSAllocatedUnfairLock<RingBuffer<Element>?>

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        state = OSAllocatedUnfairLock(initialState: RingBuffer(capacity: capacity))
        spare = OSAllocatedUnfairLock(initialState: nil)
    }

    func append(_ element: Element) {
        state.withLock { state in
            _ = state.append(element)
        }
    }

    func append(_ element: Element, while predicate: @Sendable () -> Bool) {
        state.withLock { state in
            guard predicate() else { return }
            state.append(element)
        }
    }

    func snapshot() -> [Element] {
        state.withLock { $0.snapshot() }
    }

    func takeSnapshotWithEvictionCount() -> (records: [Element], evictionCount: UInt64) {
        guard state.withLock({ !$0.isEmpty }) else { return ([], 0) }
        var replacement = spare.withLock { available in
            let replacement = available ?? RingBuffer(capacity: capacity)
            available = nil
            return replacement
        }
        replacement.prepareStorage()
        state.withLockUnchecked { active in
            swap(&active, &replacement)
        }
        let snapshot = (replacement.snapshot(), replacement.evictionCount)
        replacement.removeAll()
        let clearedReplacement = replacement
        spare.withLock { available in
            if available == nil {
                available = clearedReplacement
            }
        }
        return snapshot
    }

    func removeAll() {
        state.withLock { $0.removeAll() }
    }

    func prepareStorage() {
        prepareActiveStorage()
        spare.withLock { available in
            var prepared = available ?? RingBuffer(capacity: capacity)
            prepared.prepareStorage()
            available = prepared
        }
    }

    func prepareActiveStorage() {
        state.withLock { $0.prepareStorage() }
    }

    func releaseStorage() {
        state.withLock { $0.releaseStorage() }
        spare.withLock { $0 = nil }
    }

    var isStoragePrepared: Bool {
        state.withLock { $0.isStoragePrepared }
    }

    var isSpareStoragePrepared: Bool {
        spare.withLock { $0?.isStoragePrepared ?? false }
    }

    func synchronize() {
        state.withLock { _ in }
    }
}
